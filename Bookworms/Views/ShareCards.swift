import SwiftUI

/// The time frame's books as spines stacked on a shelf, with the frame and its totals.
///
/// Two or more books of a series with a known name share one spine (`StackSpine`). When the
/// spines don't fit one image at a legible size, the card spans several pages (`StackPages`),
/// and `ShareInput.page` chooses the one to draw.
struct YearStackCard: View {
    let input: ShareInput

    private nonisolated static let plankHeight: CGFloat = 60
    private nonisolated static let spacing: CGFloat = 32

    /// The space the spines stack in, between the header and the shelf.
    nonisolated static func area(_ aspect: ShareAspect) -> CGSize {
        let headerHeight: CGFloat = aspect == .square ? 170 : 250
        return CGSize(
            width: aspect.size.width - aspect.insets.leading - aspect.insets.trailing,
            height: aspect.size.height - aspect.insets.top - aspect.insets.bottom - headerHeight
                - plankHeight - 2 * spacing)
    }

    /// The input's books as spines, split into the card's pages.
    nonisolated static func pages(for input: ShareInput) -> StackPages {
        StackPages(spines: StackSpine.spines(input.books), area: area(input.aspect))
    }

    var body: some View {
        let aspect = input.aspect
        let area = Self.area(aspect)
        let pages = Self.pages(for: input)
        let count = pages.pages.count
        let page = min(max(0, input.page), count - 1)
        let layout = StackLayout(spines: pages.pages[page], area: area, seed: input.seed)
        let theme = input.theme
        ZStack {
            RadialGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0,
                endRadius: aspect.size.height * 0.8)
            VStack(spacing: Self.spacing) {
                header(isSquare: aspect == .square)
                ZStack(alignment: .topLeading) {
                    ForEach(layout.slabs) { slab in
                        ShareSpine(spine: slab.spine, look: input.look(for: slab.spine.book))
                            .frame(width: slab.size.width, height: slab.size.height)
                            // Turned as Stack turns a flat spine, so it faces a little left or
                            // right while lying flat on the book below it.
                            .rotation3DEffect(
                                .degrees(slab.turn), axis: (x: 0, y: 1, z: 0),
                                perspective: StackArrangement.perspective
                            )
                            .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
                            .position(slab.center)
                    }
                }
                .frame(width: area.width, height: layout.height)
                ShelfPlank(
                    page: count > 1 ? "\(page + 1) of \(count)" : nil,
                    note: page == count - 1 && pages.hiddenCount > 0
                        ? "+\(pages.hiddenCount) more" : nil
                )
                .frame(height: Self.plankHeight)
            }
            .padding(aspect.insets)
        }
    }

    /// The period and totals, which count every book in the frame on every page.
    private func header(isSquare: Bool) -> some View {
        let count = input.books.count
        let pages = input.books.reduce(0) { $0 + max(0, $1.pages ?? 0) }
        var totals = "\(count.formatted()) \(count == 1 ? "book" : "books")"
        if pages > 0 { totals += " · \(pages.formatted()) pages" }
        return VStack(spacing: isSquare ? 4 : 10) {
            Text(input.period)
                .font(ShareStyle.serif(isSquare ? 108 : 140, .semibold))
            Text(totals)
                .font(ShareStyle.serif(isSquare ? 38 : 44))
                .opacity(0.8)
        }
        .foregroundStyle(ShareStyle.cream.color)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// One spine of the Year Stack: a book, or the books of one series lettered as a single spine.
struct StackSpine: Identifiable {
    /// The books in finish order. The first sets the spine's place, design, and variation.
    let books: [CloudBook]

    var book: CloudBook { books[0] }
    var id: Int { book.id }

    /// The lettering's forms, longest first: a group's series name and book count, such as
    /// "Dungeon Crawler Carl ×5", or a book's title forms (`ShareStyle.titles(_:)`).
    var titles: [String] {
        guard books.count > 1, let name = book.seriesName else { return ShareStyle.titles(book) }
        return ["\(name) ×\(books.count)"]
    }

    /// The relative thickness. A book's is 0.8 to 1.25, from its page count. A group's is 1.5
    /// for two books and 0.25 more for each further book, up to 2: thicker than any one book, so
    /// it reads as several, without dominating the stack.
    var weight: CGFloat {
        guard books.count == 1 else { return min(2, 1 + 0.25 * CGFloat(books.count)) }
        return 0.8 + 0.45 * min(1, max(0, (CGFloat(book.pages ?? 320) - 150) / 650))
    }

    /// Orders spines as `ShareTemplate.isRankedHigher` orders their best-ranked books, so a
    /// group ranks as its best-rated book.
    static func isRankedHigher(_ lhs: StackSpine, _ rhs: StackSpine) -> Bool {
        ShareTemplate.isRankedHigher(lhs.best, rhs.best)
    }

    private var best: CloudBook { books.min(by: ShareTemplate.isRankedHigher) ?? book }

    /// Returns `books`, given in finish order, as spines in that order. Two or more books of a
    /// series with a known name become one spine at the place of the first of them. Books
    /// without a series name, such as those from the Apple TV's archive, stay single.
    static func spines(_ books: [CloudBook]) -> [StackSpine] {
        func series(_ book: CloudBook) -> Int? {
            book.seriesName?.isEmpty == false ? book.seriesID : nil
        }
        let groups = Dictionary(grouping: books.filter { series($0) != nil }) { series($0) ?? 0 }
        var placed = Set<Int>()
        return books.compactMap { book in
            guard let id = series(book), let group = groups[id], group.count > 1 else {
                return StackSpine(books: [book])
            }
            return placed.insert(id).inserted ? StackSpine(books: group) : nil
        }
    }
}

/// The Year Stack's spines split across pages, in finish order.
///
/// Spines that fit two stacks at a legible thickness stay on one page. Otherwise they fill as
/// few pages as hold them, up to `maximumPages`, each a run of spines whose weights come as
/// near an equal share as the spines allow, so page 1 holds the earliest books. Only spines
/// that 20 pages cannot hold are left out, lowest-ranked first.
struct StackPages {
    /// Instagram's carousel limit.
    static let maximumPages = 20

    /// The pages' spines. There is always at least one page, which can be empty.
    private(set) var pages: [[StackSpine]]
    /// The books left out because 20 pages could not hold them.
    private(set) var hiddenCount = 0

    init(spines: [StackSpine], area: CGSize) {
        let capacity = StackLayout.capacity(area)
        guard StackLayout.weight(spines) > capacity else {
            pages = [spines]
            return
        }
        var shown = spines
        let limit = CGFloat(Self.maximumPages) * capacity
        if StackLayout.weight(spines) > limit {
            var kept = Set<Int>()
            var sum: CGFloat = 0
            for spine in spines.sorted(by: StackSpine.isRankedHigher) {
                guard sum + spine.weight <= limit else { break }
                kept.insert(spine.id)
                sum += spine.weight
            }
            shown = spines.filter { kept.contains($0.id) }
        }
        while true {
            let fewest = max(2, Int((StackLayout.weight(shown) / capacity).rounded(.up)))
            if let split = (fewest...max(fewest, Self.maximumPages)).lazy
                .map({ StackLayout.split(shown, into: $0) })
                .first(where: { $0.allSatisfy { StackLayout.weight($0) <= capacity } })
            {
                pages = split
                break
            }
            // Uneven spines can leave 20 even pages over capacity; the lowest-ranked spine goes.
            if let lowest = shown.indices.max(by: {
                StackSpine.isRankedHigher(shown[$0], shown[$1])
            }) {
                shown.remove(at: lowest)
            }
        }
        hiddenCount =
            spines.reduce(0) { $0 + $1.books.count } - shown.reduce(0) { $0 + $1.books.count }
    }
}

/// Places one page's spines in one stack, oldest at the bottom, or in two side by side when one
/// stack would make the lettering too small.
struct StackLayout {
    struct Slab: Identifiable {
        let spine: StackSpine
        let center: CGPoint
        let size: CGSize
        /// The turn about the vertical axis, in degrees, that faces the spine a little left or
        /// right. Spines never tilt in the image's plane: each lies flat on the one below.
        let turn: Double
        var id: Int { spine.id }
    }

    // Thickness per unit of weight. The thinnest spine, at 0.8 units, stays thick enough for
    // `ShareSpine`'s 30-pixel lettering.
    private static let largest: CGFloat = 104
    private static let smallestSingle: CGFloat = 60
    private static let smallestDouble: CGFloat = 58
    private static let gap: CGFloat = 36

    private(set) var slabs: [Slab] = []
    /// The taller stack's height.
    private(set) var height: CGFloat = 0

    /// The most weight two stacks in `area` hold at a legible thickness, with room to spare for
    /// stacks of unequal height.
    static func capacity(_ area: CGSize) -> CGFloat { 2 * area.height / smallestDouble * 0.96 }

    static func weight(_ spines: [StackSpine]) -> CGFloat { spines.reduce(0) { $0 + $1.weight } }

    /// Splits `spines` into up to `count` runs in order, ending each run where the total so far
    /// comes nearest its equal share of the whole.
    static func split(_ spines: [StackSpine], into count: Int) -> [[StackSpine]] {
        let share = weight(spines) / CGFloat(count)
        var runs: [[StackSpine]] = []
        var sum: CGFloat = 0
        for spine in spines {
            let end = share * CGFloat(runs.count)
            if runs.isEmpty
                || (runs.count < count && abs(sum + spine.weight - end) > abs(sum - end))
            {
                runs.append([])
            }
            runs[runs.count - 1].append(spine)
            sum += spine.weight
        }
        return runs
    }

    init(spines: [StackSpine], area: CGSize, seed: UInt64) {
        // Older spines on the left.
        let columns =
            Self.weight(spines) * Self.smallestSingle > area.height
            ? Self.split(spines, into: 2) : [spines]
        let tallest = columns.map(Self.weight).max() ?? 0
        guard tallest > 0 else { return }
        let unit = min(Self.largest, area.height / tallest)
        let columnWidth = columns.count == 1 ? min(area.width, 880) : (area.width - Self.gap) / 2
        height = tallest * unit
        for (column, spines) in columns.enumerated() {
            let centerX =
                columns.count == 1
                ? area.width / 2 : columnWidth / 2 + CGFloat(column) * (columnWidth + Self.gap)
            var bottom = height
            for spine in spines {
                let id = spine.id
                let thickness = spine.weight * unit
                let length = columnWidth * (0.84 + 0.16 * ShareStyle.unit(seed, id, 1))
                let shift = (ShareStyle.unit(seed, id, 2) - 0.5) * min(40, columnWidth - length)
                // Up to 10 degrees, mostly much less, as `StackArrangement` spreads its turns.
                let even = 2 * ShareStyle.unit(seed, id, 3) - 1
                let turn = 10 * even * abs(even)
                slabs.append(
                    Slab(
                        spine: spine,
                        center: CGPoint(x: centerX + shift, y: bottom - thickness / 2),
                        size: CGSize(width: length, height: thickness), turn: turn))
                bottom -= thickness
            }
        }
    }
}

/// A `SpineView` lettered for a share image: one line, never below 30 pixels.
///
/// `SpineView` sizes its lettering from the thickness and shrinks long titles, which leaves
/// stacked spines with text too small to read on a phone. This view draws the spine blank and
/// letters it here instead, with the first of the spine's `titles` that fits. Lettering that
/// never fits truncates, a group's in the middle so its book count stays.
struct ShareSpine: View {
    let spine: StackSpine
    let look: SpineLook

    var body: some View {
        SpineView(
            book: CloudBook(
                id: spine.id, title: "", author: "", coverURL: nil, detailCoverURL: nil),
            look: look
        )
        .overlay {
            GeometryReader { proxy in
                let length = proxy.size.width
                // A group's thicker spine is lettered as the thickest single book, at 1.25 units,
                // is, so its label doesn't outshout the titles around it.
                let thickness = proxy.size.height * min(1, 1.25 / spine.weight)
                let size = max(30, thickness * 0.5)
                ShareFittingText(
                    forms: spine.titles.map(look.text), size: size, minimumScale: 30 / size
                ) {
                    look.font(size: $0)
                }
                .truncationMode(spine.books.count > 1 ? .middle : .tail)
                .foregroundStyle(look.foreground.color)
                // Clears SpineView's accent bands at the head and tail.
                .padding(.horizontal, max(14, length * 0.035) + thickness * 0.3)
                .frame(width: length, height: proxy.size.height, alignment: .leading)
            }
        }
    }
}

/// A wooden shelf board seen from the front, with optional notes on its edge: the page, such as
/// "1 of 3", at the left, and a note, such as "+12 more", at the right.
struct ShelfPlank: View {
    var page: String? = nil
    var note: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color(red: 0.62, green: 0.45, blue: 0.31),
                    Color(red: 0.5, green: 0.35, blue: 0.23),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 12)
            LinearGradient(
                colors: [
                    Color(red: 0.37, green: 0.24, blue: 0.15),
                    Color(red: 0.24, green: 0.15, blue: 0.09),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .overlay {
                HStack {
                    if let page { Text(page) }
                    Spacer(minLength: 0)
                    if let note { Text(note) }
                }
                .font(ShareStyle.serif(32, .semibold))
                .foregroundStyle(ShareStyle.cream.color.opacity(0.9))
                .padding(.horizontal, 28)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 16)
    }
}

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

    private func details(_ book: CloudBook, alignment: HorizontalAlignment) -> some View {
        let isSquare = input.aspect == .square
        let isReading = input.template == .currentlyReading
        let label = isReading ? "Currently reading" : book.finishedDate != nil ? "Finished" : nil
        let details = ShareStyle.details(book, isReading: isReading)
        return VStack(alignment: alignment, spacing: 18) {
            if let label {
                ShareStyle.label(label).foregroundStyle(ShareStyle.gold)
            }
            ShareFittingText(
                forms: ShareStyle.titles(book), size: isSquare ? 64 : 80, minimumScale: 0.5,
                lines: isSquare ? 4 : 3
            ) {
                ShareStyle.serif($0, .semibold)
            }
            Text(SpineView.shortAuthor(book.author))
                .font(ShareStyle.serif(40))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            if isReading {
                if let progress = book.progress {
                    progressBar(progress, width: isSquare ? 250 : 440)
                }
            } else if input.showsRatings, let rating = book.rating, rating > 0 {
                ShareStars(rating: rating, size: 44)
            }
            if !details.isEmpty {
                Text(details)
                    .font(.system(size: 32))
                    .opacity(0.75)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .foregroundStyle(ShareStyle.cream.color)
        .layoutPriority(1)
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
        ZStack {
            LinearGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                startPoint: .top, endPoint: .bottom)
            // A glow behind the fan.
            RadialGradient(
                colors: [theme.glow.color, .clear], center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0, endRadius: aspect.size.width * 0.75)
            VStack(spacing: aspect == .story ? 48 : 32) {
                Text(heading)
                    .font(ShareStyle.serif(aspect == .story ? 84 : 68, .semibold))
                    .foregroundStyle(ShareStyle.cream.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                fan(books)
                VStack(spacing: aspect == .story ? 22 : 14) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        row(rank: index + 1, book: book, showsAuthor: aspect != .square)
                    }
                }
                .layoutPriority(1)
            }
            .padding(aspect.insets)
        }
    }

    /// "My top 5 of 2025", "My top book of August 2025", or "My all-time top 5".
    private var heading: String {
        let top = input.books.count == 1 ? "top book" : "top \(input.books.count)"
        return input.frame == .lifetime ? "My all-time \(top)" : "My \(top) of \(input.period)"
    }

    private func fan(_ books: [CloudBook]) -> some View {
        // Centers the fan when fewer than five books leave it lopsided.
        let used = Self.slots.prefix(books.count)
        let middle = used.reduce(0, +) / CGFloat(max(1, used.count))
        return GeometryReader { proxy in
            let size = proxy.size
            // A lone book takes the fan's space, sized as a featured book's hero is.
            let leadHeight =
                books.count == 1
                ? min(
                    size.height * 0.88,
                    size.width * 0.86
                        / ShareCover.aspect(of: input.covers[books[0].id], style: input.coverStyle))
                : min(size.height * 0.78, size.width * 0.55)
            // An outer book, at 0.82 of the lead height and turned about 15 degrees, reaches up
            // to 0.47 lead heights from its center with the widest 3D book, or 0.5 with the
            // widest flat cover (`ShareCover.aspect`). This spacing keeps the outermost slot (2)
            // inside the fan's width, and so in the gutters.
            let reach = input.coverStyle == .flat ? 0.5 : 0.47
            let spacing = min(size.width * 0.16, (size.width / 2 - reach * leadHeight) / 2)
            ZStack {
                // The first-ranked book is drawn last, in front.
                ForEach(Array(books.enumerated().reversed()), id: \.element.id) { index, book in
                    let slot = Self.slots[index] - middle
                    let jitter = ShareStyle.unit(input.seed, book.id, 6) - 0.5
                    ShareCover(
                        book: book, look: input.look(for: book), cover: input.covers[book.id],
                        style: input.coverStyle, height: leadHeight * (index == 0 ? 1 : 0.82),
                        yaw: 0.36 + jitter * 0.12, pitch: -0.1
                    )
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 18)
                    .rotationEffect(.degrees(Double(slot) * 7 + jitter * 2))
                    .position(
                        x: size.width / 2 + slot * spacing,
                        y: size.height / 2 + slot * slot * 14 + (index == 0 ? 0 : leadHeight * 0.06)
                    )
                }
            }
        }
    }

    private func row(rank: Int, book: CloudBook, showsAuthor: Bool) -> some View {
        HStack(spacing: 20) {
            Text(String(rank))
                .font(ShareStyle.serif(46, .bold))
                .foregroundStyle(ShareStyle.gold)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 0) {
                ShareFittingText(forms: ShareStyle.titles(book), size: 38, minimumScale: 0.8) {
                    ShareStyle.serif($0, .semibold)
                }
                if showsAuthor {
                    Text(SpineView.shortAuthor(book.author))
                        .font(ShareStyle.serif(30))
                        .opacity(0.7)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            if input.showsRatings, let rating = book.rating, rating > 0 {
                ShareStars(rating: rating, size: 30)
            }
        }
        .foregroundStyle(ShareStyle.cream.color)
    }
}

/// Every book finished in the time frame as a stripe of its spine color, in reading order.
///
/// The card shows no titles, so it suits sharing a whole library.
struct SpectrumCard: View {
    let input: ShareInput

    var body: some View {
        let aspect = input.aspect
        let looks = input.books.map { input.look(for: $0) }
        let theme = ShareTheme(looks: looks)
        let years = input.books.map { $0.finishedYear ?? 0 }
        // Square images stand the spines upright; taller ones lay them flat.
        let isUpright = aspect == .square
        let showsYears = input.frame == .lifetime && !isUpright && Set(years).count > 1
        let count = input.books.count
        ZStack {
            LinearGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                startPoint: .top, endPoint: .bottom)
            VStack(spacing: 36) {
                HStack(spacing: 20) {
                    if showsYears {
                        Canvas { context, size in
                            var last = -CGFloat.infinity
                            for (index, year) in years.enumerated()
                            where index == 0 || years[index - 1] != year {
                                let y = (CGFloat(index) * size.height / CGFloat(count)).rounded()
                                // Skips a label that would overlap the one above it.
                                guard y - last >= 40 else { continue }
                                last = y
                                context.draw(
                                    Text(String(year))
                                        .font(.system(size: 30, weight: .medium))
                                        .foregroundStyle(ShareStyle.cream.color.opacity(0.75)),
                                    at: CGPoint(x: size.width, y: y), anchor: .topTrailing)
                            }
                        }
                        .frame(width: 84)
                    }
                    Canvas { context, size in
                        Self.drawStripes(looks, isUpright: isUpright, in: size, context: &context)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                }
                VStack(spacing: 8) {
                    Text("\(count.formatted()) \(count == 1 ? "book" : "books") · \(input.period)")
                        .font(ShareStyle.serif(aspect == .square ? 48 : 56, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Every spine, in reading order")
                        .font(.system(size: 30))
                        .opacity(0.65)
                }
                .foregroundStyle(ShareStyle.cream.color)
            }
            .padding(aspect.insets)
        }
    }

    /// Draws one stripe per look, snapped to whole pixels, with a spine's shading and accent
    /// bands near its head and tail.
    private static func drawStripes(
        _ looks: [SpineLook], isUpright: Bool, in size: CGSize, context: inout GraphicsContext
    ) {
        let along = isUpright ? size.width : size.height
        let length = isUpright ? size.height : size.width
        let band = max(2, min(6, length * 0.006))
        for (index, look) in looks.enumerated() {
            let start = (CGFloat(index) * along / CGFloat(looks.count)).rounded()
            let end = (CGFloat(index + 1) * along / CGFloat(looks.count)).rounded()
            let thickness = end - start
            let rect =
                isUpright
                ? CGRect(x: start, y: 0, width: thickness, height: length)
                : CGRect(x: 0, y: start, width: length, height: thickness)
            context.fill(Path(rect), with: .color(look.background.color))
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.1), .clear, .black.opacity(0.25)]),
                    startPoint: rect.origin,
                    endPoint: isUpright
                        ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.maxY))
            )
            // Bands on thinner stripes would merge into two lines across the image.
            guard thickness >= 8 else { continue }
            for offset in [length * 0.035, length * 0.965 - band] {
                let bandRect =
                    isUpright
                    ? CGRect(
                        x: start + thickness * 0.12, y: offset, width: thickness * 0.76,
                        height: band)
                    : CGRect(
                        x: offset, y: start + thickness * 0.12, width: band,
                        height: thickness * 0.76)
                context.fill(Path(bandRect), with: .color(look.accent.color))
            }
        }
    }
}
