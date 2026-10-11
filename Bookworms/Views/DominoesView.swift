import RealityKit
import SwiftUI

/// The time frame's books as dominoes: they stand on end along a winding path in finish order,
/// spaced by the days between finishes (`DominoLayout`), so a reading binge is a tight run and
/// a slump is a gap that a falling book cannot cross.
///
/// A tap on the first book topples the chain, which stops at each slump until the reader taps
/// the next book, which a glow marks, to nudge it on. A tap on any book the chain has not
/// reached also pushes it on. Tapping a book the chain has passed, or touching and holding any
/// book, calls `open` to push its details, and the chain is as the reader left it on return.
/// Pinch to zoom, and drag to look along the path. **Set up again** stands every book again.
/// Collisions play taps and, while the shelf's **Sounds** is on, clacks (`ImpactFeedback`).
///
/// Leaving stops the haptic and audio engines. Leaving other than for details, such as for
/// another tab, also frees the books and textures, and they stand again on return. While a
/// pile image renders, the scene leaves the view, as `BookPileView` explains.
struct DominoesView: View {
    let books: [CloudBook]
    /// The name of the books' time frame.
    let title: String
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Set by **Sounds** in the shelf's **Sort and filter** menu.
    @AppStorage("BookwormsThreeDSounds") private var sounds = true
    @State private var scene = DominoScene()
    @State private var viewport: PileViewport?
    /// Counts **Set up again** presses; each stands the books again.
    @State private var generation = 0
    /// Set while pushed details cover the chain, so leaving keeps it.
    @State private var showsBook = false
    /// Set between `onAppear` and `onDisappear`.
    @State private var isShown = false
    /// Set while fingers move the camera, and reset when they lift.
    @GestureState private var movesCamera = false

    private struct SetUpRequest: Equatable {
        let ids: [Int]
        let generation: Int
        let viewport: PileViewport?
    }

    var body: some View {
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
        .gesture(touchBook)
        .simultaneousGesture(moveCamera)
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Dominoes of \(count)")
        .accessibilityValue("\(title). \(status)")
        .accessibilityHint("To go through books one at a time, choose Stack or Shelf.")
        .accessibilityActions {
            if scene.status.phase.waitsForPush {
                Button("Push the next book") { scene.pushNext() }
            }
            Button("Set up again") { generation += 1 }
        }
        .overlay(alignment: .bottom) { hint }
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
            await scene.setUp(books, generation: generation, viewport: viewport, model: model)
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
            guard !showsBook else { return }
            scene.release()
        }
        .onChange(of: PileSnapshotRenderer.isRendering) { _, isRendering in
            if isRendering { scene.root.removeFromParent() }
        }
        .onChange(of: sounds, initial: true) { scene.feedback.playsSounds = sounds }
        // Keeps the haptic and audio engines only while collisions can be seen.
        .onChange(of: playsFeedback, initial: true) {
            if playsFeedback { scene.feedback.start() } else { scene.feedback.stop() }
        }
        .onChange(of: reduceMotion, initial: true) { scene.setReduceMotion(reduceMotion) }
        .onChange(of: movesCamera) { if !movesCamera { scene.endCameraMove() } }
        .onChange(of: scene.status.phase) {
            // Physics runs on under pushed details, which VoiceOver reads instead.
            guard isShown else { return }
            switch scene.status.phase {
            case .stalled, .done: AccessibilityNotification.Announcement(status).post()
            default: break
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Set up again", systemImage: "arrow.counterclockwise") { generation += 1 }
            }
        }
        // Outside the viewport reading, so the path starts below the button.
        .safeAreaInset(edge: .top, spacing: 0) {
            FrameChip(title: title, shown: chainLength, total: books.count)
        }
    }

    /// What to do next, over the bottom of the scene while the chain waits for a push.
    @ViewBuilder private var hint: some View {
        let text: String? =
            switch scene.status.phase {
            case .standing:
                "Tap the glowing book to start the chain. Touch and hold any book for its details."
            case .stalled(_, let days) where days >= DominoLayout.slumpDays:
                "\(days.formatted()) days without finishing a book stopped the chain. Tap the glowing book to go on."
            case .stalled:
                "The chain stopped. Tap the glowing book to nudge it on."
            default: nil
            }
        if let text {
            Text(text)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
                // VoiceOver reads the same status as the scene's value.
                .accessibilityHidden(true)
        }
    }

    /// The chain's phase as VoiceOver reads it.
    private var status: String {
        switch scene.status.phase {
        case .settingUp: "Setting up."
        case .standing: "Standing. Push the first book to start the chain."
        case .running: "Falling."
        case .stalled(let fallen, let days) where days >= DominoLayout.slumpDays:
            "Stopped after \(fallen) of \(chainLength) books, at \(days.formatted()) days without finishing a book. Push the next book to go on."
        case .stalled(let fallen, _):
            "Stopped after \(fallen) of \(chainLength) books. Push the next book to go on."
        case .done: "Every book has fallen."
        }
    }

    private var playsFeedback: Bool { isShown && scenePhase == .active }

    private var chainLength: Int { min(books.count, DominoLayout.maximumBooks) }

    /// The number of books, such as "39 books", or "300 of 1,024 books" past the most a chain
    /// stands.
    private var count: String { FrameChip.books(chainLength, of: books.count) }

    /// A tap pushes the chain on or opens the details of a book it has passed (see
    /// `DominoScene.tap(at:in:)`); touching and holding opens any book's details.
    private var touchBook: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .targetedToAnyEntity()
            .exclusively(before: SpatialTapGesture())
            .onEnded { value in
                switch value {
                case .first(let press): showDetails(scene.bookID(for: press.entity))
                case .second(let tap):
                    showDetails(scene.tap(at: tap.location, in: viewport?.size ?? .zero))
                }
            }
    }

    private func showDetails(_ id: Int?) {
        guard let id, let book = books.first(where: { $0.id == id }) else { return }
        showsBook = true
        open(book)
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
