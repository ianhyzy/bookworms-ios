import SwiftUI

/// A time frame's reading as one poster, after the Apple TV's Year in Review: totals, the books
/// of each month (or week, or year) as stacks of spines, highlights, and records.
///
/// The chart's columns follow the frame: months for a year, weeks for a month, and years for a
/// lifetime. A total, highlight, or record without data is left out rather than estimated.
///
/// The sections span the safe area from top to bottom. The chart takes the height its tallest
/// stack needs, up to a share of the card; the records' covers grow into what is left, and the
/// gaps between sections share the rest equally. The records appear only where they fit, and
/// Square sets the totals in one row.
struct YearInBooksCard: View {
    let input: ShareInput

    /// A total in the grid: the value and what it counts, with stars for a rating.
    private struct Tile {
        let value: String
        let label: String
        var stars: Double?
    }

    /// The height of a 30-pixel line of text.
    private static let line: CGFloat = 36
    /// The thickest a chart spine gets; thicker slabs make a sparse frame's few books look like
    /// bricks.
    private static let maximumThickness: CGFloat = 28
    /// The chart's labels, shelf, and the spacing between them.
    private static let chartOverhead = 2 * line + 4 + 3 * 8

    var body: some View {
        let aspect = input.aspect
        let stats = YearInBooks(frame: input.frame, library: input.books)
        // Lifted toward cream, so a year of black spines gets a charcoal backdrop, not a black one.
        let lead = ShareStyle.leadColor(stats.books.map { input.look(for: $0).background })
            .mixed(with: ShareStyle.cream, 0.15)
        let entries = aspect == .square ? [] : recordEntries(stats)
        ZStack {
            RadialGradient(
                colors: [
                    ShareStyle.backdrop(lead, 0.55).color, ShareStyle.backdrop(lead, 0.88).color,
                ], center: UnitPoint(x: 0.5, y: 0.2), startRadius: 0,
                endRadius: aspect.size.height * 0.9)
            // With records first, so they show whenever their smallest covers fit.
            ViewThatFits(in: .vertical) {
                if !entries.isEmpty { sections(stats, lead: lead, records: entries) }
                sections(stats, lead: lead, records: [])
            }
            .foregroundStyle(ShareStyle.cream.color)
            .padding(aspect.insets)
        }
    }

    /// The sections top to bottom, separated by equal flexible gaps.
    ///
    /// Priorities hand out the height: the chart first, up to its data's height, then the
    /// records' covers, and the gaps split what remains. Fixed sections keep their natural
    /// height, so nothing is squeezed into truncation.
    private func sections(
        _ stats: YearInBooks, lead: ColorValue, records: [(labels: [String], book: CloudBook)]
    ) -> some View {
        let aspect = input.aspect
        let area = aspect.size.height - aspect.insets.top - aspect.insets.bottom
        let gap: CGFloat = aspect == .square ? 24 : 32
        return VStack(spacing: 0) {
            Text(heading)
                .font(ShareStyle.serif(aspect == .square ? 76 : 88, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: gap)
            tiles(stats, lead: lead)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: gap)
            chart(stats, maximumHeight: area * (aspect == .story ? 0.34 : 0.4))
                .layoutPriority(2)
            if !stats.genres.isEmpty || stats.topAuthor != nil || !stats.formats.isEmpty {
                Spacer(minLength: gap)
                highlights(stats)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !records.isEmpty {
                Spacer(minLength: gap)
                self.records(records)
                    .layoutPriority(1)
            }
        }
    }

    /// "2025 in books", "August 2025 in books", or "My lifetime in books".
    private var heading: String {
        input.frame == .lifetime ? "My lifetime in books" : input.frame.title + " in books"
    }

    // MARK: - Totals

    private func tiles(_ stats: YearInBooks, lead: ColorValue) -> some View {
        let isCompact = input.aspect == .square
        let count = stats.books.count
        var tiles = [Tile(value: count.formatted(), label: count == 1 ? "Book" : "Books")]
        if stats.pages > 0 {
            tiles.append(
                Tile(
                    value: stats.pages.formatted(),
                    label: stats.booksWithPages < count
                        ? "Pages in \(stats.booksWithPages) of \(count) books" : "Pages"))
        }
        if input.showsRatings, let average = stats.averageRating {
            tiles.append(
                Tile(
                    value: average.formatted(.number.precision(.fractionLength(1))),
                    label: isCompact
                        ? "Average rating" : "Average of \(Self.count(stats.ratedBooks, "rating"))",
                    stars: (average * 2).rounded() / 2))
        }
        if let busiest = stats.busiest {
            let (value, unit) = Self.busiest(busiest.span, isCompact: isCompact)
            tiles.append(
                Tile(
                    value: value,
                    label: isCompact
                        ? "Busiest \(unit)"
                        : "Busiest \(unit) · \(Self.count(busiest.books.count, "book"))"))
        }
        let palette = palette(stats.books)
        let tints = palette.isEmpty ? [lead] : palette
        // Two tiles a row, or every tile in one row on a square; a lone last tile spans its row.
        let numbered = Array(tiles.enumerated())
        let perRow = isCompact ? tiles.count : 2
        let rows = stride(from: 0, to: numbered.count, by: perRow)
            .map {
                Array(numbered[$0..<min($0 + perRow, numbered.count)])
            }
        return VStack(spacing: 16) {
            ForEach(rows, id: \.first?.offset) { row in
                HStack(spacing: 16) {
                    ForEach(row, id: \.offset) { index, tile in
                        tileView(tile, tint: tints[index % tints.count], isCompact: isCompact)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The busiest column's name, such as "August", "Aug 8–14", or "2023", and its unit.
    private static func busiest(_ span: YearInBooks.Column.Span, isCompact: Bool) -> (
        value: String, unit: String
    ) {
        switch span {
        case .month(let month):
            let names =
                isCompact ? calendar.shortStandaloneMonthSymbols : calendar.standaloneMonthSymbols
            return (names[month - 1], "month")
        case .days(let days, let month):
            let name = calendar.shortStandaloneMonthSymbols[month - 1]
            return ("\(name) \(days.lowerBound)–\(days.upperBound)", "week")
        case .year(let year):
            return (String(year), "year")
        }
    }

    /// Up to four of the frame's most colorful spine colors, distinct enough to tell apart, most
    /// colorful first. Near-gray colors are left out, so a frame of plain spines gets the lead
    /// color.
    private func palette(_ books: [CloudBook]) -> [ColorValue] {
        let candidates =
            books.flatMap { book in
                let look = input.look(for: book)
                return [look.background, look.accent]
            }
            .map { color in
                let lab = SpineContrast.lab(color)
                return (
                    color: color, lab: lab, chroma: (lab.a * lab.a + lab.b * lab.b).squareRoot()
                )
            }
            .filter { $0.chroma > 0.06 }
            .sorted { ($0.chroma, $0.color.hex) > ($1.chroma, $1.color.hex) }
        var chosen: [(color: ColorValue, lab: SpineContrast.Lab)] = []
        for (color, lab, _) in candidates where chosen.count < 4 {
            let isDistinct = chosen.allSatisfy { other in
                let (dl, da, db) = (lab.l - other.lab.l, lab.a - other.lab.a, lab.b - other.lab.b)
                return dl * dl + da * da + db * db > 0.02
            }
            if isDistinct { chosen.append((color, lab)) }
        }
        return chosen.map(\.color)
    }

    private func tileView(_ tile: Tile, tint: ColorValue, isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if isCompact {
                Text(tile.value)
                    .font(ShareStyle.serif(56, .semibold))
                    .minimumScaleFactor(0.6)
                if let stars = tile.stars { ShareStars(rating: stars, size: 26) }
            } else {
                HStack(spacing: 16) {
                    Text(tile.value)
                        .font(ShareStyle.serif(68, .semibold))
                        .minimumScaleFactor(0.6)
                    if let stars = tile.stars { ShareStars(rating: stars, size: 30) }
                }
            }
            Text(tile.label)
                .font(.system(size: 30, weight: .medium))
                .opacity(0.8)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lineLimit(1)
        .padding(.horizontal, isCompact ? 20 : 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ShareStyle.backdrop(tint, 0.45).color, in: .rect(cornerRadius: 28))
    }

    // MARK: - Chart

    /// One column per month, week, or year: a stack of its spines with the newest on top, the
    /// count above it, and its label below it.
    ///
    /// The chart is as tall as its busiest column needs at `maximumThickness` per book, up to
    /// `maximumHeight`, where the spines thin to fit.
    private func chart(_ stats: YearInBooks, maximumHeight: CGFloat) -> some View {
        let columns = stats.columns
        let most = CGFloat(max(1, columns.map(\.books.count).max() ?? 0))
        let gap: CGFloat = columns.count > 12 ? 6 : 12
        let height = min(maximumHeight, Self.chartOverhead + Self.maximumThickness * most)
        return GeometryReader { proxy in
            let count = CGFloat(max(1, columns.count))
            let columnWidth = (proxy.size.width - (count - 1) * gap) / count
            let thickness = min(
                Self.maximumThickness, max(2, (proxy.size.height - Self.chartOverhead) / most))
            // Narrow columns label every second or third column, always including the latest,
            // and drop the counts, which would run into each other.
            let labelEvery = max(1, Int((52 / (columnWidth + gap)).rounded(.up)))
            let showsCounts = columnWidth >= 44
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    let isLabeled = (columns.count - 1 - index) % labelEvery == 0
                    VStack(spacing: 8) {
                        Text(showsCounts && !column.books.isEmpty ? String(column.books.count) : "")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(ShareStyle.gold)
                            .fixedSize()
                            .frame(height: Self.line)
                        VStack(spacing: 0) {
                            ForEach(column.books.reversed(), id: \.id) { book in
                                slab(book, columnWidth: columnWidth, thickness: thickness)
                            }
                        }
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                        Capsule()
                            .fill(ShareStyle.cream.color.opacity(0.3))
                            .frame(height: 4)
                        Text(isLabeled ? Self.label(column.span) : "")
                            .font(.system(size: 30, weight: .medium))
                            .opacity(0.75)
                            .fixedSize()
                            .frame(height: Self.line)
                    }
                    .frame(width: columnWidth)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .frame(minHeight: min(height, Self.chartOverhead + 60), maxHeight: height)
    }

    /// A column's label: a month's initial, a week's days such as "8–14", or a year as "’19".
    private static func label(_ span: YearInBooks.Column.Span) -> String {
        switch span {
        case .month(let month): calendar.veryShortStandaloneMonthSymbols[month - 1]
        case .days(let days, _): "\(days.lowerBound)–\(days.upperBound)"
        case .year(let year): "’" + String(format: "%02d", year % 100)
        }
    }

    /// One book as a blank spine, its length and offset varied by the seed so a stack looks
    /// hand-placed.
    private func slab(_ book: CloudBook, columnWidth: CGFloat, thickness: CGFloat) -> some View {
        let length = columnWidth * (0.8 + 0.2 * ShareStyle.unit(input.seed, book.id, 7))
        let shift = (ShareStyle.unit(input.seed, book.id, 8) - 0.5) * (columnWidth - length)
        return SpineView(
            book: CloudBook(id: book.id, title: "", author: "", coverURL: nil, detailCoverURL: nil),
            look: input.look(for: book)
        )
        .frame(width: length, height: thickness)
        // A hairline keeps a dark spine visible on a dark backdrop.
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(ShareStyle.cream.color.opacity(0.15), lineWidth: 1)
        }
        .offset(x: shift)
    }

    // MARK: - Highlights and records

    private func highlights(_ stats: YearInBooks) -> some View {
        let hasSecondRow = stats.topAuthor != nil || !stats.formats.isEmpty
        return VStack(alignment: .leading, spacing: 22) {
            if !stats.genres.isEmpty {
                highlight("Top genres") {
                    // As many genres as fit on one line, most common first.
                    ViewThatFits(in: .horizontal) {
                        ForEach((1...min(4, stats.genres.count)).reversed(), id: \.self) {
                            Text(stats.genres.prefix($0).map(\.name).joined(separator: " · "))
                        }
                    }
                }
            }
            if hasSecondRow {
                HStack(alignment: .top, spacing: 40) {
                    if let author = stats.topAuthor {
                        highlight("Most-read author") {
                            Text(
                                SpineView.shortAuthor(author.name) + " · "
                                    + Self.count(author.count, "book"))
                        }
                    }
                    if !stats.formats.isEmpty {
                        highlight("Formats") {
                            HStack(spacing: 28) {
                                ForEach(stats.formats, id: \.name) { format in
                                    HStack(spacing: 10) {
                                        Image(systemName: Self.symbol(format: format.name))
                                        Text(format.count.formatted())
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .lineLimit(1)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A light wash, so the panel shows on any backdrop and cream text keeps its contrast.
        .background(ShareStyle.cream.color.opacity(0.08), in: .rect(cornerRadius: 28))
    }

    private func highlight(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 30, weight: .medium))
                .opacity(0.8)
            value()
                .font(ShareStyle.serif(38, .medium))
                .minimumScaleFactor(30 / 38)
        }
    }

    /// The longest, shortest, and favorite books in aligned columns: covers on one baseline,
    /// then each record's label, title, and length or rating on shared rows.
    private func records(_ entries: [(labels: [String], book: CloudBook)]) -> some View {
        let insets = input.aspect.insets
        let spacing: CGFloat = 24
        let count = CGFloat(entries.count)
        let width =
            (input.aspect.size.width - insets.leading - insets.trailing - (count - 1) * spacing)
            / count
        // The covers take the records' flexible height; a grid below keeps each text row level.
        return VStack(spacing: 8) {
            HStack(spacing: spacing) {
                ForEach(entries, id: \.book.id) { entry in
                    recordCover(entry.book).frame(width: width)
                }
            }
            .frame(minHeight: 130, maxHeight: 340)
            Grid(horizontalSpacing: spacing, verticalSpacing: 8) {
                GridRow {
                    ForEach(entries, id: \.book.id) { entry in
                        Text(entry.labels.joined(separator: " · "))
                            .font(.system(size: 30, weight: .medium))
                            .opacity(0.8)
                            .frame(width: width)
                    }
                }
                GridRow(alignment: .top) {
                    ForEach(entries, id: \.book.id) { entry in
                        Text(entry.book.spineTitle)
                            .font(ShareStyle.serif(34, .semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(30 / 34)
                            .multilineTextAlignment(.center)
                    }
                }
                GridRow {
                    ForEach(entries, id: \.book.id) { entry in
                        // Longest and shortest show the length; a favorite shows the rating.
                        if entry.labels.last == "Favorite", let rating = entry.book.rating {
                            ShareStars(rating: rating, size: 28)
                        } else if let pages = entry.book.pages {
                            Text("\(pages.formatted()) pages")
                                .font(.system(size: 30))
                        }
                    }
                }
            }
        }
        .lineLimit(1)
    }

    /// The records in order. A favorite that is also the longest or shortest book joins that
    /// book's entry, so no book appears twice.
    private func recordEntries(_ stats: YearInBooks) -> [(labels: [String], book: CloudBook)] {
        let favorite = input.showsRatings ? stats.favorite : nil
        var entries: [(labels: [String], book: CloudBook)] = []
        for case (let label, let book?) in [
            ("Longest", stats.longest), ("Shortest", stats.shortest), ("Favorite", favorite),
        ] {
            if let index = entries.firstIndex(where: { $0.book.id == book.id }) {
                entries[index].labels.append(label)
            } else {
                entries.append(([label], book))
            }
        }
        return entries
    }

    /// A record's cover, standing on the row's baseline and as tall as the records' flexible
    /// height allows.
    private func recordCover(_ book: CloudBook) -> some View {
        let cover = input.covers[book.id]
        let ratio = ShareCover.aspect(of: cover, style: input.coverStyle)
        return GeometryReader { proxy in
            ShareCover(
                book: book, look: input.look(for: book), cover: cover, style: input.coverStyle,
                height: min(proxy.size.height * 0.92, proxy.size.width * 0.8 / ratio),
                yaw: 0.45 + (ShareStyle.unit(input.seed, book.id, 9) - 0.5) * 0.12
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 10)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
    }

    // MARK: - Labels

    /// Month names in the reader's language. The finish dates are Gregorian calendar days.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        return calendar
    }()

    private static func count(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The Apple TV's symbol for each format label from `YearInBooks.formats`.
    private static func symbol(format: String) -> String {
        switch format {
        case "Audiobook": "headphones"
        case "Ebook": "ipad"
        default: "book.closed"
        }
    }
}
