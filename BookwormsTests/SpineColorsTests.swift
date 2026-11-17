import CoreText
import Foundation
import XCTest

@testable import Bookworms

/// Covers the reader's spine colors: the provenance record that the color resets restore from, the
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

        // Each color's reset sets back only its color; the generator's colors stay recorded
        // until the last one.
        var partly = reader
        partly.background = original.background
        let oneReset = recolored.recolored(partly)
        XCTAssertEqual(oneReset.generatedColors, original)
        partly.foreground = original.foreground
        partly.accent = original.accent
        XCTAssertEqual(oneReset.recolored(partly), generated)

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

        // Other tokens go before the model token, which keeps the design's tier through a
        // recoloring and its reset.
        let original = try XCTUnwrap(design().colors)
        let copy = design(provenance: "series-reuse:123456 model:anthropic/claude-haiku-5-5")
        let recoloredCopy = copy.recolored(reader)
        XCTAssertEqual(
            recoloredCopy.provenance,
            "model:anthropic/claude-haiku-5-5 generated-colors:000000,FFFFFF,FF0000")
        XCTAssertEqual(recoloredCopy.tier, .backup)
        XCTAssertNoThrow(try recoloredCopy.validate())
        let resetCopy = recoloredCopy.recolored(original)
        XCTAssertEqual(resetCopy.provenance, "model:anthropic/claude-haiku-5-5")
        XCTAssertEqual(resetCopy.tier, .backup)

        // A model token too long to fit is shortened and still names a backup model.
        let custom = design(provenance: "model:custom/" + String(repeating: "m", count: 40))
        let recoloredCustom = custom.recolored(reader)
        XCTAssertEqual(recoloredCustom.provenance?.count, 80)
        XCTAssertEqual(recoloredCustom.tier, .backup)
        XCTAssertEqual(recoloredCustom.generatedColors, original)
        XCTAssertNoThrow(try recoloredCustom.validate())
        XCTAssertEqual(recoloredCustom.recolored(original).tier, .backup)
    }

    func testChoiceIsRecordedWithoutChangingWhatDesignsDo() throws {
        var chosen = design()
        chosen.choice = SpineChoice(
            titleLine: "THE LANTERN KEEPER", making: "typeset font", category: "serif",
            subclass: "Serif / Didone", themes: [], moods: ["Fancy", "Vintage"],
            candidates: ["Bodoni Moda", "Playfair Display"])
        XCTAssertNoThrow(try chosen.validate())
        // A design without a choice encodes as before, so saved records stay byte-for-byte.
        let plain = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(design())) as? [String: Any])
        XCTAssertNil(plain["choice"])
        let decoded = try JSONDecoder()
            .decode(
                SpineDesignV1.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(decoded.choice, chosen.choice)
        XCTAssertEqual(chosen.recolored(reader).choice, chosen.choice)
        // The choice decides nothing: runs keep, replace, and redesign exactly as without it.
        for tier in [ModelTier.local, .onDevice, .backup, .privateCloudCompute] {
            XCTAssertEqual(
                chosen.action(
                    workItemHash: work, coverHash: cover, readerChoseCover: false, runTier: tier,
                    drawsSeriesLook: false),
                design()
                    .action(
                        workItemHash: work, coverHash: cover, readerChoseCover: false,
                        runTier: tier,
                        drawsSeriesLook: false))
        }
        XCTAssertEqual(
            design().outlasts(chosen, replacing: false),
            design().outlasts(design(), replacing: false))
        XCTAssertEqual(
            chosen.outlasts(design(), replacing: false),
            design().outlasts(design(), replacing: false))
        // A longer list of families or a multi-line answer can't be saved.
        var long = chosen
        long.choice?.candidates = Array(repeating: "Lora", count: 7)
        XCTAssertThrowsError(try long.validate())
        var broken = chosen
        broken.choice?.making = "typeset\nfont"
        XCTAssertThrowsError(try broken.validate())
        var themed = chosen
        themed.choice?.themes = ["Art Deco", "Inline", "Shaded"]
        XCTAssertThrowsError(try themed.validate())
        // A choice saved before the reading named themes and moods still decodes.
        let older = try JSONDecoder()
            .decode(
                SpineChoice.self,
                from: Data(
                    #"{"making":"typeset font","serifs":"none","treatment":"plain","candidates":["Lora"]}"#
                        .utf8))
        XCTAssertEqual(older.candidates, ["Lora"])
        XCTAssertNil(older.themes)
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
                readerChoseCover: readerChoseCover, runTier: .privateCloudCompute)
        }

        // Generator colors from the run's tier stay under any generator version, and move to a
        // new work-item hash with the hash of the cover they come from. New bytes behind the
        // default cover change nothing.
        XCTAssertEqual(action(design()), .keep)
        XCTAssertEqual(action(design(generator: "ios-pcc-v0")), .keep)
        guard case .save(let moved) = action(design(), work: otherWork, cover: otherCover) else {
            return XCTFail("The design should move to the new work-item hash")
        }
        XCTAssertEqual(moved.workItemHash, otherWork)
        XCTAssertEqual(moved.coverHash, cover)
        XCTAssertEqual(moved.colors, design().colors)
        XCTAssertNil(moved.generatedColors)
        XCTAssertEqual(moved.generatedAt, design().generatedAt)
        XCTAssertEqual(action(design(), cover: otherCover), .keep)

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
        XCTAssertEqual(action(edited, cover: otherCover), .keep)

        // A cover the reader chose redesigns the spine.
        XCTAssertEqual(action(edited, cover: otherCover, readerChoseCover: true), .redesign)
        XCTAssertEqual(action(design(), cover: otherCover, readerChoseCover: true), .redesign)
        // So does a downloaded chosen cover that the design doesn't come from, such as on a
        // device that never saw the choice, or after a failed first design from it. Only a new
        // choice replaces the reader's colors.
        func fromChosen(_ design: SpineDesignV1, cover: String) -> SavedDesignAction {
            design.action(
                workItemHash: work, coverHash: cover, readerChoseCover: false,
                fromChosenCover: true, runTier: .local)
        }
        XCTAssertEqual(fromChosen(design(), cover: otherCover), .redesign)
        XCTAssertEqual(fromChosen(design(), cover: cover), .keep)
        XCTAssertEqual(fromChosen(edited, cover: otherCover), .keep)

        // A book that draws its series' look keeps a weaker tier's design, since a redesign
        // would not change its spine, and moves it to a new work-item hash.
        let foreign = design(generator: CloudContract.macGeneratorVersion)
        XCTAssertEqual(
            foreign.action(
                workItemHash: work, coverHash: cover, readerChoseCover: false,
                runTier: .privateCloudCompute, drawsSeriesLook: true), .keep)
        guard
            case .save(let drawn) = foreign.action(
                workItemHash: otherWork, coverHash: cover, readerChoseCover: false,
                runTier: .privateCloudCompute, drawsSeriesLook: true)
        else { return XCTFail("The design should move to the new work-item hash") }
        XCTAssertEqual(drawn.generatorVersion, CloudContract.macGeneratorVersion)
    }

    /// A run replaces a design only with a better tier's, whatever generator version made it,
    /// unless the reader chose another cover or asked for a redesign.
    func testRunsReplaceADesignOnlyFromABetterTier() throws {
        let otherWork = String(repeating: "c", count: 64)
        let otherCover = String(repeating: "d", count: 64)
        func action(
            _ design: SpineDesignV1, runTier: ModelTier, work: String? = nil,
            cover: String? = nil, readerChoseCover: Bool = false
        ) -> SavedDesignAction {
            design.action(
                workItemHash: work ?? self.work, coverHash: cover ?? self.cover,
                readerChoseCover: readerChoseCover, runTier: runTier)
        }
        let onDevice = design(provenance: ModelTier.onDeviceToken)
        let earlierOnDevice = design(generator: "ios-pcc-v1", provenance: ModelTier.onDeviceToken)
        let companion = design(generator: "mac-foundation-models-v1")
        let earlierPCC = design(generator: "ios-pcc-v1")

        // An on-device run keeps on-device designs from an earlier generator version and the
        // retired Mac companion, and Private Cloud Compute designs from any version.
        for kept in [onDevice, earlierOnDevice, companion, earlierPCC, design()] {
            XCTAssertEqual(action(kept, runTier: .onDevice), .keep, kept.generatorVersion)
            XCTAssertEqual(action(kept, runTier: .local), .keep, kept.generatorVersion)
        }
        // The backup model and Private Cloud Compute replace an on-device design.
        for replaced in [onDevice, earlierOnDevice, companion] {
            XCTAssertEqual(action(replaced, runTier: .backup), .redesign)
            XCTAssertEqual(action(replaced, runTier: .privateCloudCompute), .redesign)
        }
        XCTAssertEqual(action(earlierPCC, runTier: .privateCloudCompute), .keep)
        XCTAssertEqual(
            action(design(provenance: "model:openai/gpt-6-luna"), runTier: .backup), .keep)

        // A same-tier run keeps a design whose book's metadata changed, saving it under the new
        // work-item hash with its cover hash, generator, date, colors, font, and tokens.
        guard case .save(let moved) = action(companion, runTier: .onDevice, work: otherWork)
        else { return XCTFail("The design should move to the new work-item hash") }
        XCTAssertEqual(moved.workItemHash, otherWork)
        XCTAssertEqual(moved.coverHash, cover)
        XCTAssertEqual(moved.generatorVersion, "mac-foundation-models-v1")
        XCTAssertEqual(moved.generatedAt, companion.generatedAt)
        XCTAssertEqual(moved.colors, companion.colors)
        XCTAssertEqual(moved.fontFamily, companion.fontFamily)
        XCTAssertEqual(moved.provenance, companion.provenance)
        XCTAssertEqual(moved.tier, .onDevice)
        XCTAssertNoThrow(try moved.validate())
        XCTAssertEqual(action(earlierPCC, runTier: .onDevice, cover: otherCover), .keep)

        // A cover the reader chose, with new image bytes, redesigns at any tier.
        XCTAssertEqual(
            action(earlierPCC, runTier: .onDevice, cover: otherCover, readerChoseCover: true),
            .redesign)
        XCTAssertEqual(action(earlierPCC, runTier: .onDevice, readerChoseCover: true), .keep)

        // A save of the same work keeps an earlier generator's design from the same or a better
        // tier, takes a better tier's, and takes a redesign the reader asked for.
        let newOnDevice = design(provenance: ModelTier.onDeviceToken)
        XCTAssertTrue(companion.outlasts(newOnDevice, replacing: false))
        XCTAssertTrue(earlierPCC.outlasts(newOnDevice, replacing: false))
        XCTAssertFalse(companion.outlasts(design(), replacing: false))
        XCTAssertFalse(earlierPCC.movedBack().outlasts(newOnDevice, replacing: true))
    }

    /// A better tier replaces only designs from local defaults and Apple's on-device model. A
    /// capable model's design, from Private Cloud Compute or the reader's backup model, stays
    /// whichever of them a run uses, as when the reader's model designs instead of Private Cloud
    /// Compute.
    func testRunsRedesignOnlyLocalAndOnDeviceDesignsUnlessTheReaderRecolored() {
        XCTAssertTrue(ModelTier.local.isReplaced(by: .onDevice))
        XCTAssertTrue(ModelTier.local.isReplaced(by: .backup))
        XCTAssertTrue(ModelTier.local.isReplaced(by: .privateCloudCompute))
        XCTAssertTrue(ModelTier.onDevice.isReplaced(by: .backup))
        XCTAssertTrue(ModelTier.onDevice.isReplaced(by: .privateCloudCompute))
        XCTAssertFalse(ModelTier.onDevice.isReplaced(by: .onDevice))
        XCTAssertFalse(ModelTier.onDevice.isReplaced(by: .local))
        XCTAssertFalse(ModelTier.backup.isReplaced(by: .privateCloudCompute))
        XCTAssertFalse(ModelTier.backup.isReplaced(by: .backup))
        XCTAssertFalse(ModelTier.privateCloudCompute.isReplaced(by: .backup))
        XCTAssertFalse(ModelTier.privateCloudCompute.isReplaced(by: .privateCloudCompute))

        func design(_ token: String?) -> SpineDesignV1 {
            self.design(provenance: token)
        }
        func action(_ design: SpineDesignV1, runTier: ModelTier, drawsSeriesLook: Bool = false)
            -> SavedDesignAction
        {
            design.action(
                workItemHash: work, coverHash: cover, readerChoseCover: false, runTier: runTier,
                drawsSeriesLook: drawsSeriesLook)
        }
        let pcc = design(nil)
        let backup = design("model:openai/gpt-6-luna")
        let onDevice = design("series-reuse:3 model:apple/on-device")
        let local = design("model:local")

        // A better tier redesigns an on-device or local design.
        XCTAssertEqual(action(onDevice, runTier: .privateCloudCompute), .redesign)
        XCTAssertEqual(action(onDevice, runTier: .backup), .redesign)
        XCTAssertEqual(action(local, runTier: .onDevice), .redesign)
        XCTAssertEqual(action(local, runTier: .backup), .redesign)
        XCTAssertEqual(action(local, runTier: .privateCloudCompute), .redesign)
        // A capable model's design is kept at every tier, and so is an equal tier's.
        XCTAssertEqual(action(backup, runTier: .privateCloudCompute), .keep)
        XCTAssertEqual(action(pcc, runTier: .backup), .keep)
        XCTAssertEqual(action(pcc, runTier: .onDevice), .keep)
        XCTAssertEqual(action(pcc, runTier: .privateCloudCompute), .keep)
        XCTAssertEqual(action(backup, runTier: .backup), .keep)
        XCTAssertEqual(
            action(design("model:anthropic/claude-haiku-5-5"), runTier: .backup), .keep,
            "Another backup provider is the same tier")
        XCTAssertEqual(action(onDevice, runTier: .onDevice), .keep)
        XCTAssertEqual(action(local, runTier: .local), .keep)
        // Reader colors still win, and a book that draws its series' look keeps the look's.
        XCTAssertEqual(action(onDevice.recolored(reader), runTier: .privateCloudCompute), .keep)
        XCTAssertEqual(action(local, runTier: .privateCloudCompute, drawsSeriesLook: true), .keep)

        // The book that upgrades its group's look redesigns a copy without a model token, which
        // reads as Private Cloud Compute whatever made its source. A copy with a model token
        // follows the tier rule, so one from the run's tier stays and upgrades the look.
        func upgrading(_ design: SpineDesignV1, runTier: ModelTier) -> SavedDesignAction {
            design.action(
                workItemHash: work, coverHash: cover, readerChoseCover: false, runTier: runTier,
                upgradesSeriesLook: true)
        }
        let copy = design("series-reuse:12")
        XCTAssertEqual(action(copy, runTier: .privateCloudCompute), .keep)
        XCTAssertEqual(upgrading(copy, runTier: .onDevice), .redesign)
        XCTAssertTrue(copy.isUntrackedCopy)
        XCTAssertEqual(upgrading(design("series-reuse:4 model:local"), runTier: .local), .keep)
        let onDeviceCopy = design("series-reuse:4 model:apple/on-device")
        XCTAssertFalse(onDeviceCopy.isUntrackedCopy)
        XCTAssertEqual(upgrading(onDeviceCopy, runTier: .onDevice), .keep)
        XCTAssertEqual(upgrading(onDeviceCopy, runTier: .privateCloudCompute), .redesign)
        XCTAssertEqual(upgrading(pcc, runTier: .privateCloudCompute), .keep)
        XCTAssertEqual(upgrading(copy.recolored(reader), runTier: .onDevice), .keep)
    }

    func testDesignsAwaitingTheirFontRankBelowTheirTier() {
        let awaiting = design(provenance: "model:local font:system")
        let local = design(provenance: "model:local")
        func action(_ design: SpineDesignV1, runTier: ModelTier, drawsSeriesLook: Bool = false)
            -> SavedDesignAction
        {
            design.action(
                workItemHash: work, coverHash: cover, readerChoseCover: false, runTier: runTier,
                drawsSeriesLook: drawsSeriesLook)
        }
        XCTAssertTrue(awaiting.awaitsFont)
        XCTAssertFalse(local.awaitsFont)
        XCTAssertEqual(awaiting.tier, .local)
        XCTAssertEqual(awaiting.tierTokens, ["model:local", "font:system"])
        // A run at the design's own tier tries the font again; a book that draws its series'
        // look keeps drawing it, and the reader's colors stay.
        XCTAssertEqual(action(awaiting, runTier: .local), .redesign)
        XCTAssertEqual(action(awaiting, runTier: .local, drawsSeriesLook: true), .keep)
        XCTAssertEqual(action(awaiting.recolored(reader), runTier: .local), .keep)
        XCTAssertTrue(awaiting.recolored(reader).awaitsFont, "Recoloring keeps the token")
        // A design whose font downloaded replaces it, and another stand-in doesn't.
        XCTAssertFalse(awaiting.outlasts(local, replacing: false))
        XCTAssertTrue(awaiting.outlasts(awaiting, replacing: false))
        XCTAssertTrue(local.outlasts(awaiting, replacing: false))
        XCTAssertTrue(awaiting.isOutranked(by: .onDevice, awaitingFont: true))
    }

    func testSavesKeepTheFirstDesignAtATierAndTakeBetterTiers() {
        let onDevice = design(provenance: "model:apple/on-device")
        let pcc = design().movedBack()
        // A better tier's design of the same work replaces an on-device one.
        XCTAssertFalse(onDevice.outlasts(pcc, replacing: false))
        // Private Cloud Compute's and the backup model's designs keep each other out.
        let backup = design(provenance: "model:openai/gpt-6-luna").movedBack()
        XCTAssertTrue(backup.outlasts(design(), replacing: false))
        XCTAssertTrue(pcc.outlasts(design(provenance: "model:openai/gpt-6-luna"), replacing: false))
        XCTAssertFalse(backup.outlasts(design(), replacing: true), "A redesign replaces it")
        // The first design saved at a tier, or at a better one, stays.
        XCTAssertTrue(pcc.outlasts(onDevice, replacing: false))
        XCTAssertTrue(design().outlasts(pcc, replacing: false))
        // Reader colors stay, and a redesign the reader asked for replaces only an older design.
        XCTAssertTrue(onDevice.recolored(reader).outlasts(pcc, replacing: false))
        XCTAssertFalse(pcc.outlasts(design(), replacing: true))
        XCTAssertTrue(design().outlasts(pcc, replacing: true))
        // A design from another generator stays at its own tier.
        let television = design(generator: CloudContract.appleTVGeneratorVersion)
        XCTAssertFalse(television.outlasts(onDevice, replacing: false))
        XCTAssertTrue(onDevice.outlasts(television, replacing: false))

        // The tier rule holds for a save under other hashes, such as one decided from a read
        // before another device saved a better design, or under another library snapshot.
        let otherWork = String(repeating: "c", count: 64)
        let laterOnDevice = onDevice.copy(workItemHash: otherWork, generatedAt: Date())
        XCTAssertTrue(pcc.outlasts(laterOnDevice, replacing: false))
        XCTAssertTrue(onDevice.outlasts(laterOnDevice, replacing: false))
        XCTAssertFalse(onDevice.outlasts(pcc.copy(workItemHash: otherWork), replacing: false))
        XCTAssertTrue(
            onDevice.recolored(reader).outlasts(pcc.copy(workItemHash: otherWork), replacing: false)
        )
        // The design itself moves to a new work-item hash whatever its tier, and a design of
        // the cover the reader chose replaces one under other hashes.
        guard
            case .save(let moved) = onDevice.recolored(reader)
                .action(
                    workItemHash: otherWork, coverHash: cover, readerChoseCover: false,
                    runTier: .backup)
        else { return XCTFail("The design should move to the new work-item hash") }
        XCTAssertFalse(onDevice.recolored(reader).outlasts(moved, replacing: false))
        XCTAssertFalse(pcc.outlasts(laterOnDevice, replacing: true))

        // A move decided before the reader recolored the design or set it in another font
        // leaves the reader's edit, and an edit of the design saves over its move.
        guard
            case .save(let staleMove) = onDevice.action(
                workItemHash: otherWork, coverHash: cover, readerChoseCover: false,
                runTier: .onDevice)
        else { return XCTFail("The design should move to the new work-item hash") }
        XCTAssertFalse(onDevice.outlasts(staleMove, replacing: false))
        XCTAssertTrue(onDevice.recolored(reader).outlasts(staleMove, replacing: false))
        let refonted = onDevice.refonted(
            family: "Lora", postScriptName: "Lora-Bold", instanceWeight: 700, typeface: "serif")
        XCTAssertTrue(refonted.outlasts(staleMove, replacing: false))
        XCTAssertTrue(staleMove.isSameDesign(as: onDevice.recolored(reader)))
        XCTAssertTrue(staleMove.isSameDesign(as: refonted))
        XCTAssertFalse(staleMove.isSameDesign(as: laterOnDevice), "A redesign is another design")
    }

    func testDesignsReadTheirTierFromProvenance() {
        XCTAssertEqual(design().tier, .privateCloudCompute)
        XCTAssertNil(design().modelToken)
        XCTAssertEqual(design(provenance: "series-reuse:12").tier, .privateCloudCompute)
        XCTAssertEqual(
            design(provenance: "model:apple/on-device generated-colors:000000,FFFFFF,FF0000")
                .tier, .onDevice)
        XCTAssertEqual(design(provenance: "series-reuse:4 model:local").tier, .local)
        XCTAssertEqual(design(provenance: "model:custom/llama 4").tier, .backup)
        // An Apple TV look's design names no model but comes from none.
        let television = design(generator: CloudContract.appleTVGeneratorVersion)
        XCTAssertEqual(television.modelToken, "model:local")
        XCTAssertEqual(television.tier, .local)
        // Without a token, other generators read by what made their designs, in every version.
        let mac = design(generator: CloudContract.macGeneratorVersion)
        XCTAssertEqual(mac.modelToken, ModelTier.onDeviceToken)
        XCTAssertEqual(mac.tier, .onDevice)
        XCTAssertEqual(design(generator: "mac-foundation-models-v1").tier, .onDevice)
        XCTAssertEqual(design(generator: "ios-pcc-v1").tier, .privateCloudCompute)
        XCTAssertNil(design(generator: "ios-pcc-v1").modelToken)
        XCTAssertEqual(design(generator: "tv-v1").tier, .local)
        XCTAssertEqual(
            design(generator: "ios-pcc-v1", provenance: "model:openai/gpt-6-luna").tier, .backup,
            "A model token decides")
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
            recordName: "record", workItemHash: work, chosenCover: nil)
        let sameDefault = await ledger.readerChoseCover(recordName: "record", chosenCover: nil)
        let newChoice = await ledger.readerChoseCover(recordName: "record", chosenCover: chosen)
        XCTAssertFalse(sameDefault)
        XCTAssertTrue(newChoice)

        // A failed design of the new choice leaves it pending, so the retry still designs it,
        // even over colors the reader chose; only a success settles it.
        try await ledger.recordFailure(
            recordName: "record", workItemHash: work, chosenCover: chosen)
        let afterFailure = await ledger.readerChoseCover(recordName: "record", chosenCover: chosen)
        XCTAssertTrue(afterFailure)
        try await ledger.recordFailure(
            recordName: "record", workItemHash: work, chosenCover: chosen)
        let afterSecondFailure = await ledger.readerChoseCover(
            recordName: "record", chosenCover: chosen)
        XCTAssertTrue(afterSecondFailure)
        try await ledger.recordSuccess(
            recordName: "record", workItemHash: work, chosenCover: chosen)
        let afterSuccess = await ledger.readerChoseCover(recordName: "record", chosenCover: chosen)
        XCTAssertFalse(afterSuccess)
        try await ledger.recordFailure(
            recordName: "record", workItemHash: work, chosenCover: chosen)
        let unchangedFailure = await ledger.readerChoseCover(
            recordName: "record", chosenCover: chosen)
        XCTAssertFalse(unchangedFailure, "A failure of an unchanged choice is no new choice")
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

        // The copy keeps its source's tier.
        var onDevice = generated
        onDevice.provenance = "model:apple/on-device"
        let reusedOnDevice = try await BookAnalyzer()
            .seriesDesign(
                from: onDevice.recolored(reader), book: sibling, accountID: "42",
                workItemHash: work, coverHash: cover)
        XCTAssertEqual(reusedOnDevice?.provenance, "series-reuse:7 model:apple/on-device")
        XCTAssertEqual(reusedOnDevice?.tier, .onDevice)

        // A copy of a design that awaits its font awaits it too.
        var awaiting = generated
        awaiting.provenance = "model:local font:system"
        let reusedAwaiting = try await BookAnalyzer()
            .seriesDesign(
                from: awaiting, book: sibling, accountID: "42", workItemHash: work,
                coverHash: cover)
        XCTAssertEqual(reusedAwaiting?.provenance, "series-reuse:7 model:local font:system")
        XCTAssertEqual(reusedAwaiting?.awaitsFont, true)
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
        // Georgia has no glyphs for this title, so the copy letters in the system typeface, as
        // its series draws.
        let tokyo = try await reuse(georgia, title: "東京物語")
        XCTAssertNotNil(tokyo)
        XCTAssertNil(tokyo?.fontPostScriptName)
        XCTAssertEqual(tokyo?.typeface, "serif")
        // Without the face, readers draw the system typeface, which letters any title.
        let missing = try await reuse(source("NoSuchFace-Bold"), title: "東京物語")
        XCTAssertNotNil(missing)
    }

    /// A series copy follows its group's look: a copy of an older look, such as a default-styling
    /// look that a better tier upgraded or a look the reader recolored since, gives way to a copy
    /// of the look as it is now. A current copy, a copy with the reader's colors, and the book's
    /// own design stay.
    func testCopiesOfAnOlderLookGiveWayToTheLookAsItIsNow() async throws {
        // No font family, so the copies download no font.
        func look(_ provenance: String, background: String) -> SeriesLookV1 {
            SeriesLookV1(
                design: SpineDesignV1(
                    version: 1, accountID: "42", bookID: 7, workItemHash: work, coverHash: cover,
                    generatorVersion: CloudContract.generatorVersion,
                    generatedAt: Date(timeIntervalSince1970: 1_000_000),
                    backgroundHex: background, foregroundHex: "#FFFFFF", accentHex: "#FF0000",
                    typeface: "serif", weight: 600, uppercase: false, provenance: provenance),
                key: SeriesLookKey(seriesID: 5, group: "|anauthor"),
                createdAt: Date(timeIntervalSince1970: 1_000_000))
        }
        let sibling = CloudBook(
            id: 8, title: "Fictional Sequel", author: "An Author", coverURL: nil,
            detailCoverURL: nil)
        let analyzer = BookAnalyzer()
        func refreshed(_ saved: SpineDesignV1, from look: SeriesLookV1) async throws
            -> SpineDesignV1?
        {
            try await analyzer.refreshedCopy(
                of: saved, from: look, book: sibling, workItemHash: work)
        }
        let old = look("model:local", background: "#202040")
        let upgraded = look("model:google/gemini-3.8-flash", background: "#412939")
        let made = try await analyzer.seriesDesign(
            from: old.design(bookID: 7), book: sibling, accountID: "42", workItemHash: work,
            coverHash: cover)
        let stale = try XCTUnwrap(made)
        XCTAssertTrue(stale.isCopy(of: old.design(bookID: 7)))
        XCTAssertFalse(stale.isCopy(of: upgraded.design(bookID: 7)))

        let upgradedCopy = try await refreshed(stale, from: upgraded)
        let fresh = try XCTUnwrap(upgradedCopy)
        XCTAssertEqual(fresh.provenance, "series-reuse:7 model:google/gemini-3.8-flash")
        XCTAssertEqual(fresh.backgroundHex, "#412939")
        XCTAssertEqual(fresh.coverHash, cover)
        XCTAssertTrue(fresh.isCopy(of: upgraded.design(bookID: 7)))
        XCTAssertFalse(stale.outlasts(fresh, replacing: false))
        // The store takes a newer copy of the same work from the saved copy's tier.
        let recolored = upgraded.recolored(reader, at: Date(timeIntervalSince1970: 2_000_000))
        let recoloredCopy = try await refreshed(fresh, from: recolored)
        let followed = try XCTUnwrap(recoloredCopy)
        XCTAssertEqual(followed.colors, reader)
        XCTAssertFalse(fresh.outlasts(followed, replacing: false))
        // A newer copy from a weaker tier, such as of a look another device read before the
        // upgrade, or one for the book's other metadata, doesn't replace it.
        let weakerCopy = try await refreshed(fresh, from: old)
        let weaker = try XCTUnwrap(weakerCopy)
        XCTAssertTrue(fresh.outlasts(weaker, replacing: false))
        let otherWork = try XCTUnwrap(
            SpineDesignV1(
                copying: recolored.design(bookID: 7), bookID: 8, accountID: "42",
                workItemHash: String(repeating: "e", count: 64), coverHash: cover))
        XCTAssertTrue(fresh.outlasts(otherWork, replacing: false))
        // A copy without a model token reads as Private Cloud Compute, whatever made its source,
        // so any newer copy of its work replaces it.
        var untracked = stale
        untracked.provenance = "series-reuse:7"
        XCTAssertFalse(untracked.outlasts(fresh, replacing: false))

        let current = try await refreshed(fresh, from: upgraded)
        XCTAssertNil(current, "A current copy stays")
        let readersColors = try await refreshed(stale.recolored(reader), from: upgraded)
        XCTAssertNil(readersColors, "A copy with the reader's colors stays")
        XCTAssertTrue(stale.recolored(reader).outlasts(fresh, replacing: false))
        let own = upgraded.design(bookID: 8)
        let ownRefreshed = try await refreshed(own, from: old)
        XCTAssertNil(ownRefreshed, "The book's own design stays")
        XCTAssertTrue(own.outlasts(stale, replacing: false))
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

    /// `designs`, each made for its book in `books` as it is now, so it can lend by rank.
    private func current(_ designs: [Int: SpineDesignV1], in books: [CloudBook])
        -> [Int: SpineDesignV1]
    {
        designs.mapValues { design in
            books.first { $0.id == design.bookID }.map(design.current(for:)) ?? design
        }
    }

    func testSeriesMembershipNeedsTheSameSeriesAndFirstAuthor() {
        let first = seriesBook(1, by: "José Almendra")
        XCTAssertTrue(sameLook(first, seriesBook(2, by: "jose almendra")))
        XCTAssertFalse(sameLook(first, seriesBook(3, by: "Another Writer")))
        XCTAssertTrue(
            sameLook(seriesBook(4, by: "Ann Author, Co Writer"), seriesBook(5)))
        XCTAssertFalse(
            sameLook(seriesBook(4, by: "Co Writer, Ann Author"), seriesBook(5)))
        XCTAssertFalse(sameLook(seriesBook(6), seriesBook(7, series: 9)))
        XCTAssertFalse(
            sameLook(seriesBook(8, series: nil), seriesBook(9, series: nil)))
    }

    func testDiscworldBooksShareADesignOnlyWithinTheirGroup() {
        func discworld(_ id: Int, _ title: String) -> CloudBook {
            seriesBook(id, by: "Terry Pratchett", series: 1018, title: title)
        }
        let guards = discworld(1, "Guards! Guards!")
        XCTAssertTrue(sameLook(guards, discworld(2, "THUD")))
        XCTAssertTrue(sameLook(guards, discworld(3, "Night Watch: A Discworld Novel")))
        XCTAssertFalse(sameLook(guards, discworld(4, "Mort")))
        XCTAssertTrue(
            sameLook(
                discworld(5, "The Science of Discworld II: The Globe"),
                discworld(6, "The Science of Discworld")))
        // A book no group names keeps its own design.
        let maurice = discworld(7, "The Amazing Maurice and His Educated Rodents")
        XCTAssertFalse(sameLook(maurice, discworld(8, "The Amazing Maurice")))
        // Other series still match as a whole.
        XCTAssertTrue(
            sameLook(seriesBook(9, title: "One"), seriesBook(10, title: "Two")))
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
            SeriesDesigns.sources(
                ranked: SeriesDesigns.rankedLookGroups(books).values,
                designs: current(designs, in: books)),
            [2: 2, 3: 2, 4: 2, 5: 2, 6: 2])
        // Without book 2, book 4 finished before book 3 at the same position, so it leads.
        designs[2] = nil
        XCTAssertEqual(
            SeriesDesigns.sources(
                ranked: SeriesDesigns.rankedLookGroups(books).values,
                designs: current(designs, in: books)),
            [3: 4, 4: 4, 5: 4, 6: 4])

        // Without positions, the earliest finish leads, and a missing finish ranks last.
        let unnumbered = [seriesBook(10), seriesBook(11, finished: "2021-01-01"), seriesBook(9)]
        let unnumberedSources = SeriesDesigns.sources(
            ranked: SeriesDesigns.rankedLookGroups(unnumbered).values,
            designs: current(
                [9: design(for: 9), 10: design(for: 10), 11: design(for: 11)], in: unnumbered))
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
        let designs = current([1: design(for: 1), 2: design(for: 2), 3: design(for: 3)], in: books)
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            XCTAssertEqual(
                SeriesDesigns.sources(
                    ranked: SeriesDesigns.rankedLookGroups(order.map { books[$0] }).values,
                    designs: designs),
                [1: 1, 2: 1], "\(order)")
        }
    }

    /// A series keeps one font, so a book whose title the source's font can't letter still
    /// draws its source's design; readers then letter it in the system typeface.
    func testSeriesBookDrawsItsSourceWhateverTheSourceFontLetters() {
        let books = [
            seriesBook(1, position: 1), seriesBook(2, position: 2),
            seriesBook(3, position: 3, title: "東京物語"),
        ]
        let designs = current([1: design(for: 1), 2: design(for: 2), 3: design(for: 3)], in: books)
        let sources = SeriesDesigns.sources(
            ranked: SeriesDesigns.rankedLookGroups(books).values, designs: designs)
        XCTAssertEqual(sources, [1: 1, 2: 1, 3: 1])
    }

    func testOutOfDateDesignDrawsOnlyItsOwnBook() {
        // Book 1 ranks first, but its design was made for the book's earlier metadata, so it
        // lends to no one: book 3 draws book 2's design, and book 1 draws its own.
        let books = [
            seriesBook(1, position: 1), seriesBook(2, position: 2), seriesBook(3, position: 3),
        ]
        var designs = current([2: design(for: 2), 3: design(for: 3)], in: books)
        designs[1] = design(for: 1)
        XCTAssertEqual(
            SeriesDesigns.sources(
                ranked: SeriesDesigns.rankedLookGroups(books).values, designs: designs),
            [2: 2, 3: 2])
    }

    /// A model reading a preview folder that holds `books`, their saved `designs`, and saved
    /// `looks`; the folder is removed when the test ends. Each design is saved as made for its
    /// book as it is now, with the book's work-item hash, so loading creates the looks that the
    /// designs decide (`SeriesDesigns.missingLooks`).
    @MainActor
    private func previewModel(
        books: [CloudBook], designs: [SpineDesignV1], looks: [SeriesLookV1] = [],
        fonts: SpineFonts? = nil
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
        let model = AppModel(previewFolder: folder, fonts: fonts ?? SpineFonts())
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
    func testOnlyCoverlessBooksWithoutADesignUseTheDefaultStyle() async throws {
        // The series books have no cover, but book 1's design gives book 2 a design too. Book 3
        // stands alone without a cover or a design, and book 4 has a cover.
        let covered = CloudBook(
            id: 4, title: "Fictional Volume", author: "Ann Author",
            coverURL: URL(string: "https://example.com/cover.jpg"), detailCoverURL: nil)
        let books = [
            seriesBook(1, position: 1), seriesBook(2, position: 2), seriesBook(3, series: nil),
            covered,
        ]
        let (model, _) = try await previewModel(books: books, designs: [design(for: 1)])
        XCTAssertNotNil(model.design(for: books[1]))
        XCTAssertEqual(model.defaultStyledBookCount(), 1)
        XCTAssertEqual(model.designedBookCount, 2, "Book 2 draws book 1's design")

        XCTAssertNil(GenerationView.coverlessNote(0))
        XCTAssertEqual(
            GenerationView.coverlessNote(1),
            "1 book has no cover, so it gets a default style.")
        XCTAssertEqual(
            GenerationView.coverlessNote(3),
            "3 books have no cover, so they get a default style.")
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
        // A series keeps one font: Georgia can't letter book 3, so every book of the look
        // letters it in its system typeface.
        for book in books + [tokyo] {
            let drawn = try XCTUnwrap(model.design(for: book))
            XCTAssertEqual(drawn.backgroundHex, "#102030")
            XCTAssertEqual(drawn.generatorVersion, "tvos-local-v1")
            XCTAssertNil(drawn.fontPostScriptName)
            XCTAssertNil(model.look(for: book).face)
            XCTAssertNotNil(model.drawnLook(of: book))
        }

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

    /// A series without a look draws its source's design, in its face only when the face
    /// letters every book that draws it; the font picker checks every one of them too.
    @MainActor
    func testARankedSeriesLettersInTheSystemTypefaceWhenItsFaceLacksAGlyph() async throws {
        let books = [seriesBook(1, position: 1), seriesBook(2, position: 2)]
        let tokyo = seriesBook(3, position: 3, title: "東京物語")
        let latin = [seriesBook(4, series: 6, position: 1), seriesBook(5, series: 6, position: 2)]
        let saved = [1, 4]
            .map { id in
                var design = design(for: id, background: "#202020")
                design.fontPostScriptName = "Georgia-Bold"
                return design
            }
        let (model, _) = try await previewModel(books: books + [tokyo] + latin, designs: saved)
        for book in books + [tokyo] {
            XCTAssertEqual(model.designSource(for: book).id, 1, "No book leaves its series")
            XCTAssertNil(model.design(for: book)?.fontPostScriptName)
            XCTAssertEqual(model.design(for: book)?.backgroundHex, "#202020")
        }
        for book in latin {
            XCTAssertEqual(model.design(for: book)?.fontPostScriptName, "Georgia-Bold")
        }
        XCTAssertTrue(model.sharedLettering(of: books[0], uppercase: false).contains("東京物語"))
        XCTAssertFalse(model.sharedLettering(of: latin[0], uppercase: false).contains("東京物語"))
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

        // The color resets restore the colors of the design the look was made from.
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

    func testPreviewStoreRecolorsTheSavedDesign() async throws {
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

        // A run's design leaves the recolored one. Colors picked on a design that another device
        // redesigned meanwhile apply to the redesign.
        let redesigned = SpineDesignV1(
            version: 1, accountID: "42", bookID: 7, workItemHash: work, coverHash: cover,
            generatorVersion: CloudContract.generatorVersion,
            generatedAt: generated.generatedAt.addingTimeInterval(60), backgroundHex: "#FFFFFF",
            foregroundHex: "#000000", accentHex: "#0000FF", typeface: "sans", weight: 400,
            uppercase: true)
        let recolored = try await store.save(redesigned)
        XCTAssertEqual(recolored.colors, reader)
        try await store.save(redesigned, replacing: true)
        try await store.saveRecolored(generated.recolored(reader))
        let kept = try await store.savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(kept, redesigned.recolored(reader))

        // Only a book without a saved design refuses the colors.
        do {
            try await store.saveRecolored(design(for: 8).recolored(reader))
            XCTFail("Colors were saved for a book without a design")
        } catch CompanionError.designChanged {}
    }

    /// The CloudKit store keeps a design another device saved between a save's read and write
    /// when it outlasts the new one, and returns it. A recolor of a design that another device
    /// moved to the book's new metadata saves over the moved design.
    func testCloudStoreKeepsADesignAnotherDeviceSavedFirst() async throws {
        let database = ChangeTagDatabase()
        let store = try await CloudSpineStore.checked(database)
        let name = CloudContract.designRecordName(accountID: "42", bookID: 7)
        let theirs = design(provenance: "model:google/gemini-3.8-flash")
        let ours = design(provenance: "model:openai/gpt-6-luna").copy(generatedAt: Date())
        try await database.putAfterNextFetch(theirs, type: "SpineDesignV1", name: name)
        let kept = try await store.save(ours)
        XCTAssertEqual(kept, theirs)
        let saved = try await store.savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(saved, theirs)

        guard
            case .save(let moved) = theirs.action(
                workItemHash: String(repeating: "c", count: 64), coverHash: cover,
                readerChoseCover: false, runTier: .backup)
        else { return XCTFail("The design should move to the new work-item hash") }
        try await database.put(moved, type: "SpineDesignV1", name: name)
        try await store.saveRecolored(theirs.recolored(reader))
        let recolored = try await store.savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(recolored?.colors, reader)
        XCTAssertEqual(recolored?.workItemHash, moved.workItemHash)
    }

    /// A design of another contract version, such as a newer build's, is neither read nor
    /// replaced, even by a redesign the reader asked for. A malformed design of this version
    /// counts as no design.
    func testCloudStoreRefusesToReplaceAnotherVersionsDesign() async throws {
        let database = ChangeTagDatabase()
        let store = try await CloudSpineStore.checked(database)
        let name = CloudContract.designRecordName(accountID: "42", bookID: 7)
        var newer = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(design())) as? [String: Any])
        newer["version"] = 2
        newer["typeface"] = "slab"
        await database.put(
            payload: try JSONSerialization.data(withJSONObject: newer), type: "SpineDesignV1",
            name: name)
        do {
            _ = try await store.savedDesign(accountID: "42", bookID: 7)
            XCTFail("A newer build's design was read")
        } catch CompanionError.unsupportedCloudData {}
        for replacing in [false, true] {
            do {
                try await store.save(design(), replacing: replacing)
                XCTFail("A newer build's design was replaced")
            } catch CompanionError.unsupportedCloudData {}
        }

        await database.put(payload: Data(#"{"version":1}"#.utf8), type: "SpineDesignV1", name: name)
        let replaced = try await store.save(design())
        XCTAssertEqual(replaced, design())
    }

    // MARK: - The reader's font

    /// An instance of a family the reader picks, as `GoogleFonts.download(family:weight:)`
    /// returns it.
    private let picked = (
        family: "Cormorant Garamond", postScriptName: "CormorantGaramond-SemiBold"
    )

    private func refonted(_ design: SpineDesignV1) -> SpineDesignV1 {
        design.refonted(
            family: picked.family, postScriptName: picked.postScriptName, instanceWeight: 600,
            typeface: "serif")
    }

    func testReaderFontKeepsTheDesignAndItsColors() throws {
        let generated = design(provenance: "model:local font:system")
        let chosen = refonted(generated)
        XCTAssertNoThrow(try chosen.validate())
        XCTAssertEqual(chosen.fontFamily, picked.family)
        XCTAssertEqual(chosen.fontPostScriptName, picked.postScriptName)
        XCTAssertEqual(chosen.instanceWeight, 600)
        XCTAssertEqual(chosen.colors, generated.colors)
        XCTAssertTrue(chosen.isSameDesign(as: generated))
        XCTAssertTrue(chosen.hasReaderFont)
        XCTAssertTrue(chosen.hasReaderEdits)
        XCTAssertNil(chosen.generatedColors)
        // The design no longer awaits a font, and keeps its tier.
        XCTAssertEqual(chosen.provenance, "model:local reader-font")
        XCTAssertFalse(chosen.awaitsFont)
        XCTAssertEqual(chosen.tier, .local)

        // Colors and font are edits of their own: each keeps the other's token.
        let both = refonted(generated.recolored(reader))
        XCTAssertEqual(both.colors, reader)
        XCTAssertEqual(both.generatedColors, generated.colors)
        XCTAssertTrue(both.hasReaderFont)
        let reset = both.recolored(try XCTUnwrap(generated.colors))
        XCTAssertNil(reset.generatedColors)
        XCTAssertTrue(reset.hasReaderFont, "Resetting the colors keeps the reader's font")
        XCTAssertEqual(reset.fontFamily, picked.family)
        XCTAssertEqual(refonted(chosen), chosen, "Choosing again adds no second token")

        // Both tokens fit in 80 characters beside a long model token, which still names a
        // backup model.
        let custom = design(provenance: "model:custom/" + String(repeating: "m", count: 60))
        let long = refonted(custom.recolored(reader))
        XCTAssertEqual(long.provenance?.count, 80)
        XCTAssertEqual(long.tier, .backup)
        XCTAssertTrue(long.hasReaderFont)
        XCTAssertEqual(long.generatedColors, custom.colors)
        XCTAssertNoThrow(try long.validate())

        // The token decodes through JSON, as other devices read it.
        let decoded = try JSONDecoder()
            .decode(
                SpineDesignV1.self, from: JSONEncoder().encode(chosen))
        XCTAssertTrue(decoded.hasReaderFont)
        XCTAssertEqual(decoded.fontFamily, picked.family)
    }

    func testGenerationKeepsTheReadersFont() throws {
        let onDevice = design(provenance: "model:apple/on-device")
        let chosen = refonted(onDevice)
        let otherWork = String(repeating: "c", count: 64)
        let otherCover = String(repeating: "d", count: 64)
        func action(
            _ design: SpineDesignV1, work: String? = nil, cover: String? = nil,
            readerChoseCover: Bool = false, fromChosenCover: Bool = false
        ) -> SavedDesignAction {
            design.action(
                workItemHash: work ?? self.work, coverHash: cover ?? self.cover,
                readerChoseCover: readerChoseCover, fromChosenCover: fromChosenCover,
                runTier: .privateCloudCompute)
        }

        // A better tier redesigns the generator's font, but not the reader's.
        XCTAssertEqual(action(onDevice), .redesign)
        XCTAssertEqual(action(chosen), .keep)
        XCTAssertEqual(action(chosen, cover: otherCover), .keep)
        XCTAssertEqual(action(chosen, cover: otherCover, fromChosenCover: true), .keep)
        // After a metadata change, the font moves to the new work-item hash.
        guard case .save(let moved) = action(chosen, work: otherWork) else {
            return XCTFail("The reader's font should move to the new work-item hash")
        }
        XCTAssertEqual(moved.fontFamily, picked.family)
        XCTAssertEqual(moved.fontPostScriptName, picked.postScriptName)
        XCTAssertTrue(moved.hasReaderFont)
        // Only another cover the reader chooses designs the spine again.
        XCTAssertEqual(action(chosen, cover: otherCover, readerChoseCover: true), .redesign)

        // A better tier's save leaves it, as a redesign the reader asks for doesn't.
        let pcc = design()
        XCTAssertFalse(onDevice.outlasts(pcc, replacing: false))
        XCTAssertTrue(chosen.outlasts(pcc, replacing: false))
        let redesigned = pcc.copy(generatedAt: chosen.generatedAt.addingTimeInterval(60))
        XCTAssertFalse(chosen.outlasts(redesigned, replacing: true))

        // A series look made from it counts as edited, so no upgrade replaces the font.
        let key = SeriesLookKey(seriesID: 5, group: "|annauthor")
        let look = SeriesLookV1(design: chosen, key: key, createdAt: .now)
        XCTAssertNotNil(look.editedAt)
        XCTAssertFalse(look.isUpgraded(at: .privateCloudCompute))
        XCTAssertEqual(look.fontFamily, picked.family)
        let provenance = try XCTUnwrap(look.provenance)
        XCTAssertFalse(provenance.split(separator: " ").contains("reader-font"))
    }

    func testFontChoiceOfASeriesLookKeepsItsColorsAndAnyRecoloring() throws {
        let key = SeriesLookKey(seriesID: 5, group: "|annauthor")
        let saved = SeriesLookV1(
            design: design(provenance: "model:local font:system"), key: key,
            createdAt: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(saved.isUpgraded(at: .onDevice))
        let edited = Date(timeIntervalSince1970: 2_000_000)
        let chosen = saved.refonted(
            family: picked.family, postScriptName: picked.postScriptName, instanceWeight: 600,
            typeface: "serif", at: edited)
        XCTAssertNoThrow(try chosen.validate())
        XCTAssertEqual(chosen.editedAt, edited)
        XCTAssertEqual(chosen.backgroundHex, saved.backgroundHex)
        XCTAssertEqual(chosen.provenance, "model:local reader-font")
        XCTAssertTrue(chosen.hasReaderFont)
        XCTAssertFalse(chosen.isUpgraded(at: .privateCloudCompute))
        XCTAssertFalse(chosen.awaitsFont)
        // Books draw the look without the reader's token, so copies of it don't carry it.
        XCTAssertEqual(chosen.design(bookID: 7).provenance, "model:local")
        XCTAssertEqual(chosen.design(bookID: 7).fontFamily, picked.family)
    }

    @MainActor
    func testChoosingAFontSavesItAndKeepsTheColors() async throws {
        let book = seriesBook(7, series: nil)
        var saved = design()
        saved.choice = SpineChoice(candidates: ["EB Garamond", "Lora", "Gelasio"])
        let (model, folder) = try await previewModel(
            books: [book], designs: [saved.recolored(reader)], fonts: try offlineFonts())
        XCTAssertEqual(model.fontChoices(for: book), ["EB Garamond", "Lora", "Gelasio"])

        try await model.setFont("Gelasio", for: book)
        XCTAssertEqual(model.design(for: book)?.fontFamily, "Gelasio")
        let stored = try await LocalSpineStore(folder: folder)
            .savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(stored?.fontFamily, "Gelasio")
        XCTAssertNotNil(stored?.fontPostScriptName)
        XCTAssertNotNil(stored?.instanceWeight)
        XCTAssertEqual(stored?.colors, reader, "The reader's colors stay")
        XCTAssertTrue(stored?.hasReaderFont == true)
        XCTAssertEqual(stored?.choice, saved.choice)

        // Another launch reads the font back, and a later recoloring keeps it.
        let relaunched = AppModel(previewFolder: folder, fonts: try offlineFonts())
        await relaunched.reload()
        XCTAssertEqual(relaunched.design(for: book)?.fontFamily, "Gelasio")
        try await relaunched.recolor(book, to: try XCTUnwrap(design().colors))
        let recolored = try await LocalSpineStore(folder: folder)
            .savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(recolored?.fontFamily, "Gelasio")
        XCTAssertTrue(recolored?.hasReaderFont == true)
        XCTAssertNil(recolored?.generatedColors)
    }

    @MainActor
    func testResetColorsSkipsASourceRedesignedAfterItsLook() async throws {
        let books = [seriesBook(1, position: 1), seriesBook(2, position: 2)]
        let saved = [
            design(for: 1, background: "#202020"),
            design(for: 2, background: "#404040").movedBack(),
        ]
        let (model, folder) = try await previewModel(books: books, designs: saved)
        try await model.recolor(books[0], to: reader)
        XCTAssertEqual(model.generatedColors(for: books[0])?.background.hex, "#404040")

        // The source's own redesign, made after the look, has colors unrelated to the look's,
        // even once the reader edits the look again.
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: books[0], link: nil))
        let created = try XCTUnwrap(model.library?.looks[key]).createdAt
        let redesigned = design(for: 2, background: "#606060")
            .copy(generatedAt: created.addingTimeInterval(60))
        try await LocalSpineStore(folder: folder).save(redesigned, replacing: true)
        await model.reload()
        try await model.recolor(books[0], to: reader)
        XCTAssertEqual(model.look(for: books[0]).background, reader.background)
        XCTAssertNil(model.generatedColors(for: books[0]))

        // A redesign that remakes the look from that design makes it the look's source again,
        // and so does an upgrade, which keeps the look's creation date too.
        let look = try XCTUnwrap(model.library?.looks[key])
        let remade = look.remade(from: redesigned, at: created.addingTimeInterval(120))
        XCTAssertEqual(remade.createdAt, look.createdAt)
        XCTAssertNotNil(remade.remadeAt)
        try await LocalSpineStore(folder: folder).save(remade)
        await model.reload()
        XCTAssertEqual(model.generatedColors(for: books[0])?.background.hex, "#606060")
        let upgraded = look.upgraded(from: redesigned, at: created.addingTimeInterval(120))
        XCTAssertNil(upgraded.editedAt)
        try await LocalSpineStore(folder: folder).save(upgraded)
        await model.reload()
        XCTAssertEqual(model.generatedColors(for: books[0])?.background.hex, "#606060")
    }

    @MainActor
    func testAFontMustLetterTheBook() async throws {
        let book = seriesBook(7, series: nil, title: "東京物語")
        let (model, folder) = try await previewModel(
            books: [book], designs: [design()], fonts: try offlineFonts())
        do {
            try await model.setFont("Gelasio", for: book)
            XCTFail("A font without the title's glyphs was picked")
        } catch CompanionError.invalidDesign {}
        let stored = try await LocalSpineStore(folder: folder)
            .savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(stored?.fontFamily, design().fontFamily)
    }

    @MainActor
    func testReadersCanPickOnlyAtlasFamilies() async throws {
        let book = seriesBook(7, series: nil)
        let (model, folder) = try await previewModel(
            books: [book], designs: [design()], fonts: try offlineFonts())
        // In Google's catalog but not the atlas, as with a script that leans without saying so.
        do {
            try await model.setFont("Filler 1", for: book)
            XCTFail("A family outside the atlas was picked")
        } catch CompanionError.invalidDesign {}
        let stored = try await LocalSpineStore(folder: folder)
            .savedDesign(accountID: "42", bookID: 7)
        XCTAssertEqual(stored?.fontFamily, design().fontFamily, "The font stays")
        XCTAssertFalse(stored?.hasReaderFont == true)
        let pickable = await AppModel.pickableFamilies()
        XCTAssertTrue(pickable.contains("Gelasio"))
        XCTAssertFalse(pickable.contains("Great Vibes"), "Leans")
        XCTAssertFalse(pickable.contains("Italiana"), "Never generated")
    }

    /// The font picker hides Google's Noto families for other writing systems and number sets
    /// and keeps the Latin-script Noto families, but a spine set in a hidden family still lists
    /// it as its current one.
    @MainActor
    func testThePickerHidesNotoFamiliesForOtherScripts() async throws {
        let hidden = [
            "Noto Sans Old Hungarian", "Noto Sans Mayan Numerals", "Noto Serif Tangut",
            "Noto Serif Khitan Small Script", "Noto Sans Mono Hebrew", "Noto Sans JP",
            "Noto Naskh Arabic", "Noto Color Emoji",
        ]
        for family in hidden { XCTAssertFalse(AppModel.listsInPicker(family), family) }
        let kept = [
            "Noto Sans", "Noto Serif", "Noto Sans Mono", "Noto Sans Display", "Noto Serif Display",
            "Noto Sans Condensed", "Noto Serif Display SemiBold", "Gelasio", "Notable",
        ]
        for family in kept { XCTAssertTrue(AppModel.listsInPicker(family), family) }

        let book = seriesBook(7, series: nil)
        var saved = design(for: 7, family: "Noto Serif Tangut")
        saved.choice = SpineChoice(
            candidates: ["Noto Sans Old Hungarian", "Lora", "Noto Serif Tangut", "Noto Sans"])
        let (model, _) = try await previewModel(
            books: [book], designs: [saved], fonts: try offlineFonts())
        XCTAssertEqual(model.fontChoices(for: book), ["Lora", "Noto Serif Tangut", "Noto Sans"])
    }

    @MainActor
    func testChoosingAFontForASeriesBookChangesTheSeriesLook() async throws {
        let first = seriesBook(1, position: 1)
        let second = seriesBook(2, position: 2)
        let (model, folder) = try await previewModel(
            books: [first, second],
            designs: [design(for: 1, background: "#202020"), design(for: 2).movedBack()],
            fonts: try offlineFonts())
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: first, link: nil))
        XCTAssertNotNil(model.library?.looks[key], "The reload created the group's look")

        try await model.setFont("Gelasio", for: first)
        let look =
            try await LocalSpineStore(folder: folder)
            .seriesLooks(accountID: "42", keys: [key])[key]
        XCTAssertEqual(look?.fontFamily, "Gelasio")
        XCTAssertEqual(look?.backgroundHex, "#000000")
        XCTAssertNotNil(look?.editedAt)
        XCTAssertEqual(model.design(for: second)?.fontFamily, "Gelasio")
        // Reset colors still finds the generator's colors of the look's source design.
        XCTAssertEqual(model.generatedColors(for: first)?.background.hex, "#000000")
        // Each book's own saved design keeps its font.
        let own = try await LocalSpineStore(folder: folder).savedDesign(accountID: "42", bookID: 1)
        XCTAssertNil(own?.fontFamily)
    }

    /// Fonts that download "Gelasio", a copy of the installed Georgia, from a folder of their
    /// own, with every request failing as if offline.
    @MainActor
    private func offlineFonts() throws -> SpineFonts {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-fonts-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: CloudContract.digest("files-v2:Gelasio:600"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let families = ["Gelasio"] + (1...100).map { "Filler \($0)" }
        try JSONSerialization.data(
            withJSONObject: ["familyMetadataList": families.map { ["family": $0] }]
        )
        .write(to: root.appending(path: "catalog.json"))
        let georgia = CTFontCreateWithName("Georgia" as CFString, 12, nil)
        let file = try XCTUnwrap(CTFontCopyAttribute(georgia, kCTFontURLAttribute) as? URL)
        try FileManager.default.copyItem(at: file, to: directory.appending(path: "font.ttf"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        return SpineFonts(downloader: GoogleFonts(root: root, configuration: configuration))
    }

    /// Returns whether `book` and `other` draw one series look: the same non-nil look key.
    private func sameLook(_ book: CloudBook, _ other: CloudBook) -> Bool {
        guard let key = SeriesDesigns.lookKey(of: book, link: book.seriesLink) else {
            return false
        }
        return key == SeriesDesigns.lookKey(of: other, link: other.seriesLink)
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

    fileprivate func copy(workItemHash: String? = nil, generatedAt: Date? = nil) -> SpineDesignV1 {
        SpineDesignV1(
            version: version, accountID: accountID, bookID: bookID,
            workItemHash: workItemHash ?? self.workItemHash, coverHash: coverHash,
            generatorVersion: generatorVersion, generatedAt: generatedAt ?? self.generatedAt,
            backgroundHex: backgroundHex, foregroundHex: foregroundHex, accentHex: accentHex,
            typeface: typeface, weight: weight, uppercase: uppercase, fontFamily: fontFamily,
            fontPostScriptName: fontPostScriptName, instanceWeight: instanceWeight,
            provenance: provenance, choice: choice)
    }
}
