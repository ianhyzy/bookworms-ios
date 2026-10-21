import Foundation

/// Where the companion reads the library and saves spine designs.
///
/// `CloudSpineStore` is the private iCloud database that the reader's Apple devices share,
/// combined with this device's own Hardcover library when it is signed in (see `WorkSource`).
/// `LocalSpineStore` reads a folder of the same JSON for Simulator previews and tests, so no
/// iCloud account is needed; it ignores the Hardcover sign-in.
///
/// Both stores set each book's `chosenCoverURL` and `seriesLink` from the reader's
/// `CoverChoiceV1` and `SeriesLinkV1` records when they load work or the library.
protocol SpineStore: Sendable {
    /// Returns the books to design, or `nil` when there is no work.
    func loadWork() async throws -> WorkContext?
    /// Returns the book's saved design when it is valid, from any generator.
    func savedDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1?
    /// Returns whether `book` still belongs to the work in `context` with the same chosen cover,
    /// so a stale result is not saved after the Apple TV changed accounts or removed the book, or
    /// the reader picked another cover.
    func isStillCurrent(_ context: WorkContext, book: CloudBook) async throws -> Bool
    /// Saves `design` unless the saved design outlasts it (`SpineDesignV1.outlasts(_:replacing:)`),
    /// such as one that another device's run saved first at the same tier or a better one.
    func save(_ design: SpineDesignV1, replacing: Bool) async throws
    /// Saves `design`'s colors to the saved design that it recolors (see
    /// `SpineDesignV1.isSameDesign(as:)`), keeping the saved font and every other field. Throws
    /// `CompanionError.designChanged` when the saved design is another one.
    func saveRecolored(_ design: SpineDesignV1) async throws
    /// Saves the reader's cover for a book, replacing an earlier choice.
    func save(_ choice: CoverChoiceV1) async throws
    /// Deletes the reader's cover choice for a book, which restores its default cover.
    func deleteCoverChoice(accountID: String, bookID: Int) async throws
    /// Saves the reader's series choice for a book, replacing an earlier choice.
    func save(_ link: SeriesLinkV1) async throws
    /// Deletes the reader's series choice for a book, which restores its default series.
    func deleteSeriesLink(accountID: String, bookID: Int) async throws
    /// Returns the valid saved looks of the look groups `keys`.
    func seriesLooks(accountID: String, keys: Set<SeriesLookKey>) async throws -> [SeriesLookKey:
        SeriesLookV1]
    /// Saves `look` only when its group has no look yet, and returns the look the group keeps:
    /// `look`, or the look another device saved first. Throws `CompanionError.invalidCloudData`
    /// when the group's saved look is not valid.
    func createLook(_ look: SeriesLookV1) async throws -> SeriesLookV1
    /// Saves `look`, made from a design that outranks the group's saved look, over that look
    /// while `look` still upgrades it (`SeriesLookV1.isUpgraded(at:awaitingFont:)`), and returns
    /// the look the group keeps: `look`, or the saved look when the reader edited it or another
    /// device saved one that `look` doesn't outrank first. Creates the look when the group has
    /// none.
    func upgradeLook(_ look: SeriesLookV1) async throws -> SeriesLookV1
    /// Saves `look` over its group's look, such as after a requested redesign remakes it.
    func save(_ look: SeriesLookV1) async throws
    /// Saves `look`'s colors and edit date over the saved look that it recolors (see
    /// `SeriesLookV1.isSameLook(as:)`). Throws `CompanionError.designChanged` when the group's
    /// saved look is missing or another one, such as a look another device remade.
    func saveRecolored(_ look: SeriesLookV1) async throws
    /// Returns the active account's books, every valid saved design, and the saved looks of the
    /// books' look groups, or `nil` before there is a library.
    func loadLibrary() async throws -> LibrarySnapshot?
    /// Subscribes to worklist changes so a silent push can schedule generation.
    func installWorklistSubscription() async throws
    /// Returns the newest Hardcover snapshot of `accountID` in the shared `library-v1` archive,
    /// or `nil` when the archive holds none.
    func archivedLibrary(accountID: String) async throws -> CloudSourceSnapshot?
    /// Writes `library` into the shared `library-v1` archive as its account's Hardcover snapshot
    /// when it is newer than the stored one (`CloudLibraryArchive.splice(_:into:)`), so other
    /// devices can show it without downloading it from Hardcover.
    func publishLibrary(_ library: PhoneLibrary) async throws
}

extension SpineStore {
    /// Saves `design` unless the saved design outlasts it (`SpineDesignV1.outlasts(_:replacing:)`):
    /// one from the same tier or a better one, from any generator, unless `design` moves it to a
    /// new work-item hash, or one with the reader's colors.
    func save(_ design: SpineDesignV1) async throws {
        try await save(design, replacing: false)
    }
}

/// Where a generation run finds its account and books.
enum WorkSource: Equatable {
    /// The Apple TV's worklist chose the account and books from its archive.
    case worklist
    /// This device's own Hardcover library.
    case phone(PhoneLibrary)
    /// The newest Hardcover snapshot in the archive.
    case archive
    /// Nothing to design: the Apple TV paused generation and this device is signed out, or
    /// this device is signed in but has no copy of the account's library.
    case none

    /// Signed in with its own copy of the account's library (`phone`, when it belongs to
    /// `signedInAccountID`), a device designs that copy unless a worklist lists books of another
    /// account or of a newer copy. A worklist of the same account and copy or an older one
    /// doesn't decide: fixed covers make the copy's books hash as the Apple TV's do
    /// (`CloudContract.workItemHash(accountID:book:)`). Otherwise a worklist that lists books
    /// decides, so books that the Apple TV's newer copy adds get designs before this device
    /// adopts that copy. Without one, a signed-in device without its copy designs nothing,
    /// since the archive may belong to another account, and a signed-out device uses the
    /// archive unless an empty worklist says the Apple TV turned Hardcover off.
    init(worklist: SpineWorklistV1?, signedInAccountID: String?, phone: PhoneLibrary?) {
        let listing = worklist.flatMap { $0.bookIDs.isEmpty ? nil : $0 }
        // Dates match within a millisecond, as the archive matches a worklist to its snapshot.
        if let phone, phone.accountID == signedInAccountID,
            listing.map({
                $0.accountID == phone.accountID
                    && $0.syncedAt.timeIntervalSince(phone.syncedAt) < 0.001
            }) ?? true
        {
            self = .phone(phone)
        } else if listing != nil {
            self = .worklist
        } else if signedInAccountID != nil {
            self = .none
        } else {
            self = worklist == nil ? .archive : .none
        }
    }
}

/// Reads and writes the iCloud JSON shapes in a local folder.
///
/// The folder holds `library-v1.json` (the archive), an optional `spine-worklist-v1.json`,
/// `spine-designs-v1.json` (`[recordName: SpineDesignV1]`, the Apple TV cache shape),
/// `cover-choices-v1.json` (`[recordName: CoverChoiceV1]`), `series-links-v1.json`
/// (`[recordName: SeriesLinkV1]`), and `series-looks-v1.json` (`[recordName: SeriesLookV1]`).
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
            books: try applyingChoices(accountID: snapshot.accountID, to: books),
            followsWorklist: worklist != nil, cloudUserRecordName: "local")
    }

    func savedDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1? {
        let name = CloudContract.designRecordName(accountID: accountID, bookID: bookID)
        guard let design = try designs()[name], (try? design.validate()) != nil,
            design.accountID == accountID, design.bookID == bookID
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

    func save(_ design: SpineDesignV1, replacing: Bool) async throws {
        try design.validate()
        // Simulator runs exercise the real generator against a local folder; keep the newest.
        var all = try designs()
        all[CloudContract.designRecordName(accountID: design.accountID, bookID: design.bookID)] =
            design
        try write(all, "spine-designs-v1.json")
    }

    func saveRecolored(_ design: SpineDesignV1) async throws {
        try design.validate()
        guard let colors = design.colors else { throw CompanionError.invalidDesign }
        let name = CloudContract.designRecordName(
            accountID: design.accountID, bookID: design.bookID)
        var all = try designs()
        guard let saved = all[name], saved.isSameDesign(as: design) else {
            throw CompanionError.designChanged
        }
        // Keeps the saved font, as `CloudSpineStore` does.
        all[name] = saved.recolored(colors)
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

    func save(_ link: SeriesLinkV1) async throws {
        try link.validate()
        var all = try seriesLinks()
        all[CloudContract.seriesLinkRecordName(accountID: link.accountID, bookID: link.bookID)] =
            link
        try write(all, "series-links-v1.json")
    }

    func deleteSeriesLink(accountID: String, bookID: Int) async throws {
        var all = try seriesLinks()
        all[CloudContract.seriesLinkRecordName(accountID: accountID, bookID: bookID)] = nil
        try write(all, "series-links-v1.json")
    }

    func seriesLooks(accountID: String, keys: Set<SeriesLookKey>) async throws -> [SeriesLookKey:
        SeriesLookV1]
    {
        SeriesLookV1.keyed(try looks(), accountID: accountID).filter { keys.contains($0.key) }
    }

    func createLook(_ look: SeriesLookV1) async throws -> SeriesLookV1 {
        try look.validate()
        var all = try looks()
        let name = CloudContract.seriesLookRecordName(accountID: look.accountID, key: look.key)
        if all[name] != nil {
            guard
                let existing = SeriesLookV1.keyed(all, accountID: look.accountID)[look.key]
            else { throw CompanionError.invalidCloudData }
            return existing
        }
        all[name] = look
        try write(all, "series-looks-v1.json")
        return look
    }

    func upgradeLook(_ look: SeriesLookV1) async throws -> SeriesLookV1 {
        try look.validate()
        var all = try looks()
        let name = CloudContract.seriesLookRecordName(accountID: look.accountID, key: look.key)
        if let saved = SeriesLookV1.keyed(all, accountID: look.accountID)[look.key],
            !saved.isUpgraded(at: look.tier, awaitingFont: look.awaitsFont)
        {
            return saved
        }
        all[name] = look
        try write(all, "series-looks-v1.json")
        return look
    }

    func save(_ look: SeriesLookV1) async throws {
        try look.validate()
        var all = try looks()
        all[CloudContract.seriesLookRecordName(accountID: look.accountID, key: look.key)] = look
        try write(all, "series-looks-v1.json")
    }

    func saveRecolored(_ look: SeriesLookV1) async throws {
        try look.validate()
        var all = try looks()
        let name = CloudContract.seriesLookRecordName(accountID: look.accountID, key: look.key)
        guard let saved = all[name], saved.isSameLook(as: look) else {
            throw CompanionError.designChanged
        }
        all[name] = look
        try write(all, "series-looks-v1.json")
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
        let chosen = try applyingChoices(accountID: snapshot.accountID, to: books)
        return LibrarySnapshot(
            accountID: snapshot.accountID, syncedAt: snapshot.syncedAt, books: chosen,
            designs: LibrarySnapshot.latestDesigns(
                try designs().values, accountID: snapshot.accountID, books: books),
            looks: SeriesLookV1.keyed(try looks(), accountID: snapshot.accountID),
            series: snapshot.series)
    }

    func installWorklistSubscription() async throws {}

    func archivedLibrary(accountID: String) async throws -> CloudSourceSnapshot? {
        try decode(CloudLibraryArchive.self, "library-v1.json")?
            .newestHardcoverSnapshot(accountID: accountID)
    }

    func publishLibrary(_ library: PhoneLibrary) async throws {
        let url = folder.appending(path: "library-v1.json")
        let stored =
            FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard
            let archive = try CloudLibraryArchive.splice(
                CloudSourceSnapshot(library), into: stored)
        else { return }
        try archive.write(to: url, options: .atomic)
    }

    /// Returns `books` with the reader's chosen covers and series links.
    private func applyingChoices(accountID: String, to books: [CloudBook]) throws -> [CloudBook] {
        SeriesLinkV1.apply(
            try seriesLinks(), accountID: accountID,
            to: CoverChoiceV1.apply(try coverChoices(), accountID: accountID, to: books))
    }

    private func designs() throws -> [String: SpineDesignV1] {
        try decode([String: SpineDesignV1].self, "spine-designs-v1.json") ?? [:]
    }

    private func coverChoices() throws -> [String: CoverChoiceV1] {
        try decode([String: CoverChoiceV1].self, "cover-choices-v1.json") ?? [:]
    }

    private func seriesLinks() throws -> [String: SeriesLinkV1] {
        try decode([String: SeriesLinkV1].self, "series-links-v1.json") ?? [:]
    }

    private func looks() throws -> [String: SeriesLookV1] {
        try decode([String: SeriesLookV1].self, "series-looks-v1.json") ?? [:]
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
