import CoreText
import Foundation

/// A spine's lettering: its title's lines and size and its author's form and size, measured
/// with Core Text for a spine of one length and thickness.
///
/// Every measure is a share of the spine's length or thickness, apart from the author's
/// 7-point floor, so a spine of one shape letters alike at any size: as a 3D book's texture,
/// on the shelf, on the details' card, or in a share image.
///
/// The Apple TV's shelf and Book Wall spines letter by `SpineTextMetrics` in
/// `tvos/Bookworms/Services/SpineTextMetrics.swift`, which shares the margins, the title's and
/// author's widths, the title's line rule (`twoLineGain`, `oneLineFloor`, `twoLineFill`,
/// `lineGap`), and the author's forms with this rule. Keep those the same in both apps. The
/// Apple TV adds its own safeguards: sizes on a half-point grid; a title that the rule would
/// letter below 23 points takes the larger of one line and two filled lines, then a third
/// line; authors letter at 16 points or more, and 4 points smaller than the title where that
/// minimum allows; and a surname that fits no form truncates where this rule shrinks it.
struct SpineLettering: Equatable {
    /// The title on one line, or on two, broken between words.
    var titleLines: [String]
    var titleSize: CGFloat
    /// The height each title line takes: its font's line height, or less where a two-line
    /// title's letters fill the box.
    var titlePitch: CGFloat
    /// How far down each title line draws from the middle of its pitch, so that the letters of
    /// a filled two-line title, not their line boxes, sit centered across the spine.
    var titleShift: CGFloat
    /// The author's name on one line or two, or the surname where the name fits neither way.
    var author: String
    var authorSize: CGFloat
    /// The author's room along the spine.
    var authorWidth: CGFloat
    /// Whether `author` fits `authorWidth` at `authorSize`. A surname that fits no form doesn't,
    /// and the spine scales it down into its room.
    var authorFits: Bool

    /// How many times larger two lines must letter a title to take it off one line.
    static let twoLineGain: CGFloat = 1.25
    /// The share of the spine's length below which a one-line title is too small to prefer, so
    /// the title takes whichever of one line and two is larger.
    static let oneLineFloor: CGFloat = 0.045
    /// The share of the lettering's box that a two-line title's letters fill, where its width
    /// allows.
    static let twoLineFill: CGFloat = 0.85
    /// The gap between a filled title's two lines, as a share of its letters' height.
    static let lineGap: CGFloat = 0.2

    /// The share of the thickness that the lettering's box takes.
    static let boxShare: CGFloat = 0.88

    /// The margin at each end of a spine `length` long and `thickness` thick.
    static func inset(length: CGFloat, thickness: CGFloat) -> CGFloat {
        length * 0.035 + thickness * 0.25
    }

    /// `title` and `author` lettered on a spine `length` long and `thickness` thick, in `font`
    /// at each size.
    static func measure(
        title: String, author: String, length: CGFloat, thickness: CGFloat,
        font: @escaping (CGFloat) -> CTFont
    ) -> SpineLettering {
        Rule(font: font, title: title, author: author, length: length, thickness: thickness)
            .lettering()
    }

    private struct Key: Hashable {
        let title: String
        let author: String
        let length: CGFloat
        let thickness: CGFloat
        let font: String
    }
    @MainActor private static var saved: [Key: SpineLettering] = [:]

    /// `measure(title:author:length:thickness:font:)` in `look`'s font, kept for the next spine
    /// of the same text, font, and size, so a view's body measures a spine once. A book that
    /// flies to its details measures a new size on each frame, so the cache is bounded.
    @MainActor static func cached(
        title: String, author: String, length: CGFloat, thickness: CGFloat, look: SpineLook
    ) -> SpineLettering {
        let key = Key(
            title: title, author: author, length: length, thickness: thickness,
            font: look.fontKey)
        if let lettering = saved[key] { return lettering }
        let lettering = measure(
            title: title, author: author, length: length, thickness: thickness,
            font: look.coreTextFont(size:))
        if saved.count >= 4096 { saved.removeAll(keepingCapacity: true) }
        saved[key] = lettering
        return lettering
    }
}

/// One spine's measurements.
///
/// The title gets the width its one line needs at the box's size first. The author gets the
/// rest: at least 24% of the length, or the width its surname needs at its minimum size if that
/// is wider, at most 40%, and never more than its form needs. The title takes back what the
/// author leaves.
private struct Rule {
    let font: (CGFloat) -> CTFont
    let title: String
    let author: String
    let length: CGFloat
    let thickness: CGFloat
    /// The font at 100 points, which the measures per point of size come from.
    private let face: CTFont
    /// The font's line height per point of size.
    private let lineHeight: CGFloat

    init(
        font: @escaping (CGFloat) -> CTFont, title: String, author: String, length: CGFloat,
        thickness: CGFloat
    ) {
        self.font = font
        self.title = title
        self.author = author
        self.length = length
        self.thickness = thickness
        let face = font(100)
        self.face = face
        lineHeight = (CTFontGetAscent(face) + CTFontGetDescent(face) + CTFontGetLeading(face)) / 100
    }

    private var box: CGFloat { thickness * SpineLettering.boxShare }
    private var width: CGFloat {
        max(0, length - 2 * SpineLettering.inset(length: length, thickness: thickness))
    }
    /// The author's minimum size: a little over a quarter of the thickness and at least 7
    /// points, which keeps a thin spine's name legible on screen, up to 4% of the length.
    private var least: CGFloat { min(length * 0.04, max(7, thickness * 0.275)) }
    /// The author's size beside a title that spares the room: half the thickness, up to 4% of
    /// the length, so a thick spine gives its extra room to the title.
    private var large: CGFloat { max(least, min(length * 0.04, thickness * 0.5)) }

    struct Title {
        var lines: [String]
        var size: CGFloat
        var pitch: CGFloat
        var shift: CGFloat = 0
    }

    struct Author {
        var text: String
        var size: CGFloat
        var width: CGFloat
        var fits: Bool
    }

    func lettering() -> SpineLettering {
        // The author's large forms apply only where the title keeps its lines, loses no size
        // to them, and stays at least 1.4 times their size. The 1% absorbs rounding.
        let spared = row(large: true)
        var chosen = row(large: false)
        if spared.title.lines.count == chosen.title.lines.count,
            spared.title.size >= 0.99 * chosen.title.size, spared.title.size >= 1.4 * large
        {
            chosen = spared
        }
        return SpineLettering(
            titleLines: chosen.title.lines, titleSize: chosen.title.size,
            titlePitch: chosen.title.pitch, titleShift: chosen.title.shift,
            author: chosen.author.text, authorSize: chosen.author.size,
            authorWidth: chosen.author.width, authorFits: chosen.author.fits)
    }

    /// The row with the author's large forms allowed or not.
    private func row(large allowed: Bool) -> (title: Title, author: Author) {
        let free = max(0, width - thickness * 0.3)
        let surname = widest([SpineView.surname(author) ?? author], size: least)
        let share = max(length * 0.24, min(length * 0.4, surname))
        let offered = min(length * 0.4, max(min(share, free), free - widest([title], size: box)))
        let author = authorFit(in: offered, large: allowed)
        return (titleFit(free - min(offered, author.width)), author)
    }

    /// The author's first form that fits `width` and the box: the whole name on one line, then
    /// on two, at the large size where `allowed`, then at the minimum. A spine names its author
    /// in full wherever it can, so the surname comes only after those, at the same sizes.
    /// Failing every form, the surname at the minimum, which doesn't fit.
    private func authorFit(in width: CGFloat, large allowed: Bool) -> Author {
        let name = [author, SpineView.twoLines(author)].compactMap { $0 }
        let surname = [SpineView.surname(author)].compactMap { $0 }
        for forms in [name, surname] {
            for size in allowed ? [large, least] : [least] {
                for form in forms {
                    let lines = form.components(separatedBy: "\n")
                    let needed = widest(lines, size: size)
                    if needed <= width, CGFloat(lines.count) * lineHeight * size <= box {
                        return Author(text: form, size: size, width: needed, fits: true)
                    }
                }
            }
        }
        return Author(
            text: SpineView.surname(author) ?? author, size: least, width: width, fits: false)
    }

    /// The title in `width`: on one line, unless two lines letter it at least
    /// `SpineLettering.twoLineGain` times larger, or larger at all where one line would fall
    /// below `SpineLettering.oneLineFloor` of the length. Lines break between words alone, so a
    /// title without spaces, such as a Chinese one, keeps to one line.
    private func titleFit(_ width: CGFloat) -> Title {
        let oneSize = fitted(min(box, box / lineHeight), [title], in: width)
        let one = Title(lines: [title], size: oneSize, pitch: lineHeight * oneSize)
        guard let lines = twoLines(title.split(separator: " ").map(String.init)) else {
            return one
        }
        let twoSize = fitted(min(box, box / (2 * lineHeight)), lines, in: width)
        let gain = oneSize >= SpineLettering.oneLineFloor * length ? SpineLettering.twoLineGain : 1
        guard twoSize > oneSize * gain else { return one }
        return filled(Title(lines: lines, size: twoSize, pitch: lineHeight * twoSize), in: width)
    }

    /// `title`, on two lines, grown until its letters fill `SpineLettering.twoLineFill` of the
    /// box, or its longer line fills `width`.
    ///
    /// A font's line height leaves room for the tallest and the lowest letters of any text, and
    /// most spine titles are capitals, so two lines sized by line height leave much of the box
    /// empty. The letters' own reach, measured from the title's glyphs, sizes the lines instead.
    private func filled(_ title: Title, in width: CGFloat) -> Title {
        let ink = ink(title.lines)
        let height = ink.top + ink.bottom
        guard height > 0 else { return title }
        let size = fitted(
            SpineLettering.twoLineFill * box / ((2 + SpineLettering.lineGap) * height),
            title.lines, in: width)
        guard size > title.size else { return title }
        // A line's frame centers its line box on its pitch; the shift centers its letters.
        let boxCenter =
            (CTFontGetDescent(face) + CTFontGetLeading(face) - CTFontGetAscent(face)) / 200
        return Title(
            lines: title.lines, size: size, pitch: (1 + SpineLettering.lineGap) * height * size,
            shift: (boxCenter - (ink.bottom - ink.top) / 2) * size)
    }

    /// The break of `words` into two lines whose longer line is shortest.
    private func twoLines(_ words: [String]) -> [String]? {
        guard words.count >= 2 else { return nil }
        return (1..<words.count)
            .map { [words[..<$0].joined(separator: " "), words[$0...].joined(separator: " ")] }
            .min { widest($0, size: box) < widest($1, size: box) }
    }

    /// `size`, or the size below it at which `lines` fit `width` to a hundredth of a point. A
    /// face with optical sizes doesn't scale exactly, so each step measures the lines as drawn
    /// and scales the size by what they overshoot.
    private func fitted(_ size: CGFloat, _ lines: [String], in width: CGFloat) -> CGFloat {
        var size = size
        while size > 1 {
            let drawn = widest(lines, size: size)
            guard drawn > width + 0.01 else { break }
            size *= width / drawn
        }
        return size
    }

    private func line(_ text: String, in font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    }

    private func widest(_ lines: [String], size: CGFloat) -> CGFloat {
        let font = font(max(1, size))
        return lines.map { CTLineGetTypographicBounds(line($0, in: font), nil, nil, nil) }.max()
            ?? 0
    }

    /// How far the letters of `lines` reach above and below the baseline, per point of size.
    private func ink(_ lines: [String]) -> (top: CGFloat, bottom: CGFloat) {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        for text in lines {
            let bounds = CTLineGetBoundsWithOptions(line(text, in: face), .useGlyphPathBounds)
            top = max(top, bounds.maxY)
            bottom = max(bottom, -bounds.minY)
        }
        return (top / 100, bottom / 100)
    }
}
