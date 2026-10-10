import SwiftUI

/// The time frame's books as spines stacked on a shelf, with the frame and its totals.
struct YearStackCard: View {
    let input: ShareInput

    var body: some View {
        let aspect = input.aspect
        let isSquare = aspect == .square
        let headerHeight: CGFloat = isSquare ? 170 : 250
        let plankHeight: CGFloat = 60
        let spacing: CGFloat = 32
        let area = CGSize(
            width: aspect.size.width - aspect.insets.leading - aspect.insets.trailing,
            height: aspect.size.height - aspect.insets.top - aspect.insets.bottom - headerHeight
                - plankHeight - 2 * spacing)
        let layout = StackLayout(books: input.books, area: area, seed: input.seed)
        let lead = ShareStyle.leadColor(input.books.map { input.look(for: $0).background })
        ZStack {
            RadialGradient(
                colors: [
                    ShareStyle.backdrop(lead, 0.45).color, ShareStyle.backdrop(lead, 0.8).color,
                ], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0,
                endRadius: aspect.size.height * 0.8)
            VStack(spacing: spacing) {
                header(isSquare: isSquare)
                ZStack(alignment: .topLeading) {
                    ForEach(layout.slabs) { slab in
                        ShareSpine(book: slab.book, look: input.look(for: slab.book))
                            .frame(width: slab.size.width, height: slab.size.height)
                            .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
                            .rotationEffect(.degrees(slab.tilt))
                            .position(slab.center)
                    }
                }
                .frame(width: area.width, height: layout.height)
                ShelfPlank(note: layout.hiddenCount > 0 ? "+\(layout.hiddenCount) more" : nil)
                    .frame(height: plankHeight)
            }
            .padding(aspect.insets)
        }
    }

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

/// Places spines in one stack, oldest at the bottom, or in two side by side when one stack would
/// make the lettering too small. When two stacks are still too crowded, the lowest-rated books
/// are left out.
struct StackLayout {
    struct Slab: Identifiable {
        let book: CloudBook
        let center: CGPoint
        let size: CGSize
        /// The tilt in degrees.
        let tilt: Double
        var id: Int { book.id }
    }

    private(set) var slabs: [Slab] = []
    private(set) var hiddenCount = 0
    /// The taller stack's height.
    private(set) var height: CGFloat = 0

    init(books: [CloudBook], area: CGSize, seed: UInt64) {
        // Relative thickness, 0.8 to 1.25, from the page count.
        func weight(_ book: CloudBook) -> CGFloat {
            0.8 + 0.45 * min(1, max(0, (CGFloat(book.pages ?? 320) - 150) / 650))
        }
        func total(_ books: [CloudBook]) -> CGFloat { books.reduce(0) { $0 + weight($1) } }
        // Thickness per unit of weight. The thinnest spine, at 0.8 units, stays thick enough
        // for `ShareSpine`'s 30-pixel lettering.
        let largest: CGFloat = 104
        let smallestSingle: CGFloat = 60
        let smallestDouble: CGFloat = 58
        let gap: CGFloat = 36

        var columns = [books]
        if total(books) * smallestSingle > area.height {
            let capacity = 2 * area.height / smallestDouble * 0.96
            var kept = Set<Int>()
            var sum: CGFloat = 0
            for book in books.sorted(by: ShareTemplate.isRankedHigher) {
                guard sum + weight(book) <= capacity else { break }
                kept.insert(book.id)
                sum += weight(book)
            }
            let shown = books.filter { kept.contains($0.id) }
            hiddenCount = books.count - shown.count
            // Older books on the left, split where the two stacks' heights differ least.
            var left: CGFloat = 0
            var split = shown.count
            for (index, book) in shown.enumerated() {
                if abs(sum - 2 * (left + weight(book))) > abs(sum - 2 * left) {
                    split = index
                    break
                }
                left += weight(book)
            }
            columns = [Array(shown[..<split]), Array(shown[split...])].filter { !$0.isEmpty }
        }

        let tallest = columns.map(total).max() ?? 0
        guard tallest > 0 else { return }
        let unit = min(largest, area.height / tallest)
        let columnWidth = columns.count == 1 ? min(area.width, 880) : (area.width - gap) / 2
        height = tallest * unit
        for (column, books) in columns.enumerated() {
            let centerX =
                columns.count == 1
                ? area.width / 2 : columnWidth / 2 + CGFloat(column) * (columnWidth + gap)
            var bottom = height
            for (index, book) in books.enumerated() {
                let thickness = weight(book) * unit
                let length = columnWidth * (0.84 + 0.16 * ShareStyle.unit(seed, book.id, 1))
                let shift =
                    (ShareStyle.unit(seed, book.id, 2) - 0.5) * min(40, columnWidth - length)
                // The bottom book lies flat on the shelf.
                let tilt = index == 0 ? 0 : (ShareStyle.unit(seed, book.id, 3) - 0.5) * 2.6
                slabs.append(
                    Slab(
                        book: book,
                        center: CGPoint(x: centerX + shift, y: bottom - thickness / 2),
                        size: CGSize(width: length, height: thickness), tilt: tilt))
                bottom -= thickness
            }
        }
    }
}

/// A `SpineView` lettered for a share image: the title alone, never below 30 pixels.
///
/// `SpineView` sizes its lettering from the thickness and shrinks long titles, which leaves
/// stacked spines with text too small to read on a phone. This view draws the spine blank and
/// letters it here instead, truncating a title that does not fit.
struct ShareSpine: View {
    let book: CloudBook
    let look: SpineLook

    var body: some View {
        SpineView(
            book: CloudBook(
                id: book.id, title: "", author: "", coverURL: nil, detailCoverURL: nil),
            look: look
        )
        .overlay {
            GeometryReader { proxy in
                let (length, thickness) = (proxy.size.width, proxy.size.height)
                let size = max(30, thickness * 0.5)
                Text(look.text(book.spineTitle))
                    .font(look.font(size: size))
                    .lineLimit(1)
                    .minimumScaleFactor(30 / size)
                    .foregroundStyle(look.foreground.color)
                    // Clears SpineView's accent bands at the head and tail.
                    .padding(.horizontal, max(14, length * 0.035) + thickness * 0.3)
                    .frame(width: length, height: thickness, alignment: .leading)
            }
        }
    }
}

/// A wooden shelf board seen from the front, with an optional note on its edge.
struct ShelfPlank: View {
    let note: String?

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
            .overlay(alignment: .trailing) {
                if let note {
                    Text(note)
                        .font(ShareStyle.serif(32, .semibold))
                        .foregroundStyle(ShareStyle.cream.color.opacity(0.9))
                        .padding(.trailing, 28)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 16)
    }
}

/// One book, as a 3D book or a flat cover on a backdrop from its spine colors, with its
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
        let edge = ShareStyle.backdrop(look.background, 0.7)
        return ZStack {
            // A glow behind the book, tinted by the spine's accent so dark spines still light up.
            RadialGradient(
                stops: [
                    .init(color: look.background.mixed(with: look.accent, 0.3).color, location: 0),
                    .init(
                        color: look.background.mixed(with: look.accent, 0.1)
                            .mixed(with: ShareStyle.night, 0.4).color,
                        location: 0.4),
                    .init(color: edge.color, location: 1),
                ],
                center: isSquare ? UnitPoint(x: 0.27, y: 0.5) : UnitPoint(x: 0.5, y: 0.34),
                startRadius: 0, endRadius: aspect.size.width * 0.9)
            // A scrim under the text keeps it legible on light spine colors.
            LinearGradient(
                stops: [
                    .init(color: edge.color.opacity(0), location: isSquare ? 0.4 : 0.5),
                    .init(color: edge.color, location: isSquare ? 0.56 : 0.66),
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
        let ratio = Book3DView.aspect(of: cover)
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
        let details = ShareStyle.details(book)
        return VStack(alignment: alignment, spacing: 18) {
            if let label {
                ShareStyle.label(label).foregroundStyle(ShareStyle.gold)
            }
            Text(book.spineTitle)
                .font(ShareStyle.serif(isSquare ? 64 : 80, .semibold))
                .lineLimit(isSquare ? 4 : 3)
                .minimumScaleFactor(0.5)
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
        let stops = books.map { ShareStyle.backdrop(input.look(for: $0).background, 0.55).color }
        ZStack {
            LinearGradient(
                colors: stops.count > 1 ? stops : [stops.first ?? .black, stops.first ?? .black],
                startPoint: .top, endPoint: .bottom)
            if let first = books.first {
                // A glow behind the fan from the first book's spine; still dark enough for text.
                let look = input.look(for: first)
                RadialGradient(
                    colors: [
                        ShareStyle.backdrop(look.background.mixed(with: look.accent, 0.35), 0.25)
                            .color,
                        .clear,
                    ], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0,
                    endRadius: aspect.size.width * 0.75)
            }
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
            let leadHeight = min(size.height * 0.78, size.width * 0.55)
            // An outer book, at 0.82 of the lead height and turned about 15 degrees, reaches up
            // to 0.47 lead heights from its center with the widest cover Book3DView allows. This
            // spacing keeps the outermost slot (2) inside the fan's width, and so in the gutters.
            let spacing = min(size.width * 0.16, (size.width / 2 - 0.47 * leadHeight) / 2)
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
                Text(book.spineTitle)
                    .font(ShareStyle.serif(38, .semibold))
                    .minimumScaleFactor(0.8)
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
        let years = input.books.map { $0.finishedYear ?? 0 }
        // Square images stand the spines upright; taller ones lay them flat.
        let isUpright = aspect == .square
        let showsYears = input.frame == .lifetime && !isUpright && Set(years).count > 1
        let count = input.books.count
        ZStack {
            ShareStyle.backdrop(ShareStyle.leadColor(looks.map(\.background)), 0.88).color
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
