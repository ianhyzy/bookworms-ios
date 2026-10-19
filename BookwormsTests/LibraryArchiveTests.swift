import Foundation
import XCTest

@testable import Bookworms

/// Checks that `CloudLibraryArchive.splice(_:into:)` writes archives the Apple TV reads, using
/// copies of the TV's archive types.
final class LibraryArchiveTests: XCTestCase {
    private let synced = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
    private let cwaAccount = "https://cwa.example.com/reader"
    private let storedSeries = TVSeries(
        id: 5, name: "The Stored Series",
        books: [
            TVSeries.Book(
                id: 1, title: "Old", position: 1, releaseYear: 2001,
                coverURL: URL(string: "https://assets.hardcover.app/series-1.jpg"))
        ])

    func testSpliceReplacesOnlyItsAccountAndKeepsEverythingElse() throws {
        let stored = try storedArchive()
        let newer = snapshot(accountID: "42", syncedAt: synced.addingTimeInterval(60))
        let spliced = try XCTUnwrap(CloudLibraryArchive.splice(newer, into: stored))

        let archive = try JSONDecoder().decode(TVArchive.self, from: spliced)
        XCTAssertEqual(
            archive.sources.map { $0.source.rawValue + $0.accountID },
            ["cwa" + cwaAccount, "hardcover42", "hardcover77"])
        let mine = try XCTUnwrap(archive.sources.first { $0.accountID == "42" })
        XCTAssertEqual(mine.syncedAt, newer.syncedAt)
        XCTAssertEqual(mine.books.map(\.title), ["New"])
        XCTAssertEqual(mine.books.first?.review, "Loved it.")
        XCTAssertEqual(mine.books.first?.finished, "2026-02-01")
        XCTAssertEqual(mine.books.first?.finishedDates, ["2026-02-01", "2019-07-04"])
        XCTAssertEqual(mine.books.first?.statusID, 1)
        XCTAssertNil(mine.books.first?.chosenCoverURL)
        // The fields only the Apple TV stores survive the replacement.
        XCTAssertEqual(mine.books.first?.sources, [.hardcover])
        XCTAssertEqual(mine.books.first?.isOwned, true)
        // A download without series keeps the stored ones.
        XCTAssertEqual(mine.series, [storedSeries])
        XCTAssertEqual(archive.designs[7]?.coverHash, "cover")

        let before = try object(stored)
        let after = try object(spliced)
        XCTAssertEqual(after["futureKey"] as? String, "kept")
        XCTAssertEqual(after["designs"] as? NSDictionary, before["designs"] as? NSDictionary)
        for account in [cwaAccount, "77"] {
            XCTAssertEqual(entry(account, in: after), entry(account, in: before))
        }
        let book = try XCTUnwrap((entry("42", in: after)?["books"] as? [[String: Any]])?.first)
        XCTAssertNil(book["chosenCoverURL"])
        XCTAssertNil(book["seriesLink"])

        // An app that predates rereads still decodes the archive and keeps the newest finish.
        let legacy = try JSONDecoder().decode(LegacyArchive.self, from: spliced)
        XCTAssertEqual(
            legacy.sources.first { $0.accountID == "42" }?.books.first?.finished, "2026-02-01")

        // This app reads the series back, and a download with its own series replaces them.
        let ported = try JSONDecoder().decode(CloudLibraryArchive.self, from: spliced)
        XCTAssertEqual(
            ported.sources.first { $0.accountID == "42" }?.books.first?.readCount, 2)
        // The reads survive the Apple TV's re-encoding too.
        let reencoded = try JSONDecoder()
            .decode(CloudLibraryArchive.self, from: try JSONEncoder().encode(archive))
        XCTAssertEqual(
            reencoded.sources.first { $0.accountID == "42" }?.books.first?.finishedDates,
            ["2026-02-01", "2019-07-04"])
        XCTAssertEqual(
            reencoded.sources.first { $0.accountID == "42" }?.books.first?.statusID, 1)
        // An Apple TV build without the list or the status drops them when it re-encodes the
        // archive, and this app then knows only the newest read and no shelf.
        var olderTV = archive
        for source in olderTV.sources.indices {
            for book in olderTV.sources[source].books.indices {
                olderTV.sources[source].books[book].finishedDates = nil
                olderTV.sources[source].books[book].statusID = nil
            }
        }
        let olderTVCopy = try JSONDecoder()
            .decode(CloudLibraryArchive.self, from: try JSONEncoder().encode(olderTV))
        let stripped = olderTVCopy.sources.first { $0.accountID == "42" }?.books.first
        XCTAssertEqual(stripped?.finished, "2026-02-01")
        XCTAssertNil(stripped?.finishedDates)
        XCTAssertEqual(stripped?.readCount, 1)
        XCTAssertNil(stripped?.statusID)
        XCTAssertEqual(
            ported.sources.first { $0.accountID == "42" }?.series?.first?.name, "The Stored Series")
        var withSeries = snapshot(accountID: "42", syncedAt: synced.addingTimeInterval(120))
        withSeries.series = [SeriesInfo(id: 9, name: "Fresh", books: [])]
        let replaced = try JSONDecoder()
            .decode(
                TVArchive.self,
                from: try XCTUnwrap(CloudLibraryArchive.splice(withSeries, into: spliced)))
        XCTAssertEqual(
            replaced.sources.first { $0.accountID == "42" }?.series,
            [TVSeries(id: 9, name: "Fresh", books: [])])
    }

    func testSpliceAppendsANewAccountAndStartsAnArchiveTheAppleTVDecodes() throws {
        let other = snapshot(accountID: "99", syncedAt: synced.addingTimeInterval(-60))
        let appended = try JSONDecoder()
            .decode(
                TVArchive.self,
                from: try XCTUnwrap(CloudLibraryArchive.splice(other, into: try storedArchive())))
        XCTAssertEqual(
            appended.sources.map(\.accountID), [cwaAccount, "42", "77", "99"])

        let created = try JSONDecoder()
            .decode(
                TVArchive.self, from: try XCTUnwrap(CloudLibraryArchive.splice(other, into: nil)))
        XCTAssertEqual(created.version, 1)
        XCTAssertTrue(created.designs.isEmpty)
        XCTAssertEqual(created.sources.map(\.accountID), ["99"])
        XCTAssertEqual(created.sources.first?.source, .hardcover)
    }

    func testSpliceSkipsEqualOrOlderSnapshotsAndRefusesOtherVersions() throws {
        let stored = try storedArchive()
        XCTAssertNil(
            try CloudLibraryArchive.splice(
                snapshot(accountID: "42", syncedAt: synced), into: stored))
        XCTAssertNil(
            try CloudLibraryArchive.splice(
                snapshot(accountID: "42", syncedAt: synced.addingTimeInterval(-1)), into: stored))

        var future = try object(stored)
        future["version"] = 2
        let newer = snapshot(accountID: "42", syncedAt: synced.addingTimeInterval(60))
        XCTAssertThrowsError(
            try CloudLibraryArchive.splice(
                newer, into: try JSONSerialization.data(withJSONObject: future))
        ) { error in
            guard case CompanionError.unsupportedCloudData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try CloudLibraryArchive.splice(newer, into: Data("[]".utf8))) {
            error in
            guard case CompanionError.invalidCloudData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        // A duplicate entry for the account counts too: a snapshot older than either is skipped.
        var duplicated = try object(stored)
        var copies = try XCTUnwrap(duplicated["sources"] as? [[String: Any]])
        var later = try XCTUnwrap(copies.first { $0["accountID"] as? String == "42" })
        later["syncedAt"] = synced.addingTimeInterval(120).timeIntervalSinceReferenceDate
        copies.append(later)
        duplicated["sources"] = copies
        XCTAssertNil(
            try CloudLibraryArchive.splice(
                newer, into: try JSONSerialization.data(withJSONObject: duplicated)),
            "A snapshot newer than the first entry but older than a duplicate is skipped")

        // A stored date in another format could hide a newer copy, so the write stops.
        var unreadable = try object(stored)
        var sources = try XCTUnwrap(unreadable["sources"] as? [[String: Any]])
        let index = try XCTUnwrap(sources.firstIndex { $0["accountID"] as? String == "42" })
        sources[index]["syncedAt"] = "2026-10-16T12:00:00Z"
        unreadable["sources"] = sources
        XCTAssertThrowsError(
            try CloudLibraryArchive.splice(
                newer, into: try JSONSerialization.data(withJSONObject: unreadable))
        ) { error in
            guard case CompanionError.invalidCloudData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    /// A Hardcover snapshot as this app writes it, with a reread book on Want to Read that
    /// carries a review, a chosen cover, and a series link.
    private func snapshot(accountID: String, syncedAt: Date) -> CloudSourceSnapshot {
        let book = CloudBook(
            id: 1, title: "New", author: "Author", coverURL: nil,
            detailCoverURL: URL(string: "https://assets.hardcover.app/new.jpg"),
            seriesMemberships: [
                SeriesMembership(
                    seriesID: 5, name: "The Stored Series", featured: true, compilation: false)
            ],
            finished: "2026-02-01", finishedDates: ["2026-02-01", "2019-07-04"], statusID: 1,
            ratingDistribution: [RatingBucket(rating: 4.5, count: 3)], review: "Loved it.",
            chosenCoverURL: URL(string: "https://assets.hardcover.app/chosen.jpg"),
            seriesLink: SeriesLinkV1(
                version: 1, accountID: accountID, bookID: 1, standsAlone: true, ownLook: false,
                chosenAt: syncedAt))
        return CloudSourceSnapshot(
            source: "hardcover", accountID: accountID, books: [book], syncedAt: syncedAt)
    }

    /// An archive as the Apple TV saves it, with a design, a CWA snapshot, two Hardcover accounts,
    /// and a top-level key that a later version might add.
    private func storedArchive() throws -> Data {
        let archive = TVArchive(
            sources: [
                TVSnapshot(
                    source: .cwa, accountID: cwaAccount,
                    books: [
                        TVBook(
                            id: 1_000_000_000_000_123, title: "Shelved", author: "Writer",
                            sources: [.cwa], isOwned: true)
                    ],
                    syncedAt: synced.addingTimeInterval(500)),
                TVSnapshot(
                    source: .hardcover, accountID: "42",
                    books: [
                        TVBook(
                            id: 1, title: "Old", author: "Author", review: "Old review",
                            sources: [.hardcover], isOwned: true)
                    ],
                    syncedAt: synced, series: [storedSeries]),
                TVSnapshot(
                    source: .hardcover, accountID: "77",
                    books: [TVBook(id: 2, title: "Theirs", author: "Author", rating: 4)],
                    syncedAt: synced.addingTimeInterval(1_000)),
            ],
            designs: [7: TVDesign(bookID: 7, coverHash: "cover", generatedAt: synced)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var json = try object(encoder.encode(archive))
        json["futureKey"] = "kept"
        return try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func entry(_ accountID: String, in archive: [String: Any]) -> NSDictionary? {
        (archive["sources"] as? [[String: Any]])?
            .first { $0["accountID"] as? String == accountID }
            .map { $0 as NSDictionary }
    }
}

// Copies of the Apple TV's archive types: tvos `CloudLibraryArchive`, `SourceSnapshot`, `Book`,
// `SeriesInfo`, `SeriesMembership`, and `RatingBucket`. Like the TV's synthesized decoding, they
// require every non-optional key, even one with a default value. `TVDesign` keeps only the
// `AIStyleRecord` fields these tests check.

private struct TVArchive: Codable {
    var version = 1
    var sources: [TVSnapshot] = []
    var designs: [Int: TVDesign] = [:]
}

private enum TVSource: String, Codable {
    case hardcover, cwa
}

private struct TVSnapshot: Codable {
    var source: TVSource
    var accountID: String
    var books: [TVBook]
    var syncedAt: Date
    var series: [TVSeries]? = nil
}

private struct TVBook: Codable {
    let id: Int
    var title: String
    var author: String
    var description: String?
    var review: String? = nil
    var coverURL: URL?
    var pages: Int?
    var finished: String?
    var finishedDates: [String]? = nil
    var rating: Double?
    var format: String?
    var seriesID: Int?
    var seriesPosition: Double? = nil
    var seriesName: String? = nil
    var seriesMemberships: [TVSeriesMembership]? = nil
    var genres: [String]?
    var communityRating: Double?
    var ratingsCount: Int?
    var ratingDistribution: [TVRatingBucket]?
    var detailCoverURL: URL?
    var sources: [TVSource]?
    var isOwned: Bool?
    var isRead: Bool?
    var statusID: Int? = nil
    var publicationYear: Int?
    var isReading: Bool?
    var progress: Double?
    var started: String?
    var audioSeconds: Int? = nil
    var chosenCoverURL: URL? = nil
}

private struct TVSeriesMembership: Codable {
    let seriesID: Int
    let name: String
    var position: Double? = nil
    var featured = false
    var compilation = false
    var size: Int? = nil
}

private struct TVRatingBucket: Codable {
    let rating: Double
    let count: Int
}

private struct TVSeries: Codable, Equatable {
    let id: Int
    let name: String
    let books: [Book]

    struct Book: Codable, Equatable {
        let id: Int
        let title: String
        let position: Double
        let releaseYear: Int?
        let coverURL: URL?
    }
}

private struct TVDesign: Codable {
    let bookID: Int
    let coverHash: String
    let generatedAt: Date
}

/// The archive as an app from before `finishedDates` decodes it: the keys it requires, and no
/// reread history.
private struct LegacyArchive: Decodable {
    let sources: [Snapshot]

    struct Snapshot: Decodable {
        let accountID: String
        let books: [Book]
    }

    struct Book: Decodable {
        let id: Int
        let title: String
        let author: String
        let finished: String?
    }
}
