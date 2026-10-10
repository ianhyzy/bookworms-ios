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
        case .pile: "Pile"
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
        case .square: EdgeInsets(top: 64, leading: 64, bottom: 64, trailing: 64)
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

    func look(for book: CloudBook) -> SpineLook {
        looks[book.id] ?? SpineLook(book: book, design: nil, face: nil)
    }

    /// The frame's name, such as "2025" or "August 2025", or for a lifetime the years the books
    /// span, such as "2019–2026".
    var period: String {
        guard frame == .lifetime else { return frame.title }
        let years = books.compactMap(\.finishedYear)
        guard let first = years.min(), let last = years.max() else { return "" }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    /// Draws the card at exactly `aspect.size` pixels. Piles need `PileSnapshotRenderer`
    /// instead; here they draw only the credit.
    @MainActor
    func render() -> UIImage? {
        let renderer = ImageRenderer(content: ShareCanvas(input: self))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

/// The exported image: one card at its pixel size, one point per pixel.
///
/// The studio previews the rendered image rather than this view, so the preview always matches
/// the export. Card text uses `ShareStyle` type in each book's own capitalization; only spines
/// keep their designed lettering.
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
        // A quiet credit in the bottom margin, which every card keeps free of content.
        .overlay(alignment: .bottom) {
            Text("Created with Bookworms for iPhone")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(ShareStyle.cream.color.opacity(0.45))
                .shadow(color: .black.opacity(0.35), radius: 3)
                .padding(.bottom, 18)
        }
        .clipped()
        // Exports keep one appearance whatever the system setting.
        .environment(\.colorScheme, .dark)
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
    static let night = ColorValue(red: 10, green: 10, blue: 12)
    static let gold = LinearGradient(
        colors: [
            Color(red: 0.98, green: 0.85, blue: 0.47), Color(red: 0.88, green: 0.64, blue: 0.22),
        ], startPoint: .top, endPoint: .bottom)

    /// Headings and numbers: New York, the system serif.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Darkens `color` toward near-black by at least `amount`, and further until cream text on
    /// it reaches 7:1 contrast, so text stays legible on any spine color.
    static func backdrop(_ color: ColorValue, _ amount: Double) -> ColorValue {
        var amount = amount
        var result = color.mixed(with: night, amount)
        while result.contrast(with: cream) < 7, amount < 1 {
            amount = min(1, amount + 0.05)
            result = color.mixed(with: night, amount)
        }
        return result
    }

    /// The most typical color: the one with the most others near it in OKLab.
    ///
    /// The comparison is quadratic, which is fine for a library of a few hundred books.
    static func leadColor(_ colors: [ColorValue]) -> ColorValue {
        let labs = colors.map(SpineContrast.lab)
        var best = (index: 0, neighbors: -1)
        for (index, lab) in labs.enumerated() {
            let neighbors = labs.count(where: { other in
                let (dl, da, db) = (lab.l - other.l, lab.a - other.a, lab.b - other.b)
                return dl * dl + da * da + db * db < 0.01
            })
            if neighbors > best.neighbors { best = (index, neighbors) }
        }
        return colors.isEmpty ? night : colors[best.index]
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

    /// The book's format when it is not print, its finish date (or start date, for a current
    /// read or a book not yet finished), and its length, joined with middle dots. Missing parts
    /// are left out.
    ///
    /// A reread keeps its previous finish date while it is a current read, so `isReading` shows
    /// the start date instead.
    static func details(_ book: CloudBook, isReading: Bool = false) -> String {
        let format = book.format?.lowercased()
        var parts: [String] = []
        if format == "listened" { parts.append("Audiobook") }
        if format == "ebook" { parts.append("Ebook") }
        // Dates are calendar days at noon UTC; the format keeps UTC so they show the recorded day.
        if !isReading, let date = book.finishedDate {
            parts.append(date.formatted(ShelfLabels.finishedFormat))
        } else if let started = book.started, started.count >= 10,
            let date = try? Date(String(started.prefix(10)) + "T12:00:00Z", strategy: .iso8601)
        {
            parts.append("Started " + date.formatted(ShelfLabels.finishedFormat))
        }
        if format == "listened", let seconds = book.audioSeconds, seconds > 0 {
            parts.append(
                Duration.seconds(seconds)
                    .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        } else if let pages = book.pages, pages > 0 {
            parts.append("\(pages.formatted()) pages")
        }
        return parts.joined(separator: " · ")
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
                book: book, look: look, cover: cover, height: height, yaw: yaw, pitch: pitch)
        case .flat:
            let width = height * Self.aspect(of: cover, style: .flat)
            let shape = RoundedRectangle(cornerRadius: max(4, height * 0.025))
            Group {
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    ZStack {
                        look.background.color
                        Text(book.spineTitle)
                            .font(ShareStyle.serif(width * 0.13, .semibold))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.4)
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
}
