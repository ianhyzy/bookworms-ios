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
    /// Set to find a book: the iPhone opens its finder, and the Mac focuses the toolbar's search
    /// field (`LibrarySearch`).
    @State private var findsBook = false
    /// The book whose **Change Cover** a context menu or the **Library** menu chose.
    @State private var coverBook: CloudBook?
    /// How far the status bar and the Dynamic Island reach down from the screen's top edge.
    @State private var statusBar: CGFloat = 0
    @Namespace private var namespace
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        let read = readBooks
        let books = model.library == nil ? [] : shownBooks(of: read)
        let options = options(read: read, books: books)
        NavigationStack(path: $path) {
            content(read: read, books: books, options: options)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { WalnutWall().ignoresSafeArea() }
                .modifier(
                    LibraryBar(pullOut: pullOut, options: options, showsAccount: $showsAccount)
                )
                .navigationDestination(for: Int.self) { id in
                    PushedBookDetail(id: id, tab: .library)
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
        .sheet(item: $coverBook) { book in
            // As the details' **Change cover** shows it: over the room, and for the book whose
            // cover sets the spine of a series that shares a design.
            CoverPickerView(book: model.designSource(for: book)) {}
                .preferredColorScheme(.dark)
        }
        // What the menu bar's **Library** and **View** commands act on (`LibraryCommands`).
        .focusedSceneValue(
            \.libraryActions,
            options.map { options in
                LibraryActions(
                    years: options.years, find: { findsBook = true }, open: open,
                    changeCover: { coverBook = $0 })
            }, in: .library
        )
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
                    LibraryFooter(
                        options: options, pullOut: pullOut, findsBook: $findsBook,
                        showsAccount: $showsAccount)
                #endif
            }
            .modifier(ShelfPullOutStage(pullOut: pullOut))
            .modifier(
                LibrarySearch(
                    books: books, centeredID: $centeredID, findsBook: $findsBook,
                    pullOut: pullOut, open: open))
        } else if model.library == nil {
            NoLibraryView(showsAccount: $showsAccount)
        } else {
            NoBooksYetView()
        }
    }

    /// Says that the time has no books, and offers **Show all time**.
    private var noBooksInTime: some View {
        // Scrolls so that at accessibility sizes the actions stay above the footer.
        ScrollView {
            ContentUnavailableView {
                Label(noBooksTitle, systemImage: "calendar")
            } description: {
                Text("Books you finish in this time appear here.")
            } actions: {
                if time != .allTime {
                    Button("Show all time") { time = .allTime }
                }
            }
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }

    /// The empty time's title, such as "No books in the last 12 months", as a sentence.
    private var noBooksTitle: String {
        switch time {
        case .last12Months: "No books in the last 12 months"
        case .thisYear: "No books this year"
        case .last5Years: "No books in the last 5 years"
        case .allTime: "No books yet"
        case .year(let year): "No books in \(String(year))"
        }
    }

    /// The carousel and its caption.
    @ViewBuilder private func carousel(_ books: [CloudBook]) -> some View {
        SpineCarousel(
            books: books, mode: mode, centeredID: $centeredID, namespace: namespace,
            pullOut: pullOut, statusBar: statusBar, changeCover: { coverBook = $0 }, open: open
        )
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

    /// Opens `book`'s details, from a click or tap, the keyboard, a search, or a menu. Does
    /// nothing while other details show.
    ///
    /// On the Mac, with Option held, as for Option-click or Option-Return, it opens them in a
    /// window of their own (`BookWindow`) instead.
    private func open(_ book: CloudBook) {
        #if os(macOS)
            if NSEvent.modifierFlags.contains(.option) {
                return openWindow(id: BookWindow.id, value: book.id)
            }
        #endif
        guard pullOut.book == nil, path.isEmpty else { return }
        if reduceMotion {
            path.append(book.id)
        } else if mode == .stack, centeredID != book.id {
            // The stack glides the book to the middle of the screen first, as it centers the
            // book for the return (`centerPulledBook`), so the book slides out in full view,
            // clear of the stack's ends, where the stack's faded copy would otherwise hand off
            // to the flight's opaque one.
            centeredID = book.id
            Task {
                try? await Task.sleep(for: .seconds(SpineCarousel.glide))
                if mode == .stack { pullOut.pull(book, upright: false) }
            }
        } else {
            pullOut.pull(book, upright: mode == .shelf)
        }
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
        /// Whether `-BookwormsShelfSweep` has started, which it does once per launch.
        private static var sweeps = false

        /// Simulator screenshot hooks, read once the library loads:
        /// `-BookwormsShelfScrollTo <index>` centers the book at that index,
        /// `-BookwormsShelfGlideTo <index>` centers the book at that index three seconds later,
        /// gliding there from nearby, `-BookwormsShelfSweep <count>` moves the center to the next
        /// book `count` times, every 0.15 seconds from three seconds later, so a CPU or frame-time
        /// recording sees the carousel scroll without a touch, and `-BookwormsOpenBook <bookID>`
        /// centers that book and, two seconds later, pulls it out to its details, or pushes them
        /// with Reduce Motion on.
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
            if let count = defaults.string(forKey: "BookwormsShelfSweep").flatMap(Int.init),
                !Self.sweeps
            {
                Self.sweeps = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    for _ in 0..<count {
                        let shown = shownBooks(of: readBooks)
                        // Before any scroll, no book is centered yet, so the sweep starts at the first.
                        let index = shown.firstIndex { $0.id == centeredID } ?? 0
                        guard index + 1 < shown.count else { break }
                        centeredID = shown[index + 1].id
                        try? await Task.sleep(for: .seconds(0.15))
                    }
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
/// Mac, the toolbar keeps the title, with the sync status as its subtitle, the time and the
/// number of books in its middle (`LibraryTimeChip`), and **View as**, the search field
/// (`LibrarySearch`), and **View options** at its trailing end.
///
/// A modifier of its own, so a book's pull-out and return, and a sync, update only the bar, not
/// the library's body, which sorts the library.
private struct LibraryBar: ViewModifier {
    let pullOut: ShelfPullOut
    /// **View options** and the status, or `nil` without a library or read books.
    let options: LibraryOptions?
    @Binding var showsAccount: Bool

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let details = pullOut.showsDetails ? pullOut.book : nil
        content
            #if os(macOS)
                // The window takes the name of the book whose details show, for the Window menu
                // and Mission Control.
                .navigationTitle(details?.title ?? "Library")
                .navigationSubtitle(
                    details?.author ?? (options == nil ? "" : LibrarySync(model: model).status))
            #else
                // Details over the shelf show no title, as pushed details do. Hidden, the title
                // still names Library for the back button of details that push.
                .navigationTitle(details == nil ? "Library" : "")
            #endif
            .navigationBarTitleDisplayMode(.inline)
            #if os(iOS)
                .toolbarVisibility(
                    options != nil && details == nil ? .hidden : .automatic, for: .navigationBar)
            #endif
            .focusedSceneValue(
                \.goBack, details == nil ? nil : SceneAction(perform: pullOut.putBack),
                in: .library
            )
            .toolbar {
                if let book = details {
                    ToolbarItem(placement: .topBarLeading) {
                        // Escape goes back too, without the keyboard focus that an exit command
                        // needs; Command-[ is **Go > Back**.
                        Button("Back", systemImage: "chevron.backward") { pullOut.putBack() }
                            .keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Share", systemImage: "square.and.arrow.up") {
                            pullOut.keepsForShare = true
                            model.share(book)
                        }
                    }
                }
                #if os(macOS)
                    if let options, details == nil {
                        ToolbarItem(placement: .principal) { LibraryTimeChip(options: options) }
                        ToolbarItem(placement: .primaryAction) {
                            ShelfModePicker(mode: options.$mode)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            options.menu(showsAccount: $showsAccount)
                        }
                    }
                #endif
            }
    }
}

/// On the iPhone, the library's status, such as "Last 12 months · 39 books" over "Synced 2:41
/// PM", centered under the caption, between **View as** at the leading end and **Find a book**
/// and **View options** in a glass capsule at the trailing end, as Mail shows a mailbox's status
/// beside its filter button. A failed sync shows **Couldn't sync · Retry**, which syncs again.
/// VoiceOver reads the status as the screen's heading, named "Library".
///
/// It ignores touches while a book's details show, and takes them again as the book flies back;
/// a choice from the menu then puts the book back at once.
private struct LibraryFooter: View {
    let options: LibraryOptions
    let pullOut: ShelfPullOut
    @Binding var findsBook: Bool
    @Binding var showsAccount: Bool

    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var button: CGFloat = 44

    var body: some View {
        let sync = LibrarySync(model: model)
        // The sides share the width the status leaves, so the status centers on the screen.
        HStack(spacing: 8) {
            ShelfModePicker(mode: options.$mode)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Smaller than the caption, so the footer reads as the screen's status, not as
            // more about the centered book.
            VStack(spacing: 1) {
                // Breaks between the time and the count when the status does not fit on one line.
                ViewThatFits(in: .horizontal) {
                    Text(options.status)
                    VStack(spacing: 1) {
                        Text(options.time.title)
                        Text(options.books)
                    }
                }
                .foregroundStyle(ShelfPalette.paper)
                .monospacedDigit()
                if sync.failed {
                    Button(sync.status + " · Retry") { Task { await model.syncLibrary() } }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sync.status)
                        .accessibilityHint("Syncs the library again.")
                } else {
                    Text(sync.status)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Library")
            // Names the screen for VoiceOver's headings, as the hidden bar's title did.
            .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                Button("Find a book", systemImage: "magnifyingglass") { findsBook = true }
                    .frame(width: button, height: button)
                options.menu(showsAccount: $showsAccount)
                    .frame(width: button, height: button)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .contentShape(.capsule)
            .padding(.horizontal, 2)
            .glassEffect(.regular.interactive(), in: .capsule)
            .frame(maxWidth: .infinity, alignment: .trailing)
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
}

/// **View as**: a segmented control of **Stack** and **Shelf**, in the iPhone's footer and the
/// Mac's toolbar.
private struct ShelfModePicker: View {
    @Binding var mode: ShelfMode

    var body: some View {
        Picker("View as", selection: $mode) {
            ForEach(ShelfMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .fixedSize()
        #if os(iOS)
            .labelsHidden()
            .controlSize(.large)
        #else
            .help("View as Stack or Shelf")
        #endif
    }
}

/// The library's sync status, such as "Synced 2:41 PM", "Syncing…", or "Couldn't sync", for
/// the iPhone's footer and the Mac's subtitle. Read in the views that show it, so a sync
/// updates only them.
///
/// It names the time of day for a sync today and the date for an earlier one, which stays true
/// without updating as time passes.
@MainActor
struct LibrarySync {
    let model: AppModel

    /// Whether the last sync, or the last load of the library, failed.
    var failed: Bool { !model.isSyncingLibrary && model.syncFailure != nil }

    var status: String {
        if model.isSyncingLibrary { return "Syncing…" }
        if model.syncFailure != nil { return "Couldn't sync" }
        guard let synced = model.library?.syncedAt else { return "Not synced yet" }
        return "Synced " + Self.time(of: synced)
    }

    /// "2:41 PM" for a time today, and otherwise the date, such as "Oct 17, 2026".
    nonisolated static func time(
        of date: Date, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .omitted)
    }
}

extension AppModel {
    /// Syncs the library: downloads it from Hardcover when this device is signed in, and
    /// otherwise loads the library in iCloud, or the preview folder, again.
    func syncLibrary() async {
        if account.isSignedIn && !isPreview { await account.sync() } else { await reload() }
    }

    /// Whether a sync or a load of the library is running.
    var isSyncingLibrary: Bool { account.isSyncing || isLoading }

    /// Why the last download from Hardcover or load of the library failed, if either did.
    var syncFailure: String? {
        (account.isSignedIn && !isPreview ? account.syncError : nil) ?? loadError
    }
}

/// On the Mac, the toolbar's middle button, which names Library's time and the number of books
/// it shows, such as "Last 12 months" and "39", and chooses the time, as Desk's time frame button
/// does for Desk.
private struct LibraryTimeChip: View {
    let options: LibraryOptions

    var body: some View {
        Menu {
            options.timeChoices
        } label: {
            HStack(spacing: 10) {
                Label(options.time.title, systemImage: "calendar")
                Label(options.count.formatted(), systemImage: "books.vertical")
            }
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
        }
        .help("Choose the time Library shows")
        .accessibilityLabel("Time")
        .accessibilityValue(options.status)
    }
}

/// **View options**, Library's options, and its status. The menu follows Photos: **3D Books**
/// for Stack, **Time**, **Sort by**, and **Remove Filters** while the time differs from its
/// default, then **Sync Now** and **Hardcover Account…**. Its symbol fills while the time
/// differs from its default, as Mail's filter button does, and VoiceOver reads its value as
/// "Filtered". **View as** has its own control (`ShelfModePicker`).
@MainActor
struct LibraryOptions {
    @Binding var mode: ShelfMode
    @Binding var sort: ShelfSort
    @Binding var time: LibraryTime
    /// The years with read books, newest first, for **Year**.
    let years: [Int]
    /// The books shown.
    let count: Int

    /// The time and the number of books shown, such as "Last 12 months · 39 books".
    var status: String { "\(time.title) · \(books)" }
    /// The number of books shown, such as "39 books".
    var books: String { FrameChip.books(count, of: count) }

    /// Whether the time differs from its default.
    var isFiltered: Bool { time != .last12Months }

    /// The **View options** menu.
    func menu(showsAccount: Binding<Bool>) -> some View {
        LibraryOptionsMenu(options: self, showsAccount: showsAccount)
    }

    /// The spans, and a **Year** menu of the years with read books.
    @ViewBuilder var timeChoices: some View {
        Picker("Time", selection: $time) {
            ForEach(LibraryTime.spans, id: \.self) { Text($0.menuTitle).tag($0) }
        }
        .pickerStyle(.inline)
        if !years.isEmpty {
            Picker("Year", selection: $time) {
                ForEach(years, id: \.self) { Text(String($0)).tag(LibraryTime.year($0)) }
            }
            .pickerStyle(.menu)
        }
    }
}

private struct LibraryOptionsMenu: View {
    let options: LibraryOptions
    @Binding var showsAccount: Bool

    @Environment(AppModel.self) private var model
    /// How **Stack** draws its books, which `SpineCarousel` reads.
    @AppStorage("BookwormsStackStyle") private var stackStyle = StackStyle.flat

    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 17

    var body: some View {
        Menu {
            menu
        } label: {
            Label(
                "View options",
                systemImage: options.isFiltered
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
            )
            #if os(iOS)
                .labelStyle(.iconOnly)
                // The filled symbol is larger, so a fixed frame keeps the glass button's size.
                .frame(width: icon, height: icon)
            #endif
        }
        .accessibilityValue(options.isFiltered ? "Filtered" : "")
    }

    @ViewBuilder private var menu: some View {
        if options.mode == .stack {
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
        Section("Time") { options.timeChoices }
        Section {
            // A submenu, which names the order it holds, unlike an inline picker, and keeps
            // the menu short enough not to scroll.
            Picker(selection: options.$sort) {
                ForEach(ShelfSort.allCases) { Text($0.menuTitle).tag($0) }
            } label: {
                Label("Sort by", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
        }
        if options.isFiltered {
            Section {
                Button("Remove Filters", systemImage: "xmark.circle") {
                    options.time = .last12Months
                }
            }
        }
        Section {
            Button("Sync Now", systemImage: "arrow.clockwise") {
                Task { await model.syncLibrary() }
            }
            .disabled(model.isSyncingLibrary)
            Button("Hardcover Account…", systemImage: "person.crop.circle") {
                showsAccount = true
            }
        }
    }
}

/// What the menu bar's **Library** and **View** commands act on while Library shows its books
/// (`LibraryCommands`).
struct LibraryActions {
    /// The years with read books, newest first, for the **Time** menu's years.
    let years: [Int]
    /// Finds a book: focuses the toolbar's search field.
    let find: @MainActor () -> Void
    /// Opens a book's details, as a click does.
    let open: @MainActor (CloudBook) -> Void
    /// Opens **Change Cover** for a book.
    let changeCover: @MainActor (CloudBook) -> Void
}

/// Finds a book in the shown books, as find rather than a filter: the carousel glides to the
/// best match, the caption names it, and Return pulls it out.
///
/// On the Mac, a search field in the toolbar (**Library > Find Book**, Command-F) glides to the
/// best match as you type, and its suggestions list the matches; choosing one fills in its title.
/// On the iPhone, **Find a book** in the footer opens a list of the books that a search field
/// narrows; choosing one glides to it. Searching ignores keystrokes while a book's details show,
/// so the stack never moves behind them.
///
/// A modifier of its own, with the search text as its own state, so typing updates only it, not
/// the library's body, which sorts the library.
private struct LibrarySearch: ViewModifier {
    let books: [CloudBook]
    @Binding var centeredID: Int?
    /// Set to find a book; the Mac focuses its search field and clears it.
    @Binding var findsBook: Bool
    let pullOut: ShelfPullOut
    let open: (CloudBook) -> Void

    @State private var text = ""
    #if os(macOS)
        @FocusState private var isFocused: Bool
    #else
        /// The book that Return in the finder chose, which opens once the finder closes.
        @State private var opening: CloudBook?
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
            content
                .searchable(text: $text, placement: .toolbar, prompt: "Find a book")
                .searchSuggestions {
                    ForEach(BookFinding.matches(text, in: books).prefix(8)) { book in
                        BookFinderRow(book: book).searchCompletion(book.title)
                    }
                }
                .searchFocused($isFocused)
                .onChange(of: text) {
                    guard pullOut.book == nil, let book = BookFinding.matches(text, in: books).first
                    else { return }
                    centeredID = book.id
                }
                .onSubmit(of: .search) {
                    if let book = BookFinding.matches(text, in: books).first { open(book) }
                }
                .onChange(of: findsBook) {
                    guard findsBook else { return }
                    findsBook = false
                    isFocused = true
                }
                #if DEBUG
                    .onAppear { if let query = Self.debugQuery { text = query } }
                #endif
        #else
            content
                .sheet(isPresented: $findsBook, onDismiss: openChosenBook) {
                    BookFinder(books: books) { book, opens in
                        centeredID = book.id
                        if opens { opening = book }
                    }
                }
                #if DEBUG
                    .onAppear { if Self.debugQuery != nil { findsBook = true } }
                #endif
        #endif
    }

    #if DEBUG
        /// Simulator hook: `-BookwormsFindBook <text>` searches for that text when Library
        /// appears, in the Mac's search field or the iPhone's finder.
        static var debugQuery: String? { UserDefaults.standard.string(forKey: "BookwormsFindBook") }
    #endif

    #if os(iOS)
        private func openChosenBook() {
            if let opening { open(opening) }
            opening = nil
        }
    #endif
}

/// How Library finds a book (`LibrarySearch`).
enum BookFinding {
    /// The books of `books` whose title or author contains `query`, ignoring case and accents,
    /// in their shown order, those whose title starts with it first. Empty for an empty query.
    static func matches(_ query: String, in books: [CloudBook]) -> [CloudBook] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let found = books.filter {
            $0.title.localizedStandardContains(query) || $0.author.localizedStandardContains(query)
        }
        let starts = found.filter {
            $0.title.range(
                of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive])
                != nil
        }
        let startIDs = Set(starts.map(\.id))
        return starts + found.filter { !startIDs.contains($0.id) }
    }
}

/// A book in the search's suggestions and the iPhone's finder: its title over its author and
/// finish date.
private struct BookFinderRow: View {
    let book: CloudBook

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.title).lineLimit(2)
            Text(details)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        guard let finished = book.finishedDate else { return book.author }
        return book.author + " · Finished "
            + finished.formatted(ShelfLabels.finishedFormat)
    }
}

#if os(iOS)
    /// The iPhone's **Find a book** sheet: the shown books, which a search field narrows by title
    /// or author. Choosing a book glides the shelf to it; Return chooses the best match and pulls
    /// it out once the sheet closes.
    private struct BookFinder: View {
        let books: [CloudBook]
        /// Glides to a book, and with `opens`, pulls it out.
        let choose: (_ book: CloudBook, _ opens: Bool) -> Void

        @Environment(\.dismiss) private var dismiss
        @State private var text = ""
        @FocusState private var isFocused: Bool

        var body: some View {
            let matches = text.isEmpty ? books : BookFinding.matches(text, in: books)
            NavigationStack {
                List(matches) { book in
                    Button {
                        choose(book, false)
                        dismiss()
                    } label: {
                        BookFinderRow(book: book)
                    }
                    .foregroundStyle(.primary)
                }
                .overlay {
                    if matches.isEmpty { ContentUnavailableView.search(text: text) }
                }
                .navigationTitle("Find a book")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                }
                .searchable(
                    text: $text, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Title or author"
                )
                .searchFocused($isFocused)
                .onSubmit(of: .search) {
                    guard let book = matches.first else { return }
                    choose(book, true)
                    dismiss()
                }
                .onAppear {
                    isFocused = true
                    #if DEBUG
                        if let query = LibrarySearch.debugQuery { text = query }
                    #endif
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
#endif

/// The details of the book with `id`, which Library and Desk push, or why they are missing.
struct PushedBookDetail: View {
    let id: Int
    /// The tab whose navigation stack holds the details, or `nil` in a book's own window
    /// (`BookWindow`), which has nothing to go back to.
    let tab: AppTab?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let book = model.books.first { $0.id == id }
        Group {
            if let book {
                BookDetailView(book: book)
            } else {
                ContentUnavailableView(
                    "Book unavailable", systemImage: "book.closed",
                    description: Text("The latest library no longer includes this book."))
            }
        }
        #if os(macOS)
            // The window takes the book's name, as details over the shelf give it.
            .navigationTitle(book?.title ?? "Book unavailable")
            .navigationSubtitle(book?.author ?? "")
        #endif
        // Dismissing pops the details off their navigation stack.
        .focusedSceneValue(
            \.goBack, tab.map { _ in SceneAction { dismiss() } }, in: tab ?? .library)
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

    // The Mac's text styles are smaller than the iPhone's, and its window is read from farther
    // away, so the caption steps each style up there.
    #if os(macOS)
        private static let positionFont = Font.callout.weight(.medium)
        private static let titleFont = Font.title2.weight(.semibold)
        private static let authorFont = Font.body
        private static let detailsFont = Font.body
    #else
        private static let positionFont = Font.caption2.weight(.medium)
        private static let titleFont = Font.title3.weight(.semibold)
        private static let authorFont = Font.subheadline
        private static let detailsFont = Font.footnote
    #endif

    var body: some View {
        let index = books.firstIndex { $0.id == centeredID } ?? 0
        let book = books[index]
        VStack(spacing: 5) {
            // The position is decorative, so accessibility sizes give its line to the title.
            if !typeSize.isAccessibilitySize {
                Text("\(index + 1) of \(books.count)")
                    .font(Self.positionFont)
                    .monospacedDigit()
                    // Dimmer than the title, and above 4.5:1 contrast on the walnut wall.
                    .foregroundStyle(ShelfPalette.paper.opacity(0.6))
                    .accessibilityHidden(true)
            }
            BookText(book.title, of: book)
                .font(Self.titleFont)
                .fontDesign(.serif)
                .lineLimit(2)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Text(book.author)
                .font(Self.authorFont)
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
            .font(Self.detailsFont)
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

    /// The order's name in title case, such as "Recently Finished", for menu items.
    var menuTitle: String { title.capitalized }

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
