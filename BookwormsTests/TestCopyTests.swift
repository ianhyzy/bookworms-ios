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

    func testOnlyTheStoreCopyKeepsTheSharedKeychainNames() {
        let name = "gay.ian.Bookworms.iOS.hardcover"
        XCTAssertEqual(TestCopy.keychainService(name, bundleID: "gay.ian.Bookworms.iOS"), name)
        XCTAssertEqual(TestCopy.keychainService(name, bundleID: nil), name)
        XCTAssertEqual(
            TestCopy.keychainService(name, bundleID: "gay.ian.Bookworms.Mac"),
            "gay.ian.Bookworms.iOS.hardcover.gay.ian.Bookworms.Mac")
    }

    func testStoreReleaseBuildsDontMarkThemselves() {
        let store = "gay.ian.Bookworms.iOS"
        XCTAssertFalse(TestCopy.marksItself(bundleID: store, isRelease: true))
        XCTAssertTrue(TestCopy.marksItself(bundleID: store, isRelease: false))
        XCTAssertTrue(
            TestCopy.marksItself(bundleID: "gay.ian.Bookworms.scratch.marktest", isRelease: true))
        XCTAssertTrue(TestCopy.marksItself(bundleID: nil, isRelease: true))
        XCTAssertFalse(TestCopy.marksItself(bundleID: "gay.ian.Bookworms.Mac", isRelease: false))
        XCTAssertTrue(TestCopy.isTestCopy(bundleID: store), "Preview launches keep scratch keys")
    }
}
