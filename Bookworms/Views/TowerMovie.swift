import CoreImage
import RealityKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The topple clip's timeline, in frames at `PileMovieTiming.framesPerSecond`: the still holds,
/// the tower tips over under the physics engine while the tape zips back into its case, the
/// fallen books hold, and the clip rewinds to the still, so it loops.
enum TowerMovieTiming {
    /// The still before the push: 0.4 seconds.
    static let hold = 12
    /// The fall, from the push until the books lie still: 1.4 seconds.
    static let fall = 42
    /// The fallen books, before the rewind: 0.3 seconds.
    static let rest = 9
    /// The rewind to the still: 0.8 seconds.
    static let rewind = 24
    /// How long the tape takes to zip back into its case after the push.
    static let retract = 18
    /// How long the loupe takes to fade out at the push and in at the end of the rewind.
    static let fade = 6

    static var frameCount: Int { hold + fall + rest + rewind }

    /// Which recorded frame of the hold and the fall a frame of the clip shows: the frame
    /// itself until the fallen books' hold ends, and then the recorded frames backward, easing
    /// in and out, to frame 0 on the clip's last frame.
    static func source(of frame: Int) -> Int {
        let recorded = hold + fall - 1
        let rewinding = frame - hold - fall - rest + 1
        guard rewinding > 0 else { return min(frame, recorded) }
        let fraction = Float(rewinding) / Float(rewind)
        let eased = fraction * fraction * (3 - 2 * fraction)
        return Int((Float(recorded) * (1 - eased)).rounded())
    }

    /// How much the loupe shows on a frame of the clip, from 0 to 1.
    static func loupeOpacity(at frame: Int) -> CGFloat {
        let out = CGFloat(frame - hold) / CGFloat(fade)
        let back = CGFloat(frame - (frameCount - 1 - fade)) / CGFloat(fade)
        return min(max(1 - out, back, 0), 1)
    }

    /// The fraction of the tape still out of its case `frame` frames into the recording.
    static func tapeOut(at frame: Int) -> Float {
        let fraction = Float(frame - hold) / Float(retract)
        let eased = min(max(fraction, 0), 1)
        return 1 - eased * eased
    }
}

extension TowerSnapshotRenderer {
    /// Films the tower toppling as a short clip that loops to the still: `TowerMovieTiming`
    /// sets its parts. The headline, the credit, and the books are the still's, and the clip
    /// takes its turn with images and other videos, as `PileSnapshotRenderer.renderMovie`
    /// does, and writes the same files, an MP4 with a Live Photo still.
    ///
    /// The books turn dynamic at the push, which tips the whole tower about its base, away
    /// from the tape and the camera, by an amount `seed` varies a little. The physics engine
    /// then steps at a fixed rate from the same poses, so the same books and seed make the
    /// same clip. Each frame frames the books where they lie (`TowerCamera.framing`), easing
    /// the camera back as they spread so the falling books stay in view. The knocks of the
    /// books' hits are recorded and mixed into the soundtrack (`ImpactMix`). The rewind plays
    /// the recorded poses backward, in silence.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, and `PileSnapshotError` when
    ///   Metal or the writer fails or a frame misses `PileSnapshotRenderer.frameTimeout`.
    static func renderMovie(
        books: [CloudBook], title: String, aspect: ShareAspect, seed: UInt64, model: AppModel,
        progress: (Double?) -> Void, preview: (CGImage) -> Void
    ) async throws -> PileMovie {
        progress(nil)
        PileSnapshotRenderer.removeStaleClips()
        let folder = PileSnapshotRenderer.newClipFolder()
        let name = "\(ShareTemplate.tower.title) \(title)"
        let file = name.replacing("/", with: "-").replacing(":", with: "-")
        let identifier = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let movie = folder.appending(path: "\(file).mp4")
            let still = folder.appending(path: "\(file).jpg")
            try await PileSnapshotRenderer.claim()
            let filmed: (writer: PileMovieWriter, poster: CGImage, hits: [ImpactRecord])
            do {
                defer { PileSnapshotRenderer.release() }
                let stage = try await TowerStage(
                    books: books, aspect: aspect, seed: seed, model: model)
                defer { stage.renderer.entities.removeAll() }
                filmed = try await film(
                    stage, title: title, seed: seed, to: movie, progress: progress,
                    preview: preview)
            }
            try await filmed.writer.finish(
                hits: filmed.hits, livePhoto: identifier,
                before: .now + PileMovieWriter.finishTimeout)
            try await PileSnapshotRenderer.writeStill(
                filmed.poster, identifier: identifier, to: still)
            return PileMovie(
                movie: movie, still: still, livePhoto: PileMovieWriter.livePhotoURL(for: movie),
                name: name)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Films the stage, writes each frame and its knocks to `url`, and returns the writer, for
    /// the caller to finish the movie, and the last frame.
    private static func film(
        _ stage: TowerStage, title: String, seed: UInt64, to url: URL,
        progress: (Double?) -> Void, preview: (CGImage) -> Void
    ) async throws -> (writer: PileMovieWriter, poster: CGImage, hits: [ImpactRecord]) {
        let layout = stage.layout
        let size = layout.aspect.size
        let aspect = Float(size.width / size.height)
        let composer = try FrameComposer()
        let still = try await stage.renderStill()
        let facts = stage.facts(title: title)
        func layer(_ card: TowerSnapshotCard) -> CIImage? {
            let renderer = ImageRenderer(content: card)
            renderer.scale = 1
            renderer.isOpaque = false
            return renderer.cgImage.map { CIImage(cgImage: $0) }
        }
        guard
            let backdrop = layer(
                TowerSnapshotCard(
                    tower: nil, loupe: nil, facts: facts, layout: layout, theme: stage.theme,
                    showsHeadline: false, showsCredit: false)),
            let headline = layer(
                TowerSnapshotCard(
                    tower: nil, loupe: nil, facts: facts, layout: layout, theme: stage.theme,
                    showsBackdrop: false)),
            let loupe = layer(
                TowerSnapshotCard(
                    tower: nil, loupe: still.loupe, facts: facts, layout: layout,
                    theme: stage.theme, topPoint: stage.topPoint, showsBackdrop: false,
                    showsHeadline: false, showsCredit: false))
        else { throw PileSnapshotError.drawingFailed }

        let scene = stage.scene
        let books = stage.books
        let shapes = books.map { book in
            scene.bookID(for: book).flatMap(scene.shape(of:))?.size ?? .zero
        }
        // Tips the tower back and toward the tape's side, about 40 degrees from the image's
        // plane, so it falls clear of the worm and away from the camera, and the fallen books
        // run into the distance rather than across a narrow frame.
        let away = 0.7 + (Float(ShareStyle.unit(seed, 0, 93)) - 0.5) * 0.35
        let pushAxis = SIMD3<Float>(-sin(away), 0, cos(away))
        let pushSpeed = 0.5 + Float(ShareStyle.unit(seed, 0, 94)) * 0.2

        // The fall, simulated first, so each frame's camera can see where the books go next.
        let recorded = TowerMovieTiming.hold + TowerMovieTiming.fall
        var poses = [[Transform]](
            repeating: books.map(\.transform), count: TowerMovieTiming.hold + 1)
        var speeds = [Float](repeating: 0, count: books.count)
        var lastKnock = [Int](repeating: -10, count: books.count)
        scene.feedback.startRecording()
        for _ in 0..<(TowerMovieTiming.hold * PileMovieTiming.stepsPerFrame) {
            scene.feedback.advance(by: PileMovieTiming.stepDuration)
        }
        for book in books { book.components[PhysicsBodyComponent.self]?.mode = .dynamic }
        // The bodies take their new mode in the next step, which would drop velocities set now.
        scene.feedback.advance(by: PileMovieTiming.stepDuration)
        try stage.renderer.update(PileMovieTiming.stepDuration)
        // Each book takes the velocity it would have if the tower turned as one body about
        // its base.
        for book in books {
            let arm = book.position(relativeTo: scene.root)
            let mass = book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0.5
            book.applyLinearImpulse(
                simd_cross(pushAxis * pushSpeed, arm) * mass, relativeTo: scene.root)
        }
        for frame in (TowerMovieTiming.hold + 1)..<recorded {
            try Task.checkCancellation()
            for _ in 0..<PileMovieTiming.stepsPerFrame {
                scene.feedback.advance(by: PileMovieTiming.stepDuration)
                try stage.renderer.update(PileMovieTiming.stepDuration)
            }
            // A book that slows sharply in a frame hit something: its knock plays, at most once
            // every few frames.
            for (index, book) in books.enumerated() {
                let speed = simd_length(
                    book.components[PhysicsMotionComponent.self]?.linearVelocity ?? .zero)
                if speeds[index] - speed > 1.2, frame - lastKnock[index] > 4 {
                    scene.land(book, speed: speeds[index] - speed)
                    lastKnock[index] = frame
                }
                speeds[index] = speed
            }
            poses.append(books.map(\.transform))
        }
        let hits = scene.feedback.finishRecording()
        for book in books { book.components[PhysicsBodyComponent.self]?.mode = .kinematic }

        // Each frame's camera frames the books where they lie a few frames ahead, so the
        // falling books never leave the view, over the image's full width once the loupe fades.
        // It never comes nearer during the fall, and rises from the still's low eye to look
        // down on the fallen books, easing there from the still's camera.
        let wide = CGRect(
            x: layout.aspect.insets.leading, y: layout.towerRect.minY,
            width: size.width - 2 * layout.aspect.insets.leading,
            height: layout.towerRect.height)
        var cameras = [TowerCamera](repeating: stage.camera, count: TowerMovieTiming.hold + 1)
        for frame in (TowerMovieTiming.hold + 1)..<recorded {
            let ahead = poses[min(frame + 6, recorded - 1)]
            let corners = zip(ahead, shapes).flatMap { pose, size in
                (0..<8).map { corner -> SIMD3<Float> in
                    let sign = SIMD3<Float>(
                        corner & 1 == 0 ? -1 : 1, corner & 2 == 0 ? -1 : 1, corner & 4 == 0 ? -1 : 1)
                    return pose.translation + pose.rotation.act(sign * size / 2)
                }
            }
            let fraction = min(Float(frame - TowerMovieTiming.hold) / 40, 1)
            let rise = fraction * fraction * (3 - 2 * fraction)
            let low = stage.camera.eye.y
            let eye = low + (stage.tower.stackHeight * 1.6 - low) * rise
            let fit = TowerCamera.framing(
                corners + stage.props.extent, eyeHeight: max(eye, stage.camera.eye.y), in: wide,
                of: size)
            // Backs away quickly, and comes nearer slowly once the books lie low.
            let previous = cameras[frame - 1]
            let backs =
                simd_distance(fit.eye, fit.target) > simd_distance(previous.eye, previous.target)
            cameras.append(previous.mixed(with: fit, backs ? 0.3 : 0.08))
        }

        let tapeLength = stage.props.blade.scale.y
        let bladeX = stage.props.blade.position.x
        let hookOffset =
            stage.props.hook.position - [bladeX, stage.props.slotHeight + tapeLength, 0]
        func setTape(_ out: Float) {
            let length = max(tapeLength * out, 0.001)
            let blade = stage.props.blade
            blade.scale.y = length
            blade.position.y = stage.props.slotHeight + length / 2
            blade.isEnabled = out > 0.01
            TowerProps.setLength(length, of: blade)
            stage.props.hook.position = [bladeX, stage.props.slotHeight + length, 0] + hookOffset
        }

        let writer = try PileMovieWriter(
            url: url, width: Int(size.width), height: Int(size.height))
        let last = TowerMovieTiming.frameCount - 1
        do {
            try writer.start()
            let pool = try writer.framePool()
            var poster: CGImage?
            for frame in 0...last {
                try Task.checkCancellation()
                let deadline = ContinuousClock.now + PileSnapshotRenderer.frameTimeout
                let source = TowerMovieTiming.source(of: frame)
                for (book, pose) in zip(books, poses[source]) { book.transform = pose }
                setTape(TowerMovieTiming.tapeOut(at: source))
                scene.look(from: cameras[source].transform, aspect: aspect)
                let signal = UInt64(frame + 10)
                try stage.renderer.updateAndRender(
                    deltaTime: PileMovieTiming.stepDuration, cameraOutput: stage.target.output,
                    actionsAfterRender: [.signal(stage.target.event, value: signal)])
                let picture = CVReadOnlyPixelBuffer(try pool.makeMutablePixelBuffer())
                let opacity = TowerMovieTiming.loupeOpacity(at: frame)
                try await stage.target.run(after: signal, before: deadline) { commands in
                    guard let render = composer.image(of: stage.target.texture) else {
                        throw PileSnapshotError.drawingFailed
                    }
                    try composer.render(
                        composer.frame(
                            of: render, crop: CGRect(origin: .zero, size: size), size: size,
                            background: backdrop, overlays: [(loupe, opacity), (headline, 1)]),
                        into: picture, on: commands)
                }
                let snapshot =
                    frame == last
                    ? composer.cgImage(of: picture)
                    : frame % 6 == 0 ? composer.cgImage(of: picture, scale: 0.5) : nil
                try await writer.append(picture, at: frame, before: deadline)
                if let snapshot { preview(snapshot) }
                if frame == last { poster = snapshot }
                progress(Double(frame + 1) / Double(TowerMovieTiming.frameCount))
            }
            guard let poster else { throw PileSnapshotError.drawingFailed }
            return (writer, poster, hits)
        } catch {
            writer.cancel()
            throw error
        }
    }
}

extension TowerCamera {
    /// The camera `fraction` of the way from this one to `other`.
    func mixed(with other: TowerCamera, _ fraction: Float) -> TowerCamera {
        TowerCamera(
            eye: eye + (other.eye - eye) * fraction,
            target: target + (other.target - target) * fraction)
    }
}
