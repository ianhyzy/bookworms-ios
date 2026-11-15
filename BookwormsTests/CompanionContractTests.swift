import CoreGraphics
import Foundation
import XCTest

@testable import Bookworms

final class CompanionContractTests: XCTestCase {
    func testCloudEnvironmentFollowsTheProfilesDebuggerEntitlement() {
        func profile(allowsDebugger: Bool) -> Data {
            Data(
                """
                signature<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\
                <key>Entitlements</key><dict><key>get-task-allow</key><\(allowsDebugger)/></dict>\
                </dict></plist>signature
                """
                .utf8)
        }
        XCTAssertEqual(CloudEnvironment.name(profile: profile(allowsDebugger: true)), "development")
        XCTAssertEqual(CloudEnvironment.name(profile: profile(allowsDebugger: false)), "production")
        XCTAssertEqual(CloudEnvironment.name(profile: nil), "production")
    }

    func testLedgerRechecksChangedWorkAfterSevenDaysAndBacksOffFailures() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = WorkLedger(url: url)
        try await ledger.useCloudUser("first-icloud-user")
        let now = Date(timeIntervalSince1970: 1_000_000)
        func needsCheck(
            _ ledger: WorkLedger, work: String = "work", after interval: TimeInterval = 0
        ) async -> Bool {
            await ledger.needsCheck(
                recordName: "record", workItemHash: work, now: now.addingTimeInterval(interval))
        }
        let newBook = await needsCheck(ledger)
        XCTAssertTrue(newBook)
        try await ledger.recordSuccess(
            recordName: "record", workItemHash: "work", now: now)
        let unchanged = await needsCheck(ledger, after: 6 * 86_400)
        let changedWork = await needsCheck(ledger, work: "edited")
        let dueAfterWeek = await needsCheck(ledger, after: 7 * 86_400)
        XCTAssertFalse(unchanged)
        XCTAssertTrue(changedWork)
        XCTAssertTrue(dueAfterWeek)

        try await ledger.recordFailure(recordName: "record", workItemHash: "work", now: now)
        let backingOff = await needsCheck(ledger, after: 23 * 3_600)
        let failedAndEdited = await needsCheck(ledger, work: "edited", after: 60)
        let retryAfterDay = await needsCheck(ledger, after: 86_400)
        XCTAssertFalse(backingOff)
        XCTAssertTrue(failedAndEdited)
        XCTAssertTrue(retryAfterDay)
        try await ledger.recordSuccess(
            recordName: "record", workItemHash: "work", now: now)
        let clearedFailure = await needsCheck(ledger, after: 2 * 86_400)
        XCTAssertFalse(clearedFailure)

        let restarted = WorkLedger(url: url)
        let persisted = await needsCheck(restarted, after: 60)
        XCTAssertFalse(persisted)
        try await restarted.useCloudUser("second-icloud-user")
        let switchedAccount = await needsCheck(restarted)
        XCTAssertTrue(switchedAccount)
        try await ledger.retain([])
        let removedBook = await needsCheck(ledger)
        XCTAssertTrue(removedBook)
    }

    func testLedgerRechecksAtOnceForABetterTierButNotForAnUnknownOne() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        // An entry saved without a tier, as an older ledger holds.
        let saved = """
            {"cloudUserRecordName":"user","entries":{"record":{"workItemHash":"work",\
            "coverHash":"cover","generatorVersion":"\(CloudContract.generatorVersion)",\
            "checkedAt":\(now.timeIntervalSinceReferenceDate)}}}
            """
        try Data(saved.utf8).write(to: url)
        let ledger = WorkLedger(url: url)
        try await ledger.useCloudUser("user")
        func needsCheck(at tier: ModelTier) async -> Bool {
            await ledger.needsCheck(
                recordName: "record", workItemHash: "work", runTier: tier,
                now: now.addingTimeInterval(60))
        }
        let unknownTier = await needsCheck(at: .privateCloudCompute)
        XCTAssertFalse(unknownTier, "An entry without a tier waits for the weekly recheck")

        try await ledger.recordSuccess(
            recordName: "record", workItemHash: "work", tier: .onDevice,
            now: now)
        let sameTier = await needsCheck(at: .onDevice)
        let lowerTier = await needsCheck(at: .local)
        let betterTier = await needsCheck(at: .backup)
        XCTAssertFalse(sameTier)
        XCTAssertFalse(lowerTier)
        XCTAssertTrue(betterTier)
        let persisted = await WorkLedger(url: url)
            .needsCheck(
                recordName: "record", workItemHash: "work", runTier: .privateCloudCompute,
                now: now.addingTimeInterval(60))
        XCTAssertTrue(persisted)

        // A capable model's check waits for the weekly recheck at every tier, because no run
        // replaces its design.
        try await ledger.recordSuccess(
            recordName: "record", workItemHash: "work", tier: .backup,
            now: now)
        let backupAtPCC = await needsCheck(at: .privateCloudCompute)
        XCTAssertFalse(backupAtPCC)
        try await ledger.recordSuccess(
            recordName: "record", workItemHash: "work",
            tier: .privateCloudCompute, now: now)
        let pccAtBackup = await needsCheck(at: .backup)
        XCTAssertFalse(pccAtBackup)

        // A design that awaits its font is checked again after a day, or at once at a better
        // tier.
        try await ledger.recordSuccess(
            recordName: "record", workItemHash: "work", tier: .local,
            awaitsFont: true, now: now)
        let awaitingSoon = await ledger.needsCheck(
            recordName: "record", workItemHash: "work", runTier: .local,
            now: now.addingTimeInterval(23 * 3_600))
        let awaitingAfterDay = await ledger.needsCheck(
            recordName: "record", workItemHash: "work", runTier: .local,
            now: now.addingTimeInterval(86_400))
        let awaitingBetterTier = await needsCheck(at: .onDevice)
        XCTAssertFalse(awaitingSoon)
        XCTAssertTrue(awaitingAfterDay)
        XCTAssertTrue(awaitingBetterTier)

        // A failure waits out its backoff even for a better tier.
        try await ledger.recordFailure(recordName: "record", workItemHash: "work", now: now)
        let backingOff = await needsCheck(at: .privateCloudCompute)
        XCTAssertFalse(backingOff)
    }

    /// A stand-in record names the design it marked, so another design saved since is no
    /// stand-in, and it survives a failed check and a restart.
    func testLedgerRemembersWhichDesignStoodIn() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = WorkLedger(url: url)
        try await ledger.useCloudUser("user")
        let now = Date(timeIntervalSince1970: 1_000_000)
        func design(generatedAt: Date) -> SpineDesignV1 {
            SpineDesignV1(
                version: 1, accountID: "account", bookID: 1,
                workItemHash: String(repeating: "a", count: 64),
                coverHash: String(repeating: "b", count: 64),
                generatorVersion: CloudContract.generatorVersion, generatedAt: generatedAt,
                backgroundHex: "#101010", foregroundHex: "#F4EEE2", accentHex: "#7A1F1F",
                typeface: "serif", weight: 700, uppercase: false)
        }
        let standIn = design(generatedAt: now.addingTimeInterval(0.123_456_789))
        let later = design(generatedAt: now.addingTimeInterval(60))
        try await ledger.recordSuccess(
            recordName: "record", workItemHash: "work", tier: .privateCloudCompute,
            standIn: (standIn, .backup), now: now)
        let marked = await ledger.standsIn(recordName: "record", for: .backup, design: standIn)
        let otherDesign = await ledger.standsIn(recordName: "record", for: .backup, design: later)
        let otherTier = await ledger.standsIn(
            recordName: "record", for: .privateCloudCompute, design: standIn)
        XCTAssertTrue(marked)
        XCTAssertFalse(otherDesign, "Another device's design saved since stays")
        XCTAssertFalse(otherTier)

        try await ledger.recordFailure(recordName: "record", workItemHash: "work", now: now)
        let restarted = WorkLedger(url: url)
        let afterFailure = await restarted.standsIn(
            recordName: "record", for: .backup, design: standIn)
        XCTAssertTrue(afterFailure, "A failed redo keeps the stand-in")
        let dueAfterBackoff = await restarted.needsCheck(
            recordName: "record", workItemHash: "work", runTier: .backup,
            now: now.addingTimeInterval(WorkLedger.failureBackoff))
        XCTAssertTrue(dueAfterBackoff)

        try await restarted.recordSuccess(
            recordName: "record", workItemHash: "work", tier: .backup, now: now)
        let redone = await restarted.standsIn(recordName: "record", for: .backup, design: standIn)
        XCTAssertFalse(redone)
    }

    /// A book checked under an earlier generator version waits for its weekly recheck at the
    /// same tier, since that run would only keep its design, and is rechecked at once only for a
    /// better tier.
    func testLedgerDoesNotRequeueKeptBooksForANewGenerator() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let saved = """
            {"cloudUserRecordName":"user","entries":{"record":{"workItemHash":"work",\
            "coverHash":"cover","generatorVersion":"ios-pcc-v1","tier":1,\
            "checkedAt":\(now.timeIntervalSinceReferenceDate)}}}
            """
        try Data(saved.utf8).write(to: url)
        let ledger = WorkLedger(url: url)
        try await ledger.useCloudUser("user")
        func needsCheck(at tier: ModelTier, after interval: TimeInterval = 60) async -> Bool {
            await ledger.needsCheck(
                recordName: "record", workItemHash: "work", runTier: tier,
                now: now.addingTimeInterval(interval))
        }
        let sameTier = await needsCheck(at: .onDevice)
        let lowerTier = await needsCheck(at: .local)
        let betterTier = await needsCheck(at: .privateCloudCompute)
        let weekly = await needsCheck(at: .onDevice, after: WorkLedger.recheckInterval)
        XCTAssertFalse(sameTier, "A new generator version alone queues no book")
        XCTAssertFalse(lowerTier)
        XCTAssertTrue(betterTier)
        XCTAssertTrue(weekly)

        // A check that kept a design records it under the current generator, and a run at the
        // check's tier doesn't queue the book again.
        try await ledger.recordSuccess(
            recordName: "record", workItemHash: "work", tier: .onDevice,
            now: now)
        let afterKeep = await needsCheck(at: .onDevice)
        XCTAssertFalse(afterKeep)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            written.contains(#""generatorVersion":"\#(CloudContract.generatorVersion)""#),
            "Earlier builds need the field to read the entry")
    }

    /// Spines letter the title before its first colon, trimmed, as the Apple TV does.
    func testSpineTitlesDropTheSubtitleAndTrim() {
        func spineTitle(_ title: String) -> String {
            CloudBook(id: 1, title: title, author: "An Author", coverURL: nil, detailCoverURL: nil)
                .spineTitle
        }
        XCTAssertEqual(spineTitle("Dune : Part One"), "Dune")
        XCTAssertEqual(spineTitle(": A Story"), ": A Story", "An empty head keeps the full title")
        XCTAssertEqual(spineTitle("Mort"), "Mort")
    }

    func testWorkSourceFollowsWorklistAccountAndSyncDate() throws {
        let synced = Date(timeIntervalSince1970: 2_000)
        let one = CloudBook(
            id: 1, title: "One", author: "Author", coverURL: nil, detailCoverURL: nil)
        let two = CloudBook(
            id: 2, title: "Two", author: "Author", coverURL: nil, detailCoverURL: nil)
        let archive = CloudLibraryArchive(
            version: 1,
            sources: [
                CloudSourceSnapshot(
                    source: "hardcover", accountID: "42", books: [one, two], syncedAt: synced),
                CloudSourceSnapshot(
                    source: "hardcover", accountID: "77", books: [two],
                    syncedAt: synced.addingTimeInterval(60)),
                CloudSourceSnapshot(
                    source: "cwa", accountID: "42", books: [one],
                    syncedAt: synced.addingTimeInterval(120)),
            ])
        let worklist = SpineWorklistV1(version: 1, accountID: "42", syncedAt: synced, bookIDs: [2])
        let work = try archive.workSource(for: worklist, accountID: nil)
        XCTAssertEqual(work.snapshot.accountID, "42")
        XCTAssertEqual(work.books.map(\.id), [2])
        XCTAssertTrue(work.followsWorklist)

        // An iPhone spliced a newer download of the account over the Apple TV's snapshot: the
        // newer snapshot's books are the work until the Apple TV lists it.
        let spliced = CloudLibraryArchive(
            version: 1,
            sources: [
                CloudSourceSnapshot(
                    source: "hardcover", accountID: "42", books: [one, two, one],
                    syncedAt: synced.addingTimeInterval(3_600))
            ] + archive.sources.dropFirst())
        let newer = try spliced.workSource(for: worklist, accountID: nil)
        XCTAssertEqual(newer.snapshot.syncedAt, synced.addingTimeInterval(3_600))
        XCTAssertEqual(newer.books.map(\.id), [1, 2])
        XCTAssertFalse(newer.followsWorklist)
        XCTAssertFalse(try archive.workSource(for: nil, accountID: nil).followsWorklist)

        // The Apple TV listed a newer sync than the archive holds: its upload is still pending.
        let ahead = SpineWorklistV1(
            version: 1, accountID: "42", syncedAt: synced.addingTimeInterval(1), bookIDs: [2])
        XCTAssertThrowsError(try archive.workSource(for: ahead, accountID: nil)) { error in
            guard case CompanionError.waitingForLibrary = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        // With an account, its snapshot is the work, and another account's worklist counts as
        // none.
        let chosen = try archive.workSource(for: worklist, accountID: "77")
        XCTAssertEqual(chosen.snapshot.accountID, "77")
        XCTAssertEqual(chosen.books.map(\.id), [2])
        XCTAssertFalse(chosen.followsWorklist)
        XCTAssertTrue(try archive.workSource(for: worklist, accountID: "42").followsWorklist)
    }

    func testWorkSourceWithoutWorklistPrefersNewestRealAccount() throws {
        let book = CloudBook(
            id: 3, title: "Three", author: "Author", coverURL: nil, detailCoverURL: nil)
        let duplicate = CloudBook(
            id: 3, title: "Copy", author: "Author", coverURL: nil, detailCoverURL: nil)
        let older = Date(timeIntervalSince1970: 1_000)
        let archive = CloudLibraryArchive(
            version: 1,
            sources: [
                CloudSourceSnapshot(
                    source: "hardcover", accountID: "hardcover", books: [book],
                    syncedAt: older.addingTimeInterval(500)),
                CloudSourceSnapshot(
                    source: "hardcover", accountID: "42", books: [book, duplicate],
                    syncedAt: older),
                CloudSourceSnapshot(
                    source: "hardcover", accountID: "41", books: [book],
                    syncedAt: older.addingTimeInterval(-1)),
            ])
        let work = try archive.workSource(for: nil, accountID: nil)
        XCTAssertEqual(work.snapshot.accountID, "42")
        XCTAssertEqual(work.books.map(\.title), ["Three"])
        // A merged account's snapshot no longer counts, and a chosen account's always does.
        var merged = archive
        merged.merges = ["42": "41"]
        XCTAssertEqual(try merged.workSource(for: nil, accountID: nil).snapshot.accountID, "41")
        XCTAssertEqual(try merged.workSource(for: nil, accountID: "42").snapshot.accountID, "42")

        let legacyOnly = CloudLibraryArchive(
            version: 1, sources: [archive.sources[0]])
        XCTAssertEqual(
            try legacyOnly.workSource(for: nil, accountID: nil).snapshot.accountID, "hardcover")
        let empty = CloudLibraryArchive(version: 1, sources: [])
        XCTAssertThrowsError(try empty.workSource(for: nil, accountID: nil))
        // A CWA-only Apple TV uploaded its library; there is nothing to wait for.
        let cwaOnly = CloudLibraryArchive(
            version: 1,
            sources: [
                CloudSourceSnapshot(source: "cwa", accountID: "42", books: [book], syncedAt: older)
            ])
        XCTAssertThrowsError(try cwaOnly.workSource(for: nil, accountID: nil)) { error in
            guard case CompanionError.noHardcoverLibrary = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCoverCandidatesPreferDetailImageAndDeduplicate() {
        let detail = URL(string: "https://images.example.com/detail.jpg")!
        let alternate = URL(string: "https://images.example.com/alternate.jpg")!
        let book = CloudBook(
            id: 4, title: "A Book", author: "An Author",
            coverURL: alternate, detailCoverURL: detail)
        XCTAssertEqual(book.coverCandidates, [detail, alternate])
        let duplicate = CloudBook(
            id: 4, title: "A Book", author: "An Author",
            coverURL: detail, detailCoverURL: detail)
        XCTAssertEqual(duplicate.coverCandidates, [detail])
    }

    func testWorklistDeduplicatesAndRejectsMissingArchiveBooks() throws {
        let first = CloudBook(
            id: 1, title: "One", author: "Author", coverURL: nil, detailCoverURL: nil)
        let duplicate = CloudBook(
            id: 1, title: "Duplicate", author: "Author", coverURL: nil,
            detailCoverURL: nil)
        let second = CloudBook(
            id: 2, title: "Two", author: "Author", coverURL: nil, detailCoverURL: nil)
        let source = CloudSourceSnapshot(
            source: "hardcover", accountID: "42", books: [first, duplicate, second],
            syncedAt: Date())
        let worklist = SpineWorklistV1(
            version: 1, accountID: "42", syncedAt: source.syncedAt, bookIDs: [1, 2])
        XCTAssertNoThrow(try worklist.validate())
        XCTAssertEqual(try source.selectedBooks(in: worklist).map(\.title), ["One", "Two"])
        let duplicateIDs = SpineWorklistV1(
            version: 1, accountID: "42", syncedAt: source.syncedAt, bookIDs: [1, 1, 2])
        XCTAssertThrowsError(try duplicateIDs.validate())
        let missing = SpineWorklistV1(
            version: 1, accountID: "42", syncedAt: source.syncedAt, bookIDs: [1, 3])
        XCTAssertThrowsError(try source.selectedBooks(in: missing))
        // A newer build's worklist asks for an update, as a newer archive does.
        let future = SpineWorklistV1(
            version: 2, accountID: "42", syncedAt: source.syncedAt, bookIDs: [1, 2])
        XCTAssertThrowsError(try future.validate()) { error in
            guard case CompanionError.unsupportedCloudData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWorkHashIncludesAccountAndCoverURLs() {
        let book = CloudBook(
            id: 8, title: "Book", author: "Author",
            coverURL: URL(string: "https://images.example.com/alternate"),
            detailCoverURL: URL(string: "https://images.example.com/preferred"))
        let expected = CloudContract.digest(
            "account\n8\nBook\nAuthor\nhttps://images.example.com/preferred\nhttps://images.example.com/alternate"
        )
        XCTAssertEqual(CloudContract.workItemHash(accountID: "account", book: book), expected)
        XCTAssertNotEqual(
            CloudContract.workItemHash(accountID: "another", book: book), expected)
    }

    func testWireHashesMatchAppleTVContract() {
        let book = CloudBook(
            id: 7, title: "Wyke", author: "Tamsin Vellor",
            coverURL: URL(string: "https://example.test/catalog.jpg"),
            detailCoverURL: URL(string: "https://example.test/edition.jpg"))
        XCTAssertEqual(
            CloudContract.workItemHash(accountID: "42", book: book),
            "aefaaf3fe90bbd71ba5963a0fcbd0671eaa32cf5cc0d14938dfc68e4500cddac")
        // The series name is not part of the work-item hash.
        var named = book
        named.seriesName = "Wyke Cycle"
        XCTAssertEqual(
            CloudContract.workItemHash(accountID: "42", book: named),
            CloudContract.workItemHash(accountID: "42", book: book))
        XCTAssertEqual(
            CloudContract.designRecordName(accountID: "42", bookID: 7),
            "spine-design-v1-755dac3729029e2e2976249c4e03b160c699ef71f296c346e22183dc23503c33")
    }

    func testCoverURLPolicyRejectsLocalAndCredentialURLs() {
        XCTAssertTrue(CoverURLPolicy.allows(URL(string: "https://images.example.com/cover.jpg")))
        for value in [
            "http://images.example.com/cover.jpg",
            "https://127.0.0.1/cover.jpg",
            "https://server.local/cover.jpg",
            "https://user:password@images.example.com/cover.jpg",
            "https://images.example.com:8443/cover.jpg",
            "https://images.example.com/cover.jpg#fragment",
            "https://images.example.com./cover.jpg",
        ] {
            XCTAssertFalse(CoverURLPolicy.allows(URL(string: value)), value)
        }
    }

    func testDesignRequiresReadableColorsAndSupportedTypography() throws {
        let valid = SpineDesignV1(
            version: 1, accountID: "account", bookID: 1,
            workItemHash: String(repeating: "a", count: 64),
            coverHash: String(repeating: "b", count: 64),
            generatorVersion: CloudContract.generatorVersion,
            generatedAt: Date(), backgroundHex: "#000000",
            foregroundHex: "#FFFFFF", accentHex: "#FFFFFF",
            typeface: "serif", weight: 600, uppercase: false)
        XCTAssertNoThrow(try valid.validate())
        let unreadable = SpineDesignV1(
            version: valid.version, accountID: valid.accountID, bookID: valid.bookID,
            workItemHash: valid.workItemHash, coverHash: valid.coverHash,
            generatorVersion: valid.generatorVersion, generatedAt: valid.generatedAt,
            backgroundHex: "#FFFFFF", foregroundHex: "#FFFFFF",
            accentHex: "#000000", typeface: "serif", weight: 600, uppercase: false)
        XCTAssertThrowsError(try unreadable.validate())
    }

    func testAccentUsesHighestContrastSampleBeforeNeutralFallback() {
        let background = ColorValue(hex: "#000000")!
        let poorChoice = ColorValue(hex: "#202020")!
        let lowerContrast = ColorValue(hex: "#A0A0A0")!
        let bestSample = ColorValue(hex: "#C0C0C0")!
        let palette = [background, poorChoice, lowerContrast, bestSample]
        XCTAssertEqual(
            CoverPalette.readableAccent(
                for: background, proposed: poorChoice, palette: palette),
            bestSample)
        XCTAssertEqual(
            CoverPalette.readableAccent(
                for: background, proposed: lowerContrast, palette: palette),
            lowerContrast)
        XCTAssertEqual(
            CoverPalette.readableAccent(
                for: background, proposed: poorChoice, palette: [background, poorChoice]),
            ColorValue(hex: "#FFFFFF"))
    }

    func testPaletteClustersTwoColorImageDeterministically() throws {
        let side = 128
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                // Left half red, right half blue, both opaque.
                pixels[offset] = x < side / 2 ? 255 : 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = x < side / 2 ? 0 : 255
            }
        }
        let image = try XCTUnwrap(
            pixels.withUnsafeMutableBytes { buffer in
                CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .makeImage()
            })
        let first = try CoverPalette.sample(image)
        XCTAssertEqual(first, try CoverPalette.sample(image))
        XCTAssertEqual(first.count, 2)
        func near(_ color: ColorValue, _ red: Int, _ green: Int, _ blue: Int) -> Bool {
            abs(color.red - red) <= 2 && abs(color.green - green) <= 2
                && abs(color.blue - blue) <= 2
        }
        XCTAssertTrue(first.contains { near($0, 255, 0, 0) }, "\(first.map(\.hex))")
        XCTAssertTrue(first.contains { near($0, 0, 0, 255) }, "\(first.map(\.hex))")
    }

    func testInkCandidatesListDarkInksBeforeLightInks() {
        let palette = ["#7A2E1F", "#1F3A5A", "#D8CBB0"].compactMap(ColorValue.init(hex:))
        let inks = CoverPalette.inkCandidates(for: palette)
        XCTAssertEqual(inks.count, Set(inks).count)
        XCTAssertEqual(inks.count, 6)
        let lightness = inks.map { SpineContrast.lab($0).l }
        XCTAssertTrue(lightness.prefix(3).allSatisfy { abs($0 - 0.22) < 0.04 }, "\(lightness)")
        XCTAssertTrue(lightness.suffix(3).allSatisfy { abs($0 - 0.93) < 0.04 }, "\(lightness)")
        let gray = [ColorValue(hex: "#808080")!, ColorValue(hex: "#7F7F7F")!]
        XCTAssertEqual(CoverPalette.inkCandidates(for: gray).count, 2)
    }

    func testAPCAMatchesReferenceValues() {
        let black = ColorValue(hex: "#000000")!
        let white = ColorValue(hex: "#FFFFFF")!
        XCTAssertEqual(SpineContrast.apca(text: black, background: white), 106.04, accuracy: 0.05)
        XCTAssertEqual(SpineContrast.apca(text: white, background: black), -107.88, accuracy: 0.05)
        XCTAssertEqual(
            SpineContrast.apca(text: ColorValue(hex: "#888888")!, background: white), 63.06,
            accuracy: 0.1)
        XCTAssertEqual(SpineContrast.apca(text: white, background: white), 0)
    }

    func testContrastResolutionKeepsInkPolarity() {
        func resolve(_ ink: String, on cloth: String) -> (ColorValue, ColorValue, Double) {
            let pair = SpineContrast.resolve(
                foreground: ColorValue(hex: ink)!, background: ColorValue(hex: cloth)!,
                minimumLc: 75)
            return (
                pair.foreground, pair.background,
                SpineContrast.apca(text: pair.foreground, background: pair.background)
            )
        }
        func lightness(_ hex: String) -> Double { SpineContrast.lab(ColorValue(hex: hex)!).l }

        // White ink on rust cloth cannot pass alone, so the cloth darkens under it.
        let (lightInk, darkenedCloth, lightLc) = resolve("#FFFFFF", on: "#E04020")
        XCTAssertEqual(lightInk.hex, "#FFFFFF")
        XCTAssertLessThan(SpineContrast.lab(darkenedCloth).l, lightness("#E04020"))
        XCTAssertLessThanOrEqual(lightLc, -75)

        // Off-white ink on rust cloth stays light and passes without moving the cloth.
        let (offWhite, rust, offWhiteLc) = resolve("#F5EBDC", on: "#B85A2A")
        XCTAssertGreaterThan(SpineContrast.lab(offWhite).l, lightness("#F5EBDC"))
        XCTAssertEqual(rust.hex, "#B85A2A")
        XCTAssertLessThanOrEqual(offWhiteLc, -75)

        // Dark ink on dark cloth stays dark, so the cloth lightens under black.
        let (darkInk, lightenedCloth, darkLc) = resolve("#222222", on: "#555555")
        XCTAssertEqual(darkInk.hex, "#000000")
        XCTAssertGreaterThan(SpineContrast.lab(lightenedCloth).l, lightness("#555555"))
        XCTAssertGreaterThanOrEqual(darkLc, 75)

        // White on mid-tone blue passes APCA 75 but not WCAG 4.5:1, which the contract requires.
        let white = ColorValue(hex: "#FFFFFF")!
        let blue = ColorValue(hex: "#007EBE")!
        XCTAssertGreaterThanOrEqual(abs(SpineContrast.apca(text: white, background: blue)), 75)
        XCTAssertLessThan(white.contrast(with: blue), 4.5)
        let pair = SpineContrast.resolve(foreground: white, background: blue, minimumLc: 75)
        XCTAssertGreaterThanOrEqual(pair.foreground.contrast(with: pair.background), 4.5)
        XCTAssertGreaterThanOrEqual(
            abs(SpineContrast.apca(text: pair.foreground, background: pair.background)), 75)
    }

    func testDesignValidatesOptionalFontFields() throws {
        func design(
            fontFamily: String? = nil, weight: Int = 600, instanceWeight: Int? = nil
        ) -> SpineDesignV1 {
            SpineDesignV1(
                version: 1, accountID: "account", bookID: 1,
                workItemHash: String(repeating: "a", count: 64),
                coverHash: String(repeating: "b", count: 64),
                generatorVersion: CloudContract.generatorVersion, generatedAt: Date(),
                backgroundHex: "#000000", foregroundHex: "#FFFFFF", accentHex: "#FFFFFF",
                typeface: "serif", weight: weight, uppercase: false, fontFamily: fontFamily,
                instanceWeight: instanceWeight)
        }
        XCTAssertNoThrow(try design(fontFamily: nil).validate())
        XCTAssertNoThrow(try design(fontFamily: "EB Garamond").validate())
        XCTAssertNoThrow(try design(fontFamily: String(repeating: "x", count: 80)).validate())
        XCTAssertThrowsError(try design(fontFamily: "").validate())
        XCTAssertThrowsError(try design(fontFamily: String(repeating: "x", count: 81)).validate())
        XCTAssertThrowsError(try design(fontFamily: "EB\nGaramond").validate())

        // The Apple TV accepts only these requested weights; the instance weight is separate.
        for weight in [400, 500, 600, 700] {
            XCTAssertNoThrow(try design(weight: weight).validate())
        }
        for weight in [100, 300, 800, 900, 450] {
            XCTAssertThrowsError(try design(weight: weight).validate())
        }
        XCTAssertNoThrow(try design(weight: 500, instanceWeight: 100).validate())
        XCTAssertNoThrow(try design(weight: 700, instanceWeight: 900).validate())
        for instanceWeight in [0, 50, 450, 1000] {
            XCTAssertThrowsError(try design(instanceWeight: instanceWeight).validate())
        }
        let encoded = try JSONEncoder().encode(design())
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("instanceWeight"))
    }

    func testCoreTextWeightTraitsMapToCSSWeights() {
        let traits: [Double] = [-0.6, -0.4, -0.23, 0, 0.2, 0.3, 0.4, 0.6, 0.8]
        XCTAssertEqual(
            traits.map(FontFiles.cssWeight(forTrait:)),
            Array(stride(from: 100, through: 900, by: 100)))
    }

    func testSpineFamilyRawValuesAreUniqueAndNonEmpty() {
        let names = SpineFamily.allCases.map(\.rawValue)
        XCTAssertEqual(names.count, 113)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertFalse(names.contains { $0.lowercased() == "impact" })
    }

    func testUppercaseFollowsCoverLetteringFromOCR() {
        XCTAssertTrue(BookAnalyzer.prefersUppercase("A QUARREL OF CROWNS · HELENA R.T. MARSH"))
        XCTAssertTrue(BookAnalyzer.prefersUppercase("THE LONG WAGER · Martin Lowe"))
        XCTAssertFalse(BookAnalyzer.prefersUppercase("Pulsebeat · Ada Oswin"))
        // Too little lettering to judge keeps mixed case.
        XCTAssertFalse(BookAnalyzer.prefersUppercase("OK"))
        XCTAssertFalse(BookAnalyzer.prefersUppercase(""))
    }
}
