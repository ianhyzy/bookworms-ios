import Foundation
import XCTest
import simd

@testable import Bookworms

/// The dominoes' layout: finish order, the spacing rule, the winding path, and its fit.
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

    func testBingesStayWithinReachAndSlumpsLeaveAGapTooWide() {
        for height: Float in [2.1, 2.4] {
            XCTAssertEqual(DominoLayout.gap(days: 0, height: height), height * 0.15, accuracy: 1e-4)
            var previous: Float = 0
            for days in 0..<DominoLayout.slumpDays {
                let gap = DominoLayout.gap(days: days, height: height)
                XCTAssertGreaterThan(gap, previous)
                // The falling book's head strikes the next book high up.
                XCTAssertLessThan(gap, height * 0.55)
                previous = gap
            }
            // A slump lies beyond the falling book's reach, its height, by a quarter book or more.
            XCTAssertEqual(DominoLayout.gap(days: 30, height: height), height * 1.25, accuracy: 1e-4)
            XCTAssertEqual(DominoLayout.gap(days: 60, height: height), height * 1.5, accuracy: 1e-4)
            XCTAssertEqual(DominoLayout.gap(days: 900, height: height), height * 1.75, accuracy: 1e-4)
        }
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

    func testSlumpsAreOutOfReachAndOtherGapsWithinIt() {
        // Gaps of 0 to 100 days, and thick and thin books, around several turns.
        var day = 0
        let books = (0..<80).map { index in
            defer { day += (index * 37) % 101 }
            return book(index, day: day, pages: 60 + index * 17)
        }
        let plan = DominoLayout.plan(DominoLayout.chain(books, now: .now), aspect: 0.5)
        XCTAssertGreaterThan(plan.slots.last?.distance ?? 0, 3 * plan.path.period)
        for (slot, next) in zip(plan.slots, plan.slots.dropFirst()) {
            let gap = next.distance - slot.distance - (slot.size.z + next.size.z) / 2
            if slot.days >= DominoLayout.slumpDays {
                XCTAssertGreaterThan(gap, slot.size.y * 1.2)
            } else {
                XCTAssertLessThan(gap, slot.size.y * 0.6)
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
        // The most books, every one thick and a long slump after the one before.
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
