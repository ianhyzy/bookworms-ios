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
    /// units above its base, so a tilted book there stays under `PileLayout.ceiling`.
    static let highestBase: Float = PileLayout.ceiling - 4.5
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
/// one video frame and its `PileMovieTiming.samplesPerFrame` samples at a time, so the writer
/// can interleave them. Each append waits until its input takes more, which bounds the frames
/// waiting for the encoder and the pixel buffers they hold.
@MainActor
final class PileMovieWriter {
    private let writer: AVAssetWriter
    private let frames: AVAssetWriterInput.PixelBufferReceiver
    private let sound: AVAssetWriterInput.SampleBufferReceiver
    private let stillTime: AVAssetWriterInput.MetadataReceiver
    private let soundFormat: CMAudioFormatDescription

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
        sound = writer.inputReceiver(for: audio)
        stillTime = writer.inputMetadataReceiver(for: metadata)
        soundFormat = try CMAudioFormatDescription(
            audioStreamBasicDescription: AudioStreamBasicDescription(
                mSampleRate: ImpactSound.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                mBitsPerChannel: 32, mReserved: 0))
    }

    /// Starts the movie at time zero and marks frame `stillFrame` as the Live Photo's still.
    func start(stillFrame: Int) async throws {
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: Self.stillImageTimeIdentifier)
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        try await stillTime.append(
            AVTimedMetadataGroup(
                items: [item],
                timeRange: CMTimeRange(
                    start: PileMovieTiming.time(ofFrame: stillFrame),
                    duration: PileMovieTiming.time(ofFrame: 1))))
        stillTime.finish()
    }

    /// Adds a frame of 32-bit BGRA `pixels`, with rows `bytesPerRow` apart and the top row
    /// first, as frame `frame`.
    func appendFrame(_ pixels: UnsafeRawPointer, bytesPerRow: Int, at frame: Int) async throws {
        guard let pool = frames.pixelBufferPool else {
            throw writer.error ?? PileSnapshotError.drawingFailed
        }
        var buffer = try pool.makeMutablePixelBuffer()
        buffer.accessUnsafeMutableRawPlaneBytes { planes in
            guard let plane = planes.first, let base = plane.bytes.baseAddress else { return }
            let size = plane.properties.size
            for row in 0..<size.height {
                (base + row * plane.properties.bytesPerRow)
                    .copyMemory(from: pixels + row * bytesPerRow, byteCount: size.width * 4)
            }
        }
        try await frames.append(
            CVReadOnlyPixelBuffer(buffer), with: PileMovieTiming.time(ofFrame: frame))
    }

    /// Adds interleaved stereo `samples`, from `ImpactMix`, that start at sample frame `start`.
    func appendSound(_ samples: [Float], at start: Int) async throws {
        let audio = CMReadySampleBuffer(
            audioDataBuffer: CMReadOnlyDataBlockBuffer(samples.withUnsafeBytes { Data($0) }),
            formatDescription: soundFormat, sampleCount: samples.count / 2,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(start), timescale: CMTimeScale(ImpactSound.sampleRate)))
        try await sound.append(CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(audio))
    }

    /// Finishes the movie file.
    func finish() async throws {
        frames.finish()
        sound.finish()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? PileSnapshotError.drawingFailed
        }
    }

    /// Stops writing and leaves an incomplete file, which the caller deletes.
    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
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
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Draws `overlay` over a frame of 32-bit BGRA `pixels` in Display P3, `width` by
    /// `height` with rows `bytesPerRow` apart and the top row first, ignoring their alpha byte.
    /// Returns a copy of the result when `snapshot` is set.
    static func draw(
        _ overlay: CGImage, over pixels: UnsafeMutableRawPointer, width: Int, height: Int,
        bytesPerRow: Int, snapshot: Bool
    ) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
            let context = CGContext(
                data: pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(overlay, in: CGRect(x: 0, y: 0, width: width, height: height))
        return snapshot ? context.makeImage() : nil
    }
}
