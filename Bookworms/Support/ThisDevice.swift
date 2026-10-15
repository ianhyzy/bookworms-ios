/// The device noun for user-facing text: "Mac" in the macOS build and "iPhone" elsewhere.
enum ThisDevice {
    #if os(macOS)
        static let name = "Mac"
    #else
        static let name = "iPhone"
    #endif
}
