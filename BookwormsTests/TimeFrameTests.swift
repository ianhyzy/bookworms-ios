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

    func testTitles() {
        XCTAssertEqual(TimeFrame.year(2025).title, "2025")
        XCTAssertEqual(TimeFrame.lifetime.title, "Lifetime")
        XCTAssertTrue(TimeFrame.month(year: 2025, month: 8).title.contains("2025"))
    }
}
