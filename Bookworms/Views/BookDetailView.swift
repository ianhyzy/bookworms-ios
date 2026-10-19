import SwiftUI

/// A book's details: a 3D model to turn with a drag and its title, over three tabs that switch
/// only the content below them: **Details** (the book's description and facts on a grid of
/// cards), **Journal** (the reader's reading dates, progress, format, and review, on the same
/// cards, and for a finished book **Pin to Top Five**), and **Style** (**Change cover**, then the
/// spine's design: its series, colors, and **Redesign spine**).
///
/// A book that shares its series' spine design changes the series under **Style**: the series
/// look's or source's colors, and the cover and design of the source book
/// (`AppModel.designSource(for:)`), from which **Redesign spines** remakes the look. With **Edit**
/// set to **This book**, the book keeps its own design and the edits change only it.
///
/// With a `HostedBook`, the details draw no book, backdrop, or **Share** button of their own: a
/// transparent stand-in takes the book's place and turns as it would, the host draws the book
/// there behind the details, such as the Pile's RealityKit book or the shelf's pulled-out book,
/// and the host's bar offers **Share**.
struct BookDetailView: View {
    /// The book as the shelf opened it. The view shows the library's current copy, so a new
    /// cover or design appears at once.
    let opened: CloudBook
    let hostedBook: HostedBook?

    @Environment(AppModel.self) private var model
    @State private var cover: UIImage?
    @State private var choosesCover = false
    /// When the reader last changed the cover here.
    @State private var coverChangedAt: Date?
    /// The chosen cover the shown spine design comes from, as far as this screen knows: the
    /// design source's cover when the details opened, then when a new design arrives.
    @State private var designedCover: URL?
    @State private var tab = DetailTab.details
    /// The scroll view's visible height, which every tab's content fills at least, so switching
    /// to a shorter tab never scrolls the book.
    @State private var viewport: CGFloat = 0
    /// The book's description as plain text, or `nil` without one. Cleaning a long description
    /// takes milliseconds, so it happens off the main actor when the description changes.
    @State private var about: String?

    init(book: CloudBook, hostedBook: HostedBook? = nil) {
        opened = book
        self.hostedBook = hostedBook
        _designedCover = State(
            initialValue: AppModel.shared.designSource(for: book).chosenCoverURL)
        #if DEBUG
            // `-BookwormsDetailTab <details|journal|style>` opens that tab, for Simulator checks.
            let debugTab = UserDefaults.standard.string(forKey: "BookwormsDetailTab")
            if let debugTab, let tab = DetailTab(rawValue: debugTab) {
                _tab = State(initialValue: tab)
            }
        #endif
    }

    private var book: CloudBook { model.books.first { $0.id == opened.id } ?? opened }

    var body: some View {
        let book = book
        let look = model.look(for: book)
        let design = model.design(for: book)
        ScrollView {
            VStack(spacing: 24) {
                TurningBook(book: book, look: look, cover: cover, host: hostedBook)
                header
                Picker("Section", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                tabContent(look: look, design: design)
                    // Cards take the height they are offered, so the content keeps its own
                    // height and the minimum height adds room below it instead.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.containerSize.height
        } action: {
            viewport = $1
        }
        .background {
            if hostedBook == nil { ShelfPalette.wall.ignoresSafeArea() }
        }
        .toolbar {
            // A host shows its own bar, which outlasts these details as they leave.
            if hostedBook == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") { model.share(book) }
                }
            }
        }
        // A new cover choice changes the first candidate; the old cover shows until it loads.
        .task(id: book.coverCandidates.first) { cover = await model.covers.image(for: book) }
        .task(id: book.description) {
            let text = await Self.plainText(book.description)
            if !Task.isCancelled { about = text }
        }
        // A new design of the spine's source, not a recoloring of its look or design, nor an
        // ordinary run's copy of its series look.
        .onChange(of: model.library?.designs[model.designSource(for: book).id]?.generatedAt) {
            guard model.library?.designs[model.designSource(for: book).id]?.isSeriesReuse != true
            else { return }
            designedCover = model.designSource(for: book).chosenCoverURL
        }
        .sheet(isPresented: $choosesCover) {
            // The shelf sets a dark scheme for its walnut backdrop, which the sheet's content
            // inherits; the sheet's own background must match it to keep text readable.
            // A new cover can call for a new spine, which **Style** offers below the button.
            // A series that shares a design takes its spine from its source's cover.
            CoverPickerView(book: model.designSource(for: book)) { coverChangedAt = .now }
                .preferredColorScheme(.dark)
        }
        #if DEBUG
            .onAppear { if CoverPickerDebug.opensPicker { choosesCover = true } }
        #endif
    }

    /// Offers a run that redesigns the spine from the new cover.
    private func redesignCard(series: Bool) -> some View {
        Card {
            Text(series ? "Redesign the series' spines?" : "Redesign the spine?").font(.headline)
            Text(
                series
                    ? "The series' spines were designed from the previous cover."
                    : "The spine was designed from the previous cover."
            )
            .font(.footnote)
            .foregroundStyle(cardNote)
            RedesignButton(book: book, series: series, requestedAt: $coverChangedAt)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            BookText(book.title, of: book)
                .font(.title2.weight(.semibold))
                .fontDesign(.serif)
                .accessibilityAddTraits(.isHeader)
            Text(book.author)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let rating = book.rating, rating > 0 {
                RatingStars(rating: rating).font(.title3).padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(ShelfPalette.paper)
    }

    @ViewBuilder
    private func tabContent(look: SpineLook, design: SpineDesignV1?) -> some View {
        switch tab {
        case .details:
            CardGrid(cards: DetailCard.details(of: book, about: about), book: book)
        case .journal:
            journal
        case .style:
            let series = model.sharesSeriesDesign(book)
            let coverChanged =
                design != nil && model.designSource(for: book).chosenCoverURL != designedCover
            VStack(spacing: 24) {
                Button(
                    series ? "Change series cover" : "Change cover",
                    systemImage: "photo.on.rectangle"
                ) { choosesCover = true }
                .buttonStyle(.bordered)
                if coverChanged { redesignCard(series: series) }
                designCard(look: look, design: design, offersRedesign: !coverChanged)
            }
        }
    }

    /// The reader's own record of the book, all from their reading service, with a note on where
    /// a missing review would come from.
    @ViewBuilder private var journal: some View {
        let cards = DetailCard.journal(of: book)
        VStack(spacing: 24) {
            CardGrid(cards: cards, book: book)
            if !cards.contains(where: { if case .review = $0 { true } else { false } }) {
                Text(
                    cards.isEmpty
                        ? "Your reading dates and review from Hardcover appear here."
                        : "A review you write on Hardcover appears here."
                )
                .font(.footnote)
                .foregroundStyle(cardNote)
                .multilineTextAlignment(.center)
            }
            // Top Five draws finished books only.
            if book.finishedDate != nil { TopFivePinButton(bookID: book.id) }
        }
    }

    @concurrent nonisolated private static func plainText(_ markup: String?) async -> String? {
        HardcoverClient.plainText(from: markup)
    }

    private func designCard(look: SpineLook, design: SpineDesignV1?, offersRedesign: Bool)
        -> some View
    {
        SpineDesignCard(
            book: book, look: look, design: design, generated: model.generatedColors(for: book),
            series: model.sharesSeriesDesign(book) ? model.designSource(for: book) : nil,
            offersRedesign: offersRedesign)
    }
}

/// The parts of a book's details that the tabs under its title switch between.
enum DetailTab: String, CaseIterable, Identifiable {
    case details
    case journal
    case style

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// One card of the **Details** or **Journal** grid, with what it shows.
enum DetailCard: Hashable {
    /// The description as plain text.
    case about(String)
    /// Hardcover readers' average rating and how many ratings it averages, with the number of
    /// readers per half star (`ratingCounts(_:)`) when known, and the reader's own rating.
    case rating(average: Double, count: Int, counts: [Int]?, yours: Double?)
    case series(name: String?, position: Double?)
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
    /// How the reader read the book, such as "Audiobook", with that format's length.
    case format(String, length: String?)
    case review(String)

    /// Whether the card fills its row: text and tags need the width, and a rating's bars sit
    /// beside the average there instead of making the card taller than the card beside it.
    var isWide: Bool {
        switch self {
        case .about, .genres, .review: true
        case .rating(_, _, let counts, _): counts != nil
        default: false
        }
    }

    /// The **Details** cards: facts about the book itself, whichever way anyone reads it. A fact
    /// that is missing has no card. `about` is the description as plain text.
    static func details(of book: CloudBook, about: String?) -> [DetailCard] {
        // Readers tag in British and American spelling, so "Humour" repeats "Humor".
        var spellings = Set<String>()
        let genres = Array(
            (book.genres ?? []).filter(YearInBooks.isEnglishTag).map(YearInBooks.displayGenre)
                .filter { spellings.insert($0.lowercased().replacing("our", with: "or")).inserted }
                .prefix(3))
        var rating: DetailCard?
        if let average = book.communityRating, average > 0, let count = book.ratingsCount,
            count > 0
        {
            rating = .rating(
                average: average, count: count, counts: ratingCounts(book.ratingDistribution),
                yours: book.rating)
        }
        let inSeries = book.seriesName != nil || book.seriesPosition != nil
        let cards: [DetailCard?] = [
            about.map(DetailCard.about),
            rating,
            inSeries ? .series(name: book.seriesName, position: book.seriesPosition) : nil,
            book.publicationYear.map(DetailCard.published),
            ShelfLabels.pages(of: book).map(DetailCard.length),
            genres.isEmpty ? nil : .genres(genres),
        ]
        return cards.compactMap(\.self)
    }

    /// The **Journal** cards: the reader's own record of the book, from their reading service.
    /// The format card gives the length of the format read: listening time for an audiobook when
    /// known, pages otherwise.
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
                .map { .format($0, length: ShelfLabels.length(of: book)) },
            review?.isEmpty == false ? review.map(DetailCard.review) : nil,
        ]
        return cards.compactMap(\.self)
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

/// The 3D book's orientation, in radians.
struct BookPose: Equatable {
    var yaw: Double
    var pitch: Double

    /// Three-quarter view with the spine toward the viewer, as `Book3DView` defaults.
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
    /// centered where the details center their book, in global coordinates, whenever it moves,
    /// including as it drifts.
    let place: (CGRect) -> Void
    /// Receives the pose the details' book would show, drift included, whenever it changes.
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
/// timeline renders the drift alone at most 30 times a second, enough for its slow motion,
/// and pauses while the book's stage is scrolled out of view. The drag claims touches that
/// start on the book, so the page scrolls from the text below.
private struct TurningBook: View {
    nonisolated static let bookHeight: CGFloat = 380

    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    let host: HostedBook?

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
    /// The pose on screen when the current drag began. SwiftUI resets it when a drag ends or
    /// is cancelled, so the next drag starts from the current pose.
    @GestureState private var dragStart: BookPose?

    var body: some View {
        let drifts = drift != nil && isOnScreen
        TimelineView(
            .animation(
                minimumInterval: coast == nil ? 1.0 / 30 : nil, paused: coast == nil && !drifts)
        ) { context in
            let turned = coast?.pose(at: context.date) ?? pose
            let float = drift?.offset(at: context.date)
            let shown = BookPose(yaw: turned.yaw + (float?.yaw ?? 0), pitch: turned.pitch)
            let shift = float?.translation ?? .zero
            if let host {
                Color.clear
                    .frame(height: Self.bookHeight)
                    // Inside the offset, so the reported frame drifts with it.
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        host.place($0)
                    }
                    .offset(shift)
                    .onChange(of: shown, initial: true) { host.turn(shown) }
                    .accessibilityElement()
                    .accessibilityLabel("\(book.title), by \(book.author)")
            } else {
                Book3DView(
                    book: book, look: look, cover: cover, height: Self.bookHeight,
                    yaw: shown.yaw, pitch: shown.pitch
                )
                .offset(shift)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 460)
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
        .accessibilityHint("Swipe up or down to turn the book.")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? Double.pi / 4 : -Double.pi / 4
            let target = BookPose(yaw: pose.yaw + step, pitch: pose.pitch)
            if reduceMotion { pose = target } else { settle(at: target) }
        }
        #if DEBUG
            .onAppear(perform: applyDebugPose)
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

    /// When the book arrived in its details.
    let start: Date

    /// The book's displacement at `date`: `translation` in points, with y down, and `yaw` in
    /// radians to add to its pose.
    func offset(at date: Date) -> (translation: CGSize, yaw: Double) {
        let time = max(0, date.timeIntervalSince(start))
        let ramp = min(1, time / Self.rampDuration)
        let eased = ramp * ramp * ramp * (ramp * (ramp * 6 - 15) + 10)
        func wave(_ amplitude: Double, period: Double) -> Double {
            amplitude * sin(2 * .pi * time / period) * eased
        }
        return (
            CGSize(
                width: wave(Self.horizontalAmplitude, period: 48),
                height: -wave(Self.verticalAmplitude, period: 40)),
            wave(Self.swayAmplitude, period: 60)
        )
    }
}

/// Small secondary text on a `Card`. The `.secondary` style reaches only about 4.1:1 on the
/// card fill, below the 4.5:1 that footnote and caption text need.
private let cardNote = ShelfPalette.paper.opacity(0.7)

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
        .foregroundStyle(cardNote)
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
                DetailCard.rows(cards, oneColumn: typeSize.isAccessibilitySize), id: \.self
            ) { row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row, id: \.self) {
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
                average: average, count: count, counts: counts, yours: yours, isWide: fillsRow)
        case .series(let name, let position):
            let number = position.map { "Book \($0.formatted())" }
            FactCard(
                title: "Series", systemImage: "books.vertical", value: name ?? number ?? "",
                detail: name == nil ? nil : number)
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
        case .started(let date):
            FactCard(
                title: "Started", systemImage: "calendar",
                value: date.formatted(ShelfLabels.finishedFormat))
        case .finished(let date, let reads):
            FactCard(
                title: "Finished", systemImage: "checkmark.circle",
                value: date.formatted(ShelfLabels.finishedFormat),
                detail: ShelfLabels.reads(reads))
        case .readingTime(let time):
            FactCard(title: "Reading time", systemImage: "hourglass", value: time)
        case .format(let format, let length):
            FactCard(
                title: "Read as", systemImage: ShelfLabels.formatSymbol(format), value: format,
                detail: length)
        case .review(let review):
            Card {
                caption("Your review", systemImage: "text.quote")
                BookText(review, of: book)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
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
                    Text(detail).font(.subheadline).foregroundStyle(cardNote)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The description, cut to six lines, with **More** to show the rest in place when it runs
/// longer. A hidden copy at full height detects whether the six lines cut it off.
private struct AboutCard: View {
    let text: String
    let book: CloudBook

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        Card {
            caption("About", systemImage: "text.alignleft")
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
            if !isExpanded, fullHeight > shownHeight + 1 {
                Button("More") {
                    withAnimation(reduceMotion ? nil : .smooth) { isExpanded = true }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Hardcover readers' average rating, with stars, the number of ratings, and bars for the
/// readers who gave each rating, the reader's own rating in gold. A wide card puts the bars
/// beside the average, except at accessibility text sizes.
private struct RatingCard: View {
    let average: Double
    let count: Int
    let counts: [Int]?
    let yours: Double?
    let isWide: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let ratings = count == 1 ? "1 rating" : "\(count.formatted()) ratings"
        let layout =
            isWide && !typeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 20))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        Card {
            caption("Readers' rating", systemImage: "person.2")
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    Text(average, format: .number.precision(.fractionLength(1)))
                        .font(.largeTitle.weight(.semibold))
                    RatingStars(rating: average).font(.footnote)
                    Text(ratings).font(.footnote).foregroundStyle(cardNote)
                }
                if let counts { RatingBars(counts: counts, yours: yours) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readers' rating")
        .accessibilityValue(
            "\(average.formatted(.number.precision(.fractionLength(1)))) out of 5, from \(ratings)")
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
                        .fill(index == yourIndex ? ShelfPalette.gold : cardNote.opacity(0.5))
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
            .foregroundStyle(cardNote)
        }
        .accessibilityHidden(true)
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

/// The **Spine design** card: the spine, the book's series choices (`SeriesRows`), the design's
/// font, and its colors, which the reader can change, with **Redesign spine**.
///
/// Each color opens the system color picker. The card's spine shows picked colors at once. The
/// rest of the app shows them, and the library's store saves them, one second after the last
/// change or when the card leaves (`AppModel.recolor(_:to:)`), so dragging in the picker
/// neither redraws 3D textures nor writes to iCloud for each frame. Colors whose text and
/// background contrast less than 4.5:1 show only here, with a note, and are never saved.
///
/// The picker's sheet covers the lower half of the screen. While it shows, the card adds room
/// below itself and scrolls its top to the top of the details, so the spine, the contrast note,
/// and the swatches stay above the sheet.
private struct SpineDesignCard: View {
    let book: CloudBook
    /// The look of the saved design, as the rest of the app shows it.
    let look: SpineLook
    let design: SpineDesignV1?
    /// The colors **Reset colors** restores (`AppModel.generatedColors(for:)`).
    let generated: SpineColors?
    /// The series source whose design `book` shares, or `nil` when the design is its own.
    let series: CloudBook?
    /// Whether the card offers **Redesign spine**, which the details offer elsewhere after a
    /// cover change.
    let offersRedesign: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Picked colors that the library does not show yet, or that it shows but failed to save.
    @State private var draft: SpineColors?
    @State private var saveError: String?
    /// The color whose picker shows.
    @State private var picking: ColorRole?
    /// When the reader last tapped **Redesign spine** here, until a new design arrives.
    @State private var redesignedAt: Date?

    private static let cardID = "spine-design-card"

    private var saved: SpineColors {
        SpineColors(background: look.background, foreground: look.foreground, accent: look.accent)
    }

    var body: some View {
        let shown = draft ?? saved
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                card(shown: shown).id(Self.cardID)
                if picking != nil {
                    Color.clear.containerRelativeFrame(.vertical)
                }
            }
            .animation(.smooth, value: picking == nil)
            .onChange(of: picking == nil) {
                guard picking != nil else { return }
                withAnimation(.smooth) { proxy.scrollTo(Self.cardID, anchor: .top) }
            }
        }
        .sheet(item: $picking) { role in
            SystemColorPicker(
                title: "\(role.name) color", initial: shown[keyPath: role.keyPath]
            ) { color in
                var colors = draft ?? saved
                colors[keyPath: role.keyPath] = color
                draft = colors
            } finish: {
                picking = nil
            }
            #if os(iOS)
                .presentationDetents([.medium])
            #endif
        }
        .task(id: draft) {
            guard let draft else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { await save(draft) }
        }
        .onDisappear {
            // The card cannot report a failure once it is gone; the colors stay on screen until
            // the next reload.
            guard let draft, draft.isReadable else { return }
            Task { [model, book] in try? await model.recolor(book, to: draft) }
        }
        // A new design, such as a redesign from a new cover, replaces the colors being picked.
        // Recoloring a look sets its edit date, so the source's stored design tells instead; an
        // ordinary run's copy of the series look is no new design.
        .onChange(of: model.library?.designs[model.designSource(for: book).id]?.generatedAt) {
            guard model.library?.designs[model.designSource(for: book).id]?.isSeriesReuse != true
            else { return }
            draft = nil
            redesignedAt = nil
        }
        #if DEBUG
            .onAppear(perform: applyDebugColors)
        #endif
    }

    private func card(shown: SpineColors) -> some View {
        Card {
            Text("Spine design").font(.headline)
            SpineView(book: book, look: look(with: shown))
                .frame(height: book.slabThickness)
                .accessibilityHidden(true)
            SeriesRows(book: book)
            if let design {
                // Under the spine, so the note shows above the picker's sheet.
                if !shown.isReadable {
                    note(
                        "The text needs more contrast with the background. Choose a lighter or darker color to save.",
                        systemImage: "exclamationmark.triangle")
                }
                LabeledContent("Font") {
                    Text(design.fontFamily ?? design.typeface.capitalized)
                        .font(look.font(size: 19))
                }
                Divider()
                let swatches =
                    typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top))
                swatches {
                    ForEach(ColorRole.allCases) { role in
                        Swatch(role: role, color: shown[keyPath: role.keyPath]) { picking = role }
                    }
                }
                if shown.isReadable {
                    if let saveError {
                        note(saveError, systemImage: "exclamationmark.icloud")
                    } else {
                        Text(
                            series == nil
                                ? "Tap a color to change it."
                                : "Tap a color to change it for the whole series."
                        )
                        .font(.footnote)
                        .foregroundStyle(cardNote)
                    }
                }
                if let generated, shown != generated {
                    Button("Reset colors", systemImage: "arrow.uturn.backward") {
                        draft = generated
                        Task { await save(generated) }
                    }
                    .buttonStyle(.bordered)
                }
                if offersRedesign {
                    RedesignButton(book: book, series: series != nil, requestedAt: $redesignedAt)
                }
                Divider()
            }
            if let design {
                if let series {
                    Text(
                        series.id == book.id
                            ? "Other books in this series share this design."
                            : "Books in this series share the design of \(series.spineTitle)."
                    )
                    .font(.footnote)
                    .foregroundStyle(cardNote)
                }
                let created = model.drawnLook(of: book)?.createdAt ?? design.generatedAt
                Text("Created \(created, format: .dateTime.year().month().day())")
                    .font(.footnote)
                    .foregroundStyle(cardNote)
            } else {
                Text("The spine shows a placeholder cloth until it is designed.")
                    .font(.footnote)
                    .foregroundStyle(cardNote)
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
        Label(text, systemImage: systemImage).font(.footnote).foregroundStyle(cardNote)
    }

    /// Shows and saves readable `colors`, then clears the draft unless the reader has picked
    /// other colors since.
    private func save(_ colors: SpineColors) async {
        guard colors.isReadable else { return }
        do {
            try await model.recolor(book, to: colors)
            saveError = nil
            if draft == colors { draft = nil }
        } catch is CancellationError {
            // A newer draft replaced these colors.
        } catch {
            saveError = error.localizedDescription
        }
    }

    #if DEBUG
        @MainActor private static var appliedDebugColors = false

        /// Simulator hook: with `-BookwormsOpenBook <book ID>`,
        /// `-BookwormsSpineColors "RRGGBB,RRGGBB,RRGGBB"` picks those background, text, and accent
        /// colors for that book once per launch, as the color pickers would.
        private func applyDebugColors() {
            let defaults = UserDefaults.standard
            guard !Self.appliedDebugColors, design != nil,
                defaults.string(forKey: "BookwormsOpenBook").flatMap(Int.init) == book.id,
                let hexes = defaults.string(forKey: "BookwormsSpineColors")?.split(separator: ","),
                hexes.count == 3,
                let background = ColorValue(hex: "#\(hexes[0].uppercased())"),
                let foreground = ColorValue(hex: "#\(hexes[1].uppercased())"),
                let accent = ColorValue(hex: "#\(hexes[2].uppercased())")
            else { return }
            Self.appliedDebugColors = true
            draft = SpineColors(background: background, foreground: foreground, accent: accent)
        }
    #endif
}

/// The **Series** menu and the **Edit** choice of a book's spine design, saved as the book's
/// `SeriesLinkV1` (`AppModel.setSeriesLink(for:linkedSeriesID:standsAlone:ownLook:)`).
///
/// **Series** chooses the series whose look the book draws: by default its shortest series
/// (`SeriesDesigns.styleSeries(of:link:)`), or another of its Hardcover series, or none. It shows
/// when the book has a series or a link. **Edit** chooses whether recoloring, **Reset colors**,
/// and **Redesign spine** change the series' look or only this book, which then draws its own
/// design. It shows when the book's look group has a saved look or another book
/// (`AppModel.choosesEditScope(for:)`). A choice shows at once and stays while it saves; a failed
/// save shows a toast and the saved choice again. The rows take no other choice until a save
/// ends, so saves never overlap and the last choice is the one iCloud keeps.
private struct SeriesRows: View {
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
    }

    let book: CloudBook

    @Environment(AppModel.self) private var model
    /// The choice being saved, shown until the library has it.
    @State private var saving: Choice?

    var body: some View {
        let choice = saving ?? Choice(book.seriesLink)
        var seen = Set<Int>()
        let memberships = (book.seriesMemberships ?? [])
            .filter { seen.insert($0.seriesID).inserted }
        if !memberships.isEmpty || book.seriesID != nil || book.seriesLink != nil {
            LabeledContent("Series") {
                Picker(
                    "Series",
                    selection: Binding {
                        choice.series
                    } set: {
                        var new = choice
                        new.series = $0
                        choose(new)
                    }
                ) {
                    Text(standardTitle(memberships)).tag(Choice.Series.standard)
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
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(saving != nil)
            }
        }
        if model.choosesEditScope(for: book) {
            LabeledContent("Edit") {
                Picker(
                    "Edit",
                    selection: Binding {
                        choice.ownLook
                    } set: {
                        var new = choice
                        new.ownLook = $0
                        choose(new)
                    }
                ) {
                    Text("Series").tag(false)
                    Text("This book").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(saving != nil)
            }
        }
    }

    /// "Default", with the name of the series the book draws without a link.
    private func standardTitle(_ memberships: [SeriesMembership]) -> String {
        let id = SeriesDesigns.styleSeries(of: book, link: nil)?.id
        let name =
            memberships.first { $0.seriesID == id }?.name
            ?? (id != nil && id == book.seriesID ? book.seriesName : nil)
        return name.map { "Default — \($0)" } ?? "Default"
    }

    private static func title(of series: SeriesMembership) -> String {
        switch series.size {
        case nil: series.name
        case 1: "\(series.name) (1 book)"
        case let size?: "\(series.name) (\(size) books)"
        }
    }

    private func choose(_ new: Choice) {
        saving = new
        var linked: Int?
        if case .linked(let id) = new.series { linked = id }
        Task {
            do {
                try await model.setSeriesLink(
                    for: book, linkedSeriesID: linked, standsAlone: new.series == .alone,
                    ownLook: new.ownLook)
            } catch {
                model.toasts.show(.failure("Couldn't save the series choice"))
            }
            if saving == new { saving = nil }
        }
    }
}

/// Pins the book to lead Top Five share images, or unpins it (`TopFivePins`). While five other
/// books are pinned, it is disabled and says where to unpin one.
private struct TopFivePinButton: View {
    let bookID: Int
    @AppStorage(TopFivePins.key) private var pins = TopFivePins()

    var body: some View {
        let isPinned = pins.contains(bookID)
        VStack(spacing: 8) {
            Button(
                isPinned ? "Unpin from Top Five" : "Pin to Top Five",
                systemImage: isPinned ? "pin.slash" : "pin"
            ) {
                pins.toggle(bookID)
            }
            .buttonStyle(.bordered)
            .disabled(!isPinned && pins.isFull)
            if !isPinned && pins.isFull {
                Text("Five books are pinned. Unpin one under Share > Top Five to pin this one.")
                    .font(.footnote)
                    .foregroundStyle(cardNote)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// **Redesign spine** for a book (`GenerationController.redesign(_:)`), or the run's progress
/// while one runs. A run that ends after `requestedAt` while it is still set, because no new
/// design arrived, leaves a note with the run's error, for example after a quota stop or when
/// the cover did not load.
private struct RedesignButton: View {
    let book: CloudBook
    /// Whether the redesign changes the book's whole series.
    let series: Bool
    /// When the reader asked for a new design, by this button or a new cover.
    @Binding var requestedAt: Date?

    @Environment(GenerationController.self) private var generation

    var body: some View {
        if generation.status.isRunning {
            LabeledContent("Designing spines") { ProgressView() }
        } else {
            Button(series ? "Redesign spines" : "Redesign spine", systemImage: "wand.and.sparkles")
            {
                requestedAt = .now
                generation.redesign(book)
            }
            .buttonStyle(.bordered)
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
                .foregroundStyle(cardNote)
            }
        }
    }
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
/// A column for a row of three; at accessibility sizes, where a column breaks the words, a row
/// with the text beside the swatch.
private struct Swatch: View {
    let role: ColorRole
    let color: ColorValue
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let isRow = typeSize.isAccessibilitySize
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
                    Text(color.hex).font(.caption.monospaced()).foregroundStyle(cardNote)
                }
            }
            .frame(maxWidth: isRow ? nil : .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(role.name) color")
        .accessibilityValue(color.hex)
    }
}

/// The system color picker, without opacity, reporting each pick and the picker's close.
///
/// SwiftUI's `ColorPicker` opens the same picker but reports neither its opening nor its close,
/// which the **Spine design** card needs to move above the picker's sheet and back. The card
/// presents this picker in its own sheet instead.
#if os(macOS)
    /// The Mac's color well, which opens the system color panel, in a small sheet whose **Done**
    /// ends picking.
    private struct SystemColorPicker: View {
        let title: String
        let initial: ColorValue
        let pick: (ColorValue) -> Void
        let finish: () -> Void
        @State private var color: Color?

        var body: some View {
            VStack(spacing: 16) {
                ColorPicker(
                    title,
                    selection: Binding(
                        get: { color ?? Color(uiColor: initial.uiColor) },
                        set: { color = $0 }),
                    supportsOpacity: false)
                Button("Done", action: finish).keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .onChange(of: color) { _, color in
                if let color { pick(ColorValue(color)) }
            }
        }
    }
#else
    private struct SystemColorPicker: UIViewControllerRepresentable {
        let title: String
        let initial: ColorValue
        let pick: (ColorValue) -> Void
        let finish: () -> Void

        func makeUIViewController(context: Context) -> UIColorPickerViewController {
            let picker = UIColorPickerViewController()
            picker.title = title
            picker.supportsAlpha = false
            picker.selectedColor = initial.uiColor
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
            context.coordinator.parent = self
        }

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        @MainActor final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
            var parent: SystemColorPicker

            init(parent: SystemColorPicker) { self.parent = parent }

            func colorPickerViewController(
                _ picker: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool
            ) {
                parent.pick(ColorValue(Color(uiColor: color)))
            }

            func colorPickerViewControllerDidFinish(_ picker: UIColorPickerViewController) {
                parent.finish()
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
