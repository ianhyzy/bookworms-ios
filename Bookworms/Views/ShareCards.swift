import SwiftUI

/// One book, as a 3D book or a flat cover on a backdrop in its spine's color family, with its
/// details: the finish date, rating, and length for Just Finished, or the progress and start
/// date for Currently Reading.
struct FeaturedBookCard: View {
    let input: ShareInput

    var body: some View {
        if let book = input.books.first {
            card(book, look: input.look(for: book))
        }
    }

    private func card(_ book: CloudBook, look: SpineLook) -> some View {
        let aspect = input.aspect
        let isSquare = aspect == .square
        let theme = input.theme
        let edge = theme.backdropDark.color
        return ZStack {
            // A glow behind the book that fades to the dark field.
            RadialGradient(
                stops: [
                    .init(color: theme.glow.color, location: 0),
                    .init(color: theme.backdropLight.color, location: 0.4),
                    .init(color: edge, location: 1),
                ],
                center: isSquare ? UnitPoint(x: 0.27, y: 0.5) : UnitPoint(x: 0.5, y: 0.34),
                startRadius: 0, endRadius: aspect.size.width * 0.9)
            // A long, eased scrim settles the glow into the field behind the text without a
            // visible edge.
            LinearGradient(
                stops: [
                    .init(color: edge.opacity(0), location: isSquare ? 0.32 : 0.42),
                    .init(color: edge.opacity(0.6), location: isSquare ? 0.48 : 0.56),
                    .init(color: edge, location: isSquare ? 0.62 : 0.7),
                ],
                startPoint: isSquare ? .leading : .top, endPoint: isSquare ? .trailing : .bottom)
            Group {
                if isSquare {
                    HStack(spacing: 40) {
                        hero(book, look: look).frame(width: 470)
                        details(book, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 44) {
                        hero(book, look: look)
                        details(book, alignment: .center)
                    }
                }
            }
            .padding(aspect.insets)
        }
    }

    private func hero(_ book: CloudBook, look: SpineLook) -> some View {
        let cover = input.covers[book.id]
        let ratio = ShareCover.aspect(of: cover, style: input.coverStyle)
        return GeometryReader { proxy in
            ShareCover(
                book: book, look: look, cover: cover, style: input.coverStyle,
                height: min(proxy.size.height * 0.88, proxy.size.width * 0.86 / ratio),
                yaw: 0.6 + (ShareStyle.unit(input.seed, book.id, 4) - 0.5) * 0.12,
                pitch: -0.1 + (ShareStyle.unit(input.seed, book.id, 5) - 0.5) * 0.06
            )
            .shadow(color: .black.opacity(0.5), radius: 36, y: 28)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// The title and author, the rating or progress, and the details line, such as "Finished
    /// Nov 30, 2025 · 736 pages", with wider gaps between these groups than within them.
    private func details(_ book: CloudBook, alignment: HorizontalAlignment) -> some View {
        let isSquare = input.aspect == .square
        let isReading = input.template == .currentlyReading
        let details = ShareStyle.details(book, isReading: isReading)
        return VStack(alignment: alignment, spacing: 36) {
            VStack(alignment: alignment, spacing: 14) {
                if isReading {
                    ShareStyle.label("Currently reading").foregroundStyle(ShareStyle.gold)
                }
                ShareFittingText(
                    forms: ShareStyle.titles(book), size: isSquare ? 64 : 80, minimumScale: 0.5,
                    lines: isSquare ? 4 : 3, book: book
                ) {
                    ShareStyle.serif($0, .semibold)
                }
                Text(SpineView.shortAuthor(book.author))
                    .font(ShareStyle.serif(40))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            if isReading {
                if let progress = book.progress {
                    progressBar(progress, width: isSquare ? 250 : 440)
                }
            } else if input.showsRatings, let rating = book.rating, rating > 0 {
                ShareStars(rating: rating, size: 44)
            }
            if !details.isEmpty {
                detailsLine(details)
                    .font(.system(size: 32))
                    .opacity(0.75)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .foregroundStyle(ShareStyle.cream.color)
        .layoutPriority(1)
    }

    /// The details' `parts` joined with middle dots on one line, or where that is too wide,
    /// broken between parts, with the fewest lines and the most parts on the first, so no date
    /// splits and no dot ends a line.
    private func detailsLine(_ parts: [String]) -> some View {
        let joined = { (parts: ArraySlice<String>) in parts.joined(separator: " · ") }
        let breaks = (1..<parts.count).reversed()
            .map { [joined(parts[..<$0]), joined(parts[$0...])] }
        let lines = [[joined(parts[...])]] + breaks + [parts]
        return ViewThatFits(in: .horizontal) {
            ForEach(lines.indices, id: \.self) { Text(lines[$0].joined(separator: "\n")) }
        }
    }

    /// A gold bar filled to `progress` (0...1), with the percentage beside it.
    private func progressBar(_ progress: Double, width: CGFloat) -> some View {
        let value = min(1, max(0, progress))
        return HStack(spacing: 20) {
            Capsule()
                .fill(ShareStyle.cream.color.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule().fill(ShareStyle.gold).frame(width: max(18, width * value))
                }
                .frame(width: width, height: 18)
            Text(value.formatted(.percent.precision(.fractionLength(0))))
                .font(ShareStyle.serif(48, .semibold))
                .foregroundStyle(ShareStyle.gold)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The year's highest-rated books fanned like a hand of cards, with a ranked list.
struct TopFiveCard: View {
    let input: ShareInput

    /// Fan positions by rank: the first in the middle, then alternating outward.
    private static let slots: [CGFloat] = [0, -1, 1, -2, 2]

    var body: some View {
        let aspect = input.aspect
        let books = input.books
        let theme = input.theme
        let shortenable = Self.subtitleOrder(books)
        ZStack {
            LinearGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                startPoint: .top, endPoint: .bottom)
            // A glow behind the fan.
            RadialGradient(
                colors: [theme.glow.color, .clear], center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0, endRadius: aspect.size.width * 0.75)
            // Titles keep their subtitles while the fan keeps its minimum height. Past that, the
            // longest titles give theirs up one at a time, and only once every title has given
            // its subtitle up does the fan shrink below its minimum.
            ViewThatFits(in: .vertical) {
                ForEach(0...shortenable.count, id: \.self) { shortened in
                    VStack(spacing: aspect == .story ? 48 : 32) {
                        Text(heading)
                            .font(ShareStyle.serif(aspect == .story ? 84 : 68, .semibold))
                            .foregroundStyle(ShareStyle.cream.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        fan(books)
                            .frame(
                                minHeight: shortened < shortenable.count ? minimumFanHeight : nil)
                        VStack(spacing: aspect == .story ? 22 : 14) {
                            ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                                row(
                                    rank: index + 1, book: book, showsAuthor: aspect != .square,
                                    keepsSubtitle: !shortenable.prefix(shortened).contains(index))
                            }
                        }
                        .layoutPriority(1)
                    }
                }
            }
            .padding(aspect.insets)
        }
    }

    /// The least height the fan keeps while titles show their subtitles, below which its covers
    /// get too small to recognize on a phone. Every size shows its 1,080-pixel width across the
    /// screen, so the shorter Portrait and Square keep a larger share of their height, which
    /// still leaves their covers smaller than a Story's.
    private var minimumFanHeight: CGFloat {
        let share: CGFloat =
            switch input.aspect {
            case .story: 0.22
            case .portrait: 0.25
            case .square: 0.28
            }
        return input.aspect.size.height * share
    }

    /// The indexes of `books` whose titles have a shorter form, in the order they give up their
    /// subtitles to make room for the fan: the longest whole title first.
    static func subtitleOrder(_ books: [CloudBook]) -> [Int] {
        let forms = books.map(ShareStyle.titles)
        return forms.indices.filter { forms[$0].count > 1 }
            .sorted { forms[$0][0].count > forms[$1][0].count }
    }

    /// "My top 5 of 2025", "My top book of August 2025", or "My all-time top 5".
    private var heading: String {
        let top = input.books.count == 1 ? "top book" : "top \(input.books.count)"
        return input.frame == .lifetime ? "My all-time \(top)" : "My \(top) of \(input.period)"
    }

    /// A book's place in the fan: its offset from the fan's center, its height, and its turn in
    /// degrees.
    struct FanCard {
        let offset: CGPoint
        let height: CGFloat
        let turn: Double
    }

    /// How far the outermost books may reach past the fan's width into the card's side margins,
    /// in pixels: half of every size's 64-pixel margin.
    static let overhang: CGFloat = 32

    /// Lays out the fan in `size` for books with the width-to-height `aspects`, by rank, each
    /// turned a little by its jitter (-0.5...0.5). Outer books sit lower and turn further, as a
    /// hand of cards curves, and the fan reaches as far above its middle as below it. The
    /// outermost books may reach `overhang` past the sides.
    static func fan(
        aspects: [CGFloat], jitters: [Double], style: ShareCoverStyle, in size: CGSize
    ) -> [FanCard] {
        // Centers the fan when fewer than five books leave it lopsided.
        let used = slots.prefix(aspects.count)
        let middle = used.reduce(0, +) / CGFloat(max(1, used.count))
        // A lone book takes the fan's space, sized as a featured book's hero is.
        let leadHeight =
            aspects.count == 1
            ? min(size.height * 0.88, size.width * 0.86 / aspects[0])
            : min(size.height * 0.78, size.width * 0.55)
        // An outer book, at 0.82 of the lead height and turned about 21 degrees, reaches up to
        // 0.5 lead heights from its center with the widest 3D book, or 0.53 with the widest flat
        // cover (`ShareCover.aspect`). This spacing keeps the outermost slot (2) within
        // `overhang` of the fan's width, and so inside the card.
        let reach: CGFloat = style == .flat ? 0.53 : 0.5
        let spacing = min(
            size.width * 0.2, (size.width / 2 + overhang - reach * leadHeight) / 2)
        let cards = aspects.indices.map { index in
            let slot = slots[index] - middle
            let height = leadHeight * (index == 0 ? 1 : 0.82)
            let turn = Double(slot) * 10 + jitters[index] * 2
            let angle = abs(turn) * .pi / 180
            return (
                x: slot * spacing, height: height, turn: turn,
                // In proportion to the books, so a small fan curves as a large one does.
                drop: (slot * slot * 0.035 + (index == 0 ? 0 : 0.06)) * leadHeight,
                // How far the turned book reaches above and below its center.
                half: (height * aspects[index] * sin(angle) + height * cos(angle)) / 2
            )
        }
        // The drops push the fan's lowest corners down, so the fan rises by half the difference
        // between the books' reach below and above the middle. That leaves as much room under
        // the books, above the ranked list, as over them.
        let below = cards.map { $0.half + $0.drop }.max() ?? 0
        let above = cards.map { $0.half - $0.drop }.max() ?? 0
        let lift = (below - above) / 2
        return cards.map {
            FanCard(offset: CGPoint(x: $0.x, y: $0.drop - lift), height: $0.height, turn: $0.turn)
        }
    }

    private func fan(_ books: [CloudBook]) -> some View {
        let jitters = books.map { ShareStyle.unit(input.seed, $0.id, 6) - 0.5 }
        let aspects = books.map {
            ShareCover.aspect(of: input.covers[$0.id], style: input.coverStyle)
        }
        return GeometryReader { proxy in
            let size = proxy.size
            let cards = Self.fan(
                aspects: aspects, jitters: jitters, style: input.coverStyle, in: size)
            ZStack {
                // The first-ranked book is drawn last, in front.
                ForEach(Array(books.enumerated().reversed()), id: \.element.id) { index, book in
                    let card = cards[index]
                    ShareCover(
                        book: book, look: input.look(for: book), cover: input.covers[book.id],
                        style: input.coverStyle, height: card.height,
                        yaw: 0.36 + jitters[index] * 0.12, pitch: -0.1
                    )
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 18)
                    .rotationEffect(.degrees(card.turn))
                    .position(
                        x: size.width / 2 + card.offset.x, y: size.height / 2 + card.offset.y)
                }
            }
        }
    }

    /// A ranked book: its rank and title in cream, author, and stars.
    private func row(
        rank: Int, book: CloudBook, showsAuthor: Bool, keepsSubtitle: Bool
    ) -> some View {
        // The rank and stars line up with the title's first line when it wraps.
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(String(rank))
                .font(ShareStyle.serif(46, .bold))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 0) {
                title(book, keepsSubtitle: keepsSubtitle)
                if showsAuthor {
                    Text(SpineView.shortAuthor(book.author))
                        .font(ShareStyle.serif(32))
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            if input.showsRatings, let rating = book.rating, rating > 0 {
                ShareStars(rating: rating, size: 30)
            }
        }
        .foregroundStyle(ShareStyle.cream.color)
    }

    /// A ranked book's title at 40 pixels or more, so it stays legible on a phone.
    ///
    /// With `keepsSubtitle`, the whole title wraps to as many as three lines, and drops its
    /// subtitle or series name only when it needs more. Otherwise the title takes one line, in
    /// the longest form that fits on it, or else two lines, in the longest form that fits in two.
    @ViewBuilder
    private func title(_ book: CloudBook, keepsSubtitle: Bool) -> some View {
        let forms = ShareStyle.titles(book)
        if keepsSubtitle {
            ShareFittingText(forms: forms, size: 44, minimumScale: 40 / 44, lines: 3, book: book) {
                ShareStyle.serif($0, .semibold)
            }
        } else {
            let options = forms.flatMap { form in [44, 40].map { (form: form, size: CGFloat($0)) } }
            ViewThatFits(in: .horizontal) {
                ForEach(options.indices, id: \.self) { index in
                    BookText(options[index].form, of: book)
                        .font(ShareStyle.serif(options[index].size, .semibold))
                        .lineLimit(1)
                }
                // Two lines cost the same height whatever they hold, so keep the subtitle when
                // the whole title fits in them.
                ShareFittingText(
                    forms: forms, size: 44, minimumScale: 40 / 44, lines: 2, book: book
                ) {
                    ShareStyle.serif($0, .semibold)
                }
            }
        }
    }
}
