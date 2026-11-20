import Foundation

/// A span of finish dates: one year, one month, the last 12 months, or every finished book.
///
/// Finish dates are calendar days stored as noon UTC (`CloudBook.finishedDate`), so membership
/// and titles use the UTC calendar to keep each book on its recorded day. A reread belongs to
/// every span in which any of its finishes falls (`CloudBook.finishes`).
enum TimeFrame: Hashable, Sendable {
    case year(Int)
    /// A month of a year; `month` is 1...12.
    case month(year: Int, month: Int)
    /// Finishes after `after`, with no end, so a finish dated after today, such as one already
    /// on the next day in UTC, counts too. `pastYear(now:timeZone:)` makes today's.
    case last12Months(after: Date)
    case lifetime

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// The start of a span that reaches back `years` years from the calendar day `now` falls on
    /// in `timeZone`. Finish dates are stored at noon UTC, so the start is too, on today's date
    /// that many years ago, and a book finished that day is just out of the span.
    static func start(yearsBack years: Int, now: Date = .now, timeZone: TimeZone = .current)
        -> Date?
    {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        var noon = local.dateComponents([.year, .month, .day], from: now)
        noon.hour = 12
        return calendar.date(from: noon)
            .flatMap { calendar.date(byAdding: .year, value: -years, to: $0) }
    }

    /// **Last 12 Months** as of `now`, as Library's reads it (`LibraryTime`).
    static func pastYear(now: Date = .now, timeZone: TimeZone = .current) -> TimeFrame {
        .last12Months(after: start(yearsBack: 1, now: now, timeZone: timeZone) ?? .distantPast)
    }

    /// Whether `book` was finished within this span. Unfinished books are never included.
    func contains(_ book: CloudBook) -> Bool { book.asFinished(where: includes) != nil }

    /// The books of `library` finished within this span, most recently finished first, each as
    /// of its newest finish in the span (`CloudBook.asFinished(where:)`).
    func books(in library: [CloudBook]) -> [CloudBook] {
        CloudBook.finished(in: library, where: includes)
    }

    /// The books of `library` on Hardcover's **Did Not Finish** shelf that were dropped within
    /// this span, most recently dropped first. A lifetime also includes books without a drop date.
    func dropped(in library: [CloudBook]) -> [CloudBook] {
        library.filter {
            $0.statusID == HardcoverClient.didNotFinishStatus
                && (self == .lifetime || CloudBook.day($0.dropped).map(includes) == true)
        }
        .sorted { ($0.dropped ?? "", $0.id) > ($1.dropped ?? "", $1.id) }
    }

    /// Whether a finish date falls within this span.
    private func includes(_ date: Date) -> Bool {
        let parts = Self.calendar.dateComponents([.year, .month], from: date)
        switch self {
        case .year(let year): return parts.year == year
        case .month(let year, let month): return parts.year == year && parts.month == month
        case .last12Months(let start): return date > start
        case .lifetime: return true
        }
    }

    /// The name of the last 12 months, whenever they start.
    static let last12MonthsTitle = "Last 12 months"

    /// The span's name, such as "2025", "August 2025", "Last 12 months", or "All time". Every
    /// tab names its time frames with these and `LibraryTime.title`, so Library, Desk, and Share
    /// use one vocabulary.
    var title: String {
        switch self {
        case .year(let year): return String(year)
        case .month(let year, let month):
            guard let date = Self.calendar.date(from: DateComponents(year: year, month: month))
            else { return String(year) }
            return date.formatted(
                Date.FormatStyle(timeZone: .gmt).month(.wide).year())
        case .last12Months: return Self.last12MonthsTitle
        case .lifetime: return "All time"
        }
    }

    /// The calendar year of a year or a month, or `nil` for a span that isn't within one.
    var year: Int? {
        switch self {
        case .year(let year), .month(let year, _): year
        case .last12Months, .lifetime: nil
        }
    }

    /// The span's name among its year's spans, where the year goes without saying: a month's
    /// name alone, such as "August", and otherwise `title`.
    var nameInYear: String {
        guard case .month(let year, let month) = self,
            let date = Self.calendar.date(from: DateComponents(year: year, month: month))
        else { return title }
        return date.formatted(Date.FormatStyle(timeZone: .gmt).month(.wide))
    }

    /// The span's name in title case, such as "All Time", for menu items, as the HIG asks.
    var menuTitle: String { title.capitalized }

    /// The years and months that have finished books, or with `dropped`, dropped books, newest
    /// first.
    static func periods(in books: [CloudBook], dropped: Bool = false)
        -> (years: [Int], months: [TimeFrame])
    {
        var months = Set<TimeFrame>()
        let days = dropped ? books.compactMap(\.dropped) : books.flatMap(\.finishes)
        for date in days.compactMap(CloudBook.day) {
            let parts = calendar.dateComponents([.year, .month], from: date)
            if let year = parts.year, let month = parts.month {
                months.insert(.month(year: year, month: month))
            }
        }
        let sorted = months.sorted { $0.sortKey > $1.sortKey }
        var years: [Int] = []
        for case .month(let year, _) in sorted where years.last != year { years.append(year) }
        return (years, sorted)
    }

    /// The frame's name, such as "2025" or "August 2025", or for a lifetime the years `books`
    /// span, such as "2019–2026": the years they were finished in, or with `dropped`, dropped
    /// in.
    func period(of books: [CloudBook], dropped: Bool = false) -> String {
        guard self == .lifetime else { return title }
        return Self.yearSpan(of: books, dropped: dropped) ?? ""
    }

    /// The years `books` were finished in, or with `dropped`, dropped in, such as "2019–2026",
    /// or `nil` when none has a date. Every finish counts, so a reread's earlier reads widen the
    /// span.
    static func yearSpan(of books: [CloudBook], dropped: Bool = false) -> String? {
        let years = periods(in: books, dropped: dropped).years
        guard let last = years.first, let first = years.last else { return nil }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    private var sortKey: Int {
        switch self {
        case .year(let year): year * 100 + 13
        case .month(let year, let month): year * 100 + month
        case .last12Months, .lifetime: .max
        }
    }
}
