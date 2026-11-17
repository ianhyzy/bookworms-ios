import CloudKit
import Foundation
import XCTest

@testable import Bookworms

/// Covers series looks and links: the style series and look key rules the Apple TV app mirrors,
/// the record names and JSON the two apps share, the create-only save that lets the first look
/// decide, and how the CloudKit store saves over another device's changes.
final class SeriesLookTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_000_000)

    private func membership(
        _ id: Int, size: Int?, position: Double? = nil, featured: Bool = false,
        compilation: Bool = false
    ) -> SeriesMembership {
        SeriesMembership(
            seriesID: id, name: "Series \(id)", position: position, featured: featured,
            compilation: compilation, size: size)
    }

    private func book(
        _ id: Int, title: String = "A Volume", by author: String = "Ann Author",
        series: Int? = nil, memberships: [SeriesMembership]? = nil
    ) -> CloudBook {
        CloudBook(
            id: id, title: title, author: author, coverURL: nil, detailCoverURL: nil,
            seriesID: series, seriesPosition: series == nil ? nil : 4,
            seriesMemberships: memberships)
    }

    private func link(
        _ bookID: Int, series: Int? = nil, standsAlone: Bool = false, ownLook: Bool = false
    ) -> SeriesLinkV1 {
        SeriesLinkV1(
            version: 1, accountID: "42", bookID: bookID, linkedSeriesID: series,
            standsAlone: standsAlone, ownLook: ownLook, chosenAt: created)
    }

    private func design(
        _ bookID: Int, at seconds: TimeInterval = 0, provenance: String? = nil,
        family: String? = "EB Garamond", workItemHash: String = String(repeating: "a", count: 64)
    ) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: "42", bookID: bookID, workItemHash: workItemHash,
            coverHash: String(repeating: "b", count: 64),
            generatorVersion: CloudContract.generatorVersion,
            generatedAt: created.addingTimeInterval(seconds), backgroundHex: "#1A2B3C",
            foregroundHex: "#F0E0D0", accentHex: "#C0A060", typeface: "serif", weight: 700,
            uppercase: false, fontFamily: family, provenance: provenance)
    }

    private func look(_ group: String = "City Watch|terrypratchett") -> SeriesLookV1 {
        SeriesLookV1(
            version: 1, accountID: "42", seriesID: 1018, group: group, sourceBookID: 123,
            origin: "ios-pcc-v2", createdAt: created, backgroundHex: "#1A2B3C",
            foregroundHex: "#F0E0D0", accentHex: "#C0A060", typeface: "serif", weight: 700,
            uppercase: false, fontFamily: "EB Garamond", fontPostScriptName: "EBGaramond-Bold",
            instanceWeight: 700)
    }

    @MainActor func testSeriesSheetPicksRestoreTheDefaultForTheShortestSeries() {
        let discworld = membership(1018, size: 41, position: 8, featured: true)
        let watch = membership(2001, size: 8, position: 1)
        var linked = book(1, series: 1018, memberships: [discworld, watch])
        linked.seriesLink = link(1, series: 1018, ownLook: true)
        // The shortest series restores the default, and **Changes apply to** stays.
        let shortest = SeriesRows.Choice.picking(2001, for: linked)
        XCTAssertEqual(shortest.series, .standard)
        XCTAssertTrue(shortest.ownLook)
        XCTAssertEqual(
            SeriesRows.Choice.picking(1018, for: linked), SeriesRows.Choice(linked.seriesLink))
        // Another series links the book.
        let plain = book(2, series: 1018, memberships: [discworld, watch])
        XCTAssertEqual(SeriesRows.Choice.picking(1018, for: plain).series, .linked(1018))
        XCTAssertFalse(SeriesRows.Choice.picking(1018, for: plain).ownLook)
        // A book not in a series takes its shortest series again by default.
        var alone = book(3, memberships: [discworld, watch])
        alone.seriesLink = link(3, standsAlone: true)
        XCTAssertEqual(SeriesRows.Choice.picking(2001, for: alone).series, .standard)
        XCTAssertEqual(SeriesRows.Choice.picking(1018, for: alone).series, .linked(1018))
    }

    func testStyleSeriesTakesTheLinkThenTheShortestSeries() throws {
        let discworld = membership(1018, size: 41, position: 8, featured: true)
        let watch = membership(2001, size: 8, position: 1)
        let omnibus = membership(3001, size: 2, compilation: true)
        let single = membership(4001, size: 1)
        let unknown = membership(5001, size: nil)
        let inSeveral = book(1, series: 1018, memberships: [discworld, omnibus, single, watch])
        XCTAssertEqual(SeriesDesigns.styleSeries(of: inSeveral, link: nil)?.id, 2001)
        XCTAssertEqual(SeriesDesigns.styleSeries(of: inSeveral, link: nil)?.position, 1)

        // Unknown and one-book series sort after any known size; compilations sort last.
        XCTAssertEqual(
            SeriesDesigns.styleSeries(
                of: book(2, memberships: [single, unknown, discworld]), link: nil)?
                .id, 1018)
        XCTAssertEqual(
            SeriesDesigns.styleSeries(of: book(3, memberships: [omnibus, unknown]), link: nil)?.id,
            5001)
        // Equal sizes prefer the featured series, then the lower ID.
        let featured = membership(6002, size: 8, featured: true)
        XCTAssertEqual(
            SeriesDesigns.styleSeries(of: book(4, memberships: [watch, featured]), link: nil)?.id,
            6002)
        XCTAssertEqual(
            SeriesDesigns.styleSeries(
                of: book(5, memberships: [membership(7002, size: 8), watch]), link: nil)?
                .id, 2001)

        // Without memberships, from an older archive, the featured series decides.
        let older = book(6, series: 1018)
        XCTAssertEqual(SeriesDesigns.styleSeries(of: older, link: nil)?.id, 1018)
        XCTAssertEqual(SeriesDesigns.styleSeries(of: older, link: nil)?.position, 4)
        XCTAssertNil(SeriesDesigns.styleSeries(of: book(7, memberships: []), link: nil))

        // A link names the series, standing alone removes it, and a link that only keeps the
        // book's own look leaves the default.
        let linked = try XCTUnwrap(
            SeriesDesigns.styleSeries(of: inSeveral, link: link(1, series: 1018)))
        XCTAssertEqual(linked.id, 1018)
        XCTAssertEqual(linked.position, 8)
        // A linked series the book isn't in gives no position.
        let unlisted = try XCTUnwrap(
            SeriesDesigns.styleSeries(of: inSeveral, link: link(1, series: 9999)))
        XCTAssertEqual(unlisted.id, 9999)
        XCTAssertNil(unlisted.position)
        XCTAssertNil(
            SeriesDesigns.styleSeries(
                of: inSeveral, link: link(1, series: 1018, standsAlone: true)))
        XCTAssertEqual(
            SeriesDesigns.styleSeries(of: inSeveral, link: link(1, ownLook: true))?.id, 2001)
    }

    func testLookKeyJoinsTheDiscworldGroupAndFirstAuthor() {
        let guards = book(
            1, title: "Guards! Guards!", by: "Terry Pratchett, Another Writer", series: 1018)
        XCTAssertEqual(
            SeriesDesigns.lookKey(of: guards, link: nil),
            SeriesLookKey(seriesID: 1018, group: "City Watch|terrypratchett"))
        // A Discworld title in no group draws no series look.
        XCTAssertNil(
            SeriesDesigns.lookKey(
                of: book(2, title: "The Amazing Maurice", series: 1018), link: nil))
        XCTAssertEqual(
            SeriesDesigns.lookKey(of: book(3, by: "José Almendra", series: 9), link: nil),
            SeriesLookKey(seriesID: 9, group: "|josealmendra"))
        XCTAssertEqual(
            SeriesDesigns.lookKey(of: book(4, by: "", series: 9), link: nil)?.group, "|")
        XCTAssertNil(SeriesDesigns.lookKey(of: book(5), link: nil))
        // Books by the same first author match, even when a coauthor differs.
        XCTAssertTrue(
            sameLook(
                book(6, by: "Ann Author, Co Writer", series: 9), book(7, series: 9)))
        XCTAssertFalse(
            sameLook(
                book(8, by: "Co Writer, Ann Author", series: 9), book(9, series: 9)))
    }

    func testSeriesLabelNamesTheLinkedElseTheShortestSeries() throws {
        // Making Money's Hardcover series.
        let discworld = SeriesMembership(
            seriesID: 1018, name: "Discworld", position: 36, featured: true, compilation: false,
            size: 41)
        let moist = SeriesMembership(
            seriesID: 10604, name: "Discworld - Moist von Lipwig", position: 2, featured: false,
            compilation: false, size: 3)
        let industrial = SeriesMembership(
            seriesID: 10605, name: "Discworld - Industrial Revolution", position: 5,
            featured: false, compilation: false, size: 6)
        let makingMoney = book(
            377256, title: "Making Money", by: "Terry Pratchett", series: 1018,
            memberships: [discworld, moist, industrial])

        let shortest = try XCTUnwrap(SeriesDesigns.shownSeries(of: makingMoney, link: nil))
        XCTAssertEqual(shortest, moist)
        XCTAssertEqual(SeriesDesigns.place(in: shortest), "2 of 3")
        let linked = try XCTUnwrap(
            SeriesDesigns.shownSeries(of: makingMoney, link: link(377256, series: 10605)))
        XCTAssertEqual(linked, industrial)
        XCTAssertEqual(SeriesDesigns.place(in: linked), "5 of 6")
        XCTAssertEqual(
            SeriesDesigns.shownSeries(of: makingMoney, link: link(377256, ownLook: true)), moist)
        XCTAssertNil(
            SeriesDesigns.shownSeries(of: makingMoney, link: link(377256, standsAlone: true)))
        // A link to a series Hardcover no longer lists for the book names none.
        XCTAssertNil(
            SeriesDesigns.shownSeries(of: makingMoney, link: link(377256, series: 9999)))

        // Without memberships, the featured series shows when it has a name.
        var older = book(6, series: 1018)
        XCTAssertNil(SeriesDesigns.shownSeries(of: older, link: nil))
        older.seriesName = "Discworld"
        let featured = try XCTUnwrap(SeriesDesigns.shownSeries(of: older, link: nil))
        XCTAssertEqual(featured.name, "Discworld")
        XCTAssertEqual(SeriesDesigns.place(in: featured), "Book 4")
        XCTAssertNil(SeriesDesigns.shownSeries(of: book(7, memberships: []), link: nil))

        // A place outside the series' size, or a size unknown, falls back to the position alone.
        XCTAssertEqual(SeriesDesigns.place(in: membership(1, size: 3, position: 0)), "Book 0")
        XCTAssertEqual(SeriesDesigns.place(in: membership(1, size: 3, position: 2.5)), "2.5 of 3")
        XCTAssertEqual(SeriesDesigns.place(in: membership(1, size: 3, position: 4)), "Book 4")
        XCTAssertNil(SeriesDesigns.place(in: membership(1, size: 3)))
    }

    func testSeriesListingMarksTheReadersBooksInOrder() {
        func entry(_ id: Int, _ position: Double) -> SeriesInfo.SeriesBook {
            SeriesInfo.SeriesBook(
                id: id, title: "Volume \(id)", position: position, releaseYear: nil,
                coverURL: nil)
        }
        let info = SeriesInfo(
            id: 10605, name: "Discworld - Industrial Revolution",
            books: [entry(1, 1), entry(2, 2), entry(3, 3)])
        // The reader's edition of the second book has its own ID; a novella sits between books.
        let edition = book(20, memberships: [membership(10605, size: 3, position: 2)])
        let novella = book(21, memberships: [membership(10605, size: 3, position: 2.5)])
        let first = book(1, memberships: [membership(10605, size: 3, position: 1)])
        let elsewhere = book(22, memberships: [membership(99, size: 3, position: 1)])
        let library = [elsewhere, novella, edition, first]

        let listing = SeriesEntry.listing(series: 10605, info: info, library: library)
        XCTAssertEqual(listing.map(\.position), [1, 2, 2.5, 3])
        XCTAssertEqual(listing.map(\.book?.id), [1, 20, 21, nil])

        // Without Hardcover's list, the library's own books in the series show.
        let older = book(23, series: 10605)
        XCTAssertEqual(
            SeriesEntry.listing(series: 10605, info: nil, library: library + [older]).map(\.id),
            [1, 20, 21, 23])
    }

    /// **Series** opens for a book in two or more series, or for one whose series lists two or
    /// more books, as the Apple TV decides.
    func testSeriesOpensOnlyWithMoreThanTheBookToList() {
        let alone = book(30, memberships: [membership(500, size: 1, position: 1)])
        let solo = SeriesInfo(
            id: 500, name: "Series 500",
            books: [.init(id: 30, title: "A Volume", position: 1, releaseYear: nil, coverURL: nil)])
        XCTAssertFalse(SeriesEntry.opensSeries(of: alone, infos: [solo], library: [alone]))
        XCTAssertFalse(SeriesEntry.opensSeries(of: alone, infos: nil, library: [alone]))
        XCTAssertFalse(
            SeriesEntry.opensSeries(of: book(31, memberships: []), infos: nil, library: []))

        // A novella the reader owns joins the list, so the series has two books to show.
        let novella = book(32, memberships: [membership(500, size: 1, position: 1.5)])
        XCTAssertTrue(
            SeriesEntry.opensSeries(of: alone, infos: [solo], library: [alone, novella]))
        let listed = SeriesInfo(
            id: 500, name: "Series 500",
            books: solo.books + [
                .init(id: 33, title: "A Sequel", position: 2, releaseYear: nil, coverURL: nil)
            ])
        XCTAssertTrue(SeriesEntry.opensSeries(of: alone, infos: [listed], library: [alone]))

        // Two series to choose between open even with one book each.
        let both = book(
            34, memberships: [membership(500, size: 1, position: 1), membership(501, size: 1)])
        XCTAssertTrue(SeriesEntry.opensSeries(of: both, infos: nil, library: [both]))
    }

    func testRecordNamesMatchTheAppleTVContract() {
        XCTAssertEqual(
            CloudContract.seriesLookRecordName(
                accountID: "42",
                key: SeriesLookKey(seriesID: 1018, group: "City Watch|terrypratchett")),
            "series-look-v1-f6b8bd60e3d149603964e4149bb554dfad824022ea2eb99f8ca02e5708be48b1")
        XCTAssertEqual(
            CloudContract.seriesLinkRecordName(accountID: "42", bookID: 123),
            "series-link-v1-54bad7da96754d6c526b9e97c7ea7ee0fe033f6938e9a9a6dabd91758a7bb198")
        // The digest the Apple TV tests pin.
        XCTAssertEqual(
            CloudContract.seriesLinkRecordName(accountID: "42", bookID: 7),
            "series-link-v1-755dac3729029e2e2976249c4e03b160c699ef71f296c346e22183dc23503c33")
    }

    func testSeriesJSONUsesTheSharedKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func keys(_ value: some Encodable) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
            return Set(try XCTUnwrap(object as? [String: Any]).keys)
        }
        XCTAssertEqual(
            try keys(membership(1018, size: 41, position: 8, featured: true)),
            ["seriesID", "name", "position", "featured", "compilation", "size"])
        XCTAssertEqual(
            try keys(look()),
            [
                "version", "accountID", "seriesID", "group", "sourceBookID", "origin", "createdAt",
                "backgroundHex", "foregroundHex", "accentHex", "typeface", "weight", "uppercase",
                "fontFamily", "fontPostScriptName", "instanceWeight",
            ])
        // The optional keys, which the Apple TV reads by these names.
        var full = look()
        full.editedAt = created.addingTimeInterval(60)
        full.remadeAt = created.addingTimeInterval(120)
        full.provenance = ModelTier.onDeviceToken
        XCTAssertEqual(
            try keys(full).subtracting(try keys(look())), ["editedAt", "remadeAt", "provenance"])
        XCTAssertEqual(
            try JSONDecoder().decode(SeriesLookV1.self, from: encoder.encode(full)), full)
        XCTAssertEqual(
            try keys(link(123, series: 2001)),
            [
                "version", "accountID", "bookID", "linkedSeriesID", "standsAlone", "ownLook",
                "chosenAt",
            ])

        var edited = look()
        edited.editedAt = created.addingTimeInterval(60)
        XCTAssertEqual(
            try JSONDecoder().decode(SeriesLookV1.self, from: encoder.encode(edited)), edited)
        let standing = link(123, standsAlone: true)
        XCTAssertEqual(
            try JSONDecoder().decode(SeriesLinkV1.self, from: encoder.encode(standing)), standing)

        // Archives and caches saved before memberships and looks decode without them.
        let older = try JSONDecoder()
            .decode(
                CloudBook.self,
                from: Data(#"{"id":1,"title":"T","author":"A","seriesID":5}"#.utf8))
        XCTAssertNil(older.seriesMemberships)
        let cache = try JSONDecoder()
            .decode(
                LibrarySnapshot.self,
                from: Data(#"{"accountID":"42","syncedAt":0,"books":[],"designs":{}}"#.utf8))
        XCTAssertTrue(cache.looks.isEmpty)
        var snapshot = cache
        snapshot.looks = [look().key: look()]
        XCTAssertEqual(
            try JSONDecoder().decode(LibrarySnapshot.self, from: encoder.encode(snapshot)).looks,
            snapshot.looks)
    }

    /// A series choice saved over the book's link replaces only the choices the reader changed,
    /// so another device's choice saved meanwhile stays.
    func testSeriesChoicesReplaceOnlyWhatTheReaderChanged() {
        let television = link(7, series: 2001)
        // The reader keeps the book's own look on a device that still shows no link.
        XCTAssertEqual(
            link(7, ownLook: true).merged(over: television, changing: nil),
            link(7, series: 2001, ownLook: true))
        // The reader picks a series where another device kept the book's own look.
        XCTAssertEqual(
            link(7, series: 3001).merged(over: link(7, ownLook: true), changing: nil),
            link(7, series: 3001, ownLook: true))
        // Returning to the default series keeps the own look, and returning both changes all.
        let both = link(7, series: 2001, ownLook: true)
        XCTAssertEqual(
            link(7, ownLook: true).merged(over: both, changing: both), link(7, ownLook: true))
        XCTAssertTrue(link(7).merged(over: both, changing: both).changesNothing)
        XCTAssertEqual(
            link(7, standsAlone: true).merged(over: television, changing: nil),
            link(7, standsAlone: true))
        // A record for another book or account chooses nothing.
        XCTAssertEqual(
            link(7, ownLook: true).merged(over: link(8, series: 2001), changing: nil),
            link(7, ownLook: true))
    }

    func testLookValidationAppliesTheDesignRules() {
        XCTAssertNoThrow(try look().validate())
        func rejects(_ change: (inout SeriesLookV1) -> Void, _ message: String) {
            var changed = look()
            change(&changed)
            XCTAssertThrowsError(try changed.validate(), message)
        }
        rejects({ $0.foregroundHex = "#1A2B3D" }, "Unreadable colors")
        rejects({ $0.backgroundHex = "#1a2b3c" }, "Lowercase hex")
        rejects({ $0.instanceWeight = 750 }, "Instance weight off the hundreds")
        rejects({ $0.fontFamily = String(repeating: "x", count: 81) }, "Long family")
        rejects({ $0 = $0.withGroup(String(repeating: "g", count: 201)) }, "Long group")
        rejects({ $0 = $0.withOrigin(" ") }, "Blank origin")
        rejects({ $0 = $0.withOrigin(String(repeating: "o", count: 81)) }, "Long origin")
        rejects({ $0 = $0.withOrigin("ios-pcc-v2\nx") }, "Origin with a line break")
        XCTAssertNoThrow(try look().withGroup(String(repeating: "g", count: 200)).validate())
        XCTAssertThrowsError(try link(0).validate())
        XCTAssertTrue(link(1).changesNothing)
        XCTAssertFalse(link(1, ownLook: true).changesNothing)
    }

    func testLookDesignDrawsTheLookAsTheBooksOwnDesign() throws {
        var edited = look()
        edited.editedAt = created.addingTimeInterval(60)
        let saved = design(7)
        let drawn = edited.design(bookID: 7, hashesFrom: saved)
        XCTAssertEqual(drawn.bookID, 7)
        XCTAssertEqual(drawn.workItemHash, saved.workItemHash)
        XCTAssertEqual(drawn.generatorVersion, "ios-pcc-v2")
        XCTAssertEqual(drawn.generatedAt, edited.editedAt)
        XCTAssertEqual(drawn.fontPostScriptName, "EBGaramond-Bold")
        XCTAssertEqual(edited.design(bookID: 8).coverHash, SeriesLookV1.placeholderHash)
        XCTAssertNoThrow(try drawn.validate())

        // A look from the Apple TV names a system face and no family.
        var television = look()
        television.fontFamily = nil
        television.fontPostScriptName = "Georgia-Bold"
        television.instanceWeight = nil
        let fromTV = SeriesLookV1(
            design: television.design(bookID: 9), key: television.key, createdAt: created)
        XCTAssertNoThrow(try fromTV.validate())
        XCTAssertEqual(fromTV.design(bookID: 9).fontPostScriptName, "Georgia-Bold")
    }

    func testRemadeLookTakesTheNewDesignAndKeepsItsCreation() throws {
        let redesigned = design(7, at: 60, family: "Lora")
        let remade = look().remade(from: redesigned, at: created.addingTimeInterval(120))
        XCTAssertEqual(remade.key, look().key)
        XCTAssertEqual(remade.createdAt, created)
        XCTAssertEqual(remade.editedAt, created.addingTimeInterval(120))
        XCTAssertEqual(remade.sourceBookID, 7)
        XCTAssertEqual(remade.origin, CloudContract.generatorVersion)
        XCTAssertEqual(remade.fontFamily, "Lora")
        XCTAssertNil(remade.fontPostScriptName)
        XCTAssertNoThrow(try remade.validate())
    }

    func testLooksKeepTheirSourceDesignsModelToken() throws {
        let onDevice = SeriesLookV1(
            design: design(
                7,
                provenance: "series-reuse:3 generated-colors:000000,FFFFFF,FF0000 "
                    + ModelTier.onDeviceToken),
            key: look().key, createdAt: created)
        XCTAssertEqual(onDevice.provenance, ModelTier.onDeviceToken, "Only the model token")
        XCTAssertEqual(onDevice.editedAt, created, "The recolored design's colors are the reader's")
        XCTAssertEqual(onDevice.tier, .onDevice)
        XCTAssertEqual(onDevice.design(bookID: 8).tier, .onDevice, "Copies keep the tier")
        XCTAssertEqual(
            onDevice.remade(from: design(7, provenance: "model:local"), at: created).tier, .local)
        XCTAssertNoThrow(try onDevice.validate())
        XCTAssertEqual(
            try JSONDecoder().decode(SeriesLookV1.self, from: JSONEncoder().encode(onDevice)),
            onDevice)

        XCTAssertNil(look().provenance)
        XCTAssertEqual(look().tier, .privateCloudCompute, "No token is Private Cloud Compute")
        XCTAssertEqual(look().withOrigin(CloudContract.appleTVGeneratorVersion).tier, .local)
        var long = onDevice
        long.provenance = String(repeating: "p", count: 81)
        XCTAssertThrowsError(try long.validate(), "Long provenance")
    }

    func testWeakerUneditedLooksUpgradeFromTheirSourceBook() {
        var onDevice = look()
        onDevice.provenance = ModelTier.onDeviceToken
        XCTAssertTrue(onDevice.isUpgraded(at: .backup))
        XCTAssertTrue(onDevice.isUpgraded(at: .privateCloudCompute))
        XCTAssertFalse(onDevice.isUpgraded(at: .onDevice), "The first look decides equal tiers")
        XCTAssertFalse(onDevice.isUpgraded(at: .local))
        XCTAssertFalse(look().isUpgraded(at: .privateCloudCompute))
        // A capable model's look stays, whichever of them runs.
        XCTAssertFalse(look().isUpgraded(at: .backup))
        var backup = look()
        backup.provenance = "model:openai/gpt-6-luna"
        XCTAssertEqual(backup.tier, .backup)
        XCTAssertFalse(backup.isUpgraded(at: .privateCloudCompute))
        var edited = onDevice
        edited.editedAt = created.addingTimeInterval(60)
        XCTAssertFalse(edited.isUpgraded(at: .privateCloudCompute), "The reader's edit stays")

        func covered(_ book: CloudBook) -> CloudBook {
            var book = book
            book.chosenCoverURL = URL(string: "https://example.com/\(book.id).jpg")
            return book
        }
        var first = covered(book(1, series: 1018))
        first.seriesPosition = 1
        let members = [covered(book(123, series: 1018)), first, book(2, series: 1018)]
        XCTAssertEqual(onDevice.upgradeSource(among: members), 123, "The look's source book")
        XCTAssertEqual(
            onDevice.upgradeSource(among: Array(members.dropFirst())), 1,
            "The best-ranked member once the source left the group")
        XCTAssertEqual(
            onDevice.withOrigin(CloudContract.appleTVGeneratorVersion)
                .upgradeSource(among: members), 1,
            "An Apple TV look upgrades from the best-ranked member")
        XCTAssertNil(onDevice.upgradeSource(among: [book(2, series: 1018)]), "No cover")
    }

    func testLooksAwaitingTheirFontUpgradeOnceItDownloads() {
        let awaiting = SeriesLookV1(
            design: design(
                7, provenance: "series-reuse:3 model:local font:system", family: nil),
            key: look().key, createdAt: created)
        XCTAssertEqual(awaiting.provenance, "model:local font:system")
        XCTAssertTrue(awaiting.awaitsFont)
        XCTAssertEqual(awaiting.tier, .local)
        XCTAssertTrue(awaiting.design(bookID: 8).awaitsFont, "Copies await the font too")
        XCTAssertTrue(awaiting.isUpgraded(at: .local), "A design with its font replaces it")
        XCTAssertFalse(
            awaiting.isUpgraded(at: .local, awaitingFont: true), "Another stand-in doesn't")
        XCTAssertTrue(awaiting.isUpgraded(at: .onDevice, awaitingFont: true))
        var edited = awaiting
        edited.editedAt = created.addingTimeInterval(60)
        XCTAssertFalse(edited.isUpgraded(at: .local), "The reader's edit stays")
        var local = look()
        local.provenance = ModelTier.localToken
        XCTAssertFalse(local.isUpgraded(at: .local), "The first look decides equal tiers")
        // A redesign during a font outage remakes the look unedited, so it upgrades later.
        let remade = look()
            .remade(
                from: design(7, provenance: "model:local font:system", family: nil),
                at: created.addingTimeInterval(120))
        XCTAssertNil(remade.editedAt)
        XCTAssertEqual(remade.remadeAt, created.addingTimeInterval(120))
        XCTAssertTrue(remade.isUpgraded(at: .local), "A run that reaches the font upgrades it")
    }

    func testLooksReadOtherGeneratorsAndKeepTheReadersColors() throws {
        // A look seeded from the retired Mac companion's on-device design, in either version,
        // upgrades only from a better tier.
        for origin in [CloudContract.macGeneratorVersion, "mac-foundation-models-v1"] {
            let mac = look().withOrigin(origin)
            XCTAssertNil(mac.provenance)
            XCTAssertEqual(mac.tier, .onDevice, origin)
            XCTAssertTrue(mac.isUpgraded(at: .privateCloudCompute), origin)
            XCTAssertTrue(mac.isUpgraded(at: .backup), origin)
            XCTAssertFalse(mac.isUpgraded(at: .onDevice), origin)
            XCTAssertFalse(mac.isUpgraded(at: .local), origin)
        }
        // Builds that read the companion's first generator as local defaults wrote `model:local`
        // into the looks they made from its designs; those looks still read as on-device, and
        // copies of them record the on-device token.
        var misread = look().withOrigin("mac-foundation-models-v1")
        misread.provenance = ModelTier.localToken
        XCTAssertEqual(misread.tier, .onDevice)
        XCTAssertFalse(misread.isUpgraded(at: .onDevice))
        XCTAssertTrue(misread.isUpgraded(at: .privateCloudCompute))
        XCTAssertEqual(misread.design(bookID: 9).tierTokens, [ModelTier.onDeviceToken])
        var local = look()
        local.provenance = ModelTier.localToken
        XCTAssertEqual(local.tier, .local, "This app's local looks stay local")

        // A look seeded from this app's earlier Private Cloud Compute design upgrades from no
        // tier.
        let earlier = look().withOrigin("ios-pcc-v1")
        XCTAssertEqual(earlier.tier, .privateCloudCompute)
        XCTAssertFalse(earlier.isUpgraded(at: .privateCloudCompute))
        XCTAssertFalse(earlier.isUpgraded(at: .onDevice))

        // A look with a recolored design's tokens lends only its model token, so a copy takes
        // the look's own colors, and no upgrade replaces them.
        var tagged = look()
        tagged.provenance =
            "series-reuse:3 generated-colors:000000,FFFFFF,FF0000 " + ModelTier.onDeviceToken
        XCTAssertEqual(tagged.tier, .onDevice)
        let drawn = tagged.design(bookID: 8)
        XCTAssertEqual(drawn.provenance, ModelTier.onDeviceToken)
        XCTAssertNil(drawn.generatedColors)
        XCTAssertEqual(drawn.tier, .onDevice)
        XCTAssertFalse(tagged.isUpgraded(at: .privateCloudCompute))

        // A look seeded from a design the reader recolored counts as edited.
        let member = book(7, series: 9)
        let hash = CloudContract.workItemHash(accountID: "42", book: member)
        let own = design(7, provenance: ModelTier.onDeviceToken, workItemHash: hash)
        let recolored = own.recolored(
            SpineColors(
                background: ColorValue(hex: "#000000")!, foreground: ColorValue(hex: "#FFFFFF")!,
                accent: ColorValue(hex: "#FF0000")!))
        let seeded = try XCTUnwrap(
            SeriesDesigns.missingLooks(
                books: [member], designs: [7: recolored], looks: [:], now: created
            )
            .first)
        XCTAssertEqual(seeded.editedAt, created)
        XCTAssertEqual(seeded.tier, .onDevice)
        XCTAssertFalse(seeded.isUpgraded(at: .privateCloudCompute), "The reader's colors stay")
        XCTAssertTrue(
            SeriesLookV1(design: own, key: seeded.key, createdAt: created)
                .isUpgraded(at: .privateCloudCompute))
    }

    /// A look of another contract version, such as a newer build's, is never replaced, even by
    /// a remake that a requested redesign saves.
    func testSavingALookRefusesToReplaceAnotherVersionsLook() async throws {
        var newer = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(look())) as? [String: Any])
        newer["version"] = 2
        let payload = try JSONSerialization.data(withJSONObject: newer)
        let name = CloudContract.seriesLookRecordName(accountID: "42", key: look().key)
        let database = ChangeTagDatabase()
        await database.put(payload: payload, type: "SeriesLookV1", name: name)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "series-looks-v1.json")
        try JSONSerialization.data(withJSONObject: [name: newer]).write(to: file)
        let stores: [any SpineStore] = [
            try await CloudSpineStore.checked(database), LocalSpineStore(folder: folder),
        ]
        for store in stores {
            do {
                try await store.save(look())
                XCTFail("\(type(of: store)) replaced a newer build's look")
            } catch CompanionError.unsupportedCloudData {}
        }
        let kept = await database.payload(named: name)
        XCTAssertEqual(kept, payload)
    }

    func testUpgradingALookKeepsEditsAndBetterLooks() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalSpineStore(folder: folder)
        let local = look().withOrigin(CloudContract.appleTVGeneratorVersion)
        func upgrade(_ provenance: String?, family: String = "Lora") -> SeriesLookV1 {
            SeriesLookV1(
                design: design(7, provenance: provenance, family: family), key: local.key,
                createdAt: local.createdAt)
        }

        let missing = try await store.upgradeLook(upgrade(ModelTier.onDeviceToken))
        XCTAssertEqual(missing.tier, .onDevice, "A group without a look gets one")
        let tied = try await store.upgradeLook(
            upgrade(ModelTier.onDeviceToken, family: "Merriweather"))
        XCTAssertEqual(tied, missing, "An equal tier keeps the saved look")
        let better = try await store.upgradeLook(upgrade(nil))
        XCTAssertEqual(better.tier, .privateCloudCompute)
        XCTAssertEqual(better.createdAt, local.createdAt)
        let worse = try await store.upgradeLook(upgrade(ModelTier.onDeviceToken))
        XCTAssertEqual(worse, better, "A weaker look never replaces a better one")

        try await store.save(
            local.recolored(
                SpineColors(
                    background: ColorValue(hex: "#000000")!,
                    foreground: ColorValue(hex: "#FFFFFF")!,
                    accent: ColorValue(hex: "#FF0000")!), at: created.addingTimeInterval(60)))
        let edited = try await store.upgradeLook(upgrade(nil))
        XCTAssertEqual(edited.origin, CloudContract.appleTVGeneratorVersion, "The edit stays")
        let saved = try await store.seriesLooks(accountID: "42", keys: [local.key])
        XCTAssertEqual(saved[local.key], edited)
    }

    /// A look from an earlier generator version keeps its tier, so only a better tier's design
    /// replaces it.
    func testOnlyABetterTierUpgradesAnEarlierGeneratorsLook() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalSpineStore(folder: folder)
        let companion = look().withOrigin("mac-foundation-models-v1")
        try await store.save(companion)
        func upgrade(_ provenance: String?) -> SeriesLookV1 {
            SeriesLookV1(
                design: design(7, provenance: provenance, family: "Lora"), key: companion.key,
                createdAt: companion.createdAt)
        }
        let onDevice = try await store.upgradeLook(upgrade(ModelTier.onDeviceToken))
        XCTAssertEqual(onDevice, companion, "The same tier keeps the saved look")
        let backup = try await store.upgradeLook(upgrade("model:openai/gpt-6-luna"))
        XCTAssertEqual(backup.tier, .backup)
        XCTAssertEqual(backup.createdAt, companion.createdAt)

        let earlier = look().withOrigin("ios-pcc-v1")
        try await store.save(earlier)
        let kept = try await store.upgradeLook(upgrade("model:openai/gpt-6-luna"))
        XCTAssertEqual(kept, earlier, "No tier upgrades a Private Cloud Compute look")
    }

    @MainActor
    func testLookWithoutAFamilyDrawsAnInstalledFace() async {
        let fonts = SpineFonts()
        var installed = design(1, family: nil)
        installed.fontPostScriptName = "Georgia-Bold"
        var missing = design(2, family: nil)
        missing.fontPostScriptName = "NoSuchFace-Bold"
        await fonts.load([installed, missing])
        XCTAssertEqual(fonts.face(for: installed)?.postScriptName, "Georgia-Bold")
        XCTAssertNil(fonts.face(for: missing), "A missing face draws the system typeface")
    }

    /// A load tries a face once, however many of its designs name it, so a family that can't
    /// download holds the load up once, not once for each of its books.
    @MainActor
    func testLoadTriesAFaceOnceForTheDesignsThatShareIt() async {
        OfflineURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-fonts-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        let fonts = SpineFonts(downloader: GoogleFonts(root: root, configuration: configuration))
        await fonts.load([design(1), design(2), design(3)])
        XCTAssertEqual(OfflineURLProtocol.count, 1, "One request, for the catalog")
        XCTAssertNil(fonts.face(for: design(1)))
        await fonts.load([design(1)])
        XCTAssertEqual(OfflineURLProtocol.count, 2, "A network failure retries on the next load")
    }

    func testMissingLooksCopyTheEarliestOriginalDesign() throws {
        var books = [
            book(1, series: 9), book(2, series: 9), book(3, series: 9),
            book(4, by: "Another Writer", series: 9), book(5, series: 9), book(6, series: 12),
            book(7, series: 12),
        ]
        books[6].seriesLink = link(7, ownLook: true)
        func current(_ id: Int) -> String {
            CloudContract.workItemHash(accountID: "42", book: books[id - 1])
        }
        let designs = [
            // A reuse copy made earliest loses to the earliest original.
            1: design(
                1, at: 0, provenance: "series-reuse:9 generated-colors:000000,FFFFFF,FF0000",
                workItemHash: current(1)),
            2: design(2, at: 30, workItemHash: current(2)),
            3: design(3, at: 20, family: "Impact", workItemHash: current(3)),
            4: design(4, at: 50, provenance: "series-reuse:3", workItemHash: current(4)),
            // Made for the book's earlier metadata, so it is out of date.
            5: design(5, at: 5),
            7: design(7, at: 10, workItemHash: current(7)),
        ]
        let made =
            SeriesDesigns.missingLooks(
                books: books, designs: designs, looks: [:], now: created
            )
            .sorted { $0.group < $1.group }
        XCTAssertEqual(made.map(\.group), ["|annauthor", "|anotherwriter"])
        XCTAssertEqual(
            made.map(\.sourceBookID), [2, 4],
            "Book 3's Impact face is not usable, and book 5's design is out of date")
        XCTAssertEqual(made.map(\.seriesID), [9, 9], "Book 7 keeps its own look")
        XCTAssertEqual(made.first?.origin, CloudContract.generatorVersion)
        XCTAssertEqual(made.first?.createdAt, created)
        XCTAssertNoThrow(try made.first?.validate())

        let existing = try XCTUnwrap(made.first)
        XCTAssertEqual(
            SeriesDesigns.missingLooks(
                books: books, designs: designs, looks: [existing.key: existing], now: created
            )
            .map(\.group), ["|anotherwriter"], "A group with a look keeps it")
    }

    func testCreatingALookKeepsTheFirstOneSaved() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalSpineStore(folder: folder)
        let first = look()
        var second = look()
        second.backgroundHex = "#000000"
        second.foregroundHex = "#FFFFFF"

        let kept = try await store.createLook(first)
        let raced = try await store.createLook(second)
        XCTAssertEqual(kept, first)
        XCTAssertEqual(raced, first, "The first look saved decides the group")
        let saved = try await store.seriesLooks(accountID: "42", keys: [first.key])
        XCTAssertEqual(saved, [first.key: first])

        // An edit replaces the look.
        let recolored = first.recolored(
            SpineColors(
                background: ColorValue(hex: "#000000")!, foreground: ColorValue(hex: "#FFFFFF")!,
                accent: ColorValue(hex: "#FF0000")!), at: created.addingTimeInterval(60))
        try await store.save(recolored)
        let edited = try await store.seriesLooks(accountID: "42", keys: [first.key])
        XCTAssertEqual(edited[first.key]?.backgroundHex, "#000000")
        XCTAssertEqual(edited[first.key]?.origin, first.origin)
        XCTAssertEqual(edited[first.key]?.editedAt, created.addingTimeInterval(60))
    }

    /// A reader's edit applies to the look as the store holds it: another device's font stays
    /// under this device's colors, and a remake from another device takes the reader's font.
    /// Only a group without a look refuses the edit. A generated upgrade still saves only over
    /// the look it read (`saveEdited(_:replacing:)`).
    func testReaderEditsApplyToTheLookAnotherDeviceChanged() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalSpineStore(folder: folder)
        let first = try await store.createLook(look())
        let lora = SeriesLookEdit.font(
            family: "Lora", postScriptName: "Lora-Bold", instanceWeight: 700, typeface: "serif")

        // Another device sets the font; this one, still showing `first`, then sets colors.
        try await store.saveReaderEdit(lora, at: created.addingTimeInterval(60), to: first)
        try await store.saveReaderEdit(
            .colors(colors), at: created.addingTimeInterval(120), to: first)
        var saved = try await store.seriesLooks(accountID: "42", keys: [first.key])
        XCTAssertEqual(saved[first.key]?.fontFamily, "Lora")
        XCTAssertEqual(saved[first.key]?.backgroundHex, colors.background.hex)
        XCTAssertEqual(saved[first.key]?.editedAt, created.addingTimeInterval(120))

        // A generated upgrade from `first` leaves the edited look.
        do {
            try await store.saveEdited(
                first.upgraded(from: design(7, at: 180), at: created.addingTimeInterval(180)),
                replacing: first)
            XCTFail("An upgrade replaced the reader's edits")
        } catch CompanionError.designChanged {}

        // Another device remakes the look; a font picked on `first` lands on the remake.
        let remade = first.remade(
            from: design(7, at: 240, family: "EB Garamond"), at: created.addingTimeInterval(240))
        try await store.save(remade)
        try await store.saveReaderEdit(lora, at: created.addingTimeInterval(300), to: first)
        saved = try await store.seriesLooks(accountID: "42", keys: [first.key])
        XCTAssertEqual(
            saved[first.key], lora.applied(to: remade, at: created.addingTimeInterval(300)))

        do {
            try await store.saveReaderEdit(
                .colors(colors), at: created.addingTimeInterval(360),
                to: look("Ankh-Morpork|terrypratchett"))
            XCTFail("An edit was saved for a group without a look")
        } catch CompanionError.designChanged {}
    }

    /// A design finished after the reader changed the book's series choice is stale, so it
    /// seeds no look for a group the book has left.
    func testAChangedSeriesChoiceMakesADesignStale() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = """
            {"version":1,"sources":[{"source":"hardcover","accountID":"42","syncedAt":800000000,
              "books":[{"id":7,"title":"A Volume","author":"Ann Author","seriesID":9}]}]}
            """
        try Data(archive.utf8).write(to: folder.appending(path: "library-v1.json"))
        let store = LocalSpineStore(folder: folder)
        let loaded = try await store.loadWork()
        let work = try XCTUnwrap(loaded)
        let designing = try XCTUnwrap(work.books.first)
        let unchanged = try await store.isStillCurrent(work, book: designing)
        XCTAssertTrue(unchanged)

        let name = CloudContract.seriesLinkRecordName(accountID: "42", bookID: 7)
        try JSONEncoder().encode([name: link(7, ownLook: true)])
            .write(to: folder.appending(path: "series-links-v1.json"))
        let changed = try await store.isStillCurrent(work, book: designing)
        XCTAssertFalse(changed)
    }

    // MARK: - The CloudKit store

    private var lookName: String {
        CloudContract.seriesLookRecordName(accountID: "42", key: look().key)
    }

    private let colors = SpineColors(
        background: ColorValue(hex: "#000000")!, foreground: ColorValue(hex: "#FFFFFF")!,
        accent: ColorValue(hex: "#FF0000")!)

    func testCloudStoreCreatesALookOnlyWhenTheGroupHasNone() async throws {
        let database = ChangeTagDatabase()
        let store = try await CloudSpineStore.checked(database)
        let first = look()
        var second = look()
        second.backgroundHex = "#000000"
        second.foregroundHex = "#FFFFFF"

        let created = try await store.createLook(first)
        let raced = try await store.createLook(second)
        XCTAssertEqual(created, first)
        XCTAssertEqual(raced, first, "The look another device saved first decides the group")
        let saved = try await store.seriesLooks(accountID: "42", keys: [first.key])
        XCTAssertEqual(saved, [first.key: first])
    }

    func testCloudStoreUpgradesALookOnlyWhileItIsStillUnedited() async throws {
        let database = ChangeTagDatabase()
        let store = try await CloudSpineStore.checked(database)
        var onDevice = look()
        onDevice.provenance = ModelTier.onDeviceToken
        try await database.put(onDevice, type: "SeriesLookV1", name: lookName)
        let upgrade = SeriesLookV1(
            design: design(123, family: "Lora"), key: onDevice.key, createdAt: created)

        // The reader recolors the look on another device between this save's read and write.
        let edited = onDevice.recolored(colors, at: created.addingTimeInterval(60))
        try await database.putAfterNextFetch(edited, type: "SeriesLookV1", name: lookName)
        let kept = try await store.upgradeLook(upgrade)
        XCTAssertEqual(kept, edited)
        let saved = try await store.seriesLooks(accountID: "42", keys: [onDevice.key])
        XCTAssertEqual(saved[onDevice.key], edited)

        // Without the edit, the better tier's look replaces it.
        try await database.put(onDevice, type: "SeriesLookV1", name: lookName)
        let upgraded = try await store.upgradeLook(upgrade)
        XCTAssertEqual(upgraded, upgrade)

        // A newer build's look is never replaced.
        var newer = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(onDevice)) as? [String: Any])
        newer["version"] = 2
        await database.put(
            payload: try JSONSerialization.data(withJSONObject: newer), type: "SeriesLookV1",
            name: lookName)
        do {
            _ = try await store.upgradeLook(upgrade)
            XCTFail("A newer build's look was replaced")
        } catch CompanionError.unsupportedCloudData {}
    }

    /// A reader's edit that races another device's remake applies to the remake, and a
    /// generated upgrade saves only over the look it read.
    func testCloudStoreAppliesAReaderEditToTheLookItHolds() async throws {
        let database = ChangeTagDatabase()
        let store = try await CloudSpineStore.checked(database)
        let first = look()
        try await database.put(first, type: "SeriesLookV1", name: lookName)

        // Another device remakes the look between the next save's read and write.
        let remade = first.remade(
            from: design(7, at: 60, family: "Lora"), at: created.addingTimeInterval(60))
        try await database.putAfterNextFetch(remade, type: "SeriesLookV1", name: lookName)
        try await store.saveReaderEdit(
            .colors(colors), at: created.addingTimeInterval(120), to: first)
        var kept = try await store.seriesLooks(accountID: "42", keys: [first.key])
        XCTAssertEqual(
            kept[first.key], remade.recolored(colors, at: created.addingTimeInterval(120)))

        do {
            try await store.saveEdited(
                first.upgraded(from: design(7, at: 180), at: created.addingTimeInterval(180)),
                replacing: first)
            XCTFail("An upgrade replaced a look it didn't read")
        } catch CompanionError.designChanged {}
        kept = try await store.seriesLooks(accountID: "42", keys: [first.key])
        XCTAssertEqual(kept[first.key]?.backgroundHex, colors.background.hex)
    }

    func testCloudStoreSavesOnlyTheSeriesChoicesTheReaderChanged() async throws {
        let database = ChangeTagDatabase()
        let store = try await CloudSpineStore.checked(database)
        let name = CloudContract.seriesLinkRecordName(accountID: "42", bookID: 7)
        // The Apple TV picks a series while this device still shows no link.
        try await database.putAfterNextFetch(
            link(7, series: 2001), type: "SeriesLinkV1", name: name)
        let both = try await store.save(link(7, ownLook: true), replacing: nil)
        XCTAssertEqual(both, link(7, series: 2001, ownLook: true))
        let saved = try await database.payload(named: name)
            .map { try JSONDecoder().decode(SeriesLinkV1.self, from: $0) }
        XCTAssertEqual(saved, both)

        // Returning to the default series and to the series' look deletes the record.
        let cleared = try await store.save(link(7), replacing: both)
        XCTAssertNil(cleared)
        let deleted = await database.payload(named: name)
        XCTAssertNil(deleted)
    }

    func testCloudStoreGivesUpAfterThreeConflicts() async throws {
        let database = ChangeTagDatabase()
        let store = try await CloudSpineStore.checked(database)
        await database.refuseEverySave()
        do {
            try await store.save(look())
            XCTFail("A save that always conflicts succeeded")
        } catch CompanionError.cloudConflict {}
        let attempts = await database.saveAttempts
        XCTAssertEqual(attempts, 3)
    }

    /// Returns whether `book` and `other` draw one series look: the same non-nil look key.
    private func sameLook(_ book: CloudBook, _ other: CloudBook) -> Bool {
        guard let key = SeriesDesigns.lookKey(of: book, link: book.seriesLink) else {
            return false
        }
        return key == SeriesDesigns.lookKey(of: other, link: other.seriesLink)
    }
}

/// Stands in for the private database as saves with `ifServerRecordUnchanged` see it: each
/// record has a change tag that every save advances, so saving a record fetched before the
/// latest save, or a new record whose name exists, fails with `CKError.serverRecordChanged`.
/// A `LibraryArchive` record keeps its JSON in an `archive` asset, as CloudKit does.
actor ChangeTagDatabase: SpineCloudDatabase {
    private var stored: [String: (type: String, payload: Data, tag: Int)] = [:]
    /// The records this database returned, with the change tag each had then.
    private var served: [(record: CKRecord, tag: Int)] = []
    /// Another device's save, which lands right after the next fetch of its record.
    private var interjected: (name: String, type: String, payload: Data)?
    private var refusesSaves = false
    /// The error every save throws, when set (`failEverySave(with:)`).
    private var saveFailure: CKError.Code?
    private(set) var saveAttempts = 0
    /// Holds the asset files of fetched archives; removed with the database.
    private let assets = FileManager.default.temporaryDirectory.appending(
        path: "change-tag-database-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: assets) }

    /// Saves `value` as the `payload` of the named record of `type`, as another device would.
    func put(_ value: some Encodable & Sendable, type: String, name: String) throws {
        store(try JSONEncoder().encode(value), type: type, name: name)
    }

    /// Saves `payload` as the named record of `type`, as another device would.
    func put(payload: Data, type: String, name: String) {
        store(payload, type: type, name: name)
    }

    /// Saves `value` as another device would, right after the next fetch of the named record,
    /// whether or not the record exists then.
    func putAfterNextFetch(_ value: some Encodable & Sendable, type: String, name: String)
        throws
    {
        interjected = (name, type, try JSONEncoder().encode(value))
    }

    func refuseEverySave() { refusesSaves = true }

    func failEverySave(with code: CKError.Code) { saveFailure = code }

    func payload(named name: String) -> Data? { stored[name]?.payload }

    func record(for id: CKRecord.ID) throws -> CKRecord {
        defer {
            if let interjected, interjected.name == id.recordName {
                self.interjected = nil
                store(interjected.payload, type: interjected.type, name: interjected.name)
            }
        }
        guard let entry = stored[id.recordName] else { throw CKError(.unknownItem) }
        let record = CKRecord(recordType: entry.type, recordID: id)
        if entry.type == "LibraryArchive" {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let file = assets.appending(path: "\(UUID().uuidString).json")
            try entry.payload.write(to: file)
            record["archive"] = CKAsset(fileURL: file)
        } else {
            record["payload"] = entry.payload as NSData
        }
        served.append((record, entry.tag))
        return record
    }

    func records(for ids: [CKRecord.ID]) -> [CKRecord.ID: Result<CKRecord, any Error>] {
        Dictionary(uniqueKeysWithValues: ids.map { id in (id, Result { try record(for: id) }) })
    }

    func saveIfUnchanged(_ record: CKRecord) throws {
        saveAttempts += 1
        if let saveFailure { throw CKError(saveFailure) }
        let name = record.recordID.recordName
        if let current = stored[name],
            !served.contains(where: { $0.record === record && $0.tag == current.tag })
        {
            throw CKError(.serverRecordChanged)
        }
        let archive = (record["archive"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        guard !refusesSaves, let payload = record["payload"] as? Data ?? archive else {
            throw CKError(.serverRecordChanged)
        }
        store(payload, type: record.recordType, name: name)
    }

    func delete(_ id: CKRecord.ID) {
        stored[id.recordName] = nil
    }

    private func store(_ payload: Data, type: String, name: String) {
        stored[name] = (type, payload, (stored[name]?.tag ?? 0) + 1)
    }
}

extension SeriesLookV1 {
    fileprivate func withGroup(_ group: String) -> SeriesLookV1 {
        SeriesLookV1(
            version: version, accountID: accountID, seriesID: seriesID, group: group,
            sourceBookID: sourceBookID, origin: origin, createdAt: createdAt,
            backgroundHex: backgroundHex, foregroundHex: foregroundHex, accentHex: accentHex,
            typeface: typeface, weight: weight, uppercase: uppercase, fontFamily: fontFamily,
            fontPostScriptName: fontPostScriptName, instanceWeight: instanceWeight)
    }

    fileprivate func withOrigin(_ origin: String) -> SeriesLookV1 {
        SeriesLookV1(
            version: version, accountID: accountID, seriesID: seriesID, group: group,
            sourceBookID: sourceBookID, origin: origin, createdAt: createdAt,
            backgroundHex: backgroundHex, foregroundHex: foregroundHex, accentHex: accentHex,
            typeface: typeface, weight: weight, uppercase: uppercase, fontFamily: fontFamily,
            fontPostScriptName: fontPostScriptName, instanceWeight: instanceWeight)
    }
}
