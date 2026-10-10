import CloudKit
import Foundation

/// Reads the Apple TV archive, or this iPhone's own Hardcover library when it is signed in, and
/// publishes one portable design per Hardcover book in the private database of the shared iCloud
/// container.
actor CloudSpineStore: SpineStore {
    private let container = CKContainer(identifier: CloudContract.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
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
                accountID: phone.accountID, syncedAt: phone.syncedAt, books: phone.books,
                followsWorklist: false, cloudUserRecordName: cloudUserRecordName)
        case .worklist, .archive:
            guard let archive = try await fetchArchive() else {
                if worklist != nil { throw CompanionError.waitingForLibrary }
                return nil
            }
            let (snapshot, books) = try archive.workSource(for: worklist)
            return WorkContext(
                accountID: snapshot.accountID, syncedAt: snapshot.syncedAt, books: books,
                followsWorklist: worklist != nil, cloudUserRecordName: cloudUserRecordName)
        }
    }

    func currentDesign(accountID: String, bookID: Int) async throws -> SpineDesignV1? {
        let id = CKRecord.ID(
            recordName: CloudContract.designRecordName(accountID: accountID, bookID: bookID))
        let record: CKRecord
        do { record = try await database.record(for: id) } catch let error as CKError
            where error.code == .unknownItem
        { return nil }
        guard let existing = Self.design(in: record), existing.accountID == accountID,
            existing.bookID == bookID,
            existing.generatorVersion == CloudContract.generatorVersion
        else { return nil }
        return existing
    }

    func isStillCurrent(_ context: WorkContext, bookID: Int) async throws -> Bool {
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

    func save(_ design: SpineDesignV1) async throws {
        try design.validate()
        let id = CKRecord.ID(
            recordName: CloudContract.designRecordName(
                accountID: design.accountID, bookID: design.bookID))
        let payload = try JSONEncoder().encode(design)
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
            // Another run already saved this work from this generator.
            if let existing = Self.design(in: record), existing.accountID == design.accountID,
                existing.bookID == design.bookID,
                existing.workItemHash == design.workItemHash,
                existing.coverHash == design.coverHash,
                existing.generatorVersion == design.generatorVersion
            {
                return
            }
            record["payload"] = payload as CKRecordValue
            do {
                let result = try await database.modifyRecords(
                    saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
                guard let saved = result.saveResults[id] else {
                    throw CompanionError.invalidCloudData
                }
                _ = try saved.get()
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            }
        }
        throw CompanionError.cloudConflict
    }

    /// Returns this iPhone's own Hardcover library when it is signed in, otherwise the Apple TV
    /// archive, with each book's newest design.
    ///
    /// Signed in, the result is `nil` until the account's library is downloaded, because the
    /// archive may belong to another account. The phone library shows without an iCloud
    /// account, just without designs.
    func loadLibrary() async throws -> LibrarySnapshot? {
        if let accountID = HardcoverAccount.signedInAccountID {
            guard let phone = PhoneLibrary.load(), phone.accountID == accountID else { return nil }
            var snapshot = LibrarySnapshot(
                accountID: phone.accountID, syncedAt: phone.syncedAt, books: phone.books,
                designs: [:])
            do {
                _ = try await checkedUserRecordName()
                snapshot.designs = try await designs(accountID: phone.accountID, books: phone.books)
            } catch CompanionError.noICloudAccount, CompanionError.iCloudRestricted {}
            return snapshot
        }
        _ = try await checkedUserRecordName()
        guard let archive = try await fetchArchive() else { return nil }
        // An empty worklist pauses generation only; the library still shows every book.
        let shown = (try? await fetchWorklist()).flatMap { $0.bookIDs.isEmpty ? nil : $0 }
        let (snapshot, books) =
            try (try? archive.workSource(for: shown)) ?? archive.workSource(for: nil)
        return LibrarySnapshot(
            accountID: snapshot.accountID, syncedAt: snapshot.syncedAt, books: books,
            designs: try await designs(accountID: snapshot.accountID, books: books))
    }

    private func designs(accountID: String, books: [CloudBook]) async throws -> [Int:
        SpineDesignV1]
    {
        var designs: [SpineDesignV1] = []
        let names = books.map {
            CKRecord.ID(
                recordName: CloudContract.designRecordName(accountID: accountID, bookID: $0.id))
        }
        // CloudKit limits one fetch to a few hundred IDs; batches of 100 match the Apple TV.
        for start in stride(from: 0, to: names.count, by: 100) {
            let batch = Array(names[start..<min(start + 100, names.count)])
            let results = try await database.records(for: batch, desiredKeys: ["payload"])
            for result in results.values {
                if let record = try? result.get(), let design = Self.design(in: record) {
                    designs.append(design)
                }
            }
        }
        return LibrarySnapshot.latestDesigns(designs, accountID: accountID, books: books)
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

    private func fetchArchive() async throws -> CloudLibraryArchive? {
        let record: CKRecord
        do {
            record = try await database.record(
                for: CKRecord.ID(recordName: CloudContract.libraryRecordName))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard record.recordType == "LibraryArchive", let asset = record["archive"] as? CKAsset,
            let url = asset.fileURL
        else { throw CompanionError.invalidCloudData }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 50 * 1024 * 1024 else { throw CompanionError.invalidCloudData }
        let archive = try JSONDecoder()
            .decode(
                CloudLibraryArchive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw CompanionError.unsupportedCloudData }
        return archive
    }

    private static func design(in record: CKRecord) -> SpineDesignV1? {
        guard record.recordType == "SpineDesignV1", let data = record["payload"] as? Data,
            let design = try? JSONDecoder().decode(SpineDesignV1.self, from: data),
            (try? design.validate()) != nil
        else { return nil }
        return design
    }
}
