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

    func testLast12MonthsReachBackFromTodayAsTheDesksDefault() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let now = try XCTUnwrap(
            utc.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9)))
        let frame = TimeFrame.pastYear(now: now, timeZone: .gmt)
        XCTAssertTrue(frame.contains(book(1, "2025-11-14")))
        // A book finished on the same date a year ago is just out of the span.
        XCTAssertFalse(frame.contains(book(2, "2025-11-13")))
        XCTAssertTrue(frame.contains(book(3, "2026-11-14")))
        XCTAssertEqual(frame.title, "Last 12 months")
        XCTAssertEqual(frame.setting, TimeFrame.defaultPileSetting)
        XCTAssertEqual(TimeFrame(setting: TimeFrame.defaultPileSetting, now: now), frame)

        let recent = [book(1, "2025-11-14"), book(3, "2026-11-01"), book(4, "2024-02-02")]
        XCTAssertEqual(
            TimeFrame.pileFrame(setting: TimeFrame.defaultPileSetting, in: recent, now: now),
            frame)
        // With nothing finished in the last 12 months, the desk shows the newest year.
        XCTAssertEqual(
            TimeFrame.pileFrame(
                setting: TimeFrame.defaultPileSetting, in: [book(4, "2024-02-02")], now: now),
            .year(2024))

        // The span starts partway through November, so November has a column at each end.
        let columns = YearInBooks.columns(for: frame, books: [recent[0], recent[1]])
        XCTAssertEqual(columns.count, 13)
        XCTAssertEqual(columns.first?.span, .month(11))
        XCTAssertEqual(columns.first?.books.map(\.id), [1])
        XCTAssertEqual(columns.last?.span, .month(11))
        XCTAssertEqual(columns.last?.books.map(\.id), [3])
        XCTAssertEqual(columns[1].span, .month(12))
        // A finish dated after this month still has a column: the last one.
        let later = YearInBooks.columns(for: frame, books: [recent[1], book(5, "2026-12-02")])
        XCTAssertEqual(later.count, 13)
        XCTAssertEqual(later.last?.books.map(\.id), [3, 5])
    }

    func testAMonthGoesByItsNameAloneAmongItsYearsSpans() {
        let august = TimeFrame.month(year: 2025, month: 8)
        XCTAssertEqual(august.year, 2025)
        XCTAssertEqual(august.nameInYear, "August")
        XCTAssertEqual(TimeFrame.year(2025).year, 2025)
        XCTAssertEqual(TimeFrame.year(2025).nameInYear, "2025")
        XCTAssertNil(TimeFrame.lifetime.year)
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
        // An empty list counts as absent, so `finished` still places the book.
        var empty = book(4, "2025-03-01")
        empty.finishedDates = []
        XCTAssertTrue(TimeFrame.year(2025).contains(empty))
        XCTAssertEqual(empty.readCount, 1)
    }

    func testTitles() {
        XCTAssertEqual(TimeFrame.year(2025).title, "2025")
        XCTAssertEqual(TimeFrame.lifetime.title, "All time")
        // Library names its every-book span as Desk and Share do.
        XCTAssertEqual(LibraryTime.allTime.title, TimeFrame.lifetime.title)
        // A month's title follows the device's language, so it names August in that language.
        let august = TimeFrame.month(year: 2025, month: 8).title.lowercased()
        let calendar = Calendar.current
        XCTAssertTrue(august.contains("2025"), august)
        XCTAssertTrue(
            [calendar.monthSymbols[7], calendar.standaloneMonthSymbols[7]]
                .contains { august.contains($0.lowercased()) }, august)
        // Menu items take title case.
        XCTAssertEqual(TimeFrame.lifetime.menuTitle, "All Time")
        let menu = LibraryTime.spans.map(\.menuTitle)
        XCTAssertEqual(menu, ["Last 12 Months", "This Year", "Last 5 Years", "All Time"])
        XCTAssertEqual(LibraryTime.year(2025).menuTitle, "2025")
    }
}
