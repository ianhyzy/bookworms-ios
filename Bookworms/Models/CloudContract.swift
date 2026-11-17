import CryptoKit
import Foundation

enum CloudContract {
    static let containerID = "iCloud.gay.ian.Bookworms"
    static let worklistRecordName = "spine-worklist-v1"
    static let worklistSubscriptionID = "spine-worklist-v1-changes"
    static let libraryRecordName = "library-v1"
    /// Identifies designs from this app's current generator. Changing it replaces no saved
    /// design: a run keeps a design that its model tier doesn't outrank whatever generator
    /// made it, such as this app's earlier `ios-pcc-v1` or the Mac companion's
    /// `macGeneratorVersion` (`SpineDesignV1.tier`, `SpineDesignV1.action`).
    static let generatorVersion = "ios-pcc-v2"
    /// The last generator of the retired Bookworms Spines Mac companion, which, like its earlier
    /// `mac-foundation-models-v1`, designed with Apple's on-device model and recorded no model
    /// token.
    static let macGeneratorVersion = "mac-foundation-models-v2"
    /// The `SeriesLookV1.origin` of the Apple TV's own looks, which it makes without a model from
    /// a cover's colors and the book's genres.
    static let appleTVGeneratorVersion = "tvos-local-v1"

    static func designRecordName(accountID: String, bookID: Int) -> String {
        "spine-design-v1-" + digest("\(accountID):\(bookID)")
    }

    static func designClaimRecordName(accountID: String, bookID: Int) -> String {
        "spine-claim-v1-" + digest("\(accountID):\(bookID)")
    }

    static func coverChoiceRecordName(accountID: String, bookID: Int) -> String {
        "cover-choice-v1-" + digest("\(accountID):\(bookID)")
    }

    static func seriesLookRecordName(accountID: String, key: SeriesLookKey) -> String {
        "series-look-v1-" + digest("\(accountID):\(key.seriesID):\(key.group)")
    }

    static func seriesLinkRecordName(accountID: String, bookID: Int) -> String {
        "series-link-v1-" + digest("\(accountID):\(bookID)")
    }

    static func topFivePinsRecordName(accountID: String) -> String {
        "top-five-pins-v1-" + digest(accountID)
    }

    static func workItemHash(accountID: String, book: CloudBook) -> String {
        digest(
            accountID + "\n" + String(book.id) + "\n" + book.title + "\n" + book.author
                + "\n" + (book.detailCoverURL?.absoluteString ?? "") + "\n"
                + (book.coverURL?.absoluteString ?? ""))
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether two snapshot sync dates name the same sync: they match within a millisecond.
    static func isSameSync(_ date: Date, _ other: Date) -> Bool {
        abs(date.timeIntervalSince(other)) < 0.001
    }

    /// Whether the sync at `date` is newer than the sync at `other`, beyond the millisecond
    /// that `isSameSync(_:_:)` allows.
    static func isNewerSync(_ date: Date, than other: Date) -> Bool {
        date.timeIntervalSince(other) >= 0.001
    }
}

struct SpineWorklistV1: Codable, Sendable {
    let version: Int
    let accountID: String
    let syncedAt: Date
    let bookIDs: [Int]

    /// Throws `CompanionError.unsupportedCloudData` for another contract version, as the archive
    /// does, and `CompanionError.invalidCloudData` for an invalid worklist.
    func validate() throws {
        guard version == 1 else { throw CompanionError.unsupportedCloudData }
        guard !accountID.isEmpty, accountID.count <= 512,
            syncedAt.timeIntervalSince1970.isFinite,
            bookIDs.allSatisfy({ $0 > 0 }),
            bookIDs == Array(Set(bookIDs)).sorted()
        else { throw CompanionError.invalidCloudData }
    }
}

struct CloudLibraryArchive: Decodable, Sendable {
    let version: Int
    let sources: [CloudSourceSnapshot]
    /// Maps each Hardcover account that a reader merged into another to that account, as
    /// **Merge** records it (`recording(merges:into:)`). Absent until the first merge. Devices
    /// ignore a merged account's snapshot and records
    /// (`check(worklist:signedInAccountID:chosenAccountID:)`).
    var merges: [String: String]? = nil

    /// Returns the Hardcover snapshot the companion works on, with the books it should design,
    /// and whether the worklist chose them.
    ///
    /// With `accountID`, only that account's snapshots count, and a worklist of another account
    /// counts as none. Without it, the snapshots of merged accounts don't count, unless every
    /// real account was merged (`libraryIDs`).
    ///
    /// With a worklist, the Apple TV chose the account and books: the snapshot must have the
    /// worklist's account and sync date, or the library is still uploading. A newer snapshot of
    /// that account, such as an iPhone's download spliced over the Apple TV's
    /// (`splice(_:into:)`), stands until the Apple TV syncs again, so the companion designs
    /// every book of it, and the worklist doesn't choose them. Without a worklist, the newest
    /// Hardcover snapshot wins, preferring a real account ID over the legacy `"hardcover"`
    /// placeholder, and every book is listed. An archive with no Hardcover snapshot, such as
    /// from a CWA-only Apple TV, throws `CompanionError.noHardcoverLibrary`.
    func workSource(for worklist: SpineWorklistV1?, accountID: String?) throws -> (
        snapshot: CloudSourceSnapshot, books: [CloudBook], followsWorklist: Bool
    ) {
        var hardcover = sources.filter { $0.source == "hardcover" }
        var worklist = worklist
        if let accountID {
            hardcover = hardcover.filter { $0.accountID == accountID }
            if worklist?.accountID != accountID { worklist = nil }
        } else {
            let libraries = libraryIDs
            hardcover = hardcover.filter {
                $0.accountID == "hardcover" || libraries.contains($0.accountID)
            }
        }
        if let worklist {
            guard
                let source =
                    hardcover
                    .filter({ $0.accountID == worklist.accountID })
                    .max(by: { $0.syncedAt < $1.syncedAt })
            else { throw CompanionError.waitingForLibrary }
            if CloudContract.isNewerSync(source.syncedAt, than: worklist.syncedAt) {
                return (source, Self.distinct(source.books), false)
            }
            guard CloudContract.isSameSync(source.syncedAt, worklist.syncedAt) else {
                throw CompanionError.waitingForLibrary
            }
            return (source, try source.selectedBooks(in: worklist), true)
        }
        guard !hardcover.isEmpty else { throw CompanionError.noHardcoverLibrary }
        let accounts = hardcover.filter { $0.accountID != "hardcover" }
        guard
            let source = (accounts.isEmpty ? hardcover : accounts)
                .max(by: { $0.syncedAt < $1.syncedAt })
        else { throw CompanionError.waitingForLibrary }
        return (source, Self.distinct(source.books), false)
    }

    /// `books` with a valid ID, each book once.
    private static func distinct(_ books: [CloudBook]) -> [CloudBook] {
        var seen = Set<Int>()
        return books.filter { $0.id > 0 && seen.insert($0.id).inserted }
    }

    /// Returns the newest Hardcover snapshot of `accountID`, or `nil` when the archive holds
    /// none.
    func newestHardcoverSnapshot(accountID: String) -> CloudSourceSnapshot? {
        sources.filter { $0.source == "hardcover" && $0.accountID == accountID }
            .max { $0.syncedAt < $1.syncedAt }
    }
}

/// A Hardcover account with Bookworms data in iCloud.
struct CloudAccount: Equatable, Sendable, Identifiable {
    let id: String
    let username: String?
    /// Book IDs from the account's newest snapshot, plus the worklist's when it names the account.
    let bookIDs: Set<Int>
    /// The newest snapshot's sync date, or the worklist's.
    let syncedAt: Date
    var name: String { username.map { "@\($0)" } ?? "account \(id)" }
}

/// Whether a device may use iCloud, and for which account (`CloudLibraryArchive.check`).
enum CloudAccountCheck: Equatable, Sendable {
    /// iCloud may be used for `accountID`; `nil` when iCloud holds no library yet.
    case clear(accountID: String?)
    /// iCloud holds data from these accounts, which the signed-in account hasn't merged.
    case otherAccounts([CloudAccount])
    /// A device without a Hardcover sign-in found these libraries and no remembered choice.
    case chooseLibrary([CloudAccount])
    /// The reader turned iCloud storage off on this device (`CloudStorage.isOff`).
    case off
}

extension CloudLibraryArchive {
    /// The real accounts whose library a device without a sign-in may show: each account with a
    /// Hardcover snapshot and no `merges` entry. When every such account has an entry, every
    /// account with a snapshot: merges form a cycle, or an account merged into has no snapshot
    /// yet, such as when **Merge**'s upload of its library failed.
    var libraryIDs: Set<String> {
        let withSnapshot = Set(
            sources.filter { $0.source == "hardcover" && $0.accountID != "hardcover" }
                .map(\.accountID))
        let libraries = withSnapshot.filter { merges?[$0] == nil }
        return libraries.isEmpty ? withSnapshot : libraries
    }

    /// Whether `merges` leads from `account` to `target`, or `account` is `target`. Follows one
    /// entry per step and stops at an account that repeats or has no entry.
    static func absorbs(_ account: String, _ merges: [String: String], into target: String)
        -> Bool
    {
        var current = account
        var seen: Set<String> = []
        while current != target {
            guard seen.insert(current).inserted, let next = merges[current] else { return false }
            current = next
        }
        return true
    }

    /// Checks whether a device may use iCloud with this archive and `worklist`.
    ///
    /// Signed in to `signedInAccountID`, iCloud is clear unless a real account that isn't
    /// absorbed into it has a snapshot or names the worklist. Without a sign-in, iCloud is clear
    /// for the only library, or for `chosenAccountID` when it is one of several; otherwise the
    /// reader chooses. The legacy `"hardcover"` placeholder never counts as an account.
    func check(worklist: SpineWorklistV1?, signedInAccountID: String?, chosenAccountID: String?)
        -> CloudAccountCheck
    {
        let snapshots = sources.filter { $0.source == "hardcover" && $0.accountID != "hardcover" }
        func account(_ id: String) -> CloudAccount {
            let own = snapshots.filter { $0.accountID == id }.sorted { $0.syncedAt > $1.syncedAt }
            let listed = worklist?.accountID == id ? worklist : nil
            return CloudAccount(
                id: id, username: own.lazy.compactMap(\.username).first,
                bookIDs: Set(own.first?.books.map(\.id) ?? []).union(listed?.bookIDs ?? []),
                syncedAt: own.first?.syncedAt ?? listed?.syncedAt ?? .distantPast)
        }
        if let signedInAccountID {
            var ids = Set(snapshots.map(\.accountID))
            if let listed = worklist?.accountID, listed != "hardcover" { ids.insert(listed) }
            let others = ids.filter { !Self.absorbs($0, merges ?? [:], into: signedInAccountID) }
            return others.isEmpty
                ? .clear(accountID: signedInAccountID)
                : .otherAccounts(others.sorted().map(account))
        }
        let libraries = libraryIDs.sorted()
        guard libraries.count > 1 else { return .clear(accountID: libraries.first) }
        if let chosenAccountID, libraries.contains(chosenAccountID) {
            return .clear(accountID: chosenAccountID)
        }
        return .chooseLibrary(libraries.map(account))
    }
}

extension CloudLibraryArchive {
    /// Returns the archive JSON `stored` with `snapshot` as the entry for its source and account,
    /// or `nil` when the stored entry is as new or newer.
    ///
    /// The splice edits the JSON, so it keeps every other key, snapshot, and design, including
    /// fields this app doesn't decode. It replaces the newest entry for `snapshot`'s source and
    /// account only when `snapshot` is strictly newer than every such entry, and appends an entry
    /// when there is none.
    /// It never removes an entry, and it sorts entries as the Apple TV does. A snapshot without
    /// `series` or `username` keeps the stored entry's. Books leave out `chosenCoverURL` and
    /// `seriesLink`, which the archive never carries. When `stored` is `nil`, the splice starts
    /// an archive with `version` 1 and empty `designs`, which the Apple TV requires.
    ///
    /// - Throws: `CompanionError.unsupportedCloudData` when `stored` has a version other than 1,
    ///   and `CompanionError.invalidCloudData` when it is not an archive.
    static func splice(_ snapshot: CloudSourceSnapshot, into stored: Data?) throws -> Data? {
        var archive = try object(stored)
        guard var sources = (archive["sources"] ?? [Any]()) as? [[String: Any]] else {
            throw CompanionError.invalidCloudData
        }
        let written = CloudSourceSnapshot(
            source: snapshot.source, accountID: snapshot.accountID,
            books: snapshot.books.map { book in
                var book = book
                book.chosenCoverURL = nil
                book.seriesLink = nil
                return book
            },
            syncedAt: snapshot.syncedAt, series: snapshot.series, username: snapshot.username)
        guard
            var entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(written))
                as? [String: Any]
        else { throw CompanionError.invalidCloudData }
        func key(_ entry: [String: Any]) -> String {
            (entry["source"] as? String ?? "") + (entry["accountID"] as? String ?? "")
        }
        // The Apple TV keeps one entry per source and account, but a duplicate from any writer is
        // compared too, so an older snapshot never replaces a newer stored copy.
        var newest: (index: Int, date: Date)?
        for (index, stored) in sources.enumerated()
        where stored["source"] as? String == snapshot.source
            && stored["accountID"] as? String == snapshot.accountID
        {
            // A date the default decoder can't read means another writer's format; replacing the
            // entry could discard a newer copy, so the write stops instead.
            guard let seconds = stored["syncedAt"] as? Double else {
                throw CompanionError.invalidCloudData
            }
            let date = Date(timeIntervalSinceReferenceDate: seconds)
            if newest.map({ date > $0.date }) ?? true { newest = (index, date) }
        }
        if let newest {
            if newest.date >= snapshot.syncedAt { return nil }
            let index = newest.index
            let existing = sources[index]
            if entry["series"] == nil { entry["series"] = existing["series"] }
            if entry["username"] == nil { entry["username"] = existing["username"] }
            entry["books"] = keepingAppleTVFields(of: entry["books"], from: existing["books"])
            sources[index] = entry
        } else {
            entry["books"] = keepingAppleTVFields(of: entry["books"], from: nil)
            sources.append(entry)
        }
        sources.sort { key($0) < key($1) }
        archive["sources"] = sources
        return try encoded(archive)
    }

    /// Returns the archive JSON `stored` with each entry of `merges` that its `merges` lacks, or
    /// `nil` when it lacks none. A stored entry stays, even when `merges` maps its account
    /// elsewhere, and no entry is removed. Like `splice(_:into:)`, it keeps every other key,
    /// starts an archive when `stored` is `nil`, and throws the same errors.
    static func recording(merges: [String: String], into stored: Data?) throws -> Data? {
        var archive = try object(stored)
        guard var recorded = (archive["merges"] ?? [String: Any]()) as? [String: Any] else {
            throw CompanionError.invalidCloudData
        }
        let added = merges.filter { recorded[$0.key] == nil }
        guard !added.isEmpty else { return nil }
        recorded.merge(added) { stored, _ in stored }
        archive["merges"] = recorded
        if archive["sources"] == nil { archive["sources"] = [Any]() }
        return try encoded(archive)
    }

    /// The archive JSON `stored` as an object, or an empty one when `stored` is `nil`.
    private static func object(_ stored: Data?) throws -> [String: Any] {
        guard let stored else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: stored) as? [String: Any]
        else { throw CompanionError.invalidCloudData }
        if let version = object["version"], version as? Int != 1 {
            throw CompanionError.unsupportedCloudData
        }
        return object
    }

    /// `archive` as JSON with sorted keys, with `version` 1 and the `designs` the Apple TV
    /// requires.
    private static func encoded(_ archive: [String: Any]) throws -> Data {
        var archive = archive
        archive["version"] = 1
        if archive["designs"] == nil { archive["designs"] = [String: Any]() }
        return try JSONSerialization.data(withJSONObject: archive, options: .sortedKeys)
    }

    /// `books` with the two book fields only the Apple TV stores: `sources`, which is always
    /// Hardcover for a Hardcover snapshot, and `isOwned`, kept from the same book in `stored`.
    private static func keepingAppleTVFields(of books: Any?, from stored: Any?) -> Any? {
        guard let books = books as? [[String: Any]] else { return books }
        var owned: [Int: Any] = [:]
        for book in (stored as? [[String: Any]]) ?? [] {
            if let id = book["id"] as? Int, let isOwned = book["isOwned"], owned[id] == nil {
                owned[id] = isOwned
            }
        }
        return books.map { book in
            var book = book
            if book["sources"] == nil { book["sources"] = ["hardcover"] }
            if book["isOwned"] == nil, let id = book["id"] as? Int, let isOwned = owned[id] {
                book["isOwned"] = isOwned
            }
            return book
        }
    }
}

/// One source's books in the `library-v1` archive, such as one Hardcover account's library.
///
/// `source` is `"hardcover"` or `"cwa"`, and `syncedAt` is when the writer's download finished,
/// in `JSONEncoder`'s default date encoding. This app writes only Hardcover snapshots
/// (`CloudLibraryArchive.splice(_:into:)`).
struct CloudSourceSnapshot: Codable, Sendable {
    let source: String
    let accountID: String
    let books: [CloudBook]
    let syncedAt: Date
    /// The series of a Hardcover snapshot's books, which the Apple TV shows in book details.
    /// Snapshots saved before series were fetched, and CWA snapshots, leave it out.
    var series: [SeriesInfo]? = nil
    /// The account's Hardcover username, which names the account when iCloud holds another
    /// account's data (`CloudAccount.name`). Snapshots saved before usernames were kept leave it
    /// out.
    var username: String? = nil

    func selectedBooks(in worklist: SpineWorklistV1) throws -> [CloudBook] {
        let included = Set(worklist.bookIDs)
        var seen = Set<Int>()
        let selected = books.filter { included.contains($0.id) && seen.insert($0.id).inserted }
        guard selected.count == included.count else { throw CompanionError.waitingForLibrary }
        return selected
    }
}

extension CloudSourceSnapshot {
    /// The Hardcover snapshot of a library this device downloaded.
    init(_ library: PhoneLibrary) {
        self.init(
            source: "hardcover", accountID: library.accountID, books: library.books,
            syncedAt: library.syncedAt, series: library.series, username: library.username)
    }
}

/// A book in a `library-v1` archive snapshot.
///
/// The Apple TV encodes its full `Book`; this type decodes the fields the companion uses and
/// ignores the rest, and the snapshots this app writes carry only these fields. Optional reading
/// fields are absent from older archives.
struct CloudBook: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    var title: String
    let author: String
    let coverURL: URL?
    let detailCoverURL: URL?
    var genres: [String]? = nil
    var publicationYear: Int? = nil
    var format: String? = nil
    /// The format of the reader's Hardcover edition as Hardcover records it
    /// (`editions.edition_format`), such as "Hardcover" or "Mass Market Paperback": the first of
    /// the newest finished read's edition and the library entry's edition that names a hardcover
    /// or paperback, else the edition that `format` and `pages` describe. It is `nil` without an
    /// edition, and caches, archives, and Apple TV builds that predate it leave it out until the
    /// next download.
    var editionFormat: String? = nil
    var seriesID: Int? = nil
    var seriesPosition: Double? = nil
    /// The name of the `seriesID` series, from the iPhone's own Hardcover download or the Apple
    /// TV archive. An archive the Apple TV saved before it fetched series names leaves it out
    /// until the TV syncs again.
    var seriesName: String? = nil
    /// Every Hardcover series the book belongs to, which decide its series look
    /// (`SeriesDesigns.styleSeries(of:link:)`). Archives and caches saved before memberships
    /// existed leave it out; such a book's look follows `seriesID`.
    var seriesMemberships: [SeriesMembership]? = nil
    var pages: Int? = nil
    /// The finish date as `yyyy-MM-dd`: the newest finish, the first of `finishedDates`.
    var finished: String? = nil
    /// Every finished read's date, newest first, in the format of `finished`. Archives and
    /// caches saved before rereads were fetched leave it out, and then `finished` is the only
    /// read known; an empty list means the same.
    var finishedDates: [String]? = nil
    /// The reader's rating, 0...5 in half steps.
    var rating: Double? = nil
    var isReading: Bool? = nil
    /// Whether the book is on the reader's **Read** shelf, even without a finish date. The Apple
    /// TV archive carries it; older archives leave it out, and then a finish date alone marks a
    /// read book (`hasBeenRead`).
    var isRead: Bool? = nil
    /// Hardcover's shelf for the book (`user_books.status_id`), such as
    /// `HardcoverClient.wantToReadStatus`. Archives and caches saved before statuses were kept
    /// leave it out, and so do Apple TV builds that don't download it.
    var statusID: Int? = nil
    /// The day the reader shelved a book as **Did Not Finish**, as `yyyy-MM-dd`: the day its
    /// Hardcover entry was last edited when a sync first finds it on that shelf, kept by later
    /// syncs while it stays there. It is `nil` for other shelves.
    var dropped: String? = nil
    /// Reading progress, 0...1, for current reads.
    var progress: Double? = nil
    /// The start date of a current read as `yyyy-MM-dd`.
    var started: String? = nil
    var audioSeconds: Int? = nil
    /// Hardcover's average rating from all readers, and how many ratings it averages.
    var communityRating: Double? = nil
    var ratingsCount: Int? = nil
    /// How many readers gave each rating, in half-star steps.
    var ratingDistribution: [RatingBucket]? = nil
    /// The book's description as its source stores it, which can carry HTML or Markdown.
    var description: String? = nil
    /// The reader's own review as plain text (`HardcoverClient.plainText(from:)`). Snapshots
    /// that Apple TV builds without reviews saved leave it out.
    var review: String? = nil
    /// The cover the reader chose (`CoverChoiceV1`), which neither the archive nor
    /// `workItemHash` includes, so designs keep matching the Apple TV's hash.
    var chosenCoverURL: URL? = nil
    /// The reader's series choice for the book (`SeriesLinkV1`), which, like `chosenCoverURL`,
    /// neither the archive nor `workItemHash` includes.
    var seriesLink: SeriesLinkV1? = nil

    /// The covers to try in order: the reader's choice, then the default covers.
    var coverCandidates: [URL] {
        var urls: [URL] = []
        for url in [chosenCoverURL, detailCoverURL, coverURL].compactMap(\.self)
        where !urls.contains(url) {
            urls.append(url)
        }
        return urls
    }

    /// The first default cover candidate, which a sync changes only to swap in a sharper cover
    /// (`HardcoverClient.coverURLs(edition:book:otherEditions:editionIsInLanguage:previous:)`).
    var defaultCover: URL? { detailCoverURL ?? coverURL }

    /// The title without a subtitle, as spines letter it: the text before the first colon,
    /// trimmed, or the whole title when nothing comes before the colon. The Apple TV's
    /// `Book.spineTitle` uses the same rule.
    var spineTitle: String {
        guard let colon = title.firstIndex(of: ":") else { return title }
        let head = title[..<colon].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? title : head
    }

    /// The finish date, parsed from `finished` at noon UTC so it lands on the same calendar day.
    var finishedDate: Date? { Self.day(finished) }

    /// Every finish date as stored, newest first: `finishedDates`, else `finished` alone. An
    /// empty `finishedDates` counts as absent, so a book with `finished` always has a finish.
    var finishes: [String] {
        if let finishedDates, !finishedDates.isEmpty { return finishedDates }
        return finished.map { [$0] } ?? []
    }

    /// How many times the reader finished the book.
    var readCount: Int { finishes.count }

    /// The first valid finish as stored. Unlike `finished`, which a time frame sets to the read
    /// within it, no frame changes it, so a book keeps its shape and page color in every frame.
    var firstFinish: String? { finishes.filter { Self.day($0) != nil }.min() }

    /// The book as of its newest finish that `isIncluded` accepts, with `finished` set to that
    /// finish, or `nil` when it accepts none. A time frame shows a reread by its read within the
    /// frame, so its order and labels use that read. The copy is for display only: its
    /// `finished` may no longer equal `finishedDates.first`, so never save or upload it.
    func asFinished(where isIncluded: (Date) -> Bool) -> CloudBook? {
        guard let finish = finishes.filter({ Self.day($0).map(isIncluded) == true }).max() else {
            return nil
        }
        var book = self
        book.finished = finish
        return book
    }

    /// The books of `library` with a finish that `isIncluded` accepts, each as of its newest
    /// such finish (`asFinished(where:)`), most recently finished first. Ties keep `library`'s
    /// order.
    static func finished(in library: [CloudBook], where isIncluded: (Date) -> Bool)
        -> [CloudBook]
    {
        library.compactMap { $0.asFinished(where: isIncluded) }
            .sorted { ($0.finished ?? "") > ($1.finished ?? "") }
    }

    /// A `yyyy-MM-dd`-prefixed date at noon UTC, or `nil` when it isn't one.
    static func day(_ text: String?) -> Date? {
        guard let text, text.count >= 10 else { return nil }
        return try? Date(String(text.prefix(10)) + "T12:00:00Z", strategy: .iso8601)
    }
}

/// A Hardcover series and its main books in reading order, as a Hardcover snapshot's `series`
/// in the `library-v1` archive. The shape matches the Apple TV's `SeriesInfo`, so a snapshot
/// this app writes keeps the series the TV shows in book details.
struct SeriesInfo: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    /// The series' main books, one per whole-number position, earliest first.
    let books: [SeriesBook]

    struct SeriesBook: Codable, Hashable, Sendable, Identifiable {
        let id: Int
        let title: String
        let position: Double
        let releaseYear: Int?
        let coverURL: URL?
    }
}

/// One Hardcover series that a book belongs to, as the `seriesMemberships` of a book in the Apple
/// TV archive and in this app's caches.
///
/// `size` is the series' count of primary books, else of all its books, and is absent when
/// Hardcover gives neither. `position` is the book's place in the series, when it has one.
struct SeriesMembership: Codable, Sendable, Hashable {
    let seriesID: Int
    let name: String
    var position: Double? = nil
    let featured: Bool
    let compilation: Bool
    var size: Int? = nil
}

/// The number of Hardcover readers who gave a book one rating, such as 4.5.
struct RatingBucket: Codable, Sendable, Hashable {
    let rating: Double
    let count: Int
}

/// How a design chose its font: the model's reading of the cover's title lettering, before the
/// measurements check it (`BookAnalyzer.CoverReading`), the title line it measured, and the
/// families it tried. Designs save it so their choices can be reviewed, and the font picker
/// lists its `candidates` first (`AppModel.fontChoices(for:)`); generation and the series rules
/// never read it, and the Apple TV ignores it. Answers are `nil` or empty without a reading.
struct SpineChoice: Codable, Sendable, Hashable {
    /// The OCR text of the measured title line, or `nil` when no line was measured.
    var titleLine: String? = nil
    /// The title as the model read it from the lettering.
    var titleText: String? = nil
    var titleCase: String? = nil
    /// How the title letters were made, such as "typeset font".
    var making: String? = nil
    /// The lettering's Google Fonts category and subclass, such as "serif" and
    /// "Serif / Didone".
    var category: String? = nil
    var subclass: String? = nil
    /// At most two Google Fonts themes, such as "Art Deco", and three moods. Records saved
    /// before these answers existed have neither.
    var themes: [String]? = nil
    var moods: [String]? = nil
    var weight: String? = nil
    var width: String? = nil
    /// The model's one-sentence note about the lettering.
    var note: String? = nil
    /// The families the design tried, best match first: at most six.
    var candidates: [String] = []
}

struct SpineDesignV1: Codable, Sendable, Hashable {
    let version: Int
    let accountID: String
    let bookID: Int
    let workItemHash: String
    let coverHash: String
    let generatorVersion: String
    let generatedAt: Date
    let backgroundHex: String
    let foregroundHex: String
    let accentHex: String
    /// The system typeface that stands in for the font: "serif", "sans", "rounded", or
    /// "monospaced".
    var typeface: String
    /// The requested title weight: 400, 500, 600, or 700.
    let weight: Int
    let uppercase: Bool
    /// The Google Fonts family name, such as "EB Garamond". `typeface` is the fallback.
    var fontFamily: String? = nil
    /// The PostScript name of the `fontFamily` instance closest to `weight`.
    var fontPostScriptName: String? = nil
    /// The weight of the `fontPostScriptName` instance (100...900), which can differ from
    /// `weight` when the family lacks that weight.
    var instanceWeight: Int? = nil
    /// How the design was made, in space-separated tokens such as "model:apple/on-device" or
    /// "series-reuse:12". The model token names the design's tier (`SpineDesignV1.tier`);
    /// Private Cloud Compute's designs record none.
    var provenance: String? = nil
    /// What the model read on the cover and which families the design tried (`SpineChoice`).
    /// Records saved before it have none, and neither do series copies or designs drawn from a
    /// series look.
    var choice: SpineChoice? = nil

    func validate() throws {
        guard version == 1, !accountID.isEmpty, bookID > 0,
            Self.isLowercaseHash(workItemHash), Self.isLowercaseHash(coverHash),
            !generatorVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            generatedAt.timeIntervalSince1970.isFinite,
            ["serif", "sans", "rounded", "monospaced"].contains(typeface),
            [400, 500, 600, 700].contains(weight),
            instanceWeight.map({ (100...900).contains($0) && $0.isMultiple(of: 100) }) ?? true,
            [fontFamily, fontPostScriptName, provenance].allSatisfy(Self.isShortLine),
            choice.map({
                [
                    $0.titleLine, $0.titleText, $0.titleCase, $0.making, $0.category, $0.subclass,
                    $0.weight, $0.width, $0.note,
                ]
                .allSatisfy(Self.isShortLine)
                    && ($0.themes ?? []).count <= 2 && ($0.moods ?? []).count <= 3
                    && $0.candidates.count <= 6
                    && (($0.themes ?? []) + ($0.moods ?? []) + $0.candidates)
                        .allSatisfy(
                            Self.isShortLine)
            }) ?? true,
            [backgroundHex, foregroundHex, accentHex].allSatisfy(ColorValue.isValidHex),
            let background = ColorValue(hex: backgroundHex),
            let foreground = ColorValue(hex: foregroundHex),
            background.contrast(with: foreground) >= 4.5
        else { throw CompanionError.invalidDesign }
    }

    private static func isShortLine(_ value: String?) -> Bool {
        guard let value else { return true }
        return (1...80).contains(value.count) && !value.contains(where: \.isNewline)
    }

    private static func isLowercaseHash(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }
}

/// One device's claim on a book that it asks a model to design, so that two of the reader's
/// devices that run at the same time don't spend a request each on the same book.
///
/// A `SpineClaimV1` record in the private database's default zone, named by
/// `CloudContract.designClaimRecordName(accountID:bookID:)`, holds this JSON in its `payload`
/// Bytes field. `claimedAt` uses `JSONEncoder`'s default date encoding (seconds since 2001). Only
/// the iPhone and Mac app reads or writes it, and nothing deletes it: the book's next claim
/// saves over it. A claim decides nothing about which design a book keeps: the design save's
/// own rule does (`SpineDesignV1.outlasts(_:replacing:)`).
struct SpineClaimV1: Codable, Sendable, Equatable {
    /// How long a claim holds a book: longer than a design usually takes, so the claim still
    /// holds when the design is saved and another device's check reads it, and short enough
    /// that a book whose design failed soon goes to another device. A design that takes longer,
    /// such as a backup model's two slow requests, may get a second request from that device.
    static let lifetime: TimeInterval = 10 * 60

    var version = 1
    /// The install that holds the claim (`CloudSpineStore.claimDeviceID`).
    var deviceID: String
    /// The claiming device's clock, which the checking device compares with its own. A clock
    /// that is wrong by minutes ends a claim early, or holds another device's failed book that
    /// much longer.
    var claimedAt: Date

    /// Whether `deviceID` must leave the book to the claim's device at `now`. The device's own
    /// claim, such as one from a run that iOS ended, never holds it back, and neither does a
    /// claim of another contract version.
    func holds(against deviceID: String, now: Date) -> Bool {
        version == 1 && self.deviceID != deviceID
            && now.timeIntervalSince(claimedAt) < Self.lifetime
    }
}

/// The reader's choice of cover for one book, shared through iCloud so every device shows it.
///
/// A `CoverChoiceV1` record in the private database's default zone, named by
/// `CloudContract.coverChoiceRecordName(accountID:bookID:)`, holds this JSON in its `payload`
/// Bytes field. `chosenAt` uses `JSONEncoder`'s default date encoding (seconds since 2001), and
/// `editionID` is absent when the cover belongs to no Hardcover edition. Choosing the default
/// cover deletes the record. Readers ignore a record that fails `validate()` or names another
/// account or book than its record name.
struct CoverChoiceV1: Codable, Sendable, Hashable {
    let version: Int
    let accountID: String
    let bookID: Int
    let coverURL: URL
    let editionID: Int?
    let chosenAt: Date

    func validate() throws {
        guard version == 1, !accountID.isEmpty, accountID.count <= 512, bookID > 0,
            CoverURLPolicy.allows(coverURL), editionID.map({ $0 > 0 }) ?? true,
            chosenAt.timeIntervalSince1970.isFinite
        else { throw CompanionError.invalidCloudData }
    }

    /// Returns `books` with each chosen cover set as `chosenCoverURL`. `choices` maps record
    /// names to payloads; only valid choices for `accountID` stored under their own record name
    /// count.
    static func apply(
        _ choices: [String: CoverChoiceV1], accountID: String, to books: [CloudBook]
    ) -> [CloudBook] {
        var covers: [Int: URL] = [:]
        for (name, choice) in choices
        where choice.accountID == accountID
            && name
                == CloudContract.coverChoiceRecordName(accountID: accountID, bookID: choice.bookID)
            && (try? choice.validate()) != nil
        {
            covers[choice.bookID] = choice.coverURL
        }
        return books.map { book in
            var book = book
            book.chosenCoverURL = covers[book.id]
            return book
        }
    }
}

/// The look that every book of one look group draws (`SeriesDesigns.lookKey(of:link:)`), shared
/// through iCloud so every device draws the same series alike.
///
/// A `SeriesLookV1` record in the private database's default zone, named by
/// `CloudContract.seriesLookRecordName(accountID:key:)`, holds this JSON in its `payload` Bytes
/// field, with dates in `JSONEncoder`'s default encoding. `origin` is the generator of the design
/// or look the record was made from, such as "ios-pcc-v2" or the Apple TV's "tvos-local-v1", and
/// `sourceBookID` is the book whose design or look it was made from. `provenance`, when present,
/// holds that design's tier tokens (`SpineDesignV1.tierTokens`) in looks this app makes, and a
/// model token in the Apple TV's: the model token gives the look's tier (`tier`), and the
/// system-font token marks a design that awaits its font.
///
/// The first look saved for a group decides it among equal tiers: devices create the record only
/// when it is missing (see `SpineStore.createLook(_:)`). A design from a better tier than a look
/// from local defaults or the on-device model, or from the look's tier when the look awaits its
/// font, replaces a look the reader never edited
/// (`isUpgraded(at:awaitingFont:)`, `SpineStore.upgradeLook(_:)`), keeping `createdAt` and setting
/// `remadeAt`. The reader's edits replace the colors or the font, or the whole look when the
/// reader asks to redesign the series, and set `editedAt`; a redesign also sets `remadeAt`, which
/// looks remade before the field existed lack. A font the reader chose also adds the
/// `SpineDesignV1.readerFontToken` to `provenance`, which no design drawn from the look copies.
/// Readers ignore a record that fails `validate()` or names another account or group than its
/// record name.
struct SeriesLookV1: Codable, Sendable, Hashable {
    /// The hash a look's design carries in place of a book's own work-item or cover hash.
    static let placeholderHash = String(repeating: "0", count: 64)

    let version: Int
    let accountID: String
    let seriesID: Int
    let group: String
    let sourceBookID: Int
    let origin: String
    let createdAt: Date
    var editedAt: Date? = nil
    var backgroundHex: String
    var foregroundHex: String
    var accentHex: String
    var typeface: String
    let weight: Int
    let uppercase: Bool
    var fontFamily: String? = nil
    var fontPostScriptName: String? = nil
    var instanceWeight: Int? = nil
    var provenance: String? = nil
    /// When a redesign or an upgrade last made the look again from a new design of a book in its
    /// group (`remade(from:at:)`, `upgraded(from:at:)`); absent until then and in older records.
    var remadeAt: Date? = nil

    var key: SeriesLookKey { SeriesLookKey(seriesID: seriesID, group: group) }

    /// Whether the reader chose the look's font
    /// (`refonted(family:postScriptName:instanceWeight:typeface:at:)`).
    var hasReaderFont: Bool {
        provenance?.split(separator: " ").contains { $0 == SpineDesignV1.readerFontToken }
            == true
    }

    /// The model tier that made the look (`SpineDesignV1.tier`): the tier its `provenance` names,
    /// or, without a model token, the tier its `origin` implies, such as local defaults for an
    /// Apple TV look.
    var tier: ModelTier { storedDesign(bookID: sourceBookID, hashesFrom: nil).tier }

    /// Whether the look stands in its system typeface for a font that couldn't download
    /// (`SpineDesignV1.awaitsFont`).
    var awaitsFont: Bool { storedDesign(bookID: sourceBookID, hashesFrom: nil).awaitsFont }

    /// Whether a design from `tier` replaces this look: the look's colors and font are the
    /// generator's, and the design outranks the look's own
    /// (`SpineDesignV1.isOutranked(by:awaitingFont:)`), because local defaults or the on-device
    /// model made the look and `tier` is better, or the look awaits a font that the design, unless
    /// `awaitingFont`, has. The reader's edits stay: an edited look, or one whose `provenance`
    /// carries a reader's token (`SpineDesignV1.hasReaderEdits`).
    func isUpgraded(at tier: ModelTier, awaitingFont: Bool = false) -> Bool {
        let design = storedDesign(bookID: sourceBookID, hashesFrom: nil)
        return editedAt == nil && !design.hasReaderEdits
            && design.isOutranked(by: tier, awaitingFont: awaitingFont)
    }

    /// The book among `members`, the look group's books, whose design replaces the look when it
    /// is upgraded (`isUpgraded(at:awaitingFont:)`), or `nil` when no member has a cover: the
    /// look's source book while it is a member with a cover, otherwise the best-ranked member
    /// with one (`SeriesDesigns.ranksBefore(_:_:)`). An Apple TV look samples a cover instead of
    /// copying a design, so it always takes the best-ranked member.
    func upgradeSource(among members: [CloudBook]) -> Int? {
        let designable = members.filter { !$0.coverCandidates.isEmpty }
        if origin != CloudContract.appleTVGeneratorVersion,
            designable.contains(where: { $0.id == sourceBookID })
        {
            return sourceBookID
        }
        return designable.min(by: SeriesDesigns.ranksBefore)?.id
    }

    /// Checks the record's own fields, then the design rules for colors and type that
    /// `SpineDesignV1.validate()` applies to the look's design.
    func validate() throws {
        guard version == 1, !accountID.isEmpty, accountID.count <= 512, seriesID > 0,
            sourceBookID > 0, group.count <= 200,
            !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, origin.count <= 80,
            !origin.contains(where: \.isNewline),
            createdAt.timeIntervalSince1970.isFinite,
            editedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
            remadeAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw CompanionError.invalidCloudData }
        try storedDesign(bookID: sourceBookID, hashesFrom: nil).validate()
    }

    /// The look as a design of the book `bookID`, which draws and series reuse treat like a saved
    /// design: the look's colors and type in an allowed upright face
    /// (`SpineDesignV1.withAllowedFont`), `origin` as the generator, the tier tokens of
    /// `provenance` alone (`SpineDesignV1.tierTokens`), and the last edit or creation as the
    /// design date. The work-item and cover hashes come from `saved`, the book's own saved
    /// design, or are `placeholderHash`. Dropping the other tokens, which any device may have
    /// copied from a design, keeps a copy of the look in the look's own colors.
    func design(bookID: Int, hashesFrom saved: SpineDesignV1? = nil) -> SpineDesignV1 {
        var design = storedDesign(bookID: bookID, hashesFrom: saved).withAllowedFont
        let tokens = (provenance?.split(separator: " ") ?? [])
            .filter { $0.hasPrefix("model:") || $0 == SpineDesignV1.systemFontToken }
        design.provenance = tokens.isEmpty ? nil : tokens.joined(separator: " ")
        return design
    }

    /// `design(bookID:hashesFrom:)` with the stored font, which validation checks.
    private func storedDesign(bookID: Int, hashesFrom saved: SpineDesignV1?) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: accountID, bookID: bookID,
            workItemHash: saved?.workItemHash ?? Self.placeholderHash,
            coverHash: saved?.coverHash ?? Self.placeholderHash, generatorVersion: origin,
            generatedAt: editedAt ?? createdAt, backgroundHex: backgroundHex,
            foregroundHex: foregroundHex, accentHex: accentHex, typeface: typeface, weight: weight,
            uppercase: uppercase, fontFamily: fontFamily, fontPostScriptName: fontPostScriptName,
            instanceWeight: instanceWeight, provenance: provenance)
    }

    /// Returns the look with `colors`, edited at `date`.
    func recolored(_ colors: SpineColors, at date: Date) -> SeriesLookV1 {
        var look = self
        look.backgroundHex = colors.background.hex
        look.foregroundHex = colors.foreground.hex
        look.accentHex = colors.accent.hex
        look.editedAt = date
        return look
    }

    /// Returns the look set in `family`, the reader's choice, edited at `date`: its instance
    /// `postScriptName`, which weighs `instanceWeight`, with `typeface` as its system stand-in.
    /// Its provenance gains the reader's font token and loses the system-font token, as a
    /// design's does (`SpineDesignV1.refonted(family:postScriptName:instanceWeight:typeface:)`).
    func refonted(
        family: String, postScriptName: String?, instanceWeight: Int?, typeface: String,
        at date: Date
    ) -> SeriesLookV1 {
        var look = self
        look.fontFamily = family
        look.fontPostScriptName = postScriptName
        look.instanceWeight = instanceWeight
        look.typeface = typeface
        look.provenance = SpineDesignV1.readerFontProvenance(provenance)
        look.editedAt = date
        return look
    }

    /// Returns the look made again from `design`, a new design of one of its books, at `date`:
    /// `design`'s colors and type, book, generator, and model token, with the look's creation
    /// date, edited and remade at `date`. A `design` that awaits its font (`awaitsFont`) leaves
    /// the look unedited, so a later run that reaches the font still upgrades it
    /// (`isUpgraded(at:awaitingFont:)`).
    func remade(from design: SpineDesignV1, at date: Date) -> SeriesLookV1 {
        var look = upgraded(from: design, at: date)
        if !design.awaitsFont { look.editedAt = date }
        return look
    }

    /// Returns the look a better tier's `design` makes again at `date`, as `remade(from:at:)`
    /// does, but unedited, so a later upgrade may still replace it.
    func upgraded(from design: SpineDesignV1, at date: Date) -> SeriesLookV1 {
        var look = SeriesLookV1(design: design, key: key, createdAt: createdAt)
        look.remadeAt = date
        return look
    }

    /// Returns the valid looks for `accountID` among `looks`, which maps record names to
    /// payloads, keyed by look group. A look counts only under its own record name.
    static func keyed(_ looks: [String: SeriesLookV1], accountID: String)
        -> [SeriesLookKey: SeriesLookV1]
    {
        var keyed: [SeriesLookKey: SeriesLookV1] = [:]
        for (name, look) in looks
        where look.accountID == accountID
            && name == CloudContract.seriesLookRecordName(accountID: accountID, key: look.key)
            && (try? look.validate()) != nil
        {
            keyed[look.key] = look
        }
        return keyed
    }
}

/// The reader's edit of a series look: new colors or a new font. A save applies only the edit to
/// the look as iCloud holds it (`SpineStore.saveReaderEdit(_:at:to:)`), so another device's
/// edit of the other field stays, as with a design's edits (`SpineStore.saveRecolored(_:)`,
/// `SpineStore.saveRefonted(_:)`).
enum SeriesLookEdit: Hashable, Sendable {
    case colors(SpineColors)
    /// The family's instance `postScriptName`, which weighs `instanceWeight`, with `typeface` as
    /// its system stand-in.
    case font(family: String, postScriptName: String?, instanceWeight: Int?, typeface: String)

    /// Returns `look` with this edit, edited at `date`.
    func applied(to look: SeriesLookV1, at date: Date) -> SeriesLookV1 {
        switch self {
        case .colors(let colors):
            look.recolored(colors, at: date)
        case .font(let family, let postScriptName, let instanceWeight, let typeface):
            look.refonted(
                family: family, postScriptName: postScriptName, instanceWeight: instanceWeight,
                typeface: typeface, at: date)
        }
    }
}

extension SeriesLookV1 {
    /// A look for the group `key`, made from `design`'s colors and type, with `design`'s tier
    /// tokens (`SpineDesignV1.tierTokens`) as its `provenance`. The design's other tokens
    /// describe that book's design alone: a look copies no `series-reuse`, `generated-colors`, or
    /// `reader-font` token. A design the reader recolored or set in another font
    /// (`SpineDesignV1.hasReaderEdits`) gives the look the reader's colors and font, so the look
    /// counts as edited at `createdAt` and no upgrade replaces them
    /// (`isUpgraded(at:awaitingFont:)`).
    init(design: SpineDesignV1, key: SeriesLookKey, createdAt: Date) {
        self.init(
            version: 1, accountID: design.accountID, seriesID: key.seriesID, group: key.group,
            sourceBookID: design.bookID, origin: design.generatorVersion, createdAt: createdAt,
            editedAt: design.hasReaderEdits ? createdAt : nil,
            backgroundHex: design.backgroundHex, foregroundHex: design.foregroundHex,
            accentHex: design.accentHex, typeface: design.typeface, weight: design.weight,
            uppercase: design.uppercase, fontFamily: design.fontFamily,
            fontPostScriptName: design.fontPostScriptName, instanceWeight: design.instanceWeight,
            provenance: design.tierTokens.isEmpty ? nil : design.tierTokens.joined(separator: " "))
    }
}

/// The reader's series choice for one book, shared through iCloud so every device groups the book
/// the same way.
///
/// A `SeriesLinkV1` record in the private database's default zone, named by
/// `CloudContract.seriesLinkRecordName(accountID:bookID:)`, holds this JSON in its `payload` Bytes
/// field; `chosenAt` uses `JSONEncoder`'s default date encoding. `linkedSeriesID` names the series
/// whose look the book draws, and whose name its details show, instead of its shortest one,
/// `standsAlone` takes the book out of every series, and `ownLook` keeps the book's own design
/// instead of its series' look. A save changes only the choices the reader changed, so a choice
/// another device saved meanwhile stays (`merged(over:changing:)`), and a link that then sets
/// none of them deletes the record. Readers ignore a record that fails `validate()` or names
/// another account or book than its record name.
struct SeriesLinkV1: Codable, Sendable, Hashable {
    let version: Int
    let accountID: String
    let bookID: Int
    var linkedSeriesID: Int? = nil
    var standsAlone: Bool
    var ownLook: Bool
    let chosenAt: Date

    /// Whether the link leaves the book as it is without one, so it is deleted, not saved.
    var changesNothing: Bool { linkedSeriesID == nil && !standsAlone && !ownLook }

    func validate() throws {
        guard version == 1, !accountID.isEmpty, accountID.count <= 512, bookID > 0,
            linkedSeriesID.map({ $0 > 0 }) ?? true, chosenAt.timeIntervalSince1970.isFinite
        else { throw CompanionError.invalidCloudData }
    }

    /// The link the book keeps when this link, the reader's change of `base`, the link the
    /// device showed, is saved over `saved`, the record's link: `saved`'s choices, with the
    /// series (`linkedSeriesID` and `standsAlone`) and `ownLook` each replaced only where this
    /// link differs from `base`, chosen at `chosenAt`. A missing `base` or `saved`, or a `saved`
    /// link that fails `validate()` or names another account or book, chooses nothing.
    func merged(over saved: SeriesLinkV1?, changing base: SeriesLinkV1?) -> SeriesLinkV1 {
        let saved = saved.flatMap { stored in
            stored.accountID == accountID && stored.bookID == bookID
                && (try? stored.validate()) != nil ? stored : nil
        }
        var link = self
        if linkedSeriesID == base?.linkedSeriesID, standsAlone == (base?.standsAlone ?? false) {
            link.linkedSeriesID = saved?.linkedSeriesID
            link.standsAlone = saved?.standsAlone ?? false
        }
        if ownLook == (base?.ownLook ?? false) { link.ownLook = saved?.ownLook ?? false }
        return link
    }

    /// Returns `books` with each book's link set as `seriesLink`. `links` maps record names to
    /// payloads; only valid links for `accountID` stored under their own record name count.
    static func apply(
        _ links: [String: SeriesLinkV1], accountID: String, to books: [CloudBook]
    ) -> [CloudBook] {
        var chosen: [Int: SeriesLinkV1] = [:]
        for (name, link) in links
        where link.accountID == accountID
            && name == CloudContract.seriesLinkRecordName(accountID: accountID, bookID: link.bookID)
            && (try? link.validate()) != nil
        {
            chosen[link.bookID] = link
        }
        return books.map { book in
            var book = book
            book.seriesLink = chosen[book.id]
            return book
        }
    }
}

/// The books the reader pinned to Top Five (`TopFivePins`), shared through iCloud so the
/// iPhone and the Mac pin the same books.
///
/// One `TopFivePinsV1` record per account in the private database's default zone, named by
/// `CloudContract.topFivePinsRecordName(accountID:)`, holds this JSON in its `payload` Bytes
/// field; `pinnedAt` uses `JSONEncoder`'s default date encoding. `bookIDs` lists up to
/// `TopFivePins.limit` Hardcover book IDs in pin order, and is empty once the reader unpins
/// every book: the record is never deleted. A save changes only the pins the reader changed, so
/// a pin another device saved meanwhile stays (`merged(over:changing:)`). Readers ignore a
/// record that fails `validate()` or names another account than its record name.
struct TopFivePinsV1: Codable, Sendable, Hashable {
    let version: Int
    let accountID: String
    var bookIDs: [Int]
    let pinnedAt: Date

    func validate() throws {
        guard version == 1, !accountID.isEmpty, accountID.count <= 512,
            bookIDs.count <= TopFivePins.limit, bookIDs.allSatisfy({ $0 > 0 }),
            Set(bookIDs).count == bookIDs.count, pinnedAt.timeIntervalSince1970.isFinite
        else { throw CompanionError.invalidCloudData }
    }

    /// The pins the account keeps when these pins, the reader's change of `base`, the pins as
    /// this device last synced them, are saved over `saved`, the record's pins: `saved`'s pins
    /// without the ones this device unpinned since `base`, followed by the ones it pinned since,
    /// pinned at `pinnedAt`, with this list's pins in this list's order, so a pin unpinned and
    /// pinned again here moves. Over `TopFivePins.limit`, the newest pins this
    /// list lacks give way, so a pin the reader just made stays even when the saved pins are full
    /// of pins that this device hides. A missing `base` counts as no pins. A missing `saved`, or
    /// one that fails `validate()` or names another account, has nothing to merge with, so these
    /// pins stay as they are.
    func merged(over saved: TopFivePinsV1?, changing base: TopFivePinsV1?) -> TopFivePinsV1 {
        guard let saved, saved.accountID == accountID, (try? saved.validate()) != nil else {
            return self
        }
        let baseIDs = Set(base?.bookIDs ?? [])
        let mine = Set(bookIDs)
        var merged = saved.bookIDs.filter { !baseIDs.contains($0) || mine.contains($0) }
        for id in bookIDs where !baseIDs.contains(id) && !merged.contains(id) {
            merged.append(id)
        }
        while merged.count > TopFivePins.limit,
            let other = merged.lastIndex(where: { !mine.contains($0) })
        {
            merged.remove(at: other)
        }
        var ordered = bookIDs.filter(merged.contains)
        merged = merged.map { mine.contains($0) ? ordered.removeFirst() : $0 }
        var pins = self
        pins.bookIDs = Array(merged.prefix(TopFivePins.limit))
        return pins
    }

    /// Returns the payload when it is valid and stored under its own record name, else `nil`.
    func checked(recordName: String) -> TopFivePinsV1? {
        recordName == CloudContract.topFivePinsRecordName(accountID: accountID)
            && (try? validate()) != nil ? self : nil
    }
}

/// One reconciliation's input: the account, its snapshot date, and the books to design.
struct WorkContext: Sendable {
    let accountID: String
    let syncedAt: Date
    let books: [CloudBook]
    /// Whether an Apple TV worklist chose the books. Otherwise the companion designs every book
    /// of the snapshot: this device's own library, or a Hardcover snapshot in the archive
    /// (`CloudLibraryArchive.workSource(for:accountID:)`).
    let followsWorklist: Bool
    /// The iCloud user's record name in this build's CloudKit environment (`CloudEnvironment`),
    /// which scopes the local ledger.
    let cloudUserRecordName: String
}

/// The active account's library, saved designs, and series looks, as the viewer and share images
/// show them.
struct LibrarySnapshot: Codable, Sendable {
    var accountID: String
    var syncedAt: Date
    var books: [CloudBook]
    /// Valid designs for this account, keyed by book ID, from any generator, as stored.
    var designs: [Int: SpineDesignV1]
    /// Valid series looks of the books' look groups, keyed by group.
    var looks: [SeriesLookKey: SeriesLookV1] = [:]
    /// The series of the books from the library's last Hardcover download, which book details
    /// list (`SeriesInfo`). `nil` when the library has none, such as a launch cache saved before
    /// series were kept.
    var series: [SeriesInfo]? = nil
    /// Why a signed-in device's own library loaded without iCloud's designs and choices:
    /// `.noICloudAccount`, `.iCloudRestricted`, `.otherAccountInICloud`, or `.iCloudOff`. Not
    /// saved with the launch cache.
    var iCloudIssue: CompanionError? = nil

    private enum CodingKeys: String, CodingKey {
        case accountID, syncedAt, books, designs, looks, series
    }

    /// Keeps the newest valid design per book for `accountID` and `books`.
    ///
    /// Designs from any generator count, so Mac and older designs show until a newer one replaces
    /// them. A design whose work-item hash no longer matches still shows: its colors and font stay
    /// usable after small metadata edits. Designs keep their stored fonts, so series rules and new
    /// looks see what other devices see; `AppModel` draws a blocked font, such as Impact, in its
    /// replacement (`SpineDesignV1.withAllowedFont`).
    static func latestDesigns(
        _ designs: some Sequence<SpineDesignV1>, accountID: String, books: [CloudBook]
    ) -> [Int: SpineDesignV1] {
        let ids = Set(books.map(\.id))
        var latest: [Int: SpineDesignV1] = [:]
        for design in designs
        where design.accountID == accountID && ids.contains(design.bookID)
            && (try? design.validate()) != nil
        {
            if let existing = latest[design.bookID], existing.generatedAt >= design.generatedAt {
                continue
            }
            latest[design.bookID] = design
        }
        return latest
    }
}

extension LibrarySnapshot {
    /// Decodes a snapshot, including a launch cache saved before series looks or series existed.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(String.self, forKey: .accountID)
        syncedAt = try container.decode(Date.self, forKey: .syncedAt)
        books = try container.decode([CloudBook].self, forKey: .books)
        designs = try container.decode([Int: SpineDesignV1].self, forKey: .designs)
        looks =
            try container.decodeIfPresent([SeriesLookKey: SeriesLookV1].self, forKey: .looks)
            ?? [:]
        series = try container.decodeIfPresent([SeriesInfo].self, forKey: .series)
    }
}

enum CompanionError: LocalizedError, Equatable, Sendable {
    case noICloudAccount
    case iCloudRestricted
    case iCloudUnavailable
    case invalidCloudData
    case unsupportedCloudData
    case waitingForLibrary
    /// The Apple TV archive has sources, such as CWA, but none from Hardcover.
    case noHardcoverLibrary
    case bookNotInLibrary
    case invalidCover
    case coverTooLarge
    case modelUnavailable
    /// The daily Private Cloud Compute quota is used up until the date, when known.
    case quotaReached(Date?)
    /// The designing model is unreachable or busy; retry after the date, when the model gives
    /// one.
    case modelBusy(Date?)
    /// The operating system's limit on design requests while the device runs on battery, which
    /// lifts while it charges.
    case batteryRateLimited(Date?)
    case invalidDesign
    /// Google Fonts is failing or rate limiting requests; retry after the date, when the service
    /// gives one.
    case fontServiceUnavailable(Date?)
    case cloudConflict
    /// iCloud no longer holds the design or look an edit started from: for the reader's colors
    /// or font, the record is gone, and for a generated upgrade, another device remade or the
    /// reader edited the look first.
    case designChanged
    /// A third-party spine designer rejected its settings, such as its key, model name, or
    /// account, or is not set up, with the reason.
    case providerRejected(String)
    /// A backup model request failed in a way that may pass: it timed out, couldn't connect,
    /// lost its connection, or got a bad or server-error reply (`SpineWorker.unreachableErrors`,
    /// `ProviderError.isServerError`). It fails only the book, after its retries and another
    /// model's try.
    case providerUnreachable
    /// The Keychain refused to read the backup model's saved API key, with the message. The run
    /// stops, and a later run tries the key again.
    case keyUnreadable(String)
    /// The backup model refused one book's request, such as with HTTP 400, or gave no answer the
    /// app can read, with the message (`BookAnalyzer.modelFailure(_:)`). It fails only the book,
    /// unless the backup refuses several books in a row with the same message
    /// (`SpineWorker.RefusalStreak`).
    case providerRefused(String)
    /// Vision didn't read the cover's text within `CoverTextReader.timeout`. The book fails, so
    /// it isn't designed without its text, and the run stops.
    case coverTextTimedOut
    /// One of Apple's models answered neither a request nor its second sending within the
    /// limit (`BookAnalyzer.answer(within:tries:_:)`). The book fails, and the run pauses and
    /// tries the other books later.
    case modelTimedOut
    /// An earlier cover's timed-out text read still holds Vision, so no cover's text can be read
    /// now. The run stops and tries again later.
    case coverTextBusy
    /// iCloud holds data from another Hardcover account that this device's account hasn't
    /// merged, so the device uses no iCloud data until the reader chooses
    /// (`CloudAccountCheck.otherAccounts`).
    case otherAccountInICloud
    /// The reader turned iCloud storage off on this device (`CloudStorage.isOff`).
    case iCloudOff
    /// iCloud holds libraries from several Hardcover accounts, and this device, without a
    /// sign-in, has no remembered choice (`CloudAccountCheck.chooseLibrary`).
    case libraryChoiceNeeded
    /// **Merge** needs this device's copy of its Hardcover library, which hasn't downloaded yet.
    case libraryNotDownloaded

    var errorDescription: String? {
        switch self {
        case .noICloudAccount: "Sign in to iCloud on this \(ThisDevice.name)."
        case .iCloudRestricted: "iCloud access is restricted on this \(ThisDevice.name)."
        case .iCloudUnavailable: "iCloud is temporarily unavailable."
        case .invalidCloudData: "Bookworms iCloud data could not be read."
        case .unsupportedCloudData: "Update this app to read the iCloud data."
        case .waitingForLibrary: "Waiting for the Apple TV to upload its library to iCloud."
        case .noHardcoverLibrary:
            "The Apple TV library has no Hardcover books. Connect Hardcover on the Apple TV or on this \(ThisDevice.name) to design spines."
        case .bookNotInLibrary: "This book is not in the library Bookworms shows now."
        case .invalidCover: "A book cover could not be read securely."
        case .coverTooLarge: "A book cover exceeds the image limit."
        case .modelUnavailable: "The design model isn't available on this \(ThisDevice.name)."
        case .quotaReached(let date):
            if let date {
                "You've reached today's Private Cloud Compute limit. It resets at \(date.formatted(date: .omitted, time: .shortened))."
            } else {
                "You've reached today's Private Cloud Compute limit."
            }
        case .modelBusy, .modelTimedOut:
            "The design model is busy or unreachable. Bookworms tries again later."
        case .batteryRateLimited:
            "On battery, \(ThisDevice.system) limits design requests. Plug in this \(ThisDevice.name) to keep designing."
        case .providerUnreachable: "The design model didn't respond. Bookworms tries again later."
        case .invalidDesign: "The generated design did not pass validation."
        case .fontServiceUnavailable: "Google Fonts is unavailable. Bookworms will retry."
        case .cloudConflict: "A concurrent iCloud update prevented saving."
        case .designChanged:
            "The spine changed on another device, so these colors were not saved. Try again."
        case .coverTextTimedOut:
            "Reading a book cover's text took too long. Bookworms tries again later."
        case .coverTextBusy:
            "Bookworms is still reading an earlier cover's text. It tries again later."
        case .otherAccountInICloud:
            "iCloud has data from another Hardcover account. Choose Merge or Keep iCloud Off."
        case .iCloudOff: "iCloud storage is off on this \(ThisDevice.name)."
        case .libraryChoiceNeeded: "Choose which iCloud library to show."
        case .libraryNotDownloaded:
            "Your Hardcover library hasn't downloaded yet. Bookworms asks again when it has."
        case .providerRejected(let reason), .providerRefused(let reason),
            .keyUnreadable(let reason):
            reason
        }
    }
}
