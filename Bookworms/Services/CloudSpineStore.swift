import CloudKit
import Foundation

#if os(macOS)
    import Security
#endif

/// Reads the shared `library-v1` archive, or this device's own Hardcover library when it is
/// signed in, and publishes one portable design per Hardcover book in the private database of the
/// shared iCloud container. It also writes this device's Hardcover library into the archive, so
/// other devices can show it without downloading it. The reader's cover choices, series links,
/// and Top Five pins, and the series looks, live in the same database.
///
/// The store reads and writes nothing in iCloud until `checkAccounts()` clears it for one
/// Hardcover account, so a device never mixes iCloud data from two accounts without the
/// reader's **Merge**.
actor CloudSpineStore: SpineStore {
    private lazy var container = CKContainer(identifier: CloudContract.containerID)
    private let suppliedDatabase: (any SpineCloudDatabase)?
    /// The user defaults suite of a test, or `nil` for `HardcoverAccount.summaryDefaults`.
    private let defaultsSuite: String?
    /// Holds the sign-in summary and the reader's iCloud choices (`CloudStorage`).
    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? HardcoverAccount.summaryDefaults
    }
    /// The last check's result: the account it cleared, `nil` when iCloud holds no library yet,
    /// or the error every record call throws until a check clears one. Closed at launch.
    private var gate: Result<String?, CompanionError> = .failure(.iCloudUnavailable)
    /// The records' database while the gate is open for the signed-in account, or for any
    /// account when signed out; otherwise a database that throws the gate's error. Every record
    /// read and write goes through it, except the check and **Merge** (`ungatedDatabase`).
    private var database: any SpineCloudDatabase {
        switch gate {
        case .success(let accountID) where signedInAccountID.map({ $0 == accountID }) ?? true:
            ungatedDatabase
        case .success: PausedSpineDatabase(error: .iCloudUnavailable)
        case .failure(let error): PausedSpineDatabase(error: error)
        }
    }
    /// The container's private database, or a test's stand-in.
    private var ungatedDatabase: any SpineCloudDatabase {
        suppliedDatabase ?? PrivateSpineDatabase(database: container.privateCloudDatabase)
    }
    /// The account that the gate is open for, or `nil` while it is closed or no library exists.
    private var clearedAccountID: String? { (try? gate.get()) ?? nil }
    private var signedInAccountID: String? { HardcoverAccount.signedInAccountID(in: defaults) }
    /// The last save of the reader's colors or font, which the next one waits for. The actor
    /// admits another save while one waits on CloudKit, so without this a retried older save
    /// could land after a newer one.
    private var recolorTail: Task<Void, Never>?
    /// The account and sync date of the phone library that the last `loadWork` returned, so a
    /// run that designs it stops once the reader signs out.
    private var phoneWork: (accountID: String, syncedAt: Date)?
    /// This device's Hardcover library and its file's modification date, so the check before
    /// each save (`isStillCurrent(_:book:)`) doesn't decode the whole library again.
    private var phoneCopy: (modified: Date, library: PhoneLibrary)?
    /// A test's iCloud user record name, which stands in for the container's account check.
    private let userRecordName: String?
    private let suppliedClaimDeviceID: String?
    /// Names this install in its claims (`SpineClaimV1.deviceID`): a test's ID, or a random one
    /// made at first use and kept in `defaults`. An install that loses it makes a new one, and
    /// the old one's claims expire.
    private var claimDeviceID: String {
        if let suppliedClaimDeviceID { return suppliedClaimDeviceID }
        let key = "SpineClaimDeviceID"
        if let id = defaults.string(forKey: key) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
    private let now: @Sendable () -> Date

    /// Creates a store on the shared container's private database, or on `database`, which
    /// tests pass to stand in for CloudKit, with the user defaults suite `defaultsSuite` of their
    /// own. Such a store reads and writes records only; the iCloud account checks and the
    /// worklist subscription still use the container, unless the test passes `userRecordName`.
    init(
        database: (any SpineCloudDatabase)? = nil, defaultsSuite: String? = nil,
        userRecordName: String? = nil, claimDeviceID: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        suppliedDatabase = database
        self.defaultsSuite = defaultsSuite
        self.userRecordName = userRecordName
        suppliedClaimDeviceID = claimDeviceID
        self.now = now
    }

    /// Reads the archive and worklist and opens the gate (`database`) when iCloud is clear for
    /// this device's account; otherwise closes it with the check's error. With iCloud storage
    /// off, it reads nothing. A failed read leaves the gate as it was and rethrows.
    func checkAccounts() async throws -> CloudAccountCheck {
        if CloudStorage.isOff(in: defaults) {
            gate = .failure(.iCloudOff)
            return .off
        }
        let archive =
            try await fetchArchive(in: ungatedDatabase)
            ?? CloudLibraryArchive(version: 1, sources: [])
        let worklist = try await fetchWorklist(in: ungatedDatabase)
        let signedIn = signedInAccountID
        let check = archive.check(
            worklist: worklist, signedInAccountID: signedIn,
            chosenAccountID: signedIn == nil ? CloudStorage.chosenLibrary(in: defaults) : nil
        )
        switch check {
        case .clear(let accountID): gate = .success(accountID)
        case .otherAccounts: gate = .failure(.otherAccountInICloud)
        case .chooseLibrary: gate = .failure(.libraryChoiceNeeded)
        case .off: gate = .failure(.iCloudOff)
        }
        return check
    }

    func installWorklistSubscription() async throws {
        let subscriptionID = CloudContract.worklistSubscriptionID
        let database = container.privateCloudDatabase
        do {
            _ = try await database.subscription(for: subscriptionID)
            return
        } catch let error as CKError where error.code == .unknownItem {
            // A missing subscription is normal on first launch.
        }
        let subscription = CKQuerySubscription(
            recordType: "SpineWorklistV1", predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    func loadWork() async throws -> WorkContext? {
        // A user's record name is the same in both environments, so the environment joins it.
        let cloudUserRecordName =
            "\(CloudEnvironment.current)/\(try await checkedUserRecordName())"
        // Every run checks first, so no run designs another account's books.
        _ = try await checkAccounts()
        if case .failure(let error) = gate { throw error }
        let worklist = try await fetchWorklist()
        phoneWork = nil
        switch workSource(worklist) {
        case .none:
            return nil
        case .phone(let phone):
            phoneWork = (phone.accountID, phone.syncedAt)
            return WorkContext(
                accountID: phone.accountID, syncedAt: phone.syncedAt,
                books: try await applyingChoices(accountID: phone.accountID, books: phone.books),
                followsWorklist: false, cloudUserRecordName: cloudUserRecordName)
        case .worklist, .archive:
            guard let archive = try await fetchArchive() else {
                if worklist != nil { throw CompanionError.waitingForLibrary }
                return nil
            }
            let (snapshot, books, followsWorklist) = try archive.workSource(
                for: worklist, accountID: clearedAccountID)
            return WorkContext(
                accountID: snapshot.accountID, syncedAt: snapshot.syncedAt,
                books: try await applyingChoices(accountID: snapshot.accountID, books: books),
                followsWorklist: followsWorklist, cloudUserRecordName: cloudUserRecordName)
        }
    }

    func savedDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1? {
        let id = CKRecord.ID(
            recordName: CloudContract.designRecordName(accountID: accountID, bookID: bookID))
        let record: CKRecord
        do { record = try await database.record(for: id) } catch let error as CKError
            where error.code == .unknownItem
        { return nil }
        if Self.holdsOtherVersion(record["payload"] as? Data) {
            throw CompanionError.unsupportedCloudData
        }
        guard let existing = Self.design(in: record), existing.accountID == accountID,
            existing.bookID == bookID
        else { return nil }
        return existing
    }

    /// The claim's save is the check: it goes through only while the record is as this device
    /// read it, so of two devices that claim a book at once, CloudKit refuses one, and that
    /// device reads the other's claim on its next try.
    func claimDesign(accountID: String, bookID: Int) async -> Bool {
        let deviceID = claimDeviceID
        let now = now()
        var isHeld = false
        do {
            try await write(
                recordType: "SpineClaimV1",
                recordName: CloudContract.designClaimRecordName(
                    accountID: accountID, bookID: bookID)
            ) { record in
                isHeld =
                    Self.payload(SpineClaimV1.self, in: record)?
                    .holds(against: deviceID, now: now) ?? false
                if isHeld { return nil }
                return try JSONEncoder().encode(SpineClaimV1(deviceID: deviceID, claimedAt: now))
            }
            return !isHeld
        } catch CompanionError.cloudConflict {
            // Other devices kept saving the claim, so one of them holds it.
            return false
        } catch {
            return true
        }
    }

    func isStillCurrent(_ context: WorkContext, book: CloudBook) async throws -> Bool {
        guard try await belongsToWork(context, bookID: book.id) else { return false }
        let current = try await applyingChoices(accountID: context.accountID, books: [book])
        return current.first?.chosenCoverURL == book.chosenCoverURL
            && current.first?.seriesLink == book.seriesLink
    }

    /// Returns whether `bookID` is still in the work that `context` came from.
    private func belongsToWork(_ context: WorkContext, bookID: Int) async throws -> Bool {
        let worklist = try await fetchWorklist()
        guard context.followsWorklist else {
            // A worklist, sign-in, or sign-out since the run started takes over on the next run.
            // Signed out now, only a run that started on the archive continues.
            let fromArchive = phoneWork.map { $0 != (context.accountID, context.syncedAt) } ?? true
            switch workSource(worklist) {
            case .phone(let phone):
                return phone.accountID == context.accountID
                    && phone.books.contains { $0.id == bookID }
            case .archive:
                return fromArchive
            case .worklist:
                // A run on the account's snapshot that is newer than the worklist continues
                // until the Apple TV lists that snapshot or a newer one
                // (`CloudLibraryArchive.workSource(for:accountID:)`).
                guard let worklist else { return false }
                return fromArchive && worklist.accountID == context.accountID
                    && CloudContract.isNewerSync(context.syncedAt, than: worklist.syncedAt)
            case .none: return false
            }
        }
        guard let worklist else { return false }
        return worklist.accountID == context.accountID
            && CloudContract.isSameSync(worklist.syncedAt, context.syncedAt)
            && worklist.bookIDs.contains(bookID)
    }

    @discardableResult func save(
        _ design: SpineDesignV1, replacing: Bool, ifUnchangedFrom base: SpineDesignV1?
    ) async throws -> SpineDesignV1 {
        var kept = design
        try await write(design) { existing in
            guard let existing,
                base.map({ existing != $0 }) == true
                    || existing.outlasts(design, replacing: replacing)
            else { return design }
            kept = existing
            return nil
        }
        return kept
    }

    func saveRecolored(_ design: SpineDesignV1) async throws {
        guard let colors = design.colors else { throw CompanionError.invalidDesign }
        try await inRecolorOrder {
            try await self.write(design) { existing in
                guard let existing else {
                    throw CompanionError.designChanged
                }
                // Only the colors change in the stored record.
                let recolored = existing.recolored(colors)
                return recolored == existing ? nil : recolored
            }
        }
    }

    func saveRefonted(_ design: SpineDesignV1) async throws {
        guard let family = design.fontFamily else { throw CompanionError.invalidDesign }
        try await inRecolorOrder {
            try await self.write(design) { existing in
                guard let existing else {
                    throw CompanionError.designChanged
                }
                // Only the font changes in the stored record.
                let refonted = existing.refonted(
                    family: family, postScriptName: design.fontPostScriptName,
                    instanceWeight: design.instanceWeight, typeface: design.typeface)
                return refonted == existing ? nil : refonted
            }
        }
    }

    /// Runs `save` after every earlier save of the reader's edits has finished, so colors and
    /// fonts reach CloudKit in the order the reader chose them. A failed save doesn't hold up the
    /// next one.
    private func inRecolorOrder(_ save: @escaping @Sendable () async throws -> Void) async throws {
        let previous = recolorTail
        let current = Task {
            await previous?.value
            try await save()
        }
        recolorTail = Task { _ = try? await current.value }
        try await current.value
    }

    /// Writes the design that `update` returns, given the record's valid design if any, to the
    /// record of `design`'s account and book. Keeps the record when `update` returns `nil`, and
    /// saves nothing when it throws. Saves with `ifServerRecordUnchanged` and retries up to
    /// three times when another device changes the record meanwhile.
    ///
    /// A record of another contract version, such as a newer build's design, throws
    /// `CompanionError.unsupportedCloudData`, because saving over it would drop the fields this
    /// build can't read; a malformed version-1 record counts as no design.
    private func write(
        _ design: SpineDesignV1, as update: (SpineDesignV1?) throws -> SpineDesignV1?
    ) async throws {
        try design.validate()
        let id = CKRecord.ID(
            recordName: CloudContract.designRecordName(
                accountID: design.accountID, bookID: design.bookID))
        for _ in 0..<3 {
            let record: CKRecord
            do { record = try await database.record(for: id) } catch let error as CKError
                where error.code == .unknownItem
            {
                record = CKRecord(recordType: "SpineDesignV1", recordID: id)
            }
            guard record.recordType == "SpineDesignV1" else {
                throw CompanionError.invalidCloudData
            }
            if Self.holdsOtherVersion(record["payload"] as? Data) {
                throw CompanionError.unsupportedCloudData
            }
            guard let saving = try update(Self.design(in: record)) else { return }
            try saving.validate()
            record["payload"] = try JSONEncoder().encode(saving) as CKRecordValue
            do {
                try await database.saveIfUnchanged(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            }
        }
        throw CompanionError.cloudConflict
    }

    /// Saves `choice` unless the record already names this cover; the last writer wins.
    func save(_ choice: CoverChoiceV1) async throws {
        try choice.validate()
        try await write(
            JSONEncoder().encode(choice), recordType: "CoverChoiceV1",
            recordName: CloudContract.coverChoiceRecordName(
                accountID: choice.accountID, bookID: choice.bookID)
        ) { record in
            guard let existing = Self.payload(CoverChoiceV1.self, in: record) else { return false }
            return existing.coverURL == choice.coverURL && existing.editionID == choice.editionID
        }
    }

    func deleteCoverChoice(accountID: String, bookID: Int) async throws {
        try await deleteRecord(
            named: CloudContract.coverChoiceRecordName(accountID: accountID, bookID: bookID))
    }

    func save(_ link: SeriesLinkV1, replacing base: SeriesLinkV1?) async throws -> SeriesLinkV1? {
        try link.validate()
        let name = CloudContract.seriesLinkRecordName(
            accountID: link.accountID, bookID: link.bookID)
        var kept: SeriesLinkV1?
        try await write(recordType: "SeriesLinkV1", recordName: name) { record in
            let merged = link.merged(
                over: Self.payload(SeriesLinkV1.self, in: record), changing: base)
            kept = merged.changesNothing ? nil : merged
            return try kept.map { try JSONEncoder().encode($0) }
        }
        // A CloudKit delete doesn't check the record's change tag.
        if kept == nil { try await deleteRecord(named: name) }
        return kept
    }

    func topFivePins(accountID: String) async throws -> TopFivePinsV1? {
        let name = CloudContract.topFivePinsRecordName(accountID: accountID)
        return try await records([name]).first
            .flatMap { Self.payload(TopFivePinsV1.self, in: $0) }?
            .checked(recordName: name)
    }

    func save(_ pins: TopFivePinsV1, replacing base: TopFivePinsV1?) async throws -> TopFivePinsV1 {
        try pins.validate()
        var kept = pins
        try await write(
            recordType: "TopFivePinsV1",
            recordName: CloudContract.topFivePinsRecordName(accountID: pins.accountID)
        ) { record in
            kept = pins.merged(over: Self.payload(TopFivePinsV1.self, in: record), changing: base)
            return try JSONEncoder().encode(kept)
        }
        return kept
    }

    func seriesLooks(accountID: String, keys: Set<SeriesLookKey>) async throws -> [SeriesLookKey:
        SeriesLookV1]
    {
        var looks: [String: SeriesLookV1] = [:]
        for record in try await records(
            keys.map { CloudContract.seriesLookRecordName(accountID: accountID, key: $0) })
        {
            looks[record.recordID.recordName] = Self.payload(SeriesLookV1.self, in: record)
        }
        return SeriesLookV1.keyed(looks, accountID: accountID)
    }

    /// Saves `look` as a new record. When the record exists, another device decided the group's
    /// look first: the save fails with `serverRecordChanged`, and the saved look is returned.
    func createLook(_ look: SeriesLookV1) async throws -> SeriesLookV1 {
        try look.validate()
        let record = CKRecord(
            recordType: "SeriesLookV1",
            recordID: CKRecord.ID(
                recordName: CloudContract.seriesLookRecordName(
                    accountID: look.accountID, key: look.key)))
        record["payload"] = try JSONEncoder().encode(look) as CKRecordValue
        do {
            try await database.saveIfUnchanged(record)
            return look
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard
                let existing = try await seriesLooks(
                    accountID: look.accountID, keys: [look.key])[look.key]
            else { throw CompanionError.invalidCloudData }
            return existing
        }
    }

    /// Saves `look` over a saved look it upgrades, checking the saved record again on each try,
    /// so a recoloring or a better look that another device saves meanwhile is kept. A record
    /// that holds no valid version-1 look is replaced, and one of another contract version, such
    /// as a newer build's look, throws `CompanionError.unsupportedCloudData`.
    func upgradeLook(_ look: SeriesLookV1) async throws -> SeriesLookV1 {
        try look.validate()
        let name = CloudContract.seriesLookRecordName(accountID: look.accountID, key: look.key)
        var kept = look
        try await write(
            JSONEncoder().encode(look), recordType: "SeriesLookV1", recordName: name
        ) { record in
            if Self.holdsOtherVersion(record["payload"] as? Data) {
                throw CompanionError.unsupportedCloudData
            }
            guard let payload = Self.payload(SeriesLookV1.self, in: record),
                let saved =
                    SeriesLookV1.keyed([name: payload], accountID: look.accountID)[look.key],
                !saved.isUpgraded(at: look.tier, awaitingFont: look.awaitsFont)
            else { return false }
            kept = saved
            return true
        }
        return kept
    }

    /// Saves `look` over its group's look; the last writer wins. A look of another contract
    /// version, such as a newer build's, throws `CompanionError.unsupportedCloudData` instead.
    func save(_ look: SeriesLookV1) async throws {
        try look.validate()
        try await write(
            JSONEncoder().encode(look), recordType: "SeriesLookV1",
            recordName: CloudContract.seriesLookRecordName(
                accountID: look.accountID, key: look.key)
        ) { record in
            if Self.holdsOtherVersion(record["payload"] as? Data) {
                throw CompanionError.unsupportedCloudData
            }
            return false
        }
    }

    func saveEdited(_ look: SeriesLookV1, replacing base: SeriesLookV1) async throws {
        try look.validate()
        let payload = try JSONEncoder().encode(look)
        try await inRecolorOrder {
            try await self.write(
                payload, recordType: "SeriesLookV1",
                recordName: CloudContract.seriesLookRecordName(
                    accountID: look.accountID, key: look.key)
            ) { record in
                guard let saved = Self.payload(SeriesLookV1.self, in: record),
                    saved == base || saved == look
                else { throw CompanionError.designChanged }
                return saved == look
            }
        }
    }

    func saveReaderEdit(_ edit: SeriesLookEdit, at date: Date, to look: SeriesLookV1) async throws {
        try await inRecolorOrder {
            try await self.write(
                recordType: "SeriesLookV1",
                recordName: CloudContract.seriesLookRecordName(
                    accountID: look.accountID, key: look.key)
            ) { record in
                guard let saved = Self.payload(SeriesLookV1.self, in: record) else {
                    throw CompanionError.designChanged
                }
                let edited = edit.applied(to: saved, at: date)
                guard edited != saved else { return nil }
                try edited.validate()
                return try JSONEncoder().encode(edited)
            }
        }
    }

    /// Saves `payload` in the named record, creating the record when it is missing, unless
    /// `isCurrent` finds that the record already holds it; nothing is saved when `isCurrent`
    /// throws. Saves with `ifServerRecordUnchanged` and retries up to three times when another
    /// device changes the record meanwhile.
    private func write(
        _ payload: Data, recordType: String, recordName: String,
        isCurrent: (CKRecord) throws -> Bool = { _ in false }
    ) async throws {
        try await write(recordType: recordType, recordName: recordName) { record in
            try isCurrent(record) ? nil : payload
        }
    }

    /// Saves the payload that `update` returns for the named record, given the record as fetched
    /// or a new one when it is missing; keeps the record when `update` returns `nil`, and saves
    /// nothing when it throws. Saves with `ifServerRecordUnchanged` and retries up to three
    /// times when another device changes the record meanwhile.
    private func write(
        recordType: String, recordName: String, as update: (CKRecord) throws -> Data?
    ) async throws {
        let id = CKRecord.ID(recordName: recordName)
        for _ in 0..<3 {
            let record: CKRecord
            do { record = try await database.record(for: id) } catch let error as CKError
                where error.code == .unknownItem
            {
                record = CKRecord(recordType: recordType, recordID: id)
            }
            guard record.recordType == recordType else { throw CompanionError.invalidCloudData }
            guard let payload = try update(record) else { return }
            record["payload"] = payload as CKRecordValue
            do {
                try await database.saveIfUnchanged(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            }
        }
        throw CompanionError.cloudConflict
    }

    private func deleteRecord(named name: String) async throws {
        try await database.delete(CKRecord.ID(recordName: name))
    }

    /// Returns this device's own Hardcover library when it is signed in, otherwise the archive's
    /// library of the account that the check cleared (`checkAccounts()`), with each book's
    /// newest design.
    ///
    /// Signed in, the result is `nil` until this device has its copy of the account's library,
    /// downloaded or adopted from the archive (`HardcoverAccount.syncIfStale()`); snapshots of
    /// other accounts are never used. Signed out, the archive can show the library and reviews
    /// that this device published. The phone library shows without iCloud, just without designs,
    /// and names why in `iCloudIssue`: no iCloud account, a restriction, another account's data
    /// awaiting the reader's choice, or iCloud storage turned off.
    func loadLibrary() async throws -> LibrarySnapshot? {
        if let accountID = signedInAccountID {
            guard let phone = phoneLibrary(), phone.accountID == accountID else { return nil }
            var snapshot = LibrarySnapshot(
                accountID: phone.accountID, syncedAt: phone.syncedAt, books: phone.books,
                designs: [:], series: phone.series)
            do {
                _ = try await checkedUserRecordName()
                snapshot.designs = try await designs(accountID: phone.accountID, books: phone.books)
                snapshot.books = try await applyingChoices(
                    accountID: phone.accountID, books: phone.books)
                snapshot.looks = try await looks(accountID: phone.accountID, books: snapshot.books)
            } catch let error as CompanionError
                where [.noICloudAccount, .iCloudRestricted, .otherAccountInICloud, .iCloudOff]
                .contains(error)
            {
                snapshot.iCloudIssue = error
            }
            return snapshot
        }
        _ = try await checkedUserRecordName()
        guard let archive = try await fetchArchive() else { return nil }
        // An empty worklist pauses generation only; the library still shows every book.
        let shown = try await fetchWorklist().flatMap { $0.bookIDs.isEmpty ? nil : $0 }
        let accountID = clearedAccountID
        let (snapshot, books, _) =
            try (try? archive.workSource(for: shown, accountID: accountID))
            ?? archive.workSource(for: nil, accountID: accountID)
        let chosen = try await applyingChoices(accountID: snapshot.accountID, books: books)
        return LibrarySnapshot(
            accountID: snapshot.accountID, syncedAt: snapshot.syncedAt, books: chosen,
            designs: try await designs(accountID: snapshot.accountID, books: books),
            looks: try await looks(accountID: snapshot.accountID, books: chosen),
            series: snapshot.series)
    }

    /// Returns the saved looks of the look groups of `books`, which carry their series links.
    private func looks(accountID: String, books: [CloudBook]) async throws -> [SeriesLookKey:
        SeriesLookV1]
    {
        try await seriesLooks(
            accountID: accountID,
            keys: Set(books.compactMap { SeriesDesigns.lookKey(of: $0, link: $0.seriesLink) }))
    }

    private func designs(accountID: String, books: [CloudBook]) async throws -> [Int:
        SpineDesignV1]
    {
        let records = try await records(
            books.map { CloudContract.designRecordName(accountID: accountID, bookID: $0.id) })
        return LibrarySnapshot.latestDesigns(
            records.compactMap(Self.design(in:)), accountID: accountID, books: books)
    }

    /// Returns `books` with the reader's chosen covers and series links.
    private func applyingChoices(accountID: String, books: [CloudBook]) async throws
        -> [CloudBook]
    {
        let records = try await records(
            books.flatMap {
                [
                    CloudContract.coverChoiceRecordName(accountID: accountID, bookID: $0.id),
                    CloudContract.seriesLinkRecordName(accountID: accountID, bookID: $0.id),
                ]
            })
        var covers: [String: CoverChoiceV1] = [:]
        var links: [String: SeriesLinkV1] = [:]
        for record in records {
            covers[record.recordID.recordName] = Self.payload(CoverChoiceV1.self, in: record)
            links[record.recordID.recordName] = Self.payload(SeriesLinkV1.self, in: record)
        }
        return SeriesLinkV1.apply(
            links, accountID: accountID,
            to: CoverChoiceV1.apply(covers, accountID: accountID, to: books))
    }

    /// Fetches the `payload` of the named records that exist.
    ///
    /// A missing record is skipped. Any other per-record failure throws, so a transient error
    /// cannot pass for a deleted design, choice, or look.
    private func records(_ names: [String], in database: (any SpineCloudDatabase)? = nil)
        async throws -> [CKRecord]
    {
        let database = database ?? self.database
        var records: [CKRecord] = []
        // CloudKit limits one fetch to a few hundred IDs; batches of 100 match the Apple TV.
        for start in stride(from: 0, to: names.count, by: 100) {
            let batch = names[start..<min(start + 100, names.count)]
                .map {
                    CKRecord.ID(recordName: $0)
                }
            let results = try await database.records(for: batch)
            for result in results.values {
                switch result {
                case .success(let record): records.append(record)
                case .failure(let error as CKError) where error.code == .unknownItem: continue
                case .failure(let error): throw error
                }
            }
        }
        return records
    }

    /// Where a run would find its work now, given `worklist`. Signed out, a worklist of another
    /// account than the cleared one counts as none.
    private func workSource(_ worklist: SpineWorklistV1?) -> WorkSource {
        let accountID = signedInAccountID
        var worklist = worklist
        if accountID == nil, let cleared = clearedAccountID, worklist?.accountID != cleared {
            worklist = nil
        }
        return WorkSource(
            worklist: worklist, signedInAccountID: accountID,
            phone: accountID == nil ? nil : phoneLibrary())
    }

    /// This device's cached Hardcover library (`PhoneLibrary.load(from:)`), decoded again only
    /// when its file changes.
    private func phoneLibrary() -> PhoneLibrary? {
        let url = PhoneLibrary.url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path())
        guard let modified = attributes?[.modificationDate] as? Date else {
            phoneCopy = nil
            return nil
        }
        if let phoneCopy, phoneCopy.modified == modified { return phoneCopy.library }
        let library = PhoneLibrary.load(from: url)
        phoneCopy = library.map { (modified: modified, library: $0) }
        return library
    }

    private func checkedUserRecordName() async throws -> String {
        if let userRecordName { return userRecordName }
        switch try await container.accountStatus() {
        case .available: break
        case .noAccount: throw CompanionError.noICloudAccount
        case .restricted: throw CompanionError.iCloudRestricted
        default: throw CompanionError.iCloudUnavailable
        }
        return try await container.userRecordID().recordName
    }

    private func fetchWorklist(in database: (any SpineCloudDatabase)? = nil) async throws
        -> SpineWorklistV1?
    {
        let database = database ?? self.database
        let record: CKRecord
        do {
            record = try await database.record(
                for: CKRecord.ID(recordName: CloudContract.worklistRecordName))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard record.recordType == "SpineWorklistV1", let data = record["payload"] as? Data,
            data.count <= 5 * 1024 * 1024
        else { throw CompanionError.invalidCloudData }
        let worklist = try Self.decode(SpineWorklistV1.self, from: data)
        try worklist.validate()
        return worklist
    }

    func archivedLibrary(accountID: String) async throws -> CloudSourceSnapshot? {
        try await fetchArchive()?.newestHardcoverSnapshot(accountID: accountID)
    }

    /// Splices `library` into the archive record, creating the record when it is missing.
    func publishLibrary(_ library: PhoneLibrary) async throws {
        let snapshot = CloudSourceSnapshot(library)
        try await updateArchive(in: database) { try CloudLibraryArchive.splice(snapshot, into: $0) }
    }

    /// Adds `merges` to the archive's (`CloudLibraryArchive.recording(merges:into:)`), so no
    /// device asks about those accounts again, then opens the gate when every entry merged into
    /// the signed-in account. Writes past the gate, because it records the reader's answer.
    func recordMerges(_ merges: [String: String]) async throws {
        try await updateArchive(in: ungatedDatabase) {
            try CloudLibraryArchive.recording(merges: merges, into: $0)
        }
        if let accountID = signedInAccountID, merges.values.allSatisfy({ $0 == accountID }) {
            gate = .success(accountID)
        }
    }

    /// Copies the records of `oldAccountID` for `books`, the books that `accountID`'s library
    /// shares with it, to `accountID`: designs, cover choices, series links, the series looks of
    /// the books' look groups, and the Top Five pins of these books. Writes past the gate, for
    /// **Merge**.
    ///
    /// Each copy changes only the payload's `accountID`, and a design's `workItemHash`, which it
    /// computes for `accountID`'s book; every other field survives, even one this app doesn't
    /// decode. A copy is create-only: a record that `accountID` already has stays. A source
    /// record that is missing, of another type, unreadable, or of another account is skipped.
    /// Nothing is deleted.
    func copyRecords(from oldAccountID: String, into accountID: String, books: [CloudBook])
        async throws
    {
        let database = ungatedDatabase
        // Both accounts' links decide which look groups the books belong to.
        var links: [String: SeriesLinkV1] = [:]
        for record in try await records(
            books.flatMap {
                [
                    CloudContract.seriesLinkRecordName(accountID: oldAccountID, bookID: $0.id),
                    CloudContract.seriesLinkRecordName(accountID: accountID, bookID: $0.id),
                ]
            }, in: database)
        {
            links[record.recordID.recordName] = Self.payload(SeriesLinkV1.self, in: record)
        }
        let oldLinks = SeriesLinkV1.apply(links, accountID: oldAccountID, to: books)
        let newLinks = SeriesLinkV1.apply(links, accountID: accountID, to: books)
        var keys = Set<SeriesLookKey>()
        for (book, old) in zip(newLinks, oldLinks) {
            for link in [book.seriesLink, old.seriesLink, nil] {
                if let key = SeriesDesigns.lookKey(of: book, link: link) { keys.insert(key) }
            }
        }

        // Each copy's payload changes besides `accountID`, or `nil` to skip the copy.
        typealias Copy = (
            type: String, from: String, to: String, change: ([String: Any]) -> [String: Any]?
        )
        var copies: [Copy] = []
        func named(_ name: (String) -> String) -> (from: String, to: String) {
            (name(oldAccountID), name(accountID))
        }
        for book in books {
            let design = named { CloudContract.designRecordName(accountID: $0, bookID: book.id) }
            let workItemHash = CloudContract.workItemHash(accountID: accountID, book: book)
            copies.append(
                ("SpineDesignV1", design.from, design.to, { _ in ["workItemHash": workItemHash] }))
            let cover = named {
                CloudContract.coverChoiceRecordName(accountID: $0, bookID: book.id)
            }
            copies.append(("CoverChoiceV1", cover.from, cover.to, { _ in [:] }))
            let link = named { CloudContract.seriesLinkRecordName(accountID: $0, bookID: book.id) }
            copies.append(("SeriesLinkV1", link.from, link.to, { _ in [:] }))
        }
        for key in keys {
            let look = named { CloudContract.seriesLookRecordName(accountID: $0, key: key) }
            copies.append(("SeriesLookV1", look.from, look.to, { _ in [:] }))
        }
        let ids = Set(books.map(\.id))
        let pins = named { CloudContract.topFivePinsRecordName(accountID: $0) }
        copies.append(
            (
                "TopFivePinsV1", pins.from, pins.to,
                { payload in
                    let kept = (payload["bookIDs"] as? [Int])?.filter(ids.contains) ?? []
                    return kept.isEmpty ? nil : ["bookIDs": kept]
                }
            ))

        var sources: [String: CKRecord] = [:]
        for record in try await records(copies.map(\.from), in: database) {
            sources[record.recordID.recordName] = record
        }
        for copy in copies {
            guard let source = sources[copy.from], source.recordType == copy.type,
                let data = source["payload"] as? Data,
                var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                payload["accountID"] as? String == oldAccountID,
                let changes = copy.change(payload)
            else { continue }
            payload.merge(changes) { _, new in new }
            payload["accountID"] = accountID
            let record = CKRecord(recordType: copy.type, recordID: CKRecord.ID(recordName: copy.to))
            record["payload"] =
                try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
                as CKRecordValue
            do {
                try await database.saveIfUnchanged(record)
            } catch let error as CKError where error.code == .serverRecordChanged {
                // The account already has this record, which stays.
            }
        }
    }

    /// Saves the archive JSON that `update` returns for the stored archive, creating the record
    /// when it is missing; keeps the record when `update` returns `nil`. Saves with
    /// `ifServerRecordUnchanged` and retries up to three times when another device changes the
    /// archive meanwhile.
    private func updateArchive(
        in database: any SpineCloudDatabase, _ update: (Data?) throws -> Data?
    ) async throws {
        for _ in 0..<3 {
            let (record, stored) = try await libraryRecord(in: database)
            guard let payload = try update(stored) else { return }
            // CloudKit uploads the asset from this file during the save.
            let file = FileManager.default.temporaryDirectory.appending(
                path: "library-\(UUID().uuidString).json")
            try payload.write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }
            record["archive"] = CKAsset(fileURL: file)
            do {
                try await database.saveIfUnchanged(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            }
        }
        throw CompanionError.cloudConflict
    }

    private func fetchArchive(in database: (any SpineCloudDatabase)? = nil) async throws
        -> CloudLibraryArchive?
    {
        guard let json = try await libraryRecord(in: database ?? self.database).json else {
            return nil
        }
        let archive = try Self.decode(CloudLibraryArchive.self, from: json)
        guard archive.version == 1 else { throw CompanionError.unsupportedCloudData }
        return archive
    }

    /// Returns the `library-v1` record with its archive JSON, or a new record and `nil` when
    /// none exists. Throws `CompanionError.invalidCloudData` for a record without a readable
    /// archive of at most 50 MB.
    private func libraryRecord(in database: any SpineCloudDatabase) async throws -> (
        record: CKRecord, json: Data?
    ) {
        let id = CKRecord.ID(recordName: CloudContract.libraryRecordName)
        let record: CKRecord
        do { record = try await database.record(for: id) } catch let error as CKError
            where error.code == .unknownItem
        {
            return (CKRecord(recordType: "LibraryArchive", recordID: id), nil)
        }
        guard record.recordType == "LibraryArchive", let asset = record["archive"] as? CKAsset,
            let url = asset.fileURL
        else { throw CompanionError.invalidCloudData }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 50 * 1024 * 1024 else { throw CompanionError.invalidCloudData }
        return (record, try Data(contentsOf: url))
    }

    private static func design(in record: CKRecord) -> SpineDesignV1? {
        guard record.recordType == "SpineDesignV1", let data = record["payload"] as? Data,
            let design = try? JSONDecoder().decode(SpineDesignV1.self, from: data),
            (try? design.validate()) != nil
        else { return nil }
        return design
    }

    /// Whether the JSON `data` names a contract version other than 1, such as a newer build's,
    /// which this build can neither read nor replace without losing its fields.
    private static func holdsOtherVersion(_ data: Data?) -> Bool {
        struct Versioned: Decodable { let version: Int }
        guard let data, let payload = try? JSONDecoder().decode(Versioned.self, from: data) else {
            return false
        }
        return payload.version != 1
    }

    /// Decodes a worklist or archive, throwing `CompanionError.unsupportedCloudData` for JSON
    /// of another contract version that this build can't decode and
    /// `CompanionError.invalidCloudData` for any other JSON it can't decode.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch is DecodingError {
            throw holdsOtherVersion(data)
                ? CompanionError.unsupportedCloudData : CompanionError.invalidCloudData
        }
    }

    /// Decodes the `payload` of a record whose type is named for `type`, such as a
    /// `CoverChoiceV1` record. Readers validate the result.
    private static func payload<T: Decodable>(_ type: T.Type, in record: CKRecord) -> T? {
        guard record.recordType == String(describing: type), let data = record["payload"] as? Data
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// The private database calls that `CloudSpineStore` makes, so tests can stand in a database
/// that enforces `ifServerRecordUnchanged` for its conflict handling.
protocol SpineCloudDatabase: Sendable {
    /// Fetches the record, or throws `CKError.unknownItem` when it doesn't exist.
    func record(for id: CKRecord.ID) async throws -> CKRecord
    /// Fetches the `payload` of each record; a missing record's result is `CKError.unknownItem`.
    func records(for ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
    /// Saves `record` only when the server's copy is unchanged since it was fetched, or does not
    /// exist for a new record, and throws the record's save error, such as
    /// `CKError.serverRecordChanged`.
    func saveIfUnchanged(_ record: CKRecord) async throws
    /// Deletes the record, and succeeds when it doesn't exist.
    func delete(_ id: CKRecord.ID) async throws
}

/// The database `CloudSpineStore` uses while its gate is closed: every call throws `error`.
private struct PausedSpineDatabase: SpineCloudDatabase {
    let error: CompanionError

    func record(for id: CKRecord.ID) async throws -> CKRecord { throw error }

    func records(for ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
    {
        throw error
    }

    func saveIfUnchanged(_ record: CKRecord) async throws { throw error }

    func delete(_ id: CKRecord.ID) async throws { throw error }
}

/// This device's iCloud choices, kept in `HardcoverAccount.summaryDefaults` or a test's suite.
/// Signing out keeps them.
enum CloudStorage {
    /// Set by **Keep iCloud Off**: the device then reads and writes nothing in iCloud, and the
    /// check (`CloudSpineStore.checkAccounts()`) asks nothing.
    private static let offKey = "iCloudStorageOff"
    /// The account whose library a device without a sign-in chose to show
    /// (`CloudAccountCheck.chooseLibrary`). A sign-in ignores it.
    private static let libraryKey = "iCloudLibraryAccountID"

    static func isOff(in defaults: UserDefaults = HardcoverAccount.summaryDefaults) -> Bool {
        defaults.bool(forKey: offKey)
    }

    static func setOff(_ off: Bool, in defaults: UserDefaults = HardcoverAccount.summaryDefaults) {
        if off { defaults.set(true, forKey: offKey) } else { defaults.removeObject(forKey: offKey) }
    }

    static func chosenLibrary(in defaults: UserDefaults = HardcoverAccount.summaryDefaults)
        -> String?
    {
        defaults.string(forKey: libraryKey)
    }

    static func choose(
        _ accountID: String, in defaults: UserDefaults = HardcoverAccount.summaryDefaults
    ) {
        defaults.set(accountID, forKey: libraryKey)
    }
}

/// `SpineCloudDatabase` over a CloudKit database.
private struct PrivateSpineDatabase: SpineCloudDatabase {
    let database: CKDatabase

    func record(for id: CKRecord.ID) async throws -> CKRecord {
        try await database.record(for: id)
    }

    func records(for ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
    {
        try await database.records(for: ids, desiredKeys: ["payload"])
    }

    func saveIfUnchanged(_ record: CKRecord) async throws {
        let result = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        guard let saved = result.saveResults[record.recordID] else {
            throw CompanionError.invalidCloudData
        }
        _ = try saved.get()
    }

    func delete(_ id: CKRecord.ID) async throws {
        do {
            _ = try await database.deleteRecord(withID: id)
        } catch let error as CKError where error.code == .unknownItem {}
    }
}

/// The CloudKit environment this build reads and writes, which scopes the local ledger
/// (`WorkContext.cloudUserRecordName`). A TestFlight install over a development build keeps the
/// app's container, ledger included, but moves from the Development database to Production, so
/// books checked in one must be checked again in the other.
enum CloudEnvironment {
    static let current: String = {
        #if targetEnvironment(simulator)
            "development"
        #elseif os(macOS)
            // Export for TestFlight and the App Store signs the Mac's `icloud-container-environment`
            // entitlement "Production"; development signing adds none, and CloudKit then uses
            // Development. A Mac profile never holds `get-task-allow`.
            SecTaskCreateFromSelf(nil)
                .flatMap {
                    SecTaskCopyValueForEntitlement(
                        $0, "com.apple.developer.icloud-container-environment" as CFString, nil)
                } as? String == "Production" ? "production" : "development"
        #else
            name(
                profile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
                    .flatMap { try? Data(contentsOf: $0) })
        #endif
    }()

    /// "development" when `profile`, the build's embedded iOS provisioning profile, lets a
    /// debugger attach (`get-task-allow`), as development signing does, since such a build uses
    /// the Development database; otherwise "production", as for TestFlight and App Store builds,
    /// which embed a distribution profile or none.
    static func name(profile: Data?) -> String {
        guard let profile, let start = profile.firstRange(of: Data("<?xml".utf8)),
            let end = profile.firstRange(of: Data("</plist>".utf8)),
            let plist = try? PropertyListSerialization.propertyList(
                from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any],
            entitlements["get-task-allow"] as? Bool == true
        else { return "production" }
        return "development"
    }
}
