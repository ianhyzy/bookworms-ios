import CloudKit
import SwiftUI
import UIKit

/// Registers for CloudKit change alerts and routes them to the generator.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !testing && !AppModel.shared.isPreview {
            application.registerForRemoteNotifications()
            Task { await GenerationController.shared.installWorklistSubscription() }
        }
        #if DEBUG
            // `-BookwormsGenerateOnLaunch YES` starts a run for Simulator checks, and
            // `-BookwormsShowSpines YES` opens the Spines tab without one.
            if !testing && UserDefaults.standard.bool(forKey: "BookwormsShowSpines") {
                AppModel.shared.selectedTab = .spines
            }
            if !testing && UserDefaults.standard.bool(forKey: "BookwormsGenerateOnLaunch") {
                AppModel.shared.selectedTab = .spines
                GenerationController.shared.generateNow()
            }
            // `-BookwormsShareTemplate <name>` opens the Share tab; see `ShareStudioView`.
            if !testing && UserDefaults.standard.string(forKey: "BookwormsShareTemplate") != nil {
                AppModel.shared.selectedTab = .share
            }
        #endif
        return true
    }

    /// Schedules generation for a worklist change. The push allows about 30 seconds, too
    /// little for a design.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let subscriptionID =
            CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID
        guard subscriptionID == CloudContract.worklistSubscriptionID else { return .noData }
        await GenerationController.shared.worklistChanged()
        return .newData
    }
}

@main
struct BookwormsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @State private var generation = GenerationController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(generation)
        }
        .backgroundTask(.processingTask(GenerationController.processingTaskID)) {
            await GenerationController.shared.runChargingTask()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            // The shelf sets its own tint; this keeps the bar's lamp tint out of its account
            // sheet, which follows the system appearance.
            Tab("Shelf", systemImage: "books.vertical", value: .shelf) {
                ShelfView().tint(.accentColor)
            }
            Tab("Share", systemImage: "square.and.arrow.up", value: .share) { ShareStudioView() }
            Tab("Spines", systemImage: "wand.and.sparkles", value: .spines) { GenerationView() }
        }
        // In light appearance, the bar over the shelf's dark wall leaves the default blue with
        // almost no contrast, so the shelf's lamp marks its selected tab.
        .tint(model.selectedTab == .shelf ? ShelfPalette.lamp : nil)
        .task { await model.reload() }
        .onChange(of: scenePhase) { _, phase in
            generation.scenePhaseChanged(to: phase)
            if phase == .active { Task { await model.reloadIfStale() } }
        }
    }
}
