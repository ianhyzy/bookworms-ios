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

    func testLayoutSharpensFewerBooksWithinTheTextureBudget() {
        for aspect in ShareAspect.allCases {
            var previous = CGFloat.infinity
            for count in [1, 2, 3, 6, 12, 40, 150] {
                let layout = PileSnapshotLayout(aspect: aspect, count: count)
                let scale = layout.textureScale
                XCTAssertTrue((1...5).contains(scale), "\(aspect) \(count)")
                XCTAssertLessThanOrEqual(scale, previous)
                previous = scale
                // Closer framing draws sharper textures, but never more texture memory than the
                // largest pile at a scale of 1.
                XCTAssertLessThanOrEqual(
                    CGFloat(count) * scale * scale, CGFloat(PileSnapshotRenderer.maximumBooks))
                // The pile rect lies below the heading and above the bottom margin.
                XCTAssertGreaterThan(layout.pileRect.minY, layout.pileTop)
                XCTAssertEqual(layout.pileRect.maxY, aspect.size.height - aspect.insets.bottom)
            }
        }
        XCTAssertEqual(PileSnapshotLayout(aspect: .story, count: 150).textureScale, 1)
    }

    func testFramingFitsSettledBooksInsideThePileRect() {
        let layout = PileSnapshotLayout(aspect: .story, count: 12)
        let zoomRange: ClosedRange<Float> = 0.25...5
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
            let camera = PileCamera()
                .framing(
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

    /// Framing starts from no particular view, so points that lie level with or behind the eye
    /// of a default camera still end up in front of the framed one: a pile far down the table,
    /// and books still in the air.
    func testFramingShowsPointsTheDefaultViewCannotSee() {
        let size = CGSize(width: 402, height: 874)
        let rect = CGRect(x: 16, y: 124, width: 370, height: 587)
        let onTheTable = stride(from: Float(40), through: 110, by: 5)
            .map { far -> [SIMD3<Float>] in
                [
                    [-10, 0, far - 40], [10, 0, far - 40], [-10, 0, far], [10, 0, far],
                    [-10, 3, far], [10, 3, far],
                ]
            }
        let inTheAir = stride(from: Float(10), through: 150, by: 20)
            .map { height -> [SIMD3<Float>] in
                [[-12, 0, -16], [12, 0, 40], [-8, height, 10], [8, height, 30]]
            }
        for points in onTheTable + inTheAir {
            let camera = PileCamera(yaw: 0.35)
                .framing(points, in: rect, of: size, zoomRange: 0.05...2.5)
            for point in points {
                let local = camera.rotation.inverse.act(point - camera.transform.translation)
                XCTAssertLessThan(local.z, 0, "\(point) lies behind the camera")
                let shown = pixel(camera, point, size)
                XCTAssertTrue(
                    rect.insetBy(dx: -1, dy: -1).contains(shown),
                    "\(point) shows at \(shown), out of \(rect)")
            }
        }
    }

    func testScaledTrayKeepsItsMiddle() {
        let tray = PileTray(farZ: -6, nearZ: 4, farHalfWidth: 5, nearHalfWidth: 3)
        let scaled = tray.scaled(by: 0.5)
        XCTAssertEqual(scaled.farZ + scaled.nearZ, tray.farZ + tray.nearZ, accuracy: 0.0001)
        XCTAssertEqual(scaled.area, tray.area * 0.25, accuracy: 0.0001)
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
        let (image, late) = try await PileSnapshotRenderer.render(
            books: books, title: "2025", aspect: .square, seed: 1, model: modelWithoutLibrary())
        // Books without covers have none to wait for, so none is late.
        XCTAssertEqual(late, [])
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

extension XCTestCase {
    /// A preview model that never loads a library, for renders of fictional books that must not
    /// depend on the test host's `AppModel.shared`. Its folder is removed when the test ends.
    @MainActor func modelWithoutLibrary() -> AppModel {
        let folder = URL.temporaryDirectory.appending(path: "bookworms-no-library-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return AppModel(previewFolder: folder)
    }
}
