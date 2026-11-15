import SwiftUI

/// **Series**, from the **Series** card or row of a book's details: every series the book belongs
/// to, each opening its books in reading order (`SeriesBooks`). A book in one series opens
/// straight to its books.
///
/// A check button beside each series marks the series the book's label names
/// (`SeriesDesigns.shownSeries(of:link:)`) and picks another one. A pick saves the book's
/// `SeriesLinkV1` (`SeriesRows.save(_:replacing:for:model:undoManager:)`), so each of the
/// reader's devices that syncs with iCloud names it, and the book's spine joins that series' look
/// as the **Spine design** card's **Series** menu sets it. Picking the book's shortest series
/// restores the default. A pick shows at once and stays while it saves; the buttons take no other
/// pick until the save ends. A failed save shows in an alert, which, unlike a toast, shows over a
/// sheet on the Mac too.
struct SeriesSheet: View {
    /// The book as its details showed it. The sheet shows the library's current copy, so a saved
    /// pick appears at once.
    let opened: CloudBook
    let undoManager: UndoManager?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The series being saved, shown until the library has it.
    @State private var saving: Int?
    /// Why the last pick wasn't saved, until the reader dismisses the alert.
    @State private var saveError: String?

    init(book: CloudBook, undoManager: UndoManager?) {
        opened = book
        self.undoManager = undoManager
    }

    private var book: CloudBook { model.book(id: opened.id) ?? opened }

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
        .alert(
            "The series choice was not changed",
            isPresented: Binding {
                saveError != nil
            } set: {
                if !$0 { saveError = nil }
            }
        ) {
        } message: {
            Text(saveError ?? "")
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
                        // The example profile is read-only, so it picks no series.
                        if !model.isExample {
                            // Borderless, so a tap on the check picks without opening the
                            // series.
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
                            .help("Use this series for the book's label and look")
                            .accessibilityLabel("Name \(series.name) on this book")
                            .accessibilityAddTraits(isShown ? .isSelected : [])
                        }
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
                // The example profile picks no series, so its list has no checks to explain.
                if !model.isExample {
                    Text(
                        "The checked series names this book on each of your devices that syncs with iCloud."
                    )
                }
            }
        }
        .navigationTitle("Series")
        .navigationSubtitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ seriesID: Int) {
        let book = book
        let old = SeriesRows.Choice(book.seriesLink)
        let new = SeriesRows.Choice.picking(seriesID, for: book)
        guard new != old else { return }
        saving = seriesID
        Task { [model, undoManager] in
            saveError = await SeriesRows.save(
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
                // The example profile's reading is not the viewer's.
                Text(
                    model.isExample
                        ? "Read \(read) of \(entries.count)."
                        : "You've read \(read) of \(entries.count).")
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
                    .foregroundStyle(mark.isRead ? .green : .secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The reader's relation to the book: this book, read, reading, or on a shelf, or `nil`
    /// outside the library. Only a read book's mark is green.
    private var mark: (text: String, symbol: String, isRead: Bool)? {
        guard let book = entry.book else { return nil }
        if book.id == currentID { return ("This book", "book.closed.fill", false) }
        if book.hasBeenRead { return ("Read", "checkmark.circle.fill", true) }
        if book.isReading == true { return ("Reading", "book", false) }
        return ("On your shelf", "bookmark", false)
    }
}
