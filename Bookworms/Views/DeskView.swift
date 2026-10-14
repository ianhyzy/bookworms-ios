import SwiftUI

/// The books on a desk under a lamp, in one 3D scene (`DeskScenes`): the Desk scene, which drops
/// them onto the desk to throw around (`BookPileView`), and the dominoes that **Set up
/// dominoes** turns them into, which stand on end and topple (`DominoesView`). Desk opens on the
/// Desk scene; **Back to desk** returns to it with the books where they lie.
///
/// The scenes show the read books and current reads finished within their own time frame,
/// which the bar's middle button chooses (`FrameChip`), apart from Library's. Filtering and
/// sorting happen here when the snapshot or the options change. A tapped book lifts out of the
/// scene into its details over it (`LiftedDetails`); with Reduce Motion on, or when the scene
/// cannot lift the book, its details push instead.
struct DeskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("BookwormsShelfSort") private var sort = ShelfSort.finished
    @AppStorage("BookwormsShelfDesignedOnly") private var designedOnly = false
    /// Whether the pile drops period by period, which **Back to desk** hands on.
    @AppStorage("BookwormsPileByPeriod") private var dropsByPeriod = false
    /// The scenes' time frame as `TimeFrame.setting` writes it; empty for every book.
    /// `FrameChip` sets it. Until the reader chooses one, the scenes show the current year.
    @AppStorage(TimeFrame.pileSettingKey) private var frameSetting = TimeFrame.defaultPileSetting
    @State private var path: [Int] = []
    /// The book a scene lifted out to show its details, which replace the desk's controls.
    @State private var liftedDetails = LiftedDetails()
    @State private var desk = DeskScenes()
    @State private var showsAccount = false

    /// The books the desk shows, and the bar's time frame button for them.
    private struct Shelf {
        /// The time frame's books, in the desk's order and filter.
        let books: [CloudBook]
        /// The books the Desk scene drops, which also stand as the dominoes.
        let dropped: [CloudBook]
        let chip: DeskBar.Chip?
    }

    var body: some View {
        let frame = frame
        let shelf = shelf(frame: frame)
        NavigationStack(path: $path) {
            content(shelf, frame: frame)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { ShelfPalette.wall.ignoresSafeArea() }
                .modifier(
                    DeskBar(
                        liftedDetails: liftedDetails, desk: desk, chip: shelf.chip, frame: frame,
                        sort: $sort, designedOnly: $designedOnly,
                        canSetUp: !shelf.dropped.isEmpty
                    ) {
                        switch desk.mode {
                        case .desk:
                            desk.setUpDominoes(books: shelf.dropped, reduceMotion: reduceMotion)
                        case .dominoes:
                            desk.backToDesk(
                                books: shelf.dropped, tidy: reduceMotion,
                                periods: BookPileView.periods(
                                    byPeriod: dropsByPeriod, reduceMotion: reduceMotion,
                                    frame: frame))
                        }
                    }
                )
                .navigationDestination(for: Int.self) { PushedBookDetail(id: $0) }
        }
        // The walnut backdrop is dark in both appearances, so text and bars use dark styles.
        .environment(\.colorScheme, .dark)
        .tint(ShelfPalette.lamp)
        // Outside the dark scheme and tint, so the account sheet follows the system appearance.
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
    }

    @ViewBuilder private func content(_ shelf: Shelf, frame: TimeFrame?) -> some View {
        if let library = model.library {
            if !library.books.contains(where: \.hasBeenRead) {
                NoBooksYetView()
            } else if shelf.books.isEmpty {
                // Only Designed only empties a scene: a time frame always has books.
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
                            if frame != nil { frameSetting = "" }
                        }
                    }
                }
                .defaultScrollAnchor(.center, for: .alignment)
            } else {
                let title = frame?.title ?? Self.years(of: shelf.books)
                ZStack {
                    if !desk.hidesView {
                        DeskSceneView { desk.attach(to: $0) }
                            .ignoresSafeArea()
                            .accessibilityHidden(true)
                    }
                    switch desk.mode {
                    case .desk:
                        BookPileView(
                            books: shelf.books, title: title, frame: frame, desk: desk,
                            details: liftedDetails
                        ) {
                            path.append($0.id)
                        }
                    case .dominoes:
                        DominoesView(
                            books: shelf.dropped, title: title, desk: desk,
                            details: liftedDetails
                        ) {
                            path.append($0.id)
                        }
                    }
                }
            }
        } else {
            NoLibraryView(showsAccount: $showsAccount)
        }
    }

    /// The scenes' time frame, or `nil` for every book.
    private var frame: TimeFrame? {
        TimeFrame.pileFrame(setting: frameSetting, in: model.books)
    }

    /// The years `books` were finished in, such as "2019–2026", for a scene of every book.
    private static func years(of books: [CloudBook]) -> String {
        let years = books.compactMap(\.finishedYear)
        guard let first = years.min(), let last = years.max() else { return "My books" }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    /// The books the desk shows in `frame`, and the time frame button, which shows once the
    /// library has read books.
    private func shelf(frame: TimeFrame?) -> Shelf {
        guard let library = model.library, library.books.contains(where: \.hasBeenRead) else {
            return Shelf(books: [], dropped: [], chip: nil)
        }
        let books = shownBooks(in: library, frame: frame)
        let dropped = Array(PileLayout.dropped(books, count: BookPileView.maximumBooks))
        let title = frame?.title ?? Self.years(of: books.isEmpty ? model.books : books)
        return Shelf(
            books: books, dropped: dropped,
            chip: DeskBar.Chip(title: title, shown: dropped.count, total: books.count))
    }

    /// The books in the chosen order and filter, and in `frame` when it is set.
    private func shownBooks(in library: LibrarySnapshot, frame: TimeFrame?) -> [CloudBook] {
        // The read books, as in Library, and current reads, which **All books** marks with
        // ribbons. Want to Read and other unread shelves stay off.
        var books = sort.sorted(model.books.filter { $0.hasBeenRead || $0.isReading == true })
        if designedOnly { books = books.filter { library.designs[$0.id] != nil } }
        if let frame { books = books.filter(frame.contains) }
        #if DEBUG
            // `-BookwormsShareSamples <n>` also marks current reads here, for the pile's ribbons.
            books = ShareDebug.samples(books)
        #endif
        return books
    }
}

/// Desk's bar: the time frame button in the middle and the options menu, which holds **Set up
/// dominoes** or **Back to desk**. While a lifted book's details show, they give way to the
/// details' **Back** and **Share** (`LiftedDetailsOverlay`).
///
/// A modifier of its own, so a book's lift and return update only the bar, not the desk's
/// body, which sorts the library.
private struct DeskBar: ViewModifier {
    /// What the time frame button shows: the time frame's name and the books it counts.
    struct Chip {
        let title: String
        let shown: Int
        let total: Int
    }

    let liftedDetails: LiftedDetails
    let desk: DeskScenes
    /// The time frame button, or `nil` while there is no time frame to choose.
    let chip: Chip?
    /// The scenes' time frame, or `nil` for every book, which names the drop by period.
    let frame: TimeFrame?
    @Binding var sort: ShelfSort
    @Binding var designedOnly: Bool
    /// Whether the desk has books to set up.
    let canSetUp: Bool
    /// **Set up dominoes** or **Back to desk**, for the scene that shows.
    let switchScene: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How the Desk scene follows the phone's tilt, which `BookPileView` reads.
    @AppStorage("BookwormsPileTiltMode") private var tilt = PileTilt.off
    /// Whether the pile drops period by period, which `BookPileView` reads.
    @AppStorage("BookwormsPileByPeriod") private var dropsByPeriod = false
    /// Whether collisions in 3D play sounds, which the 3D views read.
    @AppStorage("BookwormsThreeDSounds") private var sounds = true
    /// How the camera films the dominoes, which `DominoesView` reads.
    @AppStorage("BookwormsDominoCamera") private var dominoCamera = DominoCameraMode.overview

    func body(content: Content) -> some View {
        content
            // Details over the scene show no title, as pushed details do. The time frame button
            // takes the title's place.
            .navigationTitle(liftedDetails.lift == nil ? "Desk" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if liftedDetails.lift == nil {
                    if let chip {
                        ToolbarItem(placement: .principal) {
                            FrameChip(title: chip.title, shown: chip.shown, total: chip.total)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { options }
                }
            }
    }

    private var isDominoes: Bool { desk.mode == .dominoes }

    /// The scene's options, and the order and filter where they change the scene's books:
    /// Dominoes stand in finish order whatever the sort (`DominoLayout.chain(_:)`).
    private var options: some View {
        Menu("Desk options", systemImage: "ellipsis") {
            Section {
                if isDominoes {
                    Button("Back to desk", systemImage: "arrow.uturn.backward", action: switchScene)
                } else {
                    Button("Set up dominoes", systemImage: "books.vertical", action: switchScene)
                        // The books on the desk set up the chain, so they finish dropping first.
                        .disabled(!canSetUp || desk.pile.status.isDropping)
                }
            }
            Section {
                // Reduce Motion keeps the camera still, so it offers no Follow.
                if isDominoes && !reduceMotion {
                    Picker("Camera", systemImage: "video", selection: $dominoCamera) {
                        ForEach(DominoCameraMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Sounds", systemImage: "speaker.wave.2", isOn: $sounds)
                if !isDominoes && !reduceMotion {
                    Toggle(byPeriodTitle, systemImage: "calendar", isOn: $dropsByPeriod)
                }
                if !isDominoes && BookPileScene.canTilt && !reduceMotion {
                    Picker("Tilt", systemImage: "gyroscope", selection: $tilt) {
                        ForEach(PileTilt.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            Section {
                // The pile drops its first books first, up to its maximum.
                if !isDominoes {
                    Picker("Sort by", selection: $sort) {
                        ForEach(ShelfSort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Designed only", isOn: $designedOnly)
            }
        }
    }

    /// Names the drop by period for the time frame's periods.
    private var byPeriodTitle: String {
        switch frame {
        case .year: "Drop by month"
        case .month: "Drop by week"
        case .lifetime, nil: "Drop by year"
        }
    }
}

/// The scenes' time frame and book count, such as "2025" and "39", in a button in the middle of
/// the navigation bar. The button opens the time frame menu: **All books**, or a **Year** or
/// **Month** with finished books. Every 3D view shares the choice, and the app saves it.
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
            HStack(spacing: 10) {
                Label(title, systemImage: "calendar")
                Label(
                    total > shown
                        ? "\(shown.formatted()) of \(total.formatted())" : total.formatted(),
                    systemImage: "books.vertical")
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            // A long span and a capped count, such as "2009–2026" and "300 of 412", shrink
            // rather than wrap at the largest text size.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 6)
        }
        // Stops growing at the largest standard size so accessibility sizes leave the bar its
        // room; the large content viewer shows the text at those sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer {
            Label("\(title), \(Self.books(shown, of: total))", systemImage: "calendar")
        }
        .accessibilityLabel("Time frame")
        .accessibilityValue("\(title), \(Self.books(shown, of: total))")
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
