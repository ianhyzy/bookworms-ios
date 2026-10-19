#if os(macOS)
    import ServiceManagement
    import SwiftUI

    /// The menu bar item's menu on the Mac: generation status and controls, the main window,
    /// and launch at login. It keeps the app reachable while it designs spines with every
    /// window closed. **Bookworms > Show in Menu Bar** hides it (`MenuBarExtraToggle`).
    struct BookwormsMenu: View {
        static let windowID = "main"

        @Environment(AppModel.self) private var model
        @Environment(GenerationController.self) private var generation
        @Environment(\.openWindow) private var openWindow
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            let designed = model.library?.designs.count ?? 0
            let total = model.library?.books.count ?? 0
            Text("\(designed) of \(total) books designed")
            Text(generation.status.currentBook?.title ?? generation.status.phase)
            Divider()
            GenerateButton()
            Button("Open Bookworms") {
                openWindow(id: Self.windowID)
                NSApplication.shared.activate()
            }
            LaunchAtLoginToggle()
            Divider()
            // Brings the app forward with its Settings window, which would otherwise open
            // behind the app in front.
            Button("Settings…") {
                openSettings()
                NSApplication.shared.activate()
            }
            .keyboardShortcut(",")
            Button("Quit Bookworms") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    /// **Generate Now**, or `idleTitle`, while idle, and **Stop Generating** during a run the
    /// reader started.
    struct GenerateButton: View {
        var idleTitle = "Generate Now"

        @Environment(GenerationController.self) private var generation

        var body: some View {
            if generation.isGenerating {
                Button("Stop Generating") { generation.stop() }
            } else {
                Button(idleTitle) { generation.generateNow() }
            }
        }
    }

    /// **Show in Menu Bar**, which shows or hides the menu bar item (`BookwormsMenu`), in the
    /// **Bookworms** menu after **Settings…** (`BookwormsCommands`), which stays reachable from
    /// the Dock with the item hidden. It is on by default; with it off, the Dock icon's menu and
    /// the main window still reach generation.
    struct MenuBarExtraToggle: View {
        /// The setting, which `BookwormsApp` reads for the menu bar item.
        static let key = "BookwormsShowsMenuBarExtra"

        @AppStorage(Self.key) private var isOn = true

        var body: some View {
            Toggle("Show in Menu Bar", isOn: $isOn)
        }
    }

    /// Registers the app as a login item, so it designs spines from login onward.
    struct LaunchAtLoginToggle: View {
        @State private var isOn = SMAppService.mainApp.status == .enabled

        var body: some View {
            Toggle("Launch at Login", isOn: $isOn)
                .onChange(of: isOn) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // macOS can ask for approval in Login Items; show what it decided.
                        isOn = SMAppService.mainApp.status == .enabled
                    }
                }
        }
    }

    /// Menu bar commands for the main window: **Show in Menu Bar** in the **Bookworms** menu
    /// (`MenuBarExtraToggle`), and a **Go** menu that closes a book's details with **Back**
    /// (Command-[) and switches sections with Command-1 through Command-4. The app has no help
    /// book, so the **Help** menu holds only the system's search. Other areas add their own
    /// `Commands`, such as `LibraryCommands` (see `FocusedActions.swift`).
    struct BookwormsCommands: Commands {
        let model: AppModel
        @FocusedValue(\.goBack) private var goBack

        var body: some Commands {
            CommandGroup(after: .appSettings) { MenuBarExtraToggle() }
            CommandMenu("Go") {
                Button("Back") { goBack?() }
                    .keyboardShortcut("[")
                    .disabled(goBack == nil)
                Divider()
                Button("Share") { model.selectedTab = .share }.keyboardShortcut("1")
                Button("Library") { model.selectedTab = .library }.keyboardShortcut("2")
                Button("Desk") { model.selectedTab = .desk }.keyboardShortcut("3")
                Button("Spines") { model.selectedTab = .spines }.keyboardShortcut("4")
            }
            CommandGroup(replacing: .help) {}
        }
    }

    /// A book's details in a window of their own, which **Open in New Window**, Option-click,
    /// and Option-Return open from Library. The window takes the book's name, comes back with
    /// the app, and says so when the library no longer includes the book. The details'
    /// **Share** brings the main window forward on the Share tab.
    struct BookWindow: View {
        static let id = "book"

        let bookID: Int?

        @Environment(AppModel.self) private var model
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            NavigationStack {
                PushedBookDetail(id: bookID ?? 0, tab: nil)
            }
            // The details stand in the walnut room, as in the main window.
            .environment(\.colorScheme, .dark)
            .tint(ShelfPalette.lamp)
            .frame(minWidth: 420, minHeight: 520)
            .onChange(of: model.shareBookID) {
                if model.shareBookID != nil { openWindow(id: BookwormsMenu.windowID) }
            }
        }
    }
#endif
