import Foundation

/// A span of finish dates: one year, one month, or every finished book.
///
/// Finish dates are calendar days stored as noon UTC (`CloudBook.finishedDate`), so membership
/// and titles use the UTC calendar to keep each book on its recorded day. A reread belongs to
/// every span in which any of its finishes falls (`CloudBook.finishes`).
enum TimeFrame: Hashable, Sendable {
    case year(Int)
    /// A month of a year; `month` is 1...12.
    case month(year: Int, month: Int)
    case lifetime

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// The current year in the UTC calendar that finish dates use.
    static var thisYear: TimeFrame { .year(calendar.component(.year, from: .now)) }

    /// Whether `book` was finished within this span. Unfinished books are never included.
    func contains(_ book: CloudBook) -> Bool { book.asFinished(where: includes) != nil }

    /// The books of `library` finished within this span, most recently finished first, each as
    /// of its newest finish in the span (`CloudBook.asFinished(where:)`).
    func books(in library: [CloudBook]) -> [CloudBook] {
        CloudBook.finished(in: library, where: includes)
    }

    /// Whether a finish date falls within this span.
    private func includes(_ date: Date) -> Bool {
        let parts = Self.calendar.dateComponents([.year, .month], from: date)
        switch self {
        case .year(let year): return parts.year == year
        case .month(let year, let month): return parts.year == year && parts.month == month
        case .lifetime: return true
        }
    }

    /// The span's name, such as "2025", "August 2025", or "All time". Every tab names its time
    /// frames with these and `LibraryTime.title`, so Library, Desk, and Share use one vocabulary.
    var title: String {
        switch self {
        case .year(let year): return String(year)
        case .month(let year, let month):
            guard let date = Self.calendar.date(from: DateComponents(year: year, month: month))
            else { return String(year) }
            return date.formatted(
                Date.FormatStyle(timeZone: .gmt).month(.wide).year())
        case .lifetime: return "All time"
        }
    }

    /// The years and months that have finished books, newest first.
    static func periods(in books: [CloudBook]) -> (years: [Int], months: [TimeFrame]) {
        var months = Set<TimeFrame>()
        for date in books.flatMap(\.finishes).compactMap(CloudBook.day) {
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

    private var sortKey: Int {
        switch self {
        case .year(let year): year * 100 + 13
        case .month(let year, let month): year * 100 + month
        case .lifetime: .max
        }
    }
}
