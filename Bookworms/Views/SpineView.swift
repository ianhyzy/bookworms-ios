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

    /// The title at the head end and the author at the tail end, as `SpineLettering` measures
    /// them. Each title line draws at its measured size without wrapping or scaling.
    private func lettering(length: CGFloat, thickness: CGFloat) -> some View {
        let box = thickness * SpineLettering.boxShare
        let lettering = SpineLettering.cached(
            title: look.text(book.spineTitle), author: Self.shortAuthor(book.author),
            length: length, thickness: thickness, look: look)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lettering.titleLines.enumerated()), id: \.offset) { line in
                    BookText(line.element, of: book, on: look)
                        .lineLimit(1)
                        .fixedSize()
                        // Shorter than the line's own height where a two-line title fills
                        // the box; the letters draw past it, unclipped.
                        .frame(height: lettering.titlePitch)
                        .offset(y: lettering.titleShift)
                }
            }
            .font(look.font(size: lettering.titleSize))
            Spacer(minLength: 0)
            Group {
                if lettering.authorFits {
                    Text(lettering.author).fixedSize()
                } else {
                    // Only a surname that fits no form shrinks below the author's minimum.
                    Text(lettering.author).lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: lettering.authorWidth, alignment: .trailing)
                }
            }
            .font(look.font(size: lettering.authorSize))
            // A two-line name's lines center on each other, at the tail end of the spine.
            .multilineTextAlignment(.center)
        }
        .frame(height: box)
        .foregroundStyle(look.foreground.color)
        .padding(.horizontal, SpineLettering.inset(length: length, thickness: thickness))
        .padding(.vertical, (thickness - box) / 2)
    }

    /// Shortens a long contributor list to its first name, since a spine has little room.
    static func shortAuthor(_ author: String) -> String {
        let names = author.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.count > 2 || (names.count == 2 && author.count > 32), let first = names.first
        else { return author }
        return first + " et al."
    }

    /// Words that belong to the surname that follows them, such as "Le" in "Ursula K. Le Guin".
    private nonisolated static let surnameParticles: Set<String> = [
        "al", "bin", "da", "de", "del", "della", "der", "di", "du", "el", "la", "le", "st.",
        "ten", "ter", "van", "von",
    ]
    /// Words that follow a surname, such as "Jr." in "Walter M. Miller Jr.".
    private nonisolated static let nameSuffixes: Set<String> = [
        "jr.", "jr", "sr.", "sr", "ii", "iii", "iv",
    ]

    /// `author` with each name shortened to its surname, such as "Le Guin" for "Ursula K. Le
    /// Guin" or "Gaiman, Pratchett" for "Neil Gaiman, Terry Pratchett", keeping the "et al."
    /// that `shortAuthor(_:)` adds. Returns `nil` when no name has a shorter form.
    nonisolated static func surname(_ author: String) -> String? {
        let (names, others) = names(of: author)
        let surnames = names.map(lastName)
        guard surnames != names else { return nil }
        return surnames.joined(separator: ", ") + others
    }

    /// `author` on two lines: a pair of names one over the other, or one name broken before
    /// its surname, such as "David Foster" over "Wallace". Returns `nil` for anything else.
    nonisolated static func twoLines(_ author: String) -> String? {
        let (names, others) = names(of: author)
        if names.count == 2 { return names[0] + ",\n" + names[1] + others }
        guard let name = names.first, names.count == 1 else { return nil }
        let surname = lastName(name)
        guard name.hasSuffix(surname) else { return nil }
        let given = name.dropLast(surname.count).trimmingCharacters(in: .whitespaces)
        return given.isEmpty ? nil : given + "\n" + surname + others
    }

    /// The names in `author`, and " et al." when `shortAuthor(_:)` ended it with that.
    private nonisolated static func names(of author: String) -> (names: [String], others: String) {
        let others = " et al."
        let hasOthers = author.hasSuffix(others)
        let names = author.dropLast(hasOthers ? others.count : 0).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (names, hasOthers ? others : "")
    }

    /// One name's surname, with the particles before it and any suffix after it, or the whole
    /// name when it is a single word.
    private nonisolated static func lastName(_ name: String) -> String {
        var words = name.split(separator: " ").map(String.init)
        guard words.count > 1 else { return name }
        var surname = [words.removeLast()]
        if nameSuffixes.contains(surname[0].lowercased()), words.count > 1 {
            surname.insert(words.removeLast(), at: 0)
        }
        while words.count > 1, let word = words.last, surnameParticles.contains(word.lowercased()) {
            surname.insert(words.removeLast(), at: 0)
        }
        return surname.joined(separator: " ")
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
