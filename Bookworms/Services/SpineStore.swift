import Foundation

/// Where the companion reads the Apple TV library and saves spine designs.
///
/// `CloudSpineStore` is the private iCloud database the Apple TV shares. `LocalSpineStore` reads
/// a folder of the same JSON for Simulator previews and tests, so no iCloud account is needed.
protocol SpineStore: Sendable {
    /// Returns the books to design, or `nil` when the Apple TV has listed no work.
    func loadWork() async throws -> WorkContext?
    /// Returns the book's saved design when it is valid and made by this app's generator.
    func currentDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1?
    /// Returns whether `bookID` still belongs to the work in `context`, so a stale result is not
    /// saved after the Apple TV changed accounts or removed the book.
    func isStillCurrent(_ context: WorkContext, bookID: Int) async throws -> Bool
    /// Saves `design` unless an equal or newer design for the same work already exists.
    func save(_ design: SpineDesignV1) async throws
    /// Returns the active account's books and every valid saved design, or `nil` before the
    /// Apple TV uploads a library.
    func loadLibrary() async throws -> LibrarySnapshot?
    /// Subscribes to worklist changes so a silent push can schedule generation.
    func installWorklistSubscription() async throws
}

/// Reads and writes the iCloud JSON shapes in a local folder.
///
/// The folder holds `library-v1.json` (the archive), an optional `spine-worklist-v1.json`, and
/// `spine-designs-v1.json` (`[recordName: SpineDesignV1]`, the Apple TV cache shape).
actor LocalSpineStore: SpineStore {
    private let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    func loadWork() async throws -> WorkContext? {
        let worklist = try decode(SpineWorklistV1.self, "spine-worklist-v1.json")
        try worklist?.validate()
        guard let archive = try decode(CloudLibraryArchive.self, "library-v1.json") else {
            return nil
        }
        let (snapshot, books) = try archive.workSource(for: worklist)
        return WorkContext(
            accountID: snapshot.accountID, syncedAt: snapshot.syncedAt, books: books,
            followsWorklist: worklist != nil, cloudUserRecordName: "local")
    }

    func currentDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1? {
        let name = CloudContract.designRecordName(accountID: accountID, bookID: bookID)
        guard let design = try designs()[name], (try? design.validate()) != nil,
            design.accountID == accountID, design.bookID == bookID,
            design.generatorVersion == CloudContract.generatorVersion
        else { return nil }
        return design
    }

    func isStillCurrent(_ context: WorkContext, bookID: Int) async throws -> Bool {
        guard let work = try await loadWork() else { return false }
        return work.accountID == context.accountID
            && abs(work.syncedAt.timeIntervalSince(context.syncedAt)) < 0.001
            && work.books.contains { $0.id == bookID }
    }

    func save(_ design: SpineDesignV1) async throws {
        try design.validate()
        // Simulator runs exercise the real generator against a local folder; keep the newest.
        var all = try designs()
        all[CloudContract.designRecordName(accountID: design.accountID, bookID: design.bookID)] =
            design
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(all).write(
            to: folder.appending(path: "spine-designs-v1.json"), options: .atomic)
    }

    func loadLibrary() async throws -> LibrarySnapshot? {
        guard let archive = try decode(CloudLibraryArchive.self, "library-v1.json") else {
            return nil
        }
        let worklist = try? decode(SpineWorklistV1.self, "spine-worklist-v1.json")
        let (snapshot, books) =
            try (try? archive.workSource(for: worklist)) ?? archive.workSource(for: nil)
        return LibrarySnapshot(
            accountID: snapshot.accountID, syncedAt: snapshot.syncedAt, books: books,
            designs: LibrarySnapshot.latestDesigns(
                try designs().values, accountID: snapshot.accountID, books: books))
    }

    func installWorklistSubscription() async throws {}

    private func designs() throws -> [String: SpineDesignV1] {
        try decode([String: SpineDesignV1].self, "spine-designs-v1.json") ?? [:]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let url = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
