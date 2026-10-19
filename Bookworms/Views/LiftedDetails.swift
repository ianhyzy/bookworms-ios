import SwiftUI

/// The details of a book that a 3D view lifts out of its scene, and the sequence that opens and
/// closes them, for `BookPileView` and `DominoesView`. `DeskView` keeps it, so the desk's bar
/// gives way to the details' **Back** and **Share** while they show.
///
/// A tap lifts the book (see `LiftingScene`). The details join the hierarchy at once, hidden,
/// since the book flies to their stand-in's frame, and fade in once it lands. **Back** fades
/// them out, then returns the book. Each lift and return counts, so a task that an earlier one
/// started cannot change a later one.
@MainActor
@Observable
final class LiftedDetails {
    struct Lift: Equatable {
        let book: CloudBook
        /// Whether the details show: set once the book lands, and cleared by **Back**.
        var showsText = false
        /// Set by **Back** while the details fade out, before the book returns.
        var isReturning = false
    }

    /// The lifted book, from the tap until **Back** returns it.
    private(set) var lift: Lift?
    /// The book of the latest lift, which stays after **Back**, so a design change committed
    /// as its details close still reaches the scene's textures.
    private(set) var lastLifted: CloudBook?
    /// Counts lifts and returns.
    @ObservationIgnored private var revision = 0

    /// Lifts `book` out of `scene` to its details, or calls `push` to push them with Reduce
    /// Motion on or when the scene cannot lift the book. Does nothing while another book flies.
    func open(
        _ book: CloudBook, from scene: any LiftingScene, reduceMotion: Bool, push: () -> Void
    ) {
        guard lift == nil, !scene.lifter.isFlying else { return }
        guard !reduceMotion, let landing = scene.lift(book.id) else { return push() }
        revision &+= 1
        let revision = revision
        lift = Lift(book: book)
        lastLifted = book
        Task {
            try? await Task.sleep(for: .seconds(landing))
            guard self.revision == revision else { return }
            withAnimation(.easeOut(duration: 0.25)) { lift?.showsText = true }
            AccessibilityNotification.ScreenChanged(nil).post()
            #if DEBUG
                // Simulator hook: `-BookwormsPileBack <seconds>` goes back that long after the
                // details appear.
                guard
                    let delay = UserDefaults.standard.string(forKey: "BookwormsPileBack")
                        .flatMap(Double.init)
                else { return }
                try? await Task.sleep(for: .seconds(delay))
                if self.revision == revision { close(scene) }
            #endif
        }
    }

    /// **Back**: fades the details out, then gives the scene its controls again and returns
    /// the book.
    ///
    /// The bars change and the details leave the hierarchy together, after the fade. That can
    /// hold up the screen for a moment, which the book waits out before it leaves (see
    /// `BookLifter.throwBack`), so the stall shows as a pause rather than a skipped throw.
    func close(_ scene: any LiftingScene) {
        guard let current = lift, !current.isReturning else { return }
        revision &+= 1
        let revision = revision
        lift?.isReturning = true
        func throwBack() {
            lift = nil
            scene.throwBack()
            AccessibilityNotification.ScreenChanged(nil).post()
        }
        // Before the book lands, the details have not appeared.
        guard current.showsText else { return throwBack() }
        withAnimation(.easeIn(duration: 0.2)) {
            lift?.showsText = false
        } completion: { [self] in
            if self.revision == revision { throwBack() }
        }
    }

    /// Closes the details at once, if they show, and puts a lifted or returning book back in
    /// `scene`.
    func putBack(_ scene: any LiftingScene) {
        scene.dropLifted()
        guard lift != nil else { return }
        revision &+= 1
        lift = nil
    }

    #if DEBUG
        /// Whether `-BookwormsOpenBook` has opened its book, which it does once per launch.
        private static var openedDebugBook = false

        /// Simulator hook: `-BookwormsOpenBook <book ID>` opens that book of `books` through
        /// `show`, as a tap does, four seconds after the scene is ready, and
        /// `-BookwormsOpenBook buried` opens the book with the most books over it.
        func openDebugBook(
            in books: [CloudBook], scene: any LiftingScene, show: (CloudBook) -> Void
        ) async {
            guard !Self.openedDebugBook,
                let value = UserDefaults.standard.string(forKey: "BookwormsOpenBook")
            else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            let id = value == "buried" ? scene.mostBuriedID() : Int(value)
            guard let book = books.first(where: { $0.id == id }) else { return }
            Self.openedDebugBook = true
            show(book)
        }
    #endif
}

/// Shows the details of `details`' lifted book over a 3D scene: hides the scene from VoiceOver,
/// offers **Back** and the book's **Share** in the bar, and draws the lifted book as sharply as
/// the details' own book, with its current cover and design.
///
/// The details' own book is a transparent stand-in that places and turns the scene's book, so
/// the same model scrolls and turns with the details. A scroll view's edge effect darkens the
/// tab bar's glass even while the details are hidden, so it shows only while the details do,
/// over the darkened veil. Removing the details with the effect showing leaves the tab bar dark
/// over the lit scene, so it goes when they start to fade.
struct LiftedDetailsOverlay: ViewModifier {
    let details: LiftedDetails
    let scene: any LiftingScene
    /// The scene's frame in global coordinates, which the details' book frame converts from.
    let canvas: CGRect
    /// Called before the book's **Share** opens the Share tab, so the view keeps the details
    /// and the scene for the reader's return, as pushed details stay.
    let keep: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale

    /// What the lifted book's textures show.
    private struct Dressing: Equatable {
        let book: CloudBook
        let look: SpineLook
    }

    private var dressing: Dressing? { details.lift.map { dressing(of: $0.book) } }

    /// What the scene's textures of the latest lifted book show, in the pile or in flight.
    private var sceneDressing: Dressing? { details.lastLifted.map(dressing(of:)) }

    private func dressing(of lifted: CloudBook) -> Dressing {
        let book = model.books.first { $0.id == lifted.id } ?? lifted
        return Dressing(book: book, look: model.look(for: book))
    }

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(details.lift.map { !$0.isReturning } ?? false)
            .overlay {
                if let lift = details.lift { overlay(lift) }
            }
            .task(id: dressing) {
                guard let dressing else { return }
                await scene.lifter.dress(dressing.book, scale: displayScale, model: model)
            }
            .task(id: sceneDressing) {
                guard let sceneDressing else { return }
                await scene.lifter.restyle(sceneDressing.book, model: model)
            }
            .focusedSceneValue(
                \.goBack,
                details.lift?.isReturning == false ? SceneAction { details.close(scene) } : nil,
                in: .desk
            )
            .toolbar {
                if let lift = details.lift {
                    ToolbarItem(placement: .topBarLeading) {
                        // Escape goes back too, without the keyboard focus that an exit command
                        // needs; Command-[ is **Go > Back**.
                        Button("Back", systemImage: "chevron.backward") { details.close(scene) }
                            .keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Share", systemImage: "square.and.arrow.up") {
                            keep()
                            model.share(lift.book)
                        }
                    }
                }
            }
    }

    private func overlay(_ lift: LiftedDetails.Lift) -> some View {
        BookDetailView(
            book: lift.book,
            hostedBook: HostedBook(
                place: { [scene, canvas] frame in
                    scene.lifter.place(
                        frame.offsetBy(dx: -canvas.minX, dy: -canvas.minY), in: canvas.size)
                },
                turn: { [scene] in scene.lifter.turn($0) }, hasLanded: lift.showsText)
        )
        .scrollEdgeEffectHidden(!lift.showsText)
        .opacity(lift.showsText ? 1 : 0)
        .allowsHitTesting(lift.showsText)
        .accessibilityHidden(!lift.showsText)
        // Pushed details close with VoiceOver's escape gesture through the navigation stack.
        .accessibilityAction(.escape) { details.close(scene) }
    }
}
