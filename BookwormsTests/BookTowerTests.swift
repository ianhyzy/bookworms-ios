import RealityKit
import XCTest

@testable import Bookworms

final class BookTowerTests: XCTestCase {
    /// Fictional books, oldest first, with page counts from 100 to 1,000 and a Hardcover rating
    /// count that `ratings` gives each.
    private func books(_ count: Int, ratings: (Int) -> Int = { $0 }) -> [CloudBook] {
        (1...count)
            .map { id in
                var book = CloudBook(
                    id: id, title: "Fictional Book \(id)", author: "Author \(id)", coverURL: nil,
                    detailCoverURL: nil, pages: 100 + id * 37 % 900, finished: "2025-01-01")
                book.ratingsCount = ratings(id)
                return book
            }
    }

    func testBooksStackFlatOnOneAnotherAtTheirRealThickness() {
        let books = books(30)
        let tower = BookTower(books: books, seed: 7)
        let thickness = books.map { BookShape(of: $0, coverAspect: 2 / 3).size.z }
        XCTAssertEqual(tower.slots.map(\.book.id), books.map(\.id))
        XCTAssertEqual(tower.height, thickness.reduce(0, +), accuracy: 1e-4)
        XCTAssertEqual(tower.stackHeight, tower.height, accuracy: 1e-4)
        XCTAssertEqual(tower.count, 30)
        XCTAssertEqual(tower.pages, books.reduce(0) { $0 + ($1.pages ?? 0) })
        var top: Float = 0
        for (slot, thickness) in zip(tower.slots, thickness) {
            // Each book rests on the one below it, with no gap or overlap.
            XCTAssertEqual(slot.transform.translation.y - thickness / 2, top, accuracy: 1e-4)
            top += thickness
            // Its front cover faces straight up: it lies level, tilted in no direction.
            XCTAssertEqual(slot.transform.rotation.act([0, 0, 1]).y, 1, accuracy: 1e-5)
            // A small shift, and a turn of a few degrees about the vertical axis.
            XCTAssertLessThanOrEqual(abs(slot.transform.translation.x), BookTower.maximumShift)
            XCTAssertLessThanOrEqual(abs(slot.transform.translation.z), BookTower.maximumShift)
            let spine = slot.transform.rotation.act([-1, 0, 0])
            XCTAssertLessThanOrEqual(
                abs(atan2(spine.x, spine.z)), Float(BookTower.maximumTwist) + 1e-4)
        }
    }

    func testTheTowerMeasuresAndStacksTheShapesItIsGiven() {
        let books = books(5)
        let shape = BookShape(size: [1.6, 2.4, 0.3], binding: .hardcover)
        let tower = BookTower(books: books, seed: 2) { _ in shape }
        XCTAssertEqual(tower.height, 1.5, accuracy: 1e-4)
        XCTAssertEqual(tower.stackHeight, 1.5, accuracy: 1e-4)
        XCTAssertEqual(tower.slots.map(\.shape), Array(repeating: shape, count: 5))
    }

    func testTheSameBooksAndSeedStackTheSameTower() {
        let books = books(12)
        let poses = { (seed: UInt64) in
            BookTower(books: books, seed: seed).slots.map(\.transform.translation)
        }
        XCTAssertEqual(poses(3), poses(3))
        XCTAssertNotEqual(poses(3), poses(4))
    }

    func testALargeFrameStacksItsMostPopularBooksAndMeasuresEveryBook() {
        // The newest books are the most popular, so the cap keeps the last 150, in order.
        let books = books(BookTower.maximumBooks + 20) { $0 * 10 }
        let tower = BookTower(books: books, seed: 1)
        XCTAssertEqual(tower.slots.map(\.book.id), Array(21...(BookTower.maximumBooks + 20)))
        XCTAssertEqual(tower.count, BookTower.maximumBooks + 20)
        XCTAssertEqual(
            tower.height, books.reduce(0) { $0 + BookShape(of: $1, coverAspect: 2 / 3).size.z },
            accuracy: 1e-3)
        XCTAssertLessThan(tower.stackHeight, tower.height)
        // Up to the cap, every book stacks.
        XCTAssertEqual(BookTower(books: Array(books.prefix(40)), seed: 1).slots.count, 40)
    }

    func testHeightReadsInTheReadersUnits() {
        let space = "\u{00A0}"
        let us = Locale(identifier: "en_US")
        let metric = Locale(identifier: "en_GB")
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(BookTower.heightText(3.5, locale: us), "1\(space)ft\(space)2\(space)in")
        XCTAssertEqual(BookTower.heightText(0.254, locale: us), "1\(space)in")
        XCTAssertEqual(BookTower.heightText(3.048, locale: us), "1\(space)ft")
        XCTAssertEqual(BookTower.heightText(3.5, locale: metric), "35\(space)cm")
        XCTAssertEqual(BookTower.heightText(12.6, locale: metric), "1.26\(space)m")
        XCTAssertEqual(BookTower.heightText(312, locale: metric), "31.2\(space)m")
        XCTAssertEqual(BookTower.heightText(12.6, locale: german), "1,26\(space)m")
    }

    func testTheClipLoopsBackToTheStill() {
        let last = TowerMovieTiming.frameCount - 1
        let recorded = TowerMovieTiming.hold + TowerMovieTiming.fall
        XCTAssertEqual(TowerMovieTiming.source(of: 0), 0)
        XCTAssertEqual(TowerMovieTiming.source(of: recorded - 1), recorded - 1)
        // The fallen books hold on the fall's last frame, then the clip rewinds to the still.
        XCTAssertEqual(
            TowerMovieTiming.source(of: recorded + TowerMovieTiming.rest - 1), recorded - 1)
        XCTAssertEqual(TowerMovieTiming.source(of: last), 0)
        let rewind = (recorded..<TowerMovieTiming.frameCount).map(TowerMovieTiming.source(of:))
        XCTAssertEqual(rewind, rewind.sorted(by: >))
        // The loupe shows on the still, fades out at the push, and is back by the last frame.
        XCTAssertEqual(TowerMovieTiming.loupeOpacity(at: 0), 1)
        XCTAssertEqual(
            TowerMovieTiming.loupeOpacity(at: TowerMovieTiming.hold + TowerMovieTiming.fade), 0)
        XCTAssertEqual(TowerMovieTiming.loupeOpacity(at: last), 1)
        // The tape is out on the still and back in its case once it retracts.
        XCTAssertEqual(TowerMovieTiming.tapeOut(at: 0), 1)
        XCTAssertEqual(
            TowerMovieTiming.tapeOut(at: TowerMovieTiming.hold + TowerMovieTiming.retract), 0)
    }

    func testATowerStandsBesideTheClosestFigurePreferringATallerOne() {
        XCTAssertNil(TowerFigure.closest(to: 0.1))
        XCTAssertEqual(TowerFigure.closest(to: 0.2)?.name, "cat")
        XCTAssertEqual(TowerFigure.closest(to: 0.8), TowerFigure.person)
        XCTAssertEqual(TowerFigure.closest(to: 1.9), TowerFigure.person)
        XCTAssertEqual(TowerFigure.closest(to: 8.1)?.name, "house")
        // Between the windmill and the castle tower, the taller one wins at the middle.
        XCTAssertEqual(TowerFigure.closest(to: 15.5)?.name, "castletower")
        XCTAssertEqual(TowerFigure.closest(to: 200)?.name, "lighthouse")
        // The ladder runs shortest first, so the pick never skips a figure.
        let heights = TowerFigure.ladder.map(\.meters)
        XCTAssertEqual(heights, heights.sorted())
    }

    func testTheLineComparesTheTowerWithItsFigure() {
        let windmill = TowerFigure.ladder.first { $0.name == "windmill" }!
        XCTAssertEqual(windmill.comparison(to: 13), "Taller than a windmill")
        XCTAssertEqual(windmill.comparison(to: 12.2), "As tall as a windmill")
        XCTAssertEqual(windmill.comparison(to: 9), "Almost as tall as a windmill")
        let ian = TowerFigure.person
        XCTAssertEqual(ian.comparison(to: 0.6), "Up to Ian's knees")
        XCTAssertEqual(ian.comparison(to: 0.79), "Up to Ian's thighs")
        XCTAssertEqual(ian.comparison(to: 1.37), "Up to Ian's chest")
        XCTAssertEqual(ian.comparison(to: 1.8), "As tall as Ian")
        // The shortest tower that stands beside Ian rather than the cat still names a landmark.
        XCTAssertEqual(TowerFigure.closest(to: 0.49), ian)
        XCTAssertEqual(ian.comparison(to: 0.49), "Up to Ian's shins")
    }

    func testEveryFigureButThePersonShipsAModel() {
        for figure in TowerFigure.ladder where figure != TowerFigure.person {
            XCTAssertNotNil(
                Bundle(for: AppModel.self)
                    .url(
                        forResource: "figure-\(figure.name)", withExtension: "usdz"), figure.name)
        }
    }
}
