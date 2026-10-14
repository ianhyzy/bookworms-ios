import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import Metal
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
    /// Audio sample frames per video frame: 1,600 at 48 kHz.
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
            guard ImpactSound.bank.indices.contains(record.variant) else { continue }
            let sound = ImpactSound.bank[record.variant]
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

/// Writes a video as an MP4 that Photos and social apps take as it is: H.264 High profile,
/// 8-bit 4:2:0 frames at 30 per second in Rec. 709 colors, an AAC-LC soundtrack at 48 kHz in
/// stereo, and the movie's index at the front of the file, with no other tracks or metadata. A
/// pile video can also get a QuickTime copy with the metadata that pairs it with a still as a
/// Live Photo.
///
/// The frames are encoded as they come, into a file of their own with one input, which takes
/// each frame as soon as the encoder has room for it. The sound joins them in a second pass
/// (`finish(hits:livePhoto:before:)`), which copies the frames without decoding them and
/// encodes the soundtrack mixed from the recorded hits (`ImpactMix`). A writer with several
/// inputs pairs their samples as it writes, and stops taking frames while it waits for sound
/// it has not been given: fed one frame's sound at a time, it did so partway through long
/// clips. The second pass offers each track its next sample in turn, so no track waits on
/// another.
///
/// Frames come from the encoder's pool (`framePool()`), whose buffers Metal can draw into
/// (`FrameComposer`). An offline render offers each frame with `appendImmediately` until the
/// encoder takes it, 4 milliseconds apart (`append(_:at:before:)`), which bounds the frames
/// waiting for the encoder and the pixel buffers they hold; a live recording offers its frames
/// without waiting (`appendIfReady(_:at:)`) and keeps the few the encoder has no room for
/// until it does (see `DominoRecorder`). The inputs' own `append` waits do not
/// return when their task or the writer is cancelled, so every wait ends at a deadline, which
/// fails the movie without waiting any further.
@MainActor
final class PileMovieWriter {
    /// How long the frames may take to finish, and the movie to be written from them.
    static let finishTimeout = Duration.seconds(30)

    /// The MP4 that `finish(hits:livePhoto:before:)` writes.
    let url: URL
    /// The frames alone, which `finish(hits:livePhoto:before:)` replaces with the movie.
    private let framesURL: URL
    private let writer: AVAssetWriter
    private let frames: AVAssetWriterInput.PixelBufferReceiver
    /// One more than the number of the last frame the encoder took, which sets the movie's
    /// length.
    private(set) var frameCount = 0
    /// How many frames the encoder took. A live recording that drops frames takes fewer than
    /// `frameCount`; each frame shows until the next one it took.
    private(set) var encodedCount = 0

    private static let stillImageTimeIdentifier = "mdta/com.apple.quicktime.still-image-time"
    nonisolated private static let log = Logger(
        subsystem: "gay.ian.Bookworms.iOS", category: "video")

    /// The writer of a movie's frames and its input, which `encoder(url:width:height:live:)`
    /// makes on any thread.
    struct Encoder {
        fileprivate let writer: AVAssetWriter
        fileprivate let frames: AVAssetWriterInput.PixelBufferReceiver
    }

    /// Prepares a movie of `width` by `height` pixels at `url`, an `.mp4` file that must not
    /// exist yet. For a `live` recording, the input expects its frames in real time
    /// (`expectsMediaDataInRealTime`), so it takes them as they come rather than pacing them as
    /// for an offline render, and the writer starts at once (see `start()`).
    convenience init(url: URL, width: Int, height: Int, live: Bool = false) throws {
        self.init(
            url: url,
            encoder: try Self.encoder(url: url, width: width, height: height, live: live))
    }

    /// Takes the writer that `encoder(url:width:height:live:)` made for `url`.
    init(url: URL, encoder: sending Encoder) {
        self.url = url
        framesURL = Self.framesURL(for: url)
        writer = encoder.writer
        frames = encoder.frames
    }

    /// The writer and input of `init(url:width:height:live:)`, made on any thread, so a
    /// recorder can make a live writer, which can take a tenth of a second or more, away from
    /// the main actor.
    nonisolated static func encoder(url: URL, width: Int, height: Int, live: Bool) throws
        -> sending Encoder
    {
        let writer = try AVAssetWriter(outputURL: framesURL(for: url), fileType: .mov)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                // Rec. 709, as `FrameComposer` draws the frames.
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                    AVVideoAverageBitRateKey: 10_000_000,
                    AVVideoExpectedSourceFrameRateKey: Int(PileMovieTiming.framesPerSecond),
                    AVVideoMaxKeyFrameIntervalKey: 2 * Int(PileMovieTiming.framesPerSecond),
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
        video.expectsMediaDataInRealTime = live
        guard writer.canAdd(video) else { throw PileSnapshotError.drawingFailed }
        let frames = writer.inputPixelBufferReceiver(
            for: video,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                size: CVImageSize(width: width, height: height), compatibility: .metalTexture))
        if live { try start(writer) }
        return Encoder(writer: writer, frames: frames)
    }

    /// The file of the frames alone for a movie at `url`.
    nonisolated private static func framesURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("frames.mov")
    }

    /// Starts the frames at time zero, for a writer that is not `live`.
    ///
    /// - Throws: `PileSnapshotError` when the writer fails to start.
    func start() throws { try Self.start(writer) }

    nonisolated private static func start(_ writer: AVAssetWriter) throws {
        try writer.start()
        writer.startSession(atSourceTime: .zero)
    }

    /// The encoder's pool of frames, for `FrameComposer` to draw into, from any thread, once
    /// the writer has started.
    ///
    /// - Throws: The writer's error, or `PileSnapshotError`, when it has no pool.
    func framePool() throws -> CVMutablePixelBuffer.Pool {
        guard let pool = frames.pixelBufferPool else {
            Self.log.error(
                "No pixel buffer pool: writer status \(self.writer.status.rawValue), \(String(describing: self.writer.error))"
            )
            throw writer.error ?? PileSnapshotError.drawingFailed
        }
        return pool
    }

    /// Adds `picture` as frame `frame`, and waits until the encoder takes it.
    ///
    /// - Throws: `PileSnapshotError` when the writer fails or does not take the frame by
    ///   `deadline`.
    func append(
        _ picture: CVReadOnlyPixelBuffer, at frame: Int, before deadline: ContinuousClock.Instant
    ) async throws {
        let time = PileMovieTiming.time(ofFrame: frame)
        try await Self.offer("frame \(frame)", to: writer, until: deadline) {
            try frames.appendImmediately(picture, with: time)
        }
        frameCount = max(frameCount, frame + 1)
        encodedCount += 1
    }

    /// Adds `picture` as frame `frame` if the encoder has room for it, without waiting, as a
    /// live recording needs. Returns whether the encoder took it.
    ///
    /// - Throws: The writer's error when it has failed.
    func appendIfReady(_ picture: CVReadOnlyPixelBuffer, at frame: Int) throws -> Bool {
        let time = PileMovieTiming.time(ofFrame: frame)
        guard try frames.appendImmediately(picture, with: time) else { return false }
        frameCount = max(frameCount, frame + 1)
        encodedCount += 1
        return true
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

    /// Finishes the frames, then writes the MP4 at `url` with the soundtrack mixed from `hits`
    /// and, for a Live Photo's content identifier `livePhoto`, a QuickTime copy that names it
    /// and marks the last frame as the still's (see `livePhotoURL(for:)`). Cancels the movie
    /// when that fails, leaving incomplete files for the caller to delete.
    ///
    /// - Throws: `PileSnapshotError` when a writer fails or the movie is not done by
    ///   `deadline`.
    func finish(
        hits: [ImpactRecord], livePhoto identifier: String? = nil,
        before deadline: ContinuousClock.Instant
    ) async throws {
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
            try await wait(for: "the movie", until: deadline) {
                try await self.mux(sound, to: self.url, identifier: nil)
            }
            if let identifier {
                try await wait(for: "the Live Photo", until: deadline) {
                    try await self.mux(
                        sound, to: Self.livePhotoURL(for: self.url), identifier: identifier)
                }
            }
            Self.log.notice(
                "Wrote \(self.encodedCount) of \(self.frameCount) frames into the movie in \((ContinuousClock.now - began) / .seconds(1), format: .fixed(precision: 2)) s"
            )
            try? FileManager.default.removeItem(at: framesURL)
        } catch {
            cancel()
            throw error
        }
    }

    /// Where `finish(hits:livePhoto:before:)` writes the Live Photo's copy of the movie at
    /// `url`.
    nonisolated static func livePhotoURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("mov")
    }

    /// Writes a movie at `target` from the finished frames and `sound`, the whole interleaved
    /// stereo soundtrack at `ImpactSound.sampleRate`: an MP4, or, for the Live Photo content
    /// identifier `identifier`, a QuickTime movie with the metadata that names it and a timed
    /// metadata track whose one sample marks the last frame as the still's.
    private func mux(_ sound: [Float], to target: URL, identifier: String?) async throws {
        let asset = AVURLAsset(url: framesURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PileSnapshotError.drawingFailed
        }
        let reader = try AVAssetReader(asset: asset)
        let pictures = reader.outputProvider(
            for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))

        let movie = try AVAssetWriter(outputURL: target, fileType: identifier == nil ? .mp4 : .mov)
        // Puts the index before the media, so apps can play and upload the file as it arrives.
        movie.shouldOptimizeForNetworkUse = true
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
                timeRange: CMTimeRange(
                    start: PileMovieTiming.time(ofFrame: max(frameCount - 1, 0)),
                    duration: PileMovieTiming.time(ofFrame: 1)))
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

    /// Writes `image` to `url` as a PNG, or as a JPEG for a `.jpg` URL that names
    /// `identifier`, if any, as its Live Photo content identifier, in the Apple maker note's
    /// key 17, which pairs it with the movie.
    nonisolated static func writeStill(_ image: CGImage, identifier: String?, to url: URL)
        throws
    {
        let type: UTType = url.pathExtension == "jpg" ? .jpeg : .png
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, 1, nil)
        else { throw PileSnapshotError.drawingFailed }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let identifier { properties[kCGImagePropertyMakerAppleDictionary] = ["17": identifier] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PileSnapshotError.drawingFailed
        }
    }
}

/// Draws video frames on the GPU with Core Image: part of a 3D render, scaled to fill the
/// frame, over a background, under overlays such as a heading and the credit, and converted
/// from the render's Display P3 primaries to the Rec. 709 primaries, with the sRGB curve, that
/// `PileMovieWriter` tags its frames with. The few colors of the lamp-lit scene outside Rec. 709
/// clip to it.
///
/// It keeps no state between frames, so any thread can use it, such as RealityKit's render
/// thread, which records a run (`DominoRecorder`).
final class FrameComposer: Sendable {
    let device: any MTLDevice
    private let context: CIContext
    private let renderSpace: CGColorSpace
    private let linearRenderSpace: CGColorSpace
    private let frameSpace: CGColorSpace

    /// - Throws: `PileSnapshotError` when Metal is unavailable.
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let renderSpace = CGColorSpace(name: CGColorSpace.displayP3),
            let linearRenderSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
            let frameSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw PileSnapshotError.drawingFailed }
        self.device = device
        self.renderSpace = renderSpace
        self.linearRenderSpace = linearRenderSpace
        self.frameSpace = frameSpace
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// `texture`, a render with Display P3 primaries, as an image the right way up.
    func image(of texture: any MTLTexture) -> CIImage? {
        // Metal decodes an sRGB texture's values to linear ones as Core Image reads them.
        let decoded: Set<MTLPixelFormat> = [
            .bgra8Unorm_srgb, .rgba8Unorm_srgb, .bgr10_xr_srgb, .bgra10_xr_srgb,
        ]
        let space = decoded.contains(texture.pixelFormat) ? linearRenderSpace : renderSpace
        return CIImage(mtlTexture: texture, options: [.colorSpace: space])?
            .oriented(.downMirrored)
    }

    /// The frame of `size` pixels that shows the part `crop` of `render`, in the render's
    /// pixels from its top left, scaled to fill the frame, over `background`, stretched under
    /// the whole render, and under `overlays`, each the frame's size, at their opacities.
    func frame(
        of render: CIImage, crop: CGRect, size: CGSize, background: CIImage? = nil,
        overlays: [(image: CIImage, opacity: CGFloat)]
    ) -> CIImage {
        // Core Image counts y up from the bottom.
        let extent = render.extent
        let part = CGRect(
            x: crop.minX, y: extent.maxY - crop.maxY, width: crop.width, height: crop.height)
        let scene =
            background.map { background in
                render.composited(
                    over: background.transformed(
                        by: CGAffineTransform(
                            scaleX: extent.width / background.extent.width,
                            y: extent.height / background.extent.height)))
            } ?? render
        var frame = scene.cropped(to: part)
            // Repeats the edge pixels, so scaling blends nothing from outside the part.
            .clampedToExtent()
            .transformed(
                by: CGAffineTransform(translationX: -part.minX, y: -part.minY)
                    .concatenating(
                        CGAffineTransform(
                            scaleX: size.width / part.width, y: size.height / part.height)))
        for overlay in overlays where overlay.opacity > 0 {
            let image =
                overlay.opacity >= 1
                ? overlay.image
                : overlay.image.applyingFilter(
                    "CIColorMatrix",
                    parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: overlay.opacity)])
            frame = image.composited(over: frame)
        }
        return frame.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Encodes drawing `image` into `picture`, a frame from `PileMovieWriter.framePool()`, on
    /// `commands`, which must commit before the frame is used.
    ///
    /// - Throws: `PileSnapshotError` when the frame has no Metal texture, and Core Image's
    ///   errors.
    func render(
        _ image: CIImage, into picture: CVReadOnlyPixelBuffer, on commands: any MTLCommandBuffer
    ) throws {
        try picture.withUnsafeBuffer { buffer in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer), mipmapped: false)
            descriptor.usage = [.shaderWrite, .renderTarget]
            descriptor.storageMode = .shared
            guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue(),
                let texture = device.makeTexture(
                    descriptor: descriptor, iosurface: surface, plane: 0)
            else { throw PileSnapshotError.drawingFailed }
            let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commands)
            destination.colorSpace = frameSpace
            destination.isFlipped = true
            destination.alphaMode = .none
            try context.startTask(toRender: image, to: destination)
        }
    }

    /// `picture`, `scale` times its size, as an image to show or save.
    func cgImage(of picture: CVReadOnlyPixelBuffer, scale: CGFloat = 1) -> CGImage? {
        let space = frameSpace
        let image = picture.withUnsafeBuffer {
            CIImage(cvPixelBuffer: $0, options: [.colorSpace: space])
        }
        return cgImage(
            scale == 1 ? image : image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
    }

    /// `image` as an image to show or save, in sRGB.
    func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(
            image, from: image.extent.integral, format: .BGRA8, colorSpace: frameSpace)
    }
}
