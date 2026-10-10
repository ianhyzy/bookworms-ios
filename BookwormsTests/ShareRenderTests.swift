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
    /// with flat ones.
    @MainActor
    func testEveryTemplateRendersAtExactPixelSizeWithContent() throws {
        let cases: [(frame: TimeFrame, style: ShareCoverStyle)] = [
            (.year(2025), .threeD), (.month(year: 2025, month: 5), .flat), (.lifetime, .flat),
        ]
        for template in ShareTemplate.allCases {
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
    /// Stack is left out because its spines carry their lettering.
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
        for template in ShareTemplate.allCases where template != .yearStack {
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

        let reading = ShareTemplate.currentlyReading
        XCTAssertEqual(reading.choices(from: Self.books, in: .year(2019)).map(\.id), [15, 16])
        XCTAssertEqual(reading.books(from: Self.books, in: .lifetime, bookID: 16).map(\.id), [16])
        XCTAssertEqual(reading.books(from: Self.books, in: .lifetime, bookID: 4).map(\.id), [15])
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
    }

    func testStackLayoutLeavesOutLowestRatedBooksWhenCrowded() {
        let books = (1...60)
            .map { index in
                CloudBook(
                    id: index, title: "Book \(index)", author: "Author", coverURL: nil,
                    detailCoverURL: nil, pages: 400, finished: "2025-01-01",
                    rating: Double(index % 5) + 1)
            }
        let area = CGSize(width: 952, height: 700)
        let layout = StackLayout(books: books, area: area, seed: 1)
        XCTAssertGreaterThan(layout.hiddenCount, 0)
        XCTAssertEqual(layout.slabs.count + layout.hiddenCount, books.count)
        XCTAssertLessThanOrEqual(layout.height, area.height + 0.5)
        let shownRatings = layout.slabs.compactMap(\.book.rating)
        let hiddenRatings =
            books.filter { book in
                !layout.slabs.contains { $0.book.id == book.id }
            }
            .compactMap(\.rating)
        XCTAssertGreaterThanOrEqual(shownRatings.min() ?? 0, hiddenRatings.max() ?? 0)
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
