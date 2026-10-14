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
/// **Set up dominoes** (`setUpDominoes(books:)`) hands the books on the desk, as they lie, to the
/// dominoes, which set themselves up from there. **Back to desk** (`backToDesk(books:tidy:
/// periods:)`) hands the dominoes' books back, wherever they lie, standing, fallen, or gathered,
/// as the desk's arrangement. Each handover swaps the scenes in the view between two frames,
/// while the desk, the lamp, the books, and the camera stay as they were, so the eye sees one
/// scene go on.
///
/// The scenes share the desk so its lamp and table stay as they are across a swap, and share
/// the book parts so the receiving scene builds its books at once, without drawing textures
/// again. They stay separate scenes because they share little else: the pile's walls, carrying,
/// tilt, and box on one side, and the chain's path, cameras, recording, and finale on the other.
/// The scene that does not show holds no books.
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
    /// The view the scenes show in, with the bars over it, which the scenes' views report.
    @ObservationIgnored var viewport: PileViewport?

    let pile: BookPileScene
    let dominoes: DominoScene
    @ObservationIgnored private weak var view: ARView?

    init() {
        let factory = BookFactory()
        let stage = DeskStage()
        pile = BookPileScene(factory: factory, stage: stage)
        dominoes = DominoScene(factory: factory, stage: stage)
        factory.coverArrived = { [weak pile, weak dominoes] id, material in
            pile?.retexture(id, cover: material)
            dominoes?.retexture(id, cover: material)
        }
    }

    /// Shows the scene that `mode` names in `view`, the `ARView` that `DeskSceneView` makes,
    /// leaving it nothing to draw while a pile image renders (see `PileSnapshotRenderer`).
    func attach(to view: ARView) {
        self.view = view
        switch mode {
        case .desk:
            pile.attach(to: view)
            if PileSnapshotRenderer.isRendering { pile.detach() }
        case .dominoes:
            dominoes.attach(to: view)
            if PileSnapshotRenderer.isRendering { dominoes.detach() }
        }
    }

    /// **Set up dominoes**: hands the books on the desk to the dominoes as the chain of `books`,
    /// the books the desk drops, which then set themselves up from where they lie, or, with
    /// `reduceMotion`, stand in their places at once. Does nothing before a view shows the desk.
    func setUpDominoes(books: [CloudBook], reduceMotion: Bool) {
        guard mode == .desk, let view, let viewport else { return }
        let handover = pile.handOff()
        pile.detach()
        dominoes.attach(to: view)
        if PileSnapshotRenderer.isRendering { dominoes.detach() }
        // The dominoes' view, which tells the scene, does not show yet.
        dominoes.setReduceMotion(reduceMotion)
        dominoGeneration += 1
        dominoes.receive(handover, books: books, generation: dominoGeneration, viewport: viewport)
        pile.removeBooks()
        mode = .dominoes
    }

    /// **Set up again**: sets the dominoes' books up again from where they lie.
    func setUpDominoesAgain() {
        dominoGeneration += 1
        dominoes.setUpAgain(generation: dominoGeneration)
    }

    /// **Back to desk**: hands the dominoes' books back to the Desk scene wherever they lie, as
    /// the desk's arrangement of `books`, the books the desk drops, with its drop settings,
    /// `tidy` for Reduce Motion's stacks and the drop by `periods`, so the desk keeps them
    /// rather than dropping them again (see `BookPileScene.adopt`). Discards the dominoes'
    /// recording. While no view shows the scenes, it removes the dominoes' books instead, and
    /// the Desk scene drops its books when it next shows.
    func backToDesk(books: [CloudBook], tidy: Bool, periods: TimeFrame?) {
        guard mode == .dominoes else { return }
        guard let view, let viewport else {
            dominoes.detach()
            dominoes.removeBooks()
            mode = .desk
            return
        }
        let handover = dominoes.handOff()
        dominoes.detach()
        pile.attach(to: view)
        if PileSnapshotRenderer.isRendering { pile.detach() }
        pile.adopt(
            handover, books: books, tidy: tidy, periods: periods, generation: pileGeneration,
            viewport: viewport)
        dominoes.removeBooks()
        mode = .desk
    }

    #if DEBUG
        /// Whether `-BookwormsSetUpDominoes YES` has set up the dominoes, which it does once per
        /// launch.
        private static var setUpOnLaunch = false

        /// Simulator hook: `-BookwormsSetUpDominoes YES` chooses **Set up dominoes** for
        /// `books` once, two seconds after the desk's first drop finishes.
        func setUpDominoesOnLaunch(books: [CloudBook], reduceMotion: Bool) async {
            guard !Self.setUpOnLaunch,
                UserDefaults.standard.bool(forKey: "BookwormsSetUpDominoes")
            else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, mode == .desk else { return }
            Self.setUpOnLaunch = true
            setUpDominoes(books: books, reduceMotion: reduceMotion)
        }
    #endif
}
