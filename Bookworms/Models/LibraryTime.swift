import Foundation

/// The span of finish dates that Library's **Stack** and **Shelf** show, which **Time** in
/// Library's menu chooses. Desk keeps its own `TimeFrame`.
///
/// **Last 12 Months** and **Last 5 Years** reach back that far from today and have no end: a
/// book counts when it was finished after the same date 12 months or 5 years ago, so a finish
/// dated after today, such as one already on the next day in UTC, counts too. **This Year** is
/// today's calendar year. A book counts by its finish dates (`CloudBook.finishes`), calendar
/// days, so a reread shows in every span in which it was finished, and a read book without a
/// finish date falls in no dated span and shows only under **All Time**.
///
/// The raw value is what `BookwormsLibraryTime` saves: a case name, or "year:2025".
enum LibraryTime: Hashable, Sendable {
    case last12Months
    case thisYear
    case last5Years
    case allTime
    /// One calendar year.
    case year(Int)

    /// The spans that **Time** lists above its **Year** menu, the default first.
    static let spans: [LibraryTime] = [.last12Months, .thisYear, .last5Years, .allTime]

    /// The span's name, in the same vocabulary as `TimeFrame.title`.
    var title: String {
        switch self {
        case .last12Months: TimeFrame.last12MonthsTitle
        case .thisYear: "This year"
        case .last5Years: "Last 5 years"
        case .allTime: TimeFrame.lifetime.title
        case .year(let year): String(year)
        }
    }

    /// The span's name in title case, such as "Last 12 Months", for menu items, as the HIG asks.
    var menuTitle: String { title.capitalized }

    /// The books of `books` that the span holds, where `now` falls on a calendar day in
    /// `timeZone`. **All Time** keeps every book in its order. Other spans list books most
    /// recently finished first, each as of its newest finish in the span
    /// (`CloudBook.asFinished(where:)`).
    func books(
        in books: [CloudBook], now: Date = .now, timeZone: TimeZone = .current
    ) -> [CloudBook] {
        switch self {
        case .allTime: return books
        case .thisYear:
            var local = Calendar(identifier: .gregorian)
            local.timeZone = timeZone
            return TimeFrame.year(local.component(.year, from: now)).books(in: books)
        case .year(let year): return TimeFrame.year(year).books(in: books)
        case .last12Months:
            return TimeFrame.pastYear(now: now, timeZone: timeZone).books(in: books)
        case .last5Years:
            guard let start = TimeFrame.start(yearsBack: 5, now: now, timeZone: timeZone)
            else { return books }
            return CloudBook.finished(in: books) { $0 > start }
        }
    }

    /// The years in which any of `books` was finished, newest first, for the **Year** menu.
    static func years(in books: [CloudBook]) -> [Int] { TimeFrame.periods(in: books).years }
}

extension LibraryTime: RawRepresentable {
    init?(rawValue: String) {
        if let span = Self.spans.first(where: { $0.rawValue == rawValue }) {
            self = span
        } else if rawValue.hasPrefix("year:"), let year = Int(rawValue.dropFirst(5)) {
            self = .year(year)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .last12Months: "last12Months"
        case .thisYear: "thisYear"
        case .last5Years: "last5Years"
        case .allTime: "allTime"
        case .year(let year): "year:\(year)"
        }
    }
}
