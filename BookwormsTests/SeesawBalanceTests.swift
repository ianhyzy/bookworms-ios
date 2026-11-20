import XCTest

@testable import Bookworms

final class SeesawBalanceTests: XCTestCase {
    private func book(_ id: Int, pages: Int?, finished: String = "2025-03-01", ratings: Int? = nil)
        -> CloudBook
    {
        var book = CloudBook(
            id: id, title: "Invented Title \(id)", author: "Imaginary Author",
            coverURL: nil, detailCoverURL: nil, pages: pages, finished: finished)
        book.ratingsCount = ratings
        return book
    }

    func testSidesWeighPagesAndCountUnknownPagesAsBookShapeDoes() {
        let balance = SeesawBalance(
            mine: [book(1, pages: 400), book(2, pages: nil)], theirs: [book(3, pages: 100)])
        XCTAssertEqual(balance.mine.pages, 400 + SeesawBalance.unknownPages)
        XCTAssertEqual(balance.theirs.pages, 100)
        XCTAssertEqual(balance.lean, .mine)
    }

    func testLeansTowardTheHeavierSideOrStaysLevel() {
        XCTAssertEqual(
            SeesawBalance(mine: [book(1, pages: 200)], theirs: [book(2, pages: 900)]).lean,
            .theirs)
        XCTAssertEqual(
            SeesawBalance(mine: [book(1, pages: 300)], theirs: [book(2, pages: 300)]).lean,
            .level)
        XCTAssertEqual(SeesawBalance(mine: [], theirs: []).lean, .level)
    }

    func testTiltGrowsWithTheDifferenceUpToTheMaximum() {
        func tilt(_ mine: Int, _ theirs: Int) -> Float {
            SeesawBalance(mine: [book(1, pages: mine)], theirs: [book(2, pages: theirs)])
                .tilt(arm: 4, radius: 4.5, plankPages: 2_000, maximum: 0.2)
        }
        XCTAssertEqual(tilt(500, 500), 0)
        XCTAssertGreaterThan(tilt(600, 500), 0)
        XCTAssertGreaterThan(tilt(900, 500), tilt(600, 500))
        // The tilt depends on the difference, not on which side is heavier.
        XCTAssertEqual(tilt(900, 500), tilt(500, 900))
        XCTAssertEqual(tilt(20_000, 100), 0.2)
    }

    func testFrameKeepsEachLibrarysBooksFinishedInItNewestFirst() {
        let balance = SeesawBalance(
            frame: .year(2025),
            mine: [
                book(1, pages: 100, finished: "2025-02-01"),
                book(2, pages: 100, finished: "2024-12-31"),
                book(3, pages: 100, finished: "2025-09-01"),
            ],
            theirs: [book(4, pages: 100, finished: "2026-01-02")])
        XCTAssertEqual(balance.mine.books.map(\.id), [3, 1])
        XCTAssertTrue(balance.theirs.books.isEmpty)
        XCTAssertEqual(balance.lean, .mine)
    }

    func testShownBooksAreTheMostPopularThenTheNewest() {
        let side = SeesawBalance.Side(books: [
            book(1, pages: 100, ratings: 5), book(2, pages: 100, ratings: 900),
            book(3, pages: 100), book(4, pages: 100, ratings: 5),
        ])
        XCTAssertEqual(side.shown(limit: 3).map(\.id), [2, 1, 4])
    }

    @MainActor
    func testTheHeavierEndRestsOnTheDeskAndNeverSinksIntoIt() {
        for base in [SeesawScene.Base.fulcrum, .rocker] {
            let heavy = SeesawBalance(mine: [book(1, pages: 50_000)], theirs: [])
            let pose = SeesawScene.plankPose(heavy, base: base)
            let corners = SeesawScene.plankCorners(pose)
            let lowest = corners.min { $0.y < $1.y }!
            XCTAssertEqual(lowest.y, 0, accuracy: 0.05, "\(base)")
            // The reader's end, on the left, is the one that dips.
            XCTAssertLessThan(lowest.x, 0, "\(base)")
            let level = SeesawScene.plankPose(SeesawBalance(mine: [], theirs: []), base: base)
            XCTAssertEqual(level.angle, 0)
            XCTAssertEqual(
                SeesawScene.plankCorners(level).map(\.y).min()!,
                SeesawScene.baseHeight, accuracy: 1e-4, "\(base)")
        }
    }

    @MainActor
    func testAFulcrumTipsAllTheWayAndARockerByTheDifference() {
        let close = SeesawBalance(mine: [book(1, pages: 1_050)], theirs: [book(2, pages: 1_000)])
        XCTAssertEqual(
            abs(SeesawScene.plankPose(close, base: .fulcrum).angle),
            SeesawScene.maximumTilt(base: .fulcrum))
        let rocking = abs(SeesawScene.plankPose(close, base: .rocker).angle)
        XCTAssertGreaterThan(rocking, 0)
        XCTAssertLessThan(rocking, SeesawScene.maximumTilt(base: .rocker) / 4)
    }
}
