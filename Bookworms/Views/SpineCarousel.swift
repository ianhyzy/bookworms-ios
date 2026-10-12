import SwiftUI

/// The shelf's two presentations of the library.
enum ShelfMode: String, CaseIterable, Identifiable {
    /// Books lying flat on each other, spines toward the reader, in a stack that scrolls
    /// vertically.
    case stack
    /// Spines standing side by side in a wooden bookcase that scrolls horizontally.
    case shelf

    var id: Self { self }
    var title: String { self == .stack ? "Stack" : "Shelf" }
}

/// How **Stack** draws its books. The raw values are what `BookwormsStackStyle` saves.
enum StackStyle: String {
    /// Flat spines (`SpineView`).
    case flat = "2d"
    /// 3D books (`Book3DView`) seen from slightly above and in front, so each book's top board
    /// shows above its spine.
    case threeD = "3d"

    /// How far a 3D book turns about its length to show its top board, in radians.
    static let lookDown = 0.3
    /// The shading of a 3D book's faces. `Book3DView` lights an upright book from its upper
    /// left, which lies at the lower left of a book on its back, so full shading would darken
    /// the top boards most.
    static let lighting = 0.6

    /// How `book` lies in the stack, which is also where its flight to the details starts.
    /// `covered` says whether another book lies on it, hiding all of a 3D book but its spine.
    func rest(of book: CloudBook, covered: Bool) -> PullOutPath.Rest {
        let tilt = StackArrangement.tilt(of: book)
        switch self {
        case .flat:
            return PullOutPath.Rest(tilt: tilt)
        case .threeD:
            return PullOutPath.Rest(
                tilt: tilt, yaw: -Self.lookDown, pitch: StackArrangement.twist(of: book),
                lighting: Self.lighting, isCovered: covered)
        }
    }
}

/// The library's spines, as a stack of books (Stack) or a bookcase (Shelf), reporting the book
/// nearest the viewport's center through `centeredID`.
///
/// Both scroll freely, with ordinary momentum. Stack lays each book a little askew (`StackArrangement`)
/// and draws it flat or in 3D, as the saved `StackStyle` says. Shelf scrolls with the bookcase's
/// wood as part of the content. A tap on any book opens it, and so does VoiceOver activation.
/// The body does not read `centeredID`.
///
/// While `pullOut` has a book out, that book hides, leaving a shadowed gap, and reports the gap's
/// frame, where the book flies from and back to.
struct SpineCarousel: View {
    let books: [CloudBook]
    let mode: ShelfMode
    @Binding var centeredID: Int?
    /// The zoom transition's source namespace; each spine is a source keyed by its book ID.
    let namespace: Namespace.ID
    let pullOut: ShelfPullOut
    /// Opens a book's details.
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AppStorage("BookwormsStackStyle") private var style = StackStyle.flat

    /// Shelved books nearly touch, so their spines read as separate books.
    private static let shelfSpacing: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            switch mode {
            case .stack: stack(in: proxy.size)
            case .shelf: shelf(in: proxy.size)
            }
        }
        // A pulled book that a library update removes has no place to return to.
        .onChange(of: books.map(\.id)) { _, ids in
            if let id = pullOut.book?.id, !ids.contains(id) { pullOut.close() }
        }
        // A book can only return to the place it left, which the other style draws differently.
        .onChange(of: style) { pullOut.close() }
        .background {
            // A pool of warm light behind the middle of the stack, larger than the carousel so its
            // falloff never meets an edge. The shelf's lamp lights the bookcase instead.
            if mode == .stack {
                RadialGradient(
                    colors: [ShelfPalette.lamp.opacity(0.22), .clear], center: .center,
                    startRadius: 0, endRadius: 320
                )
                .frame(width: 700, height: 700)
                .accessibilityHidden(true)
            }
        }
    }

    private func stack(in size: CGSize) -> some View {
        let arrangement = StackArrangement(width: size.width)
        let track = arrangement.track(of: books)
        // A spine overhangs its page by up to half its thickness, and a 3D book's top board rises
        // above its spine, so the mask hides that much at each end, where the lazy stack may not
        // have built a book's page.
        let rise = style == .threeD ? StackedBook.rise(of: books, in: arrangement) : 0
        let stops = StackArrangement.maskStops(
            height: size.height, top: track.maxThickness / 2,
            bottom: track.maxThickness / 2 + rise)
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                Color.clear.frame(height: track.leadingSpace(viewport: size.height))
                LazyVStack(spacing: 0) {
                    ForEach(track.pages.indices, id: \.self) { page in
                        ZStack(alignment: .topLeading) {
                            ForEach(track.pages[page]) { slot in
                                spineButton(slot.book) {
                                    stackedBook(
                                        slot.book, spine: arrangement.spine(of: slot.book),
                                        covered: slot.index > 0)
                                }
                                .padding(.leading, arrangement.leading(of: slot.book))
                                .padding(.top, slot.inset)
                                // Each book lies over the top board of the book below it.
                                .zIndex(-Double(slot.index))
                            }
                        }
                        .frame(
                            width: size.width, height: SpineTrack.pageLength, alignment: .topLeading
                        )
                        .zIndex(-Double(page))
                    }
                }
                Color.clear.frame(height: track.trailingSpace(viewport: size.height))
            }
        }
        .modifier(
            CenterTracking(
                track: track, axis: .vertical, viewport: size.height, centeredID: $centeredID)
        )
        // Fades the stack as one image, so a fading 3D book never shows the book under it through
        // its spine. The mask also hides the top boards that would rise under the bar.
        .mask { LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom) }
    }

    /// A stacked book, lying as `style` says, with its spine filling `spine`'s length and
    /// thickness. `covered` says whether another book lies on it.
    @ViewBuilder
    private func stackedBook(_ book: CloudBook, spine: CGSize, covered: Bool) -> some View {
        let look = model.look(for: book)
        let rest = style.rest(of: book, covered: covered)
        switch style {
        case .flat:
            SpineView(book: book, look: look)
                .frame(width: spine.width, height: spine.height)
                .rotationEffect(.radians(rest.tilt))
                .modifier(PulledSpine(id: book.id, pullOut: pullOut, upright: false, rest: rest))
        case .threeD:
            StackedBook(book: book, look: look, spine: spine, rest: rest, pullOut: pullOut)
        }
    }

    private func shelf(in size: CGSize) -> some View {
        let bookcase = Bookcase(height: size.height)
        let scale = bookcase.scale
        let track = SpineTrack(books: books) {
            $0.shelfSpineSize(scale: scale).width
        } gap: { _, _ in
            Self.shelfSpacing
        }
        // How far the scroll view reaches past each side of the screen. Pages hold the spines
        // centered in them, so a spine overhangs its page by up to half its thickness, and a
        // lazy stack builds only the pages within its scroll view's bounds. Reaching past half
        // the thickest spine and its contact shadow keeps a page built while any of its spines
        // shows. VoiceOver gets the screen's width instead, so it treats only spines on screen
        // as visible and pages by the screen.
        let bleed = voiceOver ? 0 : (track.maxThickness / 2 + 4).rounded(.up)
        let viewport = size.width + 2 * bleed
        let leading = track.leadingSpace(viewport: viewport)
        return ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                BookcaseWood(bookcase: bookcase, start: leading, length: track.length)
                HStack(spacing: 0) {
                    Color.clear.frame(width: leading)
                    // Top aligned, because the lazy stack takes the scroll view's full height.
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach(track.pages.indices, id: \.self) { page in
                            ZStack(alignment: .bottomLeading) {
                                ForEach(track.pages[page]) { slot in
                                    let spine = slot.book.shelfSpineSize(scale: scale)
                                    spineButton(slot.book) {
                                        UprightSpineView(
                                            book: slot.book, look: model.look(for: slot.book),
                                            height: spine.height, thickness: spine.width
                                        )
                                        .modifier(
                                            PulledSpine(
                                                id: slot.book.id, pullOut: pullOut, upright: true))
                                    }
                                    .background(alignment: .bottom) {
                                        ContactShadow(width: spine.width)
                                    }
                                    // VoiceOver reads by shelf order, not by the uneven tops.
                                    .accessibilitySortPriority(-Double(slot.index))
                                    .padding(.leading, slot.inset)
                                }
                            }
                            .frame(
                                width: SpineTrack.pageLength, height: bookcase.base,
                                alignment: .bottomLeading)
                        }
                    }
                    // Scopes the sort priorities to the spines.
                    .accessibilityElement(children: .contain)
                    Color.clear.frame(width: track.trailingSpace(viewport: viewport))
                }
            }
            .frame(height: size.height, alignment: .top)
        }
        .modifier(
            CenterTracking(
                track: track, axis: .horizontal, viewport: size.width, centeredID: $centeredID)
        )
        .padding(.horizontal, -bleed)
        .overlay { ShelfLamp().modifier(LampHandOff(pullOut: pullOut)) }
    }

    /// A book's button, which opens it.
    private func spineButton(_ book: CloudBook, @ViewBuilder label: () -> some View) -> some View {
        Button {
            open(book)
        } label: {
            label().matchedTransitionSource(id: book.id, in: namespace)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(book.title), by \(book.author)")
        .accessibilityHint("Opens the book's details.")
    }
}

/// A book in **Stack**'s 3D style: `Book3DView` lying on its back, head on the left, seen from
/// slightly above and in front, as `rest` turns it.
///
/// The book is scaled as a pulled-out book starts (`PullOutPath`), so its spine nearly fills
/// `spine`, the slot's length and thickness. It sits on the slot's bottom edge, and its top board
/// rises above the slot, under the book above. The book loads its cover, whose shape sets the
/// board's width, as the details do.
private struct StackedBook: View {
    let book: CloudBook
    let look: SpineLook
    /// The slot's length and thickness.
    let spine: CGSize
    let rest: PullOutPath.Rest
    let pullOut: ShelfPullOut

    @Environment(AppModel.self) private var model
    @State private var cover: UIImage?

    /// The scale that fits the book's spine to `spine`, and the drawn book's size before its
    /// tilt, for a cover `aspect` wide.
    static func fit(
        spine: CGSize, aspect: CGFloat, rest: PullOutPath.Rest
    ) -> (scale: CGFloat, drawn: CGSize) {
        let scale =
            1
            / PullOutPath.spineMagnification(
                aspect: aspect, thicknessRatio: spine.height / spine.width)
        let bounds = BookProjection(
            width: spine.width * aspect, height: spine.width, thickness: spine.height,
            yaw: .pi / 2 + rest.yaw, pitch: rest.pitch
        )
        .bounds
        // Lying on its back, the drawn book's width runs along the screen's height.
        return (scale, CGSize(width: bounds.height * scale, height: bounds.width * scale))
    }

    /// How far the top board of the longest of `books`, with the widest cover `Book3DView` draws,
    /// rises above its spine: about the most that any of the books' boards rises.
    static func rise(of books: [CloudBook], in arrangement: StackArrangement) -> CGFloat {
        let longest = books.max {
            arrangement.spine(of: $0).width < arrangement.spine(of: $1).width
        }
        guard let longest else { return 0 }
        let spine = arrangement.spine(of: longest)
        let rest = StackStyle.threeD.rest(of: longest, covered: true)
        return fit(spine: spine, aspect: Book3DView.aspects.upperBound, rest: rest).drawn.height
            - spine.height
    }

    var body: some View {
        let (scale, drawn) = Self.fit(
            spine: spine, aspect: Book3DView.aspect(of: cover), rest: rest)
        Book3DView(
            book: book, look: look, cover: cover, height: spine.width, yaw: .pi / 2 + rest.yaw,
            pitch: rest.pitch, thicknessRatio: spine.height / spine.width, lighting: rest.lighting
        )
        .scaleEffect(scale)
        .rotationEffect(.radians(-.pi / 2 + rest.tilt))
        .frame(width: drawn.width, height: drawn.height)
        .frame(width: spine.width, height: spine.height, alignment: .bottom)
        .modifier(
            PulledSpine(
                id: book.id, pullOut: pullOut, upright: false, rest: rest,
                lift: (spine.height - drawn.height) / 2)
        )
        .task(id: book.coverCandidates.first) {
            cover = await model.covers.image(for: book)
        }
    }
}

/// Hides a spine while `pullOut` has its book out, leaving a gap in the shadow of the books beside
/// it, and reports the gap's frame and how the book lay in it.
///
/// The gap reports its frame as soon as the book is pulled, while the spine still shows, and the
/// spine hides once the flying book is drawn over it, so no frame shows neither. The frame is the
/// layout frame, before `rest.tilt`, which the flight applies itself; `lift` moves it to the
/// center of the drawn book where that differs from the slot's.
private struct PulledSpine: ViewModifier {
    let id: Int
    let pullOut: ShelfPullOut
    /// Whether the spine stands upright, so its neighbors are on its left and right.
    let upright: Bool
    var rest = PullOutPath.Rest()
    /// How far the drawn book's center lies below the slot's, negative for above.
    var lift: CGFloat = 0

    func body(content: Content) -> some View {
        let isPulled = pullOut.book?.id == id
        content
            .opacity(isPulled && pullOut.isOut ? 0 : 1)
            .background {
                if isPulled {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.75), location: 0),
                            .init(color: .black.opacity(0.4), location: 0.3),
                            .init(color: .black.opacity(0.4), location: 0.7),
                            .init(color: .black.opacity(0.75), location: 1),
                        ], startPoint: upright ? .leading : .top,
                        endPoint: upright ? .trailing : .bottom
                    )
                    .rotationEffect(.radians(rest.tilt))
                    // Measured outside the tilt, which would otherwise report its bounding box.
                    .background {
                        Color.clear.onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .global).offsetBy(dx: 0, dy: lift)
                        } action: {
                            pullOut.rest = rest
                            pullOut.home = $0
                        }
                    }
                }
            }
    }
}

/// Keeps `centeredID` on the book nearest the center, and scrolls to `centeredID` when something
/// other than scrolling changes it.
///
/// Tracking and scrolling use `SpineTrack` offsets, which match the layout exactly. Offsets count
/// from the end of the scroll view's content inset, as `ScrollPosition` does; the scroll view
/// takes a top inset where it meets the navigation bar.
private struct CenterTracking: ViewModifier {
    let track: SpineTrack
    let axis: Axis
    /// The length along `axis` that shows on screen.
    let viewport: CGFloat
    @Binding var centeredID: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition()
    /// The book that scrolling last brought to the center, which tells scrolling apart from
    /// other changes to `centeredID`.
    @State private var scrolledID: Int?

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            // Watches the offset rather than the book at it: a new order puts another book at
            // the same offset, which must not replace the `centeredID` that a sort sets.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                axis == .vertical
                    ? geometry.contentOffset.y + geometry.contentInsets.top
                    : geometry.contentOffset.x + geometry.contentInsets.leading
            } action: { old, offset in
                // The first call reports the starting offset, before `onAppear` scrolls to
                // `centeredID`, so only an actual change moves `centeredID`.
                let id = track.id(nearest: offset)
                guard offset != old, id != scrolledID else { return }
                scrolledID = id
                centeredID = id
            }
            .onChange(of: centeredID) {
                guard centeredID != scrolledID else { return }
                // Glides to a book on screen, and jumps to one off screen, such as the first book
                // after a new sort.
                let distance = abs(track.offset(of: centeredID) - track.offset(of: scrolledID))
                let glides = !reduceMotion && distance < viewport / 2
                withAnimation(glides ? .smooth : nil) { scrollToCenteredBook() }
            }
            // The same offset centers a different book after the order changes, and a new order
            // or a new scale moves the centered book's offset. A reorder can leave the offsets
            // equal, so both are watched.
            .onChange(of: track.ids) { scrollToCenteredBook() }
            .onChange(of: track.offsets) { scrollToCenteredBook() }
            // A new carousel, such as after a mode switch, opens on the centered book. One that
            // reappears, such as after Back from details, keeps its offset, because a free
            // scroll rarely rests exactly on a book's.
            .onAppear {
                if centeredID != scrolledID { scrollToCenteredBook() }
            }
            .scrollIndicators(.hidden)
            // The stack's books fade out before its ends, and the shelf's top board meets the
            // bar, so the bar's edge effect would only draw a seam across the walnut.
            .scrollEdgeEffectHidden()
    }

    private func scrollToCenteredBook() {
        let offset = track.offset(of: centeredID)
        if axis == .vertical { position.scrollTo(y: offset) } else { position.scrollTo(x: offset) }
    }
}

/// The carousel's spines laid out along its scroll axis, from their thicknesses and the gaps
/// between neighbors.
///
/// A lazy stack estimates the extent of rows it has not built, so with one spine per row, a
/// fling or a jump to a distant book stops with a different spine at the center than the one
/// the scroll offset names. The carousel's lazy stack therefore holds pages of equal length,
/// with no spacing, so it places even pages it has not built exactly and `offsets` match the
/// layout. Each page holds the spines whose centers fall within it; a spine may overhang its
/// page by half its thickness. The stack's mask hides half of `maxThickness` at each end of its
/// scroll view (`StackArrangement.maskStops(height:top:bottom:)`), so every visible book's page
/// intersects the scroll view and is built. Shelved spines stay opaque, so the shelf's scroll view
/// reaches past the screen's sides by half of `maxThickness` instead.
struct SpineTrack {
    static let pageLength: CGFloat = 100

    /// A spine on a page, `inset` from the page's start. The inset is negative for a spine that
    /// overhangs the page's start. `index` is the spine's position in `ids`.
    struct Slot: Identifiable {
        let book: CloudBook
        let index: Int
        let inset: CGFloat
        var id: Int { book.id }
    }

    let ids: [Int]
    /// The scroll offset that centers each spine. The first spine is centered at offset 0.
    let offsets: [CGFloat]
    let pages: [[Slot]]
    /// From the first spine's start to the last spine's end.
    let length: CGFloat
    let maxThickness: CGFloat
    private let firstThickness: CGFloat
    private let lastThickness: CGFloat

    /// Lays out `books` with `thickness` along the scroll axis, each `gap` after the one before
    /// it. A negative gap overlaps the neighbors.
    init(
        books: [CloudBook], thickness: (CloudBook) -> CGFloat,
        gap: (_ before: CloudBook, _ after: CloudBook) -> CGFloat
    ) {
        ids = books.map(\.id)
        let thicknesses = books.map(thickness)
        firstThickness = thicknesses.first ?? 0
        lastThickness = thicknesses.last ?? 0
        maxThickness = thicknesses.max() ?? 0
        var start: CGFloat = 0
        var offsets: [CGFloat] = []
        var pages: [[Slot]] = []
        for (index, (book, thickness)) in zip(books, thicknesses).enumerated() {
            if index > 0 { start += gap(books[index - 1], book) }
            offsets.append(start + (thickness - firstThickness) / 2)
            let page = Int((start + thickness / 2) / Self.pageLength)
            while pages.count <= page { pages.append([]) }
            let inset = start - CGFloat(page) * Self.pageLength
            pages[page].append(Slot(book: book, index: index, inset: inset))
            start += thickness
        }
        self.offsets = offsets
        self.pages = pages
        length = start
    }

    /// The space before the first page, so the first spine can reach the viewport's center.
    func leadingSpace(viewport: CGFloat) -> CGFloat { max(0, (viewport - firstThickness) / 2) }

    /// The space after the last page, so the last spine can reach the viewport's center, less
    /// the room the last page already leaves after it.
    func trailingSpace(viewport: CGFloat) -> CGFloat {
        let pagesEnd = CGFloat(pages.count) * Self.pageLength
        return max(0, (viewport - lastThickness) / 2 - (pagesEnd - length))
    }

    /// The index of the spine nearest the center at `offset`, or `nil` for an empty track.
    func index(nearest offset: CGFloat) -> Int? {
        guard !offsets.isEmpty else { return nil }
        // Binary search for the first spine whose midpoint with the next lies past `offset`.
        var low = 0
        var high = offsets.count - 1
        while low < high {
            let middle = (low + high) / 2
            if (offsets[middle] + offsets[middle + 1]) / 2 < offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    func id(nearest offset: CGFloat) -> Int? { index(nearest: offset).map { ids[$0] } }

    /// The offset that centers the book with `id`, or the first book when `id` is absent.
    func offset(of id: Int?) -> CGFloat {
        id.flatMap { ids.firstIndex(of: $0) }.map { offsets[$0] } ?? 0
    }
}

/// Where **Stack** lays each book in a scroll view `width` points wide, so the books look
/// casually piled: the spine's size, how far the book lies off the stack's middle, and how far it
/// turns.
///
/// Spines have the shelf's sizes (`CloudBook.shelfSpineSize(scale:)`) lying on their side, at the
/// largest scale that fits the longest possible book across the screen. A book's offsets come from
/// its ID, so it lies the same way on every launch and in every order. Each offset is the square
/// of an even spread, keeping its sign, so most books lie nearly straight and few reach the
/// limits. Each book rests on the one below it, touching it where they meet (`gap(above:below:)`).
struct StackArrangement {
    /// How far a book can lie off the middle, as a share of the width.
    static let maximumShift: CGFloat = 0.03
    /// How far a book can turn in the screen's plane: 1.5 degrees.
    static let maximumTilt = 1.5 * Double.pi / 180
    /// How far a 3D book can turn about the screen's vertical axis, in radians. A turn past about
    /// 0.16 shows the page edges at one end of the book.
    static let maximumTwist = 0.3
    /// Space between the screen's edges and the longest book lying in the middle.
    static let margin: CGFloat = 16
    /// How far the stack fades in from each end of the masked part of its scroll view.
    static let fade: CGFloat = 96

    /// A book's place in the stack: its center's distance right of the middle, its length, and
    /// its clockwise turn in radians.
    struct Lie {
        var center: CGFloat
        var length: CGFloat
        var tilt: Double
    }

    let width: CGFloat
    /// Points per decimeter of book, up to the shelf's largest.
    let scale: CGFloat

    init(width: CGFloat) {
        self.width = width
        let room = width * (1 - 2 * Self.maximumShift) - 2 * Self.margin
        scale = min(170, max(1, room / CGFloat(BookShape.longest)))
    }

    /// The spine lying on its side: its length by its thickness.
    func spine(of book: CloudBook) -> CGSize {
        let upright = book.shelfSpineSize(scale: scale)
        return CGSize(width: upright.height, height: upright.width)
    }

    /// The distance from the scroll view's leading edge to the spine's, before its tilt.
    func leading(of book: CloudBook) -> CGFloat {
        (width - spine(of: book).width) / 2 + shift(of: book)
    }

    func shift(of book: CloudBook) -> CGFloat {
        width * Self.maximumShift * Self.spread(book, salt: 70)
    }

    static func tilt(of book: CloudBook) -> Double { maximumTilt * spread(book, salt: 71) }

    static func twist(of book: CloudBook) -> Double { maximumTwist * spread(book, salt: 72) }

    /// The books from the top of the stack to the bottom.
    func track(of books: [CloudBook]) -> SpineTrack {
        SpineTrack(books: books) {
            spine(of: $0).height
        } gap: { above, below in
            Self.gap(above: lie(of: above), below: lie(of: below))
        }
    }

    func lie(of book: CloudBook) -> Lie {
        Lie(center: shift(of: book), length: spine(of: book).width, tilt: Self.tilt(of: book))
    }

    /// The space from the bottom of `above`'s spine to the top of `below`'s, both measured at the
    /// spine's center before its tilt, that makes the two touch at one point and nowhere overlap.
    ///
    /// Along the length the books share, each spine's edge is a line, so the books first meet at
    /// one end of that span. The tilt's small change to a spine's ends and thickness is ignored.
    static func gap(above: Lie, below: Lie) -> CGFloat {
        let start = max(above.center - above.length / 2, below.center - below.length / 2)
        let end = min(above.center + above.length / 2, below.center + below.length / 2)
        func overlap(at x: CGFloat) -> CGFloat {
            (x - above.center) * tan(above.tilt) - (x - below.center) * tan(below.tilt)
        }
        return max(overlap(at: start), overlap(at: end))
    }

    /// The stops of the stack's mask, from the top of a scroll view `height` points tall to its
    /// bottom: clear for `top` and `bottom` points at the ends, then opaque from `fade` further in.
    /// A scroll view too short for both fades fades in to its middle.
    static func maskStops(height: CGFloat, top: CGFloat, bottom: CGFloat) -> [Gradient.Stop] {
        guard height > 0 else { return [] }
        let opaqueStart = min(0.5, (top + fade) / height)
        let opaqueEnd = max(0.5, 1 - (bottom + fade) / height)
        return [
            .init(color: .clear, location: min(opaqueStart, top / height)),
            .init(color: .black, location: opaqueStart),
            .init(color: .black, location: opaqueEnd),
            .init(color: .clear, location: max(opaqueEnd, 1 - bottom / height)),
        ]
    }

    /// A value in -1...1 from the book's ID and `salt`, mostly near 0.
    private static func spread(_ book: CloudBook, salt: UInt64) -> Double {
        let even = 2 * ShareStyle.unit(0, book.id, salt) - 1
        return even * abs(even)
    }
}

extension CloudBook {
    /// The thickness of the spine that a book's details draw with its design: `thicknessRatio`,
    /// which spans 0.05...0.2, mapped linearly onto 44...96 points, so even a short book has room
    /// for a legible title.
    var slabThickness: CGFloat { 44 + (thicknessRatio - 0.05) / 0.15 * 52 }

    /// The book's spine on the shelf and, lying on its side, in the stack, in points: `width` is
    /// its thickness and `height` its height, from its `BookShape` at `scale` points per
    /// decimeter.
    ///
    /// Heights keep the shape's proportions. Thickness grows from a floor, so a 120-page book's
    /// spine still fits legible lettering, and a 900-page book's is a little over twice as
    /// thick, where in life it is about five times.
    func shelfSpineSize(scale: CGFloat) -> CGSize {
        let size = BookShape(of: self, coverAspect: 2 / 3).size
        return CGSize(
            width: scale * (0.12 + 0.7 * CGFloat(size.z)), height: scale * CGFloat(size.y))
    }
}

/// The proportions of the bookcase that Shelf draws in a scroll view `height` points tall: the
/// front edge of the shelf above, the back panel, and the board the books stand on, whose top
/// shows a little, as seen from just above it.
private struct Bookcase {
    static let topEdge: CGFloat = 14
    static let surface: CGFloat = 12
    static let lip: CGFloat = 18
    /// The board's shadow on the wall below it.
    static let drop: CGFloat = 16
    /// The front of each side panel.
    static let side: CGFloat = 18
    /// Between a side panel and the nearest book.
    static let gap: CGFloat = 6

    /// The board's shadow on the wall below it, under the bays and the side panels alike.
    static var dropShadow: some View {
        LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: drop)
    }

    /// At least the boards and the shadow, so no part gets a negative size, even in a transient
    /// layout of a scroll view with no height. A shorter scroll view clips the bookcase.
    let height: CGFloat

    init(height: CGFloat) {
        self.height = max(height, Self.topEdge + Self.surface + Self.lip + Self.drop)
    }

    /// How far down the books stand: partway back on the board's top.
    var base: CGFloat { height - Self.drop - Self.lip - Self.surface * 0.45 }

    /// Points per decimeter of book: the most that lets the tallest book (`BookShape.longest`)
    /// clear the shelf above by 20 points, up to 170, so a tall phone still shows about ten
    /// books across. A short shelf, such as a small phone's with the largest text, gets smaller
    /// spines rather than clipped ones.
    var scale: CGFloat {
        min(170, max(1, (base - Self.topEdge - 20) / CGFloat(BookShape.longest)))
    }
}

/// The bookcase's wood around `length` points of books that start `start` points into the
/// scroll content: a side panel at each end, and the bays between them.
///
/// The bays between the side panels each span one square wood tile as tall as the bookcase, so
/// the seamless texture repeats without seams. They sit in a lazy stack, so a long shelf builds
/// only the bays on screen. Every bay is a whole tile, so the stack places the bays it has not
/// built exactly, and the right side panel meets the last bay; the last bay is cut to the
/// shelf's length.
private struct BookcaseWood: View {
    let bookcase: Bookcase
    let start: CGFloat
    let length: CGFloat

    var body: some View {
        let tile = bookcase.height
        let inside = length + 2 * Bookcase.gap
        let count = max(1, Int((inside / tile).rounded(.up)))
        HStack(spacing: 0) {
            Color.clear.frame(width: max(0, start - Bookcase.gap - Bookcase.side))
            // Above the bays, which its shadow falls on.
            BookcaseSide(bookcase: bookcase).zIndex(1)
            LazyHStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in BookcaseBay(bookcase: bookcase) }
            }
            .frame(width: inside, alignment: .leading)
            .clipped()
            BookcaseSide(bookcase: bookcase).scaleEffect(x: -1).zIndex(1)
        }
        .accessibilityHidden(true)
    }
}

/// A stretch of the bookcase behind and under the books, one wood tile wide.
private struct BookcaseBay: View {
    let bookcase: Bookcase

    var body: some View {
        let tile = bookcase.height
        VStack(spacing: 0) {
            WoodGrain(tile: tile, shade: 0.55)
                .frame(height: Bookcase.topEdge)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.black.opacity(0.45)).frame(height: 1)
                }
            // The back panel, its grain upright, so it shows the shelf moving between the
            // books' tops; in the shadow of the shelf above and of the board.
            WoodGrain(tile: tile, across: false, shade: 0.72)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.6), location: 0),
                            .init(color: .clear, location: 0.1),
                            .init(color: .clear, location: 0.8),
                            .init(color: .black.opacity(0.4), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                }
            // The board's top, darker toward the back, and light enough in front for the books'
            // contact shadows to show.
            LinearGradient(
                colors: [ShelfPalette.board.mix(with: .black, by: 0.35), ShelfPalette.board],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Bookcase.surface)
            // The board's front edge, lit along its top.
            WoodGrain(tile: tile, shade: 0.4)
                .overlay {
                    LinearGradient(
                        colors: [.white.opacity(0.06), .black.opacity(0.3)], startPoint: .top,
                        endPoint: .bottom)
                }
                .overlay(alignment: .top) {
                    Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                }
                .frame(height: Bookcase.lip)
            Bookcase.dropShadow
        }
        .frame(width: tile, height: tile)
    }
}

/// The front of the bookcase's left side panel, from the top to the board's front edge, with its
/// shadows on the back panel beside it and on the wall below; mirror it for the right.
private struct BookcaseSide: View {
    let bookcase: Bookcase

    var body: some View {
        VStack(spacing: 0) {
            WoodGrain(tile: bookcase.height, across: false, shade: 0.5)
                .overlay {
                    LinearGradient(
                        colors: [.white.opacity(0.08), .clear, .black.opacity(0.35)],
                        startPoint: .leading, endPoint: .trailing)
                }
                .frame(height: bookcase.height - Bookcase.drop)
                .background(alignment: .trailing) {
                    LinearGradient(
                        colors: [.black.opacity(0.5), .clear], startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 16)
                    .offset(x: 16)
                    .padding(.vertical, Bookcase.topEdge)
                }
            Bookcase.dropShadow
        }
        .frame(width: Bookcase.side)
    }
}

/// The table's wood texture (`TableWood`), darkened to walnut: a seamless square `tile` points
/// wide, its grain running across unless `across` is false, under dark brown at `shade` opacity.
///
/// It fills the frame it is given from the tile's top-leading corner, so the frame must fit in
/// one tile.
private struct WoodGrain: View {
    let tile: CGFloat
    var across = true
    let shade: Double

    var body: some View {
        Image("TableWood")
            .resizable()
            .frame(width: tile, height: tile)
            .rotationEffect(.degrees(across ? 90 : 0))
            .overlay { Color(red: 0.17, green: 0.085, blue: 0.035).opacity(shade) }
            // The zero minimums let the frame shrink below the tile, which it then clips.
            .frame(
                minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                alignment: .topLeading
            )
            .clipped()
    }
}

/// The soft shadow where a book of `width` points stands on the board.
private struct ContactShadow: View {
    let width: CGFloat

    var body: some View {
        EllipticalGradient(colors: [.black.opacity(0.6), .clear])
            .frame(width: width + 6, height: 10)
            .offset(y: 4)
            .allowsHitTesting(false)
    }
}

/// Hides the shelf's lamp while `pullOut` has a book out, when the book's flight draws the lamp
/// over the book instead, and reports the lamp's frame for that.
private struct LampHandOff: ViewModifier {
    let pullOut: ShelfPullOut

    func body(content: Content) -> some View {
        content
            .opacity(pullOut.isOut ? 0 : 1)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                pullOut.lampFrame = $0
            }
    }
}

/// A lamp above the middle of the shelf, fixed to the screen while the books scroll under it:
/// a warm pool of light at the top that falls off toward the screen's sides.
///
/// It fades out at its top and bottom, so it meets the plain wall above and below the carousel
/// without a step.
struct ShelfLamp: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [ShelfPalette.lamp.opacity(0.14), .clear], center: .top, startRadius: 0,
                endRadius: 480)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.7),
                    .init(color: .black.opacity(0.5), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
