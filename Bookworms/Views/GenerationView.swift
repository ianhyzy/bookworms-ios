import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// The **Spines** tab, on paper: a bindery shelf of the latest designed spines
/// (`BinderyHeader`), generator progress with a gauge of the library's designs, the models that
/// made the saved designs (`SavedDesigns`), the model this device designs with and its quota, and the charging
/// preference. The toolbar opens the Hardcover account sheet, which shows where the library comes
/// from and when it last synced; on the iPhone, a gear opens it as **Settings**, with the app's
/// settings after the account. A spine on the shelf opens its book's details.
struct GenerationView: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAccount = false
    @State private var confirmsRedesignAll = false
    @State private var path = NavigationPath()
    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
        @AppStorage(SettingsPane.key) private var settingsPane = SettingsPane.general
    #endif
    #if os(iOS)
        /// This app's Background App Refresh status. iOS refuses the charging task while it is
        /// off, so the view rereads it on appearance, on return to the foreground, and when it
        /// changes.
        @State private var backgroundRefresh = UIBackgroundRefreshStatus.available
        @State private var showsSettings = false
    #endif

    var body: some View {
        @Bindable var generation = generation
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                Form {
                    BinderyHeader(
                        current: generation.status.currentBook, path: $path,
                        showsAccount: $showsAccount)
                    progress
                    // A library with no designs yet has nothing to count.
                    if model.library?.designs.isEmpty == false {
                        SavedDesigns().id(SavedDesigns.scrollID)
                    }
                    designModel
                    Section {
                        Toggle(isOn: $generation.generatesWhileCharging) {
                            HStack(spacing: 6) {
                                Text(Self.chargingLabel)
                                InfoButton("About \(Self.chargingLabel.lowercased())") {
                                    Text(Self.chargingFooter)
                                }
                            }
                        }
                    } footer: {
                        // A warning stays in view: it says why the toggle does nothing.
                        if generation.generatesWhileCharging, let warning = backgroundRefreshWarning
                        {
                            Text(warning)
                        }
                    }
                }
                // The first section has no header, so the default top margin reads as a gap. Share
                // uses the same margin.
                .contentMargins(.top, 4, for: .scrollContent)
                #if DEBUG
                    // `-BookwormsSpinesScroll YES` scrolls **Saved designs** to the top a second after
                    // the tab appears, for Simulator checks of the sections under the shelf.
                    .task {
                        guard UserDefaults.standard.bool(forKey: "BookwormsSpinesScroll") else {
                            return
                        }
                        try? await Task.sleep(for: .seconds(1))
                        proxy.scrollTo(SavedDesigns.scrollID, anchor: .top)
                    }
                #endif
                .scrollContentBackground(.hidden)
                .background { PaperGround().ignoresSafeArea() }
                .navigationDestination(for: Int.self) { id in
                    // Book details stand in the walnut room, which is dark in both appearances.
                    PushedBookDetail(id: id, tab: .spines)
                        .environment(\.colorScheme, .dark)
                        #if os(iOS)
                            .toolbarColorScheme(.dark, for: .navigationBar)
                        #endif
                        .tint(ShelfPalette.lamp)
                }
                .navigationTitle("Spines")
                // The tab bar already names the tab, so an inline title leaves the form more room.
                .navigationBarTitleDisplayMode(.inline)
                #if os(iOS)
                    // The Mac's sidebar holds the account in every section (`SidebarAccount`).
                    .toolbar {
                        let control = AccountControl(model)
                        // The gear opens Settings whatever the sign-in, so the prompt stands
                        // beside it.
                        if control.isPrompt {
                            ToolbarItem(placement: .topBarTrailing) { accountButton(control) }
                            ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Settings", systemImage: "gearshape") { showsSettings = true }
                            .badge(control.needsAttention ? Text("!") : nil)
                            .accessibilityValue(control.needsAttention ? "Needs attention" : "")
                        }
                    }
                #endif
                .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
                .task { await generation.refreshModelStatus() }
                #if os(iOS)
                    .sheet(isPresented: $showsSettings) {
                        HardcoverAccountView(showsSettings: true)
                    }
                    .task { backgroundRefresh = UIApplication.shared.backgroundRefreshStatus }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
                        }
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIApplication.backgroundRefreshStatusDidChangeNotification)
                    ) { _ in
                        backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
                    }
                #endif
                #if DEBUG
                    // For Simulator checks, `-BookwormsShowAccount YES` opens the gear's Settings
                    // on the iPhone and the account sheet on the Mac, where
                    // `-BookwormsShowSettings YES` opens the Settings window.
                    .onAppear {
                        if UserDefaults.standard.bool(forKey: "BookwormsShowAccount") {
                            #if os(iOS)
                                showsSettings = true
                            #else
                                showsAccount = true
                            #endif
                        }
                        #if os(macOS)
                            if UserDefaults.standard.bool(forKey: "BookwormsShowSettings") {
                                openSettings()
                            }
                        #endif
                    }
                #endif
            }
        }
    }

    #if os(macOS)
        private static let chargingLabel = "Generate while idle"
        /// Also the footer of the same toggle in Settings.
        static let chargingFooter =
            "Bookworms designs new spines while this Mac is idle and plugged in, even with its window closed. When this is off, it designs them only when you ask."
    #else
        private static let chargingLabel = "Generate while charging"
        private static let chargingFooter =
            "Bookworms designs new spines while this iPhone is charging, usually overnight. When this is off, it designs them only when you ask."
    #endif

    /// Why the charging task cannot run, when Background App Refresh is off for this app. The
    /// Mac has no such setting.
    private var backgroundRefreshWarning: String? {
        #if os(iOS)
            switch backgroundRefresh {
            case .denied:
                "Turn on Background App Refresh for Bookworms in \(ThisDevice.settingsApp) to generate while charging."
            case .restricted:
                "Background App Refresh is restricted on this iPhone, so Bookworms designs spines only when you ask."
            default: nil
            }
        #else
            nil
        #endif
    }

    /// The **Generation** section: the run's progress or the last run's outcome and time, the
    /// gauge of the library's designs, the run's message, and the buttons that start and stop
    /// runs. The details that don't need the reader's attention wait behind an info button
    /// (`GenerationInfo`).
    private var progress: some View {
        let status = generation.status
        return Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                runProgress(status).frame(maxWidth: .infinity, alignment: .leading)
                if !status.isRunning, let lastRun = status.lastRunAt {
                    // An absolute time stays true while the tab stays open.
                    Text(LibrarySync.time(of: lastRun))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Last run \(LibrarySync.time(of: lastRun))")
                }
                GenerationInfo()
            }
            if model.library != nil { DesignGauge() }
            if let error = status.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if generation.canStop {
                Button("Stop", role: .destructive) { generation.stop() }
            } else {
                Button("Generate now") { generation.generateNow() }
                    .disabled(status.isRunning)
            }
            // Only a library with designs has spines to design anew.
            if model.library?.designs.isEmpty == false {
                Button("Redesign all spines…") { confirmsRedesignAll = true }
                    .disabled(status.isRunning)
                    .confirmationDialog(
                        "Redesign all spines with \(Self.redesignModelName)?",
                        isPresented: $confirmsRedesignAll, titleVisibility: .visible
                    ) {
                        Button("Redesign All Spines") { generation.redesignAll() }
                    } message: {
                        Text(Self.redesignAllMessage)
                    }
            }
        } header: {
            Text("Generation").bookHeading()
        }
    }

    /// The model that **Redesign all spines** designs with: the chosen model, as if the reader
    /// preferred it to Private Cloud Compute (`SpineWorker.reconcile(mode:redesigning:
    /// redesigningAllBefore:)`). Apple's choice is Private Cloud Compute, or the on-device model
    /// in builds without it (`NO_PCC`).
    private static var redesignModelName: String {
        let designer = SpineDesigner.current
        #if NO_PCC
            let apple = ModelTier.onDevice
        #else
            let apple = ModelTier.privateCloudCompute
        #endif
        return (designer.provider == .apple ? apple : .backup).name(backup: designer)
    }

    /// The confirmation's message: what stays, and what the redesign costs. A provider bills each
    /// request; the model info button says the same of each new spine.
    private static var redesignAllMessage: String {
        let kept = "Spines you customized stay as they are."
        return SpineDesigner.current.provider == .apple
            ? kept : "\(kept) Each spine costs about one request."
    }

    /// The run's progress (`WorkerSnapshot.headline`): while it runs, a bar of its books, the
    /// book being designed and the model designing it, and the time left; then its tally.
    /// VoiceOver reads it as one element.
    private func runProgress(_ status: WorkerSnapshot) -> some View {
        let left = status.timeLeftText
        let tally = status.tally
        let model = Self.modelName(status.model)
        return VStack(alignment: .leading, spacing: 6) {
            if status.isRunning {
                ProgressView(value: status.fraction) {
                    Text(status.headline)
                } currentValueLabel: {
                    if let book = status.designingBook {
                        // One line when the title and the model fit, as at most text sizes;
                        // otherwise the model goes under the title.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 4) {
                                BookText(book.title, of: book)
                                Text("· \(model)")
                            }
                            .lineLimit(1)
                            VStack(alignment: .leading, spacing: 2) {
                                BookText(book.title, of: book).lineLimit(2)
                                Text(model)
                            }
                        }
                    }
                }
                if let left { Text(left).font(.subheadline) }
            } else {
                Text(status.headline)
            }
            if !tally.isEmpty {
                Text(tally.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.headline)
        .accessibilityValue(
            ([status.designingBook.map { "\($0.title), \(model)" }, left] + tally)
                .compactMap { $0 }
                .joined(separator: ", "))
    }

    /// The model's name as the **Model** row shows it. Until the first status arrives, the best
    /// tier this build could use names the model.
    private static func modelName(_ status: ModelStatus?) -> String {
        status?.designerName ?? expectedTier.name(backup: .current)
    }

    /// The run's model tier: Private Cloud Compute with its daily limit, or, when it isn't
    /// available or the reader prefers their own model, the reader's model with an API key, the
    /// on-device model, or local defaults.
    /// **Choose model** opens the model settings. A provider the reader chose but didn't set up,
    /// or that rejected its settings, says why beside it, unless the run's message already says
    /// so. The info button explains what a design costs at this tier and why the better tiers
    /// are unavailable. Builds without Private Cloud Compute (`NO_PCC`) never name it. While
    /// only Apple's on-device model or default styling can design, the footer suggests turning on
    /// Apple Intelligence when it is off, and a provider when none is chosen. The reasons come
    /// from the cached status, so the body reads no Keychain item.
    private var designModel: some View {
        let status = generation.status.model
        // Until the first status arrives, the best tier this build could use names the model.
        let tier = status?.tier ?? Self.expectedTier
        // After a lasting rejection, the run's message starts with it (`fallbackMessage`).
        let backupReason = status?.backupUnavailableReason
            .flatMap {
                generation.status.error?.contains($0) == true ? nil : $0
            }
        return Section {
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    Text(Self.modelName(status))
                    InfoButton("About the model") { modelInfo(status: status, tier: tier) }
                }
            }
            if let status, !status.isAvailable, let reason = status.unavailableReason {
                LabeledContent("Unavailable") { Text(reason) }
            }
            if tier == .privateCloudCompute {
                LabeledContent("Daily limit", value: status.map(Self.quotaText) ?? "Checking")
            }
            #if os(macOS)
                Button("Choose model…") {
                    settingsPane = .backupModel
                    openSettings()
                }
                if let backupReason {
                    LabeledContent("Chosen model") { Text(backupReason) }
                }
            #else
                NavigationLink {
                    Form { SpineDesignerSettings() }
                        .navigationTitle("Design model")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent("Choose model") {
                        Text(backupReason ?? Self.choiceName)
                    }
                }
            #endif
        } header: {
            Text("Design model on this \(ThisDevice.name)").bookHeading()
        } footer: {
            if let tip = Self.tip(
                status: status, tier: tier, provider: SpineDesigner.current.provider)
            {
                Text(tip)
            }
        }
    }

    /// The **Design model** footer's tip while only Apple's on-device model or default styling
    /// can design: turn on Apple Intelligence when it is off, and choose a provider when the
    /// saved choice, `provider`, is Apple's. A chosen provider that can't design says why beside
    /// **Choose model** instead.
    static func tip(status: ModelStatus?, tier: ModelTier, provider chosen: SpineDesigner.Provider)
        -> String?
    {
        guard [.onDevice, .local].contains(tier) else { return nil }
        let appleIntelligenceOff =
            status?.onDeviceUnavailableReason == BookAnalyzer.appleIntelligenceOff
        let suggestsProvider = chosen == .apple
        let turnOn = "turn on Apple Intelligence in \(ThisDevice.settingsApp)"
        let provider = "choose Anthropic, OpenAI, or Google Gemini and add your API key"
        switch (appleIntelligenceOff, suggestsProvider) {
        case (true, true): return "For better spines, \(turnOn), or \(provider)."
        case (true, false): return "For better spines, \(turnOn)."
        case (false, true): return "For better spines, \(provider)."
        case (false, false): return nil
        }
    }

    /// The models that made `designs`, by `SpineDesignV1.madeBy`, with how many designs each
    /// made: the best tier first, then the most designs.
    static func designSources(_ designs: [SpineDesignV1]) -> [(name: String, count: Int)] {
        var counts: [String: (tier: ModelTier, count: Int)] = [:]
        for design in designs {
            counts[design.madeBy, default: (design.tier, 0)].count += 1
        }
        return
            counts.sorted {
                ($0.value.tier, $0.value.count, $1.key) > ($1.value.tier, $1.value.count, $0.key)
            }
            .map { ($0.key, $0.value.count) }
    }

    /// The saved model choice, as **Choose model** shows it: Apple's models, which in builds
    /// without Private Cloud Compute (`NO_PCC`) are only the on-device model, or the provider's
    /// name.
    private static var choiceName: String {
        let provider = SpineDesigner.current.provider
        #if NO_PCC
            let apple = "Apple on-device"
        #else
            let apple = "Apple"
        #endif
        return provider == .apple ? apple : provider.name
    }

    /// The Generation info's note about books without a cover, which draw the default cover
    /// and spine; `nil` when every book has one.
    static func coverlessNote(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 book has no cover, so it gets a default style."
        default: "\(count) books have no cover, so they get a default style."
        }
    }

    /// What a design costs at `tier`, and why the next better model can't design
    /// (`infoReason(status:tier:overrides:)`). A series copy sends no request, so a new spine
    /// costs about one request. Who bills a provider's requests shows where the reader chooses
    /// it (`SpineDesignerSettings`).
    private func modelInfo(status: ModelStatus?, tier: ModelTier) -> some View {
        let note =
            switch tier {
            case .privateCloudCompute:
                "Free within Apple's daily limit, at about one request per new spine."
            case .backup: "About one request per new spine."
            case .onDevice: "Free, with no daily limit."
            case .local: "No model is available."
            }
        let reason = Self.infoReason(
            status: status, tier: tier, overrides: SpineDesigner.overridesPrivateCloudCompute)
        return Group {
            Text(note)
            if let reason { Text(reason) }
        }
    }

    /// The info button's one reason why a better model can't design: under default styling,
    /// Apple's on-device model's, which also covers Private Cloud Compute on a device that
    /// supports neither, else Private Cloud Compute's. It leaves out Private Cloud Compute's
    /// reason while the reader's model designs because it `overrides` Private Cloud Compute, and
    /// every reason while Apple Intelligence is off, which the footer's tip
    /// (`tip(status:tier:provider:)`) says how to fix. Builds without Private Cloud Compute
    /// (`NO_PCC`) never give its reason.
    static func infoReason(status: ModelStatus?, tier: ModelTier, overrides: Bool) -> String? {
        guard let status, status.onDeviceUnavailableReason != BookAnalyzer.appleIntelligenceOff
        else { return nil }
        if let reason = status.onDeviceUnavailableReason { return reason }
        #if NO_PCC
            return nil
        #else
            return tier == .backup && overrides ? nil : status.pccUnavailableReason
        #endif
    }

    /// The best tier this build could use: Private Cloud Compute, or the saved backup model when
    /// it overrides Private Cloud Compute, or in `NO_PCC` builds the saved backup model or the
    /// on-device model. It reads no Keychain item, so it doesn't know whether the backup is set
    /// up.
    private static var expectedTier: ModelTier {
        let hasBackup = SpineDesigner.current.provider != .apple
        #if NO_PCC
            return hasBackup ? .backup : .onDevice
        #else
            return hasBackup && SpineDesigner.overridesPrivateCloudCompute
                ? .backup : .privateCloudCompute
        #endif
    }

    #if os(iOS)
        /// The toolbar's prompt for a sign-in. An iPhone's bar draws a label as its symbol
        /// alone, so the button is the control's words.
        private func accountButton(_ control: AccountControl) -> some View {
            Button(control.title) { control.open(model.account) { showsAccount = true } }
        }
    #endif

    private static func quotaText(_ status: ModelStatus) -> String {
        let reset =
            status.quotaResetDate.map {
                ", resets at \($0.formatted(date: .omitted, time: .shortened))"
            } ?? ""
        switch status.quota {
        case .belowLimit: return "Not reached"
        case .approachingLimit: return "Almost reached" + reset
        case .limitReached: return "Reached" + reset
        }
    }
}

/// The **Saved designs** section: which models made the designs the library's books draw, with
/// a count for each (`GenerationView.designSources(_:)`), and the rule by which one model's
/// design replaces another's. Each design names its model in `provenance`, which syncs with it,
/// so every device counts the same models, such as Google Gemini's designs on a device without
/// that API key. It counts when the library or its designs change (`AppModel.designRevision`).
private struct SavedDesigns: View {
    /// The section's ID in the tab's form.
    static let scrollID = "saved-designs"

    @Environment(AppModel.self) private var model
    @State private var sources: [(name: String, count: Int)] = []

    var body: some View {
        Section {
            // A wide window, such as the Mac's, sets the counts in columns, so each count stays
            // near its model's name; a phone's width keeps one column.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 32, alignment: .leading)],
                alignment: .leading, spacing: 12
            ) {
                ForEach(sources, id: \.name) { source in
                    LabeledContent(source.name) { Text(source.count, format: .number) }
                }
            }
        } header: {
            Text("Saved designs").bookHeading()
        }
        .onChange(of: model.designRevision, initial: true) {
            sources = GenerationView.designSources(model.books.compactMap(model.design(for:)))
        }
    }
}

/// A small info button that shows `content`, details the tab keeps off the screen, in a
/// popover.
private struct InfoButton<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    @State private var isPresented = false

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        Button(label, systemImage: "info.circle") { isPresented = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(label)
            .popover(isPresented: $isPresented) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { content() }
                        .padding()
                        .frame(idealWidth: 340, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 420)
                .presentationCompactAdaptation(.popover)
            }
    }
}

/// The Generation section's info button: the books without a cover, the background run in
/// progress, and where a run's books come from, or nothing when none applies. It counts the
/// books without a cover when the library or its designs change (`AppModel.designRevision`), so
/// only the button, not the whole tab, redraws for each saved design.
private struct GenerationInfo: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    /// How many books have no cover and draw no design (`AppModel.defaultStyledBookCount()`).
    @State private var coverless = 0

    var body: some View {
        let notes = [
            GenerationView.coverlessNote(coverless),
            // Names the run that dims **Generate now** on the iPhone, and that **Stop** ends on
            // the Mac.
            generation.status.isRunning && !generation.isGenerating
                ? "A background run is in progress." : nil,
            // Why a run may design books the gauge doesn't count. A worklist decides only for a
            // newer copy of this account's library
            // (`WorkSource.init(worklist:signedInAccountID:phone:)`).
            model.account.isSignedIn && !model.isPreview
                ? "When your Apple TV has a newer copy of your library, Bookworms designs from it."
                : nil,
        ]
        .compactMap { $0 }
        Group {
            if !notes.isEmpty {
                InfoButton("About generation") {
                    ForEach(notes, id: \.self) { Text($0) }
                }
            }
        }
        .onChange(of: model.designRevision, initial: true) {
            coverless = model.defaultStyledBookCount()
        }
    }
}

/// The top of the Spines tab: a bindery shelf of the latest designed spines, newest at the
/// right, standing on a bare board that runs past the window's edges, with no card around it.
/// While a run designs, the book in progress stands at the shelf's end in blank cloth, with its cover in a
/// row below; when its design saves, its lettering appears like a foil stamp. Without a library,
/// the shelf stands empty with **Connect Hardcover**. A spine opens its book's details.
///
/// The shelf's books are prepared when the books' designs change (`AppModel.designRevision`),
/// not in the body. The header is equal for the same book in
/// progress, and SwiftUI compares an equatable view that isn't plain data by its `==`, so a run's
/// other progress updates skip it. `.equatable()` would also hide the section's rows from the
/// form, which then draws them as one.
private struct BinderyHeader: View, Equatable {
    let current: CloudBook?
    /// The tab's navigation path, which a spine pushes its book's details onto.
    @Binding var path: NavigationPath
    @Binding var showsAccount: Bool

    @Environment(AppModel.self) private var model

    /// The latest designed books, oldest first: one more than the shelf shows, so it stays full
    /// without the book in progress, which stands at its end.
    @State private var designed: [CloudBook] = []

    /// How many designed books the shelf shows: fewer on the iPhone, so the books stand large
    /// enough that thin spines letter their authors legibly.
    #if os(macOS)
        static let shown = 10
    #else
        static let shown = 6
    #endif
    /// The books' size.
    static let scale: CGFloat = 128

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.current == rhs.current }

    var body: some View {
        Section {
            if model.library != nil {
                let books = shelfBooks
                let shelf = HStack(alignment: .bottom, spacing: 1) {
                    ForEach(books, id: \.book.id) { item in
                        // A navigation link in a form row would add a disclosure chevron.
                        Button {
                            path.append(item.book.id)
                        } label: {
                            BinderySpine(book: item.book, look: item.look, size: item.size)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            item.look == nil
                                ? "\(item.book.title), being designed"
                                : "\(item.book.title), by \(item.book.author)"
                        )
                        .accessibilityHint("Opens the book's details.")
                    }
                }
                .padding(.horizontal, 16)
                // The books stand partway back on the board's top, over it.
                VStack(spacing: -Bookcase.surface * 0.55) {
                    ViewThatFits(in: .horizontal) {
                        shelf
                        ScrollView(.horizontal) { shelf }
                            .defaultScrollAnchor(.trailing)
                            .scrollIndicators(.hidden)
                    }
                    .frame(maxWidth: .infinity)
                    .zIndex(1)
                    FloatingShelfBoard()
                }
                .padding(.top, 12)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Latest designs")
                .listRowInsets(EdgeInsets())
                if let current { CurrentBookRow(book: current) }
            } else {
                VStack(spacing: 16) {
                    EmptyBookcase()
                    Text("No library yet").font(.title3.weight(.semibold)).bookHeading()
                    if !model.isPreview {
                        Button("Connect Hardcover") { showsAccount = true }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        #if os(iOS)
            // No side margins, so the board runs to the screen's edges; a row's cell clips its
            // content, so the board can't draw past the margins.
            .listSectionMargins(.horizontal, 0)
        #endif
        .onChange(of: model.designRevision, initial: true) { prepare() }
    }

    /// The latest designed books, then the book in progress without a look. The book in progress
    /// leaves the designed books here, in the body, so the pass where a run moves to it never
    /// lists it twice.
    private var shelfBooks: [(book: CloudBook, look: SpineLook?, size: CGSize)] {
        var books = designed.filter { $0.id != current?.id }.suffix(Self.shown)
            .map { (book: $0, look: Optional(model.look(for: $0))) }
        if let current {
            books.append((book: model.book(id: current.id) ?? current, look: nil))
        }
        return books.map { ($0.book, $0.look, $0.book.shelfSpineSize(scale: Self.scale)) }
    }

    private func prepare() {
        let latest = (model.library.map { Array($0.designs.values) } ?? [])
            .sorted { $0.generatedAt > $1.generatedAt }
            .prefix(Self.shown + 1)
        designed = latest.reversed().compactMap { model.book(id: $0.bookID) }
    }
}

/// A spine on the bindery shelf: blank cloth while its book is being designed, then its design,
/// whose lettering appears as a foil stamp: the cloth over it fades as a brief glint of gold
/// passes, or under Reduce Motion, a plain cross-fade. A spine that appears designed shows its
/// lettering at once.
private struct BinderySpine: View {
    let book: CloudBook
    let look: SpineLook?
    let size: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A foil stamp's progress: blank cloth over the lettering, and the glint.
    private struct Stamp {
        var cover = 0.0
        var glint = 0.0
    }

    var body: some View {
        // One view in both states, so the animator sees the design arrive.
        ZStack {
            if let look {
                UprightSpineView(
                    book: book, look: look, height: size.height, thickness: size.width)
            }
        }
        .frame(width: size.width, height: size.height)
        .keyframeAnimator(initialValue: Stamp(), trigger: look != nil) { content, stamp in
            content.overlay {
                PlainSpine(
                    cloth: look?.background
                        ?? SpineLook(book: book, design: nil, face: nil).background
                )
                .opacity(look == nil ? 1 : stamp.cover)
                ShelfPalette.gold.opacity(stamp.glint)
            }
        } keyframes: { _ in
            KeyframeTrack(\.cover) {
                LinearKeyframe(1, duration: 0)
                CubicKeyframe(0, duration: reduceMotion ? 0.4 : 0.8)
            }
            // Under Reduce Motion, the glint stays at zero.
            KeyframeTrack(\.glint) {
                CubicKeyframe(reduceMotion ? 0 : 0.35, duration: 0.25)
                CubicKeyframe(0, duration: 0.55)
            }
        }
        .background(alignment: .bottom) { ContactShadow(width: size.width) }
    }
}

/// The book a run is designing: its cover, small, beside its title.
private struct CurrentBookRow: View {
    let book: CloudBook

    @Environment(AppModel.self) private var model
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 36, height: 54)
                .overlay {
                    if let cover { Image(uiImage: cover).resizable().scaledToFill() }
                }
                .background(.quaternary)
                .clipShape(.rect(cornerRadius: 2))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Designing").font(.catalogLabel).foregroundStyle(.secondary)
                BookText(book.title, of: book).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .task(id: book.id) { cover = await model.covers.image(for: book, maximumPixelSize: 180) }
    }
}

/// How much of the library has a design: the count, and a gauge of one sliver per book, the
/// designed books' in their spines' colors from the left, as a row of the Generation section.
/// It gathers the colors when the books' designs change (`AppModel.designRevision`), and the
/// canvas draws again only when they change.
private struct DesignGauge: View {
    @Environment(AppModel.self) private var model
    /// The designed books' spine colors, in the library's order.
    @State private var colors: [ColorValue] = []

    var body: some View {
        let total = model.books.count
        VStack(alignment: .leading, spacing: 8) {
            Text("\(colors.count) of \(total) books designed")
            GaugeSlivers(colors: colors, total: total)
                .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation {
            ProgressView(
                "Books designed", value: Double(colors.count), total: Double(max(total, 1)))
        }
        .onChange(of: model.designRevision, initial: true) {
            colors = model.books.compactMap {
                model.design(for: $0).flatMap { ColorValue(hex: $0.backgroundHex) }
            }
        }
    }
}

/// The gauge's slivers: `colors` from the left, then empty slots up to `total`, in a capsule.
private struct GaugeSlivers: View, Equatable {
    let colors: [ColorValue]
    let total: Int

    var body: some View {
        Canvas { context, size in
            let capsule = Path(
                roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(capsule, with: .color(.secondary.opacity(0.18)))
            context.clip(to: capsule)
            let width = size.width / CGFloat(max(total, 1))
            for (index, color) in colors.enumerated() {
                // A little wider than its slot, so no seams show between slivers.
                let rect = CGRect(
                    x: CGFloat(index) * width, y: 0, width: width + 0.5, height: size.height)
                context.fill(Path(rect), with: .color(color.color))
            }
        }
    }
}
