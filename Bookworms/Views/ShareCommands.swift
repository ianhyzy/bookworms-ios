#if os(macOS)
    import AppKit
    import SwiftUI

    /// The Share tab's menu commands on the Mac: **File > Save Image…** (Command-S), **Edit >
    /// Copy Image**, **View > Quick Look** (Command-Y), and the system's **Show Inspector**,
    /// which shows or hides the studio's settings.
    ///
    /// They act on the image the Share tab shows in the key window (`ShareStudioView`), and dim
    /// while another tab shows or while a newer image is on its way.
    struct ShareCommands: Commands {
        @FocusedValue(\.shareImage) private var image
        @FocusedValue(\.saveShareImage) private var save
        @FocusedValue(\.previewShareImage) private var preview

        var body: some Commands {
            CommandGroup(after: .saveItem) {
                Button("Save Image…") { save?() }
                    .keyboardShortcut("s")
                    .disabled(save == nil)
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Image") { image.map(Self.copy) }
                    .disabled(image == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Quick Look") { preview?() }
                    .keyboardShortcut("y")
                    .disabled(preview == nil)
            }
            InspectorCommands()
        }

        /// Puts `image` on the pasteboard with its credit, as a PNG and a TIFF, which every app
        /// that pastes images takes.
        @MainActor static func copy(_ image: ShareImage) {
            guard let credited = image.image.withShareCredit(), let png = credited.pngData(),
                let tiff = credited.tiffRepresentation
            else { return NSSound.beep() }
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setData(tiff, forType: .tiff)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
        }
    }
#endif
