import SwiftUI

/// A book spine drawn lying flat: head on the left, title then author reading left to right.
///
/// The parent sets the frame: width is the spine's length and height its thickness. Rotate the
/// view 90 degrees clockwise (`UprightSpineView`) to stand it up the way the Apple TV shelf
/// shows it, reading top to bottom. The view is pure SwiftUI, so `ImageRenderer` can export it.
struct SpineView: View {
    let book: CloudBook
    let look: SpineLook

    var body: some View {
        GeometryReader { proxy in
            let length = proxy.size.width
            let thickness = proxy.size.height
            let corner = Self.cornerRadius(thickness: thickness)
            ZStack {
                // Flat, because `SpineContrast` checks the lettering against this color alone.
                RoundedRectangle(cornerRadius: corner)
                    .fill(look.background.color)
                relief.clipShape(RoundedRectangle(cornerRadius: corner))
                bands(length: length, thickness: thickness)
                lettering(length: length, thickness: thickness)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title), by \(book.author)")
    }

    /// The corner radius of a spine `thickness` tall: nearly square, as a flat cloth spine's
    /// corners are. `Book3DView` starts a book pulled off the shelf from the same radius, so the
    /// hand-off from this spine does not jump.
    nonisolated static func cornerRadius(thickness: CGFloat) -> CGFloat {
        min(1, thickness * 0.025)
    }

    /// Shading across the thickness: the long edges darken where the cloth turns onto the
    /// boards, with no highlight between them, so the face reads as a flat spine.
    private var relief: some View {
        let shade = Self.relief(on: look.background)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(shade), location: 0),
                .init(color: .clear, location: 0.05),
                .init(color: .clear, location: 0.95),
                .init(color: .black.opacity(shade * 0.65), location: 1),
            ], startPoint: .top, endPoint: .bottom)
    }

    /// The relief's black opacity at the top edge on `cloth`. Darker cloth takes more.
    nonisolated static func relief(on cloth: ColorValue) -> Double {
        0.025 + 0.12 * (1 - cloth.relativeLuminance)
    }

    /// The thinnest book, as `BookShape` measures it (decimeters, back to front), whose spine
    /// has blind-stamped bands: 3.2 cm, about 700 pages. A thinner spine draws them too small
    /// to read.
    nonisolated static let stampedThickness: Float = 0.32

    /// Whether `book`'s spine has blind-stamped bands. It depends on the book alone, so a
    /// spine and the 3D book pulled from it agree whatever size each is drawn at.
    nonisolated static func stamps(_ book: CloudBook) -> Bool {
        BookShape(of: book, coverAspect: 2 / 3).size.z >= stampedThickness
    }

    /// Blind-stamped bands near the head and tail of a thick book.
    @ViewBuilder
    private func bands(length: CGFloat, thickness: CGFloat) -> some View {
        if Self.stamps(book) {
            Self.stampedBands(on: look.background, length: length, thickness: thickness)
                .padding(.vertical, thickness * 0.1)
        }
    }

    /// Bands pressed into `cloth` near the head and tail of a spine `length` long, with no
    /// ink: each line is shadowed on its head side, away from the light, and caught by the
    /// light on its tail side. A white highlight barely shows on light cloth, so the shadow
    /// deepens with the cloth's lightness to keep the line readable there.
    static func stampedBands(on cloth: ColorValue, length: CGFloat, thickness: CGFloat)
        -> some View
    {
        let stamp = max(1.2, thickness * 0.03)
        let light = cloth.relativeLuminance
        let band = HStack(spacing: 0) {
            Color.black.opacity(0.22 + 0.22 * light).frame(width: stamp)
            Color.white.opacity(0.15 * (1 - light)).frame(width: stamp)
        }
        .frame(width: max(2, thickness * 0.07))
        return HStack(spacing: 0) {
            band
            Spacer(minLength: 0)
            band
        }
        .padding(.horizontal, max(3, length * 0.0175))
    }

    private func lettering(length: CGFloat, thickness: CGFloat) -> some View {
        let inset = max(14, length * 0.035) + max(2, thickness * 0.07) + thickness * 0.18
        let titleSize = thickness * 0.5
        return HStack(spacing: thickness * 0.3) {
            BookText(look.text(book.spineTitle), of: book, on: look)
                .font(look.font(size: titleSize))
                .lineLimit(thickness >= 64 ? 2 : 1)
                .minimumScaleFactor(0.3)
                .frame(maxWidth: .infinity, alignment: .leading)
            // A fixed share keeps the author visible however long the title is. The size stops
            // growing with thickness at a share of the length, so a thick spine fits the same
            // name a thinner one does.
            Text(Self.shortAuthor(book.author))
                .font(look.font(size: min(length * 0.04, max(7, titleSize * 0.55))))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: length * 0.24, alignment: .trailing)
        }
        .foregroundStyle(look.foreground.color)
        .padding(.horizontal, inset)
        .padding(.vertical, thickness * 0.12)
    }

    /// Shortens a long contributor list to its first name, since a spine has little room.
    static func shortAuthor(_ author: String) -> String {
        let names = author.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.count > 2 || (names.count == 2 && author.count > 32), let first = names.first
        else { return author }
        return first + " et al."
    }
}

/// A spine standing upright, reading top to bottom like the Apple TV shelf.
struct UprightSpineView: View {
    let book: CloudBook
    let look: SpineLook
    let height: CGFloat
    let thickness: CGFloat

    var body: some View {
        SpineView(book: book, look: look)
            .frame(width: height, height: thickness)
            .rotationEffect(.degrees(90))
            .frame(width: thickness, height: height)
    }
}

extension CloudBook {
    /// A spine thickness, relative to the spine length, from the page count: a 320-page book is
    /// about 8 percent of its height.
    var thicknessRatio: CGFloat {
        let pages = CGFloat(min(1400, max(60, self.pages ?? 320)))
        return min(0.2, max(0.05, 0.035 + pages / 1000 * 0.13))
    }
}
