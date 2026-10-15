import Foundation
import XCTest

@testable import Bookworms

/// Covers comparisons with other Hardcover readers: decoding the social queries, the refresh's
/// filtering, taste-match scoring, friend Hot Takes, Book Swap, and username lookups. Every
/// reader, book, and reply is fictional, and no test contacts Hardcover.
final class SocialTests: XCTestCase {
    // MARK: - Matching and scoring

    private static func book(
        _ id: Int, rating: Double?, finished: String? = "2025-06-01", community: Double? = nil
    ) -> CloudBook {
        CloudBook(
            id: id, title: "Fictional Book \(id)", author: "Author \(id)", coverURL: nil,
            detailCoverURL: nil, finished: finished, rating: rating, communityRating: community,
            ratingsCount: community == nil ? nil : 500)
    }

    func testSharedBooksNeedTwoValidRatings() {
        let mine = [
            Self.book(1, rating: 4), Self.book(2, rating: nil), Self.book(3, rating: 0),
            Self.book(4, rating: 5), Self.book(5, rating: 3),
        ]
        let theirs = [
            Self.book(1, rating: 3.5), Self.book(2, rating: 4), Self.book(3, rating: 4),
            Self.book(4, rating: nil), Self.book(4, rating: 2), Self.book(9, rating: 5),
        ]
        let match = TasteMatch(mine: mine, theirs: theirs)
        XCTAssertEqual(match.shared.map(\.id), [1], "Unrated, zero, and missing ratings drop out")
        XCTAssertEqual(match.shared.first?.gap, 0.5)
        XCTAssertEqual(match.theirRating(for: 1), 3.5)
        XCTAssertNil(match.theirRating(for: 4), "The first copy of a duplicate book wins")
    }

    func testScoreNeedsFiveSharedBooksAndFallsFiftyPointsPerStar() {
        func shared(_ gaps: [Double]) -> [SharedRating] {
            gaps.enumerated()
                .map { index, gap in
                    SharedRating(book: Self.book(index, rating: 5), mine: 5, theirs: 5 - gap)
                }
        }
        XCTAssertNil(TasteMatch.score(of: shared([0, 0, 0, 0])), "Four books are too few")
        XCTAssertEqual(TasteMatch.score(of: shared([0, 0, 0, 0, 0])), 100)
        XCTAssertEqual(TasteMatch.score(of: shared([1, 1, 1, 1, 1])), 50)
        XCTAssertEqual(TasteMatch.score(of: shared([0.5, 0, 0, 0, 0])), 95)
        XCTAssertEqual(TasteMatch.score(of: shared([4, 4, 2, 2, 2])), 0, "Never below zero")
        let match = TasteMatch(
            mine: (1...5).map { Self.book($0, rating: 4) },
            theirs: (1...5).map { Self.book($0, rating: 4) })
        XCTAssertEqual(match.score, 100)
        XCTAssertEqual(match.tier, "Reading twins")
    }

    func testAgreementsAndFightsRankTheirBooks() {
        let mine = [
            Self.book(1, rating: 5), Self.book(2, rating: 4.5), Self.book(3, rating: 4),
            Self.book(4, rating: 5), Self.book(5, rating: 1), Self.book(6, rating: 3),
            Self.book(7, rating: 2),
        ]
        let theirs = [
            Self.book(1, rating: 5), Self.book(2, rating: 4), Self.book(3, rating: 4),
            Self.book(4, rating: 1), Self.book(5, rating: 4), Self.book(6, rating: 3),
            Self.book(7, rating: 3.5),
        ]
        let match = TasteMatch(mine: mine, theirs: theirs)
        XCTAssertEqual(match.agreements.map(\.id), [1, 2, 3], "Highest combined first; 6 is 3★")
        XCTAssertEqual(match.fights.map(\.id), [4, 5, 7], "Widest gap first, at least 1.5★")
        XCTAssertEqual(TasteMatch.fightLabel(4), "Friendship on the line")
        XCTAssertEqual(TasteMatch.fightLabel(2), "Agree to disagree")
        XCTAssertEqual(TasteMatch.fightLabel(1.5), "A polite debate")
    }

    /// A friend's Hot Takes compare with their rating instead of Hardcover's average, which
    /// does not need 50 ratings.
    func testFriendHotTakesRankTheWidestGapsInTheFrame() {
        let mine = [
            Self.book(1, rating: 5, finished: "2025-02-01", community: 4.9),
            Self.book(2, rating: 4, finished: "2025-03-01"),
            Self.book(3, rating: 2, finished: "2024-03-01"),
            Self.book(4, rating: 4.5, finished: nil),
            Self.book(5, rating: 3, finished: "2025-04-01"),
        ]
        let theirs = [
            Self.book(1, rating: 2), Self.book(2, rating: 3.5), Self.book(3, rating: 5),
            Self.book(4, rating: 1), Self.book(5, rating: 3.5),
        ]
        let match = TasteMatch(mine: mine, theirs: theirs)
        XCTAssertEqual(match.hotTakes(in: .year(2025), direction: .lovedMore).map(\.id), [1, 2])
        XCTAssertEqual(
            match.hotTakes(in: .lifetime, direction: .lovedMore).map(\.id), [4, 1, 2],
            "A lifetime counts books without a finish date")
        XCTAssertEqual(match.hotTakes(in: .lifetime, direction: .lovedLess).map(\.id), [3, 5])
        let takes = ShareTemplate.hotTakes
        XCTAssertEqual(
            takes.books(from: mine, in: .year(2025), match: match).map(\.id), [1, 2],
            "With a match, Hot Takes compares with the reader")
        XCTAssertEqual(
            takes.books(from: mine, in: .year(2025)).map(\.id), [],
            "Without one, it compares with Hardcover, where book 1's gap is too small")
        XCTAssertEqual(
            ShareTemplate.tasteMatch.books(from: mine, in: .lifetime, match: match).map(\.id),
            [4, 1, 3], "No agreements, then the fights, widest and newest first")
        XCTAssertEqual(ShareTemplate.tasteMatch.books(from: mine, in: .lifetime), [])
    }

    func testBookSwapPicksFavoritesTheOtherNeverShelved() {
        let mine = [
            Self.book(1, rating: 5), Self.book(2, rating: 4.5), Self.book(3, rating: 3.5),
            Self.book(4, rating: 4, finished: "2025-09-01"), Self.book(5, rating: 4),
            Self.book(6, rating: 5), Self.book(20, rating: nil),
        ]
        let theirs = [
            Self.book(6, rating: nil), Self.book(10, rating: 5), Self.book(11, rating: 4),
            Self.book(12, rating: 3), Self.book(20, rating: 5),
        ]
        let match = TasteMatch(mine: mine, theirs: theirs)
        XCTAssertEqual(
            match.forThem.map(\.id), [1, 2, 4],
            "Highest rated first, then the latest finish; 6 is on their shelf; three at most")
        XCTAssertEqual(
            match.forMe.map(\.id), [10, 11], "20 is on my shelf, even without my rating")
        XCTAssertEqual(
            ShareTemplate.bookSwap.books(from: mine, in: .lifetime, match: match).map(\.id),
            [1, 2, 4, 10, 11])
    }

    // MARK: - Usernames and invitations

    func testUsernamesParseFromHandlesAndLinks() {
        XCTAssertEqual(ReaderProfile.username(from: "  @robin_vale "), "robin_vale")
        XCTAssertEqual(ReaderProfile.username(from: "https://hardcover.app/@sam.o/"), "sam.o")
        XCTAssertEqual(ReaderProfile.username(from: "hardcover.app/@jun-park"), "jun-park")
        XCTAssertNil(ReaderProfile.username(from: ""))
        XCTAssertNil(ReaderProfile.username(from: "robin vale"))
        XCTAssertNil(ReaderProfile.username(from: "robin\"}"))
        XCTAssertEqual(
            HardcoverInvite.profileURL("robin_vale")?.absoluteString,
            "https://hardcover.app/@robin_vale")
        XCTAssertNil(HardcoverInvite.profileURL("a b"))
        XCTAssertEqual(
            HardcoverInvite.shareText("robin_vale"),
            "Compare takes with me on Hardcover: https://hardcover.app/@robin_vale")
        let profile = ReaderProfile(id: 1, username: "robin_vale", name: "Robin Vale")
        XCTAssertEqual(profile.shortName, "Robin")
        XCTAssertEqual(ReaderProfile(id: 2, username: "jun", name: " ").displayName, "@jun")
    }

    // MARK: - Decoding and refresh

    func testFollowingLeavesOutBlockedNamelessAndOwnProfiles() async throws {
        let client = HardcoverClient(
            transport: Self.router([
                "SocialFollowing": Self.followingPage
            ]))
        let readers = try await client.following(owner: 1, blocked: [13], token: "fictional")
        XCTAssertEqual(readers.map(\.id), [11, 12])
        XCTAssertEqual(readers[0].avatarURL?.absoluteString, "https://images.example.com/11.jpg")
        XCTAssertNil(readers[1].avatarURL, "Only HTTPS photos load")
    }

    func testReaderLibraryDecodesTheirRatings() async throws {
        let client = HardcoverClient(transport: Self.router(["ReaderLibrary": Self.libraryPage]))
        let books = try await client.readerLibrary(user: 11, token: "fictional")
        XCTAssertEqual(books.map(\.id), [101, 102])
        let first = try XCTUnwrap(books.first { $0.id == 101 })
        XCTAssertEqual(first.rating, 4.5)
        XCTAssertEqual(first.author, "Mara Quill")
        XCTAssertEqual(first.finished, "2025-03-02")
        XCTAssertNil(first.review)
    }

    @MainActor
    func testRefreshDropsUnfollowedAndBlockedReadersAndKeepsSnapshotOnFailure() async throws {
        let url = temporaryURL()
        var saved = SocialSnapshot(owner: Self.owner)
        let gone = ReaderProfile(id: 99, username: "unfollowed_reader")
        saved.following = [gone]
        saved.lookedUp = [ReaderProfile(id: 13, username: "blocked_reader")]
        saved.libraries = [
            99: ReaderLibrary(books: [Self.book(101, rating: 3)], syncedAt: .now),
            13: ReaderLibrary(books: [Self.book(101, rating: 3)], syncedAt: .now),
        ]
        try JSONEncoder().encode(saved).write(to: url)
        let model = SocialModel(
            client: HardcoverClient(transport: Self.router(Self.socialReplies)), cacheURL: url,
            pause: .zero)
        await model.restore(accountID: "1")
        XCTAssertEqual(model.snapshot?.libraries.keys.sorted(), [13, 99])
        await model.sync(token: "fictional", accountID: "1")
        let snapshot = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(snapshot.following.map(\.id), [11, 12])
        XCTAssertEqual(snapshot.lookedUp, [], "Blocked readers leave the looked-up list")
        XCTAssertEqual(snapshot.libraries.keys.sorted(), [11, 12])
        XCTAssertNotNil(snapshot.syncedAt)
        XCTAssertNil(model.failure)

        // A temporary failure keeps the snapshot; a denied login clears it. Each model reads its
        // own copy, since the first one writes its file in the background.
        let failingURL = temporaryURL()
        try JSONEncoder().encode(snapshot).write(to: failingURL)
        let failing = SocialModel(
            client: HardcoverClient(transport: { request in
                Self.respond(400, "", to: request)
            }), cacheURL: failingURL, pause: .zero)
        await failing.restore(accountID: "1")
        await failing.sync(token: "fictional", accountID: "1")
        XCTAssertEqual(failing.snapshot?.following.map(\.id), [11, 12])
        XCTAssertNotNil(failing.failure)
        let deniedURL = temporaryURL()
        try JSONEncoder().encode(snapshot).write(to: deniedURL)
        let denied = SocialModel(
            client: HardcoverClient(transport: { request in
                Self.respond(401, "", to: request)
            }), cacheURL: deniedURL, pause: .zero)
        await denied.restore(accountID: "1")
        XCTAssertNotNil(denied.snapshot)
        await denied.sync(token: "fictional", accountID: "1")
        XCTAssertNil(denied.snapshot)
        XCTAssertNotNil(denied.failure)
    }

    func testRefreshDownloadsTheMostRecentlyActiveFirstWithinTheLimit() {
        let following = (1...20).map { ReaderProfile(id: $0, username: "reader\($0)") }
        let looked = [ReaderProfile(id: 50, username: "looked"), following[0]]
        let targets = SocialModel.readersToSync(
            following: following, active: [18, 3, 99, 18], lookedUp: looked)
        XCTAssertEqual(targets.count, SocialModel.readerLimit + 1)
        XCTAssertEqual(Array(targets.prefix(4)), [18, 3, 1, 2])
        XCTAssertEqual(targets.last, 50, "Looked-up readers always refresh")
    }

    @MainActor
    func testLookupsReportEachReasonAReaderCannotBeCompared() async throws {
        let replies = Self.socialReplies.merging([
            "ReaderLookup": """
            {"data":{"users":[{"id":1,"username":"owner_reader","name":"Owner"},
              {"id":13,"username":"blocked_reader","name":null},
              {"id":30,"username":"Quiet_Reader","name":"Quiet"},
              {"id":40,"username":"public_reader","name":"Pat Public"}]}}
            """
        ]) { _, new in new }
        // Reader 30 has no ratings; reader 40 has the fixture library.
        let model = SocialModel(
            client: HardcoverClient(transport: Self.router(replies, emptyLibraryFor: 30)),
            cacheURL: temporaryURL(), pause: .zero)
        let cases: [(String, ReaderLookupError)] = [
            ("not a name", .invalidUsername), ("@owner_reader", .yourself),
            ("nobody_here", .notFound("nobody_here")),
            ("blocked_reader", .blocked("blocked_reader")),
            // Hardcover matches usernames exactly, so the stored capitals must be typed.
            ("Quiet_Reader", .noRatings("Quiet_Reader")),
        ]
        for (input, expected) in cases {
            do {
                _ = try await model.lookUp(input, token: "fictional")
                XCTFail("Expected \(expected) for \(input)")
            } catch {
                XCTAssertEqual(error as? ReaderLookupError, expected, input)
            }
        }
        let found = try await model.lookUp("https://hardcover.app/@public_reader", token: "t")
        XCTAssertEqual(found.id, 40)
        XCTAssertEqual(model.snapshot?.lookedUp.map(\.id), [40])
        XCTAssertEqual(model.snapshot?.libraries[40]?.books.count, 2)
    }

    // MARK: - Fixtures

    private static let owner = ReaderProfile(id: 1, username: "owner_reader", name: "Owner")

    private static let followingPage = """
        {"data":{"followed_users":[
          {"followed_user":{"id":11,"username":"robin_vale","name":"Robin Vale",
            "image":{"url":"https://images.example.com/11.jpg"}}},
          {"followed_user":{"id":12,"username":"sam_okafor","name":null,
            "image":{"url":"http://images.example.com/12.jpg"}}},
          {"followed_user":{"id":13,"username":"blocked_reader","name":"Blocked","image":null}},
          {"followed_user":{"id":14,"username":null,"name":"No Username","image":null}},
          {"followed_user":{"id":1,"username":"owner_reader","name":"Owner","image":null}},
          {"followed_user":null}
        ]}}
        """

    private static let libraryPage = """
        {"data":{"user_books":[
          {"status_id":3,"last_read_date":"2025-03-02","rating":4.5,
           "book":{"id":101,"title":"The Lantern Keeper","pages":320,
             "cached_contributors":[{"author":{"name":"Mara Quill"},"contribution":null}],
             "rating":4.1,"ratings_count":250,
             "image":{"url":"https://covers.example.com/101.jpg","width":400,"height":600}},
           "edition":null},
          {"status_id":5,"last_read_date":null,"rating":null,
           "book":{"id":102,"title":"An Unfinished Map","cached_contributors":[]},
           "edition":null}
        ]}}
        """

    /// Replies by operation name for a refresh of owner 1, who follows 11, 12, and 13 and
    /// blocked 13.
    private static let socialReplies: [String: String] = [
        "SocialOwner": #"{"data":{"me":[{"id":1,"username":"owner_reader","name":"Owner"}]}}"#,
        "SocialBlocked": #"{"data":{"user_blocks":[{"blocked_user_id":13}]}}"#,
        "SocialFollowing": followingPage,
        "SocialActivity": #"{"data":{"activities":[{"user":{"id":12}},{"user":null}]}}"#,
        "ReaderLibrary": libraryPage,
        "ReaderLookup": #"{"data":{"users":[]}}"#,
    ]

    /// Answers each GraphQL request with the reply for its operation name, filtering
    /// `ReaderLookup` to the requested usernames, and an empty library for `emptyLibraryFor`.
    private static func router(_ replies: [String: String], emptyLibraryFor empty: Int? = nil)
        -> HardcoverClient.Transport
    {
        { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            let json = body as? [String: Any]
            let query = json?["query"] as? String ?? ""
            let variables = json?["variables"] as? [String: Any] ?? [:]
            let name = replies.keys.first { query.contains("query \($0)") } ?? ""
            var reply = replies[name] ?? #"{"data":{}}"#
            if name == "ReaderLibrary", variables["user"] as? Int == empty {
                reply = #"{"data":{"user_books":[]}}"#
            }
            if name == "ReaderLookup", let names = variables["usernames"] as? [String],
                let data = reply.data(using: .utf8),
                let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let users = (parsed["data"] as? [String: Any])?["users"] as? [[String: Any]]
            {
                let matching = users.filter { names.contains($0["username"] as? String ?? "") }
                let filtered = try JSONSerialization.data(
                    withJSONObject: ["data": ["users": matching]])
                reply = String(decoding: filtered, as: UTF8.self)
            }
            return respond(200, reply, to: request)
        }
    }

    /// A file in the temporary folder that no other test uses, removed when the test ends.
    private func temporaryURL() -> URL {
        let url = URL.temporaryDirectory.appending(path: "social-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static func respond(_ status: Int, _ body: String, to request: URLRequest)
        -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
