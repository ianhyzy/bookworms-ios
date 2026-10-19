import RealityKit
import SwiftUI

/// The books on the desk as dominoes: they stand on end along a winding path in finish order,
/// evenly spaced (`DominoLayout`), and a cobweb hangs between two books wherever 30 days or more
/// passed between their finishes (`DominoLayout.cobwebDays`). **Dominoes** in the desk's bar
/// hands this view the books lying on the desk, which set themselves up from where they lie
/// (see `DominoScene` and `DominoSetup`). A chain of other books, such as another time frame's,
/// gets its books ready under a spinner (`SceneLoading`), and they drop into their places from
/// above the top of the screen.
///
/// A pointing hand floats before the first book, as a finger about to poke it; a tap on the
/// hand topples the whole chain, tearing the cobwebs as it goes. The first time a chain stands,
/// a tip points at the hand (`PushTip`, `DeskScenes.pushTipPoint`). Should the chain stop, such as
/// where a book leans on the next without knocking it over, the hand points at the book to tap
/// to nudge it on. Tapping or touching and holding a book, before the push, while the chain
/// falls, or once the books lie gathered, lifts it out of the chain to its details over the
/// darkened scene, as the Desk scene does (`LiftedDetails`), while the chain holds still, and
/// **Back** sets it down exactly where it lay (see `DominoScene`). The books are never thrown:
/// they are arranged. With Reduce Motion on, or when the scene cannot lift the book, `open`
/// pushes the details instead, and the chain is as the reader left it on return.
/// **Camera** in the desk's options menu chooses how the camera films the chain
/// (`DominoCameraMode`). Pinch to zoom, or on the Mac scroll, and drag to look along the path;
/// each takes the camera over until the next push. **Set up again** sets every book up again
/// from where it lies.
/// Collisions play taps and, while the desk's **Sounds** is on, knocks (`ImpactFeedback`).
/// While the scene records a run, from the push until the heading shows over the gathered
/// books, a red dot and the time since the push show under the bar (`RecordingBadge`). Once the books have gathered,
/// **Share** offers the run's video, which the scene recorded as it played (`DominoRecorder`),
/// and its last frame, through the share sheet; without a recording, it offers an image of the
/// view.
///
/// The scene (`DeskScenes.dominoes`) draws in the desk's view, which lives only while Desk is
/// on screen (`DeskSceneView`), so a hidden tab runs no frame loop, and this view lays the
/// gestures, controls, heading, and details over it. The scene keeps its books, so the chain is
/// as the reader left it on return,
/// standing or fallen. Leaving stops the haptic and audio engines, and leaving other than for
/// details, such as for another tab, puts a lifted book back at once. A memory warning while
/// the tab is hidden frees the books and textures, and they stand again on return. While a
/// pile image renders, the scene leaves the view and a lifted book goes back, as
/// `BookPileView` explains.
struct DominoesView: View {
    let books: [CloudBook]
    /// The name of the books' time frame.
    let title: String
    /// The desk's scenes, whose dominoes this view shows.
    let desk: DeskScenes
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
    @State private var viewport: PileViewport?
    /// The scene's frame in global coordinates, which the details' book frame converts from.
    @State private var canvas = CGRect.zero
    /// Set while pushed details cover the chain, or while the lifted book's details wait for
    /// the reader to return from the Share tab, so leaving keeps it.
    @State private var showsBook = false
    /// Set between `onAppear` and `onDisappear`. The view stays in the hierarchy under a pushed
    /// book or in a tab that is not selected.
    @State private var isShown = false
    /// The files the share sheet offers, while it shows.
    @State private var files: SharedFiles?
    /// What the reader chose to share while the run's video was still being written.
    @State private var waitingShare: Shared?
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

    private var scene: DominoScene { desk.dominoes }

    /// Whether the chain stands waiting for its first push, with nothing moving the camera or
    /// covering the chain, when the push tip can point at the hand.
    private var waitsForPush: Bool {
        scene.status.phase == .standing && !movesCamera && details.lift == nil
    }

    var body: some View {
        // A SwiftUI layer over the desk's view takes the touches: gestures on the hosted view
        // would not fire.
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
            #if os(macOS)
                .background { ScrollWheelReader(onScroll: scroll) }
            #endif
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
            .accessibilityHint(
                "\(DeskTips.tap) a book for its details. To go through books one at a time, open Library."
            )
            .accessibilityActions {
                if scene.status.phase.waitsForPush {
                    Button("Push the next book") { scene.pushNext() }
                }
                Button("Set up again") { desk.setUpDominoesAgain() }
            }
            .overlay { shareFrame }
            .overlay { heading }
            // Until the heading takes its place over the gathered books.
            .overlay(alignment: .top) {
                if scene.status.phase != .finished {
                    RecordingBadge(recorder: scene.recorder).padding(.top, 8)
                }
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
                desk.viewport = $0
            }
            .task(
                id: SetUpRequest(
                    ids: books.map(\.id), generation: desk.dominoGeneration, viewport: viewport)
            ) {
                guard let viewport else { return }
                let generation = desk.dominoGeneration
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
                PushTip.chainWaits = false
                desk.pushTipPoint = nil
                scene.endCameraMove()
                scene.recorder.interrupt()
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
            // The hand holds still before the first push, so the tip points at it once the
            // camera has come to rest. A camera move or a lifted book's details take the tip
            // down, and it points at the hand again once they end.
            .task(id: waitsForPush && scene.isCameraSettled) {
                PushTip.chainWaits = false
                desk.pushTipPoint = nil
                guard waitsForPush, scene.isCameraSettled else { return }
                try? await Task.sleep(for: .seconds(0.2))
                guard !Task.isCancelled, let size = viewport?.size else { return }
                desk.pushTipPoint = scene.handPoint(in: size)
                PushTip.chainWaits = desk.pushTipPoint != nil
            }
            .onChange(of: scene.status.phase) {
                if scene.status.phase == .running { DeskTips.pushed() }
                // Physics runs on under details, which VoiceOver reads instead.
                guard isShown, details.lift == nil else { return }
                switch scene.status.phase {
                case .stalled, .done, .finished:
                    AccessibilityNotification.Announcement(status).post()
                default: break
                }
            }
            // The recording takes the view's layout and heading as the chain stands.
            .onChange(of: recordingLayout, initial: true) { _, layout in
                scene.recorder.layout = layout
            }
            // iOS may stop the hardware encoder in the background.
            .onChange(of: scenePhase) {
                if scenePhase == .background { scene.recorder.interrupt() }
            }
            .onChange(of: scene.recorder.isRecording) {
                guard !scene.recorder.isRecording, let waiting = waitingShare else { return }
                waitingShare = nil
                share(waiting)
            }
            .toolbar {
                if details.lift == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Set up again", systemImage: "arrow.counterclockwise") {
                            desk.setUpDominoesAgain()
                        }
                    }
                    // The run's video and image, once the books have gathered.
                    if scene.status.phase == .finished {
                        ToolbarItem(placement: .topBarTrailing) { shareMenu }
                    }
                }
            }
            .shareSheet($files)
    }

    /// The heading over the gathered books, in the share images' style, once every book lies
    /// in the spread; it fades in, and stays until **Set up again**. It spans the spread's area
    /// (`DominoFinale.area(in:)`), the whole view on an iPhone and the recording's 9:16 frame in
    /// a wider view, so it shows where and as large as the video shows it. The area is the one
    /// the spread was laid out in, for the view the chain was planned in
    /// (`DominoScene.plannedViewport`), which the scene keeps while the phase changes.
    @ViewBuilder private var heading: some View {
        if scene.status.phase == .finished, details.lift == nil,
            let viewport = scene.plannedViewport
        {
            let area = DominoFinale.area(in: viewport)
            DominoFinaleCard(
                title: title, count: books.count, pages: DominoFinaleCard.pages(of: books),
                scale: area.width / ShareAspect.story.size.width,
                insets: EdgeInsets(
                    top: viewport.insets.top + DominoFinaleCard.liveTop - area.minY, leading: 0,
                    bottom: 0, trailing: 0)
            )
            .frame(width: area.width, height: area.height)
            .offset(x: area.minX, y: area.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeIn(duration: 0.6)))
            // VoiceOver reads the same totals as the scene's value.
            .accessibilityHidden(true)
        }
    }

    /// In a view wider than 9:16, such as a Mac's window, darkens the view on either side of the
    /// spread's area (`DominoFinale.area(in:)`) from when the books lift to gather, or appear
    /// with Reduce Motion on, so the window shows the 9:16 frame that the video and **Image**
    /// show. It fades in as the video's frame arrives there, and stays until **Set up again**.
    /// A view that the area fills, such as an iPhone's, shows none.
    @ViewBuilder private var shareFrame: some View {
        if scene.status.phase.hasEnded, details.lift == nil,
            let viewport = scene.plannedViewport
        {
            let area = DominoFinale.area(in: viewport)
            if area.width < viewport.size.width {
                HStack(spacing: 0) {
                    Rectangle().frame(width: area.minX)
                    Color.clear.frame(width: area.width)
                    Rectangle()
                }
                .foregroundStyle(.black.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeInOut(duration: 0.6)))
                .accessibilityHidden(true)
            }
        }
    }

    /// What **Share** shares.
    private enum Shared {
        case video, image
    }

    /// **Share**: the run's video or its last frame, or, when no recording of the run was
    /// kept, an image of the view. A choice made while the video is still being written waits
    /// for it, with a spinner in the button's place.
    @ViewBuilder private var shareMenu: some View {
        let recorder = scene.recorder
        if waitingShare != nil {
            ProgressView()
                .accessibilityLabel("Preparing to share")
        } else {
            Menu("Share", systemImage: "square.and.arrow.up") {
                if recorder.clip != nil || recorder.isRecording {
                    Button("Video", systemImage: "video") { share(.video) }
                    Button("Image", systemImage: "photo") { share(.image) }
                } else {
                    Section("To share a video, set up again and watch the run through.") {
                        Button("Image", systemImage: "photo") { share(.image) }
                    }
                }
            }
        }
    }

    /// Opens the share sheet for the run's video or image, once the video is written, or for
    /// an image of the view when there is no recording.
    private func share(_ shared: Shared) {
        let recorder = scene.recorder
        if let clip = recorder.clip {
            files = SharedFiles(urls: [shared == .video ? clip.movie : clip.still])
        } else if recorder.isRecording {
            waitingShare = shared
        } else if shared == .video {
            model.toasts.show(.failure("Couldn't make the video"))
        } else {
            Task {
                do {
                    files = SharedFiles(
                        urls: [try await recorder.snapshot(in: scene.plannedViewport)])
                } catch {
                    model.toasts.show(.failure("Couldn't make the image"))
                }
            }
        }
    }

    /// The view's layout and heading, for the recording.
    private var recordingLayout: DominoRecorder.Layout? {
        viewport.map {
            DominoRecorder.Layout(
                viewport: $0, title: title, count: books.count,
                pages: DominoFinaleCard.pages(of: books))
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
        case .gathering: "The books are gathering."
        case .finished:
            "\(title): \(FrameChip.books(chainLength, of: books.count)) lie face up. Share offers a video and an image of the run."
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

    /// A tap on the hand pushes the chain on, and a tap on a book lifts it to its details (see
    /// `DominoScene.tap(at:in:)`); touching and holding a book lifts it too. Both find the book
    /// with the scene's own ray.
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

    #if os(macOS)
        /// Zooms toward `point` for a scroll over the part of the view the bars leave clear, as
        /// a pinch does, and returns whether it did; scrolls elsewhere, or while details cover
        /// the chain, go on to the views under them.
        private func scroll(_ event: NSEvent, at point: CGPoint) -> Bool {
            guard isShown, details.lift == nil, viewport?.clear.contains(point) == true else {
                return false
            }
            desk.moveCamera(magnification: PilePointer.move(for: event).magnification, focus: point)
            return true
        }
    #endif

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

/// A red dot and the time since the push, while the dominoes' run records, so the reader knows
/// the run is being filmed. The time is a timer-style `Text`, which the system redraws each
/// second without updating this view.
private struct RecordingBadge: View {
    let recorder: DominoRecorder

    @State private var start: Date?

    var body: some View {
        Group {
            if let start {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(start, style: .timer)
                        .monospacedDigit()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ShelfPalette.paper)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45), in: .capsule)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording")
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: recorder.isRecording, initial: true) {
            withAnimation(.easeInOut(duration: 0.2)) {
                start = recorder.isRecording ? start ?? .now : nil
            }
        }
    }
}
