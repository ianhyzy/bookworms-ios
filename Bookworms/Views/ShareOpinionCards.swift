import SwiftUI

/// The reader's review of one book under its cover, title, and rating.
///
/// A long review shows as an excerpt that ends at a word with an ellipsis. The text takes the
/// largest size at which it fits whole, so a short review reads like a pull quote, and the cover
/// then takes the largest height that leaves the text that size. Past the smallest size and
/// cover, the text truncates at the bottom.
struct ReviewCard: View {
    let input: ShareInput

    var body: some View {
        if let book = input.books.first, let review = book.reviewText {
            card(book, review: review)
        }
    }

    /// The review's longest excerpt, its type sizes, largest first, and the cover heights,
    /// tallest first.
    private var metrics: (limit: Int, sizes: [CGFloat], covers: [CGFloat]) {
        switch input.aspect {
        case .story: (720, [120, 96, 84, 72, 60, 52, 46, 40, 36], [680, 600, 520, 440])
        case .portrait: (440, [100, 80, 68, 60, 52, 46, 40, 36, 32], [500, 440, 390, 340])
        case .square: (300, [80, 64, 56, 52, 46, 40, 36, 32, 30], [380, 330, 300, 270])
        }
    }

    private func card(_ book: CloudBook, review: String) -> some View {
        let aspect = input.aspect
        let theme = input.theme
        let metrics = metrics
        let excerpt = ShareStyle.excerpt(review, limit: metrics.limit)
        let options = metrics.sizes.flatMap { size in metrics.covers.map { (size, $0) } }
        return ZStack {
            // A glow in the spine's color family behind the cover, fading to a dark field for the
            // text.
            RadialGradient(
                stops: [
                    .init(color: theme.glow.color, location: 0),
                    .init(color: theme.backdropDark.color, location: 1),
                ],
                center: UnitPoint(x: 0.25, y: aspect == .story ? 0.25 : 0.2), startRadius: 0,
                endRadius: aspect.size.width)
            ViewThatFits(in: .vertical) {
                ForEach(options.indices, id: \.self) { index in
                    content(
                        book, excerpt: excerpt, size: options[index].0,
                        coverHeight: options[index].1)
                }
            }
            .foregroundStyle(ShareStyle.cream.color)
            .padding(aspect.insets)
        }
    }

    private func content(_ book: CloudBook, excerpt: String, size: CGFloat, coverHeight: CGFloat)
        -> some View
    {
        let aspect = input.aspect
        let look = input.look(for: book)
        let theme = input.theme
        return VStack(alignment: .leading, spacing: aspect == .story ? 64 : 40) {
            HStack(spacing: 44) {
                ShareCover(
                    book: book, look: look, cover: input.covers[book.id],
                    style: input.coverStyle, height: coverHeight,
                    yaw: 0.5 + (ShareStyle.unit(input.seed, book.id, 4) - 0.5) * 0.12
                )
                .shadow(color: .black.opacity(0.5), radius: 28, y: 20)
                VStack(alignment: .leading, spacing: 14) {
                    ShareStyle.label("My review").foregroundStyle(ShareStyle.gold)
                    ShareFittingText(
                        forms: ShareStyle.titles(book), size: aspect == .square ? 52 : 60,
                        minimumScale: 0.6, lines: 3, book: book
                    ) {
                        ShareStyle.serif($0, .semibold)
                    }
                    // The title starts beside the cover, close to the glow's center.
                    .environment(\.bookTextGround, theme.glow)
                    Text(SpineView.shortAuthor(book.author))
                        .font(ShareStyle.serif(36))
                        .opacity(0.85)
                        .lineLimit(2)
                        .minimumScaleFactor(30 / 36)
                    if input.showsRatings, let rating = book.rating, rating > 0 {
                        ShareStars(rating: rating, size: 38)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The review beside a gold rule.
            BookText(excerpt, of: book)
                .font(ShareStyle.serif(size))
                .lineSpacing(size * 0.18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 34)
                .background(alignment: .leading) {
                    Capsule().fill(ShareStyle.gold).frame(width: 6)
                }
        }
    }
}

/// Up to three books whose rating differs most from Hardcover's readers, or from another
/// reader's (`ShareInput.social`), with both ratings and the gap in stars.
///
/// Several takes stack as rows that share the height below the heading. A single take gets a
/// cover that fills that height instead. Compared with another reader, the card ends with the
/// invitation to compare on Hardcover.
struct HotTakesCard: View {
    let input: ShareInput

    var body: some View {
        let theme = input.theme
        ZStack {
            LinearGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                startPoint: .top, endPoint: .bottom)
            if let social = input.social {
                VStack(spacing: 24) {
                    takes.frame(maxHeight: .infinity)
                    ShareInviteLine(username: social.owner.username)
                }
                .foregroundStyle(ShareStyle.cream.color)
                .padding(input.aspect.reachingInsets)
            } else {
                takes
                    .foregroundStyle(ShareStyle.cream.color)
                    .padding(input.aspect.reachingInsets)
            }
        }
    }

    private var takes: some View {
        let aspect = input.aspect
        let isHero = input.books.count == 1
        let theme = input.theme
        let spacing = (aspect == .square ? 24 : 36) + extra
        return VStack(alignment: isHero && aspect != .square ? .center : .leading, spacing: spacing)
        {
            VStack(alignment: isHero && aspect != .square ? .center : .leading, spacing: 8) {
                Text(heading)
                    .font(ShareStyle.serif(aspect == .story ? 84 : 68, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(subtitle)
                    .font(.system(size: 32, weight: .medium))
                    .opacity(0.75)
                    .lineLimit(1)
                    .minimumScaleFactor(30 / 32)
            }
            if isHero, let book = input.books.first {
                hero(book)
            } else {
                let panel = theme.panel().color
                // One slot for every cover, as wide as the widest, so each row's text starts
                // at the same x.
                let slot = input.books
                    .map {
                        ShareCover.aspect(of: input.covers[$0.id], style: input.coverStyle)
                    }
                    .max()
                GeometryReader { proxy in
                    let count = CGFloat(input.books.count)
                    let height = min(
                        maximumRowHeight, (proxy.size.height - spacing * (count - 1)) / count)
                    VStack(spacing: spacing) {
                        ForEach(input.books) { book in
                            row(book, coverAspect: slot ?? 2 / 3, panel: panel, height: height)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }

    /// The height each gap adds on a story, whose content reaches into the bottom strip
    /// (`ShareAspect.reach`), so the covers keep the sizes they have within `ShareAspect.insets`.
    /// The gaps under the heading and between the rows share it evenly, or for a single take,
    /// the four gaps under the heading, under the cover, and above the difference and the
    /// ratings.
    private var extra: CGFloat {
        input.aspect.reach / CGFloat(input.books.count == 1 ? 4 : max(1, input.books.count))
    }

    /// The tallest a take's row grows, so two takes do not turn into posters.
    private var maximumRowHeight: CGFloat {
        switch input.aspect {
        case .story: 570
        case .portrait: 450
        case .square: 375
        }
    }

    /// Who the takes compare with: the other reader's short name, or Hardcover's readers.
    private var rival: (name: String, label: String) {
        guard let reader = input.social?.reader else { return ("Hardcover readers", "Hardcover") }
        return (reader.shortName, reader.shortName)
    }

    /// The rating the reader's is compared with.
    private func rivalRating(_ book: CloudBook) -> Double? {
        guard let match = input.social?.match else { return book.communityRating }
        return match.theirRating(for: book.id)
    }

    /// "Hot takes of 2025", "Hot takes of August 2025", or "My all-time hot takes".
    private var heading: String {
        input.frame == .lifetime ? "My all-time hot takes" : "Hot takes of \(input.period)"
    }

    /// "Books I loved more than Hardcover readers did", in the picker's words, or "A book I…"
    /// for a single take. With another reader, their short name replaces Hardcover readers.
    private var subtitle: String {
        let subject = input.books.count == 1 ? "A book" : "Books"
        return "\(subject) I \(input.direction.title.lowercased()) than \(rival.name) did"
    }

    /// One take: a cover as large as the room allows, with the title, the gap, and both
    /// ratings below it, or beside it on a square.
    @ViewBuilder
    private func hero(_ book: CloudBook) -> some View {
        let isSquare = input.aspect == .square
        let ratio = ShareCover.aspect(of: input.covers[book.id], style: input.coverStyle)
        // A turned 3D book draws up to about 10 percent taller than its height.
        let fill: CGFloat = input.coverStyle == .threeD ? 0.9 : 1
        let cover = GeometryReader { proxy in
            ShareCover(
                book: book, look: input.look(for: book), cover: input.covers[book.id],
                style: input.coverStyle,
                height: min(proxy.size.height * fill, proxy.size.width * 0.86 / ratio),
                yaw: 0.55 + (ShareStyle.unit(input.seed, book.id, 6) - 0.5) * 0.12
            )
            .shadow(color: .black.opacity(0.5), radius: 32, y: 24)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        let alignment: HorizontalAlignment = isSquare ? .leading : .center
        let details = VStack(alignment: alignment, spacing: 12 + extra) {
            VStack(alignment: alignment, spacing: 12) {
                ShareFittingText(
                    forms: ShareStyle.titles(book), size: isSquare ? 52 : 60, minimumScale: 0.6,
                    lines: 2, book: book
                ) {
                    ShareStyle.serif($0, .semibold)
                }
                Text(SpineView.shortAuthor(book.author))
                    .font(ShareStyle.serif(36))
                    .opacity(0.8)
                    .lineLimit(1)
            }
            gap(book, size: 88)
            ratings(book)
        }
        .multilineTextAlignment(isSquare ? .leading : .center)
        // The stack would otherwise shrink the title to share height it has to spare.
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        if isSquare {
            HStack(spacing: 40) {
                cover.frame(width: 470)
                details.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 40 + extra) {
                cover
                details
            }
        }
    }

    /// One take in a row `height` tall on `panel`, its cover centered in a slot `coverAspect`
    /// times as wide as the cover is tall.
    private func row(_ book: CloudBook, coverAspect: CGFloat, panel: Color, height: CGFloat)
        -> some View
    {
        let look = input.look(for: book)
        let isSquare = input.aspect == .square
        let coverHeight = height - 56
        return HStack(spacing: 28) {
            ShareCover(
                book: book, look: look, cover: input.covers[book.id], style: input.coverStyle,
                height: coverHeight,
                yaw: 0.5 + (ShareStyle.unit(input.seed, book.id, 6) - 0.5) * 0.12
            )
            .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
            .frame(width: coverHeight * coverAspect)
            VStack(alignment: .leading, spacing: 10) {
                ShareFittingText(
                    forms: ShareStyle.titles(book), size: isSquare ? 38 : 42, minimumScale: 0.8,
                    lines: isSquare ? 1 : 2, book: book
                ) {
                    ShareStyle.serif($0, .semibold)
                }
                Text(SpineView.shortAuthor(book.author))
                    .font(.system(size: 30))
                    .opacity(0.75)
                    .lineLimit(1)
                ratings(book).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            gap(book, size: isSquare ? 56 : 64)
        }
        .padding(28)
        .frame(height: height)
        .background(panel, in: .rect(cornerRadius: 28))
    }

    /// The gap in stars between the reader's rating and the rival rating, in gold.
    private func gap(_ book: CloudBook, size: CGFloat) -> some View {
        let gap: Double? =
            if input.social == nil {
                book.ratingGap
            } else if let mine = book.rating, let other = rivalRating(book) {
                mine - other
            } else {
                nil
            }
        let text = Self.signed(gap ?? 0)
        return Text(text)
            .font(ShareStyle.serif(size, .bold))
            .foregroundStyle(ShareStyle.gold)
            .fixedSize()
            .accessibilityLabel("\(text) stars")
    }

    /// The reader's stars over the rival's, in aligned columns.
    private func ratings(_ book: CloudBook) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            if let rating = book.rating {
                ratingRow("Me", rating: rating, isMuted: false)
            }
            if let other = rivalRating(book) {
                ratingRow(rival.label, rating: other, isMuted: true)
            }
        }
    }

    private func ratingRow(_ label: String, rating: Double, isMuted: Bool) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 30, weight: .medium))
                .opacity(isMuted ? 0.7 : 1)
                // A long name shrinks a little before the stars lose room.
                .minimumScaleFactor(0.8)
            ShareStars(rating: rating, size: 28, isMuted: isMuted)
            Text(rating.formatted(.number.precision(.fractionLength(1))))
                .font(ShareStyle.serif(32, .semibold))
                .opacity(isMuted ? 0.7 : 1)
        }
        .lineLimit(1)
    }

    /// The gap with its sign and one decimal, such as "+1.5" or "−0.8".
    nonisolated static func signed(_ gap: Double) -> String {
        gap.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))
            .replacingOccurrences(of: "-", with: "−")
    }
}
