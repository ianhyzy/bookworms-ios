import Foundation
import RealityKit
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
        // Every size `BookShape` makes for a 2:3 cover, from every page count and variety.
        var sizes = Set<SIMD3<Float>>()
        for pages in 100...1_400 {
            for x: Float in [0, 0.5, 1] {
                for y: Float in [0, 0.5, 1] {
                    let size = BookShape.size(pages: pages, coverAspect: 2 / 3, variety: [x, y])
                    sizes.insert(BookShape(size: size, binding: .paperback).size)
                }
            }
        }
        // From 1.7 tall to doorstoppers 2.8 tall and 0.52 thick.
        XCTAssertGreaterThan(sizes.count, 60)
        XCTAssertTrue(sizes.contains { $0.y > 2.79 && $0.z > 0.51 })
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

    func testChainRunsInFinishOrderWithCurrentReadsLast() {
        let books = [
            book(1, finished: "2025-03-10"), book(2, finished: nil),
            book(3, finished: "2025-01-05"), book(4, finished: "2025-03-10"),
            book(5, finished: "2025-05-01"),
        ]
        let chain = DominoLayout.chain(books)
        XCTAssertEqual(chain.map { $0.book.id }, [3, 1, 4, 5, 2])
        // No gap between finishes leads to a current read, so no cobweb hangs before one.
        XCTAssertEqual(chain.map { $0.days }, [64, 0, 52, 0, 0])
    }

    func testSameDayBooksKeepTheirOrderWhateverTheShelfSort() {
        let books = [
            book(7, finished: "2025-03-10"), book(2, finished: nil),
            book(5, finished: "2025-03-10"),
            book(9, finished: nil), book(1, finished: "2025-01-05"),
        ]
        let chain = DominoLayout.chain(books).map { $0.book.id }
        XCTAssertEqual(chain, [1, 5, 7, 2, 9])
        XCTAssertEqual(DominoLayout.chain(books.reversed()).map { $0.book.id }, chain)
    }

    func testLongChainsKeepTheMostRecentBooks() {
        let books = (0..<310).reversed().map { book($0, day: $0) }
        let chain = DominoLayout.chain(books)
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
        let chain = DominoLayout.chain(books)
        let plan = DominoLayout.plan(chain, aspect: 0.5)
        XCTAssertGreaterThan(plan.slots.last?.distance ?? 0, 3 * plan.path.period)
        // Each book's day counts the days of the gaps before it, some long enough for a web.
        XCTAssertEqual(
            zip(plan.slots, plan.slots.dropFirst()).map { $1.day - $0.day },
            chain.dropLast().map(\.days))
        XCTAssertTrue(chain.contains { $0.days >= DominoLayout.cobwebDays })
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
            let plan = DominoLayout.plan(DominoLayout.chain(books), aspect: 0.5)
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
            let plan = DominoLayout.plan(DominoLayout.chain(books), aspect: aspect)
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

    func testOutlineBoundsStandingAndFallenBooks() {
        // Enough books to fill a row and turn, where books fall off the path.
        let books = (0..<40).map { book($0, day: $0 * 3) }
        let plan = DominoLayout.plan(DominoLayout.chain(books), aspect: 0.5)
        XCTAssertTrue(plan.slots.contains { plan.path.isTurning(at: $0.distance) })
        let points = DominoLayout.outline(of: plan.slots)
        XCTAssertEqual(points.count, plan.slots.count * 6)
        for slot in plan.slots {
            // Both top corners across the path, at the book's height.
            let tops = points.filter {
                $0.y == slot.size.y
                    && abs(simd_distance(SIMD2($0.x, $0.z), slot.position) - slot.size.x / 2) < 1e-4
            }
            XCTAssertGreaterThanOrEqual(tops.count, 2)
            // Both corners of its head where it lands, its height past its leading bottom edge.
            let landings = points.filter { point in
                let offset = SIMD2(point.x, point.z) - slot.position
                return point.y == 0
                    && abs(simd_dot(offset, slot.heading) - slot.size.y - slot.size.z / 2) < 1e-4
                    && abs(
                        simd_length(offset - slot.heading * simd_dot(offset, slot.heading))
                            - slot.size.x / 2) < 1e-4
            }
            XCTAssertGreaterThanOrEqual(landings.count, 2, "\(slot.book.id)")
        }
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

    func testLiftedBooksStandAgainOnlyUnfallenAndInAFreePlace() {
        // A book's place in its own frame, its neighbors standing 0.6 units off its covers, and
        // the book before it fallen into its place.
        let place = BoundingBox(min: [-0.75, -1.1, -0.15], max: [0.75, 1.1, 0.15])
        let neighbors = [
            BoundingBox(min: [-0.75, -1.1, 0.75], max: [0.75, 1.3, 1.05]),
            BoundingBox(min: [-0.7, -1.1, -1.05], max: [0.7, 0.9, -0.75]),
        ]
        let fallen = BoundingBox(min: [-0.75, -1.1, -0.9], max: [0.75, -0.6, 1.0])
        func stands(_ index: Int, next: Int, _ others: [BoundingBox]) -> Bool {
            DominoLayout.standsAgain(index: index, next: next, place: place, others: others)
        }
        // At or past the front, between standing neighbors: whether or not a push started the
        // chain, and at the front of a chain that stopped short of it.
        XCTAssertTrue(stands(3, next: 3, neighbors))
        XCTAssertTrue(stands(5, next: 3, neighbors))
        XCTAssertTrue(stands(0, next: 0, []))
        // A book fallen into its place, or one leaning over it, sends it back thrown.
        XCTAssertFalse(stands(3, next: 3, neighbors + [fallen]))
        let leaning = BoundingBox(min: [-0.7, 0.5, -1.2], max: [0.7, 1.6, 0.9])
        XCTAssertFalse(stands(4, next: 3, [leaning]))
        // A book the chain had passed is thrown back, even into a free place.
        XCTAssertFalse(stands(2, next: 3, neighbors))
    }

    func testSetDownDropsAStandingBookIntoItsPlaceFromAbove() throws {
        let plan = DominoLayout.plan(
            DominoLayout.chain((0..<12).map { book($0, day: $0 * 3) }), aspect: 0.5)
        let slot = plan.slots[5]
        let place = DominoLayout.standingPose(of: slot)
        // Standing on its tail, a hair above the table.
        XCTAssertEqual(place.translation.y - slot.size.y / 2, 0.002, accuracy: 1e-5)
        XCTAssertEqual(place.rotation.act([0, 1, 0]).y, 1, accuracy: 1e-5)
        // From a details pose high in front of the camera, turned to face it, back to a place
        // it rose 2.6 units from, clear of its neighbors.
        let rise: Float = 2.6
        let start = Transform(
            rotation: simd_quatf(angle: 2, axis: simd_normalize([0.2, 1, 0.4])),
            translation: place.translation + [6, 17, 10])
        func pose(_ progress: Float) -> Transform {
            BookFlight.setDown(from: start, to: place, rise: rise, progress: progress)
        }
        XCTAssertEqual(simd_distance(pose(0).translation, start.translation), 0, accuracy: 1e-4)
        XCTAssertEqual(simd_distance(pose(1).translation, place.translation), 0, accuracy: 1e-4)
        XCTAssertEqual(
            abs(simd_dot(pose(1).rotation.vector, place.rotation.vector)), 1, accuracy: 1e-4)
        // It eases out of the details rather than leaping away, so it stays in view.
        let way = simd_distance(start.translation, place.translation)
        XCTAssertLessThan(simd_distance(pose(0.02).translation, start.translation), way * 0.01)
        // It comes no lower than the top of its rise until it is over its place, then drops
        // straight in, standing, so it never sweeps through the books beside its place.
        for step in 0...100 {
            let progress = Float(step) / 100
            let translation = pose(progress).translation
            let across = simd_length(SIMD2(translation.x, translation.z) - slot.position)
            if across > 1e-3 {
                XCTAssertGreaterThanOrEqual(
                    translation.y, place.translation.y + rise - 1e-3, "\(step)")
            } else {
                XCTAssertEqual(
                    abs(simd_dot(pose(progress).rotation.vector, place.rotation.vector)), 1,
                    accuracy: 1e-4, "\(step)")
            }
        }
        // It arrives at rest, so it lands without a bounce.
        XCTAssertLessThan(simd_distance(pose(0.99).translation, place.translation), 0.01)
    }

    func testBooksDropFromJustAboveTheView() throws {
        let half = PileCamera.fieldOfView / 2
        let cameras = [
            PileCamera(target: [1, 0, -2], yaw: 0.4, zoom: 0.3),
            PileCamera(yaw: DominoCameraRig.finaleYaw, pitch: DominoCameraRig.finalePitch),
        ]
        for camera in cameras {
            let shown = camera.transform
            for point: SIMD2<Float> in [[0, 0], [-6, 4], [5, -7]] {
                let height = try XCTUnwrap(
                    PileCamera.heightAboveView(of: point, radius: 1.5, seenFrom: shown))
                // The ball's middle lies its radius above the plane through the camera and the
                // view's top edge, which tips back from the camera's up axis by half the view.
                let local = shown.rotation.inverse.act(
                    [point.x, height, point.y] - shown.translation)
                XCTAssertEqual(local.y * cos(half) + local.z * sin(half), 1.5, accuracy: 0.001)
            }
        }
        // A view whose top edge looks level or up shows every height.
        XCTAssertNil(
            PileCamera.heightAboveView(
                of: .zero, radius: 1, seenFrom: PileCamera(pitch: half).transform))
    }

    func testEveryDropStartsWithinTheSpread() {
        for count in [1, 2, 16, 39, 300] {
            let step = DominoLayout.entryStep(count: count)
            XCTAssertLessThanOrEqual(step, 0.05)
            XCTAssertLessThanOrEqual(
                step * Double(count - 1), DominoLayout.entrySpread + 0.0001, "\(count)")
        }
        XCTAssertEqual(DominoLayout.entryStep(count: 16), 0.05)
        // The whole entrance, with the last cobweb's fade, stays under two seconds.
        XCTAssertLessThan(
            DominoLayout.entrySpread + DominoLayout.entryFall + DominoLayout.webFade, 2)
    }

    func testASlowBatchSpreadsItsDropsOverItsBuild() {
        // Built at once, a batch keeps the chain's step.
        XCTAssertEqual(
            DominoLayout.entryStep(count: 276, batch: 16, interval: 0),
            DominoLayout.entryStep(count: 276))
        XCTAssertEqual(DominoLayout.entryStep(count: 39, batch: 16, interval: 0.1), 1.2 / 38)
        // Built in 0.48 seconds, its 16 drops share that time.
        XCTAssertEqual(
            DominoLayout.entryStep(count: 276, batch: 16, interval: 0.48), 0.03, accuracy: 1e-9)
        // A slower build spreads them at most 50 milliseconds apart.
        XCTAssertEqual(DominoLayout.entryStep(count: 276, batch: 16, interval: 1.1), 0.05)
        XCTAssertEqual(DominoLayout.entryStep(count: 276, batch: 0, interval: 1), 0.05)
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
