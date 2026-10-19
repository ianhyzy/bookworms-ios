#if os(macOS)
    import SwiftUI

    /// What the Mac's Desk commands act on: the desk's scenes, and the bar's switch between
    /// them. Desk's bar publishes it while Desk shows its scene with nothing over it.
    struct DeskCommandTarget {
        let desk: DeskScenes
        /// Whether the dominoes show, so the switch reads **Back to Desk**.
        let isDominoes: Bool
        /// Whether the switch can run now: the Desk scene's books have finished dropping.
        let canSwitch: Bool
        /// **Set Up Dominoes** or **Back to Desk**, as the bar's button does.
        let switchScene: () -> Void
    }

    extension FocusedValues {
        @Entry var deskCommands: DeskCommandTarget?
        /// Whether a sheet covers the Desk scene, such as the **Share desk** sheet.
        @Entry var deskSheetShows: Bool?
    }

    /// The menu bar's Desk commands: **Zoom In** and **Zoom Out** in the **View** menu for
    /// either scene, **Actual Size** for the Desk scene, and the switch to the dominoes and
    /// back in the **Desk** menu. They are unavailable while another section shows, or while
    /// details or a sheet cover the scene.
    struct DeskCommands: Commands {
        /// How much each **Zoom In** zooms, and each **Zoom Out** undoes.
        private static let zoomStep: CGFloat = 1.25

        @FocusedValue(\.deskCommands) private var shown
        @FocusedValue(\.deskSheetShows) private var sheetShows

        var body: some Commands {
            let target = sheetShows == true ? nil : shown
            CommandGroup(after: .toolbar) {
                let desk = target?.desk
                Section {
                    Button("Zoom In") { desk?.moveCamera(magnification: Self.zoomStep) }
                        .keyboardShortcut("+")
                    Button("Zoom Out") { desk?.moveCamera(magnification: 1 / Self.zoomStep) }
                        .keyboardShortcut("-")
                    Button("Actual Size") { desk?.zoomToActualSize() }
                        .keyboardShortcut("0")
                        .disabled(target?.isDominoes != false)
                }
                .disabled(desk == nil)
            }
            CommandMenu("Desk") {
                Button(target?.isDominoes == true ? "Back to Desk" : "Set Up Dominoes") {
                    target?.switchScene()
                }
                .disabled(target?.canSwitch != true)
            }
        }
    }
#endif
