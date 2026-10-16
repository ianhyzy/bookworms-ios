import CoreText
import Foundation
import XCTest

@testable import Bookworms

/// Covers the reader's spine colors: the provenance record that Reset restores from, the
/// contrast gate, which saved designs a generation run keeps, series reuse, alignment, and looks,
/// and the preview store's save.
final class SpineColorsTests: XCTestCase {
    private let work = String(repeating: "a", count: 64)
    private let cover = String(repeating: "b", count: 64)
    private let reader = SpineColors(
        background: ColorValue(hex: "#1A2B3C")!, foreground: ColorValue(hex: "#F4E9D0")!,
        accent: ColorValue(hex: "#C08040")!)

    private func design(
        generator: String = CloudContract.generatorVersion, provenance: String? = nil
    ) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: "42", bookID: 7, workItemHash: work, coverHash: cover,
            generatorVersion: generator, generatedAt: Date(timeIntervalSince1970: 1_000_000),
            backgroundHex: "#000000", foregroundHex: "#FFFFFF", accentHex: "#FF0000",
            typeface: "serif", weight: 600, uppercase: false, fontFamily: "EB Garamond",
            provenance: provenance)
    }

    func testRecoloringRecordsGeneratedColorsAndResetRemovesThem() throws {
        let generated = design(provenance: "series-reuse:12")
        let original = try XCTUnwrap(generated.colors)
        XCTAssertNil(generated.generatedColors)

        let recolored = generated.recolored(reader)
        XCTAssertNoThrow(try recolored.validate())
        XCTAssertEqual(recolored.colors, reader)
        XCTAssertEqual(recolored.generatedColors, original)
        XCTAssertEqual(
            recolored.provenance, "series-reuse:12 generated-colors:000000,FFFFFF,FF0000")
        XCTAssertTrue(recolored.isSameDesign(as: generated))
        XCTAssertEqual(recolored.fontFamily, generated.fontFamily)

        // A second change keeps the generator's colors, not the first change's.
        var again = reader
        again.accent = ColorValue(hex: "#00FF00")!
        XCTAssertEqual(recolored.recolored(again).generatedColors, original)

        let reset = recolored.recolored(original)
        XCTAssertEqual(reset, generated)
        XCTAssertNil(reset.generatedColors)

        // The token decodes through JSON, as other devices read it.
        let decoded = try JSONDecoder()
            .decode(
                SpineDesignV1.self, from: JSONEncoder().encode(recolored))
        XCTAssertEqual(decoded.generatedColors, original)
    }

    func testRecoloringKeepsProvenanceWithinEightyCharacters() throws {
        let long = design(provenance: String(repeating: "x", count: 60))
        let recolored = long.recolored(reader)
        XCTAssertEqual(recolored.provenance, "generated-colors:000000,FFFFFF,FF0000")
        XCTAssertNoThrow(try recolored.validate())
        XCTAssertNil(
            design().recolored(reader).recolored(try XCTUnwrap(design().colors)).provenance)
    }

    func testUnreadableColorsAreNotSavable() {
        var unreadable = reader
        unreadable.foreground = ColorValue(hex: "#2A3B4C")!
        XCTAssertTrue(reader.isReadable)
        XCTAssertFalse(unreadable.isReadable)
        XCTAssertThrowsError(try design().recolored(unreadable).validate())
    }

    func testGenerationKeepsReaderColorsUntilTheReaderChoosesACover() {
        let edited = design(generator: "ios-pcc-v0").recolored(reader)
        let otherWork = String(repeating: "c", count: 64)
        let otherCover = String(repeating: "d", count: 64)
        func action(
            _ design: SpineDesignV1, work: String? = nil, cover: String? = nil,
            readerChoseCover: Bool = false
        ) -> SavedDesignAction {
            design.action(
                workItemHash: work ?? self.work, coverHash: cover ?? self.cover,
                readerChoseCover: readerChoseCover)
        }

        // Generator colors: kept only for the same work and cover from this generator.
        XCTAssertEqual(action(design()), .keep)
        XCTAssertEqual(action(design(generator: "ios-pcc-v0")), .redesign)
        XCTAssertEqual(action(design(), work: otherWork), .redesign)
        XCTAssertEqual(action(design(), cover: otherCover), .redesign)

        // Reader colors outlast a generator change, and move to the new work-item hash.
        XCTAssertEqual(action(edited), .keep)
        XCTAssertEqual(action(edited, readerChoseCover: true), .keep)
        guard case .save(let rehashed) = action(edited, work: otherWork) else {
            return XCTFail("Reader colors should move to the new work-item hash")
        }
        XCTAssertEqual(rehashed.workItemHash, otherWork)
        XCTAssertEqual(rehashed.coverHash, cover)
        XCTAssertEqual(rehashed.colors, reader)
        XCTAssertEqual(rehashed.provenance, edited.provenance)
        XCTAssertEqual(rehashed.generatedAt, edited.generatedAt)
        XCTAssertEqual(rehashed.generatorVersion, "ios-pcc-v0")
        XCTAssertNoThrow(try rehashed.validate())

        // New bytes for the same cover, such as a new default cover, keep the reader's colors.
        guard case .save(let recovered) = action(edited, cover: otherCover) else {
            return XCTFail("Reader colors should move to the new cover hash")
        }
        XCTAssertEqual(recovered.coverHash, otherCover)
        XCTAssertEqual(recovered.workItemHash, work)
        XCTAssertEqual(recovered.colors, reader)
        XCTAssertEqual(recovered.generatedColors, edited.generatedColors)
        XCTAssertEqual(recovered.generatedAt, edited.generatedAt)

        // A cover the reader chose redesigns the spine.
        XCTAssertEqual(action(edited, cover: otherCover, readerChoseCover: true), .redesign)

        // A book that draws its series' look keeps another generator's design while the hashes
        // match, since a redesign would not change its spine.
        let foreign = design(generator: "mac-foundation-models-v2")
        XCTAssertEqual(
            foreign.action(
                workItemHash: work, coverHash: cover, readerChoseCover: false,
                drawsSeriesLook: true), .keep)
        XCTAssertEqual(
            foreign.action(
                workItemHash: otherWork, coverHash: cover, readerChoseCover: false,
                drawsSeriesLook: true), .redesign)
    }

    func testLedgerTellsWhetherTheReaderChoseAnotherCover() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = WorkLedger(url: url)
        let chosen = URL(string: "https://example.com/chosen.jpg")!

        let unknown = await ledger.readerChoseCover(recordName: "record", chosenCover: chosen)
        XCTAssertFalse(unknown)

        try await ledger.recordSuccess(
            recordName: "record", workItemHash: work, coverHash: cover, chosenCover: nil)
        let sameDefault = await ledger.readerChoseCover(recordName: "record", chosenCover: nil)
        let newChoice = await ledger.readerChoseCover(recordName: "record", chosenCover: chosen)
        XCTAssertFalse(sameDefault)
        XCTAssertTrue(newChoice)
    }

    func testSeriesReuseCopiesTheGeneratorsColorsNotTheReaders() async throws {
        // No font family, so the reuse downloads no font.
        let generated = SpineDesignV1(
            version: 1, accountID: "42", bookID: 7, workItemHash: work, coverHash: cover,
            generatorVersion: CloudContract.generatorVersion,
            generatedAt: Date(timeIntervalSince1970: 1_000_000), backgroundHex: "#000000",
            foregroundHex: "#FFFFFF", accentHex: "#FF0000", typeface: "serif", weight: 600,
            uppercase: false)
        let sibling = CloudBook(
            id: 8, title: "Fictional Sequel", author: "An Author", coverURL: nil,
            detailCoverURL: nil)
        let reused = try await BookAnalyzer()
            .seriesDesign(
                from: generated.recolored(reader), book: sibling, accountID: "42",
                workItemHash: work, coverHash: cover)
        XCTAssertEqual(reused?.colors, generated.colors)
        XCTAssertNil(reused?.generatedColors)
        XCTAssertEqual(reused?.provenance, "series-reuse:7")
    }

    func testSeriesReuseNeedsTheGlyphsOfAnInstalledFaceWithoutAFamily() async throws {
        func source(_ postScriptName: String) -> SpineDesignV1 {
            SpineDesignV1(
                version: 1, accountID: "42", bookID: 7, workItemHash: work, coverHash: cover,
                generatorVersion: "tvos-local-v1",
                generatedAt: Date(timeIntervalSince1970: 1_000_000), backgroundHex: "#000000",
                foregroundHex: "#FFFFFF", accentHex: "#FF0000", typeface: "serif", weight: 700,
                uppercase: false, fontPostScriptName: postScriptName)
        }
        func reuse(_ source: SpineDesignV1, title: String) async throws -> SpineDesignV1? {
            try await BookAnalyzer()
                .seriesDesign(
                    from: source,
                    book: CloudBook(
                        id: 8, title: title, author: "An Author", coverURL: nil,
                        detailCoverURL: nil),
                    accountID: "42", workItemHash: work, coverHash: cover)
        }
        let georgia = source("Georgia-Bold")
        let latin = try await reuse(georgia, title: "Fictional Sequel")
        XCTAssertEqual(latin?.fontPostScriptName, "Georgia-Bold")
        // Georgia has no glyphs for this title, so the book gets a model design.
        let tokyo = try await reuse(georgia, title: "東京物語")
        XCTAssertNil(tokyo)
        // Without the face, readers draw the system typeface, which letters any title.
        let missing = try await reuse(source("NoSuchFace-Bold"), title: "東京物語")
        XCTAssertNotNil(missing)
    }

    private func seriesBook(
        _ id: Int, by author: String = "Ann Author", series: Int? = 5, position: Double? = nil,
        finished: String? = nil, title: String = "Fictional Volume"
    ) -> CloudBook {
        CloudBook(
            id: id, title: title, author: author, coverURL: nil, detailCoverURL: nil,
            seriesID: series, seriesPosition: position, finished: finished)
    }

    private func design(for bookID: Int, background: String = "#000000", family: String? = nil)
        -> SpineDesignV1
    {
        SpineDesignV1(
            version: 1, accountID: "42", bookID: bookID, workItemHash: work, coverHash: cover,
            generatorVersion: CloudContract.generatorVersion,
            generatedAt: Date(timeIntervalSince1970: 1_000_000), backgroundHex: background,
            foregroundHex: "#FFFFFF", accentHex: "#FF0000", typeface: "serif", weight: 600,
            uppercase: false, fontFamily: family)
    }

    func testSeriesMembershipNeedsTheSameSeriesAndFirstAuthor() {
        let first = seriesBook(1, by: "José Saramago")
        XCTAssertTrue(SeriesDesigns.matches(first, seriesBook(2, by: "jose saramago")))
        XCTAssertFalse(SeriesDesigns.matches(first, seriesBook(3, by: "Another Writer")))
        XCTAssertTrue(
            SeriesDesigns.matches(seriesBook(4, by: "Ann Author, Co Writer"), seriesBook(5)))
        XCTAssertFalse(
            SeriesDesigns.matches(seriesBook(4, by: "Co Writer, Ann Author"), seriesBook(5)))
        XCTAssertFalse(SeriesDesigns.matches(seriesBook(6), seriesBook(7, series: 9)))
        XCTAssertFalse(
            SeriesDesigns.matches(seriesBook(8, series: nil), seriesBook(9, series: nil)))
    }

    func testDiscworldBooksShareADesignOnlyWithinTheirGroup() {
        func discworld(_ id: Int, _ title: String) -> CloudBook {
            seriesBook(id, by: "Terry Pratchett", series: 1018, title: title)
        }
        let guards = discworld(1, "Guards! Guards!")
        XCTAssertTrue(SeriesDesigns.matches(guards, discworld(2, "THUD")))
        XCTAssertTrue(SeriesDesigns.matches(guards, discworld(3, "Night Watch: A Discworld Novel")))
        XCTAssertFalse(SeriesDesigns.matches(guards, discworld(4, "Mort")))
        XCTAssertTrue(
            SeriesDesigns.matches(
                discworld(5, "The Science of Discworld II: The Globe"),
                discworld(6, "The Science of Discworld")))
        // A book no group names keeps its own design.
        let maurice = discworld(7, "The Amazing Maurice and His Educated Rodents")
        XCTAssertFalse(SeriesDesigns.matches(maurice, discworld(8, "The Amazing Maurice")))
        // Other series still match as a whole.
        XCTAssertTrue(
            SeriesDesigns.matches(seriesBook(9, title: "One"), seriesBook(10, title: "Two")))
    }

    func testSeriesSourceRanksPositionThenFinishThenID() {
        // Book 1 ranks first but has no design; book 2's design names Impact, a blocked face.
        let books = [
            seriesBook(1, position: 1), seriesBook(2, position: 2),
            seriesBook(3, position: 3, finished: "2024-05-01"),
            seriesBook(4, position: 3, finished: "2023-05-01"), seriesBook(5),
            seriesBook(6, finished: "2020-01-01"), seriesBook(7, by: "Another Writer", position: 0),
        ]
        var designs = [2: design(for: 2, family: "Impact")]
        for id in 3...7 { designs[id] = design(for: id) }
        // Book 2 lends its design, in Bebas Neue, to the books after it; book 7 has another
        // author. Book 1 ranks first but draws its own design once it has one.
        XCTAssertEqual(
            SeriesDesigns.sources(books: books, designs: designs),
            [2: 2, 3: 2, 4: 2, 5: 2, 6: 2])
        // Without book 2, book 4 finished before book 3 at the same position, so it leads.
        designs[2] = nil
        XCTAssertEqual(
            SeriesDesigns.sources(books: books, designs: designs), [3: 4, 4: 4, 5: 4, 6: 4])

        // Without positions, the earliest finish leads, and a missing finish ranks last.
        let unnumbered = [seriesBook(10), seriesBook(11, finished: "2021-01-01"), seriesBook(9)]
        let unnumberedSources = SeriesDesigns.sources(
            books: unnumbered,
            designs: [9: design(for: 9), 10: design(for: 10), 11: design(for: 11)])
        XCTAssertEqual(unnumberedSources, [9: 11, 10: 11, 11: 11])
        XCTAssertEqual(
            SeriesDesigns.sourceFirst(unnumbered + [seriesBook(12, series: nil)]).map(\.id),
            [11, 9, 10, 12])
    }

    func testSeriesSourcesGroupByFirstAuthorInAnyBookOrder() {
        // Book 2 shares its first author with book 1, so it draws book 1's design. Book 3's
        // first author is only book 2's coauthor, so it draws its own.
        let books = [
            seriesBook(1, by: "Ann Author", position: 1),
            seriesBook(2, by: "Ann Author, Co Writer", position: 2),
            seriesBook(3, by: "Co Writer", position: 3),
        ]
        let designs = [1: design(for: 1), 2: design(for: 2), 3: design(for: 3)]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            XCTAssertEqual(
                SeriesDesigns.sources(books: order.map { books[$0] }, designs: designs),
                [1: 1, 2: 1], "\(order)")
        }
    }

    func testSeriesBookKeepsItsOwnDesignWhenTheSourceFontLacksGlyphs() throws {
        let face = FontFace(
            descriptor: CTFontDescriptorCreateWithNameAndSize("Helvetica" as CFString, 12),
            postScriptName: "Helvetica")
        let books = [
            seriesBook(1, position: 1), seriesBook(2, position: 2),
            seriesBook(3, position: 3, title: "東京物語"),
        ]
        let designs = [1: design(for: 1), 2: design(for: 2), 3: design(for: 3)]
        let sources = SeriesDesigns.sources(books: books, designs: designs) { book, design in
            face.covers(SeriesDesigns.lettering(of: book, uppercase: design.uppercase))
        }
        XCTAssertEqual(sources, [1: 1, 2: 1])
    }

    /// A model reading a preview folder that holds `books`, their saved `designs`, and saved
    /// `looks`; the folder is removed when the test ends. Each design is saved as made for its
    /// book as it is now, with the book's work-item hash, so loading creates the looks that the
    /// designs decide (`SeriesDesigns.missingLooks`).
    @MainActor
    private func previewModel(
        books: [CloudBook], designs: [SpineDesignV1], looks: [SeriesLookV1] = []
    ) async throws -> (model: AppModel, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-series-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let archive: [String: Any] = [
            "version": 1,
            "sources": [
                [
                    "source": "hardcover", "accountID": "42", "syncedAt": 1_000,
                    "books": try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(books)),
                ]
            ],
        ]
        try JSONSerialization.data(withJSONObject: archive)
            .write(to: folder.appending(path: "library-v1.json"))
        let current = designs.map { design in
            books.first { $0.id == design.bookID }.map(design.current(for:)) ?? design
        }
        try JSONEncoder()
            .encode(
                Dictionary(
                    uniqueKeysWithValues: current.map {
                        (CloudContract.designRecordName(accountID: "42", bookID: $0.bookID), $0)
                    })
            )
            .write(to: folder.appending(path: "spine-designs-v1.json"))
        try JSONEncoder()
            .encode(
                Dictionary(
                    uniqueKeysWithValues: looks.map {
                        (CloudContract.seriesLookRecordName(accountID: "42", key: $0.key), $0)
                    })
            )
            .write(to: folder.appending(path: "series-looks-v1.json"))
        let model = AppModel(previewFolder: folder)
        await model.reload()
        return (model, folder)
    }

    @MainActor
    func testOnlyALoadedLibrarySeedsASeriesLook() async throws {
        let books = [seriesBook(1, position: 1), seriesBook(2, position: 2)]
        let (model, folder) = try await previewModel(books: books, designs: [])
        let designsURL = folder.appending(path: "spine-designs-v1.json")
        try Data("not json".utf8).write(to: designsURL)
        await model.reload()
        XCTAssertNotNil(model.loadError)

        // The failed load leaves the library on screen; a design shown on it seeds no look.
        let current = design(for: 1).current(for: books[0])
        model.apply(current)
        try await model.setSeriesLink(
            for: books[0], linkedSeriesID: nil, standsAlone: false, ownLook: false)
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: books[0], link: nil))
        let store = LocalSpineStore(folder: folder)
        let unseeded = try await store.seriesLooks(accountID: "42", keys: [key])
        XCTAssertEqual(model.library?.looks, [:])
        XCTAssertEqual(unseeded, [:])

        try JSONEncoder()
            .encode([CloudContract.designRecordName(accountID: "42", bookID: 1): current])
            .write(to: designsURL)
        await model.reload()
        let seeded = try await store.seriesLooks(accountID: "42", keys: [key])
        XCTAssertEqual(seeded[key]?.sourceBookID, 1, "A successful load seeds the look")
        XCTAssertEqual(model.library?.looks[key]?.sourceBookID, 1)
    }

    @MainActor
    func testSeriesActionsActOnTheSourceOfTheSeriesLook() async throws {
        let books = [
            seriesBook(1, by: "Ann Author", position: 1),
            seriesBook(2, by: "Ann Author, Co Writer", position: 2),
            seriesBook(3, by: "Co Writer", position: 3),
        ]
        let (model, _) = try await previewModel(
            books: books, designs: [1, 2, 3].map { design(for: $0) })
        // Loading made a look for each first author from the earliest design, book 1's and
        // book 3's. Change cover and Redesign spine act on `designSource(for:)`.
        XCTAssertEqual(model.library?.looks.values.map(\.sourceBookID).sorted(), [1, 3])
        XCTAssertEqual(model.designSource(for: books[1]).id, 1, "Book 2 changes book 1")
        XCTAssertEqual(model.designSource(for: books[2]).id, 3, "Book 3 changes itself")
        XCTAssertEqual(model.design(for: books[2])?.bookID, 3)
    }

    @MainActor
    func testRecoloringASeriesBookRecolorsTheSeriesLook() async throws {
        let first = seriesBook(1, position: 1)
        let second = seriesBook(2, position: 2)
        let saved = [
            design(for: 1, background: "#202020"),
            design(for: 2, background: "#404040").movedBack(),
        ]
        let (model, folder) = try await previewModel(books: [first, second], designs: saved)
        // Book 2's design is older, so it decides the look, even though book 1 ranks first.
        XCTAssertEqual(model.designSource(for: first).id, 2)
        XCTAssertEqual(model.design(for: first)?.backgroundHex, "#404040")
        XCTAssertEqual(model.design(for: first)?.bookID, 1)

        try await model.recolor(first, to: reader)
        let store = LocalSpineStore(folder: folder)
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: first, link: nil))
        let look = try await store.seriesLooks(accountID: "42", keys: [key])[key]
        XCTAssertEqual(look?.backgroundHex, reader.background.hex)
        XCTAssertEqual(look?.sourceBookID, 2)
        XCTAssertNotNil(look?.editedAt)
        // Each book's own saved design is unchanged.
        let own = try await store.savedDesign(accountID: "42", bookID: 1)
        let source = try await store.savedDesign(accountID: "42", bookID: 2)
        XCTAssertEqual(own?.backgroundHex, "#202020")
        XCTAssertEqual(source?.backgroundHex, "#404040")
        XCTAssertEqual(model.look(for: first).background, reader.background)
        XCTAssertEqual(model.look(for: second).background, reader.background)
    }

    @MainActor
    func testSavedLookDecidesTheSeriesUnlessABookKeepsItsOwn() async throws {
        var books = [seriesBook(1, position: 1), seriesBook(2, position: 2)]
        // Georgia has no glyphs for this title.
        let tokyo = seriesBook(3, position: 3, title: "東京物語")
        let saved = [
            design(for: 1, background: "#202020"), design(for: 2, background: "#404040"),
            design(for: 3, background: "#606060"),
        ]
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: books[0], link: nil))
        // A look the Apple TV made from a cover, in a system face, before either design.
        let television = SeriesLookV1(
            version: 1, accountID: "42", seriesID: key.seriesID, group: key.group,
            sourceBookID: 2, origin: "tvos-local-v1", createdAt: Date(timeIntervalSince1970: 0),
            backgroundHex: "#102030", foregroundHex: "#F0F0F0", accentHex: "#F0F0F0",
            typeface: "serif", weight: 700, uppercase: true, fontPostScriptName: "Georgia-Bold")
        let (model, folder) = try await previewModel(
            books: books + [tokyo], designs: saved, looks: [television])
        XCTAssertEqual(model.library?.looks, [key: television], "Loading keeps the first look")
        for book in books {
            let drawn = try XCTUnwrap(model.design(for: book))
            XCTAssertEqual(drawn.backgroundHex, "#102030")
            XCTAssertEqual(drawn.generatorVersion, "tvos-local-v1")
            XCTAssertEqual(model.look(for: book).face?.postScriptName, "Georgia-Bold")
        }
        XCTAssertEqual(
            model.design(for: tokyo)?.backgroundHex, "#606060",
            "A book the look's face cannot letter draws its own design")
        XCTAssertNil(model.drawnLook(of: tokyo))

        // Keeping book 2's own look draws its own design, and recoloring it leaves the look.
        books[1].seriesLink = SeriesLinkV1(
            version: 1, accountID: "42", bookID: 2, standsAlone: false, ownLook: true,
            chosenAt: .now)
        try await model.setSeriesLink(
            for: books[1], linkedSeriesID: nil, standsAlone: false, ownLook: true)
        XCTAssertEqual(model.design(for: books[1])?.backgroundHex, "#404040")
        XCTAssertFalse(model.sharesSeriesDesign(books[1]))
        try await model.recolor(books[1], to: reader)
        XCTAssertEqual(model.design(for: books[0])?.backgroundHex, "#102030")
        let own = try await LocalSpineStore(folder: folder).savedDesign(accountID: "42", bookID: 2)
        XCTAssertEqual(own?.colors, reader)

        // The link survives a reload, and a choice that changes nothing deletes it.
        await model.reload()
        XCTAssertEqual(model.books.first { $0.id == 2 }?.seriesLink?.ownLook, true)
        try await model.setSeriesLink(
            for: books[1], linkedSeriesID: nil, standsAlone: false, ownLook: false)
        await model.reload()
        XCTAssertNil(model.books.first { $0.id == 2 }?.seriesLink)
        XCTAssertEqual(model.design(for: books[1])?.backgroundHex, "#102030")
    }

    @MainActor
    func testSeriesEditsFollowTheLooksSourceWhileItDrawsTheLook() async throws {
        let books = [
            seriesBook(1, position: 1), seriesBook(2, position: 2), seriesBook(3, series: 6),
        ]
        let saved = [
            design(for: 1, background: "#202020"),
            design(for: 2, background: "#404040").movedBack(),
        ]
        let (model, _) = try await previewModel(books: books, designs: saved)
        XCTAssertEqual(model.designSource(for: books[0]).id, 2)
        XCTAssertTrue(model.choosesEditScope(for: books[0]))
        XCTAssertFalse(model.choosesEditScope(for: books[2]), "Book 3 is alone in its series")

        // Reset colors restores the colors of the design the look was made from.
        try await model.recolor(books[0], to: reader)
        XCTAssertEqual(model.look(for: books[0]).background, reader.background)
        XCTAssertEqual(model.generatedColors(for: books[0])?.background.hex, "#404040")

        // Once the source keeps its own look, edits to book 1 act on book 1, which still draws
        // the look, and book 2 can still return to the series.
        try await model.setSeriesLink(
            for: books[1], linkedSeriesID: nil, standsAlone: false, ownLook: true)
        XCTAssertEqual(model.designSource(for: books[0]).id, 1)
        XCTAssertEqual(model.look(for: books[0]).background, reader.background)
        XCTAssertNotNil(model.lookDesigns[1])
        XCTAssertFalse(model.sharesSeriesDesign(books[0]), "Book 1 shares its look with no one")
        let second = try XCTUnwrap(model.books.first { $0.id == 2 })
        XCTAssertTrue(model.choosesEditScope(for: second))
        XCTAssertEqual(model.generatedColors(for: second)?.background.hex, "#404040")
    }

    @MainActor
    func testRecoloringKeepsTheSavedFontThatReadersReplace() async throws {
        let book = seriesBook(7, series: nil)
        var saved = design()
        saved.fontFamily = "Lora"
        saved.fontPostScriptName = "Lora-BoldItalic"
        saved.instanceWeight = 700
        let (model, folder) = try await previewModel(books: [book], designs: [saved])
        XCTAssertNil(model.design(for: book)?.fontPostScriptName, "Readers show upright Lora")

        try await model.recolor(book, to: reader)
        let stored = try await LocalSpineStore(folder: folder)
            .savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(stored?.colors, reader)
        XCTAssertEqual(stored?.fontFamily, "Lora")
        XCTAssertEqual(stored?.fontPostScriptName, "Lora-BoldItalic")
        XCTAssertEqual(stored?.instanceWeight, 700)
    }

    func testPreviewStoreReplacesOnlyTheRecoloredDesign() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-colors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalSpineStore(folder: folder)
        let generated = design()
        try await store.save(generated)

        try await store.saveRecolored(generated.recolored(reader))
        let saved = try await store.savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(saved?.colors, reader)

        // A redesign since the reader started picking colors wins.
        let redesigned = SpineDesignV1(
            version: 1, accountID: "42", bookID: 7, workItemHash: work, coverHash: cover,
            generatorVersion: CloudContract.generatorVersion,
            generatedAt: generated.generatedAt.addingTimeInterval(60), backgroundHex: "#FFFFFF",
            foregroundHex: "#000000", accentHex: "#0000FF", typeface: "sans", weight: 400,
            uppercase: true)
        try await store.save(redesigned)
        do {
            try await store.saveRecolored(generated.recolored(reader))
            XCTFail("A recoloring of a replaced design was saved")
        } catch CompanionError.designChanged {}
        let kept = try await store.savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(kept, redesigned)
    }
}

extension SpineDesignV1 {
    /// The design, made a minute earlier.
    fileprivate func movedBack() -> SpineDesignV1 {
        copy(generatedAt: generatedAt.addingTimeInterval(-60))
    }

    /// The design, made for `book` as it is now.
    fileprivate func current(for book: CloudBook) -> SpineDesignV1 {
        copy(workItemHash: CloudContract.workItemHash(accountID: accountID, book: book))
    }

    private func copy(workItemHash: String? = nil, generatedAt: Date? = nil) -> SpineDesignV1 {
        SpineDesignV1(
            version: version, accountID: accountID, bookID: bookID,
            workItemHash: workItemHash ?? self.workItemHash, coverHash: coverHash,
            generatorVersion: generatorVersion, generatedAt: generatedAt ?? self.generatedAt,
            backgroundHex: backgroundHex, foregroundHex: foregroundHex, accentHex: accentHex,
            typeface: typeface, weight: weight, uppercase: uppercase, fontFamily: fontFamily,
            fontPostScriptName: fontPostScriptName, instanceWeight: instanceWeight,
            provenance: provenance)
    }
}
