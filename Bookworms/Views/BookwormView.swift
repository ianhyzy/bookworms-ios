import RealityKit
import SwiftUI

/// The Bookworm: the finished books of the time frame stand in a block on the desk, and a
/// cartoon worm eats through them in the order the reader finished them (`BookwormScene`).
///
/// **Restart** starts the meal over, and **Pause** stops the worm where it is. Tapping a book
/// or a segment of the worm names the book. A tally of the books and pages eaten so far shows
/// under the worm. With Reduce Motion on, the worm shows curled up after the meal at once, with
/// its tally, and no dust drifts in the lamp's beam. Collisions and bites play taps and, while
/// the shelf's **Sounds** is on, sounds, only while the view shows in the active app. Leaving
/// the view releases the books and their textures, and the meal starts over on return.
///
/// As `BookPileView` does, the view takes its entities out of its scene while a pile image
/// renders, since RealityKit's render thread can crash drawing them meanwhile.
struct BookwormView: View {
    let books: [CloudBook]
    /// The name of the books' time frame.
    let title: String

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Set by **Sounds** in the shelf's **Sort and filter** menu.
    @AppStorage("BookwormsThreeDSounds") private var sounds = true
    @State private var scene = BookwormScene()
    /// Counts **Restart** presses; each starts the meal over.
    @State private var generation = 0
    /// The book whose name shows after a tap.
    @State private var named: CloudBook?
    /// Set between `onAppear` and `onDisappear`.
    @State private var isShown = false

    private struct MealRequest: Equatable {
        let ids: [Int]
        let finished: Bool
        let generation: Int
    }

    var body: some View {
        // The body reads none of the scene's state, so the worm's progress redraws only the
        // views that show it.
        let meal = BookwormLayout.eatingOrder(books)
        Group {
            if meal.isEmpty {
                ContentUnavailableView(
                    "No finished books", systemImage: "book.closed",
                    description: Text("The bookworm eats books you have finished."))
            } else {
                stage(meal)
            }
        }
        .toolbar {
            if !meal.isEmpty && !reduceMotion {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Restart", systemImage: "arrow.counterclockwise") { generation += 1 }
                }
                ToolbarItem(placement: .topBarTrailing) { PlayButton(scene: scene) }
            }
            // Names the time frame, which the toolbar's menu saves across launches.
            ToolbarItem(placement: .subtitle) {
                Text("\(title) · \(count(meal))")
            }
        }
    }

    private func stage(_ meal: [CloudBook]) -> some View {
        ZStack {
            RealityView { content in
                content.camera = .virtual
                content.renderingEffects.antialiasing = .multisample4X
                scene.attach(to: &content)
                if PileSnapshotRenderer.isRendering { scene.root.removeFromParent() }
            } update: { content in
                // Puts back what a finished pile image took out of the scene.
                if !PileSnapshotRenderer.isRendering && scene.root.scene == nil {
                    content.add(scene.root)
                }
            }
            .gesture(nameBook)
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel("Bookworm")
            .accessibilityHint(
                "A worm eats your books in the order you finished them. To go through books one at a time, choose Stack or Shelf."
            )
            .accessibilityAction(named: "Play or pause") { scene.isPlaying.toggle() }
            .accessibilityAction(named: "Restart") { generation += 1 }
            VStack {
                if let named {
                    NamedBook(book: named)
                        .transition(.opacity)
                }
                Spacer()
                Caption(scene: scene)
            }
            .padding()
        }
        // Outside `ignoresSafeArea`, the proxy reports the safe area's size and the insets the
        // scene extends past.
        .onGeometryChange(for: PileViewport.self) { proxy in
            let insets = proxy.safeAreaInsets
            return PileViewport(
                size: CGSize(
                    width: proxy.size.width + insets.leading + insets.trailing,
                    height: proxy.size.height + insets.top + insets.bottom),
                insets: insets)
        } action: {
            scene.setViewport($0)
        }
        .task(
            id: MealRequest(ids: meal.map(\.id), finished: reduceMotion, generation: generation)
        ) {
            await scene.start(meal, finished: reduceMotion, model: model)
        }
        // Hides the name three seconds after the last tap.
        .task(id: named?.id) {
            guard named != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { named = nil }
        }
        .onAppear { isShown = true }
        .onDisappear {
            isShown = false
            named = nil
            scene.release()
        }
        // Leaves the view nothing to draw while a pile image renders, in whichever tab.
        .onChange(of: PileSnapshotRenderer.isRendering) { _, isRendering in
            if isRendering { scene.root.removeFromParent() }
        }
        .onChange(of: sounds, initial: true) { scene.feedback.playsSounds = sounds }
        // Keeps the haptic and audio engines only while collisions can be seen.
        .onChange(of: playsFeedback, initial: true) {
            if playsFeedback { scene.feedback.start() } else { scene.feedback.stop() }
        }
        .onChange(of: reduceMotion, initial: true) { scene.setDust(!reduceMotion) }
    }

    private var playsFeedback: Bool { isShown && scenePhase == .active }

    /// The number of books, such as "39 books", or "100 of 412 books" past
    /// `BookwormLayout.maximumBooks`.
    private func count(_ meal: [CloudBook]) -> String {
        let finished = books.count { $0.finishedDate != nil }
        if finished > meal.count {
            return "\(meal.count) of \(finished.formatted()) books"
        }
        return finished == 1 ? "1 book" : "\(finished.formatted()) books"
    }

    private var nameBook: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                guard let id = scene.bookID(for: value.entity),
                    let book = books.first(where: { $0.id == id })
                else { return }
                scene.pop(value.entity)
                withAnimation(.easeOut(duration: 0.2)) { named = book }
            }
    }
}

/// **Pause** or **Play**, which reads the scene's state so only the button redraws.
private struct PlayButton: View {
    let scene: BookwormScene

    var body: some View {
        Button(
            scene.isPlaying ? "Pause" : "Play",
            systemImage: scene.isPlaying ? "pause.fill" : "play.fill"
        ) {
            scene.isPlaying.toggle()
        }
        .disabled(scene.isFinished || scene.isLoading)
    }
}

/// Progress while the books are prepared, then the tally of what the worm has eaten.
private struct Caption: View {
    let scene: BookwormScene

    var body: some View {
        if scene.isLoading {
            ProgressView("Stacking books")
                .foregroundStyle(ShelfPalette.paper)
        } else if scene.eatenBooks > 0 {
            Text(BookwormLayout.caption(books: scene.eatenBooks, pages: scene.eatenPages))
                .font(.title3.weight(.semibold))
                .fontDesign(.serif)
                .monospacedDigit()
                .foregroundStyle(ShelfPalette.paper)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: .capsule)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// The title, author, and finish date of a tapped book or segment.
private struct NamedBook: View {
    let book: CloudBook

    var body: some View {
        VStack(spacing: 3) {
            Text(book.title)
                .font(.headline)
                .fontDesign(.serif)
                .lineLimit(2)
            Text(book.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let finished = book.finishedDate {
                Text("Finished \(finished, format: ShelfLabels.finishedFormat)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(ShelfPalette.paper)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}
