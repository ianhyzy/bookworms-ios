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
            // `-BookwormsShelfMode <stack|shelf>` opens Library, and `pile` opens Desk.
            // `-BookwormsTab <share|library|desk|spines>` opens that tab. Only launch arguments
            // count: Library saves its mode under the same key.
            let arguments = UserDefaults.standard.volatileDomain(
                forName: UserDefaults.argumentDomain)
            if !testing, let mode = arguments["BookwormsShelfMode"] as? String {
                AppModel.shared.selectedTab = mode == "pile" ? .desk : .library
            }
            if !testing, let tab = (arguments["BookwormsTab"] as? String).flatMap(AppTab.init) {
                AppModel.shared.selectedTab = tab
            }
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
    /// Set once the first launch outside preview mode has offered the Hardcover sheet.
    @AppStorage("BookwormsOfferedHardcover") private var offeredHardcover = false
    @State private var showsAccount = false

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Share", systemImage: "square.and.arrow.up", value: .share) { ShareStudioView() }
            // Library and Desk set their own tint; this keeps the bar's lamp tint out of their
            // account sheets, which follow the system appearance.
            Tab("Library", systemImage: "books.vertical", value: .library) {
                LibraryView().tint(.accentColor)
            }
            Tab("Desk", systemImage: "lamp.desk", value: .desk) { DeskView().tint(.accentColor) }
            Tab("Spines", systemImage: "wand.and.sparkles", value: .spines) { GenerationView() }
        }
        // In light appearance, the bar over Library's and Desk's dark wall leaves the default
        // blue with almost no contrast, so their lamp marks the selected tab.
        .tint([.library, .desk].contains(model.selectedTab) ? ShelfPalette.lamp : nil)
        // Hardcover is the library's own source, so the first launch offers it once, over
        // whichever tab opens. Outside the tint, so the sheet follows the system appearance.
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        .background(ToastWindow(toasts: model.toasts))
        .task {
            guard !offeredHardcover, !model.isPreview else { return }
            offeredHardcover = true
            if !model.account.isSignedIn { showsAccount = true }
        }
        .task { await model.reload() }
        .onChange(of: scenePhase) { _, phase in
            generation.scenePhaseChanged(to: phase)
            if phase == .active { Task { await model.reloadIfStale() } }
        }
    }
}
