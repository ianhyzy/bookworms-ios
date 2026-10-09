import SwiftUI
import UIKit

/// A share image layout.
enum ShareTemplate: String, CaseIterable, Identifiable {
    case yearStack, justFinished, topFive, spectrum

    var id: Self { self }

    var title: String {
        switch self {
        case .yearStack: "Year Stack"
        case .justFinished: "Just Finished"
        case .topFive: "Top Five"
        case .spectrum: "Spine Spectrum"
        }
    }

    var systemImage: String {
        switch self {
        case .yearStack: "square.stack.3d.up"
        case .justFinished: "book.closed"
        case .topFive: "trophy"
        case .spectrum: "barcode"
        }
    }

    /// Returns the books the card draws, in the card's order.
    ///
    /// Year Stack and Spine Spectrum draw the books finished in `year`, or in every year when
    /// `year` is `nil`, oldest first. Top Five draws up to five of them, highest rated first,
    /// then most recently finished. Just Finished draws the book with `bookID`, else the most
    /// recently finished book, and ignores `year`.
    func books(from library: [CloudBook], year: Int?, bookID: Int?) -> [CloudBook] {
        if self == .justFinished, let book = library.first(where: { $0.id == bookID }) {
            return [book]
        }
        let finished =
            library.filter { book in
                book.finishedYear != nil
                    && (year == nil || book.finishedYear == year || self == .justFinished)
            }
            .sorted { ($0.finished ?? "", $0.id) < ($1.finished ?? "", $1.id) }
        switch self {
        case .yearStack, .spectrum:
            return finished
        case .topFive:
            return Array(finished.sorted(by: Self.isRankedHigher).prefix(5))
        case .justFinished:
            return finished.last.map { [$0] } ?? []
        }
    }

    /// Orders by rating, unrated last, then by the most recent finish.
    static func isRankedHigher(_ lhs: CloudBook, _ rhs: CloudBook) -> Bool {
        (lhs.rating ?? 0, lhs.finished ?? "", lhs.id) > (
            rhs.rating ?? 0, rhs.finished ?? "", rhs.id
        )
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
    /// The books to draw, from `ShareTemplate.books(from:year:bookID:)`.
    var books: [CloudBook]
    var looks: [Int: SpineLook] = [:]
    /// Downsampled covers. A book without one shows a cover in its spine colors.
    var covers: [Int: UIImage] = [:]
    /// The year the books were finished in, or `nil` for every year.
    var year: Int?
    var showsRatings = true
    /// Varies tilts, offsets, and lengths.
    var seed: UInt64 = 0

    func look(for book: CloudBook) -> SpineLook {
        looks[book.id] ?? SpineLook(book: book, design: nil, face: nil)
    }

    /// The year, or the range of years the books span, such as "2019–2026".
    var period: String {
        if let year { return String(year) }
        let years = books.compactMap(\.finishedYear)
        guard let first = years.min(), let last = years.max() else { return "" }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    /// Draws the card at exactly `aspect.size` pixels.
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
/// the export.
struct ShareCanvas: View {
    let input: ShareInput

    var body: some View {
        Group {
            switch input.template {
            case .yearStack: YearStackCard(input: input)
            case .justFinished: JustFinishedCard(input: input)
            case .topFive: TopFiveCard(input: input)
            case .spectrum: SpectrumCard(input: input)
            }
        }
        .frame(width: input.aspect.size.width, height: input.aspect.size.height)
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

    /// The book's format when it is not print, its finish date, and its length, joined with
    /// middle dots. Missing parts are left out.
    static func details(_ book: CloudBook) -> String {
        let format = book.format?.lowercased()
        var parts: [String] = []
        if format == "listened" { parts.append("Audiobook") }
        if format == "ebook" { parts.append("Ebook") }
        if let date = book.finishedDate {
            // The date is noon UTC; format it in UTC so it shows the recorded day.
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.timeZone = .gmt
            parts.append(date.formatted(style))
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

    var body: some View {
        HStack(spacing: size * 0.12) {
            ForEach(0..<5, id: \.self) { index in
                let fill = rating - Double(index)
                Image(
                    systemName: fill >= 0.75
                        ? "star.fill" : fill >= 0.25 ? "star.leadinghalf.filled" : "star"
                )
                .font(.system(size: size, weight: .semibold))
                // Filled, half, and empty symbols differ in width; a fixed frame keeps the row
                // the same width for every rating.
                .frame(width: size * 1.15, height: size * 1.1)
            }
        }
        .foregroundStyle(ShareStyle.gold)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating.formatted()) out of 5 stars")
    }
}
