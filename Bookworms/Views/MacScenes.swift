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
                SpineDesignerSettings()
                Section("Hardcover") {
                    LabeledContent(
                        "Account", value: model.account.isSignedIn ? "Connected" : "Not connected")
                    Button(model.account.isSignedIn ? "Manage Account…" : "Connect Hardcover…") {
                        showsAccount = true
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 520)
            .fixedSize(horizontal: false, vertical: true)
            .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        }
    }

    /// Chooses the model that designs spines: Apple's Private Cloud Compute, a preset provider
    /// with its own API key, or any OpenAI-compatible endpoint.
    ///
    /// Keys go straight to this Mac's Keychain and never show again; the field only replaces or
    /// removes the saved key.
    private struct SpineDesignerSettings: View {
        @Environment(GenerationController.self) private var generation
        @State private var designer = SpineDesigner.current
        @State private var newKey = ""
        @State private var hasKey = false

        var body: some View {
            Section {
                Picker("Model provider", selection: $designer.provider) {
                    ForEach(SpineDesigner.Provider.allCases) { Text($0.name).tag($0) }
                }
                if designer.provider != .apple {
                    TextField("Model", text: $designer.model, prompt: Text("Model name"))
                    if designer.provider == .custom {
                        TextField(
                            "Base URL", text: $designer.baseURL,
                            prompt: Text("https://example.com/v1"))
                    }
                    if hasKey {
                        LabeledContent("API key") {
                            Button("Remove Key", role: .destructive) {
                                designer.provider.key.delete()
                                refresh()
                            }
                        }
                    } else {
                        SecureField("API key", text: $newKey)
                            .onSubmit {
                                guard !newKey.isEmpty else { return }
                                try? designer.provider.key.save(newKey)
                                newKey = ""
                                refresh()
                            }
                    }
                }
            } header: {
                Text("Spine design model")
            } footer: {
                Text(designer.provider == .apple ? Self.appleNote : Self.providerNote)
            }
            .onChange(of: designer.provider) { _, provider in
                designer.model = provider.defaultModel
                designer.baseURL = provider.defaultBaseURL
            }
            .onChange(of: designer) { refresh() }
            .onAppear { hasKey = designer.provider.key.read() != nil }
        }

        private static let appleNote =
            "Apple's model designs spines with Private Cloud Compute, within its daily limit."
        private static let providerNote =
            "The provider receives each cover, its title and author, and the colors and font families to choose from. Requests are billed to your API account. Press Return to save a key; it stays in this Mac's Keychain."

        private func refresh() {
            designer.save()
            hasKey = designer.provider.key.read() != nil
            Task { await generation.refreshModelStatus() }
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
