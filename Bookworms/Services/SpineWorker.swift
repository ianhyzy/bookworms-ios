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
    /// The model this run designs with: the best tier when the run first loaded the library, or
    /// the best one below the backup model after the backup rejected a request. `nil` between
    /// runs.
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

    /// Creates a worker that starts from `lastRun`, the saved outcome of the previous run.
    init(store: any SpineStore, lastRun: WorkerSnapshot = WorkerSnapshot()) {
        self.store = store
        snapshot = lastRun
        (updates, continuation) = AsyncStream.makeStream()
    }

    /// Reads and publishes the best model tier's availability and quota. A run in progress keeps
    /// showing its own tier, which it publishes after each book, and reads the best tier again
    /// when it ends.
    func refreshModelStatus() async {
        if runModel == nil { snapshot.model = await analyzer.status() }
        snapshot.dropExpiredStop()
        publish()
    }

    /// Designs the books that need it, until the queue is empty or a stop condition.
    ///
    /// With `redesigning`, the run first designs that book anew at its tier even when its saved
    /// design is current, as **Redesign spine** asks: it skips the ledger, the saved design, and
    /// series reuse. With `remakesLook`, the book's look group's saved look then takes
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
        runModel = nil
        refusals = RefusalStreak()
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
        redesign = nil
        runModel = nil
        // The best tier again, as the next run would pick it, such as below a backup model that
        // this run found rejected.
        snapshot.model = await analyzer.status()
        snapshot.isRunning = false
        snapshot.currentBook = nil
        snapshot.lastRunAt = Date()
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
            for book in queue {
                try Task.checkCancellation()
                let workHash = CloudContract.workItemHash(accountID: accountID, book: book)
                let recordName = Self.recordName(accountID, book)
                let redesigned = redesign?.bookID == book.id ? redesign : nil
                // After the backup model's lasting rejection moved the run to a lower tier
                // (`newDesign`), a book queued only to upgrade to the backup's tier is skipped
                // without downloading its cover. A rejection of one book's request leaves the
                // run's tier, so the other books still upgrade.
                if redesigned == nil, let tier = runModel?.tier, tier < upgradeTier,
                    !(await ledger.needsCheck(
                        recordName: recordName, workItemHash: workHash,
                        chosenCover: book.chosenCoverURL, runTier: tier))
                {
                    snapshot.queue -= 1
                    continue
                }
                snapshot.phase = "Designing spines"
                snapshot.currentBook = book
                publish()
                let start = ContinuousClock.now
                do {
                    let cover = try await covers.fetch(book.coverCandidates)
                    let outcome = try await design(
                        for: book, cover: cover, workHash: workHash, context: context,
                        forced: redesigned != nil, mode: mode)
                    if case .save(let made, let isNew) = outcome {
                        guard try await store.isStillCurrent(context, book: book) else {
                            return true
                        }
                        try await store.save(made, replacing: redesigned != nil)
                        continuation.yield(.saved(made))
                        bookDesigns[book.id] = made
                        checkedBooks.insert(book.id)
                        if isNew {
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
                    if case .save(let made, _) = outcome { awaitsFont = made.awaitsFont }
                    try await ledger.recordSuccess(
                        recordName: recordName, workItemHash: workHash, coverHash: cover.hash,
                        chosenCover: book.chosenCoverURL,
                        tier: runModel.map { max($0.tier, outcome.design.tier) },
                        awaitsFont: awaitsFont)
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
                    // A backup model's rejection, which needs the reader, stays in view.
                    if snapshot.error == nil {
                        snapshot.error =
                            "Some books could not be designed. Bookworms tries them again tomorrow."
                    }
                }
                if redesigned != nil { redesign = nil }
                snapshot.queue -= 1
                if stopForModel(await readModel(), mode: mode) { return false }
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

    /// What a run does with a book's design (`design(for:cover:workHash:context:forced:mode:)`).
    private enum Outcome {
        /// Leaves this design, iCloud's, in place.
        case keep(SpineDesignV1)
        /// Saves this design. `isNew` tells whether the run's tier made it from the cover rather
        /// than copying a saved design or look.
        case save(SpineDesignV1, isNew: Bool)

        var design: SpineDesignV1 {
            switch self {
            case .keep(let design), .save(let design, _): design
            }
        }
    }

    /// Returns the design to save for `book`, or the saved design to keep when iCloud already
    /// has this work at the run's tier or better, or a design whose colors the reader chose (see
    /// `SpineDesignV1.action(workItemHash:coverHash:readerChoseCover:runTier:drawsSeriesLook:)`).
    /// `forced` always makes a new design.
    ///
    /// The book whose design upgrades its group's look (`SeriesLookV1.upgradeSource(among:)`)
    /// is designed as if the group had no look, so a weaker tier's look gets a design from the
    /// run's tier. When that book's own saved design is kept, it upgrades the look with no
    /// request. A book draws its group's look only when the look's face letters its title and
    /// author, as the app draws it; otherwise its own design follows the tier rule.
    private func design(
        for book: CloudBook, cover: CoverImage, workHash: String, context: WorkContext,
        forced: Bool, mode: RunMode
    ) async throws -> Outcome {
        // Looked up even when forced, so `saveLook` knows whether the group has a look.
        let savedLook = try await seriesLook(for: book, accountID: context.accountID)
        let runTier = runModel?.tier ?? .local
        let upgradesLook =
            savedLook.map { $0.isUpgraded(at: runTier) && isUpgradeSource(book, of: $0) } ?? false
        let look = upgradesLook ? nil : savedLook
        if !forced {
            // A ledger miss is not proof: another device may have saved this work already.
            let saved = try await store.savedDesign(accountID: context.accountID, bookID: book.id)
            let readerChoseCover = await ledger.readerChoseCover(
                recordName: Self.recordName(context.accountID, book),
                chosenCover: book.chosenCoverURL)
            func action(drawsSeriesLook: Bool) -> SavedDesignAction {
                saved?
                    .action(
                        workItemHash: workHash, coverHash: cover.hash,
                        readerChoseCover: readerChoseCover, runTier: runTier,
                        drawsSeriesLook: drawsSeriesLook, upgradesSeriesLook: upgradesLook)
                    ?? .redesign
            }
            // The glyph check waits until the book's design would otherwise be redesigned, so
            // kept designs cost no font download.
            var savedAction = action(drawsSeriesLook: false)
            if savedAction == .redesign, let look, action(drawsSeriesLook: true) == .keep,
                try await analyzer.letters(book, with: look.design(bookID: look.sourceBookID))
            {
                savedAction = .keep
            }
            switch (savedAction, saved) {
            case (.keep, let saved?):
                if upgradesLook, saved.generatedColors == nil {
                    await saveLook(from: saved, for: book, replacing: false)
                }
                return .keep(saved)
            case (.save(let design), _): return .save(design, isNew: false)
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
            if let source,
                let reused = try await analyzer.seriesDesign(
                    from: source, book: book, accountID: context.accountID,
                    workItemHash: workHash, coverHash: cover.hash)
            {
                return .save(reused, isNew: false)
            }
        }
        return .save(
            try await newDesign(
                for: book, cover: cover, workHash: workHash, accountID: context.accountID,
                mode: mode),
            isNew: true)
    }

    /// Designs `book` at the run's tier.
    ///
    /// A lasting rejection by the backup model, such as a revoked key, an unknown model name, or
    /// an account without credit (`ProviderError.isLasting`), would repeat for every book. The
    /// app remembers it until the reader changes the backup model's settings
    /// (`SpineDesigner.rejection`), so this run and later ones design with the best tier below
    /// the backup, down to local defaults, and the Spines tab shows the rejection. When the tier
    /// found can take no request now, such as Private Cloud Compute at its daily limit, the
    /// rejection stops the run.
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
        // Any outcome but another refusal ends the streak.
        var streak = refusals
        refusals = RefusalStreak()
        do {
            return try await design(using: model)
        } catch CompanionError.providerRejected(let reason) {
            return try await design(
                using: try await fallBack(from: model, rejection: reason, mode: mode))
        } catch CompanionError.providerRefused(let reason) {
            if streak.isLasting(after: reason) {
                _ = try await fallBack(from: model, rejection: reason, mode: mode)
            }
            refusals = streak
            throw CompanionError.providerRefused(reason)
        }
    }

    /// Remembers `rejection` as the backup model's lasting rejection of `model`'s settings
    /// (`SpineDesigner.rememberRejection(_:)`) and moves the run to the best tier below it, which
    /// it returns. Throws `CompanionError.providerRejected`, which stops the run, when that tier
    /// can take no request now.
    private func fallBack(from model: ModelStatus, rejection: String, mode: RunMode) async throws
        -> ModelStatus
    {
        model.designer.rememberRejection(rejection)
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
        let tier =
            switch next.tier {
            case .privateCloudCompute: "Private Cloud Compute"
            case .backup: next.designerName
            case .onDevice: "Apple's on-device model"
            case .local: "local defaults"
            }
        return "\(sentence) Until you change the backup model, Bookworms uses \(tier)."
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
    /// is another book with a usable saved design from this generator, made for that book as it
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
            if let design = bookDesigns[mate.id],
                design.generatorVersion == CloudContract.generatorVersion,
                SeriesDesigns.isUsableSource(design), SeriesDesigns.isCurrent(design, for: mate)
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
        if let runModel {
            status = await analyzer.status(of: runModel.tier, designer: runModel.designer)
            status.pccUnavailableReason = runModel.pccUnavailableReason
            status.backupUnavailableReason = runModel.backupUnavailableReason
            status.onDeviceUnavailableReason = runModel.onDeviceUnavailableReason
        } else {
            status = await analyzer.status()
        }
        runModel = status
        snapshot.model = status
        return status
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
