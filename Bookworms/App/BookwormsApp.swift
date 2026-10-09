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
        }
        return true
    }

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
            Tab("Shelf", systemImage: "books.vertical", value: .shelf) { ShelfView() }
            Tab("Share", systemImage: "square.and.arrow.up", value: .share) { ShareStudioView() }
            Tab("Spines", systemImage: "wand.and.sparkles", value: .spines) { GenerationView() }
        }
        .task { await model.reload() }
        .onChange(of: scenePhase) { _, phase in
            generation.scenePhaseChanged(to: phase)
        }
    }
}
