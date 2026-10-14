import SwiftUI

/// A book's own text, such as its title, description, review, or spine lettering, with every
/// "house" of House of Leaves in blue.
///
/// Mark Z. Danielewski's novel prints the word "house" in blue. For that book alone
/// (`HouseOfLeaves.isNovel(_:)`), this view letters each "house" in the novel's blue, fitted to
/// the ground behind it (`HouseOfLeaves.lettering(on:ink:highlight:)`). Any other book's text,
/// including a title with "house" in it, is plain text. VoiceOver reads the text unchanged.
///
/// Pass the spine design when the text is lettered on a spine or a coverless front, so the blue
/// reads on that cloth. Otherwise the blue reads on `EnvironmentValues.bookTextGround`.
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
            HouseOfLeavesText(text: text, look: look)
        } else {
            Text(verbatim: text)
        }
    }
}

extension EnvironmentValues {
    /// The lightest color behind `BookText` that is not on a spine, such as a details card or a
    /// share image's panel. With `nil`, the ground is the color scheme's
    /// (`HouseOfLeaves.darkGround` or `HouseOfLeaves.lightGround`).
    @Entry var bookTextGround: ColorValue? = nil
}

/// House of Leaves' text, which alone reads the ground from the environment, so other books'
/// text has no environment dependencies.
private struct HouseOfLeavesText: View {
    let text: String
    let look: SpineLook?

    @Environment(\.bookTextGround) private var ground
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let lettering =
            if let look {
                HouseOfLeaves.lettering(
                    on: look.background, ink: look.foreground,
                    highlight: SpineView.relief(on: look.background).highlight)
            } else {
                HouseOfLeaves.lettering(
                    on: ground
                        ?? (colorScheme == .dark
                            ? HouseOfLeaves.darkGround : HouseOfLeaves.lightGround))
            }
        let words = HouseOfLeaves.text(text, blue: lettering.blue.color)
        if lettering.glows { words.textRenderer(HouseOfLeaves.Glow()) } else { words }
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
    private static let white = ColorValue(red: 255, green: 255, blue: 255)

    /// The lightest ground that dark-scheme text sits on by default: a dark grouped list's
    /// raised cell, as in a sheet. Its luminance is above the walnut wall's lighter end
    /// (`ShelfPalette.wallLight`) and the dark lists' other grounds, so a blue that reads here
    /// reads on all of them.
    static let darkGround = ColorValue(red: 0x2C, green: 0x2C, blue: 0x2E)
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
    static func text(_ text: String, blue: Color) -> Text {
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

    /// How "house" is lettered on `ground` among text in `ink`: the novel's blue, moved as
    /// little as legibility needs, and whether a faint white glow sits behind it.
    ///
    /// The blue keeps #6570AE's hue and moves in OKLab lightness toward `ink`, in steps of 0.01,
    /// until it reaches WCAG 4.5:1 and APCA Lc 60 on `ground`. Without `ink`, it moves toward
    /// black or white, whichever contrasts more with `ground`. So it stays the novel's blue on
    /// white, darkens a little on cream, and lightens on dark grounds.
    ///
    /// The glow lightens the ground beside the strokes. Behind a blue darker than its ground,
    /// that adds contrast, so the word glows, and the blue already passes without the glow.
    /// Behind a blue lighter than its ground, a glow would cost contrast, so the word has none.
    ///
    /// `highlight` is the share of white that lightens the ground over part of the lettering,
    /// such as a spine's relief (`SpineView.relief(on:)`). A blue lighter than its ground must
    /// pass there too. On a ground that no lightness of the blue reaches, such as a mid-blue
    /// cloth, the word takes `ink`.
    static func lettering(on ground: ColorValue, ink: ColorValue? = nil, highlight: Double = 0)
        -> (blue: ColorValue, glows: Bool)
    {
        let ink = ink ?? CoverPalette.readableForeground(for: ground)
        let lightens = SpineContrast.lab(ink).l > SpineContrast.lab(ground).l
        let grounds = lightens ? [ground, ground.mixed(with: white, highlight)] : [ground]
        var lab = SpineContrast.lab(novelBlue)
        while (0...1).contains(lab.l) {
            let color = SpineContrast.color(lab)
            if grounds.allSatisfy({ passes(color, on: $0) }) { return (color, !lightens) }
            lab.l += lightens ? 0.01 : -0.01
        }
        return (ink, !lightens)
    }

    /// Whether `color` reaches WCAG 4.5:1 and APCA Lc 60 as text on `ground`.
    static func passes(_ color: ColorValue, on ground: ColorValue) -> Bool {
        color.contrast(with: ground) >= 4.5
            && abs(SpineContrast.apca(text: color, background: ground)) >= 60
    }

    /// Marks a "house" for `Glow`.
    struct Word: TextAttribute {}

    /// Draws text as usual, over a faint, soft white glow behind each `Word`.
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
