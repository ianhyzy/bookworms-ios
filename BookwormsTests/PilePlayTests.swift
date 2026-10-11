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
        // The tray lies inside the box on the table.
        let tray = try XCTUnwrap(PileTray(aspect: aspect, safeTop: top, safeBottom: bottom))
        for corner in tray.scaled(by: 0.95).corners {
            XCTAssertTrue(box.contains(corner + [0, 0.1, 0], margin: 0))
        }
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
        XCTAssertNil(years.last?.season)
        XCTAssertEqual(years.map(\.season), [0.25, 0.75, nil])
    }

    func testLampWarmsFromWinterBlueThroughSummerGoldToAutumnAmber() {
        let months = (1...12).map { PileSeasons.lampColor(season: (Float($0) - 0.5) / 12) }
        assertNear(months[0], PileSeasons.winter)
        assertNear(months[3], simd_mix(PileSeasons.winter, PileSeasons.summer, [0.5, 0.5, 0.5]))
        assertNear(months[6], PileSeasons.summer)
        assertNear(months[9], PileSeasons.autumn)
        assertNear(months[11], PileSeasons.autumn)
        assertNear(PileSeasons.lampColor(season: 0), PileSeasons.winter)
        // Blue fades month by month; January is blue and July gold.
        for (earlier, later) in zip(months, months.dropFirst()) {
            XCTAssertGreaterThanOrEqual(earlier.z, later.z)
        }
        XCTAssertGreaterThan(months[0].z, months[0].x)
        XCTAssertGreaterThan(months[6].x, months[6].z)

        XCTAssertEqual(PileSeasons.season(of: .month(1), index: 0, count: 12), 0.5 / 12)
        XCTAssertEqual(
            PileSeasons.season(of: .days(8...14, month: 8), index: 1, count: 5),
            (7 + 22.0 / 62) / 12, accuracy: 0.0001)
        XCTAssertEqual(PileSeasons.season(of: .year(2020), index: 3, count: 4), 0.875)
    }
}
