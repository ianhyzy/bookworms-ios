import Foundation
import XCTest

@testable import Bookworms

/// Covers series looks and links: the style series and look key rules the Apple TV app mirrors,
/// the record names and JSON the two apps share, and the create-only save that lets the first
/// look decide.
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
        XCTAssertNil(
            SeriesDesigns.styleSeries(of: inSeveral, link: link(1, series: 9999))?.position)
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
            SeriesDesigns.lookKey(of: book(3, by: "José Saramago", series: 9), link: nil),
            SeriesLookKey(seriesID: 9, group: "|josesaramago"))
        XCTAssertEqual(
            SeriesDesigns.lookKey(of: book(4, by: "", series: 9), link: nil)?.group, "|")
        XCTAssertNil(SeriesDesigns.lookKey(of: book(5), link: nil))
        // Books by the same first author match, even when a coauthor differs.
        XCTAssertTrue(
            SeriesDesigns.matches(
                book(6, by: "Ann Author, Co Writer", series: 9), book(7, series: 9)))
        XCTAssertFalse(
            SeriesDesigns.matches(
                book(8, by: "Co Writer, Ann Author", series: 9), book(9, series: 9)))
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
                from: Data(#"{"accountID":"42","syncedAt":0,"books":[],"designs":[]}"#.utf8))
        XCTAssertTrue(cache.looks.isEmpty)
        var snapshot = cache
        snapshot.looks = [look().key: look()]
        XCTAssertEqual(
            try JSONDecoder().decode(LibrarySnapshot.self, from: encoder.encode(snapshot)).looks,
            snapshot.looks)
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

    func testRecoloringALookKeepsARemakeFromAnotherDevice() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalSpineStore(folder: folder)
        let first = try await store.createLook(look())
        let colors = SpineColors(
            background: ColorValue(hex: "#000000")!, foreground: ColorValue(hex: "#FFFFFF")!,
            accent: ColorValue(hex: "#FF0000")!)
        try await store.saveRecolored(first.recolored(colors, at: created.addingTimeInterval(60)))

        // Another device remade the look in another font before this one saved its colors.
        let remade = first.remade(
            from: design(7, at: 60, family: "Lora"), at: created.addingTimeInterval(120))
        try await store.save(remade)
        do {
            try await store.saveRecolored(
                first.recolored(colors, at: created.addingTimeInterval(180)))
            XCTFail("A recoloring of a remade look was saved")
        } catch CompanionError.designChanged {}
        let kept = try await store.seriesLooks(accountID: "42", keys: [first.key])
        XCTAssertEqual(kept[first.key], remade)
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
