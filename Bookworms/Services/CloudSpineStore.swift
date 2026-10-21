import CloudKit
import Foundation

/// Reads the shared `library-v1` archive, or this device's own Hardcover library when it is
/// signed in, and publishes one portable design per Hardcover book in the private database of the
/// shared iCloud container. It also writes this device's Hardcover library into the archive, so
/// other devices can show it without downloading it. The reader's cover choices and series links,
/// and the series looks, live in the same database.
actor CloudSpineStore: SpineStore {
    private let container = CKContainer(identifier: CloudContract.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    /// The last recolor save, which the next one waits for. The actor admits another save while
    /// one waits on CloudKit, so without this a retried older save could land after a newer one.
    private var recolorTail: Task<Void, Never>?
    /// The account and sync date of the phone library that the last `loadWork` returned, so a
    /// run that designs it stops once the reader signs out.
    private var phoneWork: (accountID: String, syncedAt: Date)?

    func installWorklistSubscription() async throws {
        let subscriptionID = CloudContract.worklistSubscriptionID
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
        let cloudUserRecordName = try await checkedUserRecordName()
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
            let (snapshot, books) = try archive.workSource(for: worklist)
            return WorkContext(
                accountID: snapshot.accountID, syncedAt: snapshot.syncedAt,
                books: try await applyingChoices(accountID: snapshot.accountID, books: books),
                followsWorklist: worklist != nil, cloudUserRecordName: cloudUserRecordName)
        }
    }

    func savedDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1? {
        let id = CKRecord.ID(
            recordName: CloudContract.designRecordName(accountID: accountID, bookID: bookID))
        let record: CKRecord
        do { record = try await database.record(for: id) } catch let error as CKError
            where error.code == .unknownItem
        { return nil }
        guard let existing = Self.design(in: record), existing.accountID == accountID,
            existing.bookID == bookID
        else { return nil }
        return existing
    }

    func isStillCurrent(_ context: WorkContext, book: CloudBook) async throws -> Bool {
        guard try await belongsToWork(context, bookID: book.id) else { return false }
        let current = try await applyingChoices(accountID: context.accountID, books: [book])
        return current.first?.chosenCoverURL == book.chosenCoverURL
    }

    /// Returns whether `bookID` is still in the work that `context` came from.
    private func belongsToWork(_ context: WorkContext, bookID: Int) async throws -> Bool {
        let worklist = try await fetchWorklist()
        guard context.followsWorklist else {
            // A worklist, sign-in, or sign-out since the run started takes over on the next run.
            switch workSource(worklist) {
            case .phone(let phone):
                return phone.accountID == context.accountID
                    && phone.books.contains { $0.id == bookID }
            case .archive:
                // Signed out now: only a run that started on the archive continues.
                return phoneWork.map { $0 != (context.accountID, context.syncedAt) } ?? true
            case .worklist, .none: return false
            }
        }
        guard let worklist else { return false }
        return worklist.accountID == context.accountID
            && abs(worklist.syncedAt.timeIntervalSince(context.syncedAt)) < 0.001
            && worklist.bookIDs.contains(bookID)
    }

    func save(_ design: SpineDesignV1, replacing: Bool) async throws {
        try await write(design) { existing in
            existing?.outlasts(design, replacing: replacing) == true ? nil : design
        }
    }

    func saveRecolored(_ design: SpineDesignV1) async throws {
        guard let colors = design.colors else { throw CompanionError.invalidDesign }
        try await inRecolorOrder {
            try await self.write(design) { existing in
                guard let existing, existing.isSameDesign(as: design) else {
                    throw CompanionError.designChanged
                }
                // Only the colors change in the stored record.
                let recolored = existing.recolored(colors)
                return recolored == existing ? nil : recolored
            }
        }
    }

    /// Runs `save` after every earlier recolor save has finished, so recolors reach CloudKit in
    /// the order the reader made them. A failed save doesn't hold up the next one.
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
            guard let saving = try update(Self.design(in: record)) else { return }
            try saving.validate()
            record["payload"] = try JSONEncoder().encode(saving) as CKRecordValue
            do {
                try await saveIfUnchanged(record)
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

    /// Saves `link`; the last writer wins.
    func save(_ link: SeriesLinkV1) async throws {
        try link.validate()
        try await write(
            JSONEncoder().encode(link), recordType: "SeriesLinkV1",
            recordName: CloudContract.seriesLinkRecordName(
                accountID: link.accountID, bookID: link.bookID))
    }

    func deleteSeriesLink(accountID: String, bookID: Int) async throws {
        try await deleteRecord(
            named: CloudContract.seriesLinkRecordName(accountID: accountID, bookID: bookID))
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
            try await saveIfUnchanged(record)
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
    /// that holds no valid look is replaced.
    func upgradeLook(_ look: SeriesLookV1) async throws -> SeriesLookV1 {
        try look.validate()
        let name = CloudContract.seriesLookRecordName(accountID: look.accountID, key: look.key)
        var kept = look
        try await write(
            JSONEncoder().encode(look), recordType: "SeriesLookV1", recordName: name
        ) { record in
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

    /// Saves `look` over its group's look; the last writer wins.
    func save(_ look: SeriesLookV1) async throws {
        try look.validate()
        try await write(
            JSONEncoder().encode(look), recordType: "SeriesLookV1",
            recordName: CloudContract.seriesLookRecordName(
                accountID: look.accountID, key: look.key))
    }

    func saveRecolored(_ look: SeriesLookV1) async throws {
        try look.validate()
        let payload = try JSONEncoder().encode(look)
        try await inRecolorOrder {
            try await self.write(
                payload, recordType: "SeriesLookV1",
                recordName: CloudContract.seriesLookRecordName(
                    accountID: look.accountID, key: look.key)
            ) { record in
                guard let saved = Self.payload(SeriesLookV1.self, in: record),
                    saved.isSameLook(as: look)
                else { throw CompanionError.designChanged }
                return saved == look
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
        let id = CKRecord.ID(recordName: recordName)
        for _ in 0..<3 {
            let record: CKRecord
            do { record = try await database.record(for: id) } catch let error as CKError
                where error.code == .unknownItem
            {
                record = CKRecord(recordType: recordType, recordID: id)
            }
            guard record.recordType == recordType else { throw CompanionError.invalidCloudData }
            if try isCurrent(record) { return }
            record["payload"] = payload as CKRecordValue
            do {
                try await saveIfUnchanged(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            }
        }
        throw CompanionError.cloudConflict
    }

    /// Saves `record` only when the server's copy is unchanged since it was fetched, or does not
    /// exist for a new record, and throws the record's save error.
    private func saveIfUnchanged(_ record: CKRecord) async throws {
        let result = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        guard let saved = result.saveResults[record.recordID] else {
            throw CompanionError.invalidCloudData
        }
        _ = try saved.get()
    }

    private func deleteRecord(named name: String) async throws {
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: name))
        } catch let error as CKError where error.code == .unknownItem {}
    }

    /// Returns this device's own Hardcover library when it is signed in, otherwise the archive's
    /// library, with each book's newest design.
    ///
    /// Signed in, the result is `nil` until this device has its copy of the account's library,
    /// downloaded or adopted from the archive (`HardcoverAccount.syncIfStale()`), because the
    /// archive's newest library may belong to another account. Signed out, the archive can show
    /// the library and reviews that this device published. The phone library shows without an
    /// iCloud account, just without designs.
    func loadLibrary() async throws -> LibrarySnapshot? {
        if let accountID = HardcoverAccount.signedInAccountID {
            guard let phone = PhoneLibrary.load(), phone.accountID == accountID else { return nil }
            var snapshot = LibrarySnapshot(
                accountID: phone.accountID, syncedAt: phone.syncedAt, books: phone.books,
                designs: [:], series: phone.series)
            do {
                _ = try await checkedUserRecordName()
                snapshot.designs = try await designs(accountID: phone.accountID, books: phone.books)
                snapshot.books = try await applyingChoices(
                    accountID: phone.accountID, books: phone.books)
                snapshot.looks = try await looks(accountID: phone.accountID, books: snapshot.books)
            } catch CompanionError.noICloudAccount, CompanionError.iCloudRestricted {}
            return snapshot
        }
        _ = try await checkedUserRecordName()
        guard let archive = try await fetchArchive() else { return nil }
        // An empty worklist pauses generation only; the library still shows every book.
        let shown = (try? await fetchWorklist()).flatMap { $0.bookIDs.isEmpty ? nil : $0 }
        let (snapshot, books) =
            try (try? archive.workSource(for: shown)) ?? archive.workSource(for: nil)
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
    private func records(_ names: [String]) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        // CloudKit limits one fetch to a few hundred IDs; batches of 100 match the Apple TV.
        for start in stride(from: 0, to: names.count, by: 100) {
            let batch = names[start..<min(start + 100, names.count)]
                .map {
                    CKRecord.ID(recordName: $0)
                }
            let results = try await database.records(for: batch, desiredKeys: ["payload"])
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

    /// Where a run would find its work now, given `worklist`.
    private func workSource(_ worklist: SpineWorklistV1?) -> WorkSource {
        let accountID = HardcoverAccount.signedInAccountID
        return WorkSource(
            worklist: worklist, signedInAccountID: accountID,
            phone: accountID == nil ? nil : PhoneLibrary.load())
    }

    private func checkedUserRecordName() async throws -> String {
        switch try await container.accountStatus() {
        case .available: break
        case .noAccount: throw CompanionError.noICloudAccount
        case .restricted: throw CompanionError.iCloudRestricted
        default: throw CompanionError.iCloudUnavailable
        }
        return try await container.userRecordID().recordName
    }

    private func fetchWorklist() async throws -> SpineWorklistV1? {
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
        let worklist = try JSONDecoder().decode(SpineWorklistV1.self, from: data)
        try worklist.validate()
        return worklist
    }

    func archivedLibrary(accountID: String) async throws -> CloudSourceSnapshot? {
        try await fetchArchive()?.newestHardcoverSnapshot(accountID: accountID)
    }

    /// Splices `library` into the archive record, creating the record when it is missing. Saves
    /// with `ifServerRecordUnchanged` and retries up to three times when another device changes
    /// the archive meanwhile.
    func publishLibrary(_ library: PhoneLibrary) async throws {
        let snapshot = CloudSourceSnapshot(library)
        for _ in 0..<3 {
            let (record, stored) = try await libraryRecord()
            guard let payload = try CloudLibraryArchive.splice(snapshot, into: stored) else {
                return
            }
            // CloudKit uploads the asset from this file during the save.
            let file = FileManager.default.temporaryDirectory.appending(
                path: "library-\(UUID().uuidString).json")
            try payload.write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }
            record["archive"] = CKAsset(fileURL: file)
            do {
                try await saveIfUnchanged(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            }
        }
        throw CompanionError.cloudConflict
    }

    private func fetchArchive() async throws -> CloudLibraryArchive? {
        guard let json = try await libraryRecord().json else { return nil }
        let archive = try JSONDecoder().decode(CloudLibraryArchive.self, from: json)
        guard archive.version == 1 else { throw CompanionError.unsupportedCloudData }
        return archive
    }

    /// Returns the `library-v1` record with its archive JSON, or a new record and `nil` when
    /// none exists. Throws `CompanionError.invalidCloudData` for a record without a readable
    /// archive of at most 50 MB.
    private func libraryRecord() async throws -> (record: CKRecord, json: Data?) {
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

    /// Decodes the `payload` of a record whose type is named for `type`, such as a
    /// `CoverChoiceV1` record. Readers validate the result.
    private static func payload<T: Decodable>(_ type: T.Type, in record: CKRecord) -> T? {
        guard record.recordType == String(describing: type), let data = record["payload"] as? Data
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
