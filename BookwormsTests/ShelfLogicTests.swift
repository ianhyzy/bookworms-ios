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

    func testRollingTimesEndTodayAndStartAfterTheSameDateBefore() {
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
                .series(name: "The Lantern Cycle", position: 2),
                .published(2021),
                // Pages even for an audiobook: the book's length whatever the format. The
                // format and its listening time belong to the Journal.
                .length("352 pages"),
                .genres(["Fantasy", "Mystery", "Adventure"]),
            ])

        var bare = book(2, "Unrated")
        bare.communityRating = 4
        bare.ratingsCount = 0
        bare.seriesID = 12
        XCTAssertEqual(DetailCard.details(of: bare, about: nil), [])
        bare.seriesPosition = 3
        bare.publicationYear = 1999
        XCTAssertEqual(
            DetailCard.details(of: bare, about: nil),
            [.series(name: nil, position: 3), .published(1999)])
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
                .finished(try XCTUnwrap(listened.finishedDate)),
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
                .format("Physical", length: "200 pages"),
            ])
        XCTAssertEqual(DetailCard.journal(of: book(3, "Unrecorded")), [])
    }

    func testCardRowsPairHalfCardsWithoutHoles() {
        let about = DetailCard.about("A keeper tends the last lantern.")
        let rating = DetailCard.rating(average: 4, count: 10, counts: nil, yours: nil)
        let series = DetailCard.series(name: "The Lantern Cycle", position: 2)
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
        let stops = StackArrangement.maskStops(height: 1000, top: 30, bottom: 90)
        assertLocations(stops, [0.03, (30 + fade) / 1000, 1 - (90 + fade) / 1000, 0.91])
        XCTAssertEqual(stops.map(\.color), [.clear, .black, .black, .clear])
        // A short scroll view fades in to its middle, keeping the stops in order.
        assertLocations(
            StackArrangement.maskStops(height: 200, top: 30, bottom: 90), [0.15, 0.5, 0.5, 0.55])
        XCTAssertEqual(StackArrangement.maskStops(height: 0, top: 30, bottom: 90).count, 0)
    }

    func testStackedBooksStartTheirFlightAsTheyLie() {
        let top = book(1, "Top", pages: 300)
        let twist = StackArrangement.twist(of: top)
        XCTAssertEqual(
            StackStyle.flat.rest(of: top),
            PullOutPath.Rest(
                pitch: twist * StackStyle.flatTwist / StackArrangement.maximumTwist,
                slidesInStack: true))
        XCTAssertEqual(
            StackStyle.threeD.rest(of: top),
            PullOutPath.Rest(
                yaw: -StackStyle.lookDown, pitch: twist, lighting: StackStyle.lighting,
                slidesInStack: true))
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

    func testDriftEasesInFromRestThenFloatsAtFullAmplitude() {
        let start = Date(timeIntervalSince1970: 1_000)
        let drift = Drift(start: start)
        func offset(_ seconds: Double) -> (translation: CGSize, yaw: Double) {
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

    /// The size `pose` draws a book at on screen, before its roll: its projected bounds, scaled.
    private func drawnSize(_ pose: PullOutPath.Pose, aspect: CGFloat) -> CGSize {
        let projection = BookProjection(
            width: pose.height * aspect, height: pose.height,
            thickness: pose.height * pose.thicknessRatio, yaw: pose.yaw, pitch: pose.pitch)
        return CGSize(
            width: projection.bounds.width * pose.scale,
            height: projection.bounds.height * pose.scale)
    }

    func testPulledBookStartsAsItsSpineAndLandsInTheStage() {
        let home = CGRect(x: 100, y: 300, width: 30, height: 280)
        let stage = CGRect(x: 0, y: 120, width: 402, height: 380)
        let path = PullOutPath(
            home: home, upright: true, stage: stage, pose: .resting, aspect: 2 / 3,
            thicknessRatio: 0.08)

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

        // It lands in the details' pose, size, and place.
        let end = path.pose(at: 1)
        XCTAssertEqual(end.height, 380, accuracy: 0.001)
        XCTAssertEqual(end.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(end.thicknessRatio, 0.08, accuracy: 0.0001)
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
            stage: CGRect(x: 0, y: 150, width: 402, height: 380), pose: .resting, aspect: 2 / 3,
            thicknessRatio: 0.08)
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
            pose: .resting, aspect: 0.66, thicknessRatio: 0.1)
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

    func testStackedBookStandsUpAndSpunBookTurnsBackTheShortWay() {
        let home = CGRect(x: 20, y: 400, width: 362, height: 65)
        let spun = BookPose(yaw: BookPose.resting.yaw + 4 * .pi + 0.3, pitch: 0.2)
        let path = PullOutPath(
            home: home, upright: false, stage: CGRect(x: 0, y: 100, width: 402, height: 380),
            pose: spun, aspect: 2 / 3, thicknessRatio: 0.11)

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

        let end = path.pose(at: 1)
        XCTAssertEqual(end.roll, 0, accuracy: 0.0001)
        XCTAssertEqual(end.yaw, spun.yaw, accuracy: 0.0001)
        XCTAssertEqual(end.pitch, spun.pitch, accuracy: 0.0001)
    }

    func testStackNeighborsMakeRoomOutwardThenSettle() {
        let open = { (distance: Int, room: Double) in
            StackRoom.offset(distance: distance, room: room, closing: 0)
        }
        // The pulled book, and every book while none is pulled, stays put.
        for room in [0.0, 0.3, 1] {
            XCTAssertEqual(open(0, room), 0)
        }
        // Before the pull, nothing has moved.
        for distance in [-3, -1, 1, 3] {
            XCTAssertEqual(open(distance, 0), 0)
        }
        // Once settled, books above are up and books below are down, the nearest by `near`
        // and farther ones a little more, up to `far`.
        XCTAssertEqual(open(1, 1), StackRoom.near, accuracy: 0.1)
        XCTAssertEqual(open(-1, 1), -StackRoom.near, accuracy: 0.1)
        XCTAssertGreaterThan(open(2, 1), open(1, 1))
        XCTAssertEqual(
            open(20, 1), StackRoom.far - (StackRoom.far - StackRoom.near) / 20, accuracy: 0.3)
        // The nudge spreads outward: a farther book starts later, and the overshoot stays small.
        XCTAssertGreaterThan(open(1, 0.1), open(4, 0.1))
        XCTAssertEqual(open(8, 0.1), 0)
        for distance in [1, 2, 5, 12] {
            var peak: CGFloat = 0
            var previous: CGFloat = 0
            for step in 0...200 {
                let offset = open(distance, Double(step) / 200)
                XCTAssertLessThan(abs(offset - previous), 0.6, "no jump at step \(step)")
                peak = max(peak, offset)
                previous = offset
            }
            XCTAssertLessThan(peak, StackRoom.far * 1.2)
            XCTAssertGreaterThan(peak, StackRoom.near)
        }
    }

    func testStackNeighborsSnapShutWithoutOverlappingTheReturnedBook() {
        // The books hold their room until the snap starts, and are back in place when it ends.
        XCTAssertEqual(
            StackRoom.offset(distance: 1, room: 1, closing: 0), StackRoom.near, accuracy: 0.1)
        XCTAssertEqual(StackRoom.offset(distance: -3, room: 1, closing: 1), 0)
        for distance in [-12, -5, -1, 1, 2, 5, 12] {
            var rebounded = false
            var previous = StackRoom.offset(distance: distance, room: 1, closing: 0)
            for step in 0...400 {
                let offset = StackRoom.offset(
                    distance: distance, room: 1, closing: Double(step) / 400)
                // A book above stays at or above its place, and a book below at or below it.
                XCTAssertGreaterThanOrEqual(offset * CGFloat(distance.signum()), 0)
                if abs(offset) > abs(previous) { rebounded = true }
                previous = offset
            }
            XCTAssertTrue(rebounded, "a book \(distance) places away rebounds")
            XCTAssertLessThan(
                abs(StackRoom.offset(distance: distance, room: 1, closing: 0.999)), 0.05)
        }
        // The snap spreads outward like the opening.
        XCTAssertLessThan(
            abs(StackRoom.offset(distance: 1, room: 1, closing: 0.15)),
            abs(StackRoom.offset(distance: 6, room: 1, closing: 0.15)))
    }

    func testThreeDStackedBookStartsAsItLiesAndLandsInTheDetails() {
        let home = CGRect(x: 40, y: 400, width: 280, height: 32)
        let rest = PullOutPath.Rest(
            yaw: -0.3, pitch: 0.2, lighting: 0.6)
        let path = PullOutPath(
            home: home, upright: false, stage: CGRect(x: 0, y: 100, width: 402, height: 380),
            pose: .resting, aspect: 2 / 3, thicknessRatio: 0.1, rest: rest)

        // Drawn as the stack draws it: turned to show its top board and an end, and shaded.
        let start = path.pose(at: 0)
        XCTAssertEqual(start.center, CGPoint(x: home.midX, y: home.midY))
        XCTAssertEqual(start.height, 280, accuracy: 0.001)
        XCTAssertEqual(start.thicknessRatio, 32 / 280, accuracy: 0.0001)
        XCTAssertEqual(
            start.scale,
            1 / PullOutPath.spineMagnification(aspect: 2 / 3, thicknessRatio: 32 / 280),
            accuracy: 0.0001)
        XCTAssertEqual(start.roll, -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(sin(start.yaw - rest.yaw), 1, accuracy: 0.0001)
        XCTAssertEqual(start.pitch, 0.2, accuracy: 0.0001)
        XCTAssertEqual(start.lighting, 0.6, accuracy: 0.0001)
        XCTAssertEqual(path.pose(at: -0.1), start)
        // Turned to face a little left, it comes out toward the reader, a little left, and down
        // the screen.
        let placeTop = start.center.y + drawnSize(start, aspect: 2 / 3).width / 2 - home.height
        let pulled = path.pose(at: PullOutPath.floatStart)
        XCTAssertLessThan(pulled.center.x, start.center.x)
        XCTAssertGreaterThan(pulled.center.y, start.center.y)
        XCTAssertGreaterThan(pulled.scale / start.scale, 1.1)
        XCTAssertEqual(pulled.roll, -.pi / 2, accuracy: 0.0001)
        // It ends the slide just clear of the book above, before it rises or stands up, as far
        // as the stack's own drawing of the slide moves it.
        let out = path.pose(at: PullOutPath.pullEnd)
        XCTAssertEqual(out.roll, -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(
            out.center.y - drawnSize(out, aspect: 2 / 3).width / 2, placeTop, accuracy: 0.5)
        let slide = PullOutPath.slide(
            at: PullOutPath.pullEnd, length: 280, thickness: 32,
            extent: drawnSize(start, aspect: 2 / 3).width, rest: rest)
        XCTAssertEqual(out.center.y - start.center.y, slide.offset.height, accuracy: 0.001)
        XCTAssertEqual(out.center.x - start.center.x, slide.offset.width, accuracy: 0.001)
        XCTAssertEqual(out.scale / start.scale, slide.scale, accuracy: 0.0001)

        let end = path.pose(at: 1)
        XCTAssertEqual(end.roll, 0, accuracy: 0.0001)
        XCTAssertEqual(end.yaw, BookPose.resting.yaw, accuracy: 0.0001)
        XCTAssertEqual(end.pitch, BookPose.resting.pitch, accuracy: 0.0001)
        XCTAssertEqual(end.lighting, 1, accuracy: 0.0001)
    }
}
