import SwiftUI

/// A book's own text, such as its title, description, review, or spine lettering, with every
/// "house" of House of Leaves in blue.
///
/// Mark Z. Danielewski's novel prints the word "house" in blue. For that book alone
/// (`HouseOfLeaves.isNovel(_:)`), this view letters each "house" in the novel's blue with a faint
/// white glow behind it. Any other book's text, including a title with "house" in it, is plain
/// text. VoiceOver reads the text unchanged.
///
/// Pass the spine design when the text is lettered on a spine or a coverless front, so the blue
/// reads on that cloth. Otherwise the blue follows the color scheme (`HouseOfLeaves.Blue`).
struct BookText: View {
    let text: String
    let book: CloudBook?
    let look: SpineLook?

    init(_ text: String, of book: CloudBook?, on look: SpineLook? = nil) {
        self.text = text
        self.book = book
        self.look = look
    }

    var body: some View {
        if let book, HouseOfLeaves.isNovel(book) {
            let blue =
                look.map {
                    AnyShapeStyle(HouseOfLeaves.blue(on: $0.background, ink: $0.foreground).color)
                } ?? AnyShapeStyle(HouseOfLeaves.Blue())
            HouseOfLeaves.text(text, blue: blue).textRenderer(HouseOfLeaves.Glow())
        } else {
            Text(verbatim: text)
        }
    }
}

/// Recognizes House of Leaves and letters its "house" as the novel does.
enum HouseOfLeaves {
    /// The blue the novel prints "house" in.
    static let novelBlue = ColorValue(red: 0x65, green: 0x70, blue: 0xAE)
    /// The glow's opacity where it is strongest, under the word's strokes.
    static let glowOpacity = 0.35
    /// The glow's radius as a share of the line's height.
    static let glowRadius = 0.15
    /// The share of white that the glow adds to the ground just beside the word's strokes:
    /// about 0.1 in Simulator screenshots of captions, cards, spines, and share images.
    static let glowLift = 0.1

    /// The blue on the app's own grounds in a dark scheme: the walnut wall and its cards, share
    /// images, and dark system lists.
    static let darkBlue = blue(on: darkGround, ink: white)
    /// The blue on the app's own grounds in a light scheme: system lists.
    static let lightBlue = blue(on: lightGround, ink: ColorValue(red: 0, green: 0, blue: 0))
    private static let white = ColorValue(red: 255, green: 255, blue: 255)

    /// A gray at the lightness of the lightest ground that dark-scheme text sits near: a share
    /// card's glow (`ShareTheme.glow`, OKLab lightness 0.40), which fades before the text beside
    /// a cover. The walnut wall, its cards, share backdrops and panels, and dark system grounds
    /// are all darker.
    static let darkGround = SpineContrast.color(SpineContrast.Lab(l: 0.40, a: 0, b: 0))
    /// The darkest ground that light-scheme text sits on: the grouped list background.
    static let lightGround = ColorValue(red: 0xF2, green: 0xF2, blue: 0xF7)

    /// Whether `book` is House of Leaves by Mark Z. Danielewski, in any edition.
    ///
    /// The author must name Danielewski, and the title must be "House of Leaves" in any case,
    /// ignoring a subtitle after a colon or a dash and an edition note in parentheses or
    /// brackets. Editions carry different Hardcover IDs, so the ID plays no part.
    static func isNovel(_ book: CloudBook) -> Bool {
        // The author check fails first for nearly every book, so it comes first.
        guard book.author.range(of: "danielewski", options: .caseInsensitive) != nil else {
            return false
        }
        let title = book.title.prefix { !":—–-([".contains($0) }
        return title.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("house of leaves") == .orderedSame
    }

    /// The ranges of the word "house" in `text`, in any case, with a plural or possessive
    /// ending: "House", "HOUSE", "houses", or "house's". A word that only contains it, such as
    /// "household" or "lighthouse", has none.
    static func houseRanges(in text: String) -> [Range<String.Index>] {
        text.ranges(of: /\bhouse(?:s|['’]s)?\b/.ignoresCase().wordBoundaryKind(.simple))
    }

    /// `text` with each "house" in `blue`, marked for `Glow`.
    static func text(_ text: String, blue: AnyShapeStyle) -> Text {
        var result = Text(verbatim: "")
        var start = text.startIndex
        for range in houseRanges(in: text) {
            let before = Text(verbatim: String(text[start..<range.lowerBound]))
            let word = Text(verbatim: String(text[range])).foregroundStyle(blue)
                .customAttribute(Word())
            result = Text("\(result)\(before)\(word)")
            start = range.upperBound
        }
        return Text("\(result)\(Text(verbatim: String(text[start...])))")
    }

    /// The novel's blue as lettering on `ground` among text in `ink`.
    ///
    /// The blue keeps its hue and moves in OKLab lightness toward `ink`, in steps of 0.01, only
    /// as far as it must to reach WCAG 4.5:1 and APCA Lc 60 on `ground`, both bare and as the
    /// glow lights it beside the strokes (`glowLift`). So it stays the novel's blue on white,
    /// darkens a little on cream, and lightens on dark grounds, where the glow alone cannot
    /// make a mid-tone blue legible. On a ground that no lightness of the blue reaches, such as
    /// a saturated mid-blue cloth, the word takes `ink` and keeps only its glow.
    static func blue(on ground: ColorValue, ink: ColorValue) -> ColorValue {
        let step = SpineContrast.lab(ink).l > SpineContrast.lab(ground).l ? 0.01 : -0.01
        let grounds = [ground, ground.mixed(with: white, glowLift)]
        var lab = SpineContrast.lab(novelBlue)
        while (0...1).contains(lab.l) {
            let color = SpineContrast.color(lab)
            if grounds.allSatisfy({ passes(color, on: $0) }) { return color }
            lab.l += step
        }
        return ink
    }

    /// Whether `color` reaches WCAG 4.5:1 and APCA Lc 60 as text on `ground`.
    static func passes(_ color: ColorValue, on ground: ColorValue) -> Bool {
        color.contrast(with: ground) >= 4.5
            && abs(SpineContrast.apca(text: color, background: ground)) >= 60
    }

    /// `darkBlue` in a dark color scheme and `lightBlue` in a light one.
    struct Blue: ShapeStyle {
        func resolve(in environment: EnvironmentValues) -> Color {
            (environment.colorScheme == .dark ? darkBlue : lightBlue).color
        }
    }

    /// Marks a "house" for `Glow`.
    struct Word: TextAttribute {}

    /// Draws text as usual, over a faint, soft white glow behind each `Word`, which sets the
    /// blue off dark grounds and vanishes on light ones.
    ///
    /// The glows all draw first, so none lies over a neighboring letter. The renderer keeps the
    /// default `displayPadding` of zero: a padding widens the width that text wraps to.
    struct Glow: TextRenderer {
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            for line in layout {
                for run in line where run[Word.self] != nil {
                    let bounds = run.typographicBounds
                    var glow = context
                    glow.addFilter(
                        .shadow(
                            color: .white.opacity(glowOpacity),
                            radius: (bounds.ascent + bounds.descent) * glowRadius,
                            options: .shadowOnly))
                    glow.draw(run)
                }
            }
            for line in layout { context.draw(line) }
        }
    }
}
