import RealityKit
import SwiftUI

/// The pile view's full size, under the bars, and the insets of the bars that cover its edges.
struct PileViewport: Equatable {
    var size: CGSize
    var insets: EdgeInsets
}

/// The library as a physics toy: the first books, up to `maximumBooks` of them and
/// `PileLayout.maximumVolume` liters, drop onto a table and pile up.
///
/// Drag a book to pick it up and throw it, tap one for its details, pinch to zoom, and turn two
/// fingers to look around the pile. When the phone reports motion, the shelf's **Tilt** tips the
/// table or makes the phone the pile's box (`PileTilt`), and in either a hard shake throws the
/// books. With the shelf's drop by period on, the books drop a month, week, or year at a time
/// (see `PileLayout.periods`). Collisions play haptic taps and, while the shelf's **Sounds** is
/// on, knocks (`ImpactFeedback`), only while the pile shows in the active app. With Reduce
/// Motion on, books appear in tidy stacks instead of falling, tilt and shaking are off, and no
/// dust drifts in the lamp's beam. The table fills the screen, but walls keep the books between
/// the bars.
///
/// A tapped book rises out of the pile and flies to where `BookDetailView` draws its book, and
/// the details fade in over the darkened pile once it lands. The details' own book is a
/// transparent stand-in that places and turns the pile's book, so the same model scrolls and
/// turns with the details. While they show, the pile's gestures, tilt, shaking, and controls,
/// and the shelf's (through `showsDetails`), give way to **Back**. **Back** fades the details
/// out, returns the controls, and throws the book back into the pile. With Reduce Motion on, or
/// when the pile cannot lift the book, a tap calls `open` to push the details instead.
/// Returning from pushed details, or from the Share tab that the lifted book's **Share** opens,
/// finds the pile as the reader left it. Leaving the pile any other way, such as for another
/// tab, puts a lifted or returning book back at once and frees the books and textures, and the
/// books drop again on the reader's return.
///
/// **Share** makes an image of `books`, up to `PileSnapshotRenderer.maximumBooks` of them, in a
/// new pile headed `title`. While its sheet is open, the pile leaves the screen and keeps its
/// books, and tilt and shaking pause, as they do while the app is not active.
///
/// RealityKit's render thread can crash drawing this view while a share image's offscreen
/// renderer steps the same engine, so while any pile image renders, such as the Share tab's
/// Pile template, the table and books leave the view's scene, and a lifted book goes back. A
/// book cannot lift while they are out. RealityKit keeps updating a `RealityView` in a tab that
/// is not selected, and a view removed there lingers until its tab shows again and then takes
/// its scene along, so the view itself stays.
struct BookPileView: View {
    /// The most books the pile drops. Tall enough stacks of more would reach the ceiling, and
    /// their textures would outgrow the memory `BookPileScene` budgets for.
    static let maximumBooks = 300

    let books: [CloudBook]
    /// The name of the books' time frame, which heads the share image.
    let title: String
    /// The books' time frame, or `nil` for every book, which a drop by period goes through.
    var frame: TimeFrame? = nil
    /// Set while a lifted book's details show over the pile, when the shelf hides its controls.
    @Binding var showsDetails: Bool
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    /// Set by **Tilt** in the shelf's **Sort and filter** menu.
    @AppStorage("BookwormsPileTiltMode") private var tilt = PileTilt.table
    /// Set by the drop by period toggle in the shelf's **Sort and filter** menu.
    @AppStorage("BookwormsPileByPeriod") private var dropsByPeriod = false
    /// Set by **Sounds** in the shelf's **Sort and filter** menu.
    @AppStorage("BookwormsThreeDSounds") private var sounds = true
    @State private var scene = BookPileScene()
    @State private var viewport: PileViewport?
    /// The canvas's frame in global coordinates, which the details' book frame converts from.
    @State private var canvas = CGRect.zero
    /// Counts **Drop again** presses; each starts a new drop with new poses.
    @State private var generation = 0
    /// Set while pushed details cover the pile, or while the lifted book's details wait for the
    /// reader to return from the Share tab, so leaving keeps the pile.
    @State private var showsBook = false
    /// The book lifted out of the pile, whose details show over it.
    @State private var lifted: Lifted?
    /// Counts lifts and returns, so a task that an earlier one started cannot change a later one.
    @State private var liftRevision = 0
    /// Set between `onAppear` and `onDisappear`. The view stays in the hierarchy under a pushed
    /// book or in a tab that is not selected, where tilt must stay off.
    @State private var isShown = false
    @State private var sharesPile = false
    /// Set while a finger holds a book. SwiftUI resets it when the drag ends or is cancelled,
    /// so the book is let go either way.
    @GestureState private var holdsBook = false
    /// Set while fingers zoom or turn the camera, and reset like `holdsBook`, so the next
    /// gesture starts from the camera as it is.
    @GestureState private var movesCamera = false

    private struct DropRequest: Equatable {
        let ids: [Int]
        let tidy: Bool
        let periods: TimeFrame?
        let generation: Int
        let viewport: PileViewport?
    }

    /// What the lifted book's textures show.
    private struct Dressing: Equatable {
        let book: CloudBook
        let look: SpineLook
    }

    private var dressing: Dressing? {
        guard let id = lifted?.book.id, let book = books.first(where: { $0.id == id }) else {
            return nil
        }
        return Dressing(book: book, look: model.look(for: book))
    }

    private struct Lifted: Equatable {
        let book: CloudBook
        /// Whether the details show: set once the book lands, and cleared by **Back**.
        var showsText = false
        /// Set by **Back** while the details fade out, before the book is thrown back.
        var isReturning = false
    }

    var body: some View {
        let dropped = Array(PileLayout.dropped(books, count: Self.maximumBooks))
        ZStack {
            if sharesPile {
                Color.clear
            } else {
                RealityView { content in
                    content.camera = .virtual
                    content.renderingEffects.antialiasing = .multisample4X
                    scene.attach(to: &content)
                    if PileSnapshotRenderer.isRendering { scene.root.removeFromParent() }
                } update: { content in
                    // Puts back what a finished render took out of the scene.
                    if !PileSnapshotRenderer.isRendering && scene.root.scene == nil {
                        content.add(scene.root)
                    }
                }
                .gesture(throwBook)
                .gesture(openBook)
                .simultaneousGesture(moveCamera)
                .allowsHitTesting(lifted == nil)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    canvas = $0
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Pile of \(count)")
        .accessibilityValue(title)
        .accessibilityHint(
            "Drag a book to throw it, or tap one for its details. To go through books one at a time, choose Stack or Shelf."
        )
        .accessibilityAction(named: dropTitle) { generation += 1 }
        .accessibilityHidden(lifted.map { !$0.isReturning } ?? false)
        .overlay {
            if let lifted { details(lifted) }
        }
        // Outside `ignoresSafeArea`, the proxy reports the safe area's size and the insets the
        // view extends past.
        .onGeometryChange(for: PileViewport.self) { proxy in
            let insets = proxy.safeAreaInsets
            return PileViewport(
                size: CGSize(
                    width: proxy.size.width + insets.leading + insets.trailing,
                    height: proxy.size.height + insets.top + insets.bottom),
                insets: insets)
        } action: {
            viewport = $0
        }
        .task(
            id: DropRequest(
                ids: dropped.map(\.id), tidy: reduceMotion, periods: periods,
                generation: generation, viewport: viewport)
        ) {
            guard let viewport else { return }
            scene.planDrop(
                dropped, tidy: reduceMotion, periods: periods, generation: generation,
                viewport: viewport)
            // A new pile, such as one without the lifted book, removed it.
            if let lifted, scene.liftedID != lifted.book.id { putBack() }
            await scene.fill(
                dropped, tidy: reduceMotion, periods: periods, generation: generation,
                viewport: viewport, model: model)
            #if DEBUG
                await openDebugBook()
                // `-BookwormsPileRedrops <n>` drops again, as **Drop again** does, until the
                // drop with generation n.
                if !Task.isCancelled,
                    generation < UserDefaults.standard.integer(forKey: "BookwormsPileRedrops")
                {
                    generation += 1
                }
            #endif
        }
        // Draws the lifted book as sharply as the details' own book, with its current cover and
        // design.
        .task(id: dressing) {
            guard let dressing else { return }
            await scene.dressLifted(dressing.book, scale: displayScale, model: model)
        }
        .onAppear {
            showsBook = false
            isShown = true
            #if DEBUG
                if PileSnapshotDebug.opensSheet { sharesPile = true }
            #endif
        }
        .onDisappear {
            isShown = false
            scene.endDrag()
            scene.setTilt(tiltMode, tracking: false)
            // A view removed from the hierarchy, such as for another 3D view, gets no
            // `playsFeedback` change, so this releases the engines and the audio session.
            scene.feedback.stop()
            guard !showsBook else { return }
            putBack()
            scene.release()
        }
        // Leaves the view nothing to draw while a share image renders, in whichever tab.
        .onChange(of: PileSnapshotRenderer.isRendering) { _, isRendering in
            guard isRendering else { return }
            putBack()
            scene.root.removeFromParent()
        }
        // Stops sampling motion while nothing reads it, and takes a new reference afterward.
        .onChange(of: tracksMotion) { scene.setTilt(tiltMode, tracking: tracksMotion) }
        .onChange(of: tiltMode, initial: true) { scene.setTilt(tiltMode, tracking: tracksMotion) }
        .onChange(of: sounds, initial: true) { scene.feedback.playsSounds = sounds }
        // Keeps the haptic and audio engines only while collisions can be seen.
        .onChange(of: playsFeedback, initial: true) {
            if playsFeedback { scene.feedback.start() } else { scene.feedback.stop() }
        }
        .onChange(of: reduceMotion, initial: true) { scene.setDust(!reduceMotion) }
        .onChange(of: holdsBook) { if !holdsBook { scene.endDrag() } }
        .onChange(of: movesCamera) { if !movesCamera { scene.endCameraMove() } }
        .toolbar {
            if let lifted {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward", action: returnBook)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        // Keeps the details for the reader's return, as pushed details stay.
                        showsBook = true
                        model.share(lifted.book)
                    }
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    Button(dropTitle, systemImage: "arrow.counterclockwise") { generation += 1 }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Share", systemImage: "square.and.arrow.up") { sharesPile = true }
                }
                // Names the time frame, which the toolbar's menu saves across launches.
                ToolbarItem(placement: .subtitle) {
                    Text("\(title) · \(count)")
                }
            }
        }
        .sheet(isPresented: $sharesPile) { PileSnapshotSheet(books: books, title: title) }
    }

    /// The lifted book's details, which fade in once the book lands. The pile's book shows
    /// through their transparent stand-in for the details' own book.
    ///
    /// They join the hierarchy at the tap, since the book flies to their stand-in's frame. A
    /// scroll view's edge effect darkens the tab bar's glass even while the details are hidden,
    /// so it shows only while the details do, over the darkened veil. Removing the details with
    /// the effect showing leaves the tab bar dark over the lit pile, so it goes when they start
    /// to fade.
    private func details(_ lifted: Lifted) -> some View {
        BookDetailView(
            book: lifted.book,
            hostedBook: HostedBook(
                place: { [scene, canvas] frame in
                    scene.placeLifted(
                        frame.offsetBy(dx: -canvas.minX, dy: -canvas.minY), in: canvas.size)
                },
                turn: { [scene] in scene.turnLifted($0) })
        )
        .scrollEdgeEffectHidden(!lifted.showsText)
        .opacity(lifted.showsText ? 1 : 0)
        .allowsHitTesting(lifted.showsText)
        .accessibilityHidden(!lifted.showsText)
        // Pushed details close with VoiceOver's escape gesture through the navigation stack.
        .accessibilityAction(.escape, returnBook)
    }

    private var tiltMode: PileTilt { reduceMotion ? .off : tilt }
    /// The frame a drop goes through period by period, or `nil` for a drop in waves.
    private var periods: TimeFrame? { dropsByPeriod && !reduceMotion ? frame ?? .lifetime : nil }
    private var playsFeedback: Bool { isShown && !sharesPile && scenePhase == .active }
    /// Whether the pile may sample motion, for tilt and shakes, which **Tilt**'s **Off** turns
    /// off too (see `BookPileScene.setTilt`).
    private var tracksMotion: Bool {
        isShown && !reduceMotion && !sharesPile && lifted == nil && scenePhase == .active
    }

    /// The number of books, such as "39 books", or "300 of 1,024 books" when the pile drops
    /// only the first books.
    private var count: String {
        let dropped = PileLayout.dropped(books, count: Self.maximumBooks).count
        if dropped < books.count {
            return "\(dropped.formatted()) of \(books.count.formatted()) books"
        }
        return books.count == 1 ? "1 book" : "\(books.count.formatted()) books"
    }

    private var dropTitle: String { reduceMotion ? "Stack again" : "Drop again" }

    private var throwBook: some Gesture {
        DragGesture(minimumDistance: 6)
            .targetedToAnyEntity()
            .updating($holdsBook) { _, holds, _ in holds = true }
            .onChanged { value in
                scene.drag(
                    value.entity, along: value.ray(through: value.location, in: .local, to: .scene))
            }
    }

    private var openBook: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                guard let id = scene.bookID(for: value.entity),
                    let book = books.first(where: { $0.id == id })
                else { return }
                show(book)
            }
    }

    /// Lifts `book` out of the pile to its details, or pushes them with Reduce Motion on or
    /// when the pile cannot lift it. Does nothing while another book flies.
    private func show(_ book: CloudBook) {
        guard lifted == nil, !scene.isFlying else { return }
        guard !reduceMotion, let landing = scene.lift(book.id) else {
            showsBook = true
            open(book)
            return
        }
        liftRevision &+= 1
        let revision = liftRevision
        lifted = Lifted(book: book)
        showsDetails = true
        Task {
            try? await Task.sleep(for: .seconds(landing))
            guard liftRevision == revision else { return }
            withAnimation(.easeOut(duration: 0.25)) { lifted?.showsText = true }
            AccessibilityNotification.ScreenChanged(nil).post()
            #if DEBUG
                // Simulator hook: `-BookwormsPileBack <seconds>` goes back that long after the
                // details appear.
                guard
                    let delay = UserDefaults.standard.string(forKey: "BookwormsPileBack")
                        .flatMap(Double.init)
                else { return }
                try? await Task.sleep(for: .seconds(delay))
                if liftRevision == revision { returnBook() }
            #endif
        }
    }

    /// Fades the details out, then gives the pile its controls again and throws the book back
    /// into the pile.
    ///
    /// The bars change and the details leave the hierarchy together, after the fade. That can
    /// hold up the screen for a moment, which the book waits out before it leaves (see
    /// `BookPileScene.throwBack`), so the stall shows as a pause rather than a skipped throw.
    private func returnBook() {
        guard let current = lifted, !current.isReturning else { return }
        liftRevision &+= 1
        let revision = liftRevision
        lifted?.isReturning = true
        func throwBack() {
            lifted = nil
            showsDetails = false
            scene.throwBack()
            AccessibilityNotification.ScreenChanged(nil).post()
        }
        // Before the book lands, the details have not appeared.
        guard current.showsText else { return throwBack() }
        withAnimation(.easeIn(duration: 0.2)) {
            lifted?.showsText = false
        } completion: {
            if liftRevision == revision { throwBack() }
        }
    }

    /// Closes the details at once, if they show, and puts a lifted or returning book back in
    /// the pile.
    private func putBack() {
        scene.dropLifted()
        guard lifted != nil else { return }
        liftRevision &+= 1
        lifted = nil
        showsDetails = false
    }

    private var moveCamera: some Gesture {
        MagnifyGesture()
            .simultaneously(with: RotateGesture())
            .updating($movesCamera) { _, moves, _ in moves = true }
            .onChanged { value in
                scene.moveCamera(
                    magnification: value.first?.magnification ?? 1,
                    rotation: value.second?.rotation ?? .zero, focus: value.first?.startLocation,
                    in: viewport?.size ?? .zero)
            }
    }

    #if DEBUG
        /// Whether `-BookwormsOpenBook` has opened its book, which it does once per launch.
        @MainActor private static var openedDebugBook = false

        /// Simulator hook: `-BookwormsOpenBook <book ID>` opens that book, as a tap does, four
        /// seconds after the drop finishes.
        private func openDebugBook() async {
            guard !Self.openedDebugBook,
                let id = UserDefaults.standard.string(forKey: "BookwormsOpenBook")
                    .flatMap(Int.init),
                let book = books.first(where: { $0.id == id })
            else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            Self.openedDebugBook = true
            show(book)
        }
    #endif
}

extension TimeFrame {
    /// The frame a setting names: "year:2025", "month:2025-8", or "lifetime".
    init?(setting: String) {
        let parts = setting.split(separator: ":", maxSplits: 1).map(String.init)
        let numbers = parts.dropFirst().first?.split(separator: "-").compactMap { Int($0) } ?? []
        switch (parts.first, numbers.count) {
        case ("year", 1): self = .year(numbers[0])
        case ("month", 2) where (1...12).contains(numbers[1]):
            self = .month(year: numbers[0], month: numbers[1])
        case ("lifetime", 0) where parts.count == 1: self = .lifetime
        default: return nil
        }
    }

    /// The frame as `init(setting:)` reads it.
    var setting: String {
        switch self {
        case .year(let year): "year:\(year)"
        case .month(let year, let month): "month:\(year)-\(month)"
        case .lifetime: "lifetime"
        }
    }

    /// The pile's frame for a saved setting, or `nil` for every book.
    ///
    /// A saved year or month in which no book was finished, such as one from another library,
    /// gives way to the newest year or month that has one, so the pile keeps the reader's kind
    /// of frame.
    static func pileFrame(setting: String, in books: [CloudBook]) -> TimeFrame? {
        guard let saved = TimeFrame(setting: setting) else { return nil }
        let periods = periods(in: books)
        switch saved {
        case .year(let year) where !periods.years.contains(year):
            return periods.years.first.map(TimeFrame.year)
        case .month where !periods.months.contains(saved): return periods.months.first
        default: return saved
        }
    }
}
