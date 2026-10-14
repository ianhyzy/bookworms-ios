import NaturalLanguage
import SwiftUI
import UIKit

/// A share image layout.
enum ShareTemplate: String, CaseIterable, Identifiable {
    case yearStack, yearInBooks, topFive, hotTakes, spectrum, pile, justFinished, review
    case currentlyReading

    var id: Self { self }

    var title: String {
        switch self {
        case .yearStack: "Year Stack"
        case .yearInBooks: "Year in Books"
        case .topFive: "Top Five"
        case .hotTakes: "Hot Takes"
        case .spectrum: "Spine Spectrum"
        case .pile: "Desk"
        case .justFinished: "Just Finished"
        case .review: "Review"
        case .currentlyReading: "Currently Reading"
        }
    }

    var systemImage: String {
        switch self {
        case .yearStack: "square.stack.3d.up"
        case .yearInBooks: "chart.bar.xaxis"
        case .topFive: "trophy"
        case .hotTakes: "flame"
        case .spectrum: "barcode"
        case .pile: "square.stack.3d.down.right"
        case .justFinished: "book.closed"
        case .review: "quote.bubble"
        case .currentlyReading: "bookmark"
        }
    }

    /// Whether the card features one book, which the reader can choose.
    var isSingleBook: Bool { self == .justFinished || self == .review || self == .currentlyReading }

    /// Whether the card draws covers that can be 3D books or flat. Year Stack and Spine Spectrum
    /// draw no covers, and a pile's books are always 3D.
    var hasCoverStyle: Bool { self != .yearStack && self != .spectrum && self != .pile }

    /// Whether the card shows the reader's ratings, which the studio can hide. Hot Takes is
    /// about ratings, so it always shows them.
    var hasRatingOption: Bool {
        self == .yearInBooks || self == .topFive || self == .justFinished || self == .review
    }

    /// Whether the time frame selects the card's books. Currently Reading shows what is being
    /// read now, so it has none.
    var usesTimeFrame: Bool { self != .currentlyReading }

    /// The books a single-book card can feature, newest first: the books finished in `frame`,
    /// only reviewed ones for Review, and for Currently Reading every current read, latest start
    /// first. A review needs no finish date, so Review's lifetime also offers reviewed books that
    /// have none, last.
    func choices(from library: [CloudBook], in frame: TimeFrame) -> [CloudBook] {
        if self == .currentlyReading {
            return library.filter { $0.isReading == true }
                .sorted { ($0.started ?? "") > ($1.started ?? "") }
        }
        let pool = self == .review && frame == .lifetime ? library : library.filter(frame.contains)
        let sorted = pool.sorted { ($0.finished ?? "", $0.id) > ($1.finished ?? "", $1.id) }
        return self == .review ? sorted.filter { $0.reviewText != nil } : sorted
    }

    /// Returns the books the card draws, in the card's order.
    ///
    /// A single-book card draws the book with `bookID` when it is one of its `choices`, else the
    /// first choice. Just Finished also draws a chosen book from outside the frame, so a book
    /// shared from its details always shows. Year Stack, Year in Books, and Spine Spectrum draw
    /// the books finished in `frame`, oldest first. Pile draws them newest first, as the shelf
    /// lists them, so the newest books land on top. Top Five draws up to five of them, highest
    /// rated first, then most recently finished. Hot Takes draws up to three whose rating
    /// differs most from Hardcover's average in `direction`.
    func books(
        from library: [CloudBook], in frame: TimeFrame, bookID: Int? = nil,
        direction: HotTakeDirection = .lovedMore
    ) -> [CloudBook] {
        if isSingleBook {
            let choices = choices(from: library, in: frame)
            let chosen = (self == .justFinished ? library : choices).first { $0.id == bookID }
            return [chosen ?? choices.first].compactMap(\.self)
        }
        let finished = library.filter(frame.contains)
            .sorted { ($0.finished ?? "", $0.id) < ($1.finished ?? "", $1.id) }
        switch self {
        case .pile:
            return finished.reversed()
        case .topFive:
            return Array(finished.sorted(by: Self.isRankedHigher).prefix(5))
        case .hotTakes:
            let sign: Double = direction == .lovedMore ? 1 : -1
            return
                finished
                .compactMap { book in book.ratingGap.map { (book: book, gap: $0 * sign) } }
                .filter { $0.gap >= HotTakeDirection.minimumGap }
                .sorted { ($0.gap, $0.book.finished ?? "") > ($1.gap, $1.book.finished ?? "") }
                .prefix(3).map(\.book)
        default:
            return finished
        }
    }

    /// Orders by rating, unrated last, then by the most recent finish.
    static func isRankedHigher(_ lhs: CloudBook, _ rhs: CloudBook) -> Bool {
        (lhs.rating ?? 0, lhs.finished ?? "", lhs.id) > (
            rhs.rating ?? 0, rhs.finished ?? "", rhs.id
        )
    }
}

/// Which disagreements with Hardcover's readers Hot Takes shows.
enum HotTakeDirection: String, CaseIterable, Identifiable {
    case lovedMore, lovedLess

    /// The smallest gap, in stars, that counts as a hot take.
    static let minimumGap = 0.5
    /// The fewest Hardcover ratings whose average a hot take compares against, so a handful of
    /// votes cannot make a gap.
    static let minimumRatings = 50

    var id: Self { self }

    var title: String {
        switch self {
        case .lovedMore: "Loved more"
        case .lovedLess: "Loved less"
        }
    }
}

/// How a card draws covers.
enum ShareCoverStyle: String, CaseIterable, Identifiable {
    /// A lit 3D book with its spine.
    case threeD
    /// The cover alone, with rounded corners and a soft shadow.
    case flat

    var id: Self { self }

    var title: String {
        switch self {
        case .threeD: "3D"
        case .flat: "Flat"
        }
    }
}

/// An export size, in pixels, matching common social formats.
enum ShareAspect: String, CaseIterable, Identifiable {
    case story, portrait, square

    var id: Self { self }

    var title: String {
        switch self {
        case .story: "Story"
        case .portrait: "Portrait"
        case .square: "Square"
        }
    }

    var size: CGSize {
        switch self {
        case .story: CGSize(width: 1080, height: 1920)
        case .portrait: CGSize(width: 1080, height: 1350)
        case .square: CGSize(width: 1080, height: 1080)
        }
    }

    /// The margins around a card's content. On a story, they keep text out of the area that the
    /// platforms' top and bottom bars cover (y 250 to 1670).
    var insets: EdgeInsets {
        switch self {
        case .story: EdgeInsets(top: 250, leading: 64, bottom: 250, trailing: 64)
        case .portrait: EdgeInsets(top: 88, leading: 64, bottom: 88, trailing: 64)
        case .square: EdgeInsets(top: 64, leading: 64, bottom: 88, trailing: 64)
        }
    }
}

/// Everything a share card draws, resolved before rendering.
///
/// `ImageRenderer` draws synchronously, so covers must already be decoded and spine fonts loaded
/// into `looks`. The card is a pure function of this value: the same input draws the same image.
struct ShareInput {
    var template: ShareTemplate
    var aspect: ShareAspect
    /// The books to draw, from `ShareTemplate.books(from:in:bookID:direction:)`.
    var books: [CloudBook]
    var looks: [Int: SpineLook] = [:]
    /// Downsampled covers. A book without one shows a cover in its spine colors.
    var covers: [Int: UIImage] = [:]
    /// The time frame the books were finished in.
    var frame = TimeFrame.lifetime
    var coverStyle = ShareCoverStyle.threeD
    var direction = HotTakeDirection.lovedMore
    var showsRatings = true
    /// Varies tilts, offsets, and lengths.
    var seed: UInt64 = 0
    /// The page to draw, from 0, when the card spans several images (`pageCount`).
    var page = 0

    func look(for book: CloudBook) -> SpineLook {
        looks[book.id] ?? SpineLook(book: book, design: nil, face: nil)
    }

    /// The card's color family, from the drawn books' spine colors.
    var theme: ShareTheme { ShareTheme(looks: books.map(look(for:))) }

    /// The frame's name, such as "2025" or "August 2025", or for a lifetime the years the books
    /// span, such as "2019–2026".
    var period: String {
        guard frame == .lifetime else { return frame.title }
        let years = books.compactMap(\.finishedYear)
        guard let first = years.min(), let last = years.max() else { return "" }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    /// The number of images the card spans: a Year Stack's pages, else one.
    var pageCount: Int {
        template == .yearStack ? YearStackCard.pages(for: self).pages.count : 1
    }

    /// Draws `page` at exactly `aspect.size` pixels, without the credit, which sharing adds
    /// (`UIImage.withShareCredit()`). Piles need `PileSnapshotRenderer` instead; here they draw
    /// nothing.
    @MainActor
    func render() -> UIImage? {
        let renderer = ImageRenderer(content: ShareCanvas(input: self))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

/// The exported image without its credit: one card at its pixel size, one point per pixel.
///
/// The studio previews the rendered image rather than this view, so the preview matches the
/// export except for the credit, which only exports carry. Card text uses `ShareStyle` type in
/// each book's own capitalization; only spines keep their designed lettering.
struct ShareCanvas: View {
    let input: ShareInput

    var body: some View {
        Group {
            switch input.template {
            case .yearStack: YearStackCard(input: input)
            case .yearInBooks: YearInBooksCard(input: input)
            case .topFive: TopFiveCard(input: input)
            case .hotTakes: HotTakesCard(input: input)
            case .spectrum: SpectrumCard(input: input)
            // `PileSnapshotRenderer` draws piles: `ImageRenderer` cannot capture RealityKit.
            case .pile: EmptyView()
            case .justFinished, .currentlyReading: FeaturedBookCard(input: input)
            case .review: ReviewCard(input: input)
            }
        }
        .frame(width: input.aspect.size.width, height: input.aspect.size.height)
        .clipped()
        // Exports keep one appearance whatever the system setting.
        .environment(\.colorScheme, .dark)
        // Panels are the lightest ground that most card text sits on.
        .environment(\.bookTextGround, input.theme.panel())
    }
}

/// The quiet credit that every exported share image and video carries at its bottom edge, in
/// the bottom margin that every card keeps free of content. Previews in the app leave it out.
struct ShareCredit: View {
    /// The strip at the bottom of an export that the credit and its shadow take, in pixels,
    /// which an in-app preview of a video leaves out.
    nonisolated static let height: CGFloat = 40

    var body: some View {
        Text("Created with Bookworms for iPhone")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(ShareStyle.cream.color.opacity(0.5))
            .shadow(color: .black.opacity(0.35), radius: 3)
            .padding(.bottom, 10)
    }
}

extension UIImage {
    /// This image with `ShareCredit` at its bottom edge, at the same size and scale, or `nil`
    /// when it cannot be drawn. Every share image gets its credit here on its way out of the
    /// app, so a preview of the image alone matches the export everywhere else.
    @MainActor
    func withShareCredit() -> UIImage? {
        let renderer = ImageRenderer(
            content: Image(uiImage: self).overlay(alignment: .bottom) { ShareCredit() })
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

extension CloudBook {
    /// The year of a valid finish date.
    var finishedYear: Int? {
        guard finishedDate != nil, let finished else { return nil }
        return Int(finished.prefix(4))
    }

    /// The review without surrounding whitespace, or `nil` when there is none.
    var reviewText: String? {
        let text = review?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// The reader's rating minus Hardcover's average, for a rated book that at least
    /// `HotTakeDirection.minimumRatings` readers rated.
    var ratingGap: Double? {
        guard let rating, (0.5...5).contains(rating), let communityRating,
            (0.5...5).contains(communityRating),
            (ratingsCount ?? 0) >= HotTakeDirection.minimumRatings
        else { return nil }
        return rating - communityRating
    }
}

/// Colors, type, and repeatable variation that the share cards share.
enum ShareStyle {
    static let cream = ColorValue(red: 250, green: 242, blue: 222)
    static let gold = LinearGradient(
        colors: [
            Color(red: 0.98, green: 0.85, blue: 0.47), Color(red: 0.88, green: 0.64, blue: 0.22),
        ], startPoint: .top, endPoint: .bottom)

    /// Headings and numbers: New York, the system serif.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Returns a repeatable value in `0..<1` for a seed, book, and purpose (SplitMix64).
    static func unit(_ seed: UInt64, _ bookID: Int, _ salt: UInt64) -> Double {
        var z =
            seed &+ UInt64(bitPattern: Int64(bookID)) &* 0x9E37_79B9_7F4A_7C15
            &+ salt &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    /// The forms a share image letters `book`'s title in, longest first. Cards letter the first
    /// form that fits (`ShareFittingText`).
    ///
    /// The first form leaves out a trailing series tag: a parenthetical that holds a "#", ends
    /// in a number, or starts with the series name, such as "(Dungeon Crawler Carl, #4)" or
    /// "(The Expanse 3)". Each later form drops a subtitle, the text after the first ": " or
    /// " — ". When the text before it is the series name, the form drops that prefix instead,
    /// so "Star Wars: Thrawn" in the series "Star Wars" becomes "Thrawn".
    static func titles(_ book: CloudBook) -> [String] {
        let series = book.seriesName?.lowercased()
        var title = book.title.trimmingCharacters(in: .whitespaces)
        if let tag = title.firstMatch(of: /\s*\(([^()]*)\)$/),
            tag.range.lowerBound > title.startIndex
        {
            let inside = tag.1.trimmingCharacters(in: .whitespaces).lowercased()
            if inside.contains("#") || inside.last?.isNumber == true
                || series.map(inside.hasPrefix) == true
            {
                title = String(title[..<tag.range.lowerBound])
            }
        }
        var forms = [title]
        while let form = forms.last,
            let separator = [": ", " — "].compactMap({ form.range(of: $0) })
                .min(by: { $0.lowerBound < $1.lowerBound })
        {
            let head = form[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = form[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty, !rest.isEmpty else { break }
            forms.append(head.lowercased() == series ? rest : head)
        }
        return forms
    }

    /// Small tracked capitals that name what a card shows, such as "FINISHED".
    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 30, weight: .semibold))
            .tracking(5)
    }

    /// Shortens `text` to at most `limit` characters and ends it with an ellipsis: after the
    /// last full sentence when one ends in the final 40 percent, else at a word boundary. Line
    /// breaks fold into spaces, so an excerpt spends no lines on paragraph gaps.
    ///
    /// `NLTokenizer` finds the sentences, so a decimal such as "4.5", an abbreviation such as
    /// "Mr.", or a closing quote does not end one early.
    static func excerpt(_ text: String, limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let folded = words.joined(separator: " ")
        guard folded.count > limit else { return folded }
        // Leaves room for " …".
        var result = ""
        for word in words {
            let next = result.isEmpty ? String(word) : result + " " + word
            if next.count > limit - 2 { break }
            result = next
        }
        if result.isEmpty { return folded.prefix(limit - 1) + "…" }
        // Tokenizes the whole text, since a sentence's end depends on what follows it.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = folded
        let ends = tokenizer.tokens(for: folded.startIndex..<folded.endIndex)
            .map { range in
                folded.distance(from: folded.startIndex, to: range.upperBound)
                    - folded[range].reversed().prefix(while: \.isWhitespace).count
            }
        // `result` is a prefix of `folded`, so a sentence that ends within it ends the excerpt.
        if let end = ends.last(where: { $0 <= result.count }), end >= limit * 6 / 10 {
            return folded.prefix(end) + " …"
        }
        while let last = result.last, last.isPunctuation { result.removeLast() }
        return result + "…"
    }

    /// The book's format when it is not print alone, labeled as the Shelf labels it, its finish
    /// date (or start date, for a current read or a book not yet finished), and its length,
    /// joined with middle dots. Missing parts are left out. An audiobook's length is its
    /// listening time; any other book's is its page count.
    ///
    /// A reread keeps its previous finish date while it is a current read, so `isReading` shows
    /// the start date instead.
    static func details(_ book: CloudBook, isReading: Bool = false) -> String {
        let format = ShelfLabels.format(book.format)
        var parts: [String] = []
        if let format, format != "Physical" { parts.append(format) }
        // Dates are calendar days at noon UTC; the format keeps UTC so they show the recorded day.
        if !isReading, let date = book.finishedDate {
            parts.append(date.formatted(ShelfLabels.finishedFormat))
        } else if let date = book.startedDate {
            parts.append("Started " + date.formatted(ShelfLabels.finishedFormat))
        }
        if let length = ShelfLabels.length(of: book, width: .narrow) { parts.append(length) }
        return parts.joined(separator: " · ")
    }
}

/// One color family for a card's backdrop, glow, and panels, from its books' spine colors.
///
/// Covers and spines keep their own colors, which is where a card's variety comes from. The
/// rest of the card shares the books' dominant hue, so unrelated spine colors never sit side by
/// side as saturated panels. Each color has a fixed OKLCH lightness and a chroma limit, and
/// darkens further when needed to keep cream text at 7:1 contrast or better.
struct ShareTheme: Equatable {
    /// The OKLCH hue in degrees, in `0..<360`.
    let hue: Double
    /// The OKLCH chroma each color takes, up to that color's own limit.
    let chroma: Double

    /// A warm charcoal, for books without a clearly colored spine.
    static let neutral = ShareTheme(hue: 60, chroma: 0.012)

    /// Hue offsets that tell panels apart within the family, 32 degrees from end to end.
    private static let panelOffsets: [Double] = [0, 16, -16, 8]

    /// Dark yellows and yellow-greens, which look muddy at more than 0.035 chroma.
    private static let muddyHues = 85.0...125.0

    init(hue: Double, chroma: Double) {
        self.hue = hue
        self.chroma = chroma
    }

    /// The theme of the spines' background and accent colors.
    init(looks: [SpineLook]) {
        self.init(colors: looks.flatMap { [$0.background, $0.accent] })
    }

    /// The dominant hue of `colors` and the typical chroma near it. The same colors always give
    /// the same theme.
    ///
    /// Each color with an OKLCH chroma of at least 0.03 adds its chroma to one of 24 hue bins,
    /// and each bin also counts half of its neighbors. The theme's hue is the chroma-weighted
    /// circular mean of the colors within 30 degrees of the fullest bin, and its chroma is their
    /// median. Without such colors, the theme is `neutral`. Dark yellows and yellow-greens
    /// (hues 85 to 125) look muddy, so such a theme turns to amber with less chroma. A panel
    /// whose hue offset turns it into that band keeps its hue but takes the lower chroma.
    init(colors: [ColorValue]) {
        let colorful = colors.compactMap { color -> (hue: Double, chroma: Double)? in
            let lab = SpineContrast.lab(color)
            let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            return chroma >= 0.03 ? (Self.degrees(atan2(lab.b, lab.a)), chroma) : nil
        }
        guard !colorful.isEmpty else {
            self = .neutral
            return
        }
        var bins = [Double](repeating: 0, count: 24)
        for color in colorful { bins[Int(color.hue / 15) % 24] += color.chroma }
        let smoothed = bins.indices.map {
            2 * bins[$0] + bins[($0 + 23) % 24] + bins[($0 + 1) % 24]
        }
        // `max(by:)` keeps the first of equal bins. The fullest bin's colors, and those of a
        // neighbor that filled it, lie within 30 degrees of its center, so `near` has colors.
        let fullest = smoothed.indices.max { smoothed[$0] < smoothed[$1] } ?? 0
        let center = (Double(fullest) + 0.5) * 15
        let near = colorful.filter { abs(Self.difference($0.hue, center)) <= 30 }
        let x = near.reduce(0) { $0 + $1.chroma * cos($1.hue * .pi / 180) }
        let y = near.reduce(0) { $0 + $1.chroma * sin($1.hue * .pi / 180) }
        let chromas = near.map(\.chroma).sorted()
        let middle = chromas.count / 2
        let hue = Self.degrees(atan2(y, x))
        let chroma =
            chromas.count.isMultiple(of: 2)
            ? (chromas[middle - 1] + chromas[middle]) / 2 : chromas[middle]
        let isMuddy = Self.muddyHues.contains(hue)
        self.init(hue: isMuddy ? 75 : hue, chroma: isMuddy ? min(chroma, 0.035) : chroma)
    }

    /// The backdrop's lighter end: the top of a linear gradient or the center of a radial one.
    var backdropLight: ColorValue { color(lightness: 0.30, chromaLimit: 0.06) }
    /// The backdrop's darker end, and the field behind long text.
    var backdropDark: ColorValue { color(lightness: 0.15, chromaLimit: 0.035) }
    /// A glow behind featured covers.
    var glow: ColorValue { color(lightness: 0.40, chromaLimit: 0.09) }

    /// A panel behind a total or a row. Panels with different indexes differ only slightly in
    /// hue, so a row of them reads as one family.
    func panel(_ index: Int = 0) -> ColorValue {
        color(
            lightness: 0.34, chromaLimit: 0.075,
            hueOffset: Self.panelOffsets[index % Self.panelOffsets.count])
    }

    /// The signed difference from `other` to `hue`, in degrees, in `-180...180`.
    static func difference(_ hue: Double, _ other: Double) -> Double {
        let difference = (hue - other).truncatingRemainder(dividingBy: 360)
        return difference > 180
            ? difference - 360 : difference < -180 ? difference + 360 : difference
    }

    private static func degrees(_ radians: Double) -> Double {
        let degrees = radians * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The theme's hue, turned by `hueOffset`, at `lightness` with at most `chromaLimit` chroma,
    /// or 0.035 when the turned hue is muddy.
    /// The lightness drops until cream text on the color reaches 7:1.
    private func color(lightness: Double, chromaLimit: Double, hueOffset: Double = 0)
        -> ColorValue
    {
        let turned = (self.hue + hueOffset + 360).truncatingRemainder(dividingBy: 360)
        let chroma = min(
            self.chroma, chromaLimit, Self.muddyHues.contains(turned) ? 0.035 : chromaLimit)
        let hue = turned * .pi / 180
        let (a, b) = (chroma * cos(hue), chroma * sin(hue))
        var lightness = lightness
        var result = SpineContrast.color(SpineContrast.Lab(l: lightness, a: a, b: b))
        while result.contrast(with: ShareStyle.cream) < 7, lightness > 0.05 {
            lightness -= 0.01
            result = SpineContrast.color(SpineContrast.Lab(l: lightness, a: a, b: b))
        }
        return result
    }
}

/// Five stars filled to a rating in half steps, in gold.
struct ShareStars: View {
    let rating: Double
    let size: CGFloat
    /// Draws the stars in quiet cream instead of gold, for someone else's rating.
    var isMuted = false

    /// The symbol for star `index` (0...4), rounding `rating` to the nearest half star as the
    /// Apple TV does.
    static func symbol(rating: Double, index: Int) -> String {
        let fill = rating - Double(index)
        return fill >= 0.75 ? "star.fill" : fill >= 0.25 ? "star.leadinghalf.filled" : "star"
    }

    var body: some View {
        HStack(spacing: size * 0.12) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: Self.symbol(rating: rating, index: index))
                    .font(.system(size: size, weight: .semibold))
                    // Filled, half, and empty symbols differ in width; a fixed frame keeps the row
                    // the same width for every rating.
                    .frame(width: size * 1.15, height: size * 1.1)
            }
        }
        .foregroundStyle(
            isMuted
                ? AnyShapeStyle(ShareStyle.cream.color.opacity(0.6))
                : AnyShapeStyle(ShareStyle.gold)
        )
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating.formatted()) out of 5 stars")
    }
}

/// A book's cover on a card, `height` tall: a lit 3D book, or the flat cover with rounded
/// corners. The caller adds the shadow.
///
/// A book without a downloaded cover gets one in its spine colors, titled in the share serif.
struct ShareCover: View {
    /// The drawn width over the height. A flat cover keeps the image's own ratio, within 0.5...1
    /// so an unusual image cannot upset a layout; a 3D book uses `Book3DView`'s narrower range.
    static func aspect(of cover: UIImage?, style: ShareCoverStyle) -> CGFloat {
        guard style == .flat, let cover, cover.size.height > 0 else {
            return Book3DView.aspect(of: cover)
        }
        return min(1, max(0.5, cover.size.width / cover.size.height))
    }

    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    let style: ShareCoverStyle
    let height: CGFloat
    var yaw = 0.45
    var pitch = -0.12

    var body: some View {
        switch style {
        case .threeD:
            Book3DView(
                book: Self.lettered(book), look: look, cover: cover, height: height, yaw: yaw,
                pitch: pitch)
        case .flat:
            let width = height * Self.aspect(of: cover, style: .flat)
            let shape = RoundedRectangle(cornerRadius: max(4, height * 0.025))
            Group {
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    ZStack {
                        look.background.color
                        ShareFittingText(
                            forms: ShareStyle.titles(book), size: width * 0.13, minimumScale: 0.4,
                            lines: nil, book: book, look: look
                        ) {
                            ShareStyle.serif($0, .semibold)
                        }
                        .multilineTextAlignment(.center)
                        .foregroundStyle(look.foreground.color)
                        .padding(width * 0.12)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(shape)
            // A hairline keeps a dark cover's edge visible on a dark backdrop.
            .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(book.title), by \(book.author)")
        }
    }

    /// `book` with its shortest title form. A 3D book's spine and coverless front have little
    /// room, so they letter it, as the Shelf's spines letter the title without its subtitle.
    private static func lettered(_ book: CloudBook) -> CloudBook {
        var book = book
        book.title = ShareStyle.titles(book).last ?? book.title
        return book
    }
}

/// Letters the first of several text forms that fits, at the largest size that fits.
///
/// `ViewThatFits` tries each form from `size` down to `size * minimumScale`, in steps of about
/// 10 percent, before it tries the next form, so a longer form at a smaller size wins over a
/// shorter one. One line must fit the proposed width. With more `lines`, the wrapped text must
/// fit the height of that many lines at `size`, so a smaller size can wrap to an extra line;
/// with `nil`, it must fit the proposed height. When nothing fits, the last form at the
/// smallest size truncates.
///
/// Forms of a book's own text name `book`, and `look` when lettered on its cloth, so they show
/// House of Leaves' blue "house" (`BookText`).
struct ShareFittingText: View {
    let forms: [String]
    let size: CGFloat
    let minimumScale: CGFloat
    var lines: Int? = 1
    var book: CloudBook?
    var look: SpineLook?
    let font: (CGFloat) -> Font

    var body: some View {
        let smallest = size * minimumScale
        var sizes = [size]
        while let last = sizes.last, last * 0.9 > smallest { sizes.append(last * 0.9) }
        if smallest < size { sizes.append(smallest) }
        let options = forms.flatMap { form in sizes.map { (form: form, size: $0) } }
        let texts = ForEach(options.indices, id: \.self) { index in
            BookText(options[index].form, of: book, on: look).font(font(options[index].size))
        }
        return Group {
            switch lines {
            case 1:
                ViewThatFits(in: .horizontal) { texts }.lineLimit(1)
            case let lines?:
                // A line is about 1.2 times the size; half a line more allows for the leading.
                HeightLimit(height: (CGFloat(lines) + 0.5) * size * 1.2) {
                    ViewThatFits(in: .vertical) { texts }.lineLimit(nil)
                }
            case nil:
                ViewThatFits(in: .vertical) { texts }.lineLimit(nil)
            }
        }
    }
}

/// Proposes at most `height` to its content and takes the content's own size. A frame with a
/// maximum height would instead grow to that height whenever its parent offers more.
private struct HeightLimit: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(limited(proposal)) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, proposal: limited(proposal))
    }

    private func limited(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width, height: min(proposal.height ?? height, height))
    }
}
