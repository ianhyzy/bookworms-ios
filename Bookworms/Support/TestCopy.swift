#if os(macOS)
    import AppKit
    import CoreImage
#endif

/// Tells a test copy of the Mac app from the installed app, so the two never look alike: a test
/// copy shows its icon in grayscale and says **Test copy** in each window's title bar.
enum TestCopy {
    /// The installed Mac app's bundle ID, which `script/run_mac.sh` sets.
    static let macBundleID = "gay.ian.Bookworms.Mac"

    /// Whether a Mac app with `bundleID` is a test copy: every build but the installed app's,
    /// such as an Xcode build (`gay.ian.Bookworms.iOS`) or a copy re-signed with a scratch ID.
    static func isTestCopy(bundleID: String?) -> Bool {
        bundleID != macBundleID
    }

    #if os(macOS)
        /// Whether this app is a test copy.
        static let isActive = isTestCopy(bundleID: Bundle.main.bundleIdentifier)

        /// Grays the app's icon in the Dock and labels each window's title bar, from launch on.
        /// The installed app skips both.
        @MainActor static func markIfActive() {
            guard isActive else { return }
            let app = NSApplication.shared
            if let icon = grayscale(app.applicationIconImage) { app.applicationIconImage = icon }
            // SwiftUI owns the windows' titles and subtitles, so each window gets a title bar
            // accessory, which SwiftUI leaves alone: the windows open at launch now, and later
            // ones when they first show.
            app.windows.forEach(label)
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { window.map(label) }
            }
        }

        private static let labelID = NSUserInterfaceItemIdentifier("TestCopyLabel")

        /// Adds **Test copy** to the trailing end of a titled window's title bar, once. Sheets
        /// and panels, such as the Colors panel, keep theirs plain.
        @MainActor private static func label(_ window: NSWindow) {
            guard window.styleMask.contains(.titled), !(window is NSPanel), !window.isSheet,
                !window.titlebarAccessoryViewControllers.contains(where: {
                    $0.identifier == labelID
                })
            else { return }
            let text = NSTextField(labelWithString: "Test copy")
            text.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            text.textColor = .secondaryLabelColor
            text.translatesAutoresizingMaskIntoConstraints = false
            // The title bar stretches a trailing accessory to its full height, and a label draws
            // its text at its top, so a container centers the label and keeps it off the corner.
            let inset: CGFloat = 16
            let container = NSView(
                frame: NSRect(x: 0, y: 0, width: text.fittingSize.width + inset, height: 28))
            container.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                text.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            let accessory = NSTitlebarAccessoryViewController()
            accessory.identifier = labelID
            accessory.view = container
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)
        }

        /// `image` with its color removed and its transparency kept.
        private static func grayscale(_ image: NSImage) -> NSImage? {
            var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
            guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            else { return nil }
            let gray = CIImage(cgImage: source)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            guard let result = CIContext().createCGImage(gray, from: gray.extent) else {
                return nil
            }
            return NSImage(cgImage: result, size: image.size)
        }
    #endif
}
