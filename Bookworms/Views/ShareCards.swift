import SwiftUI

/// The time frame's books as spines stacked on a shelf, with the frame and its totals.
///
/// The header sits a little below the image's top edge, and the shelf runs across the bottom
/// edge, so the stack takes all the height between them. Each book is its own spine
/// (`StackSpine`). When the spines don't fit one image at a legible size, the card spans several
/// pages (`StackPages`), and `ShareInput.page` chooses the one to draw.
struct YearStackCard: View {
    let input: ShareInput

    /// The least room between the header and the top of the stack.
    private nonisolated static let spacing: CGFloat = 32

    /// The margin above the header's text. Feed posts need only a little. A story's keeps the
    /// heading below the progress bars and profile row that Instagram draws over a story's top
    /// 140 or so pixels.
    private nonisolated static func top(_ aspect: ShareAspect) -> CGFloat {
        aspect == .story ? 136 : 32
    }

    /// The header's height: the heading's and the totals' lines and the space between them.
    private nonisolated static func headerHeight(_ aspect: ShareAspect) -> CGFloat {
        aspect == .square ? 178 : 230
    }

    /// The space the spines stack in, between the header and the shelf.
    nonisolated static func area(_ aspect: ShareAspect) -> CGSize {
        CGSize(
            width: aspect.size.width - aspect.insets.leading - aspect.insets.trailing,
            height: aspect.size.height - top(aspect) - headerHeight(aspect) - spacing
                - ShelfPlank.base)
    }

    /// The input's books as spines, split into the card's pages.
    nonisolated static func pages(for input: ShareInput) -> StackPages {
        StackPages(
            spines: input.books.map(StackSpine.init), area: area(input.aspect),
            look: input.look(for:))
    }

    var body: some View {
        let aspect = input.aspect
        let area = Self.area(aspect)
        let pages = Self.pages(for: input)
        let count = pages.pages.count
        let page = min(max(0, input.page), count - 1)
        let layout = StackLayout(spines: pages.pages[page], area: area, seed: input.seed)
        let theme = input.theme
        ZStack(alignment: .bottom) {
            RadialGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0,
                endRadius: aspect.size.height * 0.8)
            ShelfPlank(
                page: count > 1 ? "\(page + 1) of \(count)" : nil,
                note: page == count - 1 && pages.hiddenCount > 0
                    ? "+\(pages.hiddenCount) more" : nil,
                inset: aspect.insets.leading)
            // The stack comes after the shelf so its bottom spine covers the back of the board's
            // top, where it rests.
            VStack(spacing: 0) {
                header(isSquare: aspect == .square)
                    .frame(height: Self.headerHeight(aspect), alignment: .top)
                Spacer(minLength: Self.spacing)
                ZStack(alignment: .topLeading) {
                    ForEach(layout.slabs) { slab in
                        ShareSpine(
                            spine: slab.spine, look: input.look(for: slab.spine.book),
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
            }
            .padding(.top, Self.top(aspect))
            .padding(.bottom, ShelfPlank.base)
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

/// One book's spine in the Year Stack.
///
/// Sizes are in decimeters, as `BookShape` measures books, and keep the Library's Stack
/// proportions (`StackArrangement.spine(of:)`), so every spine is book-shaped.
struct StackSpine: Identifiable {
    /// Stack's arrangement at an arbitrary width. Its spines are proportional to its scale, so
    /// `shape(of:)` divides the scale out.
    private static let stack = StackArrangement(width: 400)

    let book: CloudBook
    /// The length by the thickness, lying flat.
    let size: CGSize
    /// The fewest pixels per decimeter at which the spine stays legible: thick enough for
    /// `ShareSpine.minimumThickness`, and once `StackPages` has measured its lettering, long
    /// enough to letter a title in full.
    var minimumScale: CGFloat = 0

    var id: Int { book.id }

    init(book: CloudBook) {
        self.book = book
        size = Self.shape(of: book)
        minimumScale = ShareSpine.minimumThickness / size.height
    }

    /// Stack's spine for `book` lying flat, in decimeters: its length by its thickness.
    static func shape(of book: CloudBook) -> CGSize {
        let spine = stack.spine(of: book)
        return CGSize(width: spine.width / stack.scale, height: spine.height / stack.scale)
    }

    /// The lettering's forms, longest first (`ShareStyle.titles(_:)`).
    var titles: [String] { ShareStyle.titles(book) }

    /// Orders spines as `ShareTemplate.isRankedHigher` orders their books.
    static func isRankedHigher(_ lhs: StackSpine, _ rhs: StackSpine) -> Bool {
        ShareTemplate.isRankedHigher(lhs.book, rhs.book)
    }
}

/// The Year Stack's spines split across pages, in finish order.
///
/// Spines fill as few pages as hold them, up to `maximumPages`, in order, so page 1 holds the
/// earliest books. Each page's run of spines must fit the page at its own smallest legible scale
/// (`StackLayout.fits(_:area:)`): the scale at which its thinnest spine letters at the minimum
/// size and every spine whose title can fit has room to letter it in full, which the page's
/// longest spine must leave room for. The pages share the spines as evenly as that allows, so
/// each draws at a similar size. Only spines that 20 pages cannot hold are left out,
/// lowest-ranked first.
struct StackPages {
    /// Instagram's carousel limit.
    static let maximumPages = 20

    /// The pages' spines. There is always at least one page, which can be empty.
    private(set) var pages: [[StackSpine]]
    /// The books left out because 20 pages could not hold them.
    private(set) var hiddenCount = 0

    /// Splits `spines` into pages of `area`, measuring each spine's titles in `look`'s font.
    init(
        spines: [StackSpine], area: CGSize,
        look: (CloudBook) -> SpineLook = { SpineLook(book: $0, design: nil, face: nil) }
    ) {
        // A title that has no room even at the spine's largest scale asks for none.
        let spines = spines.map { spine in
            var spine = spine
            let limit = StackLayout.maximumScale([spine], area: area)
            let lettering = ShareSpine.letteringScale(spine, look: look(spine.book), limit: limit)
            spine.minimumScale = max(spine.minimumScale, lettering ?? 0)
            return spine
        }
        if let pages = Self.paginate(spines, area: area) {
            self.pages = pages
            return
        }
        // Keeps the most top-ranked spines that 20 pages hold. Fewer spines need no more pages,
        // so bisection finds the count. Any one spine fits a page, so at least one is kept.
        let ranked = spines.sorted(by: StackSpine.isRankedHigher)
        var (fitting, failing) = (0, ranked.count)
        var pages: [[StackSpine]] = [[]]
        while failing - fitting > 1 {
            let count = (fitting + failing) / 2
            let kept = Set(ranked.prefix(count).map(\.id))
            if let fitted = Self.paginate(spines.filter { kept.contains($0.id) }, area: area) {
                (fitting, pages) = (count, fitted)
            } else {
                failing = count
            }
        }
        self.pages = pages
        hiddenCount = spines.count - pages.joined().count
    }

    /// `spines` on the fewest pages, up to `maximumPages`, that each fit `area`, with the thickest
    /// page as thin as that number of pages allows, or `nil` when 20 pages can't hold them.
    private static func paginate(_ spines: [StackSpine], area: CGSize) -> [[StackSpine]]? {
        guard !spines.isEmpty else { return [[]] }
        // Any part of a run that fits also fits, so filling each page as full as it goes uses
        // the fewest pages.
        let fewest = fill(spines, area: area, limit: .infinity)
        guard fewest.count <= maximumPages else { return nil }
        // The thinnest limit on a page's thickness that still needs no more pages.
        var pages = fewest
        var (low, high) = (
            StackLayout.thickness(spines) / CGFloat(fewest.count), StackLayout.thickness(spines)
        )
        for _ in 0..<30 {
            let limit = (low + high) / 2
            let filled = fill(spines, area: area, limit: limit)
            if filled.count <= fewest.count {
                (pages, high) = (filled, limit)
            } else {
                low = limit
            }
        }
        // The limit can still leave the last page light. Moves a page's last spine to the next
        // page while that brings their thicknesses closer and the next page still fits.
        for _ in pages.indices {
            var moved = false
            for index in pages.indices.dropLast().reversed() {
                while pages[index].count > 1, let last = pages[index].last {
                    let difference =
                        StackLayout.thickness(pages[index])
                        - StackLayout.thickness(pages[index + 1])
                    let next = [last] + pages[index + 1]
                    guard abs(difference - 2 * last.size.height) < abs(difference),
                        StackLayout.fits(next, area: area)
                    else { break }
                    pages[index].removeLast()
                    pages[index + 1] = next
                    moved = true
                }
            }
            if !moved { break }
        }
        return pages
    }

    /// Fills pages in order, starting the next page when a spine would make the current one
    /// thicker than `limit` decimeters or keep it from fitting `area`.
    private static func fill(_ spines: [StackSpine], area: CGSize, limit: CGFloat) -> [[StackSpine]]
    {
        var pages: [[StackSpine]] = []
        for spine in spines {
            if let page = pages.last.map({ $0 + [spine] }),
                StackLayout.thickness(page) <= limit, StackLayout.fits(page, area: area)
            {
                pages[pages.count - 1] = page
            } else {
                pages.append([spine])
            }
        }
        return pages
    }
}

/// Places one page's spines in one stack, oldest at the bottom, each lying flat on the one
/// below it.
///
/// Every image size uses one column. Two side by side would leave spines that keep their book
/// proportions half as long, too short for most titles, so a crowded frame takes more pages
/// instead.
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

    private(set) var slabs: [Slab] = []
    /// Pixels per decimeter of book.
    private(set) var scale: CGFloat = 0
    /// The stack's height.
    private(set) var height: CGFloat = 0

    /// The fewest pixels per decimeter that keep every one of `spines` legible
    /// (`StackSpine.minimumScale`).
    static func minimumScale(_ spines: [StackSpine]) -> CGFloat {
        spines.map(\.minimumScale).max() ?? 0
    }

    /// The most pixels per decimeter for `spines` in `area`: the longest of them lies across the
    /// area's width, with room to shift to either side.
    static func maximumScale(_ spines: [StackSpine], area: CGSize) -> CGFloat {
        let longest = spines.map(\.size.width).max() ?? CGFloat(BookShape.longest)
        return area.width * (1 - 2 * StackArrangement.maximumShift) / longest
    }

    /// Whether `spines` fit one page of `area` at their own `minimumScale(_:)`: they stack no
    /// taller than the area, and the longest of them leaves room for that scale. A long book can
    /// keep a page from the scale that another spine's title needs to letter in full.
    static func fits(_ spines: [StackSpine], area: CGSize) -> Bool {
        let scale = minimumScale(spines)
        return thickness(spines) * scale <= area.height
            && scale <= maximumScale(spines, area: area)
    }

    static func thickness(_ spines: [StackSpine]) -> CGFloat {
        spines.reduce(0) { $0 + $1.size.height }
    }

    /// Stacks `spines` at the largest scale, up to `maximumScale(_:area:)`, that fits `area`'s
    /// height, so a page fills its height unless its spines are few or short.
    init(spines: [StackSpine], area: CGSize, seed: UInt64) {
        let total = Self.thickness(spines)
        guard total > 0 else { return }
        scale = min(Self.maximumScale(spines, area: area), area.height / total)
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
/// image.
///
/// `SpineView` sizes its lettering from the thickness and shrinks long titles, which leaves
/// stacked spines with text too small to read on a phone. This view draws the spine blank and
/// letters it here instead, through `lettering(_:of:look:width:thickness:)`.
struct ShareSpine: View {
    /// The smallest lettering, in pixels, that reads in a shared image on a phone.
    nonisolated static let minimumLettering: CGFloat = 30
    /// One line's lettering size as a share of the spine's thickness.
    nonisolated static let letteringRatio: CGFloat = 0.5
    /// The smallest size two-line lettering starts at. Only spines thick enough for it wrap a
    /// title, so a wrapped title stays about as large as one line on an ordinary spine.
    nonisolated static let wrappedLettering: CGFloat = 36
    /// The thinnest, in pixels, that a spine can be drawn and stay legible: thick enough for one
    /// line of lettering at `minimumLettering`.
    nonisolated static let minimumThickness: CGFloat = minimumLettering / letteringRatio

    let spine: StackSpine
    /// The look of `spine.book`.
    let look: SpineLook
    let scale: CGFloat

    var body: some View {
        let length = spine.size.width * scale
        let thickness = spine.size.height * scale
        let box = Self.letteringBox(spine, scale: scale)
        SpineView(
            book: CloudBook(
                id: spine.book.id, title: "", author: "", coverURL: nil, detailCoverURL: nil),
            look: look
        )
        .frame(width: length, height: thickness)
        .overlay(alignment: .leading) {
            Self.lettering(
                spine.titles, of: spine.book, look: look, width: box.width, thickness: thickness
            )
            .padding(.leading, box.leading)
        }
    }

    /// The fewest pixels per decimeter, up to `limit`, at which `spine` letters one of its titles
    /// in full at `minimumLettering`, on one line or, when thick enough, two, as drawn
    /// (`letteringLook(_:look:)`); or `nil` when none fits even at `limit`.
    ///
    /// The lettering measures 2 percent wider than `NSString` reports, in case SwiftUI sets it a
    /// little wider.
    nonisolated static func letteringScale(_ spine: StackSpine, look: SpineLook, limit: CGFloat)
        -> CGFloat?
    {
        let font = look.uiFont(size: minimumLettering)
        func width(_ text: String) -> CGFloat {
            let lines = text.split(separator: "\n")
                .map {
                    (String($0) as NSString).size(withAttributes: [.font: font]).width
                }
            return (lines.max() ?? 0) * 1.02
        }
        let forms = spine.titles.map(look.text)
        let oneLine = forms.map(width).min() ?? 0
        let twoLines = forms.compactMap(balanced).map(width).min()
        // The lettering centers its lines in 84 percent of the thickness it sizes to.
        func fits(_ scale: CGFloat) -> Bool {
            let box = letteringBox(spine, scale: scale).width
            let thickness = spine.size.height * scale
            let height = thickness * 0.84
            if oneLine <= box, font.lineHeight <= height { return true }
            guard let twoLines, thickness * 0.32 >= wrappedLettering else { return false }
            return twoLines <= box && 2 * font.lineHeight <= height
        }
        guard fits(limit) else { return nil }
        var (low, high) = (CGFloat(0), limit)
        for _ in 0..<20 {
            let scale = (low + high) / 2
            if fits(scale) { high = scale } else { low = scale }
        }
        return high
    }

    /// Where the lettering starts, from the spine's head, and how wide it is, at `scale` pixels
    /// per decimeter: clear of `SpineView`'s accent bands.
    nonisolated static func letteringBox(_ spine: StackSpine, scale: CGFloat) -> (
        leading: CGFloat, width: CGFloat
    ) {
        let length = spine.size.width * scale
        let thickness = spine.size.height * scale
        let inset = max(6, length * 0.035) + max(2, thickness * 0.07) + max(10, thickness * 0.12)
        return (inset, max(0, length - 2 * inset))
    }

    /// Letters the first way of these that fits a box `width` wide on a spine `thickness` thick,
    /// at sizes from `letteringRatio` of the thickness down to `minimumLettering`.
    ///
    /// At each size, it tries each of `forms` in order, longest first, on one line, then, on a
    /// spine thick enough for two lines at `wrappedLettering`, on two balanced lines. Two lines
    /// take a smaller size than one. So a long title wraps on a thick spine before a subtitle
    /// goes, and a subtitle goes before the lettering shrinks. When nothing fits, the last form
    /// truncates at `minimumLettering`. Forms of `book`'s own title letter its "house" in blue
    /// (`BookText`).
    static func lettering(
        _ forms: [String], of book: CloudBook, look: SpineLook, width: CGFloat, thickness: CGFloat
    ) -> some View {
        let options = options(forms.map(look.text), thickness: thickness)
        return ViewThatFits(in: [.horizontal, .vertical]) {
            ForEach(options.indices, id: \.self) { index in
                BookText(options[index].text, of: book, on: look)
                    .font(look.font(size: options[index].size))
                    .lineLimit(options[index].lines)
            }
        }
        .foregroundStyle(look.foreground.color)
        .frame(width: width, height: thickness * 0.84, alignment: .leading)
    }

    /// The lettering options in the order `lettering(_:of:look:width:thickness:)` tries them.
    static func options(_ forms: [String], thickness: CGFloat) -> [(
        text: String, size: CGFloat, lines: Int
    )] {
        let one = max(minimumLettering, thickness * letteringRatio)
        // Two lines, with their leading, fill the 84 percent of the thickness that one line
        // centers in. `letteringScale(_:look:limit:)` assumes the same share.
        let two = thickness * 0.32
        var options: [(text: String, size: CGFloat, lines: Int)] = []
        var factor: CGFloat = 1
        while true {
            let size = max(minimumLettering, one * factor)
            for form in forms {
                options.append((form, size, 1))
                // Two lines shrink to `minimumLettering` too, once.
                if two >= wrappedLettering, two * factor > minimumLettering * 0.92,
                    let wrapped = balanced(form)
                {
                    options.append((wrapped, max(minimumLettering, two * factor), 2))
                }
            }
            if size == minimumLettering { return options }
            factor *= 0.92
        }
    }

    /// `text` broken at the space nearest its middle, or `nil` when it has no space.
    nonisolated static func balanced(_ text: String) -> String? {
        let characters = Array(text)
        guard
            let space = characters.indices.filter({ characters[$0] == " " })
                .min(by: { abs($0 - characters.count / 2) < abs($1 - characters.count / 2) })
        else { return nil }
        return String(characters[..<space]) + "\n" + String(characters[(space + 1)...])
    }
}

/// A wooden shelf board seen from a little above, across the bottom of a Year Stack image, with
/// optional notes on its front edge: the page, such as "1 of 3", at the left, and a note, such as
/// "+12 more", at the right.
///
/// The front edge holds the credit that sharing adds at the image's bottom edge (`ShareCredit`),
/// centered between the notes.
struct ShelfPlank: View {
    /// The board's top, as it shows from a little above.
    nonisolated static let surface: CGFloat = 12
    /// The board's front edge: the credit's strip, with room to spare.
    nonisolated static let front: CGFloat = ShareCredit.height + 8
    /// How far above the board's bottom the books rest: halfway back on its top.
    nonisolated static let base: CGFloat = front + surface / 2

    var page: String? = nil
    var note: String? = nil
    /// The notes' distance from the board's ends.
    let inset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color(red: 0.62, green: 0.45, blue: 0.31),
                    Color(red: 0.5, green: 0.35, blue: 0.23),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Self.surface)
            LinearGradient(
                colors: [
                    Color(red: 0.37, green: 0.24, blue: 0.15),
                    Color(red: 0.24, green: 0.15, blue: 0.09),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Self.front)
            .overlay {
                HStack {
                    if let page { Text(page) }
                    Spacer(minLength: 0)
                    if let note { Text(note) }
                }
                .font(ShareStyle.serif(32, .semibold))
                .foregroundStyle(ShareStyle.cream.color.opacity(0.9))
                .padding(.horizontal, inset)
            }
        }
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
                lines: isSquare ? 4 : 3, book: book
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
                ShareFittingText(
                    forms: ShareStyle.titles(book), size: 38, minimumScale: 0.8, book: book
                ) {
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
