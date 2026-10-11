import RealityKit
import XCTest

@testable import Bookworms

/// The Jenga tower's layout, the finger's pull, grinding, the fall, and the camera.
final class JengaTests: XCTestCase {
    /// Fictional books finished a day apart from January 2025, listed newest first as the shelf
    /// lists them, from 90 to 1,200 pages.
    private func books(_ count: Int) -> [CloudBook] {
        (0..<count).reversed()
            .map { index in
                var book = CloudBook(
                    id: 2_000 + index, title: "Fictional Book \(index)", author: "An Author",
                    coverURL: nil, detailCoverURL: nil, pages: 90 + (index * 263) % 1_110)
                book.finished = String(format: "2025-%02d-%02d", 1 + index / 28, 1 + index % 28)
                return book
            }
    }

    private func layers(_ blocks: [JengaBlock]) -> [[JengaBlock]] {
        Dictionary(grouping: blocks, by: \.layer).sorted { $0.key < $1.key }.map(\.value)
    }

    /// The horizontal direction a layer's blocks lie side by side along.
    private func across(_ layer: Int) -> SIMD3<Float> {
        layer.isMultiple(of: 2) ? [0, 0, 1] : [1, 0, 0]
    }

    func testTowerStacksTheShelfsFirstBooksEarliestFinishedFirst() {
        let shelf = books(60)
        let blocks = JengaLayout.tower(shelf)
        XCTAssertEqual(blocks.count, JengaLayout.maximumBooks)
        XCTAssertEqual(
            Set(blocks.map(\.book.id)),
            Set(shelf.prefix(JengaLayout.maximumBooks).map(\.id)))
        XCTAssertEqual(blocks.map(\.layer), blocks.indices.map { $0 / 3 })
        let layers = layers(blocks)
        for (lower, upper) in zip(layers, layers.dropFirst()) {
            let lowerLatest = lower.compactMap(\.book.finishedDate).max() ?? .distantFuture
            let upperEarliest = upper.compactMap(\.book.finishedDate).min() ?? .distantPast
            XCTAssertLessThanOrEqual(lowerLatest, upperEarliest)
        }
        // A book not yet finished goes on top.
        let reading = CloudBook(
            id: 9_999, title: "Fictional Current Read", author: "An Author", coverURL: nil,
            detailCoverURL: nil, isReading: true)
        let tower = JengaLayout.tower([reading] + books(5))
        XCTAssertTrue(
            tower.filter { $0.layer == tower.last?.layer }.contains { $0.book.id == 9_999 })
    }

    func testLayersCrossLieFlatAndRestOnTheLayerBelow() {
        let layers = layers(JengaLayout.tower(books(54)))
        var base: Float = 0
        for (index, layer) in layers.enumerated() {
            let along = simd_cross([0, 1, 0], across(index))
            let length = layer[0].shape.size.y
            let width = layer[0].shape.size.x
            for block in layer {
                let rotation = block.transform.rotation
                // Front cover up, head and tail along the layer.
                XCTAssertLessThan(simd_distance(rotation.act([0, 0, 1]), [0, 1, 0]), 0.0001)
                XCTAssertEqual(abs(simd_dot(rotation.act([0, 1, 0]), along)), 1, accuracy: 0.0001)
                XCTAssertEqual(block.shape.size.y, length, accuracy: 0.0001)
                XCTAssertEqual(block.shape.size.x, width, accuracy: 0.0001)
                let bottom = block.transform.translation.y - block.shape.size.z / 2
                XCTAssertEqual(bottom, base, accuracy: 0.0001)
                // Square: the outer blocks' outer faces meet the layer's ends.
                let side = simd_dot(block.transform.translation, across(index))
                XCTAssertLessThanOrEqual(abs(side) + width / 2, length / 2 + 0.0001)
                XCTAssertEqual(simd_dot(block.transform.translation, along), 0, accuracy: 0.0001)
            }
            let sides = layer.map { simd_dot($0.transform.translation, across(index)) }.sorted()
            for (a, b) in zip(sides, sides.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b - a, width + JengaLayout.gap - 0.0001)
            }
            if index > 0 {
                // Each block's middle lies well within the layer below, which crosses it.
                let below = layers[index - 1][0].shape.size.y
                for side in sides { XCTAssertLessThanOrEqual(abs(side) + width / 4, below / 2) }
            }
            base =
                (layer.map { $0.transform.translation.y + $0.shape.size.z / 2 }.max() ?? 0)
                + JengaLayout.clearance
        }
    }

    func testThinnestBookLiesLooseInTheMiddleBetweenEvenRails() throws {
        var loose = 0
        for layer in layers(JengaLayout.tower(books(54))) {
            let outer = layer.filter { $0.place != 1 }
            let middle = try XCTUnwrap(layer.first { $0.place == 1 })
            XCTAssertEqual(layer.map(\.place), [0, 1, 2])
            XCTAssertEqual(outer[0].shape.size.z, outer[1].shape.size.z, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(middle.shape.size.z, outer[0].shape.size.z + 0.0001)
            // Loose by at most a step, so the tower barely leans when a rail is gone.
            XCTAssertGreaterThanOrEqual(
                middle.shape.size.z, outer[0].shape.size.z - JengaLayout.looseness - 0.0001)
            let own = layer.map { BookShape(of: $0.book, coverAspect: 2.0 / 3).size.z }
            XCTAssertEqual(
                BookShape(of: middle.book, coverAspect: 2.0 / 3).size.z, own.min() ?? 0,
                accuracy: 0.0001)
            if middle.shape.size.z < outer[0].shape.size.z - 0.0001 { loose += 1 }
        }
        XCTAssertGreaterThan(loose, 0)
    }

    func testOuterBlocksTurnTheirSpinesOutward() {
        for block in JengaLayout.tower(books(54)) where block.place != 1 {
            // The spine is on the book's -x side.
            let spine = block.transform.rotation.act([-1, 0, 0])
            var outward = block.transform.translation
            outward.y = 0
            XCTAssertGreaterThan(simd_dot(spine, simd_normalize(outward)), 0.999)
        }
    }

    func testShortTopLayersStandOnTheLowerLayersRails() {
        XCTAssertEqual(JengaLayout.tower(books(4)).last?.place, 1)
        XCTAssertEqual(JengaLayout.tower(books(5)).suffix(2).map(\.place), [0, 2])
        XCTAssertTrue(JengaLayout.tower([]).isEmpty)
    }

    func testSlideFollowsTheFingerAlongTheBlocksAxis() {
        let axis: JengaLayout.Ray = ([0, 0.5, 0], [1, 0, 0])
        let origin = SIMD3<Float>(0, 6, 10)
        let ray: JengaLayout.Ray = (origin, [1.5, 0.5, 0] - origin)
        XCTAssertEqual(JengaLayout.offset(of: ray, along: axis) ?? 0, 1.5, accuracy: 0.0001)
        // Looking along the axis gives nothing to steer by.
        XCTAssertNil(JengaLayout.offset(of: ([-10, 0.5, 0], [1, 0, 0]), along: axis))
    }

    func testPullIsADampedSpringWithACap() {
        XCTAssertEqual(JengaLayout.drive(error: 0, speed: 0, mass: 0.3), 0)
        XCTAssertEqual(JengaLayout.drive(error: 5, speed: 0, mass: 0.3), JengaLayout.maximumForce)
        XCTAssertEqual(
            JengaLayout.drive(error: -5, speed: 0, mass: 0.3), -JengaLayout.maximumForce)
        // A block already moving toward the finger is pulled less.
        XCTAssertLessThan(
            JengaLayout.drive(error: 0.1, speed: 1, mass: 0.3),
            JengaLayout.drive(error: 0.1, speed: 0, mass: 0.3))
        XCTAssertLessThan(abs(JengaLayout.drive(error: 0.1, speed: 0, mass: 0.3)), 30)
    }

    func testGrindTapsWithTravelHarderUnderLoadAndCreaksWhenStuck() {
        var grind = JengaGrind()
        XCTAssertNil(grind.advance(by: JengaGrind.step / 2, load: 0.1, deltaTime: 1.0 / 60))
        let light = grind.advance(by: JengaGrind.step / 2, load: 0.1, deltaTime: 1.0 / 60)
        XCTAssertNotNil(light)
        var loaded = JengaGrind()
        let heavy = loaded.advance(by: JengaGrind.step, load: 0.8, deltaTime: 1.0 / 60)
        XCTAssertGreaterThan(heavy ?? 0, light ?? 1)
        // Held fast by the full pull, it creaks now and then.
        var stuck = JengaGrind()
        var creaks = 0
        for _ in 0..<60 where stuck.advance(by: 0, load: 1, deltaTime: 1.0 / 60) != nil {
            creaks += 1
        }
        XCTAssertEqual(creaks, Int(1 / JengaGrind.strainInterval))
        var resting = JengaGrind()
        for _ in 0..<60 { XCTAssertNil(resting.advance(by: 0, load: 0.2, deltaTime: 1.0 / 60)) }
    }

    func testTowerFallsOnlyWhenSeveralBlocksDrop() {
        XCTAssertFalse(JengaLayout.hasFallen(drops: [0, 0.01, 0.002]))
        XCTAssertFalse(JengaLayout.hasFallen(drops: [3, 2.5, 0, 0]))
        XCTAssertTrue(JengaLayout.hasFallen(drops: [3, 2.5, 1.2, 0]))
    }

    func testCameraFitsTheTowerBetweenTheBars() {
        // An iPhone-shaped view, 402 × 874 points, with bars of 116 and 83 points.
        let aspect: Float = 402.0 / 874
        let top: Float = 1 - 2 * 116.0 / 874
        let bottom: Float = -1 + 2 * 83.0 / 874
        // A rebuild keeps the reader's turn, so the fit holds at any yaw.
        for (height, width, yaw): (Float, Float, Float) in [
            (3.4, 2.25, JengaCamera.defaultYaw), (8, 2.4, 2.3), (0.2, 2.1, -1.1),
        ] {
            let camera = JengaCamera(
                fitting: height, width: width, aspect: aspect, top: top, bottom: bottom, yaw: yaw)
            XCTAssertEqual(camera.yaw, yaw)
            var low: Float = 1
            var high: Float = -1
            for corner in 0..<8 {
                let point = SIMD3<Float>(
                    corner & 1 == 0 ? -width / 2 : width / 2, corner & 2 == 0 ? 0 : height,
                    corner & 4 == 0 ? -width / 2 : width / 2)
                let ndc = camera.project(point, aspect: aspect)
                XCTAssertLessThanOrEqual(abs(ndc.x), 1)
                low = min(low, ndc.y)
                high = max(high, ndc.y)
            }
            XCTAssertGreaterThanOrEqual(low, bottom)
            XCTAssertLessThanOrEqual(high, top)
            // Fitted closely: the tower fills most of the room in one direction.
            let ndcs = (0..<8)
                .map { corner in
                    camera.project(
                        SIMD3(
                            corner & 1 == 0 ? -width / 2 : width / 2, corner & 2 == 0 ? 0 : height,
                            corner & 4 == 0 ? -width / 2 : width / 2), aspect: aspect)
                }
            let spread = max(
                (high - low) / (top - bottom),
                ((ndcs.map(\.x).max() ?? 0) - (ndcs.map(\.x).min() ?? 0)) / 2)
            XCTAssertGreaterThan(spread, 0.8)
            // The target shows in the middle of the room, at the height it marks.
            let center = camera.project(camera.target, aspect: aspect)
            XCTAssertEqual(center.y, (top + bottom) / 2, accuracy: 0.0001)
            XCTAssertEqual(
                camera.height(under: center, aspect: aspect) ?? 0, camera.target.y,
                accuracy: 0.001)
        }
    }
}
