import CoreMedia
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
        XCTAssertEqual(PileMovieTiming.samplesPerFrame, 1_470)
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

    func testTheClipShowsTheLastGroupsAndLeavesTimeToCloseIn() {
        XCTAssertEqual(PileMovieTiming.shownGroups, 8)
        let few = PileMovieTiming.schedule(groups: 3)
        XCTAssertEqual(few.preroll, 0)
        XCTAssertEqual(few.frames, [0, 12, 24])
        let many = PileMovieTiming.schedule(groups: 14)
        XCTAssertEqual(many.preroll, 6)
        XCTAssertEqual(many.frames.count, 8)
        XCTAssertEqual(many.frames.last, PileMovieTiming.lastDrop)
        XCTAssertEqual(PileMovieTiming.schedule(groups: 0).frames, [])
        // The camera has at least 1.2 seconds to close in.
        XCTAssertGreaterThanOrEqual(
            PileMovieTiming.frameCount - 1 - PileMovieTiming.holdFrames - PileMovieTiming.lastDrop
                - PileMovieTiming.pushDelay, 36)
    }

    func testTheHighestStartLandsBeforeTheCameraMoves() {
        XCTAssertLessThanOrEqual(PileMovieTiming.highestBase + 3.7 + 0.8, PileLayout.ceiling)
        // Steps a fall from the highest start under gravity and air drag.
        let step = Float(PileMovieTiming.stepDuration)
        var height = PileMovieTiming.highestBase + 3.7
        var speed: Float = 0
        var steps = 0
        while height > 0 {
            speed = (speed + PileLayout.gravity * step) / (1 + PileMovieTiming.airDrag * step)
            height -= speed * step
            steps += 1
        }
        XCTAssertLessThan(steps, PileMovieTiming.pushDelay * PileMovieTiming.stepsPerFrame)
    }

    func testTheCameraEasesInOnThePileAndHoldsForTheStill() {
        let last = PileMovieTiming.frameCount - 1
        for lastDrop in [0, 48, PileMovieTiming.lastDrop] {
            let start = lastDrop + PileMovieTiming.pushDelay
            let pushes = (0...last).map { PileMovieTiming.push(atFrame: $0, lastDrop: lastDrop) }
            XCTAssertTrue(pushes[...start].allSatisfy { $0 == 0 })
            XCTAssertTrue(pushes[(last - PileMovieTiming.holdFrames)...].allSatisfy { $0 == 1 })
            XCTAssertEqual(pushes, pushes.sorted())
            // Eases in and out: the first and last steps are the smallest.
            let steps = zip(pushes.dropFirst(), pushes).map { $0 - $1 }.filter { $0 > 0 }
            XCTAssertLessThan(steps.first!, steps[steps.count / 2])
            XCTAssertLessThan(steps.last!, steps[steps.count / 2])
        }
    }

    func testBooksStartHiddenBehindTheHeading() throws {
        for aspect in ShareAspect.allCases {
            for count in [1, 12, 40, 150] {
                let layout = try XCTUnwrap(PileSnapshotLayout(aspect: aspect, count: count))
                let size = aspect.size
                let headingY = 1 - 2 * Float(layout.pileTop / size.height)
                let nearestZ = layout.tray.scaled(by: 0.7).nearZ - PileLayout.reach
                let base = PileMovieTiming.dropBase(
                    camera: layout.camera, headingY: headingY, nearestZ: nearestZ)
                XCTAssertTrue((0...PileMovieTiming.highestBase).contains(base))
                guard base < PileMovieTiming.highestBase else { continue }
                // The nearest book's near edge, in the lowest layer, starts on the heading's
                // edge, and farther or higher points start above it, out of view.
                let aspectRatio = Float(size.width / size.height)
                let edge = SIMD3(0, base + 1.2, nearestZ + PileLayout.reach)
                XCTAssertEqual(
                    layout.camera.project(edge, aspect: aspectRatio).y, headingY, accuracy: 1e-3,
                    "\(aspect) \(count)")
                for point in [edge + [2, 0, -3], edge + [0, 2.5, 0], edge + [-1.5, 1, -1]] {
                    XCTAssertGreaterThan(
                        layout.camera.project(point, aspect: aspectRatio).y, headingY)
                }
            }
        }
    }

    func testEachSoundStartsOnItsFrameWithItsVolumeAndPan() {
        let hit = record(time: 0.05, kind: .thud, variant: 2, volume: 0.5, pan: -1)
        let sound = ImpactSound.bank[.thud]![2]
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
            record(time: 0.02, kind: .slap, variant: 0, volume: 1, pan: 0.3),
            // Starts before the first ends, and runs across several frames.
            record(time: 0.06, kind: .thud, variant: 1, volume: 0.8, pan: -0.5),
            record(time: 0.3, kind: .thud, variant: 3, volume: 0.4, pan: 0.8),
        ]
        let frame = PileMovieTiming.samplesPerFrame
        let whole = ImpactMix.samples(hits, in: 0..<frame * 20)
        let pieces = (0..<20).flatMap { ImpactMix.samples(hits, in: $0 * frame..<($0 + 1) * frame) }
        XCTAssertEqual(whole, pieces)
        XCTAssertGreaterThan(whole.map(abs).max() ?? 0, 0.1)
    }

    func testTheMixStaysWithinFullScale() {
        let pileUp = (0..<20).map {
            record(time: 0.01, kind: .thud, variant: $0 % 4, volume: 1, pan: 1)
        }
        let mix = ImpactMix.samples(pileUp, in: 0..<PileMovieTiming.samplesPerFrame * 4)
        XCTAssertEqual(mix.map(abs).max() ?? 0, 1, accuracy: 1e-6)
    }

    private func record(
        time: TimeInterval, kind: ImpactSound.Kind, variant: Int, volume: Float, pan: Float
    ) -> ImpactRecord {
        ImpactRecord(
            time: time, impulse: 1, mass: 0.5, position: .zero, kind: kind, variant: variant,
            volume: volume, pan: pan)
    }
}
