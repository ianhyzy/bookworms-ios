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
    /// The book being designed.
    var currentBook: CloudBook?
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
    /// A series look that a pass created, or found another device had created first.
    case savedLook(SeriesLookV1)
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
    // Saved designs of series books, looked up at most once per pass, and designs the pass
    // made.
    private var bookDesigns: [Int: SpineDesignV1] = [:]
    private var checkedBooks = Set<Int>()
    // The pass's look groups, and their saved looks, looked up at most once per pass; `nil`
    // records a group without a look.
    private var lookGroups: [SeriesLookKey: [CloudBook]] = [:]
    private var looks: [SeriesLookKey: SeriesLookV1?] = [:]
    /// The book that the reader asked to design anew in this run, until the run tries it.
    private var redesign: (bookID: Int, remakesLook: Bool)?

    static let busyRetryDelay: TimeInterval = 15 * 60
    /// How long a stop waits when its cause needs the user, such as a full iCloud storage plan
    /// or Apple Intelligence turned off. **Generate now** does not wait.
    static let lastingStopDelay: TimeInterval = 24 * 60 * 60
    /// URL error codes that stop the run with no retry date: no usable network, or a cancelled
    /// request.
    static let offlineErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        .cancelled,
    ]

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
    /// With `redesigning`, the run first makes a new model design for that book even when its
    /// saved design is current, as **Redesign spine** asks: it skips the ledger, the saved
    /// design, and series reuse. With `remakesLook`, the book's look group's saved look then takes
    /// the new design's colors and type (`SeriesLookV1.remade(from:at:)`). A book outside the
    /// run's work, or without a cover, is not designed.
    ///
    /// A call made while another run is in progress waits for that run, then runs, so a
    /// background task never completes while work it asked for is still in flight.
    func reconcile(mode: RunMode, redesigning: (bookID: Int, remakesLook: Bool)? = nil) async {
        // Overlapping runs are rare, and polling keeps the wait cancellable.
        while isRunning {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        isRunning = true
        redesign = redesigning
        snapshot.isRunning = true
        snapshot.error = nil
        snapshot.retryAfter = nil
        // A pass ends early when the Apple TV or the reader changes the work; the next pass
        // reads it again.
        var changed = false
        for _ in 0..<3 {
            changed = await runPass(mode: mode)
            if !changed { break }
        }
        // The work kept changing. The books left in `queue` keep the charging task scheduled.
        if changed { snapshot.phase = "Ready to continue" }
        snapshot.isRunning = false
        snapshot.currentBook = nil
        snapshot.lastRunAt = Date()
        redesign = nil
        isRunning = false
        publish()
    }

    /// Returns `true` when the Apple TV or the reader's cover choice changed the work during the
    /// pass.
    private func runPass(mode: RunMode) async -> Bool {
        snapshot.phase = "Checking the library"
        snapshot.queue = 0
        snapshot.completed = 0
        snapshot.failed = 0
        bookDesigns = [:]
        checkedBooks = []
        lookGroups = [:]
        looks = [:]
        publish()
        do {
            guard let context = try await store.loadWork() else {
                // Signed in, the store waits only for the account's first download.
                snapshot.phase =
                    HardcoverAccount.signedInAccountID == nil
                    ? "Waiting for the Apple TV library"
                    : "Waiting for your Hardcover library to download"
                return false
            }
            let accountID = context.accountID
            try await ledger.useCloudUser(context.cloudUserRecordName)
            lookGroups = SeriesDesigns.lookGroups(context.books)
            let books = context.books.filter { !$0.coverCandidates.isEmpty }
            try await ledger.retain(Set(books.map { Self.recordName(accountID, $0) }))
            var queue: [CloudBook] = []
            for book in books {
                let workHash = CloudContract.workItemHash(accountID: accountID, book: book)
                if await ledger.needsCheck(
                    recordName: Self.recordName(accountID, book), workItemHash: workHash,
                    chosenCover: book.chosenCoverURL)
                {
                    queue.append(book)
                }
            }
            queue = SeriesDesigns.sourceFirst(queue)
            if let redesign, let book = books.first(where: { $0.id == redesign.bookID }) {
                queue.removeAll { $0.id == book.id }
                queue.insert(book, at: 0)
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
                snapshot.currentBook = book
                publish()
                let workHash = CloudContract.workItemHash(accountID: accountID, book: book)
                let recordName = Self.recordName(accountID, book)
                let start = ContinuousClock.now
                let redesigned = redesign?.bookID == book.id ? redesign : nil
                do {
                    let cover = try await covers.fetch(book.coverCandidates)
                    if let made = try await design(
                        for: book, cover: cover, workHash: workHash, context: context,
                        forced: redesigned != nil)
                    {
                        guard try await store.isStillCurrent(context, book: book) else {
                            return true
                        }
                        try await store.save(made.design)
                        continuation.yield(.saved(made.design))
                        bookDesigns[book.id] = made.design
                        checkedBooks.insert(book.id)
                        if made.isModelDesign {
                            await saveLook(
                                from: made.design, for: book,
                                replacing: redesigned?.remakesLook == true)
                        }
                        generationLog.info(
                            "Book \(book.id, privacy: .private(mask: .hash)) designed in \(start.duration(to: .now), privacy: .public)"
                        )
                    }
                    try await ledger.recordSuccess(
                        recordName: recordName, workItemHash: workHash, coverHash: cover.hash,
                        chosenCover: book.chosenCoverURL)
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
                    try await ledger.recordFailure(
                        recordName: recordName, workItemHash: workHash,
                        chosenCover: book.chosenCoverURL)
                    snapshot.failed += 1
                    guard disposition == .skipBook else {
                        stop(Self.message(for: error), retryAfter: nil)
                        return false
                    }
                    snapshot.error =
                        "Some books could not be designed. Bookworms tries them again tomorrow."
                }
                if redesigned != nil { redesign = nil }
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

    /// Returns the design to save for `book`, and whether a model request made it, or `nil` when
    /// iCloud already has this work or a design whose colors the reader chose (see
    /// `SpineDesignV1.action(workItemHash:coverHash:readerChoseCover:drawsSeriesLook:)`).
    /// `forced` always makes a model design.
    private func design(
        for book: CloudBook, cover: CoverImage, workHash: String, context: WorkContext,
        forced: Bool
    ) async throws -> (design: SpineDesignV1, isModelDesign: Bool)? {
        // Looked up even when forced, so `saveLook` knows whether the group has a look.
        let look = try await seriesLook(for: book, accountID: context.accountID)
        if !forced {
            // A ledger miss is not proof: another device may have saved this work already.
            let saved = try await store.savedDesign(accountID: context.accountID, bookID: book.id)
            let readerChoseCover = await ledger.readerChoseCover(
                recordName: Self.recordName(context.accountID, book),
                chosenCover: book.chosenCoverURL)
            let action = saved?
                .action(
                    workItemHash: workHash, coverHash: cover.hash,
                    readerChoseCover: readerChoseCover, drawsSeriesLook: look != nil)
            switch action ?? .redesign {
            case .keep: return nil
            case .save(let design): return (design, false)
            case .redesign: break
            }
            // Books in one look group share a design so their spines match on the shelf. A book
            // that draws its group's look saves a copy of it, whichever device made the look.
            let source =
                if let look {
                    look.design(bookID: look.sourceBookID)
                } else {
                    try await storedSeriesDesign(for: book, context: context)
                }
            if let source,
                let reused = try await analyzer.seriesDesign(
                    from: source, book: book, accountID: context.accountID,
                    workItemHash: workHash, coverHash: cover.hash)
            {
                return (reused, false)
            }
        }
        return (
            try await analyzer.design(
                book: book, accountID: context.accountID, workItemHash: workHash, cover: cover),
            true
        )
    }

    /// Returns the series look `book` draws: its look group's saved look, unless its link keeps
    /// its own look.
    private func seriesLook(for book: CloudBook, accountID: String) async throws -> SeriesLookV1? {
        guard book.seriesLink?.ownLook != true,
            let key = SeriesDesigns.lookKey(of: book, link: book.seriesLink)
        else { return nil }
        if let known = looks[key] { return known }
        let look = try await store.seriesLooks(accountID: accountID, keys: [key])[key]
        looks[key] = .some(look)
        return look
    }

    /// Makes `design`, a new model design, the series look of `book`'s look group when the group
    /// has none, so the group's first design decides its look. A look another device saved first
    /// wins. With `replacing`, a group's saved look is made again from `design` instead. A failed
    /// save leaves the group to the rank rule (`storedSeriesDesign`) or its old look until a
    /// later design or the app's catch-up saves one.
    private func saveLook(from design: SpineDesignV1, for book: CloudBook, replacing: Bool) async {
        // `design(for:...)` looked up the group's look, unless the book keeps its own look.
        guard book.seriesLink?.ownLook != true,
            let key = SeriesDesigns.lookKey(of: book, link: book.seriesLink),
            let saved = looks[key], saved == nil || replacing
        else { return }
        do {
            let look: SeriesLookV1
            if let saved {
                look = saved.remade(from: design, at: Date())
                try await store.save(look)
            } else {
                look = try await store.createLook(
                    SeriesLookV1(design: design, key: key, createdAt: Date()))
            }
            looks[key] = .some(look)
            continuation.yield(.savedLook(look))
        } catch {
            let nsError = error as NSError
            generationLog.error(
                "Series look not saved: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)"
            )
        }
    }

    /// Returns the saved design of `book`'s source in a look group without a saved look, by the
    /// rule the app draws with (`SeriesDesigns.sources(of:lends:canLetter:)`), when that source
    /// is another book with a usable saved design from this generator.
    ///
    /// A source ranks before the books that draw with it and is always designed from its own
    /// cover: a redesign from a new cover, or a newly read first book, changes the group.
    private func storedSeriesDesign(
        for book: CloudBook, context: WorkContext
    ) async throws -> SpineDesignV1? {
        guard book.seriesLink?.ownLook != true,
            let key = SeriesDesigns.lookKey(of: book, link: book.seriesLink)
        else { return nil }
        // Every earlier book in the group, usable or not, decides which of them are roots.
        let earlier = (lookGroups[key] ?? [])
            .filter {
                $0.id != book.id && SeriesDesigns.ranksBefore($0, book)
            }
        guard !earlier.isEmpty else { return nil }
        for mate in earlier where checkedBooks.insert(mate.id).inserted {
            bookDesigns[mate.id] = try await store.savedDesign(
                accountID: context.accountID, bookID: mate.id)
        }
        let designs = earlier.reduce(into: [Int: SpineDesignV1]()) { designs, mate in
            if let design = bookDesigns[mate.id],
                design.generatorVersion == CloudContract.generatorVersion,
                SeriesDesigns.isUsableSource(design)
            {
                designs[mate.id] = design
            }
        }
        let source = SeriesDesigns.sources(of: earlier + [book]) { designs[$0.id] != nil }[book.id]
        return source.flatMap { designs[$0] }
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
    ///
    /// An unavailable model waits `lastingStopDelay`, so the charging task does not download the
    /// library in every charging window only to stop again.
    static func modelStop(_ status: ModelStatus, mode: RunMode, now: Date = Date()) -> (
        message: String, retryAfter: Date?
    )? {
        guard status.isAvailable else {
            return (
                status.unavailableReason ?? CompanionError.modelUnavailable.localizedDescription,
                now.addingTimeInterval(lastingStopDelay)
            )
        }
        guard status.coverReader != .none else {
            return (
                CompanionError.modelUnavailable.localizedDescription,
                now.addingTimeInterval(lastingStopDelay)
            )
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
    /// Quota, model service, Google Fonts service, iCloud, and connectivity errors stop the run so
    /// later books are not spent on a request that cannot succeed now. A full iCloud storage plan
    /// waits `lastingStopDelay`, because it does not clear by itself. Errors tied to one book's
    /// cover or design fail that book. A cover host that is unreachable while the network works
    /// fails the book, so one dead link cannot block the queue on every run. A timeout or a
    /// dropped connection can come from either, so it fails the book and stops the run.
    static func disposition(of error: any Error, now: Date = Date()) -> Disposition {
        switch error {
        case let error as CompanionError:
            switch error {
            case .invalidCover, .coverTooLarge, .invalidDesign: return .skipBook
            case .quotaReached(let resetDate): return .stopRun(retryAfter: resetDate)
            case .modelBusy(let retryAfter), .fontServiceUnavailable(let retryAfter):
                return .stopRun(retryAfter: retryAfter ?? now.addingTimeInterval(busyRetryDelay))
            default: return .stopRun(retryAfter: nil)
            }
        case let error as CKError where error.code == .quotaExceeded:
            return .stopRun(retryAfter: now.addingTimeInterval(lastingStopDelay))
        case let error as CKError:
            let transient: Set<CKError.Code> = [
                .networkUnavailable, .networkFailure, .requestRateLimited, .zoneBusy,
                .serviceUnavailable, .notAuthenticated, .accountTemporarilyUnavailable,
            ]
            // Other codes, such as a schema the production container lacks, usually affect
            // every save, so stop after this book instead of spending the quota on the rest.
            guard transient.contains(error.code) else { return .skipBookAndStop }
            return .stopRun(retryAfter: error.retryAfterSeconds.map { now.addingTimeInterval($0) })
        case let error as URLError:
            if offlineErrors.contains(error.code) { return .stopRun(retryAfter: nil) }
            if [.timedOut, .networkConnectionLost].contains(error.code) { return .skipBookAndStop }
            return .skipBook
        case is CancellationError:
            return .stopRun(retryAfter: nil)
        default:
            return .skipBook
        }
    }

    /// The status message for an error that stops the run.
    ///
    /// A network that a policy refused, which only the background cover downloader sets, reads
    /// as waiting for Wi-Fi rather than as offline.
    static func message(for error: any Error) -> String {
        switch error {
        case let error as CompanionError:
            return error.errorDescription ?? error.localizedDescription
        case let error as CKError where error.code == .quotaExceeded:
            return "Your iCloud storage is full. Free up space so Bookworms can save spines."
        case let error as URLError where error.networkUnavailableReason != nil:
            return
                "Waiting for Wi-Fi. Generation while charging does not use cellular data or Low Data Mode."
        default:
            return error.localizedDescription
        }
    }

    private static func recordName(_ accountID: String, _ book: CloudBook) -> String {
        CloudContract.designRecordName(accountID: accountID, bookID: book.id)
    }
}
