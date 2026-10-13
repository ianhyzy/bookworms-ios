import SwiftUI

/// The time frame's books as spines stacked on a shelf, with the frame and its totals.
///
/// Two or more books of a series with a known name share one place in the stack as a tied
/// bundle (`StackSpine`). When the spines don't fit one image at a legible size, the card spans
/// several pages (`StackPages`), and `ShareInput.page` chooses the one to draw.
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
                        ShareSpine(
                            spine: slab.spine, looks: slab.spine.books.map(input.look(for:)),
                            scale: layout.scale
                        )
                        // Turned as Stack turns a flat spine, so it faces a little left or right
                        // while lying flat on the book below it.
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

/// One place in the Year Stack: a book, or the books of one series tied in a bundle.
///
/// Sizes are in decimeters, as `BookShape` measures books, and keep the Library's Stack
/// proportions (`StackArrangement.spine(of:)`), so every spine is book-shaped.
struct StackSpine: Identifiable {
    /// The most slices a bundle draws. Its tag counts every book.
    static let maximumSlices = 6

    /// A bundle's greatest thickness for its length: a little squatter than Stack's thickest
    /// book, which is about 4.5 times as long as it is thick.
    static let bundleRatio: CGFloat = 1 / 4.2

    /// The thickness of the thinnest spine: a 100-page book, whatever its variety.
    static let thinnest = shape(
        of: CloudBook(
            id: 0, title: "", author: "", coverURL: nil, detailCoverURL: nil, pages: 100)
    )
    .height

    /// Stack's arrangement at an arbitrary width. Its spines are proportional to its scale, so
    /// `shape(of:)` divides the scale out.
    private static let stack = StackArrangement(width: 400)

    /// The books in finish order. The first sets the spine's place and ranks it with the others.
    let books: [CloudBook]
    /// The slices from the top down, each a book and its size lying flat. A book is one slice.
    let slices: [(book: CloudBook, size: CGSize)]
    /// The length by the thickness of all the slices.
    let size: CGSize

    var book: CloudBook { books[0] }
    var id: Int { book.id }

    /// Lays out `books`, given in finish order.
    ///
    /// A bundle draws up to `maximumSlices` of its books, all as long as the longest of them,
    /// like a series in one edition, so its twine crosses every slice. Together the slices are as
    /// thick as their books, up to `bundleRatio` of that length, and they share that thickness
    /// equally, so a big series packs thin slices into one book-shaped bundle.
    init(books: [CloudBook]) {
        self.books = books
        let shown = books.prefix(Self.maximumSlices).map { (book: $0, size: Self.shape(of: $0)) }
        if shown.count > 1 {
            let length = shown.map(\.size.width).max() ?? 0
            let total = min(shown.reduce(0) { $0 + $1.size.height }, length * Self.bundleRatio)
            slices = shown.map {
                ($0.book, CGSize(width: length, height: total / CGFloat(shown.count)))
            }
        } else {
            slices = shown
        }
        size = CGSize(
            width: slices.map(\.size.width).max() ?? 0,
            height: slices.reduce(0) { $0 + $1.size.height })
    }

    /// Stack's spine for `book` lying flat, in decimeters: its length by its thickness.
    static func shape(of book: CloudBook) -> CGSize {
        let spine = stack.spine(of: book)
        return CGSize(width: spine.width / stack.scale, height: spine.height / stack.scale)
    }

    /// The lettering's forms, longest first: a bundle's series name, or a book's title forms
    /// (`ShareStyle.titles(_:)`).
    var titles: [String] {
        guard books.count > 1, let name = book.seriesName else { return ShareStyle.titles(book) }
        return [name]
    }

    /// Orders spines as `ShareTemplate.isRankedHigher` orders their best-ranked books, so a
    /// bundle ranks as its best-rated book.
    static func isRankedHigher(_ lhs: StackSpine, _ rhs: StackSpine) -> Bool {
        ShareTemplate.isRankedHigher(lhs.best, rhs.best)
    }

    private var best: CloudBook { books.min(by: ShareTemplate.isRankedHigher) ?? book }

    /// Returns `books`, given in finish order, as spines in that order. Two or more books of a
    /// series with a known name become one bundle at the place of the first of them. Books
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
/// Spines that fit one stack at `StackLayout.minimumScale` stay on one page. Otherwise they fill
/// as few pages as hold them, up to `maximumPages`, each a run of spines whose thicknesses come
/// as near an equal share as the spines allow, so page 1 holds the earliest books. Only spines
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
        guard StackLayout.thickness(spines) > capacity else {
            pages = [spines]
            return
        }
        var shown = spines
        let limit = CGFloat(Self.maximumPages) * capacity
        if StackLayout.thickness(spines) > limit {
            var kept = Set<Int>()
            var sum: CGFloat = 0
            for spine in spines.sorted(by: StackSpine.isRankedHigher) {
                guard sum + spine.size.height <= limit else { break }
                kept.insert(spine.id)
                sum += spine.size.height
            }
            shown = spines.filter { kept.contains($0.id) }
        }
        while true {
            let fewest = max(2, Int((StackLayout.thickness(shown) / capacity).rounded(.up)))
            if let split = (fewest...max(fewest, Self.maximumPages)).lazy
                .map({ StackLayout.split(shown, into: $0) })
                .first(where: { $0.allSatisfy { StackLayout.thickness($0) <= capacity } })
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

/// Places one page's spines in one stack, oldest at the bottom, each lying flat on the one
/// below it.
///
/// Every image size uses one column. Two columns of the stack area's width can't hold Stack's
/// longest book (`BookShape.longest`) at `minimumScale` without squashing it, so a crowded frame
/// takes more pages instead.
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

    /// The fewest pixels per decimeter: the scale at which the thinnest spine letters at
    /// `ShareSpine.minimumLettering`.
    static let minimumScale =
        ShareSpine.minimumLettering / (ShareSpine.letteringRatio * StackSpine.thinnest)

    private(set) var slabs: [Slab] = []
    /// Pixels per decimeter of book.
    private(set) var scale: CGFloat = 0
    /// The stack's height.
    private(set) var height: CGFloat = 0

    /// The most pixels per decimeter in `area`: the longest book lies across the area's width,
    /// with room to shift to either side.
    static func maximumScale(_ area: CGSize) -> CGFloat {
        area.width * (1 - 2 * StackArrangement.maximumShift) / CGFloat(BookShape.longest)
    }

    /// The thickest stack, in decimeters, that `area` holds at `minimumScale`.
    static func capacity(_ area: CGSize) -> CGFloat { area.height / minimumScale }

    static func thickness(_ spines: [StackSpine]) -> CGFloat {
        spines.reduce(0) { $0 + $1.size.height }
    }

    /// Splits `spines` into up to `count` runs in order, ending each run where the thickness so
    /// far comes nearest its equal share of the whole.
    static func split(_ spines: [StackSpine], into count: Int) -> [[StackSpine]] {
        let share = thickness(spines) / CGFloat(count)
        var runs: [[StackSpine]] = []
        var sum: CGFloat = 0
        for spine in spines {
            let end = share * CGFloat(runs.count)
            if runs.isEmpty
                || (runs.count < count && abs(sum + spine.size.height - end) > abs(sum - end))
            {
                runs.append([])
            }
            runs[runs.count - 1].append(spine)
            sum += spine.size.height
        }
        return runs
    }

    /// Stacks `spines` at the largest scale, up to `maximumScale(_:)`, that fits `area`'s height.
    init(spines: [StackSpine], area: CGSize, seed: UInt64) {
        let total = Self.thickness(spines)
        guard total > 0 else { return }
        scale = min(Self.maximumScale(area), area.height / total)
        height = total * scale
        var bottom = height
        for spine in spines {
            let id = spine.id
            let size = CGSize(width: spine.size.width * scale, height: spine.size.height * scale)
            // Squares of an even spread, keeping their signs, as `StackArrangement` spreads its
            // offsets, so most spines lie nearly straight: up to 3 percent of the width to
            // either side, and up to 10 degrees of turn.
            let across = 2 * ShareStyle.unit(seed, id, 2) - 1
            let shift = across * abs(across) * StackArrangement.maximumShift * area.width
            let even = 2 * ShareStyle.unit(seed, id, 3) - 1
            slabs.append(
                Slab(
                    spine: spine,
                    center: CGPoint(x: area.width / 2 + shift, y: bottom - size.height / 2),
                    size: size, turn: 10 * even * abs(even)))
            bottom -= size.height
        }
    }
}

/// A Year Stack spine at `scale` pixels per decimeter: a book's `SpineView` lettered for a share
/// image, or a series' slices tied with twine, with the series name lettered across them and the
/// book count on a paper tag.
///
/// `SpineView` sizes its lettering from the thickness and shrinks long titles, which leaves
/// stacked spines with text too small to read on a phone. This view draws the spines blank and
/// letters them here instead (`lettering(_:look:width:thickness:)`).
struct ShareSpine: View {
    /// The smallest lettering, in pixels, that reads in a shared image on a phone.
    nonisolated static let minimumLettering: CGFloat = 30
    /// One line's lettering size as a share of the spine's thickness.
    nonisolated static let letteringRatio: CGFloat = 0.5
    /// The smallest size two-line lettering starts at. Only spines thick enough for it wrap a
    /// title, so a wrapped title stays about as large as one line on an ordinary spine.
    static let wrappedLettering: CGFloat = 36

    let spine: StackSpine
    /// The looks of `spine.books`, in order.
    let looks: [SpineLook]
    let scale: CGFloat

    var body: some View {
        let length = spine.size.width * scale
        let thickness = spine.size.height * scale
        let count = spine.books.count
        let looks = Self.sliceLooks(spine, looks: looks)
        let box = Self.letteringBox(spine, scale: scale)
        VStack(spacing: 0) {
            ForEach(spine.slices.indices, id: \.self) { index in
                let slice = spine.slices[index]
                SpineView(
                    book: CloudBook(
                        id: slice.book.id, title: "", author: "", coverURL: nil,
                        detailCoverURL: nil),
                    look: looks[index]
                )
                .frame(width: slice.size.width * scale, height: slice.size.height * scale)
                // Tied slices lie a little off true, up to 1 percent of the length either way.
                .offset(
                    x: count > 1 ? (ShareStyle.unit(0, slice.book.id, 80) - 0.5) * length * 0.02 : 0
                )
            }
        }
        .frame(width: length, height: thickness)
        .overlay(alignment: .leading) {
            Self.lettering(spine.titles, look: looks[0], width: box.width, thickness: thickness)
                .padding(.leading, box.leading)
        }
        .overlay {
            if count > 1 { Tie(length: length, thickness: thickness, count: count) }
        }
    }

    /// The slices' looks: each book's own, unless the first book's lettering, which runs across
    /// every slice, would lack contrast on one of them. Then every slice takes the first book's
    /// look, as a series in one edition would.
    static func sliceLooks(_ spine: StackSpine, looks: [SpineLook]) -> [SpineLook] {
        let shown = Array(looks.prefix(spine.slices.count))
        let isReadable = shown.allSatisfy {
            $0.background.contrast(with: shown[0].foreground) >= 3
        }
        return isReadable ? shown : shown.map { _ in shown[0] }
    }

    /// Where the lettering starts, from the spine's head, and how wide it is, at `scale` pixels
    /// per decimeter: clear of `SpineView`'s accent bands and of a bundle's twine and tag.
    static func letteringBox(_ spine: StackSpine, scale: CGFloat) -> (
        leading: CGFloat, width: CGFloat
    ) {
        let length = spine.size.width * scale
        let thickness = spine.size.height * scale
        let band = spine.slices[0].size.height * scale
        let inset = max(6, length * 0.035) + max(2, band * 0.07) + max(10, thickness * 0.12)
        var start = inset
        var end = length - inset
        if spine.books.count > 1 {
            let tie = Tie(length: length, thickness: thickness, count: spine.books.count)
            start = max(start, tie.letteringStart)
            end = min(end, tie.letteringEnd)
        }
        return (start, max(0, end - start))
    }

    /// Letters the first way of these that fits a box `width` wide on a spine `thickness` thick,
    /// at sizes from `letteringRatio` of the thickness down to `minimumLettering`.
    ///
    /// At each size, it tries each of `forms` in order, longest first, on one line, then, on a
    /// spine thick enough for two lines at `wrappedLettering`, on two balanced lines. Two lines
    /// take a smaller size than one. So a long title wraps on a thick spine before a subtitle
    /// goes, and a subtitle goes before the lettering shrinks. When nothing fits, the last form
    /// truncates at `minimumLettering`.
    static func lettering(_ forms: [String], look: SpineLook, width: CGFloat, thickness: CGFloat)
        -> some View
    {
        let options = options(forms.map(look.text), thickness: thickness)
        return ViewThatFits(in: [.horizontal, .vertical]) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].text)
                    .font(look.font(size: options[index].size))
                    .lineLimit(options[index].lines)
            }
        }
        .foregroundStyle(look.foreground.color)
        .frame(width: width, height: thickness * 0.84, alignment: .leading)
    }

    /// The lettering options in the order `lettering(_:look:width:thickness:)` tries them.
    static func options(_ forms: [String], thickness: CGFloat) -> [(
        text: String, size: CGFloat, lines: Int
    )] {
        let one = max(minimumLettering, thickness * letteringRatio)
        // Two lines, with their leading, fill the 84 percent of the thickness that one line
        // centers in.
        let two = thickness * 0.32
        var options: [(text: String, size: CGFloat, lines: Int)] = []
        var factor: CGFloat = 1
        while true {
            let size = max(minimumLettering, one * factor)
            for form in forms {
                options.append((form, size, 1))
                if two >= wrappedLettering, two * factor >= minimumLettering,
                    let wrapped = balanced(form)
                {
                    options.append((wrapped, two * factor, 2))
                }
            }
            if size == minimumLettering { return options }
            factor *= 0.92
        }
    }

    /// `text` broken at the space nearest its middle, or `nil` when it has no space.
    static func balanced(_ text: String) -> String? {
        let characters = Array(text)
        guard
            let space = characters.indices.filter({ characters[$0] == " " })
                .min(by: { abs($0 - characters.count / 2) < abs($1 - characters.count / 2) })
        else { return nil }
        return String(characters[..<space]) + "\n" + String(characters[(space + 1)...])
    }
}

/// Twine tied twice around a bundle `length` by `thickness` pixels, near its head and its tail,
/// with a bow on the tail's twine and a paper tag that hangs from the bow and counts the series'
/// books.
///
/// The series name runs between the two. The bow and tag sit on the face, not on top, so the
/// bundle still lies flat under the book above it, and the tag hangs straight down from the bow
/// inside the bundle's face.
private struct Tie: View {
    let length: CGFloat
    let thickness: CGFloat
    let count: Int

    private static let twine = Color(red: 0.8, green: 0.68, blue: 0.48)
    private static let twineDark = Color(red: 0.5, green: 0.38, blue: 0.23)
    private static let twineLight = Color(red: 0.93, green: 0.84, blue: 0.66)

    /// The twine's width.
    var width: CGFloat { max(6, length * 0.011) }
    /// The middle of the twine near the head, from the bundle's head.
    var head: CGFloat { length * 0.08 }
    /// The middle of the twine near the tail, which carries the bow and tag.
    var tail: CGFloat { length * 0.82 }
    /// The bow's middle, from the bundle's top.
    var knot: CGFloat { thickness * 0.15 }
    /// The tag's height, inside the bundle's face. A bundle is at least 105 pixels thick at
    /// `StackLayout.minimumScale`, so the count is lettered at 32 pixels or more.
    var tagHeight: CGFloat { min(thickness * 0.74, 150) }
    var tagTop: CGFloat { knot + thickness * 0.05 }
    /// The room between the lettering and the twine or tag.
    private var gap: CGFloat { max(12, thickness * 0.06) }
    /// Where lettering on the face can start and must end, from the head.
    var letteringStart: CGFloat { head + width / 2 + gap }
    var letteringEnd: CGFloat { tail - SeriesTag.width(height: tagHeight) / 2 - gap }

    var body: some View {
        let hole = tagTop + tagHeight * SeriesTag.hole
        ZStack(alignment: .topLeading) {
            ForEach([head, tail], id: \.self) { middle in
                band
                    .frame(width: width, height: thickness)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, x: 1)
                    .position(x: middle, y: thickness / 2)
            }
            SeriesTag(count: count, height: tagHeight)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 1, y: 2)
                .position(x: tail, y: tagTop + tagHeight / 2)
            // The tag's string runs from the bow down through the tag's hole.
            Capsule()
                .fill(Self.twine)
                .frame(width: width * 0.45, height: hole - knot)
                .position(x: tail, y: (knot + hole) / 2)
            bow
                .position(x: tail, y: knot)
        }
        .frame(width: length, height: thickness)
    }

    /// The twine across the face: rounded across its width, twisted along it, and shaded where
    /// it wraps over the top and bottom edges.
    private var band: some View {
        LinearGradient(
            colors: [Self.twineDark, Self.twineLight, Self.twine, Self.twineDark],
            startPoint: .leading, endPoint: .trailing
        )
        .overlay {
            Twist(pitch: width * 0.9)
                .stroke(Self.twineDark.opacity(0.7), lineWidth: max(1, width * 0.14))
        }
        .overlay {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.4), location: 0),
                    .init(color: .clear, location: 0.06),
                    .init(color: .clear, location: 0.94),
                    .init(color: .black.opacity(0.4), location: 1),
                ], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }

    /// A bow: two loops either side of the knot, with its ends hanging down.
    private var bow: some View {
        let loop = Capsule().fill(Self.twine).stroke(Self.twineDark, lineWidth: 1)
        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                loop
                    .frame(width: width * 0.8, height: width * 3.2)
                    .rotationEffect(.degrees(side * 18), anchor: .top)
                    .offset(y: width * 1.6)
                loop
                    .frame(width: width * 3.4, height: width * 1.7)
                    .rotationEffect(.degrees(side * 22))
                    .offset(x: side * width * 1.6)
            }
            Circle()
                .fill(Self.twine)
                .stroke(Self.twineDark, lineWidth: 1)
                .frame(width: width * 1.6, height: width * 1.6)
        }
    }
}

/// Diagonal strokes down a strand of twine, `pitch` apart, that read as its twist.
private struct Twist: Shape {
    let pitch: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            for y in stride(from: rect.minY - rect.width, through: rect.maxY, by: pitch) {
                path.move(to: CGPoint(x: rect.minX, y: y + rect.width * 0.7))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }
}

/// A manila luggage tag with a reinforced string hole, showing a series' book count.
private struct SeriesTag: View {
    /// The hole's center, as a share of the tag's height from its top.
    static let hole: CGFloat = 0.17

    let count: Int
    let height: CGFloat

    static func width(height: CGFloat) -> CGFloat { height * 0.64 }

    var body: some View {
        let width = Self.width(height: height)
        let shape = TagShape()
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.97, green: 0.92, blue: 0.81),
                        Color(red: 0.91, green: 0.84, blue: 0.69),
                    ], startPoint: .top, endPoint: .bottom))
            shape.stroke(
                Color(red: 0.66, green: 0.54, blue: 0.36), lineWidth: max(1, width * 0.025))
            Circle()
                .fill(Color(red: 0.84, green: 0.73, blue: 0.53))
                .frame(width: width * 0.3, height: width * 0.3)
                .position(x: width / 2, y: height * Self.hole)
            Text(count.formatted())
                .font(ShareStyle.serif(height * 0.42, .semibold))
                .foregroundStyle(Color(red: 0.24, green: 0.16, blue: 0.09))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, width * 0.1)
                .position(x: width / 2, y: height * 0.62)
            // Punched through, so the bundle shows in the hole.
            Circle()
                .frame(width: width * 0.14, height: width * 0.14)
                .position(x: width / 2, y: height * Self.hole)
                .blendMode(.destinationOut)
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) books")
    }
}

/// A luggage tag's outline: a card with its top corners cut off and its bottom corners rounded.
private struct TagShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cut = rect.width * 0.28
        let radius = rect.width * 0.08
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
            path.closeSubpath()
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
