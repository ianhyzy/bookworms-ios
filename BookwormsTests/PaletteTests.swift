import UIKit
import XCTest

@testable import Bookworms

/// Checks the asset catalog's colors: the accent, the walnut room, and the paper ground keep
/// their contrast in each appearance, and more under Increase Contrast.
@MainActor
final class PaletteTests: XCTestCase {
    private enum Look: CaseIterable {
        case light, dark, lightHigh, darkHigh

        @MainActor var traits: UITraitCollection {
            UITraitCollection { traits in
                traits.userInterfaceStyle = self == .light || self == .lightHigh ? .light : .dark
                traits.accessibilityContrast =
                    self == .lightHigh || self == .darkHigh ? .high : .normal
            }
        }
    }

    private func color(_ name: String, _ look: Look) throws -> ColorValue {
        let color = try XCTUnwrap(UIColor(named: name, in: .main, compatibleWith: nil))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.resolvedColor(with: look.traits)
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return ColorValue(
            red: Int((red * 255).rounded()), green: Int((green * 255).rounded()),
            blue: Int((blue * 255).rounded()))
    }

    private let white = ColorValue(red: 255, green: 255, blue: 255)
    private let black = ColorValue(red: 0, green: 0, blue: 0)
    /// A dark grouped list's cell, the ground most dark-appearance accent text sits on.
    private let darkCell = ColorValue(red: 0x1C, green: 0x1C, blue: 0x1E)

    /// The accent reads as text on white, paper, and dark cells, and holds white labels, as
    /// prominent buttons and filled toggles draw them: 4.5:1 for light appearance's labels, 7:1
    /// under Increase Contrast, and 3:1, the large text and icon minimum, in dark appearance, as
    /// the system's dark blue does. A dark accent light enough for 7:1 text would drop white
    /// labels below 3:1, so dark Increase Contrast keeps nearly the dark accent and 4.5:1 text.
    func testAccentReadsOnPaperAndSystemGrounds() throws {
        for look in Look.allCases {
            let accent = try color("AccentColor", look)
            switch look {
            case .light, .lightHigh:
                let needed = look == .lightHigh ? 7.0 : 4.5
                XCTAssertGreaterThanOrEqual(accent.contrast(with: white), needed, "\(look)")
                let paper = try color("PaperBottom", look)
                XCTAssertGreaterThanOrEqual(accent.contrast(with: paper), needed, "\(look)")
            case .dark, .darkHigh:
                XCTAssertGreaterThanOrEqual(accent.contrast(with: white), 3, "\(look)")
                XCTAssertGreaterThanOrEqual(accent.contrast(with: darkCell), 4.5, "\(look)")
                let paper = try color("PaperTop", look)
                XCTAssertGreaterThanOrEqual(accent.contrast(with: paper), 4.5, "\(look)")
            }
        }
        // A High Contrast variant identical to the standard one makes the system brighten the
        // accent itself under Increase Contrast, past these limits.
        XCTAssertNotEqual(try color("AccentColor", .darkHigh), try color("AccentColor", .dark))
    }

    func testTextOnPaperKeepsBodyContrast() throws {
        for look in Look.allCases {
            let ink = look == .light || look == .lightHigh ? black : white
            for name in ["PaperTop", "PaperBottom"] {
                let paper = try color(name, look)
                XCTAssertGreaterThanOrEqual(ink.contrast(with: paper), 7, "\(name) \(look)")
            }
        }
    }

    func testRoomColorsReadOnTheWallAndGainContrast() throws {
        // The room is dark in both appearances, so only the contrast setting changes it.
        for look in [Look.light, .lightHigh] {
            let wall = try color("ShelfWallTop", look)
            for name in ["ShelfPaper", "ShelfLamp", "ShelfGold"] {
                let ink = try color(name, look)
                XCTAssertGreaterThanOrEqual(ink.contrast(with: wall), 7, "\(name) \(look)")
            }
        }
        for name in ["ShelfPaper", "ShelfLamp", "ShelfGold"] {
            let standard = try color(name, .light).contrast(with: color("ShelfWallTop", .light))
            let high = try color(name, .lightHigh).contrast(with: color("ShelfWallTop", .lightHigh))
            XCTAssertGreaterThan(high, standard, name)
        }
        XCTAssertEqual(try color("ShelfWallTop", .dark), try color("ShelfWallTop", .light))
    }

    /// Prominent buttons under the lamp's tint, in Library, Desk, and the cover picker, label in
    /// dark ink, which keeps 7:1 on the lamp's light, also under Increase Contrast.
    func testLampHoldsDarkInkLabels() throws {
        for look in Look.allCases {
            let contrast = try color("ShelfLamp", look).contrast(with: Stationery.inkValue)
            XCTAssertGreaterThanOrEqual(contrast, 7, "\(look): \(contrast)")
        }
    }

    func testWallLightMatchesItsColorSet() throws {
        XCTAssertEqual(try color("ShelfWallTop", .light), ShelfPalette.wallLight)
    }
}
