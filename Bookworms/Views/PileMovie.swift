import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// The timeline of a pile video: its frames, the physics steps behind each, when each group of
/// books drops and from how high, how the camera closes in, and where each hit's sound starts.
///
/// Each 1/30-second frame advances the simulation by two 1/60-second steps, the step still
/// images settle with, and then shows it. Frame `f` therefore shows the simulation at
/// `(f + 1) / 30` seconds, and a hit during its steps first shows in it.
///
/// Groups drop from the first frame, 0.4 seconds apart, from behind the heading (see
/// `dropBase`), so each book falls into view rather than appearing in the air. Once the last
/// group has landed, the camera eases from the drop's framing to the settled pile's, as a still
/// image frames it, and keeps it for the last frames, which the Live Photo's still shows.
enum PileMovieTiming {
    static let framesPerSecond: Int32 = 30
    /// Six seconds of frames.
    static let frameCount = 180
    static let stepsPerFrame = 2
    static let stepDuration: TimeInterval = 1.0 / 60
    /// Frames from one group of books to the next: 0.4 seconds, as still images drop them.
    static let groupFrames = 12
    /// The latest frame a group drops at, which leaves time for it to land and for the camera
    /// to close in.
    static let lastDrop = 84
    /// Frames from the last group's drop to the camera's move: longer than the longest fall (see
    /// `highestBase` and `airDrag`).
    static let pushDelay = 36
    /// The final frames, in which the camera keeps the settled pile's framing.
    static let holdFrames = 9
    /// The highest base a group starts from, in scene units. A group's highest layer starts 3.7
    /// units above its base, so a tilted book there stays well under `PileLayout.ceiling`, and
    /// a book from there lands within `pushDelay`.
    static let highestBase: Float = 17.5
    /// The linear damping of a video's books, as air drag. From 15 units up, a book lands at about
    /// the speed of a 7-unit drop without drag, rather than 50 percent faster, which flips many
    /// books face down.
    static let airDrag: Float = 1.5
    /// The angular damping of a video's books, which keeps a hard landing from tumbling them.
    static let spinDrag: Float = 2
    /// Steps in which the groups that drop before the clip settle: one second.
    static let prerollSettleSteps = 60
    /// Audio sample frames per video frame: 1,470 at 44.1 kHz.
    static let samplesPerFrame = Int(ImpactSound.sampleRate) / Int(framesPerSecond)

    /// The most groups a clip shows falling. Earlier groups drop before it starts.
    static var shownGroups: Int { lastDrop / groupFrames + 1 }

    /// How many of `groups` drop before the clip starts, so that the rest land in view, and the
    /// frame each of the rest drops at.
    static func schedule(groups: Int) -> (preroll: Int, frames: [Int]) {
        let preroll = max(0, groups - shownGroups)
        return (preroll, (0..<(groups - preroll)).map { $0 * groupFrames })
    }

    /// The height a clip's groups start from, at least, so its books start hidden behind the
    /// heading, whose bottom edge is `headingY` in normalized device coordinates.
    ///
    /// The base puts the nearest book's near edge, `nearestZ` plus `PileLayout.reach`, on that
    /// edge when the book starts in its group's lowest layer, 1.2 units above the base (see
    /// `PileLayout.settleGroups`). Higher or farther points show higher on screen, behind the
    /// heading, while they stay below the camera; above it, they are out of view. `camera` must
    /// not turn. The base stays within 0...`highestBase`.
    static func dropBase(camera: PileCamera, headingY: Float, nearestZ: Float) -> Float {
        let (origin, direction) = camera.ray(ndc: [0, headingY], aspect: 1)
        let edge = nearestZ + PileLayout.reach
        let hidden = origin.y + direction.y * (edge - origin.z) / direction.z
        return min(max(hidden - 1.2, 0), highestBase)
    }

    /// How far the camera has moved from the drop's framing to the settled pile's at frame
    /// `frame`, from 0 to 1, when the last group drops at frame `lastDrop`. The move starts
    /// `pushDelay` frames after that drop, eases in and out, and arrives `holdFrames` before the
    /// end, so a clip with fewer groups closes in more slowly.
    static func push(atFrame frame: Int, lastDrop: Int) -> Float {
        let start = lastDrop + pushDelay
        let end = frameCount - 1 - holdFrames
        let progress = min(1, max(0, Float(frame - start) / Float(end - start)))
        return progress * progress * (3 - 2 * progress)
    }

    /// When frame `frame` shows.
    static func time(ofFrame frame: Int) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
    }

    /// The first frame that shows the simulation at `time`, in seconds since the clip's first
    /// step. Times add up from 1/60-second steps, so a time a rounding error past a frame's end
    /// still counts as that frame.
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

/// Writes a pile video to a QuickTime movie: HEVC frames, an AAC soundtrack, and the metadata
/// that pairs the movie with a still as a Live Photo.
///
/// The movie names the Live Photo's content identifier and marks a frame as the still's time;
/// the still carries the same identifier (see `writeStill`). Frames and sound arrive in step,
/// each frame's `PileMovieTiming.samplesPerFrame` samples just before the frame. The writer
/// interleaves them, so either input can refuse more until the other catches up; a separate
/// task therefore appends the sound, so neither input's wait holds up the other.
///
/// Each frame waits until the video input takes it, which bounds the frames waiting for the
/// encoder and the pixel buffers they hold. The inputs' `append` waits have no timeout and do
/// not return when their task or the writer is cancelled, while a render holds the turn that
/// the live pile and every share image wait on. Every wait therefore ends at a deadline, which
/// fails the movie without waiting for the `append` any further.
@MainActor
final class PileMovieWriter {
    private let writer: AVAssetWriter
    private let frames: AVAssetWriterInput.PixelBufferReceiver
    private let stillTime: AVAssetWriterInput.MetadataReceiver
    private let soundFormat: CMAudioFormatDescription
    /// The mixed sound, in order, for `soundtrack` to append: at most the soundtrack, about
    /// 2 MB.
    private let soundFeed: AsyncStream<Sound>.Continuation
    /// Appends the sound that `soundFeed` yields to the audio input.
    private let soundtrack: Task<Void, any Error>

    private typealias Sound = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>

    private static let stillImageTimeIdentifier = "mdta/com.apple.quicktime.still-image-time"

    /// Prepares a movie of `width` by `height` pixels at `url`, which must not exist yet, for
    /// the Live Photo content identifier `identifier`.
    init(url: URL, width: Int, height: Int, identifier: String) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let content = AVMutableMetadataItem()
        content.keySpace = .quickTimeMetadata
        content.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier.rawValue as NSString
        content.value = identifier as NSString
        content.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [content]

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
                ],
            ])
        let audio = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: ImpactSound.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
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
        let metadata = AVAssetWriterInput(
            mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        guard [video, audio, metadata].allSatisfy(writer.canAdd) else {
            throw PileSnapshotError.drawingFailed
        }
        frames = writer.inputPixelBufferReceiver(
            for: video,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                size: CVImageSize(width: width, height: height), compatibility: .cgBitmapContext))
        stillTime = writer.inputMetadataReceiver(for: metadata)
        soundFormat = try CMAudioFormatDescription(
            audioStreamBasicDescription: AudioStreamBasicDescription(
                mSampleRate: ImpactSound.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                mBitsPerChannel: 32, mReserved: 0))
        let sound = writer.inputReceiver(for: audio)
        let (chunks, feed) = AsyncStream.makeStream(of: Sound.self)
        soundFeed = feed
        soundtrack = Task { for await chunk in chunks { try await sound.append(chunk) } }
    }

    /// Starts the movie at time zero and marks frame `stillFrame` as the Live Photo's still.
    ///
    /// - Throws: `PileSnapshotError` when the writer fails or does not take the mark by
    ///   `deadline`.
    func start(stillFrame: Int, before deadline: ContinuousClock.Instant) async throws {
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: Self.stillImageTimeIdentifier)
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        let mark = AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(
                start: PileMovieTiming.time(ofFrame: stillFrame),
                duration: PileMovieTiming.time(ofFrame: 1)))
        let stillTime = stillTime
        try await wait(until: deadline) { try await stillTime.append(mark) }
        stillTime.finish()
    }

    /// Adds a frame of 32-bit BGRA `pixels`, with rows `bytesPerRow` apart and the top row
    /// first, as frame `frame`, with `overlay` drawn over it (see `PileMovieOverlay`), and waits
    /// until the video input takes it.
    ///
    /// Copies the pixels at once, so the caller can reuse their memory when this returns.
    ///
    /// - Returns: The finished frame, `snapshot` times smaller in each dimension, when
    ///   `snapshot` is set.
    /// - Throws: `PileSnapshotError` when the writer fails or does not take the frame by
    ///   `deadline`.
    func appendFrame(
        _ pixels: UnsafeRawPointer, bytesPerRow: Int, overlay: CGImage, at frame: Int,
        snapshot: Int?, before deadline: ContinuousClock.Instant
    ) async throws -> CGImage? {
        guard let pool = frames.pixelBufferPool else {
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
                bytesPerRow: plane.properties.bytesPerRow, snapshot: snapshot)
        }
        let finished = CVReadOnlyPixelBuffer(buffer)
        let time = PileMovieTiming.time(ofFrame: frame)
        let frames = frames
        try await wait(until: deadline) { try await frames.append(finished, with: time) }
        return image
    }

    /// Adds interleaved stereo `samples`, from `ImpactMix`, that start at sample frame `start`.
    /// Returns at once; the audio input takes them as the interleaving allows.
    func appendSound(_ samples: [Float], at start: Int) {
        let audio = CMReadySampleBuffer(
            audioDataBuffer: CMReadOnlyDataBlockBuffer(samples.withUnsafeBytes { Data($0) }),
            formatDescription: soundFormat, sampleCount: samples.count / 2,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(start), timescale: CMTimeScale(ImpactSound.sampleRate)))
        soundFeed.yield(Sound(audio))
    }

    /// Finishes the movie file once the audio input has taken all the sound. Cancels the movie
    /// when that fails.
    ///
    /// - Throws: `PileSnapshotError` when the writer fails or does not finish by `deadline`.
    func finish(before deadline: ContinuousClock.Instant) async throws {
        do {
            // Without more frames to wait for, the audio input takes the rest of the sound.
            frames.finish()
            soundFeed.finish()
            let soundtrack = soundtrack
            try await wait(until: deadline) { try await soundtrack.value }
            let writer = writer
            try await wait(until: deadline) { await writer.finishWriting() }
            guard writer.status == .completed else {
                throw writer.error ?? PileSnapshotError.drawingFailed
            }
        } catch {
            cancel()
            throw error
        }
    }

    /// Stops writing and leaves an incomplete file, which the caller deletes.
    func cancel() {
        soundFeed.finish()
        soundtrack.cancel()
        if writer.status == .writing { writer.cancelWriting() }
    }

    /// Waits for `operation` until `deadline`, then throws `PileSnapshotError.drawingFailed`
    /// and leaves the operation to end on its own, if ever. Cancelling the calling task does
    /// not end the wait sooner.
    private func wait(
        until deadline: ContinuousClock.Instant,
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let outcome = Outcome()
        try await withCheckedThrowingContinuation { continuation in
            outcome.continuation = continuation
            let timer = Task {
                try await Task.sleep(until: deadline)
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

    /// Writes `image` to `url` as a JPEG that names `identifier` as its Live Photo content
    /// identifier, in the Apple maker note's key 17, which pairs it with the movie.
    nonisolated static func writeStill(_ image: CGImage, identifier: String, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PileSnapshotError.drawingFailed }
        CGImageDestinationAddImage(
            destination, image,
            [
                kCGImagePropertyMakerAppleDictionary: ["17": identifier],
                kCGImageDestinationLossyCompressionQuality: 0.92,
            ] as CFDictionary)
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

    /// Draws `overlay` over a frame of 32-bit BGRA `pixels` in Display P3, `width` by
    /// `height` with rows `bytesPerRow` apart and the top row first, ignoring their alpha byte.
    /// Returns a copy of the result, `snapshot` times smaller in each dimension, when `snapshot`
    /// is set.
    static func draw(
        _ overlay: CGImage, over pixels: UnsafeMutableRawPointer, width: Int, height: Int,
        bytesPerRow: Int, snapshot: Int?
    ) -> CGImage? {
        guard
            let context = context(
                width: width, height: height, alpha: false, data: pixels, bytesPerRow: bytesPerRow)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(overlay, in: bounds)
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
