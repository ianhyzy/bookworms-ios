import CloudKit
import SwiftUI
import TipKit
import os

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Subscribes to worklist changes and applies Debug launch arguments, once per launch.
@MainActor
private func finishLaunching(registerForPushes: () -> Void) {
    let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !testing { configureTips() }
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

/// Configures TipKit once per launch, before any view shows a tip, so each area only adds its
/// tips. The tips' display state lives in TipKit's default datastore in the app's container.
///
/// Debug builds accept `-BookwormsTips <show|hide|reset>`: `show` shows every tip whatever its
/// rules, `hide` hides them all for screenshots, and `reset` forgets which tips were shown.
@MainActor
private func configureTips() {
    #if DEBUG
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        switch arguments["BookwormsTips"] as? String {
        case "show": Tips.showAllTipsForTesting()
        case "hide": Tips.hideAllTipsForTesting()
        case "reset": try? Tips.resetDatastore()
        default: break
        }
    #endif
    do {
        try Tips.configure()
    } catch {
        Logger(subsystem: "gay.ian.Bookworms.iOS", category: "tips")
            .error("TipKit setup failed: \(error.localizedDescription, privacy: .public)")
    }
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
            // Each area's menu commands, one line each (see `FocusedActions.swift`).
            .commands {
                BookwormsCommands(model: model, generation: generation)
                ShareCommands()
                DeskCommands()
            }
            Settings {
                MacSettingsView()
                    .environment(model)
                    .environment(generation)
            }
            MenuBarExtra("Bookworms", image: "menubar.bookworm") {
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
    @Environment(AppModel.self) private var model
    /// Whether a launch has offered the Hardcover sheet. `-BookwormsOfferedHardcover YES` skips the
    /// offer for checks, and `NO` offers it again.
    @AppStorage("BookwormsOfferedHardcover") private var offeredHardcover = false
    @Environment(GenerationController.self) private var generation
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAccount = false
    /// The share image shown full size over every tab and bar, while the Share tab's preview is
    /// held.
    @State private var fullSizeShareImage: UIImage?

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            // The custom symbols' sources are in `script/custom-symbols.py`.
            Tab("Share", image: "tab.share", value: .share) {
                ShareStudioView().toastOverlay(model.toasts)
            }
            Tab("Library", systemImage: "books.vertical", value: .library) {
                LibraryView().toastOverlay(model.toasts)
            }
            Tab("Desk", systemImage: "lamp.desk", value: .desk) {
                DeskView().toastOverlay(model.toasts)
            }
            Tab("Spines", image: "tab.spines", value: .spines) {
                GenerationView().toastOverlay(model.toasts)
            }
        }
        #if os(macOS)
            // A Mac app lists its sections in a Liquid Glass sidebar rather than a tab bar. The
            // sidebar marks the selected row in the person's accent color, as other Mac apps
            // do; Library and Desk tint only their own content with the lamp's color.
            .tabViewStyle(.sidebarAdaptable)
        #endif
        .environment(\.fullSizeShareImage, $fullSizeShareImage)
        .overlay {
            if let image = fullSizeShareImage {
                FullSizeShareImage(image: image) { fullSizeShareImage = nil }
            }
        }
        // Hardcover is the library's own source, so the first launch without a sign-in offers it
        // over whichever tab shows, and so does a sign-in that stops working. After the first
        // offer, the empty states, the Spines tab, and Settings offer it instead.
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        #if os(macOS)
            // Grouped forms match the iPhone's inset sections instead of the Mac's columns.
            .formStyle(.grouped)
        #else
            .background(ToastWindow(toasts: model.toasts))
        #endif
        .task {
            guard !model.isPreview else { return }
            if model.account.needsReconnect {
                showsAccount = true
            } else if !model.account.isSignedIn, !offeredHardcover {
                offeredHardcover = true
                showsAccount = true
            }
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
