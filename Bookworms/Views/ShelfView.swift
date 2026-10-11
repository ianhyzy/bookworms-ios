import SwiftUI

/// The library as a 3D carousel of spines, with a caption for the centered book, or in 3D, which
/// shows a pile of books on a table (`BookPileView`).
///
/// Both show the library snapshot that `AppModel` holds; sorting and filtering happen here when
/// the snapshot or the options change, never while scrolling.
struct ShelfView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("BookwormsShelfMode") private var mode = ShelfPresentation.stack
    @AppStorage("BookwormsShelfSort") private var sort = ShelfSort.finished
    @AppStorage("BookwormsShelfDesignedOnly") private var designedOnly = false
    /// The pile's time frame as `TimeFrame.setting` writes it; empty for every book. Until the
    /// reader chooses one, the pile shows the current year.
    @AppStorage("BookwormsPileFrame") private var pileFrameSetting = TimeFrame.thisYear.setting
    /// Whether tilting the phone tips the pile's table, which `BookPileView` reads.
    @AppStorage("BookwormsPileTilt") private var tilts = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The centered book, shared by both carousel modes so switching keeps the reader's place.
    @State private var centeredID: Int?
    @State private var path: [Int] = []
    @State private var showsAccount = false
    @Namespace private var namespace

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { ShelfPalette.wall.ignoresSafeArea() }
                .navigationTitle("Shelf")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .navigationDestination(for: Int.self) { id in
                    if let book = model.books.first(where: { $0.id == id }) {
                        BookDetailView(book: book)
                            .navigationTransition(.zoom(sourceID: id, in: namespace))
                    } else {
                        ContentUnavailableView(
                            "Book unavailable", systemImage: "book.closed",
                            description: Text("The latest library no longer includes this book."))
                    }
                }
        }
        // The walnut backdrop is dark in both appearances, so text and bars use dark styles.
        .environment(\.colorScheme, .dark)
        .tint(ShelfPalette.lamp)
        // Outside the dark scheme and tint, so the account sheet follows the system appearance.
        // Kept on the stack, so the sheet stays open when the library it brings replaces the
        // empty state.
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        .onChange(of: sort) { recenter() }
        .onChange(of: designedOnly) { recenter() }
        #if DEBUG
            .onChange(of: model.books.count, initial: true) { applyDebugArguments() }
        #endif
    }

    @ViewBuilder private var content: some View {
        if let library = model.library {
            let frame = mode == .pile ? pileFrame : nil
            let books = shownBooks(in: library, frame: frame)
            if library.books.isEmpty {
                ContentUnavailableView(
                    "No books yet", systemImage: "books.vertical",
                    description: Text(
                        model.account.isSignedIn && !model.isPreview
                            ? "Books on your Hardcover shelves appear here after the next sync."
                            : "Books you finish appear here after your Apple TV syncs."))
            } else if books.isEmpty {
                // Only Designed only empties the shelf: a pile's time frame always has books.
                ContentUnavailableView {
                    Label(
                        frame.map { "No designed spines in \($0.title)" }
                            ?? "No designed spines yet", systemImage: "wand.and.sparkles")
                } description: {
                    Text("Spines appear here once they are designed.")
                } actions: {
                    if let frame {
                        Button("Show all books from \(frame.title)") { designedOnly = false }
                    }
                    Button("Show all books") {
                        designedOnly = false
                        if frame != nil { pileFrameSetting = "" }
                    }
                }
            } else if let carousel = mode.carousel {
                VStack(spacing: 0) {
                    SpineCarousel(
                        books: books, mode: carousel, centeredID: $centeredID, namespace: namespace
                    ) { path.append($0.id) }
                    ShelfCaption(books: books, centeredID: $centeredID)
                        // Larger sizes overflow the caption's fixed height; the book's details
                        // show the same record at any size.
                        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                }
            } else {
                BookPileView(books: books, title: frame?.title ?? Self.years(of: books)) {
                    path.append($0.id)
                }
            }
        } else {
            NoLibraryView(showsAccount: $showsAccount)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Presentation", selection: $mode) {
                ForEach(ShelfPresentation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("Sort and filter", systemImage: "line.3.horizontal.decrease") {
                // In the menu rather than the bar, which the presentation picker and the pile's
                // own buttons fill.
                if mode == .pile {
                    pileFrameOptions
                    if BookPileScene.canTilt && !reduceMotion {
                        Section {
                            Toggle("Tilt to move books", systemImage: "gyroscope", isOn: $tilts)
                        }
                    }
                }
                Picker("Sort by", selection: $sort) {
                    ForEach(ShelfSort.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Designed only", isOn: $designedOnly)
            }
        }
    }

    /// Chooses the pile's books: every book, or the books finished in one year or month.
    /// Choosing drops the chosen books in a new pile.
    private var pileFrameOptions: some View {
        let periods = TimeFrame.periods(in: model.books)
        let frame = Binding {
            pileFrame
        } set: {
            pileFrameSetting = $0?.setting ?? ""
        }
        return Section("Time frame") {
            Picker("Books", selection: frame) {
                Text("All books").tag(TimeFrame?.none)
            }
            if !periods.years.isEmpty {
                Picker("Year", selection: frame) {
                    ForEach(periods.years, id: \.self) { year in
                        Text(String(year)).tag(TimeFrame?.some(.year(year)))
                    }
                }
                .pickerStyle(.menu)
                Picker("Month", selection: frame) {
                    ForEach(periods.months, id: \.self) { month in
                        Text(month.title).tag(TimeFrame?.some(month))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    /// The pile's time frame, or `nil` for every book.
    private var pileFrame: TimeFrame? {
        TimeFrame.pileFrame(setting: pileFrameSetting, in: model.books)
    }

    /// The years `books` were finished in, such as "2019–2026", for a pile of every book.
    private static func years(of books: [CloudBook]) -> String {
        let years = books.compactMap(\.finishedYear)
        guard let first = years.min(), let last = years.max() else { return "My books" }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    /// The books in the chosen order and filter, and in `frame` when it is set.
    private func shownBooks(in library: LibrarySnapshot, frame: TimeFrame? = nil) -> [CloudBook] {
        var books = sort.sorted(model.books)
        if designedOnly { books = books.filter { library.designs[$0.id] != nil } }
        if let frame { books = books.filter(frame.contains) }
        return books
    }

    /// Returns to the first book after the order or filter changes.
    private func recenter() {
        guard let library = model.library else { return }
        centeredID = shownBooks(in: library).first?.id
    }

    #if DEBUG
        /// Simulator screenshot hooks, read once the library loads:
        /// `-BookwormsShelfScrollTo <index>` centers the book at that index, and
        /// `-BookwormsOpenBook <bookID>` opens that book's details.
        private func applyDebugArguments() {
            guard let library = model.library else { return }
            let books = shownBooks(in: library)
            let defaults = UserDefaults.standard
            if let index = defaults.string(forKey: "BookwormsShelfScrollTo").flatMap(Int.init),
                books.indices.contains(index)
            {
                centeredID = books[index].id
            }
            if let id = defaults.string(forKey: "BookwormsOpenBook").flatMap(Int.init),
                path.isEmpty
            {
                centeredID = id
                path = [id]
            }
        }
    #endif
}

/// Why there is no library to show, from the library load and the Hardcover account.
enum LibraryStatus: Equatable {
    /// A load from iCloud or the preview folder is running.
    case loading
    /// The signed-in account's library is downloading.
    case downloading
    /// Signed out, and the Apple TV has not uploaded a library. `note` is the error from loading
    /// the Apple TV's library, such as a missing iCloud account.
    case signedOut(note: String?)
    /// Hardcover rejected the saved login; `error` says how.
    case reconnect(error: String?)
    /// Signed in, but the library did not download or load.
    case failed(error: String?)

    /// - Parameter isSignedIn: Whether this iPhone's Hardcover sign-in provides the library.
    init(
        isLoading: Bool, isSignedIn: Bool, isSyncing: Bool, needsReconnect: Bool,
        syncError: String?, loadError: String?
    ) {
        if !isSignedIn {
            self = isLoading ? .loading : .signedOut(note: loadError)
        } else if needsReconnect {
            self = .reconnect(error: syncError)
        } else if isLoading || isSyncing {
            self = .downloading
        } else {
            self = .failed(error: syncError ?? loadError)
        }
    }

    /// The model's status. Preview mode ignores the sign-in. Debug builds launched with
    /// `-BookwormsLibraryStatus <signedOut|downloading|failed|reconnect>` show that status, with
    /// a fictional error, for Simulator checks.
    @MainActor init(_ model: AppModel) {
        #if DEBUG
            if let debug = UserDefaults.standard.string(forKey: "BookwormsLibraryStatus") {
                switch debug {
                case "downloading": self = .downloading
                case "failed": self = .failed(error: HardcoverError.http(503).errorDescription)
                case "reconnect":
                    self = .reconnect(error: HardcoverError.invalidToken.errorDescription)
                default: self = .signedOut(note: nil)
                }
                return
            }
        #endif
        let account = model.account
        self.init(
            isLoading: model.isLoading, isSignedIn: account.isSignedIn && !model.isPreview,
            isSyncing: account.isSyncing, needsReconnect: account.needsReconnect,
            syncError: account.syncError, loadError: model.loadError)
    }

    var title: String {
        switch self {
        case .loading: "Loading your library"
        case .downloading: "Downloading your Hardcover library"
        case .signedOut: "No library yet"
        case .reconnect: "Reconnect Hardcover"
        case .failed: "Couldn't download your library"
        }
    }

    /// What to do next, or what went wrong; empty while loading.
    var message: String {
        switch self {
        case .loading, .downloading: ""
        case .signedOut(let note):
            // The note concerns only the Apple TV's library, so it must not read as a step that
            // connecting Hardcover also needs.
            [
                "Turn on iCloud storage in the Bookworms app on your Apple TV, or connect Hardcover on this iPhone.",
                note.map { "Apple TV library: \($0)" },
            ]
            .compactMap(\.self).joined(separator: "\n\n")
        case .reconnect(let error): error ?? "Hardcover no longer accepts this iPhone's login."
        case .failed(let error): error ?? "Your Hardcover library isn't on this iPhone yet."
        }
    }
}

/// The Shelf and Share tabs' content without a library: progress, or how to get one, with
/// **Connect Hardcover**, **Reconnect**, or **Try again**.
///
/// The caller presents the account sheet when `showsAccount` is set, from a view that outlives
/// this one, so the sheet stays open when the library arrives.
struct NoLibraryView: View {
    @Binding var showsAccount: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = LibraryStatus(model)
        switch status {
        case .loading, .downloading:
            ProgressView(status.title)
        case .signedOut, .reconnect, .failed:
            ContentUnavailableView {
                Label(status.title, systemImage: systemImage(status))
            } description: {
                Text(status.message)
            } actions: {
                actions(status)
            }
        }
    }

    private func systemImage(_ status: LibraryStatus) -> String {
        switch status {
        case .reconnect: "person.crop.circle.badge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        default: "books.vertical"
        }
    }

    @ViewBuilder private func actions(_ status: LibraryStatus) -> some View {
        let tryAgain = Button("Try again") { Task { await model.reload() } }
        switch status {
        case .signedOut:
            // Preview mode ignores the sign-in.
            if !model.isPreview {
                Button("Connect Hardcover") { showsAccount = true }
                    .buttonStyle(.bordered)
            }
            tryAgain
        case .reconnect:
            Button("Reconnect") {
                model.account.startSignIn()
                showsAccount = true
            }
            .buttonStyle(.bordered)
        default:
            tryAgain
        }
    }
}

/// The centered book's title, author, and reading record.
///
/// Reads `centeredID` itself, so a new centered book updates only this caption. The caption
/// keeps a fixed, Dynamic Type–scaled height so the carousel above it never resizes mid-scroll.
private struct ShelfCaption: View {
    let books: [CloudBook]
    @Binding var centeredID: Int?
    @ScaledMetric(relativeTo: .title3) private var height: CGFloat = 150
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let index = books.firstIndex { $0.id == centeredID } ?? 0
        let book = books[index]
        VStack(spacing: 5) {
            // The position is decorative, so accessibility sizes give its line to the title.
            if !typeSize.isAccessibilitySize {
                Text("\(index + 1) of \(books.count)")
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    // Dimmer than the title, and above 4.5:1 contrast on the walnut wall.
                    .foregroundStyle(ShelfPalette.paper.opacity(0.6))
                    .accessibilityHidden(true)
            }
            Text(book.title)
                .font(.title3.weight(.semibold))
                .fontDesign(.serif)
                .lineLimit(2)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Text(book.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            let finished = book.finishedDate.map {
                Text("Finished \($0, format: ShelfLabels.finishedFormat)")
            }
            let stars = book.rating.flatMap { $0 > 0 ? RatingStars(rating: $0) : nil }
            // Stacks the date over the stars when large text leaves no room for both.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    finished
                    stars
                }
                VStack(spacing: 4) {
                    finished
                    stars
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.8)
        .foregroundStyle(ShelfPalette.paper)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// A 0...5 rating in half steps, drawn as five stars.
struct RatingStars: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: ShareStars.symbol(rating: rating, index: index))
            }
        }
        .foregroundStyle(ShelfPalette.gold)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating.formatted()) out of 5")
    }
}

/// The shelf's walnut palette, from the Apple TV's dark wood shelf.
enum ShelfPalette {
    static let wall = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.145, blue: 0.105),
            Color(red: 0.11, green: 0.078, blue: 0.055),
        ], startPoint: .top, endPoint: .bottom)
    static let board = Color(red: 0.32, green: 0.21, blue: 0.135)
    static let lamp = Color(red: 1, green: 0.8, blue: 0.56)
    static let paper = Color(red: 0.95, green: 0.9, blue: 0.82)
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.36)
}

/// The shelf's presentations: the carousel's two modes and 3D, which shows the physics pile. The
/// raw values match `ShelfMode`, so a saved carousel mode carries over.
enum ShelfPresentation: String, CaseIterable, Identifiable {
    case stack, shelf, pile

    var id: Self { self }
    /// The carousel mode, or `nil` for 3D.
    var carousel: ShelfMode? { ShelfMode(rawValue: rawValue) }
    var title: String { carousel?.title ?? "3D" }
}

/// How the shelf orders books.
enum ShelfSort: String, CaseIterable, Identifiable {
    case finished, title, author, rating

    var id: Self { self }

    var title: String {
        switch self {
        case .finished: "Recently finished"
        case .title: "Title"
        case .author: "Author"
        case .rating: "Your rating"
        }
    }

    /// Orders `books`, which arrive most recently finished first. The sort is stable, so ties
    /// keep that order; unrated books follow rated ones.
    func sorted(_ books: [CloudBook]) -> [CloudBook] {
        switch self {
        case .finished: books
        case .title:
            books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            books.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        case .rating: books.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        }
    }
}

/// Display text for book and design fields.
enum ShelfLabels {
    /// Finish dates are calendar days stored at noon UTC, so they format in UTC to keep the day.
    static let finishedFormat = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)

    /// The reading format as the Apple TV labels it, such as "Audiobook" for "Listened".
    static func format(_ format: String?) -> String? {
        switch format?.lowercased() {
        case nil: nil
        case "read", "physical": "Physical"
        case "listened", "audio", "audiobook": "Audiobook"
        case "ebook", "e-book", "digital": "Ebook"
        case "both": "Physical & audiobook"
        default: format
        }
    }
}
