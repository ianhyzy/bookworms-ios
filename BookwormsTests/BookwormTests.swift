import Foundation
import XCTest
import simd

@testable import Bookworms

/// The Bookworm's layout and motion math: eating order, the block, the worm's trail, its
/// segments, its curl, and its tally.
final class BookwormTests: XCTestCase {
    private func book(_ id: Int, finished: String? = "2025-01-01", pages: Int? = 320) -> CloudBook {
        var book = CloudBook(
            id: id, title: "Fictional Book \(id)", author: "An Author", coverURL: nil,
            detailCoverURL: nil)
        book.finished = finished
        book.pages = pages
        return book
    }

    func testWormEatsFinishedBooksInFinishOrder() {
        let books = [
            book(1, finished: "2025-03-02"), book(2, finished: nil),
            book(3, finished: "2025-01-15"), book(4, finished: "2025-03-02"),
            book(5, finished: "2024-12-31"),
        ]
        // Books finished the same day keep the shelf's order.
        XCTAssertEqual(BookwormLayout.eatingOrder(books).map(\.id), [5, 3, 1, 4])
    }

    func testWormEatsAtMostTheFirstHundredFinishedBooks() {
        let books =
            [book(0, finished: nil)]
            + (1...130)
            .map { id in
                book(id, finished: "2025-01-" + String(format: "%02d", 28 - id % 28))
            }
        let meal = BookwormLayout.eatingOrder(books)
        XCTAssertEqual(meal.count, BookwormLayout.maximumBooks)
        XCTAssertEqual(Set(meal.map(\.id)), Set(1...100))
    }

    func testStacksRunInASerpentineOfNeighbors() {
        let pitch = BookwormLayout.stackPitch
        for count in 1...16 {
            let centers = BookwormLayout.stackCenters(count: count)
            XCTAssertEqual(centers.count, count)
            XCTAssertLessThanOrEqual(Set(centers.map(\.x)).count, 3)
            // The worm starts on the near side.
            XCTAssertEqual(centers[0].y, centers.map(\.y).max())
            for (from, to) in zip(centers, centers.dropFirst()) {
                let step = abs(to - from)
                let isNeighbor =
                    (abs(step.x - pitch.x) < 0.0001 && step.y < 0.0001)
                    || (abs(step.y - pitch.y) < 0.0001 && step.x < 0.0001)
                XCTAssertTrue(isNeighbor, "\(count) stacks: \(from) to \(to)")
            }
        }
    }

    func testBlockStacksEachStackInEatingOrderFromTheTable() {
        let meal = (1...20).map { book($0, pages: 100 + $0 * 40) }
        let bricks = BookwormLayout.block(meal)
        XCTAssertEqual(bricks.map(\.book.id), meal.map(\.id))
        // Twenty books fill three stacks evenly.
        XCTAssertEqual(
            bricks.map(\.stack),
            Array(repeating: 0, count: 7) + Array(repeating: 1, count: 7)
                + Array(repeating: 2, count: 6))
        let centers = BookwormLayout.stackCenters(count: 3)
        for (index, brick) in bricks.enumerated() {
            let thickness = BookShape(of: brick.book, coverAspect: 2 / 3).size.z
            XCTAssertEqual(SIMD2(brick.center.x, brick.center.z), centers[brick.stack])
            if index == 0 || bricks[index - 1].stack != brick.stack {
                XCTAssertEqual(brick.center.y, thickness / 2, accuracy: 0.0001)
            } else {
                // Each book lies on the one before it.
                let below = bricks[index - 1]
                let belowThickness = BookShape(of: below.book, coverAspect: 2 / 3).size.z
                XCTAssertEqual(
                    brick.center.y - below.center.y, (thickness + belowThickness) / 2,
                    accuracy: 0.0001)
            }
        }
        XCTAssertEqual(BookwormLayout.block([]), [])
    }

    func testEveryMealFillsContiguousStacksOfAtMostEightBooks() {
        for count in 1...BookwormLayout.maximumBooks {
            let bricks = BookwormLayout.block((1...count).map { book($0) })
            let stacks = (count + BookwormLayout.booksPerStack - 1) / BookwormLayout.booksPerStack
            let centers = BookwormLayout.stackCenters(count: stacks)
            // Stack indices start at 0 and step up by at most one, so no stack is empty.
            XCTAssertEqual(bricks.first?.stack, 0)
            XCTAssertEqual(bricks.last?.stack, stacks - 1, "\(count) books")
            for (below, above) in zip(bricks, bricks.dropFirst()) {
                XCTAssertTrue((0...1).contains(above.stack - below.stack), "\(count) books")
            }
            for stack in 0..<stacks {
                let held = bricks.filter { $0.stack == stack }
                XCTAssertTrue(
                    (1...BookwormLayout.booksPerStack).contains(held.count), "\(count) books")
                for brick in held {
                    XCTAssertEqual(SIMD2(brick.center.x, brick.center.z), centers[stack])
                }
            }
        }
    }

    func testSegmentsGrowLongerForEveryHundredPages() {
        XCTAssertEqual(BookwormLayout.segmentLength(pages: 0), 0.16, accuracy: 0.0001)
        XCTAssertEqual(BookwormLayout.segmentLength(pages: 99), 0.16, accuracy: 0.0001)
        XCTAssertEqual(BookwormLayout.segmentLength(pages: 100), 0.2, accuracy: 0.0001)
        XCTAssertEqual(BookwormLayout.segmentLength(pages: 450), 0.32, accuracy: 0.0001)
        XCTAssertEqual(
            BookwormLayout.segmentLength(pages: nil), BookwormLayout.segmentLength(pages: 320))
        XCTAssertEqual(
            BookwormLayout.segmentLength(pages: 5000), BookwormLayout.segmentLength(pages: 1500))
    }

    func testTrailSamplesFollowThePathAndRunStraightBeforeIt() {
        var trail = WormTrail(head: [0, 0], heading: [1, 0])
        for step in 1...4 { trail.move(to: [Float(step) * 0.25, 0]) }
        for step in 1...4 { trail.move(to: [1, Float(step) * 0.25]) }
        var samples: [(point: SIMD2<Float>, forward: SIMD2<Float>)] = []
        trail.sample([0, 0.5, 1.5, 2.5], into: &samples)
        let expected: [(SIMD2<Float>, SIMD2<Float>)] = [
            ([1, 1], [0, 1]), ([1, 0.5], [0, 1]), ([0.5, 0], [1, 0]),
            // Past where the head started, the trail runs straight back.
            ([-0.5, 0], [1, 0]),
        ]
        XCTAssertEqual(samples.count, expected.count)
        for (sample, (point, forward)) in zip(samples, expected) {
            XCTAssertLessThan(simd_distance(sample.point, point), 0.0001, "\(sample)")
            XCTAssertLessThan(simd_distance(sample.forward, forward), 0.0001, "\(sample)")
        }
        // A short move keeps no new point, but the head still leads the trail.
        trail.move(to: [1, 1.05])
        XCTAssertEqual(trail.points.count, 9)
        trail.sample([0.05], into: &samples)
        XCTAssertLessThan(simd_distance(samples[0].point, [1, 1]), 0.0001)
    }

    func testCurlKeepsCoilsApartWithTheHeadOutsideFacingTheCamera() {
        let lengths: [Float] =
            [BookwormLayout.headRadius * 1.5] + (0..<40).map { _ in 0.28 } + [0.76, 0.16, 0.5, 0.3]
        let points = BookwormLayout.curl(lengths: lengths)
        XCTAssertEqual(points.count, lengths.count)
        // The head lies on the near side, outermost.
        XCTAssertEqual(points[0].x, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(points[0].y, 0)
        var along: [Float] = [0]
        for index in 1..<points.count {
            let spacing = (lengths[index - 1] + lengths[index]) / 2
            XCTAssertEqual(
                simd_distance(points[index - 1], points[index]), spacing, accuracy: 0.02)
            XCTAssertGreaterThanOrEqual(simd_length(points[index - 1]), simd_length(points[index]))
            along.append(along[index - 1] + spacing)
        }
        // Parts more than two coil gaps apart along the body lie on other coils, or far around
        // their own, so the body never crosses itself.
        for first in points.indices {
            for second in points.indices
            where along[second] - along[first] >= 2 * BookwormLayout.coilGap {
                XCTAssertGreaterThan(
                    simd_distance(points[first], points[second]), BookwormLayout.coilGap * 0.95)
            }
        }
        XCTAssertEqual(BookwormLayout.curl(lengths: []), [])
        // A head alone lies one coil gap out on the near side.
        let head = BookwormLayout.curl(lengths: [0.6])
        XCTAssertEqual(head.count, 1)
        XCTAssertLessThan(simd_distance(head[0], [0, BookwormLayout.coilGap]), 0.0001)
    }

    func testFramingFitsEveryPointTightlyBetweenTheBars() {
        let pitch: Float = 50 * .pi / 180
        let fieldOfView: Float = 38 * .pi / 180
        let (aspect, width, bottom, top): (Float, Float, Float, Float) = (0.46, 0.94, -0.7, 0.75)
        let points: [SIMD3<Float>] = [
            [-3.8, 0, -3.3], [3.8, 0, -3.3], [-3.8, 0, 3.6], [3.8, 0, 3.6], [-3.8, 2.4, -3.3],
            [3.8, 2.4, 3.6], [1, 0.8, 0],
        ]
        let fit = BookwormLayout.framing(
            points, pitch: pitch, fieldOfView: fieldOfView, aspect: aspect, width: width,
            bottom: bottom, top: top)
        let back = SIMD3<Float>(0, sin(pitch), cos(pitch))
        let up = SIMD3<Float>(0, cos(pitch), -sin(pitch))
        // Where `point` lands in normalized device coordinates from `distance` away.
        func project(_ point: SIMD3<Float>, distance: Float) -> SIMD2<Float> {
            let offset = point - (fit.target + back * distance)
            let depth = -simd_dot(offset, back)
            return SIMD2(offset.x / aspect, simd_dot(offset, up)) / (depth * tan(fieldOfView / 2))
        }
        for point in points {
            let place = project(point, distance: fit.distance)
            XCTAssertLessThanOrEqual(abs(place.x), width + 0.001, "\(point)")
            XCTAssertLessThanOrEqual(place.y, top + 0.001, "\(point)")
            XCTAssertGreaterThanOrEqual(place.y, bottom - 0.001, "\(point)")
        }
        // A camera any closer leaves some point outside the bounds.
        let closer = points.map { project($0, distance: fit.distance * 0.97) }
        XCTAssertTrue(
            closer.contains { abs($0.x) > width || $0.y > top || $0.y < bottom })
    }

    func testHeadStopsJustOutsideTheStackItEats() {
        let half = BookwormLayout.stackHalfSize
        let reach = BookwormLayout.headRadius * 0.3
        let stack = SIMD2<Float>(2, -1)
        // From the near side, the head stops past the spines; from the left, past the tails.
        let fromFront = BookwormLayout.biteSpot(stack: stack, from: stack + [0, 5])
        XCTAssertLessThan(simd_distance(fromFront, stack + [0, half.y + reach]), 0.0001)
        let fromLeft = BookwormLayout.biteSpot(stack: stack, from: stack - [4, 0])
        XCTAssertLessThan(simd_distance(fromLeft, stack - [half.x + reach, 0]), 0.0001)
        // Coming in at a slant, it stops at the footprint's nearer edge on the way in.
        let slanted = BookwormLayout.biteSpot(stack: stack, from: stack + [3, 3])
        XCTAssertEqual(slanted.y - stack.y, half.y + reach * 0.7071, accuracy: 0.001)
        XCTAssertEqual(slanted.x - stack.x, slanted.y - stack.y, accuracy: 0.001)
        // A stack of wide books keeps the head out past their wider footprint.
        let wide = SIMD2<Float>(1.2, 1.02)
        let fromFrontOfWide = BookwormLayout.biteSpot(
            stack: stack, from: stack + [0, 5], halfSize: wide)
        XCTAssertLessThan(simd_distance(fromFrontOfWide, stack + [0, wide.y + reach]), 0.0001)
        // A head already at the stack stays put.
        let close = stack + [0, 0.5]
        XCTAssertEqual(BookwormLayout.biteSpot(stack: stack, from: close), close)
    }

    func testRingIsATubeAroundTheUnitCircleFacingOut() {
        let tube: Float = 0.1
        for arc: Float in [2 * .pi, .pi * 0.6] {
            let ring = BookwormLayout.ring(arc: arc, tube: tube)
            XCTAssertEqual(ring.positions.count, ring.normals.count)
            XCTAssertEqual(ring.indices.count % 3, 0)
            for (position, normal) in zip(ring.positions, ring.normals) {
                XCTAssertEqual(simd_length(normal), 1, accuracy: 0.0001)
                // Each vertex lies `tube` out from the circle, along its normal.
                let onCircle = position - normal * tube
                XCTAssertEqual(simd_length(onCircle), 1, accuracy: 0.0001)
                XCTAssertEqual(onCircle.z, 0, accuracy: 0.0001)
            }
            // Triangles wind counterclockwise seen from outside, where their normals point.
            for corner in stride(from: 0, to: ring.indices.count, by: 3) {
                let ids = ring.indices[corner..<corner + 3].map(Int.init)
                let corners = ids.map { ring.positions[$0] }
                let outward = ids.reduce(SIMD3<Float>.zero) { $0 + ring.normals[$1] }
                let facing = simd_cross(corners[1] - corners[0], corners[2] - corners[0])
                XCTAssertGreaterThan(simd_dot(facing, outward), 0)
            }
        }
        // A short arc is centered on the circle's bottom, as a smile is.
        let smile = BookwormLayout.ring(arc: .pi * 0.6, tube: tube)
        let lowest = smile.positions.min { $0.y < $1.y }
        XCTAssertEqual(lowest?.x ?? 1, 0, accuracy: 0.0001)
    }

    func testPaceKeepsLongMealsShort() {
        XCTAssertEqual(BookwormLayout.pace(books: 1), 1)
        XCTAssertEqual(BookwormLayout.pace(books: 30), 1)
        XCTAssertEqual(BookwormLayout.pace(books: 90), 3)
    }

    func testCaptionCountsBooksAndPages() {
        XCTAssertEqual(BookwormLayout.caption(books: 1, pages: 320), "Ate 1 book · 320 pages")
        XCTAssertEqual(BookwormLayout.caption(books: 39, pages: 640), "Ate 39 books · 640 pages")
        XCTAssertEqual(BookwormLayout.caption(books: 2, pages: 0), "Ate 2 books")
    }

    func testThreeDOffersTheBookworm() {
        XCTAssertEqual(ThreeDView.bookworm.title, "Bookworm")
        XCTAssertEqual(ThreeDView(rawValue: "bookworm"), .bookworm)
    }
}
