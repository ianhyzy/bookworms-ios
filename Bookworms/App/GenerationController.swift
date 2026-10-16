import Observation
import SwiftUI

#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif

/// Runs spine generation on request, while charging, and after a worklist change.
///
/// **Generate now** runs in the app and asks iOS to keep it going in the background with a
/// continued-processing task. The charging task runs inside SwiftUI's background task, which
/// cancels it on expiration. A silent push only schedules the charging task, because its
/// 30-second window is too short for a design. `SpineWorker` lets one run proceed at a time.
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
        var lastRun =
            UserDefaults.standard.data(forKey: Self.lastRunKey)
            .flatMap { try? JSONDecoder().decode(WorkerSnapshot.self, from: $0) }
            ?? WorkerSnapshot()
        lastRun.dropExpiredStop()
        worker = SpineWorker(store: AppModel.shared.store, lastRun: lastRun)
        status = lastRun
        // One consumer applies updates in the order the worker made them.
        let updates = worker.updates
        Task {
            for await update in updates { self.handle(update) }
        }
    }

    /// Starts a user-requested run, unless one is already in progress.
    func generateNow() {
        guard userRun == nil else { return }
        isGenerating = true
        userRun = Task {
            await requestContinuedProcessing()
            let started = Date.now
            await worker.reconcile(mode: .foreground)
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

    /// Reads Private Cloud Compute's availability and quota for the Spines tab.
    func refreshModelStatus() async {
        await worker.refreshModelStatus()
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
    /// retry date, or with no known work left, a day from now, which keeps the seven-day cover
    /// rechecks and libraries without a worklist current. Nil means as soon as possible.
    private func nextRunDate(hasNewWork: Bool) -> Date? {
        if let retryAfter = status.retryAfter, retryAfter > .now { return retryAfter }
        if !hasNewWork && !workMayRemain { return .now.addingTimeInterval(24 * 60 * 60) }
        return nil
    }

    #if os(macOS)
        /// Asks macOS to run generation when the Mac is idle, or cancels the request when the
        /// user turned the preference off. The Mac app keeps running with no window open, so
        /// the activity fires while it stays in the menu bar.
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
                    await GenerationController.shared.runChargingTask()
                    completion(.finished)
                }
            }
            backgroundActivity = activity
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
                if let data = try? JSONEncoder().encode(snapshot) {
                    UserDefaults.standard.set(data, forKey: Self.lastRunKey)
                }
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

        private func report(_ snapshot: WorkerSnapshot, to task: BGContinuedProcessingTask) {
            let done = snapshot.completed + snapshot.failed
            task.progress.totalUnitCount = Int64(done + snapshot.queue)
            task.progress.completedUnitCount = Int64(done)
            task.updateTitle(
                "Designing spines", subtitle: snapshot.currentBook?.title ?? snapshot.phase)
        }
    #endif
}
