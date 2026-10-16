import Foundation

/// The books that share a series look (`SeriesLookV1`): one style series
/// (`SeriesDesigns.styleSeries(of:link:)`), split by Discworld group and first author.
///
/// `group` joins the Discworld group, empty outside listed series, and the first author's
/// `SeriesDesigns.authorKeys(of:)` key with "|", such as "City Watch|terrypratchett".
struct SeriesLookKey: Codable, Hashable, Sendable {
    let seriesID: Int
    let group: String
}

/// Decides which books in a series draw alike, so a series looks alike on the shelf: the same
/// font, colors, case, and weight, with only the title and thickness changing.
///
/// Books with one look key (`lookKey(of:link:)`) form a look group. A group's first saved look
/// (`SeriesLookV1`) decides how its books draw; a book whose link sets `ownLook`, or whose
/// lettering the look's loaded face lacks glyphs for, draws its own design instead. Before a
/// group has a look, its books draw the design of the best-ranked book with one
/// (`sources(of:lends:canLetter:)`). Each book keeps its own saved design either way. Generation
/// follows the same rules (`SpineWorker`), so a group's books usually save matching designs
/// anyway. The Apple TV app mirrors `styleSeries`, `lookKey`, and `subseries`; keep them in step,
/// because the look key names the look's record, and keys that differ between the apps give one
/// group two looks.
enum SeriesDesigns {
    /// The series whose look `book` draws, with the book's position in it: the series its link
    /// names, else its shortest series, or `nil` for no series.
    ///
    /// The shortest series groups a book of a long series, such as Discworld, with the smaller
    /// series it also belongs to, so the long series' books don't all look alike. Among
    /// `seriesMemberships`, compilations sort last, then series by size, with unknown and
    /// one-book series last, then the featured series, then the lower ID. A book without
    /// memberships, from an older archive or cache, uses `seriesID`.
    static func styleSeries(of book: CloudBook, link: SeriesLinkV1?) -> (
        id: Int, position: Double?
    )? {
        if let link {
            if link.standsAlone { return nil }
            if let id = link.linkedSeriesID {
                return (id, book.seriesMemberships?.first { $0.seriesID == id }?.position)
            }
        }
        guard let memberships = book.seriesMemberships else {
            return book.seriesID.map { ($0, book.seriesPosition) }
        }
        func order(_ series: SeriesMembership) -> (Int, Int, Int, Int) {
            let size = series.size.flatMap { $0 >= 2 ? $0 : nil } ?? .max
            return (series.compilation ? 1 : 0, size, series.featured ? 0 : 1, series.seriesID)
        }
        return memberships.min { order($0) < order($1) }.map { ($0.seriesID, $0.position) }
    }

    /// The look group of `book`, or `nil` when it draws no series look: it has no style series,
    /// or its style series has `subseries` groups and none lists its title.
    static func lookKey(of book: CloudBook, link: SeriesLinkV1?) -> SeriesLookKey? {
        guard let series = styleSeries(of: book, link: link)?.id else { return nil }
        var subgroup = ""
        if let groups = subseries[series] {
            // A book in no group keeps its own design.
            guard let group = groups[titleKey(book.title)] else { return nil }
            subgroup = group
        }
        return SeriesLookKey(
            seriesID: series, group: subgroup + "|" + (authorKeys(of: book).first ?? ""))
    }

    /// Returns whether `book` and `other` draw one series look: the same look key.
    static func matches(_ book: CloudBook, _ other: CloudBook) -> Bool {
        guard let key = lookKey(of: book, link: book.seriesLink) else { return false }
        return key == lookKey(of: other, link: other.seriesLink)
    }

    /// Groups within long series that Hardcover does not record, keyed by Hardcover series ID
    /// and then by `titleKey(_:)`: each group shares a look instead of the whole series.
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

    /// The book's authors in order, compared without case, diacritics, spaces, or punctuation.
    /// Libraries join several authors with ", ".
    static func authorKeys(of book: CloudBook) -> [String] {
        book.author.components(separatedBy: ", ")
            .map {
                String(
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                        .filter { $0.isLetter || $0.isNumber })
            }
            .filter { !$0.isEmpty }
    }

    /// Returns whether `lhs` ranks before `rhs` in their look group: the lower position in the
    /// style series, then the earlier finish, then the lower book ID. A missing position or
    /// finish ranks last, so reading the first book or a prequel later moves the group to its
    /// design.
    static func ranksBefore(_ lhs: CloudBook, _ rhs: CloudBook) -> Bool {
        func rank(_ book: CloudBook) -> (Double, Date, Int) {
            (
                styleSeries(of: book, link: book.seriesLink)?.position ?? .infinity,
                book.finishedDate ?? .distantFuture, book.id
            )
        }
        return rank(lhs) < rank(rhs)
    }

    /// Returns whether a design's font is allowed: neither its `fontFamily` nor its
    /// `fontPostScriptName` is blocked, such as Impact or an italic. A missing name passes.
    ///
    /// A new look copies only a design that passes as stored (`SpineStore.savedDesign`,
    /// `LibrarySnapshot.designs`), the same records the Apple TV app checks with its copy of this
    /// rule, so both apps pick the same source for a group's first look. It rejects a blocked
    /// `fontFamily` or `fontPostScriptName`, as the Apple TV does. A group without a look judges
    /// each design in its allowed upright face (`SpineDesignV1.withAllowedFont`), as readers draw
    /// it.
    static func isUsableSource(_ design: SpineDesignV1) -> Bool {
        (design.fontFamily.map(BookAnalyzer.allowsFamily) ?? true)
            && (design.fontPostScriptName.map(BookAnalyzer.allowsFamily) ?? true)
    }

    /// Groups `books` by look key, leaving out books without one and books whose link keeps
    /// their own look.
    static func lookGroups(_ books: [CloudBook]) -> [SeriesLookKey: [CloudBook]] {
        var groups: [SeriesLookKey: [CloudBook]] = [:]
        for book in books where book.seriesLink?.ownLook != true {
            if let key = lookKey(of: book, link: book.seriesLink) {
                groups[key, default: []].append(book)
            }
        }
        return groups
    }

    /// `lookGroups(_:)` with each group's books in rank order (`ranksBefore(_:_:)`).
    static func rankedLookGroups(_ books: [CloudBook]) -> [SeriesLookKey: [CloudBook]] {
        lookGroups(books).mapValues { $0.sorted(by: ranksBefore) }
    }

    /// Maps each book that draws another book's spine design to that book, its source; a
    /// source maps to itself, and a book that draws its own design and lends it to no one is
    /// absent. This is the rule for look groups without a saved look.
    ///
    /// Only a root lends its design: a book that draws its own. Each look group is decided in
    /// `ranksBefore` order. A book takes the best-ranked earlier root that can lend (`lends`) and
    /// can letter it (`canLetter`); otherwise it is a root itself. Recolor, **Change cover**, and
    /// **Redesign spine** on a book act on its source, which always designs from its own cover.
    /// The result doesn't depend on the order of `books`.
    static func sources(
        of books: [CloudBook], lends: (CloudBook) -> Bool,
        canLetter: (_ book: CloudBook, _ source: CloudBook) -> Bool = { _, _ in true }
    ) -> [Int: Int] {
        sources(ranked: rankedLookGroups(books).values, lends: lends, canLetter: canLetter)
    }

    /// `sources(of:lends:canLetter:)` for look groups whose books are already in rank order, as
    /// `rankedLookGroups(_:)` returns them, so a caller that keeps the groups skips regrouping.
    static func sources(
        ranked groups: some Sequence<[CloudBook]>, lends: (CloudBook) -> Bool,
        canLetter: (_ book: CloudBook, _ source: CloudBook) -> Bool = { _, _ in true }
    ) -> [Int: Int] {
        var sources: [Int: Int] = [:]
        for members in groups {
            var roots: [CloudBook] = []
            for book in members {
                if let root = roots.first(where: { lends($0) && canLetter(book, $0) }) {
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
    /// when its allowed upright face (`SpineDesignV1.withAllowedFont`) is usable
    /// (`isUsableSource`), so a design saved in a blocked face, such as Impact, lends its
    /// replacement.
    static func sources(
        books: [CloudBook], designs: [Int: SpineDesignV1],
        canLetter: (CloudBook, SpineDesignV1) -> Bool = { _, _ in true }
    ) -> [Int: Int] {
        sources(ranked: rankedLookGroups(books).values, designs: designs, canLetter: canLetter)
    }

    /// `sources(books:designs:canLetter:)` for look groups already in rank order.
    static func sources(
        ranked groups: some Sequence<[CloudBook]>, designs: [Int: SpineDesignV1],
        canLetter: (CloudBook, SpineDesignV1) -> Bool = { _, _ in true }
    ) -> [Int: Int] {
        sources(
            ranked: groups,
            lends: { designs[$0.id].map { isUsableSource($0.withAllowedFont) } == true },
            canLetter: { book, source in designs[source.id].map { canLetter(book, $0) } ?? false })
    }

    /// Returns `queue` with each look group's books in rank order, in the places the group's
    /// books already held, so a run designs a group's source before the books that reuse it.
    static func sourceFirst(_ queue: [CloudBook]) -> [CloudBook] {
        var ordered = queue
        var groups: [SeriesLookKey: [Int]] = [:]
        for index in queue.indices where queue[index].seriesLink?.ownLook != true {
            if let key = lookKey(of: queue[index], link: queue[index].seriesLink) {
                groups[key, default: []].append(index)
            }
        }
        for indices in groups.values {
            let books = indices.map { queue[$0] }.sorted(by: ranksBefore)
            for (index, book) in zip(indices, books) { ordered[index] = book }
        }
        return ordered
    }

    /// The looks to create for the look groups in `books` that have no saved look in `looks`.
    ///
    /// A group gets a look when a member has a usable saved design (`isUsableSource`) made for
    /// the book as it is now: its work-item hash matches the book's
    /// (`CloudContract.workItemHash(accountID:book:)`). The look copies the member design made
    /// earliest (`generatedAt`, then the lower book ID), as stored, among designs that are not
    /// series reuse copies, or among the copies when every design is one.
    static func missingLooks(
        books: [CloudBook], designs: [Int: SpineDesignV1],
        looks: [SeriesLookKey: SeriesLookV1], now: Date
    ) -> [SeriesLookV1] {
        lookGroups(books)
            .compactMap { key, members in
                guard looks[key] == nil else { return nil }
                let usable = members.compactMap { book -> SpineDesignV1? in
                    guard let design = designs[book.id], isUsableSource(design),
                        design.workItemHash
                            == CloudContract.workItemHash(accountID: design.accountID, book: book)
                    else { return nil }
                    return design
                }
                let originals = usable.filter { !$0.isSeriesReuse }
                let source = (originals.isEmpty ? usable : originals)
                    .min { ($0.generatedAt, $0.bookID) < ($1.generatedAt, $1.bookID) }
                return source.map { SeriesLookV1(design: $0, key: key, createdAt: now) }
            }
    }

    /// The text a spine letters for `book` in a design, for glyph checks: its title and author.
    static func lettering(of book: CloudBook, uppercase: Bool) -> String {
        let text = book.title + " " + book.author
        return uppercase ? text.uppercased() : text
    }
}

extension SpineDesignV1 {
    /// Whether the design copies another book's (`provenance` "series-reuse:<bookID>").
    var isSeriesReuse: Bool {
        provenance?.split(separator: " ").contains { $0.hasPrefix("series-reuse:") } == true
    }
}
