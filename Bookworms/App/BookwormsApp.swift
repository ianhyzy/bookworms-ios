import CloudKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Subscribes to worklist changes and applies Debug launch arguments, once per launch.
@MainActor
private func finishLaunching(registerForPushes: () -> Void) {
    let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !testing && !AppModel.shared.isPreview {
        registerForPushes()
        Task { await GenerationController.shared.installWorklistSubscription() }
    }
    #if DEBUG
        // `-BookwormsShelfMode <stack|shelf>` opens Library, and `pile` opens Desk.
        // `-BookwormsTab <share|library|desk|spines>` opens that tab. Only launch arguments
        // count: Library saves its mode under the same key.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
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
}

/// Whether a remote notification is the Apple TV's worklist change alert.
private func isWorklistChange(_ userInfo: [AnyHashable: Any]) -> Bool {
    CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID
        == CloudContract.worklistSubscriptionID
}

#if os(macOS)
    /// Registers for CloudKit change alerts, routes them to the generator, and keeps the app
    /// running in the menu bar after its last window closes.
    final class AppDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            MainActor.assumeIsolated {
                finishLaunching { NSApplication.shared.registerForRemoteNotifications() }
                UIApplication.reportMemoryPressure()
                Task { await GenerationController.shared.scheduleChargingTask() }
            }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            false
        }

        func application(
            _ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]
        ) {
            guard isWorklistChange(userInfo) else { return }
            Task { @MainActor in await GenerationController.shared.worklistChanged() }
        }
    }
#else
    /// Registers for CloudKit change alerts and routes them to the generator.
    final class AppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? =
                nil
        ) -> Bool {
            finishLaunching { application.registerForRemoteNotifications() }
            return true
        }

        /// Schedules generation for a worklist change. The push allows about 30 seconds, too
        /// little for a design.
        func application(
            _ application: UIApplication,
            didReceiveRemoteNotification userInfo: [AnyHashable: Any]
        ) async -> UIBackgroundFetchResult {
            guard isWorklistChange(userInfo) else { return .noData }
            await GenerationController.shared.worklistChanged()
            return .newData
        }
    }
#endif

@main
struct BookwormsApp: App {
    #if os(macOS)
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
        @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel.shared
    @State private var generation = GenerationController.shared

    var body: some Scene {
        #if os(macOS)
            // One main window; the menu bar item reopens it and keeps generation reachable
            // while it is closed.
            Window("Bookworms", id: BookwormsMenu.windowID) {
                RootView()
                    .environment(model)
                    .environment(generation)
                    .frame(minWidth: 760, minHeight: 560)
            }
            .defaultSize(width: 1180, height: 820)
            .commands { BookwormsCommands(model: model, generation: generation) }
            Settings {
                MacSettingsView()
                    .environment(model)
                    .environment(generation)
            }
            MenuBarExtra("Bookworms", systemImage: "books.vertical") {
                BookwormsMenu()
                    .environment(model)
                    .environment(generation)
            }
        #else
            WindowGroup {
                RootView()
                    .environment(model)
                    .environment(generation)
            }
            .backgroundTask(.processingTask(GenerationController.processingTaskID)) {
                await GenerationController.shared.runChargingTask()
            }
        #endif
    }
}

struct RootView: View {
    /// `-BookwormsOfferedHardcover YES` skips the launch's Hardcover sheet for checks.
    private static let skipsHardcoverPrompt =
        (UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[
            "BookwormsOfferedHardcover"] as? String)
        .map { ($0 as NSString).boolValue } ?? false

    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAccount = false

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Share", systemImage: "square.and.arrow.up", value: .share) { ShareStudioView() }
            Tab("Library", systemImage: "books.vertical", value: .library) { LibraryView() }
            Tab("Desk", systemImage: "lamp.desk", value: .desk) { DeskView() }
            Tab("Spines", systemImage: "wand.and.sparkles", value: .spines) { GenerationView() }
        }
        #if os(macOS)
            // A Mac app lists its sections in a Liquid Glass sidebar rather than a tab bar.
            .tabViewStyle(.sidebarAdaptable)
        #endif
        // Hardcover is the library's own source, so each launch without a working sign-in, and
        // a sign-in that stops working, offers it over whichever tab shows.
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        #if os(macOS)
            // Grouped forms match the iPhone's inset sections instead of the Mac's columns.
            .formStyle(.grouped)
            // Mac sheets are windows of their own, so the main window's toasts sit in it.
            .overlay { ToastOverlay(toasts: model.toasts).allowsHitTesting(false) }
        #else
            .background(ToastWindow(toasts: model.toasts))
        #endif
        .task {
            guard !model.isPreview, !Self.skipsHardcoverPrompt else { return }
            if !model.account.isSignedIn || model.account.needsReconnect { showsAccount = true }
        }
        .onChange(of: model.account.needsReconnect) { _, broken in
            if broken && !model.isPreview { showsAccount = true }
        }
        .task { await model.reload() }
        .onChange(of: scenePhase) { _, phase in
            generation.scenePhaseChanged(to: phase)
            if phase == .active { Task { await model.reloadIfStale() } }
        }
    }
}
