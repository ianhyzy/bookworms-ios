import Foundation
import NaturalLanguage
import Synchronization

/// Reading statistics for one calendar year, computed with the Apple TV Year in Review's rules.
///
/// The library keeps each book's most recent read, so a reread counts once, in the year of its
/// latest finish. Books without a valid finish date are left out.
struct YearInBooks: Equatable {
    /// A name and how many books it applies to, such as a genre or format.
    struct Tally: Equatable {
        let name: String
        let count: Int
    }

    let year: Int
    /// Every book finished this year, earliest first.
    let books: [CloudBook]
    /// The books finished in each month, January first, each month earliest first.
    let months: [[CloudBook]]
    /// The page total across books with a recorded page count.
    let pages: Int
    let booksWithPages: Int
    let averageRating: Double?
    let ratedBooks: Int
    /// The month (1–12) with the most finished books; the earliest wins a tie.
    let busiestMonth: Int?
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

    /// Genres counted per book; Hardcover lists a book's most-tagged genres first.
    static let genresPerBook = 3

    /// Computes the statistics for the books in `library` finished in `year`.
    init(year: Int, library: [CloudBook]) {
        self.year = year
        let books = library.filter { $0.finishedYear == year }
            .sorted { ($0.finished ?? "", $0.id) < ($1.finished ?? "", $1.id) }
        self.books = books

        var months = Array(repeating: [CloudBook](), count: 12)
        for book in books {
            // `finishedYear` validated the date, so the month is 1...12.
            if let month = book.finished.flatMap({ Int($0.dropFirst(5).prefix(2)) }) {
                months[month - 1].append(book)
            }
        }
        self.months = months
        let most = months.map(\.count).max() ?? 0
        busiestMonth = most > 0 ? months.firstIndex { $0.count == most }.map { $0 + 1 } : nil

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
