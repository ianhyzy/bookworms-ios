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
        let lines = ShareStyle.details(book, isReading: input.template == .currentlyReading)
        // A story's content reaches into its bottom strip (`ShareInput.reach`). Each gap between
        // the details' groups takes a quarter of that height and the gap under the hero takes the
        // rest, so the details still read as one caption and the hero keeps the size it has
        // within `ShareAspect.insets`.
        let groupGap = input.reach / 4
        let groupGaps = (showsMeter(book) ? 1 : 0) + (lines.isEmpty ? 0 : 1)
        let heroGap = input.reach - groupGap * CGFloat(groupGaps)
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
                        details(book, lines: lines, alignment: .leading, spacing: 36)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 44 + heroGap) {
                        hero(book, look: look)
                        details(book, lines: lines, alignment: .center, spacing: 36 + groupGap)
                    }
                }
            }
            .padding(input.reachingInsets)
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

    /// Whether the details show a progress bar or stars between the title and the details line.
    private func showsMeter(_ book: CloudBook) -> Bool {
        input.template == .currentlyReading
            ? book.progress != nil : input.showsRatings && (book.rating ?? 0) > 0
    }

    /// The title and author, the rating or progress, and the details line of `lines`, such as
    /// "Finished Nov 30, 2025 · 736 pages", with `spacing` between these groups, wider than the
    /// gaps within them.
    private func details(
        _ book: CloudBook, lines: [String], alignment: HorizontalAlignment, spacing: CGFloat
    ) -> some View {
        let isSquare = input.aspect == .square
        let isReading = input.template == .currentlyReading
        return VStack(alignment: alignment, spacing: spacing) {
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
            if showsMeter(book) {
                if isReading, let progress = book.progress {
                    progressBar(progress, width: isSquare ? 250 : 440)
                } else if let rating = book.rating {
                    ShareStars(rating: rating, size: 44)
                }
            }
            if !lines.isEmpty {
                detailsLine(lines)
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

    /// A gold bar filled to `progress` (0...1), with the percentage in cream beside it.
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
                .foregroundStyle(ShareStyle.cream.color)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The year's highest-rated books standing on a ledge, with a ranked list.
struct TopFiveCard: View {
    let input: ShareInput

    /// Places along the ledge by rank: the first in the middle, then alternating outward.
    private static let slots: [CGFloat] = [0, -1, 1, -2, 2]
    /// How far back on the ledge each rank stands: the first at its front edge, the next two
    /// behind it, and the last two at the back.
    private static let depths: [CGFloat] = [0, 1, 1, 2, 2]

    var body: some View {
        let aspect = input.aspect
        let books = input.books
        let theme = input.theme
        let shortenable = Self.subtitleOrder(books)
        ZStack {
            LinearGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                startPoint: .top, endPoint: .bottom)
            // A glow behind the books.
            RadialGradient(
                colors: [theme.glow.color, .clear], center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0, endRadius: aspect.size.width * 0.75)
            // Titles keep their subtitles while the ledge keeps its minimum height. Past that, the
            // longest titles give theirs up one at a time, and only once every title has given
            // its subtitle up does the ledge shrink below its minimum.
            ViewThatFits(in: .vertical) {
                ForEach(0...shortenable.count, id: \.self) { shortened in
                    VStack(spacing: gaps.section) {
                        Text(heading)
                            .font(ShareStyle.serif(aspect == .story ? 84 : 68, .semibold))
                            .foregroundStyle(ShareStyle.cream.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        shelf(books)
                            .frame(
                                minHeight: shortened < shortenable.count ? minimumShelfHeight : nil)
                        VStack(spacing: gaps.row) {
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
            .padding(input.reachingInsets)
        }
    }

    /// The gaps around the ledge and between the ranked rows, in pixels.
    ///
    /// A story's content reaches into its bottom strip (`ShareInput.reach`), and the two gaps
    /// around the ledge and the one between each pair of rows share that height evenly, so the
    /// books and the titles keep the sizes they have within `ShareAspect.insets`.
    private var gaps: (section: CGFloat, row: CGFloat) {
        let extra = input.reach / CGFloat(input.books.count + 1)
        return input.aspect == .story ? (48 + extra, 22 + extra) : (32, 14)
    }

    /// The least height the ledge keeps while titles show their subtitles, below which its
    /// covers get too small to recognize on a phone. Every size shows its 1,080-pixel width
    /// across the screen, so the shorter Portrait and Square keep a larger share of their height,
    /// which still leaves their covers smaller than a Story's.
    private var minimumShelfHeight: CGFloat {
        let share: CGFloat =
            switch input.aspect {
            case .story: 0.22
            case .portrait: 0.25
            case .square: 0.28
            }
        return input.aspect.size.height * share
    }

    /// The indexes of `books` whose titles have a shorter form, in the order they give up their
    /// subtitles to make room for the books: the longest whole title first.
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

    /// A book's place on the ledge: how far its middle sits from the middle of the books'
    /// space, its height, and how far down that space its base rests.
    struct LedgeBook {
        let x: CGFloat
        let height: CGFloat
        let base: CGFloat
    }

    /// The ledge's top surface: its front edge, how far down the books' space it lies, and how
    /// deep the surface shows above that edge, seen from a little above. The lip below it is
    /// `lip` deep.
    struct Ledge {
        let books: [LedgeBook]
        let front: CGFloat
        let depth: CGFloat
        let lip: CGFloat
    }

    /// How far the outermost books may reach past the space's width into the card's side
    /// margins, in pixels: half of every size's 64-pixel margin.
    static let overhang: CGFloat = 32

    /// How much wider than its cover a book looks with its spine turned toward the viewer, at
    /// most, for the reach of the outermost books.
    private static let spineAllowance: CGFloat = 1.12

    /// Stands books with the width-to-height `aspects`, by rank, on a ledge in `size`.
    ///
    /// The books stand upright, never turned in the card's plane. The first-ranked book stands at
    /// the ledge's front edge in the middle, and the others alternate outward, further back the
    /// further out they stand: a book further back rests higher on the surface, as seen from a
    /// little above, and looks smaller, so the books stand in front of one another like a shop's
    /// display rather than floating. Every base rests on the surface, between its front edge and
    /// its back. The books and the lip span as much height above the space's middle as below
    /// it, and the outermost books may reach `overhang` past the sides.
    static func ledge(aspects: [CGFloat], in size: CGSize) -> Ledge {
        // Centers the books when fewer than five leave the row lopsided.
        let used = slots.prefix(aspects.count)
        let middle = used.reduce(0, +) / CGFloat(max(1, used.count))
        // A lone book takes the space, sized as a featured book's hero is.
        let leadHeight =
            aspects.count == 1
            ? min(size.height * 0.84, size.width * 0.86 / aspects[0])
            : min(size.height * 0.78, size.width * 0.54)
        let scales: [CGFloat] = [1, 0.88, 0.78]
        let rise = leadHeight * 0.06
        let lip = leadHeight * 0.05
        let heights = aspects.indices.map { leadHeight * scales[Int(depths[$0])] }
        // The widest outer book, its spine turned out, reaches no further than `overhang` past
        // the space's side.
        let distances = aspects.indices.map { abs(slots[$0] - middle) }
        let reach = distances.max() ?? 0
        let outerHalf =
            aspects.indices.filter { distances[$0] == reach }
            .map { heights[$0] * aspects[$0] * spineAllowance / 2 }.max() ?? 0
        let spacing =
            reach == 0
            ? 0 : min(size.width * 0.21, (size.width / 2 + overhang - outerHalf) / reach)
        // The lead book is the tallest, so the books' top is its top.
        let front = (size.height + leadHeight - lip) / 2
        let books = aspects.indices.map { index in
            LedgeBook(
                x: (slots[index] - middle) * spacing, height: heights[index],
                base: front - depths[index] * rise)
        }
        return Ledge(books: books, front: front, depth: rise * 2.6, lip: lip)
    }

    private func shelf(_ books: [CloudBook]) -> some View {
        let jitters = books.map { ShareStyle.unit(input.seed, $0.id, 6) - 0.5 }
        let aspects = books.map {
            ShareCover.aspect(of: input.covers[$0.id], style: input.coverStyle)
        }
        let theme = input.theme
        return GeometryReader { proxy in
            let size = proxy.size
            let ledge = Self.ledge(aspects: aspects, in: size)
            ZStack(alignment: .top) {
                // The ledge spans the card from edge to edge, like a shelf on the wall.
                LedgeBoard(theme: theme, depth: ledge.depth, lip: ledge.lip)
                    .frame(height: ledge.depth + ledge.lip)
                    .padding(.horizontal, -input.aspect.insets.leading)
                    .offset(y: ledge.front - ledge.depth)
                // The first-ranked book is drawn last, in front.
                ForEach(Array(books.enumerated().reversed()), id: \.element.id) { index, book in
                    let place = ledge.books[index]
                    let width = place.height * aspects[index]
                    ShareCover(
                        book: book, look: input.look(for: book), cover: input.covers[book.id],
                        style: input.coverStyle, height: place.height,
                        // Each book turns a little about its upright axis, never in the card's
                        // plane.
                        yaw: 0.36 + jitters[index] * 0.12, pitch: -0.1
                    )
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    // Its base rests on the ledge, with its contact shadow under it.
                    .background(alignment: .bottom) {
                        EllipticalGradient(colors: [.black.opacity(0.55), .clear])
                            .frame(width: width * 1.1, height: ledge.depth * 0.5)
                            .offset(y: ledge.depth * 0.18)
                    }
                    .frame(width: size.width, height: place.base, alignment: .bottom)
                    .offset(x: place.x)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
    }

    /// A ranked book: its rank, title, and author in cream, and its stars.
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

/// The ledge under Top Five's books: its top surface, lit from above and darker toward the
/// wall, and its front lip, in the card's color family.
private struct LedgeBoard: View {
    let theme: ShareTheme
    /// How deep the top surface shows, and how deep the lip is, in pixels.
    let depth: CGFloat
    let lip: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [theme.backdropDark.color, theme.panel().color],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: depth)
            // The lit front edge, then the lip in shadow.
            Rectangle().fill(ShareStyle.cream.color.opacity(0.22)).frame(height: 2)
            LinearGradient(
                colors: [theme.backdropDark.color, .black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: max(0, lip - 2))
        }
        .accessibilityHidden(true)
    }
}
