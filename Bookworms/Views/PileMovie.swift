import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import RealityKit
import UniformTypeIdentifiers
import os

/// The timeline of a pile video: its frames, the physics steps behind each, and when and how
/// each book falls into place.
///
/// Each 1/30-second frame advances the scene by two 1/60-second steps, then shows it. Frame `f`
/// therefore shows the scene at `(f + 1) / 30` seconds, and a landing during its steps first
/// shows in it.
///
/// The books fall onto the places of the image's spread (`PileSpread`), in the order they go
/// down, so a book lands only after the books it rests on (see `landings(_:)`). Each starts
/// hidden behind the heading (`startHeight(of:camera:headingY:aspect:)`) and falls straight
/// down under gravity and air drag (`fallen(after:)`), turning a little as it falls, and stops in
/// its place. The camera holds the image's framing throughout, and the last frame, which the
/// Live Photo's still shows, matches the image.
enum PileMovieTiming {
    static let framesPerSecond: Int32 = 30
    /// Six seconds of frames.
    static let frameCount = 180
    static let stepsPerFrame = 2
    static let stepDuration: TimeInterval = 1.0 / 60
    /// The linear damping of a falling book, as air drag: from 15 units up, a book lands at
    /// about the speed of a 7-unit drop without drag.
    static let airDrag: Float = 1.5
    /// The most time between two books' landings.
    static let landingInterval: Float = 0.4
    /// The earliest the first book lands, in seconds, so a clip opens on the empty table.
    static let firstLanding: Float = 1
    /// The latest a book lands, in seconds, which leaves the last 1.5 seconds still.
    static let lastLanding: Float = 4.5
    /// Audio sample frames per video frame: 1,470 at 44.1 kHz.
    static let samplesPerFrame = Int(ImpactSound.sampleRate) / Int(framesPerSecond)

    /// How far a book falls in `seconds` from rest, under `PileLayout.gravity` and `airDrag`.
    static func fallen(after seconds: Float) -> Float {
        let (gravity, drag) = (PileLayout.gravity, airDrag)
        return gravity / drag * (seconds - (1 - exp(-drag * seconds)) / drag)
    }

    /// How long a book takes to fall `height` from rest, and how fast it lands.
    static func fall(height: Float) -> (duration: Float, speed: Float) {
        // A fall under drag has no closed-form time for a distance, so this halves its way to it.
        var (low, high): (Float, Float) = (0, 10)
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if fallen(after: middle) < height { low = middle } else { high = middle }
        }
        return (high, PileLayout.gravity / airDrag * (1 - exp(-airDrag * high)))
    }

    /// When each book lands, in seconds from the clip's start, for books in the order they go
    /// down that take `durations` to fall.
    ///
    /// The books land one after another at an even interval, so a book never lands before the
    /// books under it: `landingInterval` apart, or closer for a pile that would otherwise land
    /// after `lastLanding`. The first lands at `firstLanding`, or later when a book's fall would
    /// otherwise start before the clip does.
    static func landings(_ durations: [Float]) -> [Float] {
        func first(_ interval: Float) -> Float {
            max(firstLanding, durations.enumerated().map { $1 - Float($0) * interval }.max() ?? 0)
        }
        func last(_ interval: Float) -> Float {
            first(interval) + Float(max(durations.count - 1, 0)) * interval
        }
        var interval = landingInterval
        if last(interval) > lastLanding {
            var low: Float = 0
            for _ in 0..<30 {
                let middle = (low + interval) / 2
                if last(middle) <= lastLanding { low = middle } else { interval = middle }
            }
            interval = low
        }
        let start = first(interval)
        return durations.indices.map { start + Float($0) * interval }
    }

    /// How high above its place in the spread a book whose corners lie at `corners` starts, so
    /// that `camera`, in a frame of width-to-height `aspect`, shows it wholly above `headingY`,
    /// the heading's bottom edge in normalized device coordinates, where the heading hides it.
    ///
    /// A camera too close to raise the book that far, short of its own height, starts it as high
    /// as it can, so the book falls in from the top of the frame instead.
    static func startHeight(
        of corners: [SIMD3<Float>], camera: PileCamera, headingY: Float, aspect: Float
    ) -> Float {
        let ceiling = camera.transform.translation.y - 1
        return
            corners.map { corner in
                var (low, high) = (Float(0), max(0, ceiling - corner.y))
                guard camera.project(corner + [0, high, 0], aspect: aspect).y > headingY else {
                    return high
                }
                for _ in 0..<30 {
                    let middle = (low + high) / 2
                    if camera.project(corner + [0, middle, 0], aspect: aspect).y > headingY {
                        high = middle
                    } else {
                        low = middle
                    }
                }
                return high
            }
            .max() ?? 0
    }

    /// Where a book lies at `time` that lands at `landing` from `height` straight above `rest`,
    /// its pose in the spread, after a fall of `duration` (see `fall(height:)`), turned by `turn`
    /// as it starts: still until its fall begins, then falling and turning into `rest`, where it
    /// stays.
    static func pose(
        rest: Transform, height: Float, duration: Float, turn: simd_quatf, landing: Float,
        at time: Float
    ) -> Transform {
        let elapsed = min(max(time - landing + duration, 0), duration)
        let progress = duration > 0 ? elapsed / duration : 1
        var pose = rest
        pose.translation.y += height - fallen(after: elapsed)
        pose.rotation = simd_slerp(
            turn * rest.rotation, rest.rotation, progress * progress * (3 - 2 * progress))
        return pose
    }

    /// When frame `frame` shows.
    static func time(ofFrame frame: Int) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
    }

    /// The first frame that shows the scene at `time`, in seconds since the clip's first step.
    /// Times add up from 1/60-second steps, so a time a rounding error past a frame's end still
    /// counts as that frame.
    static func frame(showing time: TimeInterval) -> Int {
        max(0, Int((time * Double(framesPerSecond) - 1e-6).rounded(.up)) - 1)
    }
}

/// Mixes recorded hits (`ImpactRecord`) into a video's stereo soundtrack, as `ImpactAudio`
/// plays them live.
enum ImpactMix {
    /// The left and right gains of a mono sound panned to `pan`, from -1 at the left to 1 at the
    /// right. The pan has equal power, as the audio engine's mixer pans a mono voice: about 0.71
    /// on each side in the middle, and 0.99 on the near side at 0.8.
    static func gains(pan: Float) -> (left: Float, right: Float) {
        let angle = (min(1, max(-1, pan)) + 1) * .pi / 4
        return (cos(angle), sin(angle))
    }

    /// The interleaved stereo samples, at `ImpactSound.sampleRate`, of the sample frames in
    /// `range` of the soundtrack.
    ///
    /// Each record plays its sound at its volume and pan, scaled by `ImpactSound.level`,
    /// starting with the video frame that first shows its hit, so a sound never leads its
    /// picture. Sounds overlap freely, and the mix is clamped to ±1, which `ImpactSound.level`
    /// keeps it within. Mixing a range in pieces gives the same samples as mixing it whole.
    static func samples(_ records: [ImpactRecord], in range: Range<Int>) -> [Float] {
        var mix = [Float](repeating: 0, count: range.count * 2)
        for record in records {
            guard let variants = ImpactSound.bank[record.kind],
                variants.indices.contains(record.variant)
            else { continue }
            let sound = variants[record.variant]
            let start =
                PileMovieTiming.frame(showing: record.time) * PileMovieTiming.samplesPerFrame
            let lower = max(start, range.lowerBound)
            let upper = min(start + sound.count, range.upperBound)
            guard lower < upper else { continue }
            let gain = record.volume * ImpactSound.level
            let (left, right) = gains(pan: record.pan)
            for index in lower..<upper {
                let sample = sound[index - start] * gain
                let out = (index - range.lowerBound) * 2
                mix[out] += sample * left
                mix[out + 1] += sample * right
            }
        }
        return mix.map { min(1, max(-1, $0)) }
    }
}

/// Writes a pile or dominoes video to a QuickTime movie: HEVC frames, an AAC soundtrack, and,
/// for a pile, the metadata that pairs the movie with a still as a Live Photo.
///
/// The frames are encoded as they render, into a file of their own with one input, which
/// takes each frame as soon as the encoder has room for it. The sound and the metadata join
/// them in a second pass (`finish(hits:before:)`), which copies the frames without decoding
/// them, encodes the soundtrack mixed from the recorded hits (`ImpactMix`), and, for a Live
/// Photo's movie, names its content identifier and marks a frame as the still's time; the
/// still carries the same identifier (see `writeStill`). A writer with several inputs pairs
/// their samples as it writes, and stops taking frames while it waits for sound it has not
/// been given: fed one frame's sound at a time, it did so partway through long clips. In the
/// second pass each track feeds the writer from a task of its own, so every track always has
/// its next sample ready.
///
/// Each frame is offered with `appendImmediately` until the encoder takes it, 4 milliseconds
/// apart (see `offer`), which bounds the frames waiting for the encoder and the pixel buffers
/// they hold. The inputs' own `append` waits do not return when their task or the writer is
/// cancelled, while a render holds the turn that the live pile and every share image wait on,
/// so every wait ends at a deadline, which fails the movie without waiting any further.
@MainActor
final class PileMovieWriter {
    /// How long the frames may take to finish, and the movie to be written from them.
    static let finishTimeout = Duration.seconds(30)

    private let url: URL
    /// The frames alone, which `finish(hits:before:)` replaces with the movie.
    private let framesURL: URL
    private let identifier: String?
    private let writer: AVAssetWriter
    private let frames: AVAssetWriterInput.PixelBufferReceiver
    private var frameCount = 0
    private var stillFrame = 0

    private static let stillImageTimeIdentifier = "mdta/com.apple.quicktime.still-image-time"
    nonisolated private static let log = Logger(
        subsystem: "gay.ian.Bookworms.iOS", category: "video")

    /// Prepares a movie of `width` by `height` pixels at `url`, which must not exist yet, for
    /// the Live Photo content identifier `identifier`, or a plain movie without one.
    init(url: URL, width: Int, height: Int, identifier: String?) throws {
        self.url = url
        self.identifier = identifier
        framesURL = url.deletingPathExtension().appendingPathExtension("frames.mov")
        writer = try AVAssetWriter(outputURL: framesURL, fileType: .mov)
        // Display P3 primaries, as `RealityRenderer` draws its frames.
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoExpectedSourceFrameRateKey: Int(PileMovieTiming.framesPerSecond),
                    AVVideoMaxKeyFrameIntervalKey: 2 * Int(PileMovieTiming.framesPerSecond),
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
        guard writer.canAdd(video) else { throw PileSnapshotError.drawingFailed }
        frames = writer.inputPixelBufferReceiver(
            for: video,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                size: CVImageSize(width: width, height: height), compatibility: .cgBitmapContext))
    }

    /// Starts the frames at time zero and, for a Live Photo's movie, notes frame `stillFrame`
    /// as its still.
    ///
    /// - Throws: `PileSnapshotError` when the writer fails to start.
    func start(stillFrame: Int) throws {
        self.stillFrame = stillFrame
        try writer.start()
        writer.startSession(atSourceTime: .zero)
    }

    /// Adds a frame of 32-bit BGRA `pixels`, with rows `bytesPerRow` apart and the top row
    /// first, as frame `frame`, with `overlay` drawn over it at `opacity` (see
    /// `PileMovieOverlay`), and waits until the encoder takes it.
    ///
    /// Copies the pixels at once, so the caller can reuse their memory when this returns.
    ///
    /// - Returns: The finished frame, `snapshot` times smaller in each dimension, when
    ///   `snapshot` is set.
    /// - Throws: `PileSnapshotError` when the writer fails or does not take the frame by
    ///   `deadline`.
    func appendFrame(
        _ pixels: UnsafeRawPointer, bytesPerRow: Int, overlay: CGImage, opacity: CGFloat = 1,
        at frame: Int, snapshot: Int?, before deadline: ContinuousClock.Instant
    ) async throws -> CGImage? {
        guard let pool = frames.pixelBufferPool else {
            Self.log.error(
                "No pixel buffer pool at frame \(frame): writer status \(self.writer.status.rawValue), \(String(describing: self.writer.error))"
            )
            throw writer.error ?? PileSnapshotError.drawingFailed
        }
        var buffer = try pool.makeMutablePixelBuffer()
        let image = buffer.accessUnsafeMutableRawPlaneBytes { planes -> CGImage? in
            guard let plane = planes.first, let base = plane.bytes.baseAddress else { return nil }
            let size = plane.properties.size
            for row in 0..<size.height {
                (base + row * plane.properties.bytesPerRow)
                    .copyMemory(from: pixels + row * bytesPerRow, byteCount: size.width * 4)
            }
            return PileMovieOverlay.draw(
                overlay, over: base, width: size.width, height: size.height,
                bytesPerRow: plane.properties.bytesPerRow, opacity: opacity, snapshot: snapshot)
        }
        let finished = CVReadOnlyPixelBuffer(buffer)
        let time = PileMovieTiming.time(ofFrame: frame)
        try await Self.offer("frame \(frame)", to: writer, until: deadline) {
            try frames.appendImmediately(finished, with: time)
        }
        frameCount = max(frameCount, frame + 1)
        return image
    }

    /// Offers `what` to one of `writer`'s inputs with `append` until the input takes it, 4
    /// milliseconds between offers, and throws `PileSnapshotError.drawingFailed` when the
    /// writer fails or `deadline` passes first.
    private static func offer(
        _ what: String, to writer: AVAssetWriter, until deadline: ContinuousClock.Instant,
        _ append: () throws -> Bool
    ) async throws {
        while try !append() {
            guard writer.status == .writing else {
                throw writer.error ?? PileSnapshotError.drawingFailed
            }
            guard ContinuousClock.now < deadline else {
                Self.log.error("The writer did not take \(what) by its deadline")
                throw PileSnapshotError.drawingFailed
            }
            try await Task.sleep(for: .milliseconds(4))
        }
    }

    /// Finishes the frames, then writes the movie: the frames, the soundtrack mixed from
    /// `hits`, and a Live Photo's metadata. Cancels the movie when that fails, leaving
    /// incomplete files for the caller to delete.
    ///
    /// - Throws: `PileSnapshotError` when a writer fails or the movie is not done by
    ///   `deadline`.
    func finish(hits: [ImpactRecord], before deadline: ContinuousClock.Instant) async throws {
        do {
            frames.finish()
            let writer = writer
            try await wait(for: "the frames", until: deadline) { await writer.finishWriting() }
            guard writer.status == .completed else {
                throw writer.error ?? PileSnapshotError.drawingFailed
            }
            let sound = ImpactMix.samples(
                hits, in: 0..<frameCount * PileMovieTiming.samplesPerFrame)
            let began = ContinuousClock.now
            try await wait(for: "the movie", until: deadline) { try await self.mux(sound) }
            Self.log.notice(
                "Wrote the movie in \((ContinuousClock.now - began) / .seconds(1), format: .fixed(precision: 1)) s"
            )
            try? FileManager.default.removeItem(at: framesURL)
        } catch {
            cancel()
            throw error
        }
    }

    /// Writes the movie at `url` from the finished frames and `sound`, the whole interleaved
    /// stereo soundtrack at `ImpactSound.sampleRate`.
    private func mux(_ sound: [Float]) async throws {
        let asset = AVURLAsset(url: framesURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PileSnapshotError.drawingFailed
        }
        let reader = try AVAssetReader(asset: asset)
        let pictures = reader.outputProvider(
            for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))

        let movie = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil,
            sourceFormatHint: try await track.load(.formatDescriptions).first)
        let audio = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: ImpactSound.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
        var metadata: AVAssetWriterInput?
        if let identifier {
            let content = AVMutableMetadataItem()
            content.keySpace = .quickTimeMetadata
            content.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier.rawValue as NSString
            content.value = identifier as NSString
            content.dataType = kCMMetadataBaseDataType_UTF8 as String
            movie.metadata = [content]
            // A timed metadata track whose one sample marks the Live Photo's still.
            var description: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [
                    [
                        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier:
                            Self.stillImageTimeIdentifier,
                        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType:
                            kCMMetadataBaseDataType_SInt8,
                    ]
                ] as CFArray, formatDescriptionOut: &description)
            metadata = AVAssetWriterInput(
                mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        }
        guard ([video, audio] + [metadata].compactMap(\.self)).allSatisfy(movie.canAdd) else {
            throw PileSnapshotError.drawingFailed
        }
        let frames = movie.inputReceiver(for: video)
        let samples = movie.inputReceiver(for: audio)
        let marks: AVAssetWriterInput.MetadataReceiver? =
            if let metadata { movie.inputMetadataReceiver(for: metadata) } else { nil }
        let format = try CMAudioFormatDescription(
            audioStreamBasicDescription: AudioStreamBasicDescription(
                mSampleRate: ImpactSound.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                mBitsPerChannel: 32, mReserved: 0))
        let stillTime = PileMovieTiming.time(ofFrame: stillFrame)

        // A second of sound at a time, as one sample buffer.
        let count = sound.count / 2
        func second(from start: Int) -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
            let end = min(start + Int(ImpactSound.sampleRate), count)
            let data = sound[start * 2..<end * 2].withUnsafeBytes { Data($0) }
            return CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(
                CMReadySampleBuffer(
                    audioDataBuffer: CMReadOnlyDataBlockBuffer(data),
                    formatDescription: format, sampleCount: end - start,
                    presentationTimeStamp: CMTime(
                        value: CMTimeValue(start), timescale: CMTimeScale(ImpactSound.sampleRate))
                ))
        }
        var mark: AVTimedMetadataGroup?
        if marks != nil {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(rawValue: Self.stillImageTimeIdentifier)
            item.value = 0 as NSNumber
            item.dataType = kCMMetadataBaseDataType_SInt8 as String
            mark = AVTimedMetadataGroup(
                items: [item],
                timeRange: CMTimeRange(start: stillTime, duration: PileMovieTiming.time(ofFrame: 1))
            )
        }

        try movie.start()
        movie.startSession(atSourceTime: .zero)
        try reader.start()
        // The writer pairs the tracks' samples as it writes, taking one track's while another's
        // waits, so each pass offers every track its next sample and sleeps only when none is
        // taken.
        var picture = try await pictures.next()
        var start = 0
        var chunk = second(from: 0)
        while picture != nil || start < count || mark != nil {
            var taken = false
            if let next = picture, try frames.appendImmediately(next) {
                picture = try await pictures.next()
                if picture == nil { frames.finish() }
                taken = true
            }
            if start < count, try samples.appendImmediately(chunk) {
                start += Int(ImpactSound.sampleRate)
                if start < count { chunk = second(from: start) } else { samples.finish() }
                taken = true
            }
            if let marks, let group = mark, try marks.appendImmediately(group) {
                mark = nil
                marks.finish()
                taken = true
            }
            if !taken {
                guard movie.status == .writing else {
                    throw movie.error ?? PileSnapshotError.drawingFailed
                }
                try await Task.sleep(for: .milliseconds(4))
            }
        }
        await movie.finishWriting()
        guard movie.status == .completed else {
            throw movie.error ?? PileSnapshotError.drawingFailed
        }
    }

    /// Stops writing the frames and leaves incomplete files, which the caller deletes.
    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }

    /// Waits for `operation` until `deadline`, then throws `PileSnapshotError.drawingFailed`
    /// and leaves the operation to end on its own, if ever. Cancelling the calling task does
    /// not end the wait sooner.
    private func wait(
        for what: String, until deadline: ContinuousClock.Instant,
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let outcome = Outcome()
        try await withCheckedThrowingContinuation { continuation in
            outcome.continuation = continuation
            let timer = Task {
                try await Task.sleep(until: deadline)
                Self.log.error(
                    "The writer did not finish \(what) by its deadline: status \(self.writer.status.rawValue), \(String(describing: self.writer.error))"
                )
                outcome.resume(with: .failure(PileSnapshotError.drawingFailed))
            }
            Task {
                do {
                    try await operation()
                    outcome.resume(with: .success(()))
                } catch {
                    outcome.resume(with: .failure(error))
                }
                timer.cancel()
            }
        }
    }

    /// Whichever ends first of an operation and its deadline.
    @MainActor private final class Outcome {
        var continuation: CheckedContinuation<Void, any Error>?

        func resume(with result: Result<Void, any Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    /// Writes `image` to `url` as a JPEG that names `identifier`, if any, as its Live Photo
    /// content identifier, in the Apple maker note's key 17, which pairs it with the movie.
    nonisolated static func writeStill(_ image: CGImage, identifier: String?, to url: URL)
        throws
    {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PileSnapshotError.drawingFailed }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let identifier { properties[kCGImagePropertyMakerAppleDictionary] = ["17": identifier] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PileSnapshotError.drawingFailed
        }
    }
}

/// Draws a video frame's heading and credit over the frame and copies the result.
enum PileMovieOverlay {
    /// `image` redrawn in Display P3, the space of the frames, so that drawing it over each one
    /// converts no colors.
    static func displayP3(_ image: CGImage) -> CGImage? {
        guard let context = context(width: image.width, height: image.height, alpha: true)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Draws `overlay` at `opacity` over a frame of 32-bit BGRA `pixels` in Display P3,
    /// `width` by `height` with rows `bytesPerRow` apart and the top row first, ignoring their
    /// alpha byte. Returns a copy of the result, `snapshot` times smaller in each dimension,
    /// when `snapshot` is set.
    static func draw(
        _ overlay: CGImage, over pixels: UnsafeMutableRawPointer, width: Int, height: Int,
        bytesPerRow: Int, opacity: CGFloat = 1, snapshot: Int?
    ) -> CGImage? {
        guard
            let context = context(
                width: width, height: height, alpha: false, data: pixels, bytesPerRow: bytesPerRow)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if opacity > 0 {
            context.setAlpha(opacity)
            context.draw(overlay, in: bounds)
            context.setAlpha(1)
        }
        guard let snapshot, let frame = context.makeImage() else { return nil }
        guard snapshot > 1,
            let small = self.context(
                width: width / snapshot, height: height / snapshot, alpha: false)
        else { return frame }
        small.interpolationQuality = .medium
        small.draw(frame, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        return small.makeImage()
    }

    /// A 32-bit BGRA Display P3 context, over `data` when it is set.
    private static func context(
        width: Int, height: Int, alpha: Bool, data: UnsafeMutableRawPointer? = nil,
        bytesPerRow: Int = 0
    ) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        let order = alpha ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst
        return CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: order.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
}
