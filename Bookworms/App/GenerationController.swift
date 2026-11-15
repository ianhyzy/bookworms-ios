import Observation
import SwiftUI

#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif
#if os(macOS)
    import IOKit.ps
#endif

/// Runs spine generation on request and in the background on external power, and schedules the
/// background run when new work arrives: an Apple TV worklist or a change to this device's
/// library.
///
/// **Generate now** runs in the app and asks iOS to keep it going in the background with a
/// continued-processing task. A run the reader started that designs books and then pauses until
/// a retry date starts again in the app at that date (`resumeDate(after:now:)`). The charging
/// task runs inside SwiftUI's background task, which cancels it on expiration, as iOS expires it
/// when the iPhone is unplugged. On the Mac it runs while the Mac is idle and draws AC power, and
/// a switch to battery power cancels it. A silent push only schedules the charging task, because
/// its 30-second window is too short for a design. `SpineWorker` lets one run proceed at a time.
@MainActor
@Observable
final class GenerationController {
    static let shared = GenerationController()
    static let processingTaskID = "gay.ian.Bookworms.iOS.spines"
    /// Continued-processing requests add a unique suffix; Info.plist permits the wildcard.
    static let continuedTaskPrefix = "gay.ian.Bookworms.iOS.generate."
    private static let chargingKey = "GeneratesWhileCharging"
    private static let lastRunKey = "LastGenerationRun"

    /// The current run's progress, or the last run's saved outcome, because the charging task
    /// runs unseen.
    private(set) var status: WorkerSnapshot
    /// Whether a user-started run is in progress.
    private(set) var isGenerating = false
    /// Whether **Stop** has a run to cancel (`stop()`): a user-started run, or on the Mac the
    /// idle run in progress. iOS runs its charging task unseen, so only a user-started run stops.
    var canStop: Bool {
        #if os(macOS)
            isGenerating || status.isRunning
        #else
            isGenerating
        #endif
    }
    var generatesWhileCharging: Bool {
        didSet {
            UserDefaults.standard.set(generatesWhileCharging, forKey: Self.chargingKey)
            Task { await scheduleChargingTask() }
        }
    }

    /// Whether each provider has a saved API key that its requests can carry, as this device's
    /// Keychain and the reader's consent last said (`readSavedKey(of:)`), so the design model's
    /// settings show **Saved** in their first frame without a Keychain read on the main actor.
    /// It holds presence flags, never keys. Launch reads every provider's flag.
    private(set) var savedKeys = SavedKeys()

    @ObservationIgnored private let worker: SpineWorker
    @ObservationIgnored private var userRun: Task<Void, Never>?
    /// When a paused user-started run starts again in the app (`resumeDate(after:now:)`), until
    /// a run starts.
    @ObservationIgnored private var resumeDate: Date?
    #if os(macOS)
        @ObservationIgnored private var backgroundActivity: NSBackgroundActivityScheduler?
        /// The idle run in progress, which a switch to battery power cancels.
        @ObservationIgnored private var idleRun: Task<Void, Never>?
        /// When the reader last stopped an idle run (`stop()`), until a user-started run. It lasts
        /// only as long as this process; a relaunch schedules idle runs as before.
        @ObservationIgnored private var idleRunStoppedAt: Date?
        /// The notification of switches between AC and battery power, on the main run loop from
        /// the first idle run on.
        @ObservationIgnored private var powerSourceAlert: CFRunLoopSource?
    #else
        @ObservationIgnored private var continuedTask: BGContinuedProcessingTask?
        /// What the continued task's progress has shown of the run (`report(_:to:)`).
        @ObservationIgnored private var taskProgress = TaskProgress()
        /// Reports the run's progress on a schedule while a book is in flight (`attach(_:)`).
        @ObservationIgnored private var progressTicks: Task<Void, Never>?
    #endif
    @ObservationIgnored private var installedSubscription = false
    /// When new work last arrived in this process (`workChanged()`). A run that started earlier
    /// may have missed it, so its end keeps the immediate charging task.
    @ObservationIgnored private var newWorkAt: Date?

    /// Whether the last run may have left work, so the charging task should start as soon as it
    /// can.
    private var workMayRemain: Bool { Self.workMayRemain(after: status) }

    /// A cancelled run may have left work even with an empty queue, because each run counts its
    /// queue afresh and iOS often cancels the charging task, when the reader picks up the
    /// iPhone, before the run has counted it.
    nonisolated private static func workMayRemain(after status: WorkerSnapshot) -> Bool {
        status.lastRunAt == nil || status.queue > 0 || status.retryAfter != nil
            || status.phase == WorkerSnapshot.stoppedPhase
    }

    private init() {
        // A launch argument, such as `-GeneratesWhileCharging NO`, stores a string, which
        // `bool(forKey:)` reads as a Boolean.
        let defaults = UserDefaults.standard
        generatesWhileCharging =
            defaults.object(forKey: Self.chargingKey) == nil
            || defaults.bool(forKey: Self.chargingKey)
        var lastRun = Self.savedLastRun ?? WorkerSnapshot()
        lastRun.dropExpiredStop()
        worker = SpineWorker(store: AppModel.shared.store, lastRun: lastRun)
        status = lastRun
        // One consumer applies updates in the order the worker made them.
        let updates = worker.updates
        Task {
            for await update in updates { self.handle(update) }
        }
        #if os(iOS)
            watchBatteryState()
        #else
            // A pause saved before a relaunch resumes on AC power too.
            if lastRun.waitsForPower {
                _ = watchPowerSource()
                powerSourceChanged()
            }
        #endif
        Task {
            for provider in SpineDesigner.Provider.allCases where provider != .apple {
                await self.readSavedKey(of: provider)
            }
        }
    }

    /// Starts a user-requested run, unless one is already in progress. The run tries the backup
    /// model again even when its provider rejected these settings (`SpineDesigner.rejection`),
    /// because the reader may have fixed the cause outside the app, such as by adding credit or
    /// loading the model on a local server.
    func generateNow() {
        guard userRun == nil, !AppModel.shared.isExample else { return }
        SpineDesigner.forgetRejection()
        startRun(redesigning: nil)
    }

    /// Starts a user-requested run, unless one is already in progress, that first designs
    /// `book`'s design source (`AppModel.designSource(for:)`) anew at the run's tier, even when
    /// its saved design is current. When `book` draws its series' look, the look then takes the
    /// new design's colors and type, so the whole series changes. Like `generateNow()`, it tries
    /// the backup model again even when its provider rejected these settings.
    func redesign(_ book: CloudBook) {
        guard userRun == nil else { return }
        SpineDesigner.forgetRejection()
        let model = AppModel.shared
        startRun(
            redesigning: (model.designSource(for: book).id, model.lookDesigns[book.id] != nil))
    }

    private func startRun(redesigning: (bookID: Int, remakesLook: Bool)?) {
        // The example profile is read-only, and a run would design this device's own library.
        guard userRun == nil, !AppModel.shared.isExample else { return }
        resumeDate = nil
        isGenerating = true
        #if os(macOS)
            idleRunStoppedAt = nil
        #endif
        userRun = Task {
            await requestContinuedProcessing()
            let started = Date.now
            await worker.reconcile(mode: .foreground, redesigning: redesigning)
            #if !os(macOS)
                finishContinuedTask()
            #endif
            userRun = nil
            isGenerating = false
            waitToResume()
            await scheduleChargingTask(hasNewWork: receivedWork(since: started))
        }
    }

    /// When a user-started run that left `status` starts again in the app: at its retry date,
    /// such as a provider's rate limit or the quota reset, and no sooner than a minute from
    /// `now`, so a retry date that has already passed, such as a provider's `Retry-After` of
    /// zero, doesn't start run after run. `nil` for a run that left no retry date, for one that
    /// waits for power, which resumes when plugged in (`powerConnected()`), and for one that
    /// designed no book: its model may be down, so the next background run tries again, and
    /// the resumed runs end once one of them designs nothing.
    nonisolated static func resumeDate(after status: WorkerSnapshot, now: Date = .now) -> Date? {
        guard let retryAfter = status.retryAfter, !status.waitsForPower, status.designed > 0
        else { return nil }
        return max(retryAfter, now.addingTimeInterval(60))
    }

    /// Waits for the resume date of the user-started run that just ended, if it has one. iOS
    /// suspends the wait with the app, so the app's return to the foreground also checks the
    /// date (`scenePhaseChanged(to:)`). The date lasts only as long as this process: after a
    /// relaunch, the charging task or **Generate now** continues the work.
    private func waitToResume() {
        resumeDate = Self.resumeDate(after: status)
        guard let date = resumeDate else { return }
        Task {
            // `Date` can run behind the sleep's clock, so the wait ends only once the date has
            // passed.
            while date > .now {
                try? await Task.sleep(for: .seconds(date.timeIntervalSinceNow))
            }
            resumeIfDue()
        }
    }

    /// Starts the paused user-started run again once its resume date has passed. A wait that a
    /// newer run made stale finds no date, or a later one, and starts nothing.
    private func resumeIfDue() {
        guard let resumeDate, resumeDate <= .now else { return }
        #if os(iOS)
            // A run that starts in the background is suspended mid-download, so it waits for
            // the app's return to the foreground.
            guard UIApplication.shared.applicationState == .active else { return }
        #endif
        restartRun()
    }

    /// Starts a paused run again as **Generate now** does, without a notification, unless a run
    /// is in progress, which does the paused run's work.
    private func restartRun() {
        guard !status.isRunning, userRun == nil else { return }
        startRun(redesigning: nil)
    }

    /// Cancels the user-started run, and on the Mac the idle run in progress, which a **Generate
    /// now** run waits behind. The books in flight stop with the run, including a cover's text
    /// read that hangs (`CoverTextReader`). A stopped idle run starts again no sooner than a day
    /// later, unless the reader starts a run (`nextRunDate(after:hasNewWork:stoppedAt:now:)`).
    func stop() {
        userRun?.cancel()
        #if os(macOS)
            if let idleRun {
                idleRunStoppedAt = .now
                idleRun.cancel()
            }
        #endif
    }

    /// Resumes a run that paused for the system's battery rate limit once the device draws
    /// external power, which lifts the limit.
    private func powerConnected() {
        guard status.waitsForPower else { return }
        restartRun()
    }

    #if os(iOS)
        /// Watches the battery state so that plugging in resumes a run paused for the battery
        /// rate limit. iOS delivers the change only while the app runs, so `scenePhaseChanged`
        /// also checks the power when the app becomes active; a suspended app resumes in the
        /// charging task at the pause's retry date.
        private func watchBatteryState() {
            UIDevice.current.isBatteryMonitoringEnabled = true
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    guard Self.isOnExternalPower, UIApplication.shared.applicationState == .active
                    else { return }
                    GenerationController.shared.powerConnected()
                }
            }
        }

        private static var isOnExternalPower: Bool {
            [.charging, .full].contains(UIDevice.current.batteryState)
        }
    #endif

    /// Runs inside the charging-only background processing task.
    ///
    /// SwiftUI cancels the calling task when the system expires the background task, and the
    /// cancellation reaches the worker's requests and downloads. It does nothing while a
    /// user-started run is in progress, which designs the same books and schedules the charging
    /// task when it ends, or while the example profile shows, as `startRun(redesigning:)` does;
    /// leaving the example schedules it again (`AppModel.leaveExample()`). It continues a
    /// paused user-started run's work, so that run no longer starts again in the app.
    func runChargingTask() async {
        guard generatesWhileCharging, userRun == nil, !AppModel.shared.isExample else { return }
        resumeDate = nil
        let started = Date.now
        await worker.reconcile(mode: .background)
        await scheduleChargingTask(hasNewWork: receivedWork(since: started))
    }

    /// Schedules generation after the Apple TV publishes a new worklist. In the foreground, it
    /// also checks the Hardcover accounts in iCloud, so a worklist of another account asks the
    /// reader at once.
    func worklistChanged() async {
        await workChanged()
        #if os(macOS)
            let isForeground = NSApplication.shared.isActive
        #else
            let isForeground = UIApplication.shared.applicationState == .active
        #endif
        if isForeground { await AppModel.shared.checkICloudAccounts() }
    }

    /// Schedules generation for work that may be new: a worklist from the Apple TV, or this
    /// device's library after a Hardcover sign-in, sync, or sign-out, an adopted iCloud copy, or
    /// the example profile (`AppModel.schedulesGeneration`). Generation waits for the charging
    /// task, which starts without the wait a finished run leaves
    /// (`nextRunDate(after:hasNewWork:stoppedAt:now:)`).
    func workChanged() async {
        newWorkAt = .now
        await scheduleChargingTask(hasNewWork: true)
    }

    private func receivedWork(since date: Date) -> Bool {
        (newWorkAt ?? .distantPast) >= date
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        // Without a continued-processing task, iOS suspends the run mid-download. Cancelling
        // it records no failure, unlike the errors a suspended download returns on resume. A
        // Mac app keeps running behind other windows, so its run continues.
        #if !os(macOS)
            if phase == .background, continuedTask == nil { userRun?.cancel() }
            // A device plugged in while the app was suspended or closed posts no change once
            // it is active.
            if phase == .active, Self.isOnExternalPower { powerConnected() }
            // A resume date that passed while the app was suspended starts its run now.
            if phase == .active { resumeIfDue() }
        #endif
        switch phase {
        case .background where generatesWhileCharging:
            Task {
                if await needsChargingTask { await scheduleChargingTask() }
            }
        case .active where status.model != nil:
            // Creates no model: the status refreshes only after the Spines tab or a run asked.
            Task { await worker.refreshModelStatus() }
        default:
            break
        }
    }

    /// Whether leaving the foreground should schedule the charging task: the last run may have
    /// left work, or iOS holds no request for it, as after a submission that failed while
    /// Background App Refresh was off. Otherwise the pending request stays, because one
    /// scheduled now would replace a sooner request for new work. The Mac's idle activity
    /// stays scheduled from launch on.
    private var needsChargingTask: Bool {
        get async {
            if workMayRemain { return true }
            #if os(macOS)
                return false
            #else
                return await !Self.pendingTaskIDs().contains(Self.processingTaskID)
            #endif
        }
    }

    /// Reads the designing model's availability and quota for the Spines tab.
    func refreshModelStatus() async {
        await worker.refreshModelStatus()
    }

    /// Forgets the backup model's remembered rejection, because the reader changed its settings,
    /// and the last run's message that another tier designs until then, in the Spines tab and in
    /// the saved outcome. Then reads the model status again.
    func backupSettingsChanged() async {
        if let rejection = SpineDesigner.forgetRejection() {
            await worker.clearMessage(about: rejection)
            if var lastRun = Self.savedLastRun, lastRun.error?.contains(rejection) == true {
                lastRun.error = nil
                Self.savedLastRun = lastRun
            }
        }
        await worker.refreshModelStatus()
    }

    /// Reads whether `provider` has a saved API key into `savedKeys`, off the main actor. The key
    /// of a provider the reader hasn't allowed on this device counts as not saved
    /// (`SpineDesigner.Provider.savedKey()`). Returns whether the Keychain holds such a key, so
    /// the design model's settings can ask the reader about it.
    @discardableResult
    func readSavedKey(of provider: SpineDesigner.Provider) async -> Bool {
        let read = savedKeys.startRead(of: provider)
        let saved = await Self.keychain { provider.savedKey() }
        savedKeys.finish(read, found: saved == .usable)
        return saved == .awaitsConsent
    }

    /// Saves `key` as `provider`'s API key, off the main actor. Throws when the Keychain
    /// refuses it.
    func saveKey(_ key: String, for provider: SpineDesigner.Provider) async throws {
        try await Self.keychain { try provider.key.save(key) }
        savedKeys.changed(provider, hasKey: true)
    }

    /// Removes `provider`'s API key, off the main actor. A key the Keychain fails to delete
    /// stays saved.
    func removeKey(of provider: SpineDesigner.Provider) async {
        let kept = await Self.keychain {
            provider.key.delete()
            return provider.savedKey() == .usable
        }
        savedKeys.changed(provider, hasKey: kept)
    }

    /// Runs a Keychain call off the main actor, because the Keychain can block, such as while a
    /// Mac asks the reader for access.
    @concurrent nonisolated private static func keychain<T: Sendable>(
        _ call: @Sendable () throws -> T
    ) async rethrows -> T {
        try call()
    }

    /// The last run's outcome as saved in `UserDefaults`, or `nil` before the first run.
    private static var savedLastRun: WorkerSnapshot? {
        get {
            UserDefaults.standard.data(forKey: lastRunKey)
                .flatMap { try? JSONDecoder().decode(WorkerSnapshot.self, from: $0) }
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: lastRunKey)
        }
    }

    /// Subscribes to Apple TV worklist changes once per launch.
    func installWorklistSubscription() async {
        guard !installedSubscription else { return }
        installedSubscription = true
        do {
            try await AppModel.shared.store.installWorklistSubscription()
        } catch {
            // The charging task still checks the library daily.
            generationLog.error("Worklist subscription failed: \(error, privacy: .public)")
        }
    }

    private func nextRunDate(hasNewWork: Bool) -> Date? {
        #if os(macOS)
            Self.nextRunDate(after: status, hasNewWork: hasNewWork, stoppedAt: idleRunStoppedAt)
        #else
            Self.nextRunDate(after: status, hasNewWork: hasNewWork)
        #endif
    }

    /// The earliest the next background run is worth starting after a run that left `status`:
    /// the quota reset or a service's retry date; after a stop without a retry date, such as a
    /// charging run waiting for Wi-Fi or one offline before it loaded its queue,
    /// `busyRetryDelay` after the stop, so the charging task doesn't start again at once and
    /// load the library each time; after a cancelled run, as soon as possible
    /// (`workMayRemain(after:)`); and with no known work left, a day after the run, which keeps
    /// the seven-day design rechecks and libraries without a worklist current. The last
    /// two waits count from the run's end, so scheduling again doesn't move them later, and new
    /// work skips them. A reader's stop of an idle run at `stoppedAt` waits a day from the
    /// stop, even with new work, since **Stop** ends background designing. Nil means as soon as
    /// possible, which a wait that has passed also returns.
    nonisolated static func nextRunDate(
        after status: WorkerSnapshot, hasNewWork: Bool, stoppedAt: Date? = nil, now: Date = .now
    ) -> Date? {
        if let resume = stoppedAt?.addingTimeInterval(24 * 60 * 60), resume > now {
            return max(resume, status.retryAfter ?? resume)
        }
        if let retryAfter = status.retryAfter, retryAfter > now { return retryAfter }
        guard !hasNewWork else { return nil }
        let wait: TimeInterval
        if status.phase == WorkerSnapshot.pausedPhase, status.retryAfter == nil {
            // `SpineWorker` pauses a run that stops; a retry date that has passed, such as a
            // quota reset, ends the stop.
            wait = SpineWorker.busyRetryDelay
        } else if !workMayRemain(after: status) {
            // A finished run's message, such as books it skipped, keeps the day's wait.
            wait = 24 * 60 * 60
        } else {
            return nil
        }
        let date = (status.lastRunAt ?? now).addingTimeInterval(wait)
        return date > now ? date : nil
    }

    /// The power source a Mac reports, or `unknown` when the read fails.
    enum PowerSource { case ac, battery, unknown }

    /// Whether an idle Mac run may start or keep going. It needs AC power and a watch on the
    /// power source (`watching`) that stops it on a switch to battery power. An unknown power
    /// source counts as battery power, so a failed read or watch defers a run that hasn't
    /// started, and a failed read stops one under way.
    nonisolated static func idleRunMayProceed(power: PowerSource, watching: Bool) -> Bool {
        power == .ac && watching
    }

    #if os(macOS)
        /// Asks macOS to run generation when the Mac is idle, or cancels the request when the
        /// user turned the preference off. The Mac app keeps running with no window open, so
        /// the activity fires while it stays in the menu bar. The run starts only on AC power
        /// (`runIdleActivity()`).
        func scheduleChargingTask(hasNewWork: Bool = false) async {
            backgroundActivity?.invalidate()
            backgroundActivity = nil
            guard generatesWhileCharging, !SpineBatch.isRequested else { return }
            let activity = NSBackgroundActivityScheduler(identifier: Self.processingTaskID)
            let delay = nextRunDate(hasNewWork: hasNewWork)?.timeIntervalSinceNow ?? 0
            // The scheduler needs an interval; a minute stands in for "now". It fires up to its
            // tolerance before or after the interval, so the interval adds the tolerance, and a
            // run never starts before `nextRunDate(hasNewWork:)`.
            let earliest = max(delay, 60)
            activity.tolerance = earliest / 4
            activity.interval = earliest + activity.tolerance
            activity.qualityOfService = .utility
            activity.schedule { completion in
                Task { @MainActor in
                    let result = await GenerationController.shared.runIdleActivity()
                    completion(result)
                }
            }
            backgroundActivity = activity
        }

        /// Runs the charging task while this Mac draws AC power and watches for a switch to
        /// battery power, as iOS runs it only on external power, and otherwise asks macOS to try
        /// again later (`idleRunMayProceed(power:watching:)`). A switch to battery power during
        /// the run cancels it (`powerSourceChanged()`); a **Generate now** run keeps going.
        private func runIdleActivity() async -> NSBackgroundActivityScheduler.Result {
            // An idle run in progress does the work, and schedules the next activity when it ends.
            guard idleRun == nil else { return .finished }
            // Watching first means a switch after the read still reaches `powerSourceChanged()`.
            let watching = watchPowerSource()
            guard Self.idleRunMayProceed(power: Self.powerSource, watching: watching) else {
                return .deferred
            }
            let run = Task { await runChargingTask() }
            idleRun = run
            await run.value
            idleRun = nil
            return .finished
        }

        /// The power source this Mac draws from. A Mac without a battery, such as a Mac mini,
        /// reports AC power.
        private static var powerSource: PowerSource {
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
            else { return .unknown }
            return source as String == kIOPMACPowerKey ? .ac : .battery
        }

        /// Starts watching for switches between AC and battery power, once, and returns whether
        /// the notification is installed. A failed setup tries again at the next idle run. The
        /// notification fires only on those switches, not as the battery's charge changes, and
        /// arrives on the main run loop.
        private func watchPowerSource() -> Bool {
            guard powerSourceAlert == nil else { return true }
            guard
                let alert = IOPSCreateLimitedPowerNotification(
                    { _ in
                        MainActor.assumeIsolated {
                            GenerationController.shared.powerSourceChanged()
                        }
                    }, nil)?
                    .takeRetainedValue()
            else {
                generationLog.error("Power source notification failed; idle runs wait")
                return false
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), alert, .commonModes)
            powerSourceAlert = alert
            return true
        }

        /// Stops the idle run in progress when this Mac switches to battery power or its power
        /// source can't be read.
        private func powerSourceChanged() {
            if !Self.idleRunMayProceed(power: Self.powerSource, watching: true) {
                idleRun?.cancel()
            } else {
                powerConnected()
            }
        }
    #else
        /// Asks iOS to run generation while the iPhone charges and is idle on a network, or cancels
        /// the request when the user turned the preference off.
        ///
        /// The run starts no earlier than `nextRunDate(hasNewWork:)`.
        func scheduleChargingTask(hasNewWork: Bool = false) async {
            guard generatesWhileCharging, !SpineBatch.isRequested else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskID)
                return
            }
            let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = true
            request.earliestBeginDate = nextRunDate(hasNewWork: hasNewWork)
            do {
                try await Self.submit(request)
            } catch {
                // Submission fails in the Simulator and when Background App Refresh is off; the
                // Spines tab explains the latter, and leaving the app submits again
                // (`needsChargingTask`).
                generationLog.info("Charging task not scheduled: \(error, privacy: .public)")
            }
        }

        /// Submits a request off the main thread, as `BGTaskScheduler` asks.
        @concurrent nonisolated private static func submit(_ request: sending BGTaskRequest)
            async throws
        {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        }

        /// The identifiers of the task requests that iOS holds for this app.
        @concurrent nonisolated private static func pendingTaskIDs() async -> [String] {
            await BGTaskScheduler.shared.pendingTaskRequests().map(\.identifier)
        }
    #endif

    private func handle(_ update: WorkerUpdate) {
        switch update {
        case .status(let snapshot):
            // A new finish date marks the end of a run, which is the outcome worth saving.
            if snapshot.lastRunAt != status.lastRunAt {
                Self.savedLastRun = snapshot
                // Shows books the Apple TV added while the app was suspended.
                Task { await AppModel.shared.reloadIfStale() }
            }
            status = snapshot
            #if os(macOS)
                // A run paused for the battery rate limit resumes on AC power (`powerConnected()`).
                if snapshot.waitsForPower { _ = watchPowerSource() }
            #else
                if let continuedTask { report(snapshot, to: continuedTask) }
            #endif
        case .saved(let design):
            AppModel.shared.apply(design)
        case .savedLook(let look):
            AppModel.shared.apply([look])
        }
    }

    #if os(macOS)
        /// Does nothing on the Mac, which keeps the run going without a continued-processing
        /// task and has none.
        private func requestContinuedProcessing() async {}
    #else
        /// Asks iOS to continue the user's run in the background. When the request fails, as in the
        /// Simulator, the run continues while the app stays in the foreground.
        private func requestContinuedProcessing() async {
            // iOS rejects a registration for the Info.plist wildcard itself, and submitting an
            // unregistered identifier raises an exception, so each run registers its own identifier.
            // Continued-processing handlers may register after launch. The main queue lets the
            // handler attach the task without crossing actors.
            let identifier = Self.continuedTaskPrefix + UUID().uuidString
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier, using: .main
            ) { task in
                MainActor.assumeIsolated { GenerationController.shared.attach(task) }
            }
            guard registered else {
                generationLog.info("Continued processing registration was rejected")
                return
            }
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier, title: "Designing spines", subtitle: "Starting")
            // Run now or not at all: the foreground run starts either way.
            request.strategy = .fail
            do {
                try await Self.submit(request)
            } catch {
                generationLog.info("Continued processing unavailable: \(error, privacy: .public)")
            }
        }

        /// Ties a launched continued-processing task to the user's run: progress follows the run,
        /// and expiration cancels it.
        private func attach(_ task: BGTask) {
            guard let task = task as? BGContinuedProcessingTask, let userRun else {
                task.setTaskCompleted(success: true)
                return
            }
            continuedTask = task
            let expiring = ObjectIdentifier(task)
            task.expirationHandler = {
                userRun.cancel()
                Task { @MainActor in GenerationController.shared.continuedTaskExpired(expiring) }
            }
            taskProgress = TaskProgress()
            report(status, to: task)
            progressTicks?.cancel()
            progressTicks = Task {
                while true {
                    try? await Task.sleep(for: TaskProgress.tickInterval)
                    guard !Task.isCancelled, let continuedTask else { return }
                    report(status, to: continuedTask)
                }
            }
        }

        /// Tells iOS that the run's task is over. No ending is a failure to report: a run that
        /// the reader stopped, or that iOS interrupted, keeps its finished books, and a later
        /// run continues it. The Spines tab shows the books that failed and why a run paused.
        private func finishContinuedTask() {
            continuedTask?.setTaskCompleted(success: true)
            continuedTask = nil
            progressTicks?.cancel()
        }

        /// Ends the task that iOS expired, and saves the run as stopped, at once. iOS may
        /// suspend the app before the cancelled run unwinds, as it did with a model request
        /// that had no answer, so neither can wait for the run's own ending. A run that does
        /// unwind saves its own outcome over this one (`handle(_:)`).
        private func continuedTaskExpired(_ expired: ObjectIdentifier) {
            // The run may have ended and completed the task before this ran.
            guard continuedTask.map(ObjectIdentifier.init) == expired else { return }
            generationLog.info("iOS ended the continued-processing task; the run stops")
            if status.isRunning {
                Self.savedLastRun = status.ended(at: .now, phase: WorkerSnapshot.stoppedPhase)
            }
            finishContinuedTask()
        }

        /// Shows the run's progress as the Spines tab words it, the count and time left, with
        /// the bar's fraction and an estimate of the book in flight (`TaskProgress`). A status
        /// that isn't running is the last run's outcome, which a new task doesn't show.
        private func report(_ snapshot: WorkerSnapshot, to task: BGContinuedProcessingTask) {
            guard snapshot.isRunning else { return }
            task.progress.totalUnitCount = TaskProgress.total
            task.progress.completedUnitCount = taskProgress.units(for: snapshot, now: .now)
            task.updateTitle(
                "Designing spines",
                subtitle: [snapshot.headline, snapshot.timeLeftText].compactMap { $0 }
                    .joined(separator: " · "))
        }
    #endif
}

/// The progress that a run reports to its continued-processing task.
///
/// iOS ends a continued-processing task whose progress stops changing for some tens of seconds,
/// once the app has left the screen. The run's own bar moves only when a book finishes
/// (`WorkerSnapshot.fraction`), and one book can take longer than that while a model answers.
/// So while a book is in flight, the reported progress also advances with the time since the
/// bar last moved or the book began, ever more slowly, toward most of the share that the book
/// adds when it finishes (`WorkerSnapshot.bookShare`). Within one run, the reported progress
/// never moves backward. Another run's status, such as a charging run's that a **Generate now**
/// run waits behind, starts the count again.
struct TaskProgress {
    /// The task's total unit count, fine enough that a tick moves the count for several minutes
    /// into one book of a library of thousands.
    static let total: Int64 = 1_000_000
    /// How often a run reports while nothing finishes.
    static let tickInterval = Duration.seconds(5)
    /// The time, in seconds, in which a book's estimate covers about two thirds of its limit:
    /// about as long as a slow book takes.
    static let slowBook: TimeInterval = 300
    /// The most of a book's share that its estimate takes, so a finished book still moves it.
    static let estimateLimit = 0.9

    private var reported: Int64 = 0
    /// The run the count belongs to, by its start.
    private var run: Date?
    /// What the estimate's time counts from: the bar's fraction and the book in flight when
    /// either last changed, and when that was.
    private var mark: (fraction: Double, book: Int?, at: Date)?

    /// The completed units to report for `snapshot` at `now`.
    mutating func units(for snapshot: WorkerSnapshot, now: Date) -> Int64 {
        if run != snapshot.startedAt {
            run = snapshot.startedAt
            reported = 0
            mark = nil
        }
        let fraction = snapshot.fraction
        let book = snapshot.designingBook?.id
        if mark?.fraction != fraction || mark?.book != book { mark = (fraction, book, now) }
        var estimate = fraction
        if book != nil, let mark {
            let elapsed = max(0, now.timeIntervalSince(mark.at))
            estimate +=
                snapshot.bookShare * Self.estimateLimit * (1 - exp(-elapsed / Self.slowBook))
        }
        reported = max(reported, Int64(estimate * Double(Self.total)))
        return reported
    }
}

/// Whether each provider has a saved API key (`GenerationController.savedKeys`); a provider it
/// lacks hasn't been read. A read's answer applies only when no save or removal of that
/// provider's key finished while the read ran, so a stale read never undoes a newer change.
struct SavedKeys {
    /// A Keychain read in progress (`startRead(of:)`).
    struct Read {
        fileprivate let provider: SpineDesigner.Provider
        fileprivate let changes: Int
    }

    private var flags: [SpineDesigner.Provider: Bool] = [:]
    /// How many saves and removals finished, by provider.
    private var changes: [SpineDesigner.Provider: Int] = [:]

    subscript(provider: SpineDesigner.Provider) -> Bool? { flags[provider] }

    func startRead(of provider: SpineDesigner.Provider) -> Read {
        Read(provider: provider, changes: changes[provider, default: 0])
    }

    /// Records what `read` found, unless a save or removal finished since it started.
    mutating func finish(_ read: Read, found: Bool) {
        guard changes[read.provider, default: 0] == read.changes else { return }
        flags[read.provider] = found
    }

    /// Records a finished save or removal.
    mutating func changed(_ provider: SpineDesigner.Provider, hasKey: Bool) {
        flags[provider] = hasKey
        changes[provider, default: 0] += 1
    }
}
