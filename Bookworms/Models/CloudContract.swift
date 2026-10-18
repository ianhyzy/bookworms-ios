import CryptoKit
import Foundation

enum CloudContract {
    static let containerID = "iCloud.gay.ian.Bookworms"
    static let worklistRecordName = "spine-worklist-v1"
    static let worklistSubscriptionID = "spine-worklist-v1-changes"
    static let libraryRecordName = "library-v1"
    /// Identifies designs from this app's current generator. Changing it replaces no saved
    /// design: a run keeps a design from its own model tier or a better one whatever generator
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

    static func coverChoiceRecordName(accountID: String, bookID: Int) -> String {
        "cover-choice-v1-" + digest("\(accountID):\(bookID)")
    }

    static func seriesLookRecordName(accountID: String, key: SeriesLookKey) -> String {
        "series-look-v1-" + digest("\(accountID):\(key.seriesID):\(key.group)")
    }

    static func seriesLinkRecordName(accountID: String, bookID: Int) -> String {
        "series-link-v1-" + digest("\(accountID):\(bookID)")
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
}

struct SpineWorklistV1: Codable, Sendable {
    let version: Int
    let accountID: String
    let syncedAt: Date
    let bookIDs: [Int]

    func validate() throws {
        guard version == 1, !accountID.isEmpty, accountID.count <= 512,
            syncedAt.timeIntervalSince1970.isFinite,
            bookIDs.allSatisfy({ $0 > 0 }),
            bookIDs == Array(Set(bookIDs)).sorted()
        else { throw CompanionError.invalidCloudData }
    }
}

struct CloudLibraryArchive: Decodable, Sendable {
    let version: Int
    let sources: [CloudSourceSnapshot]

    /// Returns the Hardcover snapshot the companion works on, with the books it should design.
    ///
    /// With a worklist, the Apple TV chose the account and books: the snapshot must have the
    /// worklist's account and sync date, or the library is still uploading. Without one (Apple TV
    /// builds that predate the worklist), the newest Hardcover snapshot wins, preferring a real
    /// account ID over the legacy `"hardcover"` placeholder, and every book is listed. An archive
    /// with no Hardcover snapshot, such as from a CWA-only Apple TV, throws
    /// `CompanionError.noHardcoverLibrary`.
    func workSource(for worklist: SpineWorklistV1?) throws -> (
        snapshot: CloudSourceSnapshot, books: [CloudBook]
    ) {
        let hardcover = sources.filter { $0.source == "hardcover" }
        if let worklist {
            guard
                let source =
                    hardcover
                    .filter({ $0.accountID == worklist.accountID })
                    .max(by: { $0.syncedAt < $1.syncedAt }),
                abs(source.syncedAt.timeIntervalSince(worklist.syncedAt)) < 0.001
            else { throw CompanionError.waitingForLibrary }
            return (source, try source.selectedBooks(in: worklist))
        }
        guard !hardcover.isEmpty else { throw CompanionError.noHardcoverLibrary }
        let accounts = hardcover.filter { $0.accountID != "hardcover" }
        guard
            let source = (accounts.isEmpty ? hardcover : accounts)
                .max(by: { $0.syncedAt < $1.syncedAt })
        else { throw CompanionError.waitingForLibrary }
        var seen = Set<Int>()
        return (source, source.books.filter { $0.id > 0 && seen.insert($0.id).inserted })
    }

    /// Returns the newest Hardcover snapshot of `accountID`, or `nil` when the archive holds
    /// none.
    func newestHardcoverSnapshot(accountID: String) -> CloudSourceSnapshot? {
        sources.filter { $0.source == "hardcover" && $0.accountID == accountID }
            .max { $0.syncedAt < $1.syncedAt }
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
    /// `series` keeps the stored entry's series. Books leave out `chosenCoverURL` and
    /// `seriesLink`, which the archive never carries. When `stored` is `nil`, the splice starts
    /// an archive with `version` 1 and empty `designs`, which the Apple TV requires.
    ///
    /// - Throws: `CompanionError.unsupportedCloudData` when `stored` has a version other than 1,
    ///   and `CompanionError.invalidCloudData` when it is not an archive.
    static func splice(_ snapshot: CloudSourceSnapshot, into stored: Data?) throws -> Data? {
        var archive: [String: Any] = [:]
        if let stored {
            guard let object = try? JSONSerialization.jsonObject(with: stored) as? [String: Any]
            else { throw CompanionError.invalidCloudData }
            archive = object
        }
        if let version = archive["version"], version as? Int != 1 {
            throw CompanionError.unsupportedCloudData
        }
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
            syncedAt: snapshot.syncedAt, series: snapshot.series)
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
            entry["books"] = keepingAppleTVFields(of: entry["books"], from: existing["books"])
            sources[index] = entry
        } else {
            entry["books"] = keepingAppleTVFields(of: entry["books"], from: nil)
            sources.append(entry)
        }
        sources.sort { key($0) < key($1) }
        archive["sources"] = sources
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
            syncedAt: library.syncedAt, series: library.series)
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
    /// The finish date as `yyyy-MM-dd`.
    var finished: String? = nil
    /// The reader's rating, 0...5 in half steps.
    var rating: Double? = nil
    var isReading: Bool? = nil
    /// Whether the book is on the reader's **Read** shelf, even without a finish date. The Apple
    /// TV archive carries it; older archives leave it out, and then a finish date alone marks a
    /// read book (`hasBeenRead`).
    var isRead: Bool? = nil
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

    /// The title without a subtitle, matching the Apple TV spine: the text before the first colon.
    var spineTitle: String {
        guard let colon = title.firstIndex(of: ":") else { return title }
        let head = title[..<colon].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? title : head
    }

    /// The finish date, parsed from `finished` at noon UTC so it lands on the same calendar day.
    var finishedDate: Date? {
        guard let finished, finished.count >= 10 else { return nil }
        return try? Date(String(finished.prefix(10)) + "T12:00:00Z", strategy: .iso8601)
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
    let typeface: String
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

    func validate() throws {
        guard version == 1, !accountID.isEmpty, bookID > 0,
            Self.isLowercaseHash(workItemHash), Self.isLowercaseHash(coverHash),
            !generatorVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            generatedAt.timeIntervalSince1970.isFinite,
            ["serif", "sans", "rounded", "monospaced"].contains(typeface),
            [400, 500, 600, 700].contains(weight),
            instanceWeight.map({ (100...900).contains($0) && $0.isMultiple(of: 100) }) ?? true,
            [fontFamily, fontPostScriptName, provenance].allSatisfy(Self.isShortLine),
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
/// holds that design's tier tokens (`SpineDesignV1.tierTokens`): its model token, which gives the
/// look's tier (`tier`), and the system-font token of a design that awaits its font.
///
/// The first look saved for a group decides it among equal tiers: devices create the record only
/// when it is missing (see `SpineStore.createLook(_:)`). A design from a better tier, or from
/// the look's tier when the look awaits its font, replaces a look the reader never edited
/// (`isUpgraded(at:awaitingFont:)`, `SpineStore.upgradeLook(_:)`), keeping `createdAt`. The
/// reader's edits replace the colors, or the whole look when the reader asks to redesign the
/// series, and set `editedAt`. Readers ignore a record that fails `validate()` or
/// names another account or group than its record name.
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
    let typeface: String
    let weight: Int
    let uppercase: Bool
    var fontFamily: String? = nil
    var fontPostScriptName: String? = nil
    var instanceWeight: Int? = nil
    var provenance: String? = nil

    var key: SeriesLookKey { SeriesLookKey(seriesID: seriesID, group: group) }

    /// The model tier that made the look (`SpineDesignV1.tier`): the tier its `provenance` names,
    /// or, without a model token, the tier its `origin` implies, such as local defaults for an
    /// Apple TV look.
    var tier: ModelTier { storedDesign(bookID: sourceBookID, hashesFrom: nil).tier }

    /// Whether the look stands in its system typeface for a font that couldn't download
    /// (`SpineDesignV1.awaitsFont`).
    var awaitsFont: Bool { storedDesign(bookID: sourceBookID, hashesFrom: nil).awaitsFont }

    /// Whether a design from `tier` replaces this look: the look's colors are the generator's,
    /// and the design outranks the look's own (`SpineDesignV1.isOutranked(by:awaitingFont:)`),
    /// because a weaker tier made the look, or the look awaits a font that the design, unless
    /// `awaitingFont`, has. The reader's colors stay: an edited look, or one whose `provenance`
    /// carries a recolored design's `generated-colors` token.
    func isUpgraded(at tier: ModelTier, awaitingFont: Bool = false) -> Bool {
        let design = storedDesign(bookID: sourceBookID, hashesFrom: nil)
        return editedAt == nil && design.generatedColors == nil
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
            editedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
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

    /// Whether `other` is this look or a recoloring of it: every field but the colors and
    /// `editedAt` matches, so no device remade the look in between.
    func isSameLook(as other: SeriesLookV1) -> Bool {
        var look = other
        look.backgroundHex = backgroundHex
        look.foregroundHex = foregroundHex
        look.accentHex = accentHex
        look.editedAt = editedAt
        return look == self
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

    /// Returns the look made again from `design`, a new design of one of its books, at `date`:
    /// `design`'s colors and type, book, generator, and model token, with the look's creation
    /// date.
    func remade(from design: SpineDesignV1, at date: Date) -> SeriesLookV1 {
        var look = SeriesLookV1(design: design, key: key, createdAt: createdAt)
        look.editedAt = date
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

extension SeriesLookV1 {
    /// A look for the group `key`, made from `design`'s colors and type, with `design`'s tier
    /// tokens (`SpineDesignV1.tierTokens`) as its `provenance`. The design's other tokens
    /// describe that book's design alone: a look copies no `series-reuse` or `generated-colors`
    /// token. A design the reader recolored gives the look the reader's colors, so the look
    /// counts as edited at `createdAt` and no upgrade replaces them
    /// (`isUpgraded(at:awaitingFont:)`).
    init(design: SpineDesignV1, key: SeriesLookKey, createdAt: Date) {
        self.init(
            version: 1, accountID: design.accountID, seriesID: key.seriesID, group: key.group,
            sourceBookID: design.bookID, origin: design.generatorVersion, createdAt: createdAt,
            editedAt: design.generatedColors == nil ? nil : createdAt,
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
/// whose look the book draws instead of its shortest one, `standsAlone` takes the book out of every
/// series, and `ownLook` keeps the book's own design instead of its series' look. A choice that
/// sets none of them deletes the record. Readers ignore a record that fails `validate()` or names
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

/// One reconciliation's input: the account, its snapshot date, and the books to design.
struct WorkContext: Sendable {
    let accountID: String
    let syncedAt: Date
    let books: [CloudBook]
    /// Whether an Apple TV worklist chose the books. Without one, the companion designs the
    /// newest Hardcover snapshot in the archive.
    let followsWorklist: Bool
    /// The iCloud user's record name, which scopes the local ledger.
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
    /// Decodes a snapshot, including a launch cache saved before series looks existed.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(String.self, forKey: .accountID)
        syncedAt = try container.decode(Date.self, forKey: .syncedAt)
        books = try container.decode([CloudBook].self, forKey: .books)
        designs = try container.decode([Int: SpineDesignV1].self, forKey: .designs)
        looks =
            try container.decodeIfPresent([SeriesLookKey: SeriesLookV1].self, forKey: .looks)
            ?? [:]
    }
}

enum CompanionError: LocalizedError, Sendable {
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
    case invalidDesign
    /// Google Fonts is failing or rate limiting requests; retry after the date, when the service
    /// gives one.
    case fontServiceUnavailable(Date?)
    case cloudConflict
    /// iCloud holds another design than the one the reader recolored, such as a redesign from
    /// another device.
    case designChanged
    /// A third-party spine designer rejected its settings, such as its key, model name, or
    /// account, or is not set up, with the reason.
    case providerRejected(String)
    /// The backup model refused one book's request with HTTP 400, with the provider's message.
    /// It fails only the book, unless the backup refuses several books in a row with the same
    /// message (`SpineWorker.RefusalStreak`).
    case providerRefused(String)

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
        case .modelUnavailable: "The spine design model is unavailable on this \(ThisDevice.name)."
        case .quotaReached(let date):
            if let date {
                "Today's Private Cloud Compute limit is reached. It resets at \(date.formatted(date: .omitted, time: .shortened))."
            } else {
                "Today's Private Cloud Compute limit is reached."
            }
        case .modelBusy: "The spine design model is busy or unreachable. Bookworms will retry."
        case .invalidDesign: "The generated design did not pass validation."
        case .fontServiceUnavailable: "Google Fonts is unavailable. Bookworms will retry."
        case .cloudConflict: "A concurrent iCloud update prevented saving."
        case .designChanged:
            "The spine was redesigned on another device, so these colors were not saved."
        case .providerRejected(let reason), .providerRefused(let reason): reason
        }
    }
}
