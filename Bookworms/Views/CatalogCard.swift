import CoreText
import SwiftUI

// A book's details as library catalog cards: card stock with a handwritten heading over a red
// rule, printed field names, and entries written by hand on printed rules, with the rod hole
// at the foot. Like the other paper props (`Stationery`), a card is a flat fill, a static dither
// tile, rules that canvases draw when their size changes, and one baked shadow image.

/// The handwriting of a book's catalog cards, measured once for a rule spacing.
///
/// Every line of handwriting takes one band `rule` tall, with its baseline 80 percent of the
/// way down, so writing sits on the printed rule a little below it and descenders cross the
/// rule, as on Checkout Card (`Ruled`). The hand is Caveat (`CheckoutCard.handFamily`), or
/// Noteworthy at three quarters of the size until Caveat loads, since Noteworthy's x-height is
/// a third larger. Values are cached by rule, face, and weight (`make(rule:face:bold:)`), so view
/// bodies never measure fonts.
struct PaperType: Equatable, Sendable {
    /// A size of handwriting, as a share of the rule.
    enum Hand: CaseIterable, Sendable {
        /// A written entry, such as a year or the description: 24 points on 34-point rules.
        case entry
        /// A card's heading.
        case heading
        /// The book's title, the heading of the details' first card.
        case title
        /// The readers' average rating.
        case figure
        /// A note or annotation, the smallest handwriting.
        case note

        var share: CGFloat {
            switch self {
            case .entry: 0.7
            case .heading: 0.82
            case .title: 1
            case .figure: 1.6
            case .note: 0.62
            }
        }
    }

    /// One size of the hand and its line metrics, in points.
    struct Metrics: Equatable, Sendable {
        let font: Font
        let size: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat

        var lineHeight: CGFloat { ascent + descent + leading }
    }

    /// The spacing of the printed rules.
    let rule: CGFloat
    /// The downloaded hand, or `nil` while Noteworthy stands in.
    let face: FontFace?
    /// The face the hand draws in, or `nil` for Georgia Italic when no handwriting is installed.
    private let drawn: FontFace?
    private let sizes: [Hand: Metrics]

    /// `init` measures every hand.
    subscript(hand: Hand) -> Metrics { sizes[hand]! }

    init(rule: CGFloat, face: FontFace?, bold: Bool = false) {
        self.rule = rule
        self.face = face
        let drawn =
            face
            ?? (bold
                ? SpineFonts.installedFace(named: "Noteworthy-Bold") : CheckoutCard.fallbackHand)
        self.drawn = drawn
        let scale: CGFloat = face == nil ? 0.75 : 1
        sizes = Dictionary(
            uniqueKeysWithValues: Hand.allCases.map { hand in
                let size = hand.share * rule * scale
                let font = Self.font(drawn, size: size)
                return (
                    hand,
                    Metrics(
                        font: Font(font), size: size, ascent: CTFontGetAscent(font),
                        descent: CTFontGetDescent(font), leading: CTFontGetLeading(font))
                )
            })
    }

    /// `hand`'s font at `scale` times its size, for measuring a line or writing it smaller.
    func font(_ hand: Hand, scale: CGFloat = 1) -> CTFont {
        Self.font(drawn, size: self[hand].size * scale)
    }

    private static func font(_ drawn: FontFace?, size: CGFloat) -> CTFont {
        drawn.map { CTFontCreateWithFontDescriptor($0.descriptor, size, nil) }
            ?? CTFontCreateWithName("Georgia-Italic" as CFString, size, nil)
    }

    @MainActor private static var cache: [String: PaperType] = [:]

    /// The handwriting for `rule` in `face`, measured on its first use.
    @MainActor static func make(rule: CGFloat, face: FontFace?, bold: Bool) -> PaperType {
        let key = "\(rule) \(face?.postScriptName ?? "fallback") \(bold)"
        if let cached = cache[key] { return cached }
        let type = PaperType(rule: rule, face: face, bold: bold)
        cache[key] = type
        return type
    }

    /// Where a line of `hand` starts below the top of its band, so its baseline lies 80 percent
    /// of the way down.
    func topInset(_ hand: Hand) -> CGFloat { max(0, 0.8 * rule - self[hand].ascent) }

    /// The room below the last line of `hand` that completes its band. It can be negative by a
    /// fraction of a point, when the line's descent reaches past the band.
    func bottomInset(_ hand: Hand) -> CGFloat { rule - topInset(hand) - self[hand].lineHeight }

    /// The space between lines of `hand` that makes each line take one rule.
    func lineSpacing(_ hand: Hand) -> CGFloat { max(0, rule - self[hand].lineHeight) }
}

extension EnvironmentValues {
    /// The details' handwriting while they show catalog cards, or `nil` for glass cards.
    @Entry var paperType: PaperType? = nil
    /// How far a row's rules reach back to the left of its value, under its printed name
    /// (`CatalogRow`).
    @Entry fileprivate var ruleOverhang: CGFloat = 0
}

extension View {
    /// Letters the view's text in `hand`, with lines a rule apart.
    func handFont(_ hand: PaperType.Hand) -> some View { modifier(HandFont(hand: hand)) }

    /// Puts each line of handwriting in `hand` on a printed rule, filling the width offered.
    func ruled(_ hand: PaperType.Hand) -> some View { modifier(Ruled(hand: hand)) }

    /// A row whose value isn't handwriting, such as a font specimen or a stamp: at least one
    /// band tall, with a rule under it.
    func ruledRow() -> some View { modifier(RuledRow()) }
}

/// The handwriting that the details use when no `PaperType` reaches a view, as in a preview.
@MainActor let defaultPaper = PaperType.make(rule: 34, face: nil, bold: false)

private struct HandFont: ViewModifier {
    let hand: PaperType.Hand
    @Environment(\.paperType) private var paper

    func body(content: Content) -> some View {
        let paper = paper ?? defaultPaper
        content.font(paper[hand].font).lineSpacing(paper.lineSpacing(hand))
    }
}

private struct Ruled: ViewModifier {
    let hand: PaperType.Hand
    @Environment(\.paperType) private var paper
    @Environment(\.ruleOverhang) private var overhang

    func body(content: Content) -> some View {
        let paper = paper ?? defaultPaper
        content
            .padding(.top, paper.topInset(hand))
            .padding(.bottom, paper.bottomInset(hand))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { RuleLines(rule: paper.rule).padding(.leading, -overhang) }
    }
}

private struct RuledRow: ViewModifier {
    @Environment(\.paperType) private var paper
    @Environment(\.ruleOverhang) private var overhang

    func body(content: Content) -> some View {
        let rule = (paper ?? defaultPaper).rule
        content
            .padding(.vertical, 0.12 * rule)
            .frame(maxWidth: .infinity, minHeight: rule, alignment: .leading)
            .background(alignment: .bottom) {
                Rectangle().fill(Stationery.rule).frame(height: 0.75)
                    .padding(.bottom, 0.04 * rule)
                    .padding(.leading, -overhang)
                    .accessibilityHidden(true)
            }
    }
}

/// A printed rule under each band of a ruled view, 16 percent of the rule below the band's
/// baseline.
private struct RuleLines: View {
    let rule: CGFloat

    var body: some View {
        Canvas { context, size in
            let bands = max(1, Int((size.height / rule).rounded()))
            for band in 0..<bands {
                let y = (CGFloat(band) + 0.96) * rule
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.75)),
                    with: .color(Stationery.rule))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Handwritten text on the card's rules, in pen ink. With `tilt`, an entry that fits on one line
/// sits a little off level and off its line (`tilted(_:)`); an entry that wraps stays level, so
/// each of its lines sits on its rule.
struct HandText: View {
    /// A one-line entry's slant and lift, which its book and field decide, as handwriting varies:
    /// `ShareStyle.unit(0, book, salt)` and the next salt.
    struct Tilt {
        let book: Int
        let salt: UInt64
    }

    let text: String
    var hand = PaperType.Hand.entry
    var tilt: Tilt?

    init(_ text: String, hand: PaperType.Hand = .entry, tilt: Tilt? = nil) {
        self.text = text
        self.hand = hand
        self.tilt = tilt
    }

    var body: some View {
        let written = Text(Self.roomy(text)).handFont(hand).foregroundStyle(Stationery.penInk)
        Group {
            if let tilt {
                // A tilt turns the entry as one piece, which would lift a second line off its rule.
                ViewThatFits(in: .horizontal) {
                    written.tilted(tilt)
                    written
                }
            } else {
                written
            }
        }
        .ruled(hand)
    }

    /// `text` with `room` points after the last letter of each word. Text draws only within its
    /// bounds, and the hand's slanted ascenders, such as a final "l", lean past them, at the end
    /// of the text and of each wrapped line. The space after a word gives the room back, so
    /// words on a line stay as far apart.
    static func roomy(_ text: String, room: CGFloat = 4) -> AttributedString {
        text.indices.reduce(into: AttributedString()) { roomy, index in
            var character = AttributedString(String(text[index]))
            let next = text.index(after: index)
            if !text[index].isWhitespace, next == text.endIndex || text[next].isWhitespace {
                character.kern = room
            } else if text[index].isWhitespace, index > text.startIndex,
                !text[text.index(before: index)].isWhitespace
            {
                character.kern = -room
            }
            roomy += character
        }
    }
}

extension View {
    /// Slants a one-line entry up to 0.8 degrees and lifts it up to 4 percent of the rule, by
    /// `tilt`'s amounts; without `tilt`, leaves it level.
    @ViewBuilder
    func tilted(_ tilt: HandText.Tilt?) -> some View {
        if let tilt { modifier(Tilted(tilt: tilt)) } else { self }
    }
}

private struct Tilted: ViewModifier {
    let tilt: HandText.Tilt
    @Environment(\.paperType) private var paper

    func body(content: Content) -> some View {
        let rule = (paper ?? defaultPaper).rule
        content
            // Room for a slanted hand's last stroke, which reaches past the text's bounds.
            .padding(.trailing, 0.2 * rule)
            .rotationEffect(
                .degrees((ShareStyle.unit(0, tilt.book, tilt.salt) - 0.5) * 1.6), anchor: .leading
            )
            .offset(y: (ShareStyle.unit(0, tilt.book, tilt.salt + 1) - 0.5) * 0.08 * rule)
    }
}

/// A pen in a person's hand, which draws each line a little off true, as a shape to fill. Each of
/// a line's ends lands up to a point to either side of where it should, so the line runs a few
/// degrees off its course and two lines drawn parallel seldom are. Its middle bows to one side
/// and waves gently, up to `maxWobble` points from the straight line it should follow in all. Up
/// to 28 points, the bow and wave grow with the cube of the line's length, as an arm swings
/// through a long line but a hand flicks a short one, so a long line bends visibly and a short
/// hatch stroke stays nearly straight. Nearly every end misses its mark by a visible amount,
/// running up to `maxOvershoot` points past it, so lines cross at a corner, or, less often,
/// stopping up to `maxShortfall` short of it, so a corner stays open. The line is thinner where
/// the pen lands and lifts than where it presses hardest. `book` and `salt` decide every line the
/// pen draws, in order, so a drawing is the same on every redraw.
struct HandPen {
    /// One point on a line's middle, and the line's width there.
    struct Mark: Equatable {
        let point: CGPoint
        let width: CGFloat
    }

    /// The farthest any part of a line strays to either side of the line it should follow.
    static let maxWobble: CGFloat = 3
    /// The farthest a line's end runs past where it should end, along the line.
    static let maxOvershoot: CGFloat = 3
    /// The farthest a line's end stops short of where it should end, along the line.
    static let maxShortfall: CGFloat = 2
    /// The thinnest a line gets, where the pen barely touches, as a share of its full width.
    static let minPressure: CGFloat = 0.45

    /// Whether every line keeps its full width, without the pen's pressure: a cleaner line for
    /// Increase Contrast and Reduce Transparency. The lines take the same course either way.
    let isEven: Bool
    private var generator: BookAnalyzer.SeededGenerator

    init(book: Int, salt: UInt64, isEven: Bool = false) {
        generator = BookAnalyzer.SeededGenerator(
            seed: UInt64(bitPattern: Int64(book)) &* 0xD1B5_4A32_D192_ED03 &+ salt)
        self.isEven = isEven
    }

    /// A line from `start` to `end`, `width` wide where the pen presses hardest. `slop` scales how
    /// far its ends stray, along the line and to either side, for a quick stroke, such as a hatch
    /// line, that should stay near its marks.
    mutating func line(from start: CGPoint, to end: CGPoint, width: CGFloat, slop: CGFloat = 1)
        -> Path
    {
        let marks = marks(from: start, to: end, width: width, slop: slop)
        guard marks.count > 1 else { return Path() }
        let length = hypot(end.x - start.x, end.y - start.y)
        let across = CGSize(width: (start.y - end.y) / length, height: (end.x - start.x) / length)
        func side(_ mark: Mark, _ sign: CGFloat) -> CGPoint {
            CGPoint(
                x: mark.point.x + sign * across.width * mark.width / 2,
                y: mark.point.y + sign * across.height * mark.width / 2)
        }
        var path = Path()
        path.addLines(marks.map { side($0, 1) } + marks.reversed().map { side($0, -1) })
        path.closeSubpath()
        return path
    }

    /// The middle of a line from `start` to `end`, about every 3 points, with its width at each
    /// point; none for a line shorter than a hundredth of a point. `slop` scales how far the
    /// line's ends stray, as in `line(from:to:width:slop:)`.
    mutating func marks(from start: CGPoint, to end: CGPoint, width: CGFloat, slop: CGFloat = 1)
        -> [Mark]
    {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.01 else { return [] }
        let along = CGSize(width: (end.x - start.x) / length, height: (end.y - start.y) / length)
        let reach = min(1, length / 12) * slop
        let swing = pow(min(1, length / 28), 3)
        let lead = miss() * reach
        let trail = miss() * reach
        // The parts of the wobble sum to at most `maxWobble`. The bow always bends some way, so
        // a long line never comes out ruled straight. Each end strays on its own, which turns
        // the line off its course.
        let startOff = random(-1...1) * reach
        let endOff = random(-1...1) * reach
        let bow = random(0.4...1.4) * (unit() < 0.5 ? -1 : 1) * swing
        let wave = random(0...0.6) * swing
        let cycles = length / random(20...32)
        let phase = random(0...(2 * .pi))
        let landing = random(Self.minPressure...0.85)
        let peak = random(0.85...1)
        let lift = random(Self.minPressure...0.75)
        let crest = random(0.3...0.7)
        let steps = max(4, Int((length / 3).rounded(.up)))
        return (0...steps)
            .map { step in
                let t = CGFloat(step) / CGFloat(steps)
                let distance = -lead + (length + lead + trail) * t
                let offset =
                    startOff * (1 - t) + endOff * t + bow * sin(.pi * t)
                    + wave * sin(2 * .pi * cycles * t + phase)
                let pressure =
                    t < crest
                    ? landing + (peak - landing) * Self.ease(t / crest)
                    : peak + (lift - peak) * Self.ease((t - crest) / (1 - crest))
                return Mark(
                    point: CGPoint(
                        x: start.x + along.width * distance - along.height * offset,
                        y: start.y + along.height * distance + along.width * offset),
                    width: isEven ? width : width * pressure)
            }
    }

    /// The next value in `0...1` from the pen's sequence, for the drawing's own choices, such as
    /// where the next line starts.
    mutating func unit() -> CGFloat { random(0...1) }

    /// How far past its mark a line's end runs, or, when negative, how far short of it the line
    /// stops: past it a little more often than short, and never right on it.
    private mutating func miss() -> CGFloat {
        unit() < 0.55 ? random(0.8...Self.maxOvershoot) : -random(0.6...Self.maxShortfall)
    }

    private mutating func random(_ range: ClosedRange<CGFloat>) -> CGFloat {
        .random(in: range, using: &generator)
    }

    private static func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
}

/// A printed field name beside its value, the name in a fixed column so values line up down
/// the card, its baseline on the value's first, and the value's rules running under it. At
/// accessibility text sizes, the name sits above the value. With `spoken`, VoiceOver reads the
/// row as one element, the name and then `spoken`; without it, the value's controls speak for
/// themselves.
struct CatalogRow<Value: View>: View {
    let label: String
    /// What VoiceOver reads as the row's value, or `nil` to let the value speak for itself.
    var spoken: String?
    @ViewBuilder let value: Value

    init(_ label: String, spoken: String? = nil, @ViewBuilder value: () -> Value) {
        self.label = label
        self.spoken = spoken
        self.value = value()
    }

    @ScaledMetric private var labelColumn: CGFloat = 104
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout =
            stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        let row = layout {
            Text(label)
                .font(.detailsFieldLabel)
                .foregroundStyle(Stationery.labelInk)
                .frame(width: stacked ? nil : labelColumn, alignment: .leading)
                .padding(.top, stacked ? 8 : 0)
                // Without `spoken`, the value's controls name themselves.
                .accessibilityHidden(spoken == nil)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.ruleOverhang, stacked ? 0 : labelColumn + 8)
        }
        if let spoken {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(spoken)
        } else {
            row
        }
    }
}

/// A library catalog card: card stock with `heading` handwritten over a red rule, then its
/// content, and the hole for the drawer's rod punched at its foot. Buttons on it take the ink's
/// tint.
struct CatalogCard<Content: View>: View {
    let heading: String
    /// The book whose title is the heading, written larger and in more lines as it needs, or
    /// `nil` for a card's name.
    let book: CloudBook?
    /// VoiceOver's focus on the heading, for a card that a control elsewhere shows.
    let headingFocus: AccessibilityFocusState<Bool>.Binding?
    @ViewBuilder let content: Content

    init(
        _ heading: String, headingFocus: AccessibilityFocusState<Bool>.Binding? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.heading = heading
        book = nil
        self.headingFocus = headingFocus
        self.content = content()
    }

    /// A card headed with `book`'s title.
    init(title book: CloudBook, @ViewBuilder content: () -> Content) {
        heading = book.title
        self.book = book
        headingFocus = nil
        self.content = content()
    }

    @Environment(\.paperType) private var paper

    var body: some View {
        let paper = paper ?? defaultPaper
        let rule = paper.rule
        CardStockSheet(cornerRadius: 3) {
            VStack(alignment: .leading, spacing: 0) {
                let title = headingLines(paper)
                    .foregroundStyle(Stationery.penInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Stationery.red).frame(height: 1)
                            .accessibilityHidden(true)
                    }
                    .accessibilityAddTraits(.isHeader)
                if let headingFocus { title.accessibilityFocused(headingFocus) } else { title }
                content
            }
            .padding(.horizontal, 16)
            // The band at the foot holds the rod hole.
            .padding(.bottom, rule)
            .overlay(alignment: .bottom) {
                RodHole().padding(.bottom, rule / 2 - RodHole.diameter / 2)
            }
        }
        .tint(Stationery.ink)
    }

    /// The heading in its band, which is 1.25 rules tall, its baseline 0.12 rule above the red
    /// rule, which descenders cross. A book's title fits itself to the card (`WrappedTitle`).
    @ViewBuilder private func headingLines(_ paper: PaperType) -> some View {
        if let book {
            WrappedTitle(book: book)
        } else {
            let metrics = paper[.heading]
            written(heading, of: nil, size: metrics.size)
                .font(metrics.font)
                .padding(.top, max(0, 1.13 * paper.rule - metrics.ascent))
                .padding(.bottom, 0.12 * paper.rule - metrics.descent - metrics.leading)
        }
    }
}

/// `text` handwritten at `size`, with room for Caveat's "f", which reaches 0.2 em past its
/// advance. House of Leaves letters its title's "house" in blue (`BookText`).
@MainActor @ViewBuilder
private func written(_ text: String, of book: CloudBook?, size: CGFloat) -> some View {
    if let book, HouseOfLeaves.isNovel(book) {
        BookText(text, of: book)
    } else {
        Text(HandText.roomy(text, room: 0.2 * size))
    }
}

/// The details' book title above the red rule, broken in lines (`TitleLines`) once its width is
/// known. VoiceOver reads it as one element.
private struct WrappedTitle: View {
    let book: CloudBook
    @Environment(\.paperType) private var paper
    @State private var width: CGFloat?

    var body: some View {
        let paper = paper ?? defaultPaper
        let rule = paper.rule
        let hand = paper[.title]
        let title =
            width.map { TitleLines.make(book.title, width: $0, paper: paper) }
            ?? TitleLines(lines: [book.title])
        let scale = title.scale
        let font = scale == 1 ? hand.font : Font(paper.font(.title, scale: scale))
        // The lines' baselines are 0.96 rule apart at the title's size, the height from Caveat's
        // deepest descender to its tallest capital, so a descender never touches the letter
        // below it; Noteworthy's reach 0.95 rule at its smaller size.
        let pitch = 0.96 * rule * scale
        let firstBaseline = max(1.13 * rule, hand.ascent * scale)
        VStack(alignment: .leading, spacing: pitch - hand.lineHeight * scale) {
            ForEach(title.lines.indices, id: \.self) { line in
                written(title.lines[line], of: book, size: hand.size * scale)
                    .font(font)
                    // Measured widths can differ from the drawn ones by a fraction of a point.
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
        }
        .padding(.top, firstBaseline - hand.ascent * scale)
        .padding(.bottom, 0.12 * rule - (hand.descent + hand.leading) * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.title)
    }
}

/// A book title broken in lines that fit a width, and the share of the hand's size that it is
/// written at.
struct TitleLines: Equatable {
    var lines: [String]
    var scale: CGFloat = 1

    @MainActor private static var cache: [String: TitleLines] = [:]

    /// `title` in `paper`'s title hand broken for `width`, measured with Core Text on its first
    /// use.
    @MainActor
    static func make(_ title: String, width: CGFloat, paper: PaperType) -> TitleLines {
        let font = paper.font(.title)
        let key = "\(title)\n\(width) \(paper.rule) \(CTFontCopyPostScriptName(font))"
        if let cached = cache[key] { return cached }
        // `HandText.roomy` adds its room after a line's last letter.
        let room = 0.2 * paper[.title].size
        let made = make(title, width: width) { line in
            let string = NSAttributedString(
                string: String(line),
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            return CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(string), nil, nil, nil) + room
        }
        // Resizing a Mac window measures the title at every width it passes through.
        if cache.count >= 256 { cache.removeAll() }
        cache[key] = made
        return made
    }

    /// `title` broken for `width`, with `measure` giving a line's width at the hand's full size.
    ///
    /// A title at most a tenth too wide stays on one line, written smaller, down to about 91
    /// percent of its size. A longer one breaks where `Text` would (`breaks(in:)`), with as many
    /// words on each line as fit; a word left alone on the last line is joined by the previous
    /// line's last word when both fit and that line has another word. A word wider than `width`
    /// shrinks the whole title until it fits, down to the size of the other cards' headings
    /// (`smallestWordScale`); a word wider still starts a line and breaks between its letters,
    /// as `Text` breaks it, and the title keeps its size.
    static func make(_ title: String, width: CGFloat, measure: (Substring) -> CGFloat)
        -> TitleLines
    {
        let whole = measure(title[...])
        if whole <= width { return TitleLines(lines: [title]) }
        if whole <= 1.1 * width { return TitleLines(lines: [title], scale: width / whole) }
        let lines = unorphaned(title, width: width, measure: measure)
        let widest = lines.map(measure).max() ?? width
        if smallestWordScale * widest <= width {
            return TitleLines(lines: lines.map(String.init), scale: min(1, width / widest))
        }
        var letterBreaks: [String.Index] = []
        var wideWords: Set<String.Index> = []
        var start = title.startIndex
        for next in breaks(in: title[...]) {
            let word = trimmed(title[start..<next])
            if measure(word) > width {
                wideWords.insert(start)
                letterBreaks += word.indices.dropFirst()
            }
            letterBreaks.append(next)
            start = next
        }
        return TitleLines(
            lines: greedy(
                title, at: letterBreaks, startingLinesAt: wideWords, width: width, measure: measure
            )
            .map(String.init))
    }

    /// The smallest share of its size that a title shrinks to for a word wider than the card:
    /// the size of the other cards' headings.
    static let smallestWordScale = PaperType.Hand.heading.share / PaperType.Hand.title.share

    /// `title` in as many words on each line as fit `width`, with lines starting at `breaks`, and
    /// always at `starts`; a word wider than `width` takes a line of its own.
    private static func greedy(
        _ title: String, at breaks: [String.Index], startingLinesAt starts: Set<String.Index> = [],
        width: CGFloat, measure: (Substring) -> CGFloat
    ) -> [Substring] {
        var lines: [Substring] = []
        var start = title.startIndex
        var end = start
        for next in breaks {
            if end > start, starts.contains(end) || measure(trimmed(title[start..<next])) > width {
                lines.append(trimmed(title[start..<end]))
                start = end
            }
            end = next
        }
        lines.append(trimmed(title[start..<end]))
        return lines
    }

    /// `greedy(_:at:width:measure:)`'s lines, with a word left alone on the last line joined by
    /// the previous line's last word when both fit and that line has another word, as `Text`
    /// breaks a title.
    private static func unorphaned(
        _ title: String, width: CGFloat, measure: (Substring) -> CGFloat
    ) -> [Substring] {
        var lines = greedy(title, at: breaks(in: title[...]), width: width, measure: measure)
        guard lines.count > 1, let last = lines.last, breaks(in: last).count == 1,
            let moved = breaks(in: lines[lines.count - 2]).dropLast().last,
            measure(title[moved..<last.endIndex]) <= width
        else { return lines }
        lines[lines.count - 2] = trimmed(title[lines[lines.count - 2].startIndex..<moved])
        lines[lines.count - 1] = title[moved..<last.endIndex]
        return lines
    }

    /// Where lines of `title` can start, and its end: the Unicode line-break opportunities that
    /// `Text` breaks at, such as after spaces, after a hyphen, dash, or slash inside a word, and
    /// between most Chinese, Japanese, and Korean characters.
    private static func breaks(in title: Substring) -> [String.Index] {
        let location = title.startIndex.utf16Offset(in: title.base)
        let tokenizer = CFStringTokenizerCreate(
            nil, title.base as CFString, CFRange(location: location, length: title.utf16.count),
            kCFStringTokenizerUnitLineBreak, nil)
        var breaks: [String.Index] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let start = CFStringTokenizerGetCurrentTokenRange(tokenizer).location
            if start > location { breaks.append(String.Index(utf16Offset: start, in: title.base)) }
        }
        breaks.append(title.endIndex)
        return breaks
    }

    private static func trimmed(_ line: Substring) -> Substring {
        let end = line.lastIndex { !$0.isWhitespace }.map(line.index(after:))
        return line[..<(end ?? line.startIndex)]
    }
}

/// The hole punched through a catalog card for the drawer's rod, showing the dark wall behind
/// it. It is painted, not cut, so the card needs no mask.
struct RodHole: View {
    static let diameter: CGFloat = 14

    var body: some View {
        Circle()
            .fill(Stationery.rodHole)
            .overlay { Circle().strokeBorder(Stationery.ink.opacity(0.35), lineWidth: 0.75) }
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityHidden(true)
    }
}

/// Four kraft photo corners: right triangles with 12-point legs over a rectangle's corners,
/// pushed 2 points outward, as if they held the rectangle to the card.
struct PhotoCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: -2, dy: -2)
        let leg: CGFloat = 12
        var path = Path()
        for (corner, x, y) in [
            (CGPoint(x: rect.minX, y: rect.minY), leg, leg),
            (CGPoint(x: rect.maxX, y: rect.minY), -leg, leg),
            (CGPoint(x: rect.minX, y: rect.maxY), leg, -leg),
            (CGPoint(x: rect.maxX, y: rect.maxY), -leg, -leg),
        ] {
            path.move(to: corner)
            path.addLine(to: CGPoint(x: corner.x + x, y: corner.y))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + y))
            path.closeSubpath()
        }
        return path
    }
}
