import SwiftUI

// Small still scenes for screens without books to show: a short bookcase (the empty Library,
// and the Spines tab's bindery shelf), the empty desk under the lamp, and a blotter with a
// blank card. They are shapes, gradients, and baked images that draw again only when their
// inputs change, so they cost nothing while the screen around them scrolls; the Desk's still
// replaces its live RealityKit scene instead of running it.

/// A short bookcase: `content`'s books standing on its board between its side panels, drawn as
/// Shelf draws its bookcase (`Bookcase`, `BookcaseWood`).
///
/// `content` gets the bookcase, whose `scale` sizes books (`CloudBook.shelfSpineSize(scale:)`),
/// and lays them out from the left end of the board, bottom-aligned, in `length` points.
struct ShortShelf<Content: View>: View {
    let height: CGFloat
    let length: CGFloat
    @ViewBuilder let content: (Bookcase) -> Content

    var body: some View {
        let bookcase = Bookcase(height: height, statusBar: 0)
        let start = Bookcase.side + Bookcase.gap
        ZStack(alignment: .topLeading) {
            BookcaseWood(bookcase: bookcase, start: start, length: length)
            content(bookcase)
                .frame(width: length, height: bookcase.base, alignment: .bottomLeading)
                .offset(x: start)
        }
        .frame(width: length + 2 * start, height: height, alignment: .topLeading)
    }
}

extension Bookcase {
    /// The height of a bookcase whose books are drawn at `scale` points per decimeter: the
    /// inverse of `scale`, without a status bar.
    static func height(scale: CGFloat) -> CGFloat {
        scale * CGFloat(BookShape.longest) + topEdge + 20 + drop + lip + surface * 0.45
    }
}

/// A solid brass bookend standing on a shelf's board, `height` points tall.
struct Bookend: View {
    let height: CGFloat

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
            .fill(
                LinearGradient(
                    colors: [
                        ShelfPalette.gold.mix(with: .white, by: 0.25), ShelfPalette.gold,
                        ShelfPalette.gold.mix(with: .black, by: 0.45),
                    ], startPoint: .leading, endPoint: .trailing)
            )
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.35)).frame(height: 1).padding(.horizontal, 2)
            }
            .frame(width: 9, height: height)
            .background(alignment: .bottom) { ContactShadow(width: 9) }
            .accessibilityHidden(true)
    }
}

/// A book's spine in plain cloth, with no lettering, standing upright.
struct PlainSpine: View {
    let cloth: ColorValue

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(cloth.color)
            .overlay {
                // The cloth turns onto the boards at the spine's long edges.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.3), location: 0),
                        .init(color: .clear, location: 0.1),
                        .init(color: .clear, location: 0.9),
                        .init(color: .black.opacity(0.22), location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
            }
            .accessibilityHidden(true)
    }

    /// The Apple TV's fallback cloths, which undesigned books wear.
    static let cloths = [
        ColorValue(red: 46, green: 74, blue: 71), ColorValue(red: 97, green: 51, blue: 41),
        ColorValue(red: 59, green: 71, blue: 99), ColorValue(red: 117, green: 92, blue: 56),
        ColorValue(red: 77, green: 56, blue: 87),
    ]
}

/// The empty Library: a short bookcase with two brass bookends and, while the first download
/// runs, `filled` of its `capacity` plain-cloth books, which slide in beside the left bookend
/// as pages of the library arrive and appear in place under Reduce Motion.
struct EmptyBookcase: View {
    /// How full the shelf is, from 0 to 1.
    var filled: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let length: CGFloat = 216
    private static let scale: CGFloat = 44

    var body: some View {
        let height = Bookcase.height(scale: Self.scale)
        let books = Self.books(count: Int((filled * Double(Self.capacity)).rounded()))
        ShortShelf(height: height, length: Self.length) { _ in
            HStack(alignment: .bottom, spacing: 0) {
                Bookend(height: Self.scale * 1.2)
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(books, id: \.index) { book in
                        PlainSpine(cloth: book.cloth)
                            .frame(width: book.size.width, height: book.size.height)
                            .background(alignment: .bottom) {
                                ContactShadow(width: book.size.width)
                            }
                            .transition(
                                reduceMotion
                                    ? .identity : .move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.leading, 1)
                Spacer(minLength: 0)
                Bookend(height: Self.scale * 1.2)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: books.count)
        }
        .accessibilityHidden(true)
    }

    /// How many books fill the shelf between the bookends.
    static let capacity = 16

    /// Fictional books of a few heights and thicknesses, the same for each index, in the shelf
    /// proportions (`CloudBook.shelfSpineSize(scale:)`).
    private static func books(count: Int) -> [(index: Int, cloth: ColorValue, size: CGSize)] {
        (0..<min(count, capacity))
            .map { index in
                let book = CloudBook(
                    id: 7_000 + index * 37, title: "", author: "", coverURL: nil,
                    detailCoverURL: nil)
                return (index, PlainSpine.cloths[index % 5], book.shelfSpineSize(scale: scale))
            }
    }
}

/// The empty desk under the lamp: a still baked from the table's wood (`DeskStill`, from
/// `script/room-textures.swift`), whose edges fade into the Desk tab's wall.
struct EmptyDesk: View {
    var body: some View {
        Image(.deskStill)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 360)
            .accessibilityHidden(true)
    }
}

/// A desk blotter seen from above, with a blank card lying on it, for the Share tab without a
/// library. The card lies flat, so it may turn a little in the screen's plane.
struct BlankCardOnBlotter: View {
    var body: some View {
        let leather = ColorValue(red: 0x4A, green: 0x2C, blue: 0x20).color
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(ColorValue(red: 0x2F, green: 0x3B, blue: 0x33).color)
                .overlay {
                    Image(.paperDither).resizable(resizingMode: .tile).opacity(0.08)
                        .clipShape(.rect(cornerRadius: 6))
                }
            // Leather corners, which hold the blotting paper.
            ForEach(0..<4, id: \.self) { corner in
                BlotterCorner()
                    .fill(leather)
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(Double(corner) * 90))
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: [.topLeading, .topTrailing, .bottomTrailing, .bottomLeading][
                            corner])
            }
            CardStockSheet(cornerRadius: 3) { Color.clear }
                .frame(width: 92, height: 124)
                .rotationEffect(.degrees(-4))
        }
        .frame(width: 260, height: 172)
        .background { SoftShadow(cornerRadius: 6, opacity: 0.4) }
        .accessibilityHidden(true)
    }
}

/// A blotter's leather corner, as a triangle in the top-leading corner of its frame.
private struct BlotterCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
