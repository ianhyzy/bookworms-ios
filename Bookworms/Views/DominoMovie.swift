import CoreImage
import Metal
import RealityKit
import SwiftUI
import Synchronization
import UIKit
import os

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
/// The video is ready a second or two after the recording ends, since nothing renders again.
///
/// The recorder takes the frames that the Desk scene's `ARView` draws. RealityKit calls its
/// `postProcess` render callback on its render thread as it encodes each frame (`Tap`). The
/// callback passes the frame on to the screen with a blit, and, for each frame the recording
/// keeps, `FrameComposer` draws on the GPU the part of the view that a 9:16 frame shows
/// (`crop(in:)`) over the wall's gradient, which shows around the scene, with the heading and
/// the credit, into a pixel buffer from the encoder's pool. Once the GPU is done, the frame
/// goes to the hardware encoder on the main actor; frames the encoder has no room for wait for
/// it in order, up to `backlogLimit`, so the video keeps every frame. The heading is `DominoFinaleCard`, where
/// the live view shows it, and it fades in as the live one does. `DominoMovieTiming` picks the
/// frames on each scene update, so a long run plays faster than live and the video stays
/// within 30 seconds, and times the hits that `ImpactFeedback` recorded, which are mixed into
/// the soundtrack once the recording ends (`ImpactMix`).
///
/// The callback goes on, and the writer starts, once the chain stands, so their costs fall
/// before the push; the first frame drawn then compiles Core Image's kernels. The callback
/// comes off when the recording ends. Leaving the scene or lifting a book before the books
/// have gathered discards the recording; once they have gathered, either ends it early and
/// keeps it. A new chain deletes the clip.
@MainActor
@Observable
final class DominoRecorder {
    /// What a recording shows: the view's size and bars, and the heading's text.
    struct Layout: Equatable {
        let viewport: PileViewport
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
        }
    }

    /// What RealityKit's render thread needs to draw a recording's frames, and the requests
    /// that pass between it and the main actor, behind a lock.
    private final class Tap: Sendable {
        /// Frames to draw from the next frame the view draws, and the heading's opacity in
        /// them; no frames for a frame that only warms Core Image up.
        struct Request {
            var frames: ClosedRange<Int>?
            var heading: CGFloat
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
        /// The frame's size in pixels, and the part of the view it shows, in points.
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
                return state.isWarm ? nil : Request(heading: 0)
            }
            guard let request else { return }
            let source = context.sourceColorTexture
            do {
                guard let render = composer.image(of: source) else {
                    throw PileSnapshotError.drawingFailed
                }
                let scale = CGFloat(source.width) / width
                let picture = CVReadOnlyPixelBuffer(try pool.makeMutablePixelBuffer())
                try composer.render(
                    composer.frame(
                        of: render, crop: crop.applying(.init(scaleX: scale, y: scale)),
                        size: size, background: wall,
                        overlays: [(heading, request.heading), (credit, 1)]),
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
    /// with `progress` of the run done (see `DominoMovieTiming.advance(by:progress:)`). Arms a
    /// recording once the chain stands.
    func advance(by deltaTime: TimeInterval, phase: DominoPhase, progress: Float) {
        guard let run else {
            if phase == .standing, !cannotRecord { arm() }
            return
        }
        guard var timing = run.timing, !run.isEnding else { return }
        defer { run.timing = timing }
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
                    frames: lower...frames.upperBound, heading: CGFloat(shown * shown))
            }
        }
        if timing.isFull
            || run.finishedAt.map({ timing.live - $0 >= DominoMovieTiming.hold }) == true
        {
            run.isEnding = true
            endIfDrawn(run)
        }
    }

    /// Starts recording an armed chain `length` units long at its push, and the hits with it.
    func start(length: Float) {
        guard let run, run.timing == nil else { return }
        run.timing = DominoMovieTiming(length: length)
        feedback.startRecording()
        isRecording = true
    }

    /// Ends a recording early: keeps it once the books lie gathered or it has its most
    /// frames, and discards it before.
    func interrupt() {
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
        if let run { discard(run) }
        clip?.remove()
        clip = nil
        isRecording = false
    }

    /// The part of a view of `viewport` that a 9:16 recording shows, in points. It spans the
    /// view's width and puts the heading at a story's top margin, where the share images put
    /// theirs, unless that would leave out the bottom of the scene above the tab bar. A view
    /// wider than 9:16 shows its full height, centered.
    nonisolated static func crop(in viewport: PileViewport) -> CGRect {
        let size = viewport.size
        let story = ShareAspect.story.size
        let height = size.width * story.height / story.width
        guard height <= size.height else {
            let width = size.height * story.width / story.height
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let heading = viewport.insets.top + DominoFinaleCard.liveTop
        let preferred = heading - ShareAspect.story.insets.top * size.width / story.width
        let lowest = size.height - viewport.insets.bottom - height
        let top = min(max(preferred, lowest, 0), size.height - height)
        return CGRect(x: 0, y: top, width: size.width, height: height)
    }

    // MARK: Recording

    /// Gets a recording ready for the push: the writer, the heading, and the render callback.
    private func arm() {
        guard let view, let layout else { return }
        do {
            let composer = try composer ?? FrameComposer()
            self.composer = composer
            let size = ShareAspect.story.size
            let crop = Self.crop(in: layout.viewport)
            let (heading, credit) = try Self.overlays(for: layout, crop: crop)
            PileSnapshotRenderer.removeStaleClips()
            let folder = URL.temporaryDirectory.appending(path: "PileVideo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "Dominoes \(layout.title)"
            let writer = try PileMovieWriter(
                url: folder.appending(path: Self.fileName(name) + ".mp4"),
                width: Int(size.width), height: Int(size.height))
            try writer.start()
            let tap = Tap(
                composer: composer, pool: try writer.framePool(), size: size, crop: crop,
                width: layout.viewport.size.width, heading: heading, credit: credit,
                wall: try Self.wall()
            ) { [weak self] picture, frames, id in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.drew(picture, as: frames, in: id) }
                }
            }
            run = Run(tap: tap, writer: writer, folder: folder, name: name)
            view.renderCallbacks.postProcess = { @Sendable context in tap.draw(context) }
        } catch {
            Self.log.error("The recording could not start: \(error)")
            cannotRecord = true
        }
    }

    /// `name` without the characters that file names cannot hold.
    private static func fileName(_ name: String) -> String {
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
    /// beyond it, the oldest is dropped, so a slow encoder never holds up the view.
    private static let backlogLimit = 6

    /// Hands a frame that the GPU has drawn to the encoder, as each of `frames`, and ends the
    /// recording after its last frame.
    private func drew(_ picture: CVReadOnlyPixelBuffer, as frames: ClosedRange<Int>, in id: UUID) {
        guard let run, run.tap.id == id else { return }
        run.tap.state.withLock { $0.drawing -= 1 }
        run.backlog += frames.map { (picture, $0) }
        if run.backlog.count > Self.backlogLimit {
            let dropped = run.backlog.prefix(run.backlog.count - Self.backlogLimit)
            Self.log.notice("The encoder fell behind; dropped \(dropped.count) frames")
            run.backlog.removeFirst(dropped.count)
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
        let hits = DominoMovieTiming.hits(feedback.finishRecording(), shownAt: run.times)
        let began = ContinuousClock.now
        let generation = generation
        Task {
            do {
                try await run.writer.finish(
                    hits: hits, before: .now + PileMovieWriter.finishTimeout)
                guard let poster = composer.cgImage(of: last) else {
                    throw PileSnapshotError.drawingFailed
                }
                let still = run.writer.url.deletingPathExtension().appendingPathExtension("png")
                try await PileSnapshotRenderer.writeStill(poster, identifier: nil, to: still)
                let clip = PileMovie(
                    movie: run.writer.url, still: still, poster: poster, name: run.name)
                Self.log.notice(
                    "Recorded \(run.writer.frameCount) frames and \(hits.count) hits; the movie took \((ContinuousClock.now - began) / .seconds(1), format: .fixed(precision: 2)) s to write"
                )
                // A new chain while the movie was written leaves no place for it.
                guard generation == self.generation else { return clip.remove() }
                self.clip = clip
                #if DEBUG
                    DominoVideoDebug.write(clip)
                #endif
            } catch {
                Self.log.error("The recording could not be written: \(error)")
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
    /// for **Share** when no recording of the run was kept. Replaces the previous one.
    ///
    /// - Throws: `PileSnapshotError` when the view or its snapshot is missing or cannot be
    ///   drawn.
    func snapshot() async throws -> URL {
        guard let view, let layout else { throw PileSnapshotError.drawingFailed }
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
