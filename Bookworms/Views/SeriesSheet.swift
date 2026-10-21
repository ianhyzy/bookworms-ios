import SwiftUI

/// **Series**, from a book's **Series** card: every series the book belongs to, each opening its
/// books in reading order (`SeriesBooks`). A book in one series opens straight to its books.
///
/// A check button beside each series marks the series the book's label names
/// (`SeriesDesigns.shownSeries(of:link:)`) and picks another one. A pick saves the book's
/// `SeriesLinkV1` (`SeriesRows.save(_:replacing:for:model:undoManager:)`), so every device names
/// it, and the book's spine joins that series' look as the **Series** menu under **Style** sets
/// it. Picking the book's shortest series restores the default. A pick shows at once and stays
/// while it saves; the buttons take no other pick until the save ends.
struct SeriesSheet: View {
    /// The book as its details showed it. The sheet shows the library's current copy, so a saved
    /// pick appears at once.
    let opened: CloudBook
    let undoManager: UndoManager?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The series being saved, shown until the library has it.
    @State private var saving: Int?

    init(book: CloudBook, undoManager: UndoManager?) {
        opened = book
        self.undoManager = undoManager
    }

    private var book: CloudBook { model.books.first { $0.id == opened.id } ?? opened }

    var body: some View {
        let book = book
        let shown = SeriesDesigns.shownSeries(of: book, link: book.seriesLink)
        let all = Self.series(of: book, shown: shown)
        NavigationStack {
            Group {
                if all.count > 1 {
                    list(all, shown: saving ?? shown?.seriesID, of: book)
                } else if let only = all.first {
                    SeriesBooks(series: only, bookID: book.id)
                }
            }
            .navigationDestination(for: SeriesMembership.self) {
                SeriesBooks(series: $0, bookID: book.id).toolbar { done }
            }
            .toolbar { done }
        }
    }

    private var done: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }

    /// The book's series, each once, in Hardcover's order. A book without memberships, from an
    /// older archive, has only the series its label names.
    private static func series(of book: CloudBook, shown: SeriesMembership?) -> [SeriesMembership] {
        var seen = Set<Int>()
        let all = (book.seriesMemberships ?? []).filter { seen.insert($0.seriesID).inserted }
        guard let shown, !seen.contains(shown.seriesID) else { return all }
        return [shown] + all
    }

    /// Each series as a row that opens its books, after a check button that picks it.
    private func list(_ all: [SeriesMembership], shown: Int?, of book: CloudBook) -> some View {
        List {
            Section {
                ForEach(all, id: \.seriesID) { series in
                    let isShown = series.seriesID == shown
                    HStack(spacing: 12) {
                        // Borderless, so a tap on the check picks without opening the series.
                        Button {
                            choose(series.seriesID)
                        } label: {
                            Image(systemName: isShown ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(
                                    isShown ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.borderless)
                        .disabled(saving != nil)
                        .accessibilityLabel("Name \(series.name) on this book")
                        .accessibilityAddTraits(isShown ? .isSelected : [])
                        NavigationLink(value: series) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(series.name)
                                if let place = SeriesDesigns.place(in: series) {
                                    Text(place).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityHint("Shows the books in this series.")
                    }
                }
            } footer: {
                Text(
                    "The checked series names this book and sets its series under Style, whose look the spine shares. The shortest series is the default."
                )
            }
        }
        .navigationTitle("Series")
        .navigationSubtitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ seriesID: Int) {
        let book = book
        let old = SeriesRows.Choice(book.seriesLink)
        var new = old
        new.series =
            seriesID == SeriesDesigns.styleSeries(of: book, link: nil)?.id
            ? .standard : .linked(seriesID)
        guard new != old else { return }
        saving = seriesID
        Task { [model, undoManager] in
            await SeriesRows.save(
                new, replacing: old, for: book, model: model, undoManager: undoManager)
            if saving == seriesID { saving = nil }
        }
    }
}

/// One series' books in reading order (`SeriesEntry.listing(series:info:library:)`), with the
/// book whose details opened **Series** marked **This book**, then how many the reader has read.
private struct SeriesBooks: View {
    let series: SeriesMembership
    let bookID: Int

    @Environment(AppModel.self) private var model
    /// Listed when the view appears, so rendering never sorts the library.
    @State private var entries: [SeriesEntry] = []

    var body: some View {
        List {
            Section {
                ForEach(entries) { SeriesEntryRow(entry: $0, currentID: bookID) }
            } footer: {
                let read = entries.filter { $0.book?.hasBeenRead == true }.count
                Text("You've read \(read) of \(entries.count).")
            }
        }
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            entries = SeriesEntry.listing(
                series: series.seriesID,
                info: model.library?.series?.first { $0.id == series.seriesID },
                library: model.books)
        }
    }
}

/// One book of a series as **Series** lists it, with the library's copy when the reader has the
/// book.
struct SeriesEntry: Identifiable, Hashable {
    /// The Hardcover book ID.
    let id: Int
    let title: String
    let position: Double
    let releaseYear: Int?
    /// The reader's copy, or `nil` when the book isn't in the library.
    let book: CloudBook?

    /// The books of series `id` in reading order.
    ///
    /// `info`, Hardcover's list from the last download, gives one main book per whole-number
    /// position. Hardcover lists one edition at each position, so a library book at that
    /// position stands in for the entry, and library books at other positions, such as a novella
    /// at 2.5, join in order. Without a list, the library's own books in the series show.
    static func listing(series id: Int, info: SeriesInfo?, library: [CloudBook]) -> [SeriesEntry] {
        var owned: [Double: CloudBook] = [:]
        for book in library {
            // Memberships decide; a book from an older archive has only its featured series.
            let position =
                book.seriesMemberships.map { all in all.first { $0.seriesID == id }?.position }
                ?? (book.seriesID == id ? book.seriesPosition : nil)
            if let position, owned[position] == nil { owned[position] = book }
        }
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries = (info?.books ?? [])
            .map {
                SeriesEntry(
                    id: $0.id, title: $0.title, position: $0.position, releaseYear: $0.releaseYear,
                    book: byID[$0.id] ?? owned[$0.position])
            }
        let listed = Set(entries.map(\.position))
        let listedBooks = Set(entries.compactMap(\.book?.id))
        for (position, book) in owned
        where !listed.contains(position) && !listedBooks.contains(book.id) {
            entries.append(
                SeriesEntry(
                    id: book.id, title: book.title, position: position,
                    releaseYear: book.publicationYear, book: book))
        }
        return entries.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }
}

/// A row of **Series**: the book's position, title, and year, and a mark for the reader's copy.
/// Books outside the library are dimmed.
private struct SeriesEntryRow: View {
    let entry: SeriesEntry
    /// The book whose details opened the sheet, marked **This book**.
    let currentID: Int

    var body: some View {
        let mark = mark
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.position.formatted(.number.precision(.fractionLength(0...1))))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.book?.title ?? entry.title)
                    .foregroundStyle(entry.book == nil ? .secondary : .primary)
                let detail = [mark?.text, entry.releaseYear.map(String.init)].compactMap(\.self)
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let mark {
                Image(systemName: mark.symbol)
                    .foregroundStyle(mark.symbol == "checkmark.circle.fill" ? .green : .secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The reader's relation to the book: this book, read, reading, or on a shelf, or `nil`
    /// outside the library.
    private var mark: (text: String, symbol: String)? {
        guard let book = entry.book else { return nil }
        if book.id == currentID { return ("This book", "book.closed.fill") }
        if book.hasBeenRead { return ("Read", "checkmark.circle.fill") }
        if book.isReading == true { return ("Reading", "book") }
        return ("On your shelf", "bookmark")
    }
}
