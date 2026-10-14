import XCTest

@testable import Bookworms

/// Covers House of Leaves' blue "house": which book it applies to, which words turn blue, and
/// how far the blue moves to stay legible.
final class HouseOfLeavesTests: XCTestCase {
    private func book(_ title: String, by author: String = "Mark Z. Danielewski") -> CloudBook {
        CloudBook(id: 1, title: title, author: author, coverURL: nil, detailCoverURL: nil)
    }

    private func words(_ text: String) -> [String] {
        HouseOfLeaves.houseRanges(in: text).map { String(text[$0]) }
    }

    func testRecognizesTheNovelInAnyEdition() {
        for title in [
            "House of Leaves", "house of leaves", "HOUSE OF LEAVES",
            "House of Leaves: The Remastered Full-Color Edition",
            "House of Leaves (Remastered Edition)", "House of Leaves [Full Color]",
            "House of Leaves — Pelafina's Letters", " House of Leaves ",
        ] {
            XCTAssertTrue(HouseOfLeaves.isNovel(book(title)), title)
        }
        XCTAssertTrue(HouseOfLeaves.isNovel(book("House of Leaves", by: "Mark Danielewski")))
        XCTAssertTrue(
            HouseOfLeaves.isNovel(book("House of Leaves", by: "Mark Z. Danielewski, Zampanò")))
    }

    func testLeavesEveryOtherBookAlone() {
        XCTAssertFalse(HouseOfLeaves.isNovel(book("House of Leaves", by: "Someone Else")))
        XCTAssertFalse(HouseOfLeaves.isNovel(book("The Fifty Year Sword")))
        XCTAssertFalse(HouseOfLeaves.isNovel(book("The Whalestoe Letters")))
        XCTAssertFalse(HouseOfLeaves.isNovel(book("Only Revolutions: House of Leaves")))
        XCTAssertFalse(
            HouseOfLeaves.isNovel(
                book("The Room Where It Happened: A White House Memoir", by: "John R. Bolton")))
        XCTAssertFalse(HouseOfLeaves.isNovel(book("Slaughterhouse-Five", by: "Kurt Vonnegut")))
        XCTAssertFalse(HouseOfLeaves.isNovel(book("The House in the Cerulean Sea", by: "TJ Klune")))
    }

    func testFindsTheWordHouseWithItsEndings() {
        XCTAssertEqual(
            words("House, house; HOUSE. The house's hall, the house’s stairs, two houses."),
            ["House", "house", "HOUSE", "house's", "house’s", "houses"])
        XCTAssertEqual(words("A house-like shape"), ["house"])
        XCTAssertEqual(words("“House”"), ["House"])
    }

    func testSkipsWordsThatOnlyContainHouse() {
        XCTAssertEqual(
            words("household lighthouse Housekeeping penthouses Slaughterhouse warehouse_1"), [])
        XCTAssertEqual(words("Leaves"), [])
    }

    func testKeepsTheNovelsBlueWhereItAlreadyReads() {
        let white = ColorValue(red: 255, green: 255, blue: 255)
        XCTAssertEqual(
            HouseOfLeaves.blue(on: white, ink: ColorValue(red: 0, green: 0, blue: 0)),
            HouseOfLeaves.novelBlue)
    }

    func testMovesTheBlueOnlyAsFarAsLegibilityNeeds() {
        let paper = ColorValue(red: 242, green: 230, blue: 209)
        let cream = ShareStyle.cream
        let black = ColorValue(red: 0, green: 0, blue: 0)
        let cases: [(ground: ColorValue, ink: ColorValue)] = [
            (ColorValue(red: 51, green: 37, blue: 27), paper),  // The walnut wall's top.
            (ColorValue(red: 28, green: 20, blue: 14), paper),  // Its bottom.
            (ColorValue(hex: "#16120E")!, ColorValue(hex: "#DFD8CC")!),  // A near-black cloth.
            (ColorValue(red: 150, green: 40, blue: 40), cream),  // A red cloth.
            (cream, ColorValue(red: 40, green: 30, blue: 20)),  // A cream cloth.
            (ColorValue(red: 220, green: 180, blue: 60), black),  // A yellow cloth.
        ]
        for (ground, ink) in cases {
            let blue = HouseOfLeaves.blue(on: ground, ink: ink)
            // Legible on the bare ground and where the glow lights it.
            let lit = ground.mixed(
                with: ColorValue(red: 255, green: 255, blue: 255), HouseOfLeaves.glowLift)
            XCTAssertTrue(HouseOfLeaves.passes(blue, on: ground), ground.hex)
            XCTAssertTrue(HouseOfLeaves.passes(blue, on: lit), ground.hex)
            // Still blue: the blue channel leads.
            XCTAssertGreaterThan(blue.blue, max(blue.red, blue.green), ground.hex)
            // A step and a half less would not pass.
            var lab = SpineContrast.lab(blue)
            lab.l += SpineContrast.lab(ink).l > SpineContrast.lab(ground).l ? -0.015 : 0.015
            let weaker = SpineContrast.color(lab)
            XCTAssertFalse(
                HouseOfLeaves.passes(weaker, on: ground) && HouseOfLeaves.passes(weaker, on: lit),
                ground.hex)
        }
    }

    func testSchemeBluesReadOnEveryGroundOfTheirScheme() {
        let walnutCard = ColorValue(red: 51, green: 37, blue: 27)
            .mixed(with: ColorValue(red: 255, green: 255, blue: 255), 0.07)
        let shareGrounds = stride(from: 0.0, to: 360, by: 5)
            .flatMap { hue in
                let theme = ShareTheme(hue: hue, chroma: 0.09)
                return [theme.glow, theme.panel(), theme.backdropLight, theme.backdropDark]
            }
        let dark =
            [
                ColorValue(red: 28, green: 20, blue: 14), walnutCard,
                ColorValue(red: 0, green: 0, blue: 0), ColorValue(hex: "#1C1C1E")!,
                ColorValue(hex: "#2C2C2E")!,
            ] + shareGrounds
        for ground in dark {
            XCTAssertTrue(HouseOfLeaves.passes(HouseOfLeaves.darkBlue, on: ground), ground.hex)
        }
        for ground in [ColorValue(red: 255, green: 255, blue: 255), HouseOfLeaves.lightGround] {
            XCTAssertTrue(HouseOfLeaves.passes(HouseOfLeaves.lightBlue, on: ground), ground.hex)
        }
    }
}
