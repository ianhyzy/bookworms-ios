import CloudKit
import Foundation
import XCTest

@testable import Bookworms

/// Checks that a device uses iCloud for one Hardcover account only: the account check
/// (`CloudLibraryArchive.check(worklist:signedInAccountID:chosenAccountID:)`), the store's gate,
/// and **Merge**'s copy (`CloudSpineStore.copyRecords(from:into:books:)`).
final class OneAccountTests: XCTestCase {
    private let synced = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - The check

    func testAbsorbsFollowsChainsOneWayAndStopsAtCycles() {
        let merges = ["5": "10", "10": "20", "30": "40", "40": "30"]
        XCTAssertTrue(CloudLibraryArchive.absorbs("20", merges, into: "20"))
        XCTAssertTrue(CloudLibraryArchive.absorbs("10", merges, into: "20"))
        XCTAssertTrue(CloudLibraryArchive.absorbs("5", merges, into: "20"), "Chains count")
        XCTAssertFalse(CloudLibraryArchive.absorbs("20", merges, into: "10"), "One way only")
        XCTAssertFalse(CloudLibraryArchive.absorbs("30", merges, into: "20"), "A cycle stops")
        XCTAssertFalse(CloudLibraryArchive.absorbs("7", merges, into: "20"))
    }

    func testSignedInCheckListsEveryUnmergedRealAccount() {
        let mine = snapshot("20", books: [1, 2])
        let older = snapshot("10", books: [1, 3], username: "older_reader")
        let legacy = snapshot("hardcover", books: [9])
        func check(
            _ sources: [CloudSourceSnapshot], merges: [String: String]? = nil,
            worklist: SpineWorklistV1? = nil, signedIn: String = "20"
        ) -> CloudAccountCheck {
            CloudLibraryArchive(version: 1, sources: sources, merges: merges)
                .check(worklist: worklist, signedInAccountID: signedIn, chosenAccountID: "10")
        }

        XCTAssertEqual(
            check([mine, legacy]), .clear(accountID: "20"), "The placeholder is ignored")
        XCTAssertEqual(check([]), .clear(accountID: "20"))
        guard case .otherAccounts(let others) = check([mine, older, legacy]) else {
            return XCTFail("Another account's snapshot must ask")
        }
        XCTAssertEqual(others.map(\.id), ["10"])
        XCTAssertEqual(others.first?.name, "@older_reader")
        XCTAssertEqual(others.first?.bookIDs, [1, 3])
        XCTAssertEqual(others.first?.syncedAt, synced)

        XCTAssertEqual(check([mine, older], merges: ["10": "20"]), .clear(accountID: "20"))
        let oldest = snapshot("5", books: [4])
        XCTAssertEqual(
            check([mine, older, oldest], merges: ["5": "10", "10": "20"]),
            .clear(accountID: "20"), "A chain of merges counts")
        // The account merged into another doesn't absorb that account.
        XCTAssertEqual(
            check([mine, older], merges: ["10": "20"], signedIn: "10"),
            .otherAccounts([account("20", books: [1, 2])]))
        // A cycle that doesn't reach the signed-in account still asks.
        let third = snapshot("30", books: [5])
        guard
            case .otherAccounts(let cycle) = check(
                [mine, older, third], merges: ["10": "30", "30": "10"])
        else { return XCTFail("A cycle must ask") }
        XCTAssertEqual(cycle.map(\.id), ["10", "30"])

        // An account that only the worklist names asks too, by its ID.
        let worklist = SpineWorklistV1(
            version: 1, accountID: "7", syncedAt: synced.addingTimeInterval(9), bookIDs: [1, 8])
        XCTAssertEqual(
            check([mine], worklist: worklist),
            .otherAccounts([
                CloudAccount(
                    id: "7", username: nil, bookIDs: [1, 8], syncedAt: worklist.syncedAt)
            ]))
        XCTAssertEqual(account("7", books: []).name, "account 7")
        let placeholderList = SpineWorklistV1(
            version: 1, accountID: "hardcover", syncedAt: synced, bookIDs: [1])
        XCTAssertEqual(check([mine], worklist: placeholderList), .clear(accountID: "20"))
    }

    func testAccountNameComesFromTheNewestSnapshotWithAUsername() {
        let newer = snapshot("10", books: [1], at: synced.addingTimeInterval(60))
        let named = snapshot("10", books: [2], username: "kept_name")
        let check = CloudLibraryArchive(version: 1, sources: [named, newer])
            .check(worklist: nil, signedInAccountID: "20", chosenAccountID: nil)
        XCTAssertEqual(
            check,
            .otherAccounts([
                CloudAccount(
                    id: "10", username: "kept_name", bookIDs: [1],
                    syncedAt: synced.addingTimeInterval(60))
            ]))
    }

    func testSignedOutCheckAsksOnlyBetweenSeveralLibraries() {
        let first = snapshot("10", books: [1])
        let second = snapshot("20", books: [2], username: "second_reader")
        let legacy = snapshot("hardcover", books: [3])
        func check(
            _ sources: [CloudSourceSnapshot], merges: [String: String]? = nil,
            chosen: String? = nil
        ) -> CloudAccountCheck {
            CloudLibraryArchive(version: 1, sources: sources, merges: merges)
                .check(worklist: nil, signedInAccountID: nil, chosenAccountID: chosen)
        }

        XCTAssertEqual(check([]), .clear(accountID: nil))
        XCTAssertEqual(check([legacy]), .clear(accountID: nil))
        XCTAssertEqual(check([first, legacy]), .clear(accountID: "10"))
        XCTAssertEqual(
            check([first, second, legacy]),
            .chooseLibrary([account("10", books: [1]), account("20", books: [2], "second_reader")]))
        XCTAssertEqual(check([first, second], chosen: "20"), .clear(accountID: "20"))
        XCTAssertEqual(check([first, second], merges: ["10": "20"]), .clear(accountID: "20"))
        // Until the account merged into has a snapshot, the merged account is the only library.
        XCTAssertEqual(check([first], merges: ["10": "20"]), .clear(accountID: "10"))
        // A choice that is no longer a library asks again.
        XCTAssertEqual(
            check([first, second, snapshot("30", books: [4])], merges: ["10": "20"], chosen: "10"),
            .chooseLibrary([account("20", books: [2], "second_reader"), account("30", books: [4])]))
        // Merges in a cycle leave no library, so every account with a snapshot is one.
        guard
            case .chooseLibrary(let libraries) = check(
                [first, second], merges: ["10": "20", "20": "10"])
        else { return XCTFail("A cycle must ask") }
        XCTAssertEqual(libraries.map(\.id), ["10", "20"])
    }

    // MARK: - The store

    func testStoreUsesNoICloudDataUntilTheCheckClearsIt() async throws {
        let database = ChangeTagDatabase()
        let store = CloudSpineStore(database: database, defaultsSuite: try suite(signedInAs: "20"))
        await assertThrows(.iCloudUnavailable) { _ = try await store.topFivePins(accountID: "20") }

        try await putArchive(
            [snapshot("20", books: [1]), snapshot("10", books: [1])], in: database)
        guard case .otherAccounts = try await store.checkAccounts() else {
            return XCTFail("Another account's snapshot must ask")
        }
        await assertThrows(.otherAccountInICloud) {
            _ = try await store.topFivePins(accountID: "20")
        }
        await assertThrows(.otherAccountInICloud) {
            try await store.save(
                CoverChoiceV1(
                    version: 1, accountID: "20", bookID: 1,
                    coverURL: URL(string: "https://assets.hardcover.app/chosen.jpg")!,
                    editionID: nil, chosenAt: self.synced))
        }

        // Recording the merge opens the store, and the next check clears it too.
        try await store.recordMerges(["10": "20"])
        _ = try await store.topFivePins(accountID: "20")
        let check = try await store.checkAccounts()
        XCTAssertEqual(check, .clear(accountID: "20"))
        let stored = await database.payload(named: CloudContract.libraryRecordName)
        XCTAssertEqual(
            try JSONDecoder().decode(CloudLibraryArchive.self, from: try XCTUnwrap(stored)).merges,
            ["10": "20"])
    }

    func testAWorklistOfAnotherAccountClosesTheStore() async throws {
        let database = ChangeTagDatabase()
        let store = CloudSpineStore(database: database, defaultsSuite: try suite(signedInAs: "20"))
        try await database.put(
            SpineWorklistV1(version: 1, accountID: "7", syncedAt: synced, bookIDs: [1]),
            type: "SpineWorklistV1", name: CloudContract.worklistRecordName)
        let check = try await store.checkAccounts()
        XCTAssertEqual(
            check,
            .otherAccounts([CloudAccount(id: "7", username: nil, bookIDs: [1], syncedAt: synced)]))
        await assertThrows(.otherAccountInICloud) {
            _ = try await store.savedDesign(accountID: "20", bookID: 1)
        }
    }

    func testStoreWithICloudOffReadsNothing() async throws {
        let database = ChangeTagDatabase()
        // An unreadable archive would fail any check that read it.
        await database.put(
            payload: Data("not json".utf8), type: "LibraryArchive",
            name: CloudContract.libraryRecordName)
        let suite = try suite(signedInAs: "20")
        CloudStorage.setOff(true, in: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let store = CloudSpineStore(database: database, defaultsSuite: suite)
        let check = try await store.checkAccounts()
        XCTAssertEqual(check, .off)
        await assertThrows(.iCloudOff) { _ = try await store.topFivePins(accountID: "20") }
    }

    func testSignedOutStoreUsesTheChosenLibrary() async throws {
        let database = ChangeTagDatabase()
        let suite = try suite(signedInAs: nil)
        let store = CloudSpineStore(
            database: database, defaultsSuite: suite, userRecordName: "_test-user")
        // The library not chosen is the newest, and the worklist lists its books.
        try await putArchive(
            [
                snapshot("10", books: [1]),
                snapshot("20", books: [2], at: synced.addingTimeInterval(60)),
            ],
            in: database)
        try await database.put(
            SpineWorklistV1(
                version: 1, accountID: "20", syncedAt: synced.addingTimeInterval(60), bookIDs: [2]),
            type: "SpineWorklistV1", name: CloudContract.worklistRecordName)
        guard case .chooseLibrary = try await store.checkAccounts() else {
            return XCTFail("Two libraries must ask")
        }
        await assertThrows(.libraryChoiceNeeded) {
            _ = try await store.topFivePins(accountID: "10")
        }
        CloudStorage.choose("10", in: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let check = try await store.checkAccounts()
        XCTAssertEqual(check, .clear(accountID: "10"))
        _ = try await store.topFivePins(accountID: "10")

        let loaded = try await store.loadLibrary()
        let library = try XCTUnwrap(loaded)
        XCTAssertEqual(library.accountID, "10")
        XCTAssertEqual(library.books.map(\.id), [1])
        let loadedWork = try await store.loadWork()
        let work = try XCTUnwrap(loadedWork)
        XCTAssertEqual(work.accountID, "10")
        XCTAssertEqual(work.books.map(\.id), [1])
        XCTAssertFalse(work.followsWorklist, "Another account's worklist counts as none")
    }

    func testMergeCopiesEachRecordTypeWithoutReplacingTheAccountsOwn() async throws {
        let database = ChangeTagDatabase()
        let store = try await CloudSpineStore.checked(database)
        let first = CloudBook(
            id: 1, title: "First", author: "An Author",
            coverURL: URL(string: "https://assets.hardcover.app/first.jpg"), detailCoverURL: nil,
            seriesID: 5)
        let second = CloudBook(
            id: 2, title: "Second", author: "An Author", coverURL: nil, detailCoverURL: nil)
        func put(_ type: String, _ name: String, _ payload: [String: Any]) async throws {
            await database.put(
                payload: try JSONSerialization.data(withJSONObject: payload), type: type,
                name: name)
        }
        let oldDesign = CloudContract.designRecordName(accountID: "10", bookID: 1)
        try await put(
            "SpineDesignV1", oldDesign,
            ["version": 1, "accountID": "10", "bookID": 1, "workItemHash": "old", "kept": "yes"])
        try await put(
            "SpineDesignV1", CloudContract.designRecordName(accountID: "10", bookID: 2),
            ["version": 1, "accountID": "10", "bookID": 2, "workItemHash": "old"])
        let own = CloudContract.designRecordName(accountID: "20", bookID: 2)
        try await put(
            "SpineDesignV1", own,
            ["version": 1, "accountID": "20", "bookID": 2, "workItemHash": "mine"])
        try await put(
            "CoverChoiceV1", CloudContract.coverChoiceRecordName(accountID: "10", bookID: 1),
            ["version": 1, "accountID": "10", "bookID": 1])
        // A record under the old account's name that names another account is skipped.
        try await put(
            "CoverChoiceV1", CloudContract.coverChoiceRecordName(accountID: "10", bookID: 2),
            ["version": 1, "accountID": "11", "bookID": 2])
        try await database.put(
            SeriesLinkV1(
                version: 1, accountID: "10", bookID: 1, linkedSeriesID: 6, standsAlone: false,
                ownLook: false, chosenAt: synced),
            type: "SeriesLinkV1",
            name: CloudContract.seriesLinkRecordName(accountID: "10", bookID: 1))
        // The old account's link puts the book in series 6, whose look is copied too.
        let linkedKey = try XCTUnwrap(
            SeriesDesigns.lookKey(
                of: first,
                link: SeriesLinkV1(
                    version: 1, accountID: "10", bookID: 1, linkedSeriesID: 6,
                    standsAlone: false, ownLook: false, chosenAt: synced)))
        try await put(
            "SeriesLookV1", CloudContract.seriesLookRecordName(accountID: "10", key: linkedKey),
            ["version": 1, "accountID": "10", "seriesID": 6])
        try await put(
            "TopFivePinsV1", CloudContract.topFivePinsRecordName(accountID: "10"),
            ["version": 1, "accountID": "10", "bookIDs": [2, 99, 1]])

        try await store.copyRecords(from: "10", into: "20", books: [first, second])

        func payload(_ name: String) async throws -> [String: Any]? {
            guard let data = await database.payload(named: name) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let design = try await payload(CloudContract.designRecordName(accountID: "20", bookID: 1))
        XCTAssertEqual(design?["accountID"] as? String, "20")
        XCTAssertEqual(
            design?["workItemHash"] as? String,
            CloudContract.workItemHash(accountID: "20", book: first))
        XCTAssertEqual(design?["kept"] as? String, "yes", "Fields the app doesn't decode survive")
        let mine = try await payload(own)
        XCTAssertEqual(mine?["workItemHash"] as? String, "mine", "The account's own design stays")
        let cover = try await payload(
            CloudContract.coverChoiceRecordName(accountID: "20", bookID: 1))
        XCTAssertEqual(cover?["accountID"] as? String, "20")
        let skipped = try await payload(
            CloudContract.coverChoiceRecordName(accountID: "20", bookID: 2))
        XCTAssertNil(skipped)
        let link = try await payload(
            CloudContract.seriesLinkRecordName(accountID: "20", bookID: 1))
        XCTAssertEqual(link?["linkedSeriesID"] as? Int, 6)
        let look = try await payload(
            CloudContract.seriesLookRecordName(accountID: "20", key: linkedKey))
        XCTAssertEqual(look?["accountID"] as? String, "20")
        let pins = try await payload(CloudContract.topFivePinsRecordName(accountID: "20"))
        XCTAssertEqual(pins?["bookIDs"] as? [Int], [2, 1], "Pins keep only this account's books")
        let old = try await payload(oldDesign)
        XCTAssertEqual(old?["accountID"] as? String, "10", "The old account's records stay")
    }

    func testCopyAndRecordMergesThrowWhenSavesFail() async throws {
        let database = ChangeTagDatabase()
        try await putArchive([snapshot("10", books: [1])], in: database)
        let store = try await CloudSpineStore.checked(database)
        try await database.put(
            TopFivePinsV1(version: 1, accountID: "10", bookIDs: [1], pinnedAt: synced),
            type: "TopFivePinsV1", name: CloudContract.topFivePinsRecordName(accountID: "10"))
        await database.failEverySave(with: .networkFailure)
        let book = CloudBook(
            id: 1, title: "First", author: "An Author", coverURL: nil, detailCoverURL: nil)
        do {
            try await store.copyRecords(from: "10", into: "20", books: [book])
            XCTFail("A failed save must fail the copy")
        } catch {}
        do {
            try await store.recordMerges(["10": "20"])
            XCTFail("A failed save must fail the merge")
        } catch {}
        let stored = await database.payload(named: CloudContract.libraryRecordName)
        let archive = try XCTUnwrap(stored)
        XCTAssertNil(try JSONDecoder().decode(CloudLibraryArchive.self, from: archive).merges)
    }

    /// **Merge** copies newest account first and records the merges only after every copy
    /// succeeds, then publishes this account's library when iCloud has none.
    func testMergeRecordsOnlyAfterEveryCopyAndPublishesAMissingLibrary() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let calls = CallLog()
        var store = HeldStore(local: LocalSpineStore(folder: folder))
        store.beforeCopy = { old in
            await calls.append("copy \(old)")
            if old == "5" { throw CKError(.networkFailure) }
        }
        store.onRecordMerges = { await calls.append("record \($0.keys.sorted())") }
        let library = PhoneLibrary(
            accountID: "20", username: nil, syncedAt: synced,
            books: snapshot("20", books: [1, 2]).books)
        let others = [
            account("5", books: [2]),
            CloudAccount(id: "10", username: nil, bookIDs: [1], syncedAt: synced + 60),
        ]

        do {
            try await store.merge(others, into: library)
            XCTFail("A failed copy must fail the merge")
        } catch {}
        var logged = await calls.calls
        XCTAssertEqual(logged, ["copy 10", "copy 5"], "A failed copy records no merge")
        let unpublished = try await store.archivedLibrary(accountID: "20")
        XCTAssertNil(unpublished)

        store.beforeCopy = { await calls.append("copy \($0)") }
        try await store.merge(others, into: library)
        logged = await calls.calls
        XCTAssertEqual(logged.dropFirst(2), ["copy 10", "copy 5", "record [\"10\", \"5\"]"])
        let published = try await store.archivedLibrary(accountID: "20")
        XCTAssertEqual(published?.books.map(\.id), [1, 2])
    }

    // MARK: - Fixtures

    private func snapshot(
        _ accountID: String, books: [Int], username: String? = nil, at date: Date? = nil
    ) -> CloudSourceSnapshot {
        CloudSourceSnapshot(
            source: "hardcover", accountID: accountID,
            books: books.map {
                CloudBook(
                    id: $0, title: "Book \($0)", author: "An Author", coverURL: nil,
                    detailCoverURL: nil)
            },
            syncedAt: date ?? synced, username: username)
    }

    private func account(_ id: String, books: [Int], _ username: String? = nil) -> CloudAccount {
        CloudAccount(id: id, username: username, bookIDs: Set(books), syncedAt: synced)
    }

    private func putArchive(_ sources: [CloudSourceSnapshot], in database: ChangeTagDatabase)
        async throws
    {
        var archive: Data?
        for source in sources {
            archive = try CloudLibraryArchive.splice(source, into: archive)
        }
        await database.put(
            payload: try XCTUnwrap(archive), type: "LibraryArchive",
            name: CloudContract.libraryRecordName)
    }

    /// An empty user defaults suite of these tests' own, with a sign-in summary for `accountID`
    /// when it is given, removed when the test ends.
    private func suite(signedInAs accountID: String?) throws -> String {
        let suite = "gay.ian.Bookworms.iOS.tests.OneAccount"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        if let accountID {
            try XCTUnwrap(UserDefaults(suiteName: suite))
                .set(
                    try JSONEncoder()
                        .encode(HardcoverAccount.Summary(accountID: accountID, username: nil)),
                    forKey: HardcoverAccount.summaryKey)
        }
        return suite
    }

    private func assertThrows(
        _ expected: CompanionError, _ call: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await call()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CompanionError, expected, file: file, line: line)
        }
    }
}

/// The calls a test's store saw, in order.
actor CallLog {
    var calls: [String] = []

    func append(_ call: String) { calls.append(call) }
}

extension CloudSpineStore {
    /// A signed-out store on `database` whose account check has run, as `AppModel.reload()`
    /// runs it first, so the store reads and writes `database`.
    static func checked(_ database: some SpineCloudDatabase) async throws -> CloudSpineStore {
        // An empty suite that nothing writes, so the store reads no sign-in or iCloud choice.
        let store = CloudSpineStore(
            database: database, defaultsSuite: "gay.ian.Bookworms.iOS.tests.SignedOut")
        _ = try await store.checkAccounts()
        return store
    }
}
