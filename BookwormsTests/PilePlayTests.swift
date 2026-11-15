import RealityKit
import XCTest
import simd

@testable import Bookworms

/// The pile's play modes: the phone as the box, shakes, and the drop by period.
final class PilePlayTests: XCTestCase {
    private func book(_ id: Int, finished: String?) -> CloudBook {
        var book = CloudBook(
            id: id, title: "Fictional Book \(id)", author: "An Author", coverURL: nil,
            detailCoverURL: nil)
        book.finished = finished
        return book
    }

    private func assertNear(
        _ value: SIMD3<Float>, _ expected: SIMD3<Float>, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(simd_distance(value, expected), 0, accuracy: 0.001, file: file, line: line)
    }

    func testBoxGravityFollowsThePhoneThroughTheCamera() {
        var camera = PileCamera()
        let full = PileLayout.gravity
        // Held at the camera's pitch, the table is level.
        let level = SIMD3<Double>(camera.rotation.inverse.act([0, -1, 0]))
        assertNear(PileLayout.boxGravity(device: level, camera: camera.rotation), [0, -full, 0])
        // Face down, books fall onto the glass, toward the viewer.
        let faceDown = PileLayout.boxGravity(device: [0, 0, 1], camera: camera.rotation)
        assertNear(faceDown, camera.rotation.act([0, 0, 1]) * full)
        // Upright, they fall toward the bottom of the screen at full strength, without a cap.
        let upright = PileLayout.boxGravity(device: [0, -1, 0], camera: camera.rotation)
        assertNear(upright, camera.rotation.act([0, -1, 0]) * full)
        XCTAssertGreaterThan(upright.z, 0)

        // Turned a quarter, tipping the right edge down still sends books to the screen's right.
        camera.yaw = .pi / 2
        let right = PileLayout.boxGravity(device: [1, 0, 0], camera: camera.rotation)
        XCTAssertEqual(simd_dot(right, camera.rotation.act([1, 0, 0])), full, accuracy: 0.001)
        XCTAssertEqual(right.y, 0, accuracy: 0.001)
    }

    func testFaceDownBoxGravityFallsStraightOntoTheGlass() throws {
        let aspect: Float = 402.0 / 874
        for camera in [PileCamera(), PileCamera(yaw: 0.6)] {
            let box = try XCTUnwrap(
                PileBox(aspect: aspect, safeTop: 0.7, safeBottom: -0.8, camera: camera))
            let gravity = PileLayout.boxGravity(device: [0, 0, 1], camera: camera.rotation)
            // Against the glass's inward normal, with no share along the glass.
            XCTAssertEqual(
                simd_dot(simd_normalize(gravity), box.planes[0].normal), -1, accuracy: 0.0001)
        }
    }

    func testOnlyAHardShakeThrowsBooksAgainstTheJolt() throws {
        let camera = PileCamera().rotation
        let up = SIMD3<Float>(0, 1, 0)
        XCTAssertNil(PileLayout.shakeKick(acceleration: [1.2, 0.5, 0], camera: camera, up: up))
        // The phone jolts to its right, so the books fly to the screen's left, and hop.
        let kick = try XCTUnwrap(
            PileLayout.shakeKick(acceleration: [2.5, 0, 0], camera: camera, up: up))
        XCTAssertLessThan(simd_dot(kick, camera.act([1, 0, 0])), 0)
        XCTAssertGreaterThan(kick.y, 0)
        let hardest = try XCTUnwrap(
            PileLayout.shakeKick(acceleration: [9, 0, 0], camera: camera, up: up))
        XCTAssertGreaterThan(simd_length(hardest), simd_length(kick))
        XCTAssertEqual(
            simd_length(hardest), 20 * simd_length(SIMD3<Float>(-1, 0.6, 0)), accuracy: 0.001)
    }

    func testBoxKeepsBooksOnScreenUnderTheGlass() throws {
        let aspect: Float = 402.0 / 874
        let top: Float = 1 - 2 * 116.0 / 874
        let bottom: Float = -1 + 2 * 83.0 / 874
        let box = try XCTUnwrap(PileBox(aspect: aspect, safeTop: top, safeBottom: bottom))
        let camera = PileCamera()
        let forward = camera.rotation.act([0, 0, -1])
        // The glass is parallel to the screen, 20 units in front of the camera, and its
        // corners show just inside the bars.
        for corner in box.faces[0] {
            XCTAssertEqual(
                simd_dot(corner - camera.transform.translation, forward), 20, accuracy: 0.01)
            let ndc = camera.project(corner, aspect: aspect)
            XCTAssertLessThan(abs(ndc.x), 1)
            XCTAssertLessThan(ndc.y, top)
            XCTAssertGreaterThan(ndc.y, bottom)
        }
        // The tray lies inside the box, so books lying on the table stay put when it closes,
        // at the scene's margin.
        let tray = try XCTUnwrap(PileTray(aspect: aspect, safeTop: top, safeBottom: bottom))
        for corner in tray.scaled(by: 0.95).corners {
            XCTAssertTrue(box.contains(corner + [0, 0.1, 0], margin: 0.3))
        }
        let middle = SIMD3<Float>(0, 0.1, (tray.farZ + tray.nearZ) / 2)
        XCTAssertTrue(box.contains(middle, margin: 0.3))
        assertNear(box.clamp(middle, margin: 0.3), middle)
        // A point between the glass and the camera moves inside.
        let outside = camera.transform.translation + forward * 5
        XCTAssertFalse(box.contains(outside, margin: 0))
        XCTAssertTrue(box.contains(box.clamp(outside, margin: 1), margin: 0.9))
    }

    func testPeriodsDropInFinishOrderJanuaryFirst() {
        let books = [
            book(1, finished: "2025-08-03"), book(2, finished: "2025-01-20"),
            book(3, finished: "2025-08-01"), book(4, finished: "2025-01-05"),
        ]
        let months = PileLayout.periods(books, frame: .year(2025))
        XCTAssertEqual(months.map(\.span), [.month(1), .month(8)])
        XCTAssertEqual(months.map { $0.books.map(\.id) }, [[4, 2], [3, 1]])

        let weeks = PileLayout.periods(
            [books[0], books[2]], frame: .month(year: 2025, month: 8))
        XCTAssertEqual(weeks.map(\.span), [.days(1...7, month: 8)])
        XCTAssertEqual(weeks.first?.books.map(\.id), [3, 1])

        // Every book drops by year, leaving out empty years, and unfinished books last.
        let years = PileLayout.periods(
            books + [book(5, finished: "2023-03-01"), book(6, finished: nil)], frame: .lifetime)
        XCTAssertEqual(years.map(\.span), [.year(2023), .year(2025), nil])
        XCTAssertEqual(years.last?.books.map(\.id), [6])
    }

    // MARK: Carrying a book

    func testAHeldBookLevelsTheNearerWayAndKeepsItsTurn() {
        let yaw = simd_quatf(angle: 0.7, axis: [0, 1, 0])
        let tipped = simd_quatf(angle: 0.5, axis: [1, 0, 0])
        for flip in [
            simd_quatf(angle: 0, axis: [1, 0, 0]), simd_quatf(angle: .pi, axis: [1, 0, 0]),
        ] {
            let resting = yaw * PileLayout.lyingFlat * flip
            let level = PileCarry.level(tipped * resting)
            // Front cover up stays up, and face down stays down.
            assertNear(level.act([0, 0, 1]), resting.act([0, 0, 1]))
            // The spine lies flat and points across the table as it did, give or take the tip.
            let spine = level.act([-1, 0, 0])
            XCTAssertEqual(spine.y, 0, accuracy: 0.001)
            XCTAssertGreaterThan(simd_dot(spine, resting.act([-1, 0, 0])), 0.95)
        }
    }

    func testAThrowKeepsTheFingersSpeedUpToTheCapAndTossesTheBookUp() {
        assertNear(PileCarry.throwVelocity([5, 0, 0]), [5, 1, 0])
        assertNear(PileCarry.throwVelocity(.zero), .zero)
        let flick = PileCarry.throwVelocity([0, 3, -300])
        XCTAssertEqual(
            simd_length(SIMD2(flick.x, flick.z)), PileCarry.maximumThrowSpeed, accuracy: 0.001)
        XCTAssertLessThan(flick.z, 0)
        XCTAssertEqual(flick.y, PileCarry.maximumThrowSpeed / 5, accuracy: 0.001)
    }

    func testTurnIsTheShorterRotationToTheTarget() {
        let start = simd_quatf(angle: 0.3, axis: [0, 1, 0])
        assertNear(PileCarry.turn(from: start, to: start), .zero)
        let target = simd_quatf(angle: 0.5, axis: [1, 0, 0]) * start
        assertNear(PileCarry.turn(from: start, to: target), [0.5, 0, 0])
        // The same target as a negated quaternion turns the same short way.
        assertNear(
            PileCarry.turn(from: start, to: simd_quatf(vector: -target.vector)), [0.5, 0, 0])
    }

    func testAHeldBookLeansIntoAPushAndSettlesLevel() {
        var swing = PileSwing()
        let step: Float = 1 / 60
        var peak: Float = 0
        // A steady push toward +x leans the book's top toward +x, so its leading edge dips.
        for _ in 0..<120 {
            swing.advance(acceleration: [100, 0], by: step)
            peak = max(peak, swing.lean.x)
        }
        XCTAssertEqual(swing.lean.x, 100 * PileSwing.sensitivity, accuracy: 0.01)
        XCTAssertGreaterThan(peak, swing.lean.x)
        XCTAssertEqual(swing.lean.y, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(swing.tilt.act([0, 1, 0]).x, 0)
        // Once the finger moves steadily, the swing dies away.
        for _ in 0..<120 { swing.advance(acceleration: .zero, by: step) }
        XCTAssertLessThan(simd_length(swing.lean), 0.01)
        // However hard the push, the lean stays under its cap.
        var hard = PileSwing()
        for _ in 0..<60 { hard.advance(acceleration: [0, 1e4], by: step) }
        XCTAssertLessThanOrEqual(hard.tilt.angle, PileSwing.maximumTilt + 1e-4)
        XCTAssertGreaterThan(hard.tilt.act([0, 1, 0]).z, 0)
    }

    func testScrollingZoomsAndShiftScrollingTurns() {
        // A wheel scrolled away zooms in, toward the reader zooms out, by the same factor.
        let away = PilePointer.move(deltaX: 0, deltaY: 1, precise: false, shift: false)
        let toward = PilePointer.move(deltaX: 0, deltaY: -1, precise: false, shift: false)
        XCTAssertGreaterThan(away.magnification, 1)
        XCTAssertEqual(away.magnification * toward.magnification, 1, accuracy: 1e-9)
        XCTAssertEqual(away.rotation.radians, 0)
        // A trackpad's points zoom less each than a wheel's lines.
        let point = PilePointer.move(deltaX: 0, deltaY: 1, precise: true, shift: false)
        XCTAssertGreaterThan(point.magnification, 1)
        XCTAssertLessThan(point.magnification, away.magnification)
        // Sideways scrolling turns without zooming, so does Shift with a wheel, whether macOS
        // reports it as sideways scrolling or not, and the two turn alike.
        let sideways = PilePointer.move(deltaX: 2, deltaY: 0, precise: false, shift: false)
        XCTAssertNotEqual(sideways.rotation.radians, 0)
        let shifted = PilePointer.move(deltaX: 2, deltaY: 0, precise: false, shift: true)
        let unswapped = PilePointer.move(deltaX: 0, deltaY: 2, precise: false, shift: true)
        for move in [shifted, unswapped] {
            XCTAssertEqual(move.magnification, 1)
            XCTAssertEqual(move.rotation.radians, sideways.rotation.radians, accuracy: 1e-9)
        }
        // On the iPhone, where the tests run, a hold picks a book up rather than a drag.
        XCTAssertFalse(PileCarry.picksUpOnDrag)
    }

    func testThePointerFindsTheNearestBoxItsRayMeets() throws {
        // A book lying flat at the origin, 2 × 3 × 0.4 units, turned a quarter turn.
        let book = Transform(
            rotation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
                * simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]),
            translation: [0, 0.2, 0])
        let size = SIMD3<Float>(2, 3, 0.4)
        // Straight down onto its top cover, 0.4 units up.
        let down = try XCTUnwrap(
            PilePointer.hit(
                origin: [0, 10, 0], direction: [0, -1, 0], transform: book, size: size))
        XCTAssertEqual(down, 9.6, accuracy: 1e-4)
        // Its length runs along x after the turn, so a ray 1.4 units along x still meets it and
        // one 1.4 units along z misses.
        XCTAssertNotNil(
            PilePointer.hit(
                origin: [1.4, 10, 0], direction: [0, -1, 0], transform: book, size: size))
        XCTAssertNil(
            PilePointer.hit(
                origin: [0, 10, 1.4], direction: [0, -1, 0], transform: book, size: size))
        // A ray that starts past the box, pointing away, misses it.
        XCTAssertNil(
            PilePointer.hit(origin: [0, 10, 0], direction: [0, 1, 0], transform: book, size: size))
        // The camera's ray through the middle of the view meets a book at the table's middle.
        let camera = PileCamera()
        let ray = camera.ray(ndc: .zero, aspect: 0.5)
        XCTAssertNotNil(
            PilePointer.hit(
                origin: ray.origin, direction: ray.direction, transform: book, size: size))
    }

    func testTheGatherPullsTowardItsCenterHarderFromFartherAndDiesAway() {
        let middle = PileLayout.gatherTime / 2
        XCTAssertEqual(PileLayout.gatherPull(toward: .zero, after: middle), .zero)
        // At its peak, a book 4 units out or more feels the whole pull, and a nearer one less.
        assertNear(
            PileLayout.gatherPull(toward: [8, 0, 0], after: middle),
            [PileLayout.gatherStrength, 0, 0])
        assertNear(
            PileLayout.gatherPull(toward: [0, 0, -2], after: middle),
            [0, 0, -PileLayout.gatherStrength / 2])
        // The peak slides a book lying flat, which friction holds against 0.6 of gravity.
        XCTAssertGreaterThan(PileLayout.gatherStrength, 0.6 * PileLayout.gravity)
        XCTAssertLessThan(
            simd_length(PileLayout.gatherPull(toward: [8, 0, 0], after: 0.1)),
            PileLayout.gatherStrength / 4)
        XCTAssertEqual(
            PileLayout.gatherPull(toward: [8, 0, 0], after: PileLayout.gatherTime), .zero)
    }

    @MainActor func testThePeriodLabelGrowsWithTheViewsShorterSide() {
        // An iPhone keeps the base size, whichever way it is held.
        XCTAssertEqual(PileCalendar.scale(in: CGSize(width: 402, height: 874)), 1)
        XCTAssertEqual(PileCalendar.scale(in: CGSize(width: 874, height: 402)), 1)
        // The Mac's default window keeps it too; full screen on a 14-inch display grows the
        // label by three quarters, and larger views stop at twice the size.
        XCTAssertEqual(PileCalendar.scale(in: CGSize(width: 980, height: 820)), 1)
        XCTAssertEqual(
            PileCalendar.scale(in: CGSize(width: 1512, height: 982)), 1.75, accuracy: 0.001)
        XCTAssertEqual(PileCalendar.scale(in: CGSize(width: 3000, height: 1600)), 2)
    }
}
