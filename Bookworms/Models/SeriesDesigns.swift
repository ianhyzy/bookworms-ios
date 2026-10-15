import Foundation

/// Decides which books in a series draw with another book's spine design, so a series looks
/// alike on the shelf: the same font, colors, case, and weight, with only the title and
/// thickness changing.
///
/// Alignment happens when the app draws, not when it generates: each book keeps its own saved
/// design, so changing these rules changes no saved data. Generation follows the same rules
/// (`SpineWorker`), so a series' books usually save matching designs anyway.
enum SeriesDesigns {
    /// Returns whether `book` and `other` share a series design: the same series and at least
    /// one shared author.
    ///
    /// This is the whole membership rule; everything else in the app calls it. To let every
    /// book in a series match whoever wrote it, return `true` after the series check instead of
    /// comparing authors. Each `CloudBook` stores one series, the featured one from Hardcover,
    /// so a book in several series matches only through that one.
    static func matches(_ book: CloudBook, _ other: CloudBook) -> Bool {
        guard let series = book.seriesID, series == other.seriesID else { return false }
        return !authors(of: book).isDisjoint(with: authors(of: other))
    }

    /// The book's authors, compared without case, diacritics, spaces, or punctuation. Libraries
    /// join several authors with ", ".
    static func authors(of book: CloudBook) -> Set<String> {
        Set(
            book.author.components(separatedBy: ", ")
                .map {
                    String(
                        $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                            .filter { $0.isLetter || $0.isNumber })
                }
                .filter { !$0.isEmpty })
    }

    /// Returns whether `lhs` ranks before `rhs` as a series' design source: the lower series
    /// position, then the earlier finish, then the lower book ID. A missing position or finish
    /// ranks last, so reading the first book or a prequel later moves the series to its design.
    static func ranksBefore(_ lhs: CloudBook, _ rhs: CloudBook) -> Bool {
        (lhs.seriesPosition ?? .infinity, lhs.finishedDate ?? .distantFuture, lhs.id)
            < (rhs.seriesPosition ?? .infinity, rhs.finishedDate ?? .distantFuture, rhs.id)
    }

    /// Returns whether another book may draw with `design`: never a blocked family, such as
    /// Impact or an italic.
    ///
    /// The check stands on its own and does not rely on library designs being remapped to
    /// allowed faces when they load: the spine worker passes saved designs exactly as stored
    /// (`SpineStore.savedDesign`), and the library views may run before that remapping exists.
    static func isUsableSource(_ design: SpineDesignV1) -> Bool {
        design.fontFamily.map(BookAnalyzer.allowsFamily) ?? true
    }

    /// Maps each book that shares a series design to the book whose design it draws with. A
    /// source maps to itself; books that draw their own design are absent.
    ///
    /// A book's source is the best-ranked book among it and its matching series-mates whose
    /// design is usable. `canLetter` tells whether a source design can letter a book; a book it
    /// rejects, such as one whose title the source's font lacks glyphs for, keeps its own
    /// design.
    static func sources(
        books: [CloudBook], designs: [Int: SpineDesignV1],
        canLetter: (CloudBook, SpineDesignV1) -> Bool = { _, _ in true }
    ) -> [Int: Int] {
        let candidates = Dictionary(
            grouping: books.filter {
                $0.seriesID != nil && designs[$0.id].map(isUsableSource) == true
            },
            by: { $0.seriesID })
        var sources: [Int: Int] = [:]
        for book in books {
            guard
                let source = candidates[book.seriesID]?
                    .filter({ $0.id == book.id || matches(book, $0) }).min(by: ranksBefore),
                source.id != book.id, let design = designs[source.id], canLetter(book, design)
            else { continue }
            sources[book.id] = source.id
            sources[source.id] = source.id
        }
        return sources
    }

    /// Returns `queue` with each series' books in source order, in the places the series'
    /// books already held, so a run designs a series' source before the books that reuse it.
    static func sourceFirst(_ queue: [CloudBook]) -> [CloudBook] {
        var ordered = queue
        let series = Dictionary(grouping: queue.indices.filter { queue[$0].seriesID != nil }) {
            queue[$0].seriesID
        }
        for indices in series.values {
            let books = indices.map { queue[$0] }.sorted(by: ranksBefore)
            for (index, book) in zip(indices, books) { ordered[index] = book }
        }
        return ordered
    }

    /// The text a spine letters for `book` in a design, for glyph checks: its title and author.
    static func lettering(of book: CloudBook, uppercase: Bool) -> String {
        let text = book.title + " " + book.author
        return uppercase ? text.uppercased() : text
    }
}
