import SwiftUI

/// The books you have read, as a stack of books or a bookcase of spines (`SpineCarousel`), with
/// a caption for the centered book and, on the iPhone, a footer that names the library and holds
/// its options (`LibraryFooter`).
///
/// It shows the library snapshot that `AppModel` holds, within the time that **Time** chooses
/// (`LibraryTime`); filtering and sorting happen here when the snapshot or the options change,
/// never while scrolling.
///
/// A tapped book slides out of the carousel and floats into its details over the shelf
/// (`ShelfPullOut`), as a book the Pile lifts does. With Reduce Motion on, its details push
/// instead.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("BookwormsShelfMode") private var mode = ShelfMode.stack
    @AppStorage("BookwormsShelfSort") private var sort = ShelfSort.finished
    @AppStorage("BookwormsLibraryTime") private var time = LibraryTime.last12Months
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The centered book, shared by both modes so switching keeps the reader's place.
    @State private var centeredID: Int?
    @State private var path: [Int] = []
    /// The book that Stack or Shelf pulled out to show its details over the shelf.
    @State private var pullOut = ShelfPullOut()
    @State private var showsAccount = false
    /// How far the status bar and the Dynamic Island reach down from the screen's top edge.
    @State private var statusBar: CGFloat = 0
    @Namespace private var namespace

    var body: some View {
        let read = readBooks
        let books = model.library == nil ? [] : shownBooks(of: read)
        let options = options(read: read, books: books)
        NavigationStack(path: $path) {
            content(read: read, books: books, options: options)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { WalnutWall().ignoresSafeArea() }
                .modifier(LibraryBar(pullOut: pullOut, options: options))
                .navigationDestination(for: Int.self) { id in
                    PushedBookDetail(id: id)
                        #if os(iOS)
                            .navigationTransition(.zoom(sourceID: id, in: namespace))
                        #endif
                }
        }
        #if os(iOS)
            // The stack's own safe area, outside its bar, so the bar's showing never changes it.
            .onGeometryChange(for: CGFloat.self) {
                $0.safeAreaInsets.top
            } action: {
                statusBar = $0
            }
        #endif
        // The walnut backdrop is dark in both appearances, so text and bars use dark styles.
        .environment(\.colorScheme, .dark)
        #if os(iOS)
            // The tab bar belongs to the tab view, outside the dark scheme, and its glass stays
            // light over the dark wall in light appearance, so the tab asks for a dark bar too.
            .toolbarColorScheme(.dark, for: .tabBar)
            // The scheme applies only while the bar's background shows.
            .toolbarBackgroundVisibility(.visible, for: .tabBar)
        #endif
        .tint(ShelfPalette.lamp)
        // Outside the dark scheme and tint, so the account sheet follows the system appearance.
        // Kept on the stack, so the sheet stays open when the library it brings replaces the
        // empty state.
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        .onChange(of: sort) { recenter() }
        .onChange(of: time) { recenter() }
        // The shelf's controls return as a pulled-out book flies back, and a book can only
        // return to a spine that is still where it left it.
        .onChange(of: mode) { pullOut.close() }
        // In Stack, the stack centers a pulled book behind its details, and again as Back starts,
        // so the book always flies back to the middle of the screen, clear of the stack's
        // ends, even if the stack moved while the details showed.
        .onChange(of: pullOut.showsText) { centerPulledBook() }
        .onChange(of: pullOut.isReturning) { centerPulledBook() }
        #if DEBUG
            .onChange(of: model.books.count, initial: true) { applyDebugArguments() }
        #endif
    }

    /// **View options** and the library's status, or `nil` without a library or read books,
    /// where Library offers neither.
    private func options(read: [CloudBook], books: [CloudBook]) -> LibraryOptions? {
        guard model.library != nil, !read.isEmpty else { return nil }
        return LibraryOptions(
            mode: $mode, sort: $sort, time: $time, years: LibraryTime.years(in: read),
            count: books.count)
    }

    @ViewBuilder private func content(
        read: [CloudBook], books: [CloudBook], options: LibraryOptions?
    ) -> some View {
        if let options {
            VStack(spacing: 0) {
                if books.isEmpty {
                    noBooksInTime
                } else {
                    carousel(books)
                }
                #if os(iOS)
                    LibraryFooter(options: options, pullOut: pullOut)
                #endif
            }
            .modifier(ShelfPullOutStage(pullOut: pullOut))
        } else if model.library == nil {
            NoLibraryView(showsAccount: $showsAccount)
        } else {
            NoBooksYetView()
        }
    }

    /// Says that the time has no books, and offers **Show All Time**.
    private var noBooksInTime: some View {
        // Scrolls so that at accessibility sizes the actions stay above the footer.
        ScrollView {
            ContentUnavailableView {
                Label("No books in \(time.title)", systemImage: "calendar")
            } description: {
                Text("Books you finish in this time appear here.")
            } actions: {
                if time != .allTime {
                    Button("Show All Time") { time = .allTime }
                }
            }
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }

    /// The carousel and its caption.
    @ViewBuilder private func carousel(_ books: [CloudBook]) -> some View {
        SpineCarousel(
            books: books, mode: mode, centeredID: $centeredID, namespace: namespace,
            pullOut: pullOut, statusBar: statusBar
        ) { book in
            if reduceMotion {
                path.append(book.id)
            } else if mode == .stack, centeredID != book.id {
                // The stack glides the book to the middle of the screen first, as it
                // centers the book for the return (`centerPulledBook`), so the book
                // slides out in full view, clear of the stack's ends, where the
                // stack's faded copy would otherwise hand off to the flight's opaque
                // one.
                centeredID = book.id
                Task {
                    try? await Task.sleep(for: .seconds(SpineCarousel.glide))
                    if mode == .stack { pullOut.pull(book, upright: false) }
                }
            } else {
                pullOut.pull(book, upright: mode == .shelf)
            }
        }
        .modifier(ShelfPullOutWait(pullOut: pullOut))
        #if os(iOS)
            // The books run up under the status bar and the Dynamic Island to the
            // screen's top edge, where the bar shows only over a book's details. Its
            // frame stays the same whether the bar shows or not, so a pulled book's
            // place never moves.
            .ignoresSafeArea(.container, edges: .top)
        #endif
        ShelfCaption(books: books, centeredID: $centeredID)
            // Larger sizes overflow the caption's fixed height; the book's details
            // show the same record at any size.
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            #if os(macOS)
                // The window's standard margin below the caption, where the iPhone's footer
                // sits.
                .padding(.bottom, 20)
            #endif
    }

    private func centerPulledBook() {
        guard mode == .stack, !pullOut.upright, let id = pullOut.book?.id,
            pullOut.showsText || pullOut.isReturning
        else { return }
        centeredID = id
    }

    /// The books you have read, as on the Apple TV's default shelf. Current reads, Want to Read,
    /// and other unread shelves stay off.
    private var readBooks: [CloudBook] { model.books.filter(\.hasBeenRead) }

    /// The books of `read` in the chosen time and order.
    private func shownBooks(of read: [CloudBook]) -> [CloudBook] {
        var books = sort.sorted(time.books(in: read))
        #if DEBUG
            // `-BookwormsShareSamples <n>` adds fictional reviews for the details' Journal.
            books = ShareDebug.samples(books)
        #endif
        return books
    }

    /// Returns to the first book after the time or order changes.
    private func recenter() {
        pullOut.close()
        guard model.library != nil else { return }
        centeredID = shownBooks(of: readBooks).first?.id
    }

    #if DEBUG
        /// Simulator screenshot hooks, read once the library loads:
        /// `-BookwormsShelfScrollTo <index>` centers the book at that index,
        /// `-BookwormsShelfGlideTo <index>` centers the book at that index three seconds later,
        /// gliding there from nearby, and `-BookwormsOpenBook <bookID>` centers that
        /// book and, two seconds later, pulls it out to its details, or pushes them with Reduce
        /// Motion on.
        private func applyDebugArguments() {
            guard model.library != nil else { return }
            let books = shownBooks(of: readBooks)
            let defaults = UserDefaults.standard
            if let index = defaults.string(forKey: "BookwormsShelfScrollTo").flatMap(Int.init),
                books.indices.contains(index)
            {
                centeredID = books[index].id
            }
            if let index = defaults.string(forKey: "BookwormsShelfGlideTo").flatMap(Int.init),
                books.indices.contains(index)
            {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    centeredID = books[index].id
                }
            }
            if let id = defaults.string(forKey: "BookwormsOpenBook").flatMap(Int.init),
                path.isEmpty
            {
                centeredID = id
                if reduceMotion {
                    path = [id]
                } else if let book = books.first(where: { $0.id == id }) {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        pullOut.pull(book, upright: mode == .shelf)
                    }
                }
            }
        }
    #endif
}

/// Library's bar: its title, or, while a book's details show over the shelf, **Back** and the
/// book's **Share**.
///
/// On the iPhone, the bar hides while `LibraryFooter` names the library under the books, which
/// run up to the screen's top edge, and shows for a book's details and for the screens without
/// a library or read books. A time without books keeps the footer, for **View options**. On the
/// Mac, the toolbar keeps the title, with the time and the number of books as its subtitle and
/// **View options** at its trailing end.
///
/// A modifier of its own, so a book's pull-out and return update only the bar, not the
/// library's body, which sorts the library.
private struct LibraryBar: ViewModifier {
    let pullOut: ShelfPullOut
    /// **View options** and the status, or `nil` without a library or read books.
    let options: LibraryOptions?

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            // Details over the shelf show no title, as pushed details do. Hidden, the title
            // still names Library for the back button of details that push.
            .navigationTitle(pullOut.showsDetails ? "" : "Library")
            #if os(macOS)
                .navigationSubtitle(pullOut.showsDetails ? "" : options?.status ?? "")
            #endif
            .navigationBarTitleDisplayMode(.inline)
            #if os(iOS)
                .toolbarVisibility(
                    options != nil && !pullOut.showsDetails ? .hidden : .automatic,
                    for: .navigationBar)
            #endif
            .toolbar {
                if let book = pullOut.book, pullOut.showsDetails {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { pullOut.putBack() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Share", systemImage: "square.and.arrow.up") {
                            pullOut.keepsForShare = true
                            model.share(book)
                        }
                    }
                }
                #if os(macOS)
                    if let options, !pullOut.showsDetails {
                        ToolbarItem(placement: .primaryAction) { options }
                    }
                #endif
            }
    }
}

/// On the iPhone, the library's name and its status, such as "Last 12 Months · 39 books",
/// centered under the caption, with **View options** as a round glass button at the trailing
/// end, as Mail shows a mailbox's status beside its filter button.
///
/// It ignores touches while a book's details show, and takes them again as the book flies back;
/// a choice from the menu then puts the book back at once.
private struct LibraryFooter: View {
    let options: LibraryOptions
    let pullOut: ShelfPullOut

    var body: some View {
        HStack(spacing: 8) {
            // Balances the menu, so the text centers on the screen.
            button.hidden().accessibilityHidden(true)
            // Smaller than the caption, so the footer reads as the screen's status, not as
            // more about the centered book.
            VStack(spacing: 1) {
                Text("Library")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ShelfPalette.paper)
                // Breaks between the time and the count when the status does not fit on one line.
                ViewThatFits(in: .horizontal) {
                    Text(options.status)
                    VStack(spacing: 1) {
                        Text(options.time.title)
                        Text(options.books)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            // Names the screen for VoiceOver's headings, as the hidden bar's title did.
            .accessibilityAddTraits(.isHeader)
            button
        }
        .padding(.horizontal, 16)
        // A little more space above than between the caption's lines, so the footer reads as
        // the screen's own line, under the book's.
        .padding(.top, 6)
        .padding(.bottom, 8)
        // Larger sizes would take lines that the books need.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .allowsHitTesting(!pullOut.showsDetails)
    }

    private var button: some View {
        options
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }
}

/// The **View options** menu, which follows Photos: **View as**, **3D Books** for Stack,
/// **Time**, **Sort by**, and **Remove Filters** while the time differs from its default. Its
/// symbol fills meanwhile, as Mail's filter button does, and VoiceOver reads its value as
/// "Filtered".
private struct LibraryOptions: View {
    @Binding var mode: ShelfMode
    @Binding var sort: ShelfSort
    @Binding var time: LibraryTime
    /// The years with read books, newest first, for **Year**.
    let years: [Int]
    /// The books shown.
    let count: Int

    /// How **Stack** draws its books, which `SpineCarousel` reads.
    @AppStorage("BookwormsStackStyle") private var stackStyle = StackStyle.flat

    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 17

    /// The time and the number of books shown, such as "Last 12 Months · 39 books".
    var status: String { "\(time.title) · \(books)" }
    /// The number of books shown, such as "39 books".
    var books: String { FrameChip.books(count, of: count) }

    /// Whether the time differs from its default.
    private var isFiltered: Bool { time != .last12Months }

    var body: some View {
        Menu {
            menu
        } label: {
            Label(
                "View options",
                systemImage: isFiltered
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
            )
            #if os(iOS)
                .labelStyle(.iconOnly)
                // The filled symbol is larger, so a fixed frame keeps the glass button's size.
                .frame(width: icon, height: icon)
            #endif
        }
        .accessibilityValue(isFiltered ? "Filtered" : "")
    }

    @ViewBuilder private var menu: some View {
        Picker("View as", selection: $mode) {
            ForEach(ShelfMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        if mode == .stack {
            Section {
                Toggle(
                    "3D Books", systemImage: "cube",
                    isOn: Binding {
                        stackStyle == .threeD
                    } set: {
                        stackStyle = $0 ? .threeD : .flat
                    })
            }
        }
        Picker("Time", selection: $time) {
            ForEach(LibraryTime.spans, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        if !years.isEmpty {
            Section {
                Picker("Year", selection: $time) {
                    ForEach(years, id: \.self) { Text(String($0)).tag(LibraryTime.year($0)) }
                }
                .pickerStyle(.menu)
            }
        }
        Section {
            // A submenu, which names the order it holds, unlike an inline picker, and keeps
            // the menu short enough not to scroll.
            Picker("Sort by", selection: $sort) {
                ForEach(ShelfSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
        }
        if isFiltered {
            Section {
                Button("Remove Filters", systemImage: "xmark.circle") { time = .last12Months }
            }
        }
    }
}

/// The details of the book with `id`, which Library and Desk push, or why they are missing.
struct PushedBookDetail: View {
    let id: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        if let book = model.books.first(where: { $0.id == id }) {
            BookDetailView(book: book)
        } else {
            ContentUnavailableView(
                "Book unavailable", systemImage: "book.closed",
                description: Text("The latest library no longer includes this book."))
        }
    }
}

/// The centered book's title, author, and reading record.
///
/// Reads `centeredID` itself, so a new centered book updates only this caption. The caption
/// keeps a fixed, Dynamic Type–scaled height so the carousel above it never resizes mid-scroll.
/// Its text sits at the bottom, on the footer, so the two read as one block under the books; the
/// height fits a two-line title over a finish date and rating, and a one-line title leaves the
/// space above it.
private struct ShelfCaption: View {
    let books: [CloudBook]
    @Binding var centeredID: Int?
    @ScaledMetric(relativeTo: .title3) private var height: CGFloat = 120
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
            BookText(book.title, of: book)
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
            let reads = ShelfLabels.reads(book.readCount).map(ReadCountBadge.init)
            let stars = book.rating.flatMap { $0 > 0 ? RatingStars(rating: $0) : nil }
            // Stacks the date over the badge and stars when large text leaves no room for all,
            // so the date keeps a line to itself, and gives each its own line when the badge and
            // stars don't fit side by side either.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    finished
                    reads
                    stars
                }
                VStack(spacing: 4) {
                    finished
                    HStack(spacing: 8) {
                        reads
                        stars
                    }
                }
                VStack(spacing: 4) {
                    finished
                    reads
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
        .frame(height: height, alignment: .bottom)
        .accessibilityElement(children: .combine)
    }
}

/// How many times the reader finished a reread, such as "Read 3 times", in a small capsule.
struct ReadCountBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            // Brighter than the caption's secondary text, so it keeps above 4.5:1 contrast on
            // the lighter capsule.
            .foregroundStyle(ShelfPalette.paper.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(ShelfPalette.paper.opacity(0.12), in: .capsule)
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

extension CloudBook {
    /// Whether the reader has read the book: it is on their **Read** shelf or has a finish date,
    /// and is not a current read. This matches the Apple TV's default shelf.
    var hasBeenRead: Bool { isReading != true && (isRead == true || finished != nil) }

    /// The start date of the current or last read, parsed at noon UTC like `finishedDate`.
    var startedDate: Date? {
        guard let started, started.count >= 10 else { return nil }
        return try? Date(String(started.prefix(10)) + "T12:00:00Z", strategy: .iso8601)
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

    /// The SF Symbol for a `format(_:)` label, as the Apple TV shows it, such as "headphones" for
    /// "Audiobook".
    static func formatSymbol(_ label: String) -> String {
        switch label {
        case "Audiobook": "headphones"
        case "Ebook": "ipad"
        case "Physical & audiobook": "books.vertical"
        default: "book.closed"
        }
    }

    /// "Read 3 times" for a book finished more than once, else `nil`.
    static func reads(_ count: Int) -> String? { count > 1 ? "Read \(count) times" : nil }

    /// How long the reader took, counting both the start and finish days, such as "12 days".
    /// Returns `nil` without both dates or when they are out of order.
    static func readingTime(from started: Date?, to finished: Date?) -> String? {
        guard let started, let finished, started <= finished else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let days = calendar.dateComponents([.day], from: started, to: finished).day else {
            return nil
        }
        return days == 0 ? "1 day" : "\((days + 1).formatted()) days"
    }

    /// The book's length: listening time for an audiobook when Hardcover records it, such as
    /// "12 hr, 5 min", otherwise the page count, such as "352 pages". Returns `nil` without
    /// either.
    static func length(
        of book: CloudBook, width: Duration.UnitsFormatStyle.UnitWidth = .abbreviated
    ) -> String? {
        if format(book.format) == "Audiobook", let seconds = book.audioSeconds, seconds > 0 {
            return Duration.seconds(seconds)
                .formatted(.units(allowed: [.hours, .minutes], width: width))
        }
        return pages(of: book)
    }

    /// The book's page count, such as "352 pages", whatever format the reader chose. Returns `nil`
    /// without one.
    static func pages(of book: CloudBook) -> String? {
        // Hardcover records 0 pages for some audiobooks; the Apple TV omits those too.
        guard let pages = book.pages, pages > 0 else { return nil }
        return "\(pages.formatted()) pages"
    }
}
