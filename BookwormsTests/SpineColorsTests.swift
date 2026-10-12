import Foundation
import XCTest

@testable import Bookworms

/// Covers the reader's spine colors: the provenance record that Reset restores from, the
/// contrast gate, which saved designs a generation run keeps, series reuse, and the preview
/// store's save.
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
