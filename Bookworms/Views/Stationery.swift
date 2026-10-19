import SwiftUI

// The paper props inside the app's screens: the library card that holds the Hardcover sign-in
// code, the bookplate of the signed-in account, and a book's date-due card and review page.
// They are objects, not chrome, so they keep their colors in both appearances, as a real card
// would. Each is a flat fill with a static dither tile and, on ruled cards, rules that a canvas
// draws only when the card's size changes; their shadows are one baked image (`SoftShadow`).
// Nothing here draws per frame, blurs, or needs an offscreen pass.

/// The colors of card stock and the inks on it. Every ink keeps 7:1 or more on the stock
/// (`StationeryTests`).
enum Stationery {
    /// Library card stock.
    static let stockValue = ColorValue(red: 0xEF, green: 0xE3, blue: 0xCC)
    /// Typed and printed text.
    static let inkValue = ColorValue(red: 0x2B, green: 0x21, blue: 0x17)
    /// Printed labels, such as a card's column headings.
    static let labelInkValue = ColorValue(red: 0x4E, green: 0x3E, blue: 0x2F)
    /// A date stamp's violet ink.
    static let stampInkValue = ColorValue(red: 0x2E, green: 0x2A, blue: 0x6B)

    static let stock = stockValue.color
    static let ink = inkValue.color
    static let labelInk = labelInkValue.color
    static let stampInk = stampInkValue.color
    /// A library card's printed rules: faint ink, decoration only.
    static let rule = inkValue.color.opacity(0.14)
    /// The red rule under a library card's heading, and a bookmark ribbon's cloth.
    static let red = ColorValue(red: 0x8E, green: 0x2B, blue: 0x24).color
}

/// A piece of card stock behind `content`, with its ink as the foreground style, a printed rule
/// every `ruleSpacing` points when set, and a soft shadow on whatever it lies on.
struct CardStockSheet<Content: View>: View {
    var ruleSpacing: CGFloat?
    var cornerRadius: CGFloat = 4
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(Stationery.ink)
            .environment(\.bookTextGround, Stationery.stockValue)
            .background {
                ZStack {
                    Stationery.stock
                    Image(.paperDither).resizable(resizingMode: .tile).opacity(0.05)
                    if let ruleSpacing { CardRules(spacing: ruleSpacing) }
                }
                .clipShape(.rect(cornerRadius: cornerRadius))
                .background { SoftShadow(cornerRadius: cornerRadius) }
                .accessibilityHidden(true)
            }
    }
}

/// Printed rules across a card, `spacing` points apart, starting one space below its top.
private struct CardRules: View {
    let spacing: CGFloat

    var body: some View {
        Canvas { context, size in
            var y = spacing
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.75)),
                    with: .color(Stationery.rule))
                y += spacing
            }
        }
    }
}

/// The soft shadow under a flat object of the frame's size: one baked, blurred image
/// (`SoftShadow`, from `script/room-textures.swift`) stretched between fixed corners, so it
/// costs no blur pass. It falls a little below the object, as under a lamp above.
struct SoftShadow: View {
    var cornerRadius: CGFloat = 4
    var opacity = 0.55

    var body: some View {
        // The image is 96 points square: a 24-point blur around a 48-point rectangle.
        Image(.softShadow)
            .resizable(
                capInsets: EdgeInsets(top: 40, leading: 40, bottom: 40, trailing: 40),
                resizingMode: .stretch
            )
            .padding(-24)
            .offset(y: 3)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A bookmark ribbon's end: a strip of cloth with a notch cut into its tip.
struct RibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let notch = min(rect.width * 0.6, rect.height * 0.25)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notch))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A red cloth bookmark ribbon, with a faint sheen along one edge.
struct Ribbon: View {
    var body: some View {
        RibbonShape()
            .fill(Stationery.red)
            .overlay {
                LinearGradient(
                    colors: [.white.opacity(0.18), .clear, .black.opacity(0.18)],
                    startPoint: .leading, endPoint: .trailing
                )
                .clipShape(RibbonShape())
            }
            .accessibilityHidden(true)
    }
}
