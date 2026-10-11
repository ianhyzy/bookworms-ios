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
            let corner = min(4, thickness * 0.08)
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

    /// Shading across the thickness so the flat face reads as a rounded cloth spine.
    private var relief: some View {
        let strength = 0.025 + 0.12 * (1 - look.background.relativeLuminance)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(strength), location: 0),
                .init(color: .clear, location: 0.08),
                .init(color: .white.opacity(strength * 0.55), location: 0.14),
                .init(color: .clear, location: 0.25),
                .init(color: .clear, location: 0.9),
                .init(color: .black.opacity(strength * 0.65), location: 1),
            ], startPoint: .top, endPoint: .bottom)
    }

    /// Accent bands near the head and tail, as on the Apple TV Book Wall.
    private func bands(length: CGFloat, thickness: CGFloat) -> some View {
        let width = max(2, thickness * 0.07)
        let inset = max(6, length * 0.035)
        return HStack(spacing: 0) {
            Rectangle().fill(look.accent.color).frame(width: width)
            Spacer(minLength: 0)
            Rectangle().fill(look.accent.color).frame(width: width)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, thickness * 0.1)
    }

    private func lettering(length: CGFloat, thickness: CGFloat) -> some View {
        let inset = max(14, length * 0.035) + max(2, thickness * 0.07) + thickness * 0.18
        let titleSize = thickness * 0.5
        return HStack(spacing: thickness * 0.3) {
            Text(look.text(book.spineTitle))
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
