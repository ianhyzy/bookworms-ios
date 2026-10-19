import AVFoundation
import CoreMedia
import RealityKit
import XCTest

@testable import Bookworms

final class PileMovieTests: XCTestCase {
    func testFramesAdvanceTheSimulationAThirtiethOfASecond() {
        XCTAssertEqual(
            Double(PileMovieTiming.frameCount) / Double(PileMovieTiming.framesPerSecond), 6)
        XCTAssertEqual(
            PileMovieTiming.stepDuration * Double(PileMovieTiming.stepsPerFrame), 1.0 / 30,
            accuracy: 1e-12)
        XCTAssertEqual(PileMovieTiming.time(ofFrame: 0), .zero)
        XCTAssertEqual(PileMovieTiming.time(ofFrame: 45).seconds, 1.5, accuracy: 1e-12)
        XCTAssertEqual(PileMovieTiming.samplesPerFrame, 1_600)
        XCTAssertEqual(
            PileMovieTiming.samplesPerFrame * PileMovieTiming.frameCount,
            Int(ImpactSound.sampleRate) * 6)
    }

    func testAHitSoundsWithTheFirstFrameThatShowsIt() {
        // Frame f takes two steps and shows the simulation after them, so the hits of steps
        // 2f + 1 and 2f + 2 show in it. Times add up from steps, as the clock does.
        var time: TimeInterval = 0
        for step in 1...(PileMovieTiming.frameCount * PileMovieTiming.stepsPerFrame) {
            time += PileMovieTiming.stepDuration
            XCTAssertEqual(PileMovieTiming.frame(showing: time), (step - 1) / 2, "step \(step)")
        }
        XCTAssertEqual(PileMovieTiming.frame(showing: 0), 0)
        XCTAssertEqual(PileMovieTiming.frame(showing: 0.05), 1)
    }

    func testFallsLandAtTheirHeightsAndSpeeds() {
        for height: Float in [0.5, 3, 15, 45] {
            let (duration, speed) = PileMovieTiming.fall(height: height)
            XCTAssertEqual(PileMovieTiming.fallen(after: duration), height, accuracy: 1e-3)
            // Air drag holds a long fall well under its speed without drag.
            XCTAssertLessThan(speed, (2 * PileLayout.gravity * height).squareRoot())
            XCTAssertLessThan(speed, PileLayout.gravity / PileMovieTiming.airDrag)
        }
        // From 15 units up, a book lands about as fast as a 7-unit drop without drag.
        XCTAssertEqual(
            PileMovieTiming.fall(height: 15).speed, (2 * PileLayout.gravity * 7).squareRoot(),
            accuracy: 3)
    }

    func testLandingsKeepTheOrderAndLeaveTimeForTheStill() {
        let clip = Float(PileMovieTiming.frameCount) / Float(PileMovieTiming.framesPerSecond)
        for count in [1, 3, 12, 40, 150] {
            // Falls of 0.5 to 2 seconds, longer for books nearer the camera, which go down later.
            let durations = (0..<count).map { 0.5 + 1.5 * Float($0 % 7) / 6 }
            let landings = PileMovieTiming.landings(durations)
            XCTAssertEqual(landings.count, count)
            XCTAssertGreaterThanOrEqual(landings[0], PileMovieTiming.firstLanding)
            for (index, landing) in landings.enumerated() {
                XCTAssertGreaterThanOrEqual(landing, durations[index])
                if index > 0 { XCTAssertGreaterThan(landing, landings[index - 1]) }
            }
            XCTAssertLessThanOrEqual(landings.last!, clip - 1.5, "\(count)")
        }
        XCTAssertEqual(PileMovieTiming.landings([1, 1]), [1, 1.4])
    }

    func testBooksStartHiddenBehindTheHeading() {
        let camera = PileCamera(target: [0, 0, 1], zoom: 1.5)
        let aspect: Float = 1080.0 / 1350
        let headingY: Float = 0.5
        let corners: [SIMD3<Float>] = [[-1, 0, 4], [1, 0.3, 4], [-1, 0, 2], [1, 0.3, 2]]
        let height = PileMovieTiming.startHeight(
            of: corners, camera: camera, headingY: headingY, aspect: aspect)
        XCTAssertGreaterThan(height, 0)
        // Every corner starts above the heading's edge, and the lowest just reaches it.
        let raised = corners.map { camera.project($0 + [0, height, 0], aspect: aspect).y }
        XCTAssertGreaterThanOrEqual(raised.min()!, headingY - 1e-3)
        XCTAssertEqual(raised.min()!, headingY, accuracy: 1e-2)
        // A camera too close to hide a book starts it just under the camera's height.
        let close = PileCamera(target: [0, 0, 1], zoom: 20)
        XCTAssertEqual(
            PileMovieTiming.startHeight(
                of: [[0, 0, 6]], camera: close, headingY: 0.99, aspect: aspect),
            close.transform.translation.y - 1, accuracy: 1e-3)
    }

    func testABookFallsStraightDownIntoItsPlace() {
        let rest = Transform(
            rotation: simd_quatf(angle: 0.2, axis: [0, 1, 0]), translation: [1, 0.1, 2])
        let turn = simd_quatf(angle: 0.3, axis: [1, 0, 0])
        let (duration, _) = PileMovieTiming.fall(height: 10)
        func pose(_ time: Float) -> Transform {
            PileMovieTiming.pose(
                rest: rest, height: 10, duration: duration, turn: turn, landing: 2, at: time)
        }
        // Still and turned until the fall begins.
        XCTAssertEqual(pose(0).translation, rest.translation + [0, 10, 0])
        XCTAssertEqual(pose(2 - duration).translation.y, 10.1, accuracy: 1e-4)
        XCTAssertEqual(pose(0).rotation.angle, (turn * rest.rotation).angle, accuracy: 1e-4)
        // Falling straight down, faster as it goes, then at rest from the landing on.
        let heights = stride(from: 2 - duration, through: 2, by: 0.05).map { pose($0).translation }
        XCTAssertTrue(heights.allSatisfy { $0.x == 1 && $0.z == 2 })
        let drops = zip(heights, heights.dropFirst()).map { $0.y - $1.y }
        XCTAssertEqual(drops, drops.sorted())
        for time: Float in [2, 3] {
            XCTAssertEqual(pose(time).translation.y, 0.1, accuracy: 1e-3)
            XCTAssertEqual(
                abs(simd_dot(pose(time).rotation.vector, rest.rotation.vector)), 1, accuracy: 1e-4)
        }
    }

    func testEachSoundStartsOnItsFrameWithItsVolumeAndPan() {
        let hit = record(time: 0.05, variant: 2, volume: 0.5, pan: -1)
        let sound = ImpactSound.bank[2]
        let frame = PileMovieTiming.samplesPerFrame
        XCTAssertTrue(ImpactMix.samples([hit], in: 0..<frame).allSatisfy { $0 == 0 })
        let mix = ImpactMix.samples([hit], in: frame..<frame * 2)
        XCTAssertEqual(mix.count, frame * 2)
        for index in [0, 10, 500] {
            XCTAssertEqual(
                mix[index * 2], sound[index] * 0.5 * ImpactSound.level, accuracy: 1e-6)
            // Panned fully left, nothing plays on the right.
            XCTAssertEqual(mix[index * 2 + 1], 0, accuracy: 1e-6)
        }
        let center = ImpactMix.gains(pan: 0)
        XCTAssertEqual(center.left, 0.7071, accuracy: 0.0001)
        XCTAssertEqual(center.right, 0.7071, accuracy: 0.0001)
        // As the live mixer plays the scene's widest pan.
        XCTAssertEqual(ImpactMix.gains(pan: 0.8).right, 0.99, accuracy: 0.005)
        XCTAssertEqual(ImpactMix.gains(pan: 1).left, 0, accuracy: 1e-6)
    }

    func testMixingFrameByFrameMatchesMixingWhole() {
        let hits = [
            record(time: 0.02, variant: 0, volume: 1, pan: 0.3),
            // Starts before the first ends, and runs across several frames.
            record(time: 0.06, variant: 1, volume: 0.8, pan: -0.5),
            record(time: 0.3, variant: 3, volume: 0.4, pan: 0.8),
        ]
        let frame = PileMovieTiming.samplesPerFrame
        let whole = ImpactMix.samples(hits, in: 0..<frame * 20)
        let pieces = (0..<20).flatMap { ImpactMix.samples(hits, in: $0 * frame..<($0 + 1) * frame) }
        XCTAssertEqual(whole, pieces)
        XCTAssertGreaterThan(whole.map(abs).max() ?? 0, 0.1)
    }

    func testTheMixStaysWithinFullScale() {
        let pileUp = (0..<20)
            .map {
                record(time: 0.01, variant: $0 % 4, volume: 1, pan: 1)
            }
        let mix = ImpactMix.samples(pileUp, in: 0..<PileMovieTiming.samplesPerFrame * 4)
        XCTAssertEqual(mix.map(abs).max() ?? 0, 1, accuracy: 1e-6)
    }

    /// A held last frame lengthens the movie and its soundtrack by the hold, in frames a
    /// thirtieth of a second long, as a dominoes recording ends.
    @MainActor
    func testAHeldFrameLengthensTheMovieAndItsSoundtrack() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "held.mp4")
        let writer = try PileMovieWriter(url: url, width: 64, height: 64)
        try writer.start()
        let picture = CVReadOnlyPixelBuffer(try writer.framePool().makeMutablePixelBuffer())
        let deadline = ContinuousClock.now + PileMovieWriter.finishTimeout
        for frame in 0..<3 { try await writer.append(picture, at: frame, before: deadline) }
        try await writer.hold(picture, for: 1, before: deadline)
        XCTAssertEqual(writer.frameCount, 33)
        try await writer.finish(hits: [], before: deadline)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.1, accuracy: 0.02)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let sound = try await audio?.load(.timeRange).duration
        XCTAssertEqual(sound?.seconds ?? 0, 1.1, accuracy: 0.03)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let samples = reader.outputProvider(
            for: AVAssetReaderTrackOutput(track: video, outputSettings: nil))
        try reader.start()
        var count = 0
        while try await samples.next() != nil { count += 1 }
        XCTAssertEqual(count, 33)
    }

    private func record(
        time: TimeInterval, variant: Int, volume: Float, pan: Float
    ) -> ImpactRecord {
        ImpactRecord(
            time: time, impulse: 1, mass: 0.5, position: .zero, variant: variant,
            volume: volume, pan: pan)
    }
}
