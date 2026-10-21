import SwiftUI

/// **Series**, from a book's **Series** card: the series the book's label names
/// (`SeriesDesigns.shownSeries(of:link:)`) and its books in reading order, with the reader's
/// books marked as read, reading, or on a shelf.
///
/// A book in more than one series lists them all first; choosing one saves it as the book's
/// `SeriesLinkV1` (`SeriesRows.save(_:replacing:for:model:undoManager:)`), so every device shows
/// it, and the book's spine joins that series' look as the **Series** menu under **Style** sets it.
/// Choosing the book's shortest series restores the default. A choice shows at once and stays
/// while it saves.
struct SeriesSheet: View {
    /// The book as its details showed it. The sheet shows the library's current copy, so a saved
    /// choice appears at once.
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
        var seen = Set<Int>()
        let memberships = (book.seriesMemberships ?? [])
            .filter {
                seen.insert($0.seriesID).inserted
            }
        let selected = saving ?? shown?.seriesID
        let series = memberships.first { $0.seriesID == selected } ?? shown
        NavigationStack {
            List {
                if memberships.count > 1 {
                    Section {
                        Picker(
                            "Series",
                            selection: Binding {
                                selected
                            } set: {
                                if let id = $0 { choose(id) }
                            }
                        ) {
                            ForEach(memberships, id: \.seriesID) { membership in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(membership.name)
                                    if let place = SeriesDesigns.place(in: membership) {
                                        Text(place).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                .tag(Optional(membership.seriesID))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .disabled(saving != nil)
                    } header: {
                        Text("Show this book in")
                    } footer: {
                        Text("Also sets the series under Style, whose look the spine shares.")
                    }
                }
                if let series {
                    let entries = SeriesEntry.listing(
                        series: series.seriesID,
                        info: model.library?.series?.first { $0.id == series.seriesID },
                        library: model.books)
                    Section {
                        ForEach(entries) { SeriesEntryRow(entry: $0, currentID: book.id) }
                    } header: {
                        Text(series.name)
                    } footer: {
                        let read = entries.filter { $0.book?.hasBeenRead == true }.count
                        Text("You've read \(read) of \(entries.count).")
                    }
                }
            }
            .navigationTitle("Series")
            .navigationSubtitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
