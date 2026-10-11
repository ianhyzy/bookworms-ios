import Metal
import RealityKit
import SwiftUI

/// A pile video on disk: the movie, and the still of its last frame, which pair as a Live
/// Photo. Both live in a folder of their own in the temporary directory.
struct PileMovie: Sendable {
    let movie: URL
    let still: URL
    /// The last frame, for previews.
    let poster: CGImage
    /// The name to share the movie under, such as "Pile 2025".
    let name: String

    /// Deletes the movie, the still, and their folder.
    func remove() {
        try? FileManager.default.removeItem(at: movie.deletingLastPathComponent())
    }
}

extension PileSnapshotRenderer {
    /// Films `books` falling into a pile under the heading `title`, as a six-second video at the
    /// pixel size of `aspect`, with the knocks of their landings.
    ///
    /// The books, their order, the 150-book limit, the heading, the credit, and the lamp-lit
    /// table are those of `render(books:title:aspect:seed:model:)`, and the render takes its
    /// turn with images: one pile renders at a time, and the live pile steps out meanwhile. The
    /// books drop in the image's groups, 0.4 seconds apart, seen through the framing the image's
    /// drop starts with, but from behind the heading, so they fall into view. A clip shows at
    /// most `PileMovieTiming.shownGroups` groups falling; earlier ones drop before it starts.
    /// The camera then closes in on the settled pile as the image frames it (see
    /// `PileMovieTiming`).
    ///
    /// The simulation runs on the main actor, `PileMovieTiming.stepsPerFrame` steps per frame.
    /// Each frame renders into a Metal texture, which a blit copies into memory (`FrameTarget`);
    /// `PileMovieWriter` copies it into a pixel buffer, draws the heading and credit over it
    /// there, and encodes it. Hits that `ImpactFeedback` would play are recorded, and each
    /// frame's share of the soundtrack is mixed from them (`ImpactMix`) as soon as the frame
    /// shows.
    ///
    /// The render's turn ends with the last frame, so finishing the movie and the still never
    /// holds up the live pile or a share image. Each frame must render and reach the encoder
    /// within `frameTimeout`, and the movie must finish within it too.
    ///
    /// `progress` gets `nil` while fonts and covers load, then the fraction of frames done.
    /// `preview` gets every sixth finished frame at half size, and the last at full size, for
    /// the sheet to show meanwhile. The scene, its textures, and the renderer are released when
    /// the last frame is done, and a failed or cancelled render deletes its files. The first
    /// render of a launch deletes the clips that earlier launches left behind.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, and `PileSnapshotError` when
    ///   Metal or the writer fails, a frame misses `frameTimeout`, or the first frame is one
    ///   flat color.
    static func renderMovie(
        books: [CloudBook], title: String, aspect: ShareAspect, seed: UInt64, model: AppModel,
        progress: (Double?) -> Void, preview: (CGImage) -> Void
    ) async throws -> PileMovie {
        progress(nil)
        let dropped = Array(books.prefix(maximumBooks).reversed())
        guard let layout = PileSnapshotLayout(aspect: aspect, count: dropped.count) else {
            throw PileSnapshotError.drawingFailed
        }
        removeStaleClips()
        let folder = URL.temporaryDirectory.appending(path: "PileVideo-\(UUID().uuidString)")
        let name = "Pile \(title)"
        let file = name.replacing("/", with: "-").replacing(":", with: "-")
        let identifier = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let movie = folder.appending(path: "\(file).mov")
            let still = folder.appending(path: "\(file).jpg")
            try await claim()
            let filmed: (writer: PileMovieWriter, poster: CGImage)
            do {
                defer { release() }
                filmed = try await film(
                    dropped, title: title, count: books.count, layout: layout, seed: seed,
                    model: model, to: movie, identifier: identifier, progress: progress,
                    preview: preview)
            }
            try await filmed.writer.finish(before: .now + frameTimeout)
            try await writeStill(filmed.poster, identifier: identifier, to: still)
            return PileMovie(movie: movie, still: still, poster: filmed.poster, name: name)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// How long one frame may take to render and reach the encoder: far longer than a frame
    /// takes, even the first, which compiles shaders.
    private static let frameTimeout = Duration.seconds(10)

    /// Whether this launch has deleted the clips that earlier ones left behind.
    private static var removedStaleClips = false

    /// Deletes the clips that earlier launches left behind, once per launch. A clip outlives
    /// its sheet only when the app ends with the sheet open; a clip of this launch can still be
    /// playing, sharing, or saving.
    private static func removeStaleClips() {
        guard !removedStaleClips else { return }
        removedStaleClips = true
        let files = FileManager.default
        let leftovers =
            (try? files.contentsOfDirectory(
                at: .temporaryDirectory, includingPropertiesForKeys: nil))
            ?? []
        for stale in leftovers where stale.lastPathComponent.hasPrefix("PileVideo-") {
            try? files.removeItem(at: stale)
        }
    }

    /// Encodes the still away from the main actor.
    @concurrent
    nonisolated private static func writeStill(
        _ image: CGImage, identifier: String, to url: URL
    ) async throws {
        try PileMovieWriter.writeStill(image, identifier: identifier, to: url)
    }

    /// Drops the books in front of the camera, writes each frame and its sound to `url`, and
    /// returns the writer, for the caller to finish the movie, and the last frame.
    private static func film(
        _ books: [CloudBook], title: String, count: Int, layout: PileSnapshotLayout,
        seed: UInt64, model: AppModel, to url: URL, identifier: String,
        progress: (Double?) -> Void, preview: (CGImage) -> Void
    ) async throws -> (writer: PileMovieWriter, poster: CGImage) {
        let width = Int(layout.aspect.size.width)
        let height = Int(layout.aspect.size.height)
        let target = try FrameTarget(width: width, height: height)
        guard let overlay = overlay(title: title, count: count, layout: layout) else {
            throw PileSnapshotError.drawingFailed
        }

        let scene = BookPileScene(textureScale: layout.textureScale)
        let renderer = try RealityRenderer()
        renderer.entities.append(scene.root)
        defer { renderer.entities.removeAll() }
        renderer.activeCamera = scene.camera
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.isToneMappingEnabled = true
        // `RealityRenderer.update`, which runs on the main actor, delivers collisions as it
        // steps, so each is recorded at its step's time. One delivered elsewhere goes unheard
        // rather than stopping the app.
        let collisions = renderer.subscribe(to: CollisionEvents.Began.self) { event in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { scene.collide(event) }
        }
        defer { collisions.cancel() }
        await scene.prepareFilm(
            books, on: layout.tray, camera: layout.camera, aspect: Float(width) / Float(height),
            model: model)
        try Task.checkCancellation()

        func step() throws {
            scene.feedback.advance(by: PileMovieTiming.stepDuration)
            try renderer.update(PileMovieTiming.stepDuration)
        }
        let groups = PileLayout.settleGroups(books, in: layout.tray, seed: seed)
        let schedule = PileMovieTiming.schedule(groups: groups.count)
        // Out of view, the earlier groups drop as for an image, from just above every book so
        // far, so none starts inside a stack that has just landed. The walls stay up through
        // the clip: without them, a big pile slumps across the table.
        if schedule.preroll > 0 {
            let steps = PileMovieTiming.groupFrames * PileMovieTiming.stepsPerFrame
            for group in groups.prefix(schedule.preroll) {
                _ = scene.drop(group, base: 0, above: [])
                for _ in 0..<steps { try step() }
                try Task.checkCancellation()
                await Task.yield()
            }
            for _ in 0..<PileMovieTiming.prerollSettleSteps { try step() }
        }

        let headingY = 1 - 2 * Float(layout.pileTop / layout.aspect.size.height)
        let nearestZ = groups[schedule.preroll...].joined().map(\.transform.translation.z).max()
        let base = PileMovieTiming.dropBase(
            camera: layout.camera, headingY: headingY, nearestZ: nearestZ ?? 0)
        let lastDrop = schedule.frames.last ?? 0

        let writer = try PileMovieWriter(
            url: url, width: width, height: height, identifier: identifier)
        let last = PileMovieTiming.frameCount - 1
        do {
            try await writer.start(stillFrame: last, before: .now + frameTimeout)
            var next = schedule.preroll
            var falling: Set<Entity.ID> = []
            var poster: CGImage?
            scene.feedback.startRecording()
            for frame in 0...last {
                try Task.checkCancellation()
                // Every wait of the frame ends by this deadline, so a frame that never renders
                // or an encoder that stops taking frames cannot hold the render's turn.
                let deadline = ContinuousClock.now + frameTimeout
                while next < groups.count, schedule.frames[next - schedule.preroll] <= frame {
                    falling = scene.drop(groups[next], base: base, above: falling)
                    next += 1
                }
                let push = PileMovieTiming.push(atFrame: frame, lastDrop: lastDrop)
                if push > 0 {
                    // Framed afresh each frame, so the camera follows books that still slide.
                    let framed = layout.camera.framing(
                        scene.bookCorners, in: layout.pileRect, of: layout.aspect.size,
                        zoomRange: 0.25...layout.camera.zoom * 1.25)
                    scene.look(through: layout.camera.mixed(with: framed, push))
                }
                for _ in 1..<PileMovieTiming.stepsPerFrame { try step() }
                scene.feedback.advance(by: PileMovieTiming.stepDuration)
                let signal = UInt64(frame + 1)
                try renderer.updateAndRender(
                    deltaTime: PileMovieTiming.stepDuration, cameraOutput: target.output,
                    actionsAfterRender: [.signal(target.event, value: signal)])
                try await target.read(after: signal, before: deadline)
                if frame == 0, target.isBlank { throw PileSnapshotError.drawingFailed }
                let start = frame * PileMovieTiming.samplesPerFrame
                writer.appendSound(
                    ImpactMix.samples(
                        scene.feedback.recorded,
                        in: start..<start + PileMovieTiming.samplesPerFrame),
                    at: start)
                let snapshot = try await writer.appendFrame(
                    target.buffer.contents(), bytesPerRow: target.bytesPerRow, overlay: overlay,
                    at: frame, snapshot: frame == last ? 1 : frame % 6 == 0 ? 2 : nil,
                    before: deadline)
                if let snapshot { preview(snapshot) }
                if frame == last { poster = snapshot }
                progress(Double(frame + 1) / Double(PileMovieTiming.frameCount))
            }
            _ = scene.feedback.finishRecording()
            guard let poster else { throw PileSnapshotError.drawingFailed }
            return (writer, poster)
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// The heading and the credit of a pile image, without the pile, in Display P3, to draw
    /// over each frame.
    private static func overlay(title: String, count: Int, layout: PileSnapshotLayout)
        -> CGImage?
    {
        let renderer = ImageRenderer(
            content: PileSnapshotCard(pile: nil, title: title, count: count, layout: layout))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage.flatMap(PileMovieOverlay.displayP3)
    }
}

/// Where `RealityRenderer` draws a video's frames, and where the CPU reads them.
///
/// RealityKit renders into a private `bgra8Unorm_srgb` texture, as for still images, and a blit
/// copies each frame into a shared buffer once the render signals `event`. The frames have
/// Display P3 primaries with the sRGB transfer curve.
///
/// If the render never signals, the copy would wait forever, and with it the render's turn
/// that the live pile and every share image wait on. `read(after:before:)` therefore signals
/// the event itself at its deadline.
@MainActor
private struct FrameTarget {
    let event: any MTLSharedEvent
    let output: RealityRenderer.CameraOutput
    let buffer: any MTLBuffer
    let bytesPerRow: Int
    private let queue: any MTLCommandQueue
    private let texture: any MTLTexture

    init(width: Int, height: Int) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        bytesPerRow = (width * 4 + 255) / 256 * 256
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
            let event = device.makeSharedEvent(),
            let texture = device.makeTexture(descriptor: descriptor),
            let buffer = device.makeBuffer(
                length: bytesPerRow * height, options: .storageModeShared)
        else { throw PileSnapshotError.drawingFailed }
        self.queue = queue
        self.event = event
        self.texture = texture
        self.buffer = buffer
        output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
    }

    /// Copies the frame into `buffer` once the render signals `event` with `value`, and waits
    /// for the copy, even when the task is cancelled, so the render never ends while RealityKit
    /// still draws into the texture.
    ///
    /// - Throws: `PileSnapshotError` when the frame did not render by `deadline` or the copy
    ///   failed.
    func read(after value: UInt64, before deadline: ContinuousClock.Instant) async throws {
        guard let commands = queue.makeCommandBuffer() else {
            throw PileSnapshotError.drawingFailed
        }
        commands.encodeWaitForEvent(event, value: value)
        guard let blit = commands.makeBlitCommandEncoder() else {
            throw PileSnapshotError.drawingFailed
        }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        let event = self.event
        let watchdog = Task {
            guard (try? await Task.sleep(until: deadline)) != nil, event.signaledValue < value
            else { return false }
            event.signaledValue = value
            return true
        }
        await withCheckedContinuation { continuation in
            commands.addCompletedHandler { _ in continuation.resume() }
            commands.commit()
        }
        watchdog.cancel()
        guard await !watchdog.value, commands.status == .completed else {
            throw PileSnapshotError.drawingFailed
        }
    }

    /// Whether the frame in `buffer` is one flat color, as a renderer that drew nothing leaves
    /// it.
    var isBlank: Bool {
        PileSnapshotRenderer.isBlank(
            Data(bytesNoCopy: buffer.contents(), count: buffer.length, deallocator: .none),
            width: texture.width, height: texture.height, bytesPerRow: bytesPerRow)
    }
}
