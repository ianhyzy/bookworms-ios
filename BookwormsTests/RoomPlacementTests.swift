import RealityKit
import XCTest

@testable import Bookworms

final class RoomPlacementTests: XCTestCase {
    /// Fictional books from 150 to 750 pages, every fifth more popular than the rest.
    private static let books: [CloudBook] = (1...30)
        .map { index in
            CloudBook(
                id: 2_000 + index, title: "Fictional Book \(index)", author: "Author \(index)",
                coverURL: nil, detailCoverURL: nil, pages: 150 + (index * 113) % 600,
                ratingsCount: index % 5 == 0 ? 5_000 : index)
        }

    /// The root turns its books' spines (+z) toward the camera and scales decimeters to
    /// meters, so a 24 cm book draws 24 cm long.
    func testRootFacesTheCameraAtTrueSize() {
        let point = SIMD3<Float>(1, 0.75, -2)
        let camera = SIMD3<Float>(3, 1.6, -2)
        let root = RoomPlacement.root(at: point, facing: camera)
        XCTAssertEqual(root.scale, SIMD3(repeating: 0.1))
        XCTAssertEqual(root.translation, point)
        let spine = root.rotation.act([0, 0, 1])
        XCTAssertEqual(spine.x, 1, accuracy: 1e-5)
        XCTAssertEqual(spine.y, 0, accuracy: 1e-5)
        XCTAssertEqual(spine.z, 0, accuracy: 1e-5)
        let book = BookShape(size: [1.6, 2.4, 0.32], binding: .hardcover)
        let length = simd_length(root.matrix * SIMD4(0, book.size.y, 0, 0))
        XCTAssertEqual(length, 0.24, accuracy: 1e-5)
        // A camera straight above leaves the root unturned.
        XCTAssertEqual(
            RoomPlacement.root(at: point, facing: point + [0, 1, 0]).rotation.angle, 0,
            accuracy: 1e-6)
    }

    // MARK: Shelf probe

    /// Axis-aligned boxes, in meters, that stand in for the LiDAR scene mesh.
    private struct Room {
        var boxes: [(min: SIMD3<Float>, max: SIMD3<Float>)]

        func cast(_ origin: SIMD3<Float>, _ direction: SIMD3<Float>, _ length: Float) -> Float? {
            boxes.compactMap { box -> Float? in
                var near: Float = 0
                var far = length
                for axis in 0..<3 {
                    if abs(direction[axis]) < 1e-6 {
                        if origin[axis] < box.min[axis] || origin[axis] > box.max[axis] {
                            return nil
                        }
                        continue
                    }
                    var t0 = (box.min[axis] - origin[axis]) / direction[axis]
                    var t1 = (box.max[axis] - origin[axis]) / direction[axis]
                    if t0 > t1 { swap(&t0, &t1) }
                    near = max(near, t0)
                    far = min(far, t1)
                    if near > far { return nil }
                }
                return near
            }
            .min()
        }
    }

    /// A bookcase 80 cm wide inside, its board's top at 80 cm, its back 30 cm behind the
    /// board's front edge, and the next board 30 cm above.
    private static let bookcase = Room(boxes: [
        ([-0.45, 0.78, -0.32], [0.45, 0.80, 0]),  // the board
        ([-0.45, 1.10, -0.32], [0.45, 1.12, 0]),  // the board above
        ([-0.45, 0.6, -0.34], [0.45, 1.3, -0.32]),  // the back
        ([-0.45, 0.6, -0.34], [-0.40, 1.3, 0]),  // the left side panel
        ([0.40, 0.6, -0.34], [0.45, 1.3, 0]),  // the right side panel
    ])

    func testProbeMeasuresTheSpaceBetweenThePanels() throws {
        let camera = SIMD3<Float>(0.1, 1.2, 1.5)
        let found = try XCTUnwrap(
            ShelfProbe.measure(at: [0.1, 0.8, -0.1], from: camera, cast: Self.bookcase.cast))
        // 80 cm, less at most one step at each end.
        XCTAssertEqual(found.space.width, 8, accuracy: 0.8)
        XCTAssertLessThanOrEqual(found.space.width, 8)
        XCTAssertEqual(found.space.clearance, 3, accuracy: 0.01)
        // The frame starts at the left panel, where the board meets the back, and faces out.
        XCTAssertEqual(found.frame.translation.x, -0.4, accuracy: 0.041)
        XCTAssertEqual(found.frame.translation.y, 0.8, accuracy: 1e-5)
        XCTAssertEqual(found.frame.translation.z, -0.32, accuracy: 0.01)
        let out = found.frame.rotation.act([0, 0, 1])
        XCTAssertEqual(out.z, 1, accuracy: 1e-5)
        let along = found.frame.rotation.act([1, 0, 0])
        XCTAssertEqual(along.x, 1, accuracy: 1e-5)
    }

    /// A shelf with no side panels ends where its board ends, so no book stands over air, and
    /// one with nothing above has room for any book.
    func testProbeStopsWhereTheBoardEnds() throws {
        let wallShelf = Room(boxes: [
            ([-0.3, 0.78, -0.25], [0.5, 0.80, 0]),
            ([-1, 0, -0.27], [1, 2, -0.25]),
        ])
        let found = try XCTUnwrap(
            ShelfProbe.measure(at: [0, 0.8, -0.1], from: [0, 1.4, 1.2], cast: wallShelf.cast))
        XCTAssertEqual(found.space.width, 8, accuracy: 0.8)
        XCTAssertLessThanOrEqual(found.space.width, 8)
        XCTAssertEqual(found.space.clearance, .infinity)
    }

    func testProbeNeedsABack() {
        let table = Room(boxes: [([-0.6, 0.73, -0.4], [0.6, 0.75, 0.4])])
        XCTAssertNil(ShelfProbe.measure(at: [0, 0.75, 0], from: [0, 1.4, 1.2], cast: table.cast))
    }

    // MARK: Shelf fill

    func testFillStandsBooksInsideTheSpaceAndEndsWithAFlatBookend() {
        let space = ShelfSpace(width: 6, clearance: 3)
        let fill = ShelfFill(books: Self.books, space: space, seed: 7)
        XCTAssertFalse(fill.slots.isEmpty)
        XCTAssertLessThanOrEqual(fill.width, space.width)
        let standing = fill.slots.dropLast(ShelfFill.bookendCount)
        let lying = fill.slots.suffix(ShelfFill.bookendCount)
        var edge: Float = 0
        for slot in standing {
            // Upright, head up, spine toward the room, each against the last.
            XCTAssertEqual(slot.transform.rotation.act([0, 1, 0]).y, 1, accuracy: 1e-5)
            XCTAssertEqual(slot.transform.rotation.act([-1, 0, 0]).z, 1, accuracy: 1e-5)
            XCTAssertEqual(
                slot.transform.translation.x - slot.shape.size.z / 2, edge, accuracy: 1e-4)
            XCTAssertEqual(slot.transform.translation.y, slot.shape.size.y / 2, accuracy: 1e-5)
            XCTAssertLessThanOrEqual(slot.shape.size.y, space.clearance)
            edge += slot.shape.size.z
        }
        // The bookend lies flat, each book on the one below, past the standing row.
        var top: Float = 0
        for slot in lying {
            XCTAssertEqual(slot.transform.rotation.act([0, 0, 1]).y, 1, accuracy: 1e-5)
            XCTAssertEqual(
                slot.transform.translation.y - slot.shape.size.z / 2, top, accuracy: 1e-5)
            XCTAssertGreaterThan(slot.transform.translation.x - slot.shape.size.y / 2, edge - 0.1)
            top += slot.shape.size.z
        }
        // The shelf keeps the books' finishing order among the standing books.
        let order = standing.map(\.book.id)
        XCTAssertEqual(order, order.sorted())
    }

    /// A short shelf shows the most popular books that fit, and a low one leaves out books too
    /// tall to stand in it.
    func testFillKeepsPopularBooksThatFit() {
        let narrow = ShelfFill(
            books: Self.books, space: ShelfSpace(width: 4, clearance: 3), seed: 7)
        let wide = ShelfFill(books: Self.books, space: ShelfSpace(width: 40, clearance: 3), seed: 7)
        XCTAssertLessThan(narrow.slots.count, wide.slots.count)
        let shown = Set(narrow.slots.map(\.book.id))
        let popular = Self.books.filter { ($0.ratingsCount ?? 0) >= 5_000 }.map(\.id)
        XCTAssertTrue(popular.allSatisfy(shown.contains), "\(shown)")
        let low = ShelfFill(books: Self.books, space: ShelfSpace(width: 40, clearance: 2), seed: 7)
        for slot in low.slots.dropLast(ShelfFill.bookendCount) {
            XCTAssertLessThanOrEqual(slot.shape.size.y, 2)
        }
        XCTAssertLessThan(low.slots.count, wide.slots.count)
        XCTAssertLessThanOrEqual(wide.slots.count, RoomPlacement.maximumBooks)
    }

    /// Three books or fewer lie flat as one small stack.
    func testFewBooksLieFlat() {
        let fill = ShelfFill(
            books: Array(Self.books.prefix(2)), space: ShelfSpace(width: 6, clearance: 3), seed: 1)
        XCTAssertEqual(fill.slots.count, 2)
        for slot in fill.slots {
            XCTAssertEqual(slot.transform.rotation.act([0, 0, 1]).y, 1, accuracy: 1e-5)
        }
    }

    #if os(iOS)
        func testBandLinesUseTheRegionsUnits() {
            let metric = Locale(identifier: "en_GB")
            let us = Locale(identifier: "en_US")
            // Formatters join a number and its unit with a no-break space.
            func plain(_ text: String) -> String {
                text.replacing("\u{00A0}", with: " ").replacing("\u{202F}", with: " ")
            }
            XCTAssertEqual(
                plain(RoomPhoto.line(count: 11, stackHeight: 3.2, locale: metric)),
                "11 books, 32 cm tall")
            XCTAssertEqual(
                plain(RoomPhoto.line(count: 11, stackHeight: 3.2, locale: us)),
                "11 books, 1 ft 1 in tall")
            XCTAssertEqual(
                plain(RoomPhoto.line(count: 1, shelfWidth: 0.4, locale: metric)),
                "1 book, 4 cm of shelf")
            XCTAssertEqual(
                plain(RoomPhoto.line(count: 14, shelfWidth: 5.4, locale: us)),
                "14 books, 1 ft 9 in of shelf")
        }

        /// The framed part of the screen has the share image's photo shape and fills the width.
        func testFramingMatchesThePhoto() {
            let screen = CGSize(width: 402, height: 874)
            for aspect in ShareAspect.allCases {
                let rect = RoomPhoto.photoRect(in: screen, aspect: aspect)
                let photo = CGSize(
                    width: aspect.size.width,
                    height: aspect.size.height - RoomPhoto.bandHeight(aspect))
                XCTAssertEqual(rect.width / rect.height, photo.width / photo.height, accuracy: 1e-6)
                XCTAssertEqual(rect.width, screen.width, accuracy: 1e-6)
                XCTAssertEqual(rect.midY, screen.height / 2, accuracy: 1e-6)
            }
        }
    #endif
}
