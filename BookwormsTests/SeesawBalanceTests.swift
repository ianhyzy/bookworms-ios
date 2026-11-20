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
        for (mine, theirs) in [(5_000, 100), (100, 5_000), (101, 100)] {
            let balance = SeesawBalance(
                mine: [book(1, pages: mine)], theirs: [book(2, pages: theirs)])
            let corners = SeesawScene.plankCorners(SeesawScene.plankPose(balance))
            let lowest = corners.min { $0.y < $1.y }!
            // Like a playground seesaw, a single page tips it all the way.
            XCTAssertEqual(lowest.y, 0, accuracy: 1e-3)
            XCTAssertEqual(lowest.x < 0, mine > theirs)
        }
    }

    @MainActor
    func testAnEvenBalanceStaysLevelOnTheFulcrum() {
        let pose = SeesawScene.plankPose(SeesawBalance(mine: [], theirs: []))
        XCTAssertEqual(pose.angle, 0)
        XCTAssertEqual(
            SeesawScene.plankCorners(pose).map(\.y).min()!, SeesawScene.baseHeight,
            accuracy: 1e-4)
    }
}
