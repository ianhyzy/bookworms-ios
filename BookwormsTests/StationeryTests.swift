import XCTest

@testable import Bookworms

/// Checks that the inks on the paper props, such as the date-due card and the review page, keep
/// 7:1 on their card stock, as body text needs.
final class StationeryTests: XCTestCase {
    func testInksKeepSevenToOneOnTheCardStock() {
        for (name, ink) in [
            ("ink", Stationery.inkValue), ("label ink", Stationery.labelInkValue),
            ("stamp ink", Stationery.stampInkValue), ("pen ink", Stationery.penInkValue),
        ] {
            let contrast = ink.contrast(with: Stationery.stockValue)
            XCTAssertGreaterThanOrEqual(contrast, 7, "\(name): \(contrast)")
        }
    }

    /// Checkout Card's lightest stamp, at 90 percent, and lightest writing, at 92 percent
    /// (`CheckoutCard`), still keep 7:1.
    func testCheckoutCardsLightestInksKeepSevenToOne() {
        for (name, ink, strength) in [
            ("stamp ink", Stationery.stampInkValue, 0.9), ("pen ink", Stationery.penInkValue, 0.92),
            ("ink", Stationery.inkValue, 0.92),
        ] {
            let faded = ink.mixed(with: Stationery.stockValue, 1 - strength)
            let contrast = faded.contrast(with: Stationery.stockValue)
            XCTAssertGreaterThanOrEqual(contrast, 7, "\(name): \(contrast)")
        }
    }
}
