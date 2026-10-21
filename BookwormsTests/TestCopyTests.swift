import XCTest

@testable import Bookworms

final class TestCopyTests: XCTestCase {
    func testOnlyTheInstalledMacAppIsNotATestCopy() {
        XCTAssertFalse(TestCopy.isTestCopy(bundleID: "gay.ian.Bookworms.Mac"))
        XCTAssertTrue(TestCopy.isTestCopy(bundleID: "gay.ian.Bookworms.scratch.marktest"))
        XCTAssertTrue(TestCopy.isTestCopy(bundleID: "gay.ian.Bookworms.iOS"))
        XCTAssertTrue(TestCopy.isTestCopy(bundleID: "gay.ian.Bookworms.Mac.scratch"))
        XCTAssertTrue(TestCopy.isTestCopy(bundleID: nil))
    }
}
