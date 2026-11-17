import Foundation
import SwiftUI
import XCTest
import os

@testable import Bookworms

/// Covers how `AppModel` keeps the reader's edits around a reload, loads again after a failed
/// load, saves series choices, and keeps the example profile read-only.
final class AppModelTests: XCTestCase {
    private let cover = String(repeating: "b", count: 64)

    private func colors(_ background: String) -> SpineColors {
        SpineColors(
            background: ColorValue(hex: background)!, foreground: ColorValue(hex: "#F4E9D0")!,
            accent: ColorValue(hex: "#C08040")!)
    }

    private func book(_ id: Int, series: Int? = 5, position: Double? = nil) -> CloudBook {
        CloudBook(
            id: id, title: "Fictional Volume", author: "Ann Author", coverURL: nil,
            detailCoverURL: nil, seriesID: series, seriesPosition: position)
    }

    /// A design made for `book` as it is now, so it can seed its series' look.
    private func design(for book: CloudBook, accountID: String = "42") -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: accountID, bookID: book.id,
            workItemHash: CloudContract.workItemHash(accountID: accountID, book: book),
            coverHash: cover, generatorVersion: CloudContract.generatorVersion,
            generatedAt: Date(timeIntervalSince1970: 1_000_000), backgroundHex: "#000000",
            foregroundHex: "#FFFFFF", accentHex: "#FF0000", typeface: "serif", weight: 600,
            uppercase: false, fontFamily: nil)
    }

    /// A preview folder holding `books` of `accountID` and their saved `designs`; the folder is
    /// removed when the test ends.
    private func previewFolder(
        books: [CloudBook], designs: [SpineDesignV1], accountID: String = "42"
    ) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let archive: [String: Any] = [
            "version": 1,
            "sources": [
                [
                    "source": "hardcover", "accountID": accountID, "syncedAt": 1_000,
                    "books": try JSONSerialization.jsonObject(with: JSONEncoder().encode(books)),
                ]
            ],
        ]
        try JSONSerialization.data(withJSONObject: archive)
            .write(to: folder.appending(path: "library-v1.json"))
        try JSONEncoder()
            .encode(
                Dictionary(
                    uniqueKeysWithValues: designs.map {
                        (
                            CloudContract.designRecordName(accountID: accountID, bookID: $0.bookID),
                            $0
                        )
                    })
            )
            .write(to: folder.appending(path: "spine-designs-v1.json"))
        return folder
    }

    @MainActor
    func testEditsSavingAroundAReloadStayAndTheNextEditSaves() async throws {
        // Books 1 and 2 draw their series' look, and book 3 draws its own design.
        let books = [book(1, position: 1), book(2, position: 2), book(3, series: nil)]
        let folder = try previewFolder(books: books, designs: books.map { design(for: $0) })
        let store = HeldStore(local: LocalSpineStore(folder: folder))
        let model = AppModel(previewFolder: folder, store: store)
        await model.reload()
        XCTAssertNotNil(model.drawnLook(of: books[0]))

        // Edits that start saving before a reload and land after its fetch read the old records.
        await store.saves.hold()
        let lookEdit = Task { try await model.recolor(books[0], to: colors("#1A2B3C")) }
        let designEdit = Task { try await model.recolor(books[2], to: colors("#2B1A3C")) }
        await store.saves.wait(for: 2)
        await store.loads.hold()
        let reloading = Task { await model.reload() }
        await store.loads.wait(for: 1)
        await store.saves.release()
        try await lookEdit.value
        try await designEdit.value
        await store.loads.release()
        await reloading.value
        XCTAssertEqual(model.look(for: books[0]).background, colors("#1A2B3C").background)
        XCTAssertEqual(model.look(for: books[2]).background, colors("#2B1A3C").background)
        // The next edit of the look saves over the look the first one saved.
        try await model.recolor(books[0], to: colors("#3C1A2B"))

        // Edits still saving when a reload ends stay on screen.
        await store.saves.hold()
        let lookSaving = Task { try await model.recolor(books[0], to: colors("#1A3C2B")) }
        let designSaving = Task { try await model.recolor(books[2], to: colors("#2B3C1A")) }
        await store.saves.wait(for: 2)
        await model.reload()
        XCTAssertEqual(model.look(for: books[1]).background, colors("#1A3C2B").background)
        XCTAssertEqual(model.look(for: books[2]).background, colors("#2B3C1A").background)
        await store.saves.release()
        try await lookSaving.value
        try await designSaving.value
    }

    /// A reader's edit keeps another device's change of the look, and when the look is gone from
    /// iCloud, it lands after a reload on the look the book draws then.
    @MainActor
    func testEditsLandOnTheLookAsAnotherDeviceLeftIt() async throws {
        let books = [book(1, position: 1), book(2, position: 2)]
        let folder = try previewFolder(books: books, designs: books.map { design(for: $0) })
        let local = LocalSpineStore(folder: folder)
        let model = AppModel(previewFolder: folder, store: HeldStore(local: local))
        await model.reload()
        let look = try XCTUnwrap(model.drawnLook(of: books[0]))

        // Another device sets the series' font; this one, still showing `look`, sets colors.
        try await local.saveReaderEdit(
            .font(
                family: "Lora", postScriptName: "Lora-Bold", instanceWeight: 700,
                typeface: "serif"),
            at: .now, to: look)
        try await model.recolor(books[0], to: colors("#1A2B3C"))
        XCTAssertEqual(model.drawnLook(of: books[0])?.fontFamily, "Lora")
        XCTAssertEqual(model.look(for: books[1]).background, colors("#1A2B3C").background)

        // Another device's change leaves the group without a look: after the reload, the edit
        // lands on what the series draws then.
        try Data("{}".utf8).write(to: folder.appending(path: "series-looks-v1.json"))
        try await model.recolor(books[0], to: colors("#2B1A3C"))
        XCTAssertEqual(model.look(for: books[1]).background, colors("#2B1A3C").background)
    }

    @MainActor
    func testAPinChangedDuringASyncKeepsAnotherDevicesPin() async throws {
        let folder = try previewFolder(books: [1, 2, 3].map { book($0, series: nil) }, designs: [])
        let suite = "gay.ian.Bookworms.tests.pins-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = HeldStore(local: LocalSpineStore(folder: folder))
        let model = AppModel(previewFolder: folder, store: store, pinDefaults: defaults)
        let pins = { (ids: [Int]) in
            TopFivePinsV1(version: 1, accountID: "42", bookIDs: ids, pinnedAt: .now)
        }
        // This device confirmed 1; the Mac pinned 3 since.
        _ = try await store.save(pins([1, 3]), replacing: nil)
        defaults.set("1", forKey: TopFivePins.key)
        defaults.set(try JSONEncoder().encode(pins([1])), forKey: TopFivePins.syncedKey)

        // The reader pins 2 while the reload's sync reads the record.
        await store.pinReads.hold()
        let reloading = Task { await model.reload() }
        await store.pinReads.wait(for: 1)
        defaults.set("1,2", forKey: TopFivePins.key)
        let pinning = Task { await model.syncTopFivePins() }
        await store.pinReads.release()
        await reloading.value
        await pinning.value
        let saved = try await store.topFivePins(accountID: "42")
        XCTAssertEqual(saved?.bookIDs, [1, 3, 2])
        XCTAssertEqual(defaults.string(forKey: TopFivePins.key), "1,3,2")
    }

    @MainActor
    func testEnteringDeskEndsItsHoldOnce() throws {
        let model = AppModel(previewFolder: try previewFolder(books: [], designs: []))
        let before = model.deskHoldEnds
        model.selectedTab = .desk
        model.selectedTab = .desk
        XCTAssertEqual(model.deskHoldEnds, before + 1)
        model.selectedTab = .library
        XCTAssertEqual(model.deskHoldEnds, before + 1, "Leaving keeps the count")
        model.selectedTab = .desk
        XCTAssertEqual(model.deskHoldEnds, before + 2)
    }

    func testTheDeskKeepsItsBooksOnlyWhileTheReaderStays() {
        let hold = DeskBookHold(ends: 1, accountID: "42", isExample: false)
        func keeps(
            _ earlier: DeskBookHold?, isOnDesk: Bool = true, showsDetails: Bool = false,
            dropsBooks: Bool = true
        ) -> Bool {
            hold.keeps(
                earlier, isOnDesk: isOnDesk, showsDetails: showsDetails, dropsBooks: dropsBooks)
        }
        let earlierEntry = DeskBookHold(ends: 0, accountID: "42", isExample: false)

        XCTAssertTrue(keeps(hold), "A sync on the desk")
        XCTAssertFalse(keeps(hold, isOnDesk: false), "Away from the desk")
        XCTAssertFalse(keeps(hold, dropsBooks: false), "An empty desk")
        XCTAssertFalse(keeps(nil), "The first pass")
        XCTAssertFalse(keeps(earlierEntry), "A new entry or a chosen time frame")
        XCTAssertTrue(keeps(earlierEntry, showsDetails: true), "A return to open details")
        XCTAssertTrue(keeps(hold, isOnDesk: false, showsDetails: true), "Details left open")
        XCTAssertFalse(
            keeps(
                DeskBookHold(ends: 1, accountID: "7", isExample: false), showsDetails: true),
            "Another account")
        XCTAssertFalse(
            keeps(DeskBookHold(ends: 1, accountID: "42", isExample: true), showsDetails: true),
            "The example profile")
    }

    @MainActor
    func testAFailedLoadLoadsAgainAtTheNextActivation() async throws {
        let folder = try previewFolder(books: [book(1, series: nil)], designs: [])
        let model = AppModel(previewFolder: folder)
        await model.reload()
        let designs = folder.appending(path: "spine-designs-v1.json")
        try Data("not json".utf8).write(to: designs)
        await model.reload()
        XCTAssertNotNil(model.loadError)

        try Data("{}".utf8).write(to: designs)
        await model.reloadIfStale()
        XCTAssertNil(model.loadError)
    }

    @MainActor
    func testALibraryShownWithoutICloudNamesWhy() async throws {
        let folder = try previewFolder(books: [book(1, series: nil)], designs: [])
        var store = HeldStore(local: LocalSpineStore(folder: folder))
        store.loaded = {
            var library = $0
            library?.iCloudIssue = .noICloudAccount
            return library
        }
        let model = AppModel(previewFolder: folder, store: store)
        await model.reload()
        XCTAssertEqual(model.books.count, 1)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.iCloudIssue, CompanionError.noICloudAccount.errorDescription)
        // The reason belongs to the load, so the launch cache doesn't keep it.
        let cached = try JSONDecoder()
            .decode(
                LibrarySnapshot.self, from: JSONEncoder().encode(try XCTUnwrap(model.library)))
        XCTAssertNil(cached.iCloudIssue)
    }

    /// Until the account check clears iCloud, a reload keeps the designs of the library on
    /// screen: while the check can't run, the load fails at the closed store, and while the
    /// reader hasn't answered the prompt, it returns the library without iCloud's records.
    @MainActor
    func testAClosedICloudKeepsTheShownAccountsDesigns() async throws {
        let first = book(1, series: nil)
        let folder = try previewFolder(books: [first], designs: [design(for: first)])
        let closed = OSAllocatedUnfairLock<CompanionError?>(initialState: nil)
        var store = HeldStore(local: LocalSpineStore(folder: folder))
        store.loaded = { library in
            switch closed.withLock({ $0 }) {
            case nil: return library
            case .iCloudUnavailable?: throw CompanionError.iCloudUnavailable
            case let issue?:
                var bare = library
                bare?.designs = [:]
                bare?.iCloudIssue = issue
                return bare
            }
        }
        let model = AppModel(previewFolder: folder, store: store)
        await model.reload()
        XCTAssertNotNil(model.library?.designs[1])

        closed.withLock { $0 = .iCloudUnavailable }
        await model.reload()
        XCTAssertNotNil(model.library?.designs[1], "A failed check keeps the shown designs")
        XCTAssertNotNil(model.loadError)

        closed.withLock { $0 = .otherAccountInICloud }
        await model.reload()
        XCTAssertNotNil(model.library?.designs[1], "An unanswered prompt keeps the shown designs")
        XCTAssertEqual(model.iCloudIssue, CompanionError.otherAccountInICloud.errorDescription)
        XCTAssertNil(model.loadError)
    }

    @MainActor
    func testARestrictedICloudIsNotAskedToSignIn() async throws {
        let folder = try previewFolder(books: [book(1, series: nil)], designs: [])
        var store = HeldStore(local: LocalSpineStore(folder: folder))
        store.loaded = { _ in throw CompanionError.iCloudRestricted }
        let restricted = AppModel(previewFolder: folder, store: store)
        await restricted.reload()
        XCTAssertNil(restricted.library)
        XCTAssertEqual(restricted.loadError, CompanionError.iCloudRestricted.errorDescription)

        store.loaded = { _ in throw CompanionError.noICloudAccount }
        let signedOut = AppModel(previewFolder: folder, store: store)
        await signedOut.reload()
        XCTAssertEqual(
            signedOut.loadError, "Sign in to iCloud with the account your other Apple devices use.")
        XCTAssertNil(signedOut.iCloudIssue)
    }

    @MainActor
    func testNamingTheShortestSeriesLinksNoSeries() async throws {
        var shown = book(1, series: 9002)
        shown.seriesMemberships = [
            SeriesMembership(
                seriesID: 9001, name: "Fictional Saga", position: 1, featured: false,
                compilation: false, size: 3),
            SeriesMembership(
                seriesID: 9002, name: "Fictional Universe", featured: true, compilation: false,
                size: 40),
        ]
        let model = AppModel(previewFolder: try previewFolder(books: [shown], designs: []))
        await model.reload()
        XCTAssertEqual(SeriesDesigns.styleSeries(of: shown, link: nil)?.id, 9001)

        try await model.setSeriesLink(
            for: shown, linkedSeriesID: 9002, standsAlone: false, ownLook: false)
        XCTAssertEqual(model.books.first?.seriesLink?.linkedSeriesID, 9002)
        try await model.setSeriesLink(
            for: shown, linkedSeriesID: 9001, standsAlone: false, ownLook: false)
        XCTAssertNil(model.books.first?.seriesLink, "The default series deletes the link")
        try await model.setSeriesLink(
            for: shown, linkedSeriesID: 9001, standsAlone: false, ownLook: true)
        await model.reload()
        let link = try XCTUnwrap(model.books.first?.seriesLink)
        XCTAssertNil(link.linkedSeriesID)
        XCTAssertTrue(link.ownLook)
    }

    /// Each file in `folders` with its contents, to show that nothing wrote to them.
    private func contents(of folders: [URL]) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for folder in folders {
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                files[folder.lastPathComponent + "/" + name] = try Data(
                    contentsOf: folder.appending(path: name))
            }
        }
        return files
    }

    @MainActor
    func testTheExampleProfileIsReadOnlyAndUsesItsSyncDateAsNow() async throws {
        let shown = book(7, series: nil)
        let example = try previewFolder(
            books: [shown], designs: [design(for: shown, accountID: "example")],
            accountID: "example")
        let own = try previewFolder(books: [book(1, series: nil)], designs: [])
        let model = AppModel(previewFolder: own)
        let before = try contents(of: [example, own])

        await model.showExample(from: example)
        XCTAssertTrue(model.isExample)
        XCTAssertEqual(model.books.map(\.id), [7])
        XCTAssertEqual(model.selectedTab, .library)
        XCTAssertEqual(model.now, Date(timeIntervalSinceReferenceDate: 1_000))
        let background = model.look(for: shown).background

        // Reloads, edits, and generation results change nothing and write to neither folder. A
        // preview model writes no launch cache either way.
        await model.reload()
        try await model.recolor(shown, to: colors("#1A2B3C"))
        try await model.chooseCover(nil, for: shown)
        try await model.setSeriesLink(
            for: shown, linkedSeriesID: nil, standsAlone: true, ownLook: false)
        model.apply(design(for: shown, accountID: "example").recolored(colors("#2B1A3C")))
        XCTAssertEqual(model.library?.accountID, "example")
        XCTAssertEqual(model.look(for: shown).background, background)
        XCTAssertNil(model.books.first?.seriesLink)
        XCTAssertEqual(try contents(of: [example, own]), before)

        model.leaveExample()
        XCTAssertFalse(model.isExample)
        XCTAssertNil(model.library)
    }

    @MainActor
    func testTheExampleProfileKeepsItsChoicesApartFromTheSavedOnes() async throws {
        let example = try previewFolder(
            books: [book(7, series: nil)], designs: [], accountID: "example")
        let model = AppModel(previewFolder: try previewFolder(books: [], designs: []))
        var saved = ShelfSort.title
        let savedSort = Binding<ShelfSort>(get: { saved }, set: { saved = $0 })
        let sort = model.choice(\.sort, saved: savedSort)

        await model.showExample(from: example)
        XCTAssertEqual(sort.wrappedValue, .title)
        sort.wrappedValue = .author
        XCTAssertEqual(sort.wrappedValue, .author)
        XCTAssertEqual(saved, .title)

        model.leaveExample()
        XCTAssertEqual(sort.wrappedValue, .title)
        sort.wrappedValue = .rating
        XCTAssertEqual(saved, .rating)

        // Showing the example again starts from the saved choice.
        await model.showExample(from: example)
        XCTAssertEqual(sort.wrappedValue, .rating)
    }

    /// Leaving the example schedules the background run that the example skipped, once.
    @MainActor
    func testLeavingTheExampleProfileSchedulesGeneration() async throws {
        let example = try previewFolder(
            books: [book(7, series: nil)], designs: [], accountID: "example")
        let model = AppModel(previewFolder: try previewFolder(books: [], designs: []))
        var scheduled = 0
        model.schedulesGeneration = { scheduled += 1 }
        await model.showExample(from: example)
        XCTAssertEqual(scheduled, 0)

        model.leaveExample()
        XCTAssertEqual(scheduled, 1)
        model.leaveExample()
        XCTAssertEqual(scheduled, 1, "Only leaving the example schedules a run")
    }

    @MainActor
    func testAnAccountChangeEndsTheExampleProfile() async throws {
        let example = try previewFolder(
            books: [book(7, series: nil)], designs: [], accountID: "example")
        let model = AppModel(previewFolder: try previewFolder(books: [], designs: []))
        await model.showExample(from: example)
        XCTAssertTrue(model.isExample)

        model.account.onLibraryChange?()
        XCTAssertFalse(model.isExample)
        XCTAssertNil(model.library)
    }

    /// An account's library change, such as its first download, schedules a background run for
    /// its books, once, also when it ends the example profile.
    @MainActor
    func testAnAccountLibraryChangeSchedulesGeneration() async throws {
        let example = try previewFolder(
            books: [book(7, series: nil)], designs: [], accountID: "example")
        let model = AppModel(previewFolder: try previewFolder(books: [], designs: []))
        var scheduled = 0
        model.schedulesGeneration = { scheduled += 1 }

        model.account.onLibraryChange?()
        XCTAssertEqual(scheduled, 1)

        await model.showExample(from: example)
        XCTAssertTrue(model.isExample)
        model.account.onLibraryChange?()
        XCTAssertEqual(scheduled, 2)
    }

    @MainActor
    func testAMissingExampleProfileShowsNoLibrary() async throws {
        let model = AppModel(previewFolder: try previewFolder(books: [], designs: []))
        model.selectedTab = .spines
        await model.showExample(
            from: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        XCTAssertFalse(model.isExample)
        XCTAssertNil(model.library)
        XCTAssertNotNil(model.toasts.toast)
        XCTAssertEqual(model.selectedTab, .spines)

        await model.showExample(from: nil)
        XCTAssertFalse(model.isExample)
        XCTAssertNil(model.library)
    }
}

/// Lets a test hold the calls that reach it, as a slow network would, until it releases them.
actor Hold {
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func hold() { isHolding = true }

    func release() {
        isHolding = false
        for call in held { call.resume() }
        held = []
    }

    /// Returns at once unless the test holds calls.
    func pass() async {
        guard isHolding else { return }
        await withCheckedContinuation { held.append($0) }
    }

    /// Returns once `count` calls wait here.
    func wait(for count: Int) async {
        while held.count < count { await Task.yield() }
    }
}

/// A preview folder's store whose library load can wait after it reads the folder (`loads`),
/// whose reader edits can wait before they write (`saves`), and whose Top Five read can wait
/// after it reads the pins (`pinReads`). `loaded` can change or replace the folder's library
/// with what an iCloud load returns or throws. `beforeCheckedSave` runs before a design save that
/// checks the saved design against the one its caller read
/// (`SpineStore.save(_:replacing:ifUnchangedFrom:)`), with that design, so a test can change it
/// in between.
struct HeldStore: SpineStore {
    let local: LocalSpineStore
    let loads = Hold()
    let saves = Hold()
    let pinReads = Hold()
    var beforeCheckedSave: (@Sendable (SpineDesignV1) async throws -> Void)?
    var loaded: (@Sendable (LibrarySnapshot?) throws -> LibrarySnapshot?)?
    /// Runs before each **Merge** copy with the old account's ID, and can fail the copy.
    var beforeCopy: (@Sendable (String) async throws -> Void)?
    /// Runs with the merges that `recordMerges(_:)` records.
    var onRecordMerges: (@Sendable ([String: String]) async -> Void)?
    /// The books that another device holds a claim on (`claimDesign(accountID:bookID:)`).
    var claimedElsewhere: Set<Int> = []

    func claimDesign(accountID: String, bookID: Int) async -> Bool {
        !claimedElsewhere.contains(bookID)
    }

    func loadLibrary() async throws -> LibrarySnapshot? {
        let library = try await local.loadLibrary()
        await loads.pass()
        return try loaded?(library) ?? library
    }

    func saveRecolored(_ design: SpineDesignV1) async throws {
        await saves.pass()
        try await local.saveRecolored(design)
    }

    func saveRefonted(_ design: SpineDesignV1) async throws {
        await saves.pass()
        try await local.saveRefonted(design)
    }

    func saveEdited(_ look: SeriesLookV1, replacing base: SeriesLookV1) async throws {
        await saves.pass()
        try await local.saveEdited(look, replacing: base)
    }

    func saveReaderEdit(_ edit: SeriesLookEdit, at date: Date, to look: SeriesLookV1) async throws
        -> SeriesLookV1
    {
        await saves.pass()
        return try await local.saveReaderEdit(edit, at: date, to: look)
    }

    func loadWork() async throws -> WorkContext? { try await local.loadWork() }

    func savedDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1? {
        try await local.savedDesign(accountID: accountID, bookID: bookID)
    }

    func isStillCurrent(_ context: WorkContext, book: CloudBook) async throws -> Bool {
        try await local.isStillCurrent(context, book: book)
    }

    func save(_ design: SpineDesignV1, replacing: Bool, ifUnchangedFrom base: SpineDesignV1?)
        async throws -> SpineDesignV1
    {
        if let base { try await beforeCheckedSave?(base) }
        return try await local.save(design, replacing: replacing, ifUnchangedFrom: base)
    }

    func save(_ choice: CoverChoiceV1) async throws { try await local.save(choice) }

    func deleteCoverChoice(accountID: String, bookID: Int) async throws {
        try await local.deleteCoverChoice(accountID: accountID, bookID: bookID)
    }

    func save(_ link: SeriesLinkV1, replacing base: SeriesLinkV1?) async throws -> SeriesLinkV1? {
        try await local.save(link, replacing: base)
    }

    func topFivePins(accountID: String) async throws -> TopFivePinsV1? {
        let pins = try await local.topFivePins(accountID: accountID)
        await pinReads.pass()
        return pins
    }

    func save(_ pins: TopFivePinsV1, replacing base: TopFivePinsV1?) async throws -> TopFivePinsV1 {
        try await local.save(pins, replacing: base)
    }

    func seriesLooks(accountID: String, keys: Set<SeriesLookKey>) async throws
        -> [SeriesLookKey: SeriesLookV1]
    {
        try await local.seriesLooks(accountID: accountID, keys: keys)
    }

    func createLook(_ look: SeriesLookV1) async throws -> SeriesLookV1 {
        try await local.createLook(look)
    }

    func upgradeLook(_ look: SeriesLookV1) async throws -> SeriesLookV1 {
        try await local.upgradeLook(look)
    }

    func save(_ look: SeriesLookV1) async throws { try await local.save(look) }

    func installWorklistSubscription() async throws {
        try await local.installWorklistSubscription()
    }

    func archivedLibrary(accountID: String) async throws -> CloudSourceSnapshot? {
        try await local.archivedLibrary(accountID: accountID)
    }

    func publishLibrary(_ library: PhoneLibrary) async throws {
        try await local.publishLibrary(library)
    }

    func checkAccounts() async throws -> CloudAccountCheck { try await local.checkAccounts() }

    func copyRecords(from oldAccountID: String, into accountID: String, books: [CloudBook])
        async throws
    {
        try await beforeCopy?(oldAccountID)
        try await local.copyRecords(from: oldAccountID, into: accountID, books: books)
    }

    func recordMerges(_ merges: [String: String]) async throws {
        await onRecordMerges?(merges)
        try await local.recordMerges(merges)
    }
}
