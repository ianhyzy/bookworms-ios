import CoreImage
import Metal
import RealityKit
import SwiftUI
import Synchronization
import os

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The heading over a dominoes finale, in the share images' style: the time frame, and the
/// books and their pages, such as "39 books · 18,683 pages". `scale` sizes it from the
/// 1080-pixel-wide share image, at 1, down to the live view, and `insets.top` places it below
/// the bars. A recording of the run draws the same heading where the live view shows it
/// (`DominoRecorder`), and adds the credit.
struct DominoFinaleCard: View {
    /// How far below the time frame button the live view shows the heading, in points.
    nonisolated static let liveTop: CGFloat = 8

    let title: String
    let count: Int
    let pages: Int
    let scale: CGFloat
    let insets: EdgeInsets

    var body: some View {
        VStack(spacing: 8 * scale) {
            Text(title)
                .font(ShareStyle.serif(120 * scale, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(totals)
                .font(ShareStyle.serif(40 * scale))
                .opacity(0.8)
        }
        .foregroundStyle(ShareStyle.cream.color)
        .shadow(color: .black.opacity(0.5), radius: 8 * scale, y: 2 * scale)
        .padding(.horizontal, 64 * scale)
        .padding(.top, insets.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// The books and their pages, which count every book in the frame.
    var totals: String {
        var totals = "\(count.formatted()) \(count == 1 ? "book" : "books")"
        if pages > 0 { totals += " · \(pages.formatted()) pages" }
        return totals
    }

    /// The pages of `books` that have a page count.
    static func pages(of books: [CloudBook]) -> Int {
        books.reduce(0) { $0 + max(0, $1.pages ?? 0) }
    }
}

/// Records a dominoes run as the reader watches it, for **Share**: from the push through the
/// finale until the heading has shown, as a story-size MP4 with the hits' knocks
/// (`PileMovieWriter`), and a PNG of its last frame, both with the credit at the bottom edge.
/// Once the books have gathered, the movie then holds its last frame still for
/// `DominoMovieTiming.lastFrameHold` seconds, so viewers see the gathered books under the
/// heading before it ends; a recording cut off at its frame limit before then ends without the
/// hold. Nothing renders again:
/// once the recording ends, the encoder takes the last frame again for each frame of the hold
/// and finishes, the soundtrack is mixed into the movie, running on under the hold, and the
/// PNG is written alongside.
///
/// The recorder takes the frames that the Desk scene's `ARView` draws. RealityKit calls its
/// `postProcess` render callback on its render thread as it encodes each frame (`Tap`). The
/// callback passes the frame on to the screen with a blit, and, for each frame the recording
/// keeps, `FrameComposer` draws on the GPU the part of the view that a 9:16 frame shows
/// (`crop(in:)`) over the wall's gradient, which shows around the scene, with the heading and
/// the credit, into a pixel buffer from the encoder's pool. In a view wider than 9:16, such as
/// a Mac's window, the frame shows the view's full height and pans across it after the run's
/// subject, which the scene passes on each update: where the Follow camera keeps the falling
/// front, or the chain just ahead of the front with another view, then the finale
/// (`DominoPan`). The video opens on the subject, at the hand and the first book. Each frame
/// request carries the frame's place, and its size stays fixed, so the heading and the credit
/// stay put in the video, and the PNG shows the last frame's place. Once the GPU is done, the
/// frame goes to the hardware encoder on the main actor, which expects frames in real time;
/// frames the encoder has no room for wait for it in order, up to `backlogLimit`, past which
/// every other one is dropped. The heading is `DominoFinaleCard`, where the live view shows it,
/// and it fades in as the live one does. `DominoMovieTiming` picks the frames on each scene
/// update, so a long run plays faster than live and the recording stays within 30 seconds, and
/// times the hits that `ImpactFeedback` recorded, which are mixed into the soundtrack once the
/// recording ends (`ImpactMix`).
///
/// The recording arms once the chain stands, so its costs fall before the push (`arm()`). The
/// writer is made and started, and Core Image compiles the frames' kernels, away from the main
/// actor and the render thread. The heading, the credit, and the wall's gradient render on the
/// main actor in between, in a frame of their own after the one in which the chain stands. The
/// callback goes on last; a moment later, RealityKit's rendering holds up a frame or two of the
/// view, with the main actor idle. A push that comes while the recording arms starts it once
/// it is armed, so the video then starts that much after the push. The callback comes off
/// when the recording ends. While a book is out at its details, the recording pauses
/// (`advance(by:phase:progress:paused:subject:)`), so the video cuts from the lift to the book's
/// return. Leaving the scene before the books have gathered discards the recording; once they
/// have gathered, leaving ends it early and keeps it. A new chain deletes the clip.
@MainActor
@Observable
final class DominoRecorder {
    /// What a recording shows: the view's size and bars, and the heading's text.
    struct Layout: Equatable {
        var viewport: PileViewport
        let title: String
        let count: Int
        let pages: Int
    }

    /// The last finished recording, until the chain is set up again.
    private(set) var clip: PileMovie?
    /// Whether a recording runs past the push or is being written, so a clip may follow.
    private(set) var isRecording = false

    /// The layout of the chain the view shows, which a recording takes as it arms.
    @ObservationIgnored var layout: Layout?

    @ObservationIgnored private let feedback: ImpactFeedback
    @ObservationIgnored private weak var view: ARView?
    @ObservationIgnored private var run: Run?
    @ObservationIgnored private var composer: FrameComposer?
    /// The folder of the last image of the view, which the next one replaces.
    @ObservationIgnored private var snapshotFolder: URL?
    /// Counts new chains, so a movie written after one started is dropped.
    @ObservationIgnored private var generation = 0
    /// Set when a recording could not start, so the chain does not try again every frame.
    @ObservationIgnored private var cannotRecord = false
    /// The recording that is arming (see `arm()`), and how many have armed, so an arming that
    /// was cancelled does not clear a later one.
    @ObservationIgnored private var arming: Task<Void, Never>?
    @ObservationIgnored private var armings = 0
    /// The chain's length when the push came while the recording armed.
    @ObservationIgnored private var pendingStart: Float?

    nonisolated private static let log = Logger(
        subsystem: "gay.ian.Bookworms.iOS", category: "video")

    /// One recording, from arming until its movie is written.
    @MainActor
    private final class Run {
        let tap: Tap
        let writer: PileMovieWriter
        let folder: URL
        let name: String
        /// The frames' timing from the push on.
        var timing: DominoMovieTiming?
        /// Where the frames show the view, which follows the run's subject across a wide view,
        /// and whether it has aimed at one yet.
        var pan: DominoPan
        private var hasAimed = false
        /// The live time each frame shows, by frame number.
        var times: [Double] = []
        /// When the books lay gathered, in live seconds since the push.
        var finishedAt: Double?
        /// Drawn frames that wait for room in the encoder, oldest first, by frame number.
        var backlog: [(picture: CVReadOnlyPixelBuffer, frame: Int)] = []
        /// Offers the backlog to the encoder again shortly, while it has frames.
        var feeding: Task<Void, Never>?
        /// The last frame the encoder took.
        var last: CVReadOnlyPixelBuffer?
        /// Set once the last frame is due; the recording ends once it is drawn.
        var isEnding = false

        init(tap: Tap, writer: PileMovieWriter, folder: URL, name: String) {
            self.tap = tap
            self.writer = writer
            self.folder = folder
            self.name = name
            pan = DominoPan(left: tap.crop.minX)
        }

        /// Moves the frame `deltaTime` seconds toward `subject`, a share of the view's width
        /// from its left edge, keeping it within the view (see `DominoPan`). The first aim
        /// goes straight to the subject, so the video opens on it, also after a push that came
        /// while the recording armed.
        func aim(at subject: CGFloat, by deltaTime: TimeInterval) {
            pan.step(
                toward: subject * tap.width - tap.crop.width / 2,
                within: 0...max(tap.width - tap.crop.width, 0),
                by: hasAimed ? deltaTime : .infinity)
            hasAimed = true
        }
    }

    /// What RealityKit's render thread needs to draw a recording's frames, and the requests
    /// that pass between it and the main actor, behind a lock.
    private final class Tap: Sendable {
        /// Frames to draw from the next frame the view draws, the heading's opacity in them,
        /// and the left edge of the part of the view they show, in points; no frames for a
        /// frame that only warms Core Image up.
        struct Request {
            var frames: ClosedRange<Int>?
            var heading: CGFloat
            var left: CGFloat
        }

        struct State {
            var request: Request?
            var isWarm = false
            /// Frames drawing on the GPU, until the main actor has them.
            var drawing = 0
            /// Cleared when the recording ends, after which the callback only blits.
            var isOpen = true
        }

        let id = UUID()
        let state = Mutex(State())
        let composer: FrameComposer
        let pool: CVMutablePixelBuffer.Pool
        /// The frame's size in pixels, and the part of the view it shows, in points, before
        /// each request moves it across the view (`Request.left`).
        let size: CGSize
        let crop: CGRect
        /// The view's width in points.
        let width: CGFloat
        let heading: CIImage
        let credit: CIImage
        /// The wall's gradient, top to bottom, to stretch behind the render.
        let wall: CIImage
        /// Hands a drawn frame to the main actor.
        let deliver: @Sendable (CVReadOnlyPixelBuffer, ClosedRange<Int>, UUID) -> Void

        init(
            composer: FrameComposer, pool: CVMutablePixelBuffer.Pool, size: CGSize,
            crop: CGRect, width: CGFloat, heading: CIImage, credit: CIImage, wall: CIImage,
            deliver: @escaping @Sendable (CVReadOnlyPixelBuffer, ClosedRange<Int>, UUID) -> Void
        ) {
            self.composer = composer
            self.pool = pool
            self.size = size
            self.crop = crop
            self.width = width
            self.heading = heading
            self.credit = credit
            self.wall = wall
            self.deliver = deliver
        }

        /// Passes the view's frame on to the screen, and draws it into the recording when a
        /// frame is requested, or once to warm Core Image up. Runs on RealityKit's render
        /// thread.
        func draw(_ context: ARView.PostProcessContext) {
            let commands = context.commandBuffer
            if let blit = commands.makeBlitCommandEncoder() {
                blit.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
                blit.endEncoding()
            }
            let request = state.withLock { state -> Request? in
                guard state.isOpen else { return nil }
                defer {
                    state.request = nil
                    state.isWarm = true
                }
                if let request = state.request {
                    if request.frames != nil { state.drawing += 1 }
                    return request
                }
                return state.isWarm ? nil : Request(heading: 0, left: crop.minX)
            }
            guard let request else { return }
            let source = context.sourceColorTexture
            do {
                guard let render = composer.image(of: source) else {
                    throw PileSnapshotError.drawingFailed
                }
                let picture = CVReadOnlyPixelBuffer(try pool.makeMutablePixelBuffer())
                try composer.render(
                    frame(of: render, heading: request.heading, left: request.left),
                    into: picture, on: commands)
                guard let frames = request.frames else {
                    return DominoRecorder.log.notice(
                        "Recording from a \(source.width) × \(source.height) render in pixel format \(source.pixelFormat.rawValue)"
                    )
                }
                let (id, deliver) = (id, deliver)
                commands.addCompletedHandler { _ in deliver(picture, frames, id) }
            } catch {
                DominoRecorder.log.error("A recording's frame failed: \(error)")
                if request.frames != nil { state.withLock { $0.drawing -= 1 } }
            }
        }

        /// Draws a frame from a stand-in render of the view, `height` points tall, and waits
        /// for the GPU, so Core Image compiles the kernels of the recording's frames before
        /// the render thread first draws one. Compiling them there holds up the view's frame
        /// for about a tenth of a second. Runs away from the main actor and the render thread.
        ///
        /// The stand-in has the pixel format of the Simulator's render. A view that renders in
        /// another format may still compile kernels in the first frame the render thread draws.
        func warmUp(height: CGFloat) throws {
            let device = composer.device
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: Int(width), height: Int(height),
                mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor),
                let render = composer.image(of: texture),
                let commands = device.makeCommandQueue()?.makeCommandBuffer()
            else { throw PileSnapshotError.drawingFailed }
            let picture = CVReadOnlyPixelBuffer(try pool.makeMutablePixelBuffer())
            try composer.render(
                frame(of: render, heading: 0, left: crop.minX), into: picture, on: commands)
            commands.commit()
            commands.waitUntilCompleted()
        }

        /// The recording's frame of `render`, a render of the view at any scale, showing the
        /// part of the view from `left`, in points, with the heading at `heading` opacity.
        private func frame(of render: CIImage, heading opacity: CGFloat, left: CGFloat)
            -> CIImage
        {
            let scale = render.extent.width / width
            let shown = CGRect(origin: CGPoint(x: left, y: crop.minY), size: crop.size)
            return composer.frame(
                of: render, crop: shown.applying(.init(scaleX: scale, y: scale)), size: size,
                background: wall, overlays: [(heading, opacity), (credit, 1)])
        }
    }

    init(feedback: ImpactFeedback) {
        self.feedback = feedback
    }

    /// Records from `view` from now on. A recording under way in another view ends.
    func attach(to view: ARView) {
        guard view !== self.view else { return }
        interrupt()
        self.view = view
    }

    /// Moves a recording on by `deltaTime` live seconds, in which the chain reached `phase`,
    /// with `progress` of the run done (see `DominoMovieTiming.advance(by:progress:)`), and
    /// pans its frame toward `subject`, where the run's action shows across the view, as a
    /// share of its width; or leaves them out while `paused`, as while a book is out at its
    /// details. Arms a recording once the chain stands.
    func advance(
        by deltaTime: TimeInterval, phase: DominoPhase, progress: Float, paused: Bool,
        subject: CGFloat?
    ) {
        guard let run else {
            if phase == .standing, !cannotRecord { arm() }
            return
        }
        guard var timing = run.timing, !run.isEnding else { return }
        defer { run.timing = timing }
        guard !paused else { return timing.skip(deltaTime) }
        if let subject { run.aim(at: subject, by: deltaTime) }
        let ended = phase == .done || phase.hasEnded
        let due = timing.advance(by: deltaTime, progress: ended ? nil : Double(progress))
        if phase == .finished, run.finishedAt == nil { run.finishedAt = timing.live }
        if let frames = due {
            run.times += repeatElement(timing.live, count: frames.count)
            // Eases in over 0.6 seconds, as the live heading does.
            let shown = run.finishedAt.map { min(1, (timing.live - $0) / 0.6) } ?? 0
            run.tap.state.withLock { state in
                let lower = state.request?.frames?.lowerBound ?? frames.lowerBound
                state.request = Tap.Request(
                    frames: lower...frames.upperBound, heading: CGFloat(shown * shown),
                    left: run.pan.left)
            }
        }
        if timing.isFull
            || run.finishedAt.map({ timing.live - $0 >= DominoMovieTiming.hold }) == true
        {
            run.isEnding = true
            endIfDrawn(run)
        }
    }

    #if DEBUG
        /// The part of the view's width that the recording's frames show, from the push until
        /// the recording ends, as shares of the width, for the camera log.
        var shownSpan: ClosedRange<CGFloat>? {
            guard let run, run.timing != nil, run.tap.width > 0 else { return nil }
            let left = run.pan.left / run.tap.width
            return left...(left + run.tap.crop.width / run.tap.width)
        }
    #endif

    /// Starts recording an armed chain `length` units long at its push, and the hits with it.
    func start(length: Float) {
        guard let run else {
            if arming != nil { pendingStart = length }
            return
        }
        pendingStart = nil
        guard run.timing == nil else { return }
        run.timing = DominoMovieTiming(length: length)
        feedback.startRecording()
        isRecording = true
    }

    /// Ends a recording early: keeps it once the books lie gathered or it has its most
    /// frames, and discards it before. Cancels a recording that is arming.
    func interrupt() {
        cancelArming()
        guard let run else { return }
        if run.finishedAt != nil || run.isEnding {
            run.isEnding = true
            run.tap.state.withLock { $0.request = nil }
            endIfDrawn(run)
        } else {
            discard(run)
        }
    }

    /// Discards any recording and deletes the clip, for a new chain.
    func reset() {
        generation += 1
        cannotRecord = false
        cancelArming()
        if let run { discard(run) }
        clip?.remove()
        clip = nil
        isRecording = false
    }

    /// The part of a view of `viewport` that a 9:16 recording shows, in points. It spans the
    /// view's width and puts the heading at a story's top margin, where the share images put
    /// theirs, unless that would leave out the bottom of the scene above the tab bar. A view
    /// wider than 9:16 shows its full height, centered on the part of the view that the bars
    /// leave clear as far as the view allows. That is where the finale gathers the books
    /// (`DominoFinale.area(in:)`), and a recording pans there from across the view
    /// (`DominoPan`).
    nonisolated static func crop(in viewport: PileViewport) -> CGRect {
        let size = viewport.size
        let story = ShareAspect.story.size
        let height = size.width * story.height / story.width
        guard height <= size.height else {
            let width = size.height * story.width / story.height
            let left = min(max(viewport.clear.midX - width / 2, 0), size.width - width)
            return CGRect(x: left, y: 0, width: width, height: size.height)
        }
        let heading = viewport.insets.top + DominoFinaleCard.liveTop
        let preferred = heading - ShareAspect.story.insets.top * size.width / story.width
        let lowest = size.height - viewport.insets.bottom - height
        let top = min(max(preferred, lowest, 0), size.height - height)
        return CGRect(x: 0, y: top, width: size.width, height: height)
    }

    // MARK: Recording

    /// Starts getting a recording ready for the push: the composer, the folder, and the started
    /// writer away from the main actor, since making a writer can take a tenth of a second or
    /// more; then the heading, the credit, and the wall's gradient on the main actor, so they
    /// render a frame or more after the one in which the chain stands; then Core Image's
    /// kernels away from the main actor (`warmUp(_:height:)`); and last the render callback.
    /// `interrupt()`, `reset()`, or a new view cancels it, and the next standing chain arms
    /// again.
    private func arm() {
        guard arming == nil, let view, let layout else { return }
        armings += 1
        let number = armings
        arming = Task {
            await arm(view: view, layout: layout)
            if armings == number { arming = nil }
        }
    }

    private func cancelArming() {
        arming?.cancel()
        arming = nil
        pendingStart = nil
    }

    private func arm(view: ARView, layout: Layout) async {
        var made: (writer: PileMovieWriter, folder: URL)?
        do {
            let size = ShareAspect.story.size
            PileSnapshotRenderer.removeStaleClips()
            let name = "Dominoes \(layout.title)"
            let prepared = try await Self.prepare(composer: composer, name: name, size: size)
            let composer = prepared.composer
            let folder = prepared.folder
            let writer = PileMovieWriter(url: prepared.url, encoder: prepared.encoder)
            made = (writer, folder)
            guard !Task.isCancelled else { throw CancellationError() }
            let crop = Self.crop(in: layout.viewport)
            let (heading, credit) = try Self.overlays(for: layout, crop: crop)
            let wall = try Self.wall()
            let tap = Tap(
                composer: composer, pool: try writer.framePool(), size: size, crop: crop,
                width: layout.viewport.size.width, heading: heading, credit: credit, wall: wall
            ) { [weak self] picture, frames, id in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.drew(picture, as: frames, in: id) }
                }
            }
            await Self.warmUp(tap, height: layout.viewport.size.height)
            // An arming that was cancelled, or that another view or arming overtook, ends.
            guard !Task.isCancelled, self.view === view, run == nil else {
                throw CancellationError()
            }
            self.composer = composer
            run = Run(tap: tap, writer: writer, folder: folder, name: name)
            view.renderCallbacks.postProcess = { @Sendable context in tap.draw(context) }
            // A push that came while the recording armed starts it now.
            if let length = pendingStart { start(length: length) }
        } catch {
            if let made {
                made.writer.cancel()
                try? FileManager.default.removeItem(at: made.folder)
            }
            guard !(error is CancellationError) else { return }
            Self.log.error("The recording could not start: \(error)")
            cannotRecord = true
        }
    }

    /// `composer`, or a new one, a new folder for a recording named `name`, and a started
    /// encoder for a movie of `size` pixels at `url` in it, made away from the main actor.
    @concurrent
    nonisolated private static func prepare(
        composer: FrameComposer?, name: String, size: CGSize
    ) async throws
        -> sending (
            composer: FrameComposer, folder: URL, url: URL, encoder: PileMovieWriter.Encoder
        )
    {
        let composer = try composer ?? FrameComposer()
        let folder = URL.temporaryDirectory.appending(path: "PileVideo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName(name) + ".mp4")
        let encoder = try PileMovieWriter.encoder(
            url: url, width: Int(size.width), height: Int(size.height), live: true)
        return (composer, folder, url, encoder)
    }

    /// Warms Core Image up for `tap`'s frames away from the main actor (see
    /// `Tap.warmUp(height:)`). A failure leaves the warming to the render thread.
    @concurrent
    nonisolated private static func warmUp(_ tap: Tap, height: CGFloat) async {
        do {
            try tap.warmUp(height: height)
        } catch {
            log.error("Core Image did not warm up for a recording: \(error)")
        }
    }

    /// `name` without the characters that file names cannot hold.
    nonisolated private static func fileName(_ name: String) -> String {
        name.replacing("/", with: "-").replacing(":", with: "-")
    }

    /// The heading, where the live view shows it, and the credit, each a frame's size.
    private static func overlays(for layout: Layout, crop: CGRect) throws -> (CIImage, CIImage) {
        let size = ShareAspect.story.size
        let scale = size.width / crop.width
        let card = DominoFinaleCard(
            title: layout.title, count: layout.count, pages: layout.pages, scale: 1,
            insets: EdgeInsets(
                top: (layout.viewport.insets.top + DominoFinaleCard.liveTop - crop.minY) * scale,
                leading: 0, bottom: 0, trailing: 0))
        func image(_ content: some View) -> CIImage? {
            let renderer = ImageRenderer(
                content: content.frame(width: size.width, height: size.height))
            renderer.scale = 1
            renderer.isOpaque = false
            return renderer.cgImage.map { CIImage(cgImage: $0) }
        }
        guard let heading = image(card),
            let credit = image(Color.clear.overlay(alignment: .bottom) { ShareCredit() })
        else { throw PileSnapshotError.drawingFailed }
        return (heading, credit)
    }

    /// The wall's gradient, which the live view shows around the scene, as a strip to stretch
    /// over the view.
    private static func wall() throws -> CIImage {
        guard
            let strip = BookFactory.render(
                Rectangle().fill(ShelfPalette.wall).frame(width: 4, height: 128), scale: 1)
        else { throw PileSnapshotError.drawingFailed }
        return CIImage(cgImage: strip)
    }

    /// The most drawn frames that wait for the encoder, about a sixth of a second of video;
    /// beyond it, every other one is dropped (`thinned(_:)`), so a slow encoder never holds up
    /// the view.
    private static let backlogLimit = 6

    /// `backlog` with every other frame dropped, counting back from the newest, which it
    /// keeps. A stalled encoder then leaves the video a few frames spread across the stall,
    /// rather than one frame frozen through it, as dropping the oldest would.
    nonisolated static func thinned<Frame>(_ backlog: [Frame]) -> [Frame] {
        backlog.enumerated()
            .filter { (backlog.count - 1 - $0.offset).isMultiple(of: 2) }
            .map(\.element)
    }

    /// Hands a frame that the GPU has drawn to the encoder, as each of `frames`, and ends the
    /// recording after its last frame.
    private func drew(_ picture: CVReadOnlyPixelBuffer, as frames: ClosedRange<Int>, in id: UUID) {
        guard let run, run.tap.id == id else { return }
        run.tap.state.withLock { $0.drawing -= 1 }
        run.backlog += frames.map { (picture, $0) }
        if run.backlog.count > Self.backlogLimit {
            let waiting = run.backlog.count
            run.backlog = Self.thinned(run.backlog)
            Self.log.notice(
                "The encoder fell behind; dropped \(waiting - run.backlog.count) frames")
        }
        feed(run)
    }

    /// Offers `run`'s waiting frames to the encoder in order, and again 4 milliseconds later
    /// while it has no room, then ends the recording after its last frame. A failed writer
    /// discards the recording.
    private func feed(_ run: Run) {
        guard self.run === run else { return }
        do {
            while let next = run.backlog.first,
                try run.writer.appendIfReady(next.picture, at: next.frame)
            {
                run.last = next.picture
                run.backlog.removeFirst()
            }
        } catch {
            Self.log.error("The recording's writer failed: \(error)")
            return discard(run)
        }
        guard run.backlog.isEmpty else {
            if run.feeding == nil {
                run.feeding = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(4))
                    run.feeding = nil
                    self?.feed(run)
                }
            }
            return
        }
        endIfDrawn(run)
    }

    /// Ends `run` once it is ending and its last frame is drawn: takes the render callback
    /// off, then writes the movie and its still.
    private func endIfDrawn(_ run: Run) {
        guard run.isEnding, run.backlog.isEmpty,
            run.tap.state.withLock({ $0.request == nil && $0.drawing == 0 })
        else { return }
        guard let last = run.last, let composer else { return discard(run) }
        close(run)
        let hits = DominoMovieTiming.hits(
            feedback.finishRecording(), shownAt: run.times, skipping: run.timing?.gaps ?? [])
        let began = ContinuousClock.now
        let generation = generation
        Task {
            do {
                guard let poster = composer.cgImage(of: last) else {
                    throw PileSnapshotError.drawingFailed
                }
                let still = run.writer.url.deletingPathExtension().appendingPathExtension("png")
                // The still encodes away from the main actor while the movie finishes.
                async let written: Void = PileSnapshotRenderer.writeStill(
                    poster, identifier: nil, to: still)
                let deadline = ContinuousClock.now + PileMovieWriter.finishTimeout
                // A recording cut off at its frame limit before the books gather ends mid-run,
                // where a still last frame would look like a stalled player.
                let held = run.finishedAt == nil ? 0 : DominoMovieTiming.lastFrameHold
                try await run.writer.repeatFrame(last, for: held, before: deadline)
                try await run.writer.finish(hits: hits, before: deadline)
                try await written
                let clip = PileMovie(
                    movie: run.writer.url, still: still, poster: poster, name: run.name)
                Self.log.notice(
                    "Recorded \(run.writer.encodedCount) of \(run.writer.frameCount) frames and \(hits.count) hits; the movie took \((ContinuousClock.now - began) / .seconds(1), format: .fixed(precision: 2)) s to write"
                )
                // A new chain while the movie was written leaves no place for it.
                guard generation == self.generation else { return clip.remove() }
                self.clip = clip
                #if DEBUG
                    DominoVideoDebug.write(clip)
                #endif
            } catch {
                Self.log.error("The recording could not be written: \(error)")
                run.writer.cancel()
                try? FileManager.default.removeItem(at: run.folder)
            }
            if generation == self.generation { isRecording = false }
        }
    }

    /// Stops `run` and deletes its files.
    private func discard(_ run: Run) {
        guard self.run === run else { return }
        close(run)
        run.writer.cancel()
        try? FileManager.default.removeItem(at: run.folder)
        if run.timing != nil { _ = feedback.finishRecording() }
        isRecording = false
    }

    /// Takes the render callback off and lets the render thread draw no more frames.
    private func close(_ run: Run) {
        if self.run === run { self.run = nil }
        run.feeding?.cancel()
        run.tap.state.withLock { $0.isOpen = false }
        view?.renderCallbacks.postProcess = nil
    }

    // MARK: Image

    /// An image of the view as it shows now, in a 9:16 PNG with the heading and the credit,
    /// for **Share** when no recording of the run was kept. It frames `viewport`, the view the
    /// chain was planned in, while the view keeps that size, so a wider view's image shows the
    /// spread's area (`DominoFinale.area(in:)`) also after the sidebar shows or hides. A view
    /// resized since, or one without a plan, frames its current layout, which matches the
    /// snapshot it takes. Replaces the previous one.
    ///
    /// - Throws: `PileSnapshotError` when the view or its snapshot is missing or cannot be
    ///   drawn.
    func snapshot(in viewport: PileViewport?) async throws -> URL {
        guard let view, var layout else { throw PileSnapshotError.drawingFailed }
        if let viewport, viewport.size == layout.viewport.size { layout.viewport = viewport }
        let image: UIImage? = await withCheckedContinuation { done in
            view.snapshot(saveToHDR: false) { done.resume(returning: $0) }
        }
        guard let shot = image?.cgImage else { throw PileSnapshotError.drawingFailed }
        let composer = try composer ?? FrameComposer()
        self.composer = composer
        let crop = Self.crop(in: layout.viewport)
        let (heading, credit) = try Self.overlays(for: layout, crop: crop)
        let scale = CGFloat(shot.width) / layout.viewport.size.width
        guard
            let picture = composer.cgImage(
                composer.frame(
                    of: CIImage(cgImage: shot), crop: crop.applying(.init(scaleX: scale, y: scale)),
                    size: ShareAspect.story.size, background: try Self.wall(),
                    overlays: [(heading, 1), (credit, 1)]))
        else { throw PileSnapshotError.drawingFailed }
        if let snapshotFolder { try? FileManager.default.removeItem(at: snapshotFolder) }
        let folder = URL.temporaryDirectory.appending(path: "PileVideo-\(UUID().uuidString)")
        snapshotFolder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: Self.fileName("Dominoes \(layout.title)") + ".png")
        try await PileSnapshotRenderer.writeStill(picture, identifier: nil, to: url)
        return url
    }
}

/// The left edge of a recording's 9:16 frame, in points, as it pans across a wider view after
/// the run's subject (see `DominoRecorder`).
///
/// Two first-order lags in series ease the edge toward its goal. Together they respond as a
/// critically damped spring: the frame sets off and settles smoothly, and never overshoots.
/// Each step moves each lag part of the way toward a value it has had, so the edge only takes
/// values between its first and the goals it has had, which `step` holds within the view. It
/// follows a subject that moves at a steady speed `lag` seconds behind, so the scene aims that
/// far ahead along the chain.
struct DominoPan {
    /// How fast each lag closes on its goal, per second. With the scene's subject led by
    /// `lag`, it sets how quickly the frame turns with the chain at a row's end, within about
    /// half a second, which keeps the fastest fronts measured across a Mac window's overview, a
    /// year's and a month's, near the frame's middle.
    static let rate: Double = 10

    /// How long the frame trails a subject that moves at a steady speed, in seconds.
    static var lag: TimeInterval { 2 / rate }

    /// The frame's left edge, and the first lag's.
    private(set) var left: CGFloat
    private var lead: CGFloat

    init(left: CGFloat) {
        self.left = left
        lead = left
    }

    /// Moves `deltaTime` seconds toward `goal`, held within `range`. An infinite step jumps
    /// to the goal.
    mutating func step(
        toward goal: CGFloat, within range: ClosedRange<CGFloat>, by deltaTime: TimeInterval
    ) {
        let goal = min(max(goal, range.lowerBound), range.upperBound)
        let share = CGFloat(1 - exp(-Self.rate * max(deltaTime, 0)))
        lead += (goal - lead) * share
        left += (lead - left) * share
    }
}

#if DEBUG
    /// Simulator hook, since a script cannot tap **Share**.
    ///
    /// With `-BookwormsDominoVideo YES`, each finished recording of a dominoes run is copied to
    /// `Library/Caches/Bookworms/domino-video-debug.mp4` with its still at
    /// `domino-video-debug.png`.
    enum DominoVideoDebug {
        static var isOn: Bool { UserDefaults.standard.bool(forKey: "BookwormsDominoVideo") }

        static func write(_ movie: PileMovie) {
            guard isOn else { return }
            let folder = URL.cachesDirectory.appending(path: "Bookworms")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (source, name) in [
                (movie.movie, "domino-video-debug.mp4"), (movie.still, "domino-video-debug.png"),
            ] {
                let target = folder.appending(path: name)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: source, to: target)
            }
        }
    }
#endif
