import SwiftUI

/// A book's details on one page: a 3D model to turn with a drag, its title, author, and rating,
/// the reader's dates on a date-due card, the book's description, its readers' rating, and its
/// facts with the reader's status and format, the reader's review as a page, **Pin to Top Five**
/// for a finished book, and last the spine's design (`SpineDesignCard`), with **Change cover**.
/// Tapping the book's spine scrolls to the design. Where the details are wide, as in a wide Mac
/// window or on the iPhone Duo's inner display in landscape, the book stands in a column of its
/// own beside the rest.
///
/// The cards are library catalog cards with handwritten entries (`CatalogCard`), the first with
/// the title, author, and rating, or glass cards under the title printed on the walnut, as
/// **Book details** in settings chooses for this device (`CardStylePicker`). Every part follows
/// the choice: on glass, the reading record and the review are glass cards too, and no part is
/// paper. A part with nothing to show, such as a review the reader hasn't written, leaves no
/// note in its place.
///
/// A book that shares its series' spine design changes the series on the design card: the
/// series look's or source's colors, and the cover and design of the source book
/// (`AppModel.designSource(for:)`), from which **Redesign spines** remakes the look. With
/// **Changes apply to** set to **This book only**, the book keeps its own design and the edits
/// change only it. Color, series, and cover changes register with the window's undo manager.
///
/// With a `HostedBook`, the details draw no book, backdrop, or **Make share image** button of
/// their own: a transparent stand-in takes the book's place and turns as it would, the host
/// draws the book there behind the details, such as the Pile's RealityKit book or the shelf's
/// pulled-out book, and the host's bar offers **Make share image**.
struct BookDetailView: View {
    /// The book as the shelf opened it. The view shows the library's current copy, so a new
    /// cover or design appears at once.
    let opened: CloudBook
    /// The book's thickness as a share of its height, or `nil` for its own proportion
    /// (`BookShape`). Details opened from Library pass the proportion of the spine the reader
    /// chose (`CloudBook.librarySpineRatio(upright:)`), which is at least as thick as the book, so the
    /// book keeps the shape it had on the shelf or in the stack.
    let thicknessRatio: CGFloat?
    let hostedBook: HostedBook?

    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.legibilityWeight) private var legibilityWeight
    /// Whether the details take input, which a host turns off as they leave.
    @Environment(\.isEnabled) private var isEnabled
    /// Whether the cards are catalog cards rather than glass ones (`CardStylePicker`).
    @AppStorage(Self.noteCardsKey) private var noteCards = true
    /// The catalog cards' rule spacing before its limits, which grows with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var rawRule: CGFloat = 34
    /// The catalog cards' handwriting, or `nil` while Noteworthy stands in for it.
    @State private var hand: FontFace?
    @State private var cover: UIImage?
    @State private var sheet: DetailSheet?
    /// Whether VoiceOver's focus is on the **Spine design** card's heading, where showing the
    /// spine design moves it.
    @AccessibilityFocusState private var spineHeadingFocused: Bool
    /// Whether the book's **Series** opens (`SeriesEntry.opensSeries(of:infos:library:)`), kept
    /// until the library changes, since working it out can walk the whole library.
    @State private var opensSeries = false
    /// When the reader last changed the cover here.
    @State private var coverChangedAt: Date?
    /// The chosen cover the shown spine design comes from, as far as this screen knows: the
    /// design source's cover when the details opened, then when a new design arrives.
    @State private var designedCover: URL?
    /// The book's description as plain text, or `nil` without one. Cleaning a long description
    /// takes milliseconds, so it happens off the main actor when the description changes.
    @State private var about: String?
    /// Whether the details are wide enough to stand the book beside the text, as in a wide Mac
    /// window or on the iPhone Duo's inner display in landscape. It changes only when the width
    /// crosses `twoColumnWidth`. The Mac's default window is wide enough, so its details start
    /// wide. Crossing the width moves the book, whose drift and pose restart; the text keeps
    /// its scroll offset, which then shows content the book's height away.
    #if os(macOS)
        @State private var isWide = true
    #else
        @State private var isWide = false
    #endif
    #if os(iOS)
        /// The text column's width while `isWide` (`textColumnWidth(width:leading:trailing:)`).
        @State private var textWidth: CGFloat = 640
    #endif
    #if DEBUG
        /// Where `-BookwormsDetailScroll` scrolls the details.
        @State private var debugScroll = ScrollPosition()
    #endif

    /// The narrowest details that put the book in a column of its own: its stage and a text
    /// column of about 410 points on the iPhone.
    nonisolated private static let twoColumnWidth: CGFloat = 820

    /// The text column's width in wide iPhone details `width` points wide between safe-area
    /// insets of `leading` and `trailing` points: up to 640 points, and never past the screen's
    /// middle, so the book's column takes the screen's leading half. On the iPhone Duo's open
    /// inner display in landscape, the fold then falls between the book and the text, not
    /// through the cards. A Mac window has no fold, so its text column fills up to 640 points.
    nonisolated static func textColumnWidth(
        width: CGFloat, leading: CGFloat = 0, trailing: CGFloat = 0
    ) -> CGFloat {
        min(640, ((width + leading + trailing) / 2 - trailing).rounded(.down))
    }
    /// The user defaults key of whether the details show catalog cards.
    nonisolated static let noteCardsKey = "detailsNoteCards"
    /// The spine design card's scroll target.
    private static let spineDesignID = "spine-design"

    /// A sheet the details show. The account sheet replaces the cover picker, rather than
    /// opening over it, when the picker needs a sign-in. **Series** opens from a card
    /// (`EnvironmentValues.detailSheet`).
    fileprivate enum DetailSheet: Identifiable {
        case cover, account, series
        var id: Self { self }
    }

    init(book: CloudBook, thicknessRatio: CGFloat? = nil, hostedBook: HostedBook? = nil) {
        opened = book
        self.thicknessRatio = thicknessRatio
        self.hostedBook = hostedBook
        _designedCover = State(
            initialValue: AppModel.shared.designSource(for: book).chosenCoverURL)
        // A hand that has loaded before letters the cards from their first frame.
        var hand = AppModel.shared.fonts.loadedFace(
            family: CheckoutCard.handFamily, weight: CheckoutCard.handWeight)
        #if DEBUG
            // `-BookwormsHandFallback YES` keeps Noteworthy, as when Caveat can't download.
            if UserDefaults.standard.bool(forKey: "BookwormsHandFallback") { hand = nil }
        #endif
        _hand = State(initialValue: hand)
    }

    private var book: CloudBook { model.book(id: opened.id) ?? opened }

    private func updateOpensSeries() {
        opensSeries = SeriesEntry.opensSeries(
            of: book, infos: model.library?.series, library: model.books)
    }

    /// Caveat's weight: heavier with Bold Text on.
    private var handWeight: Int { legibilityWeight == .bold ? 700 : CheckoutCard.handWeight }

    /// The catalog cards' handwriting, or `nil` for glass cards. The rules are 34 points apart
    /// at the default text size, as on the date-due card, and stop growing at accessibility3's
    /// 80 points; the Mac has no Dynamic Type.
    private var paper: PaperType? {
        guard noteCards else { return nil }
        return PaperType.make(
            rule: min(max(rawRule, 32), 80), face: hand, bold: legibilityWeight == .bold)
    }

    var body: some View {
        let book = book
        let source = model.designSource(for: book)
        let look = model.look(for: book)
        let design = model.design(for: book)
        ScrollViewReader { proxy in
            let scrollToSpine = {
                withAnimation(reduceMotion ? nil : .smooth) {
                    proxy.scrollTo(Self.spineDesignID, anchor: .top)
                } completion: {
                    // Otherwise VoiceOver stays on the book, now scrolled out of view.
                    spineHeadingFocused = true
                }
            }
            // The example profile shows no spine design card to scroll to.
            let showSpine = model.isExample ? nil : scrollToSpine
            // The book moves between its own column and the top of the scroll view, which keeps
            // its identity, so the text keeps its state when the width crosses the threshold.
            HStack(spacing: 0) {
                if isWide {
                    TurningBook(
                        book: book, look: look, cover: cover, thicknessRatio: thicknessRatio,
                        host: hostedBook, showSpine: showSpine
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                scroll {
                    if !isWide {
                        TurningBook(
                            book: book, look: look, cover: cover,
                            thicknessRatio: thicknessRatio, host: hostedBook,
                            showSpine: showSpine)
                    }
                    content(book: book, source: source, look: look, design: design)
                }
                #if os(iOS)
                    .frame(width: isWide ? textWidth : nil)
                #else
                    .frame(maxWidth: isWide ? 640 : .infinity)
                #endif
            }
        }
        .environment(\.paperType, paper)
        .environment(\.detailSheet, $sheet)
        .environment(\.opensSeries, opensSeries)
        .onChange(of: model.books, initial: true) { updateOpensSeries() }
        .onChange(of: model.library?.series) { updateOpensSeries() }
        .onGeometryChange(for: Bool.self) {
            $0.size.width >= Self.twoColumnWidth
        } action: {
            isWide = $0
        }
        #if os(iOS)
            .onGeometryChange(for: CGFloat.self) { proxy in
                let insets = proxy.safeAreaInsets
                return Self.textColumnWidth(
                    width: proxy.size.width, leading: insets.leading, trailing: insets.trailing)
            } action: {
                textWidth = $0
            }
        #endif
        .background {
            if hostedBook == nil { WalnutWall().ignoresSafeArea() }
        }
        .toolbar {
            // A host shows its own bar, which outlasts these details as they leave, with these
            // buttons.
            if hostedBook == nil {
                ToolbarItem(placement: .primaryAction) {
                    MakeShareImageButton { model.share(book) }
                }
            }
        }
        // Any change to the candidates, such as a new cover choice or a sync's fallback, loads
        // again; the old cover shows until then. The download is shared and finishes even when a
        // new cover cancels this task.
        .task(id: book.coverCandidates) {
            let image = await model.covers.image(for: book)
            if !Task.isCancelled { cover = image }
        }
        .task(id: book.description) {
            let text = await Self.plainText(book.description)
            if !Task.isCancelled { about = text }
        }
        // Glass cards need no handwriting, so it loads once the reader chooses catalog cards.
        .task(id: noteCards ? handWeight : nil) {
            guard noteCards else { return }
            #if DEBUG
                if UserDefaults.standard.bool(forKey: "BookwormsHandFallback") { return }
            #endif
            let face = await model.fonts.face(family: CheckoutCard.handFamily, weight: handWeight)
            if let face, !Task.isCancelled { hand = face }
        }
        // A new design of the spine's source, not a recoloring of its look or design, nor an
        // ordinary run's copy of its series look.
        .onChange(of: model.library?.designs[source.id]?.generatedAt) {
            guard model.library?.designs[source.id]?.isSeriesReuse != true else { return }
            designedCover = source.chosenCoverURL
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .cover:
                // The shelf sets a dark scheme for its walnut backdrop, which the sheet's content
                // inherits; the sheet's own background must match it to keep text readable.
                // A new cover can call for a new spine, which a card above the design offers.
                // A series that shares a design takes its spine from its source's cover.
                CoverPickerView(
                    book: source,
                    scope: .init(of: book, in: model),
                    undoManager: undoManager
                ) {
                    coverChangedAt = .now
                } signIn: {
                    self.sheet = .account
                }
                .preferredColorScheme(.dark)
                .presentationSizing(.form)
            case .account:
                HardcoverAccountView().preferredColorScheme(.dark)
            case .series:
                SeriesSheet(book: book, undoManager: undoManager)
                    .preferredColorScheme(.dark)
                    .presentationSizing(.form)
            }
        }
        #if DEBUG
            .onAppear { if CoverPickerDebug.opensPicker { sheet = .cover } }
        #endif
    }

    /// The details' scroll view, with the content scrolling under the bar.
    private func scroll(@ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(spacing: 24) { content() }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        #if DEBUG
            // `-BookwormsDetailScroll <points>` scrolls the details that far down a second after
            // they appear, and `-BookwormsDetailScroll end` to the end, for Simulator checks.
            .scrollPosition($debugScroll)
            .task {
                guard let offset = UserDefaults.standard.string(forKey: "BookwormsDetailScroll")
                else { return }
                try? await Task.sleep(for: .seconds(1))
                if offset == "end" {
                    debugScroll.scrollTo(edge: .bottom)
                } else if let offset = Double(offset) {
                    debugScroll.scrollTo(y: offset)
                }
            }
        #endif
        // Fades text that scrolls under the bar into the walnut. The hard style's opaque backing
        // would draw a band of the system's background, ending in a line, across only the scroll
        // view, which in the Mac's wide layout is the text column.
        .scrollEdgeEffectStyle(.soft, for: .top)
        #if os(macOS)
            // The Mac's toolbar otherwise draws its own flat band over the bar, lighter than the
            // walnut and ending in a line above the title.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
    }

    /// The title, then the cards in order. `source` is the book the spine's design comes from
    /// (`AppModel.designSource(for:)`).
    @ViewBuilder
    private func content(
        book: CloudBook, source: CloudBook, look: SpineLook, design: SpineDesignV1?
    ) -> some View {
        let reading = DetailCard.journal(of: book)
        let parts = DetailCard.journalParts(reading)
        let series = model.sharesSeriesDesign(book)
        let coverChanged = design != nil && source.chosenCoverURL != designedCover
        header(book)
        if !parts.record.isEmpty { DateDueCard(rows: parts.record) }
        facts(DetailCard.details(of: book, about: about), others: parts.others, of: book)
        if let review = parts.review { ReviewPage(review: review, book: book) }
        // The example profile is read-only, so it offers no pin or spine edits.
        if !model.isExample {
            // Top Five draws finished books only.
            if book.finishedDate != nil { TopFivePinButton(bookID: book.id) }
            if coverChanged { redesignCard(series: series, of: book) }
            SpineDesignCard(
                book: book, look: look, design: design,
                generated: model.generatedColors(for: book), series: series ? source : nil,
                cover: cover, offersRedesign: !coverChanged,
                canPick: isEnabled && hostedBook?.hasLanded != false && sheet == nil,
                headingFocus: $spineHeadingFocused
            ) {
                sheet = .cover
            }
            .id(Self.spineDesignID)
        }
    }

    /// The book's facts, then the reader's status and format, then the genres: on catalog cards,
    /// the description and the readers' rating on cards of their own and the rest as the rows of
    /// one **Details** card; on glass, a grid of cards.
    @ViewBuilder
    private func facts(_ details: [DetailCard], others: [DetailCard], of book: CloudBook)
        -> some View
    {
        let cards = details.filter { !$0.isGenres } + others + details.filter(\.isGenres)
        if noteCards {
            ForEach(cards.filter { !$0.isField }, id: \.gridID) {
                DetailCardView(card: $0, book: book, fillsRow: true)
            }
            let fields = cards.filter(\.isField)
            if !fields.isEmpty { DetailsCatalogCard(fields: fields, book: book) }
        } else {
            CardGrid(cards: cards, book: book)
        }
    }

    /// Offers a run that redesigns the spine from the new cover.
    @ViewBuilder
    private func redesignCard(series: Bool, of book: CloudBook) -> some View {
        let heading = series ? "Redesign the series' spines?" : "Redesign the spine?"
        let note =
            series
            ? "The series' spines were designed from the previous cover."
            : "The spine was designed from the previous cover."
        if noteCards {
            CatalogCard(heading) {
                HandText(note, hand: .note)
                VStack(alignment: .leading, spacing: 8) {
                    RedesignButton(book: book, series: series, requestedAt: $coverChangedAt)
                }
                .padding(.vertical, 12)
            }
        } else {
            Card {
                Text(heading).font(.headline)
                Text(note).font(.footnote).foregroundStyle(CardNote())
                RedesignButton(book: book, series: series, requestedAt: $coverChangedAt)
            }
        }
    }

    /// The book's title and author and the reader's rating: written by hand on the first catalog
    /// card, or printed on the walnut above glass cards.
    @ViewBuilder private func header(_ book: CloudBook) -> some View {
        let rating = book.rating.flatMap { $0 > 0 ? $0 : nil }
        if let paper {
            CatalogCard(title: book) {
                HandText(book.author, tilt: .init(book: book.id, salt: 60))
                if let rating {
                    RatingStars(rating: rating, tint: Stationery.penInk)
                        .font(.system(size: 0.6 * paper.rule))
                        .ruledRow()
                }
            }
        } else {
            VStack(spacing: 6) {
                BookText(book.title, of: book)
                    .font(.title2.weight(.semibold))
                    .fontDesign(.serif)
                    .accessibilityAddTraits(.isHeader)
                Text(book.author)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let rating {
                    RatingStars(rating: rating).font(.title3).padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(ShelfPalette.paper)
        }
    }

    @concurrent nonisolated private static func plainText(_ markup: String?) async -> String? {
        HardcoverClient.plainText(from: markup)
    }
}

/// Chooses catalog cards or glass cards for every book's details on this device: in **Settings**,
/// under the Hardcover account, on the iPhone and in **Settings > General** on the Mac.
struct CardStylePicker: View {
    @AppStorage(BookDetailView.noteCardsKey) private var noteCards = true

    var body: some View {
        Picker("Book details", selection: $noteCards) {
            Text("Note cards").tag(true)
            Text("Glass cards").tag(false)
        }
    }
}

/// One card of the details' grid of glass cards, or of their catalog cards, with what it shows.
enum DetailCard: Hashable {
    /// The description as plain text.
    case about(String)
    /// Hardcover readers' average rating and how many ratings it averages, with the number of
    /// readers per half star (`ratingCounts(_:)`) when known, and the reader's own rating.
    case rating(average: Double, count: Int, counts: [Int]?, yours: Double?)
    /// The series the book's label names (`SeriesDesigns.shownSeries(of:link:)`).
    case series(SeriesMembership)
    case published(Int)
    /// The page count, which describes the book in any format.
    case length(String)
    case genres([String])
    /// A current read, with the fraction read when known.
    case status(progress: Double?)
    case started(Date)
    /// The newest finish, and how many times the reader finished the book.
    case finished(Date, reads: Int)
    case readingTime(String)
    /// How the reader read the book, such as "Audiobook", with an audiobook's listening time.
    case format(String, length: String?)
    case review(String)

    /// Whether the card fills its row: text and tags need the width, and a rating's bars sit
    /// beside the average there instead of making the card taller than the card beside it.
    var isWide: Bool {
        switch self {
        case .about, .genres: true
        case .rating(_, _, let counts, _): counts != nil
        default: false
        }
    }

    /// The cards about the book itself, whichever way anyone reads it. A fact that is missing
    /// has no card. `about` is the description as plain text.
    static func details(of book: CloudBook, about: String?) -> [DetailCard] {
        let genres = Array(YearInBooks.displayGenres(of: book).prefix(3))
        var rating: DetailCard?
        if let average = book.communityRating, average > 0, let count = book.ratingsCount,
            count > 0
        {
            rating = .rating(
                average: average, count: count, counts: ratingCounts(book.ratingDistribution),
                yours: book.rating)
        }
        let cards: [DetailCard?] = [
            about.map(DetailCard.about),
            rating,
            SeriesDesigns.shownSeries(of: book, link: book.seriesLink).map(DetailCard.series),
            book.publicationYear.map(DetailCard.published),
            ShelfLabels.pages(of: book).map(DetailCard.length),
            genres.isEmpty ? nil : .genres(genres),
        ]
        return cards.compactMap(\.self)
    }

    /// The reader's own record of the book, from their reading service. The format card gives an
    /// audiobook's listening time when known; the page count is the **Length** card's
    /// (`details(of:about:)`).
    static func journal(of book: CloudBook) -> [DetailCard] {
        let started = book.startedDate
        let finished = book.finishedDate
        let review = book.review?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cards: [DetailCard?] = [
            book.isReading == true ? .status(progress: book.progress) : nil,
            started.map(DetailCard.started),
            finished.map { .finished($0, reads: book.readCount) },
            ShelfLabels.readingTime(from: started, to: finished).map(DetailCard.readingTime),
            ShelfLabels.format(book.format)
                .map { .format($0, length: ShelfLabels.listeningTime(of: book)) },
            review?.isEmpty == false ? review.map(DetailCard.review) : nil,
        ]
        return cards.compactMap(\.self)
    }

    /// Splits the reader's record (`journal(of:)`) into the reading record's rows (start, finish,
    /// and reading time, in order), the review, and the other cards, in order.
    static func journalParts(_ cards: [DetailCard]) -> (
        record: [DetailCard], review: String?, others: [DetailCard]
    ) {
        var record: [DetailCard] = []
        var review: String?
        var others: [DetailCard] = []
        for card in cards {
            switch card {
            case .started, .finished, .readingTime: record.append(card)
            case .review(let text): review = text
            default: others.append(card)
            }
        }
        return (record, review, others)
    }

    /// The number of readers who gave each rating, in half-star steps from half a star to five
    /// stars, or `nil` when no rating has a reader.
    static func ratingCounts(_ buckets: [RatingBucket]?) -> [Int]? {
        var counts = Array(repeating: 0, count: 10)
        for bucket in buckets ?? [] where (0.5...5).contains(bucket.rating) && bucket.count > 0 {
            counts[Int((bucket.rating * 2).rounded()) - 1] += bucket.count
        }
        return counts.contains { $0 > 0 } ? counts : nil
    }

    /// The card's identity in `CardGrid`: its contents, except that the **Series** card keeps one
    /// identity when a pick changes its series, so the **Series** sheet it presents stays open.
    var gridID: AnyHashable {
        if case .series = self { "series" } else { self }
    }

    /// Arranges `cards` in order in rows of one or two, leaving no holes. A wide card fills its
    /// own row, and the cards between wide ones pair up; when their number is odd, the first
    /// fills a row alone, since it can use the room. With `oneColumn`, each card fills a row.
    static func rows(_ cards: [DetailCard], oneColumn: Bool) -> [[DetailCard]] {
        guard !oneColumn else { return cards.map { [$0] } }
        var rows: [[DetailCard]] = []
        var halves: [DetailCard] = []
        func pairHalves() {
            if !halves.count.isMultiple(of: 2) { rows.append([halves.removeFirst()]) }
            rows += stride(from: 0, to: halves.count, by: 2).map { Array(halves[$0...$0 + 1]) }
            halves = []
        }
        for card in cards {
            if card.isWide {
                pairHalves()
                rows.append([card])
            } else {
                halves.append(card)
            }
        }
        pairHalves()
        return rows
    }
}

extension DetailCard {
    /// Whether the catalog cards write the fact as a row of their **Details** card, rather than
    /// on a card of its own as the description and the readers' rating are.
    fileprivate var isField: Bool {
        switch self {
        case .about, .rating: false
        default: true
        }
    }

    fileprivate var isGenres: Bool {
        if case .genres = self { true } else { false }
    }
}

/// The 3D book's orientation, in radians.
struct BookPose: Equatable {
    var yaw: Double
    var pitch: Double

    /// Three-quarter view with the spine toward the viewer, which `Book3DView` defaults to.
    static let resting = BookPose(yaw: 0.45, pitch: -0.12)
    static let pitchRange = -0.4...0.3

    /// The pose after a drag of `translation` from this one. Dragging right turns the spine
    /// toward the viewer; dragging down tips the head toward the viewer.
    func turned(by translation: CGSize) -> BookPose {
        BookPose(
            yaw: yaw + translation.width / 110,
            pitch: min(
                Self.pitchRange.upperBound,
                max(Self.pitchRange.lowerBound, pitch - translation.height / 260)))
    }
}

/// Where a host behind `BookDetailView` draws the details' book, and how it turns.
struct HostedBook {
    /// Receives the frame of the book's height, `TurningBook.bookHeight` points tall and
    /// centered where the details center their book, in global coordinates, whenever the
    /// details' layout moves it.
    let place: (CGRect) -> Void
    /// Receives how far the drift moves the book from that frame and turns it from the pose that
    /// `turn` reports, on every frame of the drift. A host moves and turns its book by it
    /// without laying the book out or drawing its faces again.
    let float: (Drift.Offset) -> Void
    /// Receives the pose the details' book would show before the drift, whenever a drag or a
    /// coast changes it.
    let turn: (BookPose) -> Void
    /// Whether the host's book has landed in the details, which starts its drift. The drift
    /// then runs until the details leave, so a return starts from the drifted frame and pose.
    let hasLanded: Bool
}

/// A `Book3DView` to turn with a drag. Yaw is unbounded and pitch stays within a gentle tilt.
/// On release the book coasts with the swipe's momentum and its tilt eases back to rest, unless
/// Reduce Motion is on, when it stays where the finger left it. Once the book arrives, it floats
/// gently (see `Drift`), unless Reduce Motion is on. With a `host`, the book is a transparent
/// stand-in that reports its frame and pose for the host to draw.
///
/// The coast and the drift are functions of time that `TimelineView` samples, rather than
/// SwiftUI animations, so a drag that interrupts a coast starts from the pose on screen. The
/// drift adds to the dragged or coasting pose, so a drag neither stops nor restarts it. The
/// timeline runs at the display's rate and pauses while the book's stage is scrolled out of
/// view. Each frame of the drift moves and turns the drawn book with a render-only transform,
/// in fractions of a pixel (`BookProjection.turn(by:)`), which updates nothing else: the book's
/// faces redraw, and its layout changes, only when a drag or a coast turns it. The drag claims
/// touches that start on the book's stage, so the page scrolls from the text below.
///
/// A tap on the spine, as the book is drawn at that moment, or within 10 points of it, calls
/// `showSpine`; so does VoiceOver's **Show spine design** action. Without `showSpine`, the book
/// offers neither. A host's book is found where the details' own book would be drawn in the
/// same pose, which matches the host's drawing closely but not exactly.
private struct TurningBook: View {
    nonisolated static let bookHeight: CGFloat = 380
    /// The height of the book's stage, which leaves room for its drift and turns.
    nonisolated static let stageHeight: CGFloat = 460

    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    /// The book's thickness as a share of its height, or `nil` for its own proportion.
    let thicknessRatio: CGFloat?
    let host: HostedBook?
    let showSpine: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pose under the finger, or the pose a coast comes to rest at.
    @State private var pose = BookPose.resting
    /// The coast in progress, if any.
    @State private var coast: Coast?
    /// The idle float, from the moment the book arrives in its details, or `nil` with Reduce
    /// Motion on.
    @State private var drift: Drift?
    /// Whether some of the book's stage shows in the details' scroll view.
    @State private var isOnScreen = true
    /// When the stage last scrolled out of view, while it stays out.
    @State private var hiddenSince: Date?
    /// The stage's width, at whose center the book stands.
    @State private var stageWidth: CGFloat = 0
    /// The pose on screen when the current drag began. SwiftUI resets it when a drag ends or
    /// is cancelled, so the next drag starts from the current pose.
    @GestureState private var dragStart: BookPose?

    var body: some View {
        let drifts = drift != nil && isOnScreen
        let width = Self.bookHeight * Book3DView.aspect(of: cover)
        // Without a coast, the pose holds, so the drift's frames share one projection.
        let resting =
            host == nil && coast == nil
            ? BookProjection(
                width: width, height: Self.bookHeight, thickness: thickness, yaw: pose.yaw,
                pitch: pose.pitch)
            : nil
        TimelineView(.animation(paused: coast == nil && !drifts)) { context in
            let turned = coast?.pose(at: context.date) ?? pose
            let float = drift?.offset(at: context.date) ?? .zero
            if let host {
                Color.clear
                    .frame(height: Self.bookHeight)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        host.place($0)
                    }
                    .onChange(of: float, initial: true) { host.float(float) }
                    .onChange(of: turned, initial: true) { host.turn(turned) }
                    .accessibilityElement()
                    .accessibilityLabel("\(book.title), by \(book.author)")
            } else {
                let projection =
                    resting
                    ?? BookProjection(
                        width: width, height: Self.bookHeight, thickness: thickness,
                        yaw: turned.yaw, pitch: turned.pitch)
                let sway = projection.turn(by: float.yaw)
                // Between turns, the book's inputs and size stay the same, so only the visual
                // effect updates. Layout would round the drift to whole pixels, and a sway drawn
                // into the book would change its size, which layout centers to whole pixels too.
                Book3DView(
                    book: book, look: look, cover: cover, height: Self.bookHeight,
                    yaw: turned.yaw, pitch: turned.pitch, thicknessRatio: thicknessRatio
                )
                .visualEffect { content, _ in
                    content.transformEffect(sway).offset(float.translation)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.stageHeight)
        .background {
            // Larger than the stage so the glow's falloff never meets an edge. A host's book
            // lies behind the details, where the glow would veil it.
            if host == nil {
                RadialGradient(
                    colors: [ShelfPalette.lamp.opacity(0.22), .clear], center: .center,
                    startRadius: 0, endRadius: 280
                )
                .frame(width: 640, height: 640)
                .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            stageWidth = $0
        }
        .onTapGesture { if let showSpine, showsSpine(at: $0) { showSpine() } }
        .gesture(spin)
        // The pushed details' book arrives as they appear, and a host's book once it lands.
        .onChange(of: host?.hasLanded ?? true, initial: true) { _, arrived in
            if arrived, drift == nil, !reduceMotion { drift = Drift(start: .now) }
        }
        // Reduce Motion stops the drift at once, and turning it off eases the drift in again.
        .onChange(of: reduceMotion) { _, reduced in
            drift = reduced || host?.hasLanded == false ? nil : Drift(start: .now)
        }
        // The drift pauses while the stage is out of view and resumes where it paused, so it
        // never jumps, whatever part of the stage counts as visible.
        .onScrollVisibilityChange(threshold: 0.01) { visibilityChanged($0) }
        // Pauses the timeline once the coast settles.
        .task(id: coast) {
            guard coast != nil else { return }
            try? await Task.sleep(for: .seconds(Coast.spring.settlingDuration))
            if !Task.isCancelled { coast = nil }
        }
        #if os(iOS)
            // The Mac's VoiceOver adjusts with its keyboard commands, which the adjustable trait
            // announces.
            .accessibilityHint("Swipe up or down to turn the book.")
        #endif
        .accessibilityActions {
            if let showSpine { Button("Show spine design", action: showSpine) }
        }
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? Double.pi / 4 : -Double.pi / 4
            let target = BookPose(yaw: pose.yaw + step, pitch: pose.pitch)
            if reduceMotion { pose = target } else { settle(at: target) }
        }
        #if DEBUG
            .onAppear(perform: applyDebugPose)
            // `-BookwormsTapBook <x,y>` taps the stage at that point, in points from its top
            // leading corner, three seconds after it appears, for checks that cannot tap.
            .task {
                guard
                    let point = UserDefaults.standard.string(forKey: "BookwormsTapBook")?
                    .split(separator: ",").compactMap({ Double($0) }), point.count == 2
                else { return }
                try? await Task.sleep(for: .seconds(3))
                if let showSpine, showsSpine(at: CGPoint(x: point[0], y: point[1])) { showSpine() }
            }
        #endif
    }

    private var spin: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dragStart) { _, start, _ in
                if start == nil { start = coast?.pose(at: .now) ?? pose }
            }
            .onChanged { value in
                guard let dragStart else { return }
                coast = nil
                pose = dragStart.turned(by: value.translation)
            }
            .onEnded { value in
                guard !reduceMotion else { return }
                let momentum = CGSize(
                    width: value.predictedEndTranslation.width - value.translation.width,
                    height: value.predictedEndTranslation.height - value.translation.height)
                let yaw = pose.turned(by: momentum).yaw
                settle(at: BookPose(yaw: yaw, pitch: BookPose.resting.pitch))
            }
    }

    /// The drawn book's thickness in points.
    private var thickness: CGFloat {
        Self.bookHeight * (thicknessRatio ?? Book3DView.thicknessRatio(of: book, cover: cover))
    }

    /// Whether `point`, in the stage's coordinates, lies on the book's spine as it is drawn now,
    /// or within 10 points of it, since a three-quarter view shows a narrow spine.
    private func showsSpine(at point: CGPoint) -> Bool {
        let now = Date.now
        let turned = coast?.pose(at: now) ?? pose
        let float = drift?.offset(at: now) ?? .zero
        let projection = BookProjection(
            width: Self.bookHeight * Book3DView.aspect(of: cover), height: Self.bookHeight,
            thickness: thickness, yaw: turned.yaw + float.yaw, pitch: turned.pitch)
        // The book stands centered on the stage, moved by the drift.
        let origin = CGPoint(
            x: (stageWidth - projection.bounds.width) / 2 + float.translation.width,
            y: (Self.stageHeight - projection.bounds.height) / 2 + float.translation.height)
        return projection.face(
            .spine, contains: CGPoint(x: point.x - origin.x, y: point.y - origin.y), within: 10)
    }

    /// Pauses the drift while the stage is out of view, and resumes it where it paused.
    private func visibilityChanged(_ visible: Bool) {
        isOnScreen = visible
        if !visible {
            hiddenSince = .now
        } else if let hiddenSince, let current = drift {
            drift = Drift(
                start: current.start.addingTimeInterval(Date.now.timeIntervalSince(hiddenSince)))
            self.hiddenSince = nil
        }
    }

    /// Springs from the pose on screen to `target`.
    private func settle(at target: BookPose) {
        coast = Coast(from: coast?.pose(at: .now) ?? pose, to: target, start: .now)
        pose = target
    }

    #if DEBUG
        /// Simulator screenshot hook: `-BookwormsBookYaw <radians>` and
        /// `-BookwormsBookPitch <radians>` set the initial pose.
        private func applyDebugPose() {
            let defaults = UserDefaults.standard
            if let yaw = defaults.string(forKey: "BookwormsBookYaw").flatMap(Double.init) {
                pose.yaw = yaw
            }
            if let pitch = defaults.string(forKey: "BookwormsBookPitch").flatMap(Double.init) {
                pose.pitch = pitch
            }
        }
    #endif
}

/// A spring from one pose to another, sampled by time.
struct Coast: Equatable {
    static let spring = Spring(duration: 1.1, bounce: 0.12)

    let from: BookPose
    let to: BookPose
    let start: Date

    func pose(at date: Date) -> BookPose {
        let progress = Self.spring.value(target: 1.0, time: date.timeIntervalSince(start))
        return BookPose(
            yaw: from.yaw + (to.yaw - from.yaw) * progress,
            pitch: from.pitch + (to.pitch - from.pitch) * progress)
    }
}

/// The details' book's idle float, as the Apple TV's Book Wall floats a book in its details.
///
/// Three independent sine waves move the book up and down over 40 seconds, from side to side
/// over 48 seconds, and sway its yaw 2 degrees each way over 60 seconds, rising first. A
/// smootherstep ramp eases them in over their first 4 seconds, so the offset and its velocity
/// both start at zero and the book leaves the pose it arrived in without a jump.
///
/// The Book Wall drifts its detail book, roughly 600 points tall on the TV's 1080-point screen,
/// 24 points vertically and 6 horizontally: about 4 and 1 percent of its height. The phone keeps
/// those shares of its own book's height, about 15 and 4 points, so the book floats as far for
/// its size.
struct Drift: Equatable {
    static let verticalAmplitude = 0.04 * TurningBook.bookHeight
    static let horizontalAmplitude = 0.01 * TurningBook.bookHeight
    static let swayAmplitude = Double.pi / 90
    static let rampDuration = 4.0

    /// The book's displacement at one moment.
    struct Offset: Equatable {
        /// In points, with y down.
        var translation: CGSize
        /// In radians, to add to the book's yaw.
        var yaw: Double

        static let zero = Offset(translation: .zero, yaw: 0)
    }

    /// When the book arrived in its details.
    let start: Date

    /// The book's displacement at `date`.
    func offset(at date: Date) -> Offset {
        let time = max(0, date.timeIntervalSince(start))
        let ramp = min(1, time / Self.rampDuration)
        let eased = ramp * ramp * ramp * (ramp * (ramp * 6 - 15) + 10)
        func wave(_ amplitude: Double, period: Double) -> Double {
            amplitude * sin(2 * .pi * time / period) * eased
        }
        return Offset(
            translation: CGSize(
                width: wave(Self.horizontalAmplitude, period: 48),
                height: -wave(Self.verticalAmplitude, period: 40)),
            yaw: wave(Self.swayAmplitude, period: 60))
    }
}

/// Small secondary text on a card: the stock's label ink on paper (`EnvironmentValues.onPaper`),
/// and elsewhere the paper color at 70 percent. On a glass `Card`, the `.secondary` style reaches
/// only about 4.1:1 on the fill, below the 4.5:1 that footnote and caption text need.
private struct CardNote: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.onPaper ? Stationery.labelInk : ShelfPalette.paper.opacity(0.7)
    }
}

/// A note on a card: handwritten on catalog cards, else small text in `CardNote`.
private struct CardNoteText: View {
    let text: String

    init(_ text: String) { self.text = text }

    @Environment(\.paperType) private var paper

    var body: some View {
        if paper != nil {
            HandText(text, hand: .note)
        } else {
            Text(text).font(.footnote).foregroundStyle(CardNote())
        }
    }
}

/// A grouped panel on the walnut backdrop. It takes the height it is offered, so cards side by
/// side in a `CardGrid` row match.
private struct Card<Content: View>: View {
    /// The card's fill over the walnut wall's lighter end, the lightest a card gets.
    static var ground: ColorValue {
        ShelfPalette.wallLight.mixed(with: ColorValue(red: 255, green: 255, blue: 255), 0.07)
    }

    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .foregroundStyle(ShelfPalette.paper)
            .environment(\.bookTextGround, Self.ground)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.07), in: .rect(cornerRadius: 22))
    }
}

/// A card's name with a small symbol, above its content.
private func caption(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
        .font(.footnote.weight(.medium))
        .foregroundStyle(CardNote())
}

/// A card's labeled row: the label beside its value when both fit on one line, otherwise the
/// label above the value, so neither overlaps the other at any text size. When the value doesn't
/// fit on one line under the label either, `fallback` stands in for it, such as a menu for a
/// segmented control; by default the value itself, which then wraps.
private struct CardRow<Value: View, Fallback: View>: View {
    let title: String
    let value: Value
    let fallback: Fallback

    init(
        _ title: String, @ViewBuilder value: () -> Value, @ViewBuilder fallback: () -> Fallback
    ) {
        self.title = title
        self.value = value()
        self.fallback = fallback()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(title)
                Spacer(minLength: 0)
                value.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                value.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                fallback
            }
        }
    }
}

extension CardRow where Fallback == Value {
    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.init(title, value: value, fallback: value)
    }
}

/// Cards in the rows that `DetailCard.rows(_:oneColumn:)` arranges: two columns, or one at
/// accessibility text sizes. Each row is as tall as its tallest card.
private struct CardGrid: View {
    let cards: [DetailCard]
    /// The book the cards describe, whose own text the cards letter with `BookText`.
    let book: CloudBook

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 12) {
            ForEach(
                DetailCard.rows(cards, oneColumn: typeSize.isAccessibilitySize),
                id: \.gridIDs
            ) { row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row, id: \.gridID) {
                        DetailCardView(card: $0, book: book, fillsRow: row.count == 1)
                    }
                }
                // Measures the row at its tallest card's height, then offers every card that
                // height.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension [DetailCard] {
    /// A row's identity in `CardGrid` (`DetailCard.gridID`).
    fileprivate var gridIDs: [AnyHashable] { map(\.gridID) }
}

/// One card of a `CardGrid`. VoiceOver reads each card as one element.
private struct DetailCardView: View {
    let card: DetailCard
    let book: CloudBook
    let fillsRow: Bool

    var body: some View {
        switch card {
        case .about(let text):
            AboutCard(text: text, book: book)
        case .rating(let average, let count, let counts, let yours):
            RatingCard(
                average: average, count: count, counts: counts, yours: yours, isWide: fillsRow,
                bookID: book.id)
        case .series(let series):
            SeriesCard(series: series)
        case .published(let year):
            FactCard(title: "Published", systemImage: "calendar", value: String(year))
        case .length(let pages):
            FactCard(title: "Length", systemImage: "text.book.closed", value: pages)
        case .genres(let genres):
            GenresCard(genres: genres)
        case .status(let progress):
            FactCard(
                title: "Status", systemImage: "book", value: "Reading now",
                detail: progress.map {
                    "\($0.formatted(.percent.precision(.fractionLength(0)))) read"
                })
        case .format(let format, let length):
            FactCard(
                title: "Read as", systemImage: ShelfLabels.formatSymbol(format), value: format,
                detail: length)
        // The reading record and the review show these (`DetailCard.journalParts(_:)`).
        case .started, .finished, .readingTime, .review:
            EmptyView()
        }
    }
}

/// The reader's dates: when they started and finished the book, and how long it took. With
/// catalog cards, a date-due card: the dates stamped in violet ink and the time typed, each on a
/// printed rule. A stamp sits a degree or two off level, as an inked stamp does; the card itself
/// lies straight. With glass cards, a glass card with the same lines in plain type. VoiceOver
/// reads each line as one element.
private struct DateDueCard: View {
    /// The `.started`, `.finished`, and `.readingTime` cards to letter.
    let rows: [DetailCard]

    /// The rules' spacing, which grows with Dynamic Type so a line of text fits between them.
    @ScaledMetric private var line: CGFloat = 34
    @ScaledMetric private var labelColumn: CGFloat = 104
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.paperType) private var paper

    var body: some View {
        if paper != nil {
            CardStockSheet(ruleSpacing: line) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Reading record")
                        .font(.detailsFieldLabel)
                        .foregroundStyle(Stationery.labelInk)
                        .frame(maxWidth: .infinity, minHeight: line, alignment: .leading)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Stationery.red).frame(height: 1)
                                .accessibilityHidden(true)
                        }
                        .accessibilityAddTraits(.isHeader)
                    lines
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        } else {
            Card {
                caption("Reading record", systemImage: "bookmark")
                    .accessibilityAddTraits(.isHeader)
                lines
            }
        }
    }

    private var lines: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            entryLine(row, tilt: index.isMultiple(of: 2) ? -1.5 : 1)
        }
    }

    @ViewBuilder private func entryLine(_ row: DetailCard, tilt: Double) -> some View {
        switch row {
        case .started(let date):
            entry("Started", stamp: date)
        case .finished(let date, let reads):
            entry("Finished", stamp: date, detail: ShelfLabels.reads(reads), tilt: tilt)
        case .readingTime(let time):
            entry("Reading time", typed: time)
        default:
            EmptyView()
        }
    }

    /// One line: its label, then a date or typed text, and a detail. VoiceOver reads the date in
    /// plain type, as glass cards show it.
    private func entry(
        _ label: String, stamp: Date? = nil, typed: String? = nil, detail: String? = nil,
        tilt: Double = -1.5
    ) -> some View {
        let plain = stamp?.formatted(ShelfLabels.finishedFormat) ?? typed ?? ""
        return Group {
            if paper != nil {
                printed(label, stamp: stamp, typed: typed, detail: detail, tilt: tilt)
            } else {
                CardRow(label) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(plain)
                        if let detail {
                            Text(detail).font(.footnote).foregroundStyle(CardNote())
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([plain, detail].compactMap(\.self).joined(separator: ", "))
    }

    /// A line on the date-due card: its printed label, then a stamped date or typed text, and a
    /// detail, on one rule. At accessibility text sizes, the label stands above the rest.
    private func printed(
        _ label: String, stamp: Date?, typed: String?, detail: String?, tilt: Double
    ) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let layout =
            stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text(label)
                .font(.detailsFieldLabel)
                .foregroundStyle(Stationery.labelInk)
                .frame(width: stacked ? nil : labelColumn, alignment: .leading)
            if let stamp {
                Text(stamp.formatted(Stationery.stampFormat).uppercased())
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Stationery.stampInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .rotationEffect(.degrees(tilt))
            } else if let typed {
                Text(typed).bookHeading()
            }
            if !stacked { Spacer(minLength: 0) }
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(Stationery.labelInk)
            }
        }
        .padding(.vertical, stacked ? 8 : 0)
        .frame(minHeight: line)
    }
}

/// The reader's review. With catalog cards, a page: New York type with a hanging quotation mark
/// in the margin, and a red ribbon lying down the page's edge and out past its foot, as a
/// bookmark does. With glass cards, a glass card in plain type.
private struct ReviewPage: View {
    let review: String
    let book: CloudBook

    @Environment(\.paperType) private var paper

    var body: some View {
        if paper != nil {
            page
        } else {
            Card {
                caption("Your review", systemImage: "quote.opening")
                    .accessibilityAddTraits(.isHeader)
                BookText(review, of: book)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var page: some View {
        CardStockSheet(cornerRadius: 2) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your review")
                    .font(.detailsFieldLabel)
                    .foregroundStyle(Stationery.labelInk)
                    .accessibilityAddTraits(.isHeader)
                BookText(review, of: book)
                    .bookHeading()
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .overlay(alignment: .topLeading) {
                        Text("\u{201C}")
                            .font(.system(size: 44, design: .serif))
                            .foregroundStyle(Stationery.labelInk.opacity(0.55))
                            .offset(x: -24, y: -12)
                            .accessibilityHidden(true)
                    }
            }
            .padding(.leading, 40)
            .padding(.trailing, 44)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            Ribbon()
                .frame(width: 12)
                .padding(.trailing, 18)
                .padding(.bottom, -18)
        }
        .padding(.bottom, 18)
        .accessibilityElement(children: .combine)
    }
}

/// A card with one fact, with an optional detail under it.
private struct FactCard: View {
    let title: String
    let systemImage: String
    let value: String
    var detail: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                caption(title, systemImage: systemImage)
                Text(value).font(.title3.weight(.semibold))
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(CardNote())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The glass **Series** card: the series the book's label names and the book's place in it.
/// Selecting it opens **Series** (`SeriesButton`).
private struct SeriesCard: View {
    let series: SeriesMembership

    var body: some View {
        SeriesButton { opens in
            FactCard(
                title: "Series", systemImage: "books.vertical", value: series.name,
                detail: SeriesDesigns.place(in: series)
            )
            .overlay(alignment: .topTrailing) {
                if opens {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CardNote())
                        .padding(16)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// The sheet the book's details show, which a button on a card sets. A sheet takes the
    /// environment of the view it is attached to, so the details attach it: attached on a catalog
    /// card, its text and buttons would take the card's ink.
    @Entry fileprivate var detailSheet: Binding<BookDetailView.DetailSheet?> = .constant(nil)
    /// Whether the book's **Series** opens (`SeriesEntry.opensSeries(of:infos:library:)`).
    @Entry fileprivate var opensSeries = true
}

/// A button that opens **Series** (`SeriesSheet`), which lists the book's series, each opening
/// its books in order, with a check button that picks the series the book's label names. The
/// glass **Series** card and the catalog card's **Series** row are its label, which shows a
/// chevron only when `opens`. A book with nothing more to list shows the label alone
/// (`SeriesEntry.opensSeries(of:infos:library:)`).
private struct SeriesButton<Label: View>: View {
    @ViewBuilder let label: (_ opens: Bool) -> Label

    @Environment(\.detailSheet) private var sheet
    @Environment(\.opensSeries) private var opens

    var body: some View {
        if opens {
            button
        } else {
            label(false)
        }
    }

    private var button: some View {
        Button {
            sheet.wrappedValue = .series
        } label: {
            label(true)
        }
        .buttonStyle(.plain)
        #if os(macOS)
            .pointerStyle(.link)
        #endif
        .accessibilityHint("Shows the book's series and the books in it.")
        #if DEBUG
            // `-BookwormsSeriesSheet YES` opens the sheet, for Simulator and Mac checks.
            .onAppear {
                if UserDefaults.standard.bool(forKey: "BookwormsSeriesSheet") {
                    sheet.wrappedValue = .series
                }
            }
        #endif
    }
}

/// The **Details** catalog card: the book's facts, then the reader's status and format, then the
/// genres, each a printed field with a handwritten entry. A fact that is missing has no row. The
/// **Series** row opens **Series** (`SeriesButton`). VoiceOver reads each row as one element,
/// such as "Published, 1993".
private struct DetailsCatalogCard: View {
    let fields: [DetailCard]
    let book: CloudBook

    var body: some View {
        CatalogCard("Details") {
            ForEach(fields, id: \.gridID) { row($0) }
        }
    }

    @ViewBuilder private func row(_ field: DetailCard) -> some View {
        switch field {
        case .series(let series):
            let place = SeriesDesigns.place(in: series)
            SeriesButton { opens in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CatalogRow("Series") {
                        VStack(alignment: .leading, spacing: 0) {
                            HandText(series.name)
                            if let place {
                                HandText(place, hand: .note, tilt: tilt(1))
                            }
                        }
                    }
                    if opens {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Stationery.labelInk)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .accessibilityLabel("Series")
            .accessibilityValue([series.name, place].compactMap(\.self).joined(separator: ", "))
        case .published(let year):
            entry("Published", String(year), tilt: tilt(2))
        case .length(let pages):
            entry("Length", pages, tilt: tilt(3))
        case .status(let progress):
            let read = progress.map {
                "\($0.formatted(.percent.precision(.fractionLength(0)))) read"
            }
            entry("Status", ["Reading now", read].compactMap(\.self).joined(separator: ", "))
        case .format(let format, let length):
            entry("Read as", [format, length].compactMap(\.self).joined(separator: ", "))
        case .genres(let genres):
            entry("Genres", genres.joined(separator: ", "))
        default:
            EmptyView()
        }
    }

    /// A field's handwritten entry, off level by `tilt` while it fits on one line (`HandText`).
    private func entry(_ label: String, _ value: String, tilt: HandText.Tilt? = nil) -> some View {
        CatalogRow(label, spoken: value) { HandText(value, tilt: tilt) }
    }

    private func tilt(_ salt: UInt64) -> HandText.Tilt { .init(book: book.id, salt: salt * 10) }
}

/// The description, cut to six lines, with **More** to show the rest in place when it runs
/// longer. A hidden copy at full height detects whether the six lines cut it off. On a catalog
/// card, it is written by hand on the rules.
private struct AboutCard: View {
    let text: String
    let book: CloudBook

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.paperType) private var paper
    @State private var isExpanded = false
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        let isCut = !isExpanded && fullHeight > shownHeight + 1
        Group {
            if paper != nil {
                CatalogCard("About") {
                    description
                        .handFont(.entry)
                        .foregroundStyle(Stationery.penInk)
                        .ruled(.entry)
                    if isCut {
                        more
                            .underline()
                            .handFont(.note)
                            .foregroundStyle(Stationery.penInk)
                            .buttonStyle(.plain)
                            #if os(macOS)
                                .pointerStyle(.link)
                            #endif
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .ruled(.note)
                    }
                }
            } else {
                Card {
                    caption("About", systemImage: "text.alignleft")
                    description
                    if isCut { more.font(.subheadline.weight(.semibold)) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The text, and the hidden copy at full height, both in the font the card sets.
    private var description: some View {
        BookText(text, of: book)
            .lineLimit(isExpanded ? nil : 6)
            .textSelection(.enabled)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                shownHeight = $0
            }
            .background(alignment: .topLeading) {
                if !isExpanded {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            fullHeight = $0
                        }
                }
            }
    }

    private var more: some View {
        Button("More") {
            withAnimation(reduceMotion ? nil : .smooth) { isExpanded = true }
        }
    }
}

/// Hardcover readers' average rating, with stars, the number of ratings, and bars for the
/// readers who gave each rating, with the reader's own rating marked. A wide card puts the bars
/// beside the average, except at accessibility text sizes. A catalog card writes the average and
/// count by hand and draws the bars in pen (`RatingChart`); glass draws them as solid bars, the
/// reader's in gold (`RatingBars`).
private struct RatingCard: View {
    let average: Double
    let count: Int
    let counts: [Int]?
    let yours: Double?
    let isWide: Bool
    /// The book, whose ID sets the slant of the handwritten average and the course of the
    /// chart's pen.
    let bookID: Int

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.paperType) private var paper

    var body: some View {
        let ratings = count == 1 ? "1 rating" : "\(count.formatted()) ratings"
        let figure = average.formatted(.number.precision(.fractionLength(1)))
        let layout =
            isWide && !typeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 20))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        Group {
            if let paper {
                let slant = (ShareStyle.unit(0, bookID, 40) - 0.5) * 1.6
                CatalogCard("Readers' rating") {
                    layout {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.handFigure(figure, paper: paper))
                                .font(paper[.figure].font)
                                .rotationEffect(.degrees(slant), anchor: .leading)
                            RatingStars(rating: average, tint: Stationery.penInk).font(.body)
                            // The hand's final "s" reaches past its advance.
                            Text(HandText.roomy(ratings)).font(paper[.note].font)
                        }
                        .foregroundStyle(Stationery.penInk)
                        .fixedSize()
                        if let counts { RatingChart(counts: counts, yours: yours, bookID: bookID) }
                    }
                    .padding(.top, 8)
                }
            } else {
                Card {
                    caption("Readers' rating", systemImage: "person.2")
                    layout {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(figure).font(.largeTitle.weight(.semibold))
                            RatingStars(rating: average).font(.footnote)
                            Text(ratings).font(.footnote).foregroundStyle(CardNote())
                        }
                        if let counts { RatingBars(counts: counts, yours: yours) }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readers' rating")
        .accessibilityValue(
            ["\(figure) out of 5, from \(ratings)", yours.map { "your rating \($0.formatted())" }]
                .compactMap(\.self).joined(separator: ", "))
    }

    /// The average spaced for the hand. Text draws only within its bounds, and Caveat's digits
    /// reach up to 0.09 em past their advance, so the last digit gets 0.12 em of room, or its
    /// stroke is cut off. Caveat also sets the decimal separator against the digit before it and
    /// about 0.16 em from the one after, which reads as "4. 1", so kerning moves the separator
    /// toward the middle. Noteworthy needs only `HandText.roomy`'s usual room.
    private static func handFigure(_ figure: String, paper: PaperType) -> AttributedString {
        let size = paper[.figure].size
        guard paper.face != nil else { return HandText.roomy(figure) }
        let separator = figure.firstIndex { !$0.isNumber }
        return figure.indices.reduce(into: AttributedString()) { text, index in
            var character = AttributedString(String(figure[index]))
            if index == separator {
                character.kern = -0.1 * size
            } else if figure.index(after: index) == separator {
                character.kern = 0.05 * size
            } else if figure.index(after: index) == figure.endIndex {
                character.kern = 0.12 * size
            }
            text += character
        }
    }
}

/// One bar for each half-star rating, from half a star on the left to five stars on the right,
/// as tall as its share of the most common rating.
private struct RatingBars: View {
    let counts: [Int]
    let yours: Double?

    var body: some View {
        let most = CGFloat(max(1, counts.max() ?? 0))
        let yourIndex = yours.map { Int(($0 * 2).rounded()) - 1 }
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(counts.indices, id: \.self) { index in
                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                        .fill(
                            index == yourIndex
                                ? AnyShapeStyle(ShelfPalette.gold)
                                : AnyShapeStyle(CardNote().opacity(0.5))
                        )
                        // A sliver marks a rating that no reader gave.
                        .frame(height: max(2, 44 * CGFloat(counts[index]) / most))
                }
            }
            .frame(height: 44, alignment: .bottom)
            HStack {
                Text("½")
                Spacer()
                Text("5")
            }
            .font(.caption2)
            .foregroundStyle(CardNote())
        }
        .accessibilityHidden(true)
    }
}

/// The readers' ratings drawn by hand in pen on a catalog card: one outlined, hatched bar for
/// each half-star rating, from half a star on the left to five stars on the right, as tall as its
/// share of the most common rating, and a dash on the baseline for a rating no reader gave. The
/// reader's own rating is drawn in red pencil, with "you" written above the bars and an arrow
/// down to it. Every line comes from a `HandPen` that the book and the bar decide: each side of
/// a bar is its own stroke, so its corners cross or stay open, and the hatch, about 45 degrees
/// and 4 points apart, varies a little in spacing, angle, and where its lines stop. The canvas
/// draws again only when its size, the ratings, or the contrast settings change, so scrolling
/// moves a finished image.
struct RatingChart: View {
    let counts: [Int]
    let yours: Double?
    let bookID: Int

    @Environment(\.paperType) private var paper
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let paper = paper ?? defaultPaper
        let note = paper[.note]
        let isEven = contrast == .increased || reduceTransparency
        VStack(spacing: 2) {
            Canvas { context, size in
                draw(in: &context, size: size, rule: paper.rule, note: note, isEven: isEven)
            }
            .frame(height: 1.9 * paper.rule)
            HStack {
                Text("½")
                Spacer()
                // The hand's "5" reaches past its advance.
                Text(HandText.roomy("5"))
            }
            .font(note.font)
            .foregroundStyle(Stationery.penInk)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func draw(
        in context: inout GraphicsContext, size: CGSize, rule: CGFloat, note: PaperType.Metrics,
        isEven: Bool
    ) {
        let columns = Self.columns(of: counts, in: size, rule: rule)
        let yourIndex = yours.map { Int(($0 * 2).rounded()) - 1 }
        // The bounds of each stroke of the other ratings' ink, which the arrow keeps clear of. A
        // stroke's own bounds, rather than its bar's, let an arrow pass near a stroke that runs
        // past its corner.
        var others = Path()
        for (index, column) in columns.enumerated() {
            let ink = index == yourIndex ? Stationery.red : Stationery.penInk
            var pen = HandPen(book: bookID, salt: UInt64(index), isEven: isEven)
            guard counts[index] > 0 else {
                let y = column.maxY - 0.75
                // A quick dash, a point short of the column at each end, which stays clear of its
                // neighbors' ink.
                let dash = pen.line(
                    from: CGPoint(x: column.minX + 1, y: y),
                    to: CGPoint(x: column.maxX - 1, y: y), width: 1.7, slop: 0.5)
                context.fill(dash, with: .color(ink.opacity(isEven ? 1 : 0.8)))
                if index != yourIndex { others.addRect(dash.boundingRect) }
                continue
            }
            let bar = column.insetBy(dx: 0.6, dy: 0.6)
            // Up the left side, across the top, down the right side, and back along the bottom.
            let corners = [
                CGPoint(x: bar.minX, y: bar.maxY), CGPoint(x: bar.minX, y: bar.minY),
                CGPoint(x: bar.maxX, y: bar.minY), CGPoint(x: bar.maxX, y: bar.maxY),
            ]
            var outline = Path()
            for (corner, next) in zip(corners, corners.dropFirst() + corners.prefix(1)) {
                let side = pen.line(from: corner, to: next, width: 1.4)
                outline.addPath(side)
                if index != yourIndex { others.addRect(side.boundingRect) }
            }
            // The hatch's angle drifts from line to line, up to 4 degrees off 45, so neighbors
            // stay nearly parallel.
            var hatch = Path()
            var tilt = (pen.unit() - 0.5) * 5
            var start = -1.12 * bar.height - 4
            while start < bar.width + 4 {
                tilt = min(4, max(-4, tilt + (pen.unit() - 0.5) * 1.6))
                let angle = Angle.degrees(45 + tilt)
                let through = CGPoint(x: bar.minX + start, y: bar.maxY)
                let direction = CGSize(width: cos(angle.radians), height: -sin(angle.radians))
                if let (from, to) = Self.clip(through, direction, to: bar) {
                    hatch.addPath(pen.line(from: from, to: to, width: 1.15, slop: 0.5))
                }
                start += 4 + (pen.unit() - 0.5) * 1.6
            }
            // The hatch and dashes are lighter than the outlines, except with Increase Contrast
            // or Reduce Transparency, which draw every line in full ink.
            context.fill(hatch, with: .color(ink.opacity(isEven ? 1 : 0.75)))
            context.fill(outline, with: .color(ink))
            if index != yourIndex { others.addRect(hatch.boundingRect) }
        }
        guard let yourIndex, columns.indices.contains(yourIndex) else { return }
        let label = context.resolve(Text("you").font(note.font).foregroundStyle(Stationery.red))
        let pointer = Self.pointer(
            to: yourIndex, of: columns, clearOf: others, label: label.measure(in: size),
            note: note, in: size,
            pen: HandPen(book: bookID, salt: UInt64(counts.count), isEven: isEven))
        context.fill(pointer.arrow, with: .color(Stationery.red))
        context.drawLayer { layer in
            layer.concatenate(pointer.word)
            layer.draw(
                label, at: .zero,
                anchor: UnitPoint(x: pointer.side < 0 ? 1 : 0, y: note.ascent / note.lineHeight))
        }
    }

    /// Room inside the canvas, which cuts off ink past its edges, for lines that stray. No
    /// rating's ink reaches this far past its column: a bar sits 0.6 points inside its column,
    /// and its outline, 1.4 points wide, strays up to 3 points past the bar
    /// (`HandPen.maxWobble`, `HandPen.maxOvershoot`). A dash and the hatch stray less.
    nonisolated static let margin = max(HandPen.maxWobble, HandPen.maxOvershoot) + 1

    /// Each rating's column in a chart `size` big on `rule`-point rules: the rectangle its bar
    /// fills, as tall as its share of the most common rating, or, for a rating no reader gave,
    /// the strip along the baseline that its dash crosses. The tallest bar leaves room above it
    /// for "you" and the top of its arrow.
    nonisolated static func columns(of counts: [Int], in size: CGSize, rule: CGFloat) -> [CGRect] {
        let baseline = size.height - margin
        let reserved = 0.65 * rule + 10
        let most = CGFloat(max(1, counts.max() ?? 0))
        let gap: CGFloat = 4
        let width =
            (size.width - 2 * margin - gap * CGFloat(counts.count - 1)) / CGFloat(counts.count)
        return counts.enumerated()
            .map { index, count in
                let height = count > 0 ? max(3, (baseline - reserved) * CGFloat(count) / most) : 1.5
                return CGRect(
                    x: margin + CGFloat(index) * (width + gap), y: baseline - height, width: width,
                    height: height)
            }
    }

    /// "you" and its arrow down to the reader's rating
    /// (`pointer(to:of:clearOf:label:note:in:pen:)`).
    struct Pointer {
        /// How far to the side of the tip the arrow starts, negative for left of it. The word
        /// goes on the same side, past the arrow's tail.
        let side: CGFloat
        /// The arrow's shaft and head.
        let arrow: Path
        /// Moves the word from the origin, at the end of its baseline nearer the arrow, into
        /// place along the top of the chart, slanting up 3 degrees.
        let word: CGAffineTransform
        /// The word's extent, which keeps clear of the arrow and inside the chart: its lowercase
        /// letters and descenders, with room for the hand's overhang at the far end and, at the
        /// end nearer the arrow, for the overhang beside the shaft.
        let wordBox: Path
        /// Whether the arrow's course keeps its distance from the other bars and its ink keeps
        /// clear of theirs.
        let isClear: Bool
    }

    /// "you", written along the top of a chart `size` big, above every bar, and an arrow drawn
    /// with `pen` from beside the word down to the reader's rating, the column at `index` of
    /// `columns`. `others` covers the other ratings' ink, and `label` is the size of the word in
    /// `note`'s hand. The arrow slants about 25 degrees when its course keeps 4 points from the
    /// other bars and its ink, head included, keeps clear of `others`; otherwise it drops nearly
    /// straight inside the bar's own column. The word goes left of the arrow, so it reads as
    /// "you" and then the arrow, unless it would run off the chart or only the right side leaves
    /// room for the arrow. The word's advance ends 2 points short of the arrow's tail, and a
    /// shaft that strays toward it pushes it along its baseline, so the word never touches the
    /// arrow; `columns` leaves it room above every bar. When every arrow would cross another
    /// rating's ink, as in a narrow chart, the most upright one does. In a chart too narrow to
    /// write the word beside any arrow, the steep arrow on the roomier side points to the rating
    /// anyway, and the word runs off the chart.
    nonisolated static func pointer(
        to index: Int, of columns: [CGRect], clearOf others: Path, label: CGSize,
        note: PaperType.Metrics, in size: CGSize, pen: HandPen
    ) -> Pointer {
        let column = columns[index]
        // The hand's lowercase letters stand at most 0.55 em above the baseline, as Noteworthy's
        // "you" does; Caveat's stands 0.4 em.
        let lowercase = 0.55 * note.size
        let baseline = lowercase + 2
        let tip = CGPoint(x: column.midX, y: column.minY - 4)
        let tailY = baseline - 0.25 * note.size
        let barb = max(4, 0.28 * note.size)
        // Room at the far end of the word for the hand's overhang: Caveat Bold, for Bold Text,
        // reaches up to 0.077 em past the advance with its "u" and 0.068 em with its "y", and
        // Caveat Medium up to 0.062 and 0.055 em. Noteworthy stays within its advance.
        let room = 0.08 * note.size
        let slanted = 0.45 * (tip.y - tailY)
        let steep = 0.3 * column.width
        // Each other rating's surroundings: its column grown to 4 points around the bar, which
        // stands 0.6 points inside the column.
        var nearby = columns.map { $0.insetBy(dx: -3.4, dy: -3.4) }
        nearby.remove(at: index)
        let placements = [-slanted, slanted, -steep, steep]
            .map { side -> Pointer in
                let tail = CGPoint(x: tip.x + side, y: tailY)
                var pen = pen
                var arrow = pen.line(from: tail, to: tip, width: 1.4, slop: 0.3)
                // The head: two strokes into the tip, each about 29 degrees off the shaft.
                let back = atan2(tail.y - tip.y, tail.x - tip.x)
                for turn in [-0.5, 0.5] {
                    let end = CGPoint(
                        x: tip.x + barb * cos(back + turn), y: tip.y + barb * sin(back + turn))
                    arrow.addPath(pen.line(from: end, to: tip, width: 1.4, slop: 0.3))
                }
                // The word's advance ends 2 points short of the tail.
                let word = CGAffineTransform(
                    translationX: tail.x + (side < 0 ? -2 : 2), y: baseline
                )
                .rotated(by: -.pi / 60)
                // The word's extent in its own frame, where it runs from its end at the origin
                // away from the arrow: its lowercase letters above the baseline and its
                // descenders below, each with `room` at the far end. At the near end, each leaves
                // room for the overhang beside the shaft, which starts 0.25 em above the baseline
                // and runs away from the word. Above the baseline, the "u" reaches up to 0.06 em
                // past the advance in Caveat Bold and 0.045 em in Medium; only its top, above the
                // shaft's start, reaches farther. The "y" stays within the advance above the
                // baseline, but its descender reaches 0.07 em past it, and a steep shaft is still
                // close beside it there.
                func band(top: CGFloat, height: CGFloat, near: CGFloat) -> CGRect {
                    let near = near * note.size
                    return CGRect(
                        x: side < 0 ? -label.width - room : -near, y: top,
                        width: label.width + room + near, height: height)
                }
                let bands = [
                    band(top: -lowercase, height: lowercase, near: side < 0 ? 0.06 : 0),
                    band(top: 0, height: note.descent, near: side < 0 ? 0 : 0.07),
                ]
                // A shaft that strays toward the word pushes it along its baseline until each
                // band keeps a tenth of a point from the shaft's ink beside it, so they don't
                // touch at the edge.
                let ink = arrow.applying(word.inverted()).cgPath
                let pushes = bands.map { band -> CGFloat in
                    let beside =
                        ink.intersection(
                            CGPath(rect: band.insetBy(dx: -3 * size.width, dy: 0), transform: nil)
                        )
                        .boundingBoxOfPath
                    guard !beside.isNull else { return 0 }
                    return side < 0
                        ? min(0, beside.minX - 0.1 - band.maxX)
                        : max(0, beside.maxX + 0.1 - band.minX)
                }
                let placed = CGAffineTransform(
                    translationX: side < 0 ? pushes.min()! : pushes.max()!, y: 0
                )
                .concatenating(word)
                let box = Path { $0.addRects(bands) }.applying(placed)
                // The course, the straight line from the tail to the tip, keeps clear of every
                // other bar's surroundings at 17 points along it. Between them it may cut a
                // corner; the ink test still keeps the arrow off the other ratings' ink.
                let course = (0...16)
                    .map { step in
                        let t = CGFloat(step) / 16
                        return CGPoint(
                            x: tail.x + (tip.x - tail.x) * t, y: tail.y + (tip.y - tail.y) * t)
                    }
                return Pointer(
                    side: side, arrow: arrow, word: placed, wordBox: box,
                    isClear: !course.contains { point in nearby.contains { $0.contains(point) } }
                        && !arrow.cgPath.intersects(others.cgPath))
            }
        let fitting = placements.filter {
            $0.wordBox.boundingRect.minX >= 0 && $0.wordBox.boundingRect.maxX <= size.width
        }
        return fitting.first(where: \.isClear)
            ?? fitting.min { abs($0.side) < abs($1.side) }
            ?? placements[tip.x > size.width / 2 ? 2 : 3]
    }

    /// The part inside `rect` of the line through `point` in `direction`, or `nil` when less
    /// than a point of it lies inside.
    private static func clip(_ point: CGPoint, _ direction: CGSize, to rect: CGRect)
        -> (CGPoint, CGPoint)?
    {
        var low = -CGFloat.infinity
        var high = CGFloat.infinity
        for (origin, step, minimum, maximum) in [
            (point.x, direction.width, rect.minX, rect.maxX),
            (point.y, direction.height, rect.minY, rect.maxY),
        ] {
            let (a, b) = ((minimum - origin) / step, (maximum - origin) / step)
            low = max(low, min(a, b))
            high = min(high, max(a, b))
        }
        guard high - low > 1 else { return nil }
        func at(_ distance: CGFloat) -> CGPoint {
            CGPoint(
                x: point.x + direction.width * distance, y: point.y + direction.height * distance)
        }
        return (at(low), at(high))
    }
}

/// Up to three genres as tags: in one line, or two and then one when they do not fit across, or
/// one a line.
private struct GenresCard: View {
    let genres: [String]

    var body: some View {
        Card {
            caption("Genres", systemImage: "tag")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { tags(genres) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { tags(genres.prefix(2)) }
                    HStack(spacing: 8) { tags(genres.dropFirst(2)) }
                }
                VStack(alignment: .leading, spacing: 8) { tags(genres) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tags(_ genres: some RandomAccessCollection<String>) -> some View {
        ForEach(Array(genres), id: \.self) { genre in
            Text(genre)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.1), in: .capsule)
        }
    }
}

/// The **Spine design** card, which closes the details: the spine lying on its side, the book's
/// series choices (`SeriesRows`), the design's font, and its colors, which the reader can change,
/// with **Redesign spine** and **Change cover**. It doesn't name the model that made the design,
/// which shows only in the Spines tab (`GenerationView`).
///
/// Each color opens the system color picker: on the iPhone in a sheet (`ColorPickerPresenter`),
/// and on the Mac from an inline color well, which opens the Colors panel. The card's spine shows
/// picked colors at once. The rest of the app shows them, and the library's store saves them, one
/// second after the last change or when the card leaves (`AppModel.recolor(_:to:)`), so dragging
/// in the picker neither redraws 3D textures nor writes to iCloud for each frame. Colors whose
/// text and background contrast less than 4.5:1 show only here, with a note, and are never saved.
/// Each save registers its undo as the library shows the new colors. A color that differs from
/// the generator's has a reset (`ColorResetButton`), which sets only that color back and saves it
/// at once.
///
/// The **Font** row opens the font picker in a sheet (`FontPicker`), which saves each pick at once.
///
/// On the iPhone, the font picker's sheet covers the lower half of the screen, and the color
/// picker's is as tall as the picker's content, down to its current and saved colors, or half
/// the screen, which the reader can lower it to. While a sheet shows, the card adds room below
/// itself and scrolls its heading to the top of the details. While a color picker shows, the
/// card holds only the spine, shrunk beside a small copy of the cover for the picker's
/// eyedropper, the contrast note, if any, in one line, and the row of the color being picked,
/// with its reset. At the default text size on an iPhone 17 Pro, those fit above the taller
/// sheet; where they don't, as on the iPhone SE, the sheet opens at half height. The picker
/// closes when the reader leaves the card: when the details start to leave or open a sheet of
/// their own, or the tab changes.
private struct SpineDesignCard: View {
    let book: CloudBook
    /// The look of the saved design, as the rest of the app shows it.
    let look: SpineLook
    let design: SpineDesignV1?
    /// The generator's colors, which each color's reset restores
    /// (`AppModel.generatedColors(for:)`).
    let generated: SpineColors?
    /// The series source whose design `book` shares, or `nil` when the design is its own.
    let series: CloudBook?
    /// The book's cover, which shows beside the spine while a color picker shows.
    let cover: UIImage?
    /// Whether the card offers **Redesign spine**, which the details offer elsewhere after a
    /// cover change.
    let offersRedesign: Bool
    /// Whether a color picker can show: the details take input, a host's book has landed in
    /// them, and they show no sheet of their own.
    let canPick: Bool
    /// VoiceOver's focus on the card's heading, which showing the spine design sets.
    let headingFocus: AccessibilityFocusState<Bool>.Binding
    /// Opens **Change cover**.
    let changeCover: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.paperType) private var paper
    @Environment(\.undoManager) private var undoManager
    /// Picked colors that the library does not show yet, or that it shows but has not saved.
    @State private var draft: SpineColors?
    /// The colors of the newest save that iCloud has not answered yet.
    @State private var saving: SpineColors?
    @State private var saveError: String?
    /// The picker that shows, if any.
    @State private var sheet: CardSheet?
    /// The font picker's height.
    @State private var fontDetent = PresentationDetent.medium
    /// When the reader last tapped **Redesign spine** here, until a new design arrives.
    @State private var redesignedAt: Date?
    /// The width the card offers the spine's row, which caps the spine's length.
    @State private var rowWidth = BookFactory.spineLength
    /// The height from the card's top through the picked color's row, which the color picker's
    /// sheet leaves room for.
    @State private var pickingHeight: CGFloat = 0

    /// The card, which the details scroll to the top while a picker's sheet shows, and the
    /// coordinate space of its rows.
    nonisolated private static let cardID = "spine-design-card"
    /// The spine's scale while a color picker shows.
    private static let pickingScale: CGFloat = 0.75
    /// The height of the cover beside the spine while a color picker shows: the thickest
    /// spine's height at `pickingScale`.
    private static let pickingCoverHeight: CGFloat = 72

    private var saved: SpineColors { Self.colors(of: look) }

    /// The color whose picker shows, if any.
    private var picking: ColorRole? {
        if case .color(let role) = sheet { role } else { nil }
    }

    private static func colors(of look: SpineLook) -> SpineColors {
        SpineColors(background: look.background, foreground: look.foreground, accent: look.accent)
    }

    var body: some View {
        let shown = draft ?? saved
        let source = model.designSource(for: book)
        Group {
            #if os(macOS)
                // The Mac picks colors with color wells, so its only sheet is the font picker.
                card(shown: shown).sheet(item: $sheet) { _ in fontPicker }
            #else
                pickerSheetHost(shown: shown)
            #endif
        }
        .task(id: draft) { await saveAfterPause() }
        .onDisappear(perform: saveOnLeaving)
        // A new design, such as a redesign from a new cover, replaces the colors being picked.
        // Recoloring a look sets its edit date, so the source's stored design tells instead; an
        // ordinary run's copy of the series look is no new design.
        .onChange(of: model.library?.designs[source.id]?.generatedAt) {
            guard model.library?.designs[source.id]?.isSeriesReuse != true else { return }
            draft = nil
            redesignedAt = nil
        }
        #if DEBUG
            .onAppear(perform: applyDebugColors)
            .task { await openDebugPicker() }
        #endif
    }

    #if os(iOS)
        /// The card, which makes room for the color or font picker's sheet and scrolls itself
        /// above it.
        private func pickerSheetHost(shown: SpineColors) -> some View {
            let isPicking = sheet != nil
            return ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    card(shown: shown)
                        .id(Self.cardID)
                        .coordinateSpace(.named(Self.cardID))
                    if isPicking {
                        Color.clear.containerRelativeFrame(.vertical)
                    }
                }
                .animation(.smooth, value: sheet)
                .onChange(of: isPicking) {
                    guard isPicking else { return }
                    withAnimation(.smooth) { proxy.scrollTo(Self.cardID, anchor: .top) }
                }
            }
            .background {
                // Closes the picker in the same update that takes the reader away, so a sheet
                // the details open can present.
                ColorPickerPresenter(
                    role: canPick ? picking : nil,
                    color: picking.map { shown[keyPath: $0.keyPath] }, room: pickingHeight
                ) { color in
                    if let picking { pick(color, for: picking) }
                } finish: {
                    sheet = nil
                }
            }
            .sheet(item: fontSheet) { _ in fontPicker }
            .onChange(of: canPick) { if !canPick { stopPicking() } }
            // Another tab keeps these details, but not the reader.
            .onChange(of: model.selectedTab) { stopPicking() }
            .onDisappear(perform: stopPicking)
        }

        /// Closes the color picker, if one shows.
        private func stopPicking() {
            if picking != nil { sheet = nil }
        }

        /// The font picker's sheet, which shows while `sheet` is `.font`.
        private var fontSheet: Binding<CardSheet?> {
            Binding(get: { sheet == .font ? .font : nil }, set: { sheet = $0 })
        }
    #endif

    private var fontPicker: some View {
        FontPicker(book: book)
            .preferredColorScheme(.dark)
            .presentationSizing(.form)
            .presentationDetents([.medium, .large], selection: $fontDetent)
    }

    /// Shows `color` for `role` on the card's spine; it saves after a pause.
    private func pick(_ color: ColorValue, for role: ColorRole) {
        var colors = draft ?? saved
        colors[keyPath: role.keyPath] = color
        draft = colors
    }

    /// Saves the draft one second after the last change.
    private func saveAfterPause() async {
        guard let draft else { return }
        try? await Task.sleep(for: .seconds(1))
        if !Task.isCancelled { save(draft) }
    }

    /// Saves a draft as the card leaves. The card cannot report a failure once it is gone; the
    /// colors stay on screen until the next reload.
    private func saveOnLeaving() {
        if let draft { save(draft) }
    }

    @ViewBuilder private func card(shown: SpineColors) -> some View {
        if paper != nil {
            CatalogCard("Spine design", headingFocus: headingFocus) { rows(shown: shown) }
        } else {
            Card {
                Text("Spine design")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused(headingFocus)
                rows(shown: shown)
            }
        }
    }

    /// The card's contents, in order: the spine lying on its side, the book's series choices,
    /// the design's font, model, and colors, the buttons, and where the design comes from. While
    /// a color picker shows, only the spine, with the cover beside it, and that color's row.
    @ViewBuilder private func rows(shown: SpineColors) -> some View {
        let onPaper = paper != nil
        let length = min(BookFactory.spineLength, rowWidth)
        let scale = picking != nil && cover != nil ? Self.pickingScale : 1
        HStack(spacing: 12) {
            if picking != nil, let cover {
                Image(uiImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: Self.pickingCoverHeight)
                    .overlay {
                        if onPaper { PhotoCorners().fill(Stationery.photoCorner) }
                    }
                    .transition(.opacity)
            }
            // Beside the cover, a picture of the spine at its own length and thickness, shrunk
            // whole, so its lettering lays out as the saved spine's does.
            SpineView(book: book, look: look(with: shown))
                .frame(width: length, height: book.slabThickness)
                .scaleEffect(scale)
                .frame(width: length * scale, height: book.slabThickness * scale)
                .overlay {
                    if onPaper { PhotoCorners().fill(Stationery.photoCorner) }
                }
        }
        // The minimum makes the frame take the width it is offered, not a wider spine's, so the
        // spine's length follows the card's width rather than its own.
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            rowWidth = $0
        }
        .padding(.top, onPaper ? 10 : 0)
        .padding(.bottom, onPaper ? 12 : 0)
        .accessibilityHidden(true)
        // Under the spine, so the note shows above the picker's sheet, in one line while the
        // picker shows, which leaves room for the picked color's row.
        if design != nil, !shown.isReadable {
            note(
                picking != nil
                    ? "The text needs more contrast to save."
                    : "The text needs more contrast with the background. Choose a lighter or darker color to save.",
                systemImage: "exclamationmark.triangle")
        }
        if let picking {
            colors(shown: shown, only: picking)
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .named(Self.cardID)).maxY
                } action: {
                    pickingHeight = $0
                }
        } else {
            details(shown: shown)
        }
    }

    /// The card's rows under the spine while no color picker shows.
    @ViewBuilder private func details(shown: SpineColors) -> some View {
        let onPaper = paper != nil
        SeriesRows(book: book)
        if let design {
            let family = design.fontFamily ?? design.typeface.capitalized
            if let paper {
                Button {
                    sheet = .font
                } label: {
                    CatalogRow("Font") {
                        Text(family)
                            .font(look.font(size: PaperType.Hand.entry.share * paper.rule))
                            .foregroundStyle(Stationery.ink)
                            .ruledRow()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Font")
                .accessibilityValue(family)
            } else {
                Button {
                    sheet = .font
                } label: {
                    CardRow("Font") { Text(family).font(look.font(size: 19)) }.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Font")
                .accessibilityValue(family)
                Divider()
            }
            colors(shown: shown)
            if shown.isReadable, let saveError {
                note(saveError, systemImage: "exclamationmark.icloud")
            }
        }
        // The redesign button can show a note in its place, which needs the width.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .padding(.vertical, onPaper ? 12 : 0)
        if let design {
            if !onPaper { Divider() }
            if let series {
                CardNoteText(
                    series.id == book.id
                        ? "Other books in this series share this design."
                        : "Books in this series share the design of \(series.spineTitle).")
            }
            // A redesigned series look dates from its redesign.
            let created =
                model.drawnLook(of: book).map { $0.remadeAt ?? $0.createdAt } ?? design.generatedAt
            if onPaper {
                CatalogRow(
                    "Created", spoken: created.formatted(date: .abbreviated, time: .omitted)
                ) {
                    Text(created.formatted(Self.stampFormat).uppercased())
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .foregroundStyle(Stationery.stampInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .rotationEffect(.degrees(-1.5))
                        .ruledRow()
                }
            } else {
                Text("Created \(created, format: .dateTime.year().month().day())")
                    .font(.footnote)
                    .foregroundStyle(CardNote())
            }
        }
    }

    /// A design's creation date as a stamp prints it, in this device's time zone, since it is a
    /// moment rather than a reading day.
    private static let stampFormat = Date.FormatStyle().day().month(.abbreviated).year()

    /// **Redesign spine**, unless the details offer it above the card after a cover change, and
    /// **Change cover**.
    @ViewBuilder private var buttons: some View {
        if offersRedesign, let design {
            RedesignButton(
                book: book, series: series != nil, design: design, requestedAt: $redesignedAt)
        }
        Button(
            series != nil ? "Change series cover" : "Change cover",
            systemImage: "photo.on.rectangle", action: changeCover
        )
        .detailsButtonStyle(book: book.id, salt: 81)
    }

    /// The design's colors, or only `role`'s, which open the color picker: on glass, swatches on
    /// the iPhone and color wells on the Mac; on a catalog card, a row for each color with its
    /// painted chip on the iPhone or its color well on the Mac, and its hex code written by hand.
    /// A color that differs from the generator's has a reset at its trailing edge.
    @ViewBuilder private func colors(shown: SpineColors, only role: ColorRole? = nil) -> some View {
        if let paper {
            ForEach(role.map { [$0] } ?? ColorRole.allCases) { role in
                let index = ColorRole.allCases.firstIndex(of: role) ?? 0
                let color = shown[keyPath: role.keyPath]
                let hex = Text(HandText.roomy(color.hex))
                    .handFont(.entry)
                    .foregroundStyle(Stationery.penInk)
                    .tilted(.init(book: book.id, salt: 60 + UInt64(index) * 10))
                #if os(macOS)
                    CatalogRow(role.name) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            ColorWell(role: role, color: color) { pick($0, for: role) }
                                .alignmentGuide(.firstTextBaseline) {
                                    $0[VerticalAlignment.bottom] - 2
                                }
                            hex
                        }
                        .ruled(.entry)
                    }
                    // Centered on the last rule's band, which holds the hex code at every size.
                    .overlay(alignment: .bottomTrailing) {
                        resetButton(role, shown: shown).frame(height: paper.rule)
                    }
                #else
                    Button {
                        sheet = .color(role)
                    } label: {
                        CatalogRow(role.name) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                PaintChip(color: color)
                                hex
                            }
                            .ruled(.entry)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(role.name) color")
                    .accessibilityValue(color.hex)
                    // Over the row's button rather than in its label, so it takes its own taps.
                    // Centered on the last rule's band, which holds the hex code at every size.
                    .overlay(alignment: .bottomTrailing) {
                        resetButton(role, shown: shown).frame(height: paper.rule)
                    }
                #endif
            }
        } else {
            #if os(macOS)
                ForEach(ColorRole.allCases) { role in
                    ColorWellRow(role: role, color: shown[keyPath: role.keyPath]) {
                        pick($0, for: role)
                    } reset: {
                        resetButton(role, shown: shown)
                    }
                }
            #else
                let alone = role != nil
                let swatches =
                    typeSize.isAccessibilitySize || alone
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top))
                swatches {
                    ForEach(role.map { [$0] } ?? ColorRole.allCases) { role in
                        Swatch(role: role, color: shown[keyPath: role.keyPath], isRow: alone) {
                            sheet = .color(role)
                        } reset: {
                            resetButton(role, shown: shown)
                        }
                    }
                }
            #endif
        }
    }

    /// The reset for `role` while `shown` differs from the generator's color for it, which sets
    /// that color back and saves it at once, with an undo of its own.
    @ViewBuilder private func resetButton(_ role: ColorRole, shown: SpineColors) -> some View {
        if let original = generated?[keyPath: role.keyPath],
            shown[keyPath: role.keyPath] != original
        {
            ColorResetButton(role: role, book: book.id) {
                var colors = draft ?? saved
                colors[keyPath: role.keyPath] = original
                draft = colors
                save(colors, action: "Reset \(role.name) Color")
            }
        }
    }

    private func look(with colors: SpineColors) -> SpineLook {
        var look = look
        look.background = colors.background
        look.foreground = colors.foreground
        look.accent = colors.accent
        return look
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(CardNote())
            .padding(.vertical, paper != nil && picking == nil ? 8 : 0)
    }

    /// Shows and saves readable `colors`, then clears the draft unless the reader has picked
    /// other colors since.
    ///
    /// The library shows the colors at once (`AppModel.recolor(_:to:)`), so the undo named
    /// `action` registers then, with the colors shown before, rather than when iCloud's save
    /// returns. The save runs in a task of its own, so a later pick or the card's leaving never
    /// cancels it. Colors the library already shows save again only after a failed save, and
    /// register no second undo.
    private func save(_ colors: SpineColors, action: String = "Change Color") {
        let before = Self.colors(of: model.look(for: book))
        guard colors.isReadable else { return }
        guard colors != before || saveError != nil else {
            // A pick back to the saved colors leaves nothing to save, and a draft kept for it
            // would save over later colors when the card leaves. A draft for colors still saving
            // stays until that save succeeds, so the card can retry it after a failure.
            if draft == colors, saving != colors { draft = nil }
            return
        }
        if colors != before {
            undoManager?
                .registerStyleChange(action) { [model, book] in
                    try await model.recolor(book, to: before)
                } redo: { [model, book] in
                    try await model.recolor(book, to: colors)
                }
        }
        saving = colors
        Task.immediate {
            defer { if saving == colors { saving = nil } }
            do {
                try await model.recolor(book, to: colors)
                saveError = nil
                if draft == colors { draft = nil }
            } catch {
                saveError = SpineWorker.iCloudMessage(for: error) ?? error.localizedDescription
                // A save that failed before the library showed the colors, or that reloaded the
                // library for another device's design, leaves the style undo history naming
                // colors the library no longer shows.
                if Self.colors(of: model.look(for: book)) != colors {
                    undoManager?.removeAllActions(withTarget: AppModel.shared)
                }
            }
        }
    }

    #if DEBUG
        @MainActor private static var appliedDebugColors = false

        /// Simulator hook: with `-BookwormsOpenBook <book ID>`,
        /// `-BookwormsSpineColors "RRGGBB,RRGGBB,RRGGBB"` picks those background, text, and accent
        /// colors for that book once per launch, as the color pickers would. An empty entry, as
        /// in `"RRGGBB,,"`, keeps that color.
        private func applyDebugColors() {
            let defaults = UserDefaults.standard
            guard !Self.appliedDebugColors, design != nil,
                defaults.string(forKey: "BookwormsOpenBook").flatMap(Int.init) == book.id,
                let hexes = defaults.string(forKey: "BookwormsSpineColors")?
                    .split(separator: ",", omittingEmptySubsequences: false),
                hexes.count == ColorRole.allCases.count
            else { return }
            var colors = saved
            for (role, hex) in zip(ColorRole.allCases, hexes) where !hex.isEmpty {
                guard let color = ColorValue(hex: "#\(hex.uppercased())") else { return }
                colors[keyPath: role.keyPath] = color
            }
            Self.appliedDebugColors = true
            draft = colors
        }

        @MainActor private static var openedDebugPicker = false

        /// Simulator hook: with `-BookwormsOpenBook <book ID>`, `-BookwormsFontPicker YES` opens
        /// that book's font picker once per launch, two seconds after the card appears
        /// (`FontPicker`), and `-BookwormsFontPicker large` opens it at full height. On the
        /// iPhone, `-BookwormsColorPicker <background|text|accent>` opens that color's picker
        /// instead.
        private func openDebugPicker() async {
            let defaults = UserDefaults.standard
            let font = defaults.string(forKey: "BookwormsFontPicker")
            #if os(iOS)
                let name = defaults.string(forKey: "BookwormsColorPicker")?.lowercased()
                let color = ColorRole.allCases.first { $0.name.lowercased() == name }
            #else
                let color: ColorRole? = nil
            #endif
            guard !Self.openedDebugPicker, design != nil,
                defaults.string(forKey: "BookwormsOpenBook").flatMap(Int.init) == book.id,
                color != nil || font == "large" || defaults.bool(forKey: "BookwormsFontPicker")
            else { return }
            Self.openedDebugPicker = true
            try? await Task.sleep(for: .seconds(2))
            if let color {
                sheet = .color(color)
            } else {
                if font == "large" { fontDetent = .large }
                sheet = .font
            }
        }
    #endif
}

/// The **Series** menu and the **Changes apply to** choice of a book's spine design, saved as the book's
/// `SeriesLinkV1` (`AppModel.setSeriesLink(for:linkedSeriesID:standsAlone:ownLook:)`).
///
/// **Series** chooses the series whose look the book draws and whose name its **Series** card
/// shows: by default its shortest series (`SeriesDesigns.styleSeries(of:link:)`), or another of
/// its Hardcover series, or none. It shows when the book has a series or a link. The check
/// buttons in `SeriesSheet` save the same choice. **Changes apply to** chooses whether
/// recoloring, including a color's reset, and **Redesign spine** change the series' look or only
/// this book, which then draws its own design. It shows when the book's look group has a saved look
/// or another book (`AppModel.choosesEditScope(for:)`). A choice shows at once and stays while it
/// saves; a failed save shows a toast and the saved choice again. The rows take no other choice
/// until a save ends, so saves never overlap and the last choice is the one iCloud keeps.
struct SeriesRows: View {
    /// A book's series choice, as the rows show it.
    struct Choice: Equatable {
        enum Series: Hashable {
            /// The book's shortest series.
            case standard
            case linked(Int)
            case alone
        }

        var series: Series
        var ownLook: Bool

        init(_ link: SeriesLinkV1?) {
            series =
                if link?.standsAlone == true {
                    .alone
                } else if let id = link?.linkedSeriesID {
                    .linked(id)
                } else {
                    .standard
                }
            ownLook = link?.ownLook == true
        }

        /// `book`'s choice once **Series** picks the series with `seriesID` (`SeriesSheet`): the
        /// book's shortest series restores the default, also for a book **Not in a series**, and
        /// **Changes apply to** stays.
        static func picking(_ seriesID: Int, for book: CloudBook) -> Choice {
            var choice = Choice(book.seriesLink)
            choice.series =
                seriesID == SeriesDesigns.styleSeries(of: book, link: nil)?.id
                ? .standard : .linked(seriesID)
            return choice
        }
    }

    let book: CloudBook

    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.paperType) private var paper
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The choice being saved, shown until the library has it.
    @State private var saving: Choice?
    /// Why the last choice wasn't saved, until a later choice saves.
    @State private var saveError: String?

    var body: some View {
        let choice = saving ?? Choice(book.seriesLink)
        var seen = Set<Int>()
        let memberships = (book.seriesMemberships ?? [])
            .filter { seen.insert($0.seriesID).inserted }
        if !memberships.isEmpty || book.seriesID != nil || book.seriesLink != nil {
            let series = Binding {
                choice.series
            } set: {
                var new = choice
                new.series = $0
                choose(new)
            }
            let options = Group {
                Text(standardTitle).tag(Choice.Series.standard)
                ForEach(memberships, id: \.seriesID) {
                    Text(Self.title(of: $0)).tag(Choice.Series.linked($0.seriesID))
                }
                // A link to a series that Hardcover no longer lists for the book.
                if case .linked(let id) = choice.series,
                    !memberships.contains(where: { $0.seriesID == id })
                {
                    Text("Linked series").tag(choice.series)
                }
                Text("Not in a series").tag(Choice.Series.alone)
            }
            let menu = menu(
                "Series", selection: series, title: title(of: choice.series, memberships)
            ) {
                options
            }
            .disabled(saving != nil)
            if paper != nil {
                CatalogRow("Series") { menu }
            } else {
                CardRow("Series") { menu }
            }
        }
        if model.choosesEditScope(for: book) {
            let ownLook = Binding {
                choice.ownLook
            } set: {
                var new = choice
                new.ownLook = $0
                choose(new)
            }
            let options = Group {
                Text("Whole series").tag(false)
                Text("This book only").tag(true)
            }
            if paper != nil {
                checkboxes(ownLook: ownLook)
            } else {
                CardRow("Changes apply to") {
                    Picker("Changes apply to", selection: ownLook) { options }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(saving != nil)
                } fallback: {
                    // At accessibility text sizes, the segments don't fit beside each other.
                    menu(
                        "Changes apply to", selection: ownLook,
                        title: choice.ownLook ? "This book only" : "Whole series"
                    ) { options }
                    .disabled(saving != nil)
                }
            }
        }
        // A note rather than a toast, because a Mac book window shows no toasts.
        if let saveError {
            Label(
                "Couldn't save the series choice. " + saveError,
                systemImage: "exclamationmark.icloud"
            )
            .font(.footnote)
            .foregroundStyle(CardNote())
            .padding(.vertical, paper != nil ? 8 : 0)
        }
    }

    /// **Changes apply to** on a catalog card: its printed name, then a check box for each
    /// choice, side by side, or one under the other at accessibility text sizes.
    private func checkboxes(ownLook: Binding<Bool>) -> some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 0))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Changes apply to")
                .font(.detailsFieldLabel)
                .foregroundStyle(Stationery.labelInk)
                .padding(.top, 10)
                .accessibilityHidden(true)
            layout {
                checkbox("Whole series", isOn: !ownLook.wrappedValue) {
                    ownLook.wrappedValue = false
                }
                checkbox("This book only", isOn: ownLook.wrappedValue) {
                    ownLook.wrappedValue = true
                }
            }
        }
        .disabled(saving != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes apply to")
    }

    private func checkbox(_ title: String, isOn: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isOn ? "checkmark.square" : "square")
                    .font(.body)
                    .accessibilityHidden(true)
                Text(HandText.roomy(title)).handFont(.entry)
            }
            .foregroundStyle(Stationery.penInk)
            .ruled(.entry)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(macOS)
            .pointerStyle(.link)
        #endif
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// A menu that chooses `selection` among `options` and shows `title`, the chosen option's
    /// name, which wraps. A menu-style picker letters its choice in a control of fixed height,
    /// so a long series name that wraps would overlap the rows below it. On a catalog card, the
    /// name is written by hand.
    @ViewBuilder
    private func menu<Value: Hashable, Options: View>(
        _ label: String, selection: Binding<Value>, title: String,
        @ViewBuilder options: () -> Options
    ) -> some View {
        let menu = Menu {
            Picker(label, selection: selection, content: options)
                .pickerStyle(.inline)
        } label: {
            if paper != nil {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(HandText.roomy(title)).multilineTextAlignment(.leading).handFont(.entry)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Stationery.penInk)
                .ruled(.entry)
                .contentShape(.rect)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title).multilineTextAlignment(.leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                // In the tint, as a menu-style picker letters its choice.
                .foregroundStyle(.tint)
            }
        }
        .accessibilityLabel(label)
        .accessibilityValue(title)
        #if os(macOS)
            if paper != nil {
                // Handwriting on the card, rather than in a pop-up button's bezel.
                menu
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .pointerStyle(.link)
            } else {
                menu
            }
        #else
            menu
        #endif
    }

    /// The name of `series`, the book's series choice, as its option in the **Series** menu.
    private func title(of series: Choice.Series, _ memberships: [SeriesMembership]) -> String {
        switch series {
        case .standard: standardTitle
        case .linked(let id):
            memberships.first { $0.seriesID == id }.map(Self.title(of:)) ?? "Linked series"
        case .alone: "Not in a series"
        }
    }

    /// "Default", with the name of the series the book draws without a link.
    private var standardTitle: String {
        SeriesDesigns.shownSeries(of: book, link: nil).map { "Default — \($0.name)" } ?? "Default"
    }

    private static func title(of series: SeriesMembership) -> String {
        switch series.size {
        case nil: series.name
        case 1: "\(series.name) (1 book)"
        case let size?: "\(series.name) (\(size) books)"
        }
    }

    private func choose(_ new: Choice) {
        let old = saving ?? Choice(book.seriesLink)
        // A choice the book already has, such as its checked box, saves nothing.
        guard new != old else { return }
        saving = new
        Task { [model, book, undoManager] in
            saveError = await Self.save(
                new, replacing: old, for: book, model: model, undoManager: undoManager)
            if saving == new { saving = nil }
        }
    }

    /// Saves `new` as `book`'s series choice and registers its undo, which restores `old`.
    ///
    /// - Returns: Why the save failed, for the caller to show, or `nil` once it succeeds.
    static func save(
        _ new: Choice, replacing old: Choice, for book: CloudBook, model: AppModel,
        undoManager: UndoManager?
    ) async -> String? {
        do {
            try await save(new, for: book, model: model)
            undoManager?
                .registerStyleChange("Change Series Choice") {
                    try await save(old, for: book, model: model)
                } redo: {
                    try await save(new, for: book, model: model)
                }
            return nil
        } catch {
            return SpineWorker.iCloudMessage(for: error) ?? error.localizedDescription
        }
    }

    private static func save(_ choice: Choice, for book: CloudBook, model: AppModel) async throws {
        var linked: Int?
        if case .linked(let id) = choice.series { linked = id }
        try await model.setSeriesLink(
            for: book, linkedSeriesID: linked, standsAlone: choice.series == .alone,
            ownLook: choice.ownLook)
    }
}

/// Pins the book to Top Five's pinned share image, or unpins it (`TopFivePins`). While five other
/// books are pinned, it is disabled and says where to unpin one. With catalog cards, it is a
/// stamp on a tag taped to the wall, restamped as it pins or unpins (`RestampButton`).
private struct TopFivePinButton: View {
    let bookID: Int
    @AppStorage(TopFivePins.key) private var pins = TopFivePins()
    @Environment(AppModel.self) private var model
    @Environment(\.paperType) private var paper

    var body: some View {
        let isPinned = pins.contains(bookID)
        VStack(spacing: 8) {
            let button = RestampButton(isPinned, stamped: paper != nil) {
                pins.toggle(bookID)
                Task { await model.syncTopFivePins() }
            } label: { pinned in
                Label(Self.title(pinned), systemImage: pinned ? "pin.slash" : "pin")
            }
            .accessibilityLabel(Self.title(isPinned))
            .detailsButtonStyle(book: bookID, salt: 83)
            .disabled(!isPinned && pins.isFull)
            if paper != nil { TapedTag { button } } else { button }
            if !isPinned && pins.isFull {
                Text(
                    "Five books are pinned. Unpin one under Share > Top Five > Pinned to pin this one."
                )
                .font(.footnote)
                .foregroundStyle(CardNote())
                .multilineTextAlignment(.center)
            }
        }
    }

    private static func title(_ pinned: Bool) -> LocalizedStringKey {
        pinned ? "Unpin from Top Five" : "Pin to Top Five"
    }
}

extension View {
    /// Prints the button as a rubber stamp (`StampButtonStyle`) with catalog cards, placed by
    /// `book` and `salt`, or keeps it bordered with glass cards.
    fileprivate func detailsButtonStyle(book: Int, salt: UInt64) -> some View {
        modifier(DetailsButtonStyle(book: book, salt: salt))
    }
}

private struct DetailsButtonStyle: ViewModifier {
    let book: Int
    let salt: UInt64
    @Environment(\.paperType) private var paper

    func body(content: Content) -> some View {
        if paper != nil {
            content.buttonStyle(StampButtonStyle(book: book, salt: salt))
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// **Redesign spine** for a book (`GenerationController.redesign(_:)`), or the run's progress
/// while one runs: with catalog cards, the same stamp, disabled but in full ink, reading
/// "Designing spines" beside a spinner in its ink. A run that ends after `requestedAt` while it is still set, because no new
/// design arrived, leaves a note with the run's error, for example after a quota stop or when
/// the cover did not load.
///
/// When this device's model ranks below the model that made `design`, the spine's current
/// design, a note takes the button's place and says what would let this device redesign it
/// (`SpineWorker.redesignAdvice(for:deviceTier:)`), leaving the model's name to the card's
/// **Model** row: a redesign here would replace a better model's design, which a run never does
/// (`SpineWorker.reconcile(mode:redesigning:)`). The reader's own model ranks with Private Cloud
/// Compute while it overrides it (`ModelTier.redesignRank(prefersBackup:)`). After a cover
/// change, `design` is `nil`, because the new cover is redesigned at any tier.
private struct RedesignButton: View {
    let book: CloudBook
    /// Whether the redesign changes the book's whole series.
    let series: Bool
    var design: SpineDesignV1? = nil
    /// When the reader asked for a new design, by this button or a new cover.
    @Binding var requestedAt: Date?

    @Environment(GenerationController.self) private var generation
    @Environment(\.paperType) private var paper

    #if DEBUG
        /// `-BookwormsDesigningSpines YES` shows the run's progress in place of every redesign
        /// button, for screenshots.
        private static let debugBusy = UserDefaults.standard.bool(
            forKey: "BookwormsDesigningSpines")
    #else
        private static let debugBusy = false
    #endif

    var body: some View {
        content.task {
            // The model status arrives when the Spines tab opens or a run starts.
            if design != nil, generation.status.model == nil {
                await generation.refreshModelStatus()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if generation.status.isRunning || Self.debugBusy {
            if paper != nil {
                Button {
                } label: {
                    Label {
                        Text("Designing spines")
                    } icon: {
                        StampSpinner()
                    }
                }
                .buttonStyle(StampButtonStyle(book: book.id, salt: 80, busy: true))
                .disabled(true)
            } else {
                LabeledContent("Designing spines") { ProgressView() }
            }
        } else if let design, let device = generation.status.model,
            device.tier.redesignRank(prefersBackup: SpineDesigner.overridesPrivateCloudCompute)
                < design.tier
        {
            Label(
                SpineWorker.redesignAdvice(for: design.tier, deviceTier: device.tier),
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(CardNote())
        } else {
            Button(series ? "Redesign spines" : "Redesign spine", systemImage: "wand.and.sparkles")
            {
                requestedAt = .now
                generation.redesign(book)
            }
            .detailsButtonStyle(book: book.id, salt: 80)
            if let lastRunAt = generation.status.lastRunAt, let requestedAt,
                lastRunAt > requestedAt
            {
                Label(
                    generation.status.error
                        ?? (series
                            ? "The last run did not redesign these spines."
                            : "The last run did not redesign this spine."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(CardNote())
            }
        }
    }
}

/// A picker that the **Spine design** card shows in a sheet: a color's, on the iPhone, or the
/// font picker.
private enum CardSheet: Hashable, Identifiable {
    case color(ColorRole)
    case font

    var id: Self { self }
}

/// A spine color the reader can change.
private enum ColorRole: CaseIterable, Identifiable {
    case background, text, accent

    var id: Self { self }

    var name: String {
        switch self {
        case .background: "Background"
        case .text: "Text"
        case .accent: "Accent"
        }
    }

    var keyPath: WritableKeyPath<SpineColors, ColorValue> {
        switch self {
        case .background: \.background
        case .text: \.foreground
        case .accent: \.accent
        }
    }
}

/// One design color: a button with its swatch, its role, and its hex value, which opens the
/// color picker.
///
/// A column for a row of three; alone, or at accessibility sizes, where a column breaks the
/// words, a row with the text beside the swatch.
private struct Swatch<Reset: View>: View {
    let role: ColorRole
    let color: ColorValue
    /// Whether the swatch stands alone, as a row, at every text size.
    var isRow = false
    let action: () -> Void
    /// The color's reset, if any, level with the swatch: beside it in a column, and at the
    /// row's trailing edge in a row.
    @ViewBuilder let reset: Reset

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let isRow = self.isRow || typeSize.isAccessibilitySize
        let layout =
            isRow ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 6))
        Button(action: action) {
            layout {
                Circle()
                    .fill(color.color)
                    .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    .frame(width: 40, height: 40)
                VStack(alignment: isRow ? .leading : .center, spacing: isRow ? 2 : 6) {
                    Text(role.name).font(.caption)
                    Text(color.hex).font(.caption.monospaced()).foregroundStyle(CardNote())
                }
            }
            .frame(maxWidth: .infinity, alignment: isRow ? .leading : .center)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(role.name) color")
        .accessibilityValue(color.hex)
        // Over the swatch's button rather than in its label, so it takes its own taps. In a
        // column, the swatch is centered, so the offset clears its 40-point circle.
        .overlay(alignment: isRow ? .trailing : .top) {
            reset.frame(height: 40).offset(x: isRow ? 0 : 42)
        }
    }
}

/// A small button that sets one design color back to the generator's: on a catalog card, a
/// circled arrow stamped in a date stamp's violet ink, with the stamps' uneven ink (`StampInk`),
/// struck a few degrees off level, and on glass, a plain symbol. Increase Contrast and Reduce
/// Transparency print solid ink. On the iPhone, its touch target is 44 points square around the
/// symbol; the card lays it over its row, so the target never makes the row taller.
private struct ColorResetButton: View {
    static let symbol = "arrow.counterclockwise.circle"

    let role: ColorRole
    /// The book whose stamps this one's tilt and ink vary with.
    let book: Int
    let action: () -> Void

    @Environment(\.paperType) private var paper
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let salt = 90 + UInt64(ColorRole.allCases.firstIndex(of: role) ?? 0)
        let glyph = Image(systemName: Self.symbol).font(.subheadline.weight(.semibold))
        Button(action: action) {
            Group {
                if paper == nil {
                    Image(systemName: Self.symbol).font(.body).foregroundStyle(CardNote())
                } else if contrast == .increased || reduceTransparency {
                    glyph.foregroundStyle(Stationery.stampInk)
                } else {
                    // The symbol lays out the button, and a canvas prints its ink: the arrow as a
                    // stamp's type and the circle as its frame.
                    let ink = Stationery.stampInk
                    let part = { (arrow: Color, circle: Color) in
                        glyph.symbolRenderingMode(.palette).foregroundStyle(arrow, circle)
                    }
                    glyph.foregroundStyle(.clear)
                        .background {
                            StampInk(
                                book: book, salt: salt, ink: ink, lightening: 1, line: 1.5,
                                inset: CGSize(width: 4, height: 4), type: part(ink, .clear),
                                frame: part(.clear, ink))
                        }
                }
            }
            .rotationEffect(
                .degrees(paper != nil ? (ShareStyle.unit(0, book, salt) - 0.5) * 10 : 0)
            )
            #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
            #endif
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset \(role.name) color")
        .help("Reset \(role.name) color")
    }
}

/// A design color painted on a catalog card: a small chip with a white border, as a paint
/// sample is.
private struct PaintChip: View {
    let color: ColorValue

    @Environment(\.paperType) private var paper

    var body: some View {
        // 26 by 18 points on 34-point rules, growing with the handwriting.
        let scale = (paper?.rule ?? 34) / 34
        let shape = RoundedRectangle(cornerRadius: 2)
        shape.fill(color.color)
            .overlay {
                shape.strokeBorder(
                    Color(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xEE / 255), lineWidth: 2.5)
            }
            .overlay { shape.strokeBorder(Stationery.ink.opacity(0.35), lineWidth: 0.5) }
            .frame(width: 26 * scale, height: 18 * scale)
            .accessibilityHidden(true)
    }
}

#if os(macOS)
    /// One design color on the Mac: its role, its hex value, an inline color well, which opens
    /// the Colors panel and reports each pick, without opacity, and the color's reset, if any.
    private struct ColorWellRow<Reset: View>: View {
        let role: ColorRole
        let color: ColorValue
        let pick: (ColorValue) -> Void
        @ViewBuilder let reset: Reset

        var body: some View {
            LabeledContent {
                HStack(spacing: 10) {
                    Text(color.hex).font(.callout.monospaced()).foregroundStyle(CardNote())
                    ColorWell(role: role, color: color, pick: pick)
                    // The reset's room stays, so the well holds still as the reset comes and goes.
                    ZStack {
                        Image(systemName: ColorResetButton.symbol).hidden()
                        reset
                    }
                }
            } label: {
                Text(role.name)
            }
        }
    }

    /// An inline color well for one design color, which opens the Colors panel and reports each
    /// pick, without opacity.
    private struct ColorWell: View {
        let role: ColorRole
        let color: ColorValue
        let pick: (ColorValue) -> Void

        var body: some View {
            ColorPicker(
                "\(role.name) color",
                selection: Binding(
                    get: { Color(uiColor: color.uiColor) }, set: { pick(ColorValue($0)) }),
                supportsOpacity: false
            )
            .labelsHidden()
        }
    }
#else
    /// Presents the system color picker, without opacity, for `role` while it is set, and reports
    /// each pick and the reader's close of the picker. A change to the card's color, such as a
    /// reset or an undo, shows in the picker.
    ///
    /// The picker hides itself for its eyedropper and then presents itself again from the view
    /// controller that presented it, so it must be presented the UIKit way; inside a SwiftUI
    /// sheet it has none, and presenting itself raises an exception. SwiftUI's `ColorPicker`
    /// presents it so, but reports neither its opening nor its close, which the **Spine design**
    /// card needs to make room above the picker and back. This view draws nothing; it finds the
    /// view controller that shows the card and presents the picker from it.
    ///
    /// The picker's sheet fits the picker's content, down to its current and saved colors, as the
    /// picker reports it, or stands at half height. It opens at half height where the taller
    /// sheet would cover the card's picking layout, as on a short iPhone. Neither height dims the
    /// details, so the reader can reach the card's reset while picking.
    private struct ColorPickerPresenter: UIViewRepresentable {
        let role: ColorRole?
        /// The card's color for `role`.
        let color: ColorValue?
        /// The height of the card's picking layout, through the picked color's row, which the
        /// details scroll to their top.
        let room: CGFloat
        let pick: (ColorValue) -> Void
        let finish: () -> Void

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {
            context.coordinator.parent = self
            context.coordinator.update(from: view)
        }

        static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
            coordinator.close()
        }

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        @MainActor
        final class Coordinator: NSObject, UIColorPickerViewControllerDelegate,
            UISheetPresentationControllerDelegate
        {
            var parent: ColorPickerPresenter
            /// The picker, kept while it hides for its eyedropper.
            private var picker: UIColorPickerViewController?
            /// The color the picker shows, as the card rounds it.
            private var shown: ColorValue?
            /// The tallest content the picker has reported since it opened, which its sheet
            /// keeps. Around its eyedropper, the picker reports less than its content needs.
            private var contentHeight: CGFloat = 0
            private var sizeObservation: NSKeyValueObservation?

            private static let fit = UISheetPresentationController.Detent.Identifier("fit")

            init(parent: ColorPickerPresenter) { self.parent = parent }

            func update(from view: UIView) {
                guard let role = parent.role, let color = parent.color else { return close() }
                if let picker {
                    picker.title = "\(role.name) color"
                    if color != shown {
                        picker.selectedColor = color.uiColor
                        shown = color
                    }
                    return
                }
                let picker = UIColorPickerViewController()
                picker.title = "\(role.name) color"
                picker.supportsAlpha = false
                picker.selectedColor = color.uiColor
                picker.delegate = self
                shown = color
                self.picker = picker
                // After SwiftUI's update, once the view is in its window.
                Task { @MainActor [weak view] in
                    guard self.picker === picker else { return }
                    let host =
                        sequence(first: view as UIResponder?, next: { $0?.next })
                        .lazy.compactMap { $0 as? UIViewController }.first
                    guard let host, view?.window != nil else { return finish() }
                    // A picker still closing, such as one the reader just closed, leaves first.
                    if let leaving = host.presentedViewController, leaving.isBeingDismissed,
                        let transition = leaving.transitionCoordinator
                    {
                        transition.animate(alongsideTransition: nil) { _ in
                            Task { @MainActor in self.present(picker, from: host) }
                        }
                    } else {
                        present(picker, from: host)
                    }
                }
            }

            /// Presents `picker` from `host`, unless the card has closed it.
            private func present(_ picker: UIColorPickerViewController, from host: UIViewController)
            {
                guard self.picker === picker else { return }
                // The host can't present while it presents another sheet.
                guard host.presentedViewController == nil, let window = host.view.window else {
                    return finish()
                }
                configure(picker, host: host, bottomInset: window.safeAreaInsets.bottom)
                // The picker runs in another process, so UIKit presents it some time after this
                // call. A picker the card closed in the meantime had nothing to dismiss, so it
                // leaves once it shows.
                host.present(picker, animated: true) { [weak self] in
                    if self?.picker !== picker { Self.dismiss(picker) }
                }
            }

            /// Sets up the picker's sheet and follows the height its content needs.
            private func configure(
                _ picker: UIColorPickerViewController, host: UIViewController, bottomInset: CGFloat
            ) {
                guard let sheet = picker.sheetPresentationController else { return }
                sheet.detents = [
                    .medium(),
                    // The picker runs in another process and reports the size its content needs
                    // as its preferred content size, with room for the home indicator, which a
                    // sheet at a partial height already stands clear of.
                    .custom(identifier: Self.fit) { [weak self] context in
                        guard let self, contentHeight > 0 else { return nil }
                        return min(contentHeight - bottomInset, context.maximumDetentValue)
                    },
                ]
                sheet.selectedDetentIdentifier = Self.fit
                sheet.largestUndimmedDetentIdentifier = Self.fit
                sheet.prefersGrabberVisible = true
                sheet.delegate = self
                // Until the first report, the sheet stands at half height.
                sizeObservation = picker.observe(\.preferredContentSize) {
                    [weak self, weak sheet, weak host] picker, _ in
                    MainActor.assumeIsolated {
                        let height = picker.preferredContentSize.height
                        guard let self, let sheet, height > self.contentHeight else { return }
                        let opening = self.contentHeight == 0
                        self.contentHeight = height
                        sheet.animateChanges {
                            sheet.invalidateDetents()
                            // The sheet stays at half height if the taller one would cover the
                            // card's picking layout under the details' bar. The sheet's views
                            // span the window whatever its height, so its top is estimated: a
                            // custom height's top edge stands 16 points below the picker's
                            // reported height, measured up from the window's bottom.
                            guard opening, let host, let window = host.view.window else { return }
                            let top = window.bounds.height - height + 16
                            if top < host.view.safeAreaInsets.top + self.parent.room {
                                sheet.selectedDetentIdentifier = .medium
                            }
                        }
                    }
                }
            }

            func colorPickerViewController(
                _ picker: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool
            ) {
                let color = ColorValue(Color(uiColor: color))
                shown = color
                parent.pick(color)
            }

            // A picker that closed earlier can still report its close.
            func colorPickerViewControllerDidFinish(_ picker: UIColorPickerViewController) {
                if picker === self.picker { finish() }
            }

            func presentationControllerDidDismiss(
                _ presentationController: UIPresentationController
            ) {
                if presentationController.presentedViewController === picker { finish() }
            }

            /// Closes the picker and tells the card.
            private func finish() {
                guard picker != nil else { return }
                close()
                parent.finish()
            }

            /// Dismisses the picker, unless it is already leaving, and lets it go.
            func close() {
                guard let picker else { return }
                self.picker = nil
                shown = nil
                contentHeight = 0
                sizeObservation = nil
                Self.dismiss(picker)
            }

            /// Dismisses `picker` if it shows and isn't already leaving.
            private static func dismiss(_ picker: UIColorPickerViewController) {
                if picker.presentingViewController != nil, !picker.isBeingDismissed {
                    picker.dismiss(animated: true)
                }
            }
        }
    }
#endif

extension ColorValue {
    /// The sRGB color nearest `color`, which can lie outside sRGB, such as a Display P3 color
    /// from the system color picker.
    fileprivate init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        func byte(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        self.init(red: byte(resolved.red), green: byte(resolved.green), blue: byte(resolved.blue))
    }
}

/// **Make share image**, with the Share tab's keepsake-card symbol: it opens the Share tab with
/// the book (`AppModel.share(_:)`) rather than a share sheet. The details' bar and their hosts'
/// bars show it.
struct MakeShareImageButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label("Make share image", image: "tab.share") }
            .help("Make a share image with this book")
    }
}

extension UndoManager {
    /// Registers `revert` as the undo of a style change, named `name`, such as "Change Color",
    /// with `redo` as its redo, so **Edit > Undo** and **Redo**, or shaking the iPhone, alternate
    /// between them. Each runs in a task of its own, and a failure shows a toast. Every style
    /// change targets `AppModel.shared`, so `removeAllActions(withTarget:)` with it clears them.
    func registerStyleChange(
        _ name: String, revert: @escaping @MainActor () async throws -> Void,
        redo: @escaping @MainActor () async throws -> Void
    ) {
        // Weak, so the registered action doesn't keep its manager alive.
        registerUndo(withTarget: AppModel.shared) { [weak self] model in
            Task {
                do {
                    try await revert()
                } catch {
                    model.toasts.show(.failure("Couldn't change the style back"))
                }
            }
            self?.registerStyleChange(name, revert: redo, redo: revert)
        }
        setActionName(name)
    }
}
