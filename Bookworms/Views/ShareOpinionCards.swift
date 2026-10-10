import SwiftUI

/// The reader's review of one book under its cover, title, and rating.
///
/// A long review shows as an excerpt that ends at a word with an ellipsis. The text takes the
/// largest size that fits, so a short review reads like a pull quote.
struct ReviewCard: View {
    let input: ShareInput

    var body: some View {
        if let book = input.books.first, let review = book.reviewText {
            card(book, review: review)
        }
    }

    private func card(_ book: CloudBook, review: String) -> some View {
        let aspect = input.aspect
        let look = input.look(for: book)
        let edge = ShareStyle.backdrop(look.background, 0.8)
        let coverHeight: CGFloat =
            switch aspect {
            case .story: 440
            case .portrait: 340
            case .square: 270
            }
        return ZStack {
            // A glow from the spine's colors behind the cover, fading to a dark field for the text.
            RadialGradient(
                stops: [
                    .init(
                        color:
                            ShareStyle.backdrop(look.background.mixed(with: look.accent, 0.3), 0.3)
                            .color,
                        location: 0),
                    .init(color: edge.color, location: 1),
                ],
                center: UnitPoint(x: 0.25, y: aspect == .story ? 0.25 : 0.2), startRadius: 0,
                endRadius: aspect.size.width)
            VStack(alignment: .leading, spacing: aspect == .story ? 64 : 40) {
                HStack(spacing: 44) {
                    ShareCover(
                        book: book, look: look, cover: input.covers[book.id],
                        style: input.coverStyle, height: coverHeight,
                        yaw: 0.5 + (ShareStyle.unit(input.seed, book.id, 4) - 0.5) * 0.12
                    )
                    .shadow(color: .black.opacity(0.5), radius: 28, y: 20)
                    VStack(alignment: .leading, spacing: 14) {
                        ShareStyle.label("My review").foregroundStyle(ShareStyle.gold)
                        Text(book.spineTitle)
                            .font(ShareStyle.serif(aspect == .square ? 52 : 60, .semibold))
                            .lineLimit(3)
                            .minimumScaleFactor(0.6)
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
                quote(review)
            }
            .foregroundStyle(ShareStyle.cream.color)
            .padding(aspect.insets)
        }
    }

    /// The review beside a gold rule, at the largest size whose full text fits. Past the
    /// smallest size, the text truncates at the bottom.
    private func quote(_ review: String) -> some View {
        let (limit, sizes): (Int, [CGFloat]) =
            switch input.aspect {
            case .story: (720, [72, 60, 52, 46, 40, 36])
            case .portrait: (440, [60, 52, 46, 40, 36, 32])
            case .square: (300, [52, 46, 40, 36, 32, 30])
            }
        let excerpt = ShareStyle.excerpt(review, limit: limit)
        return ViewThatFits(in: .vertical) {
            ForEach(sizes, id: \.self) { size in
                Text(excerpt)
                    .font(ShareStyle.serif(size))
                    .lineSpacing(size * 0.18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 34)
        .background(alignment: .leading) {
            Capsule().fill(ShareStyle.gold).frame(width: 6)
        }
    }
}

/// Up to three books whose rating differs most from Hardcover's readers, with both ratings and
/// the gap in stars.
///
/// Several takes stack as rows. A single take gets a large cover instead, so the card does not
/// leave most of its height empty.
struct HotTakesCard: View {
    let input: ShareInput

    var body: some View {
        let aspect = input.aspect
        let isHero = input.books.count == 1
        let stops = input.books.map {
            ShareStyle.backdrop(input.look(for: $0).background, 0.6).color
        }
        ZStack {
            LinearGradient(
                colors: stops.count > 1 ? stops : [stops.first ?? .black, stops.first ?? .black],
                startPoint: .top, endPoint: .bottom)
            VStack(
                alignment: isHero && aspect != .square ? .center : .leading,
                spacing: aspect == .square ? 24 : 36
            ) {
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
                    ForEach(input.books) { book in row(book) }
                }
            }
            .foregroundStyle(ShareStyle.cream.color)
            .padding(aspect.insets)
        }
    }

    /// "Hot takes of 2025", "Hot takes of August 2025", or "My all-time hot takes".
    private var heading: String {
        input.frame == .lifetime ? "My all-time hot takes" : "Hot takes of \(input.period)"
    }

    /// "Books I loved more than Hardcover readers did", in the picker's words, or "A book I…"
    /// for a single take.
    private var subtitle: String {
        let subject = input.books.count == 1 ? "A book" : "Books"
        return "\(subject) I \(input.direction.title.lowercased()) than Hardcover readers did"
    }

    /// One take: a large cover with the title, the gap, and both ratings below it, or beside
    /// it on a square.
    @ViewBuilder
    private func hero(_ book: CloudBook) -> some View {
        let isSquare = input.aspect == .square
        let cover = ShareCover(
            book: book, look: input.look(for: book), cover: input.covers[book.id],
            style: input.coverStyle,
            height: isSquare ? 560 : input.aspect == .story ? 640 : 440,
            yaw: 0.55 + (ShareStyle.unit(input.seed, book.id, 6) - 0.5) * 0.12
        )
        .shadow(color: .black.opacity(0.5), radius: 32, y: 24)
        let details = VStack(alignment: isSquare ? .leading : .center, spacing: 12) {
            Text(book.spineTitle)
                .font(ShareStyle.serif(isSquare ? 52 : 60, .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(SpineView.shortAuthor(book.author))
                .font(ShareStyle.serif(36))
                .opacity(0.8)
                .lineLimit(1)
            gap(book, size: 88)
            ratings(book)
        }
        .multilineTextAlignment(isSquare ? .leading : .center)
        // The stack would otherwise shrink the title to share height it has to spare.
        .fixedSize(horizontal: false, vertical: true)
        if isSquare {
            HStack(spacing: 40) {
                cover
                details.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 40) {
                cover
                details
            }
        }
    }

    private func row(_ book: CloudBook) -> some View {
        let look = input.look(for: book)
        let isSquare = input.aspect == .square
        let base: CGFloat =
            switch input.aspect {
            case .story: 380
            case .portrait: 300
            case .square: 250
            }
        // Two takes get taller rows than three, so the card stays full.
        let height = input.books.count == 2 ? base * 1.25 : base
        return HStack(spacing: 28) {
            ShareCover(
                book: book, look: look, cover: input.covers[book.id], style: input.coverStyle,
                height: height - 56,
                yaw: 0.5 + (ShareStyle.unit(input.seed, book.id, 6) - 0.5) * 0.12
            )
            .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
            VStack(alignment: .leading, spacing: 10) {
                Text(book.spineTitle)
                    .font(ShareStyle.serif(isSquare ? 38 : 42, .semibold))
                    .lineLimit(isSquare ? 1 : 2)
                    .minimumScaleFactor(0.8)
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
        .background(ShareStyle.backdrop(look.background, 0.5).color, in: .rect(cornerRadius: 28))
    }

    /// The gap in stars between the reader's rating and Hardcover's average, in gold.
    private func gap(_ book: CloudBook, size: CGFloat) -> some View {
        let text = Self.signed(book.ratingGap ?? 0)
        return Text(text)
            .font(ShareStyle.serif(size, .bold))
            .foregroundStyle(ShareStyle.gold)
            .fixedSize()
            .accessibilityLabel("\(text) stars")
    }

    /// The reader's stars over Hardcover's, in aligned columns.
    private func ratings(_ book: CloudBook) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            if let rating = book.rating {
                ratingRow("Me", rating: rating, isMuted: false)
            }
            if let community = book.communityRating {
                ratingRow("Hardcover", rating: community, isMuted: true)
            }
        }
    }

    private func ratingRow(_ label: String, rating: Double, isMuted: Bool) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 30, weight: .medium))
                .opacity(isMuted ? 0.7 : 1)
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
