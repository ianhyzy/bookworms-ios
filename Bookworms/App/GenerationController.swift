import Observation
import SwiftUI

/// Runs spine generation in the foreground, while charging, and after a worklist change.
@MainActor
@Observable
final class GenerationController {
    static let shared = GenerationController()
    static let processingTaskID = "gay.ian.Bookworms.iOS.spines"

    private(set) var status = WorkerSnapshot()

    /// Runs inside the charging-only background processing task.
    func runChargingTask() async {}

    /// Schedules generation after the Apple TV publishes a new worklist.
    func worklistChanged() async {}

    func scenePhaseChanged(to phase: ScenePhase) {}
}
