import RealityKit
import XCTest

@testable import Bookworms

final class PileSnapshotTests: XCTestCase {
    /// Fictional books finished across 2024 and 2025, newest first as the shelf lists them, and
    /// one unfinished book.
    private static let books: [CloudBook] =
        [
            ("2025-11-20", 1), ("2025-11-02", 2), ("2025-08-15", 3), ("2025-01-09", 4),
            ("2024-12-31", 5), ("2024-03-02", 6),
        ]
        .map { finished, id in
            CloudBook(
                id: id, title: "Fictional Book \(id)", author: "Author \(id)", coverURL: nil,
                detailCoverURL: nil, pages: 150 + id * 90, finished: finished)
        } + [
            CloudBook(
                id: 7, title: "Unfinished Book", author: "Author 7", coverURL: nil,
                detailCoverURL: nil)
        ]

    func testSettingsRoundTrip() {
        for frame in [TimeFrame.year(2025), .month(year: 2025, month: 8), .lifetime] {
            XCTAssertEqual(TimeFrame(setting: frame.setting), frame)
        }
        XCTAssertEqual(TimeFrame(setting: "month:2025-8"), .month(year: 2025, month: 8))
        for invalid in [
            "", "all", "year:", "year:twenty", "month:2025", "month:2025-13", "lifetime:1",
        ] {
            XCTAssertNil(TimeFrame(setting: invalid), invalid)
        }
    }

    func testSavedFrameFallsBackToTheNewestOfItsKind() {
        let books = Self.books
        XCTAssertNil(TimeFrame.pileFrame(setting: "", in: books))
        // No menu saves "lifetime"; a launch argument that does gets every book.
        XCTAssertNil(TimeFrame.pileFrame(setting: "lifetime", in: books))
        XCTAssertEqual(TimeFrame.pileFrame(setting: "year:2024", in: books), .year(2024))
        XCTAssertEqual(
            TimeFrame.pileFrame(setting: "month:2025-8", in: books), .month(year: 2025, month: 8))
        // A year or month without finished books gives way to the newest one.
        XCTAssertEqual(TimeFrame.pileFrame(setting: "year:2019", in: books), .year(2025))
        XCTAssertEqual(
            TimeFrame.pileFrame(setting: "month:2025-7", in: books), .month(year: 2025, month: 11))
        // With no finished books, the pile shows every book.
        XCTAssertNil(TimeFrame.pileFrame(setting: "year:2025", in: [books[6]]))
    }

    func testEachFrameDropsItsOwnBooksInShelfOrderAndRepeatably() {
        let tray = PileTray(
            viewport: PileViewport(size: CGSize(width: 402, height: 874), insets: .init()))!
        let cases: [(TimeFrame, [Int])] = [
            (.year(2025), [1, 2, 3, 4]), (.year(2024), [5, 6]),
            (.month(year: 2025, month: 11), [1, 2]), (.lifetime, [1, 2, 3, 4, 5, 6]),
        ]
        for (frame, ids) in cases {
            let books = Self.books.filter(frame.contains)
            XCTAssertEqual(books.map(\.id), ids, frame.title)
            let plan = PileLayout.dropPlan(books, in: tray, seed: 9)
            XCTAssertEqual(plan.map(\.book.id), ids)
            XCTAssertEqual(
                plan.map(\.transform),
                PileLayout.dropPlan(books, in: tray, seed: 9).map(\.transform))
        }
    }

    func testLayoutFramesFewerBooksCloserWithinTheTextureBudget() throws {
        for aspect in ShareAspect.allCases {
            var previousZoom = Float.infinity
            for count in [1, 2, 3, 6, 12, 40, 150] {
                let layout = try XCTUnwrap(PileSnapshotLayout(aspect: aspect, count: count))
                XCTAssertTrue(PileSnapshotLayout.zoomRange.contains(layout.camera.zoom))
                XCTAssertLessThanOrEqual(layout.camera.zoom, previousZoom)
                previousZoom = layout.camera.zoom
                // Closer framing draws sharper textures, but never more texture memory than the
                // largest pile at the view's size.
                let scale = Float(layout.textureScale)
                XCTAssertLessThanOrEqual(
                    Float(count) * scale * scale, Float(PileSnapshotRenderer.maximumBooks))
                // The tray lies below the heading and above the bottom margin.
                let size = aspect.size
                for corner in layout.tray.corners {
                    let point = pixel(layout.camera, corner, size)
                    XCTAssertGreaterThan(point.y, layout.pileTop - 1, "\(aspect) \(count)")
                    XCTAssertLessThan(point.y, size.height - aspect.insets.bottom + 1)
                    XCTAssertTrue((-1...size.width + 1).contains(point.x))
                }
            }
        }
        // The camera zooms out until the tray holds about `areaPerBook` per book.
        let crowded = try XCTUnwrap(PileSnapshotLayout(aspect: .story, count: 40))
        XCTAssertLessThanOrEqual(crowded.tray.area, 40 * PileSnapshotLayout.areaPerBook + 5)
    }

    func testFramingFitsSettledBooksInsideThePileRect() throws {
        let layout = try XCTUnwrap(PileSnapshotLayout(aspect: .story, count: 12))
        let zoomRange: ClosedRange<Float> = 0.25...layout.camera.zoom * 1.25
        let rect = layout.pileRect
        // Book-sized boxes: a heap off to one side, a pile spread past the tray, and one book.
        func boxes(_ centers: [SIMD3<Float>]) -> [SIMD3<Float>] {
            centers.flatMap { center in
                (0..<8)
                    .map { corner in
                        center
                            + SIMD3(
                                corner & 1 == 0 ? -0.8 : 0.8, corner & 2 == 0 ? -0.2 : 0.2,
                                corner & 4 == 0 ? -1.1 : 1.1)
                    }
            }
        }
        let heap = (0..<12).map { SIMD3<Float>(3 + Float($0 % 3), 0.2 * Float($0 / 3), 2) }
        let spread = (0..<12)
            .map { SIMD3<Float>(Float($0 % 4) * 4 - 6, 0.2, Float($0 / 4) * 4 - 6) }
        for points in [boxes(heap), boxes(spread), boxes([[2, 0.2, -1]])] {
            let camera = layout.camera.framing(
                points, in: rect, of: layout.aspect.size, zoomRange: zoomRange)
            XCTAssertTrue(zoomRange.contains(camera.zoom))
            let pixels = points.map { pixel(camera, $0, layout.aspect.size) }
            let low = CGPoint(x: pixels.map(\.x).min()!, y: pixels.map(\.y).min()!)
            let high = CGPoint(x: pixels.map(\.x).max()!, y: pixels.map(\.y).max()!)
            XCTAssertGreaterThanOrEqual(low.x, rect.minX - 1)
            XCTAssertGreaterThanOrEqual(low.y, rect.minY - 1)
            XCTAssertLessThanOrEqual(high.x, rect.maxX + 1)
            XCTAssertLessThanOrEqual(high.y, rect.maxY + 1)
            // Centered, and as large as the zoom allows.
            XCTAssertEqual((low.x + high.x) / 2, rect.midX, accuracy: 8)
            XCTAssertEqual((low.y + high.y) / 2, rect.midY, accuracy: 8)
            if camera.zoom < zoomRange.upperBound {
                let fill = max((high.x - low.x) / rect.width, (high.y - low.y) / rect.height)
                XCTAssertGreaterThan(fill, 0.9)
            }
        }
    }

    func testScaledTrayKeepsItsMiddle() {
        let tray = PileTray(farZ: -6, nearZ: 4, farHalfWidth: 5, nearHalfWidth: 3)
        let scaled = tray.scaled(by: 0.5)
        XCTAssertEqual(scaled.farZ + scaled.nearZ, tray.farZ + tray.nearZ, accuracy: 0.0001)
        XCTAssertEqual(scaled.area, tray.area * 0.25, accuracy: 0.0001)
        // Grown until its narrower near edge spans 8 units; a tray that already does stays.
        let grown = tray.scaled(toFit: 8)
        XCTAssertEqual(grown.nearHalfWidth * 2, 8, accuracy: 0.0001)
        XCTAssertEqual(grown.farZ + grown.nearZ, tray.farZ + tray.nearZ, accuracy: 0.0001)
        XCTAssertEqual(tray.scaled(toFit: 4), tray)
    }

    func testBlankFramesAreDetected() {
        let (width, height, bytesPerRow) = (64, 64, 256)
        var pixels = Data(repeating: 90, count: bytesPerRow * height)
        XCTAssertTrue(
            PileSnapshotRenderer.isBlank(
                pixels, width: width, height: height, bytesPerRow: bytesPerRow))
        pixels[(height / 2) * bytesPerRow + (width / 2) * 4 + 1] = 200
        XCTAssertFalse(
            PileSnapshotRenderer.isBlank(
                pixels, width: width, height: height, bytesPerRow: bytesPerRow))
    }

    /// Drops fictional books without covers or designs, so the render needs no network.
    @MainActor
    func testRendererDrawsANonBlankImageAtTheShareSize() async throws {
        let books = Array(Self.books.prefix(4))
        let image = try await PileSnapshotRenderer.render(
            books: books, title: "2025", aspect: .square, seed: 1, model: .shared)
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.width, 1080)
        XCTAssertEqual(cgImage.height, 1080)
        // `render` throws when the 3D frame is one flat color; the finished card varies too.
        let data = try XCTUnwrap(cgImage.dataProvider?.data as Data?)
        XCTAssertFalse(
            PileSnapshotRenderer.isBlank(
                data, width: cgImage.width, height: cgImage.height,
                bytesPerRow: cgImage.bytesPerRow))
    }

    /// Where `camera` shows a scene point in an image of `size`, in pixels with y growing downward.
    private func pixel(_ camera: PileCamera, _ point: SIMD3<Float>, _ size: CGSize) -> CGPoint {
        let ndc = camera.project(point, aspect: Float(size.width / size.height))
        return CGPoint(
            x: CGFloat(ndc.x + 1) / 2 * size.width, y: CGFloat(1 - ndc.y) / 2 * size.height)
    }
}
