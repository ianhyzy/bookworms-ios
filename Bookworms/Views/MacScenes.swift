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

    /// The Settings window (**Bookworms > Settings…**): background generation, launch at
    /// login, and the Hardcover account.
    struct MacSettingsView: View {
        @Environment(AppModel.self) private var model
        @Environment(GenerationController.self) private var generation
        @State private var showsAccount = false

        var body: some View {
            @Bindable var generation = generation
            Form {
                Section {
                    Toggle("Generate while idle", isOn: $generation.generatesWhileCharging)
                    LaunchAtLoginToggle()
                } header: {
                    Text("Spines")
                } footer: {
                    Text(
                        "Bookworms keeps running in the menu bar after you close its window, and macOS runs generation when this Mac is idle. The Apple TV picks up new designs through iCloud."
                    )
                }
                Section("Hardcover") {
                    LabeledContent(
                        "Account", value: model.account.isSignedIn ? "Connected" : "Not connected")
                    Button(model.account.isSignedIn ? "Manage Account…" : "Connect Hardcover…") {
                        showsAccount = true
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
            .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        }
    }

    /// Menu bar commands for the main window: a **Go** menu that switches sections with
    /// Command-1 through Command-4, and generation in the **Spines** menu.
    struct BookwormsCommands: Commands {
        let model: AppModel
        let generation: GenerationController

        var body: some Commands {
            CommandMenu("Go") {
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
