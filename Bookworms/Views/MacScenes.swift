#if os(macOS)
    import ServiceManagement
    import SwiftUI

    /// The menu bar item's menu on the Mac: generation status and controls, the main window,
    /// and launch at login. It keeps the app reachable while it designs spines with every
    /// window closed.
    struct BookwormsMenu: View {
        static let windowID = "main"

        @Environment(AppModel.self) private var model
        @Environment(GenerationController.self) private var generation
        @Environment(\.openWindow) private var openWindow

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
            .keyboardShortcut("o")
            LaunchAtLoginToggle()
            Divider()
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Quit Bookworms") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    /// **Generate Now** while idle, and **Stop** during a run the reader started.
    struct GenerateButton: View {
        @Environment(GenerationController.self) private var generation

        var body: some View {
            if generation.isGenerating {
                Button("Stop Generating") { generation.stop() }
            } else {
                Button("Generate Now") { generation.generateNow() }
            }
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

    /// Menu bar commands for the main window: a **Go** menu that closes a book's details with
    /// **Back** (Command-[) and switches sections with Command-1 through Command-4, and
    /// generation in the **Spines** menu. Other areas add their own `Commands` (see
    /// `FocusedActions.swift`).
    struct BookwormsCommands: Commands {
        let model: AppModel
        let generation: GenerationController
        @FocusedValue(\.goBack) private var goBack

        var body: some Commands {
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
            CommandMenu("Spines") {
                GenerateButton()
                    .environment(generation)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
    }
#endif
