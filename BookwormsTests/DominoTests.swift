import Foundation
import XCTest
import simd

@testable import Bookworms

/// The dominoes' layout: finish order, the spacing rule, the winding path, its fit, and the
/// cobwebs over long gaps.
final class DominoTests: XCTestCase {
    private static let day = 86_400.0
    private static let start = Date(timeIntervalSince1970: 1_577_880_000)  // 2020-01-01 12:00 UTC

    private func book(_ id: Int, finished: String?, pages: Int = 320) -> CloudBook {
        var book = CloudBook(
            id: id, title: "Fictional Book \(id)", author: "An Author", coverURL: nil,
            detailCoverURL: nil)
        book.finished = finished
        book.pages = pages
        return book
    }

    /// A book finished `days` after the first day of 2020.
    private func book(_ id: Int, day days: Int, pages: Int = 320) -> CloudBook {
        let date = Self.start.addingTimeInterval(Double(days) * Self.day)
        return book(id, finished: date.formatted(.iso8601.year().month().day()), pages: pages)
    }

    func testEveryGapStaysWithinReachForAnyPairOfSizes() {
        // Every height and thickness `BookShape` makes, at least 6 times as long as thick.
        let heights = stride(from: Float(1.7), through: BookShape.longest, by: 0.1)
        let sizes = heights.flatMap { height in
            stride(from: Float(0.04), through: min(0.4, height / 6), by: 0.04)
                .map { SIMD3<Float>(height * 2 / 3, height, $0) }
        }
        for a in sizes {
            // Wider than the 15 percent that the closest books once stood apart.
            XCTAssertEqual(DominoLayout.gap(height: a.y), a.y * 0.3, accuracy: 1e-5)
            for b in sizes {
                // On a row, or on a turn, where books may stand farther apart.
                let turn = DominoLayout.turnSpacing(a, b) - (a.z + b.z) / 2
                for gap in [DominoLayout.gap(height: a.y), turn] {
                    XCTAssertLessThan(gap, a.y * 0.4, "\(a) before \(b)")
                    // The falling book's head, or its back cover at the next book's top edge,
                    // strikes the next book at least half way up.
                    let strike = min(b.y, (a.y * a.y - gap * gap).squareRoot())
                    XCTAssertGreaterThan(strike, b.y * 0.55, "\(a) before \(b)")
                }
            }
        }
    }

    func testCobwebsMarkOnlyLongGapsAndGrowDenserWithThem() throws {
        XCTAssertNil(DominoLayout.cobweb(days: 0))
        XCTAssertNil(DominoLayout.cobweb(days: DominoLayout.cobwebDays - 1))
        XCTAssertEqual(try XCTUnwrap(DominoLayout.cobweb(days: 30)), 0, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(DominoLayout.cobweb(days: 60)), 1 / 3, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(DominoLayout.cobweb(days: 240)), 1, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(DominoLayout.cobweb(days: 900)), 1, accuracy: 1e-5)
        let near: [SIMD3<Float>] = [[0, 2, -0.5], [0, 2, 0.5]]
        let far: [SIMD3<Float>] = [[0.6, 1.8, -0.5], [0.6, 1.8, 0.5]]
        func threads(_ web: Cobweb) -> [SIMD3<Float>] {
            web.pieces.flatMap { piece in piece.threads.map { $0 + piece.pivot } }
        }
        let sparse = Cobweb(near: near, far: far, density: 0, seed: 7)
        let dense = Cobweb(near: near, far: far, density: 1, seed: 7)
        XCTAssertGreaterThan(threads(dense).count, threads(sparse).count)
        XCTAssertGreaterThan(dense.pieces.count, sparse.pieces.count)
        // The same seed strings the same web.
        XCTAssertEqual(threads(Cobweb(near: near, far: far, density: 0, seed: 7)), threads(sparse))
        XCTAssertNotEqual(
            threads(Cobweb(near: near, far: far, density: 0, seed: 8)), threads(sparse))
        // Every thread hangs within the gap, under the higher edge, and above the sag's limit.
        for point in threads(dense) {
            XCTAssertGreaterThanOrEqual(point.x, -1e-4)
            XCTAssertLessThanOrEqual(point.x, 0.6 + 1e-4)
            XCTAssertLessThanOrEqual(abs(point.z), 0.5 + 1e-4)
            XCTAssertLessThanOrEqual(point.y, 2 + 1e-4)
            XCTAssertGreaterThan(point.y, 1.8 - 0.6 * 0.35 - 1e-4)
        }
        let ribbons = Cobweb.ribbons(try XCTUnwrap(dense.pieces.first).threads, width: 0.01)
        XCTAssertGreaterThan(ribbons.positions.count, 0)
    }

    func testDominoMassFollowsOnlyHeight() {
        XCTAssertEqual(DominoLayout.mass(height: 1.7), 0.34, accuracy: 1e-4)
        XCTAssertEqual(DominoLayout.mass(height: 2.8), 0.56, accuracy: 1e-4)
        // The lightest and heaviest books differ by less than a factor of 2, so a light book
        // knocks a heavy one over instead of bouncing off it.
        XCTAssertLessThan(
            DominoLayout.mass(height: BookShape.longest) / DominoLayout.mass(height: 1.7), 2)
    }

    func testChainRunsInFinishOrderWithCurrentReadsLast() throws {
        let books = [
            book(1, finished: "2025-03-10"), book(2, finished: nil),
            book(3, finished: "2025-01-05"), book(4, finished: "2025-03-10"),
            book(5, finished: "2025-05-01"),
        ]
        let now = try Date("2025-07-01T12:00:00Z", strategy: .iso8601)
        let chain = DominoLayout.chain(books, now: now)
        XCTAssertEqual(chain.map { $0.book.id }, [3, 1, 4, 5, 2])
        XCTAssertEqual(chain.map { $0.days }, [64, 0, 52, 61, 0])
    }

    func testSameDayBooksKeepTheirOrderWhateverTheShelfSort() {
        let books = [
            book(7, finished: "2025-03-10"), book(2, finished: nil),
            book(5, finished: "2025-03-10"),
            book(9, finished: nil), book(1, finished: "2025-01-05"),
        ]
        let now = Date.now
        let chain = DominoLayout.chain(books, now: now).map { $0.book.id }
        XCTAssertEqual(chain, [1, 5, 7, 2, 9])
        XCTAssertEqual(DominoLayout.chain(books.reversed(), now: now).map { $0.book.id }, chain)
    }

    func testLongChainsKeepTheMostRecentBooks() {
        let books = (0..<310).reversed().map { book($0, day: $0) }
        let chain = DominoLayout.chain(books, now: .now)
        XCTAssertEqual(chain.count, DominoLayout.maximumBooks)
        XCTAssertEqual(chain.first?.book.id, 10)
        XCTAssertEqual(chain.last?.book.id, 309)
    }

    func testPathWindsInRowsJoinedByHalfTurns() {
        let path = DominoPath(rowLength: 8)
        var previous = path.point(at: 0)
        XCTAssertEqual(previous.position, [-4, 0])
        XCTAssertEqual(previous.heading, [1, 0])
        for step in 1...400 {
            let point = path.point(at: Float(step) * 0.1)
            XCTAssertEqual(simd_distance(point.position, previous.position), 0.1, accuracy: 0.002)
            XCTAssertEqual(simd_length(point.heading), 1, accuracy: 1e-4)
            previous = point
        }
        // The second row runs back, one row nearer the camera.
        let back = path.point(at: path.period + 1)
        XCTAssertEqual(back.position.x, 3, accuracy: 1e-4)
        XCTAssertEqual(back.position.y, 2 * DominoLayout.turnRadius, accuracy: 1e-4)
        XCTAssertEqual(back.heading.x, -1, accuracy: 1e-4)
        XCTAssertTrue(path.isTurning(at: 9))
        XCTAssertFalse(path.isTurning(at: path.period + 1))
    }

    func testTimeDoesNotSpaceTheChain() {
        // Gaps of 0 to 100 days, and thick and thin books, around several turns.
        var day = 0
        let books = (0..<80)
            .map { index in
                defer { day += (index * 37) % 101 }
                return book(index, day: day, pages: 60 + index * 17)
            }
        let plan = DominoLayout.plan(DominoLayout.chain(books, now: .now), aspect: 0.5)
        XCTAssertGreaterThan(plan.slots.last?.distance ?? 0, 3 * plan.path.period)
        XCTAssertTrue(plan.slots.contains { $0.days >= DominoLayout.cobwebDays })
        for (slot, next) in zip(plan.slots, plan.slots.dropFirst()) {
            let gap = next.distance - slot.distance - (slot.size.z + next.size.z) / 2
            if plan.path.isTurning(at: slot.distance) || plan.path.isTurning(at: next.distance) {
                XCTAssertGreaterThanOrEqual(gap, DominoLayout.gap(height: slot.size.y) - 1e-4)
                XCTAssertLessThan(gap, slot.size.y * 0.4)
            } else {
                XCTAssertEqual(gap, DominoLayout.gap(height: slot.size.y), accuracy: 1e-3)
            }
        }
    }

    func testStandingBooksNeverTouchOnTheTurns() {
        // Books finished on the same day stand closest; thick ones fan out the most on a turn.
        for pages in [60, 1400] {
            let books = (0..<120).map { book($0, day: 0, pages: pages) }
            let plan = DominoLayout.plan(DominoLayout.chain(books, now: .now), aspect: 0.5)
            XCTAssertTrue(plan.slots.contains { plan.path.isTurning(at: $0.distance) })
            for (slot, next) in zip(plan.slots, plan.slots.dropFirst()) {
                XCTAssertFalse(overlap(slot, next), "\(slot.book.id) touches \(next.book.id)")
            }
        }
    }

    func testTheLongestChainFitsTheTable() {
        // The most books, every one as thick and as long as books get.
        let books = (0..<DominoLayout.maximumBooks).map { book($0, day: $0 * 200, pages: 1400) }
        for aspect: Float in [0.3, 0.5, 1] {
            let plan = DominoLayout.plan(DominoLayout.chain(books, now: .now), aspect: aspect)
            XCTAssertEqual(plan.slots.count, DominoLayout.maximumBooks)
            for slot in plan.slots {
                // A fallen book reaches its height past where it stood.
                XCTAssertLessThan(abs(slot.position.x) + slot.size.y, 45)
                XCTAssertLessThan(abs(slot.position.y) + slot.size.y, 45)
            }
        }
    }

    func testStandingBooksFaceBackAlongThePath() {
        let heading = simd_normalize(SIMD2<Float>(1, 1))
        let rotation = DominoLayout.standing(heading: heading)
        XCTAssertEqual(rotation.act([0, 1, 0]).y, 1, accuracy: 1e-5)
        let front = rotation.act([0, 0, 1])
        XCTAssertEqual(front.x, -heading.x, accuracy: 1e-5)
        XCTAssertEqual(front.z, -heading.y, accuracy: 1e-5)
    }

    func testOutlineBoundsStandingAndFallenBooks() throws {
        let books = (0..<12).map { book($0, day: $0 * 3) }
        let slots = DominoLayout.plan(DominoLayout.chain(books, now: .now), aspect: 0.5).slots
        let points = DominoLayout.outline(of: slots)
        XCTAssertEqual(points.count, slots.count * 4 + 1)
        for slot in slots {
            // Both top corners across the path, at the book's height.
            let tops = points.filter {
                $0.y == slot.size.y
                    && abs(simd_distance(SIMD2($0.x, $0.z), slot.position) - slot.size.x / 2) < 1e-4
            }
            XCTAssertGreaterThanOrEqual(tops.count, 2)
        }
        // The last book lands its height past its leading bottom edge.
        let last = try XCTUnwrap(slots.last)
        let landing = try XCTUnwrap(points.last)
        XCTAssertEqual(landing.y, 0)
        XCTAssertEqual(
            simd_dot(SIMD2(landing.x, landing.z) - last.position, last.heading),
            last.size.y + last.size.z / 2, accuracy: 1e-4)
    }

    func testPushesTipTheFirstUprightBook() {
        let upright = [false, false, true, true]
        XCTAssertEqual(DominoLayout.pushTarget(next: 0, count: 4) { upright[$0] }, 2)
        XCTAssertEqual(DominoLayout.pushTarget(next: 2, count: 4) { upright[$0] }, 2)
        // It looks at most two books past the next one, and never past the last book.
        XCTAssertEqual(DominoLayout.pushTarget(next: 0, count: 4) { _ in false }, 2)
        XCTAssertEqual(DominoLayout.pushTarget(next: 3, count: 4) { _ in false }, 3)
    }

    func testPhaseFollowsTheFront() {
        func phase(next: Int, count: Int = 3, started: Bool, settled: Bool) -> DominoPhase {
            DominoLayout.phase(next: next, count: count, started: started, settled: settled)
        }
        XCTAssertEqual(phase(next: 0, started: false, settled: true), .standing)
        XCTAssertEqual(phase(next: 1, started: true, settled: false), .running)
        XCTAssertEqual(phase(next: 2, started: true, settled: true), .stalled(fallen: 2))
        XCTAssertEqual(phase(next: 3, started: true, settled: false), .running)
        XCTAssertEqual(phase(next: 3, started: true, settled: true), .done)
        // A chain that fell without a push, or has no books, never waits for one.
        XCTAssertEqual(phase(next: 3, started: false, settled: false), .running)
        XCTAssertEqual(phase(next: 3, started: false, settled: true), .done)
        XCTAssertEqual(phase(next: 0, count: 0, started: false, settled: true), .done)
        XCTAssertFalse(phase(next: 0, count: 0, started: false, settled: false).waitsForPush)
        XCTAssertTrue(DominoPhase.stalled(fallen: 1).waitsForPush)
    }

    func testThreeDOffersDominoes() {
        XCTAssertEqual(ThreeDView.dominoes.title, "Dominoes")
        XCTAssertEqual(ThreeDView(rawValue: "dominoes"), .dominoes)
    }

    /// Whether two standing books' footprints overlap, taking each as wide as its height allows,
    /// by the separating axis test.
    private func overlap(_ a: DominoSlot, _ b: DominoSlot) -> Bool {
        func corners(_ slot: DominoSlot) -> [SIMD2<Float>] {
            let along = slot.heading * slot.size.z / 2
            let across =
                SIMD2(-slot.heading.y, slot.heading.x) * DominoLayout.widest(slot.size.y) / 2
            let middle = slot.position
            return [
                middle + along + across, middle + along - across, middle - along - across,
                middle - along + across,
            ]
        }
        let first = corners(a)
        let second = corners(b)
        for slot in [a, b] {
            for axis in [slot.heading, SIMD2(-slot.heading.y, slot.heading.x)] {
                let one = first.map { simd_dot($0, axis) }
                let two = second.map { simd_dot($0, axis) }
                if one.max()! < two.min()! || two.max()! < one.min()! { return false }
            }
        }
        return true
    }
}
