import SwiftUI

// The walnut room's colors. System glass (bars, the sidebar, sheets, menus) stays system and
// takes only the accent color (`AccentColor`).

/// The walnut room's palette, from the Apple TV's dark wood shelf.
///
/// The colors live in the asset catalog. Each color that text or controls use or sit on has a
/// High Contrast variant, which Increase Contrast selects; the room is dark in both appearances,
/// so none has a dark variant.
enum ShelfPalette {
    /// The wall's lighter end, at its top, for contrast math; `ShelfWallTop` holds the same
    /// color for drawing, and `PaletteTests` keeps the two equal.
    static let wallLight = ColorValue(red: 51, green: 37, blue: 27)
    static let wall = LinearGradient(
        colors: [Color(.shelfWallTop), Color(.shelfWallBottom)], startPoint: .top,
        endPoint: .bottom)
    static let board = Color(.shelfBoard)
    /// The lamp's warm light, and the tint of controls drawn over the walnut.
    static let lamp = Color(.shelfLamp)
    /// Text on the walnut.
    static let paper = Color(.shelfPaper)
    static let gold = Color(.shelfGold)
}
