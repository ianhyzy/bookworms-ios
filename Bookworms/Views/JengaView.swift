import RealityKit
import SwiftUI

/// The time frame's books as a tower to take apart, as in the game of Jenga.
///
/// Up to `JengaLayout.maximumBooks` books, the first in the shelf's order, stand in a
/// crisscross tower on the desk, the earliest finished at the bottom (see
/// `JengaLayout.tower`). Drag a book along its length to slide it out: it stays a physics body,
/// pulled toward the finger with a capped force, so it grinds against the books around it and
/// can bring the tower down. While a finger holds a book, its title and the reader's rating
/// show under the navigation bar. Touch and hold a book to push its details, pinch to zoom,
/// and turn two fingers to circle the tower; a pinch or turn lets go of a held book.
/// **Rebuild** stacks the tower again, and so does a change to which books are stacked. Either
/// keeps the camera's turn and zoom.
///
/// Collisions, grinding, and the tower's fall play haptic taps and, while the shelf's
/// **Sounds** is on, knocks (`ImpactFeedback`), only while the tower shows in the active app.
/// Returning from pushed details finds the tower as the reader left it. The fall is checked
/// only while the tower shows, so a fall behind the details plays on the reader's return.
/// Leaving the tower any other way, such as for another tab, frees the books and their
/// textures, and the tower is built again on the reader's return. With Reduce Motion on, no
/// dust drifts in the lamp's beam; the tower moves only when the reader moves it.
///
/// While any pile image renders (`PileSnapshotRenderer.isRendering`), the tower leaves the
/// view's scene, for the reason `BookPileView` gives.
struct JengaView: View {
    let books: [CloudBook]
    /// The name of the books' time frame.
    let title: String
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Set by **Sounds** in the shelf's **Sort and filter** menu.
    @AppStorage("BookwormsThreeDSounds") private var sounds = true
    @State private var scene = JengaScene()
    @State private var viewport: PileViewport?
    /// Counts **Rebuild** presses; each builds the tower again.
    @State private var generation = 0
    /// The book under the finger, whose title and rating show.
    @State private var held: CloudBook?
    /// Set while pushed details cover the tower, so leaving keeps it.
    @State private var showsBook = false
    /// Set between `onAppear` and `onDisappear`. The view stays in the hierarchy under pushed
    /// details or in a tab that is not selected.
    @State private var isShown = false
    /// Set while a finger holds a book, and reset by SwiftUI when the drag ends or is
    /// cancelled, so the book is let go either way.
    @GestureState private var holdsBook = false
    @GestureState private var movesCamera = false
    /// Set when a pinch or turn starts while a finger holds a book, so the rest of that drag
    /// slides nothing, even if one finger stays down after the pinch.
    @State private var slideIsCancelled = false

    /// Keyed on the set of stacked books, not their shelf order, which a synced rating or a new
    /// sort can change without changing the tower.
    private struct BuildRequest: Equatable {
        let ids: Set<Int>
        let generation: Int
        let hasViewport: Bool
    }

    var body: some View {
        let stacked = Array(books.prefix(JengaLayout.maximumBooks))
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
        // The press runs alongside the drag: attached with `gesture`, it would wait for the drag
        // to fail, and combined with `exclusively(before:)`, the drag never starts.
        .gesture(slideBook)
        .simultaneousGesture(openBook)
        .simultaneousGesture(moveCamera)
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Tower of \(count)")
        .accessibilityValue(title)
        .accessibilityHint(
            "Drag a book along its length to slide it out, or touch and hold one for its details. To go through books one at a time, choose Stack or Shelf."
        )
        .accessibilityAction(named: "Rebuild") { generation += 1 }
        .overlay(alignment: .top) {
            if let held {
                HeldBookLabel(book: held)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: held?.id)
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
            scene.frame($0)
        }
        .task(
            id: BuildRequest(
                ids: Set(stacked.map(\.id)), generation: generation, hasViewport: viewport != nil)
        ) {
            guard viewport != nil else { return }
            await scene.build(stacked, generation: generation, model: model)
        }
        .onAppear {
            showsBook = false
            isShown = true
            scene.isShown = true
            #if DEBUG
                scene.debugHold = { id in held = id.flatMap { id in books.first { $0.id == id } } }
            #endif
        }
        .onDisappear {
            isShown = false
            scene.isShown = false
            scene.endSlide()
            held = nil
            // A view removed from the hierarchy, such as for another 3D view, gets no
            // `playsFeedback` change, so this releases the engines and the audio session.
            scene.feedback.stop()
            guard !showsBook else { return }
            scene.release()
        }
        .onChange(of: PileSnapshotRenderer.isRendering) { _, isRendering in
            guard isRendering else { return }
            scene.endSlide()
            scene.root.removeFromParent()
        }
        .onChange(of: sounds, initial: true) { scene.feedback.playsSounds = sounds }
        // Keeps the haptic and audio engines only while collisions can be seen.
        .onChange(of: playsFeedback, initial: true) {
            if playsFeedback { scene.feedback.start() } else { scene.feedback.stop() }
        }
        .onChange(of: reduceMotion, initial: true) { scene.setDust(!reduceMotion) }
        .onChange(of: holdsBook) {
            guard !holdsBook else { return }
            scene.endSlide()
            held = nil
            slideIsCancelled = false
        }
        .onChange(of: holdsBook && movesCamera) { _, both in
            guard both else { return }
            scene.endSlide()
            held = nil
            slideIsCancelled = true
        }
        .onChange(of: movesCamera) { if !movesCamera { scene.endCameraMove() } }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Rebuild", systemImage: "arrow.counterclockwise") { generation += 1 }
            }
            // Names the time frame, which the toolbar's menu saves across launches.
            ToolbarItem(placement: .subtitle) {
                Text("\(title) · \(count)")
            }
        }
    }

    private var playsFeedback: Bool { isShown && scenePhase == .active }

    /// The number of books, such as "39 books", or "54 of 120 books" past the tower's maximum.
    private var count: String {
        if books.count > JengaLayout.maximumBooks {
            return "\(JengaLayout.maximumBooks) of \(books.count.formatted()) books"
        }
        return books.count == 1 ? "1 book" : "\(books.count.formatted()) books"
    }

    /// Touch and hold pushes a book's details. A finger that moves more than 3 points first
    /// fails the press, before it moves the 4 points that start `slideBook`, so a slow pull
    /// slides the book rather than opening it. A finger that moves after the press succeeds
    /// slides nothing.
    private var openBook: some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 3)
            .targetedToAnyEntity()
            .onEnded { value in
                guard !movesCamera, let id = scene.bookID(for: value.entity),
                    let book = books.first(where: { $0.id == id })
                else { return }
                showsBook = true
                open(book)
            }
    }

    private var slideBook: some Gesture {
        DragGesture(minimumDistance: 4)
            .targetedToAnyEntity()
            .updating($holdsBook) { _, holds, _ in holds = true }
            .onChanged { value in
                guard !movesCamera, !slideIsCancelled, !showsBook else { return }
                let id = scene.slide(
                    value.entity,
                    from: value.ray(through: value.startLocation, in: .local, to: .scene),
                    to: value.ray(through: value.location, in: .local, to: .scene))
                if let id, held?.id != id { held = books.first { $0.id == id } }
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

/// The held book's title and the reader's rating, under the navigation bar.
///
/// It is hidden from VoiceOver, which reads the tower as one element and cannot hold a book.
private struct HeldBookLabel: View {
    let book: CloudBook

    var body: some View {
        VStack(spacing: 4) {
            Text(book.title)
                .font(.headline)
                .fontDesign(.serif)
                .lineLimit(2)
            if let rating = book.rating, rating > 0 {
                RatingStars(rating: rating)
                    .font(.subheadline)
            } else {
                Text("Not rated")
                    .font(.subheadline)
                    .foregroundStyle(ShelfPalette.paper.opacity(0.7))
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(ShelfPalette.paper)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
