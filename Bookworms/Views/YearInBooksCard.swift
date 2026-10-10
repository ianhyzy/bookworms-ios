import SwiftUI

/// A year's reading as one poster, after the Apple TV's Year in Review: totals, each month's
/// books as a stack of spines, highlights, and records.
///
/// Story shows every section. Portrait leaves out the records, and Square also sets the totals
/// in one row. A total, highlight, or record without data is left out rather than estimated.
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

    var body: some View {
        let aspect = input.aspect
        let stats = YearInBooks(
            year: input.year ?? input.books.compactMap(\.finishedYear).max() ?? 0,
            library: input.books)
        // Lifted toward cream, so a year of black spines gets a charcoal backdrop, not a black one.
        let lead = ShareStyle.leadColor(stats.books.map { input.look(for: $0).background })
            .mixed(with: ShareStyle.cream, 0.15)
        ZStack {
            RadialGradient(
                colors: [
                    ShareStyle.backdrop(lead, 0.55).color, ShareStyle.backdrop(lead, 0.88).color,
                ], center: UnitPoint(x: 0.5, y: 0.2), startRadius: 0,
                endRadius: aspect.size.height * 0.9)
            VStack(spacing: 24) {
                Text(String(stats.year) + " in books")
                    .font(ShareStyle.serif(aspect == .square ? 76 : 88, .semibold))
                    .lineLimit(1)
                tiles(stats, lead: lead)
                chart(stats)
                highlights(stats)
                if aspect == .story { records(stats) }
            }
            .foregroundStyle(ShareStyle.cream.color)
            .padding(aspect.insets)
        }
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
        if let month = stats.busiestMonth {
            tiles.append(
                Tile(
                    value: isCompact
                        ? Self.calendar.shortStandaloneMonthSymbols[month - 1]
                        : Self.calendar.standaloneMonthSymbols[month - 1],
                    label: isCompact
                        ? "Busiest month"
                        : "Busiest month · \(Self.count(stats.months[month - 1].count, "book"))"))
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

    /// Up to four of the year's most colorful spine colors, distinct enough to tell apart, most
    /// colorful first. Near-gray colors are left out, so a year of plain spines gets the lead
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

    // MARK: - Books by month

    /// Twelve columns, each a stack of that month's spines with the newest on top, the count
    /// above it, and the month's initial below it.
    private func chart(_ stats: YearInBooks) -> some View {
        let most = CGFloat(max(1, stats.months.map(\.count).max() ?? 0))
        let gap: CGFloat = 12
        // Labels, the shelf, and the spacing between them.
        let overhead = 2 * Self.line + 4 + 3 * 8
        // Thicker slabs would make a sparse year's few books look like bricks.
        let maximumThickness: CGFloat = 28
        let initials = Self.calendar.veryShortStandaloneMonthSymbols
        return GeometryReader { proxy in
            let columnWidth = (proxy.size.width - 11 * gap) / 12
            let thickness = min(maximumThickness, max(2, (proxy.size.height - overhead) / most))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<12, id: \.self) { month in
                    let books = stats.months[month]
                    VStack(spacing: 8) {
                        Text(books.isEmpty ? "" : String(books.count))
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(ShareStyle.gold)
                            .frame(height: Self.line)
                        VStack(spacing: 0) {
                            ForEach(books.reversed(), id: \.id) { book in
                                slab(book, columnWidth: columnWidth, thickness: thickness)
                            }
                        }
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                        Capsule()
                            .fill(ShareStyle.cream.color.opacity(0.3))
                            .frame(height: 4)
                        Text(initials[month])
                            .font(.system(size: 30, weight: .medium))
                            .opacity(0.75)
                            .frame(height: Self.line)
                    }
                    .frame(width: columnWidth)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .frame(maxHeight: overhead + maximumThickness * most)
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

    @ViewBuilder
    private func highlights(_ stats: YearInBooks) -> some View {
        let hasSecondRow = stats.topAuthor != nil || !stats.formats.isEmpty
        if !stats.genres.isEmpty || hasSecondRow {
            VStack(alignment: .leading, spacing: 22) {
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

    /// The longest, shortest, and favorite books, each as a small 3D book.
    @ViewBuilder
    private func records(_ stats: YearInBooks) -> some View {
        let entries = recordEntries(stats)
        if !entries.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                ForEach(entries, id: \.book.id) { entry in record(entry.labels, entry.book) }
            }
        }
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

    private func record(_ labels: [String], _ book: CloudBook) -> some View {
        let look = input.look(for: book)
        return VStack(spacing: 6) {
            Book3DView(
                book: book, look: look, cover: input.covers[book.id], height: 136,
                yaw: 0.45 + (ShareStyle.unit(input.seed, book.id, 9) - 0.5) * 0.12
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 10)
            .frame(height: 160, alignment: .bottom)
            Text(labels.joined(separator: " · "))
                .font(.system(size: 30, weight: .medium))
                .opacity(0.8)
            Text(look.text(book.spineTitle))
                .font(look.font(size: 34))
                .lineLimit(2)
                .minimumScaleFactor(30 / 34)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Longest and shortest show the length; a favorite shows the rating.
            if labels.first != "Favorite", let pages = book.pages {
                Text("\(pages.formatted()) pages")
                    .font(.system(size: 30))
            }
            if labels.last == "Favorite", let rating = book.rating {
                ShareStars(rating: rating, size: 28)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
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
