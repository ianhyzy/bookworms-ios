import SwiftUI

/// The books in a 3D scene on a desk under a lamp, in the chosen `ThreeDView`: the Desk scene,
/// which drops them onto the desk to throw around (`BookPileView`), or Dominoes, which stands
/// them on end and topples them (`DominoesView`).
///
/// The scenes show the read books and current reads finished within their own time frame,
/// which the button under the bar chooses (`FrameChip`), apart from Library's. Filtering and
/// sorting happen here when the snapshot or the options change. A tapped book lifts out of the
/// scene into its details over it (`LiftedDetails`); with Reduce Motion on, or when the scene
/// cannot lift the book, its details push instead.
struct DeskView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("BookwormsShelfSort") private var sort = ShelfSort.finished
    @AppStorage("BookwormsShelfDesignedOnly") private var designedOnly = false
    /// The 3D view the desk shows.
    @AppStorage("BookwormsThreeDView") private var threeDView = ThreeDView.dominoes
    /// The scenes' time frame as `TimeFrame.setting` writes it; empty for every book.
    /// `FrameChip` sets it. Until the reader chooses one, the scenes show the current year.
    @AppStorage(TimeFrame.pileSettingKey) private var frameSetting = TimeFrame.defaultPileSetting
    @State private var path: [Int] = []
    /// The book a scene lifted out to show its details, which replace the desk's controls.
    @State private var liftedDetails = LiftedDetails()
    @State private var showsAccount = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { ShelfPalette.wall.ignoresSafeArea() }
                .modifier(
                    DeskBar(
                        liftedDetails: liftedDetails, view: shownViewChoice, frame: frame,
                        sort: $sort, designedOnly: $designedOnly)
                )
                .navigationDestination(for: Int.self) { PushedBookDetail(id: $0) }
        }
        // The walnut backdrop is dark in both appearances, so text and bars use dark styles.
        .environment(\.colorScheme, .dark)
        .tint(ShelfPalette.lamp)
        // Outside the dark scheme and tint, so the account sheet follows the system appearance.
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
    }

    @ViewBuilder private var content: some View {
        if let library = model.library {
            let frame = frame
            let books = shownBooks(in: library, frame: frame)
            if !library.books.contains(where: \.hasBeenRead) {
                NoBooksYetView()
            } else if books.isEmpty {
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
                // Keeps the time frame button, the only way to another period with designed
                // spines.
                .safeAreaInset(edge: .top, spacing: 0) {
                    FrameChip(
                        title: frame?.title ?? Self.years(of: model.books), shown: 0, total: 0)
                }
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

    /// The chosen 3D view, or Dominoes when the saved choice is one the app does not offer.
    private var shownView: ThreeDView {
        ThreeDView.offered.contains(threeDView) ? threeDView : .dominoes
    }

    /// Reads `shownView` and saves the reader's choice, for the **Dominoes | Desk** control.
    private var shownViewChoice: Binding<ThreeDView> {
        Binding {
            shownView
        } set: {
            threeDView = $0
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

/// Desk's title and bar: the **Dominoes | Desk** control and the options menu. While a lifted
/// book's details show, they give way to the details' **Back** and **Share**
/// (`LiftedDetailsOverlay`).
///
/// A modifier of its own, so a book's lift and return update only the bar, not the desk's
/// body, which sorts the library.
private struct DeskBar: ViewModifier {
    let liftedDetails: LiftedDetails
    /// The 3D view shown.
    @Binding var view: ThreeDView
    /// The scenes' time frame, or `nil` for every book, which names the drop by period.
    let frame: TimeFrame?
    @Binding var sort: ShelfSort
    @Binding var designedOnly: Bool

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
            // Details over the scene show no title, as pushed details do.
            .navigationTitle(liftedDetails.lift == nil ? "Desk" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if liftedDetails.lift == nil {
                    ToolbarItem(placement: .principal) {
                        Picker("Scene", selection: $view) {
                            ForEach(ThreeDView.offered) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    ToolbarItem(placement: .topBarTrailing) { options }
                }
            }
    }

    /// The scene's options, and the order and filter where they change the scene's books:
    /// Dominoes stand in finish order whatever the sort (`DominoLayout.chain(_:)`).
    private var options: some View {
        Menu("Desk options", systemImage: "ellipsis") {
            Section {
                // Reduce Motion keeps the camera still, so it offers no Follow.
                if view == .dominoes && !reduceMotion {
                    Picker("Camera", systemImage: "video", selection: $dominoCamera) {
                        ForEach(DominoCameraMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Sounds", systemImage: "speaker.wave.2", isOn: $sounds)
                if view == .pile && !reduceMotion {
                    Toggle(byPeriodTitle, systemImage: "calendar", isOn: $dropsByPeriod)
                }
                if view == .pile && BookPileScene.canTilt && !reduceMotion {
                    Picker("Tilt", systemImage: "gyroscope", selection: $tilt) {
                        ForEach(PileTilt.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            Section {
                // The pile drops its first books first, up to its maximum.
                if view == .pile {
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

/// The scenes' time frame and book count, such as "2025" and "39", in a glass button under
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

/// The scenes Desk can show. Each takes the desk's books within the time frame that all of them
/// share, and orders them as the view needs. Adding a view takes a case here, titled by its raw
/// value unless `title` names it, its arm in `DeskView.content`, and an entry in `offered`,
/// which the **Dominoes | Desk** control lists.
enum ThreeDView: String, CaseIterable, Identifiable {
    /// The Desk scene. Its raw value keeps the name saved choices and launch arguments use.
    case pile
    case dominoes
    case bookworm

    /// The views the app shows, Dominoes first and by default. The Bookworm keeps its code but
    /// is not offered for now.
    static let offered: [ThreeDView] = [.dominoes, .pile]

    var id: Self { self }
    var title: String { self == .pile ? "Desk" : rawValue.capitalized }
}
