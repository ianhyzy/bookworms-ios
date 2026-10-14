/// The device noun for user-facing text: "Mac" in the Mac Catalyst build and "iPhone" elsewhere.
enum ThisDevice {
    #if targetEnvironment(macCatalyst)
        static let name = "Mac"
    #else
        static let name = "iPhone"
    #endif
}
