import SwiftUI

/// The reader's Hardcover photo and name, over "@username on Hardcover", at the bottom right of
/// Review's card in place of the profile link (`ShareProfileLink`).
///
/// A reader without a photo shows their initials, and one without a name shows their username
/// in its place, over "on Hardcover".
struct ShareByline: View {
    let profile: ReaderProfile
    let avatar: UIImage?
    let aspect: ShareAspect
    let theme: ShareTheme

    /// Portrait and Square letter the byline smaller, as they do the rest of the card.
    private var scale: CGFloat { aspect == .story ? 1 : 0.85 }

    var body: some View {
        HStack(spacing: 24 * scale) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(profile.displayName)
                    .font(ShareStyle.serif(44 * scale, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(profile.hardcoverHandle)
                    .font(ShareStyle.serif(30 * scale))
                    .opacity(0.75)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            ShareAvatar(profile: profile, image: avatar, size: 96 * scale, fill: theme.panel())
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The reader's Hardcover photo, name, and "@username on Hardcover", centered at the bottom of
/// Currently Reading in place of the profile link: a smaller, quieter signature than Review's
/// byline (`ShareByline`), centered as the card's book and title are.
///
/// A reader without a photo shows their initials, and one without a name shows their username
/// in its place, followed by "on Hardcover".
struct ShareReaderChip: View {
    /// How the chip arranges the photo and words. The card picks one from its layout
    /// (`designs(for:)`).
    enum Design {
        /// The photo over the name, over "@username on Hardcover", each line centered.
        case stacked
        /// One line, centered as a unit: the photo, then "Avery Quill · @averyreads on
        /// Hardcover".
        case row
    }

    /// The designs a card of `aspect` tries, in order, keeping the first that fits: Square,
    /// the shortest size, always uses the row. Story and Portrait use the stacked chip unless it
    /// would leave the book's space shorter than `minimumHeroHeight(_:)`, as long details can.
    static func designs(for aspect: ShareAspect) -> [Design] {
        aspect == .square ? [.row] : [.stacked, .row]
    }

    /// The least height that a stacked chip leaves the space of the card's book, which draws the
    /// book a little shorter: 40 percent of the image's height, 768 pixels on a story and 540 on
    /// a portrait.
    static func minimumHeroHeight(_ aspect: ShareAspect) -> CGFloat { aspect.size.height * 0.4 }

    let profile: ReaderProfile
    let avatar: UIImage?
    let design: Design
    let aspect: ShareAspect
    let theme: ShareTheme

    /// Portrait and Square letter the chip smaller, as they do the rest of the card.
    private var scale: CGFloat { aspect == .story ? 1 : 0.85 }

    var body: some View {
        Group {
            switch design {
            case .stacked:
                VStack(spacing: 14 * scale) {
                    photo(64)
                    VStack(spacing: 2) {
                        Text(profile.displayName)
                            .font(ShareStyle.serif(34 * scale, .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(profile.hardcoverHandle)
                            .font(ShareStyle.serif(28 * scale))
                            .opacity(0.75)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .multilineTextAlignment(.center)
            case .row:
                HStack(spacing: 18 * scale) {
                    photo(56)
                    let handle = profile.hardcoverHandle
                    let rest = Text(handle.hasPrefix("@") ? "· \(handle)" : handle)
                        .foregroundStyle(ShareStyle.cream.color.opacity(0.75))
                    Text("\(Text(profile.displayName).fontWeight(.semibold)) \(rest)")
                        .font(ShareStyle.serif(32 * scale))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func photo(_ size: CGFloat) -> some View {
        ShareAvatar(profile: profile, image: avatar, size: size * scale, fill: theme.panel())
    }
}

extension ReaderProfile {
    /// Where to find the reader, under or after their name: "@username on Hardcover", or
    /// "on Hardcover" after a username that stands in for a missing name (`displayName`).
    var hardcoverHandle: String {
        displayName == "@\(username)" ? "on Hardcover" : "@\(username) on Hardcover"
    }
}
