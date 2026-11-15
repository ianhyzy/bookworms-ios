/// Device words for user-facing text: the device noun, the system Settings app as a sentence names
/// it, and the verb for a press, which differ between the macOS build and the iPhone build. On the
/// iPhone, "the Settings app" keeps the system app apart from the app's own **Settings** sheet.
enum ThisDevice {
    #if os(macOS)
        static let name = "Mac"
        static let system = "macOS"
        static let settingsApp = "System Settings"
        static let press = "click"
    #else
        static let name = "iPhone"
        static let system = "iOS"
        static let settingsApp = "the Settings app"
        static let press = "tap"
    #endif
}
