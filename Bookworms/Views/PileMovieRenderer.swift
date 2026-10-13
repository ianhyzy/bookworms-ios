import CoreImage
import Metal
import RealityKit
import SwiftUI
import os

/// A video on disk: the MP4 to share, and the still of its last frame. A pile video's still
/// is a JPEG that pairs with `livePhoto`, the movie's QuickTime copy, as a Live Photo; a
/// dominoes run's still is a PNG to share. The files live in a folder of their own in the
/// temporary directory.
struct PileMovie: Sendable {
    let movie: URL
    let still: URL
    /// The Live Photo's movie, for a pile video.
    var livePhoto: URL?
    /// The last frame, for previews.
    let poster: CGImage
    /// The name to share the movie under, such as "Desk 2025".
    let name: String

    /// Deletes the movie, the still, and their folder.
    func remove() {
        try? FileManager.default.removeItem(at: movie.deletingLastPathComponent())
    }
}

extension PileSnapshotRenderer {
    /// Films `books` falling into place under the heading `title`, as a six-second video at the
    /// pixel size of `aspect`, with the knocks of their landings.
    ///
    /// The books, the 150-book limit, the heading, the credit, the lamp-lit table, and the
    /// camera are those of `render(books:title:aspect:seed:model:)`, and the render takes its
    /// turn with images: one pile renders at a time, and the live pile steps out meanwhile. Each
    /// book falls from behind the heading straight onto its place in the image's spread, in the
    /// order the books go down, so the last frame is the image (see `PileMovieTiming`). The
    /// books are kinematic: the video moves them along their falls, and plays each landing's
    /// knock itself.
    ///
    /// The scene steps on the main actor, `PileMovieTiming.stepsPerFrame` steps per frame.
    /// Each frame renders into a Metal texture (`FrameTarget`), and `FrameComposer` draws it,
    /// with the heading and credit over it, into a pixel buffer that `PileMovieWriter` encodes.
    /// Hits that `ImpactFeedback` would play are recorded, and the soundtrack is mixed from
    /// them (`ImpactMix`) once the frames are done. The movie is an MP4 to share, with a
    /// QuickTime copy and a JPEG of the last frame that pair as a Live Photo.
    ///
    /// The render's turn ends with the last frame, so finishing the movie and the still never
    /// holds up the live pile or a share image. Each frame must render and reach the encoder
    /// within `frameTimeout`, and the movie must finish within `PileMovieWriter.finishTimeout`.
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
        let shown = Array(books.prefix(maximumBooks))
        let layout = PileSnapshotLayout(aspect: aspect, count: shown.count)
        removeStaleClips()
        let folder = URL.temporaryDirectory.appending(path: "PileVideo-\(UUID().uuidString)")
        let name = "Desk \(title)"
        let file = name.replacing("/", with: "-").replacing(":", with: "-")
        let identifier = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let movie = folder.appending(path: "\(file).mp4")
            let still = folder.appending(path: "\(file).jpg")
            try await claim()
            let filmed: (writer: PileMovieWriter, poster: CGImage, hits: [ImpactRecord])
            do {
                defer { release() }
                filmed = try await film(
                    shown, title: title, count: books.count, layout: layout, seed: seed,
                    model: model, to: movie, progress: progress, preview: preview)
            }
            try await filmed.writer.finish(
                hits: filmed.hits, livePhoto: identifier,
                before: .now + PileMovieWriter.finishTimeout)
            try await writeStill(filmed.poster, identifier: identifier, to: still)
            return PileMovie(
                movie: movie, still: still, livePhoto: PileMovieWriter.livePhotoURL(for: movie),
                poster: filmed.poster, name: name)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// How long one frame may take to render and reach the encoder: far longer than a frame
    /// takes, even the first, which compiles shaders.
    static let frameTimeout = Duration.seconds(10)

    /// Whether this launch has deleted the clips that earlier ones left behind.
    private static var removedStaleClips = false

    /// Deletes the clips that earlier launches left behind, once per launch. A clip outlives
    /// its sheet only when the app ends with the sheet open; a clip of this launch can still be
    /// playing, sharing, or saving.
    static func removeStaleClips() {
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
    nonisolated static func writeStill(
        _ image: CGImage, identifier: String?, to url: URL
    ) async throws {
        try PileMovieWriter.writeStill(image, identifier: identifier, to: url)
    }

    /// Drops the books into the image's spread in front of the camera, writes each frame and its
    /// sound to `url`, and returns the writer, for the caller to finish the movie, and the last
    /// frame.
    private static func film(
        _ books: [CloudBook], title: String, count: Int, layout: PileSnapshotLayout,
        seed: UInt64, model: AppModel, to url: URL, progress: (Double?) -> Void,
        preview: (CGImage) -> Void
    ) async throws -> (writer: PileMovieWriter, poster: CGImage, hits: [ImpactRecord]) {
        let size = layout.aspect.size
        let width = Int(size.width)
        let height = Int(size.height)
        let target = try FrameTarget(width: width, height: height)
        let composer = try FrameComposer()
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
        let spread = await scene.prepareSpread(
            books, in: layout.pileRect, of: layout.aspect.size, seed: seed, model: model)
        try Task.checkCancellation()

        // Each book's fall: from straight above its place, high enough that the heading hides
        // it, turned a little about the vertical and tipped about a level axis.
        let headingY = 1 - 2 * Float(layout.pileTop / layout.aspect.size.height)
        let aspect = Float(width) / Float(height)
        let falls = zip(spread.slots, spread.shapes)
            .map { slot, shape in
                let half = shape.size / 2
                let corners = (0..<8)
                    .map { corner in
                        slot.transform.translation
                            + slot.transform.rotation.act(
                                SIMD3(
                                    corner & 1 == 0 ? -half.x : half.x,
                                    corner & 2 == 0 ? -half.y : half.y,
                                    corner & 4 == 0 ? -half.z : half.z))
                    }
                func random(_ salt: UInt64) -> Float {
                    Float(ShareStyle.unit(seed, slot.book.id, salt)) * 2 - 1
                }
                let axis = random(51) * .pi
                let height =
                    PileMovieTiming.startHeight(
                        of: corners, camera: spread.camera, headingY: headingY, aspect: aspect)
                    + 0.3
                let (duration, speed) = PileMovieTiming.fall(height: height)
                return (
                    rest: slot.transform, height: height, duration: duration, speed: speed,
                    turn: simd_quatf(angle: random(52) * 0.4, axis: [0, 1, 0])
                        * simd_quatf(angle: random(53) * 0.25, axis: [cos(axis), 0, sin(axis)])
                )
            }
        let landings = PileMovieTiming.landings(falls.map(\.duration))
        func pose(_ index: Int, at time: Float) -> Transform {
            let fall = falls[index]
            return PileMovieTiming.pose(
                rest: fall.rest, height: fall.height, duration: fall.duration, turn: fall.turn,
                landing: landings[index], at: time)
        }
        let placed = scene.place(
            spread.slots.indices.map { index in
                var start = spread.slots[index]
                start.transform = pose(index, at: 0)
                return start
            }, mode: .kinematic)
        guard placed.count == falls.count else { throw PileSnapshotError.drawingFailed }

        // Moves the falling books to where they are one step later, and plays the knocks of the
        // books that land in that step. A book shows only once its fall begins, so books waiting
        // behind the heading cast no shadows on the table.
        var steps = 0
        var landed = 0
        func step() {
            steps += 1
            let time = Float(Double(steps) * PileMovieTiming.stepDuration)
            scene.feedback.advance(by: PileMovieTiming.stepDuration)
            for index in landed..<placed.count {
                placed[index].transform = pose(index, at: time)
                placed[index].isEnabled = time >= landings[index] - falls[index].duration
            }
            while landed < placed.count, landings[landed] <= time {
                scene.land(placed[landed], speed: falls[landed].speed)
                landed += 1
            }
        }

        let writer = try PileMovieWriter(url: url, width: width, height: height)
        let last = PileMovieTiming.frameCount - 1
        do {
            try writer.start()
            let pool = try writer.framePool()
            var poster: CGImage?
            scene.feedback.startRecording()
            for frame in 0...last {
                try Task.checkCancellation()
                // Every wait of the frame ends by this deadline, so a frame that never renders
                // or an encoder that stops taking frames cannot hold the render's turn.
                let deadline = ContinuousClock.now + frameTimeout
                for _ in 1..<PileMovieTiming.stepsPerFrame {
                    step()
                    try renderer.update(PileMovieTiming.stepDuration)
                }
                step()
                let signal = UInt64(frame + 1)
                try renderer.updateAndRender(
                    deltaTime: PileMovieTiming.stepDuration, cameraOutput: target.output,
                    actionsAfterRender: [.signal(target.event, value: signal)])
                if frame == 0 {
                    try await target.read(after: signal, before: deadline)
                    if target.isBlank { throw PileSnapshotError.drawingFailed }
                }
                let picture = CVReadOnlyPixelBuffer(try pool.makeMutablePixelBuffer())
                try await target.run(after: signal, before: deadline) { commands in
                    guard let render = composer.image(of: target.texture) else {
                        throw PileSnapshotError.drawingFailed
                    }
                    try composer.render(
                        composer.frame(
                            of: render, crop: CGRect(origin: .zero, size: size), size: size,
                            overlays: [(overlay, 1)]),
                        into: picture, on: commands)
                }
                let snapshot =
                    frame == last
                    ? composer.cgImage(of: picture)
                    : frame % 6 == 0 ? composer.cgImage(of: picture, scale: 0.5) : nil
                try await writer.append(picture, at: frame, before: deadline)
                if let snapshot { preview(snapshot) }
                if frame == last { poster = snapshot }
                progress(Double(frame + 1) / Double(PileMovieTiming.frameCount))
            }
            let hits = scene.feedback.finishRecording()
            #if DEBUG
                scene.logCovers("video seed \(seed), \(books.count) books")
                scene.logSpread("video seed \(seed)", in: layout.pileRect, of: layout.aspect.size)
            #endif
            guard let poster else { throw PileSnapshotError.drawingFailed }
            return (writer, poster, hits)
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// The heading and the credit of a pile image, without the pile, to draw over each frame.
    private static func overlay(title: String, count: Int, layout: PileSnapshotLayout)
        -> CIImage?
    {
        let renderer = ImageRenderer(
            content: PileSnapshotCard(pile: nil, title: title, count: count, layout: layout))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage.map { CIImage(cgImage: $0) }
    }
}

/// Where `RealityRenderer` draws a pile image's or video's frames, and where the CPU reads them.
///
/// RealityKit renders into a private `bgra8Unorm_srgb` texture. Once the render signals
/// `event`, a blit copies the frame into a shared buffer (`read(after:before:)`), or other GPU
/// work, such as drawing a video frame, reads the texture (`run(after:before:_:)`). The frames
/// have Display P3 primaries with the sRGB transfer curve.
///
/// If the render never signals, that work would wait forever, and with it the render's turn
/// that the live pile and every share image wait on. `run(after:before:_:)` therefore signals
/// the event itself at its deadline.
@MainActor
struct FrameTarget {
    nonisolated private static let log = Logger(
        subsystem: "gay.ian.Bookworms.iOS", category: "video")
    let event: any MTLSharedEvent
    let output: RealityRenderer.CameraOutput
    let buffer: any MTLBuffer
    let bytesPerRow: Int
    let texture: any MTLTexture
    private let queue: any MTLCommandQueue

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

    /// Copies the frame into `buffer` once the render signals `event` with `value` (see
    /// `run(after:before:_:)`).
    func read(after value: UInt64, before deadline: ContinuousClock.Instant) async throws {
        try await run(after: value, before: deadline) { commands in
            guard let blit = commands.makeBlitCommandEncoder() else {
                throw PileSnapshotError.drawingFailed
            }
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerRow * texture.height)
            blit.endEncoding()
        }
    }

    /// Runs the GPU work that `encode` adds to a command buffer once the render signals
    /// `event` with `value`, and waits for it, even when the task is cancelled, so the render
    /// never ends while RealityKit still draws into the texture.
    ///
    /// - Throws: `PileSnapshotError` when the frame did not render by `deadline` or the work
    ///   failed, and the errors of `encode`.
    func run(
        after value: UInt64, before deadline: ContinuousClock.Instant,
        _ encode: (any MTLCommandBuffer) throws -> Void
    ) async throws {
        guard let commands = queue.makeCommandBuffer() else {
            throw PileSnapshotError.drawingFailed
        }
        commands.encodeWaitForEvent(event, value: value)
        try encode(commands)
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
            Self.log.error(
                "A frame did not render by its deadline (status \(commands.status.rawValue))")
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
