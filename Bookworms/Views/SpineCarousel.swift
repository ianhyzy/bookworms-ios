import SwiftUI

/// The shelf's two presentations of the library.
enum ShelfMode: String, CaseIterable, Identifiable {
    /// Spines lying flat, stacked top to bottom on a wheel that turns about the x axis.
    case stack
    /// Spines standing side by side in a wooden bookcase that scrolls horizontally.
    case shelf

    var id: Self { self }
    var title: String { self == .stack ? "Stack" : "Shelf" }
}

/// The library's spines, as a snapping 3D wheel (Stack) or a bookcase (Shelf), reporting the
/// book at the viewport's center through `centeredID`.
///
/// In Stack, each spine's 3D pose is a `visualEffect` of its distance from the viewport center,
/// so scrolling changes only render effects and never re-evaluates a body. (`scrollTransition`
/// cannot drive a wheel: its phase reaches ±1 about one spine's length from its threshold.) A
/// tap on the centered spine opens it, and a tap on another spine brings it to the center.
/// Shelf scrolls freely, with the bookcase's wood as part of the content, and a tap on any
/// spine opens it. The body does not read `centeredID`; only the button actions do, when
/// tapped. VoiceOver activation always opens the book.
///
/// While `pullOut` has a book out, that book's spine hides, leaving a shadowed gap, and reports
/// the gap's frame, where the book flies from and back to.
struct SpineCarousel: View {
    let books: [CloudBook]
    let mode: ShelfMode
    @Binding var centeredID: Int?
    /// The zoom transition's source namespace; each spine is a source keyed by its book ID.
    let namespace: Namespace.ID
    let pullOut: ShelfPullOut
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// Space between the screen edges and a stacked spine's ends.
    private static let sideMargin: CGFloat = 20
    private static let stackSpacing: CGFloat = 6
    /// Shelved books nearly touch, so their spines read as separate books.
    private static let shelfSpacing: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            switch mode {
            case .stack: stack(in: proxy.size)
            case .shelf: shelf(in: proxy.size)
            }
        }
        .background {
            // A pool of warm light behind the centered spine, larger than the carousel so its
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
        let length = size.width - 2 * Self.sideMargin
        let center = size.height / 2
        let track = SpineTrack(books: books, spacing: Self.stackSpacing)
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                Color.clear.frame(height: track.leadingSpace(viewport: size.height))
                LazyVStack(spacing: 0) {
                    ForEach(track.pages.indices, id: \.self) { page in
                        ZStack(alignment: .top) {
                            ForEach(track.pages[page]) { slot in
                                let thickness = slot.book.slabThickness
                                spineButton(slot.book) {
                                    SpineView(book: slot.book, look: model.look(for: slot.book))
                                        .frame(width: length, height: thickness)
                                }
                                .visualEffect { content, proxy in
                                    let pose = WheelPose(
                                        distance: proxy.frame(in: .scrollView).midY - center,
                                        length: thickness, viewport: size.height)
                                    return
                                        content
                                        .rotation3DEffect(pose.angle, axis: (x: 1, y: 0, z: 0))
                                        .scaleEffect(pose.scale)
                                        .offset(y: pose.offset)
                                        .brightness(pose.brightness)
                                        .opacity(pose.opacity)
                                }
                                .padding(.top, slot.inset)
                            }
                        }
                        .frame(height: SpineTrack.pageLength, alignment: .top)
                    }
                }
                Color.clear.frame(height: track.trailingSpace(viewport: size.height))
            }
        }
        .scrollTargetBehavior(SpineSnapping(track: track))
        .modifier(
            CenterTracking(
                track: track, axis: .vertical, viewport: size.height, centeredID: $centeredID))
    }

    private func shelf(in size: CGSize) -> some View {
        let bookcase = Bookcase(height: size.height)
        let scale = bookcase.scale
        let track = SpineTrack(books: books, spacing: Self.shelfSpacing) {
            $0.shelfSpineSize(scale: scale).width
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
                                            height: spine.height, thickness: spine.width)
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
        .overlay { ShelfLamp() }
    }

    private func spineButton(_ book: CloudBook, @ViewBuilder label: () -> some View)
        -> some View
    {
        Button {
            if voiceOver || mode == .shelf || book.id == (centeredID ?? books.first?.id) {
                open(book)
            } else {
                centeredID = book.id
            }
        } label: {
            label()
                .matchedTransitionSource(id: book.id, in: namespace)
                .modifier(PulledSpine(id: book.id, pullOut: pullOut, upright: mode == .shelf))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(book.title), by \(book.author)")
        .accessibilityHint("Opens the book's details.")
    }
}

/// Hides a spine while `pullOut` has its book out, leaving a gap in the shadow of the books beside
/// it, and reports the gap's frame.
///
/// The gap reports its frame as soon as the book is pulled, while the spine still shows, and the
/// spine hides once the flying book is drawn over it, so no frame shows neither.
private struct PulledSpine: ViewModifier {
    let id: Int
    let pullOut: ShelfPullOut
    /// Whether the spine stands upright, so its neighbors are on its left and right.
    let upright: Bool

    func body(content: Content) -> some View {
        let isPulled = pullOut.book?.id == id
        content
            .opacity(isPulled && pullOut.isOut ? 0 : 1)
            .background {
                if isPulled {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.6), location: 0),
                            .init(color: .black.opacity(0.3), location: 0.3),
                            .init(color: .black.opacity(0.3), location: 0.7),
                            .init(color: .black.opacity(0.6), location: 1),
                        ], startPoint: upright ? .leading : .top,
                        endPoint: upright ? .trailing : .bottom
                    )
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        pullOut.home = $0
                    }
                }
            }
    }
}

/// Keeps `centeredID` on the spine at the center, and scrolls to `centeredID` when something
/// other than scrolling changes it.
///
/// Tracking and scrolling use `SpineTrack` offsets, as `SpineSnapping` does, which match the
/// layout exactly. Offsets count from the end of the scroll view's content inset, as
/// `ScrollPosition` and `ScrollTarget` do; the scroll view takes a top inset where it meets the
/// navigation bar.
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
                // Glides to a spine on screen, such as a tapped neighbor, and jumps to one off
                // screen, such as the first book after a new sort.
                let distance = abs(track.offset(of: centeredID) - track.offset(of: scrolledID))
                let glides = !reduceMotion && distance < viewport / 2
                withAnimation(glides ? .smooth : nil) { scrollToCenteredBook() }
            }
            // The same offset centers a different book after the order changes, and a new order
            // or a new shelf scale moves the centered book's offset. A reorder can leave the
            // offsets equal, so both are watched.
            .onChange(of: track.ids) { scrollToCenteredBook() }
            .onChange(of: track.offsets) { scrollToCenteredBook() }
            // A new carousel, such as after a mode switch, opens on the centered book. One that
            // reappears, such as after Back from details, keeps its offset, because a free
            // scroll rarely rests exactly on a book's.
            .onAppear {
                if centeredID != scrolledID { scrollToCenteredBook() }
            }
            .scrollIndicators(.hidden)
            // The stack's spines fade out before its ends, and the shelf's top board meets the
            // bar, so the bar's edge effect would only draw a seam across the walnut.
            .scrollEdgeEffectHidden()
    }

    private func scrollToCenteredBook() {
        let offset = track.offset(of: centeredID)
        if axis == .vertical { position.scrollTo(y: offset) } else { position.scrollTo(x: offset) }
    }
}

/// Ends every vertical scroll, including a fling's momentum, with the nearest spine at the
/// center.
private struct SpineSnapping: ScrollTargetBehavior {
    let track: SpineTrack

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.y = track.offset(nearest: target.rect.minY)
    }
}

/// The carousel's spines laid out along its scroll axis, from their thicknesses.
///
/// A lazy stack estimates the extent of rows it has not built, so with one spine per row, a
/// fling or a jump to a distant book stops with a different spine at the center than the one
/// the scroll offset names. The carousel's lazy stack therefore holds pages of equal length,
/// with no spacing, so it places even pages it has not built exactly and `offsets` match the
/// layout. Each page holds the spines whose centers fall within it; a spine may overhang its
/// page by half its thickness. A stacked spine fades out completely once its center leaves the
/// viewport, so every visible spine's page intersects the viewport and is built. Shelved spines
/// stay opaque, so the shelf's scroll view reaches past the screen's sides by half of
/// `maxThickness` instead.
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

    /// Lays out `books` with `thickness` along the scroll axis, `spacing` apart.
    init(
        books: [CloudBook], spacing: CGFloat,
        thickness: (CloudBook) -> CGFloat = \.slabThickness
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
            offsets.append(start + (thickness - firstThickness) / 2)
            let page = Int((start + thickness / 2) / Self.pageLength)
            while pages.count <= page { pages.append([]) }
            let inset = start - CGFloat(page) * Self.pageLength
            pages[page].append(Slot(book: book, index: index, inset: inset))
            start += thickness + spacing
        }
        self.offsets = offsets
        self.pages = pages
        length = max(0, start - spacing)
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

    func offset(nearest offset: CGFloat) -> CGFloat {
        index(nearest: offset).map { offsets[$0] } ?? offset
    }

    /// The offset that centers the book with `id`, or the first book when `id` is absent.
    func offset(of id: Int?) -> CGFloat {
        id.flatMap { ids.firstIndex(of: $0) }.map { offsets[$0] } ?? 0
    }
}

/// A stacked spine's pose on a drum: the flat scroll strip wrapped around a cylinder whose axis
/// runs across the screen.
///
/// `distance` is the spine center's offset from the viewport center along the scroll axis.
/// Wrapping keeps arc length, so neighbors stay evenly spaced near the center and crowd
/// together as they turn away, the way a wheel looks.
struct WheelPose {
    let angle: Angle
    let scale: Double
    /// The shift along the scroll axis from the flat position to the drum position.
    let offset: Double
    let brightness: Double
    let opacity: Double

    /// The turn where a spine leaves the viewport.
    static let maximumAngle = 0.95

    init(distance: Double, length: Double, viewport: Double) {
        // The distance at which the spine has fully left the viewport.
        let reach = (viewport + length) / 2
        let phase = max(-1, min(1, distance / reach))
        let radius = reach / Self.maximumAngle
        let theta = phase * Self.maximumAngle
        // Depth behind the front of the drum, seen by a camera three radii in front of it.
        let depth = radius * (1 - cos(theta))
        scale = 1 / (1 + depth / (3 * radius))
        offset = radius * sin(theta) * scale - phase * reach
        // A positive turn about x tips the top edge away, as on the upper half of the drum.
        angle = .radians(-theta)
        brightness = -0.22 * abs(phase)
        // Gone once the spine's center leaves the viewport, which `SpineTrack` relies on.
        opacity = 1 - pow(min(1, abs(distance) / (viewport / 2)), 1.6)
    }
}

extension CloudBook {
    /// The carousel thickness of the book's spine: `thicknessRatio`, which spans 0.05...0.2,
    /// mapped linearly onto 44...96 points, so even a short book has room for a legible title.
    var slabThickness: CGFloat { 44 + (thicknessRatio - 0.05) / 0.15 * 52 }

    /// The book's upright spine on the shelf, in points: `width` is its thickness and `height`
    /// its height, from its `BookShape` at `scale` points per decimeter.
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

/// A lamp above the middle of the shelf, fixed to the screen while the books scroll under it:
/// a warm pool of light at the top that falls off toward the screen's sides.
///
/// It fades out at its top and bottom, so it meets the plain wall above and below the carousel
/// without a step.
private struct ShelfLamp: View {
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
