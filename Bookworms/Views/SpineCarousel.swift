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
    var symbol: String { self == .stack ? "square.stack.3d.up" : "books.vertical" }
}

/// How **Stack** draws its books. The raw values are what `BookwormsStackStyle` saves.
///
/// Both styles draw `Book3DView` as the flight draws it at rest, so a flight starts and lands
/// exactly on the stacked book.
enum StackStyle: String {
    /// Books seen straight on, unshaded, and barely turned (`flatTwist`), so each shows only its
    /// spine, as a flat one.
    case flat = "2d"
    /// Books seen in perspective by one camera level with the stack's middle (`StackCamera`),
    /// and shaded, so books below the eye show their top boards and books above it their
    /// undersides, where the books next to them leave those in view.
    case threeD = "3d"

    /// How much of the light's shading a 3D book's faces show (`Book3DView.lighting`): less
    /// than the details' book shows, so the stack's spines stay bright. The light falls from the
    /// screen's upper left (`Book3DView.roll`), so top boards show lighter than undersides.
    static let lighting = 0.6
    /// How far a 2D book turns at most, in radians: about 3 degrees, so the books barely face
    /// left or right and never show their page edges.
    static let flatTwist = 0.05

    /// How far a book of this style turns at most, in radians.
    var maximumTwist: Double { self == .flat ? Self.flatTwist : StackArrangement.maximumTwist }

    /// How `book` lies in the stack, which is also where its flight to the details starts.
    ///
    /// A 3D book's camera distance depends on the stack's size and the book's cover, so
    /// `StackedBook` sets it.
    ///
    /// Nothing fades: the book shows every face throughout. The book slides out inside the
    /// stack (`Rest.slidesInStack`), over the books around it and the stacks beside it, as a book
    /// that comes out in front of them. The flight then draws it in front of the stack. The books
    /// around it make a little room while it is out (`StackRoom`).
    func rest(of book: CloudBook) -> PullOutPath.Rest {
        PullOutPath.Rest(
            pitch: StackArrangement.twist(of: book, maximum: maximumTwist),
            lighting: self == .threeD ? Self.lighting : 0, slidesInStack: true)
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
/// With a pointer, a book eases a little way out of its place while the pointer rests on it, and
/// its tooltip names it (`SpineButton`). On the Mac, a book's context menu offers what its
/// details do (`BookMenu`), and the carousel takes keyboard focus (`KeyboardBrowsing`).
///
/// While `pullOut` has a book out, that book hides, leaving a shadowed gap, and reports the gap's
/// frame, where the book flies from and back to.
struct SpineCarousel: View {
    let books: [CloudBook]
    let mode: ShelfMode
    @Binding var centeredID: Int?
    /// The iPhone's zoom transition's source namespace; each spine there is a source keyed by
    /// its book ID. The Mac pushes details without a zoom.
    let namespace: Namespace.ID
    let pullOut: ShelfPullOut
    /// How far the status bar reaches down over the carousel's top, which Shelf keeps its books
    /// below. Stack runs under it.
    let statusBar: CGFloat
    /// Opens **Change cover** for a book, which its context menu offers on the Mac.
    let changeCover: (CloudBook) -> Void
    /// Opens a book's details.
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("BookwormsStackStyle") private var style = StackStyle.flat
    @State private var scrolling = CarouselScrolling()
    #if os(macOS)
        /// Whether the carousel has keyboard focus, which warms the lamp's light rather than
        /// drawing a focus ring.
        @FocusState private var isFocused: Bool
    #else
        private let isFocused = false
    #endif

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
        .onScrollPhaseChange { _, phase in scrolling.isScrolling = phase.isScrolling }
        #if os(macOS)
            .modifier(SettledBook(books: books, centeredID: $centeredID, pullOut: pullOut))
        #endif
        .overlay(alignment: .top) {
            // On the iPhone, Stack runs up under the status bar. A wash of the wall's color, dense
            // enough to hide spine lettering behind the time and battery, covers the bar and
            // fades out over 8 points below it, so the books below stay sharp. The system's soft
            // edge effect reaches about a spine farther and blurs that book too.
            if mode == .stack, statusBar > 0 {
                let height = statusBar + 8
                LinearGradient(
                    stops: [
                        .init(color: Color(.shelfWallTop).opacity(0.85), location: 0),
                        .init(
                            color: Color(.shelfWallTop).opacity(0.85),
                            location: statusBar * 0.75 / height),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom
                )
                .frame(height: height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// Stack, in as many side-by-side stacks as the width holds at full scale, such as in a wide
    /// Mac window. Each column holds the next run of books in order, the runs differing by at
    /// most one book. The stacks rest on one line and scroll together, in both styles, as stacks
    /// of books on a shelf would, and the caption names the centered book of one stack
    /// (`CenterTracking`).
    ///
    /// On the Mac, the stacks keep room at their outer ends (`StackArrangement.layout`), so a
    /// book pulled from the stack beside the sidebar or the window's edge stays in view. With
    /// Reduce Motion, a tap opens the details without pulling a book, so the stacks keep none.
    private func stack(in size: CGSize) -> some View {
        let (columns, arrangement, room) = StackArrangement.layout(
            in: size, books: books.count, style: style,
            keepsRoom: StackArrangement.keepsPullRoom && !reduceMotion)
        // Where each run starts; the first `books.count % columns` runs take one more book.
        let bound = { ($0 * books.count + columns - 1) / columns }
        let runs = (0..<columns).map { Array(books[bound($0)..<bound($0 + 1)]) }
        let track = arrangement.track(of: runs)
        // The middle of each stack across the carousel.
        let centers = runs.indices.map { room + (CGFloat($0) + 0.5) * arrangement.width }
        return stackScroll(
            track, arrangement: arrangement, inset: room,
            camera: style == .threeD ? StackCamera.distance(viewing: size) : nil, in: size,
            board: StackBoard(
                arrangement: arrangement, inset: room, bottoms: runs.compactMap(\.last))
        )
        // A pool of warm light behind the stack whose book the caption names, larger than the
        // carousel so its falloff never meets an edge. The shelf's lamp lights the bookcase
        // instead.
        .background {
            StackLamp(
                track: track, centers: centers, height: size.height, warm: isFocused,
                centeredID: $centeredID)
        }
    }

    /// A scroll view `size` big of `track`'s stacks, side by side, each `arrangement.width` wide,
    /// starting `inset` points in, seen by a camera `camera` points in front of the spines, or
    /// straight on.
    private func stackScroll(
        _ track: SpineTrack, arrangement: StackArrangement, inset: CGFloat, camera: CGFloat?,
        in size: CGSize, board: StackBoard
    ) -> some View {
        // A lazy stack builds only the pages within its scroll view's bounds. A spine overhangs
        // its page by up to half its thickness, and toward the ends of a 3D stack, a book's top
        // board or underside reaches up to `rise` past its spine, toward the middle, so the mask
        // hides that much at each end. The scroll view reaches `bleed` past the stack's area,
        // into the caption, so the clear band at the bottom lies over the caption and the stack
        // fades out right down to it, and builds the pages there before their boards reach into
        // view. On the iPhone, where the stack runs to the screen's top edge, the scroll view
        // also reaches `top` past that edge, so the clear band at the top lies off screen.
        // VoiceOver gets the stack's area alone, so it treats only books on screen as visible;
        // there, the top has no clear band, so the books still run to the edge, where a book
        // from a page above the screen can show late.
        let longest = books.lazy.map { arrangement.spine(of: $0).width }.max() ?? 0
        let rise =
            camera == nil
            ? 0 : StackCamera.reach(length: longest, thickness: track.maxThickness, in: size)
        let bleed = voiceOver ? 0 : (track.maxThickness / 2 + rise).rounded(.up)
        #if os(iOS)
            let top = voiceOver ? 0 : (track.maxThickness / 2 + rise).rounded(.up)
            let band = top
        #else
            let top: CGFloat = 0
            let band = track.maxThickness / 2 + rise
        #endif
        // The middle of the stack's area, which lies `top` points below the scroll view's top.
        let eye = CGPoint(x: size.width / 2, y: top + size.height / 2)
        let stops = StackArrangement.maskStops(
            height: top + size.height + bleed, top: band, bottom: track.maxThickness / 2 + rise)
        // The pulled book's index, which the books of its stack make room for.
        let pulled = pullOut.roomID.flatMap { track.ids.firstIndex(of: $0) }
        // The book that is out, which the stack draws over the books around it.
        let out = pullOut.book?.id
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                Color.clear.frame(height: top + track.leadingSpace(viewport: size.height))
                // VoiceOver reads the books in the layout's order, page by page across the
                // stacks, because the stack builds a page of every stack at a time: an order
                // that finished one stack first would put a page's newly built books in an
                // earlier stack behind the book VoiceOver is on.
                LazyVStack(spacing: 0) {
                    ForEach(track.pages.indices, id: \.self) { page in
                        ZStack(alignment: .topLeading) {
                            ForEach(track.pages[page]) { slot in
                                let spine = arrangement.spine(of: slot.book)
                                spineButton(slot.book) { nudged in
                                    stackedBook(
                                        slot.book, spine: spine, camera: camera, eye: eye,
                                        nudged: nudged)
                                }
                                .padding(
                                    .leading,
                                    inset + CGFloat(slot.column) * arrangement.width
                                        + arrangement.leading(of: slot.book)
                                )
                                .padding(.top, slot.inset)
                                .modifier(
                                    StackRoom(
                                        room: pullOut.room, closing: pullOut.closing,
                                        distance: pulled.map {
                                            track.columns[slot.column].contains($0)
                                                ? slot.index - $0 : 0
                                        } ?? 0)
                                )
                                .modifier(
                                    EyeLevelOrder(
                                        index: slot.index,
                                        books: slot.inset...slot.inset + spine.height,
                                        eye: camera.map { _ in eye.y }, isOut: slot.id == out))
                            }
                        }
                        .frame(
                            width: size.width, height: SpineTrack.pageLength, alignment: .topLeading
                        )
                        .modifier(
                            EyeLevelOrder(
                                index: page, books: extent(of: track.pages[page], in: arrangement),
                                eye: camera.map { _ in eye.y },
                                isOut: track.pages[page].contains { $0.id == out }))
                    }
                }
                // Behind the books, so a book that slides out over it draws in front.
                .background(alignment: .topLeading) { board.offset(y: track.length) }
                Color.clear.frame(height: track.trailingSpace(viewport: size.height) + bleed)
            }
        }
        .modifier(
            CenterTracking(
                track: track, axis: .vertical, viewport: size.height, centeredID: $centeredID)
        )
        #if os(macOS)
            .modifier(
                KeyboardBrowsing(
                    books: books, track: track, axis: .vertical, viewport: size.height,
                    centeredID: $centeredID, pullOut: pullOut, focus: $isFocused, open: open))
        #endif
        // Fades the stack as one image, so a fading 3D book never shows the book under it through
        // its spine.
        .mask { LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom) }
        // Keeps a tap on the caption from opening a book hidden under it. A shape alone lets taps
        // through to the scroll view; a gesture takes them.
        .overlay(alignment: .bottom) {
            Color.clear.frame(height: bleed).contentShape(.rect).onTapGesture {}
                .accessibilityHidden(true)
        }
        .padding(.top, -top)
        .padding(.bottom, -bleed)
    }

    /// The span, down a page from its top, that the page's books cover.
    private func extent(of page: [SpineTrack.Slot], in arrangement: StackArrangement)
        -> ClosedRange<CGFloat>
    {
        let tops = page.map(\.inset)
        let bottoms = page.map { $0.inset + arrangement.spine(of: $0.book).height }
        return (tops.min() ?? 0)...max(tops.min() ?? 0, bottoms.max() ?? 0)
    }

    /// A stacked book, lying as `style` says, with its spine filling `spine`'s length and
    /// thickness, seen by a camera `camera` points in front of the stack (`StackCamera`), or
    /// straight on.
    private func stackedBook(
        _ book: CloudBook, spine: CGSize, camera: CGFloat?, eye: CGPoint, nudged: Bool
    ) -> some View {
        StackedBook(
            book: book, look: model.look(for: book), spine: spine, rest: style.rest(of: book),
            camera: camera, eye: eye, pullOut: pullOut, nudged: nudged)
    }

    private func shelf(in size: CGSize) -> some View {
        let bookcase = Bookcase(height: size.height, statusBar: statusBar)
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
                                    spineButton(slot.book) { nudged in
                                        UprightSpineView(
                                            book: slot.book, look: model.look(for: slot.book),
                                            height: spine.height, thickness: spine.width
                                        )
                                        // Comes a little way toward the reader, standing on
                                        // the board.
                                        .scaleEffect(
                                            PullOutPath.uprightScale(
                                                at: pullOut.peekID == slot.book.id
                                                    ? PullOutPath.peek
                                                    : nudged ? PullOutPath.nudge : 0),
                                            anchor: .bottom
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
        #if os(macOS)
            .modifier(
                KeyboardBrowsing(
                    books: books, track: track, axis: .horizontal, viewport: size.width,
                    centeredID: $centeredID, pullOut: pullOut, focus: $isFocused, open: open))
        #endif
        .padding(.horizontal, -bleed)
        .overlay {
            ShelfLamp(warmth: isFocused ? ShelfLamp.focusedWarmth : ShelfLamp.warmth)
                .modifier(LampHandOff(pullOut: pullOut))
        }
    }

    /// A book's button (`SpineButton`), which opens it.
    private func spineButton(
        _ book: CloudBook, @ViewBuilder label: @escaping (_ nudged: Bool) -> some View
    ) -> some View {
        SpineButton(
            book: book, namespace: namespace, scrolling: scrolling, open: open,
            changeCover: changeCover, label: label)
    }
}

/// Whether the carousel is scrolling, which a book reads as the pointer enters it. A reference
/// that nothing observes, so a change of scroll phase updates no view.
@MainActor
private final class CarouselScrolling {
    var isScrolling = false
}

/// A book's button in **Stack** or **Shelf**, which opens it.
///
/// With a pointer, the book eases a little way out of its place while the pointer rests on it,
/// straight toward the reader along the way its spine faces, with no tilt (`PullOutPath.nudge`),
/// and its tooltip names it. The hover is the button's own state, so a pointer moving over the
/// books updates only the books it enters and leaves. Books that scroll under a resting pointer
/// stay in place, so a fling doesn't ripple. Reduce Motion keeps the book still. On the Mac, its
/// context menu offers what its details do (`BookMenu`).
private struct SpineButton<Label: View>: View {
    let book: CloudBook
    let namespace: Namespace.ID
    let scrolling: CarouselScrolling
    let open: (CloudBook) -> Void
    let changeCover: (CloudBook) -> Void
    /// The book, eased out of its place while `nudged`.
    @ViewBuilder let label: (_ nudged: Bool) -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button {
            open(book)
        } label: {
            #if os(iOS)
                label(hovered).matchedTransitionSource(id: book.id, in: namespace)
            #else
                // Only the iPhone zooms pushed details out of the book. On the Mac, the source
                // clips the book to its place, which would cut off a pulled book's slide.
                label(hovered)
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(book.title), by \(book.author)")
        .accessibilityHint("Opens the book's details.")
        .help("\(book.title) — \(book.author)")
        .onHover { inside in
            guard !inside || !(reduceMotion || scrolling.isScrolling) else { return }
            withAnimation(.smooth(duration: 0.2)) { hovered = inside }
        }
        #if os(macOS)
            .contextMenu { BookMenu(book: book, open: open, changeCover: changeCover) }
        #endif
    }
}

#if os(macOS)
    /// What the Mac offers for a book, in its context menu and in the **Library** menu for the
    /// centered book: **Open**, **Open in New Window** (`BookWindow`), **Make Share Image**,
    /// **Change Cover…**, **Redesign Spine**, and **Copy Title**. In the menu bar, **Open** shows
    /// its key equivalent, and **Open in New Window** is in the **File** menu instead
    /// (`LibraryCommands`).
    struct BookMenu: View {
        let book: CloudBook
        let open: (CloudBook) -> Void
        let changeCover: (CloudBook) -> Void
        var inMenuBar = false

        @Environment(AppModel.self) private var model
        @Environment(GenerationController.self) private var generation
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("Open") { open(book) }
                .keyboardShortcut(inMenuBar ? KeyboardShortcut("o") : nil)
            if !inMenuBar {
                Button("Open in New Window") { openWindow(id: BookWindow.id, value: book.id) }
            }
            Divider()
            Button("Make Share Image") { model.share(book) }
            Button("Change Cover…") { changeCover(book) }
            // A run already redesigns what it finds; **Redesign** waits for it to end.
            Button(model.sharesSeriesDesign(book) ? "Redesign Spines" : "Redesign Spine") {
                generation.redesign(book)
            }
            .disabled(generation.status.isRunning)
            Divider()
            Button("Copy Title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(book.title, forType: .string)
            }
        }
    }

    /// Browses the carousel with the keyboard while it has focus, which a click or Tab gives it
    /// and Library gives it when it appears: the arrow keys along the shelf step to the next or
    /// previous book, and in **Stack** Left and Right move to the stack beside it; Page Up and
    /// Page Down move about a screenful; Home and End go to the first and last book; Return opens
    /// the centered book, in a window of its own with Option; Space peeks, sliding the book
    /// partway out and back; and typing a title's first letters goes to the first book whose
    /// title starts with them.
    ///
    /// Each key moves `centeredID`, which the carousel glides to (`CenterTracking`). The keys do
    /// nothing while a book's details show. The focus draws no ring; the lamp's light warms
    /// instead (`StackLamp`, `ShelfLamp`).
    private struct KeyboardBrowsing: ViewModifier {
        let books: [CloudBook]
        let track: SpineTrack
        /// The axis along which the books lie in a row: vertical for **Stack**.
        let axis: Axis
        /// The length along `axis` that shows on screen.
        let viewport: CGFloat
        @Binding var centeredID: Int?
        let pullOut: ShelfPullOut
        let focus: FocusState<Bool>.Binding
        let open: (CloudBook) -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        /// The letters typed so far for type-select, and when the last one came. A pause of a
        /// second starts a new title.
        @State private var typed = ""
        @State private var typedAt = Date.distantPast

        func body(content: Content) -> some View {
            content
                .focusable(interactions: .edit)
                .focused(focus)
                .focusEffectDisabled()
                .defaultFocus(focus, true)
                .onKeyPress(
                    keys: [
                        .upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown, .home,
                        .end, .return, .space,
                    ]
                ) { press in
                    guard pullOut.book == nil, !press.modifiers.contains(.command) else {
                        return .ignored
                    }
                    return move(press.key) ? .handled : .ignored
                }
                .onKeyPress(characters: .alphanumerics, phases: .down) { press in
                    guard pullOut.book == nil,
                        press.modifiers.isDisjoint(with: [.command, .control])
                    else { return .ignored }
                    typeSelect(press.characters)
                    return .handled
                }
        }

        /// Acts on `key`, returning whether it did anything.
        private func move(_ key: KeyEquivalent) -> Bool {
            let ids = track.ids
            guard !ids.isEmpty else { return false }
            let index = centeredID.flatMap { ids.firstIndex(of: $0) } ?? 0
            let column = track.column(of: centeredID)
            let along = axis == .vertical
            switch key {
            case .upArrow where along, .leftArrow where !along:
                return center(ids[max(0, index - 1)])
            case .downArrow where along, .rightArrow where !along:
                return center(ids[min(ids.count - 1, index + 1)])
            case .leftArrow, .rightArrow:
                // The stack beside this one, at the same height.
                let next = column + (key == .leftArrow ? -1 : 1)
                guard track.columns.indices.contains(next) else { return false }
                return center(track.id(nearest: track.offset(of: centeredID), in: next))
            case .pageUp, .pageDown:
                let page = viewport * 0.8 * (key == .pageUp ? -1 : 1)
                return center(track.id(nearest: track.offset(of: centeredID) + page, in: column))
            case .home: return center(ids[track.columns[column].lowerBound])
            case .end: return center(ids[track.columns[column].upperBound - 1])
            case .return:
                guard let book = books.first(where: { $0.id == ids[index] }) else { return false }
                open(book)
                return true
            case .space:
                if !reduceMotion { pullOut.peek(ids[index]) }
                return true
            default: return false
            }
        }

        private func center(_ id: Int?) -> Bool {
            guard let id else { return false }
            centeredID = id
            return true
        }

        private func typeSelect(_ characters: String) {
            let now = Date.now
            typed = now.timeIntervalSince(typedAt) < 1 ? typed + characters : characters
            typedAt = now
            let match = books.first {
                $0.title.range(
                    of: typed, options: [.anchored, .caseInsensitive, .diacriticInsensitive])
                    != nil
            }
            if let match { centeredID = match.id }
        }
    }

    /// Publishes the centered book for the menu bar's **Library** commands
    /// (`FocusedValues.centeredBook`) once scrolling settles, rather than as each book passes the
    /// center, and none while a book is out.
    private struct SettledBook: ViewModifier {
        let books: [CloudBook]
        @Binding var centeredID: Int?
        let pullOut: ShelfPullOut

        @State private var settledID: Int?
        @State private var isScrolling = false

        func body(content: Content) -> some View {
            content
                .onScrollPhaseChange { _, phase in
                    isScrolling = phase.isScrolling
                    if !phase.isScrolling { settledID = centeredID }
                }
                // A change that does not scroll, such as the first centered book.
                .onChange(of: centeredID, initial: true) {
                    if !isScrolling { settledID = centeredID }
                }
                .focusedSceneValue(
                    \.centeredBook,
                    pullOut.book == nil ? books.first { $0.id == settledID } : nil, in: .library)
        }
    }
#endif

/// A book in **Stack**: `Book3DView` lying on its back, head on the left, turned as `rest`
/// says, and seen straight on or, in 3D, by the stack's camera (`StackCamera`), `camera` points
/// in front of the spines.
///
/// The book is scaled as a pulled-out book starts (`PullOutPath`), so its spine nearly fills
/// `spine`, the slot's length and thickness, on the slot's bottom edge. A plain 3D box follows the
/// stack's eye as the stack scrolls, so its top board or underside shows past the slot, toward the
/// eye; the pulled book keeps the eye it had in its place. The book loads its cover, whose shape
/// sets the board's width, as the details do.
struct StackedBook: View {
    let book: CloudBook
    let look: SpineLook
    /// The slot's length and thickness.
    let spine: CGSize
    let rest: PullOutPath.Rest
    /// The stack camera's distance in front of the spines, in points, for a 3D book, and its
    /// eye in the scroll view's visible coordinates.
    let camera: CGFloat?
    let eye: CGPoint
    let pullOut: ShelfPullOut
    /// Whether the pointer rests on the book, which eases it a little way out of its place.
    var nudged = false

    @Environment(AppModel.self) private var model
    @State private var cover: UIImage?

    /// The scale that fits the book's spine to `spine`, the drawn book's size before its tilt,
    /// and its camera, for a cover `aspect` wide.
    static func fit(
        spine: CGSize, aspect: CGFloat, rest: PullOutPath.Rest
    ) -> (scale: CGFloat, drawn: CGSize, camera: BookProjection.Camera) {
        let scale =
            1
            / PullOutPath.spineMagnification(
                aspect: aspect, thicknessRatio: spine.height / spine.width,
                distance: rest.distance)
        let projection = BookProjection(
            width: spine.width * aspect, height: spine.width, thickness: spine.height,
            yaw: .pi / 2 + rest.yaw, pitch: rest.pitch,
            distance: rest.distance.map { $0 * Double(spine.width) })
        let bounds = projection.bounds
        // Lying on its back, the drawn book's width runs along the screen's height.
        return (
            scale, CGSize(width: bounds.height * scale, height: bounds.width * scale),
            projection.camera
        )
    }

    /// `rest`, with the stack camera's distance from the book's center for a cover `aspect`
    /// wide: the spines lie about half the book's width in front of its center.
    private func placed(aspect: CGFloat) -> PullOutPath.Rest {
        var placed = rest
        if let camera { placed.distance = Double(camera / spine.width + aspect / 2) }
        return placed
    }

    var body: some View {
        let rest = placed(aspect: Book3DView.aspect(of: cover))
        let (scale, drawn, bookCamera) = Self.fit(
            spine: spine, aspect: Book3DView.aspect(of: cover), rest: rest)
        let length = Double(spine.width)
        let isPulled = pullOut.book?.id == book.id
        // Lying on its back, head on the left.
        let roll = -Double.pi / 2
        let scrollEye = ScrollEye(point: eye, roll: roll)
        // Plain boxes keep scrolling cheap. The pulled book is bound from the tap on, as the
        // flight and the details draw it, so the flight takes over from it without a change. A
        // 3D book stays a box that follows the stack's eye until it reports the eye it saw, so
        // the bound book never draws a frame seen from its own axis.
        let isBound = isPulled && (camera == nil || pullOut.eye != nil)
        Book3DView(
            book: book, look: look, cover: cover, height: spine.width, yaw: .pi / 2 + rest.yaw,
            pitch: rest.pitch, thicknessRatio: spine.height / spine.width, lighting: rest.lighting,
            bound: isBound, distance: rest.distance.map { CGFloat($0 * length) },
            eye: isBound ? (pullOut.eye ?? .zero) * length : .zero,
            scrollEye: camera != nil && !isBound ? scrollEye : nil, roll: roll
        )
        .background {
            // Reports the eye that the box saw as the book is pulled, before it moves, and
            // holds it while the book is out, so the bound book and the flight see it so too.
            if isPulled, camera != nil {
                Color.clear.onGeometryChange(for: SIMD2<Double>.self) { proxy in
                    bookCamera.eye(at: scrollEye.point(in: proxy)) / length
                } action: { eye in
                    if !pullOut.isOut { pullOut.eye = eye }
                }
            }
        }
        .scaleEffect(scale)
        .rotationEffect(.radians(roll))
        .frame(width: drawn.width, height: drawn.height)
        // Read from the tap on, not from `isOut`: this view must already depend on `progress`
        // when `ShelfPullOut.fly` animates it, or the animation never reaches the slide and the
        // book holds still until the flight takes over. A peek or the pointer slides the book
        // partway out along the same path, and back.
        .modifier(
            StackSlide(
                progress: isPulled
                    ? pullOut.progress
                    : pullOut.peekID == book.id
                        ? PullOutPath.peek : nudged ? PullOutPath.nudge : 0,
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

/// The one camera that sees a 3D **Stack**: level with the middle of the stack's area and in
/// front of it, at the distance at which a 50 mm lens on a full-frame camera spans the area's
/// diagonal, a natural view rather than a wide-angle one.
///
/// Books lie flat and level, so a book below the eye shows a sliver of its top board, and a book
/// above it a sliver of its underside, more the farther it lies from the eye, and none at the
/// eye's level. The eye looks out from the middle of the stack's area, where the centered book,
/// which a pull starts from, shows neither.
enum StackCamera {
    /// The camera's distance in front of the spines, in points, for a stack's area `size`
    /// points big: 50 mm against a full-frame sensor's 43.27 mm diagonal.
    static func distance(viewing size: CGSize) -> CGFloat {
        50 / 43.27 * hypot(size.width, size.height)
    }

    /// How far toward the eye a book's top board or underside reaches past its spine at the
    /// ends of the scroll view of a stack whose area is `size` big, whose spines are up to
    /// `thickness` thick, and whose longest book is `length` points long: about the most that
    /// any book's board shows there, for the widest cover (`Book3DView.aspects`).
    ///
    /// A board `w` deep that recedes from a spine `y` points from the eye ends
    /// `y * w / (distance + w)` nearer the eye. The scroll view reaches half of `thickness` plus
    /// this reach past each end of the area, so `y` is at most `size.height / 2 + thickness / 2
    /// + reach`, and the reach is at most `(size.height + thickness) / 2 * w / distance`.
    @MainActor static func reach(length: CGFloat, thickness: CGFloat, in size: CGSize) -> CGFloat {
        (size.height + thickness) / 2 * length * Book3DView.aspects.upperBound
            / distance(viewing: size)
    }
}

/// Orders a stacked book, or a page of them, as one eye sees them (`StackCamera`): below the eye,
/// a book lies over the top board of the book below it, and above the eye, over the underside of
/// the book above it. The book that the eye's level passes through lies over both, and so does
/// its page over the other pages. In a flat stack, every view lies over the one below.
///
/// A pulled book, and its page, lie over all of them while it is out, in both styles, since it
/// comes out in front of the stack and the stacks beside it. A flat book's slide keeps its top
/// edge on the top edge of its place (`PullOutPath.slide`), so it never covers the book above.
///
/// The span of the view's books, `books` in its own coordinates, decides which side of the eye's
/// level the view lies on. Only a change of side updates the view, as a book's top or bottom
/// crosses the eye's level, when the faces that change order lie edge on.
private struct EyeLevelOrder: ViewModifier {
    enum Side { case above, level, below }

    let index: Int
    let books: ClosedRange<CGFloat>
    /// The eye's height in the scroll view's visible coordinates, or `nil` for a flat stack.
    let eye: CGFloat?
    /// Whether the view holds the pulled book while it is out.
    let isOut: Bool
    @State private var side = Side.below

    func body(content: Content) -> some View {
        content
            .background {
                if let eye {
                    Color.clear.onGeometryChange(for: Side.self) { [books] proxy in
                        let top = proxy.frame(in: .scrollView).minY
                        if top + books.upperBound <= eye { return .above }
                        if top + books.lowerBound >= eye { return .below }
                        return .level
                    } action: {
                        side = $0
                    }
                }
            }
            .zIndex(order)
    }

    private var order: Double {
        if isOut { return Double(Int32.max) + 1 }
        guard eye != nil else { return -Double(index) }
        switch side {
        case .above: return Double(index)
        case .below: return -Double(index)
        // Above every index that a stack holds.
        case .level: return Double(Int32.max)
        }
    }
}

/// A stacked book's slide out of its place while it is pulled (`PullOutPath.slide`), drawn in
/// the stack over the books around it (`EyeLevelOrder`). Once the book is clear of the stack,
/// the flight draws it and the stack hides it.
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
/// down while it lies below, by a few points, then snaps it back once the book is back.
///
/// Both motions spread outward from the pulled book like a nudge along a Newton's cradle: each
/// book starts `stagger` seconds after the book nearer the pulled one. The books open over the
/// opening (`room`) and settle with a little overshoot (`opening`). The nearest books move `near`
/// points and farther books a little more, up to `far`. They hold the room while the book is
/// out, so the returning book never touches them. Once it is back in its place, they snap shut
/// (`closing`) and rebound a fraction of a point before they settle, without ever overlapping
/// it. With Reduce Motion on, no book is pulled, so nothing moves.
struct StackRoom: GeometryEffect {
    static let near: CGFloat = 4.5
    static let far: CGFloat = 6
    static let stagger = 0.03
    static let opening = Spring(duration: 0.5, bounce: 0.5)
    static let snap = Spring(duration: 0.3, bounce: 0.5)
    /// How long the snap shut runs, long enough for the books a dozen places away to settle.
    static let closingDuration = 0.9

    /// `ShelfPullOut.room`.
    var room: Double
    /// `ShelfPullOut.closing`.
    var closing: Double
    /// The book's index less the pulled book's: negative above it, and 0 for the pulled book
    /// or while no book is pulled.
    let distance: Int

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(room, closing) }
        set { (room, closing) = (newValue.first, newValue.second) }
    }

    nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: 0,
                y: Self.offset(distance: distance, room: room, closing: closing)))
    }

    /// How far a book `distance` places from the pulled book has moved, down the screen for a
    /// positive distance and up for a negative one.
    static func offset(distance: Int, room: Double, closing: Double) -> CGFloat {
        guard distance != 0, closing < 1 else { return 0 }
        let places = abs(distance)
        let delay = Double(places - 1) * stagger
        let opened = value(of: opening, at: room * ShelfPullOut.openingDuration - delay)
        // The snap's overshoot shows as a rebound away from the book, not a dip into it.
        let shut = value(of: snap, at: closing * closingDuration - delay)
        let reach = (far - (far - near) / CGFloat(places)) * CGFloat(opened * abs(1 - shut))
        return distance < 0 ? -reach : reach
    }

    private static func value(of spring: Spring, at time: Double) -> Double {
        time > 0 ? spring.value(target: 1.0, time: time) : 0
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
/// from the end of the scroll view's content inset, as `ScrollPosition` does, so a top inset, such
/// as one below the Mac's toolbar, shifts neither.
///
/// When columns scroll together, scrolling reports the centered book of `column`: the column of
/// a tapped book, of the first book after a new sort, or the first column at launch. Where that
/// column's stack does not reach the center, as above a shorter stack's top book, scrolling
/// reports the nearest column that does, so the caption always names a book at the center.
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
    /// The column whose centered book scrolling reports while its stack reaches the center,
    /// which held `centeredID` when the carousel last scrolled to it. Only that scroll sets it,
    /// so a glide that passes above a shorter stack still ends on the book it glides to, and a
    /// scroll frame never looks `centeredID` up.
    @State private var column = 0

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
                guard offset != old,
                    let id = track.id(
                        nearest: offset, in: track.column(at: offset, preferring: column)),
                    id != scrolledID
                else { return }
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
            // A new carousel, such as after a mode switch, opens on the centered book, or on the
            // first book before scrolling centers one, which side-by-side stacks need not center
            // at offset 0. One that reappears, such as after Back from details, keeps its
            // offset, because a free scroll rarely rests exactly on a book's.
            .onAppear {
                if centeredID == nil || centeredID != scrolledID { scrollToCenteredBook() }
            }
            // The Mac's scroll bars follow the person's setting in System Settings; the iPhone's
            // books run to the screen's edge without one.
            #if os(macOS)
                .scrollIndicators(.automatic)
            #else
                .scrollIndicators(.hidden)
            #endif
            // The books run to the screen's edge or fade out before it, so a bar's edge effect
            // would only draw a seam across the walnut. Under the iPhone's status bar, Stack draws
            // its own faint backing instead (`SpineCarousel.body`).
            .scrollEdgeEffectHidden()
    }

    private func scrollToCenteredBook() {
        column = track.column(of: centeredID)
        let offset = track.offset(of: centeredID)
        if axis == .vertical { position.scrollTo(y: offset) } else { position.scrollTo(x: offset) }
    }
}

/// The carousel's spines laid out along its scroll axis, from their thicknesses and the gaps
/// between neighbors, in one column or in several side by side that scroll together.
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
///
/// Side-by-side columns end together, so stacks in them rest on one line, and share the pages:
/// page `i` holds every column's spines centered within it, so one lazy stack builds a row of
/// all the columns at a time.
struct SpineTrack {
    static let pageLength: CGFloat = 100

    /// A spine on a page, `inset` from the page's start, in `column`. The inset is negative for a
    /// spine that overhangs the page's start. `index` is the spine's position in `ids`.
    struct Slot: Identifiable {
        let book: CloudBook
        let index: Int
        let column: Int
        let inset: CGFloat
        var id: Int { book.id }
    }

    /// The books' IDs, column by column.
    let ids: [Int]
    /// The scroll offset that centers each spine. The spine whose center lies nearest the
    /// track's start, the first spine of a single column, is centered at offset 0.
    let offsets: [CGFloat]
    /// Each column's span of `ids` and `offsets`.
    let columns: [Range<Int>]
    /// The offset that brings each column's start to the center. Columns end together, so a
    /// column's spines lie across the center at every offset from its start to the end.
    private let starts: [CGFloat]
    let pages: [[Slot]]
    /// From the longest column's start to the end, where every column ends.
    let length: CGFloat
    let maxThickness: CGFloat
    /// The highest first spine's center and the lowest last spine's center, from the start.
    private let firstCenter: CGFloat
    private let lastCenter: CGFloat

    /// Lays out `books` in one column.
    init(
        books: [CloudBook], thickness: (CloudBook) -> CGFloat,
        gap: (_ before: CloudBook, _ after: CloudBook) -> CGFloat
    ) {
        self.init(columns: [books], thickness: thickness, gap: gap)
    }

    /// Lays out each column's books with `thickness` along the scroll axis, each `gap` after
    /// the one before it, and moves each column along so that it ends with the longest. A
    /// negative gap overlaps the neighbors.
    init(
        columns books: [[CloudBook]], thickness: (CloudBook) -> CGFloat,
        gap: (_ before: CloudBook, _ after: CloudBook) -> CGFloat
    ) {
        // Each spine's start within its column, and its thickness.
        let spans = books.map { column in
            var end: CGFloat = 0
            return column.indices.map { index in
                if index > 0 { end += gap(column[index - 1], column[index]) }
                let span = (start: end, thickness: thickness(column[index]))
                end += span.thickness
                return span
            }
        }
        let ends = spans.map { $0.last.map { $0.start + $0.thickness } ?? 0 }
        let length = ends.max() ?? 0
        // Where each column starts, so that it ends with the longest.
        let origins = ends.map { length - $0 }
        let firstCenters = zip(spans, origins)
            .compactMap { column, origin in
                column.first.map { origin + $0.thickness / 2 }
            }
        let firstCenter = firstCenters.min() ?? 0
        var ids: [Int] = []
        var offsets: [CGFloat] = []
        var columns: [Range<Int>] = []
        var pages: [[Slot]] = []
        for column in books.indices {
            let first = ids.count
            for (book, span) in zip(books[column], spans[column]) {
                let start = origins[column] + span.start
                let center = start + span.thickness / 2
                let page = Int(center / Self.pageLength)
                while pages.count <= page { pages.append([]) }
                let inset = start - CGFloat(page) * Self.pageLength
                pages[page].append(Slot(book: book, index: ids.count, column: column, inset: inset))
                ids.append(book.id)
                offsets.append(center - firstCenter)
            }
            columns.append(first..<ids.count)
        }
        self.length = length
        self.firstCenter = firstCenter
        starts = origins.map { $0 - firstCenter }
        lastCenter = spans.compactMap { $0.last.map { length - $0.thickness / 2 } }.max() ?? 0
        maxThickness = spans.joined().map { $0.thickness }.max() ?? 0
        self.ids = ids
        self.offsets = offsets
        self.columns = columns
        self.pages = pages
    }

    /// The space before the first page, so every column's first spine can reach the viewport's
    /// center.
    func leadingSpace(viewport: CGFloat) -> CGFloat { max(0, viewport / 2 - firstCenter) }

    /// The space after the last page, so every column's last spine can reach the viewport's
    /// center, less the room the last page already leaves after it.
    func trailingSpace(viewport: CGFloat) -> CGFloat {
        let pagesEnd = CGFloat(pages.count) * Self.pageLength
        return max(0, viewport / 2 - (pagesEnd - lastCenter))
    }

    /// The column that holds the book with `id`, or the first column when `id` is absent.
    func column(of id: Int?) -> Int {
        let index = id.flatMap { ids.firstIndex(of: $0) }
        return index.flatMap { index in columns.firstIndex { $0.contains(index) } } ?? 0
    }

    /// `preferred` when its spines lie across the center at `offset`, and otherwise the nearest
    /// column whose spines do. `preferred` when none does, as past the track's start.
    func column(at offset: CGFloat, preferring preferred: Int) -> Int {
        let reaches = { starts[$0] <= offset }
        guard starts.indices.contains(preferred), !reaches(preferred) else { return preferred }
        return starts.indices.lazy.filter(reaches)
            .min { abs($0 - preferred) < abs($1 - preferred) } ?? preferred
    }

    /// The index of `column`'s spine nearest the center at `offset`, or `nil` for an empty or
    /// missing column.
    func index(nearest offset: CGFloat, in column: Int = 0) -> Int? {
        guard columns.indices.contains(column), !columns[column].isEmpty else { return nil }
        // Binary search for the first spine whose midpoint with the next lies past `offset`.
        var low = columns[column].lowerBound
        var high = columns[column].upperBound - 1
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

    func id(nearest offset: CGFloat, in column: Int = 0) -> Int? {
        index(nearest: offset, in: column).map { ids[$0] }
    }

    /// The offset that centers the book with `id`, or the first book when `id` is absent.
    func offset(of id: Int?) -> CGFloat {
        id.flatMap { ids.firstIndex(of: $0) }.map { offsets[$0] } ?? offsets.first ?? 0
    }
}

/// Where **Stack** lays each book in a stack `width` points wide, so the books look
/// casually piled: the spine's size, how far the book lies off the stack's middle, and how far it
/// turns about the vertical axis, so its spine faces a little left or right.
///
/// Spines have the shelf's sizes (`CloudBook.shelfSpineSize(scale:)`) lying on their side, at the
/// largest scale that fits the longest possible book across the stack. A book's offsets come from
/// its ID, so it lies the same way on every launch and in every order. Each offset is the square
/// of an even spread, keeping its sign, so most books lie nearly straight and few reach the
/// limits. Each book lies flat on the one below it, level and touching along their length, as
/// gravity would leave a real stack; books never tilt in the screen's plane.
struct StackArrangement {
    /// How far a book can lie off the middle, as a share of the width.
    static let maximumShift: CGFloat = 0.03
    /// How far a book can turn about the screen's vertical axis, so its spine faces a little
    /// left or right, in radians: about 7 degrees. Seen by `StackCamera`, a 3D book shows the
    /// page edges at an end only when the eye lies past that end, as it does for a short book
    /// turned near the limit, or for a stack to one side of a wide Mac window.
    static let maximumTwist = 0.12
    /// Space between the screen's edges and the longest book lying in the middle.
    static let margin: CGFloat = 16
    /// How far the stack fades in from the bottom of the masked part of its scroll view, toward
    /// the caption.
    static let fade: CGFloat = 96
    /// How far the stack fades in from the top. On the iPhone, the books run under the status bar
    /// and vanish only at the screen's top edge; on the Mac, they fade in below the toolbar.
    #if os(iOS)
        static let topFade: CGFloat = 0
    #else
        static let topFade = fade
    #endif

    let width: CGFloat
    /// Points per decimeter of book, up to the shelf's largest.
    let scale: CGFloat

    /// How many stacks fit side by side in `width` with every book at least at `columnScale`,
    /// at most one per three books, so a short list stays one stack.
    static func columns(in width: CGFloat, books: Int) -> Int {
        let needed = CGFloat(BookShape.longest) * columnScale / (1 - 2 * maximumShift) + 2 * margin
        return max(1, min(Int(width / (needed + columnGap)), books / 3))
    }

    /// Whether the stacks keep room for a pulled book at their outer ends: on the Mac, beside
    /// the sidebar and the window's edge. The iPhone's one stack spans the screen.
    #if os(macOS)
        static let keepsPullRoom = true
    #else
        static let keepsPullRoom = false
    #endif

    /// How `books` books lie in stacks across an area `size` big, in `style`: how many stacks
    /// there are, how each lies, and the room the stacks keep at their outer ends.
    ///
    /// The width alone sets how many stacks there are (`columns`), in both styles and at any
    /// height. With `keepsRoom`, the stacks then narrow by the least room that keeps a book
    /// pulled from the stack beside the sidebar or the window's edge in view (`pullReach`). The
    /// space a stack already leaves beside its books counts, so a stack with space to spare
    /// keeps its books' size. Between stacks, a pulled book draws over the stack beside it.
    @MainActor static func layout(
        in size: CGSize, books: Int, style: StackStyle, keepsRoom: Bool = keepsPullRoom
    ) -> (columns: Int, arrangement: StackArrangement, room: CGFloat) {
        let columns = Self.columns(in: size.width, books: books)
        let stacks = { StackArrangement(width: max(0, size.width - 2 * $0) / CGFloat(columns)) }
        guard keepsRoom else { return (columns, stacks(0), 0) }
        let camera = style == .threeD ? StackCamera.distance(viewing: size) : nil
        let reach = { stacks($0).pullReach(twist: style.maximumTwist, camera: camera) }
        // How far the pulled book reaches past the area's side with `room` kept. Narrower stacks
        // hold books no larger, which reach no farther, and lose less space beside their books
        // than the room gains, so this falls as the room grows. The room that ignores the space
        // beside the books is enough; halving the span below it finds the least room within a
        // quarter point, rounding up.
        let short = { room in reach(room) - stacks(room).clearance - room }
        var (low, high) = (CGFloat(0), short(0) > 0 ? reach(0) - margin : 0)
        while high - low > 0.25 {
            let middle = (low + high) / 2
            if short(middle) > 0 { low = middle } else { high = middle }
        }
        return (columns, stacks(high), high)
    }

    /// The space between a stack's side and the end of its longest book, lying as far toward
    /// that side as a book lies (`shift`): `margin`, and more where the books reach
    /// `maximumScale`.
    var clearance: CGFloat {
        (width - CGFloat(BookShape.longest) * scale) / 2 - width * Self.maximumShift
    }

    /// How far past the end of its place a pulled book reaches: the longest book at this scale
    /// grows about its middle as `StackedBook` draws it and comes out toward the side its spine
    /// faces, turned by `twist` (`PullOutPath.slide`), for a camera `camera` points in front of
    /// the spines, or straight on. The widest cover reaches farthest in 3D, and the narrowest, by
    /// a fraction of a point, in 2D.
    @MainActor func pullReach(twist: Double, camera: CGFloat?) -> CGFloat {
        let length = CGFloat(BookShape.longest) * scale
        let aspects = Book3DView.aspects
        var reach: CGFloat = 0
        for aspect in [aspects.lowerBound, aspects.upperBound] {
            // As `StackedBook` places the camera: the spines lie half the book's width in front
            // of its center.
            let rest = PullOutPath.Rest(
                pitch: twist, distance: camera.map { Double($0 / length + aspect / 2) })
            let (_, drawn, _) = StackedBook.fit(
                spine: CGSize(width: length, height: 0), aspect: aspect, rest: rest)
            let slide = PullOutPath.slide(
                at: 1, length: length, thickness: 0, extent: 0, rest: rest)
            reach = max(reach, (drawn.width * slide.scale - length) / 2 + abs(slide.offset.width))
        }
        return reach
    }

    /// The smallest scale a stack takes to make room for another stack beside it.
    static let columnScale: CGFloat = 130

    /// The largest scale, in points per decimeter of book.
    static let maximumScale: CGFloat = 170
    /// Extra room between side-by-side stacks.
    static let columnGap: CGFloat = 48

    init(width: CGFloat) {
        self.width = width
        let room = width * (1 - 2 * Self.maximumShift) - 2 * Self.margin
        scale = min(Self.maximumScale, max(1, room / CGFloat(BookShape.longest)))
    }

    /// The spine lying on its side: its length by its thickness. Stack's spines are thicker
    /// than Shelf's, about a third thicker for a thin book, so long titles on thin books stay
    /// legible lying down; thick books get comically chunky instead.
    func spine(of book: CloudBook) -> CGSize {
        let upright = book.shelfSpineSize(scale: scale, floor: 0.16, growth: 0.9)
        return CGSize(width: upright.height, height: upright.width)
    }

    /// The distance from the stack's leading edge to the spine's, before its turn.
    func leading(of book: CloudBook) -> CGFloat {
        (width - spine(of: book).width) / 2 + shift(of: book)
    }

    func shift(of book: CloudBook) -> CGFloat {
        width * Self.maximumShift * Self.spread(book, salt: 70)
    }

    static func twist(of book: CloudBook, maximum: Double = maximumTwist) -> Double {
        maximum * spread(book, salt: 72)
    }

    /// The books of each stack, side by side, from the top of the stack to the bottom, each
    /// lying flat on the one below it. The stacks rest on one line.
    func track(of stacks: [[CloudBook]]) -> SpineTrack {
        SpineTrack(columns: stacks) {
            spine(of: $0).height
        } gap: { _, _ in
            0
        }
    }

    /// The stops of the stack's mask, from the top of a scroll view `height` points tall to its
    /// bottom: clear for `top` and `bottom` points at the ends, then opaque from `topFade` and
    /// `fade` further in. A scroll view too short for both fades fades in to its middle.
    static func maskStops(height: CGFloat, top: CGFloat, bottom: CGFloat) -> [Gradient.Stop] {
        guard height > 0 else { return [] }
        let opaqueStart = min(0.5, (top + topFade) / height)
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
    /// Heights keep the shape's proportions. Thickness grows from `floor` decimeters by `growth`
    /// times the book's own thickness, so a 120-page book's spine still fits legible lettering,
    /// and a 900-page book's is a little over twice as thick, where in life it is about five
    /// times.
    func shelfSpineSize(scale: CGFloat, floor: CGFloat = 0.12, growth: CGFloat = 0.7) -> CGSize {
        let size = BookShape(of: self, coverAspect: 2 / 3).size
        return CGSize(
            width: scale * (floor + growth * CGFloat(size.z)), height: scale * CGFloat(size.y))
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
    /// How far the status bar reaches down over the bookcase's top, as on the iPhone, where the
    /// bookcase runs under it.
    let statusBar: CGFloat

    init(height: CGFloat, statusBar: CGFloat) {
        self.height = max(height, Self.topEdge + Self.surface + Self.lip + Self.drop)
        self.statusBar = statusBar
    }

    /// How far down the books stand: partway back on the board's top.
    var base: CGFloat { height - Self.drop - Self.lip - Self.surface * 0.45 }

    /// Points per decimeter of book: the most that lets the tallest book (`BookShape.longest`)
    /// clear the shelf above, and the status bar, by 20 points, up to 170, so a tall phone still
    /// shows about ten books across. A short shelf, such as a small phone's with the largest
    /// text, gets smaller spines rather than clipped ones.
    var scale: CGFloat {
        min(170, max(1, (base - max(Self.topEdge, statusBar) - 20) / CGFloat(BookShape.longest)))
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
            ShelfBoard(tile: tile)
        }
        .frame(width: tile, height: tile)
    }
}

/// A walnut board seen from just above, one wood `tile` wide at most: its top, darker toward
/// the back and light enough in front for the books' contact shadows to show, its front edge,
/// lit along its top, and its shadow on the wall below.
private struct ShelfBoard: View {
    let tile: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [ShelfPalette.board.mix(with: .black, by: 0.35), ShelfPalette.board],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Bookcase.surface)
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
    }
}

/// The board under **Stack**, below the stacks' bottom books, so the stacks rest on it rather
/// than over the empty wall. Side-by-side stacks share one board, since they rest on one line. It
/// reaches a little past the longest book any stack could hold, and each stack's bottom book
/// casts a contact shadow on it. The books lie a little back from its front edge, so its top
/// shows below them.
///
/// It scrolls with the books, as part of the scroll view's content, and holds no state, so it
/// draws once.
private struct StackBoard: View {
    let arrangement: StackArrangement
    /// How far the first stack starts in from the carousel's leading edge.
    let inset: CGFloat
    /// Each stack's bottom book.
    let bottoms: [CloudBook]

    var body: some View {
        let reach = CGFloat(BookShape.longest) * arrangement.scale + 2 * StackArrangement.margin
        let start = inset + max(0, (arrangement.width - reach) / 2)
        let width = CGFloat(bottoms.count) * arrangement.width - 2 * (start - inset)
        ShelfBoard(tile: width)
            .frame(width: width)
            .overlay(alignment: .topLeading) {
                ForEach(bottoms.indices, id: \.self) { column in
                    let book = bottoms[column]
                    let length = arrangement.spine(of: book).width
                    ContactShadow(width: length)
                        .position(
                            x: inset + CGFloat(column) * arrangement.width
                                + arrangement.leading(of: book) + length / 2 - start,
                            y: 0)
                }
            }
            .padding(.leading, start)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The pool of warm light behind **Stack**, centered on the stack whose book the caption names,
/// so beside other stacks it marks which one that is. It glides to another stack when the
/// caption's book moves there, or moves at once with Reduce Motion on. With one stack, it never
/// reads `centeredID`, so scrolling never updates it.
private struct StackLamp: View {
    let track: SpineTrack
    /// The middle of each stack across the carousel.
    let centers: [CGFloat]
    /// The carousel's height, whose middle the pool lights.
    let height: CGFloat
    /// Whether the carousel has keyboard focus, which the pool marks by warming.
    let warm: Bool
    @Binding var centeredID: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let column = centers.count > 1 ? track.column(of: centeredID) : 0
        RadialGradient(
            colors: [ShelfPalette.lamp.opacity(warm ? 0.32 : 0.22), .clear], center: .center,
            startRadius: 0, endRadius: 320
        )
        .frame(width: 700, height: 700)
        .position(x: centers.indices.contains(column) ? centers[column] : 0, y: height / 2)
        .animation(reduceMotion ? nil : .smooth(duration: SpineCarousel.glide), value: column)
        .animation(.easeOut(duration: 0.2), value: warm)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    /// The light's usual strength.
    static let warmth = 0.14
    /// The light while the shelf has keyboard focus, which it marks instead of a focus ring.
    static let focusedWarmth = 0.22

    var warmth = Self.warmth

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [ShelfPalette.lamp.opacity(warmth), .clear], center: .top, startRadius: 0,
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
