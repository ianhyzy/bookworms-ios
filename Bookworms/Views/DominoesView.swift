import RealityKit
import SwiftUI

/// The time frame's books as dominoes: they stand on end along a winding path in finish order,
/// evenly spaced (`DominoLayout`), and a cobweb hangs between two books wherever 30 days or more
/// passed between their finishes (`DominoLayout.cobwebDays`). While a new chain's first books get
/// ready, a spinner shows over the table (`SceneLoading`); then the books drop into their places
/// from above the top of the screen (see `DominoScene`).
///
/// A pointing hand floats before the first book, as a finger about to poke it; a tap on the
/// hand or the book topples the whole chain, tearing the cobwebs as it goes. Should the chain
/// stop, such as where a book leans on the next without knocking it over, the hand points at
/// the book to tap to nudge it on. A tap on any book the chain has not reached also pushes it
/// on. Tapping a book the chain has passed, or touching and holding any
/// book, lifts it out of the chain to its details over the darkened scene, as the Pile does
/// (`LiftedDetails`), and **Back** returns it (see `DominoScene`). With Reduce Motion on, or when
/// the scene cannot lift the book, `open` pushes the details instead, and the chain is as the
/// reader left it on return.
/// **Camera** in the desk's options menu chooses how the camera films the chain
/// (`DominoCameraMode`). Pinch to zoom, and drag to look along the path; either takes the
/// camera over until the next push. **Set up again** stands every book again.
/// Collisions play taps and, while the desk's **Sounds** is on, clacks (`ImpactFeedback`).
///
/// The scene's view lives only while Desk is on screen (`DeskSceneView`), so a hidden tab runs
/// no frame loop; the scene keeps its books, so the chain is as the reader left it on return,
/// standing or fallen. Leaving stops the haptic and audio engines, and leaving other than for
/// details, such as for another tab, puts a lifted book back at once. A memory warning while
/// the tab is hidden frees the books and textures, and they stand again on return. While a
/// pile image renders, the scene leaves the view and a lifted book goes back, as
/// `BookPileView` explains.
struct DominoesView: View {
    let books: [CloudBook]
    /// The name of the books' time frame.
    let title: String
    /// The details of a book lifted out of the chain, which the desk's bar also reads.
    let details: LiftedDetails
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Set by **Sounds** in the desk's options menu.
    @AppStorage("BookwormsThreeDSounds") private var sounds = true
    /// Set by **Camera** in the desk's options menu.
    @AppStorage("BookwormsDominoCamera") private var cameraMode = DominoCameraMode.overview
    @State private var scene = DominoScene()
    @State private var viewport: PileViewport?
    /// The scene's frame in global coordinates, which the details' book frame converts from.
    @State private var canvas = CGRect.zero
    /// Counts **Set up again** presses; each stands the books again.
    @State private var generation = 0
    /// Set while pushed details cover the chain, or while the lifted book's details wait for
    /// the reader to return from the Share tab, so leaving keeps it.
    @State private var showsBook = false
    /// Set between `onAppear` and `onDisappear`. The view stays in the hierarchy under a pushed
    /// book or in a tab that is not selected.
    @State private var isShown = false
    /// Set while fingers move the camera, and reset when they lift.
    @GestureState private var movesCamera = false
    /// Where the current touch started, for a touch and hold, which `LongPressGesture` does not
    /// locate.
    @GestureState private var touch: CGPoint?

    private struct SetUpRequest: Equatable {
        let ids: [Int]
        let generation: Int
        let viewport: PileViewport?
    }

    var body: some View {
        DeskSceneView { view in
            scene.attach(to: view)
            if PileSnapshotRenderer.isRendering { scene.detach() }
        }
        // A SwiftUI layer takes the touches: gestures on the hosted view would not fire.
        .overlay {
            Color.clear
                .contentShape(.rect)
                .gesture(touchBook)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .updating($touch) { value, touch, _ in
                            touch = value.startLocation
                        }
                )
                .simultaneousGesture(moveCamera)
        }
        .allowsHitTesting(details.lift == nil)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            canvas = $0
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Dominoes of \(count)")
        .accessibilityValue("\(title). \(cobwebs)\(status)")
        .accessibilityHint("To go through books one at a time, open Library.")
        .accessibilityActions {
            if scene.status.phase.waitsForPush {
                Button("Push the next book") { scene.pushNext() }
            }
            Button("Set up again") { generation += 1 }
        }
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
        }
        .task(id: SetUpRequest(ids: books.map(\.id), generation: generation, viewport: viewport)) {
            guard let viewport else { return }
            scene.planSetUp(books, generation: generation, viewport: viewport)
            // A new chain, such as one without the lifted book, removed it.
            if let lift = details.lift, scene.lifter.liftedID != lift.book.id {
                details.putBack(scene)
            }
            await scene.setUp(books, generation: generation, viewport: viewport, model: model)
            #if DEBUG
                await details.openDebugBook(in: books, scene: scene) { show($0) }
            #endif
        }
        .onAppear {
            showsBook = false
            isShown = true
        }
        .onDisappear {
            isShown = false
            scene.endCameraMove()
            // `onChange(of: playsFeedback)` does not run for a view that is being removed.
            scene.feedback.stop()
            if !showsBook { details.putBack(scene) }
        }
        // Leaves the view nothing to draw while a pile image renders, in whichever tab, and
        // puts the scene back when it ends.
        .onChange(of: PileSnapshotRenderer.isRendering) { _, isRendering in
            if isRendering {
                details.putBack(scene)
                scene.detach()
            } else {
                scene.reattach()
            }
        }
        // The books and their textures are the chain's only large memory; a hidden chain gives
        // them up under pressure and stands again on return.
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification)
        ) { _ in
            guard !isShown else { return }
            details.putBack(scene)
            scene.release()
        }
        .onChange(of: sounds, initial: true) { scene.feedback.playsSounds = sounds }
        // Keeps the haptic and audio engines only while collisions can be seen.
        .onChange(of: playsFeedback, initial: true) {
            if playsFeedback { scene.feedback.start() } else { scene.feedback.stop() }
        }
        .onChange(of: reduceMotion, initial: true) { scene.setReduceMotion(reduceMotion) }
        .onChange(of: cameraMode, initial: true) { old, new in
            scene.setCameraMode(new, blends: old != new)
        }
        .onChange(of: movesCamera) { if !movesCamera { scene.endCameraMove() } }
        .onChange(of: scene.status.phase) {
            // Physics runs on under details, which VoiceOver reads instead.
            guard isShown, details.lift == nil else { return }
            switch scene.status.phase {
            case .stalled, .done: AccessibilityNotification.Announcement(status).post()
            default: break
            }
        }
        .toolbar {
            if details.lift == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Set up again", systemImage: "arrow.counterclockwise") {
                        generation += 1
                    }
                }
            }
        }
        // Outside the viewport reading, so the path starts below the button, which hides with
        // the other controls while a lifted book's details show.
        .safeAreaInset(edge: .top, spacing: 0) {
            if details.lift == nil {
                FrameChip(title: title, shown: chainLength, total: books.count)
            }
        }
    }

    /// The chain's phase as VoiceOver reads it.
    private var status: String {
        switch scene.status.phase {
        case .settingUp: "Setting up."
        case .standing: "Standing. Push the first book to start the chain."
        case .running: "Falling."
        case .stalled(let fallen):
            "Stopped after \(fallen) of \(chainLength) books. Push the next book to go on."
        case .done: "Every book has fallen."
        }
    }

    /// How many cobwebs the chain has, as VoiceOver reads it before the status, or nothing for
    /// none.
    private var cobwebs: String {
        switch scene.status.cobwebs {
        case 0: ""
        case 1: "A cobweb marks a gap of \(DominoLayout.cobwebDays) days or more between finishes. "
        case let count:
            "\(count) cobwebs mark gaps of \(DominoLayout.cobwebDays) days or more between finishes. "
        }
    }

    private var playsFeedback: Bool { isShown && scenePhase == .active }

    private var chainLength: Int { min(books.count, DominoLayout.maximumBooks) }

    /// The number of books, such as "39 books", or "300 of 1,024 books" past the most a chain
    /// stands.
    private var count: String { FrameChip.books(chainLength, of: books.count) }

    /// A tap pushes the chain on or lifts a book it has passed to its details (see
    /// `DominoScene.tap(at:in:)`); touching and holding lifts any book. Both find the book with
    /// the scene's own ray, which also finds a standing book's glow around it.
    private var touchBook: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .exclusively(before: SpatialTapGesture())
            .onEnded { value in
                let size = viewport?.size ?? .zero
                switch value {
                case .first: showDetails(touch.flatMap { scene.bookID(at: $0, in: size) })
                case .second(let tap): showDetails(scene.tap(at: tap.location, in: size))
                }
            }
    }

    private func showDetails(_ id: Int?) {
        guard let id, let book = books.first(where: { $0.id == id }) else { return }
        show(book)
    }

    /// Lifts `book` out of the chain to its details, or pushes them with Reduce Motion on or
    /// when the scene cannot lift it. Does nothing while another book flies.
    private func show(_ book: CloudBook) {
        details.open(book, from: scene, reduceMotion: reduceMotion) {
            showsBook = true
            open(book)
        }
    }

    /// Pinches zoom toward the fingers; a one-finger drag slides along the path.
    private var moveCamera: some Gesture {
        DragGesture(minimumDistance: 10)
            .simultaneously(with: MagnifyGesture())
            .updating($movesCamera) { _, moves, _ in moves = true }
            .onChanged { value in
                let pinch = value.second
                scene.moveCamera(
                    translation: pinch == nil ? value.first?.translation ?? .zero : .zero,
                    magnification: pinch?.magnification ?? 1, focus: pinch?.startLocation,
                    in: viewport?.size ?? .zero)
            }
    }
}
