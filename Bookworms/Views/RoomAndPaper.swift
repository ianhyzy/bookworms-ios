import SwiftUI

// The app's two content grounds and its type: the walnut room behind Library, Desk, and book
// details, and paper behind the screens outside the room, such as Share and Spines. System glass
// (bars, the sidebar, sheets, menus) stays system and takes only the accent color
// (`AccentColor`). Both grounds are gradients and static tiled images, so they cost nothing
// while content above them scrolls or animates; add no shaders, blur, or timers to them.

/// The walnut room's palette, from the Apple TV's dark wood shelf.
///
/// The colors live in the asset catalog. Each color that text or controls use or sit on has a
/// High Contrast variant, which Increase Contrast selects; the room is dark in both appearances,
/// so none has a dark variant.
enum ShelfPalette {
    /// The wall's lighter end, at its top, for contrast math; `ShelfWallTop` holds the same
    /// color for drawing, and `PaletteTests` keeps the two equal.
    static let wallLight = ColorValue(red: 51, green: 37, blue: 27)
    /// The wall's color alone, for small stand-ins and renders. Screens draw `WalnutWall`.
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

/// The walnut wall behind Library, Desk, and book details: `ShelfPalette.wall` with a faint wood
/// grain and a seam every 180 points, so it reads as tall panels. Increase Contrast leaves out
/// the grain and seams.
///
/// The grain (`WallGrain`, baked from the table's wood by `script/room-textures.swift`) holds
/// only lightness around the wall's middle color, so at 12% it adds grain without lightening or
/// tinting the wall.
///
/// The grain is a static tiled image and the seams a canvas that draws again only when the
/// wall's size changes, each a layer of its own, so nothing redraws when the content above them
/// scrolls. `opacity` fades each layer rather than the group, so a fading wall, such as the
/// veil behind a book that flies to its details, needs no offscreen pass. Fill the screen with
/// it, ignoring the safe area, so every wall's panels line up.
struct WalnutWall: View {
    var opacity: Double = 1
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ShelfPalette.wall
            .opacity(opacity)
            .overlay {
                if contrast == .standard {
                    Image(.wallGrain).resizable(resizingMode: .tile).opacity(0.12 * opacity)
                    WallSeams().opacity(opacity)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The seams between the wall's panels: a shadowed groove with a faintly lit edge beside it.
/// A panel is centered on the wall, so the seams fall symmetrically on each side.
///
/// It has no inputs, so a change to the wall's opacity never makes it draw again.
private struct WallSeams: View {
    static let panelWidth: CGFloat = 180

    var body: some View {
        Canvas { context, size in
            var x = (size.width - Self.panelWidth) / 2
            while x > 0 { x -= Self.panelWidth }
            while x < size.width {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                    with: .color(.black.opacity(0.25)))
                context.fill(
                    Path(CGRect(x: x + 1, y: 0, width: 0.5, height: size.height)),
                    with: .color(ShelfPalette.lamp.opacity(0.06)))
                x += Self.panelWidth
            }
        }
    }
}

/// The paper ground behind screens outside the room, such as Share, Spines, and the content of
/// sheets: the app icon's cream in light appearance and ink walnut in dark (`PaperTop` and
/// `PaperBottom`, with High Contrast variants), under a faint dither (`PaperDither`) that keeps
/// the gentle gradient from banding.
///
/// Draw it behind a screen's content, never as a window, sheet, or presentation background,
/// which keep the system's materials. Behind a `Form` or `List`:
///
/// ```swift
/// Form { ... }
///     .scrollContentBackground(.hidden)
///     .background { PaperGround().ignoresSafeArea() }
/// ```
///
/// Primary text and the accent keep 4.5:1 or more on it, and the accent 7:1 on light paper under
/// Increase Contrast (`PaletteTests`). Secondary text keeps about the 3:1 it has on the system's grouped
/// background.
struct PaperGround: View {
    var body: some View {
        LinearGradient(
            colors: [Color(.paperTop), Color(.paperBottom)], startPoint: .top, endPoint: .bottom
        )
        .overlay { Image(.paperDither).resizable(resizingMode: .tile).opacity(0.03) }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Sets a heading in New York, the serif of the app's book titles and share images: section
    /// headers, empty-state titles, and screen headers. Controls and rows stay in SF.
    func bookHeading() -> some View { fontDesign(.serif) }
}

extension Font {
    /// A small-caps label, like a library catalog card's headings, for card captions and stat
    /// labels. It scales with Dynamic Type from footnote, below which small caps grow hard to
    /// read.
    static let catalogLabel = Font.footnote.weight(.semibold).smallCaps()
}
