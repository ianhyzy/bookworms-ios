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
/// (`SeriesLookV1`) decides how its books draw; a book whose link sets `ownLook` draws its own
/// design instead. Before a group has a look, its books draw the design of the best-ranked book
/// with one made for it as it is now (`sources(ranked:designs:)`). Each book keeps its own saved
/// design either way.
///
/// Books that draw one design share its font. They letter it in its face only when the face has
/// glyphs for every one of them (`lettering(of:uppercase:)`); otherwise all of them letter it in
/// its system typeface (`SpineDesignV1.inSystemTypeface`), which letters any book. No book leaves
/// its series' design, or takes another book's, because the shared face lacks a glyph.
///
/// Generation follows the same rules (`SpineWorker`), except that it lends only a design whose
/// stored font is allowed, so a group's books usually save matching designs anyway. The
/// Apple TV app mirrors `styleSeries`, `lookKey`, and `subseries`; keep them in step, because the
/// look key names the look's record, and keys that differ between the apps give one group two
/// looks. It also mirrors `shownSeries(of:link:)`, so both apps name the same series.
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
    /// rule, so both apps pick the same source for a group's first look. A group without a look
    /// judges each design in its allowed upright face (`SpineDesignV1.withAllowedFont`), as
    /// readers draw it.
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
    /// Each look group is decided in `ranksBefore` order: every book ranked after the group's
    /// best-ranked book that can lend (`lends`) draws that book's design, and earlier books draw
    /// their own. Recolor, **Change cover**, and **Redesign spine** on a book act on its source,
    /// which always designs from its own cover. The result doesn't depend on the order of
    /// `books`. `lends` runs on each book until one lends.
    static func sources(of books: [CloudBook], lends: (CloudBook) -> Bool) -> [Int: Int] {
        sources(ranked: rankedLookGroups(books).values, lends: lends)
    }

    /// `sources(of:lends:)` for look groups whose books are already in rank order, as
    /// `rankedLookGroups(_:)` returns them, so a caller that keeps the groups skips regrouping.
    static func sources(
        ranked groups: some Sequence<[CloudBook]>, lends: (CloudBook) -> Bool
    ) -> [Int: Int] {
        var sources: [Int: Int] = [:]
        for members in groups {
            var source: CloudBook?
            for book in members {
                if let source {
                    sources[book.id] = source.id
                    sources[source.id] = source.id
                } else if lends(book) {
                    source = book
                }
            }
        }
        return sources
    }

    /// `sources(ranked:lends:)` for look groups already in rank order, as
    /// `rankedLookGroups(_:)` returns them, whose books have saved `designs`: a book lends its
    /// design when its allowed upright face (`SpineDesignV1.withAllowedFont`) is usable
    /// (`isUsableSource`), so a design saved in a blocked face, such as Impact, lends its
    /// replacement, and the design was made for the book as it is now (`isCurrent(_:for:)`).
    /// A book whose design is stale draws it but lends it to no one.
    static func sources(
        ranked groups: some Sequence<[CloudBook]>, designs: [Int: SpineDesignV1]
    ) -> [Int: Int] {
        sources(ranked: groups) { book in
            guard let design = designs[book.id] else { return false }
            return isUsableSource(design.withAllowedFont) && isCurrent(design, for: book)
        }
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
    /// the book as it is now (`isCurrent(_:for:)`). The look copies the member design made
    /// earliest (`generatedAt`, then the lower book ID), as stored, with its model token, among
    /// designs that are not series reuse copies, or among the copies when every design is one. A
    /// look copied from a design the reader recolored or set in another font counts as edited
    /// (`SeriesLookV1.init(design:key:createdAt:)`).
    static func missingLooks(
        books: [CloudBook], designs: [Int: SpineDesignV1],
        looks: [SeriesLookKey: SeriesLookV1], now: Date
    ) -> [SeriesLookV1] {
        lookGroups(books)
            .compactMap { key, members in
                guard looks[key] == nil else { return nil }
                let usable = members.compactMap { book -> SpineDesignV1? in
                    guard let design = designs[book.id], isUsableSource(design),
                        isCurrent(design, for: book)
                    else { return nil }
                    return design
                }
                let originals = usable.filter { !$0.isSeriesReuse }
                let source = (originals.isEmpty ? usable : originals)
                    .min { ($0.generatedAt, $0.bookID) < ($1.generatedAt, $1.bookID) }
                return source.map { SeriesLookV1(design: $0, key: key, createdAt: now) }
            }
    }

    /// Returns whether `design` was made for `book` as it is now: its work-item hash matches the
    /// book's (`CloudContract.workItemHash(accountID:book:)`). A design made for an earlier title,
    /// author, or cover still draws its own book, but it neither lends to other books by rank nor
    /// starts a look.
    static func isCurrent(_ design: SpineDesignV1, for book: CloudBook) -> Bool {
        design.workItemHash == CloudContract.workItemHash(accountID: design.accountID, book: book)
    }

    /// The text that glyph checks require a design's face to letter for `book`: its full title,
    /// subtitle included, and its author. Spines letter only `CloudBook.spineTitle`, so the
    /// check is stricter than the lettering, and a missing glyph in a subtitle alone also moves a
    /// shared design to its system typeface.
    static func lettering(of book: CloudBook, uppercase: Bool) -> String {
        let text = book.title + " " + book.author
        return uppercase ? text.uppercased() : text
    }
}

extension SpineDesignV1 {
    /// The design without its face, so it letters in its system typeface (`typeface`) at its
    /// weight. Books that share a design whose face lacks a glyph one of them needs draw this
    /// (`SeriesDesigns`). Only the in-memory copy changes.
    var inSystemTypeface: SpineDesignV1 {
        var design = self
        design.fontFamily = nil
        design.fontPostScriptName = nil
        design.instanceWeight = nil
        return design
    }

    /// Whether the design copies another book's (`provenance` "series-reuse:<bookID>").
    var isSeriesReuse: Bool {
        provenance?.split(separator: " ").contains { $0.hasPrefix("series-reuse:") } == true
    }
}

extension SeriesDesigns {
    /// The series that `book`'s series label names: its style series (`styleSeries(of:link:)`),
    /// the series its link names, else its shortest series, as the book's membership in it. A
    /// book without memberships, from an older archive or cache, names its featured series.
    /// `nil` when the book has no named series or its link takes it out of every series
    /// (`SeriesLinkV1.standsAlone`).
    static func shownSeries(of book: CloudBook, link: SeriesLinkV1?) -> SeriesMembership? {
        guard let id = styleSeries(of: book, link: link)?.id else { return nil }
        if let membership = book.seriesMemberships?.first(where: { $0.seriesID == id }) {
            return membership
        }
        guard id == book.seriesID, let name = book.seriesName, !name.isEmpty else { return nil }
        return SeriesMembership(
            seriesID: id, name: name, position: book.seriesPosition, featured: true,
            compilation: false)
    }

    /// A book's place in `series`, such as "5 of 6", or "Book 5" when the series' size is
    /// unknown or doesn't include the position. `nil` without a position.
    static func place(in series: SeriesMembership) -> String? {
        guard let position = series.position else { return nil }
        let number = position.formatted(.number.precision(.fractionLength(0...1)))
        guard let size = series.size, position >= 1, position <= Double(size) else {
            return "Book \(number)"
        }
        return "\(number) of \(size)"
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

    /// Whether **Series** has more to show than `book` itself: the book is in two or more
    /// series, or its one series lists two or more books (`listing(series:info:library:)`).
    /// Otherwise the details name the series without opening it. The Apple TV follows the same
    /// rule.
    static func opensSeries(of book: CloudBook, infos: [SeriesInfo]?, library: [CloudBook])
        -> Bool
    {
        var ids = Set((book.seriesMemberships ?? []).map(\.seriesID))
        if let shown = SeriesDesigns.shownSeries(of: book, link: book.seriesLink) {
            ids.insert(shown.seriesID)
        }
        guard ids.count == 1, let id = ids.first else { return ids.count > 1 }
        // Hardcover's list usually decides, which spares the walk over the library.
        let info = infos?.first { $0.id == id }
        if (info?.books.count ?? 0) > 1 { return true }
        return listing(series: id, info: info, library: library).count > 1
    }
}
