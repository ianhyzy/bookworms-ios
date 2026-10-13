import Foundation
import Security
import XCTest

@testable import Bookworms

/// Covers the iPhone's Hardcover sign-in and library with canned, fictional responses. No test
/// contacts Hardcover; Keychain tests use their own service name.
final class HardcoverTests: XCTestCase {
    // MARK: - Device authorization

    func testPollingWaitsTheIntervalSlowsDownAndReturnsTheToken() async throws {
        let script = PollScript([
            .success(.pending), .failure(URLError(.networkConnectionLost)),
            .failure(HardcoverError.http(503)), .failure(HardcoverError.http(429)),
            .success(.slowDown), .success(.pending), .success(.success(token: "fictional-token")),
        ])
        let token = try await HardcoverClient.awaitApproval(
            of: authorization(interval: 5, expiresIn: 900), poll: { try await script.next() },
            sleep: { await script.sleep($0) })
        XCTAssertEqual(token, "fictional-token")
        let sleeps = await script.sleeps
        // Network and server failures keep polling; HTTP 429 and `slow_down` each add 5 seconds
        // to every later wait.
        XCTAssertEqual(sleeps, [5, 5, 5, 5, 10, 15, 15].map { .seconds($0) })
    }

    func testPollingStopsWhenDeniedOrExpired() async {
        let cases: [([DevicePollResult], Int, HardcoverError, Int)] = [
            ([.pending, .accessDenied], 900, .deviceFlowDenied, 2),
            ([.expired], 900, .deviceFlowExpired, 1),
            // The code's lifetime ends the wait even if Hardcover keeps answering `pending`.
            ([.pending, .pending, .pending, .pending], 12, .deviceFlowExpired, 3),
        ]
        for (replies, lifetime, expected, polls) in cases {
            let script = PollScript(replies.map { .success($0) })
            do {
                _ = try await HardcoverClient.awaitApproval(
                    of: authorization(interval: nil, expiresIn: lifetime),
                    poll: { try await script.next() }, sleep: { await script.sleep($0) })
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? HardcoverError, expected)
            }
            let sleeps = await script.sleeps
            XCTAssertEqual(sleeps.count, polls)
            // Without an interval from Hardcover, RFC 8628's 5 seconds applies.
            XCTAssertEqual(sleeps.first, .seconds(5))
        }
    }

    func testDeviceCodeAndTokenRepliesDecode() async throws {
        let client = HardcoverClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains("client_id=ca996be3-0df1-4cbf-819a-e17644fbcf38"))
            if request.url?.absoluteString == "https://hardcover.app/oauth2/device" {
                XCTAssertTrue(body.contains("scope=read:me:content%20read:library"))
                return Self.respond(
                    200,
                    #"{"device_code":"pending","user_code":"TEST-0001","verification_uri":"https://hardcover.app/link","verification_uri_complete":"https://hardcover.app/link?code=TEST-0001","expires_in":600,"interval":5}"#,
                    to: request)
            }
            XCTAssertEqual(request.url?.absoluteString, "https://hardcover.app/oauth2/token")
            XCTAssertTrue(body.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
            let replies = [
                "device_code=pending": (400, #"{"error":"authorization_pending"}"#),
                "device_code=slow": (400, #"{"error":"slow_down"}"#),
                "device_code=expired": (400, #"{"error":"expired_token"}"#),
                "device_code=denied": (400, #"{"error":"access_denied"}"#),
                "device_code=approved": (
                    200, #"{"access_token":" fictional-token ","token_type":"Bearer"}"#
                ),
                "device_code=unknown": (400, #"{"error":"invalid_grant"}"#),
                "device_code=down": (503, ""),
            ]
            let (status, json) = replies.first { body.contains($0.key) }!.value
            return Self.respond(status, json, to: request)
        }

        let authorization = try await client.requestDeviceAuthorization()
        XCTAssertEqual(authorization.userCode, "TEST-0001")
        XCTAssertEqual(
            authorization.pageURL.absoluteString, "https://hardcover.app/link?code=TEST-0001")

        let pending = try await client.pollToken(deviceCode: "pending")
        let slow = try await client.pollToken(deviceCode: "slow")
        let expired = try await client.pollToken(deviceCode: "expired")
        let denied = try await client.pollToken(deviceCode: "denied")
        let approved = try await client.pollToken(deviceCode: "approved")
        XCTAssertEqual(
            [pending, slow, expired, denied, approved],
            [.pending, .slowDown, .expired, .accessDenied, .success(token: "fictional-token")])
        for (code, expected) in [
            ("unknown", HardcoverError.invalidAuthorizationCode), ("down", .http(503)),
        ] {
            do {
                _ = try await client.pollToken(deviceCode: code)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? HardcoverError, expected)
            }
        }
    }

    func testApprovalPageStaysOnHardcover() {
        let foreign = DeviceAuthorization(
            deviceCode: "d", userCode: "TEST-0001",
            verificationURIComplete: URL(string: "https://example.com/link?code=TEST-0001"),
            expiresIn: 600, interval: 5)
        XCTAssertEqual(foreign.pageURL, HardcoverClient.linkURL)
        XCTAssertEqual(authorization(interval: 5, expiresIn: 600).pageURL, HardcoverClient.linkURL)
    }

    // MARK: - Account validation

    func testTokenValidationSeparatesExpiredLoginsFromMissingScopes() async throws {
        let cases: [(Int, String, HardcoverError)] = [
            (401, "{}", .invalidToken),
            (403, #"{"error":"insufficient_scope"}"#, .insufficientScope),
            (403, #"{"error":"forbidden"}"#, .forbidden),
            (200, #"{"data":{"me":[]}}"#, .invalidToken),
            (
                200,
                #"{"errors":[{"message":"Could not verify JWT: JWTExpired","extensions":{"code":"invalid-jwt"}}]}"#,
                .invalidToken
            ),
            (
                200,
                #"{"errors":[{"message":"not found","extensions":{"code":"validation-failed"}}]}"#,
                .rejected
            ),
            (429, "", .http(429)),
        ]
        for (status, body, expected) in cases {
            let client = HardcoverClient(transport: Self.reply(status, body))
            do {
                _ = try await client.account(token: "fictional-token")
                XCTFail("Expected \(expected) for HTTP \(status) \(body)")
            } catch {
                XCTAssertEqual(error as? HardcoverError, expected, "HTTP \(status) \(body)")
            }
        }

        let client = HardcoverClient { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"), "Bearer fictional-token")
            return Self.respond(200, Self.me, to: request)
        }
        let user = try await client.account(token: "Bearer fictional-token ")
        XCTAssertEqual(user, HardcoverUser(id: 4242, username: "fictional_reader"))
    }

    func testQueriesRetryServerErrorsAndShortRateLimits() async throws {
        let script = ReplyScript([(503, nil), (429, "0"), (200, nil)])
        let client = HardcoverClient { request in
            let (status, retryAfter) = await script.next()
            return Self.respond(status, Self.me, retryAfter: retryAfter, to: request)
        }
        let user = try await client.account(token: "fictional-token")
        XCTAssertEqual(user.id, 4242)
        let unused = await script.replies.count
        XCTAssertEqual(unused, 0)

        // A rate limit longer than 30 seconds ends the request at once.
        let limited = ReplyScript([(429, "120"), (200, nil)])
        let limitedClient = HardcoverClient { request in
            let (status, retryAfter) = await limited.next()
            return Self.respond(status, Self.me, retryAfter: retryAfter, to: request)
        }
        do {
            _ = try await limitedClient.account(token: "fictional-token")
            XCTFail("Expected HTTP 429")
        } catch {
            XCTAssertEqual(error as? HardcoverError, .http(429))
        }
        let left = await limited.replies.count
        XCTAssertEqual(left, 1)
    }

    @MainActor
    func testRejectedLoginAsksToReconnectAndKeepsTheLogin() async throws {
        let (tokens, defaults, library) = try Self.signedInStores()
        defer { tokens.delete() }
        let account = HardcoverAccount(
            tokens: tokens, client: HardcoverClient(transport: Self.reply(401, "")),
            defaults: defaults, libraryURL: library)
        let revision = account.libraryRevision
        XCTAssertTrue(account.isSignedIn)

        await account.sync()
        XCTAssertTrue(account.needsReconnect)
        XCTAssertTrue(account.isSignedIn, "The login stays until a reconnect or sign-out")
        XCTAssertEqual(account.syncError, HardcoverError.invalidToken.errorDescription)
        XCTAssertEqual(account.libraryRevision, revision, "A failed sync keeps the cached library")
    }

    @MainActor
    func testLoginWithoutItsAccountSummaryIsSignedOut() throws {
        // The Keychain keeps a login after the app is deleted; user defaults do not.
        let (tokens, defaults, library) = try Self.signedInStores()
        defer { tokens.delete() }
        defaults.removeObject(forKey: HardcoverAccount.summaryKey)
        try PhoneLibrary(accountID: "4242", username: nil, syncedAt: .now, books: [])
            .save(to: library)
        let account = HardcoverAccount(tokens: tokens, defaults: defaults, libraryURL: library)
        XCTAssertFalse(account.isSignedIn)
        XCTAssertNil(tokens.read(), "A leftover login is deleted")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: library.path()), "A leftover library is deleted")
    }

    // MARK: - Library

    func testLibraryNormalizesFixturePage() async throws {
        let client = HardcoverClient { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertFalse(body.contains("mutation"))
            if body.contains("query Account") { return Self.respond(200, Self.me, to: request) }
            XCTAssertTrue(body.contains(#""user":4242"#))
            // The Apple TV reads `review` with the same scopes; `review_raw` is unproven.
            XCTAssertTrue(body.contains("status_id review"))
            XCTAssertTrue(body.contains("series { id name }"))
            XCTAssertTrue(body.contains("description"))
            XCTAssertTrue(body.contains("ratings_distribution"))
            XCTAssertFalse(body.contains("review_raw"))
            return Self.respond(200, Self.libraryPage, to: request)
        }
        let library = try await client.library(token: "fictional-token")
        XCTAssertEqual(library.accountID, "4242")
        XCTAssertEqual(library.username, "fictional_reader")
        XCTAssertEqual(
            library.books,
            [
                CloudBook(
                    id: 101, title: "The Lantern Keeper: A Novel", author: "Mara Quill",
                    coverURL: URL(string: "https://covers.example.com/book-101.jpg"),
                    detailCoverURL: URL(string: "https://covers.example.com/reader-101.jpg"),
                    genres: ["Fantasy", "Mystery"], publicationYear: 2021, format: "Ebook",
                    seriesID: 9, seriesPosition: 1, seriesName: "The Lantern Cycle", pages: 336,
                    finished: "2025-03-01",
                    rating: 4.5, isRead: true, communityRating: 4.12, ratingsCount: 250,
                    ratingDistribution: [
                        RatingBucket(rating: 4, count: 120), RatingBucket(rating: 5, count: 130),
                    ],
                    // Stored as Hardcover sends it; the details clean it for display.
                    description: "<p>A keeper tends the <em>last</em> lantern.</p>",
                    review: "A quiet triumph & a joy.\n\nWould reread."),
                CloudBook(
                    id: 303, title: "Someday Soon", author: "Lena Marsh", coverURL: nil,
                    detailCoverURL: nil, publicationYear: 2026, pages: 280, ratingsCount: 3),
                CloudBook(
                    id: 202, title: "Salt and Static", author: "Iris Okafor", coverURL: nil,
                    detailCoverURL: nil, publicationYear: 2024, format: "Read", pages: 200,
                    isReading: true, progress: 0.25, started: "2025-04-10", ratingsCount: 0),
            ])
        // Only the finished book belongs on the shelf: not the current read, and not the book
        // on Want to Read.
        XCTAssertEqual(library.books.filter(\.hasBeenRead).map(\.id), [101])
    }

    func testReviewTextBecomesPlainText() {
        let plain = HardcoverClient.plainText(from:)
        XCTAssertNil(plain(nil))
        XCTAssertNil(plain(" \n<p></p> "))
        XCTAssertEqual(
            plain("<p>A <em>quiet</em> triumph &amp; a joy.</p><p>Would reread.</p>"),
            "A quiet triumph & a joy.\n\nWould reread.")
        XCTAssertEqual(
            plain("Line one<br/>Line two<BR>Line three"), "Line one\nLine two\nLine three")
        XCTAssertEqual(
            plain(
                "# Verdict\n\n**Loved it.** Read [the sequel](https://example.com) next.\n> Five stars, _easily_."
            ),
            "Verdict\n\nLoved it. Read the sequel next.\nFive stars, easily.")
        XCTAssertEqual(
            plain("Tea &amp; toast &#8212; I <3 it, 5 * 3 > 2 and snake_case stays. #bookclub"),
            "Tea & toast — I <3 it, 5 * 3 > 2 and snake_case stays. #bookclub")
        XCTAssertEqual(plain("First.\n \n\n\nSecond."), "First.\n\nSecond.")
    }

    // MARK: - Library source

    func testSignedInPhoneLibraryIsUsedOnlyWithoutAListingWorklist() {
        let phone = PhoneLibrary(
            accountID: "4242", username: nil, syncedAt: .distantPast, books: [])
        let listing = SpineWorklistV1(
            version: 1, accountID: "4242", syncedAt: .distantPast, bookIDs: [1])
        let paused = SpineWorklistV1(
            version: 1, accountID: "4242", syncedAt: .distantPast, bookIDs: [])
        func source(_ worklist: SpineWorklistV1?, _ signedIn: String?, _ phone: PhoneLibrary?)
            -> WorkSource
        {
            WorkSource(worklist: worklist, signedInAccountID: signedIn, phone: phone)
        }
        XCTAssertEqual(source(listing, "4242", phone), .worklist)
        XCTAssertEqual(source(listing, nil, nil), .worklist)
        XCTAssertEqual(source(nil, "4242", phone), .phone(phone))
        XCTAssertEqual(source(paused, "4242", phone), .phone(phone))
        XCTAssertEqual(source(nil, nil, nil), .archive)
        XCTAssertEqual(source(paused, nil, nil), .none)
        // Signed in without the account's own copy, such as before the first download or after
        // iOS evicts it, nothing is designed: the archive may belong to another account.
        XCTAssertEqual(source(nil, "4242", nil), .none)
        XCTAssertEqual(source(nil, "7", phone), .none)
    }

    // MARK: - Keychain

    func testTokenStoreKeepsOneDeviceOnlyItem() throws {
        let store = HardcoverTokenStore(service: "gay.ian.Bookworms.iOS.tests.\(UUID().uuidString)")
        defer { store.delete() }
        XCTAssertNil(store.read())
        try store.save("first-token")
        try store.save("second-token")
        XCTAssertEqual(store.read(), "second-token")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let items = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(
            items.first?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(items.first?[kSecAttrSynchronizable as String] as? Bool, true)

        store.delete()
        XCTAssertNil(store.read())
    }

    // MARK: - Fixtures

    private func authorization(interval: Int?, expiresIn: Int) -> DeviceAuthorization {
        DeviceAuthorization(
            deviceCode: "fictional-device-code", userCode: "TEST-0001",
            verificationURIComplete: nil, expiresIn: expiresIn, interval: interval)
    }

    /// A saved login and its account summary, in a Keychain service and a user defaults suite
    /// that only these tests use, and a library file path of the test's own, so no test touches
    /// the host app's cached library.
    @MainActor
    private static func signedInStores() throws -> (HardcoverTokenStore, UserDefaults, URL) {
        let tokens = HardcoverTokenStore(
            service: "gay.ian.Bookworms.iOS.tests.\(UUID().uuidString)")
        try tokens.save("fictional-token")
        let suite = "gay.ian.Bookworms.iOS.tests.HardcoverAccount"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(
            try JSONEncoder()
                .encode(
                    HardcoverAccount.Summary(accountID: "4242", username: "fictional_reader")),
            forKey: HardcoverAccount.summaryKey)
        let library = URL.temporaryDirectory.appending(
            path: "hardcover-library-\(UUID().uuidString).json")
        return (tokens, defaults, library)
    }

    /// A transport that answers every request with `status` and `body`.
    private static func reply(_ status: Int, _ body: String) -> HardcoverClient.Transport {
        { respond(status, body, to: $0) }
    }

    private static func respond(
        _ status: Int, _ body: String, retryAfter: String? = nil, to request: URLRequest
    ) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] })!
        return (Data(body.utf8), response)
    }

    private static let me = #"{"data":{"me":[{"id":4242,"username":"fictional_reader"}]}}"#

    /// One fictional page: a finished book with an HTML review, a current read, a book on Want to
    /// Read, and an older row for the first book that normalization drops.
    private static let libraryPage = """
        {"data":{"user_books":[
          {"status_id":3,"last_read_date":"2025-03-02","rating":4.5,
           "review":"<p>A <strong>quiet</strong> triumph &amp; a joy.</p><p>Would reread.</p>",
           "book":{"id":101,"title":"The Lantern Keeper: A Novel","pages":320,"release_year":2021,
             "cached_contributors":[{"author":{"name":"Mara Quill"},"contribution":null},
               {"author":{"name":"Theo Vance"},"contribution":"Translator"}],
             "cached_tags":{"Genre":[{"tag":"Fiction","count":90,"spoilerRatio":0},
               {"tag":"Mystery","count":40,"spoilerRatio":0},{"tag":"Fantasy","count":60,"spoilerRatio":0.05},
               {"tag":"Twist Ending","count":80,"spoilerRatio":0.5}],
               "Mood":[{"tag":"Cozy","count":12,"spoilerRatio":0}]},
             "rating":4.12,"ratings_count":250,
             "ratings_distribution":[{"rating":4,"count":120},{"rating":5,"count":130}],
             "description":"<p>A keeper tends the <em>last</em> lantern.</p>",
             "image":{"url":"https://covers.example.com/book-101.jpg","width":400,"height":600},
             "book_series":[{"featured":false,"position":2,"series":{"id":7,"name":"Lantern Tales"}},
               {"featured":true,"position":1,"series":{"id":9,"name":" The Lantern Cycle "}}],
             "editions":[{"image":{"url":"https://covers.example.com/edition-101.jpg","width":900,"height":1350}}]},
           "edition":null,
           "user_book_reads":[{"finished_at":"2025-03-01","edition":{"pages":336,"audio_seconds":null,
             "image":{"url":"https://covers.example.com/reader-101.jpg","width":800,"height":1200},
             "reading_format":{"format":"Ebook"},"language":null}}],
           "current_read":[]},
          {"status_id":2,"last_read_date":null,"rating":null,"review":null,
           "book":{"id":202,"title":"Salt and Static","pages":400,"release_year":2024,
             "cached_contributors":[{"author":{"name":"Iris Okafor"},"contribution":"Author"}],
             "cached_tags":null,"rating":null,"ratings_count":0,"image":null,"book_series":[],"editions":[]},
           "edition":{"pages":200,"audio_seconds":null,"image":null,"reading_format":{"format":"Read"},"language":null},
           "user_book_reads":[],
           "current_read":[{"started_at":"2025-04-10","progress":null,"progress_pages":50,
             "progress_seconds":null,"edition":{"pages":null,"audio_seconds":null}}]},
          {"status_id":1,"last_read_date":null,"rating":null,"review":null,
           "book":{"id":303,"title":"Someday Soon","pages":280,"release_year":2026,
             "cached_contributors":[{"author":{"name":"Lena Marsh"},"contribution":null}],
             "cached_tags":null,"rating":null,"ratings_count":3,"image":null,"book_series":[],"editions":[]},
           "edition":null,"user_book_reads":[],"current_read":[]},
          {"status_id":3,"last_read_date":"2023-01-05","rating":3,"review":"Older read.",
           "book":{"id":101,"title":"The Lantern Keeper: A Novel","pages":320,"release_year":2021,
             "cached_contributors":[],"cached_tags":null,"rating":4.12,"ratings_count":250,
             "image":null,"book_series":[],"editions":[]},
           "edition":null,"user_book_reads":[],"current_read":[]}
        ]}}
        """
}

/// Replays poll results and records the waits between them.
private actor PollScript {
    private var replies: [Result<DevicePollResult, any Error>]
    private(set) var sleeps: [Duration] = []

    init(_ replies: [Result<DevicePollResult, any Error>]) {
        self.replies = replies
    }

    func next() throws -> DevicePollResult { try replies.removeFirst().get() }

    func sleep(_ duration: Duration) { sleeps.append(duration) }
}

/// Replays HTTP statuses in order, each with an optional `Retry-After` value.
private actor ReplyScript {
    private(set) var replies: [(status: Int, retryAfter: String?)]

    init(_ replies: [(status: Int, retryAfter: String?)]) {
        self.replies = replies
    }

    func next() -> (status: Int, retryAfter: String?) { replies.removeFirst() }
}
