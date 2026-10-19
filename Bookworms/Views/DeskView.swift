import SwiftUI
import TipKit

/// The books on a desk under a lamp, in one 3D scene (`DeskScenes`): the Desk scene, which drops
/// them onto the desk to throw around (`BookPileView`), and the dominoes that the bar's
/// **Dominoes** turns them into, which stand on end and topple (`DominoesView`). Desk opens on
/// the Desk scene; **Back to desk**, in the same place, returns to it with the books where they
/// lie. On the Mac, the **Desk** and **View** menus offer the same switch and the Desk scene's
/// zoom (`DeskCommands`).
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
        /// The time frame's books, in the desk's order.
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
                // The scene's table covers the wall, so the wall's grain and seams would only
                // blend under every RealityKit frame.
                .background { ShelfPalette.wall.ignoresSafeArea() }
                .modifier(
                    DeskBar(
                        liftedDetails: liftedDetails, desk: desk, chip: shelf.chip, frame: frame,
                        sort: $sort, canSetUp: !shelf.dropped.isEmpty, isCovered: !path.isEmpty
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
                .navigationDestination(for: Int.self) { PushedBookDetail(id: $0, tab: .desk) }
        }
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
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        // Low Power Mode and heat change the desk's effects while Desk shows. The state is read
        // before either task waits, so a change while Desk was hidden also counts.
        .task {
            desk.updatePowerState()
            for await _ in NotificationCenter.default.messages(
                of: ProcessInfo.self, for: .thermalStateDidChange)
            {
                desk.updatePowerState()
            }
        }
        .task {
            for await _ in NotificationCenter.default.messages(
                of: ProcessInfo.self, for: .powerStateDidChange)
            {
                desk.updatePowerState()
            }
        }
    }

    @ViewBuilder private func content(_ shelf: Shelf, frame: TimeFrame?) -> some View {
        if let library = model.library {
            if !library.books.contains(where: \.hasBeenRead) {
                NoBooksYetView(room: .desk)
            } else {
                let title = frame?.title ?? Self.years(of: shelf.books)
                ZStack {
                    DeskCanvas(desk: desk)
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
                    DeskTipAnchors(desk: desk)
                }
            }
        } else {
            NoLibraryView(room: .desk, showsAccount: $showsAccount)
        }
    }

    /// The scenes' time frame, or `nil` for every book.
    private var frame: TimeFrame? {
        TimeFrame.pileFrame(setting: frameSetting, in: model.books)
    }

    /// The years `books` were finished in, such as "2019–2026", for a scene of every book.
    private static func years(of books: [CloudBook]) -> String {
        // Every finish counts, so a reread's earlier reads widen the span.
        let years = TimeFrame.periods(in: books).years
        guard let last = years.first, let first = years.last else { return "My books" }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    /// The books the desk shows in `frame`, and the time frame button, which shows once the
    /// library has read books.
    private func shelf(frame: TimeFrame?) -> Shelf {
        guard let library = model.library, library.books.contains(where: \.hasBeenRead) else {
            return Shelf(books: [], dropped: [], chip: nil)
        }
        let books = shownBooks(frame: frame)
        let dropped = Array(PileLayout.dropped(books, count: BookPileView.maximumBooks))
        let title = frame?.title ?? Self.years(of: books.isEmpty ? model.books : books)
        return Shelf(
            books: books, dropped: dropped,
            chip: DeskBar.Chip(title: title, shown: dropped.count, total: books.count))
    }

    /// The books in the chosen order, and in `frame` when it is set.
    private func shownBooks(frame: TimeFrame?) -> [CloudBook] {
        // The read books, as in Library, and current reads, which **All Time** marks with
        // ribbons. Want to Read and other unread shelves stay off.
        var books = model.books.filter { $0.hasBeenRead || $0.isReading == true }
        // A reread shows by its finish in the frame, which can change its place.
        if let frame { books = frame.books(in: books) }
        books = sort.sorted(books)
        #if DEBUG
            // `-BookwormsShareSamples <n>` also marks current reads here, for the pile's ribbons.
            books = ShareDebug.samples(books)
        #endif
        return books
    }
}

/// The desk's view, or the resting pile's still in its place, which also lies under the view
/// as it returns, until the view draws (see `DeskScenes`).
///
/// A view of its own, so a pause and a wake update only it, not the desk's body, which sorts
/// the library.
private struct DeskCanvas: View {
    let desk: DeskScenes

    var body: some View {
        if let still = desk.still {
            Image(uiImage: still)
                .resizable()
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        if !desk.hidesView && !desk.isPaused {
            DeskSceneView { desk.attach(to: $0) }
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }
}

/// Where the Desk's tips point (`DeskTips`), over whichever scene shows: the Desk scene's tips
/// at the book nearest the view's middle while the desk rests, and the push tip at the
/// dominoes' hand (`DeskScenes.pushTipPoint`). The anchors lie over both scenes rather than in
/// either, since only the modifier that presented a tip's popover can take it down, so it must
/// outlive a switch between the scenes.
///
/// It tells the Desk scene's tips when the desk rests, so they show only over the resting
/// pile's still and go when the desk wakes, the dominoes show, or Desk leaves the screen, and it
/// finds the book once per rest.
private struct DeskTipAnchors: View {
    let desk: DeskScenes

    /// The scenes' full size, under the bars, in which the tips' points lie.
    @State private var size: CGSize?

    var body: some View {
        let rests = desk.isPaused && desk.mode == .desk && size != nil
        ZStack {
            TipAnchor(
                tip: DeskTips.pile.currentTip,
                point: rests ? size.flatMap { desk.pile.middleBookPoint(in: $0) } : nil)
            TipAnchor(tip: PushTip(), point: desk.pushTipPoint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: {
            size = $0
        }
        .ignoresSafeArea()
        .onChange(of: rests, initial: true) { PickUpTip.deskRests = rests }
        .onDisappear { PickUpTip.deskRests = false }
    }
}

/// Desk's bar: the time frame button in the middle, **Dominoes** or **Back to desk**, and the
/// options menu. While a lifted book's details show, they give way to the details' **Back** and
/// **Share** (`LiftedDetailsOverlay`). Without books to show, the bar holds none of them.
///
/// On the Mac, the bar also hands the menu bar's Desk commands what they act on
/// (`DeskCommands`), while Desk shows its scene with nothing over it.
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
    /// Whether the desk has books to set up.
    let canSetUp: Bool
    /// Whether pushed details cover the scene.
    let isCovered: Bool
    /// **Dominoes** or **Back to desk**, for the scene that shows.
    let switchScene: () -> Void

    @Environment(AppModel.self) private var model
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
            // takes the title's place. On the Mac, the window takes the book's name.
            #if os(macOS)
                .navigationTitle(liftedDetails.lift?.book.title ?? "Desk")
                .navigationSubtitle(liftedDetails.lift?.book.author ?? "")
            #else
                .navigationTitle(liftedDetails.lift == nil ? "Desk" : "")
            #endif
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if liftedDetails.lift == nil, let chip {
                    ToolbarItem(placement: .principal) {
                        FrameChip(title: chip.title, shown: chip.shown, total: chip.total)
                    }
                    ToolbarItem(placement: .topBarLeading) { sceneSwitch }
                    ToolbarItem(placement: .topBarTrailing) { options }
                }
            }
            #if os(macOS)
                .focusedSceneValue(\.deskCommands, commands)
            #endif
    }

    private var isDominoes: Bool { desk.mode == .dominoes }

    /// Whether **Dominoes** can set up the desk's books, which finish dropping first, since
    /// the books on the desk set up the chain.
    private var canSwitch: Bool { isDominoes || (canSetUp && !desk.pile.status.isDropping) }

    /// **Dominoes** in the Desk scene, and **Back to desk** in its place once the dominoes
    /// stand. The Mac's roomier toolbar shows their names beside their symbols.
    private var sceneSwitch: some View {
        Group {
            if isDominoes {
                // The Desk tab's lamp, so it reads apart from **Set up again** beside it.
                Button("Back to desk", systemImage: "lamp.desk", action: switchScene)
            } else {
                Button(
                    "Dominoes", systemImage: "square.stack.3d.forward.dottedline",
                    action: switchScene
                )
                .disabled(!canSwitch)
                .accessibilityHint("Stands the books on the desk on end, to topple them.")
            }
        }
        #if os(macOS)
            .labelStyle(.titleAndIcon)
        #endif
    }

    #if os(macOS)
        /// What the Desk commands act on, while Desk shows its scene and nothing covers it.
        private var commands: DeskCommandTarget? {
            guard model.selectedTab == .desk, chip != nil, liftedDetails.lift == nil,
                !isCovered
            else { return nil }
            return DeskCommandTarget(
                desk: desk, isDominoes: isDominoes, canSwitch: canSwitch,
                switchScene: switchScene)
        }
    #endif

    /// The scene's options, and the order where it changes the scene's books:
    /// Dominoes stand in finish order whatever the sort (`DominoLayout.chain(_:)`).
    private var options: some View {
        Menu("Desk options", systemImage: "ellipsis") {
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
                    Picker("Sort by", systemImage: "arrow.up.arrow.down", selection: $sort) {
                        ForEach(ShelfSort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
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
/// the navigation bar. The button opens the time frame menu: **All Time**, or a **Year** or
/// **Month** with finished books. Every 3D view shares the choice, and the app saves it.
///
/// Where the bar leaves too little room between its buttons, as on an iPhone, the button drops
/// the calendar, then the books' symbol, then the count, as a long span such as "2009–2026"
/// needs; VoiceOver and the large content viewer still read the count.
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
        // Built once for every size, since it reads every book's finish date.
        let menu = options
        // A menu in the bar keeps its label's full width, so the bar's room picks the size.
        ViewThatFits(in: .horizontal) {
            chip(menu, calendar: true, books: true, count: true)
            chip(menu, calendar: false, books: true, count: true)
            chip(menu, calendar: false, books: false, count: true)
            chip(menu, calendar: false, books: false, count: false)
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

    private func chip(_ menu: some View, calendar: Bool, books: Bool, count: Bool) -> some View {
        Menu {
            menu
        } label: {
            HStack(spacing: 8) {
                part(title, systemImage: "calendar", symbol: calendar)
                if count {
                    part(
                        total > shown
                            ? "\(shown.formatted()) of \(total.formatted())" : total.formatted(),
                        systemImage: "books.vertical", symbol: books)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            // The last, shortest size shrinks rather than truncates when even it does not fit,
            // as a long span can at the largest text size on the narrowest iPhone. The sizes
            // before it show only where they fit, so they never shrink.
            .minimumScaleFactor(0.75)
            #if os(macOS)
                .padding(.horizontal, 6)
            #endif
        }
        #if os(iOS)
            // The iPhone's bar draws a menu in its middle as bare text; a capsule shows it opens
            // a menu, as the Mac's toolbar does. A tinted fill rather than glass, so the bar adds
            // no blur over the live scene, and small, so it fits between the bar's buttons.
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        #endif
    }

    private func part(_ text: String, systemImage: String, symbol: Bool) -> some View {
        HStack(spacing: 4) {
            if symbol { Image(systemName: systemImage) }
            Text(text)
        }
    }

    /// **All Time**, and the years and months with finished books, newest first. Choosing one
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
            Text(TimeFrame.lifetime.menuTitle).tag(TimeFrame?.none)
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
