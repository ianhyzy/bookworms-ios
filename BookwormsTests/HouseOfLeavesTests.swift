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

    private let white = ColorValue(red: 255, green: 255, blue: 255)
    private let black = ColorValue(red: 0, green: 0, blue: 0)

    func testKeepsTheNovelsBlueWhereItAlreadyReads() {
        let lettering = HouseOfLeaves.lettering(on: white)
        XCTAssertEqual(lettering.blue, HouseOfLeaves.novelBlue)
        XCTAssertTrue(lettering.glows)
    }

    func testMovesTheBlueOnlyAsFarAsLegibilityNeeds() {
        let paper = ColorValue(red: 242, green: 230, blue: 209)
        let cream = ShareStyle.cream
        let cases: [(ground: ColorValue, ink: ColorValue?)] = [
            (ShelfPalette.wallLight, paper),
            (ColorValue(red: 28, green: 20, blue: 14), paper),  // The walnut wall's bottom.
            (HouseOfLeaves.darkGround, nil),
            (HouseOfLeaves.lightGround, nil),
            (ColorValue(hex: "#16120E")!, ColorValue(hex: "#DFD8CC")!),  // A near-black cloth.
            (ColorValue(red: 150, green: 40, blue: 40), cream),  // A red cloth.
            (cream, ColorValue(red: 40, green: 30, blue: 20)),  // A cream cloth.
            (ColorValue(red: 220, green: 180, blue: 60), black),  // A yellow cloth.
        ]
        for (ground, ink) in cases {
            let lettering = HouseOfLeaves.lettering(on: ground, ink: ink)
            let blue = lettering.blue
            XCTAssertTrue(HouseOfLeaves.passes(blue, on: ground), ground.hex)
            // Still blue: the blue channel leads.
            XCTAssertGreaterThan(blue.blue, max(blue.red, blue.green), ground.hex)
            // Only a blue darker than its ground glows, where the glow adds contrast.
            let darker = SpineContrast.lab(blue).l < SpineContrast.lab(ground).l
            XCTAssertEqual(lettering.glows, darker, ground.hex)
            // A step and a half less would not pass.
            var lab = SpineContrast.lab(blue)
            lab.l += darker ? 0.015 : -0.015
            let weaker = SpineContrast.color(lab)
            XCTAssertFalse(HouseOfLeaves.passes(weaker, on: ground), ground.hex)
        }
    }

    func testDefaultDarkBlueReadsOnTheWalnutWallAndDarkLists() {
        let blue = HouseOfLeaves.lettering(on: HouseOfLeaves.darkGround).blue
        for ground in [
            ShelfPalette.wallLight, ColorValue(red: 28, green: 20, blue: 14), black,
            ColorValue(hex: "#1C1C1E")!, HouseOfLeaves.darkGround,
        ] {
            XCTAssertTrue(HouseOfLeaves.passes(blue, on: ground), ground.hex)
        }
    }

    func testFallsBackToTheInkWhereNoBlueReads() {
        // The novel's blue as a cloth, with white lettering.
        let lettering = HouseOfLeaves.lettering(on: HouseOfLeaves.novelBlue, ink: white)
        XCTAssertEqual(lettering.blue, white)
        XCTAssertFalse(lettering.glows)
    }
}
