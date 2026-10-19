import XCTest

@testable import Bookworms

/// Checks that the inks on the paper props, such as the date-due card and the review page, keep
/// 7:1 on their card stock, as body text needs.
final class StationeryTests: XCTestCase {
    func testInksKeepSevenToOneOnTheCardStock() {
        for (name, ink) in [
            ("ink", Stationery.inkValue), ("label ink", Stationery.labelInkValue),
            ("stamp ink", Stationery.stampInkValue),
        ] {
            let contrast = ink.contrast(with: Stationery.stockValue)
            XCTAssertGreaterThanOrEqual(contrast, 7, "\(name): \(contrast)")
        }
    }
}
