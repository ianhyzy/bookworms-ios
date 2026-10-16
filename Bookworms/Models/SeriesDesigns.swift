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
        if let groups = subseries[series] {
            // A book in no group, or a group of its own, keeps its own design.
            guard let group = groups[titleKey(book.title)], group == groups[titleKey(other.title)]
            else { return false }
        }
        return !authors(of: book).isDisjoint(with: authors(of: other))
    }

    /// Groups within long series that Hardcover does not record, keyed by Hardcover series ID
    /// and then by `titleKey(_:)`: each group shares a design instead of the whole series.
    /// Books of a listed series that no group names keep their own designs.
    ///
    /// Discworld (series 1018) follows the owner's choice of the common reading-order groups.
    /// The grouping is loose; adjust it here, and in the Apple TV app's copy of this table.
    static let subseries: [Int: [String: String]] = [
        1018: groups([
            "Rincewind": [
                "The Colour of Magic", "The Color of Magic", "The Light Fantastic", "Sourcery",
                "Eric", "Faust Eric", "Interesting Times", "The Last Continent", "The Last Hero",
                "Unseen Academicals",
            ],
            "Industrial Revolution": [
                "Moving Pictures", "The Truth", "Monstrous Regiment", "Going Postal",
                "Making Money", "Raising Steam",
            ],
            "City Watch": [
                "Guards! Guards!", "Men at Arms", "Feet of Clay", "Jingo", "The Fifth Elephant",
                "Night Watch", "Thud!", "Snuff", "Where's My Cow?", "The World of Poo",
            ],
            "Death": ["Mort", "Reaper Man", "Soul Music", "Hogfather", "Thief of Time"],
            "Ancient Civilizations": ["Pyramids", "Small Gods"],
            "Witches": [
                "Equal Rites", "Wyrd Sisters", "Witches Abroad", "Lords and Ladies", "Maskerade",
                "Carpe Jugulum", "Nanny Ogg's Cookbook",
            ],
            "Tiffany Aching": [
                "The Wee Free Men", "A Hat Full of Sky", "Wintersmith", "I Shall Wear Midnight",
                "The Shepherd's Crown",
            ],
            "Science of Discworld": [
                "The Science of Discworld", "The Science of Discworld II",
                "The Science of Discworld III", "The Science of Discworld IV",
            ],
        ])
    ]

    private static func groups(_ titles: [String: [String]]) -> [String: String] {
        var keyed: [String: String] = [:]
        for (group, members) in titles {
            for title in members { keyed[titleKey(title)] = group }
        }
        return keyed
    }

    /// A title compared without case, diacritics, punctuation, or a subtitle after a colon, so
    /// "Thud!" matches "THUD" and "The Science of Discworld II: The Globe" matches its group.
    static func titleKey(_ title: String) -> String {
        let main = title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? title
        return main.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
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
    /// (`SpineStore.savedDesign`), and `AppModel.apply(_:)` adds new and recolored designs to the
    /// library without the remapping in `LibrarySnapshot.latestDesigns`. It checks only
    /// `fontFamily`; the worker accepts only this generator's designs, whose PostScript names are
    /// always allowed.
    static func isUsableSource(_ design: SpineDesignV1) -> Bool {
        design.fontFamily.map(BookAnalyzer.allowsFamily) ?? true
    }

    /// Maps each book that draws another book's spine design to that book, its source; a
    /// source maps to itself, and a book that draws its own design and lends it to no one is
    /// absent.
    ///
    /// Only a root lends its design: a book that draws its own. Each series is decided in
    /// `ranksBefore` order. A book takes the best-ranked earlier root that matches it, can lend
    /// (`lends`), and can letter it (`canLetter`); otherwise it is a root itself. Matching isn't
    /// transitive, since book 2 can share an author with books 1 and 3 that share none, so this
    /// keeps a book from drawing a design another book borrowed: book 3 then draws its own.
    /// Recolor, **Change cover**, and **Redesign spine** on a book act on its source, which
    /// always designs from its own cover. The result doesn't depend on the order of `books`.
    static func sources(
        of books: [CloudBook], lends: (CloudBook) -> Bool,
        canLetter: (_ book: CloudBook, _ source: CloudBook) -> Bool = { _, _ in true }
    ) -> [Int: Int] {
        var sources: [Int: Int] = [:]
        let series = Dictionary(grouping: books.filter { $0.seriesID != nil }, by: \.seriesID)
        for books in series.values {
            var roots: [CloudBook] = []
            for book in books.sorted(by: ranksBefore) {
                if let root = roots.first(where: {
                    matches(book, $0) && lends($0) && canLetter(book, $0)
                }) {
                    sources[book.id] = root.id
                    sources[root.id] = root.id
                } else {
                    roots.append(book)
                }
            }
        }
        return sources
    }

    /// `sources(of:lends:canLetter:)` for books with saved `designs`: a book lends its design
    /// when it has a usable one (`isUsableSource`).
    static func sources(
        books: [CloudBook], designs: [Int: SpineDesignV1],
        canLetter: (CloudBook, SpineDesignV1) -> Bool = { _, _ in true }
    ) -> [Int: Int] {
        sources(
            of: books, lends: { designs[$0.id].map(isUsableSource) == true },
            canLetter: { book, source in designs[source.id].map { canLetter(book, $0) } ?? false })
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
