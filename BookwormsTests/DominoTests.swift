import Foundation
import RealityKit
import SwiftUI
import XCTest
import simd

@testable import Bookworms

/// The dominoes' layout: finish order, the spacing rule, the winding path, its fit, the worm's
/// rows, the cobwebs over long gaps, the finale's gathering, and the video's length.
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

    func testTheChainSpeedsUpTheLongerItFalls() {
        let speeds = stride(from: 0, through: 500, by: 5)
            .map { DominoLayout.speedUp(at: Float($0)) }
        XCTAssertEqual(speeds.first, 1)
        XCTAssertEqual(speeds, speeds.sorted())
        XCTAssertLessThan(speeds.last!, DominoLayout.fastest)
        // A year's chain, about 35 units, ends a little faster; a chain of 150 units or more
        // nearly at real time, and never faster.
        XCTAssertEqual(DominoLayout.speedUp(at: 35), 1.11, accuracy: 0.01)
        XCTAssertEqual(DominoLayout.speedUp(at: 150), 1.23, accuracy: 0.01)
        // Real time is 1 / `DominoScene.slowMotion`, 0.8, of the slow motion.
        XCTAssertEqual(DominoLayout.fastest, 1 / 0.8, accuracy: 1e-6)
        // The run's time at the typical pace is the integral of one over the sped-up pace.
        var time: Float = 0
        for step in 0..<4_100 {
            time += 0.1 / DominoCameraRig.pace(at: (Float(step) + 0.5) * 0.1)
            guard step % 500 == 499 else { continue }
            XCTAssertEqual(
                DominoCameraRig.fallTime(to: Float(step + 1) * 0.1), time, accuracy: 1e-3 * time)
        }
        XCTAssertEqual(DominoCameraRig.fallTime(to: 0), 0, accuracy: 1e-6)
    }

    func testABlendTurnsOntoTheNextShotsSubjectFirst() {
        // From a high overview to a low view of the front far across the table.
        let overview = PileCamera(target: [0, 0, 0], zoom: 0.5).transform
        let low = DominoCameraPose(eye: [24, 3, 10], target: [16, 1, 2], roll: 0.04)
        let follow = Transform(rotation: low.rotation, translation: low.eye)
        // Where the low view's axis meets the table: the point it looks at.
        let forward = follow.rotation.act([0, 0, -1])
        let subject = follow.translation + forward * (-follow.translation.y / forward.y)
        func blended(_ progress: Float) -> Transform {
            DominoScene.blended(overview, to: follow, progress: progress)
        }
        XCTAssertEqual(
            simd_distance(blended(0).translation, overview.translation), 0, accuracy: 1e-4)
        XCTAssertEqual(
            abs(simd_dot(blended(0).rotation.vector, overview.rotation.vector)), 1, accuracy: 1e-4)
        XCTAssertEqual(simd_distance(blended(1).translation, follow.translation), 0, accuracy: 1e-4)
        XCTAssertEqual(
            abs(simd_dot(blended(1).rotation.vector, follow.rotation.vector)), 1, accuracy: 1e-4)
        // From 60 percent of the way, the view looks straight at the next shot's subject as it
        // travels on.
        for progress: Float in [0.6, 0.7, 0.8, 0.9] {
            let view = blended(progress)
            let local = view.rotation.inverse.act(subject - view.translation)
            XCTAssertLessThan(simd_length(SIMD2(local.x, local.y)) / -local.z, 1e-3, "\(progress)")
        }
    }

    func testABlendToAWiderViewKeepsTheFrontInView() {
        // From a low view of the falling front to a high view of the whole chain, which shows
        // the front off its middle.
        let front: SIMD3<Float> = [0, 1.1, 0]
        let low = DominoCameraPose(eye: [-8, 3.5, 8], target: front, roll: 0.03)
        let follow = Transform(rotation: low.rotation, translation: low.eye)
        let high = DominoCameraPose(eye: [16, 38, 29], target: [6, 0, 4])
        let overview = Transform(rotation: high.rotation, translation: high.eye)
        let aspect: Float = 0.46
        func shown(_ progress: Float) -> SIMD2<Float> {
            let view = DominoScene.blended(
                follow, to: overview, progress: progress, keeping: front, aspect: aspect)
            let local = view.rotation.inverse.act(front - view.translation)
            return SIMD2(local.x / aspect, local.y) / (-local.z * tan(PileCamera.fieldOfView / 2))
        }
        let start = shown(0)
        let end = shown(1)
        XCTAssertLessThan(simd_length(start), 0.05)
        XCTAssertLessThan(max(abs(end.x), abs(end.y)), 1)
        // The front moves straight across the screen from one place to the other, so it never
        // leaves the view.
        var last: Float = 0
        for step in 1...20 {
            let place = shown(Float(step) / 20)
            let along = simd_dot(place - start, end - start) / simd_length_squared(end - start)
            XCTAssertGreaterThanOrEqual(along, last - 1e-3, "\(step)")
            XCTAssertLessThanOrEqual(along, 1 + 1e-3, "\(step)")
            let across = simd_length(place - start - (end - start) * along)
            XCTAssertLessThan(across, 0.05, "\(step)")
            last = along
        }
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

    func testSetDownPutsABookBackExactlyWhereItLay() {
        // A fallen book, tilted where it lies on the next, or one lying in the gathered spread.
        let tilted = Transform(
            rotation: simd_quatf(angle: 1.2, axis: simd_normalize([0.3, 0, 1]))
                * PileLayout.lyingFlat, translation: [2, 0.6, -1])
        let start = Transform(
            rotation: simd_quatf(angle: 2, axis: simd_normalize([0.2, 1, 0.4])),
            translation: [8, 17, 10])
        let flat = Transform(rotation: PileSpread.upright, translation: [0, 0.15, 3])
        for (place, rise) in [(tilted, Float(1.2)), (flat, 0.4)] {
            func pose(_ progress: Float) -> Transform {
                BookFlight.setDown(from: start, to: place, rise: rise, progress: progress)
            }
            XCTAssertLessThan(simd_distance(pose(1).translation, place.translation), 1e-4)
            XCTAssertEqual(
                abs(simd_dot(pose(1).rotation.vector, place.rotation.vector)), 1, accuracy: 1e-4)
            // The last of the way drops straight down into the place, already turned to it.
            for step in 0...10 {
                let progress = BookFlight.crossing + (1 - BookFlight.crossing) * Float(step) / 10
                let shown = pose(progress)
                XCTAssertEqual(shown.translation.x, place.translation.x, accuracy: 1e-4)
                XCTAssertEqual(shown.translation.z, place.translation.z, accuracy: 1e-4)
                XCTAssertGreaterThanOrEqual(shown.translation.y, place.translation.y - 1e-4)
                XCTAssertEqual(
                    abs(simd_dot(shown.rotation.vector, place.rotation.vector)), 1,
                    accuracy: 1e-4)
            }
        }
    }

    func testBooksDropFromJustAboveTheView() throws {
        let half = PileCamera.fieldOfView / 2
        let cameras = [
            PileCamera(target: [1, 0, -2], yaw: 0.4, zoom: 0.3),
            PileCamera(yaw: DominoCameraRig.openingYaw, pitch: DominoCameraRig.openingPitch),
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

    func testDropsKeepALittleBehindTheBuild() {
        // Built at once, the chain keeps its step, so every drop starts within the spread.
        XCTAssertEqual(
            DominoLayout.entryStep(count: 276, perBook: 0), DominoLayout.entryStep(count: 276))
        XCTAssertEqual(DominoLayout.entryStep(count: 39, perBook: 0.01), 1.2 / 38)
        // Books that take 50 milliseconds each to build drop a little more slowly, so the books
        // waiting to drop build up while later ones build.
        XCTAssertEqual(DominoLayout.entryStep(count: 276, perBook: 0.05), 0.0575, accuracy: 1e-9)
        // However slowly they build, the drops keep behind them, so they never run out of
        // built books and pause.
        XCTAssertEqual(DominoLayout.entryStep(count: 276, perBook: 0.2), 0.23, accuracy: 1e-9)
    }

    func testDropsSpeedUpAsTheSetupGoesOn() {
        for count in [2, 16, 39, 267] {
            let gaps = (0..<count - 1).map { DominoLayout.entryGap(after: $0, of: count, step: 1) }
            // The gaps add up to the setup's time at its average pace.
            XCTAssertEqual(gaps.reduce(0, +), Double(count - 1), accuracy: 1e-9, "\(count)")
            // Each gap is shorter than the one before.
            for (earlier, later) in zip(gaps, gaps.dropFirst()) {
                XCTAssertLessThan(later, earlier, "\(count)")
            }
        }
        let gaps = (0..<266).map { DominoLayout.entryGap(after: $0, of: 267, step: 1) }
        // The last books come about three times as fast as the first.
        XCTAssertEqual(gaps[0] / gaps[265], DominoLayout.entryQuickening, accuracy: 0.05)
        XCTAssertEqual(gaps[0], 1.82, accuracy: 0.01)
        XCTAssertEqual(gaps[265], 0.61, accuracy: 0.01)
        XCTAssertEqual(DominoLayout.entryShare(0, of: 267), 0)
        XCTAssertEqual(DominoLayout.entryShare(266, of: 267), 1, accuracy: 1e-12)
        XCTAssertEqual(DominoLayout.entryGap(after: -1, of: 267, step: 1), 0)
        // Starting slower than the books build, the drops stay behind a build that keeps its
        // pace: each book starts no sooner than at the steady pace.
        for index in 0..<267 {
            XCTAssertGreaterThanOrEqual(
                DominoLayout.entryShare(index, of: 267), Double(index) / 266 - 1e-12)
        }
    }

    // MARK: Worm path

    func testAPathOfOneLengthWindsOnWithoutEnd() {
        let path = DominoPath(rowLength: 8)
        XCTAssertEqual(path.rowLength(0), 8)
        XCTAssertEqual(path.rowLength(7), 8)
        XCTAssertEqual(path.period(3), 8 + .pi * DominoLayout.turnRadius, accuracy: 1e-5)
        XCTAssertEqual(path.start(ofRow: 3), 3 * path.period, accuracy: 1e-4)
        let (row, along) = path.row(at: 2 * path.period + 5)
        XCTAssertEqual(row, 2)
        XCTAssertEqual(along, 5, accuracy: 1e-4)
        // The eighth row starts where the seventh turn ends, back at the first row's start.
        XCTAssertEqual(path.point(at: path.start(ofRow: 8)).position.x, -4, accuracy: 1e-4)
    }

    func testRowsOfTheirOwnLengthsJoinThroughTheTurns() {
        let path = DominoPath(rowLengths: [4, 10, 6])
        var previous = path.point(at: 0)
        XCTAssertEqual(previous.position, [-2, 0])
        for step in 1...600 {
            let point = path.point(at: Float(step) * 0.1)
            XCTAssertEqual(simd_distance(point.position, previous.position), 0.1, accuracy: 0.002)
            XCTAssertEqual(simd_length(point.heading), 1, accuracy: 1e-4)
            previous = point
        }
        // The second row runs back from the first row's end for its own length, and the third
        // on from there.
        XCTAssertEqual(path.point(at: path.start(ofRow: 1)).position.x, 2, accuracy: 1e-4)
        XCTAssertEqual(
            path.point(at: path.start(ofRow: 1) + 10).position.x, -8, accuracy: 1e-4)
        XCTAssertEqual(path.point(at: path.start(ofRow: 2)).position.x, -8, accuracy: 1e-4)
        XCTAssertEqual(path.point(at: path.start(ofRow: 2)).position.y, 8, accuracy: 1e-4)
        // Past the given rows, each is as long as the last and alternates between its ends.
        XCTAssertEqual(path.rowLength(5), 6)
        XCTAssertEqual(path.point(at: path.start(ofRow: 3)).position.x, -2, accuracy: 1e-4)
        XCTAssertEqual(path.point(at: path.start(ofRow: 4)).position.x, -8, accuracy: 1e-4)
        XCTAssertTrue(path.isTurning(at: path.start(ofRow: 1) + 10.5))
        XCTAssertFalse(path.isTurning(at: path.start(ofRow: 2) + 1))
    }

    func testShortChainsWindInEvenRowsAndLongOnesFillTheWorm() throws {
        XCTAssertNil(DominoLayout.wormRowLengths(for: 35))
        let rows = try XCTUnwrap(DominoLayout.wormRowLengths(for: 270))
        XCTAssertGreaterThanOrEqual(rows.count, DominoLayout.wormRows)
        // The rows and their turns just hold the chain.
        let total = rows.reduce(0, +) + Float(rows.count - 1) * .pi * DominoLayout.turnRadius
        XCTAssertGreaterThanOrEqual(total, 270)
        XCTAssertLessThan(total, 270 + rows.last! + .pi * DominoLayout.turnRadius)
        // The head rounds: the first rows grow, then the body narrows a little to the bottom.
        XCTAssertLessThan(rows[0], rows[1])
        XCTAssertLessThan(rows[1], rows[2])
        let widest = rows.max()!
        XCTAssertGreaterThan(rows.last!, widest * 0.8)
        XCTAssertLessThan(rows.last!, widest)
        // The plan takes the worm for a long chain, and even rows for a short one.
        let long = DominoLayout.plan(
            DominoLayout.chain((0..<280).map { book($0, day: $0 * 3) }), aspect: 0.5)
        XCTAssertGreaterThan(long.path.rowLengths.count, DominoLayout.wormRows)
        let short = DominoLayout.plan(
            DominoLayout.chain((0..<30).map { book($0, day: $0 * 3) }), aspect: 0.5)
        XCTAssertEqual(short.path.rowLengths.count, 1)
        // Every book keeps its spacing on the worm's rows and turns.
        for (slot, next) in zip(long.slots, long.slots.dropFirst()) {
            let gap = next.distance - slot.distance - (slot.size.z + next.size.z) / 2
            XCTAssertGreaterThanOrEqual(gap, DominoLayout.gap(height: slot.size.y) - 1e-3)
            XCTAssertLessThan(gap, slot.size.y * 0.4)
        }
    }

    // MARK: Finale

    func testTheLastBookSpringsAsTheCameraSettles() {
        // The books start to gather 2 to 3 seconds after the last book falls, while the camera
        // moves.
        XCTAssertTrue((2...3).contains(DominoFinale.gatherDelay))
        XCTAssertLessThan(DominoFinale.gatherDelay, DominoFinale.moveTime)
        // The last book springs as the camera settles, reaches the camera once it rests, and
        // lands just after, once the books have closed in over their places.
        let start = DominoFinale.snapStart
        XCTAssertLessThan(start, DominoFinale.moveTime)
        XCTAssertGreaterThanOrEqual(start + DominoFinale.snapRise, DominoFinale.moveTime)
        XCTAssertGreaterThan(
            start, DominoFinale.gatherDelay + DominoFinale.Gather.closing + DominoFinale.closeTime)
        XCTAssertEqual(
            start + DominoFinale.snapTime, DominoFinale.moveTime + DominoFinale.snapLanding,
            accuracy: 1e-5)
        XCTAssertEqual(
            DominoFinale.duration(count: 12), start + DominoFinale.snapTime, accuracy: 1e-5)
    }

    func testTheLastBookSpringsHangsAndLandsHard() {
        let from = Transform(
            rotation: simd_quatf(angle: 1.2, axis: simd_normalize([0.3, 1, 0.2])),
            translation: [-6, 0.1, 4])
        let to = Transform(rotation: PileSpread.upright, translation: [3, 0.15, -2])
        let camera = PileCamera(target: [1, 0, -1], zoom: 1)
        let slope = tan(PileCamera.fieldOfView / 2)
        let phone = CGSize(width: 402, height: 874)
        let mac = PileViewport(
            size: CGSize(width: 1_180, height: 820),
            insets: EdgeInsets(top: 52, leading: 144, bottom: 0, trailing: 0))
        // A tall paperback in a phone's portrait view, which the spread fills whole, and a
        // wide hardcover in a Mac's window, in the 9:16 frame clear of the sidebar.
        let cases: [(size: SIMD3<Float>, view: CGSize, area: CGRect)] = [
            (SIMD3(1.1, 1.8, 0.25), phone, CGRect(origin: .zero, size: phone)),
            (SIMD3(1.9, 2.4, 0.4), mac.size, DominoFinale.area(in: mac)),
        ]
        for (size, view, area) in cases {
            // It hangs in the middle of the area, facing the camera squarely, head up, near
            // enough to fill the area's width or height as far as fits, and well past the near
            // plane.
            let top = DominoFinale.snapTop(size: size, seenBy: camera, in: area, of: view)
            let aspect = Float(view.width / view.height)
            XCTAssertEqual(
                abs(simd_dot(top.rotation.vector, camera.rotation.vector)), 1, accuracy: 1e-5)
            let middleX = Float(2 * area.midX / view.width - 1)
            let middleY = Float(1 - 2 * area.midY / view.height)
            let middle = SIMD2(middleX, middleY)
            XCTAssertLessThan(
                simd_distance(camera.project(top.translation, aspect: aspect), middle), 1e-4)
            let local = camera.rotation.inverse.act(top.translation - camera.transform.translation)
            let cover = -local.z - size.z / 2
            XCTAssertGreaterThan(cover, 3)
            let share = SIMD2(Float(area.width / view.width), Float(area.height / view.height))
            let width = size.x / (2 * cover * slope * aspect) / share.x
            let height = size.y / (2 * cover * slope) / share.y
            XCTAssertLessThanOrEqual(width, DominoFinale.snapWidth + 1e-4)
            XCTAssertLessThanOrEqual(height, DominoFinale.snapHeight + 1e-4)
            XCTAssertEqual(
                max(width / DominoFinale.snapWidth, height / DominoFinale.snapHeight), 1,
                accuracy: 1e-4)
            func pose(_ time: Float) -> Transform {
                DominoFinale.snapPose(from: from, to: to, top: top, time: time)
            }
            XCTAssertEqual(simd_distance(pose(0).translation, from.translation), 0, accuracy: 1e-5)
            // It reaches the top of its spring, its cover to the camera, and hangs there a
            // beat, drifting no nearer than keeps it in view.
            let rise = DominoFinale.snapRise
            XCTAssertEqual(
                simd_distance(pose(rise).translation, top.translation), 0, accuracy: 1e-4)
            XCTAssertEqual(
                abs(simd_dot(pose(rise).rotation.vector, top.rotation.vector)), 1, accuracy: 1e-5)
            for share: Float in [0.25, 0.5, 0.75] {
                let hanging = pose(rise + DominoFinale.snapHang * share)
                XCTAssertEqual(
                    abs(simd_dot(hanging.rotation.vector, top.rotation.vector)), 1, accuracy: 1e-5)
                XCTAssertLessThan(simd_distance(hanging.translation, top.translation), 0.3)
            }
            // It drops into its place and lands at full speed, flat for the last third of the
            // drop and never below its place: the drop's last hundredth of a second covers far
            // more ground than its first.
            let drop = rise + DominoFinale.snapHang
            let landing = DominoFinale.snapTime
            XCTAssertEqual(
                simd_distance(pose(landing).translation, to.translation), 0, accuracy: 1e-5)
            for step in 0...20 {
                let time = drop + DominoFinale.snapDrop * Float(step) / 20
                XCTAssertGreaterThanOrEqual(pose(time).translation.y, to.translation.y - 1e-5)
                guard step >= 14 else { continue }
                XCTAssertEqual(
                    abs(simd_dot(pose(time).rotation.vector, to.rotation.vector)), 1,
                    accuracy: 1e-5)
            }
            let early = simd_distance(pose(drop).translation, pose(drop + 0.01).translation)
            let late = simd_distance(pose(landing - 0.01).translation, pose(landing).translation)
            XCTAssertGreaterThan(late, early * 10)
        }
    }

    func testTheMoveCentersOnTheLastBookBeforeTurningToTheSpread() {
        // A low Follow view of the chain's end, whose last book lies off its axis.
        let pose = DominoCameraPose(eye: [-12, 4, 6], target: [-3, 1, 2])
        let from = Transform(rotation: pose.rotation, translation: pose.eye)
        let last = SIMD3<Float>(-3.5, 0.15, 3)
        let to = PileCamera(target: [2, 0, -1], yaw: 0.4, zoom: 0.7)
        func shown(_ time: Float) -> SIMD2<Float> {
            let view = DominoFinale.view(
                from: from, to: to, around: last, progress: time / DominoFinale.moveTime)
            let local = view.rotation.inverse.act(last - view.translation)
            return SIMD2(local.x, local.y) / -local.z
        }
        // By `aimDelay`, the book shows in the middle of the view as the camera pulls back.
        XCTAssertGreaterThan(simd_length(shown(0)), 0.05)
        XCTAssertLessThan(simd_length(shown(DominoFinale.aimDelay)), 1e-3)
        XCTAssertLessThan(simd_length(shown(DominoFinale.gatherDelay)), 0.1)
        // It still ends on the spread's view.
        let end = DominoFinale.view(from: from, to: to, around: last, progress: 1)
        XCTAssertEqual(
            simd_distance(end.translation, to.transform.translation), 0, accuracy: 1e-3)
    }

    func testTheCameraMovesFromAnyViewToTheSpreadsAtRest() {
        let to = PileCamera(target: [2, 0, -1], yaw: 0.4, zoom: 0.7)
        // A low, banked Follow view, and an overview.
        let follow = DominoCameraPose(eye: [-12, 4, 6], target: [-3, 1, 2], roll: 0.05)
        for from in [
            Transform(rotation: follow.rotation, translation: follow.eye),
            PileCamera(target: [0, 0, 3], zoom: 1.2).transform,
        ] {
            func view(_ progress: Float) -> Transform {
                DominoFinale.view(from: from, to: to, progress: progress)
            }
            XCTAssertEqual(simd_distance(view(0).translation, from.translation), 0, accuracy: 1e-3)
            XCTAssertEqual(
                abs(simd_dot(view(0).rotation.vector, from.rotation.vector)), 1, accuracy: 1e-5)
            let end = to.transform
            XCTAssertEqual(simd_distance(view(1).translation, end.translation), 0, accuracy: 1e-3)
            XCTAssertEqual(
                abs(simd_dot(view(1).rotation.vector, end.rotation.vector)), 1, accuracy: 1e-5)
            // It leaves and arrives at rest: the first and last hundredths barely move.
            let way = simd_distance(from.translation, end.translation)
            XCTAssertLessThan(simd_distance(view(0.01).translation, from.translation), way * 0.002)
            XCTAssertLessThan(simd_distance(view(0.99).translation, end.translation), way * 0.002)
        }
        // It gets under way at once, with no hold, and spends most of its time slowing down.
        let glide = (0...100).map { DominoFinale.glide(Float($0) / 100) }
        XCTAssertEqual(glide, glide.sorted())
        XCTAssertEqual(glide.first, 0)
        XCTAssertEqual(glide.last ?? 0, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(DominoFinale.glide(1.0 / 6), 0.1)
        XCTAssertGreaterThan(DominoFinale.glide(0.5), 0.6)
    }

    func testTheRoomLightsTheLastBookMoreOnlyOutOfTheLampsBeam() {
        let place = SIMD3<Float>(1, 0.1, -1)
        func boost(_ point: SIMD3<Float>) -> Float {
            DominoFinale.boost(at: point, over: place, radius: 8)
        }
        // In the beam, such as on the way to a camera on the lamp's side, it gets no boost.
        XCTAssertEqual(boost(place), 0)
        let lamp = DeskStage.lampPlacement(pool: .zero, radius: 8).position
        XCTAssertEqual(boost(place + (lamp - place) * 0.3), 0)
        // Out of the beam, such as toward a camera across the table from the lamp, it gets
        // more, up to the limit.
        let away = place + SIMD3(-lamp.x, lamp.y, -lamp.z) * 0.45
        XCTAssertGreaterThan(boost(away), 0)
        XCTAssertLessThanOrEqual(boost(away), DominoFinale.boostLimit)
        XCTAssertEqual(boost(place + [-60, 20, -60]), DominoFinale.boostLimit)
    }

    func testTheMoveCarriesTheCamerasMotionOnAndTurnsIntoTheGlide() {
        // A Follow view descending on the last book as it falls.
        let pose = DominoCameraPose(eye: [-5.6, 12, -14.5], target: [0, 0, 1])
        let from = Transform(rotation: pose.rotation, translation: pose.eye)
        let velocity = SIMD3<Float>(4, -3.4, 0.1)
        let spin = SIMD3<Float>(0.2, -0.1, 0)
        let to = PileCamera(target: [0, 0, 1], yaw: 0.3, zoom: 0.8)
        func shown(_ time: Float) -> Transform {
            DominoFinale.view(
                from: DominoFinale.coast(from, velocity: velocity, spin: spin, time: time),
                to: to, progress: time / DominoFinale.moveTime)
        }
        // The camera leaves at the speed and heading it had, with no stop or jump.
        let step: Float = 1.0 / 120
        XCTAssertEqual(simd_distance(shown(0).translation, from.translation), 0, accuracy: 1e-3)
        let leaving = (shown(step).translation - shown(0).translation) / step
        XCTAssertLessThan(simd_distance(leaving, velocity), 0.05 * simd_length(velocity))
        // The motion dies away within a second, and the move still ends at rest on the spread.
        let carried = DominoFinale.coast(from, velocity: velocity, spin: spin, time: 2)
        let coasted = velocity * DominoFinale.coastTime
        XCTAssertEqual(
            simd_distance(carried.translation, from.translation + coasted), 0,
            accuracy: 0.02 * simd_length(coasted))
        let end = to.transform
        XCTAssertEqual(
            simd_distance(shown(DominoFinale.moveTime).translation, end.translation), 0,
            accuracy: 1e-3)
        XCTAssertEqual(
            abs(simd_dot(shown(DominoFinale.moveTime).rotation.vector, end.rotation.vector)), 1,
            accuracy: 1e-5)
        // The descent it carries has turned into the climb a second in.
        let climb = (shown(1 + step).translation.y - shown(1).translation.y) / step
        XCTAssertGreaterThan(climb, 0)
    }

    /// Fictional books lying as a fallen chain does, each partly on the next, and their places
    /// in a small spread: two books side by side, a third across their far ends, and the
    /// spread's last, which hovers for its flourish, in a row of its own.
    private func gathering() -> [(from: Transform, to: Transform, size: SIMD3<Float>)] {
        let size = SIMD3<Float>(1.4, 2.2, 0.2)
        let along = simd_quatf(angle: .pi / 2, axis: [0, 1, 0]) * PileSpread.upright
        let lying = (0..<4)
            .map { index in
                Transform(
                    rotation: along,
                    translation: [Float(index) * 1.1, size.z * (Float(3 - index) + 0.5), 0.5])
            }
        let places = [
            Transform(rotation: PileSpread.upright, translation: [-0.75, size.z / 2, 0]),
            Transform(rotation: PileSpread.upright, translation: [0.75, size.z / 2, 0]),
            Transform(rotation: PileSpread.upright, translation: [0, size.z * 1.5, -1.8]),
            Transform(rotation: PileSpread.upright, translation: [0, size.z / 2, 3]),
        ]
        return zip(lying, places).map { ($0, $1, size) }
    }

    func testTheBooksGatherWithoutPassingThroughEachOther() {
        let books = gathering()
        let flights = DominoFinale.Gather(books).flights
        // Each book lying on another lifts higher than it, at least a book's thickness higher.
        for index in 0..<3 {
            XCTAssertGreaterThan(
                flights[index].knots[0], flights[index + 1].knots[0] + books[index].size.z)
        }
        // The book across the others' ends lay under them, so it would arrive under them: it
        // waits farther from the camera, clear of their places, while they wait over theirs.
        let staged = flights[2].staging
        XCTAssertEqual(staged.x, flights[2].to.translation.x, accuracy: 1e-4)
        XCTAssertLessThan(staged.y, flights[2].to.translation.z - 0.4)
        let places = books.map { DominoSetup.Box($0.to, size: $0.size) }
        for index in [0, 1] {
            XCTAssertEqual(
                simd_distance(
                    flights[index].staging,
                    SIMD2(flights[index].to.translation.x, flights[index].to.translation.z)), 0)
            XCTAssertFalse(
                DominoFinale.Gather.level(places[2], at: staged)
                    .overlaps(
                        DominoFinale.Gather.level(places[index], at: flights[index].staging)))
        }
        // It drops no sooner than they do, and every book but the last lands before the camera
        // rests.
        XCTAssertGreaterThanOrEqual(flights[2].drop, flights[0].drop)
        XCTAssertGreaterThanOrEqual(flights[2].drop, flights[1].drop)
        let window = DominoFinale.moveTime - DominoFinale.settleMargin - DominoFinale.gatherDelay
        for flight in flights.dropLast() {
            XCTAssertLessThanOrEqual(flight.landing, window)
            XCTAssertEqual(
                simd_distance(flight.pose(at: flight.landing).translation, flight.to.translation),
                0, accuracy: 1e-4)
        }
        // The spread's last book hovers over its place, lying as it will, until its flourish.
        let last = flights[3]
        XCTAssertEqual(last.drop, .infinity)
        XCTAssertEqual(
            simd_distance(last.pose(at: window).translation, last.hovering.translation), 0,
            accuracy: 1e-4)
        XCTAssertGreaterThan(last.hover, last.to.translation.y + books[3].size.z)
        // No two books ever overlap, from where they lie to where they land.
        var time: Float = 0
        while time <= window {
            let boxes = zip(flights, books)
                .map { DominoSetup.Box($0.pose(at: time), size: $1.size, grow: -0.01) }
            for first in boxes.indices {
                for second in boxes.indices where second > first {
                    XCTAssertFalse(
                        boxes[first].overlaps(boxes[second]), "\(time) \(first) \(second)")
                }
            }
            time += 1.0 / 120
        }
    }

    func testEveryBookButTheLastLandsBeforeTheCameraRests() {
        let window = DominoFinale.moveTime - DominoFinale.settleMargin - DominoFinale.gatherDelay
        XCTAssertLessThanOrEqual(DominoFinale.Gather.landed, window)
        // A staircase of fictional books, each resting on the one before, lying apart on the
        // desk in the reverse order, and as many books as a long chain holds, lying in a row.
        let size = SIMD3<Float>(1.4, 2.2, 0.2)
        let stair = (0..<12)
            .map { index in
                (
                    from: Transform(
                        rotation: PileSpread.upright,
                        translation: [Float(11 - index) * 2, size.z / 2, 8]),
                    to: Transform(
                        rotation: PileSpread.upright,
                        translation: [0, size.z * (Float(index) + 0.5), -Float(index) * 0.6]),
                    size: size
                )
            }
        let row = (0..<300)
            .map { index in
                (
                    from: Transform(
                        rotation: PileSpread.upright,
                        translation: [Float(index) * 1.6, size.z / 2, 40]),
                    to: Transform(
                        rotation: PileSpread.upright,
                        translation: [
                            Float(index % 20) * 1.6, size.z / 2, -Float(index / 20) * 2.4,
                        ]
                    ),
                    size: size
                )
            }
        for books in [stair, row] {
            let flights = DominoFinale.Gather(books).flights
            XCTAssertEqual(flights.last?.drop, .infinity)
            for flight in flights.dropLast() {
                XCTAssertLessThanOrEqual(flight.landing, DominoFinale.Gather.landed + 1e-4)
            }
        }
        // The staircase never passes a book through another.
        let flights = DominoFinale.Gather(stair).flights
        var time: Float = 0
        while time <= window {
            let boxes = zip(flights, stair)
                .map { DominoSetup.Box($0.pose(at: time), size: $1.size, grow: -0.01) }
            for first in boxes.indices {
                for second in boxes.indices where second > first {
                    XCTAssertFalse(
                        boxes[first].overlaps(boxes[second]), "\(time) \(first) \(second)")
                }
            }
            time += 1.0 / 60
        }
    }

    func testAFlightLiftsLevelAndLandsFromAbove() {
        let from = Transform(
            rotation: simd_quatf(angle: 0.3, axis: [1, 0, 0]) * PileSpread.upright,
            translation: [-6, 0.4, 4])
        let flight =
            DominoFinale.Gather([
                (
                    from, Transform(rotation: PileSpread.upright, translation: [3, 0.1, -2]),
                    [1.4, 2.2, 0.2]
                ),
                (
                    Transform(translation: [20, 0.1, 20]), Transform(translation: [-20, 0.1, -20]),
                    [1.4, 2.2, 0.2]
                ),
            ])
            .flights[0]
        XCTAssertEqual(simd_distance(flight.pose(at: 0).translation, from.translation), 0)
        // It lifts straight up, lying level front cover up by the top of the lift.
        let lifted = flight.pose(at: DominoFinale.liftTime)
        XCTAssertEqual(lifted.translation.x, from.translation.x, accuracy: 1e-4)
        XCTAssertEqual(lifted.translation.z, from.translation.z, accuracy: 1e-4)
        XCTAssertEqual(lifted.rotation.act([0, 0, 1]).y, 1, accuracy: 1e-4)
        XCTAssertGreaterThanOrEqual(lifted.translation.y, DominoFinale.liftFloor)
        // It drops straight down onto its place, gathering speed, and lands there.
        let above = flight.pose(at: flight.drop)
        XCTAssertEqual(above.translation.x, flight.to.translation.x, accuracy: 1e-4)
        XCTAssertEqual(above.translation.z, flight.to.translation.z, accuracy: 1e-4)
        let early =
            flight.hover - flight.pose(at: flight.drop + DominoFinale.dropTime / 2).translation.y
        let late =
            flight.pose(at: flight.drop + DominoFinale.dropTime / 2).translation.y
            - flight.to.translation.y
        XCTAssertGreaterThan(late, early)
        XCTAssertEqual(
            simd_distance(flight.pose(at: flight.landing).translation, flight.to.translation), 0,
            accuracy: 1e-5)
        XCTAssertEqual(
            abs(
                simd_dot(flight.pose(at: flight.landing).rotation.vector, flight.to.rotation.vector)
            ),
            1, accuracy: 1e-5)
    }

    func testTheSpreadTurnsWithTheCamera() {
        let slot = PileSlot(
            book: book(1, day: 0),
            transform: Transform(rotation: PileSpread.upright, translation: [2, 0.1, -3]))
        let camera = PileCamera(target: [1, 0, -1], zoom: 1.4)
        let turned = DominoFinale.turned([slot], camera: camera, by: .pi / 2)
        let moved = turned.slots[0].transform.translation
        XCTAssertEqual(moved.x, -3, accuracy: 1e-4)
        XCTAssertEqual(moved.z, -2, accuracy: 1e-4)
        XCTAssertEqual(turned.camera.yaw, .pi / 2, accuracy: 1e-5)
        XCTAssertEqual(turned.camera.target.x, -1, accuracy: 1e-4)
        XCTAssertEqual(turned.camera.target.z, -1, accuracy: 1e-4)
        XCTAssertEqual(turned.camera.zoom, 1.4)
        // The book's head still points away from the turned camera.
        let head = turned.slots[0].transform.rotation.act([0, 1, 0])
        let away = turned.camera.rotation.act([0, 0, -1])
        XCTAssertGreaterThan(simd_dot(SIMD3(head.x, 0, head.z), SIMD3(away.x, 0, away.z)), 0.9)
    }

    /// The share of a chain `length` long that has fallen `share` of the way through its run,
    /// as the scene speeds the chain up: where `DominoCameraRig.fallTime(to:)` reaches `share`
    /// of the whole run's time.
    private func fallen(_ share: Double, of length: Float) -> Double {
        let (fastest, reach) = (DominoLayout.fastest, DominoLayout.speedUpReach)
        let time = Float(share) * DominoCameraRig.fallTime(to: length)
        let distance =
            reach
            * log(
                (exp(time * fastest * DominoCameraRig.typicalPace / reach) + fastest - 1) / fastest)
        return Double(distance / length)
    }

    /// Records a run that falls over `run` live seconds at 60 frames per second, speeding up as
    /// the scene speeds the chain up, then the finale and the hold, and returns the frames kept
    /// for each part.
    private func record(run: Double, length: Float) -> (run: Int, finale: Int, last: Int) {
        var timing = DominoMovieTiming(length: length)
        var frames = (run: 0, finale: 0, last: -1)
        let step = 1.0 / 60
        let finale = Double(DominoFinale.duration(count: 2)) + DominoMovieTiming.hold
        while timing.live < run + finale, !timing.isFull {
            let progress =
                timing.live + step < run ? fallen((timing.live + step) / run, of: length) : nil
            guard let kept = timing.advance(by: step, progress: progress) else { continue }
            XCTAssertEqual(kept.lowerBound, frames.last + 1, "frames follow on")
            frames.last = kept.upperBound
            if progress == nil { frames.finale += kept.count } else { frames.run += kept.count }
        }
        return frames
    }

    func testARecordingKeepsLiveSpeedUnlessItWouldRunLong() {
        let finale = Double(DominoFinale.duration(count: 2)) + DominoMovieTiming.hold
        // A year's chain plays at live speed: 30 frames a second throughout.
        let year = record(run: 5, length: 5 * DominoCameraRig.typicalPace)
        XCTAssertEqual(Double(year.run), 5 * 30, accuracy: 2)
        XCTAssertEqual(Double(year.finale), finale * 30, accuracy: 2)
        // A lifetime's chain speeds up to fit 30 seconds, and the finale keeps live speed.
        for (run, length): (Double, Float) in [(40, 380), (90, 900), (90, 300)] {
            let lifetime = record(run: run, length: length)
            XCTAssertLessThan(lifetime.last, DominoMovieTiming.frameLimit, "\(run) s")
            XCTAssertLessThanOrEqual(
                Double(lifetime.run), DominoMovieTiming.runBudget * 30 + 30, "\(run) s")
            XCTAssertEqual(Double(lifetime.finale), finale * 30, accuracy: 2, "\(run) s")
            // It uses most of its budget rather than playing faster than it must.
            XCTAssertGreaterThan(
                Double(lifetime.run), DominoMovieTiming.runBudget * 30 * 0.85, "\(run) s")
        }
    }

    func testHitsSoundWithTheFramesThatShowThem() {
        func hit(_ time: Double, _ volume: Float = 0.5) -> ImpactRecord {
            ImpactRecord(
                time: time, impulse: 1, mass: 0.4, position: .zero, variant: 0, volume: volume,
                pan: 0)
        }
        // Frames that show the view at live times 0.1, 0.2, and 0.3, as a run sped up 3 times.
        let times = [0.1, 0.2, 0.3]
        let moved = DominoMovieTiming.hits(
            [hit(0), hit(0.15), hit(0.16), hit(0.16, 1), hit(0.3), hit(0.31)], shownAt: times)
        // The push's hit sounds with the first frame, the hits within one frame's 30 ms
        // collapse to the first unless one is much stronger, and a hit after the last frame
        // is left out.
        XCTAssertEqual(moved.map(\.volume), [0.5, 0.5, 1, 0.5])
        XCTAssertEqual(
            moved.map { PileMovieTiming.frame(showing: $0.time) }, [0, 1, 1, 2])
        // Hits in the live time the recording leaves out, such as a book's details, are left
        // out.
        let skipped = DominoMovieTiming.hits(
            [hit(0), hit(0.15), hit(0.3)], shownAt: times, skipping: [0.12..<0.2])
        XCTAssertEqual(skipped.map(\.time), [moved[0].time, moved[3].time])
    }

    func testARecordingLeavesOutTheTimeItSkips() {
        var timing = DominoMovieTiming(length: 5 * DominoCameraRig.typicalPace)
        let step = 1.0 / 60
        var last = -1
        for _ in 0..<60 {
            if let kept = timing.advance(by: step, progress: timing.live / 5) {
                last = kept.upperBound
            }
        }
        let video = timing.video
        // A book out at its details for three seconds adds no frames or video time.
        for _ in 0..<180 { timing.skip(step) }
        XCTAssertEqual(timing.video, video)
        XCTAssertEqual(timing.gaps.count, 1)
        XCTAssertEqual(timing.gaps[0].lowerBound, 1, accuracy: 1e-9)
        XCTAssertEqual(timing.gaps[0].upperBound, 4, accuracy: 1e-9)
        // Frames go on from the next number once the book is back.
        var next: ClosedRange<Int>?
        while next == nil { next = timing.advance(by: step, progress: timing.live / 8) }
        XCTAssertEqual(next?.lowerBound, last + 1)
        XCTAssertLessThan(timing.video, video + 0.1)
    }

    func testABackedUpEncoderKeepsFramesSpreadAcrossTheStall() {
        XCTAssertEqual(DominoRecorder.thinned(Array(0..<7)), [0, 2, 4, 6])
        XCTAssertEqual(DominoRecorder.thinned(Array(0..<8)), [1, 3, 5, 7])
        XCTAssertEqual(DominoRecorder.thinned([3]), [3])
    }

    func testARecordingFramesTheHeadingAtTheStoryMargin() {
        // An iPhone's view, with the bars and time frame button above and the tab bar below.
        let phone = PileViewport(
            size: CGSize(width: 402, height: 874),
            insets: EdgeInsets(top: 176, leading: 0, bottom: 83, trailing: 0))
        let crop = DominoRecorder.crop(in: phone)
        XCTAssertEqual(crop.width, 402)
        XCTAssertEqual(crop.height, 402 * 16 / 9, accuracy: 1e-9)
        let heading = (176 + DominoFinaleCard.liveTop - crop.minY) * 1080 / 402
        XCTAssertEqual(heading, ShareAspect.story.insets.top, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(crop.maxY, 874 - 83)
        // With less room above the scene, the frame drops to keep the scene above the tab bar.
        let low = DominoRecorder.crop(
            in: PileViewport(
                size: CGSize(width: 375, height: 800),
                insets: EdgeInsets(top: 120, leading: 0, bottom: 50, trailing: 0)))
        XCTAssertEqual(low.maxY, 750, accuracy: 1e-9)
        // A view barely taller than 9:16 is framed whole, within its bounds.
        let short = DominoRecorder.crop(
            in: PileViewport(
                size: CGSize(width: 375, height: 700),
                insets: EdgeInsets(top: 150, leading: 0, bottom: 50, trailing: 0)))
        XCTAssertEqual(short.maxY, 700, accuracy: 1e-9)
        XCTAssertGreaterThan(short.minY, 0)
        // A view wider than 9:16 shows its full height.
        let wide = DominoRecorder.crop(
            in: PileViewport(size: CGSize(width: 900, height: 900), insets: EdgeInsets()))
        XCTAssertEqual(wide, CGRect(x: 196.875, y: 0, width: 506.25, height: 900))
    }

    func testTheFinaleFillsTheRecordingsFrameInAWideView() {
        // A phone's portrait view: the spread keeps the whole view, between the bars.
        let phone = PileViewport(
            size: CGSize(width: 402, height: 874),
            insets: EdgeInsets(top: 176, leading: 0, bottom: 83, trailing: 0))
        XCTAssertEqual(DominoFinale.area(in: phone), CGRect(x: 0, y: 0, width: 402, height: 874))
        // The chain is framed between the bars.
        XCTAssertEqual(DominoFinale.clearArea(in: phone), phone.clear)
        let rect = DominoFinale.spreadRect(in: phone)
        XCTAssertEqual(rect.minX, 16, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 176 + 402 * 0.28, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 370, accuracy: 1e-9)
        XCTAssertEqual(rect.maxY, 874 - 83 - 24, accuracy: 1e-9)
        // A Mac's window with the sidebar: the spread fills the recording's 9:16 frame, which
        // centers on the part of the view the sidebar leaves clear.
        let mac = PileViewport(
            size: CGSize(width: 1_180, height: 820),
            insets: EdgeInsets(top: 52, leading: 144, bottom: 0, trailing: 0))
        // The frame is 820 × 9 / 16 = 461.25 points wide, centered on x = 662, the middle of
        // the 1,036 points right of the sidebar.
        let area = DominoFinale.area(in: mac)
        XCTAssertEqual(area, CGRect(x: 431.375, y: 0, width: 461.25, height: 820))
        // The chain is framed in that frame below the toolbar.
        XCTAssertEqual(
            DominoFinale.clearArea(in: mac), CGRect(x: 431.375, y: 52, width: 461.25, height: 768))
        let wide = DominoFinale.spreadRect(in: mac)
        XCTAssertEqual(wide.minX, area.minX + 16, accuracy: 1e-9)
        XCTAssertEqual(wide.maxX, area.maxX - 16, accuracy: 1e-9)
        XCTAssertEqual(wide.minY, 52 + area.width * 0.28, accuracy: 1e-9)
        XCTAssertEqual(wide.maxY, 820 - 24, accuracy: 1e-9)
        // A narrow window keeps the frame within the view, and the spread clear of the sidebar.
        let narrow = PileViewport(
            size: CGSize(width: 700, height: 820),
            insets: EdgeInsets(top: 52, leading: 300, bottom: 0, trailing: 0))
        let squeezed = DominoFinale.area(in: narrow)
        XCTAssertEqual(squeezed.maxX, 700, accuracy: 1e-9)
        XCTAssertEqual(DominoFinale.spreadRect(in: narrow).minX, 316, accuracy: 1e-9)
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
