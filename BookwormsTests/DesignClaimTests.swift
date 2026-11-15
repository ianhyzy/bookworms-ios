import CloudKit
import XCTest

@testable import Bookworms

/// Two of the reader's devices claim books in one private database before they design them
/// (`CloudSpineStore.claimDesign(accountID:bookID:)`).
final class DesignClaimTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A store on `database` as the install `id`, whose clock reads `now`.
    private func device(_ id: String, on database: ChangeTagDatabase, now: Date? = nil)
        async throws -> CloudSpineStore
    {
        let now = now ?? start
        let store = CloudSpineStore(
            database: database, defaultsSuite: "gay.ian.Bookworms.iOS.tests.SignedOut",
            claimDeviceID: id, now: { now })
        _ = try await store.checkAccounts()
        return store
    }

    func testOnlyOneDeviceClaimsABook() async throws {
        let database = ChangeTagDatabase()
        let phone = try await device("phone", on: database)
        let mac = try await device("mac", on: database)

        let phoneClaims = await phone.claimDesign(accountID: "42", bookID: 7)
        let macClaims = await mac.claimDesign(accountID: "42", bookID: 7)
        let macClaimsAnother = await mac.claimDesign(accountID: "42", bookID: 8)
        // A run that iOS ended leaves its claim, which must not hold its own device back.
        let phoneClaimsAgain = await phone.claimDesign(accountID: "42", bookID: 7)

        XCTAssertTrue(phoneClaims)
        XCTAssertFalse(macClaims)
        XCTAssertTrue(macClaimsAnother)
        XCTAssertTrue(phoneClaimsAgain)
    }

    func testAnExpiredClaimGoesToTheNextDevice() async throws {
        let database = ChangeTagDatabase()
        let phone = try await device("phone", on: database)
        let early = try await device(
            "mac", on: database, now: start.addingTimeInterval(SpineClaimV1.lifetime - 1))
        let late = try await device(
            "mac", on: database, now: start.addingTimeInterval(SpineClaimV1.lifetime))

        _ = await phone.claimDesign(accountID: "42", bookID: 7)
        let claimsEarly = await early.claimDesign(accountID: "42", bookID: 7)
        let claimsLate = await late.claimDesign(accountID: "42", bookID: 7)
        // The Mac's claim is the newer one now.
        let phoneClaims = await phone.claimDesign(accountID: "42", bookID: 7)

        XCTAssertFalse(claimsEarly)
        XCTAssertTrue(claimsLate)
        XCTAssertFalse(phoneClaims)
    }

    /// Both devices read the book as unclaimed, and the Mac's save lands first.
    func testAClaimSavedDuringThisDevicesClaimHoldsTheBook() async throws {
        let database = ChangeTagDatabase()
        let phone = try await device("phone", on: database)
        try await database.putAfterNextFetch(
            SpineClaimV1(deviceID: "mac", claimedAt: start), type: "SpineClaimV1",
            name: CloudContract.designClaimRecordName(accountID: "42", bookID: 7))

        let claims = await phone.claimDesign(accountID: "42", bookID: 7)

        XCTAssertFalse(claims)
    }

    func testAClaimThatKeepsConflictingLeavesTheBook() async throws {
        let database = ChangeTagDatabase()
        let phone = try await device("phone", on: database)
        await database.refuseEverySave()

        let claims = await phone.claimDesign(accountID: "42", bookID: 7)

        XCTAssertFalse(claims)
    }

    func testAClaimOfAnotherVersionHoldsNoBookBack() async throws {
        let database = ChangeTagDatabase()
        let phone = try await device("phone", on: database)
        var newer = SpineClaimV1(deviceID: "mac", claimedAt: start)
        newer.version = 2
        try await database.put(
            newer, type: "SpineClaimV1",
            name: CloudContract.designClaimRecordName(accountID: "42", bookID: 7))

        let claims = await phone.claimDesign(accountID: "42", bookID: 7)

        XCTAssertTrue(claims)
    }

    func testAClaimThatCannotReachICloudHoldsNoBookBack() async throws {
        let database = ChangeTagDatabase()
        let phone = try await device("phone", on: database)
        await database.failEverySave(with: .networkUnavailable)

        let claims = await phone.claimDesign(accountID: "42", bookID: 7)

        XCTAssertTrue(claims)
    }
}
