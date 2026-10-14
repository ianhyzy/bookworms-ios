import RealityKit
import XCTest
import simd

@testable import Bookworms

/// How a book lifted out of an arranged scene leaves its place without passing through the
/// books resting on it (`BookExit`).
final class BookExitTests: XCTestCase {
    /// A thin book, 14 by 22 by 3 cm.
    private static let size = SIMD3<Float>(1.4, 2.2, 0.3)
    /// How far beyond the lifted book's end a rider's far edge rests on the table.
    private static let run: Float = 1.9

    /// A book lying flat, front cover up, head away from the camera, at `x` and `z`.
    private func flat(x: Float = 0, z: Float = 0) -> Transform {
        Transform(rotation: PileSpread.upright, translation: [x, Self.size.z / 2, z])
    }

    /// A book that rests across an end of the flat book at the origin: on the table at its far
    /// edge, `run` past that end, and on the end's top edge. `side` is +1 for the end toward the
    /// camera (+z) and -1 for the other.
    private func rider(side: Float) -> Transform {
        let angle = atan(Self.size.z / Self.run)
        let rotation = simd_quatf(angle: side * angle, axis: [1, 0, 0]) * PileSpread.upright
        let head = rotation.act([0, 1, 0])
        let up = rotation.act([0, 0, 1])
        // The middle of its far bottom edge, on the table.
        let far = SIMD3<Float>(0, 0, side * (Self.size.y / 2 + Self.run))
        return Transform(
            rotation: rotation,
            translation: far + head * (side * Self.size.y / 2) + up * Self.size.z / 2)
    }

    private func box(_ pose: Transform) -> DominoSetup.Box {
        DominoSetup.Box(pose, size: Self.size, grow: -BookExit.touch)
    }

    func testABookWithNothingOnItRisesStraightUp() {
        let exit = BookExit(
            book: (flat(), Self.size), among: [(flat(x: 1.45), Self.size)], margin: 0)
        XCTAssertTrue(exit.riders.isEmpty)
        XCTAssertEqual(exit.slide, .zero)
        XCTAssertGreaterThanOrEqual(exit.rise, 0.4)
    }

    func testABookSlidesOutFromUnderTheBookAcrossItsEnd() {
        let resting = rider(side: 1)
        let exit = BookExit(book: (flat(), Self.size), among: [(resting, Self.size)])
        XCTAssertEqual(exit.riders.count, 1)
        XCTAssertFalse(exit.drawsBack)
        // It slides along its length, away from the rider, just far enough.
        XCTAssertEqual(exit.slide.x, 0, accuracy: 1e-3)
        XCTAssertEqual(exit.slide.y, 0, accuracy: 1e-3)
        XCTAssertLessThan(exit.slide.z, -0.25)
        XCTAssertGreaterThan(exit.slide.z, -0.8)
        // The rider tips down until it lies flat on the table.
        let rider = exit.riders[0]
        let angle = atan(Self.size.z / Self.run)
        XCTAssertEqual(rider.fallen, angle, accuracy: 0.03)
        let fallen = DominoSetup.Box(rider.pose(turned: rider.fallen), size: Self.size)
        XCTAssertGreaterThan(fallen.bounds.low.y, -0.03)
        // No pose on the slide meets the rider as it rests, and the book ends clear of it as it
        // rests and as it fell.
        for step in 0...10 {
            var pose = flat()
            pose.translation += exit.slide * Float(step) / 10
            XCTAssertFalse(box(pose).overlaps(box(resting)), "\(step)")
        }
        var slid = flat()
        slid.translation += exit.slide
        XCTAssertFalse(box(slid).overlaps(rider.box(turned: rider.fallen)))
    }

    func testRidersAcrossBothEndsAreDrawnBackOffTheBook() {
        // Books side by side and riders across both ends leave the book no way to slide out.
        let others: [BookExit.Book] = [
            (rider(side: 1), Self.size), (rider(side: -1), Self.size),
            (flat(x: 1.45), Self.size), (flat(x: -1.45), Self.size),
        ]
        let exit = BookExit(book: (flat(), Self.size), among: others)
        XCTAssertEqual(exit.riders.count, 2)
        XCTAssertTrue(exit.drawsBack)
        XCTAssertEqual(exit.slide, .zero)
        let lifted = DominoSetup.Box(flat(), size: Self.size)
        for rider in exit.riders {
            // Each is drawn back level, away from the book, by less than half its length.
            XCTAssertEqual(rider.back.y, 0, accuracy: 1e-4)
            XCTAssertGreaterThan(simd_dot(rider.back, rider.rest.translation), 0)
            XCTAssertLessThan(simd_length(rider.back), Self.size.y / 2)
            // Drawn back, nothing of it lies over the book's way up, and where it fell, it
            // meets neither the book nor the table.
            let drawn = rider.box(turned: 0)
            for step in 0...20 {
                let raised = DominoSetup.Box(
                    Transform(
                        rotation: PileSpread.upright,
                        translation: [0, Self.size.z / 2 + Float(step) * 0.1, 0]),
                    size: Self.size, grow: -BookExit.touch)
                XCTAssertFalse(raised.overlaps(drawn), "\(step)")
            }
            let fallen = rider.box(turned: rider.fallen)
            XCTAssertFalse(fallen.overlaps(lifted.shrunk))
            XCTAssertGreaterThan(fallen.bounds.low.y, -0.03)
        }
        // The book rises clear of the riders where they fell.
        XCTAssertGreaterThanOrEqual(exit.rise, 0.4)
    }
}
