import RealityKit
import XCTest

@testable import Bookworms

final class BookPileTests: XCTestCase {
    /// Fictional books from 90 to 1,200 pages, with one of unknown length.
    private static let books: [CloudBook] = (1...40)
        .map { index in
            CloudBook(
                id: 1_000 + index, title: "Fictional Book \(index)", author: "Author \(index)",
                coverURL: nil, detailCoverURL: nil,
                pages: index == 7 ? nil : 90 + (index * 263) % 1_110)
        }

    /// An iPhone-shaped view, 402 × 874 points, with bars of 116 and 83 points.
    private static let tray = PileTray(
        aspect: 402.0 / 874, safeTop: 1 - 2 * 116.0 / 874, safeBottom: -1 + 2 * 83.0 / 874)!

    /// The corners of a slot's book at the widest cover, in scene coordinates.
    private func corners(of slot: PileSlot) -> [SIMD3<Float>] {
        let half = PileLayout.size(of: slot.book, coverAspect: 0.85) / 2
        return (0..<8)
            .map { corner in
                slot.transform.translation
                    + slot.transform.rotation.act(
                        SIMD3(
                            corner & 1 == 0 ? -half.x : half.x, corner & 2 == 0 ? -half.y : half.y,
                            corner & 4 == 0 ? -half.z : half.z))
            }
    }

    /// Whether two slots' books, at the widest cover, intersect: the separating axis test for
    /// oriented boxes, over both boxes' axes and the cross products of their edges.
    private func overlap(_ a: PileSlot, _ b: PileSlot) -> Bool {
        func axes(_ slot: PileSlot) -> [SIMD3<Float>] {
            [[1, 0, 0], [0, 1, 0], [0, 0, 1]].map { slot.transform.rotation.act($0) }
        }
        func radius(_ slot: PileSlot, along axis: SIMD3<Float>) -> Float {
            let half = PileLayout.size(of: slot.book, coverAspect: 0.85) / 2
            return zip(axes(slot), [half.x, half.y, half.z])
                .map { abs(simd_dot($0, axis)) * $1 }
                .reduce(0, +)
        }
        let edges = axes(a).flatMap { u in axes(b).map { simd_cross(u, $0) } }
        let candidates = axes(a) + axes(b) + edges.filter { simd_length($0) > 0.0001 }
        let offset = b.transform.translation - a.transform.translation
        return !candidates.contains { axis in
            let axis = simd_normalize(axis)
            return abs(simd_dot(offset, axis)) > radius(a, along: axis) + radius(b, along: axis)
        }
    }

    /// Projects a point to normalized device coordinates for the default camera.
    private func project(_ point: SIMD3<Float>, aspect: Float = 402.0 / 874) -> SIMD2<Float> {
        let camera = PileCamera()
        let local = camera.rotation.inverse.act(point - camera.transform.translation)
        let slope = tan(PileCamera.fieldOfView / 2)
        return [local.x / (-local.z * slope * aspect), local.y / (-local.z * slope)]
    }

    func testBookSizesFollowTheCoverAndPageCount() {
        let book = Self.books[0]
        let size = PileLayout.size(of: book, coverAspect: 0.7)
        XCTAssertEqual(size, PileLayout.size(of: book, coverAspect: 0.7))
        XCTAssertGreaterThanOrEqual(size.y, 2.1)
        XCTAssertLessThanOrEqual(size.y, 2.4)
        XCTAssertEqual(size.x, size.y * 0.7, accuracy: 0.0001)
        XCTAssertEqual(size.z, size.y * Float(book.thicknessRatio), accuracy: 0.0001)
        // The cover changes only the width.
        XCTAssertEqual(PileLayout.size(of: book, coverAspect: 2 / 3).y, size.y)

        var short = book
        short.pages = 100
        var long = book
        long.pages = 1_000
        XCTAssertLessThan(
            PileLayout.size(of: short, coverAspect: 0.7).z,
            PileLayout.size(of: long, coverAspect: 0.7).z)
    }

    func testCameraLooksAtItsTarget() {
        var camera = PileCamera()
        for (zoom, yaw) in [(1, 0), (2.5, 1.2)] as [(Float, Float)] {
            camera.zoom = zoom
            camera.yaw = yaw
            camera.target = [1, 0, -2]
            let center = PileCamera.intersect(camera.ray(ndc: .zero, aspect: 0.5), height: 0)
            XCTAssertEqual(simd_distance(center ?? .zero, camera.target), 0, accuracy: 0.001)
        }
        // A ray parallel to the table, or pointing away from it, never meets it.
        XCTAssertNil(PileCamera.intersect(([0, 5, 0], [1, 0, 0]), height: 0))
        XCTAssertNil(PileCamera.intersect(([0, 5, 0], [0, 1, 0]), height: 0))
    }

    func testTrayStaysBetweenTheBars() {
        let tray = Self.tray
        XCTAssertLessThan(tray.farZ, 0)
        XCTAssertGreaterThan(tray.nearZ, 0)
        // Perspective widens the far edge.
        XCTAssertGreaterThan(tray.farHalfWidth, tray.nearHalfWidth)
        let safeTop: Float = 1 - 2 * 116.0 / 874
        let safeBottom: Float = -1 + 2 * 83.0 / 874
        for corner in tray.corners {
            // On the table, and with a pile 4.5 units high against the wall.
            for height in [0, 4.5] as [Float] {
                let ndc = project(corner + [0, height, 0])
                XCTAssertLessThanOrEqual(abs(ndc.x), 1)
                XCTAssertLessThanOrEqual(ndc.y, safeTop)
                XCTAssertGreaterThanOrEqual(ndc.y, safeBottom)
            }
        }
    }

    func testClampKeepsPointsInsideTheTray() {
        let tray = Self.tray
        let inside = SIMD3<Float>(0.5, 2, 0)
        XCTAssertEqual(tray.clamp(inside, margin: 1), inside)
        let clamped = tray.clamp([40, 2, -40], margin: 1)
        XCTAssertEqual(clamped.y, 2)
        XCTAssertEqual(clamped.z, tray.farZ + 1, accuracy: 0.0001)
        XCTAssertEqual(clamped.x, tray.halfWidth(at: tray.farZ + 1) - 1, accuracy: 0.0001)
        let near = tray.clamp([-40, 0, 40], margin: 1)
        XCTAssertEqual(near.z, tray.nearZ - 1, accuracy: 0.0001)
        XCTAssertEqual(near.x, -(tray.halfWidth(at: tray.nearZ - 1) - 1), accuracy: 0.0001)
    }

    func testDropPlanIsRepeatableAndSpreadsEachWave() {
        let plan = PileLayout.dropPlan(Self.books, in: Self.tray, seed: 3)
        let again = PileLayout.dropPlan(Self.books, in: Self.tray, seed: 3)
        let other = PileLayout.dropPlan(Self.books, in: Self.tray, seed: 4)
        XCTAssertEqual(plan.map(\.book.id), Self.books.map(\.id))
        XCTAssertEqual(plan.map(\.transform), again.map(\.transform))
        XCTAssertNotEqual(plan.map(\.transform), other.map(\.transform))

        for slot in plan {
            let position = slot.transform.translation
            // Clear of the walls by half a book, and between the drop height and the ceiling.
            XCTAssertEqual(Self.tray.clamp(position, margin: PileLayout.reach), position)
            XCTAssertGreaterThanOrEqual(position.y, PileLayout.spawnHeight)
            XCTAssertLessThan(position.y + 1.3, PileLayout.ceiling)
        }
        // No two books of a wave start inside each other, at the widest cover.
        for seed in 0..<20 as Range<UInt64> {
            let plan = PileLayout.dropPlan(Self.books, in: Self.tray, seed: seed)
            for wave in stride(from: 0, to: plan.count, by: PileLayout.waveSize) {
                let slots = plan[wave..<min(wave + PileLayout.waveSize, plan.count)]
                for (index, slot) in slots.enumerated() {
                    for other in slots.dropFirst(index + 1) {
                        XCTAssertFalse(
                            overlap(slot, other), "seed \(seed): \(slot.book.id), \(other.book.id)")
                    }
                }
            }
        }
    }

    func testStillImageGroupsStartApartInsideTheWalls() throws {
        for aspect in ShareAspect.allCases {
            for count in [1, 2, 12, 40] {
                let books = Array(Self.books.prefix(count))
                let tray = try XCTUnwrap(PileSnapshotLayout(aspect: aspect, count: count)).tray
                let walls = tray.scaled(toFit: 3.4)
                let groups = PileLayout.settleGroups(books, in: tray, seed: 5)
                XCTAssertEqual(groups.flatMap { $0 }.map(\.book.id), books.map(\.id))
                for group in groups {
                    for (index, slot) in group.enumerated() {
                        // Low enough to land within the group's 0.4 seconds, without spin.
                        XCTAssertLessThanOrEqual(slot.transform.translation.y, 3.7 + 0.0001)
                        XCTAssertEqual(slot.spin, .zero)
                        for corner in corners(of: slot) {
                            XCTAssertEqual(
                                walls.clamp(corner, margin: 0), corner, "\(aspect) \(count)")
                        }
                        for other in group.dropFirst(index + 1) {
                            XCTAssertFalse(overlap(slot, other), "\(aspect) \(count)")
                        }
                    }
                }
            }
        }
    }

    func testAddedBooksMustKeepTheEarlierOrder() {
        let books = Array(Self.books.prefix(5))
        let ids = books.map(\.id)
        XCTAssertEqual(
            PileLayout.added(to: [ids[1], ids[3]], in: books)?.map(\.id), [ids[0], ids[2], ids[4]])
        XCTAssertEqual(PileLayout.added(to: [], in: books)?.map(\.id), ids)
        // A reordered or shortened list starts a new pile.
        XCTAssertNil(PileLayout.added(to: [ids[3], ids[1]], in: books))
        XCTAssertNil(PileLayout.added(to: ids + [99], in: books))
    }

    func testStackPlanStacksBooksBottomUpInsideTheTray() {
        let plan = PileLayout.stackPlan(Self.books, in: Self.tray)
        XCTAssertEqual(Set(plan.map(\.book.id)), Set(Self.books.map(\.id)))
        XCTAssertEqual(plan.count, Self.books.count)

        // Slots arrive bottom up, so each book rests on the books listed before it in its stack.
        var stacks: [(center: SIMD2<Float>, top: Float, firstID: Int?)] = []
        for slot in plan {
            let position = slot.transform.translation
            let thickness = PileLayout.size(of: slot.book, coverAspect: 2 / 3).z
            let center = SIMD2(position.x, position.z)
            if let index = stacks.firstIndex(where: { simd_distance($0.center, center) < 0.2 }) {
                XCTAssertEqual(position.y - thickness / 2, stacks[index].top, accuracy: 0.0001)
                stacks[index].top += thickness
                stacks[index].firstID = slot.book.id
            } else {
                XCTAssertEqual(position.y, thickness / 2, accuracy: 0.0001)
                stacks.append((center, thickness, slot.book.id))
            }
            // A flat book, 2.4 units long and 2.04 wide at most, stays inside the tray.
            XCTAssertEqual(
                Self.tray.clamp(position, margin: 1.2).x, position.x, accuracy: 0.0001)
            XCTAssertEqual(
                Self.tray.clamp(position, margin: 1.02).z, position.z, accuracy: 0.0001)
        }
        XCTAssertGreaterThan(stacks.count, 1)
        // The first book in the order lies on top of the first stack.
        XCTAssertEqual(stacks[0].firstID, Self.books[0].id)
        // Stacks never overlap: they are a book's length apart across, or a width apart in depth.
        for (index, stack) in stacks.enumerated() {
            for other in stacks.dropFirst(index + 1) {
                let gap = abs(stack.center - other.center)
                XCTAssertTrue(gap.x > 2.4 || gap.y > 2.04, "\(stack.center) \(other.center)")
            }
        }
        // Lying flat, front cover up, with the spine toward the camera and the head to the left.
        let rotation = PileLayout.lyingFlat
        XCTAssertEqual(simd_distance(rotation.act([0, 0, 1]), [0, 1, 0]), 0, accuracy: 0.0001)
        XCTAssertEqual(simd_distance(rotation.act([-1, 0, 0]), [0, 0, 1]), 0, accuracy: 0.0001)
        XCTAssertEqual(simd_distance(rotation.act([0, 1, 0]), [-1, 0, 0]), 0, accuracy: 0.0001)
    }

    func testTiltGravityFollowsTheChangeAndStaysOnTheTable() {
        let upright = SIMD3<Double>(0, -1, 0)
        let down = SIMD3<Float>(0, -PileLayout.gravity, 0)
        XCTAssertEqual(PileLayout.gravity(device: upright, reference: upright, yaw: 0), down)
        // A steady hand stays in the dead zone.
        XCTAssertEqual(
            PileLayout.gravity(device: [0.02, -1, 0], reference: upright, yaw: 0), down)

        // Right edge down slides books right; top edge down slides them up the screen.
        let right = PileLayout.gravity(device: [0.2, -1, 0], reference: upright, yaw: 0)
        XCTAssertGreaterThan(right.x, 0)
        XCTAssertEqual(right.z, 0, accuracy: 0.0001)
        XCTAssertEqual(right.y, -PileLayout.gravity)
        let flat = SIMD3<Double>(0, 0, -1)
        let away = PileLayout.gravity(device: [0, 0.2, -0.98], reference: flat, yaw: 0)
        XCTAssertLessThan(away.z, 0)

        // A hard tilt is clamped, so books slide but keep pressing on the table.
        let hard = PileLayout.gravity(device: [1, 0, 0], reference: upright, yaw: 0)
        XCTAssertEqual(
            simd_length(SIMD2(hard.x, hard.z)), PileLayout.maximumTilt * PileLayout.gravity,
            accuracy: 0.001)
        XCTAssertEqual(hard.y, -PileLayout.gravity)

        // Turned a quarter, the camera's right is -z, and tipping the right edge down still
        // slides books toward the screen's right.
        var camera = PileCamera()
        camera.yaw = .pi / 2
        let turned = PileLayout.gravity(device: [0.2, -1, 0], reference: upright, yaw: camera.yaw)
        let screenRight = camera.rotation.act([1, 0, 0])
        XCTAssertEqual(
            simd_dot(SIMD2(turned.x, turned.z), SIMD2(screenRight.x, screenRight.z)),
            simd_length(SIMD2(right.x, right.z)), accuracy: 0.001)
        XCTAssertEqual(turned.y, -PileLayout.gravity, accuracy: 0.001)
    }

    func testCoversAreCroppedToTheBoxLikeTheDetailsView() {
        // A square cover on a box clamped to 0.85 keeps its middle 85 percent of width.
        XCTAssertEqual(
            PileLayout.crop(CGSize(width: 200, height: 200), to: 0.85),
            CGRect(x: 15, y: 0, width: 170, height: 200))
        // A narrow cover keeps its middle height.
        XCTAssertEqual(
            PileLayout.crop(CGSize(width: 100, height: 250), to: 0.5),
            CGRect(x: 0, y: 25, width: 100, height: 200))
        // A cover that already fits is untouched.
        XCTAssertEqual(
            PileLayout.crop(CGSize(width: 150, height: 225), to: 2 / 3),
            CGRect(x: 0, y: 0, width: 150, height: 225))
    }
}
