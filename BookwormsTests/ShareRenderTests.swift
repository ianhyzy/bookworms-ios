import CoreGraphics
import UIKit
import XCTest

@testable import Bookworms

final class ShareRenderTests: XCTestCase {
    /// Fictional books over two years, with gaps in pages, ratings, genres, and designs, a long
    /// title, and a contributor list. None has a cover, so Book3DView draws its fallback cover.
    private static let books: [CloudBook] = (1...14).map(fixture)

    private static func fixture(_ index: Int) -> CloudBook {
        let title =
            index == 3
            ? "An Unusually Long Fictional Title That Keeps Going: With a Subtitle"
            : "Fictional Book \(index)"
        let author = index == 5 ? "First Author, Second Author, Third Author" : "Author \(index)"
        let pages: Int? = index.isMultiple(of: 4) ? nil : 120 + index * 61
        let year = index <= 10 ? 2025 : 2024
        let rating: Double? = index.isMultiple(of: 3) ? nil : Double(index % 5) + 0.5
        let audioSeconds: Int? = index % 3 == 2 ? 36_000 + index * 600 : nil
        return CloudBook(
            id: index, title: title, author: author, coverURL: nil, detailCoverURL: nil,
            genres: index == 7
                ? nil : index.isMultiple(of: 2) ? ["Fantasy", "Mystery"] : ["Horror"],
            format: ["Read", "Ebook", "Listened"][index % 3], pages: pages,
            finished: String(format: "%d-%02d-15", year, index % 12 + 1), rating: rating,
            audioSeconds: audioSeconds)
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

    @MainActor
    func testEveryTemplateRendersAtExactPixelSizeWithContent() throws {
        for template in ShareTemplate.allCases {
            let year: Int? = template == .spectrum ? nil : 2025
            let books = template.books(from: Self.books, year: year, bookID: nil)
            XCTAssertFalse(books.isEmpty, "\(template)")
            for aspect in ShareAspect.allCases {
                let input = ShareInput(
                    template: template, aspect: aspect, books: books, looks: Self.looks,
                    year: year, seed: 7)
                let image = try XCTUnwrap(input.render()?.cgImage, "\(template) \(aspect)")
                XCTAssertEqual(image.width, Int(aspect.size.width), "\(template) \(aspect)")
                XCTAssertEqual(image.height, Int(aspect.size.height), "\(template) \(aspect)")
                XCTAssertGreaterThan(
                    try differingFraction(image), 0.05, "\(template) \(aspect) is a flat color")
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
            (
                ShareTemplate.yearInBooks.books(from: Self.books, year: 2025, bookID: nil), 2025,
                false
            ),
        ]
        for (books, year, showsRatings) in cases {
            for aspect in ShareAspect.allCases {
                let input = ShareInput(
                    template: .yearInBooks, aspect: aspect, books: books, looks: Self.looks,
                    year: year, showsRatings: showsRatings, seed: 7)
                let image = try XCTUnwrap(input.render()?.cgImage, "\(year) \(aspect)")
                XCTAssertEqual(image.width, Int(aspect.size.width), "\(year) \(aspect)")
                XCTAssertEqual(image.height, Int(aspect.size.height), "\(year) \(aspect)")
                XCTAssertGreaterThan(
                    try differingFraction(image), 0.05, "\(year) \(aspect) is a flat color")
            }
        }
    }

    @MainActor
    func testSameSeedDrawsSameImage() throws {
        for template in [ShareTemplate.yearStack, .yearInBooks] {
            let books = template.books(from: Self.books, year: 2025, bookID: nil)
            func pixels(seed: UInt64) throws -> Data {
                let input = ShareInput(
                    template: template, aspect: .square, books: books, looks: Self.looks,
                    year: 2025, seed: seed)
                return try XCTUnwrap(input.render()?.cgImage?.dataProvider?.data as Data?)
            }
            XCTAssertEqual(try pixels(seed: 3), try pixels(seed: 3), "\(template)")
            XCTAssertNotEqual(try pixels(seed: 3), try pixels(seed: 4), "\(template)")
        }
    }

    func testSelectionOrdersEachTemplate() {
        let stack = ShareTemplate.yearStack.books(from: Self.books, year: 2025, bookID: nil)
        XCTAssertEqual(stack.count, 10)
        XCTAssertEqual(stack.compactMap(\.finished), stack.compactMap(\.finished).sorted())

        XCTAssertEqual(
            ShareTemplate.yearInBooks.books(from: Self.books, year: 2025, bookID: nil), stack)

        let top = ShareTemplate.topFive.books(from: Self.books, year: 2025, bookID: nil)
        XCTAssertEqual(top.map(\.id), [4, 8, 7, 2, 1])

        XCTAssertEqual(
            ShareTemplate.spectrum.books(from: Self.books, year: nil, bookID: nil).count, 14)
        XCTAssertEqual(
            ShareTemplate.justFinished.books(from: Self.books, year: 2024, bookID: nil).map(\.id),
            [10])
        XCTAssertEqual(
            ShareTemplate.justFinished.books(from: Self.books, year: nil, bookID: 12).map(\.id),
            [12])
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
