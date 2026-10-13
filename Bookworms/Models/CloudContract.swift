import CryptoKit
import Foundation

enum CloudContract {
    static let containerID = "iCloud.gay.ian.Bookworms"
    static let worklistRecordName = "spine-worklist-v1"
    static let worklistSubscriptionID = "spine-worklist-v1-changes"
    static let libraryRecordName = "library-v1"
    /// Identifies designs from this app. Designs with another version, such as the Mac
    /// companion's on-device `mac-foundation-models-v2`, are regenerated with Private Cloud Compute.
    static let generatorVersion = "ios-pcc-v1"

    static func designRecordName(accountID: String, bookID: Int) -> String {
        "spine-design-v1-" + digest("\(accountID):\(bookID)")
    }

    static func coverChoiceRecordName(accountID: String, bookID: Int) -> String {
        "cover-choice-v1-" + digest("\(accountID):\(bookID)")
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
}

struct CloudSourceSnapshot: Decodable, Sendable {
    let source: String
    let accountID: String
    let books: [CloudBook]
    let syncedAt: Date

    func selectedBooks(in worklist: SpineWorklistV1) throws -> [CloudBook] {
        let included = Set(worklist.bookIDs)
        var seen = Set<Int>()
        let selected = books.filter { included.contains($0.id) && seen.insert($0.id).inserted }
        guard selected.count == included.count else { throw CompanionError.waitingForLibrary }
        return selected
    }
}

/// A book from the Apple TV's `library-v1` archive.
///
/// The archive encodes the TV's full `Book`; this type decodes the fields the companion uses and
/// ignores the rest. Optional reading fields are absent from older archives.
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
    /// The name of the `seriesID` series. The iPhone's own Hardcover download carries it; the
    /// Apple TV archive does not, so its books have none.
    var seriesName: String? = nil
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
    /// The reader's own review as plain text. The Apple TV archive does not carry reviews; the
    /// iPhone fills this in from its own Hardcover sign-in.
    var review: String? = nil
    /// The cover the reader chose (`CoverChoiceV1`), which neither the archive nor
    /// `workItemHash` includes, so designs keep matching the Apple TV's hash.
    var chosenCoverURL: URL? = nil

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
    /// How the design was made when not by a model request, such as "series-reuse:12".
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

/// The active account's library and saved designs, as the viewer and share images show them.
struct LibrarySnapshot: Codable, Sendable {
    var accountID: String
    var syncedAt: Date
    var books: [CloudBook]
    /// Valid designs for this account, keyed by book ID, from any generator.
    var designs: [Int: SpineDesignV1]

    /// Keeps the newest valid design per book for `accountID` and `books`.
    ///
    /// Designs from any generator count, so Mac and older designs show until a newer one replaces
    /// them. A design whose work-item hash no longer matches still shows: its colors and font stay
    /// usable after small metadata edits.
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
    /// Private Cloud Compute is unreachable or busy; retry after the date, when the system gives
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

    var errorDescription: String? {
        switch self {
        case .noICloudAccount: "Sign in to iCloud on this iPhone."
        case .iCloudRestricted: "iCloud access is restricted on this iPhone."
        case .iCloudUnavailable: "iCloud is temporarily unavailable."
        case .invalidCloudData: "Bookworms iCloud data could not be read."
        case .unsupportedCloudData: "Update this app to read the iCloud data."
        case .waitingForLibrary: "Waiting for the Apple TV to upload its library to iCloud."
        case .noHardcoverLibrary:
            "The Apple TV library has no Hardcover books. Connect Hardcover on the Apple TV or on this iPhone to design spines."
        case .bookNotInLibrary: "This book is not in the library Bookworms shows now."
        case .invalidCover: "A book cover could not be read securely."
        case .coverTooLarge: "A book cover exceeds the image limit."
        case .modelUnavailable: "Private Cloud Compute is unavailable on this iPhone."
        case .quotaReached(let date):
            if let date {
                "Today's Private Cloud Compute limit is reached. It resets at \(date.formatted(date: .omitted, time: .shortened))."
            } else {
                "Today's Private Cloud Compute limit is reached."
            }
        case .modelBusy: "Private Cloud Compute is busy or unreachable. Bookworms will retry."
        case .invalidDesign: "The generated design did not pass validation."
        case .fontServiceUnavailable: "Google Fonts is unavailable. Bookworms will retry."
        case .cloudConflict: "A concurrent iCloud update prevented saving."
        case .designChanged:
            "The spine was redesigned on another device, so these colors were not saved."
        }
    }
}
