import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// How two readers' tastes compare: their photos, the match score and its name, the books they
/// both loved, and the books they fought over (`TasteMatch`).
///
/// The card draws nothing without a score. Fewer rows fit on smaller sizes: a Story shows two
/// fights, and Portrait and Square one. With no fights, a line says so, and the covers of the
/// books both readers loved start larger. The covers grow into leftover height, and what they
/// leave spreads evenly between the sections.
struct TasteMatchCard: View {
    let input: ShareInput

    var body: some View {
        if let social = input.social, let score = social.match.score {
            card(social, score: score)
        }
    }

    private var metrics: (avatar: CGFloat, score: CGFloat, cover: CGFloat, row: CGFloat) {
        let hasFights = input.social?.match.fights.isEmpty == false
        return switch input.aspect {
        case .story: (130, 200, hasFights ? 250 : 380, 214)
        case .portrait: (116, 170, hasFights ? 210 : 280, 204)
        case .square: (100, 140, hasFights ? 160 : 210, 194)
        }
    }

    private func card(_ social: ShareSocial, score: Int) -> some View {
        let aspect = input.aspect
        let theme = input.theme
        let match = social.match
        let fights = match.fights.prefix(aspect == .story ? 2 : 1)
        return ZStack {
            LinearGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                let gap: CGFloat = aspect == .story ? 32 : 22
                ShareReadersHeader(
                    social: social, label: "Taste match", size: metrics.avatar, theme: theme)
                Spacer(minLength: gap)
                scoreRow(score, match: match)
                Spacer(minLength: gap)
                if !match.agreements.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        ShareStyle.label("We both loved").foregroundStyle(ShareStyle.gold)
                        ShareCoverRow(
                            input: input, books: match.agreements.map(\.book),
                            height: metrics.cover, titleLines: aspect == .square ? 1 : 2)
                    }
                    // The covers grow before the gaps do.
                    .layoutPriority(1)
                    Spacer(minLength: gap)
                }
                VStack(alignment: .leading, spacing: 16) {
                    ShareStyle.label("We fought over").foregroundStyle(ShareStyle.gold)
                    if fights.isEmpty {
                        Text("Not a single fight. Suspicious.")
                            .font(ShareStyle.serif(aspect == .square ? 40 : 46).italic())
                            .opacity(0.9)
                    } else {
                        ForEach(fights) { fight(social, $0, panel: theme.panel().color) }
                    }
                }
                Spacer(minLength: gap)
                ShareInviteLine(username: social.owner.username)
            }
            .foregroundStyle(ShareStyle.cream.color)
            .padding(aspect.insets)
        }
    }

    /// The score in large gold numerals beside its name and the number of books it compares.
    private func scoreRow(_ score: Int, match: TasteMatch) -> some View {
        HStack(alignment: .center, spacing: 32) {
            Text("\(score)%")
                .font(ShareStyle.serif(metrics.score, .bold))
                .foregroundStyle(ShareStyle.gold)
                .fixedSize()
                .accessibilityLabel("\(score) percent match")
            VStack(alignment: .leading, spacing: 8) {
                Text(match.tier ?? "")
                    .font(ShareStyle.serif(input.aspect == .square ? 46 : 54, .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text("\(match.shared.count) books we both rated")
                    .font(.system(size: 32, weight: .medium))
                    .opacity(0.8)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
            }
        }
    }

    /// One book the readers rated far apart: its cover, title, both ratings, and a playful
    /// label, with the gap in stars.
    private func fight(_ social: ShareSocial, _ fight: SharedRating, panel: Color) -> some View {
        let book = fight.book
        let coverHeight = metrics.row - 40
        return HStack(spacing: 24) {
            ShareCover(
                book: book, look: input.look(for: book), cover: input.covers[book.id],
                style: input.coverStyle, height: coverHeight,
                yaw: 0.5 + (ShareStyle.unit(input.seed, book.id, 6) - 0.5) * 0.12
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 10)
            VStack(alignment: .leading, spacing: 4) {
                ShareFittingText(
                    forms: ShareStyle.titles(book), size: 38, minimumScale: 0.8, book: book
                ) {
                    ShareStyle.serif($0, .semibold)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ratingRow("Me", rating: fight.mine, isMuted: false)
                    ratingRow(social.reader.shortName, rating: fight.theirs, isMuted: true)
                }
                Text(TasteMatch.fightLabel(fight.distance))
                    .font(.system(size: 28, weight: .semibold).italic())
                    .foregroundStyle(ShareStyle.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(height: metrics.row)
        .background(panel, in: .rect(cornerRadius: 28))
    }

    private func ratingRow(_ label: String, rating: Double, isMuted: Bool) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 28, weight: .medium))
                .opacity(isMuted ? 0.75 : 1)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            ShareStars(rating: rating, size: 24, isMuted: isMuted)
        }
    }
}

/// Each reader's favorites that the other hasn't shelved (`TasteMatch.forThem` and `forMe`):
/// up to three covers for each, with the recommending reader's stars.
///
/// A side without picks says so in a line instead, and the other side's covers start larger.
/// The covers grow into leftover height, and what they leave spreads evenly between the
/// sections.
struct BookSwapCard: View {
    let input: ShareInput

    var body: some View {
        if let social = input.social {
            card(social)
        }
    }

    private var metrics: (avatar: CGFloat, cover: CGFloat, stars: CGFloat) {
        let match = input.social?.match
        let scale: CGFloat =
            match?.forThem.isEmpty == false && match?.forMe.isEmpty == false ? 1 : 1.3
        return switch input.aspect {
        case .story: (130, 320 * scale, 30)
        case .portrait: (116, 228 * scale, 26)
        case .square: (100, 170 * scale, 22)
        }
    }

    private func card(_ social: ShareSocial) -> some View {
        let aspect = input.aspect
        let theme = input.theme
        let match = social.match
        let other = social.reader.shortName
        return ZStack {
            LinearGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                let gap: CGFloat = aspect == .story ? 40 : 24
                ShareReadersHeader(
                    social: social, label: "Book swap", size: metrics.avatar, theme: theme)
                Spacer(minLength: gap)
                // The covers grow before the gaps do.
                side(
                    "\(other), read this next", books: match.forThem, isMuted: false,
                    empty: "\(other) has read all my favorites."
                )
                .layoutPriority(1)
                Spacer(minLength: gap)
                side(
                    "My next reads, from \(other)", books: match.forMe, isMuted: true,
                    empty: "I've read all of \(other)'s favorites."
                )
                .layoutPriority(1)
                Spacer(minLength: gap)
                ShareInviteLine(username: social.owner.username)
            }
            .foregroundStyle(ShareStyle.cream.color)
            .padding(aspect.insets)
        }
    }

    /// One reader's picks under a label, with the recommender's stars, or `empty` without any.
    private func side(_ label: String, books: [CloudBook], isMuted: Bool, empty: String)
        -> some View
    {
        VStack(alignment: .leading, spacing: 16) {
            ShareStyle.label(label)
                .foregroundStyle(ShareStyle.gold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if books.isEmpty {
                Text(empty)
                    .font(ShareStyle.serif(input.aspect == .square ? 38 : 44).italic())
                    .opacity(0.9)
            } else {
                ShareCoverRow(
                    input: input, books: books, height: metrics.cover,
                    titleLines: input.aspect == .square ? 1 : 2,
                    stars: (size: metrics.stars, isMuted: isMuted))
            }
        }
    }
}

/// Both readers' photos, overlapping, beside the card's label and their names, such as
/// "Avery & Robin".
struct ShareReadersHeader: View {
    let social: ShareSocial
    let label: String
    let size: CGFloat
    let theme: ShareTheme

    var body: some View {
        HStack(spacing: 28) {
            HStack(spacing: -size * 0.22) {
                ShareAvatar(
                    profile: social.owner, image: social.avatars[social.owner.id], size: size,
                    fill: theme.panel(0))
                ShareAvatar(
                    profile: social.reader, image: social.avatars[social.reader.id], size: size,
                    fill: theme.panel(1))
            }
            VStack(alignment: .leading, spacing: 6) {
                ShareStyle.label(label).foregroundStyle(ShareStyle.gold)
                ShareFittingText(
                    forms: ["\(social.owner.shortName) & \(social.reader.shortName)"],
                    size: size * 0.5, minimumScale: 0.6
                ) {
                    ShareStyle.serif($0, .semibold)
                }
            }
        }
    }
}

/// A reader's profile photo in a cream ring, or their initials without one.
struct ShareAvatar: View {
    let profile: ReaderProfile
    let image: UIImage?
    let size: CGFloat
    let fill: ColorValue

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    fill.color
                    Text(Self.initials(profile))
                        .font(ShareStyle.serif(size * 0.4, .semibold))
                        .foregroundStyle(ShareStyle.cream.color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay { Circle().strokeBorder(ShareStyle.cream.color, lineWidth: max(3, size * 0.035)) }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        .accessibilityHidden(true)
    }

    /// The first letters of the first two words of the name, or the username's first letter.
    static func initials(_ profile: ReaderProfile) -> String {
        let words = (profile.name ?? "").split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return (letters.isEmpty ? String(profile.username.prefix(1)) : letters).uppercased()
    }
}

/// Up to three covers in a row, standing on one line, each with its title below and,
/// optionally, the book's rating in stars.
///
/// The covers' row is at least `height` tall and grows by up to 40 percent into height the card
/// has to spare; the covers fill it as far as their column's width allows.
struct ShareCoverRow: View {
    let input: ShareInput
    let books: [CloudBook]
    let height: CGFloat
    let titleLines: Int
    var stars: (size: CGFloat, isMuted: Bool)?

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(books.prefix(TasteMatch.limit)) { book in
                let cover = input.covers[book.id]
                let ratio = ShareCover.aspect(of: cover, style: input.coverStyle)
                VStack(spacing: 12) {
                    GeometryReader { proxy in
                        // A turned 3D book draws up to about 10 percent taller than its height.
                        ShareCover(
                            book: book, look: input.look(for: book), cover: cover,
                            style: input.coverStyle,
                            height: min(proxy.size.height * 0.9, proxy.size.width * 0.95 / ratio),
                            yaw: 0.5 + (ShareStyle.unit(input.seed, book.id, 6) - 0.5) * 0.12
                        )
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 14)
                        .frame(
                            width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                    }
                    .frame(minHeight: height, maxHeight: height * 1.4)
                    if let stars, let rating = book.rating {
                        ShareStars(rating: rating, size: stars.size, isMuted: stars.isMuted)
                    }
                    ShareFittingText(
                        forms: ShareStyle.titles(book), size: 30, minimumScale: 0.85,
                        lines: titleLines, book: book
                    ) {
                        ShareStyle.serif($0, .semibold)
                    }
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The invitation a social image ends with: compare takes on Hardcover, and the sharer's
/// profile link (`HardcoverInvite`), on one line when it fits, else on two.
struct ShareInviteLine: View {
    let username: String

    var body: some View {
        let line = Text(HardcoverInvite.line).opacity(0.85)
        let link = Text(HardcoverInvite.link(username))
            .fontWeight(.semibold)
            .foregroundStyle(ShareStyle.gold)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                line
                Text("·").opacity(0.6)
                link
            }
            VStack(spacing: 4) {
                line
                link
            }
        }
        .font(.system(size: 30, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }
}
