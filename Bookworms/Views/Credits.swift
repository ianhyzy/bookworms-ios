import SwiftUI

extension URL {
    /// The privacy policy that the App Store listings and the Apple TV app share, which the
    /// iPhone's settings and the Mac's **Help** menu open.
    static let privacyPolicy = URL(string: "https://ian.gay/bookworms-privacy-policy/")!
}

#if os(iOS)
    /// The iPhone settings' **Credits**: the attributions in `Credits.rtf`, which the Mac shows
    /// in **About Bookworms**. The text keeps the file's links but not its fonts, so it follows
    /// Dynamic Type and the appearance.
    struct CreditsView: View {
        var body: some View {
            Form { Text(Self.credits) }
                .navigationTitle("Credits")
                .navigationBarTitleDisplayMode(.inline)
        }

        private static let credits: AttributedString = {
            guard let url = Bundle.main.url(forResource: "Credits", withExtension: "rtf"),
                let text = try? NSAttributedString(
                    url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil)
            else { return "" }
            return (try? AttributedString(text, including: \.foundation))
                ?? AttributedString(text.string)
        }()
    }
#endif
