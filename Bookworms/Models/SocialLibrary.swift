import Foundation

/// A Hardcover reader: the signed-in account, someone it follows, or a public reader looked up
/// by username.
struct ReaderProfile: Codable, Hashable, Sendable, Identifiable {
    /// The Hardcover user ID.
    let id: Int
    let username: String
    var name: String?
    var avatarURL: URL?

    /// The reader's name, or "@username" without one.
    var displayName: String {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "@\(username)" : name
    }

    /// The first word of the name, or "@username" without one, for tight labels such as a
    /// rating row's "Sam".
    var shortName: String {
        displayName.hasPrefix("@")
            ? displayName : String(displayName.split(separator: " ").first ?? "")
    }

    /// The reader's public Hardcover profile, which opens in the Hardcover app when installed.
    var profileURL: URL? { HardcoverInvite.profileURL(username) }

    /// The username that `input` names, or `nil` when it cannot be one.
    ///
    /// Accepts a bare username, one with a leading "@", or a pasted profile link such as
    /// `https://hardcover.app/@sam`. A username is 1 to 40 letters, digits, underscores,
    /// periods, or hyphens, so nothing else ever reaches a query.
    static func username(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "hardcover.app/"]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasPrefix("@") { text.removeFirst() }
        while text.hasSuffix("/") { text.removeLast() }
        guard text.wholeMatch(of: /[A-Za-z0-9_.\-]{1,40}/) != nil else { return nil }
        return text
    }
}

/// Another reader's library: their rated books and books on their Currently Reading, Read,
/// Paused, and Did Not Finish shelves, with *their* ratings and finish dates.
struct ReaderLibrary: Codable, Equatable, Sendable {
    var books: [CloudBook]
    var syncedAt: Date
}

/// The social data the Share tab compares with, saved so comparisons work offline.
struct SocialSnapshot: Codable, Equatable, Sendable {
    /// Readers looked up by username, newest first, that the snapshot keeps.
    static let lookupLimit = 5

    var owner: ReaderProfile
    /// The readers the owner follows, without readers the owner blocked.
    var following: [ReaderProfile] = []
    /// Public readers the owner looked up by username and does not follow, newest first.
    var lookedUp: [ReaderProfile] = []
    /// Downloaded libraries by reader ID, only for readers in `readers`.
    var libraries: [Int: ReaderLibrary] = [:]
    /// When the followed readers last refreshed.
    var syncedAt: Date?

    /// Everyone the owner can compare with: followed readers, then looked-up readers.
    var readers: [ReaderProfile] {
        let followed = Set(following.map(\.id))
        return following + lookedUp.filter { !followed.contains($0.id) }
    }

    /// Drops looked-up readers the owner now follows or blocked, and the libraries of anyone
    /// who is no longer a reader, so an unfollowed or blocked reader's ratings leave the iPhone.
    mutating func prune(blocked: Set<Int> = []) {
        let followed = Set(following.map(\.id))
        lookedUp.removeAll { followed.contains($0.id) || blocked.contains($0.id) }
        lookedUp = Array(lookedUp.prefix(Self.lookupLimit))
        let kept = Set(readers.map(\.id))
        libraries = libraries.filter { kept.contains($0.key) }
    }
}

/// A book both readers rated, with both ratings.
struct SharedRating: Equatable, Sendable, Identifiable {
    /// The book from the owner's library, with the owner's rating and finish date.
    let book: CloudBook
    let mine: Double
    let theirs: Double

    var id: Int { book.id }
    /// The owner's rating minus the other reader's.
    var gap: Double { mine - theirs }
    var distance: Double { abs(gap) }
    var combined: Double { mine + theirs }
}

/// How the owner's ratings compare with another reader's, prepared when either library
/// changes.
///
/// The match score is 100 minus 50 points for each star of the average gap between the two
/// ratings of every book both readers rated, from 0 to 100: identical ratings score 100, an
/// average gap of one star scores 50, and two stars or more score 0. It needs at least
/// `minimumShared` books both readers rated; with fewer, there is no score.
struct TasteMatch: Equatable, Sendable {
    /// The fewest books both readers rated before a score shows.
    static let minimumShared = 5
    /// The widest gap at which two ratings agree.
    static let agreementGap = 0.5
    /// The lowest rating that counts as loving a book, for agreements and Book Swap picks.
    static let lovedRating = 4.0
    /// The narrowest gap that counts as a fight.
    static let fightGap = 1.5
    /// The most books a list holds.
    static let limit = 3

    /// Every book both readers rated, in the owner's library order.
    let shared: [SharedRating]
    /// The match score from 0 to 100, or `nil` with fewer than `minimumShared` shared books.
    let score: Int?
    /// Books both readers rated `lovedRating` or more, at most `agreementGap` apart, highest
    /// combined rating first.
    let agreements: [SharedRating]
    /// Books whose ratings are at least `fightGap` apart, widest first.
    let fights: [SharedRating]
    /// The owner's books rated `lovedRating` or more that the other reader never shelved,
    /// highest rated first.
    let forThem: [CloudBook]
    /// The other reader's books rated `lovedRating` or more that the owner never shelved or
    /// shelved without starting (`CloudBook.isUnstarted`), highest rated first, with the other
    /// reader's rating.
    let forMe: [CloudBook]
    /// The IDs of the `forMe` books that the owner shelved without starting, such as on Want to
    /// Read, which Book Swap labels as already on the owner's list.
    let onMyList: Set<Int>
    private let theirRatings: [Int: Double]

    /// Compares the owner's library `mine` with another reader's library `theirs`. Ratings
    /// outside 0.5 to 5 stars count as unrated.
    init(mine: [CloudBook], theirs: [CloudBook]) {
        let theirBooks = Dictionary(theirs.map { ($0.id, $0) }) { first, _ in first }
        let myBooks = Dictionary(mine.map { ($0.id, $0) }) { first, _ in first }
        var seen = Set<Int>()
        shared = mine.compactMap { book in
            guard let mine = Self.valid(book.rating), seen.insert(book.id).inserted,
                let theirs = Self.valid(theirBooks[book.id]?.rating)
            else { return nil }
            return SharedRating(book: book, mine: mine, theirs: theirs)
        }
        theirRatings = Dictionary(shared.map { ($0.id, $0.theirs) }) { first, _ in first }
        score = Self.score(of: shared)
        agreements = Array(
            shared
                .filter {
                    $0.distance <= Self.agreementGap && min($0.mine, $0.theirs) >= Self.lovedRating
                }
                .sorted {
                    ($0.combined, -$0.distance, $0.book.finished ?? "", $0.id)
                        > ($1.combined, -$1.distance, $1.book.finished ?? "", $1.id)
                }
                .prefix(Self.limit))
        fights = Array(
            shared.filter { $0.distance >= Self.fightGap }
                .sorted {
                    ($0.distance, $0.book.finished ?? "", $0.id)
                        > ($1.distance, $1.book.finished ?? "", $1.id)
                }
                .prefix(Self.limit))
        forThem = Self.picks(mine.filter { theirBooks[$0.id] == nil })
        forMe = Self.picks(theirs.filter { myBooks[$0.id]?.isUnstarted ?? true })
        onMyList = Set(forMe.map(\.id).filter { myBooks[$0] != nil })
    }

    /// The score of `shared`, or `nil` with fewer than `minimumShared` books.
    static func score(of shared: [SharedRating]) -> Int? {
        guard shared.count >= minimumShared else { return nil }
        let averageGap = shared.reduce(0) { $0 + $1.distance } / Double(shared.count)
        return Int((100 - 50 * averageGap).rounded()).clamped(to: 0...100)
    }

    /// The other reader's rating of a book both readers rated.
    func theirRating(for bookID: Int) -> Double? { theirRatings[bookID] }

    /// Up to three books finished in `frame` whose ratings differ by at least
    /// `HotTakeDirection.minimumGap` in `direction`, widest gap first, then the most recently
    /// finished. A lifetime also counts rated books without a finish date.
    func hotTakes(in frame: TimeFrame, direction: HotTakeDirection) -> [SharedRating] {
        let sign: Double = direction == .lovedMore ? 1 : -1
        return Array(
            shared
                .filter {
                    (frame == .lifetime || frame.contains($0.book))
                        && $0.gap * sign >= HotTakeDirection.minimumGap
                }
                .sorted {
                    ($0.gap * sign, $0.book.finished ?? "", $0.id)
                        > ($1.gap * sign, $1.book.finished ?? "", $1.id)
                }
                .prefix(Self.limit))
    }

    /// A playful name for the score, such as "Reading twins".
    var tier: String? {
        guard let score else { return nil }
        switch score {
        case 90...: return "Reading twins"
        case 75..<90: return "Kindred shelves"
        case 55..<75: return "Good company"
        case 35..<55: return "Friendly rivals"
        default: return "Opposite shelves"
        }
    }

    /// A playful label for two ratings `distance` stars apart.
    static func fightLabel(_ distance: Double) -> String {
        switch distance {
        case 3...: "Friendship on the line"
        case 2..<3: "Agree to disagree"
        default: "A polite debate"
        }
    }

    private static func valid(_ rating: Double?) -> Double? {
        guard let rating, (0.5...5).contains(rating) else { return nil }
        return rating
    }

    private static func picks(_ books: [CloudBook]) -> [CloudBook] {
        Array(
            books.filter { (valid($0.rating) ?? 0) >= lovedRating }
                .sorted {
                    ($0.rating ?? 0, $0.finished ?? "", $0.id) > (
                        $1.rating ?? 0, $1.finished ?? "", $1.id
                    )
                }
                .prefix(limit))
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension CloudBook {
    /// Whether the reader shelved the book without starting it: it is not read, not a current
    /// read, and has no finish date or rating, as on Want to Read.
    ///
    /// The book keeps no Hardcover status, so an unrated, unfinished book on Paused, Did Not
    /// Finish, or Ignored counts too.
    // ponytail: no status_id on CloudBook; test for Want to Read (status 1) once books keep it.
    var isUnstarted: Bool {
        isRead != true && isReading != true && finished == nil && (rating ?? 0) <= 0
    }
}

/// The links that share images and their share text carry, kept in one place so the wording
/// and links change together: the sharer's Hardcover profile, and books' permanent pages.
enum HardcoverInvite {
    static let line = "Compare takes with me on Hardcover"

    /// The most books whose links a **My reading** image's share text lists. An image of more,
    /// such as a year's Desk, sends only the profile link.
    static let linkedBooks = 5

    /// `https://hardcover.app/@username`, or `nil` when `username` cannot be one.
    static func profileURL(_ username: String) -> URL? {
        guard ReaderProfile.username(from: username) == username else { return nil }
        return URL(string: "https://hardcover.app/@\(username)")
    }

    /// The profile link as an image letters it, such as "hardcover.app/@sam".
    static func link(_ username: String) -> String { "hardcover.app/@\(username)" }

    /// The text the share sheet sends with a social image.
    static func shareText(_ username: String) -> String {
        profileURL(username).map { "\(line): \($0.absoluteString)" } ?? line
    }

    /// A book's permanent Hardcover page, `https://hardcover.app/id/books/<id>`, which keeps
    /// working when the book's slug changes or it merges, or `nil` for an ID Hardcover can't
    /// have.
    static func bookURL(_ id: Int) -> URL? {
        id > 0 ? URL(string: "https://hardcover.app/id/books/\(id)") : nil
    }

    /// The text the share sheet sends with a **My reading** image: a line with each book's title
    /// and permanent page when the image draws at most `linkedBooks`, then the sharer's profile
    /// link when `username` is known. `nil` when there is neither.
    static func readingText(books: [CloudBook], username: String?) -> String? {
        var lines =
            books.count <= linkedBooks
            ? books.compactMap { book in
                bookURL(book.id).map { "\(book.title): \($0.absoluteString)" }
            } : []
        if let profile = username.flatMap(profileURL) {
            lines.append("My reading on Hardcover: \(profile.absoluteString)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Why a reader looked up by username cannot be compared.
enum ReaderLookupError: LocalizedError, Equatable {
    case invalidUsername
    case notFound(String)
    case blocked(String)
    case yourself
    case noRatings(String)

    var errorDescription: String? {
        switch self {
        case .invalidUsername:
            "Enter a Hardcover username, such as @bookworm."
        case .notFound(let username):
            "Hardcover has no public reader named @\(username). Check the spelling; private profiles can't be compared."
        case .blocked(let username):
            "You blocked @\(username) on Hardcover."
        case .yourself:
            "That's you. Choose someone else to compare with."
        case .noRatings(let username):
            "@\(username) has no ratings Bookworms can read. Their profile may be private."
        }
    }
}
