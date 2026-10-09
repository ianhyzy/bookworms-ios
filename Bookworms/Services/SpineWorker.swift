import CloudKit
import Foundation
import os

let generationLog = Logger(subsystem: "gay.ian.Bookworms.iOS", category: "generation")

/// How a run spends network data and the user's daily Private Cloud Compute quota.
enum RunMode: Sendable {
    /// A user-started run: any network, until the daily limit.
    case foreground
    /// The charging task: no cellular or constrained network, and it stops when the quota nears
    /// its limit so the user keeps headroom for the day.
    case background
}

/// The generator's progress, as the Spines tab and the continued-processing activity show it.
///
/// The last run's outcome is saved across launches, because the charging task usually runs in a
/// process that iOS ends before the user opens the app.
struct WorkerSnapshot: Sendable, Codable {
    var isRunning = false
    var phase = "Not run yet"
    /// Books left in the current or last run's queue.
    var queue = 0
    var completed = 0
    var failed = 0
    var currentTitle: String?
    var error: String?
    var model: ModelStatus?
    /// When a stopped run should resume: the quota reset or a service's retry delay.
    var retryAfter: Date?
    var lastRunAt: Date?

    // The model status is read fresh, and a saved snapshot describes a finished run.
    private enum CodingKeys: String, CodingKey {
        case phase, queue, completed, failed, error, retryAfter, lastRunAt
    }

    /// Clears a stop reason whose retry date has passed, such as a quota that has since reset,
    /// so the Spines tab does not report it as current.
    mutating func dropExpiredStop(now: Date = Date()) {
        guard !isRunning, let retryAfter, retryAfter <= now else { return }
        phase = "Ready to continue"
        error = nil
        self.retryAfter = nil
    }
}

enum WorkerUpdate: Sendable {
    case status(WorkerSnapshot)
    case saved(SpineDesignV1)
}

/// Serializes reconciliation so a push, the charging task, and **Generate now** cannot
/// duplicate work.
///
/// Status and saved designs go out through `updates` in the order they happen. A run stops when
/// its calling task is cancelled, for example when a background task expires.
actor SpineWorker {
    enum Disposition: Equatable {
        /// Stop the run. The next attempt should start no earlier than the date, when known.
        case stopRun(retryAfter: Date?)
        /// Record a failure for this book, which then waits out the ledger's backoff, and continue.
        case skipBook
        /// Record a failure for this book, then stop the run. The cause may be this book's host
        /// or the network, so the next run moves past the book, and a failing network costs one
        /// book's backoff instead of the whole queue's.
        case skipBookAndStop
    }

    nonisolated let updates: AsyncStream<WorkerUpdate>
    private let continuation: AsyncStream<WorkerUpdate>.Continuation
    private let store: any SpineStore
    private let ledger = WorkLedger()
    private let analyzer = BookAnalyzer()
    // One session per network policy for the worker's lifetime: a URLSession lives until it is
    // invalidated, so a downloader per run would leak one.
    private let covers = CoverDownloader()
    private let backgroundCovers = CoverDownloader(allowsExpensiveNetwork: false)
    private var snapshot: WorkerSnapshot
    private var isRunning = false
    // Series designs found or made during the current pass, so siblings are looked up once.
    private var seriesDesigns: [Int: SpineDesignV1] = [:]
    private var searchedSeries = Set<Int>()

    static let busyRetryDelay: TimeInterval = 15 * 60

    /// Creates a worker that starts from `lastRun`, the saved outcome of the previous run.
    init(store: any SpineStore, lastRun: WorkerSnapshot = WorkerSnapshot()) {
        self.store = store
        snapshot = lastRun
        (updates, continuation) = AsyncStream.makeStream()
    }

    /// Reads and publishes Private Cloud Compute's availability and quota.
    func refreshModelStatus() async {
        snapshot.model = await analyzer.status()
        snapshot.dropExpiredStop()
        publish()
    }

    /// Designs the books that need it, until the queue is empty or a stop condition.
    ///
    /// A call made while another run is in progress waits for that run, then runs, so a
    /// background task never completes while work it asked for is still in flight.
    func reconcile(mode: RunMode, force: Bool = false) async {
        // Overlapping runs are rare, and polling keeps the wait cancellable.
        while isRunning {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        isRunning = true
        snapshot.isRunning = true
        snapshot.error = nil
        snapshot.retryAfter = nil
        // A pass ends early when the Apple TV changes the work; the next pass reads it again.
        for _ in 0..<3 {
            guard await runPass(mode: mode, force: force) else { break }
        }
        snapshot.isRunning = false
        snapshot.currentTitle = nil
        snapshot.lastRunAt = Date()
        isRunning = false
        publish()
    }

    /// Returns `true` when the Apple TV changed the work during the pass.
    private func runPass(mode: RunMode, force: Bool) async -> Bool {
        snapshot.phase = "Checking the library"
        snapshot.queue = 0
        snapshot.completed = 0
        snapshot.failed = 0
        seriesDesigns = [:]
        searchedSeries = []
        publish()
        do {
            guard let context = try await store.loadWork() else {
                snapshot.phase = "Waiting for the Apple TV library"
                return false
            }
            let accountID = context.accountID
            try await ledger.useCloudUser(context.cloudUserRecordName)
            let books = context.books.filter { !$0.coverCandidates.isEmpty }
            try await ledger.retain(Set(books.map { Self.recordName(accountID, $0) }))
            var queue: [CloudBook] = []
            for book in books {
                let workHash = CloudContract.workItemHash(accountID: accountID, book: book)
                if await ledger.needsCheck(
                    recordName: Self.recordName(accountID, book), workItemHash: workHash,
                    force: force)
                {
                    queue.append(book)
                }
            }
            snapshot.queue = queue.count
            guard !queue.isEmpty else {
                snapshot.phase = "All spines are up to date"
                return false
            }
            // Checked only when there is work, so an idle library never reports the model.
            if await stopForModel(mode: mode) { return false }
            if let model = snapshot.model {
                generationLog.info(
                    "Run started with \(queue.count) books; covers read by \(String(describing: model.coverReader), privacy: .public); quota \(String(describing: model.quota), privacy: .public)"
                )
            }
            let covers = mode == .foreground ? self.covers : backgroundCovers
            for book in queue {
                try Task.checkCancellation()
                snapshot.phase = "Designing spines"
                snapshot.currentTitle = book.title
                publish()
                let workHash = CloudContract.workItemHash(accountID: accountID, book: book)
                let recordName = Self.recordName(accountID, book)
                let start = ContinuousClock.now
                do {
                    let cover = try await covers.fetch(book.coverCandidates)
                    if let design = try await design(
                        for: book, cover: cover, workHash: workHash, context: context)
                    {
                        guard try await store.isStillCurrent(context, bookID: book.id) else {
                            return true
                        }
                        try await store.save(design)
                        continuation.yield(.saved(design))
                        if let seriesID = book.seriesID, seriesDesigns[seriesID] == nil {
                            seriesDesigns[seriesID] = design
                        }
                        generationLog.info(
                            "Book \(book.id, privacy: .private(mask: .hash)) designed in \(start.duration(to: .now), privacy: .public)"
                        )
                    }
                    try await ledger.recordSuccess(
                        recordName: recordName, workItemHash: workHash, coverHash: cover.hash)
                    snapshot.completed += 1
                } catch {
                    try Task.checkCancellation()
                    // Error descriptions can carry a cover URL or quoted book content, which
                    // identify what the user reads, so only the domain and code are public.
                    let nsError = error as NSError
                    generationLog.error(
                        "Book \(book.id, privacy: .private(mask: .hash)) failed after \(start.duration(to: .now), privacy: .public): \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(String(describing: error), privacy: .private)"
                    )
                    let disposition = Self.disposition(of: error)
                    if case .stopRun(let retryAfter) = disposition {
                        stop(Self.message(for: error), retryAfter: retryAfter)
                        return false
                    }
                    try await ledger.recordFailure(recordName: recordName, workItemHash: workHash)
                    snapshot.failed += 1
                    guard disposition == .skipBook else {
                        stop(Self.message(for: error), retryAfter: nil)
                        return false
                    }
                    snapshot.error =
                        "Some books could not be designed. Bookworms tries them again tomorrow."
                }
                snapshot.queue -= 1
                if await stopForModel(mode: mode) { return false }
            }
            snapshot.phase = "Finished"
        } catch {
            if Task.isCancelled {
                snapshot.phase = "Stopped"
            } else {
                var retryAfter: Date?
                if case .stopRun(let date) = Self.disposition(of: error) { retryAfter = date }
                stop(Self.message(for: error), retryAfter: retryAfter)
            }
        }
        return false
    }

    /// Returns the design to save for `book`, or `nil` when iCloud already has this work.
    private func design(
        for book: CloudBook, cover: CoverImage, workHash: String, context: WorkContext
    ) async throws -> SpineDesignV1? {
        // A ledger miss is not proof: another device may have saved this work already.
        let existing = try await store.currentDesign(
            accountID: context.accountID, bookID: book.id)
        if existing?.workItemHash == workHash, existing?.coverHash == cover.hash { return nil }
        // Books in one series share a design so their spines match on the shelf.
        if let seriesID = book.seriesID {
            if seriesDesigns[seriesID] == nil, searchedSeries.insert(seriesID).inserted {
                seriesDesigns[seriesID] = try await storedSeriesDesign(
                    seriesID: seriesID, excluding: book.id, context: context)
            }
            if let source = seriesDesigns[seriesID],
                let reused = try await analyzer.seriesDesign(
                    from: source, book: book, accountID: context.accountID,
                    workItemHash: workHash, coverHash: cover.hash)
            {
                return reused
            }
        }
        return try await analyzer.design(
            book: book, accountID: context.accountID, workItemHash: workHash, cover: cover)
    }

    /// Returns the first current saved design for another book in the series, if any.
    private func storedSeriesDesign(
        seriesID: Int, excluding bookID: Int, context: WorkContext
    ) async throws -> SpineDesignV1? {
        for sibling in context.books where sibling.seriesID == seriesID && sibling.id != bookID {
            if let design = try await store.currentDesign(
                accountID: context.accountID, bookID: sibling.id)
            {
                return design
            }
        }
        return nil
    }

    /// Reads the model status and stops the run when it should send no more requests.
    private func stopForModel(mode: RunMode) async -> Bool {
        let status = await analyzer.status()
        snapshot.model = status
        guard let reason = Self.modelStop(status, mode: mode) else { return false }
        stop(reason.message, retryAfter: reason.retryAfter)
        return true
    }

    private func stop(_ message: String, retryAfter: Date?) {
        snapshot.phase = "Paused"
        snapshot.error = message
        snapshot.retryAfter = retryAfter
    }

    private func publish() { continuation.yield(.status(snapshot)) }

    /// Returns why the model should get no more requests in this run, or `nil` to continue.
    static func modelStop(_ status: ModelStatus, mode: RunMode) -> (
        message: String, retryAfter: Date?
    )? {
        guard status.isAvailable else {
            return (
                status.unavailableReason ?? CompanionError.modelUnavailable.localizedDescription,
                nil
            )
        }
        guard status.coverReader != .none else {
            return (CompanionError.modelUnavailable.localizedDescription, nil)
        }
        switch status.quota {
        case .limitReached:
            return (
                CompanionError.quotaReached(status.quotaResetDate).localizedDescription,
                status.quotaResetDate
            )
        case .approachingLimit where mode == .background:
            return (
                "Paused near today's Private Cloud Compute limit to leave room for you.",
                status.quotaResetDate
            )
        default:
            return nil
        }
    }

    /// Decides whether an error stops the run or fails only the current book.
    ///
    /// Quota, model service, iCloud, and connectivity errors stop the run so later books are not
    /// spent on a request that cannot succeed now. Errors tied to one book's cover, font, or
    /// design fail that book. A cover host that is unreachable while the network works fails
    /// the book, so one dead link cannot block the queue on every run. A timeout or a dropped
    /// connection can come from either, so it fails the book and stops the run.
    static func disposition(of error: any Error, now: Date = Date()) -> Disposition {
        switch error {
        case let error as CompanionError:
            switch error {
            case .invalidCover, .coverTooLarge, .invalidDesign: return .skipBook
            case .quotaReached(let resetDate): return .stopRun(retryAfter: resetDate)
            case .modelBusy(let retryAfter):
                return .stopRun(retryAfter: retryAfter ?? now.addingTimeInterval(busyRetryDelay))
            default: return .stopRun(retryAfter: nil)
            }
        case let error as CKError:
            let transient: Set<CKError.Code> = [
                .networkUnavailable, .networkFailure, .requestRateLimited, .zoneBusy,
                .serviceUnavailable, .notAuthenticated, .quotaExceeded,
                .accountTemporarilyUnavailable,
            ]
            guard transient.contains(error.code) else { return .skipBook }
            return .stopRun(retryAfter: error.retryAfterSeconds.map { now.addingTimeInterval($0) })
        case let error as URLError:
            let offline: Set<URLError.Code> = [
                .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
                .cancelled,
            ]
            if offline.contains(error.code) { return .stopRun(retryAfter: nil) }
            if [.timedOut, .networkConnectionLost].contains(error.code) { return .skipBookAndStop }
            return .skipBook
        case is CancellationError:
            return .stopRun(retryAfter: nil)
        default:
            return .skipBook
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? CompanionError)?.errorDescription ?? error.localizedDescription
    }

    private static func recordName(_ accountID: String, _ book: CloudBook) -> String {
        CloudContract.designRecordName(accountID: accountID, bookID: book.id)
    }
}
