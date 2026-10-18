import Foundation

enum HardcoverError: LocalizedError, Equatable {
    /// HTTP 401, an `invalid-jwt` GraphQL error, or no account for the token.
    case invalidToken
    /// HTTP 403 with `insufficient_scope`: the login lacks a read permission.
    case insufficientScope
    /// Any other HTTP 403. The login may still be valid.
    case forbidden
    case http(Int)
    case rejected
    case incomplete
    case invalidAuthorizationCode
    case deviceFlowDenied
    case deviceFlowExpired
    case credentialNotSaved
    /// The Keychain refused to read the saved login, which stays saved.
    case credentialUnreadable

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "Your Hardcover login expired or was revoked. Reconnect to keep your library up to date."
        case .insufficientScope:
            "Hardcover did not grant the read permissions Bookworms needs. Reconnect and allow them."
        case .forbidden: "Hardcover denied access to your library."
        case .http(429): "Hardcover is limiting requests. Try again in a few minutes."
        case .http(500...599): "Hardcover is temporarily unavailable. Try again later."
        case .http(let status): "Hardcover could not complete the request (HTTP \(status))."
        case .rejected: "Hardcover sent data that Bookworms could not read."
        case .incomplete: "Your Hardcover library could not be loaded completely."
        case .invalidAuthorizationCode:
            "Hardcover did not accept the sign-in code. Get a new code to try again."
        case .deviceFlowDenied: "The sign-in was declined on Hardcover."
        case .deviceFlowExpired: "The code expired before it was approved. Get a new code."
        case .credentialNotSaved:
            "Bookworms could not save your Hardcover login on this \(ThisDevice.name)."
        case .credentialUnreadable:
            "Bookworms could not read your Hardcover login from the keychain. \(Self.keychainAdvice)"
        }
    }

    /// What lets the Keychain read the login again: on a Mac, allowing its prompt; elsewhere,
    /// the first unlock after a restart.
    private static var keychainAdvice: String {
        #if os(macOS)
            "Allow access when the Mac asks, then try again."
        #else
            "Unlock this \(ThisDevice.name), then try again."
        #endif
    }
}

/// Hardcover's answer to a device-code request (RFC 8628).
struct DeviceAuthorization: Decodable, Equatable, Sendable {
    let deviceCode: String
    /// The short code the reader enters on Hardcover, such as `ABCD-1234`.
    let userCode: String
    let verificationURIComplete: URL?
    let expiresIn: Int
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }

    /// The page that approves the code: the link with the code filled in when Hardcover provides
    /// one on its own site, otherwise `hardcover.app/link`.
    var pageURL: URL {
        guard let url = verificationURIComplete, url.scheme == "https",
            url.host() == "hardcover.app"
        else { return HardcoverClient.linkURL }
        return url
    }
}

enum DevicePollResult: Equatable, Sendable {
    case pending
    case slowDown
    case expired
    case accessDenied
    case success(HardcoverCredential)
}

/// A Hardcover OAuth login: the access token that requests carry and, when Hardcover issued
/// one, the refresh token that renews it.
///
/// Hardcover's access tokens last a week. Its refresh tokens last six months and rotate: each
/// renewal returns a new pair, and spending a refresh token a second time makes Hardcover
/// revoke the whole login. A login saved before Bookworms kept refresh tokens has neither
/// `refreshToken` nor `expiresAt` and works until Hardcover rejects it.
struct HardcoverCredential: Codable, Equatable, Sendable {
    let accessToken: String
    var refreshToken: String? = nil
    /// When the access token expires, from the token reply's `expires_in`.
    var expiresAt: Date? = nil
}

extension HardcoverCredential {
    /// Reads a login as the Keychain holds it: JSON, or a bare access token, as earlier builds
    /// saved it.
    init(stored: String) {
        self =
            (try? JSONDecoder().decode(Self.self, from: Data(stored.utf8)))
            ?? Self(accessToken: stored)
    }

    /// The login as the Keychain holds it.
    func stored() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

/// The signed-in Hardcover account.
struct HardcoverUser: Decodable, Equatable, Sendable {
    let id: Int
    let username: String?
}

/// A cover from one of a book's Hardcover editions, which the reader can choose instead of the
/// default cover.
struct EditionCover: Hashable, Sendable, Identifiable {
    let editionID: Int
    let url: URL
    /// The edition's format as Hardcover records it, such as "Paperback", or its reading format,
    /// such as "Listened", when it has none.
    let format: String?
    let year: Int?

    var id: URL { url }
}

/// Signs this iPhone in to Hardcover with the OAuth 2.0 Device Authorization Grant and reads the
/// account's library.
///
/// The client ID, endpoints, and read-only scopes match the Apple TV app. The client owns its
/// query documents, so no caller can send a mutation: the iPhone never writes to Hardcover.
actor HardcoverClient {
    /// Sends one request. Tests and the DEBUG sign-in stub answer without the network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let clientID = "ca996be3-0df1-4cbf-819a-e17644fbcf38"
    static let scopes = "read:me:content read:library read:catalog:data read:social read:users"
    static let linkURL = URL(string: "https://hardcover.app/link")!
    private static let userAgent = "Bookworms/1.0 (read-only iOS client)"
    private static let session = URLSession(configuration: .ephemeral)

    private let transport: Transport

    init(transport: Transport? = nil) {
        self.transport = transport ?? { try await HardcoverClient.session.data(for: $0) }
    }

    func requestDeviceAuthorization() async throws -> DeviceAuthorization {
        let (data, status) = try await postForm(
            "https://hardcover.app/oauth2/device",
            [("client_id", Self.clientID), ("scope", Self.scopes)])
        guard status == 200 else { throw HardcoverError.http(status) }
        guard let authorization = try? JSONDecoder().decode(DeviceAuthorization.self, from: data)
        else { throw HardcoverError.rejected }
        return authorization
    }

    func pollToken(deviceCode: String) async throws -> DevicePollResult {
        let (data, status) = try await postForm(
            Self.tokenEndpoint,
            [
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("device_code", deviceCode), ("client_id", Self.clientID),
            ])
        let reply = try? JSONDecoder().decode(TokenReply.self, from: data)
        if status == 200 {
            guard let credential = reply?.credential(receivedAt: .now) else {
                throw HardcoverError.rejected
            }
            return .success(credential)
        }
        switch reply?.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token": return .expired
        case "access_denied": return .accessDenied
        default:
            throw [400, 401].contains(status)
                ? HardcoverError.invalidAuthorizationCode : HardcoverError.http(status)
        }
    }

    /// Polls until Hardcover approves, denies, or expires `authorization`, and returns the
    /// login.
    ///
    /// Waits the code's interval (5 seconds when Hardcover gives none) before each poll, and 5
    /// seconds longer after each `slow_down`, as RFC 8628 requires, or after each HTTP 429.
    /// Network failures, server errors, and rate limits keep polling because the code stays
    /// valid; the code's lifetime bounds the wait.
    static func awaitApproval(
        of authorization: DeviceAuthorization,
        poll: @Sendable () async throws -> DevicePollResult,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> HardcoverCredential {
        var interval = max(authorization.interval ?? 5, 1)
        var waited = 0
        while waited < authorization.expiresIn {
            try await sleep(.seconds(interval))
            waited += interval
            let result: DevicePollResult
            do {
                result = try await poll()
            } catch is URLError {
                continue
            } catch HardcoverError.http(let status)
                where status == 429 || (500...599).contains(status)
            {
                if status == 429 { interval += 5 }
                continue
            }
            switch result {
            case .pending: continue
            case .slowDown: interval += 5
            case .expired: throw HardcoverError.deviceFlowExpired
            case .accessDenied: throw HardcoverError.deviceFlowDenied
            case .success(let credential): return credential
            }
        }
        throw HardcoverError.deviceFlowExpired
    }

    /// Spends `refreshToken` once for a new login (RFC 6749, section 6).
    ///
    /// The request is never retried, because Hardcover revokes the whole login when a refresh
    /// token it already spent comes back, as a retry of a request that reached it would. The
    /// new login keeps `refreshToken` only if Hardcover sends no new one. Throws
    /// `HardcoverError.invalidToken` for any HTTP 4xx reply other than 408 or 429: Hardcover
    /// answers 400 or 401 once the token expired, was revoked, or was spent, and a token
    /// endpoint that refuses the request in another way can't renew the login either.
    func renew(refreshToken: String) async throws -> HardcoverCredential {
        let (data, status) = try await postForm(
            Self.tokenEndpoint,
            [
                ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
                ("client_id", Self.clientID),
            ])
        switch status {
        case 200:
            guard
                var credential = (try? JSONDecoder().decode(TokenReply.self, from: data))?
                    .credential(receivedAt: .now)
            else { throw HardcoverError.rejected }
            if credential.refreshToken == nil { credential.refreshToken = refreshToken }
            return credential
        case 408, 429: throw HardcoverError.http(status)
        case 400..<500: throw HardcoverError.invalidToken
        default: throw HardcoverError.http(status)
        }
    }

    /// Returns the token's account. Signing in checks it before saving the token.
    func account(token: String) async throws -> HardcoverUser {
        struct Reply: Decodable { let me: [HardcoverUser] }
        let reply: Reply = try await query(
            "query Account { me { id username } }", variables: [String: Int](), token: token)
        guard reply.me.count == 1, let user = reply.me.first else {
            throw HardcoverError.invalidToken
        }
        return user
    }

    /// Downloads every book on the account's shelves, 100 per request, and then the series of
    /// the books, 50 per request, each request paced about a second apart to stay inside
    /// Hardcover's rate limit.
    ///
    /// `previous` is the newest copy of the library the caller knows. Its books keep their covers
    /// (`coverURLs(edition:book:otherEditions:editionIsInLanguage:previous:)`) only when it
    /// belongs to the token's account; a copy of another account is ignored. A failed series
    /// request leaves `series` `nil` and still returns the library.
    func library(token: String, previous: PhoneLibrary? = nil) async throws -> PhoneLibrary {
        let user = try await account(token: token)
        let accountID = String(user.id)
        let previousBooks = Dictionary(
            (previous?.accountID == accountID ? previous?.books ?? [] : []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        struct Variables: Encodable {
            let user: Int
            let offset: Int
            let language: String
        }
        var rows: [LibraryPage.Row] = []
        for offset in stride(from: 0, to: 10_000, by: 100) {
            if offset > 0 { try await Task.sleep(for: Self.pagePause) }
            let page: LibraryPage = try await query(
                Self.libraryQuery,
                variables: Variables(user: user.id, offset: offset, language: Self.coverLanguage),
                token: token)
            rows += page.userBooks
            if page.userBooks.count < 100 {
                let books = Self.normalize(rows, previous: previousBooks)
                return PhoneLibrary(
                    accountID: accountID, username: user.username, syncedAt: .now, books: books,
                    series: try? await series(Set(books.compactMap(\.seriesID)), token: token))
            }
        }
        throw HardcoverError.incomplete
    }

    /// Returns the names and main books of the series `ids`, 50 series per request, each request
    /// paced like library pages. The Apple TV shows them in book details.
    private func series(_ ids: Set<Int>, token: String) async throws -> [SeriesInfo] {
        struct Variables: Encodable { let ids: [Int] }
        let sorted = ids.sorted()
        var result: [SeriesInfo] = []
        for start in stride(from: 0, to: sorted.count, by: 50) {
            try await Task.sleep(for: Self.pagePause)
            let page: SeriesPage = try await query(
                Self.seriesQuery,
                variables: Variables(ids: Array(sorted[start..<min(start + 50, sorted.count)])),
                token: token)
            result += page.series.map(Self.seriesInfo)
        }
        return result
    }

    /// Keeps one book per whole-number position: the most-read, which the query lists first. Ported
    /// from the Apple TV app, so both apps write the same series.
    private static func seriesInfo(_ series: SeriesPage.Series) -> SeriesInfo {
        var seen = Set<Double>()
        let books = series.bookSeries.compactMap { entry -> SeriesInfo.SeriesBook? in
            guard let position = entry.position, position >= 0, position == position.rounded(),
                let book = entry.book, seen.insert(position).inserted
            else { return nil }
            return SeriesInfo.SeriesBook(
                id: book.id, title: book.title ?? "Untitled", position: position,
                releaseYear: book.releaseYear,
                coverURL: book.image?.url.flatMap { $0.scheme == "https" ? $0 : nil })
        }
        return SeriesInfo(id: series.id, name: series.name, books: books)
    }

    /// Returns the covers of the book's editions, most-read edition first, one per image URL.
    /// Images that fail `CoverURLPolicy` or cannot be covers, such as square audiobook art, are
    /// left out.
    func editionCovers(bookID: Int, token: String) async throws -> [EditionCover] {
        struct Variables: Encodable { let book: Int }
        let page: EditionsPage = try await query(
            Self.editionsQuery, variables: Variables(book: bookID), token: token)
        var seen = Set<URL>()
        return page.editions.compactMap { edition in
            guard let image = edition.image, let url = image.url, CoverURLPolicy.allows(url),
                Self.isCover(image), seen.insert(url).inserted
            else { return nil }
            let format = edition.editionFormat?.trimmingCharacters(in: .whitespacesAndNewlines)
            return EditionCover(
                editionID: edition.id, url: url,
                format: format?.isEmpty == false ? format : edition.readingFormat?.format,
                year: edition.releaseYear)
        }
    }

    // MARK: - Social

    /// The signed-in reader's profile, for comparisons and the share images' invitation.
    func owner(token: String) async throws -> ReaderProfile {
        struct Reply: Decodable { let me: [SocialProfile] }
        let reply: Reply = try await query(
            Self.ownerQuery, variables: SocialVariables(), token: token)
        guard reply.me.count == 1, let owner = reply.me.first?.profile else {
            throw HardcoverError.invalidToken
        }
        return owner
    }

    /// Returns the IDs of the readers `owner` blocked on Hardcover. Every list of other readers
    /// leaves them out, so a failure here fails the request that needs it.
    func blockedReaders(owner: Int, token: String) async throws -> Set<Int> {
        struct Row: Decodable {
            let blockedUserID: Int?
            enum CodingKeys: String, CodingKey { case blockedUserID = "blocked_user_id" }
        }
        struct Reply: Decodable {
            let userBlocks: [Row]
            enum CodingKeys: String, CodingKey { case userBlocks = "user_blocks" }
        }
        var ids = Set<Int>()
        for offset in stride(from: 0, to: Self.socialRowLimit, by: 100) {
            if offset > 0 { try await Task.sleep(for: Self.pagePause) }
            let reply: Reply = try await query(
                Self.blockedQuery, variables: SocialVariables(user: owner, offset: offset),
                token: token)
            ids.formUnion(reply.userBlocks.compactMap(\.blockedUserID))
            if reply.userBlocks.count < 100 { return ids }
        }
        throw HardcoverError.incomplete
    }

    /// Returns the readers `owner` follows, in the order they were followed, without the
    /// `blocked` readers or profiles that have no username.
    func following(owner: Int, blocked: Set<Int>, token: String) async throws -> [ReaderProfile] {
        struct Row: Decodable {
            let followedUser: SocialProfile?
            enum CodingKeys: String, CodingKey { case followedUser = "followed_user" }
        }
        struct Reply: Decodable {
            let followedUsers: [Row]
            enum CodingKeys: String, CodingKey { case followedUsers = "followed_users" }
        }
        var readers: [ReaderProfile] = []
        var seen = Set<Int>()
        for offset in stride(from: 0, to: Self.socialRowLimit, by: 100) {
            if offset > 0 { try await Task.sleep(for: Self.pagePause) }
            let reply: Reply = try await query(
                Self.followingQuery, variables: SocialVariables(user: owner, offset: offset),
                token: token)
            for row in reply.followedUsers {
                guard let reader = row.followedUser?.profile, reader.id != owner,
                    !blocked.contains(reader.id), seen.insert(reader.id).inserted
                else { continue }
                readers.append(reader)
            }
            if reply.followedUsers.count < 100 { return readers }
        }
        throw HardcoverError.incomplete
    }

    /// Returns the IDs among `users` with activity in their 100 newest Hardcover events, most
    /// recently active first. Readers without recent activity are left out.
    func recentlyActive(among users: [Int], token: String) async throws -> [Int] {
        guard !users.isEmpty else { return [] }
        struct Row: Decodable {
            let user: User?
            struct User: Decodable { let id: Int }
        }
        struct Reply: Decodable { let activities: [Row] }
        let reply: Reply = try await query(
            Self.activityQuery, variables: SocialVariables(users: users), token: token)
        var seen = Set<Int>()
        return reply.activities.compactMap(\.user?.id).filter { seen.insert($0).inserted }
    }

    /// Downloads a reader's rated books and the books on their Currently Reading, Read, Paused,
    /// and Did Not Finish shelves, highest rated first, 100 per request about a second apart.
    ///
    /// Each book carries the reader's own rating and finish date, but no review. A library
    /// larger than `readerLibraryLimit` keeps its highest-rated books. Hardcover leaves out what
    /// a private profile hides, so such a reader can return no books.
    func readerLibrary(user: Int, token: String) async throws -> [CloudBook] {
        var rows: [LibraryPage.Row] = []
        for offset in stride(from: 0, to: Self.readerLibraryLimit, by: 100) {
            if offset > 0 { try await Task.sleep(for: Self.pagePause) }
            let page: LibraryPage = try await query(
                Self.readerLibraryQuery,
                variables: SocialVariables(
                    user: user, offset: offset, language: Self.coverLanguage),
                token: token)
            rows += page.userBooks
            if page.userBooks.count < 100 { break }
        }
        return Self.normalize(rows)
    }

    /// Returns the readers whose username is one of `usernames`, exactly as Hardcover stores
    /// it.
    func readers(named usernames: [String], token: String) async throws -> [ReaderProfile] {
        struct Reply: Decodable { let users: [SocialProfile] }
        let reply: Reply = try await query(
            Self.usersQuery, variables: SocialVariables(usernames: usernames), token: token)
        return reply.users.compactMap(\.profile)
    }

    /// The most rows a list of followed or blocked readers reads.
    private static let socialRowLimit = 10_000
    /// The most books a reader's library keeps.
    static let readerLibraryLimit = 3_000
    /// The pause between two pages of one list, which keeps paging inside Hardcover's rate
    /// limit.
    static let pagePause = Duration.seconds(1.1)

    /// Turns a review or a book description into plain text: HTML tags and Markdown markers are
    /// removed, entities are decoded, and paragraphs stay separated by one blank line. Returns
    /// `nil` for empty text.
    static func plainText(from markup: String?) -> String? {
        guard var text = markup else { return nil }
        text = text.replacing(/(?i)<br\s*\/?>|<\/li>/, with: "\n")
            .replacing(/(?i)<\/(p|div|blockquote|h[1-6])>/, with: "\n\n")
            // Only tag-shaped text goes, so "I <3 it" keeps its heart.
            .replacing(/<\/?[a-zA-Z][^>]*>/, with: "")
            .replacing(/(?m)^ {0,3}(?:#{1,6} +|> ?)/, with: "")
        // Inline Markdown parsing drops emphasis and link markup and decodes HTML entities.
        if let parsed = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            text = String(parsed.characters)
        }
        text = text.replacing(/[ \t]*\n[ \t]*\n\s*/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Requests

    private static let tokenEndpoint = "https://hardcover.app/oauth2/token"

    /// A reply from the token endpoint (RFC 6749, section 5): a login, or an error code.
    private struct TokenReply: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Double?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case error
        }

        /// The login the reply carries, with its expiry counted from `date`, or `nil` without a
        /// usable access token.
        func credential(receivedAt date: Date) -> HardcoverCredential? {
            guard let token = accessToken.flatMap(HardcoverClient.validToken) else { return nil }
            return HardcoverCredential(
                accessToken: token, refreshToken: refreshToken.flatMap(HardcoverClient.validToken),
                expiresAt: expiresIn.map { date.addingTimeInterval($0) })
        }
    }

    private func postForm(_ endpoint: String, _ fields: [(String, String)]) async throws -> (
        Data, Int
    ) {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var body = URLComponents()
        body.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw HardcoverError.rejected }
        return (data, http.statusCode)
    }

    private func query<Result: Decodable>(
        _ document: String, variables: some Encodable, token: String
    ) async throws -> Result {
        guard let token = Self.validToken(token) else { throw HardcoverError.invalidToken }
        var request = URLRequest(url: URL(string: "https://api.hardcover.app/v1/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder()
            .encode(
                GraphQLRequest(query: document, variables: variables))
        let (data, http) = try await send(request)
        switch http.statusCode {
        case 200: break
        case 401: throw HardcoverError.invalidToken
        case 403:
            // Only `insufficient_scope` means the login needs new permissions; other 403s are
            // denied requests, not an expired login.
            let failure = try? JSONDecoder().decode(HTTPFailure.self, from: data)
            throw failure?.error == "insufficient_scope"
                ? HardcoverError.insufficientScope : HardcoverError.forbidden
        default: throw HardcoverError.http(http.statusCode)
        }
        guard let envelope = try? JSONDecoder().decode(GraphQLReply<Result>.self, from: data)
        else { throw HardcoverError.rejected }
        if let errors = envelope.errors, !errors.isEmpty {
            // Hasura, which serves Hardcover's API, reports a rejected token as a GraphQL error
            // with HTTP 200.
            let codes = errors.compactMap(\.extensions?.code)
            throw codes.contains("invalid-jwt") || codes.contains("invalid-headers")
                ? HardcoverError.invalidToken : HardcoverError.rejected
        }
        guard let result = envelope.data else { throw HardcoverError.rejected }
        return result
    }

    /// Sends a GraphQL request and returns Hardcover's reply, retrying up to twice when a failure
    /// may pass.
    ///
    /// Server errors, timeouts, and dropped connections retry after about 2 and then 4 seconds,
    /// plus up to a second of jitter. A rate limit retries once its `Retry-After` passes if that
    /// is at most 30 seconds away; a longer or missing `Retry-After` returns the reply at once.
    /// Cancellation ends a wait with `CancellationError` and is never retried.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var retries = 0
        while true {
            let backoff = Double(2 << retries) + .random(in: 0...1)
            let wait: Double
            do {
                let (data, response) = try await transport(request)
                guard let http = response as? HTTPURLResponse else { throw HardcoverError.rejected }
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                switch http.statusCode {
                case 500...599 where retries < 2:
                    wait = backoff
                case 429 where retries < 2:
                    guard let retryAfter, retryAfter <= 30 else { return (data, http) }
                    wait = max(retryAfter, 0)
                default:
                    return (data, http)
                }
            } catch let error as URLError
                where retries < 2
                && [.timedOut, .networkConnectionLost, .cannotConnectToHost, .badServerResponse]
                    .contains(error.code)
            {
                wait = backoff
            }
            retries += 1
            try await Task.sleep(for: .seconds(wait))
        }
    }

    /// Returns the token without surrounding whitespace or a `Bearer` prefix, or `nil` when it
    /// cannot be a bearer token.
    private static func validToken(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard !value.isEmpty,
            value.unicodeScalars.allSatisfy({
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            })
        else { return nil }
        return value
    }

    #if DEBUG
        /// Answers sign-in requests with a fictional code that is never approved, without
        /// contacting Hardcover, for Simulator screenshots (`-BookwormsStubSignIn YES`).
        static let debugStub: Transport = { request in
            let isCodeRequest = request.url?.path() == "/oauth2/device"
            let body =
                isCodeRequest
                ? #"{"device_code":"debug","user_code":"WORM-2611","verification_uri":"https://hardcover.app/link","expires_in":900,"interval":5}"#
                : #"{"error":"authorization_pending"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: isCodeRequest ? 200 : 400, httpVersion: nil,
                headerFields: nil)!
            return (Data(body.utf8), response)
        }
    #endif

    // MARK: - Library normalization

    // Ported from the Apple TV app's library query, plus the reader's review. `review` is the
    // field the Apple TV's social client reads with the same client and scopes; Hardcover's
    // documentation also lists `review_raw`, which no Bookworms client has used yet.
    private static let libraryQuery = """
        query PhoneLibrary($user: Int!, $offset: Int!, $language: String!) {
          user_books(where: {user_id: {_eq: $user}}, order_by: {id: asc}, limit: 100, offset: $offset) {
            last_read_date rating status_id review
            book { id title description pages release_year cached_contributors cached_tags rating
              ratings_count ratings_distribution image { url width height }
              book_series { featured position compilation series { id name books_count primary_books_count } }
              editions(where: {image_id: {_is_null: false},
                  _or: [{language_id: {_is_null: true}}, {language: {code2: {_eq: $language}}}]},
                order_by: {users_count: desc}, limit: 5) {
                image { url width height }
              }
            }
            edition { pages audio_seconds image { url width height } reading_format { format } language { code2 } }
            user_book_reads(where: {finished_at: {_is_null: false}},
              order_by: [{finished_at: desc}, {id: desc}]) {
              finished_at edition { pages audio_seconds image { url width height } reading_format { format } language { code2 } }
            }
            current_read: user_book_reads(where: {finished_at: {_is_null: true}},
              order_by: [{id: desc}], limit: 1) {
              started_at progress progress_pages progress_seconds edition { pages audio_seconds }
            }
          }
        }
        """

    // Ported from the Apple TV app's series query.
    private static let seriesQuery = """
        query PhoneSeries($ids: [Int!]!) {
          series(where: {id: {_in: $ids}}) {
            id name
            book_series(where: {position: {_is_null: false}},
              order_by: [{position: asc}, {book: {users_count: desc}}]) {
              position book { id title release_year image { url width height } }
            }
          }
        }
        """

    private static let ownerQuery = "query SocialOwner { me { id username name image { url } } }"

    private static let blockedQuery = """
        query SocialBlocked($user: Int!, $offset: Int!) {
          user_blocks(where: {user_id: {_eq: $user}}, order_by: {id: asc}, limit: 100, offset: $offset) {
            blocked_user_id
          }
        }
        """

    private static let followingQuery = """
        query SocialFollowing($user: Int!, $offset: Int!) {
          followed_users(where: {user_id: {_eq: $user}}, order_by: {id: asc}, limit: 100, offset: $offset) {
            followed_user { id username name image { url } }
          }
        }
        """

    private static let activityQuery = """
        query SocialActivity($users: [Int!]!) {
          activities(where: {user_id: {_in: $users}}, order_by: [{created_at: desc}, {id: desc}], limit: 100) {
            user { id }
          }
        }
        """

    // The library query's book fields without the reader's review, current read, and the
    // catalog details that only the owner's books show.
    private static let readerLibraryQuery = """
        query ReaderLibrary($user: Int!, $offset: Int!, $language: String!) {
          user_books(where: {user_id: {_eq: $user},
              _or: [{rating: {_is_null: false}}, {status_id: {_in: [2, 3, 4, 5]}}]},
            order_by: [{rating: desc_nulls_last}, {id: asc}], limit: 100, offset: $offset) {
            last_read_date rating status_id
            book { id title pages release_year cached_contributors rating ratings_count
              image { url width height }
              book_series { featured position compilation series { id name books_count primary_books_count } }
              editions(where: {image_id: {_is_null: false},
                  _or: [{language_id: {_is_null: true}}, {language: {code2: {_eq: $language}}}]},
                order_by: {users_count: desc}, limit: 5) {
                image { url width height }
              }
            }
            edition { pages audio_seconds image { url width height } reading_format { format } language { code2 } }
          }
        }
        """

    private static let usersQuery = """
        query ReaderLookup($usernames: [String!]!) {
          users(where: {username: {_in: $usernames}}, limit: 5) { id username name image { url } }
        }
        """

    private static let editionsQuery = """
        query EditionCovers($book: Int!) {
          editions(where: {book_id: {_eq: $book}, image_id: {_is_null: false}},
            order_by: [{users_count: desc}, {id: asc}], limit: 60) {
            id edition_format release_year reading_format { format } image { url width height }
          }
        }
        """

    /// Hardcover's `status_id` for **Currently Reading**.
    private static let currentlyReadingStatus = 2
    /// Hardcover's `status_id` for **Read**.
    private static let readStatus = 3

    /// The two-letter code of this iPhone's preferred language. Cover choice considers other
    /// editions only in this language or with no recorded language.
    private static var coverLanguage: String {
        Locale.preferredLanguages.first
            .flatMap { Locale.Language(identifier: $0).languageCode?.identifier(.alpha2) } ?? "en"
    }

    /// Converts rows to books the way the Apple TV app does, keeping one row per book: the most
    /// recently finished. A book keeps every finished read's date in `finishedDates`, and its
    /// newest read's edition. `previous` holds the account's books from its last sync, by ID, whose
    /// covers stay fixed unless an upgrade applies
    /// (`coverURLs(edition:book:otherEditions:editionIsInLanguage:previous:)`).
    private static func normalize(_ rows: [LibraryPage.Row], previous: [Int: CloudBook] = [:])
        -> [CloudBook]
    {
        var unique: [Int: CloudBook] = [:]
        for row in rows {
            let source = row.book
            let read = row.finishedReads?.first
            let finishes = (row.finishedReads ?? []).compactMap(\.finishedAt)
            let edition = read?.edition ?? row.edition
            let author = (source.cachedContributors ?? [])
                .filter { $0.contribution == nil || $0.contribution == "Author" }
                .compactMap { $0.author?.name }.joined(separator: ", ")
            let covers = coverURLs(
                edition: edition?.image, book: source.image,
                otherEditions: (source.editions ?? []).compactMap(\.image),
                editionIsInLanguage: edition?.language?.code2
                    .map {
                        $0.lowercased() == coverLanguage.lowercased()
                    } ?? true,
                previous: previous[source.id].map { ($0.detailCoverURL, $0.coverURL) })
            let membership = source.bookSeries?
                .sorted { ($0.featured ?? false) && !($1.featured ?? false) }.first
            let seriesName = membership?.series?.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let memberships = source.bookSeries?
                .compactMap { row -> SeriesMembership? in
                    guard let series = row.series,
                        let name = series.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !name.isEmpty
                    else { return nil }
                    return SeriesMembership(
                        seriesID: series.id, name: name, position: row.position,
                        featured: row.featured ?? false, compilation: row.compilation ?? false,
                        size: series.primaryBooksCount ?? series.booksCount)
                }
            let isReading = row.statusID == currentlyReadingStatus
            let current = row.currentReads?.first
            let book = CloudBook(
                id: source.id, title: source.title ?? "Untitled",
                author: author.isEmpty ? "Unknown author" : author,
                coverURL: covers.alternate, detailCoverURL: covers.preferred,
                genres: source.cachedTags?["Genre"]?
                    .filter {
                        ($0.spoilerRatio ?? 0) < 0.2 && !["Fiction", "Nonfiction"].contains($0.tag)
                    }
                    .sorted { ($0.count ?? 0) > ($1.count ?? 0) }.map(\.tag),
                publicationYear: source.releaseYear, format: edition?.readingFormat?.format,
                seriesID: membership?.series?.id, seriesPosition: membership?.position,
                seriesName: seriesName?.isEmpty == false ? seriesName : nil,
                seriesMemberships: memberships,
                pages: edition?.pages ?? source.pages,
                finished: finishes.first ?? row.lastReadDate,
                finishedDates: finishes.isEmpty ? nil : finishes,
                rating: row.rating, isReading: isReading ? true : nil,
                // As the Apple TV marks read books: on the Read shelf, or finished at some point.
                isRead: (row.statusID == readStatus || !finishes.isEmpty
                    || row.lastReadDate != nil) ? true : nil,
                progress: isReading
                    ? progress(
                        of: current, pages: row.edition?.pages ?? source.pages,
                        audioSeconds: row.edition?.audioSeconds)
                    : nil,
                started: isReading ? current?.startedAt : nil, audioSeconds: edition?.audioSeconds,
                communityRating: source.rating, ratingsCount: source.ratingsCount,
                ratingDistribution: source.ratingsDistribution, description: source.description,
                review: plainText(from: row.review))
            if let previous = unique[book.id], !recentFirst(book, previous) { continue }
            unique[book.id] = book
        }
        return unique.values.sorted(by: recentFirst)
    }

    private static func recentFirst(_ lhs: CloudBook, _ rhs: CloudBook) -> Bool {
        if lhs.finished == rhs.finished { return lhs.id > rhs.id }
        return (lhs.finished ?? "") > (rhs.finished ?? "")
    }

    /// The fraction of an unfinished read completed, from 0 to 1, or `nil` without progress.
    ///
    /// Prefers Hardcover's percentage, then pages, then listening time, each divided by the
    /// read's edition length or the library edition's.
    private static func progress(of read: LibraryPage.Read?, pages: Int?, audioSeconds: Int?)
        -> Double?
    {
        guard let read else { return nil }
        let fraction: Double
        if let percent = read.progress {
            fraction = percent / 100
        } else if let done = read.progressPages, let total = read.edition?.pages ?? pages,
            total > 0
        {
            fraction = Double(done) / Double(total)
        } else if let done = read.progressSeconds,
            let total = read.edition?.audioSeconds ?? audioSeconds, total > 0
        {
            fraction = Double(done) / Double(total)
        } else {
            return nil
        }
        return fraction.isFinite ? min(1, max(0, fraction)) : nil
    }

    /// The reported height, in pixels, below which a saved cover counts as low quality and may be
    /// replaced by a sharper one. Matches the Apple TV app.
    static let lowQualityCoverHeight = 1000

    /// The preferred cover and a fallback, chosen like the Apple TV app.
    ///
    /// `previous` holds the covers the book had in the account's last sync. They stay fixed, so
    /// spine designs and cached images keep matching on every device even when the reader's
    /// edition changes, unless an upgrade applies: this sync's candidates include the previous
    /// preferred cover with a reported height below `lowQualityCoverHeight`, and the new choice
    /// reports a height of at least that. A cover without a reported height is never replaced
    /// and never replaces another. Without `previous`, or without a previous preferred cover,
    /// the new choice is used. The Apple TV app applies the same rule.
    static func coverURLs(
        edition: LibraryPage.Image?, book: LibraryPage.Image?,
        otherEditions: [LibraryPage.Image] = [], editionIsInLanguage: Bool = true,
        previous: (preferred: URL?, alternate: URL?)? = nil
    ) -> (preferred: URL?, alternate: URL?) {
        let choice = bestCoverURLs(
            edition: edition, book: book, otherEditions: otherEditions,
            editionIsInLanguage: editionIsInLanguage)
        guard let previous, let kept = previous.preferred else { return choice }
        let candidates = [edition, book].compactMap(\.self) + otherEditions
        func height(_ url: URL?) -> Int? {
            candidates.filter { url != nil && $0.url == url }.compactMap(\.height).max()
        }
        if let old = height(kept), old < lowQualityCoverHeight,
            let new = height(choice.preferred), new >= lowQualityCoverHeight
        {
            return choice
        }
        return previous
    }

    /// The best covers among this sync's candidates.
    ///
    /// The reader's edition wins unless another image is clearly better; a square audiobook
    /// image, for example, loses to any portrait cover. An edition in another language counts
    /// only when nothing else can serve. Without a portrait cover, the largest square image of at
    /// least 300 pixels is used.
    private static func bestCoverURLs(
        edition: LibraryPage.Image?, book: LibraryPage.Image?, otherEditions: [LibraryPage.Image],
        editionIsInLanguage: Bool
    ) -> (preferred: URL?, alternate: URL?) {
        if !editionIsInLanguage, edition != nil {
            let choice = bestCoverURLs(
                edition: nil, book: book, otherEditions: otherEditions, editionIsInLanguage: true)
            if choice.preferred != nil { return choice }
        }
        var seen = Set<URL>()
        let images = ([edition, book].compactMap(\.self) + otherEditions)
            .filter { $0.url.map { seen.insert($0).inserted } ?? false }
        guard let best = bestCover(in: images, preferring: edition) else {
            let square =
                images.filter { image in
                    guard image.url?.scheme == "https", let width = image.width,
                        let height = image.height
                    else { return false }
                    return min(width, height) >= 300
                }
                .max { ($0.height ?? 0) < ($1.height ?? 0) }
            return (square?.url, nil)
        }
        let alternate = images.first { isCover($0) && $0.url != best.url }?.url
        return (best.url, alternate)
    }

    /// The sharpest portrait cover. `preferred` scores as if 20% taller, so it wins unless
    /// another image is clearly larger.
    private static func bestCover(
        in images: [LibraryPage.Image], preferring preferred: LibraryPage.Image?
    ) -> LibraryPage.Image? {
        func score(_ image: LibraryPage.Image) -> Double {
            guard let width = image.width, let height = image.height, width > 0, height > 0
            else { return 0 }
            let ratio = Double(width) / Double(height)
            let portrait = (0.5...0.82).contains(ratio)
            let boost = preferred != nil && image.url == preferred?.url ? 1.2 : 1
            return (portrait ? 1_000_000 : 0) + min(Double(height) * boost, 2400) * 100
                - abs(ratio - 0.67) * 1000
        }
        return images.filter(isCover).max { score($0) < score($1) }
    }

    /// Whether `image` can be a cover: HTTPS, at least 300 pixels on its shorter side, and not
    /// nearly square, which usually means an author photo or audiobook art. Images without
    /// dimensions pass.
    private static func isCover(_ image: LibraryPage.Image) -> Bool {
        guard image.url?.scheme == "https" else { return false }
        guard let width = image.width, let height = image.height else { return true }
        let ratio = Double(width) / Double(max(1, height))
        return min(width, height) >= 300 && abs(ratio - 1) > 0.03
    }
}

private struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables
}

/// The variables of a social query. Absent values are left out of the request, since
/// Hardcover rejects variables that a query does not declare.
private struct SocialVariables: Encodable {
    var user: Int?
    var offset: Int?
    var users: [Int]?
    var usernames: [String]?
    var language: String?
}

/// A Hardcover user as the social queries return one. A profile without a username has no
/// page to link to, so it is left out.
private struct SocialProfile: Decodable {
    let id: Int
    let username: String?
    let name: String?
    let image: Image?

    struct Image: Decodable { let url: String? }

    var profile: ReaderProfile? {
        guard let username = username?.trimmingCharacters(in: .whitespacesAndNewlines),
            !username.isEmpty
        else { return nil }
        let avatar = image?.url.flatMap(URL.init(string:))
        return ReaderProfile(
            id: id, username: username, name: name,
            avatarURL: CoverURLPolicy.allows(avatar) ? avatar : nil)
    }
}

private struct HTTPFailure: Decodable { let error: String? }

private struct GraphQLReply<Result: Decodable>: Decodable {
    let data: Result?
    let errors: [Failure]?

    struct Failure: Decodable {
        let extensions: Extensions?
        struct Extensions: Decodable { let code: String? }
    }
}

/// The editions query's reply.
private struct EditionsPage: Decodable {
    let editions: [Edition]

    struct Edition: Decodable {
        let id: Int
        let editionFormat: String?
        let releaseYear: Int?
        let readingFormat: LibraryPage.Edition.ReadingFormat?
        let image: LibraryPage.Image?

        enum CodingKeys: String, CodingKey {
            case id, image
            case editionFormat = "edition_format"
            case releaseYear = "release_year"
            case readingFormat = "reading_format"
        }
    }
}

/// The series query's reply.
private struct SeriesPage: Decodable {
    let series: [Series]

    struct Series: Decodable {
        let id: Int
        let name: String
        let bookSeries: [Entry]

        enum CodingKeys: String, CodingKey {
            case id, name
            case bookSeries = "book_series"
        }
    }

    struct Entry: Decodable {
        let position: Double?
        let book: Book?
    }

    struct Book: Decodable {
        let id: Int
        let title: String?
        let releaseYear: Int?
        let image: LibraryPage.Image?

        enum CodingKeys: String, CodingKey {
            case id, title, image
            case releaseYear = "release_year"
        }
    }
}

/// One page of the library query, decoded field by field from Hardcover's names.
struct LibraryPage: Decodable {
    let userBooks: [Row]

    enum CodingKeys: String, CodingKey { case userBooks = "user_books" }

    struct Row: Decodable {
        let statusID: Int?
        let lastReadDate: String?
        let rating: Double?
        /// The reader's review, which may hold Markdown or HTML.
        let review: String?
        let book: Book
        let edition: Edition?
        let finishedReads: [Read]?
        let currentReads: [Read]?

        enum CodingKeys: String, CodingKey {
            case rating, review, book, edition
            case statusID = "status_id"
            case lastReadDate = "last_read_date"
            case finishedReads = "user_book_reads"
            case currentReads = "current_read"
        }
    }

    struct Book: Decodable {
        let id: Int
        let title: String?
        let pages: Int?
        let releaseYear: Int?
        let cachedContributors: [Contributor]?
        let cachedTags: [String: [Tag]]?
        let rating: Double?
        let ratingsCount: Int?
        let ratingsDistribution: [RatingBucket]?
        let description: String?
        let image: Image?
        let bookSeries: [BookSeries]?
        let editions: [EditionImage]?

        enum CodingKeys: String, CodingKey {
            case id, title, description, pages, rating, image, editions
            case releaseYear = "release_year"
            case cachedContributors = "cached_contributors"
            case cachedTags = "cached_tags"
            case ratingsCount = "ratings_count"
            case ratingsDistribution = "ratings_distribution"
            case bookSeries = "book_series"
        }
    }

    struct Contributor: Decodable {
        let contribution: String?
        let author: Author?
        struct Author: Decodable { let name: String? }
    }

    struct Tag: Decodable {
        let tag: String
        let count: Int?
        let spoilerRatio: Double?
    }

    struct BookSeries: Decodable {
        let featured: Bool?
        let position: Double?
        let compilation: Bool?
        let series: Series?
        struct Series: Decodable {
            let id: Int
            let name: String?
            let booksCount: Int?
            let primaryBooksCount: Int?

            enum CodingKeys: String, CodingKey {
                case id, name
                case booksCount = "books_count"
                case primaryBooksCount = "primary_books_count"
            }
        }
    }

    struct EditionImage: Decodable { let image: Image? }

    struct Edition: Decodable {
        let pages: Int?
        let audioSeconds: Int?
        let image: Image?
        let readingFormat: ReadingFormat?
        let language: Language?

        enum CodingKeys: String, CodingKey {
            case pages, image, language
            case audioSeconds = "audio_seconds"
            case readingFormat = "reading_format"
        }
        struct ReadingFormat: Decodable { let format: String? }
        struct Language: Decodable { let code2: String? }
    }

    /// A read: finished reads carry the finish date and edition; the current read carries
    /// progress.
    struct Read: Decodable {
        let finishedAt: String?
        let startedAt: String?
        /// Percent complete, from 0 to 100.
        let progress: Double?
        let progressPages: Int?
        let progressSeconds: Int?
        let edition: Edition?

        enum CodingKeys: String, CodingKey {
            case progress, edition
            case finishedAt = "finished_at"
            case startedAt = "started_at"
            case progressPages = "progress_pages"
            case progressSeconds = "progress_seconds"
        }
    }

    struct Image: Decodable {
        let url: URL?
        let width: Int?
        let height: Int?
    }
}
