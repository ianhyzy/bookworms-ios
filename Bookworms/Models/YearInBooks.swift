import Foundation
import NaturalLanguage
import Synchronization

/// Reading statistics for a time frame, computed with the Apple TV Year in Review's rules.
///
/// A reread counts once in each frame it was finished in, by its newest finish there
/// (`TimeFrame.books(in:)`), so its column and order follow that read. Books without a valid
/// finish date are left out.
struct YearInBooks: Equatable {
    /// A name and how many books it applies to, such as a genre or format.
    struct Tally: Equatable {
        let name: String
        let count: Int
    }

    /// A chart column: a month of a year, a run of days in a month, or a year of a lifetime.
    struct Column: Equatable {
        enum Span: Equatable {
            /// A month, 1...12.
            case month(Int)
            /// Days of `month` (1...12), such as 8...14.
            case days(ClosedRange<Int>, month: Int)
            case year(Int)
        }

        let span: Span
        /// The column's books, earliest first.
        let books: [CloudBook]
    }

    let frame: TimeFrame
    /// Every book finished in the frame, earliest first.
    let books: [CloudBook]
    /// The chart's columns, earliest first: the twelve months of a year, a month's weeks (days
    /// 1–7, 8–14, and so on, the last one shorter), or every year from the first finish to the
    /// last. Past `maximumYearSpan` years, as a mistyped date can make it, a lifetime charts only
    /// the years with books.
    let columns: [Column]
    /// The column with the most books, when it has at least two; the earliest wins a tie.
    let busiest: Column?
    /// The page total across books with a recorded page count.
    let pages: Int
    let booksWithPages: Int
    let averageRating: Double?
    let ratedBooks: Int
    /// Reading formats, most common first. A book read in print and on audio counts toward both.
    let formats: [Tally]
    /// Up to five genres, most common first.
    let genres: [Tally]
    /// The author with the most finished books, when at least two share an author.
    let topAuthor: Tally?
    /// The book with the most pages; the latest finish wins a tie.
    let longest: CloudBook?
    /// The book with the fewest pages, when another book has more.
    let shortest: CloudBook?
    /// The highest-rated book; the latest finish wins a tie.
    let favorite: CloudBook?

    /// The most years a lifetime chart spans with empty years included.
    static let maximumYearSpan = 50

    /// Genres counted per book; Hardcover lists a book's most-tagged genres first.
    static let genresPerBook = 3

    /// Computes the statistics for the books in `library` finished in `frame`.
    init(frame: TimeFrame, library: [CloudBook]) {
        self.frame = frame
        let books = frame.books(in: library)
            .sorted { ($0.finished ?? "", $0.id) < ($1.finished ?? "", $1.id) }
        self.books = books

        columns = Self.columns(for: frame, books: books)
        let most = columns.map(\.books.count).max() ?? 0
        busiest = most >= 2 ? columns.first { $0.books.count == most } : nil

        // `books` is earliest first, so the last of equal page counts is the latest finish.
        let withPages = books.filter { ($0.pages ?? 0) > 0 }
        let paged = withPages.compactMap(\.pages)
        let maximumPages = paged.max()
        let minimumPages = paged.min()
        longest = withPages.last { $0.pages == maximumPages }
        shortest =
            minimumPages == maximumPages ? nil : withPages.last { $0.pages == minimumPages }
        pages = paged.reduce(0, +)
        booksWithPages = paged.count

        let ratings = books.compactMap(\.rating).filter { (0...5).contains($0) }
        ratedBooks = ratings.count
        averageRating = ratings.isEmpty ? nil : ratings.reduce(0, +) / Double(ratings.count)
        favorite =
            books.filter { ($0.rating ?? 0) > 0 && ($0.rating ?? 0) <= 5 }
            .sorted(by: ShareTemplate.isRankedHigher).first

        formats = Self.tally(
            books.flatMap { book -> [String] in
                guard let label = ShelfLabels.format(book.format) else { return [] }
                return label == "Physical & audiobook" ? ["Physical", "Audiobook"] : [label]
            })
        genres = Array(
            Self.tally(
                books.flatMap {
                    ($0.genres ?? []).lazy.filter(Self.isEnglishTag).prefix(Self.genresPerBook)
                        .map(Self.displayGenre)
                }
            )
            .prefix(5))
        topAuthor = Self.tally(books.map(\.author).filter { !$0.isEmpty }).first { $0.count >= 2 }
    }

    /// The record books (longest, shortest, favorite) that exist, without repeats.
    var records: [CloudBook] {
        var seen = Set<Int>()
        return [longest, shortest, favorite].compactMap(\.self)
            .filter { seen.insert($0.id).inserted }
    }

    /// Sorts `books`, already in `frame` and earliest first, into the frame's chart columns.
    static func columns(for frame: TimeFrame, books: [CloudBook]) -> [Column] {
        // `finishedDate` validated each `finished` as `yyyy-MM-dd`, so these parse.
        func part(_ book: CloudBook, _ offset: Int, _ length: Int) -> Int {
            Int(book.finished?.dropFirst(offset).prefix(length) ?? "") ?? 0
        }
        switch frame {
        case .year:
            return (1...12)
                .map { month in
                    Column(span: .month(month), books: books.filter { part($0, 5, 2) == month })
                }
        case .month(let year, let month):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let days =
                calendar.date(from: DateComponents(year: year, month: month, day: 15))
                .flatMap { calendar.range(of: .day, in: .month, for: $0)?.count } ?? 31
            return stride(from: 1, through: days, by: 7)
                .map { first in
                    let range = first...min(first + 6, days)
                    return Column(
                        span: .days(range, month: month),
                        books: books.filter { range.contains(part($0, 8, 2)) })
                }
        case .lifetime:
            let years = Set(books.map { part($0, 0, 4) })
            guard let first = years.min(), let last = years.max() else { return [] }
            return (last - first < maximumYearSpan ? Array(first...last) : years.sorted())
                .map { year in
                    Column(span: .year(year), books: books.filter { part($0, 0, 4) == year })
                }
        }
    }

    /// Counts each distinct name, most common first, then alphabetically.
    private static func tally(_ names: [String]) -> [Tally] {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return counts.map { Tally(name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    /// Capitalizes tags that readers entered in lowercase, such as "litrpg", and keeps any other
    /// capitalization, such as "LGBTQ" or "LitRPG".
    static func displayGenre(_ tag: String) -> String {
        tag == tag.lowercased() ? tag.capitalized : tag
    }

    /// Reports whether a community tag reads as English. Readers tag in their own languages, so
    /// Hardcover can return tags such as "Féminisme" beside "Feminism". A strong English prior
    /// keeps short or ambiguous English tags; only clearly foreign tags fall below the threshold.
    static func isEnglishTag(_ tag: String) -> Bool {
        if let known = englishTags.withLock({ $0[tag] }) { return known }
        let recognizer = NLLanguageRecognizer()
        let languages: [NLLanguage] = [
            .english, .french, .spanish, .german, .italian, .portuguese, .dutch, .swedish, .polish,
        ]
        recognizer.languageConstraints = languages
        recognizer.languageHints = Dictionary(
            uniqueKeysWithValues: languages.map { ($0, $0 == .english ? 0.9 : 0.1 / 8) })
        recognizer.processString(tag)
        let isEnglish = recognizer.languageHypotheses(withMaximum: 1)[.english, default: 0] >= 0.7
        englishTags.withLock { $0[tag] = isEnglish }
        return isEnglish
    }

    /// Results by tag, since every render of the card checks the same tags again.
    /// ponytail: unbounded, but limited by the library's distinct tags.
    private static let englishTags = Mutex<[String: Bool]>([:])
}
