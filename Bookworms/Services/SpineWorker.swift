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
/// The counts cover the whole run, across the passes that start again when the work changes, so
/// `completed + failed + queue` is the run's work as known, which changes only when a later pass
/// finds more or fewer books. The last run's outcome is saved across launches, because the
/// charging task usually runs in a process that iOS ends before the user opens the app.
struct WorkerSnapshot: Sendable, Codable {
    var isRunning = false
    var phase = "Not run yet"
    /// Books left in the current or last run's queue.
    var queue = 0
    /// Books the run checked: new designs, series copies, and designs that stay.
    var completed = 0
    var failed = 0
    /// The checked books the run's model designed anew.
    var designed = 0
    /// The checked books that saved a copy of a series' design without a request.
    var fromSeries = 0
    /// The book being designed. It stays set while a later pass checks the library, so the
    /// bindery header keeps it in view; `designingBook` is `nil` then.
    var currentBook: CloudBook?
    var error: String?
    var model: ModelStatus?
    /// When a stopped run should resume: the quota reset or a service's retry delay.
    var retryAfter: Date?
    var startedAt: Date?
    var lastRunAt: Date?
    /// How long the run's latest books took to check, in seconds, oldest first.
    var durations: [TimeInterval] = []
    /// The time left after the pass's latest book, in seconds
    /// (`timeLeft(remaining:durations:elapsed:previous:)`).
    var timeLeft: TimeInterval?
    /// The bar's `fraction` and the books done when the current pass began.
    var passStart = (fraction: 0.0, done: 0)

    // The model status is read fresh, and a saved snapshot describes a finished run.
    private enum CodingKeys: String, CodingKey {
        case phase, queue, completed, failed, designed, fromSeries, error, retryAfter, startedAt,
            lastRunAt
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

extension WorkerSnapshot {
    /// Reads a saved outcome. One saved before runs kept a tally has no start date, which hides
    /// its tally.
    init(from decoder: any Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        phase = try saved.decode(String.self, forKey: .phase)
        queue = try saved.decode(Int.self, forKey: .queue)
        completed = try saved.decode(Int.self, forKey: .completed)
        failed = try saved.decode(Int.self, forKey: .failed)
        designed = try saved.decodeIfPresent(Int.self, forKey: .designed) ?? 0
        fromSeries = try saved.decodeIfPresent(Int.self, forKey: .fromSeries) ?? 0
        error = try saved.decodeIfPresent(String.self, forKey: .error)
        retryAfter = try saved.decodeIfPresent(Date.self, forKey: .retryAfter)
        startedAt = try saved.decodeIfPresent(Date.self, forKey: .startedAt)
        lastRunAt = try saved.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }

    /// How many of the latest books' times the estimate averages: enough that a cluster of quick
    /// series copies or slow new designs doesn't swing it.
    static let estimateWindow = 40
    /// How many books a run times, and how many seconds it runs, before it estimates the time
    /// left, so a few quick checks of saved designs at the start don't promise a short run.
    static let estimateMinimum = (books: 5, seconds: 30.0)

    /// The book being designed, while the run designs it; `nil` while a pass checks the library
    /// or the run stops.
    var designingBook: CloudBook? {
        isRunning && phase == "Designing spines" ? currentBook : nil
    }

    /// The bar's fraction of the run's work. Each pass continues from the fraction the run had
    /// reached, so the bar never moves backward when a later pass finds more books; the count
    /// shows the larger total.
    var fraction: Double {
        let done = completed + failed - passStart.done
        guard done + queue > 0 else { return passStart.fraction }
        return passStart.fraction + (1 - passStart.fraction) * Double(done) / Double(done + queue)
    }

    /// The run's progress in a line: "Designing 12 of 48" while a book is designed, the phase
    /// while the run checks the library, and once it ends, its outcome, such as "Designed 48
    /// spines in 6 minutes" or "Paused until 3:15 PM", until the next run.
    var headline: String {
        let done = completed + failed
        if isRunning {
            guard designingBook != nil else { return phase }
            return "Designing \(done + 1) of \(done + queue)"
        }
        switch phase {
        // A later pass finds the work up to date after an earlier pass checked books.
        case "Finished", "All spines are up to date":
            guard let startedAt, let lastRunAt, done > 0 else { return phase }
            let took = Self.durationText(lastRunAt.timeIntervalSince(startedAt))
            let saved = designed + fromSeries
            return saved > 0
                ? "Designed \(Self.count(saved, "spine")) in \(took)"
                : "Checked \(Self.count(done, "book")) in \(took)"
        case "Paused":
            guard let retryAfter else { return phase }
            let time =
                Calendar.current.isDateInToday(retryAfter)
                ? retryAfter.formatted(date: .omitted, time: .shortened)
                : retryAfter.formatted(.dateTime.month().day().hour().minute())
            return "Paused until \(time)"
        default:
            return phase
        }
    }

    /// The run's tally so far, without zero entries: new designs, series copies, designs that
    /// stay, failures, and once the run stops, the books left. The Generation footer counts the
    /// books without a cover, which no run designs.
    var tally: [String] {
        guard startedAt != nil else { return [] }
        let upToDate = completed - designed - fromSeries
        return [
            designed > 0 ? Self.count(designed, "new design") : nil,
            fromSeries > 0 ? "\(fromSeries) from a series" : nil,
            upToDate > 0 ? "\(upToDate) up to date" : nil,
            failed > 0 ? "\(failed) failed" : nil,
            !isRunning && queue > 0 ? "\(queue) left" : nil,
        ]
        .compactMap { $0 }
    }

    /// The time left while a book is designed, such as "About 3 minutes left"; `nil` before the
    /// run has an estimate, or while it checks the library or waits for a retry date.
    var timeLeftText: String? {
        guard designingBook != nil, retryAfter == nil, let timeLeft else { return nil }
        return Self.timeLeftText(timeLeft)
    }

    /// The time `remaining` books take at the average of `durations`, the latest books' times in
    /// seconds; `nil` until the run has timed `estimateMinimum` books and run for `elapsed`
    /// seconds, or with no books left. A rise of less than a quarter keeps the `previous`
    /// estimate, so the rounded text doesn't flip between two steps from book to book.
    static func timeLeft(
        remaining: Int, durations: [TimeInterval], elapsed: TimeInterval,
        previous: TimeInterval? = nil
    ) -> TimeInterval? {
        let recent = durations.suffix(estimateWindow)
        guard recent.count >= estimateMinimum.books, elapsed >= estimateMinimum.seconds,
            remaining > 0
        else { return nil }
        let estimate = recent.reduce(0, +) / Double(recent.count) * Double(remaining)
        if let previous, estimate > previous, estimate < previous * 1.25 { return previous }
        return estimate
    }

    /// `seconds` left, rounded so the estimate doesn't jump with each book: whole minutes under
    /// 10 minutes, then 5 minutes under an hour, then hours.
    static func timeLeftText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        switch minutes {
        case ..<1: return "Less than a minute left"
        case 1: return "About a minute left"
        case ..<10: return "About \(minutes) minutes left"
        case ..<55: return "About \(Int((Double(minutes) / 5).rounded()) * 5) minutes left"
        case ..<90: return "About an hour left"
        default: return "About \(Int((Double(minutes) / 60).rounded())) hours left"
        }
    }

    /// How long a finished run took, in whole minutes, such as "6 minutes" or "1 hour, 20
    /// minutes".
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds >= 30 else { return "under a minute" }
        let minutes = Duration.seconds(Int((seconds / 60).rounded()) * 60)
        return minutes.formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
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
    private let ledger: WorkLedger
    private let analyzer: BookAnalyzer
    // One session per network policy for the worker's lifetime: a URLSession lives until it is
    // invalidated, so a downloader per run would leak one.
    private let covers: CoverDownloader
    private let backgroundCovers = CoverDownloader(allowsExpensiveNetwork: false)
    /// The status that every model read returns instead of the device's, for tests.
    private let pinnedStatus: ModelStatus?
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
    /// The model this run designs with: the best tier when the run first loaded the library, or
    /// the best one below the backup model after the backup's lasting rejection, including the
    /// same refusal of several books in a row (`newDesign`). `nil` between runs.
    private var runModel: ModelStatus?
    /// The backup model's refusals of this run's latest books.
    private var refusals = RefusalStreak()

    /// Counts the backup model's refusals of consecutive books in a run with one message.
    ///
    /// An HTTP 400 usually refuses one book's request, such as for its crop, but some refuse
    /// every request with these settings: Anthropic reports an account without credit as an
    /// `invalid_request_error`, a text-only model refuses image input, and some
    /// OpenAI-compatible endpoints refuse the JSON schema format. So the same refusal of
    /// `limit` books in a row counts as a lasting rejection. Books that send the backup no
    /// request, such as those that keep a saved design, leave the count alone.
    struct RefusalStreak {
        static let limit = 3
        private var message: String?
        private var count = 0

        /// Counts a book's refusal with `message`. Returns `true`, and starts counting again,
        /// when it makes `limit` refusals in a row with that message.
        mutating func isLasting(after message: String) -> Bool {
            count = message == self.message ? count + 1 : 1
            self.message = message
            guard count == Self.limit else { return false }
            self = RefusalStreak()
            return true
        }
    }

    static let busyRetryDelay: TimeInterval = 15 * 60
    /// How long a stop waits when its cause needs the user, such as a full iCloud storage plan.
    /// **Generate now** does not wait.
    static let lastingStopDelay: TimeInterval = 24 * 60 * 60
    /// URL error codes that stop the run with no retry date: no usable network, or a cancelled
    /// request.
    static let offlineErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        .cancelled,
    ]

    /// Creates a worker that starts from `lastRun`, the saved outcome of the previous run. Tests
    /// pass their own `ledger`, `analyzer`, and foreground `covers`, and pin `modelStatus`, which
    /// every model read then returns, so a run's tier doesn't depend on the device.
    init(
        store: any SpineStore, lastRun: WorkerSnapshot = WorkerSnapshot(),
        ledger: WorkLedger = WorkLedger(), analyzer: BookAnalyzer = BookAnalyzer(),
        covers: CoverDownloader = CoverDownloader(), modelStatus: ModelStatus? = nil
    ) {
        self.store = store
        self.ledger = ledger
        self.analyzer = analyzer
        self.covers = covers
        pinnedStatus = modelStatus
        snapshot = lastRun
        (updates, continuation) = AsyncStream.makeStream()
    }

    /// Reads and publishes the best model tier's availability and quota. A run in progress keeps
    /// showing its own tier, which it publishes after each book, and reads the best tier again
    /// when it ends.
    func refreshModelStatus() async {
        if runModel == nil { snapshot.model = await bestStatus() }
        snapshot.dropExpiredStop()
        publish()
    }

    /// Clears the Spines tab's message about the backup model's `rejection` after the reader's
    /// change to its settings made the app forget it, so the tab no longer says that a lower
    /// tier designs until then. A run in progress keeps its tier.
    func clearMessage(about rejection: String) {
        guard snapshot.error?.contains(rejection) == true else { return }
        snapshot.error = nil
        publish()
    }

    /// Designs the books that need it, until the queue is empty or a stop condition.
    ///
    /// With `redesigning`, the run first designs that book anew at its tier even when its saved
    /// design is current, as **Redesign spine** asks: it skips the ledger, the saved design, and
    /// series reuse. With `remakesLook`, the book's look group's saved look then takes
    /// the new design's colors and type (`SeriesLookV1.remade(from:at:)`). A book outside the
    /// run's work, or without a cover, is not designed. A design or look from a better tier than
    /// the run's stays, and the run says why (`design(for:covers:workHash:context:redesign:mode:)`).
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
        runModel = nil
        refusals = RefusalStreak()
        snapshot = WorkerSnapshot(
            isRunning: true, model: snapshot.model, startedAt: Date(),
            lastRunAt: snapshot.lastRunAt)
        // A pass ends early when the Apple TV or the reader changes the work; the next pass
        // reads it again.
        var changed = false
        for _ in 0..<3 {
            changed = await runPass(mode: mode)
            if !changed { break }
        }
        // The work kept changing. The books left in `queue` keep the charging task scheduled.
        if changed { snapshot.phase = "Ready to continue" }
        redesign = nil
        runModel = nil
        // The best tier again, as the next run would pick it, such as below a backup model that
        // this run found rejected.
        snapshot.model = await bestStatus()
        snapshot.isRunning = false
        snapshot.currentBook = nil
        snapshot.lastRunAt = Date()
        isRunning = false
        publish()
    }

    /// Returns `true` when the Apple TV or the reader's cover choice changed the work during the
    /// pass.
    private func runPass(mode: RunMode) async -> Bool {
        // The counts carry over from earlier passes, and the queue until this pass finds its own.
        snapshot.phase = "Checking the library"
        snapshot.timeLeft = nil
        snapshot.passStart = (snapshot.fraction, snapshot.completed + snapshot.failed)
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
            // The status read sends no model request. It comes before the queue so that a better
            // tier queues the books a weaker tier last checked.
            let model = await readModel()
            let upgradeTier = Self.upgradeTier(model, mode: mode)
            let work = await Self.work(
                books, accountID: accountID, ledger: ledger, tier: model.tier,
                upgradeTier: upgradeTier)
            var queue = SeriesDesigns.sourceFirst(work.queue)
            if let redesign, let book = books.first(where: { $0.id == redesign.bookID }) {
                queue.removeAll { $0.id == book.id }
                queue.insert(book, at: 0)
            }
            snapshot.queue = queue.count
            guard !queue.isEmpty else {
                // Waiting upgrades keep the model's stop and its retry date, such as the quota
                // reset, so the charging task runs again then.
                if !work.upgradeWaits || !stopForModel(model, mode: mode) {
                    snapshot.phase = "All spines are up to date"
                }
                return false
            }
            if stopForModel(model, mode: mode) { return false }
            generationLog.info(
                "Run started with \(queue.count) books; tier \(String(describing: model.tier), privacy: .public); covers read by \(String(describing: model.coverReader), privacy: .public); quota \(String(describing: model.quota), privacy: .public)"
            )
            let covers = mode == .foreground ? self.covers : backgroundCovers
            // Each book's time runs from the end of the one before, skipped books included, so
            // the estimate's durations cover the same books its remaining count does.
            var mark = ContinuousClock.now
            func timeBook() {
                let now = ContinuousClock.now
                let seconds = mark.duration(to: now) / .seconds(1)
                mark = now
                snapshot.durations = Array(
                    (snapshot.durations + [seconds]).suffix(WorkerSnapshot.estimateWindow))
                snapshot.timeLeft = WorkerSnapshot.timeLeft(
                    remaining: snapshot.queue, durations: snapshot.durations,
                    elapsed: snapshot.startedAt.map { Date().timeIntervalSince($0) } ?? 0,
                    previous: snapshot.timeLeft)
            }
            for book in queue {
                try Task.checkCancellation()
                let workHash = CloudContract.workItemHash(accountID: accountID, book: book)
                let recordName = Self.recordName(accountID, book)
                var redesigned = redesign?.bookID == book.id ? redesign : nil
                // After the backup model's lasting rejection moved the run to a lower tier
                // (`newDesign`), a book queued only to upgrade to the backup's tier is skipped
                // without downloading its cover. A rejection of one book's request leaves the
                // run's tier, so the other books still upgrade.
                if redesigned == nil, let tier = runModel?.tier, tier < upgradeTier,
                    !(await ledger.needsCheck(
                        recordName: recordName, workItemHash: workHash,
                        chosenCover: book.chosenCoverURL, runTier: tier))
                {
                    // Counted as checked, so the run's total holds.
                    snapshot.completed += 1
                    snapshot.queue -= 1
                    timeBook()
                    continue
                }
                let start = mark
                snapshot.phase = "Designing spines"
                snapshot.currentBook = book
                publish()
                do {
                    let outcome = try await design(
                        for: book, covers: covers, workHash: workHash, context: context,
                        redesign: redesigned, mode: mode)
                    // `design` drops a redesign that would replace a better tier's design.
                    if redesign == nil { redesigned = nil }
                    if case .save(let made, let source, let replacing) = outcome {
                        guard try await store.isStillCurrent(context, book: book) else {
                            return true
                        }
                        try await store.save(made, replacing: redesigned != nil || replacing)
                        continuation.yield(.saved(made))
                        bookDesigns[book.id] = made
                        checkedBooks.insert(book.id)
                        if source == .new {
                            await saveLook(
                                from: made, for: book, replacing: redesigned?.remakesLook == true)
                        }
                        generationLog.info(
                            "Book \(book.id, privacy: .private(mask: .hash)) designed in \(start.duration(to: .now), privacy: .public)"
                        )
                    }
                    // A design from a better tier than the run's, such as a kept Private Cloud
                    // Compute design, needs no recheck when that tier runs. A saved design that
                    // awaits its font is checked again after a day.
                    var awaitsFont = false
                    if case .save(let made, _, _) = outcome { awaitsFont = made.awaitsFont }
                    try await ledger.recordSuccess(
                        recordName: recordName, workItemHash: workHash,
                        coverHash: outcome.design.coverHash,
                        chosenCover: book.chosenCoverURL,
                        tier: runModel.map { max($0.tier, outcome.design.tier) },
                        awaitsFont: awaitsFont)
                    snapshot.completed += 1
                    // A saved design moved to the book's new metadata counts as staying.
                    if case .save(_, .new, _) = outcome { snapshot.designed += 1 }
                    if case .save(_, .seriesCopy, _) = outcome { snapshot.fromSeries += 1 }
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
                    // A backup model's rejection, which needs the reader, stays in view.
                    if snapshot.error == nil {
                        snapshot.error =
                            "Some books could not be designed. Bookworms tries them again tomorrow."
                    }
                }
                if redesigned != nil { redesign = nil }
                snapshot.queue -= 1
                if stopForModel(await readModel(), mode: mode) { return false }
                timeBook()
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

    /// What a run does with a book's design (`design(for:covers:workHash:context:redesign:mode:)`).
    private enum Outcome {
        /// Leaves this design, iCloud's, in place.
        case keep(SpineDesignV1)
        /// Saves this design, from `source`. `replacing` tells whether it replaces the saved
        /// design whatever that design's tier, as one from the cover the reader chose does
        /// (`SpineDesignV1.outlasts(_:replacing:)`).
        case save(SpineDesignV1, source: Source, replacing: Bool = false)

        /// Where a saved design comes from.
        enum Source {
            /// The book's saved design, moved to its new work-item hash.
            case moved
            /// A new copy of a series' design or look.
            case seriesCopy
            /// The run's tier, from the cover.
            case new
        }

        var design: SpineDesignV1 {
            switch self {
            case .keep(let design), .save(let design, _, _): design
            }
        }
    }

    /// Returns the design to save for `book`, or the saved design to keep when iCloud already
    /// has a design from the run's tier or better, or a design whose colors the reader chose (see
    /// `SpineDesignV1.action(workItemHash:coverHash:readerChoseCover:fromChosenCover:runTier:drawsSeriesLook:upgradesSeriesLook:)`).
    /// A kept design whose book's metadata changed is saved again under the new work-item hash
    /// when its face letters the book's title and author, and otherwise left as it is.
    ///
    /// `redesign`, the reader's **Redesign spine** of this book, makes a new design at the run's
    /// tier, except over a design from a better tier: the book's saved design or, when the
    /// redesign remakes the series look, that look. Only a device with that tier, or a cover
    /// the reader chose since (`SpineDesignV1.comesFromAnotherCover(than:readerChoseCover:fromChosenCover:)`),
    /// replaces it, so the book is checked as on any run, and the run's message says why the
    /// spine stays (`keptMessage(madeBy:runModel:)`). The same check runs again against the
    /// new design's tier when the backup model's lasting rejection lowered it (`newDesign`).
    ///
    /// The saved design is checked before the cover downloads with `covers`. While the book
    /// shows its default cover and the reader chose no other cover since its last check on this
    /// device, a saved design that stays is kept or saved again without a download, so a recheck
    /// of a current design costs one iCloud read: the default cover's hash decides nothing then.
    /// A cover the reader chose is downloaded at every check.
    ///
    /// The book whose design upgrades its group's look (`SeriesLookV1.upgradeSource(among:)`)
    /// is designed as if the group had no look, so a weaker tier's look gets a design from the
    /// run's tier. When that book's own saved design stays, it upgrades the look with no
    /// request. A book draws its group's look only when the look's face letters its title and
    /// author, as the app draws it; otherwise its own design follows the tier rule.
    private func design(
        for book: CloudBook, covers: CoverDownloader, workHash: String, context: WorkContext,
        redesign: (bookID: Int, remakesLook: Bool)?, mode: RunMode
    ) async throws -> Outcome {
        // Looked up even for a redesign, so `saveLook` knows whether the group has a look.
        let savedLook = try await seriesLook(for: book, accountID: context.accountID)
        let runTier = runModel?.tier ?? .local
        let upgradesLook =
            savedLook.map { $0.isUpgraded(at: runTier) && isUpgradeSource(book, of: $0) } ?? false
        let look = upgradesLook ? nil : savedLook
        // A ledger miss is not proof: another device may have saved this work already. A
        // redesign reads it too, to keep a better tier's design.
        let saved = try await store.savedDesign(accountID: context.accountID, bookID: book.id)
        var forced = redesign != nil
        let readerChoseCover = await ledger.readerChoseCover(
            recordName: Self.recordName(context.accountID, book),
            chosenCover: book.chosenCoverURL)
        func savedAction(coverHash: String, fromChosenCover: Bool = false) async throws
            -> SavedDesignAction
        {
            guard let saved else { return .redesign }
            func action(drawsSeriesLook: Bool) -> SavedDesignAction {
                saved.action(
                    workItemHash: workHash, coverHash: coverHash,
                    readerChoseCover: readerChoseCover, fromChosenCover: fromChosenCover,
                    runTier: runTier, drawsSeriesLook: drawsSeriesLook,
                    upgradesSeriesLook: upgradesLook)
            }
            // The glyph checks wait until they decide, so kept designs cost no font download.
            var result = action(drawsSeriesLook: false)
            if result == .redesign, let look {
                let drawn = action(drawsSeriesLook: true)
                if drawn != .redesign,
                    try await analyzer.letters(book, with: look.design(bookID: look.sourceBookID))
                {
                    result = drawn
                }
            }
            // A design moves to a new title or author only when its face letters them. Otherwise
            // it stays under its old work-item hash, which the iPhone and Mac still draw on its
            // book and the Apple TV ignores.
            if case .save(let moved) = result, moved.workItemHash != saved.workItemHash,
                !(try await analyzer.letters(book, with: saved.withAllowedFont))
            {
                return .keep
            }
            return result
        }
        func kept(_ design: SpineDesignV1) async -> SpineDesignV1 {
            if upgradesLook, design.generatedColors == nil {
                await saveLook(from: design, for: book, replacing: false)
            }
            return design
        }
        if !forced, let saved, book.chosenCoverURL == nil, !readerChoseCover {
            switch try await savedAction(coverHash: saved.coverHash) {
            case .keep: return .keep(await kept(saved))
            case .save(let design): return .save(await kept(design), source: .moved)
            case .redesign: break
            }
        }
        let cover = try await covers.fetch(book.coverCandidates)
        let fromChosenCover = cover.url == book.chosenCoverURL
        let newCover =
            saved?
            .comesFromAnotherCover(
                than: cover.hash, readerChoseCover: readerChoseCover,
                fromChosenCover: fromChosenCover) ?? readerChoseCover
        let remadeLook =
            redesign?.remakesLook == true
            ? savedLook.map { $0.design(bookID: $0.sourceBookID) } : nil
        if forced,
            let better = Self.betterDesign(
                than: runTier, saved: saved, remadeLook: remadeLook, newCover: newCover)
        {
            forced = false
            self.redesign = nil
            snapshot.error = Self.keptMessage(madeBy: better.madeBy, runModel: runModel)
        }
        // A saved design from another cover than the reader's choice gives way at any tier, and
        // so does an untracked copy on the book that upgrades its group's look, whose tier is
        // unknown.
        let replacing =
            saved.map {
                $0.comesFromAnotherCover(
                    than: cover.hash, readerChoseCover: readerChoseCover,
                    fromChosenCover: fromChosenCover) || upgradesLook && $0.isUntrackedCopy
            } ?? false
        if !forced {
            switch (
                try await savedAction(coverHash: cover.hash, fromChosenCover: fromChosenCover),
                saved
            ) {
            case (.keep, let saved?): return .keep(await kept(saved))
            case (.save(let design), _): return .save(await kept(design), source: .moved)
            default: break
            }
            // Books in one look group share a design so their spines match on the shelf. A book
            // that draws its group's look saves a copy of it, whichever device made the look.
            let source: SpineDesignV1? =
                if let look {
                    look.design(bookID: look.sourceBookID)
                } else if upgradesLook {
                    nil
                } else {
                    try await storedSeriesDesign(for: book, context: context)
                }
            // A copy replaces a saved design only as a new design would: from a better tier, or
            // from a cover the reader chose. Otherwise the run's tier designs the book.
            if let source,
                let reused = try await analyzer.seriesDesign(
                    from: source, book: book, accountID: context.accountID,
                    workItemHash: workHash, coverHash: cover.hash),
                replacing
                    || saved.map({
                        $0.isOutranked(by: reused.tier, awaitingFont: reused.awaitsFont)
                    }) ?? true
            {
                return .save(reused, source: .seriesCopy, replacing: replacing)
            }
        }
        let made = try await newDesign(
            for: book, cover: cover, workHash: workHash, accountID: context.accountID, mode: mode)
        // The backup model's lasting rejection moves the run to a weaker tier (`newDesign`), so
        // the redesign is checked again against the tier that made `made`. Without it, the tier
        // rule decides, as on any run, and the fallback's message stays in view.
        if forced,
            Self.betterDesign(
                than: made.tier, saved: saved, remadeLook: remadeLook, newCover: newCover) != nil
        {
            self.redesign = nil
            if let saved, saved.outlasts(made, replacing: replacing) {
                return .keep(await kept(saved))
            }
        }
        return .save(made, source: .new, replacing: replacing)
    }

    /// The design that keeps a redesign at `tier` from replacing the book's `saved` design and
    /// the group's `remadeLook`: whichever of them comes from a better tier. A cover the reader
    /// chose since (`newCover`) lets the redesign replace both.
    static func betterDesign(
        than tier: ModelTier, saved: SpineDesignV1?, remadeLook: SpineDesignV1?, newCover: Bool
    ) -> SpineDesignV1? {
        newCover ? nil : [saved, remadeLook].compactMap { $0 }.first { $0.tier > tier }
    }

    /// Designs `book` at the run's tier.
    ///
    /// A lasting rejection by the backup model, such as a revoked key, an unknown model name, or
    /// an account without credit (`ProviderError.isLasting`), would repeat for every book. The
    /// app remembers it until the reader changes the backup model's settings or starts
    /// **Generate now** (`SpineDesigner.rejection`), so this run and later ones design with the
    /// best tier below the backup, down to local defaults, and the Spines tab shows the
    /// rejection. When the tier found can take no request now, such as Private Cloud Compute at
    /// its daily limit, the rejection stops the run. A rejection that arrives after the reader
    /// replaced the key fails only this book, because it says nothing about the new key.
    ///
    /// An HTTP 400 refusal fails only this book (`BookAnalyzer.modelFailure(_:)`), unless it is
    /// the third book in a row that the backup refuses with the same message
    /// (`RefusalStreak`). That refusal counts as a lasting rejection for later books, and the
    /// three books keep their failures.
    private func newDesign(
        for book: CloudBook, cover: CoverImage, workHash: String, accountID: String,
        mode: RunMode
    ) async throws -> SpineDesignV1 {
        guard let model = runModel else { throw CompanionError.modelUnavailable }
        func design(using model: ModelStatus) async throws -> SpineDesignV1 {
            try await analyzer.design(
                book: book, accountID: accountID, workItemHash: workHash, cover: cover,
                using: model)
        }
        guard model.tier == .backup else { return try await design(using: model) }
        // Held in memory for the request, so a rejection that arrives after the reader replaced
        // the key isn't remembered for the new one.
        let key = model.designer.provider.key.read()
        // Any outcome but another refusal ends the streak.
        var streak = refusals
        refusals = RefusalStreak()
        do {
            return try await design(using: model)
        } catch CompanionError.providerRejected(let reason) {
            // A rejection of a replaced key fails only this book, and the run keeps its tier.
            guard
                let next = try await fallBack(from: model, rejection: reason, key: key, mode: mode)
            else { throw CompanionError.providerRefused(reason) }
            return try await design(using: next)
        } catch CompanionError.providerRefused(let reason) {
            if streak.isLasting(after: reason) {
                _ = try await fallBack(from: model, rejection: reason, key: key, mode: mode)
            }
            refusals = streak
            throw CompanionError.providerRefused(reason)
        }
    }

    /// Remembers `rejection` as the backup model's lasting rejection of `model`'s settings
    /// (`SpineDesigner.rememberRejection(_:sentKey:)`) and moves the run to the best tier below
    /// it, which it returns. Returns `nil`, and changes nothing, when this device's key is no
    /// longer `key`, the one it held when the rejected request started. Throws
    /// `CompanionError.providerRejected`, which stops the run, when that tier can take no request
    /// now.
    private func fallBack(
        from model: ModelStatus, rejection: String, key: String?, mode: RunMode
    ) async throws -> ModelStatus? {
        guard model.designer.rememberRejection(rejection, sentKey: key) else { return nil }
        var next = await analyzer.status(for: .appleOnly)
        next.backupUnavailableReason = rejection
        guard Self.modelStop(next, mode: mode) == nil else {
            throw CompanionError.providerRejected(rejection)
        }
        runModel = next
        snapshot.model = next
        snapshot.error = Self.fallbackMessage(rejection: rejection, next: next)
        publish()
        return next
    }

    /// The Spines tab's message when the backup model's `rejection` moves runs to `next`.
    static func fallbackMessage(rejection: String, next: ModelStatus) -> String {
        let sentence = rejection.hasSuffix(".") ? rejection : rejection + "."
        return
            "\(sentence) Until you change the model settings, Bookworms uses \(inSentence(next)). Generate now tries your model again."
    }

    /// The run's message when a redesign keeps a spine that `madeBy` (`SpineDesignV1.madeBy`),
    /// a better tier than `runModel`'s, made.
    static func keptMessage(madeBy: String, runModel: ModelStatus?) -> String {
        let model = runModel.map { " uses \(inSentence($0)), which" } ?? ""
        return
            "\(madeBy) made this spine, so it stays. This \(ThisDevice.name)\(model) never replaces a better model's design."
    }

    /// `status`'s model as a message names it within a sentence.
    static func inSentence(_ status: ModelStatus) -> String {
        switch status.tier {
        case .privateCloudCompute: "Private Cloud Compute"
        case .backup: status.designerName
        case .onDevice: "Apple's on-device model"
        case .local: "default styling"
        }
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

    /// Makes `design`, a new design at the run's tier, the series look of `book`'s look group
    /// when the group has none, so the group's first design decides its look. A look another
    /// device saved first from this tier or a better one wins. When `book` is the source that
    /// upgrades the group's look (`isUpgradeSource(_:of:)`), `design` replaces a look that the
    /// reader never edited and that `design` outranks, such as one from a weaker tier or one
    /// that awaits its font (`SeriesLookV1.isUpgraded(at:awaitingFont:)`), keeping its creation
    /// date. With `replacing`, a group's saved look is made again from `design` instead. A
    /// failed save leaves the group to the rank rule (`storedSeriesDesign`) or its old look
    /// until a later design or the app's catch-up saves one, or, for an upgrade, until the
    /// book's next check.
    private func saveLook(from design: SpineDesignV1, for book: CloudBook, replacing: Bool) async {
        // `design(for:...)` looked up the group's look, unless the book keeps its own look.
        guard book.seriesLink?.ownLook != true,
            let key = SeriesDesigns.lookKey(of: book, link: book.seriesLink),
            let saved = looks[key]
        else { return }
        do {
            var look: SeriesLookV1
            if let saved, replacing {
                look = saved.remade(from: design, at: Date())
                try await store.save(look)
            } else {
                if let saved {
                    look = saved
                } else {
                    look = try await store.createLook(
                        SeriesLookV1(design: design, key: key, createdAt: Date()))
                }
                // The saved look, or a look another device created first.
                if look.isUpgraded(at: design.tier, awaitingFont: design.awaitsFont),
                    isUpgradeSource(book, of: look)
                {
                    look = try await store.upgradeLook(
                        SeriesLookV1(design: design, key: key, createdAt: look.createdAt))
                } else if saved != nil {
                    return
                }
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

    /// Whether `book` is the book of this pass's library whose design upgrades `look`
    /// (`SeriesLookV1.upgradeSource(among:)`).
    private func isUpgradeSource(_ book: CloudBook, of look: SeriesLookV1) -> Bool {
        look.upgradeSource(among: lookGroups[look.key] ?? []) == book.id
    }

    /// Returns the saved design of `book`'s source in a look group without a saved look, by the
    /// rule the app draws with (`SeriesDesigns.sources(of:lends:canLetter:)`), when that source
    /// is another book with a usable saved design, from any generator, made for that book as it
    /// is now (`SeriesDesigns.isCurrent(_:for:)`).
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
            if let design = bookDesigns[mate.id], SeriesDesigns.isUsableSource(design),
                SeriesDesigns.isCurrent(design, for: mate)
            {
                designs[mate.id] = design
            }
        }
        let source = SeriesDesigns.sources(of: earlier + [book]) { designs[$0.id] != nil }[book.id]
        return source.flatMap { designs[$0] }
    }

    /// Reads the run's model status, which sends no model request, and shows it in the snapshot.
    ///
    /// A run's first read picks its tier (`BookAnalyzer.status(for:)`). Later reads keep that
    /// tier and watch its availability and quota. Only the backup model's lasting rejection
    /// moves a run to a lower tier (`newDesign`); a tier that becomes unavailable stops the run
    /// (`stopForModel(_:mode:)`).
    private func readModel() async -> ModelStatus {
        var status: ModelStatus
        if let pinnedStatus {
            status = pinnedStatus
        } else if let runModel {
            status = await analyzer.status(of: runModel.tier, designer: runModel.designer)
            status.pccUnavailableReason = runModel.pccUnavailableReason
            status.backupUnavailableReason = runModel.backupUnavailableReason
            status.onDeviceUnavailableReason = runModel.onDeviceUnavailableReason
        } else {
            status = await bestStatus()
        }
        runModel = status
        snapshot.model = status
        return status
    }

    /// The best tier's status (`BookAnalyzer.status(for:)`), or the pinned status.
    private func bestStatus() async -> ModelStatus {
        if let pinnedStatus { return pinnedStatus }
        return await analyzer.status()
    }

    /// Stops the run when `status` says its model should get no more requests.
    private func stopForModel(_ status: ModelStatus, mode: RunMode) -> Bool {
        guard let reason = Self.modelStop(status, mode: mode) else { return false }
        stop(reason.message, retryAfter: reason.retryAfter)
        return true
    }

    /// Returns the books of `books` that the ledger says a run checks at `upgradeTier`
    /// (`upgradeTier(_:mode:)`), and whether another book waits only for `tier`, the run's, to
    /// take requests again, such as an upgrade held back by Private Cloud Compute's daily limit.
    static func work(
        _ books: [CloudBook], accountID: String, ledger: WorkLedger, tier: ModelTier,
        upgradeTier: ModelTier
    ) async -> (queue: [CloudBook], upgradeWaits: Bool) {
        var queue: [CloudBook] = []
        var upgradeWaits = false
        for book in books {
            let workHash = CloudContract.workItemHash(accountID: accountID, book: book)
            func needsCheck(at tier: ModelTier) async -> Bool {
                await ledger.needsCheck(
                    recordName: recordName(accountID, book), workItemHash: workHash,
                    chosenCover: book.chosenCoverURL, runTier: tier)
            }
            if await needsCheck(at: upgradeTier) {
                queue.append(book)
            } else if !upgradeWaits, upgradeTier < tier {
                upgradeWaits = await needsCheck(at: tier)
            }
        }
        return (queue, upgradeWaits)
    }

    /// The tier a run passes to `WorkLedger.needsCheck`, so that a book whose last check ran at
    /// a lower tier is checked again at once: the run's tier, or `.local`, which queues no
    /// upgrade, when the run would stop for its model (`modelStop(_:mode:)`), such as at Private
    /// Cloud Compute's daily limit. That run queues only the books it would queue without tiers.
    /// With none, it still stops for its model when upgrades wait, so the charging task runs
    /// again at the reset. The daily limit also stops a run partway through upgrades.
    static func upgradeTier(_ status: ModelStatus, mode: RunMode) -> ModelTier {
        modelStop(status, mode: mode) == nil ? status.tier : .local
    }

    private func stop(_ message: String, retryAfter: Date?) {
        snapshot.phase = "Paused"
        snapshot.error = message
        snapshot.retryAfter = retryAfter
    }

    private func publish() { continuation.yield(.status(snapshot)) }

    /// Returns why the run's model should get no more requests in this run, or `nil` to continue.
    /// Only Private Cloud Compute has a daily quota.
    ///
    /// A run's tier becomes unavailable only during the run, because a run starts with the best
    /// available tier and local defaults are always available. That stop sets no retry date,
    /// so the next run, which picks the best tier again, starts as soon as it is scheduled.
    static func modelStop(_ status: ModelStatus, mode: RunMode) -> (
        message: String, retryAfter: Date?
    )? {
        guard status.isAvailable else {
            return (
                status.unavailableReason ?? CompanionError.modelUnavailable.localizedDescription,
                nil
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
            case .invalidCover, .coverTooLarge, .invalidDesign, .providerRefused: return .skipBook
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
