import CoreText
import Foundation
import SwiftUI
import XCTest

@testable import Bookworms

final class ShelfLogicTests: XCTestCase {
    private func book(
        _ id: Int, _ title: String, by author: String = "An Author", rating: Double? = nil,
        pages: Int? = nil
    ) -> CloudBook {
        var book = CloudBook(
            id: id, title: title, author: author, coverURL: nil, detailCoverURL: nil)
        book.rating = rating
        book.pages = pages
        return book
    }

    func testSortsKeepRecentlyFinishedOrderForTies() {
        // Arrives most recently finished first, as `AppModel.books` provides it.
        let books = [
            book(1, "Volume 10", by: "Zed Writer", rating: 4),
            book(2, "Volume 2", by: "Ann Author"),
            book(3, "An Atlas", by: "Mid Writer", rating: 5),
            book(4, "Volume 1", by: "Ann Author", rating: 4),
        ]
        XCTAssertEqual(ShelfSort.finished.sorted(books).map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(ShelfSort.title.sorted(books).map(\.id), [3, 4, 2, 1])
        XCTAssertEqual(ShelfSort.author.sorted(books).map(\.id), [2, 4, 3, 1])
        XCTAssertEqual(ShelfSort.rating.sorted(books).map(\.id), [3, 1, 4, 2])
    }

    private func finished(_ id: Int, _ date: String?) -> CloudBook {
        var book = book(id, "Book \(id)")
        book.finished = date
        book.isRead = true
        return book
    }

    /// 9 p.m. on 12 October 2026 in Los Angeles, already 13 October in UTC.
    private let evening = Date(timeIntervalSince1970: 1_791_864_000)
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func ids(_ time: LibraryTime, _ books: [CloudBook]) -> [Int] {
        time.books(in: books, now: evening, timeZone: losAngeles).map(\.id)
    }

    func testRollingTimesStartAfterTheSameDateBeforeWithNoEnd() {
        let books = [
            finished(1, "2026-10-13"), finished(2, "2026-10-12"), finished(3, "2025-10-13"),
            finished(4, "2025-10-12"), finished(5, "2021-10-13"), finished(6, "2021-10-12"),
        ]
        // Today is the reader's 12 October, so a book finished on UTC's 13 October still counts.
        XCTAssertEqual(ids(.last12Months, books), [1, 2, 3])
        XCTAssertEqual(ids(.last5Years, books), [1, 2, 3, 4, 5])
    }

    func testCalendarYearsFollowTheReadersToday() {
        let books = [finished(1, "2026-01-01"), finished(2, "2025-12-31")]
        // 4 p.m. on New Year's Eve in Los Angeles, already 2026 in UTC.
        let newYearsEve = Date(timeIntervalSince1970: 1_767_225_600)
        XCTAssertEqual(
            LibraryTime.thisYear.books(in: books, now: newYearsEve, timeZone: losAngeles)
                .map(\.id), [2])
        XCTAssertEqual(ids(.thisYear, books), [1])
        XCTAssertEqual(ids(.year(2025), books), [2])
    }

    func testBooksWithoutFinishDatesShowOnlyUnderAllTime() {
        let books = [finished(1, nil), finished(2, "2026-05-01"), finished(3, "2026")]
        for time in [LibraryTime.last12Months, .thisYear, .last5Years, .year(2026)] {
            XCTAssertEqual(ids(time, books), [2], time.title)
        }
        XCTAssertEqual(ids(.allTime, books), [1, 2, 3])
    }

    func testYearMenuListsFinishedYearsNewestFirst() {
        let books = [
            finished(1, "2024-03-02"), finished(2, "2026-08-01"), finished(3, nil),
            finished(4, "2024-11-30"), finished(5, "2019-01-09"),
        ]
        XCTAssertEqual(LibraryTime.years(in: books), [2026, 2024, 2019])
    }

    func testRereadsShowInEverySpanByTheirReadThere() throws {
        var reread = finished(1, "2026-09-01")
        reread.finishedDates = ["2026-09-01", "2024-11-03", "2024-02-10", "2019-05-05"]
        let books = [reread, finished(2, "2024-06-01")]
        XCTAssertEqual(LibraryTime.years(in: books), [2026, 2024, 2019])
        let shown = LibraryTime.year(2024).books(in: books, now: evening, timeZone: losAngeles)
        // The newest read in 2024 orders and labels the book there.
        XCTAssertEqual(shown.map(\.id), [1, 2])
        XCTAssertEqual(shown.first?.finished, "2024-11-03")
        XCTAssertEqual(shown.first?.readCount, 4)
        XCTAssertEqual(ids(.year(2019), books), [1])
        XCTAssertEqual(ids(.last12Months, books), [1])
        XCTAssertEqual(ids(.allTime, books), [1, 2])
        XCTAssertEqual(ShelfLabels.reads(reread.readCount), "Read 4 times")
        XCTAssertNil(ShelfLabels.reads(books[1].readCount))
        XCTAssertEqual(
            DetailCard.journal(of: reread),
            [.finished(try XCTUnwrap(reread.finishedDate), reads: 4)])
    }

    @MainActor func testLibraryShowsReadBooksAndPreparesThemAgainWhenAChoiceChanges() {
        var reading = finished(3, "2026-02-01")
        reading.isReading = true
        let library = [
            finished(4, "2026-03-01"), book(2, "Unread"), reading, finished(1, "2024-05-01"),
        ]
        let shelf = LibraryShelf()
        let all = shelf.contents(of: library, sort: .finished, time: .allTime)
        // Current reads and unread shelves stay off.
        XCTAssertTrue(all.hasRead)
        XCTAssertEqual(all.books.map(\.id), [4, 1])
        XCTAssertEqual(all.years, [2026, 2024])
        XCTAssertEqual(
            shelf.contents(of: library, sort: .title, time: .allTime).books.map(\.id), [1, 4])
        XCTAssertEqual(
            shelf.contents(of: library, sort: .title, time: .year(2024)).books.map(\.id), [1])
        // A sync's books replace the prepared ones.
        let synced = [finished(5, "2024-07-01")] + library
        XCTAssertEqual(
            shelf.contents(of: synced, sort: .title, time: .year(2024)).books.map(\.id), [1, 5])
        XCTAssertFalse(
            shelf.contents(of: [book(2, "Unread")], sort: .title, time: .allTime).hasRead)
        // The same books, a day later, leave a span that ends today.
        let lastYear = [finished(6, "2025-10-13")]
        func shown(at now: Date) -> [Int] {
            shelf.contents(
                of: lastYear, sort: .finished, time: .last12Months, now: now, timeZone: losAngeles
            )
            .books.map(\.id)
        }
        XCTAssertEqual(shown(at: evening), [6])
        XCTAssertEqual(shown(at: evening.addingTimeInterval(3 * 3600)), [])
    }

    func testLibraryTimeSavesAndRestoresEveryChoice() {
        for time in LibraryTime.spans + [.year(2019)] {
            XCTAssertEqual(LibraryTime(rawValue: time.rawValue), time)
        }
        XCTAssertNil(LibraryTime(rawValue: "pile"))
        XCTAssertNil(LibraryTime(rawValue: "year:"))
        XCTAssertEqual(LibraryTime.spans.first, .last12Months)
    }

    func testFormatLabelsMatchTheAppleTV() {
        XCTAssertEqual(ShelfLabels.format("Read"), "Physical")
        XCTAssertEqual(ShelfLabels.format("Listened"), "Audiobook")
        XCTAssertEqual(ShelfLabels.format("Ebook"), "Ebook")
        XCTAssertEqual(ShelfLabels.format("Both"), "Physical & audiobook")
        XCTAssertEqual(ShelfLabels.format("Scroll"), "Scroll")
        XCTAssertNil(ShelfLabels.format(nil))
    }

    func testDetailsShowOnlyTheFactsTheBookHas() {
        var full = book(1, "The Lantern Keeper", rating: 4.5, pages: 352)
        full.seriesID = 7
        full.seriesName = "The Lantern Cycle"
        full.seriesPosition = 2
        full.publicationYear = 2021
        full.format = "Listened"
        full.audioSeconds = 43_500
        full.genres = ["Fantasy", "mystery", "Adventure", "Romance"]
        full.communityRating = 4.12
        full.ratingsCount = 250
        full.ratingDistribution = [
            RatingBucket(rating: 4, count: 120), RatingBucket(rating: 4.5, count: 10),
            RatingBucket(rating: 5, count: 120),
        ]
        XCTAssertEqual(
            DetailCard.details(of: full, about: "A keeper tends the last lantern."),
            [
                .about("A keeper tends the last lantern."),
                .rating(
                    average: 4.12, count: 250, counts: [0, 0, 0, 0, 0, 0, 0, 120, 10, 120],
                    yours: 4.5),
                .series(
                    SeriesMembership(
                        seriesID: 7, name: "The Lantern Cycle", position: 2, featured: true,
                        compilation: false)),
                .published(2021),
                // Pages even for an audiobook: the book's length whatever the format. The
                // format and its listening time belong to the Journal.
                .length("352 pages"),
                .genres(["Fantasy", "Mystery", "Adventure"]),
            ])

        var bare = book(2, "Unrated")
        bare.communityRating = 4
        bare.ratingsCount = 0
        // A series needs a name to show.
        bare.seriesID = 12
        bare.seriesPosition = 3
        XCTAssertEqual(DetailCard.details(of: bare, about: nil), [])
        bare.publicationYear = 1999
        XCTAssertEqual(DetailCard.details(of: bare, about: nil), [.published(1999)])

        // "Humour" repeats "Humor", so the next genre takes its place.
        bare.genres = ["Humor", "Humour", "Satire", "Fantasy"]
        XCTAssertEqual(
            DetailCard.details(of: bare, about: nil),
            [.published(1999), .genres(["Humor", "Satire", "Fantasy"])])
    }

    /// Wide iPhone details split at the screen's middle, under the safe area, so the open Duo's
    /// fold falls between the book and the text; a wide screen caps the text at 640 points.
    func testWideDetailsSplitAtTheScreensMiddle() {
        XCTAssertEqual(BookDetailView.textColumnWidth(width: 1000), 500)
        XCTAssertEqual(BookDetailView.textColumnWidth(width: 1600), 640)
        XCTAssertEqual(BookDetailView.textColumnWidth(width: 907, leading: 44), 475)
        XCTAssertEqual(BookDetailView.textColumnWidth(width: 907, trailing: 44), 431)
    }

    func testRatingCountsFillEveryHalfStar() {
        XCTAssertNil(DetailCard.ratingCounts(nil))
        XCTAssertNil(DetailCard.ratingCounts([RatingBucket(rating: 3, count: 0)]))
        XCTAssertEqual(
            DetailCard.ratingCounts([
                RatingBucket(rating: 0.5, count: 1), RatingBucket(rating: 3, count: 2),
                RatingBucket(rating: 3, count: 3), RatingBucket(rating: 0, count: 9),
                RatingBucket(rating: 5.5, count: 9),
            ]),
            [1, 0, 0, 0, 0, 5, 0, 0, 0, 0])
    }

    func testJournalShowsHowTheReaderReadTheBook() throws {
        var listened = book(1, "Heard", pages: 352)
        listened.format = "Listened"
        listened.audioSeconds = 43_500
        listened.finished = "2025-03-01"
        listened.review = "  Loved it.\n"
        XCTAssertEqual(
            DetailCard.journal(of: listened),
            [
                .finished(try XCTUnwrap(listened.finishedDate), reads: 1),
                .format("Audiobook", length: "12 hr, 5 min"),
                .review("Loved it."),
            ])

        var reading = book(2, "Now", pages: 200)
        reading.format = "Read"
        reading.isReading = true
        reading.progress = 0.25
        reading.started = "2025-04-10"
        XCTAssertEqual(
            DetailCard.journal(of: reading),
            [
                .status(progress: 0.25), .started(try XCTUnwrap(reading.startedDate)),
                // The page count shows on the Length card alone.
                .format("Physical", length: nil),
            ])
        XCTAssertEqual(DetailCard.journal(of: book(3, "Unrecorded")), [])
    }

    func testYourReadingPutsTheDatesOnTheDateDueCard() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let finished = started.addingTimeInterval(86_400 * 9)
        let parts = DetailCard.journalParts([
            .status(progress: nil), .started(started), .finished(finished, reads: 2),
            .readingTime("9 days"), .format("Ebook", length: nil), .review("A keeper."),
        ])
        XCTAssertEqual(
            parts.record,
            [.started(started), .finished(finished, reads: 2), .readingTime("9 days")])
        XCTAssertEqual(parts.review, "A keeper.")
        XCTAssertEqual(parts.others, [.status(progress: nil), .format("Ebook", length: nil)])
        let none = DetailCard.journalParts([])
        XCTAssertEqual(none.record, [])
        XCTAssertNil(none.review)
        XCTAssertEqual(none.others, [])
    }

    func testCardRowsPairHalfCardsWithoutHoles() {
        let about = DetailCard.about("A keeper tends the last lantern.")
        let rating = DetailCard.rating(average: 4, count: 10, counts: nil, yours: nil)
        let series = DetailCard.series(
            SeriesMembership(
                seriesID: 7, name: "The Lantern Cycle", position: 2, featured: true,
                compilation: false))
        let year = DetailCard.published(2021)
        let length = DetailCard.length("352 pages")
        let genres = DetailCard.genres(["Fantasy"])
        XCTAssertEqual(
            DetailCard.rows([about, rating, series, year, length, genres], oneColumn: false),
            [[about], [rating, series], [year, length], [genres]])
        // With an odd number, the first half card fills a row alone.
        XCTAssertEqual(
            DetailCard.rows([about, rating, year, length, genres], oneColumn: false),
            [[about], [rating], [year, length], [genres]])
        // Half cards pair only with their neighbors on the same side of a wide card.
        XCTAssertEqual(
            DetailCard.rows([year, about, length, rating, series], oneColumn: false),
            [[year], [about], [length], [rating, series]])
        // A rating with bars fills its row.
        let bars = DetailCard.rating(
            average: 4, count: 10, counts: [0, 0, 0, 0, 0, 0, 0, 4, 0, 6], yours: nil)
        XCTAssertEqual(
            DetailCard.rows([about, bars, year, length], oneColumn: false),
            [[about], [bars], [year, length]])
        XCTAssertEqual(DetailCard.rows([], oneColumn: false), [])
        XCTAssertEqual(
            DetailCard.rows([about, rating, year], oneColumn: true), [[about], [rating], [year]])
    }

    func testDescriptionsBecomePlainText() {
        XCTAssertEqual(
            HardcoverClient.plainText(
                from:
                    "<strong>A heist in orbit</strong>\r\n\r\nThe crew of the *Long Night* steals a moon.[2] Tea &amp; toast.\r\n\r\nContains:\r\n- [Part 1](https://example.com/1)\r\n- [Part 2](https://example.com/2)"
            ),
            "A heist in orbit\n\nThe crew of the Long Night steals a moon.[2] Tea & toast.\n\nContains:\n- Part 1\n- Part 2"
        )
    }

    func testSpineAuthorsFallBackToTheirSurnames() {
        XCTAssertEqual(SpineView.surname("Mara Quill Ashby"), "Ashby")
        XCTAssertEqual(SpineView.surname("Odile R. Le Brun"), "Le Brun")
        XCTAssertEqual(SpineView.surname("Celeste du Ravel"), "du Ravel")
        XCTAssertEqual(SpineView.surname("Thomas Avery Holt Jr."), "Holt Jr.")
        XCTAssertEqual(SpineView.surname("Wren Calloway et al."), "Calloway et al.")
        XCTAssertEqual(SpineView.surname("Ivo Marsh, Wren Calloway"), "Marsh, Calloway")
        XCTAssertNil(SpineView.surname("Halcyon"))
        XCTAssertEqual(SpineView.twoLines("Felix Andrew Morrow"), "Felix Andrew\nMorrow")
        XCTAssertEqual(
            SpineView.twoLines("Ivo Marsh, Wren Calloway"), "Ivo Marsh,\nWren Calloway")
        XCTAssertEqual(SpineView.twoLines("Odile R. Le Brun"), "Odile R.\nLe Brun")
        XCTAssertNil(SpineView.twoLines("Halcyon"))
    }

    /// The Apple TV's band table (`BookWallLocalSpineTests`), so both apps stamp the same books:
    /// the thicknesses `BookShape` gives these books near the band threshold.
    func testOnlyBooksAtLeast48MillimetersThickHaveStampedBands() {
        let expected: [(pages: Int?, millimeters: Int, stamps: Bool)] = [
            (nil, 24, false), (500, 36, false), (686, 44, false), (687, 48, true),
            (700, 48, true), (1_400, 88, true),
        ]
        for row in expected {
            let shelved = book(1, "Book", pages: row.pages)
            let thickness = BookShape(of: shelved, coverAspect: 2 / 3).size.z
            XCTAssertEqual(Int((thickness * 100).rounded()), row.millimeters, "\(row)")
            XCTAssertEqual(SpineView.stamps(shelved), row.stamps, "\(row)")
        }
    }

    /// Georgia Bold at `size`. It has no optical sizes, so its widths scale exactly.
    private func georgia(_ size: CGFloat) -> CTFont {
        CTFontCreateWithName("Georgia-Bold" as CFString, size, nil)
    }

    private func lettering(
        _ title: String, by author: String = "", length: CGFloat, thickness: CGFloat
    ) -> SpineLettering {
        SpineLettering.measure(
            title: title, author: author, length: length, thickness: thickness, font: georgia)
    }

    /// The sizes the title's rule works from, for `title` in Georgia Bold beside no author, which
    /// leaves the title the whole row: on one line, on two lines of the font's line height, and
    /// on two lines whose letters fill the box, with the two lines and their letters' height.
    private func titleSizes(_ title: String, length: CGFloat, thickness: CGFloat) -> (
        one: CGFloat, two: CGFloat, filled: CGFloat, lines: [String], ink: CGFloat
    ) {
        let face = georgia(100)
        func line(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): face]))
        }
        func width(_ text: String) -> CGFloat {
            CTLineGetTypographicBounds(line(text), nil, nil, nil) / 100
        }
        let box = thickness * SpineLettering.boxShare
        let room =
            length - 2 * SpineLettering.inset(length: length, thickness: thickness)
            - thickness * 0.3
        let lineHeight =
            (CTFontGetAscent(face) + CTFontGetDescent(face) + CTFontGetLeading(face)) / 100
        let words = title.split(separator: " ").map(String.init)
        let lines = (1..<words.count)
            .map { [words[..<$0].joined(separator: " "), words[$0...].joined(separator: " ")] }
            .min { $0.map(width).max()! < $1.map(width).max()! }!
        let longer = lines.map(width).max()!
        let bounds = lines.map { CTLineGetBoundsWithOptions(line($0), .useGlyphPathBounds) }
        let ink = (bounds.map(\.maxY).max()! - bounds.map(\.minY).min()!) / 100
        let two = min(box / (2 * lineHeight), room / longer)
        return (
            min(box / lineHeight, room / width(title)), two,
            // The fill and the gap are numbers here, so that the tests pin the approved look.
            max(two, min(0.85 * box / (2.2 * ink), room / longer)), lines, ink
        )
    }

    /// A title keeps to one line unless two lines letter it at least a quarter larger. Where
    /// one line would letter below 4.5% of the spine's length, it takes whichever is larger.
    func testSpineTitlesTakeTwoLinesOnlyForAClearGain() {
        var held = 0
        var gained = 0
        var small = 0
        for title in ["HOLLOW CROWNS", "THE MAP OF THE HOLLOW CROWN AND ITS KEEPERS"] {
            for thickness in stride(from: CGFloat(20), through: 120, by: 1) {
                let sizes = titleSizes(title, length: 384, thickness: thickness)
                let floor = 0.045 * 384
                // A size within 1% of a threshold could round either way.
                guard abs(sizes.two / sizes.one - 1.25) > 0.0125,
                    abs(sizes.two / sizes.one - 1) > 0.01,
                    abs(sizes.one / floor - 1) > 0.01
                else { continue }
                let takesTwo =
                    sizes.one >= floor ? sizes.two > 1.25 * sizes.one : sizes.two > sizes.one
                if sizes.one >= floor, sizes.two > sizes.one, !takesTwo { held += 1 }
                if sizes.one >= floor, takesTwo { gained += 1 }
                if sizes.one < floor, takesTwo { small += 1 }
                let lettered = lettering(title, length: 384, thickness: thickness)
                XCTAssertEqual(
                    lettered.titleLines, takesTwo ? sizes.lines : [title], "\(title) \(thickness)")
            }
        }
        // The spines cover each case: held to one line, two lines for the gain, and two lines
        // below the floor.
        XCTAssertGreaterThan(held, 0)
        XCTAssertGreaterThan(gained, 0)
        XCTAssertGreaterThan(small, 0)
        // A one-word title never breaks, and two lines break where the longer line is shortest.
        XCTAssertEqual(
            lettering("LANTERNWRIGHT", length: 330, thickness: 96).titleLines, ["LANTERNWRIGHT"])
        XCTAssertEqual(
            lettering("A MAP OF LANTERNWRIGHTS", length: 330, thickness: 96).titleLines,
            ["A MAP OF", "LANTERNWRIGHTS"])
    }

    /// A two-line title grows until its letters, not its font's line boxes, fill 85% of the
    /// lettering's box, or its longer line fills the width.
    func testTwoLineTitlesGrowUntilTheirLettersFillTheBox() {
        var grown = 0
        for title in ["HOLLOW CROWNS", "The Map of the Hollow Crown and Its Keepers"] {
            for thickness in stride(from: CGFloat(40), through: 120, by: 4) {
                let sizes = titleSizes(title, length: 384, thickness: thickness)
                let lettered = lettering(title, length: 384, thickness: thickness)
                guard lettered.titleLines.count == 2 else { continue }
                XCTAssertEqual(
                    lettered.titleSize, sizes.filled, accuracy: sizes.filled * 0.01,
                    "\(title) \(thickness)")
                guard sizes.filled > sizes.two * 1.01 else { continue }
                grown += 1
                // The lines sit a fifth of the letters' height apart.
                XCTAssertEqual(
                    lettered.titlePitch, 1.2 * sizes.ink * lettered.titleSize,
                    accuracy: lettered.titlePitch * 0.01)
            }
        }
        XCTAssertGreaterThan(grown, 0)
        // Capitals leave room in their line boxes: these grow by over a tenth.
        let capitals = titleSizes("HOLLOW CROWNS", length: 384, thickness: 120)
        XCTAssertGreaterThan(capitals.filled, capitals.two * 1.1)
    }

    /// A spine of one shape letters alike at any size, and the author's size follows the title:
    /// large beside a title that spares the room, at its minimum beside a two-line title.
    func testSpineLetteringScalesWithItsSpineAndSizesTheAuthor() {
        // The 3D texture of a 694-page book, 384 by 55 points, and the same shape 330 long.
        let crown = "THE MAP OF THE HOLLOW CROWN"
        let texture = lettering(crown, by: "Wren Halloway", length: 384, thickness: 55)
        let smaller = lettering(
            crown, by: "Wren Halloway", length: 330, thickness: 55 * 330 / 384)
        XCTAssertEqual(texture.titleLines, smaller.titleLines)
        XCTAssertEqual(smaller.titleSize / texture.titleSize, 330.0 / 384, accuracy: 0.005)
        XCTAssertEqual(smaller.author, texture.author)
        XCTAssertEqual(smaller.authorSize / texture.authorSize, 330.0 / 384, accuracy: 0.005)
        // Beside a short title, a thin spine's author takes the large size, 4% of the length,
        // on one line.
        let proof = lettering("THE PROOF", by: "Tobey Marchetti", length: 384, thickness: 35)
        XCTAssertEqual(proof.titleLines.count, 1)
        XCTAssertEqual(proof.author, "Tobey Marchetti")
        XCTAssertEqual(proof.authorSize, 384 * 0.04, accuracy: 0.001)
        // Beside a two-line title, the author keeps its minimum, a little over a quarter of
        // the thickness, below the title's size.
        let keepers = lettering(
            "THE MAP OF THE HOLLOW CROWN AND ITS KEEPERS", by: "Wren Halloway", length: 384,
            thickness: 40)
        XCTAssertEqual(keepers.titleLines.count, 2)
        XCTAssertEqual(keepers.authorSize, 40 * 0.275, accuracy: 0.001)
        XCTAssertLessThan(keepers.authorSize, keepers.titleSize)
        // On the thinnest card, 44 points, two authors keep their minimum size, a little over
        // a quarter of the thickness, rather than shrinking to fit the author's least share.
        let tides = lettering(
            "DARK TIDES", by: "Iris Calloway, Bram Osterly", length: 330, thickness: 44)
        XCTAssertTrue(tides.authorFits)
        XCTAssertGreaterThanOrEqual(tides.authorSize, 44 * 0.275 - 0.001)
    }

    /// A spine names its author in full wherever it can: the whole name at its minimum size
    /// comes before the surname at the large size.
    func testSpineAuthorsKeepTheirWholeNamesBeforeTheirSurnames() {
        // Beside a long title, the author's room is 24% of a 384-point spine, 92 points. At the
        // large size, 4% of the length, only "Marchetti" fits it; at the minimum, a little
        // over a quarter of the thickness, "Io Marchetti" does.
        let whole = lettering(
            "THE PROOF OF THE HOLLOW CROWN", by: "Io Marchetti", length: 384, thickness: 36)
        XCTAssertEqual(whole.author, "Io Marchetti")
        XCTAssertEqual(whole.authorSize, 36 * 0.275, accuracy: 0.001)
        XCTAssertTrue(whole.authorFits)
        // On a spine 16 points thick, the name is too long for one line and, at its 7-point
        // minimum, too tall for two, so it takes its surname.
        let surname = lettering(
            "THE PROOF OF THE HOLLOW CROWN", by: "Bartholomew Quillfeatherstone", length: 384,
            thickness: 16)
        XCTAssertEqual(surname.author, "Quillfeatherstone")
        XCTAssertTrue(surname.authorFits)
    }

    /// The spine draws its title as measured: a filled two-line title's lines sit a fifth of
    /// their letters' height apart, and its letters are centered across the spine.
    @MainActor func testSpinesDrawFilledTitlesCenteredAcrossTheSpine() throws {
        let face = try XCTUnwrap(SpineFonts.installedFace(named: "Georgia-Bold"))
        let book = book(1, "Hollowed Crowns", by: "Io Vey", pages: 694)
        // A look without a design takes no face, so the face is set after.
        var look = SpineLook(book: book, design: nil, face: nil)
        look.face = face
        look.background = ColorValue(red: 2, green: 2, blue: 2)
        look.foreground = ColorValue(red: 229, green: 246, blue: 240)
        look.uppercase = true
        let length: CGFloat = 384
        let ink = titleSizes("HOLLOWED CROWNS", length: length, thickness: 100).ink
        func measure(_ thickness: CGFloat) -> SpineLettering {
            SpineLettering.cached(
                title: "HOLLOWED CROWNS", author: "Io Vey", length: length,
                thickness: thickness, look: look)
        }
        // The first thickness at which the box, not the width, limits the two lines.
        let thickness = try XCTUnwrap(
            stride(from: CGFloat(60), through: 120, by: 2)
                .first {
                    let lettered = measure($0)
                    return lettered.titleLines == ["HOLLOWED", "CROWNS"]
                        && abs(lettered.titlePitch - 1.2 * ink * lettered.titleSize) < 0.01
                })
        let measured = measure(thickness)
        let rows = try letteringLines(
            SpineView(book: book, look: look).frame(width: length, height: thickness), scale: 2
        )
        .title.map(\.rows)
        XCTAssertEqual(rows.count, 2)
        let top = CGFloat(try XCTUnwrap(rows.first).lowerBound) / 2
        let bottom = CGFloat(try XCTUnwrap(rows.last).upperBound + 1) / 2
        // Within a point and a half: a row of pixels at each edge, and antialiasing.
        XCTAssertEqual(bottom - top, measured.titlePitch + ink * measured.titleSize, accuracy: 1.5)
        XCTAssertEqual((top + bottom) / 2, thickness / 2, accuracy: 1.5)
    }

    /// A spine in the system serif letters Japanese in the system sans's Gothic at the spine's
    /// weight, as the Apple TV draws it, rather than in New York's light Mincho fallback, and
    /// letters Latin titles in New York as before.
    @MainActor func testSystemSerifSpinesLetterJapaneseInTheSansGothic() throws {
        func pixels(_ text: String, _ font: Font) throws -> Data {
            let renderer = ImageRenderer(
                content: Text(text).font(font).foregroundStyle(.black).padding(4)
                    .background(.white))
            renderer.scale = 1
            return try XCTUnwrap(try XCTUnwrap(renderer.cgImage).dataProvider?.data) as Data
        }
        var look = SpineLook(book: book(1, "東京の灯"), design: nil, face: nil)
        look.typeface = "serif"
        look.weight = 700
        let japanese = "東京の灯"
        let gothic = try pixels(japanese, .system(size: 40, weight: .bold))
        XCTAssertEqual(try pixels(japanese, look.font(size: 40)), gothic)
        XCTAssertNotEqual(
            try pixels(japanese, .system(size: 40, weight: .bold, design: .serif)), gothic,
            "New York's own fallback is another face")
        XCTAssertEqual(
            try pixels("The Lantern Road", look.font(size: 40)),
            try pixels("The Lantern Road", .system(size: 40, weight: .bold, design: .serif)))
        // A look's other system typefaces draw as SwiftUI's own system fonts do: the Core Text
        // font that `SpineLettering` measures is the font the spine draws.
        let systems: [(typeface: String, weight: Int, condensed: Bool, font: Font)] = [
            ("sans", 600, true, .system(size: 40, weight: .semibold).width(.condensed)),
            ("sans", 700, false, .system(size: 40, weight: .bold)),
            ("rounded", 500, false, .system(size: 40, weight: .medium, design: .rounded)),
            ("monospaced", 400, false, .system(size: 40, design: .monospaced)),
        ]
        for system in systems {
            look.typeface = system.typeface
            look.weight = system.weight
            look.isCondensed = system.condensed
            XCTAssertEqual(
                try pixels("The Lantern Road", look.font(size: 40)),
                try pixels("The Lantern Road", system.font), "\(system.typeface)")
        }
    }

    /// A two-line author's lines center on each other at the tail end of the spine.
    @MainActor func testSpinesCenterATwoLineAuthorsLines() throws {
        let face = try XCTUnwrap(SpineFonts.installedFace(named: "Georgia-Bold"))
        let book = book(1, "Proof", by: "Maximilian Otto Vey")
        var look = SpineLook(book: book, design: nil, face: nil)
        look.face = face
        look.background = ColorValue(red: 2, green: 2, blue: 2)
        look.foreground = ColorValue(red: 229, green: 246, blue: 240)
        let measured = SpineLettering.cached(
            title: "Proof", author: "Maximilian Otto Vey", length: 384, thickness: 43, look: look)
        XCTAssertEqual(measured.author, "Maximilian Otto\nVey")
        let author = try letteringLines(
            SpineView(book: book, look: look).frame(width: 384, height: 43), scale: 2
        )
        .author.map(\.columns)
        XCTAssertEqual(author.count, 2)
        func center(_ columns: ClosedRange<Int>) -> CGFloat {
            CGFloat(columns.lowerBound + columns.upperBound + 1) / 4
        }
        // The given names are several times as wide as the surname, so lines set flush with
        // either end would sit tens of points off center. A point allows for side bearings.
        XCTAssertGreaterThan(author[0].count, 3 * author[1].count)
        XCTAssertEqual(center(author[0]), center(author[1]), accuracy: 1)
    }

    /// One line of lettering in a rendered spine: the rows and the columns of pixels it inks.
    private typealias InkLine = (rows: ClosedRange<Int>, columns: ClosedRange<Int>)

    /// The lines of the title and of the author, where `spine` letters in light ink on dark
    /// cloth. The widest gap between columns of ink separates the title from the author.
    @MainActor private func letteringLines(_ spine: some View, scale: CGFloat) throws
        -> (title: [InkLine], author: [InkLine])
    {
        let renderer = ImageRenderer(content: spine)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let (width, height) = (image.width, image.height)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func ink(_ x: Int, _ y: Int) -> Bool { pixels[y * context.bytesPerRow + x * 4 + 1] > 128 }
        func runs(_ marked: [Bool]) -> [ClosedRange<Int>] {
            var runs: [ClosedRange<Int>] = []
            for index in marked.indices where marked[index] {
                if let last = runs.last, last.upperBound == index - 1 {
                    runs[runs.count - 1] = last.lowerBound...index
                } else {
                    runs.append(index...index)
                }
            }
            return runs
        }
        let columns = runs((0..<width).map { x in (0..<height).contains { ink(x, $0) } })
        let gaps = zip(columns, columns.dropFirst()).map { $1.lowerBound - $0.upperBound }
        let gap = try XCTUnwrap(gaps.indices.max { gaps[$0] < gaps[$1] })
        func lines(in block: ClosedRange<Int>) -> [InkLine] {
            runs((0..<height).map { y in block.contains { ink($0, y) } })
                .compactMap { rows in
                    let inked = block.filter { x in rows.contains { ink(x, $0) } }
                    guard let first = inked.first, let last = inked.last else { return nil }
                    return (rows, first...last)
                }
        }
        return (
            lines(in: columns[0].lowerBound...columns[gap].upperBound),
            lines(in: columns[gap + 1].lowerBound...columns[columns.count - 1].upperBound)
        )
    }

    func testFindingPutsTitlesThatStartWithTheTextFirst() {
        let books = [
            book(1, "Heirs of Tidewater", by: "Rowan Pike"),
            book(2, "Glasshouse Hours", by: "Ines Marlowe"),
            book(3, "Tidewater", by: "Rowan Pike"),
            book(4, "Émile", by: "Tidewater Scribe"),
        ]
        XCTAssertEqual(BookFinding.matches("tidewater", in: books).map(\.id), [3, 1, 4])
        XCTAssertEqual(BookFinding.matches(" emile ", in: books).map(\.id), [4])
        XCTAssertEqual(BookFinding.matches("marlowe", in: books).map(\.id), [2])
        XCTAssertEqual(BookFinding.matches("", in: books).map(\.id), [])
        // Return opens the first match, so a title that is the text itself comes before a longer
        // title that starts with it.
        let series = [
            book(1, "Tidewater Rising", by: "Rowan Pike"), book(2, "Tidewater", by: "Rowan Pike"),
        ]
        XCTAssertEqual(BookFinding.matches("Tidewater", in: series).map(\.id), [2, 1])
    }

    func testSyncStatusNamesTheDayAndTimeThisYearAndEarlierDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = losAngeles
        let yesterday = evening.addingTimeInterval(-24 * 60 * 60)
        let lastYear = calendar.date(byAdding: .year, value: -1, to: evening)!
        // This year's date names the time and leaves out the year; an earlier one is the reverse.
        let recent = LibrarySync.time(of: yesterday, now: evening, calendar: calendar)
        XCTAssertTrue(recent.contains(":"), recent)
        XCTAssertFalse(recent.contains(String(calendar.component(.year, from: evening))), recent)
        let older = LibrarySync.time(of: lastYear, now: evening, calendar: calendar)
        XCTAssertFalse(older.contains(":"), older)
        XCTAssertTrue(older.contains(String(calendar.component(.year, from: lastYear))), older)
    }

    func testSlabThicknessStaysInTheComfortableRange() {
        XCTAssertEqual(book(1, "Short", pages: 40).slabThickness, 44, accuracy: 0.001)
        XCTAssertEqual(book(2, "Long", pages: 2_000).slabThickness, 96, accuracy: 0.001)
        let typical = book(3, "Unknown length").slabThickness
        XCTAssertGreaterThan(typical, 44)
        XCTAssertLessThan(typical, book(4, "Longer", pages: 600).slabThickness)
    }

    func testStackLaysBooksSlightlyAskewWithinTheScreen() {
        let layout = StackArrangement(width: 402)
        let books = (1...200).map { book($0, "Book \($0)", pages: 60 + $0 * 7) }
        for book in books {
            let spine = layout.spine(of: book)
            let shelved = book.shelfSpineSize(scale: layout.scale)
            // As long as on the shelf, and thicker, so lettering lying down stays legible.
            XCTAssertEqual(spine.width, shelved.height)
            XCTAssertGreaterThan(spine.height, shelved.width)
            XCTAssertLessThanOrEqual(
                abs(layout.shift(of: book)), 402 * StackArrangement.maximumShift)
            XCTAssertLessThanOrEqual(
                abs(StackArrangement.twist(of: book)), StackArrangement.maximumTwist)
            // Even the longest book, shifted, stays clear of the screen's edges.
            XCTAssertGreaterThanOrEqual(layout.leading(of: book), StackArrangement.margin - 0.001)
            XCTAssertLessThanOrEqual(
                layout.leading(of: book) + spine.width, 402 - StackArrangement.margin + 0.001)
        }
        XCTAssertLessThanOrEqual(
            layout.scale * CGFloat(BookShape.longest) + 2 * 402 * StackArrangement.maximumShift,
            402 - 2 * StackArrangement.margin + 0.001)
        // Most books face nearly straight out, and the spread is the same on every launch.
        let twists = books.map { abs(StackArrangement.twist(of: $0)) }
        let straight = twists.filter { $0 < StackArrangement.maximumTwist / 2 }.count
        XCTAssertGreaterThan(straight, books.count * 6 / 10)
        XCTAssertEqual(
            StackArrangement.twist(of: book(4, "Renamed", pages: 900)),
            StackArrangement.twist(of: books[3]))
        XCTAssertNotEqual(StackArrangement.twist(of: books[3]), 0)
        // Each book lies flat on the one below it, touching along its length.
        let track = layout.track(of: [books])
        XCTAssertEqual(track.ids, books.map(\.id))
        for index in books.indices.dropLast() {
            let (above, below) = (books[index], books[index + 1])
            let step = (layout.spine(of: above).height + layout.spine(of: below).height) / 2
            XCTAssertEqual(track.offsets[index + 1] - track.offsets[index], step, accuracy: 0.001)
        }
    }

    func testStackMaskHidesTheEndsThenFadesIn() {
        func assertLocations(_ stops: [Gradient.Stop], _ expected: [CGFloat]) {
            XCTAssertEqual(stops.count, expected.count)
            for (stop, location) in zip(stops, expected) {
                XCTAssertEqual(stop.location, location, accuracy: 1e-9)
            }
        }
        let fade = StackArrangement.fade
        let topFade = StackArrangement.topFade
        let stops = StackArrangement.maskStops(height: 1000, top: 30, bottom: 90)
        assertLocations(stops, [0.03, (30 + topFade) / 1000, 1 - (90 + fade) / 1000, 0.91])
        XCTAssertEqual(stops.map(\.color), [.clear, .black, .black, .clear])
        // A short scroll view fades in to its middle, keeping the stops in order.
        assertLocations(
            StackArrangement.maskStops(height: 200, top: 30, bottom: 90),
            [0.15, min(0.5, (30 + topFade) / 200), 0.5, 0.55])
        XCTAssertEqual(StackArrangement.maskStops(height: 0, top: 30, bottom: 90).count, 0)
    }

    func testStackedBooksStartTheirFlightAsTheyLie() {
        let top = book(1, "Top", pages: 300)
        let twist = StackArrangement.twist(of: top)
        let flat = StackStyle.flat.rest(of: top)
        XCTAssertEqual(
            flat.pitch, twist * StackStyle.flatTwist / StackArrangement.maximumTwist,
            accuracy: 1e-12)
        XCTAssertEqual(flat, PullOutPath.Rest(pitch: flat.pitch, slidesInStack: true))
        XCTAssertEqual(
            StackStyle.threeD.rest(of: top),
            PullOutPath.Rest(pitch: twist, lighting: StackStyle.lighting, slidesInStack: true))
    }

    func testStackCameraSeesTheStackFromWhereTheReaderLooks() {
        // A 100 mm lens on a full-frame camera, across the area's diagonal.
        let size = CGSize(width: 402, height: 610)
        let distance = StackCamera.distance(viewing: size)
        XCTAssertEqual(distance / hypot(402, 610), 100 / 43.27, accuracy: 1e-6)
        // About 30 cm from an iPhone's stack, at its 6 points per millimeter.
        XCTAssertEqual(distance / 6 / 10, 28, accuracy: 3)
        // A 200-point-deep underside 60 points above the eye, two thin books up, shows a sliver
        // of about 6 points, as a real book's would from there.
        XCTAssertLessThan(StackCamera.surface(depth: 200, drop: 60, distance: distance), 6.5)
    }

    func testStackBoardRecedesAsThePinholeCameraSeesIt() {
        // A board 250 points deep whose front edge lies on the spines' plane, 1,000 points from
        // the camera and 20 points below the eye. Its back edge, 1,250 points away, projects onto
        // that plane 16 points below the eye, so 4 points of its top show.
        let (distance, depth, drop): (CGFloat, CGFloat, CGFloat) = (1_000, 250, 20)
        let back = drop * distance / (distance + depth)
        let surface = StackCamera.surface(depth: depth, drop: drop, distance: distance)
        XCTAssertEqual(surface, drop - back, accuracy: 1e-9)
        XCTAssertEqual(surface, 4, accuracy: 1e-9)
        // Twice as far below the eye, twice as much shows; at or above it, none does.
        XCTAssertEqual(
            StackCamera.surface(depth: depth, drop: 2 * drop, distance: distance), 2 * surface,
            accuracy: 1e-9)
        XCTAssertEqual(StackCamera.surface(depth: depth, drop: 0, distance: distance), 0)
        XCTAssertEqual(StackCamera.surface(depth: depth, drop: -drop, distance: distance), 0)
    }

    func testOneEyeShowsTopsBelowItAndUndersidesAboveIt() {
        // A book lying on its back, seen as the stack draws it: upright in the model, with its
        // front cover toward +x, which the stack's turn makes the screen's up.
        func book(eye: SIMD2<Double>) -> BookProjection {
            BookProjection(
                width: 200, height: 300, thickness: 40, yaw: .pi / 2, pitch: 0.05,
                distance: 1_000, eye: eye)
        }
        func kinds(_ projection: BookProjection) -> Set<BookProjection.FaceKind> {
            Set(projection.visibleFaces.map(\.kind))
        }
        func apply(_ m: ProjectionTransform, _ p: CGPoint) -> CGPoint {
            let w = p.x * m.m13 + p.y * m.m23 + m.m33
            return CGPoint(
                x: (p.x * m.m11 + p.y * m.m21 + m.m31) / w,
                y: (p.x * m.m12 + p.y * m.m22 + m.m32) / w)
        }
        let level = book(eye: .zero)
        XCTAssertFalse(kinds(level).contains(.front))
        XCTAssertFalse(kinds(level).contains(.back))
        // Below the eye, the front cover, on top, shows; above it, the back cover.
        let below = book(eye: [120, 0])
        let above = book(eye: [-120, 0])
        XCTAssertTrue(kinds(below).contains(.front))
        XCTAssertFalse(kinds(below).contains(.back))
        XCTAssertTrue(kinds(above).contains(.back))
        XCTAssertFalse(kinds(above).contains(.front))
        // The eye keeps the layout and leaves the spine's center in place.
        XCTAssertEqual(below.bounds, level.bounds)
        let spine = { (projection: BookProjection) in
            projection.faces.first { $0.kind == .spine }!
        }
        let middle = CGPoint(x: spine(level).size.width / 2, y: spine(level).size.height / 2)
        let still = apply(spine(level).transform, middle)
        let moved = apply(spine(below).transform, middle)
        XCTAssertEqual(moved.x, still.x, accuracy: 0.5)
        XCTAssertEqual(moved.y, still.y, accuracy: 0.5)
        // The affine correction that scrolling applies matches the projection from the eye.
        for face in level.faces {
            let seen = below.faces.first { $0.kind == face.kind }!
            let correction = level.camera.correction(of: face, from: [120, 0])
            for corner in [
                CGPoint.zero, CGPoint(x: face.size.width, y: 0),
                CGPoint(x: 0, y: face.size.height),
                CGPoint(x: face.size.width, y: face.size.height),
            ] {
                let corrected = apply(face.transform, corner).applying(correction)
                let expected = apply(seen.transform, corner)
                XCTAssertEqual(corrected.x, expected.x, accuracy: 1e-6)
                XCTAssertEqual(corrected.y, expected.y, accuracy: 1e-6)
            }
        }
    }

    func testStackedBooksAreLitFromAbove() {
        // Laid on its back by the stack's quarter turn, a book's top board, its front cover,
        // catches more of the light than its underside does.
        let lying = BookProjection(
            width: 200, height: 300, thickness: 40, yaw: .pi / 2, pitch: 0, distance: 1_000,
            roll: -.pi / 2)
        let shade = { (kind: BookProjection.FaceKind) in
            lying.faces.first { $0.kind == kind }!.shade
        }
        XCTAssertLessThan(shade(.front), shade(.back))
    }

    func testScrollEyeUndoesTheStackedBooksTurnAndScale() {
        // A view 50 by 300 points, scaled by 0.9 and turned a quarter turn back about its
        // center, as the stack lays a book down, centered at (200, 400).
        let size = CGSize(width: 50, height: 300)
        let (scale, roll) = (0.9, -Double.pi / 2)
        let center = CGPoint(x: 200, y: 400)
        func screen(_ p: CGPoint) -> CGPoint {
            let x = (p.x - size.width / 2) * scale
            let y = (p.y - size.height / 2) * scale
            return CGPoint(
                x: center.x + x * cos(roll) - y * sin(roll),
                y: center.y + x * sin(roll) + y * cos(roll))
        }
        let frame = CGRect(
            x: center.x - size.height * scale / 2, y: center.y - size.width * scale / 2,
            width: size.height * scale, height: size.width * scale)
        for local in [CGPoint(x: 10, y: 20), CGPoint(x: -300, y: 120), CGPoint(x: 25, y: 150)] {
            let found = ScrollEye(point: screen(local), roll: roll)
                .point(inViewOf: size, framed: frame)
            XCTAssertEqual(found.x, local.x, accuracy: 1e-9)
            XCTAssertEqual(found.y, local.y, accuracy: 1e-9)
        }
    }

    func testStackKeepsItsLookPastItsEnds() {
        // A stack whose scroll view's ends bring its first book's center, 400 points down its
        // content, and its last book's, 1,252 points farther, to the eye, 400 points down the
        // screen. The board's top ends at its front edge, under the last book.
        let eye = ScrollEye(point: CGPoint(x: 200, y: 400), roll: 0, span: 400...1_652)
        let first = CGRect(x: 40, y: 383.5, width: 300, height: 33)
        let last = CGRect(x: 60, y: 1_635.5, width: 280, height: 33)
        let board = CGRect(x: 0, y: last.maxY - 6, width: 400, height: 6)
        func seen(_ content: CGRect, scrolledTo offset: CGFloat) -> CGRect {
            eye.frame(content.offsetBy(dx: 0, dy: -offset), inContent: content)
        }
        // Between the ends, every view lies where the scroll puts it.
        for offset: CGFloat in [0, 600, 1_252] {
            XCTAssertEqual(seen(last, scrolledTo: offset).minY, last.minY - offset)
        }
        // At the end, the last book lies across the eye, and a sliver of the board's top shows.
        XCTAssertEqual(seen(last, scrolledTo: 1_252).midY, 400)
        let drop = seen(board, scrolledTo: 1_252).maxY - eye.point.y
        XCTAssertGreaterThan(StackCamera.surface(depth: 250, drop: drop, distance: 1_700), 0)
        // Pulled past the end, they keep that look: the last book never rises above the eye to
        // show its underside over the board, and the board's top never hides.
        for past: CGFloat in [1, 120, 400] {
            XCTAssertEqual(seen(last, scrolledTo: 1_252 + past).midY, 400)
            XCTAssertEqual(seen(board, scrolledTo: 1_252 + past).maxY - eye.point.y, drop)
        }
        // Pulled past the start, the first book stays level with the eye.
        for past: CGFloat in [1, 200] {
            XCTAssertEqual(seen(first, scrolledTo: -past).midY, 400)
        }
    }

    func testPulledBookSeesTheEyeAsItsBoxDidInItsPlace() {
        // A 300-by-50-point place, 40 points below and 25 to the left of the eye, holding a
        // turned book seen from 1,700 points in front of the spines.
        let spine = CGSize(width: 300, height: 50)
        let rest = PullOutPath.Rest(pitch: 0.1, distance: Double(1_700 / spine.width + 0.35))
        let (scale, drawn, camera) = StackedBook.fit(spine: spine, aspect: 0.7, rest: rest)
        let eye = CGPoint(x: 200, y: 400)
        let slot = CGRect(x: 25, y: 415, width: spine.width, height: spine.height)
        // The box measures the eye from its own frame: the drawn book, standing on the slot's
        // bottom edge, centered across it.
        let frame = CGRect(
            x: slot.midX - drawn.width / 2, y: slot.maxY - drawn.height, width: drawn.width,
            height: drawn.height)
        let view = CGSize(width: drawn.height / scale, height: drawn.width / scale)
        let box =
            camera.eye(
                at: ScrollEye(point: eye, roll: -.pi / 2).point(inViewOf: view, framed: frame))
            / Double(spine.width)
        let place = StackedBook.eye(
            eye, slot: slot, length: spine.width, scale: scale, drawn: drawn, camera: camera)
        XCTAssertEqual(place.x, box.x, accuracy: 1e-9)
        XCTAssertEqual(place.y, box.y, accuracy: 1e-9)
        // Below the eye, toward the book's top board, and right of the book's middle, toward
        // its tail.
        XCTAssertGreaterThan(place.x, 0)
        XCTAssertGreaterThan(place.y, 0)
    }

    @MainActor func testPullStartsWhereThePointerEasedTheBook() {
        let tapped = book(1, "Tapped", pages: 300)
        let pullOut = ShelfPullOut()
        pullOut.pull(tapped, upright: false)
        XCTAssertEqual(pullOut.progress, 0)
        pullOut.close()
        // A click as the pointer arrives starts with the book barely eased.
        pullOut.nudge(tapped.id)
        pullOut.pull(tapped, upright: false)
        XCTAssertLessThan(pullOut.progress, PullOutPath.nudge * 0.2)
        pullOut.close()
        // The ease runs as the hover's spring does, and settles on the nudge.
        XCTAssertEqual(PullOutPath.nudge(after: 0), 0, accuracy: 1e-9)
        let partway = PullOutPath.nudge(after: 0.08)
        XCTAssertGreaterThan(partway, 0)
        XCTAssertLessThan(partway, PullOutPath.nudge)
        XCTAssertEqual(PullOutPath.nudge(after: 2), PullOutPath.nudge, accuracy: 1e-6)
        // The gap's shadow follows the slide: none in the book's place, all once it is out.
        XCTAssertEqual(PullOutPath.pull(at: 0), 0)
        XCTAssertEqual(PullOutPath.pull(at: PullOutPath.pullEnd), 1)
        XCTAssertLessThan(PullOutPath.pull(at: PullOutPath.nudge), 0.2)
    }

    @MainActor func testANudgedBookStartsItsPullWhereTheShelfDrawsIt() {
        // A 250-point spine that the pointer has eased out of its place (`PullOutPath.nudge`).
        let home = CGRect(x: 100, y: 300, width: 30, height: 250)
        let path = PullOutPath(
            home: home, upright: true, stage: CGRect(x: 0, y: 120, width: 402, height: 380),
            pose: .resting, aspect: 2 / 3)
        // At progress 0, the flight's spine lies exactly on the spine's place.
        let face = Array(flight(path.pose(at: 0), aspect: 2 / 3).points.prefix(4))
        for corner in face {
            XCTAssertTrue([home.minX, home.maxX].contains { abs($0 - corner.x) < 1e-6 })
            XCTAssertTrue([home.minY, home.maxY].contains { abs($0 - corner.y) < 1e-6 })
        }
        // The eased-out spine as `SpineCarousel` draws it: scaled by
        // `pulledScale(at: nudge)` about its bottom edge, unshaded, and casting no shadow.
        let scale = PullOutPath.pulledScale(at: PullOutPath.nudge)
        let spine = MotionSample(
            points: face.map {
                CGPoint(
                    x: home.midX + ($0.x - home.midX) * scale,
                    y: home.maxY + ($0.y - home.maxY) * scale)
            },
            levels: [0, 0, 0])
        var pulled = flight(path.pose(at: PullOutPath.nudge), aspect: 2 / 3)
        pulled.points = Array(pulled.points.prefix(4))
        // If the hover outlasts the flight, a return under the pointer seats the book with the
        // same mismatch.
        XCTExpectFailure(
            "Finding: the flight starts 1.53 pt lower than the spine, with shading 0.13 and a"
                + " shadow of 0.08, because it scales the book about its center and shades it,"
                + " where the spine scales about its bottom edge and is flat."
        ) {
            assertHandoff(spine, pulled, "Shelf pull from a nudge")
        }
    }

    @MainActor func testAPullRightAfterAPeekStartsWhereThePeekHasTheBook() {
        let peeked = book(1, "Peeked", pages: 300)
        for upright in [true, false] {
            let pullOut = ShelfPullOut()
            // A pull as the peek turns back, while `peekID` still names the book, as Return
            // gives when pressed during a peek.
            var shown: Double?
            beforeChange(2, of: \.peekID, in: pullOut) {
                // The book in its place shows the peek's progress while `peekID` names it.
                shown = pullOut.peekID == peeked.id ? PullOutPath.peek : 0
                pullOut.pull(peeked, upright: upright)
            }
            pullOut.peek(peeked.id)
            guard let shown else { return XCTFail("The peek never ended") }
            XCTAssertEqual(shown, PullOutPath.peek)
            // Matching the peek's progress is necessary, not sufficient: SwiftUI animates the
            // view's reading of `peekID`, so a fix must drive the peek through the flight's
            // `progress`, which only video can confirm.
            XCTExpectFailure(
                "Finding: the pull starts at progress 0, where the peek shows 0.15, so the"
                    + " book drops back into its place (on Shelf, the top of a 250-point spine"
                    + " drops 18.75 pt), because ShelfPullOut.start(of:) ignores peekID."
            ) {
                XCTAssertEqual(pullOut.progress, shown, upright ? "Shelf" : "Stack")
            }
        }
    }

    func testShelvedDoorstoppersStandTallerAndThickerThanNovellas() {
        // Every variety of a 900-page book outsizes every variety of a 120-page one.
        let novellas = (1...20).map { book($0, "Novella", pages: 120).shelfSpineSize(scale: 150) }
        let doorstoppers = (21...40)
            .map {
                book($0, "Doorstopper", pages: 900).shelfSpineSize(scale: 150)
            }
        let novella = (
            width: novellas.map(\.width).max()!, height: novellas.map(\.height).max()!
        )
        XCTAssertGreaterThan(doorstoppers.map(\.width).min()!, novella.width * 1.8)
        XCTAssertGreaterThan(doorstoppers.map(\.height).min()!, novella.height)
        // Thin spines keep room for lettering; tall ones stay within the longest book.
        XCTAssertGreaterThanOrEqual(novellas.map(\.width).min()!, 150 * 0.17)
        XCTAssertLessThanOrEqual(
            doorstoppers.map(\.height).max()!, 150 * CGFloat(BookShape.longest) + 0.001)
    }

    /// Details opened from Library draw their book as thick as its spine there, which is the
    /// shape the flight lands it in, so the book keeps its shape: Stack's spine is thicker than
    /// Shelf's, and Shelf's than the book.
    @MainActor func testLibrarySpinesKeepTheirProportionsInTheDetails() {
        /// The proportion the flight from a spine drawn at `home` lands its book in.
        func landed(from home: CGSize, upright: Bool) -> CGFloat {
            PullOutPath(
                home: CGRect(origin: CGPoint(x: 40, y: 200), size: home), upright: upright,
                stage: CGRect(x: 0, y: 120, width: 402, height: 380), pose: .resting,
                aspect: 2 / 3
            )
            .pose(at: 1).thicknessRatio
        }
        for pages in [120, 320, 900] {
            let shelved = book(pages, "Book", pages: pages)
            let stack = StackArrangement(width: 402).spine(of: shelved)
            let shelf = shelved.shelfSpineSize(scale: 150, floor: CloudBook.shelfFloor)
            XCTAssertEqual(
                shelved.librarySpineRatio(upright: false), landed(from: stack, upright: false),
                accuracy: 0.0001)
            XCTAssertEqual(
                shelved.librarySpineRatio(upright: true), landed(from: shelf, upright: true),
                accuracy: 0.0001)
            XCTAssertGreaterThan(
                shelved.librarySpineRatio(upright: false),
                shelved.librarySpineRatio(upright: true))
            XCTAssertGreaterThanOrEqual(
                shelved.librarySpineRatio(upright: true),
                Book3DView.thicknessRatio(of: shelved, cover: nil))
        }
    }

    /// A track of `books` with their detail spines' thicknesses, `spacing` apart.
    private func track(_ books: [CloudBook], spacing: CGFloat) -> SpineTrack {
        SpineTrack(books: books, thickness: \.slabThickness) { _, _ in spacing }
    }

    func testTrackCentersEachSpineAndFindsTheNearest() {
        // 40, 600, and 1,400 pages make spines 44, ~70.6, and 96 points thick.
        let books = [book(1, "A", pages: 40), book(2, "B", pages: 600), book(3, "C", pages: 1_400)]
        let thickness = books.map(\.slabThickness)
        let track = self.track(books, spacing: 6)

        XCTAssertEqual(track.ids, [1, 2, 3])
        XCTAssertEqual(track.offsets[0], 0)
        // Each step is half of each neighbor plus the spacing.
        XCTAssertEqual(track.offsets[1], (thickness[0] + thickness[1]) / 2 + 6, accuracy: 0.001)
        XCTAssertEqual(
            track.offsets[2] - track.offsets[1], (thickness[1] + thickness[2]) / 2 + 6,
            accuracy: 0.001)

        let between = (track.offsets[0] + track.offsets[1]) / 2
        XCTAssertEqual(track.index(nearest: -500), 0)
        XCTAssertEqual(track.index(nearest: between - 0.5), 0)
        XCTAssertEqual(track.index(nearest: between + 0.5), 1)
        XCTAssertEqual(track.index(nearest: 10_000), 2)
        XCTAssertEqual(track.id(nearest: track.offsets[2] - 3), 3)
        XCTAssertEqual(track.offset(of: 3), track.offsets[2])
        XCTAssertEqual(track.offset(of: 99), 0)
        XCTAssertNil(self.track([], spacing: 6).index(nearest: 0))

        // With the end spaces, the last offset is the content's end less the viewport.
        let viewport: CGFloat = 500
        let pagesLength = CGFloat(track.pages.count) * SpineTrack.pageLength
        let content =
            track.leadingSpace(viewport: viewport) + pagesLength
            + track.trailingSpace(viewport: viewport)
        XCTAssertEqual(content - viewport, track.offsets[2], accuracy: 0.001)
    }

    func testTrackPagesHoldTheSpinesCenteredInThem() {
        let books = (1...40).map { book($0, "Book \($0)", pages: 40 + $0 * 37) }
        let track = self.track(books, spacing: 6)
        var start: CGFloat = 0
        var order: [Int] = []
        for (page, slots) in track.pages.enumerated() {
            for slot in slots {
                let pageStart = CGFloat(page) * SpineTrack.pageLength
                let thickness = slot.book.slabThickness
                XCTAssertEqual(pageStart + slot.inset, start, accuracy: 0.001)
                XCTAssertLessThanOrEqual(pageStart, start + thickness / 2)
                XCTAssertLessThan(start + thickness / 2, pageStart + SpineTrack.pageLength)
                start += thickness + 6
                order.append(slot.id)
            }
        }
        XCTAssertEqual(order, track.ids)
    }

    func testColumnsRestOnOneLineAndScrollTogether() {
        let left = (1...5).map { book($0, "Left \($0)", pages: 40 + $0 * 90) }
        let right = (6...8).map { book($0, "Right \($0)", pages: 300) }
        let track = SpineTrack(columns: [left, right], thickness: \.slabThickness) { _, _ in 0 }
        XCTAssertEqual(track.ids, (left + right).map(\.id))
        XCTAssertEqual(track.columns, [0..<5, 5..<8])

        var starts: [Int: CGFloat] = [:]
        for (page, slots) in track.pages.enumerated() {
            for slot in slots {
                XCTAssertTrue(track.columns[slot.column].contains(slot.index))
                starts[slot.index] = CGFloat(page) * SpineTrack.pageLength + slot.inset
            }
        }
        let thickness = (left + right).map(\.slabThickness)
        for column in track.columns {
            // Each book touches the one below it, and the bottom books end together.
            for index in column.dropLast() {
                XCTAssertEqual(
                    starts[index]! + thickness[index], starts[index + 1]!, accuracy: 0.001)
            }
            let last = column.upperBound - 1
            XCTAssertEqual(starts[last]! + thickness[last], track.length, accuracy: 0.001)
        }
        // One offset centers a spine in either column, the higher first spine at 0.
        let center = { (index: Int) in starts[index]! + thickness[index] / 2 }
        XCTAssertEqual(
            track.offsets[6] - track.offsets[1], center(6) - center(1), accuracy: 0.001)
        XCTAssertEqual(min(track.offsets[0], track.offsets[5]), 0, accuracy: 0.001)
        XCTAssertEqual(track.index(nearest: track.offsets[6], in: 1), 6)
        XCTAssertEqual(track.index(nearest: -500, in: 1), 5)
        XCTAssertEqual(track.index(nearest: track.offsets[2] + 1, in: 0), 2)
        XCTAssertNil(track.index(nearest: 0, in: 2))
        XCTAssertEqual(track.column(of: 7), 1)
        XCTAssertEqual(track.column(of: 99), 0)
        // Above the shorter right stack's top, the left stack reports the centered book.
        XCTAssertLessThan(track.offsets[0], track.offsets[5])
        let rightStart = starts[5]! - min(center(0), center(5))
        XCTAssertEqual(track.column(at: rightStart + 1, preferring: 1), 1)
        XCTAssertEqual(track.column(at: rightStart - 1, preferring: 1), 0)
        XCTAssertEqual(track.column(at: rightStart - 1, preferring: 0), 0)
        XCTAssertEqual(track.column(at: -500, preferring: 1), 1)

        // Every column's first and last spines can reach the center.
        let viewport: CGFloat = 500
        XCTAssertEqual(
            track.leadingSpace(viewport: viewport), viewport / 2 - min(center(0), center(5)),
            accuracy: 0.001)
        let content =
            track.leadingSpace(viewport: viewport)
            + CGFloat(track.pages.count) * SpineTrack.pageLength
            + track.trailingSpace(viewport: viewport)
        XCTAssertEqual(
            content - viewport, max(track.offsets[4], track.offsets[7]), accuracy: 0.001)
    }

    @MainActor func testStacksKeepTheirCountAndAPulledBookInView() {
        // The stacks' areas in the Mac's default window and a taller one, in wider windows, one
        // with space to spare beside its books, and the smallest window, with their stack counts.
        let areas: [(CGSize, Int)] = [
            (CGSize(width: 1_036, height: 628), 2), (CGSize(width: 1_036, height: 900), 2),
            (CGSize(width: 1_000, height: 640), 2), (CGSize(width: 1_200, height: 700), 2),
            (CGSize(width: 1_460, height: 700), 3), (CGSize(width: 1_500, height: 800), 3),
            (CGSize(width: 2_400, height: 1_300), 5), (CGSize(width: 615, height: 380), 1),
        ]
        for (area, count) in areas {
            for style in [StackStyle.flat, .threeD] {
                // Without room kept, as on the iPhone, the stacks span the area.
                let phone = StackArrangement.layout(
                    in: area, books: 40, style: style, keepsRoom: false)
                XCTAssertEqual(phone.room, 0)
                XCTAssertEqual(phone.arrangement.width, area.width / CGFloat(phone.columns))
                // The Mac's stacks keep room for a pulled book at their outer ends.
                let (columns, stacks, room) = StackArrangement.layout(
                    in: area, books: 40, style: style, keepsRoom: true)
                // The width alone sets the count, in both styles and at any height.
                XCTAssertEqual(columns, count, "\(area) \(style)")
                XCTAssertEqual(phone.columns, count, "\(area) \(style)")
                XCTAssertEqual(
                    room * 2 + CGFloat(columns) * stacks.width, area.width, accuracy: 0.001)
                // The longest book with the narrowest and the widest cover, lying as far out as
                // a book lies and turned to face out, at the outer end of the first stack and
                // the last, drawn as the stack draws it at the end of its slide out of its place.
                let length = stacks.scale * CGFloat(BookShape.longest)
                let aspects = [Book3DView.aspects.lowerBound, Book3DView.aspects.upperBound]
                let camera = style == .threeD ? StackCamera.distance(viewing: area) : nil
                let shift = stacks.width * StackArrangement.maximumShift
                let middles = [
                    room + stacks.width / 2 - shift, area.width - room - stacks.width / 2 + shift,
                ]
                let twists = [style.maximumTwist, -style.maximumTwist]
                var clearances: [CGFloat] = []
                for (middle, twist) in zip(middles, twists) {
                    for aspect in aspects {
                        let rest = PullOutPath.Rest(
                            pitch: twist,
                            distance: camera.map {
                                StackedBook.cameraDistance(
                                    camera: $0, length: length, aspect: aspect)
                            })
                        let (_, drawn, _) = StackedBook.fit(
                            spine: CGSize(width: length, height: length / 5), aspect: aspect,
                            rest: rest)
                        let slide = PullOutPath.slide(
                            at: 1, length: length, thickness: length / 5, extent: drawn.height,
                            rest: rest)
                        // It comes out toward the side it faces.
                        XCTAssertEqual(slide.offset.width < 0, twist > 0)
                        let half = drawn.width * slide.scale / 2
                        let left = middle - half + slide.offset.width
                        let right = middle + half + slide.offset.width
                        clearances += [left, area.width - right]
                    }
                }
                let clear = clearances.min() ?? 0
                XCTAssertGreaterThanOrEqual(clear, 0, "\(area) \(style)")
                // The stacks narrow no more than the book needs.
                if room > 0 { XCTAssertLessThan(clear, 0.5, "\(area) \(style)") }
            }
        }
    }

    func testShelfTrackLaysOutTheShelvedSpines() {
        let books = (1...40).map { book($0, "Book \($0)", pages: 60 + $0 * 33) }
        let widths = books.map { $0.shelfSpineSize(scale: 150).width }
        let track = SpineTrack(books: books) {
            $0.shelfSpineSize(scale: 150).width
        } gap: { _, _ in
            1
        }
        XCTAssertEqual(
            track.length, widths.reduce(0, +) + CGFloat(books.count - 1), accuracy: 0.001)
        // The shelf's scroll view reaches past the screen by half of this.
        XCTAssertEqual(track.maxThickness, widths.max()!)
        var start: CGFloat = 0
        var order: [Int] = []
        for (page, slots) in track.pages.enumerated() {
            for slot in slots {
                let pageStart = CGFloat(page) * SpineTrack.pageLength
                XCTAssertEqual(pageStart + slot.inset, start, accuracy: 0.001)
                XCTAssertEqual(slot.index, order.count)
                start += widths[slot.index] + 1
                order.append(slot.id)
            }
        }
        XCTAssertEqual(order, track.ids)
    }

    func testCoastSpringsFromTheShownPoseToTheTarget() {
        let start = Date(timeIntervalSince1970: 1_000)
        let coast = Coast(
            from: BookPose(yaw: 0, pitch: 0.2), to: BookPose(yaw: 3, pitch: -0.12), start: start)
        XCTAssertEqual(coast.pose(at: start), coast.from)
        let midway = coast.pose(at: start.addingTimeInterval(0.3))
        XCTAssertGreaterThan(midway.yaw, 0)
        XCTAssertLessThan(midway.pitch, 0.2)
        let settled = coast.pose(at: start.addingTimeInterval(Coast.spring.settlingDuration))
        XCTAssertEqual(settled.yaw, 3, accuracy: 0.01)
        XCTAssertEqual(settled.pitch, -0.12, accuracy: 0.01)
    }

    @MainActor func testACoastEndsWhereItsSpringLeavesTheBook() {
        let start = Date(timeIntervalSince1970: 1_000)
        let settled = start.addingTimeInterval(Coast.spring.settlingDuration)
        // Half a turn, and the turn that the fastest fling gives: 2,000 points of momentum.
        let targets = [
            BookPose(yaw: BookPose.resting.yaw + .pi, pitch: BookPose.resting.pitch),
            BookPose.resting.turned(by: CGSize(width: 2_000, height: 0)),
        ]
        for target in targets {
            let coast = Coast(from: .resting, to: target, start: start)
            let kinds = BookProjection(
                width: 380 * 2 / 3, height: 380, thickness: 380 * 0.08, yaw: target.yaw,
                pitch: target.pitch
            )
            .visibleFaces.map(\.kind)
            // `TurningBook` ends the coast once its spring settles, and the book then shows the
            // coast's target.
            assertHandoff(
                details(coast.pose(at: settled), kinds: kinds), details(target, kinds: kinds),
                String(format: "The end of a %.1f-radian coast", target.yaw - coast.from.yaw))
        }
    }

    func testDriftEasesInFromRestThenFloatsAtFullAmplitude() {
        let start = Date(timeIntervalSince1970: 1_000)
        let drift = Drift(start: start)
        func offset(_ seconds: Double) -> Drift.Offset {
            drift.offset(at: start.addingTimeInterval(seconds))
        }
        // No offset at arrival or before it, and no velocity: the book leaves its pose smoothly.
        for seconds in [-1.0, 0] {
            XCTAssertEqual(offset(seconds).translation, .zero)
            XCTAssertEqual(offset(seconds).yaw, 0)
        }
        let step = 0.01
        XCTAssertEqual(offset(step).translation.width / step, 0, accuracy: 1e-4)
        XCTAssertEqual(offset(step).translation.height / step, 0, accuracy: 1e-4)
        XCTAssertEqual(offset(step).yaw / step, 0, accuracy: 1e-6)
        // From the end of the ramp, each wave reaches its full amplitude a quarter period in.
        XCTAssertEqual(offset(10).translation.height, -Drift.verticalAmplitude, accuracy: 1e-9)
        XCTAssertEqual(offset(12).translation.width, Drift.horizontalAmplitude, accuracy: 1e-9)
        XCTAssertEqual(offset(15).yaw, Drift.swayAmplitude, accuracy: 1e-12)
        XCTAssertEqual(
            offset(Drift.rampDuration).translation.height,
            -Drift.verticalAmplitude * sin(2 * .pi * Drift.rampDuration / 40), accuracy: 1e-9)
        // It moves noticeably within ten seconds, and never past its amplitudes.
        XCTAssertGreaterThan(abs(offset(6).translation.height), 10)
        for seconds in stride(from: 0.0, through: 240, by: 0.25) {
            let sample = offset(seconds)
            XCTAssertLessThanOrEqual(abs(sample.translation.width), Drift.horizontalAmplitude)
            XCTAssertLessThanOrEqual(abs(sample.translation.height), Drift.verticalAmplitude)
            XCTAssertLessThanOrEqual(abs(sample.yaw), Drift.swayAmplitude)
        }
    }

    @MainActor func testAReturnStartsWhereTheDriftHasTheBook() {
        let drifting = book(1, "Drifting", pages: 300)
        let pullOut = ShelfPullOut()
        pullOut.pull(drifting, upright: true)
        pullOut.home = CGRect(x: 100, y: 300, width: 30, height: 250)
        pullOut.stage = CGRect(x: 0, y: 120, width: 402, height: 380)
        pullOut.fly()
        XCTAssertEqual(pullOut.progress, 1)
        pullOut.float = Drift.Offset(translation: CGSize(width: 12, height: -8), yaw: 0.03)
        // The book at progress 1, laid out as `PullOutFlightHost` lays it out.
        func landed() -> MotionSample {
            let path = PullOutPath(
                home: pullOut.home ?? .zero, upright: pullOut.upright,
                stage: pullOut.stage ?? .zero, pose: pullOut.pose, aspect: 2 / 3,
                rest: pullOut.rest, eye: pullOut.eye ?? .zero)
            return flight(path.pose(at: 1), aspect: 2 / 3, float: pullOut.float)
        }
        let drifted = landed()
        // The return's first frame: **Back** has moved the stage and the drift, and the return
        // has yet to move the book from progress 1.
        var returning: MotionSample?
        beforeChange(of: \.progress, in: pullOut) {
            XCTAssertTrue(pullOut.isReturning)
            returning = landed()
        }
        pullOut.putBack()
        guard let returning else { return XCTFail("The return never started") }
        assertHandoff(drifted, returning, "A return from the drift")
    }

    func testTurnMovesTheMostFacingFaceExactlyAndTheRestClose() {
        let (height, pose, sway) = (380.0, BookPose.resting, Drift.swayAmplitude)
        func projection(thickness: Double, yaw: Double) -> BookProjection {
            BookProjection(
                width: height * 2 / 3, height: height, thickness: thickness, yaw: yaw,
                pitch: pose.pitch)
        }
        XCTAssertEqual(projection(thickness: 30, yaw: pose.yaw).turn(by: 0), ProjectionTransform())
        for thickness in [12.0, 30, 60] {
            for angle in [sway, -sway] {
                let base = projection(thickness: thickness, yaw: pose.yaw)
                let turned = projection(thickness: thickness, yaw: pose.yaw + angle)
                let turn = base.turn(by: angle)
                // Each projection shifts its own bounds into the view; the turn keeps the base's.
                let shift = base.camera.offset - turned.camera.offset
                func error(of kind: BookProjection.FaceKind) -> CGFloat {
                    let drawn = corners(of: [kind], in: base).map { $0.applying(turn) }
                    let truth = corners(of: [kind], in: turned)
                        .map { CGPoint(x: $0.x + CGFloat(shift.x), y: $0.y + CGFloat(shift.y)) }
                    XCTAssertEqual(drawn.count, 4)
                    return zip(drawn, truth).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
                }
                XCTAssertEqual(error(of: .front), 0, accuracy: 1e-6)
                // The spine's back edge lies `thickness` behind the cover's plane.
                XCTAssertLessThan(error(of: .spine), thickness * abs(angle) * 1.25)
            }
        }
    }

    /// The corners of `projection`'s faces of `kinds`, in the view's coordinates, four for each
    /// face in its own order, and none for a face turned too far from the view to be laid out.
    private func corners(
        of kinds: [BookProjection.FaceKind], in projection: BookProjection
    ) -> [CGPoint] {
        kinds.flatMap { kind -> [CGPoint] in
            guard let face = projection.faces.first(where: { $0.kind == kind }) else { return [] }
            let (width, height) = (face.size.width, face.size.height)
            return [
                .zero, CGPoint(x: width, y: 0), CGPoint(x: 0, y: height),
                CGPoint(x: width, y: height),
            ]
            .map { $0.applying(face.transform) }
        }
    }

    /// `pose` as `PullOutFlight` draws it: the corners of the book's spine and then its front
    /// cover, turned and moved by the drift's `float` (`PullOutFloat`), scaled and turned in the
    /// screen's plane about the middle of the book's bounds, and centered on `pose.center`; and
    /// its shading, shadow, and veil.
    private func flight(
        _ pose: PullOutPath.Pose, aspect: CGFloat, float: Drift.Offset = .zero
    ) -> MotionSample {
        let projection = BookProjection(
            width: pose.height * aspect, height: pose.height,
            thickness: pose.height * pose.thicknessRatio, yaw: pose.yaw, pitch: pose.pitch,
            distance: Double(pose.distance), eye: pose.eye)
        let sway = projection.turn(by: float.yaw * pose.lift)
        let middle = CGPoint(x: projection.bounds.width / 2, y: projection.bounds.height / 2)
        let (cosine, sine) = (cos(pose.roll), sin(pose.roll))
        let points = corners(of: [.spine, .front], in: projection)
            .map { corner in
                let swayed = corner.applying(sway)
                let x = (swayed.x + float.translation.width - middle.x) * pose.scale
                let y = (swayed.y + float.translation.height - middle.y) * pose.scale
                return CGPoint(
                    x: pose.center.x + x * cosine - y * sine,
                    y: pose.center.y + x * sine + y * cosine)
            }
        return MotionSample(points: points, levels: [pose.lighting, pose.shadow, pose.lift])
    }

    /// `pose` as the details draw their 380-point book (`TurningBook.bookHeight`): the corners of
    /// its faces of `kinds`, with the book's projected bounds centered on the stage's middle.
    private func details(_ pose: BookPose, kinds: [BookProjection.FaceKind]) -> MotionSample {
        let projection = BookProjection(
            width: 380 * 2 / 3, height: 380, thickness: 380 * 0.08, yaw: pose.yaw,
            pitch: pose.pitch)
        let (dx, dy) = (projection.bounds.width / 2, projection.bounds.height / 2)
        return MotionSample(
            points: corners(of: kinds, in: projection).map { CGPoint(x: $0.x - dx, y: $0.y - dy) })
    }

    /// The size `pose` draws a book at on screen, before its roll: its projected bounds, scaled.
    private func drawnSize(_ pose: PullOutPath.Pose, aspect: CGFloat) -> CGSize {
        let projection = BookProjection(
            width: pose.height * aspect, height: pose.height,
            thickness: pose.height * pose.thicknessRatio, yaw: pose.yaw, pitch: pose.pitch,
            distance: Double(pose.distance))
        return CGSize(
            width: projection.bounds.width * pose.scale,
            height: projection.bounds.height * pose.scale)
    }

    func testPulledBookStartsAsItsSpineAndLandsInTheStage() {
        let home = CGRect(x: 100, y: 300, width: 30, height: 280)
        let stage = CGRect(x: 0, y: 120, width: 402, height: 380)
        let path = PullOutPath(
            home: home, upright: true, stage: stage, pose: .resting, aspect: 2 / 3)

        // The book lays its spine out at the shelf spine's size and draws it exactly over it.
        let start = path.pose(at: 0)
        XCTAssertEqual(start.height, 280, accuracy: 0.001)
        XCTAssertEqual(start.height * start.thicknessRatio, 30, accuracy: 0.001)
        XCTAssertEqual(start.yaw, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(start.roll, 0)
        XCTAssertEqual(start.center, CGPoint(x: 115, y: 440))
        XCTAssertEqual(start.lift, 0)
        // Unshaded and casting no shadow, as the flat spine it replaces.
        XCTAssertEqual(start.lighting, 0)
        XCTAssertEqual(start.shadow, 0)
        let size = drawnSize(start, aspect: 2 / 3)
        XCTAssertEqual(size.width, 30, accuracy: 0.01)
        XCTAssertEqual(size.height, 280, accuracy: 0.01)
        // A spring's undershoot leaves the book in its place.
        XCTAssertEqual(path.pose(at: -0.1), start)

        // The slide out grows the spine toward the reader without moving or turning it, and
        // its shadow shows.
        let pulled = path.pose(at: PullOutPath.floatStart)
        XCTAssertGreaterThan(pulled.scale / start.scale, 1.1)
        XCTAssertLessThanOrEqual(pulled.scale / start.scale, PullOutPath.pullScale)
        XCTAssertEqual(pulled.center, start.center)
        XCTAssertEqual(pulled.yaw, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(pulled.height, 280, accuracy: 0.001)
        XCTAssertGreaterThan(pulled.shadow, 0.5)

        // It lands in the details' pose, size, and place, in the shape it had on the shelf.
        let end = path.pose(at: 1)
        XCTAssertEqual(end.height, 380, accuracy: 0.001)
        XCTAssertEqual(end.scale, 1, accuracy: 0.0001)
        for progress in stride(from: 0.0, through: 1, by: 0.05) {
            XCTAssertEqual(path.pose(at: progress).thicknessRatio, 30.0 / 280, accuracy: 0.0001)
        }
        XCTAssertEqual(end.yaw, BookPose.resting.yaw, accuracy: 0.0001)
        XCTAssertEqual(end.pitch, BookPose.resting.pitch, accuracy: 0.0001)
        XCTAssertEqual(end.center.x, stage.midX, accuracy: 0.001)
        XCTAssertEqual(end.center.y, stage.midY, accuracy: 0.001)
        XCTAssertEqual(end.lift, 1, accuracy: 0.0001)
        XCTAssertEqual(end.lighting, 1, accuracy: 0.0001)
        XCTAssertEqual(end.shadow, 0, accuracy: 0.0001)
        XCTAssertEqual(path.pose(at: 1.2), end)
    }

    func testPulledBookLeavesItsPlaceBeforeItTurnsAndTheShelfDims() {
        let path = PullOutPath(
            home: CGRect(x: 100, y: 200, width: 60, height: 420), upright: true,
            stage: CGRect(x: 0, y: 150, width: 402, height: 380), pose: .resting, aspect: 2 / 3)
        for step in 0...1000 {
            let progress = Double(step) / 1000
            let pose = path.pose(at: progress)
            if progress <= PullOutPath.turnStart {
                XCTAssertEqual(pose.yaw, .pi / 2, accuracy: 0.0001)
                XCTAssertEqual(pose.pitch, 0, accuracy: 0.0001)
            }
            if progress <= PullOutPath.veilStart { XCTAssertEqual(pose.lift, 0) }
        }
        // It has almost finished its slide out, and its shading has faded in, by the time it
        // turns.
        let turning = path.pose(at: PullOutPath.turnStart)
        XCTAssertGreaterThan(turning.scale / path.pose(at: 0).scale, 1.13)
        XCTAssertEqual(turning.lighting, 1, accuracy: 0.0001)
        XCTAssertLessThan(path.pose(at: PullOutPath.turnStart + 0.05).yaw, .pi / 2)
    }

    func testPulledBookMovesSmoothlyWithoutStopping() {
        let path = PullOutPath(
            home: CGRect(x: 250, y: 320, width: 40, height: 300),
            upright: true, stage: CGRect(x: 0, y: 100, width: 402, height: 380),
            pose: .resting, aspect: 0.66)
        var previous = path.pose(at: 0)
        var previousSize = drawnSize(previous, aspect: 0.66).height
        for step in 1...1000 {
            let pose = path.pose(at: Double(step) / 1000)
            let size = drawnSize(pose, aspect: 0.66).height
            // No jumps between neighboring moments.
            XCTAssertLessThan(abs(pose.center.y - previous.center.y), 1)
            XCTAssertLessThan(abs(pose.yaw - previous.yaw), 0.01)
            XCTAssertLessThan(abs(size - previousSize), 1)
            // The book never turns back on its way, and the shelf never brightens.
            XCTAssertLessThanOrEqual(pose.yaw, previous.yaw + 0.0001)
            XCTAssertGreaterThanOrEqual(pose.lift, previous.lift)
            previous = pose
            previousSize = size
        }
    }

    @MainActor func testPullsMoveWithoutJumpsAndEaseFromEachPartIntoTheNext() {
        let stage = CGRect(x: 0, y: 100, width: 402, height: 380)
        let shelf = CGRect(x: 100, y: 300, width: 30, height: 250)
        // The return of a book the reader spun.
        let spun = PullOutPath(
            home: shelf, upright: true, stage: stage,
            pose: BookPose(yaw: BookPose.resting.yaw + 4 * .pi + 0.3, pitch: 0.2), aspect: 2 / 3)
        let paths: [(name: String, path: PullOutPath, returns: Bool)] = [
            (
                "Shelf",
                PullOutPath(
                    home: shelf, upright: true, stage: stage, pose: .resting, aspect: 2 / 3), false
            ),
            ("Shelf return", spun, true),
            (
                "2D Stack",
                PullOutPath(
                    home: CGRect(x: 20, y: 400, width: 362, height: 65), upright: false,
                    stage: stage, pose: .resting, aspect: 2 / 3,
                    rest: PullOutPath.Rest(pitch: 0.05, slidesInStack: true)), false
            ),
            (
                "3D Stack",
                PullOutPath(
                    home: CGRect(x: 40, y: 400, width: 280, height: 32), upright: false,
                    stage: stage, pose: .resting, aspect: 2 / 3,
                    rest: PullOutPath.Rest(yaw: -0.3, pitch: 0.2, lighting: 0.6, distance: 3.6),
                    eye: [0.05, -0.02]), false
            ),
        ]
        let steps = (0...10_000).map { Double($0) / 10_000 }
        for (name, path, returns) in paths {
            let progress = returns ? steps.reversed() : steps
            let trace = progress.map { flight(path.pose(at: $0), aspect: 2 / 3) }
            assertContinuous(trace, name)
            // Each part of the flight starts or ends at rest, so the book never lurches where
            // one part takes over from another.
            let seams =
                path.upright
                ? [
                    PullOutPath.floatStart, PullOutPath.turnStart, PullOutPath.pullEnd,
                    PullOutPath.veilStart,
                ]
                : [PullOutPath.pullEnd, PullOutPath.veilStart]
            for seam in seams {
                guard let index = progress.firstIndex(of: seam) else {
                    XCTFail("\(name): no sample at \(seam)")
                    continue
                }
                assertSeam(
                    trace, at: index, step: 1e-4 * ShelfPullOut.openingDuration,
                    "\(name) at \(seam)")
            }
            // Until it floats, the book comes straight out along the way its spine faces: on
            // Shelf, without moving, and on Stack, along its slide's offset.
            let floats = path.upright ? PullOutPath.floatStart : PullOutPath.pullEnd
            let start = path.pose(at: 0).center
            let out = path.pose(at: floats).center
            let way = CGVector(dx: out.x - start.x, dy: out.y - start.y)
            let stray =
                steps.filter { $0 <= floats }
                .map { progress -> CGFloat in
                    let center = path.pose(at: progress).center
                    let (dx, dy) = (center.x - start.x, center.y - start.y)
                    let length = hypot(way.dx, way.dy)
                    return length > 0 ? abs(dx * way.dy - dy * way.dx) / length : hypot(dx, dy)
                }
                .max() ?? 0
            XCTAssertLessThan(stray, 1e-6, name)
            XCTAssertEqual(path.upright, out == start, name)
        }
        // A return starts with the drift's sway, which eases out as the book leaves the stage.
        let swaying = steps.reversed()
            .map {
                flight(
                    spun.pose(at: $0), aspect: 2 / 3,
                    float: Drift.Offset(translation: .zero, yaw: Drift.swayAmplitude))
            }
        XCTExpectFailure(
            "Finding: the front cover's fore edge jumps 12.9 pt at a 1.8-degree sway where the"
                + " book turns through 45 degrees, because BookProjection.turn(by:) switches the"
                + " face it turns exactly from the spine to the front,"
                + " and PullOutFloat sways the book with it."
        ) {
            assertContinuous(swaying, "Shelf return with the drift's sway")
        }
    }

    func testStackedBookStandsUpAndSpunBookTurnsBackTheShortWay() {
        let home = CGRect(x: 20, y: 400, width: 362, height: 65)
        let spun = BookPose(yaw: BookPose.resting.yaw + 4 * .pi + 0.3, pitch: 0.2)
        let path = PullOutPath(
            home: home, upright: false, stage: CGRect(x: 0, y: 100, width: 402, height: 380),
            pose: spun, aspect: 2 / 3)

        // Lying flat, head on the left: the upright spine turned a quarter turn back.
        let start = path.pose(at: 0)
        XCTAssertEqual(start.roll, -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(start.height, 362, accuracy: 0.001)
        XCTAssertEqual(start.height * start.thicknessRatio, 65, accuracy: 0.001)
        let size = drawnSize(start, aspect: 2 / 3)
        XCTAssertEqual(size.width, 65, accuracy: 0.01)
        XCTAssertEqual(size.height, 362, accuracy: 0.01)
        XCTAssertLessThan(abs(start.yaw - spun.yaw), .pi)
        XCTAssertEqual(sin(start.yaw), 1, accuracy: 0.0001)

        // A book that faces straight out comes straight toward the reader before it stands up.
        let slid = path.pose(at: PullOutPath.turnStart)
        XCTAssertEqual(slid.center.x, home.midX, accuracy: 0.001)
        XCTAssertGreaterThan(slid.scale / start.scale, 1.1)
        XCTAssertEqual(slid.roll, -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(slid.yaw, start.yaw, accuracy: 0.0001)
        // It lies level until the shelf starts to dim, so it never tilts across the books it
        // has just left, then stands up.
        let level = path.pose(at: PullOutPath.veilStart)
        XCTAssertEqual(level.roll, -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(level.yaw, start.yaw, accuracy: 0.0001)
        XCTAssertGreaterThan(level.scale * level.height, slid.scale * slid.height)
        XCTAssertGreaterThan(path.pose(at: PullOutPath.veilStart + 0.05).roll, -.pi / 2)

        let end = path.pose(at: 1)
        XCTAssertEqual(end.roll, 0, accuracy: 0.0001)
        XCTAssertEqual(end.yaw, spun.yaw, accuracy: 0.0001)
        XCTAssertEqual(end.pitch, spun.pitch, accuracy: 0.0001)
    }

    func testStackNeighborsAboveMakeRoomOutwardThenSettle() {
        let open = { (distance: Int, room: Double) in
            StackRoom.offset(distance: distance, room: room, closing: 0)
        }
        // The pulled book, every book while none is pulled, and the books below it, which rest
        // on the board, stay put.
        for room in [0.0, 0.3, 1] {
            for distance in [0, 1, 2, 12] {
                XCTAssertEqual(open(distance, room), 0)
            }
        }
        // Before the pull, nothing has moved.
        for distance in [-3, -1] {
            XCTAssertEqual(open(distance, 0), 0)
        }
        // Once settled, books above are up, the nearest by `near` and farther ones a little more,
        // up to `far`.
        XCTAssertEqual(open(-1, 1), -StackRoom.near, accuracy: 0.1)
        XCTAssertLessThan(open(-2, 1), open(-1, 1))
        XCTAssertEqual(
            open(-20, 1), -(StackRoom.far - (StackRoom.far - StackRoom.near) / 20), accuracy: 0.3)
        // The nudge spreads outward: a farther book starts later, and the overshoot stays small.
        XCTAssertLessThan(open(-1, 0.1), open(-4, 0.1))
        XCTAssertEqual(open(-8, 0.1), 0)
        for distance in [-1, -2, -5, -12] {
            var peak: CGFloat = 0
            var previous: CGFloat = 0
            for step in 0...200 {
                let rise = -open(distance, Double(step) / 200)
                XCTAssertLessThan(abs(rise - previous), 0.6, "no jump at step \(step)")
                peak = max(peak, rise)
                previous = rise
            }
            XCTAssertLessThan(peak, StackRoom.far * 1.2)
            XCTAssertGreaterThan(peak, StackRoom.near)
        }
    }

    func testStackNeighborsSnapShutWithoutOverlappingTheReturnedBook() {
        // The books hold their room until the snap starts, and are back in place when it ends.
        XCTAssertEqual(
            StackRoom.offset(distance: -1, room: 1, closing: 0), -StackRoom.near, accuracy: 0.1)
        XCTAssertEqual(StackRoom.offset(distance: -3, room: 1, closing: 1), 0)
        for distance in [-12, -5, -2, -1] {
            var rebounded = false
            var previous = StackRoom.offset(distance: distance, room: 1, closing: 0)
            for step in 0...400 {
                let offset = StackRoom.offset(
                    distance: distance, room: 1, closing: Double(step) / 400)
                // A book above stays at or above its place.
                XCTAssertLessThanOrEqual(offset, 0)
                if abs(offset) > abs(previous) { rebounded = true }
                previous = offset
            }
            XCTAssertTrue(rebounded, "a book \(-distance) places above rebounds")
            XCTAssertLessThan(
                abs(StackRoom.offset(distance: distance, room: 1, closing: 0.999)), 0.05)
        }
        // The snap spreads outward like the opening.
        XCTAssertLessThan(
            abs(StackRoom.offset(distance: -1, room: 1, closing: 0.15)),
            abs(StackRoom.offset(distance: -6, room: 1, closing: 0.15)))
    }

    func testThreeDStackedBookStartsAsItLiesAndLandsInTheDetails() {
        let home = CGRect(x: 40, y: 400, width: 280, height: 32)
        // Seen by the stack's camera, about 3.6 lengths from its center, from a little above.
        let rest = PullOutPath.Rest(pitch: 0.2, lighting: 0.6, distance: 3.6)
        let eye = SIMD2<Double>(0.05, -0.02)
        let path = PullOutPath(
            home: home, upright: false, stage: CGRect(x: 0, y: 100, width: 402, height: 380),
            pose: .resting, aspect: 2 / 3, rest: rest, eye: eye)

        // Drawn as the stack draws it: turned, shaded, and seen from the stack's eye.
        let start = path.pose(at: 0)
        XCTAssertEqual(start.center, CGPoint(x: home.midX, y: home.midY))
        XCTAssertEqual(start.height, 280, accuracy: 0.001)
        XCTAssertEqual(start.thicknessRatio, 32 / 280, accuracy: 0.0001)
        XCTAssertEqual(
            start.scale,
            1
                / PullOutPath.spineMagnification(
                    aspect: 2 / 3, thicknessRatio: 32 / 280, distance: 3.6),
            accuracy: 0.0001)
        XCTAssertEqual(start.distance, 3.6 * 280, accuracy: 0.001)
        XCTAssertEqual(start.eye.x, 0.05 * 280, accuracy: 0.001)
        XCTAssertEqual(start.eye.y, -0.02 * 280, accuracy: 0.001)
        XCTAssertEqual(start.roll, -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(sin(start.yaw - rest.yaw), 1, accuracy: 0.0001)
        XCTAssertEqual(start.pitch, 0.2, accuracy: 0.0001)
        XCTAssertEqual(start.lighting, 0.6, accuracy: 0.0001)
        XCTAssertEqual(path.pose(at: -0.1), start)
        // Turned to face a little left, it comes out toward the reader and a little left,
        // growing about its middle, as a book coming straight toward the stack's eye does.
        let pulled = path.pose(at: PullOutPath.floatStart)
        XCTAssertLessThan(pulled.center.x, start.center.x)
        XCTAssertEqual(pulled.center.y, start.center.y, accuracy: 0.001)
        XCTAssertGreaterThan(pulled.scale / start.scale, 1.1)
        XCTAssertEqual(pulled.roll, -.pi / 2, accuracy: 0.0001)
        // It ends the slide before it rises or stands up, as far as the stack's own drawing of
        // the slide moves it.
        let out = path.pose(at: PullOutPath.pullEnd)
        XCTAssertEqual(out.roll, -.pi / 2, accuracy: 0.0001)
        // A flat book, seen straight on, instead moves down the screen as it grows, so its top
        // edge ends on its place's top edge, clear of the book above.
        let flat = PullOutPath(
            home: home, upright: false, stage: path.stage, pose: .resting, aspect: 2 / 3,
            rest: PullOutPath.Rest(pitch: 0.05, slidesInStack: true))
        let flatStart = flat.pose(at: 0)
        let flatOut = flat.pose(at: PullOutPath.pullEnd)
        XCTAssertEqual(
            flatOut.center.y - drawnSize(flatOut, aspect: 2 / 3).width / 2,
            flatStart.center.y + drawnSize(flatStart, aspect: 2 / 3).width / 2 - home.height,
            accuracy: 0.5)
        let slide = PullOutPath.slide(
            at: PullOutPath.pullEnd, length: 280, thickness: 32,
            extent: drawnSize(start, aspect: 2 / 3).width, rest: rest)
        XCTAssertEqual(out.center.y - start.center.y, slide.offset.height, accuracy: 0.001)
        XCTAssertEqual(out.center.x - start.center.x, slide.offset.width, accuracy: 0.001)
        XCTAssertEqual(out.scale / start.scale, slide.scale, accuracy: 0.0001)

        // It lands seen as the details see their book.
        let end = path.pose(at: 1)
        XCTAssertEqual(end.roll, 0, accuracy: 0.0001)
        XCTAssertEqual(end.yaw, BookPose.resting.yaw, accuracy: 0.0001)
        XCTAssertEqual(end.pitch, BookPose.resting.pitch, accuracy: 0.0001)
        XCTAssertEqual(end.lighting, 1, accuracy: 0.0001)
        XCTAssertEqual(end.distance, BookProjection.standardDistance * 380, accuracy: 0.001)
        XCTAssertEqual(end.eye, .zero)
    }

    /// A book faces the pointer from its leading edge to its trailing edge, level at its middle,
    /// in tenths, and never past either edge.
    func testBookLeansTowardThePointerInTenths() {
        XCTAssertEqual(PullOutPath.lean(atX: 0, width: 200), -1)
        XCTAssertEqual(PullOutPath.lean(atX: 100, width: 200), 0)
        XCTAssertEqual(PullOutPath.lean(atX: 200, width: 200), 1)
        XCTAssertEqual(PullOutPath.lean(atX: 130, width: 200), 0.3)
        XCTAssertEqual(PullOutPath.lean(atX: -40, width: 200), -1)
        XCTAssertEqual(PullOutPath.lean(atX: 260, width: 200), 1)
        XCTAssertEqual(PullOutPath.lean(atX: 50, width: 0), 0)
    }
}

/// Runs `body` as `pullOut`'s value at `keyPath` is about to change for the `count`th time, while
/// it still holds its old value. Without a view, `withAnimation` runs its completion before it
/// returns, so a test sees the state an animation starts from only as the next change begins.
@MainActor private func beforeChange<Value>(
    _ count: Int = 1, of keyPath: KeyPath<ShelfPullOut, Value>, in pullOut: ShelfPullOut,
    _ body: @escaping @MainActor () -> Void
) {
    // Observation calls `onChange` from the setter, which runs on the main actor.
    nonisolated(unsafe) let keyPath = keyPath
    nonisolated(unsafe) let body = body
    withObservationTracking {
        _ = pullOut[keyPath: keyPath]
    } onChange: {
        MainActor.assumeIsolated {
            if count > 1 { beforeChange(count - 1, of: keyPath, in: pullOut, body) } else { body() }
        }
    }
}
