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
    #if DEBUG || SPINE_BATCH
        // `-BookwormsSpineBatch <books.json>` designs books in memory for review sheets.
        if !testing { SpineBatch.startIfRequested() }
    #endif
    #if DEBUG
        if !testing, let tab = launchArgumentTab() { AppModel.shared.selectedTab = tab }
        if !testing { AppModel.shared.showLaunchArgumentAccountPrompt() }
        // `-BookwormsGenerateOnLaunch YES` starts a run for Simulator checks.
        if !testing && UserDefaults.standard.bool(forKey: "BookwormsGenerateOnLaunch") {
            GenerationController.shared.generateNow()
        }
        #if os(macOS)
            if !testing { WindowSweep.startIfRequested() }
        #endif
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
            TestCopy.markIfActive()
            finishLaunching { NSApplication.shared.registerForRemoteNotifications() }
            UIApplication.reportMemoryPressure()
            Task { await GenerationController.shared.scheduleChargingTask() }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            false
        }

        /// Built each time the Dock asks, so it names the run's current state. The example
        /// profile neither generates nor syncs, so it has no menu.
        func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
            guard !AppModel.shared.isExample else { return nil }
            let menu = NSMenu()
            let generating = GenerationController.shared.canStop
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
                if generation.canStop { generation.stop() } else { generation.generateNow() }
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
                if SpineBatch.isRequested {
                    // A batch draws no library, so only the batch runs (`SpineBatch`).
                    ProgressView("Designing spines")
                        .frame(minWidth: 320, minHeight: 200)
                } else {
                    RootView()
                        .environment(model)
                        .environment(generation)
                        // Room beside the sidebar for the Share tab's preview controls and its
                        // settings column at its narrowest.
                        .frame(minWidth: 780, minHeight: 560)
                }
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

/// Runs `change`, such as a switch to another tab, while the app's windows cross-fade from their
/// current look to the one `change` leads to.
///
/// `RootView`'s tab view switches tabs without a transition, and SwiftUI offers none to add, so
/// the fade is a Core Animation transition on each window's layer: SwiftUI applies `change` in
/// the same transaction, and the window's last frame dissolves into its live views. On the
/// iPhone, the fade covers the key window. On the Mac, it covers every visible window, because
/// the tab can change in a window behind the key one, as when a book's own window shares the
/// book; a window that `change` leaves alone looks the same throughout. There the layer is the
/// window frame's, which also holds the toolbar and the sidebar.
@MainActor func crossfadeWindow(_ change: () -> Void) {
    let fade = CATransition()
    fade.type = .fade
    fade.duration = 0.3
    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    #if os(macOS)
        for window in NSApp.windows where window.isVisible {
            window.contentView?.superview?.layer?.add(fade, forKey: "crossfade")
        }
    #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
        scene?.keyWindow?.layer.add(fade, forKey: "crossfade")
    #endif
    change()
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
                ShareStudioView().toastOverlay(model.toasts).accountBanner($showsAccount)
            }
            Tab("Library", systemImage: "books.vertical", value: .library) {
                LibraryView().toastOverlay(model.toasts).accountBanner($showsAccount, on: .dark)
            }
            Tab("Desk", systemImage: "lamp.desk", value: .desk) {
                DeskView().toastOverlay(model.toasts).accountBanner($showsAccount, on: .dark)
            }
            // The example profile designs nothing.
            if !model.isExample {
                Tab("Spines", image: "tab.spines", value: .spines) {
                    GenerationView().toastOverlay(model.toasts)
                }
            }
        }
        #if os(macOS)
            // A Mac app lists its sections in a Liquid Glass sidebar rather than a tab bar. The
            // sidebar marks the selected row in the person's accent color, as other Mac apps
            // do; Library and Desk tint only their own content with the lamp's color.
            .tabViewStyle(.sidebarAdaptable)
            .tabViewSidebarHeader { SidebarAccount(showsAccount: $showsAccount) }
            .tabViewSidebarFooter { SidebarMinimumWidth().accessibilityHidden(true) }
        #endif
        .environment(\.fullSizeShareImage, $fullSizeShareImage)
        .overlay {
            if let image = fullSizeShareImage {
                FullSizeShareImage(image: image) { fullSizeShareImage = nil }
            }
        }
        // The Top Five pin's desk stamp comes down over every tab and bar.
        .stampStage()
        // Hardcover is the library's own source, so the first launch without a sign-in offers it
        // over whichever tab shows, and so does a sign-in that stops working. After the first
        // offer, the empty states, the iPhone's Spines tab and Settings, and the Mac's sidebar
        // offer it instead.
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        #if os(macOS)
            // Grouped forms match the iPhone's inset sections instead of the Mac's columns.
            .formStyle(.grouped)
        #else
            .background(ToastWindow(toasts: model.toasts))
        #endif
        .task {
            // Offers the sheet once, at the first launch on a device with no sign-in. A login that
            // Hardcover rejected shows `AccountBanner` on the iPhone and `SidebarAccount`'s mark
            // on the Mac instead.
            guard !model.isPreview, !model.account.isSignedIn, !offeredHardcover else { return }
            offeredHardcover = true
            showsAccount = true
        }
        .onChange(of: model.account.needsReconnect) { _, broken in
            if broken && !model.isPreview { showsAccount = true }
        }
        .modifier(CloudAccountAlerts())
        // **Library > Hardcover Account…** on the Mac.
        .focusedSceneValue(\.showAccount, SceneAction { showsAccount = true })
        #if os(macOS)
            .modifier(RestoresTab(savedTab: $savedTab))
        #endif
        .task {
            #if DEBUG
                // `-BookwormsExampleProfile YES` opens the example profile in place of the
                // launch's load, on a device without a library or sign-in.
                if UserDefaults.standard.bool(forKey: "BookwormsExampleProfile") {
                    await model.showExample()
                }
            #endif
            await model.reload()
        }
        // Builds the desk ahead of its tab once launch settles, so the tab opens at once.
        .task {
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            DeskScenes.prewarm()
        }
        .onChange(of: scenePhase) { _, phase in
            generation.scenePhaseChanged(to: phase)
            if phase == .active { Task { await model.reloadIfStale() } }
        }
    }
}

#if os(macOS)
    /// Keeps the Mac's sidebar wide enough for the sidebar button beside the window's buttons.
    ///
    /// SwiftUI lets the tab view's sidebar narrow to 140 points, and no SwiftUI modifier sets its
    /// width. At that width, the window's buttons and the sidebar button don't fit in the
    /// sidebar's part of the toolbar, so AppKit moves the button into an overflow menu (>>) at
    /// the toolbar's trailing end. This empty view, in the sidebar's footer, gives the split
    /// view's sidebar pane a minimum width through Auto Layout, which the split view keeps as it
    /// restores the sidebar's saved width and hides and shows the sidebar.
    private struct SidebarMinimumWidth: NSViewRepresentable {
        /// Room for the window's buttons and the sidebar button, with a margin.
        static let width: CGFloat = 160

        func makeNSView(context: Context) -> NSView { Probe() }
        func updateNSView(_ view: NSView, context: Context) {}

        private final class Probe: NSView {
            private static let id = "BookwormsSidebarMinimumWidth"

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                // The sidebar's pane is the ancestor that the split view holds.
                var pane: NSView? = self
                while let view = pane, !(view.superview is NSSplitView) { pane = view.superview }
                guard let pane, !pane.constraints.contains(where: { $0.identifier == Self.id })
                else { return }
                let minimum = pane.widthAnchor.constraint(
                    greaterThanOrEqualToConstant: SidebarMinimumWidth.width)
                minimum.identifier = Self.id
                minimum.isActive = true
            }
        }
    }

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
                // The example profile's tabs are not the reader's choice.
                .onChange(of: model.selectedTab) { _, tab in
                    if !model.isExample { savedTab = tab }
                }
        }
    }
#endif

/// The alerts that answer the iCloud account check (`AppModel.accountPrompt`), a failed
/// **Merge**, and how to delete Bookworms data from iCloud after **Keep iCloud Off**. The
/// prompts have no cancel button, because iCloud stays paused until the reader chooses.
private struct CloudAccountAlerts: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert("Another Hardcover account in iCloud", isPresented: .constant(!others.isEmpty)) {
                // `Task.immediate` clears the prompt before the alert can show again.
                Button("Merge") { Task.immediate { await model.mergeOtherAccounts() } }
                    .keyboardShortcut(.defaultAction)
                Button("Keep iCloud Off") { Task.immediate { await model.keepICloudOff() } }
            } message: {
                let names = ListFormatter.localizedString(byJoining: others.map(\.name))
                Text(
                    others.count == 1
                        ? "iCloud has Bookworms data from \(names). Merge copies its designs and choices to the same books in your library."
                        : "iCloud has Bookworms data from \(names). Merge copies their designs and choices to the same books in your library."
                )
            }
            .alert("Choose a library", isPresented: .constant(!libraries.isEmpty)) {
                ForEach(libraries) { library in
                    Button(library.name) { Task.immediate { await model.chooseLibrary(library) } }
                }
            } message: {
                Text("iCloud has libraries from more than one Hardcover account.")
            }
            .alert(
                "Couldn't merge",
                isPresented: Binding(
                    get: { model.mergeError != nil }, set: { if !$0 { model.mergeError = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(model.mergeError ?? "")
            }
            .alert(
                "iCloud storage is off",
                isPresented: Binding(
                    get: { model.showsICloudDeletion }, set: { model.showsICloudDeletion = $0 })
            ) {
                Button("OK") {}
            } message: {
                #if os(macOS)
                    Text(
                        "To delete Bookworms data from iCloud, open System Settings, click your name, then click iCloud > Manage > Bookworms. This deletes all Bookworms iCloud data, including this account's."
                    )
                #else
                    Text(
                        "To delete Bookworms data from iCloud, open Settings, tap your name, then tap iCloud > Manage Account Storage > Bookworms. This deletes all Bookworms iCloud data, including this account's."
                    )
                #endif
            }
    }

    private var others: [CloudAccount] {
        guard case .otherAccounts(let accounts)? = model.accountPrompt else { return [] }
        return accounts
    }

    private var libraries: [CloudAccount] {
        guard case .chooseLibrary(let accounts)? = model.accountPrompt else { return [] }
        return accounts
    }
}

extension View {
    /// Shows the account banner above the tab's content while there is one (`AccountBanner`):
    /// what it says, and a button that sets `showsAccount`. Each tab adds it, so on the Mac it
    /// stays beside the sidebar.
    ///
    /// - Parameter scheme: The appearance of a tab whose backdrop keeps one appearance, as
    ///   Library's and Desk's dark walnut does, so the bar matches the tab below it; `nil`
    ///   follows the system's.
    fileprivate func accountBanner(
        _ showsAccount: Binding<Bool>, on scheme: ColorScheme? = nil
    ) -> some View {
        modifier(AccountBannerBar(showsAccount: showsAccount, scheme: scheme))
    }
}

/// A bar above the tab rather than a safe area inset, which the tab's navigation bar would draw
/// under: the bar shortens the tab, so its navigation bar and toolbar sit below the banner.
private struct AccountBannerBar: ViewModifier {
    @Binding var showsAccount: Bool
    let scheme: ColorScheme?
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let banner = AccountBanner(
                isExample: model.isExample, control: AccountControl(model))
            {
                HStack {
                    Text(banner.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(banner.control.title) {
                        banner.control.open(model.account) { showsAccount = true }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                // The window's background shows through the bar's material, so the bar draws
                // its own in its scheme.
                .background {
                    Rectangle().fill(.background).overlay(.bar).ignoresSafeArea(edges: .top)
                }
                .environment(\.colorScheme, scheme ?? systemScheme)
            }
            content
        }
    }
}
