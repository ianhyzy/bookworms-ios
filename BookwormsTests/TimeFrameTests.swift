import XCTest

@testable import Bookworms

final class TimeFrameTests: XCTestCase {
    private func book(_ id: Int, _ finished: String?) -> CloudBook {
        CloudBook(
            id: id, title: "Book \(id)", author: "Author", coverURL: nil, detailCoverURL: nil,
            finished: finished)
    }

    func testMembershipUsesTheRecordedCalendarDay() {
        let newYearsEve = book(1, "2025-12-31")
        XCTAssertTrue(TimeFrame.year(2025).contains(newYearsEve))
        XCTAssertFalse(TimeFrame.year(2026).contains(newYearsEve))
        XCTAssertTrue(TimeFrame.month(year: 2025, month: 12).contains(newYearsEve))
        XCTAssertFalse(TimeFrame.month(year: 2025, month: 11).contains(newYearsEve))
        XCTAssertTrue(TimeFrame.lifetime.contains(newYearsEve))
        XCTAssertFalse(TimeFrame.lifetime.contains(book(2, nil)))
    }

    func testPeriodsListNewestFirstWithoutDuplicates() {
        let books = [
            book(1, "2024-03-02"), book(2, "2025-08-01"), book(3, "2025-08-20"),
            book(4, "2025-01-09"), book(5, nil),
        ]
        let periods = TimeFrame.periods(in: books)
        XCTAssertEqual(periods.years, [2025, 2024])
        XCTAssertEqual(
            periods.months,
            [
                .month(year: 2025, month: 8), .month(year: 2025, month: 1),
                .month(year: 2024, month: 3),
            ])
    }

    func testRereadsBelongToEveryFrameTheyWereFinishedIn() {
        var reread = book(1, "2026-04-01")
        reread.finishedDates = ["2026-04-01", "2024-08-15", "not a date"]
        XCTAssertTrue(TimeFrame.year(2024).contains(reread))
        XCTAssertTrue(TimeFrame.month(year: 2026, month: 4).contains(reread))
        XCTAssertFalse(TimeFrame.year(2025).contains(reread))
        XCTAssertEqual(TimeFrame.year(2024).books(in: [reread]).first?.finished, "2024-08-15")
        XCTAssertEqual(TimeFrame.lifetime.books(in: [reread]).first?.finished, "2026-04-01")
        let periods = TimeFrame.periods(in: [reread])
        XCTAssertEqual(periods.years, [2026, 2024])
        XCTAssertEqual(
            periods.months, [.month(year: 2026, month: 4), .month(year: 2024, month: 8)])
        // The first read dates the reader's copy, whatever frame shows it.
        XCTAssertEqual(reread.firstFinish, "2024-08-15")
        XCTAssertEqual(reread.readCount, 3)
        XCTAssertEqual(book(2, "2025-01-01").readCount, 1)
        XCTAssertEqual(book(3, nil).readCount, 0)
    }

    func testTitles() {
        XCTAssertEqual(TimeFrame.year(2025).title, "2025")
        XCTAssertEqual(TimeFrame.lifetime.title, "Lifetime")
        XCTAssertTrue(TimeFrame.month(year: 2025, month: 8).title.contains("2025"))
    }
}
