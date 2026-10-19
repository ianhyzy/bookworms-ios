import XCTest

@testable import Bookworms

final class YearInBooksTests: XCTestCase {
    private func book(
        _ id: Int, finished: String?, rating: Double? = nil, pages: Int? = nil,
        format: String? = nil, author: String = "Author", genres: [String]? = nil
    ) -> CloudBook {
        CloudBook(
            id: id, title: "Book \(id)", author: author, coverURL: nil, detailCoverURL: nil,
            genres: genres, format: format, pages: pages, finished: finished, rating: rating)
    }

    func testCountsTheYearsFinishedBooksEarliestFirst() {
        let stats = YearInBooks(
            frame: .year(2025),
            library: [
                book(1, finished: "2025-03-02"),
                book(2, finished: "2026-01-15"),
                book(3, finished: nil),
                book(4, finished: "2025-13-01"),
                book(5, finished: "not a date"),
                book(6, finished: "2025-01-20T10:00:00Z"),
                book(7, finished: "2025-03-09"),
                book(8, finished: "2025-01-02"),
            ])
        XCTAssertEqual(
            stats.books.map(\.id), [8, 6, 1, 7], "Other years and invalid dates are left out")
        XCTAssertEqual(stats.columns.map(\.span), (1...12).map { .month($0) })
        XCTAssertEqual(
            stats.columns.map(\.books.count), [2, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(stats.busiest?.span, .month(1), "The earliest month wins a tie")
        let empty = YearInBooks(frame: .year(2025), library: [book(1, finished: nil)])
        XCTAssertNil(empty.busiest)
        XCTAssertTrue(empty.records.isEmpty)
        let single = YearInBooks(frame: .year(2025), library: [book(1, finished: "2025-03-02")])
        XCTAssertNil(single.busiest, "A column of one book isn't busy")
    }

    func testRereadsCountInEachYearByTheirReadThere() {
        var reread = book(1, finished: "2026-02-01", pages: 300)
        reread.finishedDates = ["2026-02-01", "2025-09-20", "2025-03-05"]
        let library = [reread, book(2, finished: "2025-06-01", pages: 100)]

        let year = YearInBooks(frame: .year(2025), library: library)
        XCTAssertEqual(year.books.map(\.id), [2, 1], "The newest read in 2025 orders the book")
        XCTAssertEqual(year.books.last?.finished, "2025-09-20")
        XCTAssertEqual(year.columns[8].books.map(\.id), [1])
        XCTAssertEqual(year.pages, 400)
        XCTAssertEqual(YearInBooks(frame: .year(2026), library: library).books.map(\.id), [1])
        XCTAssertEqual(
            YearInBooks(frame: .month(year: 2025, month: 3), library: library).books.map(\.id),
            [1])
        // A lifetime counts the book once, by its newest read.
        let lifetime = YearInBooks(frame: .lifetime, library: library)
        XCTAssertEqual(lifetime.books.map(\.finished), ["2025-06-01", "2026-02-01"])
        // Its chart starts at the first read, as the card's period does.
        var early = reread
        early.finishedDates = ["2026-02-01", "2023-03-05"]
        let chart = YearInBooks(frame: .lifetime, library: [early]).columns
        XCTAssertEqual(chart.map(\.span), [.year(2023), .year(2024), .year(2025), .year(2026)])
        XCTAssertEqual(chart.map(\.books.count), [0, 0, 0, 1])

        // Share cards in 2025 show the book by its read there.
        let finished = ShareTemplate.justFinished.books(from: library, in: .year(2025), bookID: 1)
        XCTAssertEqual(finished.map(\.finished), ["2025-09-20"])
        XCTAssertEqual(
            ShareTemplate.topFive.books(from: library, in: .year(2025)).map(\.id).sorted(),
            [1, 2])
    }

    func testMonthsChartWeeksOfTheirDays() {
        let august = YearInBooks(
            frame: .month(year: 2025, month: 8),
            library: [
                book(1, finished: "2025-08-01"), book(2, finished: "2025-08-08"),
                book(3, finished: "2025-08-14"), book(4, finished: "2025-08-31"),
                book(5, finished: "2025-07-31"),
            ])
        XCTAssertEqual(
            august.columns.map(\.span),
            [
                .days(1...7, month: 8), .days(8...14, month: 8), .days(15...21, month: 8),
                .days(22...28, month: 8), .days(29...31, month: 8),
            ])
        XCTAssertEqual(august.columns.map(\.books.count), [1, 2, 0, 0, 1])
        XCTAssertEqual(august.busiest?.span, .days(8...14, month: 8))

        let february = YearInBooks(frame: .month(year: 2025, month: 2), library: [])
        XCTAssertEqual(february.columns.last?.span, .days(22...28, month: 2))
        let leapFebruary = YearInBooks(frame: .month(year: 2024, month: 2), library: [])
        XCTAssertEqual(leapFebruary.columns.last?.span, .days(29...29, month: 2))
    }

    func testLifetimeChartsEveryYearFromFirstToLast() {
        let stats = YearInBooks(
            frame: .lifetime,
            library: [
                book(1, finished: "2021-05-01"), book(2, finished: "2019-02-01"),
                book(3, finished: "2021-09-01"), book(4, finished: nil),
            ])
        XCTAssertEqual(stats.columns.map(\.span), [.year(2019), .year(2020), .year(2021)])
        XCTAssertEqual(stats.columns.map(\.books.count), [1, 0, 2])
        XCTAssertEqual(stats.busiest?.span, .year(2021))
        XCTAssertTrue(YearInBooks(frame: .lifetime, library: []).columns.isEmpty)

        let mistyped = YearInBooks(
            frame: .lifetime,
            library: [
                book(1, finished: "2021-05-01"), book(2, finished: "0202-05-01"),
                book(3, finished: "2019-09-01"),
            ])
        XCTAssertEqual(
            mistyped.columns.map(\.span), [.year(202), .year(2019), .year(2021)],
            "A span past \(YearInBooks.maximumYearSpan) years charts only the years with books")
    }

    /// A leap February's one-day column shows the day alone, and a lifetime that charts only
    /// the years with books labels them in full, so 1925 and 2025 stay apart.
    @MainActor
    func testChartLabelsNameOneDayAndFarApartYears() {
        let leapFebruary = YearInBooks(frame: .month(year: 2024, month: 2), library: [])
        XCTAssertEqual(leapFebruary.columns.last.map { YearInBooksCard.label($0.span) }, "29")
        XCTAssertEqual(YearInBooksCard.label(.days(8...14, month: 8)), "8–14")
        let busiest = YearInBooksCard.busiest(.days(29...29, month: 2), isCompact: false).value
        XCTAssertTrue(busiest.hasSuffix(" 29") && !busiest.contains("–"), busiest)

        let mistyped = YearInBooks(
            frame: .lifetime,
            library: [book(1, finished: "1925-05-01"), book(2, finished: "2025-05-01")])
        XCTAssertTrue(YearInBooksCard.isSparse(mistyped.columns))
        XCTAssertEqual(
            mistyped.columns.map { YearInBooksCard.label($0.span, isSparse: true) },
            ["1925", "2025"])
        let contiguous = YearInBooks(
            frame: .lifetime,
            library: [book(1, finished: "2019-05-01"), book(2, finished: "2021-05-01")])
        XCTAssertFalse(YearInBooksCard.isSparse(contiguous.columns))
        XCTAssertEqual(YearInBooksCard.label(.year(2019)), "’19")
    }

    func testTotalsIgnoreMissingValues() throws {
        let stats = YearInBooks(
            frame: .year(2025),
            library: [
                book(1, finished: "2025-05-01", rating: 5, pages: 300, format: "Listened"),
                book(2, finished: "2025-05-02", rating: 4, pages: 200, format: "Ebook"),
                book(3, finished: "2025-06-01", pages: 0, format: "Listened"),
                book(4, finished: "2025-07-01", rating: 7, format: "Both"),
            ])
        XCTAssertEqual(stats.pages, 500)
        XCTAssertEqual(stats.booksWithPages, 2)
        XCTAssertEqual(stats.ratedBooks, 2, "Out-of-range ratings are ignored")
        XCTAssertEqual(try XCTUnwrap(stats.averageRating), 4.5, accuracy: 0.001)
        XCTAssertEqual(stats.busiest?.span, .month(5))
        XCTAssertEqual(
            stats.formats,
            [
                .init(name: "Audiobook", count: 3), .init(name: "Ebook", count: 1),
                .init(name: "Physical", count: 1),
            ],
            "A book read in two formats counts toward both")
        XCTAssertEqual(stats.topAuthor, .init(name: "Author", count: 4))
    }

    func testRecordsPickLongestShortestAndFavorite() {
        let stats = YearInBooks(
            frame: .year(2025),
            library: [
                book(1, finished: "2025-01-01", rating: 5, pages: 640),
                book(2, finished: "2025-02-01", rating: 3, pages: 180),
                book(3, finished: "2025-03-01", rating: 5, pages: 640),
                book(4, finished: "2025-04-01", pages: 0),
            ])
        XCTAssertEqual(stats.longest?.id, 3, "The latest finish wins a tie")
        XCTAssertEqual(stats.shortest?.id, 2)
        XCTAssertEqual(stats.favorite?.id, 3)
        XCTAssertEqual(stats.records.map(\.id), [3, 2], "A book appears once among the records")

        let single = YearInBooks(
            frame: .year(2025), library: [book(1, finished: "2025-01-01", pages: 300)])
        XCTAssertEqual(single.longest?.id, 1)
        XCTAssertNil(single.shortest, "One paged book isn't also the shortest")
        XCTAssertNil(single.favorite)

        let equal = YearInBooks(
            frame: .year(2025),
            library: [
                book(1, finished: "2025-01-01", pages: 300),
                book(2, finished: "2025-02-01", pages: 300),
            ])
        XCTAssertEqual(equal.longest?.id, 2)
        XCTAssertNil(equal.shortest, "Equal lengths have no shorter book")
    }

    func testGenresAndAuthorsRankByCountThenName() {
        let stats = YearInBooks(
            frame: .year(2025),
            library: [
                book(
                    1, finished: "2025-01-01", author: "Rowan",
                    genres: ["Fantasy", "Mystery", "Horror", "Ignored"]),
                book(2, finished: "2025-02-01", author: "Rowan", genres: ["Mystery", "Fantasy"]),
                book(3, finished: "2025-03-01", author: "Vale", genres: ["Poetry"]),
                book(
                    4, finished: "2025-04-01", author: "Wren",
                    genres: ["Science Fiction", "Young Adult"]),
            ])
        XCTAssertEqual(
            stats.genres.map(\.name),
            ["Fantasy", "Mystery", "Horror", "Poetry", "Science Fiction"],
            "Each book's first \(YearInBooks.genresPerBook) genres count, up to five in all")
        XCTAssertEqual(stats.topAuthor, .init(name: "Rowan", count: 2))

        let distinct = YearInBooks(
            frame: .year(2025),
            library: [
                book(1, finished: "2025-01-01", author: "Rowan"),
                book(2, finished: "2025-02-01", author: "Vale"),
            ])
        XCTAssertNil(distinct.topAuthor, "A most-read author needs at least two books")
    }

    func testGenresSkipForeignTagsAndCapitalizeLowercaseOnes() {
        let stats = YearInBooks(
            frame: .year(2025),
            library: [
                book(
                    1, finished: "2025-01-01", genres: ["Féminisme", "litrpg", "LGBTQ", "Fantasy"])
            ])
        XCTAssertEqual(
            stats.genres.map(\.name), ["Fantasy", "LGBTQ", "Litrpg"],
            "Foreign tags don't use up a book's three genre slots")
    }
}
