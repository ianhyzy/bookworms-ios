import SwiftUI

/// The library as a stack of books or a bookcase of spines (`SpineCarousel`), with a caption for
/// the centered book, or in 3D, which shows the books in the chosen `ThreeDView`, such as a pile
/// on a table (`BookPileView`).
///
/// Both show the library snapshot that `AppModel` holds; sorting and filtering happen here when
/// the snapshot or the options change, never while scrolling.
///
/// A tapped book slides out of the carousel and floats into its details over the shelf
/// (`ShelfPullOut`), as a book the Pile lifts does. With Reduce Motion on, its details push
/// instead.
struct ShelfView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("BookwormsShelfMode") private var mode = ShelfPresentation.stack
    @AppStorage("BookwormsShelfSort") private var sort = ShelfSort.finished
    @AppStorage("BookwormsShelfDesignedOnly") private var designedOnly = false
    /// The 3D view the shelf shows.
    @AppStorage("BookwormsThreeDView") private var threeDView = ThreeDView.pile
    /// The 3D views' time frame as `TimeFrame.setting` writes it; empty for every book.
    /// `FrameChip` sets it. Until the reader chooses one, the views show the current year.
    @AppStorage(TimeFrame.pileSettingKey)
    private var pileFrameSetting = TimeFrame.defaultPileSetting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The centered book, shared by both carousel modes so switching keeps the reader's place.
    @State private var centeredID: Int?
    @State private var path: [Int] = []
    /// The book a 3D view lifted out of its scene to show its details, which replace the
    /// shelf's controls.
    @State private var liftedDetails = LiftedDetails()
    /// The book that Stack or Shelf pulled out to show its details over the shelf.
    @State private var pullOut = ShelfPullOut()
    @State private var showsAccount = false
    /// Set once the first launch outside preview mode has offered the Hardcover sheet.
    @AppStorage("BookwormsOfferedHardcover") private var offeredHardcover = false
    @Namespace private var namespace

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { ShelfPalette.wall.ignoresSafeArea() }
                .modifier(
                    ShelfBar(
                        pullOut: pullOut, liftedDetails: liftedDetails, mode: $mode,
                        sort: $sort, designedOnly: $designedOnly, threeDView: shownViewChoice,
                        pileFrame: mode == .pile ? pileFrame : nil)
                )
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
        // Hardcover is the library's own source, so the first launch offers it once.
        .task {
            guard !offeredHardcover, !model.isPreview else { return }
            offeredHardcover = true
            if !model.account.isSignedIn { showsAccount = true }
        }
        .onChange(of: sort) { recenter() }
        .onChange(of: designedOnly) { recenter() }
        // The shelf's controls return as a pulled-out book flies back, and a book can only
        // return to a spine that is still where it left it.
        .onChange(of: mode) { pullOut.close() }
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
                // Scrolls so that at accessibility sizes the actions stay above the tab bar.
                ScrollView {
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
                }
                .defaultScrollAnchor(.center, for: .alignment)
                // Keeps the time frame button, the only way to another period with designed
                // spines.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if mode == .pile {
                        FrameChip(
                            title: frame?.title ?? Self.years(of: model.books), shown: 0, total: 0)
                    }
                }
            } else if let carousel = mode.carousel {
                VStack(spacing: 0) {
                    SpineCarousel(
                        books: books, mode: carousel, centeredID: $centeredID, namespace: namespace,
                        pullOut: pullOut
                    ) { book in
                        if reduceMotion {
                            path.append(book.id)
                        } else {
                            pullOut.pull(book, upright: carousel == .shelf)
                        }
                    }
                    ShelfCaption(books: books, centeredID: $centeredID)
                        // Larger sizes overflow the caption's fixed height; the book's details
                        // show the same record at any size.
                        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                }
                .modifier(ShelfPullOutStage(pullOut: pullOut))
            } else {
                let title = frame?.title ?? Self.years(of: books)
                switch shownView {
                case .pile:
                    BookPileView(books: books, title: title, frame: frame, details: liftedDetails) {
                        path.append($0.id)
                    }
                case .dominoes:
                    DominoesView(books: books, title: title, details: liftedDetails) {
                        path.append($0.id)
                    }
                case .bookworm:
                    BookwormView(books: books, title: title)
                }
            }
        } else {
            NoLibraryView(showsAccount: $showsAccount)
        }
    }

    /// The chosen 3D view, or the Pile when the saved choice is one the app does not offer.
    private var shownView: ThreeDView {
        ThreeDView.offered.contains(threeDView) ? threeDView : .pile
    }

    /// Reads `shownView` and saves the reader's choice, for the **View** picker.
    private var shownViewChoice: Binding<ThreeDView> {
        Binding {
            shownView
        } set: {
            threeDView = $0
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
        #if DEBUG
            // `-BookwormsShareSamples <n>` also marks current reads here, for the pile's ribbons.
            books = ShareDebug.samples(books)
        #endif
        return books
    }

    /// Returns to the first book after the order or filter changes.
    private func recenter() {
        pullOut.close()
        guard let library = model.library else { return }
        centeredID = shownBooks(in: library).first?.id
    }

    #if DEBUG
        /// Simulator screenshot hooks, read once the library loads:
        /// `-BookwormsShelfScrollTo <index>` centers the book at that index, and
        /// `-BookwormsOpenBook <bookID>` centers that book and, two seconds later, pulls it out
        /// to its details, or pushes them with Reduce Motion on. In 3D, the Pile and Dominoes open
        /// the book themselves once their books are down or standing, and Bookworm ignores it.
        private func applyDebugArguments() {
            guard let library = model.library else { return }
            let books = shownBooks(in: library)
            let defaults = UserDefaults.standard
            if let index = defaults.string(forKey: "BookwormsShelfScrollTo").flatMap(Int.init),
                books.indices.contains(index)
            {
                centeredID = books[index].id
            }
            if let carousel = mode.carousel,
                let id = defaults.string(forKey: "BookwormsOpenBook").flatMap(Int.init),
                path.isEmpty
            {
                centeredID = id
                if reduceMotion {
                    path = [id]
                } else if let book = books.first(where: { $0.id == id }) {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        pullOut.pull(book, upright: carousel == .shelf)
                    }
                }
            }
        }
    #endif
}

/// The Shelf tab's title and bar: the presentation picker, **Sort and filter**, and in **Stack**
/// the **3D** toggle, or, while a book's details show over the shelf or a 3D view,
/// **Back** and the book's **Share**.
///
/// A modifier of its own, so a book's pull-out and return update only the bar, not the shelf's
/// body, which sorts the library.
private struct ShelfBar: ViewModifier {
    let pullOut: ShelfPullOut
    let liftedDetails: LiftedDetails
    @Binding var mode: ShelfPresentation
    @Binding var sort: ShelfSort
    @Binding var designedOnly: Bool
    /// The 3D view shown, for **View**.
    @Binding var threeDView: ThreeDView
    /// The 3D views' time frame while 3D shows, or `nil` for every book.
    let pileFrame: TimeFrame?

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How the pile follows the phone's tilt, which `BookPileView` reads.
    @AppStorage("BookwormsPileTiltMode") private var tilt = PileTilt.table
    /// Whether the pile drops period by period, which `BookPileView` reads.
    @AppStorage("BookwormsPileByPeriod") private var dropsByPeriod = false
    /// Whether collisions in 3D play sounds, which the 3D views read.
    @AppStorage("BookwormsThreeDSounds") private var sounds = true
    /// How the camera films the dominoes, which `DominoesView` reads.
    @AppStorage("BookwormsDominoCamera") private var dominoCamera = DominoCameraMode.overview
    /// How **Stack** draws its books, which `SpineCarousel` reads.
    @AppStorage("BookwormsStackStyle") private var stackStyle = StackStyle.flat

    /// Whether a 3D view shows a lifted book's details, with their own **Back** and **Share**.
    private var threeDShowsDetails: Bool { liftedDetails.lift != nil }

    func body(content: Content) -> some View {
        content
            // Details over the shelf show no title, as pushed details do.
            .navigationTitle(threeDShowsDetails || pullOut.showsDetails ? "" : "Shelf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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
        } else if !threeDShowsDetails {
            if mode == .stack {
                ToolbarItem(placement: .topBarLeading) {
                    // A cube rather than lettering, which would repeat the picker's 3D.
                    Toggle(
                        "3D", systemImage: "cube",
                        isOn: Binding {
                            stackStyle == .threeD
                        } set: {
                            stackStyle = $0 ? .threeD : .flat
                        }
                    )
                    .toggleStyle(.button)
                }
            }
            ToolbarItem(placement: .principal) {
                Picker("Presentation", selection: $mode) {
                    ForEach(ShelfPresentation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Sort and filter", systemImage: "line.3.horizontal.decrease") {
                    // In the menu rather than the bar, which the presentation picker and the
                    // pile's own buttons fill.
                    if mode == .pile {
                        if ThreeDView.offered.count > 1 {
                            Picker("View", systemImage: "cube", selection: $threeDView) {
                                ForEach(ThreeDView.offered) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.menu)
                        }
                        Section {
                            // Reduce Motion keeps the camera still, so it offers no Follow.
                            if threeDView == .dominoes && !reduceMotion {
                                Picker("Camera", systemImage: "video", selection: $dominoCamera) {
                                    ForEach(DominoCameraMode.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.menu)
                            }
                            Toggle("Sounds", systemImage: "speaker.wave.2", isOn: $sounds)
                            if threeDView == .pile && !reduceMotion {
                                Toggle(byPeriodTitle, systemImage: "calendar", isOn: $dropsByPeriod)
                            }
                            if threeDView == .pile && BookPileScene.canTilt && !reduceMotion {
                                Picker("Tilt", systemImage: "gyroscope", selection: $tilt) {
                                    ForEach(PileTilt.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.menu)
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
    }

    /// Names the drop by period for the time frame's periods.
    private var byPeriodTitle: String {
        switch pileFrame {
        case .year: "Drop by month"
        case .month: "Drop by week"
        case .lifetime, nil: "Drop by year"
        }
    }

}

/// The 3D views' time frame and book count, such as "2025" and "39", in a glass button under
/// the navigation bar. The button opens the time frame menu: **All books**, or a **Year** or
/// **Month** with finished books. Every 3D view shares the choice, and the app saves it.
///
/// A view places the button with `safeAreaInset(edge: .top, spacing: 0)` outside its viewport
/// reading, so its scene frames the books below the button.
struct FrameChip: View {
    /// The time frame's name, such as "2025", or the years that every book spans.
    let title: String
    /// The books the view shows, at most its cap.
    let shown: Int
    /// The books in the time frame that the view could show.
    let total: Int

    @Environment(AppModel.self) private var model
    @AppStorage(TimeFrame.pileSettingKey) private var setting = TimeFrame.defaultPileSetting

    var body: some View {
        Menu {
            options
        } label: {
            HStack(spacing: 12) {
                Label(title, systemImage: "calendar")
                Label(
                    total > shown
                        ? "\(shown.formatted()) of \(total.formatted())" : total.formatted(),
                    systemImage: "books.vertical")
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            // A long span and a capped count, such as "2009–2026" and "300 of 412", shrink
            // rather than wrap at the largest text size.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .buttonStyle(.glass)
        // At least 44 points tall, the minimum touch target.
        .controlSize(.large)
        // Stops growing at the largest standard size so accessibility sizes leave the scene its
        // room; the large content viewer shows the text at those sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer {
            Label("\(title), \(Self.books(shown, of: total))", systemImage: "calendar")
        }
        .accessibilityLabel("Time frame")
        .accessibilityValue("\(title), \(Self.books(shown, of: total))")
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// **All books**, and the years and months with finished books, newest first. Choosing one
    /// shows that period's books, which the Pile drops in a new pile.
    @ViewBuilder private var options: some View {
        // Reading finish dates parses them, so the chosen frame resolves once, not for each
        // picker.
        let periods = TimeFrame.periods(in: model.books)
        let current = TimeFrame.pileFrame(setting: setting, in: model.books)
        let frame = Binding {
            current
        } set: {
            setting = $0?.setting ?? ""
        }
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

    /// The number of books, such as "39 books", or "300 of 1,024 books" when the view shows
    /// fewer than the time frame has.
    static func books(_ shown: Int, of total: Int) -> String {
        if total > shown { return "\(shown.formatted()) of \(total.formatted()) books" }
        return total == 1 ? "1 book" : "\(total.formatted()) books"
    }
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
                "Connect Hardcover to bring in the books you've read, or turn on iCloud storage in the Bookworms app on your Apple TV.",
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

/// The shelf's presentations: the carousel's two modes and 3D, which shows a `ThreeDView`. The
/// raw values match `ShelfMode`, so a saved carousel mode carries over. 3D's raw value is
/// `pile`, which saved settings and `-BookwormsShelfMode pile` use.
enum ShelfPresentation: String, CaseIterable, Identifiable {
    case stack, shelf, pile

    var id: Self { self }
    /// The carousel mode, or `nil` for 3D.
    var carousel: ShelfMode? { ShelfMode(rawValue: rawValue) }
    var title: String { carousel?.title ?? "3D" }
}

/// The scenes 3D can show. Each takes the shelf's books within the time frame that all of them
/// share, and orders them as the view needs. Adding a view takes a case here, titled by its raw
/// value, its arm in `ShelfView.content`, and an entry in `offered`; **Sort and filter** offers
/// **View** once `offered` has two.
enum ThreeDView: String, CaseIterable, Identifiable {
    case pile
    case dominoes
    case bookworm

    /// The views the app shows. The Bookworm keeps its code but is not offered for now.
    static let offered: [ThreeDView] = [.pile, .dominoes]

    var id: Self { self }
    var title: String { rawValue.capitalized }
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
        // Hardcover records 0 pages for some audiobooks; the Apple TV omits those too.
        guard let pages = book.pages, pages > 0 else { return nil }
        return "\(pages.formatted()) pages"
    }
}
