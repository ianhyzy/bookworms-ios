import Foundation
import XCTest

@testable import Bookworms

/// Covers the `TopFivePinsV1` record: its contract, how a save merges another device's pins,
/// and how `AppModel` syncs the pins that the views keep in user defaults.
final class TopFivePinsSyncTests: XCTestCase {
    private let pinnedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func pins(_ ids: [Int], account: String = "42") -> TopFivePinsV1 {
        TopFivePinsV1(version: 1, accountID: account, bookIDs: ids, pinnedAt: pinnedAt)
    }

    func testRecordNameAndJSONKeys() throws {
        XCTAssertEqual(
            CloudContract.topFivePinsRecordName(accountID: "42"),
            "top-five-pins-v1-73475cb40a568e8da8a045ced110137e159f890ac4da883b6b17dc651b3a8049")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pins([7, 3])))
        XCTAssertEqual(
            Set(try XCTUnwrap(object as? [String: Any]).keys),
            ["version", "accountID", "bookIDs", "pinnedAt"])
        XCTAssertThrowsError(try pins([7, 7]).validate())
        XCTAssertThrowsError(try pins([1, 2, 3, 4, 5, 6]).validate())
        XCTAssertNil(pins([7]).checked(recordName: "top-five-pins-v1-other"))
    }

    func testASaveChangesOnlyThePinsThisDeviceChanged() {
        // This device last synced 1 and 2, then unpinned 1 and pinned 4; another device pinned 3.
        let merged = pins([2, 4]).merged(over: pins([1, 2, 3]), changing: pins([1, 2]))
        XCTAssertEqual(merged.bookIDs, [2, 3, 4])
        // Never synced, every pin counts as new; another account's record counts as none.
        XCTAssertEqual(pins([5]).merged(over: pins([1]), changing: nil).bookIDs, [1, 5])
        XCTAssertEqual(
            pins([5]).merged(over: pins([1], account: "9"), changing: nil).bookIDs, [5])
        // A pin unpinned and pinned again here moves, around another device's pin.
        XCTAssertEqual(
            pins([2, 1]).merged(over: pins([1, 3, 2]), changing: pins([1, 2])).bookIDs, [2, 3, 1])
        // With no record to merge with, the pins stay as they are, whatever changed.
        XCTAssertEqual(pins([1, 2]).merged(over: nil, changing: pins([1, 2, 3])).bookIDs, [1, 2])
        // Over Top Five's limit, the newest pins this device lacks give way to its own.
        XCTAssertEqual(
            pins([6, 7]).merged(over: pins([1, 2, 3, 4]), changing: pins([])).bookIDs,
            [1, 2, 3, 6, 7])
        // A new pin survives a full record whose fifth pin this device hides, as book 9 here.
        XCTAssertEqual(
            pins([1, 2, 3, 4, 6])
                .merged(over: pins([1, 2, 3, 4, 9]), changing: pins([1, 2, 3, 4])).bookIDs,
            [1, 2, 3, 4, 6])
    }

    func testCloudStoreKeepsAPinAnotherDeviceSavedMeanwhile() async throws {
        let database = ChangeTagDatabase()
        let store = try await CloudSpineStore.checked(database)
        let name = CloudContract.topFivePinsRecordName(accountID: "42")
        try await database.put(pins([1]), type: "TopFivePinsV1", name: name)
        // The Mac pins 3 between this save's read and write.
        try await database.putAfterNextFetch(pins([1, 3]), type: "TopFivePinsV1", name: name)
        let kept = try await store.save(pins([1, 2]), replacing: pins([1]))
        XCTAssertEqual(kept.bookIDs, [1, 3, 2])
        let saved = try await store.topFivePins(accountID: "42")
        XCTAssertEqual(saved, kept)
    }

    @MainActor
    func testModelSavesNewPinsThenShowsAnotherDevicesPins() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-pins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "gay.ian.Bookworms.tests.pins-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let archive = """
            {"version":1,"sources":[{"source":"hardcover","accountID":"42","syncedAt":1000,
              "books":[{"id":1,"title":"A Volume","author":"Ann Author"},
                       {"id":2,"title":"B Volume","author":"Ann Author"}]}]}
            """
        try Data(archive.utf8).write(to: folder.appending(path: "library-v1.json"))
        let store = LocalSpineStore(folder: folder)
        let model = AppModel(previewFolder: folder, store: store, pinDefaults: defaults)

        // Pins made before this device ever synced are saved at the first reload.
        defaults.set("2", forKey: TopFivePins.key)
        await model.reload()
        let first = try await store.topFivePins(accountID: "42")
        XCTAssertEqual(first?.bookIDs, [2])

        // Another device pins 1; the next sync shows it.
        _ = try await store.save(pins([2, 1]), replacing: pins([2]))
        await model.syncTopFivePins()
        XCTAssertEqual(defaults.string(forKey: TopFivePins.key), "2,1")

        // An unpin here saves over the record.
        defaults.set("1", forKey: TopFivePins.key)
        await model.syncTopFivePins()
        let unpinned = try await store.topFivePins(accountID: "42")
        XCTAssertEqual(unpinned?.bookIDs, [1])

        // A record gone missing, such as in another CloudKit environment, gets these pins again.
        try FileManager.default.removeItem(at: folder.appending(path: "top-five-pins-v1.json"))
        await model.syncTopFivePins()
        XCTAssertEqual(defaults.string(forKey: TopFivePins.key), "1")
        let restored = try await store.topFivePins(accountID: "42")
        XCTAssertEqual(restored?.bookIDs, [1])

        // A pin changed over a record gone missing keeps the other pins.
        defaults.set("1,2", forKey: TopFivePins.key)
        await model.syncTopFivePins()
        try FileManager.default.removeItem(at: folder.appending(path: "top-five-pins-v1.json"))
        defaults.set("1", forKey: TopFivePins.key)
        await model.syncTopFivePins()
        XCTAssertEqual(defaults.string(forKey: TopFivePins.key), "1")
        let changed = try await store.topFivePins(accountID: "42")
        XCTAssertEqual(changed?.bookIDs, [1])

        // A prune unpins only on this device, and the next sync shows the record's pins again.
        await model.hideUndrawableTopFivePins().value
        XCTAssertEqual(defaults.string(forKey: TopFivePins.key), "1", "No book is finished yet.")
        let finishedTwo = archive.replacingOccurrences(
            of: "\"title\":\"B Volume\"",
            with: "\"title\":\"B Volume\",\"finished\":\"2025-03-01\"")
        try Data(finishedTwo.utf8).write(to: folder.appending(path: "library-v1.json"))
        await model.reload()
        await model.hideUndrawableTopFivePins().value
        XCTAssertEqual(defaults.string(forKey: TopFivePins.key), "")
        await model.syncTopFivePins()
        let kept = try await store.topFivePins(accountID: "42")
        XCTAssertEqual(kept?.bookIDs, [1])
        XCTAssertEqual(defaults.string(forKey: TopFivePins.key), "1")

        // Another account drops pins left from this one, even those iCloud never confirmed, and
        // a pin made on it is its own.
        defaults.removeObject(forKey: TopFivePins.syncedKey)
        try Data(archive.replacingOccurrences(of: "\"42\"", with: "\"43\"").utf8)
            .write(to: folder.appending(path: "library-v1.json"))
        await model.reload()
        XCTAssertEqual(defaults.string(forKey: TopFivePins.key) ?? "", "")
        let other = try await store.topFivePins(accountID: "43")
        XCTAssertNil(other)
        defaults.set("2", forKey: TopFivePins.key)
        await model.syncTopFivePins()
        let otherPins = try await store.topFivePins(accountID: "43")
        XCTAssertEqual(otherPins?.bookIDs, [2])
    }
}
