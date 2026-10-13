import RealityKit
import SwiftUI
import os

/// The heading over a dominoes finale, in the share images' style: the time frame, and the
/// books and their pages, such as "39 books · 18,683 pages". `scale` sizes it from the
/// 1080-pixel-wide share image, at 1, down to the live view, and `insets.top` keeps the heading
/// clear of the bars. An exported image or video `showsCredit`, as the share images do, at the
/// very bottom of the frame; the live view does not.
struct DominoFinaleCard: View {
    let title: String
    let count: Int
    let pages: Int
    let scale: CGFloat
    let insets: EdgeInsets
    var showsCredit = false

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
        .overlay(alignment: .bottom) {
            if showsCredit {
                Text("Created with Bookworms for iPhone")
                    .font(.system(size: 24 * scale, weight: .medium))
                    .foregroundStyle(ShareStyle.cream.color.opacity(0.45))
                    .shadow(color: .black.opacity(0.35), radius: 3 * scale)
                    .padding(.bottom, 18 * scale)
            }
        }
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

extension PileSnapshotRenderer {
    nonisolated private static let log = Logger(
        subsystem: "gay.ian.Bookworms.iOS", category: "video")

    /// Films a run of the dominoes of `books`, from the standing chain through the push, the
    /// fall, the Follow camera's reveal, and the gathering into the spread under the heading
    /// `title`, as a story-size video with the hits' sounds, within `DominoMovieTiming.longest`
    /// seconds, and a still of its last frame.
    ///
    /// The chain is a new `DominoScene` without a view, stood up at once and filmed by the
    /// Follow camera, whose establishing move opens the clip; the push comes once it lands on
    /// the first book, and a stalled chain is pushed on. The frames, sound, and files are made
    /// as `renderMovie(books:title:aspect:seed:model:progress:preview:)` makes a pile's, and the
    /// render takes its turn with pile images and videos. `progress` gets `nil` while the
    /// books stand up, then an estimate of the share of frames done.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, and `PileSnapshotError` when
    ///   Metal or the writer fails, a frame misses its deadline, or the first frame is blank.
    static func renderDominoMovie(
        books: [CloudBook], title: String, model: AppModel, progress: (Double?) -> Void,
        preview: (CGImage) -> Void
    ) async throws -> PileMovie {
        progress(nil)
        removeStaleClips()
        let folder = URL.temporaryDirectory.appending(path: "PileVideo-\(UUID().uuidString)")
        let name = "Dominoes \(title)"
        let file = name.replacing("/", with: "-").replacing(":", with: "-")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let movie = folder.appending(path: "\(file).mov")
            let still = folder.appending(path: "\(file).jpg")
            try await claim()
            let filmed: (writer: PileMovieWriter, poster: CGImage, hits: [ImpactRecord])
            do {
                defer { release() }
                filmed = try await filmDominoes(
                    books, title: title, model: model, to: movie, progress: progress,
                    preview: preview)
            }
            try await filmed.writer.finish(
                hits: filmed.hits, before: .now + PileMovieWriter.finishTimeout)
            // A plain still, since the clip is no Live Photo.
            try await writeStill(filmed.poster, identifier: nil, to: still)
            return PileMovie(movie: movie, still: still, poster: filmed.poster, name: name)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Runs the chain and writes each frame to `url`, and returns the writer, for the caller
    /// to finish the movie, the last frame, and the hits for the soundtrack.
    private static func filmDominoes(
        _ books: [CloudBook], title: String, model: AppModel, to url: URL,
        progress: (Double?) -> Void, preview: (CGImage) -> Void
    ) async throws -> (writer: PileMovieWriter, poster: CGImage, hits: [ImpactRecord]) {
        let aspect = ShareAspect.story
        let width = Int(aspect.size.width)
        let height = Int(aspect.size.height)
        let target = try FrameTarget(width: width, height: height)
        let card = DominoFinaleCard(
            title: title, count: books.count, pages: DominoFinaleCard.pages(of: books), scale: 1,
            insets: aspect.insets, showsCredit: true)
        let heading = ImageRenderer(
            content: card.frame(width: aspect.size.width, height: aspect.size.height))
        heading.scale = 1
        heading.isOpaque = false
        guard let overlay = heading.cgImage.flatMap(PileMovieOverlay.displayP3) else {
            Self.log.error("The heading did not render")
            throw PileSnapshotError.drawingFailed
        }

        let scene = DominoScene(offline: true)
        scene.setReduceMotion(false)
        scene.setCameraMode(.follow, blends: false)
        let renderer = try RealityRenderer()
        renderer.entities.append(scene.root)
        defer { renderer.entities.removeAll() }
        renderer.activeCamera = scene.camera
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.isToneMappingEnabled = true
        // The Follow camera looks past the table's far edge from low behind the chain, where
        // the live view shows the desk's walnut wall.
        renderer.cameraSettings.colorBackground = .color(
            CGColor(red: 0.11, green: 0.078, blue: 0.055, alpha: 1))
        let length = await scene.setUpOffline(
            books, viewport: PileViewport(size: aspect.size, insets: aspect.insets), model: model)
        try Task.checkCancellation()
        if let live = scene.root.scene { scene.listen(to: live) }
        Self.log.notice(
            "Stood \(books.count) books, \(length, format: .fixed(precision: 1)) units, in \(scene.root.scene == nil ? "no" : "a") scene"
        )

        // The run speeds up so that the whole clip fits (see `DominoMovieTiming`).
        let run = DominoMovieTiming.runEstimate(length: length)
        let hurry = DominoMovieTiming.hurry
        let fixed =
            (scene.establishTime + DominoCameraRig.landTime + 8) / hurry
            + DominoFinale.duration(count: books.count) + 1.5 + DominoMovieTiming.hold
        let speed = DominoMovieTiming.speed(run: run, fixed: fixed)
        let expected = fixed + run / speed
        let step = PileMovieTiming.stepDuration

        let writer = try PileMovieWriter(url: url, width: width, height: height, identifier: nil)
        do {
            try writer.start(stillFrame: 0)
            scene.feedback.startRecording()
            let began = ContinuousClock.now
            var frame = 0
            var clock: Float = 0
            var finishedAt: Float?
            var pushed = false
            var poster: CGImage?
            while true {
                try Task.checkCancellation()
                let signal = UInt64(frame + 1)
                // The spread is laid out away from the main actor once every book has fallen;
                // the gathering's first frame waits for it.
                if scene.status.phase == .done { await scene.waitForSpread() }
                for substep in 0..<PileMovieTiming.stepsPerFrame {
                    let phase = scene.status.phase
                    if phase == .standing, !pushed, scene.isEstablished {
                        scene.pushNext()
                        pushed = true
                    } else if case .stalled = phase {
                        scene.pushNext()
                    }
                    let tempo: Float =
                        switch phase {
                        case .standing, .done: hurry
                        case .running, .stalled: speed
                        case .settingUp, .gathering, .finished: 1
                        }
                    scene.advance(by: step, tempo: tempo)
                    let physics = step * Double(tempo) * DominoScene.slowMotion
                    if substep < PileMovieTiming.stepsPerFrame - 1 {
                        try renderer.update(physics)
                    } else {
                        try renderer.updateAndRender(
                            deltaTime: physics, cameraOutput: target.output,
                            actionsAfterRender: [.signal(target.event, value: signal)])
                    }
                }
                clock += 1 / Float(PileMovieTiming.framesPerSecond)
                if scene.status.phase == .finished, finishedAt == nil { finishedAt = clock }
                // Every wait of the frame, for the GPU and for the encoder, ends by this
                // deadline, so a frame that never renders cannot hold the render's turn.
                let deadline = ContinuousClock.now + frameTimeout
                try await target.read(after: signal, before: deadline)
                if frame == 0, target.isBlank {
                    Self.log.error("The first frame is blank")
                    throw PileSnapshotError.drawingFailed
                }
                if frame.isMultiple(of: 300) {
                    let seconds = (ContinuousClock.now - began) / .seconds(1)
                    Self.log.notice(
                        "Frame \(frame) at \(clock, format: .fixed(precision: 1)) s: \(String(describing: scene.status.phase)), \(seconds, format: .fixed(precision: 1)) s in"
                    )
                }
                // The heading fades in over the gathered books.
                let shown = finishedAt.map { min(1, (clock - $0) / 0.6) } ?? 0
                let last =
                    finishedAt.map { clock >= $0 + DominoMovieTiming.hold } ?? false
                    || clock >= DominoMovieTiming.cap
                let snapshot = try await writer.appendFrame(
                    target.buffer.contents(), bytesPerRow: target.bytesPerRow, overlay: overlay,
                    opacity: CGFloat(shown), at: frame,
                    snapshot: last ? 1 : frame % 6 == 0 ? 2 : nil, before: deadline)
                if let snapshot { preview(snapshot) }
                progress(min(0.99, Double(clock / expected)))
                if last {
                    poster = snapshot
                    break
                }
                frame += 1
            }
            let hits = scene.feedback.finishRecording()
            Self.log.notice(
                "Filmed \(frame + 1) frames, \(clock, format: .fixed(precision: 1)) s, run at \(speed, format: .fixed(precision: 2)) times live, finished at \(finishedAt ?? -1, format: .fixed(precision: 1)) s, \(hits.count) hits"
            )
            guard let poster else { throw PileSnapshotError.drawingFailed }
            return (writer, poster, hits)
        } catch {
            writer.cancel()
            throw error
        }
    }
}

#if DEBUG
    /// Simulator hooks, since a script cannot tap **Share**.
    ///
    /// With `-BookwormsDominoVideo YES`, the dominoes' video sheet opens once the books have
    /// gathered, and each finished video is copied to
    /// `Library/Caches/Bookworms/domino-video-debug.mov` with its still at
    /// `domino-video-debug.jpg`.
    enum DominoVideoDebug {
        static var opensSheet: Bool { UserDefaults.standard.bool(forKey: "BookwormsDominoVideo") }

        static func write(_ movie: PileMovie) {
            guard opensSheet else { return }
            let folder = URL.cachesDirectory.appending(path: "Bookworms")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (source, name) in [
                (movie.movie, "domino-video-debug.mov"), (movie.still, "domino-video-debug.jpg"),
            ] {
                let target = folder.appending(path: name)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: source, to: target)
            }
        }
    }
#endif
