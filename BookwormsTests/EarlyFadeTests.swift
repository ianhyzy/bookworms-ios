import XCTest

@testable import Bookworms

final class EarlyFadeTests: XCTestCase {
    /// The fade draws clear at and below `clearShare`, the part of its animation that is still
    /// to run when the details must already be gone.
    func testOpacityIsClearAtAndBelowClearShare() {
        XCTAssertEqual(EarlyFade.opacity(at: 1), 1)
        XCTAssertEqual(EarlyFade.opacity(at: EarlyFade.clearShare), 0)
        XCTAssertEqual(EarlyFade.opacity(at: 0), 0)
        XCTAssertGreaterThan(EarlyFade.opacity(at: EarlyFade.clearShare + 0.01), 0)
    }

    func testFadeNeverBrightensAsItHides() {
        let opacities = stride(from: 0.0, through: 1.0, by: 0.05).map(EarlyFade.opacity(at:))
        XCTAssertEqual(opacities, opacities.sorted())
    }
}
