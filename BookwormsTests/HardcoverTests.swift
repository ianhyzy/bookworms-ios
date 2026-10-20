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
            .success(.slowDown), .success(.pending),
            .success(.success(HardcoverCredential(accessToken: "fictional-token"))),
        ])
        let credential = try await HardcoverClient.awaitApproval(
            of: authorization(interval: 5, expiresIn: 900), poll: { try await script.next() },
            sleep: { await script.sleep($0) })
        XCTAssertEqual(credential.accessToken, "fictional-token")
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
            if request.url?.absoluteString == "https://api.hardcover.app/oauth2/device" {
                XCTAssertTrue(body.contains("scope=read:me:content%20read:library"))
                return Self.respond(
                    200,
                    #"{"device_code":"pending","user_code":"TEST-0001","verification_uri":"https://hardcover.app/link","verification_uri_complete":"https://hardcover.app/link?code=TEST-0001","expires_in":600,"interval":5}"#,
                    to: request)
            }
            XCTAssertEqual(request.url?.absoluteString, "https://api.hardcover.app/oauth2/token")
            XCTAssertTrue(body.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
            let replies = [
                "device_code=pending": (400, #"{"error":"authorization_pending"}"#),
                "device_code=slow": (400, #"{"error":"slow_down"}"#),
                "device_code=expired": (400, #"{"error":"expired_token"}"#),
                "device_code=denied": (400, #"{"error":"access_denied"}"#),
                "device_code=approved": (
                    200,
                    #"{"access_token":" fictional-token ","refresh_token":"fictional-refresh","expires_in":604800,"token_type":"Bearer"}"#
                ),
                "device_code=bare": (
                    200, #"{"access_token":"fictional-token","token_type":"Bearer"}"#
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
        let bare = try await client.pollToken(deviceCode: "bare")
        XCTAssertEqual(
            [pending, slow, expired, denied, bare],
            [
                .pending, .slowDown, .expired, .accessDenied,
                .success(HardcoverCredential(accessToken: "fictional-token")),
            ])
        // The login keeps the refresh token and counts the access token's week from the reply.
        guard case .success(let approved) = try await client.pollToken(deviceCode: "approved")
        else { return XCTFail("Expected a login") }
        XCTAssertEqual(approved.accessToken, "fictional-token")
        XCTAssertEqual(approved.refreshToken, "fictional-refresh")
        XCTAssertEqual(
            try XCTUnwrap(approved.expiresAt).timeIntervalSinceNow, 604_800, accuracy: 60)
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
        let (tokens, defaults, library) = try signedInStores()
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
        let (tokens, defaults, library) = try signedInStores()
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

    @MainActor
    func testMissingLoginSignsOutAndDeletesTheSummaryAndLibrary() throws {
        // A backup restores the summary without the device-only login.
        let (_, defaults, library) = try signedInStores()
        try PhoneLibrary(accountID: "4242", username: nil, syncedAt: .now, books: [])
            .save(to: library)
        let account = HardcoverAccount(
            tokens: FakeSecretStore(nil), defaults: defaults, libraryURL: library)
        XCTAssertFalse(account.isSignedIn)
        XCTAssertNil(account.summary)
        XCTAssertNil(defaults.data(forKey: HardcoverAccount.summaryKey))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: library.path()), "A leftover library is deleted")
    }

    @MainActor
    func testUnreadableLoginStaysSavedUntilAReadSucceeds() async throws {
        let (_, defaults, library) = try signedInStores()
        try Self.cache(
            PhoneLibrary(
                accountID: "4242", username: "fictional_reader", syncedAt: Self.hoursAgo(30),
                books: []),
            at: library, defaults: defaults)
        // Before the first unlock after a restart, the Keychain refuses every read.
        let tokens = FakeSecretStore("fictional-token", isReadable: false)
        let requests = RequestCount()
        let account = HardcoverAccount(
            tokens: tokens,
            client: HardcoverClient { request in
                await requests.add()
                return try await Self.libraryTransport(request)
            },
            defaults: defaults, libraryURL: library)
        XCTAssertTrue(account.isSignedIn, "The summary marks the sign-in until a read succeeds")
        XCTAssertEqual(tokens.deletes, 0)
        XCTAssertNotNil(defaults.data(forKey: HardcoverAccount.summaryKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path()))
        XCTAssertEqual(tokens.loads, 1)

        // A due download and its requests report the refusal without asking the Keychain again,
        // so a Mac shows no prompt for them.
        await account.syncIfStale()
        XCTAssertEqual(account.syncError, HardcoverError.credentialUnreadable.errorDescription)
        let refusal = await thrownError { try await account.accessToken() }
        XCTAssertEqual(refusal as? HardcoverError, .credentialUnreadable)
        XCTAssertEqual(tokens.loads, 1)

        // **Sync now** reads the login once more.
        await account.sync()
        XCTAssertEqual(account.syncError, HardcoverError.credentialUnreadable.errorDescription)
        XCTAssertFalse(account.needsReconnect)
        XCTAssertEqual(tokens.secret, "fictional-token")
        XCTAssertEqual(tokens.loads, 2)
        let refused = await requests.count
        XCTAssertEqual(refused, 0)

        // After the unlock, the next sync reads the login and downloads the library.
        tokens.isReadable = true
        await account.sync()
        XCTAssertNil(account.syncError)
        XCTAssertEqual(PhoneLibrary.load(from: library)?.books.map(\.id), [101, 303, 202])
        XCTAssertEqual(tokens.deletes, 0)
        XCTAssertEqual(tokens.loads, 3, "The download reuses the login that Sync now read")
    }

    @MainActor
    func testUnreadableLoginWithoutASummaryDeletesNothingUntilALaunchReadsIt() throws {
        // Before the first unlock, user defaults can read as empty too.
        let (_, defaults, library) = try signedInStores()
        defaults.removeObject(forKey: HardcoverAccount.summaryKey)
        try PhoneLibrary(accountID: "4242", username: nil, syncedAt: .now, books: [])
            .save(to: library)
        let tokens = FakeSecretStore("fictional-token", isReadable: false)
        let account = HardcoverAccount(tokens: tokens, defaults: defaults, libraryURL: library)
        XCTAssertFalse(account.isSignedIn)
        XCTAssertEqual(tokens.deletes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path()))

        // User defaults may still read as empty after the unlock in the same process, so a
        // retry that reads the login keeps it and the library.
        tokens.isReadable = true
        account.retryUnreadLogin()
        XCTAssertFalse(account.isSignedIn)
        XCTAssertEqual(tokens.deletes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path()))

        // A launch that reads the login without a summary deletes it as a leftover.
        _ = HardcoverAccount(tokens: tokens, defaults: defaults, libraryURL: library)
        XCTAssertNil(tokens.secret)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path()))
    }

    // MARK: - Login renewal

    @MainActor
    func testExpiringLoginRenewsOnceForConcurrentRequestsAndSavesTheRotatedLogin() async throws {
        let (_, defaults, library) = try signedInStores()
        let tokens = FakeSecretStore(
            try HardcoverCredential(
                accessToken: "fictional-old", refreshToken: "fictional-refresh-1",
                expiresAt: .now.addingTimeInterval(600)
            )
            .stored())
        let renewals = RequestCount()
        let account = HardcoverAccount(
            tokens: tokens,
            client: HardcoverClient { request in
                guard request.url?.absoluteString == "https://api.hardcover.app/oauth2/token" else {
                    XCTFail("Only the renewal is requested")
                    return Self.respond(500, "", to: request)
                }
                await renewals.add()
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                XCTAssertTrue(body.contains("refresh_token=fictional-refresh-1"))
                XCTAssertTrue(body.contains("client_id=ca996be3-0df1-4cbf-819a-e17644fbcf38"))
                return Self.respond(200, Self.renewedLogin, to: request)
            },
            defaults: defaults, libraryURL: library)

        // The token expires within the renewal margin, so each request waits for one renewal.
        async let first = account.accessToken()
        async let second = account.accessToken()
        async let third = account.accessToken()
        let issued = try await [first, second, third]
        XCTAssertEqual(issued, ["fictional-new", "fictional-new", "fictional-new"])
        let count = await renewals.count
        XCTAssertEqual(count, 1, "Only one request spends the refresh token")
        let saved = HardcoverCredential(stored: try XCTUnwrap(tokens.secret))
        XCTAssertEqual(saved.accessToken, "fictional-new")
        XCTAssertEqual(saved.refreshToken, "fictional-refresh-2")
        XCTAssertEqual(
            try XCTUnwrap(saved.expiresAt).timeIntervalSinceNow, 604_800, accuracy: 60)

        // The renewed token lasts a week, so the next request renews nothing.
        let next = try await account.accessToken()
        XCTAssertEqual(next, "fictional-new")
        let after = await renewals.count
        XCTAssertEqual(after, 1)
        XCTAssertEqual(tokens.loads, 1, "Requests reuse the login read at launch")
    }

    @MainActor
    func testRejectedTokenRenewsOnceAndRetriesEachRequest() async throws {
        let (_, defaults, library) = try signedInStores()
        // Hardcover rejects the token before its saved expiry, as after a reset on its side.
        let tokens = FakeSecretStore(
            try HardcoverCredential(
                accessToken: "fictional-old", refreshToken: "fictional-refresh-1",
                expiresAt: .now.addingTimeInterval(86_400)
            )
            .stored())
        let renewals = RequestCount()
        let client = HardcoverClient { request in
            if request.url?.path() == "/oauth2/token" {
                await renewals.add()
                return Self.respond(200, Self.renewedLogin, to: request)
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fictional-new"
            else { return Self.respond(401, "", to: request) }
            return try await Self.libraryTransport(request)
        }
        let account = HardcoverAccount(
            tokens: tokens, client: client, defaults: defaults, libraryURL: library)

        async let synced: Void = account.sync()
        async let user = account.withAccessToken { try await client.account(token: $0) }
        let (_, reader) = try await (synced, user)
        XCTAssertEqual(reader.id, 4242)
        XCTAssertNil(account.syncError)
        XCTAssertFalse(account.needsReconnect)
        XCTAssertEqual(PhoneLibrary.load(from: library)?.books.map(\.id), [101, 303, 202])
        let count = await renewals.count
        XCTAssertEqual(count, 1, "Requests rejected together share one renewal")
        XCTAssertEqual(
            HardcoverCredential(stored: try XCTUnwrap(tokens.secret)).refreshToken,
            "fictional-refresh-2")
    }

    @MainActor
    func testRevokedRefreshTokenAsksToReconnectAndKeepsTheLogin() async throws {
        let (_, defaults, library) = try signedInStores()
        let login = try HardcoverCredential(
            accessToken: "fictional-old", refreshToken: "fictional-spent",
            expiresAt: .now.addingTimeInterval(-60)
        )
        .stored()
        let tokens = FakeSecretStore(login)
        func account(renewalStatus: Int, body: String) -> HardcoverAccount {
            HardcoverAccount(
                tokens: tokens,
                client: HardcoverClient { request in
                    guard request.url?.path() == "/oauth2/token" else {
                        XCTFail("An expired token is never sent")
                        return Self.respond(401, "", to: request)
                    }
                    return Self.respond(renewalStatus, body, to: request)
                },
                defaults: defaults, libraryURL: library)
        }

        // A server failure, or a refusal other than `invalid_grant`, keeps the login for the next
        // try.
        for (status, body) in [(503, ""), (403, #"{"error":"access_denied"}"#), (400, "<html>")] {
            let unavailable = account(renewalStatus: status, body: body)
            await unavailable.sync()
            XCTAssertEqual(unavailable.syncError, HardcoverError.http(status).errorDescription)
            XCTAssertFalse(unavailable.needsReconnect, "HTTP \(status)")
        }

        // A spent, expired, or revoked refresh token needs a new sign-in.
        let revoked = account(renewalStatus: 400, body: #"{"error":"invalid_grant"}"#)
        await revoked.sync()
        XCTAssertTrue(revoked.needsReconnect)
        XCTAssertTrue(revoked.isSignedIn, "The login stays until a reconnect or sign-out")
        XCTAssertEqual(revoked.syncError, HardcoverError.invalidToken.errorDescription)
        XCTAssertEqual(tokens.secret, login)
        XCTAssertEqual(tokens.saves, [])
    }

    func testOnlyInvalidGrantWithHTTP400Or401RejectsTheRefreshToken() async {
        let cases: [(status: Int, body: String, expected: HardcoverError)] = [
            (400, #"{"error":"invalid_grant"}"#, .invalidToken),
            (401, #"{"error":"invalid_grant"}"#, .invalidToken),
            (401, #"{"error":"invalid_client","error_description":"Unknown"}"#, .http(401)),
            (400, #"{"error":"unsupported_grant_type"}"#, .http(400)),
            (400, "<html>Bad request</html>", .http(400)),
            (401, "", .http(401)),
            (400, #"{"error":400}"#, .http(400)),
            (403, #"{"error":"access_denied"}"#, .http(403)),
            (408, #"{"error":"timeout"}"#, .http(408)),
            (429, #"{"error":"slow_down"}"#, .http(429)),
            (503, #"{"error":"temporarily_unavailable"}"#, .http(503)),
        ]
        for (status, body, expected) in cases {
            let client = HardcoverClient { request in
                XCTAssertEqual(
                    request.url?.absoluteString, "https://api.hardcover.app/oauth2/token")
                return Self.respond(status, body, to: request)
            }
            do {
                _ = try await client.renew(refreshToken: "fictional-refresh")
                XCTFail("Expected \(expected) for HTTP \(status) \(body)")
            } catch {
                XCTAssertEqual(error as? HardcoverError, expected, "HTTP \(status) \(body)")
            }
        }
    }

    @MainActor
    func testFailedEarlyRenewalKeepsTheTokenUntilItExpires() async throws {
        let (_, defaults, library) = try signedInStores()
        let tokens = FakeSecretStore(
            try HardcoverCredential(
                accessToken: "fictional-old", refreshToken: "fictional-refresh-1",
                expiresAt: .now.addingTimeInterval(600)
            )
            .stored())
        let status = ReplyStatus(503)
        let gate = ReplyGate()
        let client = HardcoverClient { request in
            if request.url?.path() == "/oauth2/token" {
                await gate.wait()
                return Self.respond(
                    await status.value, #"{"error":"invalid_grant"}"#, to: request)
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fictional-old"
            else { return Self.respond(401, "", to: request) }
            return Self.respond(200, Self.me, to: request)
        }
        let account = HardcoverAccount(
            tokens: tokens, client: client, defaults: defaults, libraryURL: library)

        // Hardcover is down, so the token in use stays until it expires, both for the request
        // that renews the login and for one that waits for that renewal.
        let renewing = Task {
            try await account.withAccessToken { try await client.account(token: $0) }
        }
        while await gate.arrivals == 0 { await Task.yield() }
        let waiting = Task { try await account.accessToken() }
        await gate.open()
        let user = try await renewing.value
        XCTAssertEqual(user.id, 4242)
        let waited = try await waiting.value
        XCTAssertEqual(waited, "fictional-old")
        XCTAssertFalse(account.needsReconnect)

        // A token endpoint that answers `invalid_grant` refuses the refresh token, so the login
        // can't be renewed.
        await status.set(400)
        let refusal = await thrownError { try await account.accessToken() }
        XCTAssertEqual(refusal as? HardcoverError, .invalidToken)
        XCTAssertTrue(account.needsReconnect)
        XCTAssertEqual(tokens.saves, [])
    }

    @MainActor
    func testUnsavedRenewalAsksToReconnectAndNeverSpendsTheTokenAgain() async throws {
        let (_, defaults, library) = try signedInStores()
        let tokens = FakeSecretStore(
            try HardcoverCredential(
                accessToken: "fictional-old", refreshToken: "fictional-refresh-1",
                expiresAt: .now.addingTimeInterval(-60)
            )
            .stored())
        tokens.failsSaves = true
        let renewals = RequestCount()
        let account = HardcoverAccount(
            tokens: tokens,
            client: HardcoverClient { request in
                await renewals.add()
                return Self.respond(200, Self.renewedLogin, to: request)
            },
            defaults: defaults, libraryURL: library)

        let unsaved = await thrownError { try await account.accessToken() }
        XCTAssertEqual(unsaved as? HardcoverError, .credentialNotSaved)
        XCTAssertTrue(account.needsReconnect)
        // The saved refresh token is spent, and sending it again would revoke the new login.
        let spent = await thrownError { try await account.accessToken() }
        XCTAssertEqual(spent as? HardcoverError, .invalidToken)
        let count = await renewals.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSignOutDuringARenewalSavesNothing() async throws {
        let (_, defaults, library) = try signedInStores()
        let tokens = FakeSecretStore(
            try HardcoverCredential(
                accessToken: "fictional-old", refreshToken: "fictional-refresh-1",
                expiresAt: .now.addingTimeInterval(600)
            )
            .stored())
        let gate = ReplyGate()
        let account = HardcoverAccount(
            tokens: tokens,
            client: HardcoverClient { request in
                await gate.wait()
                return Self.respond(200, Self.renewedLogin, to: request)
            },
            defaults: defaults, libraryURL: library)

        let request = Task { try await account.accessToken() }
        while await gate.arrivals == 0 { await Task.yield() }
        account.signOut()
        await gate.open()
        // The cancelled renewal returns neither the new token nor the old one, which still works.
        let stopped = await thrownError { try await request.value }
        XCTAssertTrue(stopped is CancellationError)
        XCTAssertEqual(tokens.saves, [])
        XCTAssertNil(tokens.secret)
        XCTAssertFalse(account.isSignedIn)
        XCTAssertFalse(account.needsReconnect)
    }

    // MARK: - Library

    func testLibraryNormalizesFixturePage() async throws {
        let client = HardcoverClient { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertFalse(body.contains("mutation"))
            if body.contains("query Account") { return Self.respond(200, Self.me, to: request) }
            if body.contains("query PhoneSeries") {
                // Only the featured series of each book, as the Apple TV asks.
                XCTAssertTrue(body.contains(#""ids":[9]"#))
                return Self.respond(200, Self.seriesPage, to: request)
            }
            XCTAssertTrue(body.contains(#""user":4242"#))
            // The Apple TV reads `review` with the same scopes; `review_raw` is unproven.
            XCTAssertTrue(body.contains("status_id review"))
            XCTAssertTrue(
                body.contains(
                    "book_series { featured position compilation series { id name books_count primary_books_count } }"
                ))
            XCTAssertTrue(body.contains("description"))
            XCTAssertTrue(body.contains("ratings_distribution"))
            XCTAssertFalse(body.contains("review_raw"))
            // Every finished read, in the same request.
            XCTAssertTrue(body.contains("order_by: [{finished_at: desc}, {id: desc}]) {"))
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
                    seriesID: 9, seriesPosition: 1, seriesName: "The Lantern Cycle",
                    seriesMemberships: [
                        SeriesMembership(
                            seriesID: 7, name: "Lantern Tales", position: 2, featured: false,
                            compilation: false, size: 3),
                        SeriesMembership(
                            seriesID: 9, name: "The Lantern Cycle", position: 1, featured: true,
                            compilation: false, size: 12),
                    ],
                    pages: 336,
                    finished: "2025-03-01", finishedDates: ["2025-03-01", "2022-06-10"],
                    rating: 4.5, isRead: true, statusID: 3, communityRating: 4.12,
                    ratingsCount: 250,
                    ratingDistribution: [
                        RatingBucket(rating: 4, count: 120), RatingBucket(rating: 5, count: 130),
                    ],
                    // Stored as Hardcover sends it; the details clean it for display.
                    description: "<p>A keeper tends the <em>last</em> lantern.</p>",
                    review: "A quiet triumph & a joy.\n\nWould reread."),
                CloudBook(
                    id: 303, title: "Someday Soon", author: "Lena Marsh", coverURL: nil,
                    detailCoverURL: nil, publicationYear: 2026, seriesMemberships: [], pages: 280,
                    statusID: 1, ratingsCount: 3),
                CloudBook(
                    id: 202, title: "Salt and Static", author: "Iris Okafor", coverURL: nil,
                    detailCoverURL: nil, publicationYear: 2024, format: "Read",
                    seriesMemberships: [], pages: 200,
                    isReading: true, statusID: 2, progress: 0.25, started: "2025-04-10",
                    ratingsCount: 0),
            ])
        // The Ignored book is left out. Only the finished book belongs on the shelf: not the
        // current read, and not the book on Want to Read.
        XCTAssertEqual(library.books.filter(\.hasBeenRead).map(\.id), [101])
        // The featured series names the book; the shorter series decides its look.
        XCTAssertEqual(SeriesDesigns.styleSeries(of: library.books[0], link: nil)?.id, 7)
        // One book per whole-number position, the first listed; only HTTPS covers.
        XCTAssertEqual(
            library.series,
            [
                SeriesInfo(
                    id: 9, name: "The Lantern Cycle",
                    books: [
                        SeriesInfo.SeriesBook(
                            id: 101, title: "The Lantern Keeper", position: 1, releaseYear: 2021,
                            coverURL: URL(string: "https://covers.example.com/book-101.jpg")),
                        SeriesInfo.SeriesBook(
                            id: 102, title: "Untitled", position: 2, releaseYear: nil,
                            coverURL: nil),
                    ])
            ])
    }

    /// A first download reports the books so far before the first page and after each, with
    /// the account's total, or without one when the count request fails.
    @MainActor
    func testFirstDownloadReportsBooksSoFarAndTheTotal() async throws {
        func page(_ ids: Range<Int>) -> String {
            let rows = ids.map { #"{"book":{"id":\#($0),"title":"Book \#($0)"}}"# }
            return #"{"data":{"user_books":[\#(rows.joined(separator: ","))]}}"#
        }
        let firstPage = page(1..<101)
        let lastPage = page(101..<151)
        struct Report: Equatable {
            let books: Int
            let total: Int?
        }
        @MainActor final class Reports { var list: [Report] = [] }

        for countFails in [false, true] {
            let client = HardcoverClient { request in
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                if body.contains("query Account") { return Self.respond(200, Self.me, to: request) }
                if body.contains("query PhoneLibraryCount") {
                    return Self.respond(
                        200,
                        countFails
                            ? #"{"errors":[{"message":"fictional failure"}]}"#
                            : #"{"data":{"user_books_aggregate":{"aggregate":{"count":150}}}}"#,
                        to: request)
                }
                let page = body.contains(#""offset":100"#) ? lastPage : firstPage
                return Self.respond(200, page, to: request)
            }
            let reports = Reports()
            let library = try await client.library(token: "fictional-token") { books, total in
                reports.list.append(Report(books: books, total: total))
            }
            XCTAssertEqual(library.books.count, 150)
            let total = countFails ? nil : 150
            XCTAssertEqual(
                reports.list,
                [
                    Report(books: 0, total: total), Report(books: 100, total: total),
                    Report(books: 150, total: total),
                ],
                "count fails: \(countFails)")
        }
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

    // MARK: - Fixed covers

    /// The Apple TV app's cases (`LibraryTests`), so both apps fix the same covers.
    func testSavedCoversStayUnlessALowQualityCoverHasASharpReplacement() {
        func cover(_ name: String, height: Int? = nil) -> LibraryPage.Image {
            LibraryPage.Image(
                url: URL(string: "https://example.com/\(name)"),
                width: height.map { $0 * 2 / 3 }, height: height)
        }
        let low = cover("low", height: 600)
        let sharp = cover("sharp", height: 1500)
        let fair = cover("fair", height: 900)
        let unsized = cover("unsized")
        let thumbnail = cover("thumbnail", height: 197)
        let saved = (preferred: low.url, alternate: URL(string: "https://example.com/saved"))
        func choice(_ images: [LibraryPage.Image], previous: (preferred: URL?, alternate: URL?)?)
            -> (preferred: URL?, alternate: URL?)
        {
            HardcoverClient.coverURLs(
                edition: nil, book: images.first, otherEditions: Array(images.dropFirst()),
                previous: previous)
        }

        XCTAssertEqual(
            choice([sharp], previous: nil).preferred, sharp.url, "A new book takes the new cover")
        XCTAssertEqual(
            choice([sharp], previous: (nil, saved.alternate)).preferred, sharp.url,
            "A book without a saved cover takes the new cover")
        let kept = choice([sharp], previous: saved)
        XCTAssertEqual(kept.preferred, low.url, "A saved cover missing from the sync stays")
        XCTAssertEqual(kept.alternate, saved.alternate)
        XCTAssertEqual(
            choice([low, sharp], previous: saved).preferred, sharp.url,
            "A low-quality cover upgrades to one at least 1000 pixels tall")
        XCTAssertEqual(
            choice([low, fair], previous: saved).preferred, low.url,
            "A cover under 1000 pixels is no upgrade")
        XCTAssertEqual(
            choice([thumbnail, unsized], previous: (thumbnail.url, nil)).preferred,
            thumbnail.url, "A cover without a reported height is never an upgrade")
        XCTAssertEqual(
            choice([unsized, sharp], previous: (unsized.url, nil)).preferred, unsized.url,
            "A saved cover without a reported height is never replaced")
    }

    func testSavedCoversStayOnlyForTheSignedInAccount() async throws {
        // The account is 4242, and its only book reports a 1500-pixel cover.
        let client = HardcoverClient { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("query Account") { return Self.respond(200, Self.me, to: request) }
            return Self.respond(
                200,
                #"{"data":{"user_books":[{"book":{"id":5,"title":"Covered","image":{"url":"https://example.com/current","width":1000,"height":1500}}}]}}"#,
                to: request)
        }
        let saved = CloudBook(
            id: 5, title: "Covered", author: "Unknown author",
            coverURL: URL(string: "https://example.com/saved-alternate"),
            detailCoverURL: URL(string: "https://example.com/saved"))
        func previous(_ accountID: String) -> PhoneLibrary {
            PhoneLibrary(
                accountID: accountID, username: nil, syncedAt: .distantPast, books: [saved])
        }
        let same = try await client.library(token: "fictional-token", previous: previous("4242"))
        XCTAssertEqual(same.books.first?.detailCoverURL, saved.detailCoverURL)
        XCTAssertEqual(same.books.first?.coverURL, saved.coverURL)
        let other = try await client.library(token: "fictional-token", previous: previous("7"))
        XCTAssertEqual(
            other.books.first?.detailCoverURL, URL(string: "https://example.com/current"),
            "Another account's copy never fixes covers")
    }

    // MARK: - iCloud copies

    /// A copy from an Apple TV build without `finishedDates` keeps this device's list for a book
    /// whose newest finish is unchanged.
    func testAdoptedCopyKeepsReadsAnOlderAppleTVDropped() {
        func book(_ id: Int, _ finished: String, _ dates: [String]? = nil) -> CloudBook {
            CloudBook(
                id: id, title: "Book \(id)", author: "Mara Quill", coverURL: nil,
                detailCoverURL: nil, finished: finished, finishedDates: dates)
        }
        let cached = PhoneLibrary(
            accountID: "4242", username: nil, syncedAt: Self.hoursAgo(5),
            books: [
                book(1, "2026-02-01", ["2026-02-01", "2019-07-04"]),
                book(2, "2025-05-05", ["2025-05-05", "2020-01-01"]),
                book(3, "2024-04-04", ["2024-04-04", "2018-08-08"]),
            ])
        // Book 2 was finished again after this device's copy, so its list is out of date.
        let copy = CloudSourceSnapshot(
            source: "hardcover", accountID: "4242",
            // An empty list counts as absent, like a missing one.
            books: [book(1, "2026-02-01"), book(2, "2026-03-03"), book(3, "2024-04-04", [])],
            syncedAt: Self.hoursAgo(1))
        let adopted = PhoneLibrary(copy, username: nil, keepingReadsOf: cached)
        XCTAssertEqual(
            adopted.books.map(\.finishedDates),
            [["2026-02-01", "2019-07-04"], nil, ["2024-04-04", "2018-08-08"]])
        XCTAssertEqual(adopted.books.map(\.readCount), [2, 1, 2])

        let other = PhoneLibrary(
            accountID: "7", username: nil, syncedAt: Self.hoursAgo(5), books: cached.books)
        XCTAssertNil(
            PhoneLibrary(copy, username: nil, keepingReadsOf: other).books.first?.finishedDates,
            "Another account's copy never adds reads")
    }

    @MainActor
    func testSyncAdoptsANewerICloudCopyWithoutAskingHardcover() async throws {
        let (tokens, defaults, library) = try signedInStores()
        defer { tokens.delete() }
        try Self.cache(
            PhoneLibrary(
                accountID: "4242", username: "fictional_reader", syncedAt: Self.hoursAgo(5),
                books: []),
            at: library, defaults: defaults)
        let book = CloudBook(
            id: 101, title: "The Lantern Keeper", author: "Mara Quill", coverURL: nil,
            detailCoverURL: URL(string: "https://covers.example.com/reader-101.jpg"),
            review: "A quiet triumph.")
        let copy = CloudSourceSnapshot(
            source: "hardcover", accountID: "4242", books: [book], syncedAt: Self.hoursAgo(1),
            series: [SeriesInfo(id: 9, name: "The Lantern Cycle", books: [])])
        let folder = try archiveFolder(with: [copy])
        let account = HardcoverAccount(
            tokens: tokens,
            client: HardcoverClient { request in
                XCTFail("A copy from the last day needs no Hardcover request")
                return Self.respond(500, "", to: request)
            },
            defaults: defaults, libraryURL: library)
        account.cloud = LocalSpineStore(folder: folder)
        let revision = account.libraryRevision

        await account.syncIfStale()
        let adopted = try XCTUnwrap(PhoneLibrary.load(from: library))
        XCTAssertEqual(adopted.books, [book])
        XCTAssertEqual(adopted.series, copy.series)
        XCTAssertEqual(adopted.syncedAt, copy.syncedAt)
        XCTAssertEqual(adopted.username, "fictional_reader")
        XCTAssertEqual(account.summary?.syncedAt, copy.syncedAt)
        XCTAssertEqual(account.libraryRevision, revision + 1)
        XCTAssertNil(account.publishTask, "An adopted copy is not published again")

        // An hour-old copy is fresh: no iCloud read and no download.
        try FileManager.default.removeItem(at: folder.appending(path: "library-v1.json"))
        await account.syncIfStale()
        XCTAssertEqual(account.libraryRevision, revision + 1)
    }

    @MainActor
    func testSyncAsksHardcoverOnceTheNewestCopyIsADayOldAndPublishesTheLibrary() async throws {
        let (tokens, defaults, library) = try signedInStores()
        defer { tokens.delete() }
        try Self.cache(
            PhoneLibrary(
                accountID: "4242", username: "fictional_reader", syncedAt: Self.hoursAgo(30),
                books: []),
            at: library, defaults: defaults)
        // The iCloud copy is newer than this device's but a day old, so Hardcover is asked, and
        // the book keeps the copy's cover. Another account's fresh copy doesn't count.
        let saved = CloudBook(
            id: 101, title: "The Lantern Keeper", author: "Mara Quill",
            coverURL: URL(string: "https://covers.example.com/saved-alternate-101.jpg"),
            detailCoverURL: URL(string: "https://covers.example.com/saved-101.jpg"))
        let folder = try archiveFolder(with: [
            CloudSourceSnapshot(
                source: "hardcover", accountID: "4242", books: [saved],
                syncedAt: Self.hoursAgo(25)),
            CloudSourceSnapshot(
                source: "hardcover", accountID: "7", books: [], syncedAt: Self.hoursAgo(1)),
        ])
        let account = HardcoverAccount(
            tokens: tokens, client: HardcoverClient(transport: Self.libraryTransport),
            defaults: defaults, libraryURL: library)
        account.cloud = LocalSpineStore(folder: folder)

        await account.syncIfStale()
        let synced = try XCTUnwrap(PhoneLibrary.load(from: library))
        XCTAssertEqual(synced.books.map(\.id), [101, 303, 202])
        XCTAssertEqual(synced.books.first?.detailCoverURL, saved.detailCoverURL)
        XCTAssertEqual(synced.books.first?.coverURL, saved.coverURL)
        XCTAssertGreaterThan(synced.syncedAt, Self.hoursAgo(1))
        XCTAssertEqual(account.summary?.syncedAt, synced.syncedAt)

        await account.publishTask?.value
        let archive = try JSONDecoder()
            .decode(
                CloudLibraryArchive.self,
                from: Data(contentsOf: folder.appending(path: "library-v1.json")))
        let published = try XCTUnwrap(archive.newestHardcoverSnapshot(accountID: "4242"))
        XCTAssertEqual(published.syncedAt, synced.syncedAt)
        XCTAssertEqual(published.books, synced.books)
        XCTAssertEqual(published.series?.map(\.id), [9])
        XCTAssertNotNil(archive.newestHardcoverSnapshot(accountID: "7"))
    }

    @MainActor
    func testADueDownloadReadsICloudFirstEvenRightAfterACheck() async throws {
        let (tokens, defaults, library) = try signedInStores()
        defer { tokens.delete() }
        try Self.cache(
            PhoneLibrary(
                accountID: "4242", username: "fictional_reader", syncedAt: Self.hoursAgo(30),
                books: []),
            at: library, defaults: defaults)
        let folder = try archiveFolder(with: [
            CloudSourceSnapshot(
                source: "hardcover", accountID: "7", books: [], syncedAt: Self.hoursAgo(1))
        ])
        let requests = RequestCount()
        let account = HardcoverAccount(
            tokens: tokens,
            client: HardcoverClient { request in
                await requests.add()
                return Self.respond(400, "", to: request)
            },
            defaults: defaults, libraryURL: library)
        account.cloud = LocalSpineStore(folder: folder)

        // The archive has no newer copy and the download fails, so the copy stays a day old
        // right after an iCloud read.
        await account.syncIfStale()
        XCTAssertNotNil(account.syncError)
        XCTAssertFalse(account.needsReconnect)
        let failed = await requests.count
        XCTAssertGreaterThan(failed, 0)

        // Another device then publishes the account's library.
        let copy = CloudSourceSnapshot(
            source: "hardcover", accountID: "4242", books: [], syncedAt: Self.hoursAgo(1))
        let archiveURL = folder.appending(path: "library-v1.json")
        try XCTUnwrap(CloudLibraryArchive.splice(copy, into: Data(contentsOf: archiveURL)))
            .write(to: archiveURL)
        await account.syncIfStale()
        XCTAssertEqual(PhoneLibrary.load(from: library)?.syncedAt, copy.syncedAt)
        let after = await requests.count
        XCTAssertEqual(after, failed, "A copy from the last day needs no Hardcover request")
    }

    @MainActor
    func testSyncNowKeepsTheArchivedCoversWithoutACopyOnThisDevice() async throws {
        let (tokens, defaults, library) = try signedInStores()
        defer { tokens.delete() }
        let saved = CloudBook(
            id: 101, title: "The Lantern Keeper", author: "Mara Quill",
            coverURL: URL(string: "https://covers.example.com/saved-alternate-101.jpg"),
            detailCoverURL: URL(string: "https://covers.example.com/saved-101.jpg"))
        let folder = try archiveFolder(with: [
            CloudSourceSnapshot(
                source: "hardcover", accountID: "4242", books: [saved],
                syncedAt: Self.hoursAgo(1))
        ])
        func account() -> HardcoverAccount {
            let account = HardcoverAccount(
                tokens: tokens, client: HardcoverClient(transport: Self.libraryTransport),
                defaults: defaults, libraryURL: library)
            account.cloud = LocalSpineStore(folder: folder)
            return account
        }

        let first = account()
        await first.sync()
        let synced = try XCTUnwrap(PhoneLibrary.load(from: library))
        XCTAssertEqual(synced.books.first?.detailCoverURL, saved.detailCoverURL)
        XCTAssertEqual(synced.books.first?.coverURL, saved.coverURL)
        await first.publishTask?.value
        let archive = try JSONDecoder()
            .decode(
                CloudLibraryArchive.self,
                from: Data(contentsOf: folder.appending(path: "library-v1.json")))
        XCTAssertEqual(archive.newestHardcoverSnapshot(accountID: "4242")?.books, synced.books)

        // With the archive unreadable and no copy here, the download saves but isn't published.
        PhoneLibrary.delete(at: library)
        try Data("unreadable".utf8).write(to: folder.appending(path: "library-v1.json"))
        let second = account()
        await second.sync()
        XCTAssertNotNil(PhoneLibrary.load(from: library))
        XCTAssertNil(second.publishTask)
    }

    @MainActor
    func testReconnectingTheSameAccountKeepsTheCopysSyncDate() async throws {
        let (tokens, defaults, library) = try signedInStores()
        defer { tokens.delete() }
        let kept = PhoneLibrary(
            accountID: "4242", username: "fictional_reader", syncedAt: Self.hoursAgo(5),
            books: [])
        try Self.cache(kept, at: library, defaults: defaults)
        // An older copy in iCloud, as after this device's upload failed.
        let folder = try archiveFolder(with: [
            CloudSourceSnapshot(
                source: "hardcover", accountID: "4242", books: [], syncedAt: Self.hoursAgo(9))
        ])
        let account = HardcoverAccount(
            tokens: tokens,
            client: HardcoverClient { request in
                switch request.url?.path() {
                case "/oauth2/device":
                    return Self.respond(
                        200,
                        #"{"device_code":"approved","user_code":"TEST-0001","verification_uri":"https://hardcover.app/link","expires_in":600,"interval":1}"#,
                        to: request)
                case "/oauth2/token":
                    return Self.respond(200, Self.renewedLogin, to: request)
                default:
                    return Self.respond(200, Self.me, to: request)
                }
            },
            defaults: defaults, libraryURL: library)
        account.cloud = LocalSpineStore(folder: folder)

        account.startSignIn()
        let deadline = Date.now.addingTimeInterval(10)
        while account.signIn != nil, Date.now < deadline {
            if case .failed(let message) = account.signIn { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(account.signIn)
        XCTAssertEqual(account.summary?.syncedAt, kept.syncedAt)
        let saved = HardcoverCredential(stored: try XCTUnwrap(tokens.read()))
        XCTAssertEqual(saved.accessToken, "fictional-new")
        XCTAssertEqual(saved.refreshToken, "fictional-refresh-2", "The login keeps refreshing")
        let token = try await account.accessToken()
        XCTAssertEqual(token, "fictional-new", "Requests use the new login")

        await account.syncIfStale()
        XCTAssertEqual(PhoneLibrary.load(from: library)?.syncedAt, kept.syncedAt)
    }

    // MARK: - Library source

    func testSignedInPhoneLibraryIsUsedUnlessAWorklistListsAnotherAccount() {
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
        let otherAccount = SpineWorklistV1(
            version: 1, accountID: "7", syncedAt: .distantPast, bookIDs: [1])
        // With its own copy, a signed-in device designs it even when the Apple TV's worklist of
        // the same account and copy, or an older one, lists books: fixed covers make both hash
        // the same.
        XCTAssertEqual(source(listing, "4242", phone), .phone(phone))
        let newerPhone = PhoneLibrary(
            accountID: "4242", username: nil, syncedAt: .now, books: [])
        XCTAssertEqual(source(listing, "4242", newerPhone), .phone(newerPhone))
        // A newer worklist decides, so the books the Apple TV's newer copy adds get designs.
        let newerListing = SpineWorklistV1(
            version: 1, accountID: "4242", syncedAt: .now, bookIDs: [1])
        XCTAssertEqual(source(newerListing, "4242", phone), .worklist)
        XCTAssertEqual(source(otherAccount, "4242", phone), .worklist)
        XCTAssertEqual(source(listing, "4242", nil), .worklist)
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
        let store = KeychainSecret(service: "gay.ian.Bookworms.iOS.tests.\(UUID().uuidString)")
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

    func testPreviewStubAndTestLaunchesKeepALoginOfTheirOwn() throws {
        let suite = "gay.ian.Bookworms.iOS.tests.ScratchLaunch"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let arguments = try XCTUnwrap(UserDefaults(suiteName: suite))
        func isScratch(_ environment: [String: String] = [:]) -> Bool {
            HardcoverAccount.isScratchLaunch(defaults: arguments, environment: environment)
        }
        XCTAssertFalse(isScratch())
        XCTAssertTrue(isScratch(["XCTestConfigurationFilePath": "/tmp/fictional.xctest"]))
        arguments.set("preview", forKey: "BookwormsPreviewFolder")
        XCTAssertTrue(isScratch())
        arguments.removeObject(forKey: "BookwormsPreviewFolder")
        #if DEBUG
            arguments.set(true, forKey: "BookwormsStubSignIn")
            XCTAssertTrue(isScratch())
        #endif

        // A test run is one, so the default login, summary, and library are its own.
        XCTAssertTrue(HardcoverAccount.usesScratchLogin)
        XCTAssertNotEqual(HardcoverAccount.loginStore.service, KeychainSecret().service)
        XCTAssertNotEqual(
            PhoneLibrary.url.deletingLastPathComponent(),
            URL.cachesDirectory.appending(path: "Bookworms"))
        let probe = "gay.ian.Bookworms.iOS.tests.scratchProbe"
        HardcoverAccount.summaryDefaults.set(true, forKey: probe)
        addTeardownBlock { HardcoverAccount.summaryDefaults.removeObject(forKey: probe) }
        XCTAssertNil(UserDefaults.standard.object(forKey: probe))
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
    /// A test login, settings suite, and library path, all removed when the test ends.
    private func signedInStores() throws -> (KeychainSecret, UserDefaults, URL) {
        let tokens = KeychainSecret(
            service: "gay.ian.Bookworms.iOS.tests.\(UUID().uuidString)")
        try tokens.save("fictional-token")
        addTeardownBlock { tokens.delete() }
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
        addTeardownBlock {
            try? FileManager.default.removeItem(at: library)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return (tokens, defaults, library)
    }

    /// Caches `library` at `url` with its account summary, as a sync would.
    private static func cache(_ library: PhoneLibrary, at url: URL, defaults: UserDefaults) throws {
        try library.save(to: url)
        defaults.set(
            try JSONEncoder()
                .encode(
                    HardcoverAccount.Summary(
                        accountID: library.accountID, username: library.username,
                        syncedAt: library.syncedAt)),
            forKey: HardcoverAccount.summaryKey)
    }

    /// A new folder whose `library-v1.json` holds `snapshots`, for a `LocalSpineStore`.
    /// A temporary folder holding an archive of `snapshots`, removed when the test ends.
    private func archiveFolder(with snapshots: [CloudSourceSnapshot]) throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "library-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var archive: Data?
        for snapshot in snapshots {
            archive = try CloudLibraryArchive.splice(snapshot, into: archive)
        }
        try XCTUnwrap(archive).write(to: folder.appending(path: "library-v1.json"))
        return folder
    }

    /// A whole second `hours` ago, which survives every JSON round trip unchanged.
    private static func hoursAgo(_ hours: Double) -> Date {
        let seconds = (Date.timeIntervalSinceReferenceDate - hours * 3600).rounded()
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Answers the account, library, and series queries with the fictional fixtures.
    private static let libraryTransport: HardcoverClient.Transport = { request in
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        if body.contains("query Account") { return respond(200, me, to: request) }
        if body.contains("query PhoneSeries") { return respond(200, seriesPage, to: request) }
        return respond(200, libraryPage, to: request)
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

    /// A token reply with a new access token, a rotated refresh token, and a week's lifetime.
    private static let renewedLogin =
        #"{"access_token":"fictional-new","refresh_token":"fictional-refresh-2","expires_in":604800,"token_type":"Bearer"}"#

    /// One fictional page: a book read twice with an HTML review, a current read, a book on Want
    /// to Read, and two rows that normalization drops: a finished book on Ignored and an older
    /// row for the first book.
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
             "book_series":[{"featured":false,"position":2,"compilation":false,
                 "series":{"id":7,"name":"Lantern Tales","books_count":4,"primary_books_count":3}},
               {"featured":true,"position":1,"compilation":null,
                 "series":{"id":9,"name":" The Lantern Cycle ","books_count":12,"primary_books_count":null}},
               {"featured":false,"position":1,"compilation":true,"series":{"id":11,"name":" "}},
               {"featured":false,"position":null,"compilation":false,"series":null}],
             "editions":[{"image":{"url":"https://covers.example.com/edition-101.jpg","width":900,"height":1350}}]},
           "edition":null,
           "user_book_reads":[{"finished_at":"2025-03-01","edition":{"pages":336,"audio_seconds":null,
             "image":{"url":"https://covers.example.com/reader-101.jpg","width":800,"height":1200},
             "reading_format":{"format":"Ebook"},"language":null}},
             {"finished_at":"2022-06-10","edition":null}],
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
          {"status_id":6,"last_read_date":"2024-08-01","rating":2,"review":null,
           "book":{"id":404,"title":"Set Aside","pages":150,"release_year":2020,
             "cached_contributors":[],"cached_tags":null,"rating":null,"ratings_count":0,
             "image":null,"book_series":[],"editions":[]},
           "edition":null,"user_book_reads":[{"finished_at":"2024-08-01","edition":null}],
           "current_read":[]},
          {"status_id":3,"last_read_date":"2023-01-05","rating":3,"review":"Older read.",
           "book":{"id":101,"title":"The Lantern Keeper: A Novel","pages":320,"release_year":2021,
             "cached_contributors":[],"cached_tags":null,"rating":4.12,"ratings_count":250,
             "image":null,"book_series":[],"editions":[]},
           "edition":null,"user_book_reads":[],"current_read":[]}
        ]}}
        """

    /// The fixture's featured series: a duplicate and a half position that normalization drops,
    /// and a book with an HTTP cover, which is left out.
    private static let seriesPage = """
        {"data":{"series":[{"id":9,"name":"The Lantern Cycle","book_series":[
          {"position":1,"book":{"id":101,"title":"The Lantern Keeper","release_year":2021,
            "image":{"url":"https://covers.example.com/book-101.jpg","width":400,"height":600}}},
          {"position":1,"book":{"id":150,"title":"The Lantern Keeper (Illustrated)",
            "release_year":2023,"image":null}},
          {"position":1.5,"book":{"id":151,"title":"A Lantern Story","release_year":2022,
            "image":null}},
          {"position":2,"book":{"id":102,"title":null,"release_year":null,
            "image":{"url":"http://covers.example.com/book-102.jpg","width":400,"height":600}}}
        ]}]}}
        """
}

/// A login store whose reads can fail, as the Keychain's do before the first unlock after a
/// restart.
private final class FakeSecretStore: SecretStore {
    var secret: String?
    var isReadable: Bool
    var failsSaves = false
    private(set) var loads = 0
    private(set) var saves: [String] = []
    private(set) var deletes = 0

    init(_ secret: String?, isReadable: Bool = true) {
        self.secret = secret
        self.isReadable = isReadable
    }

    func load() throws -> String? {
        loads += 1
        guard isReadable else {
            throw KeychainSecret.Unreadable(status: errSecInteractionNotAllowed)
        }
        return secret
    }

    func save(_ secret: String) throws {
        if failsSaves { throw KeychainSecret.NotSaved() }
        saves.append(secret)
        self.secret = secret
    }

    func delete() {
        deletes += 1
        secret = nil
    }
}

/// The error that `body` throws, or `nil` when it returns.
@MainActor
private func thrownError(_ body: () async throws -> some Any) async -> (any Error)? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

/// Counts a transport's requests.
private actor RequestCount {
    private(set) var count = 0

    func add() { count += 1 }
}

/// An HTTP status that a test changes between requests.
private actor ReplyStatus {
    private(set) var value: Int

    init(_ value: Int) { self.value = value }

    func set(_ value: Int) { self.value = value }
}

/// Holds a transport's replies until the test opens it.
private actor ReplyGate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiting { waiter.resume() }
        waiting = []
    }
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
