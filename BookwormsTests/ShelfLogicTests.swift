import Foundation
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

    func testProvenanceNamesTheGenerator() {
        func design(_ generator: String) -> SpineDesignV1 {
            SpineDesignV1(
                version: 1, accountID: "42", bookID: 1,
                workItemHash: String(repeating: "a", count: 64),
                coverHash: String(repeating: "b", count: 64), generatorVersion: generator,
                generatedAt: Date(timeIntervalSince1970: 0), backgroundHex: "#101010",
                foregroundHex: "#F0F0F0", accentHex: "#808080", typeface: "serif", weight: 600,
                uppercase: false)
        }
        XCTAssertEqual(ShelfLabels.provenance(of: nil), "Not designed yet")
        XCTAssertEqual(
            ShelfLabels.provenance(of: design(CloudContract.generatorVersion)),
            "Designed with Private Cloud Compute")
        XCTAssertEqual(
            ShelfLabels.provenance(of: design("mac-foundation-models-v2")), "Designed on Mac")
        XCTAssertEqual(ShelfLabels.provenance(of: design("fixture-ai-styles-v1")), "Designed")
    }

    func testFormatLabelsMatchTheAppleTV() {
        XCTAssertEqual(ShelfLabels.format("Read"), "Physical")
        XCTAssertEqual(ShelfLabels.format("Listened"), "Audiobook")
        XCTAssertEqual(ShelfLabels.format("Ebook"), "Ebook")
        XCTAssertEqual(ShelfLabels.format("Both"), "Physical & audiobook")
        XCTAssertEqual(ShelfLabels.format("Scroll"), "Scroll")
        XCTAssertNil(ShelfLabels.format(nil))
    }

    func testSlabThicknessStaysInTheComfortableRange() {
        XCTAssertEqual(book(1, "Short", pages: 40).slabThickness, 44, accuracy: 0.001)
        XCTAssertEqual(book(2, "Long", pages: 2_000).slabThickness, 96, accuracy: 0.001)
        let typical = book(3, "Unknown length").slabThickness
        XCTAssertGreaterThan(typical, 44)
        XCTAssertLessThan(typical, book(4, "Longer", pages: 600).slabThickness)
    }

    func testWheelIsFlatAtTheCenterAndFadesAtTheEdges() {
        let center = WheelPose(distance: 0, length: 60, viewport: 500)
        XCTAssertEqual(center.angle.radians, 0, accuracy: 0.0001)
        XCTAssertEqual(center.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(center.offset, 0, accuracy: 0.0001)
        XCTAssertEqual(center.opacity, 1, accuracy: 0.0001)

        let above = WheelPose(distance: -120, length: 60, viewport: 500)
        let below = WheelPose(distance: 120, length: 60, viewport: 500)
        // The upper half tips its top edge away, and both halves crowd toward the center.
        XCTAssertGreaterThan(above.angle.radians, 0)
        XCTAssertEqual(above.angle.radians, -below.angle.radians, accuracy: 0.0001)
        XCTAssertGreaterThan(above.offset, 0)
        XCTAssertLessThan(below.offset, 0)
        XCTAssertLessThan(below.scale, 1)

        XCTAssertEqual(WheelPose(distance: 280, length: 60, viewport: 500).opacity, 0)
    }
}
