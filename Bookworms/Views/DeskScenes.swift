import Combine
import RealityKit
import SwiftUI

/// A book as one desk scene hands it to the other: its pose under the scene's root, and how it
/// moves.
struct DeskBook {
    let id: Int
    let transform: Transform
    let motion: PhysicsMotionComponent
}

/// The books one desk scene hands to the other, and the camera's view, which the other takes.
struct DeskHandover {
    let books: [DeskBook]
    let camera: Transform
}

/// The Desk tab's two scenes, which share one desk, one set of book parts, and one `ARView`:
/// the Desk scene (`BookPileScene`), the pile of books to grab and throw, and the dominoes
/// (`DominoScene`) that the desk's books set up.
///
/// **Dominoes** in the bar (`setUpDominoes(books:reduceMotion:)`) hands the books on the desk, as
/// they lie, to the dominoes, which set themselves up from there. **Back to desk**
/// (`backToDesk(books:tidy:periods:)`) hands the dominoes' books back, wherever they lie,
/// standing, fallen, or gathered, as the desk's arrangement. Each handover swaps the scenes in the
/// view between two frames, while the desk, the lamp, the books, and the camera stay as they were,
/// so the eye sees one scene go on.
///
/// The scenes share the desk so its lamp and table stay as they are across a swap, and share
/// the book parts so the receiving scene builds its books at once, without drawing textures
/// again. They stay separate scenes because they share little else: the pile's walls, carrying,
/// tilt, and box on one side, and the chain's path, cameras, recording, and finale on the other.
/// The scene that does not show holds no books.
///
/// Once the scene that shows rests (`DeskStage.rest`), the desk pauses: it takes a still of the
/// view, shows the still in its place, and drops the view, which ends RealityKit's frame loop,
/// since RealityKit has no public way to pause an `ARView` or lower its frame rate. Both scenes
/// rest the same way, the lamp's dust fading out first; the dominoes rest only once the books
/// lie gathered and the recording is written, since the recording, the hand, and the clock
/// need every frame until then. A touch or any change to the scene wakes it (`wake()`): the
/// view returns over the still, which stays until the view has drawn, so the swap does not
/// show.
@MainActor
@Observable
final class DeskScenes {
    /// Which scene shows.
    enum Mode {
        case desk, dominoes
    }

    private(set) var mode = Mode.desk
    /// Set while the Desk scene's share sheet covers it, so no view draws the scenes.
    var hidesView = false
    /// Count **Drop again** and **Set up again** presses; each drops or sets up the books again.
    var pileGeneration = 0
    var dominoGeneration = 0
    /// The view the scenes show in, with the bars over it, which the scenes' views report. A
    /// new size wakes a paused desk, whose still has the old one.
    @ObservationIgnored var viewport: PileViewport? {
        didSet { if viewport != oldValue { wake() } }
    }
    /// Set under heat or in Low Power Mode, when the desk draws no dust and no soft shadows
    /// under the books (see `updatePowerState()`).
    @ObservationIgnored private var reducesEffects = false
    /// Set while the scene that shows rests and its still shows in place of the view.
    private(set) var isPaused = false
    /// The view as the scene came to rest, which shows while the desk pauses and under the view
    /// as it returns, until it draws. A full-screen still takes about 13 MB.
    private(set) var still: UIImage?
    /// Where the push tip points (`PushTip`), in the scenes' points: the dominoes' pointing
    /// hand, which `DominoesView` finds once the chain waits for its first push with the camera
    /// at rest.
    var pushTipPoint: CGPoint?

    let pile: BookPileScene
    /// The dominoes, made the first time they are needed, since the desk opens on the pile.
    var dominoes: DominoScene {
        if let madeDominoes { return madeDominoes }
        let made = DominoScene(factory: factory, stage: stage)
        madeDominoes = made
        return made
    }
    @ObservationIgnored private var madeDominoes: DominoScene?
    @ObservationIgnored private let stage: DeskStage
    @ObservationIgnored private let factory: BookFactory
    @ObservationIgnored private weak var attachedView: ARView?
    /// The view that shows the scenes, or `nil` while none is in a window. A view that leaves
    /// its window waits as `SceneWindowView`'s spare, so it outlives its time on screen.
    private var view: ARView? { attachedView?.window == nil ? nil : attachedView }
    /// Counts pauses and wakes, so a still that arrives after the scene stirred is dropped.
    @ObservationIgnored private var restRequest = 0
    /// Counts a returning view's first frames, after which the still goes.
    @ObservationIgnored private var firstFrames: (any Cancellable)?
    /// Work that waits for the view a paused desk makes when it wakes.
    @ObservationIgnored private var onAttach: (() -> Void)?

    init() {
        let factory = BookFactory()
        let stage = DeskStage()
        self.stage = stage
        self.factory = factory
        pile = BookPileScene(factory: factory, stage: stage)
        factory.retextured = { [weak self] id, materials in
            self?.pile.retexture(id, materials: materials)
            self?.madeDominoes?.retexture(id, materials: materials)
        }
        stage.rest.changed = { [weak self] rests in
            if rests { self?.pause() } else { self?.resume() }
        }
    }

    /// Scenes built ahead of the Desk tab, which the tab's first view takes, and whether a view
    /// has taken scenes, after which none are built ahead.
    private static var spare: DeskScenes?
    private static var isTaken = false

    /// Builds the desk's scenes, its table and lamp, and a view ahead of the Desk tab, so the tab
    /// opens without building them, as the app does once launch settles. Does nothing once
    /// built.
    static func prewarm() {
        guard spare == nil, !isTaken else { return }
        let scenes = DeskScenes()
        scenes.stage.prepare()
        spare = scenes
        SceneWindowView.prewarm()
    }

    /// The scenes `prewarm()` built, once, or new ones.
    static func take() -> DeskScenes {
        isTaken = true
        defer { spare = nil }
        return spare ?? DeskScenes()
    }

    /// Holds a view's scenes, which it takes the first time it asks, so a view that SwiftUI
    /// makes again and drops builds none.
    @MainActor
    final class Holder {
        lazy var scenes = DeskScenes.take()
    }

    /// Shows the scene that `mode` names in `view`, the `ARView` that `DeskSceneView` makes,
    /// leaving it nothing to draw while a pile image renders (see `PileSnapshotRenderer`).
    func attach(to view: ARView) {
        attachedView = view
        switch mode {
        case .desk:
            pile.attach(to: view)
            if PileSnapshotRenderer.isRendering { pile.detach() }
        case .dominoes:
            dominoes.attach(to: view)
            if PileSnapshotRenderer.isRendering { dominoes.detach() }
        }
        // A view that returns, as from another tab, counts the scene's rest afresh, so the dust
        // drifts in again before the desk pauses.
        stage.rest.stir()
        if still != nil {
            // The scene updates before each frame draws, so by the third update the first frame
            // has drawn over the still.
            var updates = 0
            firstFrames = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                updates += 1
                guard updates >= 3, let self else { return }
                still = nil
                firstFrames = nil
            }
        }
        if let onAttach {
            self.onAttach = nil
            // Outside the view update that made the view.
            Task { onAttach() }
        }
    }

    /// Pauses the resting scene: takes a still of the view, then drops the view for it, unless
    /// the scene stirs first. While no view shows the scene, or when the still fails, the scene
    /// counts its rest again, so the pause comes `SceneRest.delay` later.
    private func pause() {
        guard !isPaused else { return }
        guard !hidesView, let view else { return stage.rest.stir() }
        restRequest += 1
        let request = restRequest
        let shown = mode
        Task {
            let image: UIImage? = await withCheckedContinuation { done in
                view.snapshot(saveToHDR: false) { done.resume(returning: $0) }
            }
            // A scene that stirred meanwhile counts its rest again on its own.
            guard request == restRequest else { return }
            guard let image, mode == shown, !hidesView else { return stage.rest.stir() }
            still = image
            isPaused = true
        }
    }

    /// Brings the view back, or keeps it, once the scene no longer rests.
    private func resume() {
        restRequest += 1
        // Each scroll and touch wakes the desk; only a change should update the views.
        guard isPaused else { return }
        isPaused = false
        // A pause that SwiftUI has not drawn yet leaves the view in its window, so no attach
        // follows: drop the still and run the waiting press now.
        guard view != nil else { return }
        still = nil
        if let onAttach {
            self.onAttach = nil
            Task { onAttach() }
        }
    }

    /// Whether a **Dominoes** or **Back to desk** press waits for the view: the desk is paused,
    /// or it woke and its view has not returned yet.
    private var awaitsView: Bool {
        isPaused || (view == nil && (still != nil || onAttach != nil))
    }

    /// Wakes a paused desk, or keeps a live one from pausing for another `SceneRest.delay`, for
    /// a touch or another change that the scene cannot see.
    func wake() {
        stage.rest.stir()
        resume()
    }

    /// Wakes the desk for a touch, and waits until a paused desk's view has drawn, for at most
    /// half a second, so the scene can find the book under the touch. Returns at once while
    /// the view shows, or when the calling task is cancelled.
    func awake() async {
        wake()
        // ponytail: polls each frame for the still to go; resume a continuation from the frame
        // count if more callers need to wait.
        let deadline = ContinuousClock.now + .milliseconds(500)
        while still != nil, !isPaused, ContinuousClock.now < deadline {
            // A cancelled caller, such as a released press, stops waiting at once.
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        }
    }

    /// Moves the camera of the scene that shows in one step, for the Mac's scroll wheel and
    /// **View** menu: zooms by `magnification` toward the table under `focus`, or under the
    /// middle of what the bars leave clear, and turns the Desk scene's view by `rotation`.
    /// Wakes a paused desk, which then shows the new view once its view has drawn. A move of
    /// the dominoes' camera takes down the push tip, since the hand it points at moves.
    func moveCamera(magnification: CGFloat, rotation: Angle = .zero, focus: CGPoint? = nil) {
        guard let viewport else { return }
        let focus = focus ?? CGPoint(x: viewport.clear.midX, y: viewport.clear.midY)
        wake()
        switch mode {
        case .desk:
            pile.moveCamera(
                magnification: magnification, rotation: rotation, focus: focus,
                in: viewport.size)
            pile.endCameraMove()
        case .dominoes:
            PushTip.chainWaits = false
            dominoes.moveCamera(
                translation: .zero, magnification: magnification, focus: focus,
                in: viewport.size)
            dominoes.endCameraMove()
        }
    }

    /// **Actual Size**: returns the Desk scene's camera to its home zoom.
    func zoomToActualSize() {
        guard mode == .desk else { return }
        wake()
        pile.zoomToActualSize()
    }

    /// Frees the Desk scene's books and textures, and its still, while Desk is out of sight.
    /// The books drop again when it next shows.
    func releasePile() {
        pile.release()
        releaseStill()
    }

    /// Frees the paused desk's still and the spare view while Desk is out of sight. Desk shows
    /// again without the still, since its scene stirs on release and its view returns.
    func releaseStill() {
        still = nil
        SceneWindowView.releaseSpare()
    }

    /// Saves power while the device asks apps to: in Low Power Mode, or while its thermal state
    /// is serious or critical. Then the desk drops its dust and the soft shadows under its
    /// books, in both scenes, until the condition passes. In Debug builds,
    /// `-BookwormsReducedEffects YES` saves power throughout.
    func updatePowerState() {
        let info = ProcessInfo.processInfo
        var reduces: Bool
        // `ThermalState` is not `Comparable`.
        switch info.thermalState {
        case .serious, .critical: reduces = true
        default: reduces = info.isLowPowerModeEnabled
        }
        #if DEBUG
            reduces = reduces || UserDefaults.standard.bool(forKey: "BookwormsReducedEffects")
        #endif
        guard reduces != reducesEffects else { return }
        reducesEffects = reduces
        stage.setReducesEffects(reduces)
        factory.setGroundingShadows(
            !reduces, under: [pile.root] + [madeDominoes?.root].compactMap { $0 })
        wake()
    }

    /// **Dominoes**: hands the books on the desk to the dominoes as the chain of `books`,
    /// the books the desk drops, which then set themselves up from where they lie, or, with
    /// `reduceMotion`, stand in their places at once. Does nothing before a view shows the desk.
    func setUpDominoes(books: [CloudBook], reduceMotion: Bool) {
        guard mode == .desk else { return }
        // A second press while the view returns waits with the first.
        if awaitsView {
            // The books go to the dominoes once the view returns.
            onAttach = { [weak self] in
                self?.setUpDominoes(books: books, reduceMotion: reduceMotion)
            }
            return wake()
        }
        guard let view, let viewport else { return }
        let handover = pile.handOff()
        pile.detach()
        dominoes.attach(to: view)
        if PileSnapshotRenderer.isRendering { dominoes.detach() }
        // The dominoes' view, which tells the scene, does not show yet.
        dominoes.setReduceMotion(reduceMotion)
        dominoGeneration += 1
        if Self.handsBooksOver {
            dominoes.receive(
                handover, books: books, generation: dominoGeneration, viewport: viewport)
        }
        pile.removeBooks()
        mode = .dominoes
    }

    /// Whether **Dominoes** hands the desk's books to the dominoes. In Debug builds,
    /// `-BookwormsDominoesFromAbove YES` keeps them back, so the chain stands up from above, as
    /// another time frame's chain does.
    private static var handsBooksOver: Bool {
        #if DEBUG
            !UserDefaults.standard.bool(forKey: "BookwormsDominoesFromAbove")
        #else
            true
        #endif
    }

    /// **Set up again**: wakes a paused desk and sets the dominoes' books up again from where
    /// they lie.
    func setUpDominoesAgain() {
        wake()
        dominoGeneration += 1
        dominoes.setUpAgain(generation: dominoGeneration)
    }

    /// **Back to desk**: hands the dominoes' books back to the Desk scene wherever they lie, as
    /// the desk's arrangement of `books`, the books the desk drops, with its drop settings,
    /// `tidy` for Reduce Motion's stacks and the drop by `periods`, so the desk keeps them
    /// rather than dropping them again (see `BookPileScene.adopt`). Discards the dominoes'
    /// recording. A paused desk hands the books back once its view returns. While no view shows
    /// the scenes, or while the dominoes have no books to hand over, as a chain still standing
    /// up from above (`DominoScene.handOff()`), it only removes the dominoes' books, and the
    /// Desk scene drops its books when it next shows.
    func backToDesk(books: [CloudBook], tidy: Bool, periods: TimeFrame?) {
        guard mode == .dominoes else { return }
        // A second press while the view returns waits with the first, so it does not drop the
        // books for want of a view.
        if awaitsView {
            onAttach = { [weak self] in
                self?.backToDesk(books: books, tidy: tidy, periods: periods)
            }
            return wake()
        }
        let handover = dominoes.handOff()
        dominoes.detach()
        if let view, let viewport {
            pile.attach(to: view)
            if PileSnapshotRenderer.isRendering { pile.detach() }
            if let handover {
                pile.adopt(
                    handover, books: books, tidy: tidy, periods: periods,
                    generation: pileGeneration, viewport: viewport)
            }
        }
        dominoes.removeBooks()
        mode = .desk
    }

    #if DEBUG
        /// Whether `-BookwormsSetUpDominoes YES` has set up the dominoes, which it does once per
        /// launch.
        private static var setUpOnLaunch = false

        /// Simulator hook: `-BookwormsSetUpDominoes YES` chooses **Dominoes** for
        /// `books` once, two seconds after the desk's first drop has landed.
        func setUpDominoesOnLaunch(books: [CloudBook], reduceMotion: Bool) async {
            guard !Self.setUpOnLaunch,
                UserDefaults.standard.bool(forKey: "BookwormsSetUpDominoes")
            else { return }
            while pile.status.isDropping, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, mode == .desk else { return }
            Self.setUpOnLaunch = true
            setUpDominoes(books: books, reduceMotion: reduceMotion)
        }
    #endif
}
