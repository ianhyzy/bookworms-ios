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
            for count in [1, 6, 40, 150] {
                let layout = try XCTUnwrap(PileSnapshotLayout(aspect: aspect, count: count))
                XCTAssertTrue(PileCamera.zoomRange.contains(layout.camera.zoom))
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
                    let point = project(corner, camera: layout.camera, size: size)
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

    /// Projects a table point into the image's pixels, with y growing downward.
    private func project(_ point: SIMD3<Float>, camera: PileCamera, size: CGSize) -> CGPoint {
        let local = camera.rotation.inverse.act(point - camera.transform.translation)
        let slope = tan(PileCamera.fieldOfView / 2)
        let aspect = Float(size.width / size.height)
        let ndc = SIMD2(local.x / (-local.z * slope * aspect), local.y / (-local.z * slope))
        return CGPoint(
            x: CGFloat(ndc.x + 1) / 2 * size.width, y: CGFloat(1 - ndc.y) / 2 * size.height)
    }
}
