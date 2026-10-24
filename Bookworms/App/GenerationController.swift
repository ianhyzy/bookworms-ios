import Observation
import SwiftUI

#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif
#if os(macOS)
    import IOKit.ps
#endif

/// Runs spine generation on request, in the background on external power, and after a worklist
/// change.
///
/// **Generate now** runs in the app and asks iOS to keep it going in the background with a
/// continued-processing task. The charging task runs inside SwiftUI's background task, which
/// cancels it on expiration, as iOS expires it when the iPhone is unplugged. On the Mac it runs
/// while the Mac is idle and draws AC power, and a switch to battery power cancels it. A silent
/// push only schedules the charging task, because its 30-second window is too short for a
/// design. `SpineWorker` lets one run proceed at a time.
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
    /// Whether a user-started run is in progress, which **Stop** cancels.
    private(set) var isGenerating = false
    var generatesWhileCharging: Bool {
        didSet {
            UserDefaults.standard.set(generatesWhileCharging, forKey: Self.chargingKey)
            Task { await scheduleChargingTask() }
        }
    }

    @ObservationIgnored private let worker: SpineWorker
    @ObservationIgnored private var userRun: Task<Void, Never>?
    #if os(macOS)
        @ObservationIgnored private var backgroundActivity: NSBackgroundActivityScheduler?
        /// The idle run in progress, which a switch to battery power cancels.
        @ObservationIgnored private var idleRun: Task<Void, Never>?
        /// The notification of switches between AC and battery power, on the main run loop from
        /// the first idle run on.
        @ObservationIgnored private var powerSourceAlert: CFRunLoopSource?
    #else
        @ObservationIgnored private var continuedTask: BGContinuedProcessingTask?
    #endif
    @ObservationIgnored private var installedSubscription = false
    /// When this process last received a worklist push. A run that started earlier may have
    /// missed the new work, so its end keeps the push's immediate charging task.
    @ObservationIgnored private var worklistChangedAt: Date?

    /// Whether the last run may have left work, so the charging task is worth scheduling.
    private var workMayRemain: Bool {
        status.lastRunAt == nil || status.queue > 0 || status.retryAfter != nil
    }

    private init() {
        generatesWhileCharging =
            UserDefaults.standard.object(forKey: Self.chargingKey) as? Bool ?? true
        var lastRun = Self.savedLastRun ?? WorkerSnapshot()
        lastRun.dropExpiredStop()
        worker = SpineWorker(store: AppModel.shared.store, lastRun: lastRun)
        status = lastRun
        // One consumer applies updates in the order the worker made them.
        let updates = worker.updates
        Task {
            for await update in updates { self.handle(update) }
        }
    }

    /// Starts a user-requested run, unless one is already in progress. The run tries the backup
    /// model again even when its provider rejected these settings (`SpineDesigner.rejection`),
    /// because the reader may have fixed the cause outside the app, such as by adding credit or
    /// loading the model on a local server.
    func generateNow() {
        guard userRun == nil else { return }
        SpineDesigner.forgetRejection()
        startRun(redesigning: nil)
    }

    /// Starts a user-requested run, unless one is already in progress, that first designs
    /// `book`'s design source (`AppModel.designSource(for:)`) anew at the run's tier, even when
    /// its saved design is current. When `book` draws its series' look, the look then takes the
    /// new design's colors and type, so the whole series changes.
    func redesign(_ book: CloudBook) {
        let model = AppModel.shared
        startRun(
            redesigning: (model.designSource(for: book).id, model.lookDesigns[book.id] != nil))
    }

    private func startRun(redesigning: (bookID: Int, remakesLook: Bool)?) {
        guard userRun == nil else { return }
        isGenerating = true
        userRun = Task {
            await requestContinuedProcessing()
            let started = Date.now
            await worker.reconcile(mode: .foreground, redesigning: redesigning)
            #if !os(macOS)
                continuedTask?.setTaskCompleted(success: !Task.isCancelled)
                continuedTask = nil
            #endif
            userRun = nil
            isGenerating = false
            await scheduleChargingTask(hasNewWork: receivedWorklist(since: started))
        }
    }

    /// Cancels the user-started run after its current request.
    func stop() {
        userRun?.cancel()
    }

    /// Runs inside the charging-only background processing task.
    ///
    /// SwiftUI cancels the calling task when the system expires the background task, and the
    /// cancellation reaches the worker's requests and downloads.
    func runChargingTask() async {
        guard generatesWhileCharging else { return }
        let started = Date.now
        await worker.reconcile(mode: .background)
        await scheduleChargingTask(hasNewWork: receivedWorklist(since: started))
    }

    /// Schedules generation after the Apple TV publishes a new worklist. Generation waits for the
    /// charging task.
    func worklistChanged() async {
        worklistChangedAt = .now
        await scheduleChargingTask(hasNewWork: true)
    }

    private func receivedWorklist(since date: Date) -> Bool {
        (worklistChangedAt ?? .distantPast) >= date
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        // Without a continued-processing task, iOS suspends the run mid-download. Cancelling
        // it records no failure, unlike the errors a suspended download returns on resume. A
        // Mac app keeps running behind other windows, so its run continues.
        #if !os(macOS)
            if phase == .background, continuedTask == nil { userRun?.cancel() }
        #endif
        switch phase {
        case .background where generatesWhileCharging && workMayRemain:
            Task { await scheduleChargingTask() }
        case .active where status.model != nil:
            // Creates no model: the status refreshes only after the Spines tab or a run asked.
            Task { await worker.refreshModelStatus() }
        default:
            break
        }
    }

    /// Reads the designing model's availability and quota for the Spines tab.
    func refreshModelStatus() async {
        await worker.refreshModelStatus()
    }

    /// Forgets the backup model's remembered rejection, because the reader changed its settings,
    /// and the last run's message that a lower tier designs until then, in the Spines tab and in
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

    /// The earliest the next background run is worth starting: the quota reset or a service's
    /// retry date, or with no known work left, a day from now, which keeps the seven-day design
    /// rechecks and libraries without a worklist current. Nil means as soon as possible.
    private func nextRunDate(hasNewWork: Bool) -> Date? {
        if let retryAfter = status.retryAfter, retryAfter > .now { return retryAfter }
        if !hasNewWork && !workMayRemain { return .now.addingTimeInterval(24 * 60 * 60) }
        return nil
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
            guard generatesWhileCharging else { return }
            let activity = NSBackgroundActivityScheduler(identifier: Self.processingTaskID)
            let delay = nextRunDate(hasNewWork: hasNewWork)?.timeIntervalSinceNow ?? 0
            // The scheduler needs an interval; a minute stands in for "now".
            activity.interval = max(delay, 60)
            activity.tolerance = activity.interval / 4
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
            }
        }
    #else
        /// Asks iOS to run generation while the iPhone charges and is idle on a network, or cancels
        /// the request when the user turned the preference off.
        ///
        /// The run starts no earlier than `nextRunDate(hasNewWork:)`.
        func scheduleChargingTask(hasNewWork: Bool = false) async {
            guard generatesWhileCharging else {
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
                // Spines tab explains the latter.
                generationLog.info("Charging task not scheduled: \(error, privacy: .public)")
            }
        }

        /// Submits a request off the main thread, as `BGTaskScheduler` asks.
        @concurrent nonisolated private static func submit(_ request: sending BGTaskRequest)
            async throws
        {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
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
            #if !os(macOS)
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
            task.expirationHandler = { userRun.cancel() }
            report(status, to: task)
        }

        /// Shows the run's progress as the Spines tab words it: the count and time left, and the
        /// bar's fraction, which never moves backward (`WorkerSnapshot.fraction`).
        private func report(_ snapshot: WorkerSnapshot, to task: BGContinuedProcessingTask) {
            task.progress.totalUnitCount = 1_000
            task.progress.completedUnitCount = Int64(snapshot.fraction * 1_000)
            task.updateTitle(
                "Designing spines",
                subtitle: [snapshot.headline, snapshot.timeLeftText].compactMap { $0 }
                    .joined(separator: " · "))
        }
    #endif
}
