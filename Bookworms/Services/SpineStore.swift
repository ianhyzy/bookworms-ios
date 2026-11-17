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
    /// Returns the book's saved design when it is valid, from any generator. Throws
    /// `CompanionError.unsupportedCloudData` for a design of another contract version, such as a
    /// newer build's.
    func savedDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1?
    /// Returns whether `book` still belongs to the work in `context` with the same chosen cover
    /// and series choice, so a stale result is not saved, and seeds no series look, after the
    /// Apple TV changed accounts or removed the book, or the reader picked another cover or
    /// series choice.
    func isStillCurrent(_ context: WorkContext, book: CloudBook) async throws -> Bool
    /// Claims the book for this device before a model request for its design, and returns
    /// `false` when another of the reader's devices holds an unexpired claim (`SpineClaimV1`),
    /// so the caller leaves the book to it. Any doubt returns `true`, such as an unreachable
    /// iCloud: a second request for one book costs less than a book no device designs.
    func claimDesign(accountID: String, bookID: Int) async -> Bool
    /// Saves `design` unless the saved design outlasts it (`SpineDesignV1.outlasts(_:replacing:)`),
    /// such as one that another device's run saved first at the same tier, or from a capable
    /// model, and returns the design the book keeps: `design`, or the saved design. A saved
    /// design of another contract version throws `CompanionError.unsupportedCloudData`, even
    /// with `replacing`.
    ///
    /// With `base`, the book's saved design as the caller read it, a saved design that is no
    /// longer `base` also stays, such as `base` with colors or a font the reader chose since the
    /// read. A series copy's refresh saves this way, because it may wait for a font download
    /// after its read.
    @discardableResult func save(
        _ design: SpineDesignV1, replacing: Bool, ifUnchangedFrom base: SpineDesignV1?
    ) async throws -> SpineDesignV1
    /// Saves `design`'s colors, the reader's choice, to the book's saved design, keeping the
    /// saved font and every other field, even when another device redesigned the book or changed
    /// its font meanwhile. Throws `CompanionError.designChanged` when the book has no saved
    /// design.
    func saveRecolored(_ design: SpineDesignV1) async throws
    /// Saves `design`'s font, the reader's choice, to the saved design that it sets in that font
    /// (see `SpineDesignV1.refonted(family:postScriptName:instanceWeight:typeface:)`), keeping the
    /// saved colors and every other field, as `saveRecolored(_:)` does. Throws
    /// `CompanionError.designChanged` when the book has no saved design.
    func saveRefonted(_ design: SpineDesignV1) async throws
    /// Saves the reader's cover for a book, replacing an earlier choice.
    func save(_ choice: CoverChoiceV1) async throws
    /// Deletes the reader's cover choice for a book, which restores its default cover.
    func deleteCoverChoice(accountID: String, bookID: Int) async throws
    /// Saves the reader's series choice `link` for a book, the reader's change of `base`, the
    /// book's link as this device showed it, over the saved link: only the choices that differ
    /// from `base` replace the saved ones (`SeriesLinkV1.merged(over:changing:)`), so a choice
    /// another device saved meanwhile stays. Returns the book's link, or `nil` when it changes
    /// nothing (`SeriesLinkV1.changesNothing`), which deletes the record and restores the
    /// book's default series. A CloudKit delete doesn't check the record's change tag, so a
    /// choice that another device saves between the fetch and the delete is lost.
    func save(_ link: SeriesLinkV1, replacing base: SeriesLinkV1?) async throws -> SeriesLinkV1?
    /// Returns the account's valid saved Top Five pins, or `nil` when it has none.
    func topFivePins(accountID: String) async throws -> TopFivePinsV1?
    /// Saves the reader's Top Five pins `pins`, the reader's change of `base`, the pins as this
    /// device last synced them, over the saved pins: only the pins added or removed since `base`
    /// change the saved ones (`TopFivePinsV1.merged(over:changing:)`), so a pin another device
    /// saved meanwhile stays. Returns the pins the account keeps.
    func save(_ pins: TopFivePinsV1, replacing base: TopFivePinsV1?) async throws -> TopFivePinsV1
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
    /// none. Throws `CompanionError.unsupportedCloudData` when the group's saved look is of
    /// another contract version.
    func upgradeLook(_ look: SeriesLookV1) async throws -> SeriesLookV1
    /// Saves `look` over its group's look, such as after a requested redesign remakes it.
    /// Throws `CompanionError.unsupportedCloudData` when the group's saved look is of another
    /// contract version.
    func save(_ look: SeriesLookV1) async throws
    /// Saves `look`, such as an upgrade of a look made from a stand-in, over its group's saved
    /// look while that is still `base`. Throws `CompanionError.designChanged` when the group's
    /// saved look is missing or another one, such as a look another device remade or the reader
    /// edited.
    func saveEdited(_ look: SeriesLookV1, replacing base: SeriesLookV1) async throws
    /// Applies the reader's `edit`, made at `date`, to the look that `look`'s group has saved
    /// now, whatever another device changed in it, and saves the result, so only the edited
    /// colors or font change. Throws `CompanionError.designChanged` when the group has no saved
    /// look, and `CompanionError.invalidDesign` when the edited look is not valid.
    func saveReaderEdit(_ edit: SeriesLookEdit, at date: Date, to look: SeriesLookV1) async throws
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
    /// Checks whether iCloud holds data from Hardcover accounts other than this device's, and
    /// lets the store use iCloud only when it holds none (`CloudLibraryArchive.check`).
    func checkAccounts() async throws -> CloudAccountCheck
    /// Copies `oldAccountID`'s records for `books` to `accountID`, never replacing a record
    /// `accountID` has, for **Merge**.
    func copyRecords(from oldAccountID: String, into accountID: String, books: [CloudBook])
        async throws
    /// Records in iCloud that each account in `merges` merged into the account it maps to.
    func recordMerges(_ merges: [String: String]) async throws
}

extension SpineStore {
    /// A store that only this device writes has no other device to claim a book.
    func claimDesign(accountID: String, bookID: Int) async -> Bool { true }

    /// Saves `design` unless the saved design outlasts it
    /// (`save(_:replacing:ifUnchangedFrom:)`).
    @discardableResult func save(_ design: SpineDesignV1, replacing: Bool) async throws
        -> SpineDesignV1
    {
        try await save(design, replacing: replacing, ifUnchangedFrom: nil)
    }

    /// Saves `design` unless the saved design outlasts it (`SpineDesignV1.outlasts(_:replacing:)`):
    /// one that `design` doesn't outrank, from any generator, unless `design` moves it to a new
    /// work-item hash, or one with the reader's colors. Returns the design the book keeps.
    @discardableResult func save(_ design: SpineDesignV1) async throws -> SpineDesignV1 {
        try await save(design, replacing: false)
    }

    /// **Merge**: copies the records of each account in `others` to `library`'s account for the
    /// books they share, newest account first, so the newest wins a shared book, then records
    /// the merges, then publishes `library` when the archive has none of its account
    /// (`publishIfMissing(_:)`).
    ///
    /// The merges are recorded only after every copy succeeds, so no device treats an account as
    /// merged while its copy is incomplete; a repeat is safe because copies never replace a
    /// record. A failed publish doesn't fail the merge, and the next download publishes again.
    func merge(_ others: [CloudAccount], into library: PhoneLibrary) async throws {
        for other in others.sorted(by: { $0.syncedAt > $1.syncedAt }) {
            try await copyRecords(
                from: other.id, into: library.accountID,
                books: library.books.filter { other.bookIDs.contains($0.id) })
        }
        try await recordMerges(
            Dictionary(uniqueKeysWithValues: others.map { ($0.id, library.accountID) }))
        do { try await publishIfMissing(library) } catch {
            HardcoverAccount.logDropped("Couldn't publish the library after a merge", error)
        }
    }

    /// Publishes `library` when the archive holds no snapshot of its account, such as after a
    /// download whose upload the closed account check dropped. It never replaces a snapshot,
    /// whose cover picks another device may have made.
    func publishIfMissing(_ library: PhoneLibrary) async throws {
        if try await archivedLibrary(accountID: library.accountID) == nil {
            try await publishLibrary(library)
        }
    }
}

/// Where a generation run finds its account and books.
enum WorkSource: Equatable {
    /// The Apple TV's worklist chose the account and books from its archive, unless a newer
    /// snapshot of the account replaced the one it lists
    /// (`CloudLibraryArchive.workSource(for:accountID:)`).
    case worklist
    /// This device's own Hardcover library.
    case phone(PhoneLibrary)
    /// The newest Hardcover snapshot in the archive.
    case archive
    /// Nothing to design: the Apple TV paused generation and this device is signed out, or
    /// this device is signed in but has no copy of the account's library.
    case none

    /// Signed in, a device designs only its account's books: the books a worklist of that
    /// account lists when the worklist is newer than this device's copy of the library (`phone`,
    /// when it belongs to `signedInAccountID`), or when the device has no copy, so books that
    /// the Apple TV's newer copy adds get designs before this device adopts that copy; otherwise
    /// its copy. A worklist no newer than the copy doesn't decide: fixed covers make the copy's
    /// books hash as the Apple TV's do (`CloudContract.workItemHash(accountID:book:)`). Without
    /// either, it designs nothing. Signed out, the caller passes only a worklist of the account
    /// whose library the device shows; a worklist that lists books decides, and without one the
    /// device uses the archive, unless an empty worklist says the Apple TV turned Hardcover off.
    init(worklist: SpineWorklistV1?, signedInAccountID: String?, phone: PhoneLibrary?) {
        let listing = worklist.flatMap { $0.bookIDs.isEmpty ? nil : $0 }
        guard let signedInAccountID else {
            self = listing != nil ? .worklist : worklist == nil ? .archive : .none
            return
        }
        let copy = phone?.accountID == signedInAccountID ? phone : nil
        if let listing, listing.accountID == signedInAccountID,
            copy.map({ CloudContract.isNewerSync(listing.syncedAt, than: $0.syncedAt) }) ?? true
        {
            self = .worklist
        } else if let copy {
            self = .phone(copy)
        } else {
            self = .none
        }
    }
}

/// Reads and writes the iCloud JSON shapes in a local folder.
///
/// The folder holds `library-v1.json` (the archive), an optional `spine-worklist-v1.json`,
/// `spine-designs-v1.json` (`[recordName: SpineDesignV1]`, the Apple TV cache shape),
/// `cover-choices-v1.json` (`[recordName: CoverChoiceV1]`), `series-links-v1.json`
/// (`[recordName: SeriesLinkV1]`), `series-looks-v1.json` (`[recordName: SeriesLookV1]`), and
/// `top-five-pins-v1.json` (`[recordName: TopFivePinsV1]`).
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
        let (snapshot, books, followsWorklist) = try archive.workSource(
            for: worklist, accountID: nil)
        return WorkContext(
            accountID: snapshot.accountID, syncedAt: snapshot.syncedAt,
            books: try applyingChoices(accountID: snapshot.accountID, to: books),
            followsWorklist: followsWorklist, cloudUserRecordName: "local")
    }

    func savedDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1? {
        let name = CloudContract.designRecordName(accountID: accountID, bookID: bookID)
        guard let design = try designs()[name] else { return nil }
        guard design.version == 1 else { throw CompanionError.unsupportedCloudData }
        guard (try? design.validate()) != nil, design.accountID == accountID,
            design.bookID == bookID
        else { return nil }
        return design
    }

    func isStillCurrent(_ context: WorkContext, book: CloudBook) async throws -> Bool {
        guard let work = try await loadWork(),
            let current = work.books.first(where: { $0.id == book.id })
        else { return false }
        return work.accountID == context.accountID
            && CloudContract.isSameSync(work.syncedAt, context.syncedAt)
            && current.chosenCoverURL == book.chosenCoverURL
            && current.seriesLink == book.seriesLink
    }

    @discardableResult func save(
        _ design: SpineDesignV1, replacing: Bool, ifUnchangedFrom base: SpineDesignV1?
    ) async throws -> SpineDesignV1 {
        try design.validate()
        var all = try designs()
        let name = CloudContract.designRecordName(
            accountID: design.accountID, bookID: design.bookID)
        if let saved = all[name] {
            if saved.version != 1 { throw CompanionError.unsupportedCloudData }
            if base.map({ saved != $0 }) == true { return saved }
            if (try? saved.validate()) != nil, saved.outlasts(design, replacing: replacing) {
                return saved
            }
        }
        all[name] = design
        try write(all, "spine-designs-v1.json")
        return design
    }

    func saveRecolored(_ design: SpineDesignV1) async throws {
        try design.validate()
        guard let colors = design.colors else { throw CompanionError.invalidDesign }
        let name = CloudContract.designRecordName(
            accountID: design.accountID, bookID: design.bookID)
        var all = try designs()
        guard let saved = all[name] else {
            throw CompanionError.designChanged
        }
        // Keeps the saved font, as `CloudSpineStore` does.
        let recolored = saved.recolored(colors)
        try recolored.validate()
        all[name] = recolored
        try write(all, "spine-designs-v1.json")
    }

    func saveRefonted(_ design: SpineDesignV1) async throws {
        try design.validate()
        guard let family = design.fontFamily else { throw CompanionError.invalidDesign }
        let name = CloudContract.designRecordName(
            accountID: design.accountID, bookID: design.bookID)
        var all = try designs()
        guard let saved = all[name] else {
            throw CompanionError.designChanged
        }
        // Keeps the saved colors, as `CloudSpineStore` does.
        let refonted = saved.refonted(
            family: family, postScriptName: design.fontPostScriptName,
            instanceWeight: design.instanceWeight, typeface: design.typeface)
        try refonted.validate()
        all[name] = refonted
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

    func save(_ link: SeriesLinkV1, replacing base: SeriesLinkV1?) async throws -> SeriesLinkV1? {
        try link.validate()
        var all = try seriesLinks()
        let name = CloudContract.seriesLinkRecordName(
            accountID: link.accountID, bookID: link.bookID)
        let merged = link.merged(over: all[name], changing: base)
        all[name] = merged.changesNothing ? nil : merged
        try write(all, "series-links-v1.json")
        return all[name]
    }

    func topFivePins(accountID: String) async throws -> TopFivePinsV1? {
        let name = CloudContract.topFivePinsRecordName(accountID: accountID)
        return try allTopFivePins()[name]?.checked(recordName: name)
    }

    func save(_ pins: TopFivePinsV1, replacing base: TopFivePinsV1?) async throws -> TopFivePinsV1 {
        try pins.validate()
        var all = try allTopFivePins()
        let name = CloudContract.topFivePinsRecordName(accountID: pins.accountID)
        let merged = pins.merged(over: all[name], changing: base)
        all[name] = merged
        try write(all, "top-five-pins-v1.json")
        return merged
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
        if let stored = all[name], stored.version != 1 {
            throw CompanionError.unsupportedCloudData
        }
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
        let name = CloudContract.seriesLookRecordName(accountID: look.accountID, key: look.key)
        if let stored = all[name], stored.version != 1 {
            throw CompanionError.unsupportedCloudData
        }
        all[name] = look
        try write(all, "series-looks-v1.json")
    }

    func saveEdited(_ look: SeriesLookV1, replacing base: SeriesLookV1) async throws {
        try look.validate()
        var all = try looks()
        let name = CloudContract.seriesLookRecordName(accountID: look.accountID, key: look.key)
        guard let saved = all[name], saved == base || saved == look else {
            throw CompanionError.designChanged
        }
        all[name] = look
        try write(all, "series-looks-v1.json")
    }

    func saveReaderEdit(_ edit: SeriesLookEdit, at date: Date, to look: SeriesLookV1) async throws {
        var all = try looks()
        let name = CloudContract.seriesLookRecordName(accountID: look.accountID, key: look.key)
        guard let saved = all[name] else { throw CompanionError.designChanged }
        let edited = edit.applied(to: saved, at: date)
        try edited.validate()
        all[name] = edited
        try write(all, "series-looks-v1.json")
    }

    func loadLibrary() async throws -> LibrarySnapshot? {
        guard let archive = try decode(CloudLibraryArchive.self, "library-v1.json") else {
            return nil
        }
        let worklist = try decode(SpineWorklistV1.self, "spine-worklist-v1.json")
        try worklist?.validate()
        // An empty worklist pauses generation only; the library still shows every book.
        let shown = worklist.flatMap { $0.bookIDs.isEmpty ? nil : $0 }
        let (snapshot, books, _) =
            try (try? archive.workSource(for: shown, accountID: nil))
            ?? archive.workSource(for: nil, accountID: nil)
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

    /// A preview folder belongs to one reader, so iCloud is always clear.
    func checkAccounts() async throws -> CloudAccountCheck { .clear(accountID: nil) }

    func copyRecords(from oldAccountID: String, into accountID: String, books: [CloudBook])
        async throws
    {}

    func recordMerges(_ merges: [String: String]) async throws {}

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

    private func allTopFivePins() throws -> [String: TopFivePinsV1] {
        try decode([String: TopFivePinsV1].self, "top-five-pins-v1.json") ?? [:]
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
