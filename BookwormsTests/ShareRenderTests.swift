import CoreGraphics
import UIKit
import XCTest

@testable import Bookworms

final class ShareRenderTests: XCTestCase {
    /// Fictional books over two years, with gaps in pages, ratings, genres, reviews, and designs,
    /// a long title and review, a contributor list, and two current reads. None has a cover, so
    /// covers fall back to the spine colors.
    private static let books: [CloudBook] = (1...16).map(fixture)

    private static let longReview = String(
        repeating: "An invented review sentence that goes on for a while, ", count: 20)

    private static func fixture(_ index: Int) -> CloudBook {
        let title =
            index == 3
            ? "An Unusually Long Fictional Title That Keeps Going: With a Subtitle"
            : "Fictional Book \(index)"
        let author = index == 5 ? "First Author, Second Author, Third Author" : "Author \(index)"
        let pages: Int? = index.isMultiple(of: 4) ? nil : 120 + index * 61
        guard index <= 14 else {
            // Current reads: one with progress and a start date, one with neither.
            return CloudBook(
                id: index, title: title, author: author, coverURL: nil, detailCoverURL: nil,
                pages: pages, isReading: true, progress: index == 15 ? 0.35 : nil,
                started: index == 15 ? "2025-11-20" : nil)
        }
        let year = index <= 10 ? 2025 : 2024
        let rating: Double? = index.isMultiple(of: 3) ? nil : Double(index % 5) + 0.5
        let audioSeconds: Int? = index % 3 == 2 ? 36_000 + index * 600 : nil
        return CloudBook(
            id: index, title: title, author: author, coverURL: nil, detailCoverURL: nil,
            genres: index == 7
                ? nil : index.isMultiple(of: 2) ? ["Fantasy", "Mystery"] : ["Horror"],
            format: ["Read", "Ebook", "Listened"][index % 3], pages: pages,
            finished: String(format: "%d-%02d-15", year, index % 12 + 1), rating: rating,
            audioSeconds: audioSeconds,
            communityRating: Double(index % 4) + 1.2 + Double(index) / 100,
            ratingsCount: index == 7 ? 12 : 300,
            review: index % 3 != 1 ? nil : index == 4 ? longReview : "Invented praise \(index).")
    }

    /// Generated looks for even books; odd books keep the fallback look.
    private static let looks: [Int: SpineLook] = Dictionary(
        uniqueKeysWithValues: books.map { book in
            let design =
                book.id.isMultiple(of: 2)
                ? SpineDesignV1(
                    version: 1, accountID: "fixture", bookID: book.id,
                    workItemHash: String(repeating: "a", count: 64),
                    coverHash: String(repeating: "b", count: 64), generatorVersion: "fixture",
                    generatedAt: Date(timeIntervalSince1970: 0),
                    backgroundHex: book.id.isMultiple(of: 4) ? "#EFE3C3" : "#1F3A5F",
                    foregroundHex: book.id.isMultiple(of: 4) ? "#2A1E12" : "#F5EBD7",
                    accentHex: "#C9973A", typeface: "rounded", weight: 700, uppercase: true)
                : nil
            return (book.id, SpineLook(book: book, design: design, face: nil))
        })

    /// Every template in every aspect, for a year with 3D covers and for a month and a lifetime
    /// with flat ones. Piles render with `PileSnapshotRenderer` instead.
    @MainActor
    func testEveryTemplateRendersAtExactPixelSizeWithContent() throws {
        let cases: [(frame: TimeFrame, style: ShareCoverStyle)] = [
            (.year(2025), .threeD), (.month(year: 2025, month: 5), .flat), (.lifetime, .flat),
        ]
        for template in ShareTemplate.allCases where template != .pile {
            for (frame, style) in cases {
                let books = template.books(from: Self.books, in: frame)
                XCTAssertFalse(books.isEmpty, "\(template) \(frame)")
                for aspect in ShareAspect.allCases {
                    let label = "\(template) \(frame) \(aspect) \(style)"
                    // Each image is released before the next, so the run stays small.
                    try autoreleasepool {
                        let input = ShareInput(
                            template: template, aspect: aspect, books: books, looks: Self.looks,
                            frame: frame, coverStyle: style, seed: 7)
                        let image = try XCTUnwrap(input.render()?.cgImage, label)
                        XCTAssertEqual(image.width, Int(aspect.size.width), label)
                        XCTAssertEqual(image.height, Int(aspect.size.height), label)
                        XCTAssertGreaterThan(
                            try differingFraction(image), 0.05, "\(label) is a flat color")
                    }
                }
            }
        }
    }

    /// A year with one bare book, and a year with ratings hidden, leave out what they lack and
    /// still fill the image.
    @MainActor
    func testYearInBooksRendersSparseAndUnratedYears() throws {
        let bare = CloudBook(
            id: 99, title: "Fictional Bare Book", author: "Author", coverURL: nil,
            detailCoverURL: nil, finished: "2019-06-01")
        let cases: [(books: [CloudBook], year: Int, showsRatings: Bool)] = [
            ([bare], 2019, true),
            (ShareTemplate.yearInBooks.books(from: Self.books, in: .year(2025)), 2025, false),
        ]
        for (books, year, showsRatings) in cases {
            for aspect in ShareAspect.allCases {
                let input = ShareInput(
                    template: .yearInBooks, aspect: aspect, books: books, looks: Self.looks,
                    frame: .year(year), showsRatings: showsRatings, seed: 7)
                let image = try XCTUnwrap(input.render()?.cgImage, "\(year) \(aspect)")
                XCTAssertEqual(image.width, Int(aspect.size.width), "\(year) \(aspect)")
                XCTAssertEqual(image.height, Int(aspect.size.height), "\(year) \(aspect)")
                XCTAssertGreaterThan(
                    try differingFraction(image), 0.05, "\(year) \(aspect) is a flat color")
            }
        }
    }

    /// Card text uses the share typography, never the spine's: with flat covers, which draw no
    /// spines, a card looks the same whatever typeface and capitalization the spine has. Year
    /// Stack is left out because its spines carry their lettering, and Pile because
    /// `ImageRenderer` cannot draw it.
    @MainActor
    func testCardTextIgnoresSpineTypography() throws {
        let restyled = Self.looks.mapValues { look in
            var look = look
            look.typeface = look.typeface == "monospaced" ? "serif" : "monospaced"
            look.weight = look.weight == 400 ? 700 : 400
            look.uppercase.toggle()
            look.isCondensed.toggle()
            return look
        }
        for template in ShareTemplate.allCases where template != .yearStack && template != .pile {
            let books = template.books(from: Self.books, in: .lifetime)
            for aspect in ShareAspect.allCases {
                func pixels(_ looks: [Int: SpineLook]) throws -> Data {
                    let input = ShareInput(
                        template: template, aspect: aspect, books: books, looks: looks,
                        frame: .lifetime, coverStyle: .flat, seed: 3)
                    return try XCTUnwrap(input.render()?.cgImage?.dataProvider?.data as Data?)
                }
                try autoreleasepool {
                    // Shadow blurs can round a few pixels by a level between renders; changed
                    // lettering would differ by far more.
                    XCTAssertLessThanOrEqual(
                        largestChannelDifference(try pixels(Self.looks), try pixels(restyled)), 2,
                        "\(template) \(aspect)")
                }
            }
        }
    }

    @MainActor
    func testSameSeedDrawsSameImage() throws {
        for template in [ShareTemplate.yearStack, .yearInBooks] {
            let books = template.books(from: Self.books, in: .year(2025))
            func pixels(seed: UInt64) throws -> Data {
                let input = ShareInput(
                    template: template, aspect: .square, books: books, looks: Self.looks,
                    frame: .year(2025), seed: seed)
                return try XCTUnwrap(input.render()?.cgImage?.dataProvider?.data as Data?)
            }
            XCTAssertEqual(try pixels(seed: 3), try pixels(seed: 3), "\(template)")
            XCTAssertNotEqual(try pixels(seed: 3), try pixels(seed: 4), "\(template)")
        }
    }

    /// The Pile template offers every time frame kind, draws the frame's finished books newest
    /// first so they land on top, and heads the image with the frame's name.
    func testPileTemplateDrawsEachTimeFrameNewestFirst() {
        let pile = ShareTemplate.pile
        XCTAssertTrue(ShareTemplate.allCases.contains(pile))
        XCTAssertTrue(pile.usesTimeFrame)
        XCTAssertFalse(pile.isSingleBook)
        XCTAssertFalse(pile.hasCoverStyle, "A pile's books are always 3D")
        for frame in [TimeFrame.year(2025), .month(year: 2025, month: 5), .lifetime] {
            let books = pile.books(from: Self.books, in: frame)
            XCTAssertFalse(books.isEmpty, frame.title)
            XCTAssertEqual(
                books.map(\.id),
                ShareTemplate.yearStack.books(from: Self.books, in: frame).reversed().map(\.id),
                frame.title)
            let input = ShareInput(template: pile, aspect: .story, books: books, frame: frame)
            XCTAssertEqual(input.period, frame == .lifetime ? "2024–2025" : frame.title)
        }
    }

    /// A pile render marks itself until it ends, even when cancelled, so the live pile stays off
    /// the screen, and a render that started meanwhile still finishes after it.
    @MainActor
    func testPileRendersOneAtATimeWhileMarked() async throws {
        let books = ShareTemplate.pile.books(from: Self.books, in: .month(year: 2025, month: 5))
        func render() -> Task<UIImage, any Error> {
            Task {
                try await PileSnapshotRenderer.render(
                    books: books, title: "May", aspect: .square, seed: 1, model: .shared)
            }
        }
        XCTAssertFalse(PileSnapshotRenderer.isRendering)
        let first = render()
        while !PileSnapshotRenderer.isRendering { await Task.yield() }
        let second = render()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("A cancelled render returns no image")
        } catch is CancellationError {}
        // The second render starts only now, so the flag marks it again until it ends. Without
        // the wait, the first render's end clears the flag while the second one runs.
        let deadline = ContinuousClock.now + .seconds(2)
        while !PileSnapshotRenderer.isRendering, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(PileSnapshotRenderer.isRendering, "The second render is marked")
        let image = try await second.value
        XCTAssertEqual(image.cgImage?.width, 1080)
        XCTAssertFalse(PileSnapshotRenderer.isRendering)
    }

    /// A render that releases its turn and claims again at once, as a still image's loop does,
    /// goes after a render that was already waiting, and the flag stays set between them.
    @MainActor
    func testPileRendersTakeTurnsInOrder() async throws {
        try await PileSnapshotRenderer.claim()
        let waiting = Task { @MainActor in
            try await PileSnapshotRenderer.claim()
            defer { PileSnapshotRenderer.release() }
            return ContinuousClock.now
        }
        // Lets the waiting render join the line.
        try await Task.sleep(for: .milliseconds(50))
        PileSnapshotRenderer.release()
        XCTAssertTrue(PileSnapshotRenderer.isRendering, "The turn passes without a gap")
        try await PileSnapshotRenderer.claim()
        let again = ContinuousClock.now
        PileSnapshotRenderer.release()
        let waited = try await waiting.value
        XCTAssertLessThan(waited, again)
        XCTAssertFalse(PileSnapshotRenderer.isRendering)
    }

    /// Without a library, signed out explains both sources; signed in follows the download.
    func testNoLibraryStatusFollowsTheSignInAndDownload() {
        func status(
            loading: Bool = false, signedIn: Bool = false, syncing: Bool = false,
            reconnect: Bool = false, syncError: String? = nil, loadError: String? = nil
        ) -> LibraryStatus {
            LibraryStatus(
                isLoading: loading, isSignedIn: signedIn, isSyncing: syncing,
                needsReconnect: reconnect, syncError: syncError, loadError: loadError)
        }
        XCTAssertEqual(status(loading: true), .loading)
        let signedOut = status(loadError: "Sign in to iCloud.")
        XCTAssertEqual(signedOut, .signedOut(note: "Sign in to iCloud."))
        XCTAssertTrue(signedOut.message.contains("Apple TV"), signedOut.message)
        XCTAssertTrue(signedOut.message.contains("connect Hardcover"), signedOut.message)
        XCTAssertTrue(
            signedOut.message.hasSuffix("\n\nApple TV library: Sign in to iCloud."),
            "The note belongs to the Apple TV option: \(signedOut.message)")
        XCTAssertEqual(status(signedIn: true, syncing: true), .downloading)
        XCTAssertEqual(status(loading: true, signedIn: true), .downloading)
        XCTAssertEqual(
            status(signedIn: true, syncError: "Offline.", loadError: "Stale."),
            .failed(error: "Offline."))
        XCTAssertEqual(
            status(signedIn: true, loadError: "Unreadable."), .failed(error: "Unreadable."))
        XCTAssertFalse(status(signedIn: true).message.isEmpty)
        XCTAssertEqual(
            status(signedIn: true, syncing: true, reconnect: true, syncError: "Expired."),
            .reconnect(error: "Expired."))
    }

    func testSelectionOrdersEachTemplate() {
        let stack = ShareTemplate.yearStack.books(from: Self.books, in: .year(2025))
        XCTAssertEqual(stack.count, 10)
        XCTAssertEqual(stack.compactMap(\.finished), stack.compactMap(\.finished).sorted())
        XCTAssertEqual(ShareTemplate.yearInBooks.books(from: Self.books, in: .year(2025)), stack)
        XCTAssertEqual(
            ShareTemplate.yearStack.books(from: Self.books, in: .month(year: 2024, month: 2))
                .map(\.id), [13])

        let top = ShareTemplate.topFive.books(from: Self.books, in: .year(2025))
        XCTAssertEqual(top.map(\.id), [4, 8, 7, 2, 1])

        XCTAssertEqual(ShareTemplate.spectrum.books(from: Self.books, in: .lifetime).count, 14)
    }

    func testSingleBookTemplatesChooseWithinTheirChoices() {
        let finished = ShareTemplate.justFinished
        XCTAssertEqual(finished.books(from: Self.books, in: .year(2024)).map(\.id), [11])
        XCTAssertEqual(
            finished.books(from: Self.books, in: .year(2024), bookID: 2).map(\.id), [2],
            "A book shared from its details shows even outside the frame")

        let review = ShareTemplate.review
        XCTAssertEqual(
            review.choices(from: Self.books, in: .year(2025)).map(\.id), [10, 7, 4, 1])
        XCTAssertEqual(review.books(from: Self.books, in: .year(2025), bookID: 4).map(\.id), [4])
        XCTAssertEqual(
            review.books(from: Self.books, in: .year(2025), bookID: 2).map(\.id), [10],
            "A book without a review falls back to the newest review")
        XCTAssertTrue(review.books(from: Self.books, in: .month(year: 2025, month: 3)).isEmpty)
        let undated = CloudBook(
            id: 50, title: "Fictional Undated Book", author: "Author", coverURL: nil,
            detailCoverURL: nil, review: "Invented praise.")
        XCTAssertEqual(
            review.choices(from: Self.books + [undated], in: .lifetime).last?.id, 50,
            "A lifetime offers a reviewed book without a finish date, last")
        XCTAssertFalse(
            review.choices(from: Self.books + [undated], in: .year(2025)).contains(undated))

        let reading = ShareTemplate.currentlyReading
        XCTAssertEqual(reading.choices(from: Self.books, in: .year(2019)).map(\.id), [15, 16])
        XCTAssertEqual(reading.books(from: Self.books, in: .lifetime, bookID: 16).map(\.id), [16])
        XCTAssertEqual(reading.books(from: Self.books, in: .lifetime, bookID: 4).map(\.id), [15])
    }

    /// A reread is a current read that keeps its previous finish date; Currently Reading shows
    /// its start date instead.
    func testCurrentReadDetailsShowTheStartDate() {
        let reread = CloudBook(
            id: 60, title: "Fictional Reread", author: "Author", coverURL: nil,
            detailCoverURL: nil, pages: 412, finished: "2021-03-03", isReading: true,
            started: "2026-10-01")
        let reading = ShareStyle.details(reread, isReading: true)
        XCTAssertTrue(reading.hasPrefix("Started "), reading)
        XCTAssertTrue(reading.contains("2026"), reading)
        XCTAssertFalse(reading.contains("2021"), reading)
        XCTAssertTrue(ShareStyle.details(reread).contains("2021"), "Just Finished shows the finish")
    }

    /// The format reads as the Shelf labels it, including a book read in print and on audio,
    /// and only an audiobook gives its listening time instead of its pages.
    func testDetailsLabelEveryFormatAsTheShelfDoes() {
        func details(_ format: String) -> String {
            ShareStyle.details(
                CloudBook(
                    id: 61, title: "Fictional Format", author: "Author", coverURL: nil,
                    detailCoverURL: nil, format: format, pages: 300, finished: "2025-01-02",
                    audioSeconds: 36_000))
        }
        let both = details("Both")
        XCTAssertTrue(both.hasPrefix("Physical & audiobook · "), both)
        XCTAssertTrue(both.hasSuffix("300 pages"), both)
        let audio = details("audio")
        XCTAssertTrue(audio.hasPrefix("Audiobook · "), audio)
        XCTAssertFalse(audio.contains("pages"), audio)
        XCTAssertTrue(details("e-book").hasPrefix("Ebook · "))
        XCTAssertFalse(details("Read").contains("Physical"), "Print alone goes unlabeled")
    }

    /// Clashing spine colors give one family of panels, gray spines give a warm neutral, and
    /// cream text keeps 7:1 contrast on every theme color.
    func testThemeKeepsOneColorFamilyWithReadableText() {
        let clashing = ShareTheme(colors: [
            ColorValue(red: 200, green: 30, blue: 40), ColorValue(red: 30, green: 60, blue: 200),
            ColorValue(red: 40, green: 160, blue: 60), ColorValue(red: 230, green: 200, blue: 40),
        ])
        let hues = (0..<4)
            .map { index in
                let lab = SpineContrast.lab(clashing.panel(index))
                return atan2(lab.b, lab.a) * 180 / .pi
            }
        let span = hues.flatMap { hue in hues.map { abs(ShareTheme.difference(hue, $0)) } }.max()
        XCTAssertLessThanOrEqual(span ?? 0, 34, "Panel hues \(hues)")

        let grays = [
            ColorValue(red: 255, green: 255, blue: 255), ColorValue(red: 0, green: 0, blue: 0),
            ColorValue(red: 128, green: 128, blue: 128),
            ColorValue(red: 120, green: 118, blue: 115),
        ]
        XCTAssertEqual(ShareTheme(colors: grays), .neutral)
        XCTAssertEqual(ShareTheme(colors: []), .neutral)
        let yellow = ShareTheme(colors: [ColorValue(red: 200, green: 190, blue: 60)])
        XCTAssertFalse((85...125).contains(yellow.hue), "Muddy yellows turn to amber")
        // A sage theme (hue 126) turns its third panel to hue 110, inside the muddy band.
        let sage = SpineContrast.lab(
            ShareTheme(colors: [ColorValue(red: 140, green: 160, blue: 110)]).panel(2))
        XCTAssertLessThanOrEqual((sage.a * sage.a + sage.b * sage.b).squareRoot(), 0.04)

        let swept = stride(from: 0.0, to: 360, by: 10).map { ShareTheme(hue: $0, chroma: 0.3) }
        for theme in [clashing, .neutral] + swept {
            let colors =
                [theme.backdropLight, theme.backdropDark, theme.glow] + (0..<4).map(theme.panel)
            for color in colors {
                XCTAssertGreaterThanOrEqual(
                    color.contrast(with: ShareStyle.cream), 7, "\(theme) \(color.hex)")
            }
        }
    }

    /// Ratings in 2025 differ from the fixture's community averages by +3.26 (book 4), +2.22 (8),
    /// −0.71 (1), −0.72 (2), −1.75 (5), and −2.8 (10); book 7's average has too few ratings to
    /// count.
    func testHotTakesRankTheWidestGapsInOneDirection() {
        let takes = ShareTemplate.hotTakes
        XCTAssertEqual(takes.books(from: Self.books, in: .year(2025)).map(\.id), [4, 8])
        XCTAssertEqual(
            takes.books(from: Self.books, in: .year(2025), direction: .lovedLess).map(\.id),
            [10, 5, 2], "Up to three, widest gap first")
        XCTAssertNil(Self.books[6].ratingGap, "Book 7 has 12 ratings")
        XCTAssertEqual(HotTakesCard.signed(-0.75), "−0.8")
        XCTAssertEqual(HotTakesCard.signed(1.5), "+1.5")
    }

    func testExcerptEndsAtASentenceOrWordWithAnEllipsis() {
        XCTAssertEqual(ShareStyle.excerpt("Short\n\nand  sweet.", limit: 40), "Short and sweet.")
        let excerpt = ShareStyle.excerpt("One two three, four five six.", limit: 18)
        XCTAssertEqual(excerpt, "One two three…")
        let long = ShareStyle.excerpt(Self.longReview, limit: 300)
        XCTAssertLessThanOrEqual(long.count, 300)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(ShareStyle.excerpt("Unbreakableword", limit: 6), "Unbre…")
        XCTAssertEqual(
            ShareStyle.excerpt("First sentence here. Second one goes on and on.", limit: 30),
            "First sentence here. …", "A sentence ending late in the excerpt ends it")
        XCTAssertEqual(
            ShareStyle.excerpt(
                "Solid. I would give it 4.5 stars overall even though the last act drags.",
                limit: 40),
            "Solid. I would give it 4.5 stars…", "A decimal point doesn't end a sentence")
        XCTAssertEqual(
            ShareStyle.excerpt(
                "Loved it. Then I met Mr. Darcy and everything changed for the better.", limit: 36),
            "Loved it. Then I met Mr. Darcy and…", "An abbreviation doesn't end a sentence")
        XCTAssertEqual(
            ShareStyle.excerpt(
                "He paused. She said \"Stop.\" Then she walked away from all of it.", limit: 40),
            "He paused. She said \"Stop.\" …", "A closing quote stays with its sentence")
    }

    func testTitleFormsDropSeriesTagsThenSubtitles() {
        func titles(_ title: String, series: String? = nil) -> [String] {
            ShareStyle.titles(
                CloudBook(
                    id: 1, title: title, author: "Author", coverURL: nil, detailCoverURL: nil,
                    seriesID: series == nil ? nil : 5, seriesName: series))
        }
        XCTAssertEqual(titles("Fictional Book"), ["Fictional Book"])
        XCTAssertEqual(titles("The Gilded Ferry (Ferry Saga, #4)"), ["The Gilded Ferry"])
        XCTAssertEqual(titles("Salt Roads (The Tidewater 3)"), ["Salt Roads"])
        XCTAssertEqual(titles("Salt Roads (Tidewater)", series: "Tidewater"), ["Salt Roads"])
        XCTAssertEqual(titles("Salt Roads (Illustrated)"), ["Salt Roads (Illustrated)"])
        XCTAssertEqual(titles("(Untitled)"), ["(Untitled)"])
        XCTAssertEqual(
            titles("Ledger: A Critique of Imaginary Economics, Volume 1"),
            ["Ledger: A Critique of Imaginary Economics, Volume 1", "Ledger"])
        XCTAssertEqual(
            titles("Harbor — A Memoir (Harbor Days, #1)"), ["Harbor — A Memoir", "Harbor"])
        XCTAssertEqual(
            titles("Star Rangers: Nightfall", series: "Star Rangers"),
            ["Star Rangers: Nightfall", "Nightfall"], "A series prefix goes, not the rest")
        XCTAssertEqual(
            titles("Star Rangers: Nightfall: A Novel", series: "star rangers"),
            ["Star Rangers: Nightfall: A Novel", "Nightfall: A Novel", "Nightfall"])
        XCTAssertEqual(titles(": Colon First"), [": Colon First"])
    }

    func testStackSpinesBundleNamedSeriesAtTheirFirstBook() {
        func book(_ id: Int, series: Int? = nil, name: String? = nil, rating: Double? = nil)
            -> CloudBook
        {
            CloudBook(
                id: id, title: "Book \(id)", author: "Author", coverURL: nil, detailCoverURL: nil,
                seriesID: series, seriesName: name, pages: 400, finished: "2025-01-0\(id)",
                rating: rating)
        }
        // Series 8 has no name, as in the Apple TV's archive, and series 9 has one book here.
        let books = [
            book(1, rating: 4), book(2, series: 7, name: "Tide Saga", rating: 2),
            book(3, series: 8), book(4, series: 7, name: "Tide Saga", rating: 5),
            book(5, series: 8), book(6, series: 9, name: "Lone Series"),
            book(7, series: 7, name: "Tide Saga"),
        ]
        let spines = StackSpine.spines(books)
        XCTAssertEqual(spines.map { $0.books.map(\.id) }, [[1], [2, 4, 7], [3], [5], [6]])
        XCTAssertEqual(spines[1].titles, ["Tide Saga"], "The tag carries the count")
        XCTAssertEqual(spines[0].titles, ["Book 1"])
        XCTAssertEqual(spines[1].slices.map(\.book.id), [2, 4, 7])
        XCTAssertGreaterThan(spines[1].size.height, spines[0].size.height)
        // A group ranks as its best-rated book.
        XCTAssertTrue(StackSpine.isRankedHigher(spines[1], spines[0]))

        // A big series draws a capped number of thin slices in a book-shaped bundle.
        let long = StackSpine.spines((1...9).map { book($0, series: 7, name: "Tide Saga") })
        XCTAssertEqual(long.count, 1)
        XCTAssertEqual(long[0].books.count, 9)
        XCTAssertEqual(long[0].slices.count, StackSpine.maximumSlices)
        let thickest =
            (1...200)
            .map { id in
                StackSpine.shape(
                    of: CloudBook(
                        id: id, title: "Book", author: "Author", coverURL: nil,
                        detailCoverURL: nil, pages: 1400)
                )
                .height
            }
            .max() ?? 0
        for bundle in [spines[1], long[0]] {
            let slices = bundle.slices
            XCTAssertEqual(
                slices.reduce(0) { $0 + $1.size.height }, bundle.size.height, accuracy: 1e-9,
                "Slices touch, with no gaps")
            XCTAssertTrue(slices.allSatisfy { $0.size.width == bundle.size.width })
            XCTAssertLessThanOrEqual(
                bundle.size.height, bundle.size.width * StackSpine.bundleRatio + 1e-9)
            XCTAssertLessThanOrEqual(
                bundle.size.height, thickest * 1.1, "No thicker than a thick book, plus a little")
        }
        XCTAssertLessThan(long[0].slices[1].size.height, spines[1].slices[1].size.height)
    }

    /// Spines keep the Library's Stack proportions at every scale, in one column.
    func testStackSpinesKeepStackProportionsInOneColumn() {
        let books = [100, 180, 320, 480, 760, 1200].enumerated()
            .map { index, pages in
                CloudBook(
                    id: index + 1, title: "Fictional Book", author: "Author", coverURL: nil,
                    detailCoverURL: nil, pages: pages)
            }
        let stack = StackArrangement(width: 402)
        for book in books {
            let shape = StackSpine(books: [book]).size
            let spine = stack.spine(of: book)
            XCTAssertEqual(shape.width / shape.height, spine.width / spine.height, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(
                shape.width / shape.height, 4, "Book-shaped, never box-shaped: \(shape)")
            XCTAssertGreaterThanOrEqual(shape.height, StackSpine.thinnest - 1e-9)
        }

        for aspect in ShareAspect.allCases {
            let area = YearStackCard.area(aspect)
            // Two columns can't hold the longest book at the smallest legible scale.
            XCTAssertLessThan(
                area.width / 2, CGFloat(BookShape.longest) * StackLayout.minimumScale, "\(aspect)")
            XCTAssertGreaterThan(StackLayout.maximumScale(area), StackLayout.minimumScale)
            let spines = StackSpine.spines(books)
            let layout = StackLayout(spines: spines, area: area, seed: 4)
            XCTAssertGreaterThanOrEqual(layout.scale, StackLayout.minimumScale, "\(aspect)")
            XCTAssertLessThanOrEqual(layout.scale, StackLayout.maximumScale(area), "\(aspect)")
            XCTAssertLessThanOrEqual(layout.height, area.height + 0.5, "\(aspect)")
            var bottom = layout.height
            for slab in layout.slabs {
                XCTAssertEqual(
                    slab.size.width / slab.size.height,
                    slab.spine.size.width / slab.spine.size.height, accuracy: 1e-9)
                XCTAssertLessThanOrEqual(
                    abs(slab.center.x - area.width / 2),
                    StackArrangement.maximumShift * area.width + 1e-9, "One column")
                // Each spine lies flat on the one below it, with no gap.
                XCTAssertEqual(slab.center.y + slab.size.height / 2, bottom, accuracy: 1e-6)
                bottom -= slab.size.height
            }
        }
    }

    func testStackPagesSplitEvenlyInFinishOrderUpToTwentyPages() {
        func spines(_ count: Int) -> [StackSpine] {
            StackSpine.spines(
                (1...count)
                    .map { index in
                        CloudBook(
                            id: index, title: "Book \(index)", author: "Author", coverURL: nil,
                            detailCoverURL: nil, pages: 400, finished: "2025-01-01",
                            rating: Double(index % 5) + 1)
                    })
        }
        let area = CGSize(width: 952, height: 700)
        let few = spines(6)
        XCTAssertEqual(
            StackPages(spines: few, area: area).pages.map { $0.map(\.id) }, [few.map(\.id)])

        // A crowded frame fills pages evenly and in order, leaving nothing out.
        let crowded = spines(60)
        let pages = StackPages(spines: crowded, area: area)
        XCTAssertGreaterThan(pages.pages.count, 1)
        XCTAssertEqual(pages.hiddenCount, 0)
        XCTAssertEqual(pages.pages.flatMap { $0 }.map(\.id), crowded.map(\.id))
        let thicknesses = pages.pages.map(StackLayout.thickness)
        XCTAssertLessThanOrEqual(thicknesses.max() ?? 0, StackLayout.capacity(area))
        // Within about two books of each other.
        XCTAssertLessThanOrEqual((thicknesses.max() ?? 0) - (thicknesses.min() ?? 0), 0.7)
        for page in pages.pages {
            let layout = StackLayout(spines: page, area: area, seed: 1)
            XCTAssertEqual(layout.slabs.count, page.count)
            XCTAssertLessThanOrEqual(layout.height, area.height + 0.5)
            XCTAssertGreaterThanOrEqual(layout.scale, StackLayout.minimumScale)
        }

        // Past 20 pages, the lowest-ranked books are left out.
        let many = spines(1000)
        let capped = StackPages(spines: many, area: area)
        XCTAssertEqual(capped.pages.count, StackPages.maximumPages)
        XCTAssertGreaterThan(capped.hiddenCount, 0)
        let shown = capped.pages.flatMap { $0 }
        XCTAssertEqual(shown.count + capped.hiddenCount, many.count)
        let shownIDs = Set(shown.map(\.id))
        let hiddenRatings = many.filter { !shownIDs.contains($0.id) }.compactMap(\.book.rating)
        XCTAssertGreaterThanOrEqual(
            shown.compactMap(\.book.rating).min() ?? 0, hiddenRatings.max() ?? 0)
    }

    /// Titles and series names as long and as wide as those the owner reviewed in a 2026 story
    /// image, in the same capitalization, letter in full, on one line or two, without
    /// truncating. That frame's pages render at the largest scale, as these spines do.
    @MainActor
    func testStackLettersLongTitlesWithoutTruncating() throws {
        func books(_ title: String, _ ids: ClosedRange<Int>, pages: Int) -> [CloudBook] {
            ids.map { id in
                CloudBook(
                    id: id, title: title, author: "Author", coverURL: nil, detailCoverURL: nil,
                    seriesID: ids.count > 1 ? ids.lowerBound : nil,
                    seriesName: ids.count > 1 ? title : nil, pages: pages,
                    finished: "2026-02-01")
            }
        }
        let library =
            books("THE LAST GATE OF NORTHWIND", 1...1, pages: 300)
            + books("We Who Have Never Seen Rain", 2...2, pages: 200)
            + books("THE MOONWELL TRILOGY", 3...5, pages: 400)
            + books("Mona and Daisy Mysteries", 6...8, pages: 300)
            + books("MOUNTAIN WANDERER NED", 9...16, pages: 450)
        let spines = StackSpine.spines(library)
        XCTAssertEqual(spines.count, 5)
        let area = YearStackCard.area(.story)
        let layout = StackLayout(spines: spines, area: area, seed: 1)
        XCTAssertEqual(layout.scale, StackLayout.maximumScale(area), accuracy: 1e-9)
        for spine in spines {
            let title = try XCTUnwrap(spine.titles.first)
            let thickness = spine.size.height * layout.scale
            let box = ShareSpine.letteringBox(spine, scale: layout.scale)
            for weight in [UIFont.Weight.semibold, .bold] {
                for design in [UIFontDescriptor.SystemDesign.default, .serif] {
                    // The lettering takes the first option that fits, as `ViewThatFits` does.
                    let fits = ShareSpine.options([title], thickness: thickness)
                        .contains { option in
                            let base = UIFont.systemFont(ofSize: option.size, weight: weight)
                            let font = UIFont(
                                descriptor: base.fontDescriptor.withDesign(design)
                                    ?? base.fontDescriptor,
                                size: option.size)
                            let width =
                                option.text.split(separator: "\n")
                                .map {
                                    (String($0) as NSString).size(withAttributes: [.font: font])
                                        .width
                                }
                                .max() ?? 0
                            return width <= box.width
                                && CGFloat(option.lines) * font.lineHeight <= thickness * 0.84
                        }
                    XCTAssertTrue(fits, "\(title) truncates in \(weight) \(design)")
                }
            }
        }
    }

    /// A crowded Year Stack spans several pages, each a full image.
    @MainActor
    func testCrowdedYearStackRendersEveryPage() throws {
        let books = (1...90)
            .map { index in
                CloudBook(
                    id: index, title: "Fictional Book \(index)", author: "Author",
                    coverURL: nil, detailCoverURL: nil, pages: 300,
                    finished: String(format: "2025-%02d-15", index % 12 + 1))
            }
        var input = ShareInput(
            template: .yearStack, aspect: .square, books: books, frame: .year(2025), seed: 2)
        XCTAssertGreaterThan(input.pageCount, 1)
        for page in 0..<input.pageCount {
            input.page = page
            let image = try XCTUnwrap(input.render()?.cgImage, "page \(page)")
            XCTAssertEqual(image.width, 1080)
            XCTAssertEqual(image.height, 1080)
        }
    }

    /// The largest difference in any color channel between two renders of the same size.
    private func largestChannelDifference(_ lhs: Data, _ rhs: Data) -> Int {
        guard lhs != rhs else { return 0 }
        return zip(lhs, rhs).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    /// The share of pixels that differ from the first pixel.
    private func differingFraction(_ image: CGImage) throws -> Double {
        let (width, height) = (image.width, image.height)
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        let first = try XCTUnwrap(pixels.first)
        return Double(pixels.count(where: { $0 != first })) / Double(pixels.count)
    }
}
