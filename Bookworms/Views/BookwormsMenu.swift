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
        @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

        var body: some View {
            let designed = model.library?.designs.count ?? 0
            let total = model.library?.books.count ?? 0
            Text("\(designed) of \(total) books designed")
            Text(generation.status.currentBook?.title ?? generation.status.phase)
            Divider()
            if generation.isGenerating {
                Button("Stop") { generation.stop() }
            } else {
                Button("Generate Now") { generation.generateNow() }
            }
            Button("Open Bookworms") {
                openWindow(id: Self.windowID)
                NSApplication.shared.activate()
            }
            .keyboardShortcut("o")
            Toggle("Launch at Login", isOn: $launchesAtLogin)
                .onChange(of: launchesAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // macOS can ask for approval in Login Items; show what it decided.
                        launchesAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Divider()
            Button("Quit Bookworms") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
#endif
