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
    }

    /// The menu bar's Desk commands: **Zoom In**, **Zoom Out**, and **Actual Size** in the
    /// **View** menu for the Desk scene, and the switch to the dominoes and back in the **Desk**
    /// menu. They are unavailable while another section shows or details cover the scene.
    struct DeskCommands: Commands {
        /// How much each **Zoom In** zooms, and each **Zoom Out** undoes.
        private static let zoomStep: CGFloat = 1.25

        @FocusedValue(\.deskCommands) private var target

        var body: some Commands {
            CommandGroup(after: .toolbar) {
                let pile = target.flatMap { $0.isDominoes ? nil : $0.desk }
                Section {
                    Button("Zoom In") { pile?.moveCamera(magnification: Self.zoomStep) }
                        .keyboardShortcut("+")
                    Button("Zoom Out") { pile?.moveCamera(magnification: 1 / Self.zoomStep) }
                        .keyboardShortcut("-")
                    Button("Actual Size") { pile?.zoomToActualSize() }
                        .keyboardShortcut("0")
                }
                .disabled(pile == nil)
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
