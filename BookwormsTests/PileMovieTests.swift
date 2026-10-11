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

    func testTheClipShowsTheLastGroupsAndLeavesTimeToSettle() {
        XCTAssertEqual(PileMovieTiming.shownGroups, 10)
        let few = PileMovieTiming.schedule(groups: 3)
        XCTAssertEqual(few.preroll, 0)
        XCTAssertEqual(few.frames, [6, 18, 30])
        let many = PileMovieTiming.schedule(groups: 14)
        XCTAssertEqual(many.preroll, 4)
        XCTAssertEqual(many.frames.count, 10)
        XCTAssertEqual(many.frames.first, PileMovieTiming.firstDrop)
        XCTAssertLessThanOrEqual(
            many.frames.last ?? .max, PileMovieTiming.frameCount - PileMovieTiming.settleFrames)
        XCTAssertEqual(PileMovieTiming.schedule(groups: 0).frames, [])
    }

    func testAGroupLandsBeforeTheGroupAfterNextDrops() {
        // `BookPileScene.drop` leaves only the previous group out of the pile's height, so a
        // group must land from its highest start within two group intervals.
        let interval = Float(2 * PileMovieTiming.groupFrames) / Float(PileMovieTiming.framesPerSecond)
        let fall = 0.5 * PileLayout.gravity * interval * interval
        XCTAssertLessThan(3.7 + PileMovieTiming.lift, fall)
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
