import CloudKit
import Foundation

struct WorkerSnapshot: Sendable {
    var iCloud = "Checking iCloud"
    var model = "Checking model"
    var queue = 0
    var completed = 0
    var activity = "Starting"
    var error: String?
}

/// Serializes reconciliation so wake, push, timer, and manual retry cannot duplicate work.
actor SpineWorker {
    typealias Reporter = @Sendable (WorkerSnapshot) -> Void

    private let cloud: any SpineStore
    private let covers = CoverDownloader()
    private let analyzer = BookAnalyzer()
    private let ledger = WorkLedger()
    private var snapshot = WorkerSnapshot()
    private var reporter: Reporter?
    private var running = false
    private var rerunRequested = false
    private var forceRequested = false
    private var paused = false
    private var analysisTask: Task<SpineDesignV1, Error>?

    init(store: any SpineStore) {
        cloud = store
    }

    func setPaused(_ newValue: Bool) {
        paused = newValue
        if newValue { analysisTask?.cancel() }
        snapshot.activity = newValue ? "Paused" : "Ready"
        publish()
    }

    func installNotifications() async {
        do { try await cloud.installWorklistSubscription() } catch {
            snapshot.error = "Change alerts unavailable; hourly checks remain active."
            publish()
        }
    }

    func reconcile(forceCoverCheck: Bool, report: @escaping Reporter) async {
        reporter = report
        if running {
            rerunRequested = true
            forceRequested = forceRequested || forceCoverCheck
            return
        }
        running = true
        var force = forceCoverCheck
        repeat {
            rerunRequested = false
            forceRequested = false
            await reconcileOnce(forceCoverCheck: force)
            force = forceRequested
        } while rerunRequested && !paused
        running = false
    }

    private func reconcileOnce(forceCoverCheck: Bool) async {
        guard !paused else {
            snapshot.activity = "Paused"
            publish()
            return
        }
        snapshot.error = nil
        snapshot.activity = "Checking library"
        publish()
        do {
            guard let context = try await cloud.loadWork() else {
                snapshot.iCloud = "Connected"
                snapshot.queue = 0
                snapshot.activity = "Waiting for Apple TV"
                publish()
                return
            }
            snapshot.iCloud = "Connected"
            let accountID = context.accountID
            try await ledger.useCloudUser(context.cloudUserRecordName)
            let availableBooks = context.books.filter { !$0.coverCandidates.isEmpty }
            let names = Set(
                availableBooks.map {
                    CloudContract.designRecordName(accountID: accountID, bookID: $0.id)
                })
            try await ledger.retain(names)
            var books: [CloudBook] = []
            for book in availableBooks {
                let recordName = CloudContract.designRecordName(
                    accountID: accountID, bookID: book.id)
                let needsCheck = await ledger.needsCoverCheck(
                    recordName: recordName,
                    workItemHash: CloudContract.workItemHash(accountID: accountID, book: book),
                    sourceSyncedAt: context.syncedAt, force: forceCoverCheck)
                if needsCheck { books.append(book) }
            }
            snapshot.queue = books.count
            snapshot.completed = 0
            publish()
            guard await analyzer.modelIsAvailable() else {
                snapshot.model = "Unavailable"
                snapshot.activity = "Waiting for model"
                snapshot.error = CompanionError.modelUnavailable.localizedDescription
                publish()
                return
            }
            snapshot.model = "Available on device"
            // Books in one series share a design so their spines match on the shelf.
            var seriesDesigns: [Int: SpineDesignV1] = [:]
            var searchedSeries = Set<Int>()
            for book in books {
                if paused { break }
                let workHash = CloudContract.workItemHash(accountID: accountID, book: book)
                let recordName = CloudContract.designRecordName(
                    accountID: accountID, bookID: book.id)
                snapshot.activity = "Checking cover"
                publish()
                do {
                    let cover = try await covers.fetch(book.coverCandidates)
                    // A local hit is not enough: another device or user may have removed the record.
                    let existing = try await cloud.currentDesign(
                        accountID: accountID, bookID: book.id)
                    let cloudMatch =
                        existing?.workItemHash == workHash && existing?.coverHash == cover.hash
                    if !cloudMatch {
                        if paused { break }
                        var reused: SpineDesignV1?
                        if let seriesID = book.seriesID {
                            if seriesDesigns[seriesID] == nil,
                                searchedSeries.insert(seriesID).inserted
                            {
                                seriesDesigns[seriesID] = try await storedSeriesDesign(
                                    seriesID: seriesID, excluding: book.id, in: context.books,
                                    accountID: accountID)
                            }
                            if let source = seriesDesigns[seriesID] {
                                reused = try await analyzer.seriesDesign(
                                    from: source, book: book, accountID: accountID,
                                    workItemHash: workHash, coverHash: cover.hash)
                            }
                        }
                        let design: SpineDesignV1
                        if let reused {
                            design = reused
                        } else {
                            snapshot.activity = "Analyzing cover"
                            publish()
                            let task = Task {
                                try await analyzer.design(
                                    book: book, accountID: accountID,
                                    workItemHash: workHash, cover: cover)
                            }
                            analysisTask = task
                            design = try await task.value
                            analysisTask = nil
                            if let seriesID = book.seriesID, seriesDesigns[seriesID] == nil {
                                seriesDesigns[seriesID] = design
                            }
                        }
                        if paused { break }
                        guard
                            try await cloud.isStillCurrent(context, bookID: book.id)
                        else {
                            rerunRequested = true
                            break
                        }
                        snapshot.activity = "Saving design"
                        publish()
                        try await cloud.save(design)
                    }
                    try await ledger.record(
                        recordName: recordName, workItemHash: workHash,
                        coverHash: cover.hash, sourceSyncedAt: context.syncedAt)
                } catch {
                    analysisTask = nil
                    if paused { break }
                    if case CompanionError.modelUnavailable = error {
                        snapshot.model = "Unavailable"
                        snapshot.activity = "Waiting for model"
                        snapshot.error = CompanionError.modelUnavailable.localizedDescription
                        publish()
                        return
                    }
                    // Keep the queue moving when one cover or design is unusable.
                    snapshot.error = "A cover could not be processed. Retry later."
                    if error is URLError { break }
                }
                snapshot.completed += 1
                snapshot.queue = max(0, books.count - snapshot.completed)
                publish()
            }
            snapshot.activity = paused ? "Paused" : "Idle"
            publish()
        } catch {
            snapshot.activity = "Waiting to retry"
            snapshot.iCloud = "Unavailable"
            snapshot.error =
                (error as? CompanionError)?.localizedDescription
                ?? "Could not sync with iCloud."
            publish()
        }
    }

    /// Returns the first current saved design for another book in the series, if any.
    private func storedSeriesDesign(
        seriesID: Int, excluding bookID: Int, in books: [CloudBook], accountID: String
    ) async throws -> SpineDesignV1? {
        for sibling in books where sibling.seriesID == seriesID && sibling.id != bookID {
            if let design = try await cloud.currentDesign(accountID: accountID, bookID: sibling.id)
            {
                return design
            }
        }
        return nil
    }

    private func publish() { reporter?(snapshot) }
}
