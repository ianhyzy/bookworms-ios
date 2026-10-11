import Foundation

/// Where the companion reads the library and saves spine designs.
///
/// `CloudSpineStore` is the private iCloud database the Apple TV shares, combined with this
/// iPhone's own Hardcover library when it is signed in (see `WorkSource`). `LocalSpineStore`
/// reads a folder of the same JSON for Simulator previews and tests, so no iCloud account is
/// needed; it ignores the Hardcover sign-in.
///
/// Both stores set each book's `chosenCoverURL` from the reader's `CoverChoiceV1` records when
/// they load work or the library.
protocol SpineStore: Sendable {
    /// Returns the books to design, or `nil` when there is no work.
    func loadWork() async throws -> WorkContext?
    /// Returns the book's saved design when it is valid and made by this app's generator.
    func currentDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1?
    /// Returns whether `book` still belongs to the work in `context` with the same chosen cover,
    /// so a stale result is not saved after the Apple TV changed accounts or removed the book, or
    /// the reader picked another cover.
    func isStillCurrent(_ context: WorkContext, book: CloudBook) async throws -> Bool
    /// Saves `design` unless an equal or newer design for the same work already exists.
    func save(_ design: SpineDesignV1) async throws
    /// Saves the reader's cover for a book, replacing an earlier choice.
    func save(_ choice: CoverChoiceV1) async throws
    /// Deletes the reader's cover choice for a book, which restores its default cover.
    func deleteCoverChoice(accountID: String, bookID: Int) async throws
    /// Returns the active account's books and every valid saved design, or `nil` before there
    /// is a library.
    func loadLibrary() async throws -> LibrarySnapshot?
    /// Subscribes to worklist changes so a silent push can schedule generation.
    func installWorklistSubscription() async throws
}

/// Where a generation run finds its account and books.
enum WorkSource: Equatable {
    /// The Apple TV's worklist chose the account and books from its archive.
    case worklist
    /// This iPhone's own Hardcover library.
    case phone(PhoneLibrary)
    /// The newest Hardcover snapshot in the Apple TV archive.
    case archive
    /// Nothing to design: the Apple TV paused generation and this iPhone is signed out, or
    /// this iPhone is signed in but has no copy of the account's library.
    case none

    /// A worklist that lists books decides. Without one, a signed-in iPhone designs only its
    /// own library (`phone`, when it belongs to `signedInAccountID`): the archive may belong to
    /// another account, so it never stands in, even before the first download. Signed out, the
    /// archive is used unless an empty worklist says the Apple TV turned Hardcover off.
    init(worklist: SpineWorklistV1?, signedInAccountID: String?, phone: PhoneLibrary?) {
        if let worklist, !worklist.bookIDs.isEmpty {
            self = .worklist
        } else if let signedInAccountID {
            if let phone, phone.accountID == signedInAccountID {
                self = .phone(phone)
            } else {
                self = .none
            }
        } else {
            self = worklist == nil ? .archive : .none
        }
    }
}

/// Reads and writes the iCloud JSON shapes in a local folder.
///
/// The folder holds `library-v1.json` (the archive), an optional `spine-worklist-v1.json`,
/// `spine-designs-v1.json` (`[recordName: SpineDesignV1]`, the Apple TV cache shape), and
/// `cover-choices-v1.json` (`[recordName: CoverChoiceV1]`).
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
            accountID: snapshot.accountID, syncedAt: snapshot.syncedAt,
            books: CoverChoiceV1.apply(
                try coverChoices(), accountID: snapshot.accountID, to: books),
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

    func isStillCurrent(_ context: WorkContext, book: CloudBook) async throws -> Bool {
        guard let work = try await loadWork(),
            let current = work.books.first(where: { $0.id == book.id })
        else { return false }
        return work.accountID == context.accountID
            && abs(work.syncedAt.timeIntervalSince(context.syncedAt)) < 0.001
            && current.chosenCoverURL == book.chosenCoverURL
    }

    func save(_ design: SpineDesignV1) async throws {
        try design.validate()
        // Simulator runs exercise the real generator against a local folder; keep the newest.
        var all = try designs()
        all[CloudContract.designRecordName(accountID: design.accountID, bookID: design.bookID)] =
            design
        try write(all, "spine-designs-v1.json")
    }

    func save(_ choice: CoverChoiceV1) async throws {
        try choice.validate()
        var all = try coverChoices()
        all[
            CloudContract.coverChoiceRecordName(accountID: choice.accountID, bookID: choice.bookID)] =
            choice
        try write(all, "cover-choices-v1.json")
    }

    func deleteCoverChoice(accountID: String, bookID: Int) async throws {
        var all = try coverChoices()
        all[CloudContract.coverChoiceRecordName(accountID: accountID, bookID: bookID)] = nil
        try write(all, "cover-choices-v1.json")
    }

    func loadLibrary() async throws -> LibrarySnapshot? {
        guard let archive = try decode(CloudLibraryArchive.self, "library-v1.json") else {
            return nil
        }
        // An empty worklist pauses generation only; the library still shows every book.
        let shown = (try? decode(SpineWorklistV1.self, "spine-worklist-v1.json"))
            .flatMap { $0.bookIDs.isEmpty ? nil : $0 }
        let (snapshot, books) =
            try (try? archive.workSource(for: shown)) ?? archive.workSource(for: nil)
        return LibrarySnapshot(
            accountID: snapshot.accountID, syncedAt: snapshot.syncedAt,
            books: CoverChoiceV1.apply(
                try coverChoices(), accountID: snapshot.accountID, to: books),
            designs: LibrarySnapshot.latestDesigns(
                try designs().values, accountID: snapshot.accountID, books: books))
    }

    func installWorklistSubscription() async throws {}

    private func designs() throws -> [String: SpineDesignV1] {
        try decode([String: SpineDesignV1].self, "spine-designs-v1.json") ?? [:]
    }

    private func coverChoices() throws -> [String: CoverChoiceV1] {
        try decode([String: CoverChoiceV1].self, "cover-choices-v1.json") ?? [:]
    }

    private func write(_ value: some Encodable, _ name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(value).write(to: folder.appending(path: name), options: .atomic)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let url = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
