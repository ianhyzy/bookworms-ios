import RealityKit
import XCTest

@testable import Bookworms

final class PileShapeTests: XCTestCase {
    /// An iPhone-shaped view's tray, 402 × 874 points, with bars of 116 and 83 points.
    private static let tray = PileTray(
        aspect: 402.0 / 874, safeTop: 1 - 2 * 116.0 / 874, safeBottom: -1 + 2 * 83.0 / 874)!

    /// The sizes of `count` fictional books from 90 to 1,200 pages.
    private func sizes(_ count: Int) -> [SIMD3<Float>] {
        (1...count)
            .map { index in
                BookShape(
                    of: CloudBook(
                        id: 2_000 + index, title: "Fictional Book \(index)",
                        author: "Author \(index)", coverURL: nil, detailCoverURL: nil,
                        pages: 90 + (index * 263) % 1_110),
                    coverAspect: 2 / 3
                )
                .size
            }
    }

    /// Every book has a place, and in it touches no other book and rests on the table or on a
    /// book placed before it, so no book floats and each lands after the books under it.
    func testEveryShapeLaysEveryBookFlatOnWhatIsUnderIt() {
        for shape in PileShape.allCases {
            for count in [1, 7, 40, 300] {
                let sizes = sizes(count)
                let places = shape.places(for: sizes, in: Self.tray)
                XCTAssertEqual(places.map(\.book).sorted(), Array(sizes.indices), "\(shape) \(count)")
                let boxes = places.map { DominoSetup.Box($0.pose, size: sizes[$0.book]) }
                for (index, box) in boxes.enumerated() {
                    // Lying flat: front cover up.
                    XCTAssertTrue(PileLayout.isCoverUp(places[index].pose.rotation))
                    for other in boxes[..<index] {
                        XCTAssertFalse(
                            box.moved(by: [0, 0.001, 0]).overlaps(other),
                            "\(shape) \(count): \(index) overlaps")
                    }
                    let onTable = box.bounds.low.y < 0.01
                    let onBook = boxes[..<index].contains { box.moved(by: [0, -0.01, 0]).overlaps($0) }
                    XCTAssertTrue(onTable || onBook, "\(shape) \(count): \(index) floats")
                }
            }
        }
    }

    /// A shape is about as wide, deep, and high as its name says.
    func testTheShapesLookTheirPart() throws {
        let sizes = sizes(40)
        func extent(_ shape: PileShape) -> SIMD3<Float> {
            let bounds = shape.places(for: sizes, in: Self.tray)
                .map { DominoSetup.Box($0.pose, size: sizes[$0.book]).bounds }
            let low = bounds.map(\.low).reduce(SIMD3(repeating: .infinity)) { simd_min($0, $1) }
            let high = bounds.map(\.high).reduce(SIMD3(repeating: -.infinity)) { simd_max($0, $1) }
            return high - low
        }
        let cube = extent(.cube)
        XCTAssertLessThan(cube.max() / cube.min(), 2.2, "\(cube)")
        let wall = extent(.wall)
        XCTAssertGreaterThan(wall.x, 2 * wall.z, "\(wall)")
        XCTAssertGreaterThan(wall.y, wall.z, "\(wall)")
        // A pyramid's top course is narrower than its base.
        let pyramid = PileShape.pyramid.courses(
            count: 40, size: [1.4, 2.1, 0.25], width: 8, depth: 8, height: 4.5)
        let first = try XCTUnwrap(pyramid.first)
        let last = try XCTUnwrap(pyramid.last)
        XCTAssertLessThan(last.count, first.count)
    }

    /// Flying into a shape, every book lands in its place, none held in the air as the
    /// dominoes' last book is.
    func testEveryBookLandsWhenNoneIsHeld() {
        let sizes = sizes(12)
        let places = PileShape.cube.places(for: sizes, in: Self.tray)
        let hops = places.enumerated()
            .map { order, place in
                (
                    from: Transform(
                        rotation: PileLayout.lyingFlat,
                        translation: [Float(order % 4) * 3 - 4.5, sizes[place.book].z / 2, Float(order / 4) * 2.4 - 2]),
                    to: place.pose, size: sizes[place.book]
                )
            }
        let gather = DominoFinale.Gather(hops, budget: DominoFinale.gatherBudget, holdsLast: false)
        XCTAssertEqual(gather.flights.count, hops.count)
        for (flight, hop) in zip(gather.flights, hops) {
            XCTAssertTrue(flight.landing.isFinite)
            XCTAssertEqual(flight.pose(at: flight.landing + 0.01).translation, hop.to.translation)
        }
    }
}
