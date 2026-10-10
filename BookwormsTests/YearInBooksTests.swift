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
            year: 2025,
            library: [
                book(1, finished: "2025-03-02"),
                book(2, finished: "2026-01-15"),
                book(3, finished: nil),
                book(4, finished: "2025-13-01"),
                book(5, finished: "not a date"),
                book(6, finished: "2025-01-20T10:00:00Z"),
            ])
        XCTAssertEqual(stats.books.map(\.id), [6, 1], "Other years and invalid dates are left out")
        XCTAssertEqual(stats.months.map(\.count), [1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(stats.busiestMonth, 1, "The earliest month wins a tie")
        let empty = YearInBooks(year: 2025, library: [book(1, finished: nil)])
        XCTAssertNil(empty.busiestMonth)
        XCTAssertTrue(empty.records.isEmpty)
    }

    func testTotalsIgnoreMissingValues() throws {
        let stats = YearInBooks(
            year: 2025,
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
        XCTAssertEqual(stats.busiestMonth, 5)
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
            year: 2025,
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
            year: 2025, library: [book(1, finished: "2025-01-01", pages: 300)])
        XCTAssertEqual(single.longest?.id, 1)
        XCTAssertNil(single.shortest, "One paged book isn't also the shortest")
        XCTAssertNil(single.favorite)

        let equal = YearInBooks(
            year: 2025,
            library: [
                book(1, finished: "2025-01-01", pages: 300),
                book(2, finished: "2025-02-01", pages: 300),
            ])
        XCTAssertEqual(equal.longest?.id, 2)
        XCTAssertNil(equal.shortest, "Equal lengths have no shorter book")
    }

    func testGenresAndAuthorsRankByCountThenName() {
        let stats = YearInBooks(
            year: 2025,
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
            year: 2025,
            library: [
                book(1, finished: "2025-01-01", author: "Rowan"),
                book(2, finished: "2025-02-01", author: "Vale"),
            ])
        XCTAssertNil(distinct.topAuthor, "A most-read author needs at least two books")
    }

    func testGenresSkipForeignTagsAndCapitalizeLowercaseOnes() {
        let stats = YearInBooks(
            year: 2025,
            library: [
                book(
                    1, finished: "2025-01-01", genres: ["Féminisme", "litrpg", "LGBTQ", "Fantasy"])
            ])
        XCTAssertEqual(
            stats.genres.map(\.name), ["Fantasy", "LGBTQ", "Litrpg"],
            "Foreign tags don't use up a book's three genre slots")
    }
}
