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
        case .credentialNotSaved: "Bookworms could not save your Hardcover login on this iPhone."
        }
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
    case success(token: String)
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
            "https://hardcover.app/oauth2/token",
            [
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("device_code", deviceCode), ("client_id", Self.clientID),
            ])
        struct Reply: Decodable {
            let accessToken: String?
            let error: String?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case error
            }
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if status == 200 {
            guard let token = reply?.accessToken.flatMap(Self.validToken) else {
                throw HardcoverError.rejected
            }
            return .success(token: token)
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
    /// access token.
    ///
    /// Waits the code's interval (5 seconds when Hardcover gives none) before each poll, and 5
    /// seconds longer after each `slow_down`, as RFC 8628 requires, or after each HTTP 429.
    /// Network failures, server errors, and rate limits keep polling because the code stays
    /// valid; the code's lifetime bounds the wait.
    static func awaitApproval(
        of authorization: DeviceAuthorization,
        poll: @Sendable () async throws -> DevicePollResult,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> String {
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
            case .success(let token): return token
            }
        }
        throw HardcoverError.deviceFlowExpired
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

    /// Downloads every book on the account's shelves, 100 per request, paced about a second
    /// apart to stay inside Hardcover's rate limit.
    func library(token: String) async throws -> PhoneLibrary {
        let user = try await account(token: token)
        struct Variables: Encodable {
            let user: Int
            let offset: Int
            let language: String
        }
        var rows: [LibraryPage.Row] = []
        for offset in stride(from: 0, to: 10_000, by: 100) {
            if offset > 0 { try await Task.sleep(for: .seconds(1.1)) }
            let page: LibraryPage = try await query(
                Self.libraryQuery,
                variables: Variables(user: user.id, offset: offset, language: Self.coverLanguage),
                token: token)
            rows += page.userBooks
            if page.userBooks.count < 100 {
                return PhoneLibrary(
                    accountID: String(user.id), username: user.username, syncedAt: .now,
                    books: Self.normalize(rows))
            }
        }
        throw HardcoverError.incomplete
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
              book_series { featured position series { id name } }
              editions(where: {image_id: {_is_null: false},
                  _or: [{language_id: {_is_null: true}}, {language: {code2: {_eq: $language}}}]},
                order_by: {users_count: desc}, limit: 5) {
                image { url width height }
              }
            }
            edition { pages audio_seconds image { url width height } reading_format { format } language { code2 } }
            user_book_reads(where: {finished_at: {_is_null: false}},
              order_by: [{finished_at: desc}, {id: desc}], limit: 1) {
              finished_at edition { pages audio_seconds image { url width height } reading_format { format } language { code2 } }
            }
            current_read: user_book_reads(where: {finished_at: {_is_null: true}},
              order_by: [{id: desc}], limit: 1) {
              started_at progress progress_pages progress_seconds edition { pages audio_seconds }
            }
          }
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
    /// recently finished.
    private static func normalize(_ rows: [LibraryPage.Row]) -> [CloudBook] {
        var unique: [Int: CloudBook] = [:]
        for row in rows {
            let source = row.book
            let read = row.finishedReads?.first
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
                    } ?? true)
            let membership = source.bookSeries?
                .sorted { ($0.featured ?? false) && !($1.featured ?? false) }.first
            let seriesName = membership?.series?.name?.trimmingCharacters(in: .whitespaces)
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
                pages: edition?.pages ?? source.pages,
                finished: read?.finishedAt ?? row.lastReadDate,
                rating: row.rating, isReading: isReading ? true : nil,
                // As the Apple TV marks read books: on the Read shelf, or finished at some point.
                isRead: (row.statusID == readStatus || read?.finishedAt != nil
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

    /// The preferred cover and a fallback, chosen like the Apple TV app.
    ///
    /// The reader's edition wins unless another image is clearly better; a square audiobook
    /// image, for example, loses to any portrait cover. An edition in another language counts
    /// only when nothing else can serve. Without a portrait cover, the largest square image of at
    /// least 300 pixels is used.
    private static func coverURLs(
        edition: LibraryPage.Image?, book: LibraryPage.Image?, otherEditions: [LibraryPage.Image],
        editionIsInLanguage: Bool
    ) -> (preferred: URL?, alternate: URL?) {
        if !editionIsInLanguage, edition != nil {
            let choice = coverURLs(
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

/// One page of the library query, decoded field by field from Hardcover's names.
private struct LibraryPage: Decodable {
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
        let bookSeries: [SeriesMembership]?
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

    struct SeriesMembership: Decodable {
        let featured: Bool?
        let position: Double?
        let series: Series?
        struct Series: Decodable {
            let id: Int
            let name: String?
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
