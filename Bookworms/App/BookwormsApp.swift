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
        if !testing, let tab = launchArgumentTab() { AppModel.shared.selectedTab = tab }
        // `-BookwormsGenerateOnLaunch YES` starts a run for Simulator checks.
        if !testing && UserDefaults.standard.bool(forKey: "BookwormsGenerateOnLaunch") {
            GenerationController.shared.generateNow()
        }
    #endif
}

#if DEBUG
    /// The tab Debug launch arguments open, or `nil` when none chooses one. The last that
    /// applies wins:
    /// - `-BookwormsShelfMode <stack|shelf>` opens Library, and `pile` opens Desk. Only launch
    ///   arguments count, since Library saves its mode under the same key.
    /// - `-BookwormsTab <share|library|desk|spines>` opens that tab.
    /// - `-BookwormsShowSpines YES` and `-BookwormsGenerateOnLaunch YES` open Spines.
    /// - `-BookwormsShareTemplate <name>` opens Share; see `ShareStudioView`.
    private func launchArgumentTab() -> AppTab? {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let defaults = UserDefaults.standard
        var tab: AppTab?
        if let mode = arguments["BookwormsShelfMode"] as? String {
            tab = mode == "pile" ? .desk : .library
        }
        if let named = (arguments["BookwormsTab"] as? String).flatMap(AppTab.init) { tab = named }
        if defaults.bool(forKey: "BookwormsShowSpines")
            || defaults.bool(forKey: "BookwormsGenerateOnLaunch")
        {
            tab = .spines
        }
        if defaults.string(forKey: "BookwormsShareTemplate") != nil { tab = .share }
        return tab
    }
#endif

#if os(macOS)
    /// Whether a Debug launch argument chose the first tab (`finishLaunching`), which the window's
    /// saved tab then leaves alone.
    private let launchChoosesTab: Bool = {
        #if DEBUG
            launchArgumentTab() != nil
        #else
            false
        #endif
    }()
#endif

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
    /// Registers for CloudKit change alerts, routes them to the generator, keeps the app
    /// running in the menu bar after its last window closes, and gives the Dock icon a menu
    /// with **Generate Now** or **Stop Generating** and **Sync Library**.
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

        /// Built each time the Dock asks, so it names the run's current state. AppKit asks on the
        /// main thread.
        @MainActor func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
            let menu = NSMenu()
            let generating = GenerationController.shared.isGenerating
            menu.addItem(
                withTitle: generating ? "Stop Generating" : "Generate Now",
                action: #selector(toggleGeneration), keyEquivalent: ""
            )
            .target = self
            menu.addItem(
                withTitle: "Sync Library", action: #selector(syncLibrary), keyEquivalent: ""
            )
            .target = self
            return menu
        }

        @objc private func toggleGeneration() {
            MainActor.assumeIsolated {
                let generation = GenerationController.shared
                if generation.isGenerating { generation.stop() } else { generation.generateNow() }
            }
        }

        @objc private func syncLibrary() {
            Task { @MainActor in await AppModel.shared.syncLibrary() }
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
    #if os(macOS)
        @AppStorage(MenuBarExtraToggle.key) private var showsMenuBarExtra = true
    #endif

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
                SidebarCommands()
                BookwormsCommands(model: model)
                LibraryCommands(model: model, generation: generation)
                ShareCommands()
                DeskCommands()
            }
            // A book's details, opened from Library in a window of their own.
            WindowGroup("Book", id: BookWindow.id, for: Int.self) { $id in
                BookWindow(bookID: id)
                    .environment(model)
                    .environment(generation)
            }
            .defaultSize(width: 680, height: 820)
            Settings {
                MacSettingsView()
                    .environment(model)
                    .environment(generation)
            }
            MenuBarExtra("Bookworms", image: "menubar.bookworm", isInserted: $showsMenuBarExtra) {
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
    #if os(macOS)
        /// The section last chosen, which the next launch reopens on; Share at first launch. The
        /// app keeps it rather than the window, whose saved state ends when the window closes.
        @AppStorage("BookwormsLastTab") private var savedTab = AppTab.share
    #endif
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
        // **Library > Hardcover Account…** on the Mac.
        .focusedSceneValue(\.showAccount, SceneAction { showsAccount = true })
        #if os(macOS)
            .modifier(RestoresTab(savedTab: $savedTab))
        #endif
        .task { await model.reload() }
        .onChange(of: scenePhase) { _, phase in
            generation.scenePhaseChanged(to: phase)
            if phase == .active { Task { await model.reloadIfStale() } }
        }
    }
}

#if os(macOS)
    /// Reopens the Mac's main window on the section it last showed, once per launch, and saves
    /// each new section. A Debug launch argument's section wins, and so does a share that a book
    /// window requested before the main window opened, which `BookWindow` opens the main window
    /// for. A window reopened later in the same launch, such as from the menu bar item, keeps the
    /// section that shows. A modifier of its own, so a tab switch updates only it, not the root
    /// view.
    private struct RestoresTab: ViewModifier {
        /// Whether a window has restored its section in this launch.
        private static var restored = false

        @Binding var savedTab: AppTab
        @Environment(AppModel.self) private var model

        func body(content: Content) -> some View {
            content
                .onAppear {
                    guard !Self.restored else { return }
                    Self.restored = true
                    if !launchChoosesTab && model.shareBookID == nil {
                        model.selectedTab = savedTab
                    }
                }
                .onChange(of: model.selectedTab) { _, tab in savedTab = tab }
        }
    }
#endif
