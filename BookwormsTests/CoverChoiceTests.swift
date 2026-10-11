import Foundation
import XCTest

@testable import Bookworms

/// Covers the `CoverChoiceV1` contract, how chosen covers reach books and the ledger, and the
/// editions query, with fictional books and canned Hardcover replies.
final class CoverChoiceTests: XCTestCase {
    private let detail = URL(string: "https://covers.example.com/7/detail.jpg")!
    private let alternate = URL(string: "https://covers.example.com/7/alternate.jpg")!
    private let chosen = URL(string: "https://covers.example.com/7/2.jpg")!

    private var book: CloudBook {
        CloudBook(
            id: 7, title: "The Lantern Keeper", author: "Mara Quill", coverURL: alternate,
            detailCoverURL: detail)
    }

    private func choice(
        accountID: String = "42", bookID: Int = 7, coverURL: URL? = nil, editionID: Int? = 31
    ) -> CoverChoiceV1 {
        CoverChoiceV1(
            version: 1, accountID: accountID, bookID: bookID, coverURL: coverURL ?? chosen,
            editionID: editionID, chosenAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    // MARK: - Contract

    func testRecordNameAndJSONMatchTheSharedContract() throws {
        XCTAssertEqual(
            CloudContract.coverChoiceRecordName(accountID: "42", bookID: 7),
            "cover-choice-v1-755dac3729029e2e2976249c4e03b160c699ef71f296c346e22183dc23503c33")
        XCTAssertEqual(
            CloudContract.coverChoiceRecordName(accountID: "reader-1", bookID: 1234),
            "cover-choice-v1-83b1cd81db89961507083cb1fbc2f11d5a9e8a15e91f50b048ca7f7c9b2f3b1a")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(
            String(decoding: try encoder.encode(choice()), as: UTF8.self),
            #"{"accountID":"42","bookID":7,"chosenAt":800000000,"coverURL":"https://covers.example.com/7/2.jpg","editionID":31,"version":1}"#
        )
        // A cover without an edition leaves the key out.
        XCTAssertFalse(
            String(decoding: try encoder.encode(choice(editionID: nil)), as: UTF8.self)
                .contains("editionID"))

        // Another client's payload, with its own key order and escaped slashes.
        let payload = Data(
            #"{"version":1,"chosenAt":800000000,"editionID":31,"bookID":7,"accountID":"42","coverURL":"https:\/\/covers.example.com\/7\/2.jpg"}"#
                .utf8)
        XCTAssertEqual(try JSONDecoder().decode(CoverChoiceV1.self, from: payload), choice())
    }

    func testValidationRejectsUnsupportedChoices() {
        XCTAssertNoThrow(try choice().validate())
        XCTAssertNoThrow(try choice(editionID: nil).validate())
        XCTAssertNoThrow(try choice(accountID: String(repeating: "a", count: 512)).validate())
        let invalid = [
            CoverChoiceV1(
                version: 2, accountID: "42", bookID: 7, coverURL: chosen, editionID: 31,
                chosenAt: .now),
            choice(accountID: ""),
            choice(accountID: String(repeating: "a", count: 513)),
            choice(bookID: 0),
            choice(coverURL: URL(string: "http://covers.example.com/7/2.jpg")!),
            choice(coverURL: URL(string: "https://localhost/7/2.jpg")!),
            choice(coverURL: URL(string: "https://192.168.1.4/7/2.jpg")!),
            choice(editionID: 0),
        ]
        for value in invalid {
            XCTAssertThrowsError(try value.validate(), "\(value)")
        }
    }

    // MARK: - Applying choices

    func testChosenCoverLeadsCandidatesWithoutChangingTheWorkHash() {
        let name = CloudContract.coverChoiceRecordName(accountID: "42", bookID: 7)
        let hash = CloudContract.workItemHash(accountID: "42", book: book)
        let applied = CoverChoiceV1.apply([name: choice()], accountID: "42", to: [book])[0]
        XCTAssertEqual(applied.chosenCoverURL, chosen)
        XCTAssertEqual(applied.coverCandidates, [chosen, detail, alternate])
        XCTAssertEqual(CloudContract.workItemHash(accountID: "42", book: applied), hash)

        // A choice of a default cover keeps one copy of it.
        var same = book
        same.chosenCoverURL = alternate
        XCTAssertEqual(same.coverCandidates, [alternate, detail])

        // Choices for another account, filed under another book's name, or invalid are ignored.
        let ignored: [[String: CoverChoiceV1]] = [
            [name: choice(accountID: "77")],
            [CloudContract.coverChoiceRecordName(accountID: "42", bookID: 8): choice()],
            [name: choice(editionID: -1)],
        ]
        for choices in ignored {
            let result = CoverChoiceV1.apply(choices, accountID: "42", to: [book])[0]
            XCTAssertNil(result.chosenCoverURL)
            XCTAssertEqual(result.coverCandidates, [detail, alternate])
        }
    }

    func testPreviewStoreSavesAppliesAndDeletesChoices() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-choices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = """
            {"version":1,"sources":[{"source":"hardcover","accountID":"42","syncedAt":800000000,
              "books":[{"id":7,"title":"The Lantern Keeper","author":"Mara Quill",
                "coverURL":"\(alternate.absoluteString)","detailCoverURL":"\(detail.absoluteString)"},
                {"id":8,"title":"Salt and Static","author":"Iris Okafor"}]}]}
            """
        try Data(archive.utf8).write(to: folder.appending(path: "library-v1.json"))
        let store = LocalSpineStore(folder: folder)

        try await store.save(choice())
        let library = try await store.loadLibrary()
        XCTAssertEqual(library?.books.map(\.chosenCoverURL), [chosen, nil])
        let loaded = try await store.loadWork()
        let work = try XCTUnwrap(loaded)
        XCTAssertEqual(work.books.first?.coverCandidates.first, chosen)
        // A design from the old cover is stale once the reader picks another.
        let designing = work.books[0]
        let unchanged = try await store.isStillCurrent(work, book: designing)
        XCTAssertTrue(unchanged)
        try await store.save(choice(coverURL: URL(string: "https://covers.example.com/7/3.jpg")!))
        let changed = try await store.isStillCurrent(work, book: designing)
        XCTAssertFalse(changed)

        try await store.deleteCoverChoice(accountID: "42", bookID: 7)
        let restored = try await store.loadLibrary()
        XCTAssertEqual(restored?.books.map(\.chosenCoverURL), [nil, nil])

        do {
            try await store.save(choice(editionID: 0))
            XCTFail("An invalid choice was saved")
        } catch {}
    }

    // MARK: - Ledger

    func testLedgerRechecksABookWhenItsChosenCoverChanges() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let other = URL(string: "https://covers.example.com/7/3.jpg")!

        // An entry from a build without cover choices matches the default cover.
        let legacy = """
            {"cloudUserRecordName":"icloud-user","entries":{"record":{"workItemHash":"work",
              "coverHash":"cover","generatorVersion":"\(CloudContract.generatorVersion)",
              "checkedAt":\(now.timeIntervalSinceReferenceDate)}}}
            """
        try Data(legacy.utf8).write(to: url)
        let ledger = WorkLedger(url: url)
        func needsCheck(_ cover: URL?, after interval: TimeInterval = 60) async -> Bool {
            await ledger.needsCheck(
                recordName: "record", workItemHash: "work", chosenCover: cover,
                now: now.addingTimeInterval(interval))
        }
        let legacyDefault = await needsCheck(nil)
        let firstChoice = await needsCheck(chosen)
        XCTAssertFalse(legacyDefault)
        XCTAssertTrue(firstChoice)

        try await ledger.recordSuccess(
            recordName: "record", workItemHash: "work", coverHash: "chosen", chosenCover: chosen,
            now: now)
        let sameChoice = await needsCheck(chosen)
        let backToDefault = await needsCheck(nil)
        XCTAssertFalse(sameChoice)
        XCTAssertTrue(backToDefault)

        // A new choice skips the failure backoff, like a metadata edit.
        try await ledger.recordFailure(
            recordName: "record", workItemHash: "work", chosenCover: chosen, now: now)
        let backingOff = await needsCheck(chosen)
        let newChoice = await needsCheck(other)
        XCTAssertFalse(backingOff)
        XCTAssertTrue(newChoice)
    }

    // MARK: - Editions query

    func testEditionCoversParseFixtureReply() async throws {
        let client = HardcoverClient { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"), "Bearer fictional-token")
            let body =
                try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            XCTAssertTrue((body?["query"] as? String)?.contains("query EditionCovers") == true)
            XCTAssertEqual((body?["variables"] as? [String: Int])?["book"], 7)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(Self.editionsReply.utf8), response)
        }
        let covers = try await client.editionCovers(bookID: 7, token: "fictional-token")
        XCTAssertEqual(
            covers,
            [
                EditionCover(
                    editionID: 31, url: URL(string: "https://covers.example.com/e31.jpg")!,
                    format: "Paperback", year: 2019),
                EditionCover(
                    editionID: 33, url: URL(string: "https://covers.example.com/e33.jpg")!,
                    format: "Listened", year: nil),
                EditionCover(
                    editionID: 38, url: URL(string: "https://covers.example.com/e38.jpg")!,
                    format: nil, year: 2024),
            ])
    }

    /// Six editions are left out: 32 repeats an image, 34 has no image, 35 no URL, 36 uses
    /// plain HTTP, 37 is square art, and 39 is a thumbnail. Edition 33's blank format falls back
    /// to its reading format; edition 38 has no size, which passes.
    private static let editionsReply = """
        {"data":{"editions":[
          {"id":31,"edition_format":"Paperback","release_year":2019,"reading_format":{"format":"Read"},
           "image":{"url":"https://covers.example.com/e31.jpg","width":600,"height":900}},
          {"id":32,"edition_format":"Hardcover","release_year":2018,"reading_format":{"format":"Read"},
           "image":{"url":"https://covers.example.com/e31.jpg","width":600,"height":900}},
          {"id":33,"edition_format":"  ","release_year":null,"reading_format":{"format":"Listened"},
           "image":{"url":"https://covers.example.com/e33.jpg","width":500,"height":760}},
          {"id":34,"edition_format":"Ebook","release_year":2020,"reading_format":null,"image":null},
          {"id":35,"edition_format":null,"release_year":2020,"reading_format":null,
           "image":{"url":null,"width":600,"height":900}},
          {"id":36,"edition_format":"Paperback","release_year":2012,"reading_format":null,
           "image":{"url":"http://covers.example.com/e36.jpg","width":600,"height":900}},
          {"id":37,"edition_format":"Audiobook","release_year":2021,"reading_format":null,
           "image":{"url":"https://covers.example.com/e37.jpg","width":800,"height":800}},
          {"id":39,"edition_format":"Paperback","release_year":2001,"reading_format":null,
           "image":{"url":"https://covers.example.com/e39.jpg","width":120,"height":180}},
          {"id":38,"edition_format":null,"release_year":2024,"reading_format":null,
           "image":{"url":"https://covers.example.com/e38.jpg","width":null,"height":null}}
        ]}}
        """
}
