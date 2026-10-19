import RealityKit
import SwiftUI
import TipKit

/// The pile view's full size, under the bars, and the insets of the bars that cover its edges.
struct PileViewport: Equatable {
    var size: CGSize
    var insets: EdgeInsets
}

/// The Desk scene: the library as a physics toy. The first books, up to `maximumBooks` of them
/// and `PileLayout.maximumVolume` liters, drop onto a table and pile up. While a new pile's
/// first books get ready, a spinner shows over the table (`SceneLoading`), and every book falls
/// in from above the top of the screen.
///
/// Touch and hold a book to pick it up, with a light haptic tap, drag to carry it, and let go
/// to throw it (`PileCarry`); tap one for its details, pinch to zoom, and turn two fingers to
/// look around the pile. One finger's touch decides between a tap and a hold, and the first of
/// a held book and a camera move to start keeps the fingers until they lift. On the Mac, a drag
/// picks a book up at once and a click opens it; the pointer shows a grab hand over a book and
/// while it carries one, a book's context menu offers its actions (`BookMenuItems`), the scroll
/// wheel zooms toward the pointer, and Shift with the wheel, or Option with a drag, turns the
/// view (`PilePointer`). Tips teach these gestures once the pile rests (`DeskTips`). When the
/// phone reports motion, the desk's **Tilt** tips the table or makes the phone the pile's box
/// (`PileTilt`), and in either a hard shake throws the books. With the desk's drop by period
/// on, the books drop a month, week, or year at a time (see `PileLayout.periods`). Collisions
/// play haptic taps and, while the desk's **Sounds** is on, knocks (`ImpactFeedback`), only
/// while the pile shows in the active app. With Reduce Motion on, books appear in tidy stacks
/// instead of falling, a held book neither swings nor flies but drops where it is let go, tilt
/// and shaking are off, and no dust drifts in the lamp's beam. The table fills the screen, but
/// walls keep the books between the bars and, on the Mac, clear of the sidebar (`PileTray`).
///
/// A tapped book rises out of the pile and flies to where `BookDetailView` draws its book, and
/// the details fade in over the darkened pile once it lands (`LiftedDetails`). While they show,
/// the pile's gestures, tilt, shaking, and controls, and the desk's, give way to **Back**.
/// **Back** fades the details out, returns the controls, and throws the book back into the
/// pile. With Reduce Motion on, or when the pile cannot lift the book, a tap calls `open` to
/// push the details instead.
///
/// The scene (`DeskScenes.pile`) draws in the desk's view, which lives only while Desk is on
/// screen and no share sheet covers the pile (`DeskSceneView`), so a hidden tab runs no frame
/// loop; the scene keeps its books, so the pile is as the reader left it on return. Once the
/// pile rests, a still of it replaces the view until a touch or a change wakes the desk
/// (`DeskScenes`). This view lays the gestures, controls, and details over it. Under pushed
/// details, the table and books are disabled, so nothing simulates or draws. Leaving the pile
/// other than for details, such as for another tab or for the dominoes, puts a lifted or
/// returning book back at once. A memory warning while the tab is hidden frees the books and
/// textures, and the books drop again on the reader's return.
///
/// **Share** makes an image of `books`, up to `PileSnapshotRenderer.maximumBooks` of them, in a
/// new pile headed `title`. While its sheet is open, the pile leaves the screen and keeps its
/// books, and tilt and shaking pause, as they do while the app is not active.
///
/// RealityKit's render thread can crash drawing this view while a share image's offscreen
/// renderer steps the same engine, so while any pile image renders, such as the Share tab's
/// Pile template, the table and books leave the view's scene, and a lifted book goes back. A
/// book cannot lift while they are out.
struct BookPileView: View {
    /// The most books the pile drops. Tall enough stacks of more would reach the ceiling, and
    /// their textures would outgrow the memory `BookPileScene` budgets for.
    static let maximumBooks = 300

    let books: [CloudBook]
    /// The name of the books' time frame, which heads the share image.
    let title: String
    /// The books' time frame, or `nil` for every book, which a drop by period goes through.
    var frame: TimeFrame? = nil
    /// The desk's scenes, whose Desk scene this view shows.
    let desk: DeskScenes
    /// The details of a book lifted out of the pile, which the desk's bar also reads.
    let details: LiftedDetails
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Set by **Tilt** in the desk's options menu.
    @AppStorage("BookwormsPileTiltMode") private var tilt = PileTilt.off
    /// Set by the drop by period toggle in the desk's options menu.
    @AppStorage("BookwormsPileByPeriod") private var dropsByPeriod = false
    /// Set by **Sounds** in the desk's options menu.
    @AppStorage("BookwormsThreeDSounds") private var sounds = true
    @State private var viewport: PileViewport?
    /// The canvas's frame in global coordinates, which the details' book frame converts from.
    @State private var canvas = CGRect.zero
    /// Set while pushed details cover the pile, or while the lifted book's details wait for the
    /// reader to return from the Share tab, so leaving keeps the pile.
    @State private var showsBook = false
    /// Set between `onAppear` and `onDisappear`. The view stays in the hierarchy under a pushed
    /// book or in a tab that is not selected, where tilt must stay off.
    @State private var isShown = false
    @State private var sharesPile = false
    /// One finger's touch on the desk, from touching down until it lifts.
    @State private var touch: Touch?
    /// Counts books picked up, each of which plays a light haptic tap.
    @State private var pickups = 0
    #if os(macOS)
        /// The book whose cover the context menu's **Change Cover…** changes.
        @State private var coverBook: CloudBook?
        /// Where the pointer last was over the desk.
        @State private var pointerSpot = DeskPointer.Spot()
    #endif
    /// Set while a finger touches the desk. SwiftUI resets it when the touch ends or is
    /// cancelled, so a held book is let go either way.
    @GestureState private var touches = false
    /// Set while fingers zoom or turn the camera, and reset like `touches`, so the next
    /// gesture starts from the camera as it is.
    @GestureState private var movesCamera = false

    /// What a finger, or the Mac's pointer with its button down, on the desk is doing.
    private enum Touch {
        /// Resting until `PileCarry.holdDelay` passes, when `hold` picks up the book under it;
        /// on the Mac, with no `hold`, until it drags past `PileCarry.slop`. Lifting sooner
        /// taps.
        case pressing(hold: Task<Void, Never>?)
        /// Dragged on the Mac: `lift` picks up the book where the drag started, once the
        /// desk's view can find it.
        case lifting(Task<Void, Never>)
        /// Carrying a book it picked up.
        case holding
        /// Dragging with Option held on the Mac, which turns the view about the pile.
        case turning
        /// Moved before the hold, or held where no book could be picked up: it does nothing
        /// more until it lifts.
        case idle
    }

    private struct DropRequest: Equatable {
        let ids: [Int]
        let tidy: Bool
        let periods: TimeFrame?
        let generation: Int
        let viewport: PileViewport?
    }

    private var scene: BookPileScene { desk.pile }

    var body: some View {
        let dropped = Array(PileLayout.dropped(books, count: Self.maximumBooks))
        // A SwiftUI layer over the desk's view takes the touches: gestures on the hosted view
        // would not fire.
        Color.clear
            .contentShape(.rect)
            .gesture(touchBook)
            .simultaneousGesture(moveCamera)
            #if os(macOS)
                .modifier(
                    DeskPointer(
                        desk: desk, books: books, size: viewport?.size, spot: pointerSpot,
                        presses: touch != nil, carries: isCarrying,
                        open: { book in
                            Task {
                                await desk.awake()
                                show(book)
                            }
                        }, changeCover: { coverBook = $0 })
                )
                .background { ScrollWheelReader(onScroll: scroll) }
            #endif
            .overlay { PileTipAnchor(desk: desk, size: viewport?.size) }
            .allowsHitTesting(details.lift == nil)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                canvas = $0
            }
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel("Desk with \(count)")
            .accessibilityValue(title)
            .accessibilityHint(Self.hint)
            .accessibilityAction(named: dropTitle) { desk.pileGeneration += 1 }
            .settingUp(scene.loading.isLoading)
            .modifier(
                LiftedDetailsOverlay(details: details, scene: scene, canvas: canvas) {
                    showsBook = true
                }
            )
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
                desk.viewport = $0
            }
            .task(
                id: DropRequest(
                    ids: dropped.map(\.id), tidy: reduceMotion, periods: periods,
                    generation: desk.pileGeneration, viewport: viewport)
            ) {
                guard let viewport else { return }
                let generation = desk.pileGeneration
                scene.planDrop(
                    dropped, tidy: reduceMotion, periods: periods, generation: generation,
                    viewport: viewport)
                // A new pile, such as one without the lifted book, removed it.
                if let lift = details.lift, scene.liftedID != lift.book.id {
                    details.putBack(scene)
                }
                await scene.fill(
                    dropped, tidy: reduceMotion, periods: periods, generation: generation,
                    viewport: viewport, model: model)
                #if DEBUG
                    await desk.setUpDominoesOnLaunch(books: dropped, reduceMotion: reduceMotion)
                    await details.openDebugBook(in: books, scene: scene, show: show)
                    // `-BookwormsPileRedrops <n>` drops again, as **Drop again** does, until the
                    // drop with generation n.
                    if !Task.isCancelled,
                        generation < UserDefaults.standard.integer(forKey: "BookwormsPileRedrops")
                    {
                        desk.pileGeneration += 1
                    }
                #endif
            }
            .onAppear {
                showsBook = false
                isShown = true
                #if DEBUG
                    if PileSnapshotDebug.opensSheet { sharesPile = true }
                #endif
            }
            // The pile leaves the screen while its share sheet covers it.
            .onChange(of: sharesPile, initial: true) { desk.hidesView = sharesPile }
            .onDisappear {
                isShown = false
                scene.endDrag()
                scene.setTilt(tiltMode, tracking: false)
                // A view removed from the hierarchy, such as for another 3D view, gets no
                // `playsFeedback` change, so this releases the engines and the audio session.
                scene.feedback.stop()
                if !showsBook { details.putBack(scene) }
            }
            // Leaves the view nothing to draw while a share image renders, in whichever tab, and
            // puts the scene back when it ends.
            .onChange(of: PileSnapshotRenderer.isRendering) { _, isRendering in
                if isRendering {
                    details.putBack(scene)
                    scene.detach()
                } else {
                    scene.reattach()
                }
            }
            // The books and their textures are the pile's only large memory; a hidden pile gives
            // them up under pressure and drops again on return.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification)
            ) { _ in
                guard !isShown else { return }
                details.putBack(scene)
                desk.releasePile()
            }
            // Stops sampling motion while nothing reads it, and takes a new reference afterward.
            .onChange(of: tracksMotion) { scene.setTilt(tiltMode, tracking: tracksMotion) }
            .onChange(of: tiltMode, initial: true) {
                scene.setTilt(tiltMode, tracking: tracksMotion)
            }
            .onChange(of: sounds, initial: true) { scene.feedback.playsSounds = sounds }
            // Keeps the haptic and audio engines only while collisions can be seen.
            .onChange(of: playsFeedback, initial: true) {
                if playsFeedback { scene.feedback.start() } else { scene.feedback.stop() }
            }
            .onChange(of: reduceMotion, initial: true) { scene.setDust(!reduceMotion) }
            // A touch wakes a paused desk at once, so its view is back before a hold picks up a
            // book (`PileCarry.holdDelay`) or a tap lifts one.
            .onChange(of: touches) { if touches { desk.wake() } else { endTouch() } }
            .sensoryFeedback(.impact(weight: .light), trigger: pickups)
            .onChange(of: movesCamera) {
                if movesCamera {
                    desk.wake()
                    DeskTips.cameraMoved()
                } else {
                    scene.endCameraMove()
                }
            }
            .toolbar {
                if details.lift == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(dropTitle, systemImage: "arrow.counterclockwise") {
                            desk.pileGeneration += 1
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Share", systemImage: "square.and.arrow.up") { sharesPile = true }
                    }
                }
            }
            .sheet(isPresented: $sharesPile) { PileSnapshotSheet(books: books, title: title) }
            #if os(macOS)
                // As a book's details open it: a series that shares a design takes its spine
                // from its source's cover, and the sheet matches the room's dark scheme.
                .sheet(item: $coverBook) { book in
                    CoverPickerView(book: model.designSource(for: book)) {}
                    .preferredColorScheme(.dark)
                }
            #endif
            #if DEBUG
                .onChange(of: desk.isPaused) { tapAfterPause() }
            #endif
    }

    #if DEBUG
        /// Simulator hook: `-BookwormsPileWakeTap <seconds>` taps the middle of the screen that
        /// long after the desk pauses, as a tap does whose touch the gesture never reported, so
        /// the tap alone wakes the desk and lifts the book there.
        private func tapAfterPause() {
            let delay = UserDefaults.standard.double(forKey: "BookwormsPileWakeTap")
            guard desk.isPaused, delay > 0, let size = viewport?.size else { return }
            Task {
                try? await Task.sleep(for: .seconds(delay))
                tap(at: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
            }
        }
    #endif

    private var tiltMode: PileTilt { reduceMotion ? .off : tilt }
    /// The frame a drop goes through period by period, or `nil` for a drop in waves.
    private var periods: TimeFrame? {
        Self.periods(byPeriod: dropsByPeriod, reduceMotion: reduceMotion, frame: frame)
    }

    /// The frame a drop goes through period by period, or `nil` for a drop in waves: `frame`, or
    /// every book's years for `nil`, while the desk's drop by period is on and Reduce Motion off.
    static func periods(byPeriod: Bool, reduceMotion: Bool, frame: TimeFrame?) -> TimeFrame? {
        byPeriod && !reduceMotion ? frame ?? .lifetime : nil
    }
    private var playsFeedback: Bool { isShown && !sharesPile && scenePhase == .active }
    /// Whether the pile may sample motion, for tilt and shakes, which **Tilt**'s **Off** turns
    /// off too (see `BookPileScene.setTilt`).
    private var tracksMotion: Bool {
        isShown && !reduceMotion && !sharesPile && details.lift == nil && scenePhase == .active
    }

    /// The number of books, such as "39 books", or "300 of 1,024 books" when the pile drops
    /// only the first books.
    private var count: String {
        FrameChip.books(
            PileLayout.dropped(books, count: Self.maximumBooks).count, of: books.count)
    }

    private var dropTitle: String { reduceMotion ? "Stack again" : "Drop again" }

    /// The scene's gestures as VoiceOver hints them, in the words of the Mac's pointer or the
    /// iPhone's touch.
    private static var hint: String {
        #if os(macOS)
            "Drag a book and let go to throw it, or click one for its details. To go through books one at a time, open Library."
        #else
            "Touch and hold a book, then drag and let go to throw it, or tap one for its details. To go through books one at a time, open Library."
        #endif
    }

    /// Whether the touch carries a book, when the Mac's pointer shows a closed hand.
    private var isCarrying: Bool {
        if case .holding = touch { true } else { false }
    }

    /// Whether a new press turns the view rather than touching a book: Option held on the Mac.
    private static var turnsView: Bool {
        #if os(macOS)
            NSEvent.modifierFlags.contains(.option)
        #else
            false
        #endif
    }

    /// One finger on the desk, which taps, or holds a book to pick it up, carry it, and throw
    /// it; on the Mac, the pointer, which clicks, or drags a book at once. The scene's own ray
    /// finds the book, since the view takes no entity-targeted gestures. A zero-distance drag
    /// reports the touch from the moment it lands, which a long press does not, so the hold's
    /// timer runs here.
    private var touchBook: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touches) { _, touches, _ in touches = true }
            .onChanged { value in
                let size = viewport?.size ?? .zero
                switch touch {
                case nil where Self.turnsView:
                    touch = .turning
                case nil:
                    touch = .pressing(
                        hold: PileCarry.picksUpOnDrag
                            ? nil
                            : pickUp(at: value.startLocation, in: size, after: PileCarry.holdDelay))
                case .pressing(let hold) where Self.wandered(value):
                    hold?.cancel()
                    touch =
                        PileCarry.picksUpOnDrag
                        ? .lifting(pickUp(at: value.startLocation, in: size)) : .idle
                case .holding: scene.carry(to: value.location, in: size)
                case .turning:
                    scene.moveCamera(
                        magnification: 1,
                        rotation: .radians(
                            Double(value.translation.width * PilePointer.turnPerPoint)),
                        focus: nil, in: size)
                default: break
                }
            }
            .onEnded { value in
                let size = viewport?.size ?? .zero
                #if os(macOS)
                    pointerSpot.location = value.location
                #endif
                switch touch {
                case .pressing(let hold):
                    hold?.cancel()
                    if !Self.wandered(value) { tap(at: value.startLocation, in: size) }
                case .lifting(let lift): lift.cancel()
                case .holding:
                    scene.throwBook(velocity: value.velocity, at: value.location, in: size)
                    DeskTips.thrown()
                case .turning:
                    scene.endCameraMove()
                    DeskTips.cameraMoved()
                default: break
                }
                touch = nil
            }
    }

    /// Picks up the book under `point`, in a view of `size`, after `delay`, once the desk's
    /// view can find it, and carries it from then on. A point over no book leaves the touch
    /// idle.
    private func pickUp(at point: CGPoint, in size: CGSize, after delay: Duration = .zero)
        -> Task<Void, Never>
    {
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            await desk.awake()
            guard !Task.isCancelled else { return }
            if scene.pickUp(at: point, in: size, gentle: reduceMotion) {
                touch = .holding
                pickups += 1
                DeskTips.pickedUp()
            } else {
                touch = .idle
            }
        }
    }

    /// Whether a touch moved too far to be a tap or a hold.
    private static func wandered(_ value: DragGesture.Value) -> Bool {
        hypot(value.translation.width, value.translation.height) > PileCarry.slop
    }

    /// Ends a touch that SwiftUI cancelled, dropping a held book where it is. After `onEnded`,
    /// this finds nothing left to do.
    private func endTouch() {
        switch touch {
        case .pressing(let hold): hold?.cancel()
        case .lifting(let lift): lift.cancel()
        case .turning: scene.endCameraMove()
        default: break
        }
        touch = nil
        scene.endDrag()
    }

    #if os(macOS)
        /// Zooms or turns the view for a scroll at `point` over the part of the desk the bars
        /// leave clear, and returns whether it did; scrolls elsewhere, such as over the
        /// sidebar, or while details or a sheet cover the desk, go on to the views under them.
        private func scroll(_ event: NSEvent, at point: CGPoint) -> Bool {
            guard isShown, details.lift == nil, !sharesPile, coverBook == nil, let viewport
            else { return false }
            let insets = viewport.insets
            let clear = CGRect(
                x: insets.leading, y: insets.top,
                width: viewport.size.width - insets.leading - insets.trailing,
                height: viewport.size.height - insets.top - insets.bottom)
            guard clear.contains(point) else { return false }
            // As the device moved, whichever way the reader's scrolling setting turns it.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
            let move = PilePointer.move(
                deltaX: event.scrollingDeltaX * sign, deltaY: event.scrollingDeltaY * sign,
                precise: event.hasPreciseScrollingDeltas,
                shift: event.modifierFlags.contains(.shift))
            desk.moveCamera(
                magnification: move.magnification, rotation: move.rotation, focus: point)
            DeskTips.cameraMoved()
            return true
        }
    #endif

    /// Opens the book under a tap at `point` once the desk's view can find it. A tap on a paused
    /// desk wakes it, if the touch did not already, and the returning view takes a few frames
    /// before the scene's rays find books.
    private func tap(at point: CGPoint, in size: CGSize) {
        Task {
            await desk.awake()
            openBook(at: point, in: size)
        }
    }

    private func openBook(at point: CGPoint, in size: CGSize) {
        guard let entity = scene.book(at: point, in: size), let id = scene.bookID(for: entity),
            let book = books.first(where: { $0.id == id })
        else { return }
        show(book)
    }

    /// Lifts `book` out of the pile to its details, or pushes them with Reduce Motion on or
    /// when the pile cannot lift it. Does nothing while another book flies.
    private func show(_ book: CloudBook) {
        details.open(book, from: scene, reduceMotion: reduceMotion) {
            showsBook = true
            open(book)
        }
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

    /// The `UserDefaults` key of the 3D views' time frame, which `DeskView` reads and
    /// `FrameChip` sets.
    static let pileSettingKey = "BookwormsPileFrame"
    /// The saved time frame until the reader chooses one: the current year.
    static var defaultPileSetting: String { thisYear.setting }

    /// The pile's frame for a saved setting, or `nil` for every book, which an empty setting
    /// names. No menu saves "lifetime", but a launch argument can, so it names every book too.
    ///
    /// A saved year or month in which no book was finished, such as one from another library,
    /// gives way to the newest year or month that has one, so the pile keeps the reader's kind
    /// of frame.
    static func pileFrame(setting: String, in books: [CloudBook]) -> TimeFrame? {
        guard let saved = TimeFrame(setting: setting), saved != .lifetime else { return nil }
        let periods = periods(in: books)
        switch saved {
        case .year(let year) where !periods.years.contains(year):
            return periods.years.first.map(TimeFrame.year)
        case .month where !periods.months.contains(saved): return periods.months.first
        default: return saved
        }
    }
}

/// Where the Desk scene's tips point (`DeskTips`): at the book nearest the view's middle,
/// while the desk rests. It tells the tips' rules when the desk rests, so a tip shows only over
/// the resting pile's still and goes when the desk wakes or Desk leaves the screen, and it
/// finds its book once per rest.
private struct PileTipAnchor: View {
    let desk: DeskScenes
    let size: CGSize?

    /// How to pick up a book, then how to move the camera once two books have been thrown.
    @State private var tips = TipGroup(.ordered) {
        PickUpTip()
        TurnTip()
    }

    var body: some View {
        let rests = desk.isPaused && desk.mode == .desk && size != nil
        TipAnchor(
            tip: tips.currentTip,
            point: rests ? size.flatMap { desk.pile.middleBookPoint(in: $0) } : nil
        )
        .onChange(of: rests, initial: true) { PickUpTip.deskRests = rests }
        .onDisappear { PickUpTip.deskRests = false }
    }
}

#if os(macOS)
    /// The Mac's pointer over the Desk scene: an open hand over a book and a closed one while
    /// it carries one, and the context menu of the book under it. Books are found from their
    /// poses (`BookPileScene.bookID(under:in:)`), so hovering never wakes a paused desk, and the
    /// view updates only when the pointer passes onto another book or off one.
    ///
    /// macOS reports no hovering during a press, or while books move under a pointer that
    /// stays still. So once a press ends, which may have thrown the book or turned the view,
    /// the pointer names no book until it moves, and it finds its book again when the desk
    /// rests or wakes.
    private struct DeskPointer: ViewModifier {
        /// Where the pointer last was over the desk, as hovering and the end of a press report
        /// it: a plain reference, so moving the pointer updates no view.
        final class Spot {
            var location: CGPoint?
        }

        let desk: DeskScenes
        let books: [CloudBook]
        let size: CGSize?
        let spot: Spot
        /// Whether the pointer's button is down over the desk.
        let presses: Bool
        /// Whether the pointer carries a book.
        let carries: Bool
        let open: (CloudBook) -> Void
        let changeCover: (CloudBook) -> Void

        @State private var hovered: Int?

        func body(content: Content) -> some View {
            content
                .onContinuousHover { phase in
                    if case .active(let point) = phase {
                        spot.location = point
                    } else {
                        spot.location = nil
                    }
                    findHovered()
                }
                .onChange(of: presses) { if !presses { hovered = nil } }
                .onChange(of: desk.isPaused) { findHovered() }
                .pointerStyle(carries ? .grabActive : hovered == nil ? nil : .grabIdle)
                .contextMenu {
                    if let book = hovered.flatMap({ id in books.first { $0.id == id } }) {
                        BookMenuItems(book: book, open: open, changeCover: changeCover)
                    }
                }
        }

        /// Finds the book under the pointer's last spot.
        private func findHovered() {
            var id: Int?
            if let point = spot.location, let size {
                id = desk.pile.bookID(under: point, in: size)
            }
            if id != hovered { hovered = id }
        }
    }
#endif
