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
///
/// Both styles draw `Book3DView` as the flight draws it at rest, so a flight starts and lands
/// exactly on the stacked book.
enum StackStyle: String {
    /// Books seen straight on and unshaded, so each shows its spine as a flat one, and the
    /// page edges at one end when it is strongly turned.
    case flat = "2d"
    /// Books seen from slightly above and in front, and shaded, so each book's top board shows
    /// above its spine.
    case threeD = "3d"

    /// How far a 3D book turns about its length to show its top board, in radians.
    static let lookDown = 0.3
    /// The shading of a 3D book's faces. `Book3DView` lights an upright book from its upper
    /// left, which lies at the lower left of a book on its back, so full shading would darken
    /// the top boards most.
    static let lighting = 0.6

    /// How `book` lies in the stack, which is also where its flight to the details starts.
    ///
    /// Nothing fades: the book shows every face throughout. The book slides out inside the
    /// stack, under the books above it, until it is clear of them (`Rest.slidesInStack`), and
    /// the flight then draws it in front of the stack. The books around it make a little room
    /// while it is out (`StackRoom`).
    func rest(of book: CloudBook) -> PullOutPath.Rest {
        let twist = StackArrangement.twist(of: book)
        switch self {
        case .flat: return PullOutPath.Rest(pitch: twist, slidesInStack: true)
        case .threeD:
            return PullOutPath.Rest(
                yaw: -Self.lookDown, pitch: twist, lighting: Self.lighting, slidesInStack: true)
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
    /// How long the carousel takes to glide a book on screen to the center, in seconds.
    static let glide = 0.5

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
        // A lazy stack builds only the pages within its scroll view's bounds. A spine overhangs
        // its page by up to half its thickness, and a 3D book's top board rises above its spine,
        // so the mask hides that much at each end. To keep that clear band small at the bottom,
        // the scroll view reaches `bleed` past the stack's area, into the caption, and builds
        // the pages there before their boards rise into view. VoiceOver gets the stack's area
        // alone, so it treats only books on screen as visible.
        let rise = style == .threeD ? StackedBook.rise(of: books, in: arrangement) : 0
        let bleed = voiceOver ? 0 : rise.rounded(.up)
        let stops = StackArrangement.maskStops(
            height: size.height + bleed, top: track.maxThickness / 2,
            bottom: track.maxThickness / 2 + rise)
        // The pulled book's index and the flight's progress, which move the books around it.
        let pulled = pullOut.book.flatMap { book in track.ids.firstIndex(of: book.id) }
        let progress = pulled == nil ? 0 : pullOut.progress
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                Color.clear.frame(height: track.leadingSpace(viewport: size.height))
                LazyVStack(spacing: 0) {
                    ForEach(track.pages.indices, id: \.self) { page in
                        ZStack(alignment: .topLeading) {
                            ForEach(track.pages[page]) { slot in
                                spineButton(slot.book) {
                                    stackedBook(slot.book, spine: arrangement.spine(of: slot.book))
                                }
                                .padding(.leading, arrangement.leading(of: slot.book))
                                .padding(.top, slot.inset)
                                .modifier(
                                    StackRoom(
                                        progress: progress,
                                        distance: pulled.map { slot.index - $0 } ?? 0)
                                )
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
                Color.clear.frame(height: track.trailingSpace(viewport: size.height) + bleed)
            }
        }
        .modifier(
            CenterTracking(
                track: track, axis: .vertical, viewport: size.height, centeredID: $centeredID)
        )
        // Fades the stack as one image, so a fading 3D book never shows the book under it through
        // its spine. The mask also hides the top boards that would rise under the bar.
        .mask { LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom) }
        // Keeps a tap on the caption from opening a book hidden under it. A shape alone lets taps
        // through to the scroll view; a gesture takes them.
        .overlay(alignment: .bottom) {
            Color.clear.frame(height: bleed).contentShape(.rect).onTapGesture {}
                .accessibilityHidden(true)
        }
        .padding(.bottom, -bleed)
    }

    /// A stacked book, lying as `style` says, with its spine filling `spine`'s length and
    /// thickness.
    private func stackedBook(_ book: CloudBook, spine: CGSize) -> some View {
        StackedBook(
            book: book, look: model.look(for: book), spine: spine, rest: style.rest(of: book),
            pullOut: pullOut)
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

/// A book in **Stack**: `Book3DView` lying on its back, head on the left, seen straight on or
/// from slightly above and in front, as `rest` turns it.
///
/// The book is scaled as a pulled-out book starts (`PullOutPath`), so its spine nearly fills
/// `spine`, the slot's length and thickness. It sits on the slot's bottom edge, and in 3D its top
/// board rises above the slot, under the book above. The book loads its cover, whose shape sets
/// the board's width, as the details do.
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
        let rest = StackStyle.threeD.rest(of: longest)
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
        .rotationEffect(.radians(-.pi / 2))
        .frame(width: drawn.width, height: drawn.height)
        // Read from the tap on, not from `isOut`: this view must already depend on `progress`
        // when `ShelfPullOut.fly` animates it, or the animation never reaches the slide and the
        // book holds still until the flight takes over.
        .modifier(
            StackSlide(
                progress: pullOut.book?.id == book.id ? pullOut.progress : 0,
                spine: spine, extent: drawn.height, rest: rest)
        )
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

/// A stacked book's slide out of its place while it is pulled (`PullOutPath.slide`), drawn in
/// the stack, so the books above it cover what still lies under them and it covers the books
/// below. Once the book is clear of the stack, the flight draws it and the stack hides it.
///
/// SwiftUI animates `progress`, so the slide follows the flight frame by frame.
private struct StackSlide: ViewModifier, Animatable {
    var progress: Double
    /// The book's place: the spine's length by its thickness.
    let spine: CGSize
    /// How far the drawn book reaches down the screen as it lay.
    let extent: CGFloat
    let rest: PullOutPath.Rest

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let slide = PullOutPath.slide(
            at: progress, length: spine.width, thickness: spine.height, extent: extent, rest: rest)
        content
            .scaleEffect(slide.scale)
            .offset(slide.offset)
            .opacity(progress < PullOutPath.pullEnd ? 1 : 0)
            .transaction { $0.animation = nil }
    }
}

/// Makes room for a pulled book: moves a stacked book up while it lies above the pulled book and
/// down while it lies below, by a few points, as the flight's `progress` runs.
///
/// The nudge spreads outward from the pulled book like a Newton's cradle: each book starts
/// `stagger` seconds of the opening after the book nearer the pulled one, and settles with a
/// little overshoot (`spring`). The nearest books move `near` points and farther books a little
/// more, up to `far`. SwiftUI animates `progress`, so the motion follows the flight frame by
/// frame: the return plays it backward, the neighbors close in as the book slides back into its
/// place, nothing is left to snap when the flight ends, and **Back** during the opening turns
/// them around with the book. With Reduce Motion on, no book is pulled, so nothing moves.
struct StackRoom: GeometryEffect {
    static let near: CGFloat = 3.5
    static let far: CGFloat = 5
    static let stagger = 0.03
    static let spring = Spring(duration: 0.5, bounce: 0.45)

    var progress: Double
    /// The book's index less the pulled book's: negative above it, and 0 for the pulled book
    /// or while no book is pulled.
    let distance: Int

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: 0, y: Self.offset(distance: distance, progress: progress)))
    }

    /// How far a book `distance` places from the pulled book has moved at `progress`, down the
    /// screen for a positive distance and up for a negative one.
    static func offset(distance: Int, progress: Double) -> CGFloat {
        guard distance != 0 else { return 0 }
        let places = CGFloat(abs(distance))
        let amplitude = far - (far - near) / places
        let time =
            progress * ShelfPullOut.openingDuration - Double(places - 1) * stagger
        guard time > 0 else { return 0 }
        let reach = amplitude * CGFloat(spring.value(target: 1.0, time: time))
        return distance < 0 ? -reach : reach
    }
}

/// Hides a spine while `pullOut` has its book out, leaving a gap in the shadow of the books beside
/// it, and reports the gap's frame and how the book lay in it. A book that slides out inside the
/// stack hides itself (`StackSlide`).
///
/// The gap reports its frame as soon as the book is pulled, while the spine still shows, and the
/// spine hides once the flying book is drawn over it, so no frame shows neither. The frame is the
/// layout frame, before the book's turn, which the flight applies itself; `lift` moves it to the
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
            .opacity(isPulled && pullOut.isOut && !rest.slidesInStack ? 0 : 1)
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
                withAnimation(glides ? .smooth(duration: SpineCarousel.glide) : nil) {
                    scrollToCenteredBook()
                }
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
/// page by half its thickness. The stack's mask hides the ends of its scroll view where a book on
/// a page that is not built could show (`StackArrangement.maskStops(height:top:bottom:)`), so
/// every visible book's page intersects the scroll view and is built. Shelved spines stay opaque,
/// so the shelf's scroll view reaches past the screen's sides by half of `maxThickness` instead.
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
/// turns about the vertical axis, so its spine faces a little left or right.
///
/// Spines have the shelf's sizes (`CloudBook.shelfSpineSize(scale:)`) lying on their side, at the
/// largest scale that fits the longest possible book across the screen. A book's offsets come from
/// its ID, so it lies the same way on every launch and in every order. Each offset is the square
/// of an even spread, keeping its sign, so most books lie nearly straight and few reach the
/// limits. Each book lies flat on the one below it, level and touching along their length, as
/// gravity would leave a real stack; books never tilt in the screen's plane.
struct StackArrangement {
    /// How far a book can lie off the middle, as a share of the width.
    static let maximumShift: CGFloat = 0.03
    /// How far a book can turn about the screen's vertical axis, so its spine faces a little
    /// left or right, in radians. A 3D book turned past about 0.16 shows the page edges at one end.
    static let maximumTwist = 0.3
    /// The `rotation3DEffect` perspective that matches `BookProjection`'s camera, which sits 3.2
    /// book lengths away, for a flat spine as long as its book, which the share images' Year
    /// Stack turns.
    static let perspective = 1 / 3.2
    /// Space between the screen's edges and the longest book lying in the middle.
    static let margin: CGFloat = 16
    /// How far the stack fades in from each end of the masked part of its scroll view.
    static let fade: CGFloat = 96

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

    /// The distance from the scroll view's leading edge to the spine's, before its turn.
    func leading(of book: CloudBook) -> CGFloat {
        (width - spine(of: book).width) / 2 + shift(of: book)
    }

    func shift(of book: CloudBook) -> CGFloat {
        width * Self.maximumShift * Self.spread(book, salt: 70)
    }

    static func twist(of book: CloudBook) -> Double { maximumTwist * spread(book, salt: 72) }

    /// The books from the top of the stack to the bottom, each lying flat on the one below it.
    func track(of books: [CloudBook]) -> SpineTrack {
        SpineTrack(books: books) {
            spine(of: $0).height
        } gap: { _, _ in
            0
        }
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
