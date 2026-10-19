import FoundationModels
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// The **Spines** tab, on paper: a bindery shelf of the latest designed spines over a gauge of
/// the library's designs (`BinderyHeader`), generator progress, the designing model and its
/// quota, and the charging preference. The toolbar opens the Hardcover account sheet, which
/// shows where the library comes from and when it last synced. A spine on the shelf opens its
/// book's details.
struct GenerationView: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAccount = false
    @State private var showsModelInfo = false
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
    #endif

    var body: some View {
        @Bindable var generation = generation
        NavigationStack(path: $path) {
            Form {
                BinderyHeader(
                    current: generation.status.currentBook, path: $path,
                    showsAccount: $showsAccount)
                progress
                designModel
                Section {
                    Toggle(Self.chargingLabel, isOn: $generation.generatesWhileCharging)
                } footer: {
                    if generation.generatesWhileCharging, let warning = backgroundRefreshWarning {
                        Text(warning)
                    } else {
                        Text(Self.chargingFooter)
                    }
                }
            }
            // The first section has no header, so the default top margin reads as a gap. Share
            // uses the same margin.
            .contentMargins(.top, 4, for: .scrollContent)
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
            .toolbar {
                Button("Hardcover account", systemImage: accountSymbol) { showsAccount = true }
                    .accessibilityValue(accountNeedsAttention ? "Needs attention" : "")
            }
            .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
            .task { await generation.refreshModelStatus() }
            #if os(iOS)
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
                // `-BookwormsShowAccount YES` opens the account sheet for Simulator checks, and
                // on the Mac, `-BookwormsShowSettings YES` opens Settings.
                .onAppear {
                    if UserDefaults.standard.bool(forKey: "BookwormsShowAccount") {
                        showsAccount = true
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

    #if os(macOS)
        private static let chargingLabel = "Generate while idle"
        private static let chargingFooter =
            "macOS runs generation when this Mac is idle, even with no Bookworms window open. The Apple TV picks up new designs through iCloud."
    #else
        private static let chargingLabel = "Generate while charging"
        private static let chargingFooter =
            "iOS runs generation when this iPhone is charging and idle on a network, typically overnight. The Apple TV picks up new designs through iCloud."
    #endif

    /// Why the charging task cannot run, when Background App Refresh is off for this app. The
    /// Mac has no such setting.
    private var backgroundRefreshWarning: String? {
        #if os(iOS)
            switch backgroundRefresh {
            case .denied:
                "Turn on Background App Refresh for Bookworms in Settings to generate while charging."
            case .restricted:
                "Background App Refresh is restricted on this iPhone, so Bookworms generates spines only when you tap Generate now."
            default: nil
            }
        #else
            nil
        #endif
    }

    private var progress: some View {
        let status = generation.status
        let done = status.completed + status.failed
        return Section {
            if status.isRunning {
                ProgressView(value: Double(done), total: Double(max(done + status.queue, 1))) {
                    Text(status.phase)
                } currentValueLabel: {
                    Group {
                        if let book = status.currentBook {
                            BookText(book.title, of: book)
                        } else {
                            Text("\(done) of \(done + status.queue)")
                        }
                    }
                    .lineLimit(1)
                }
            } else {
                LabeledContent("Status", value: status.phase)
            }
            if let lastRun = status.lastRunAt {
                LabeledContent(
                    "Last run", value: lastRun.formatted(.relative(presentation: .named)))
            }
            if let error = status.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if generation.isGenerating {
                Button("Stop", role: .destructive) { generation.stop() }
            } else {
                Button("Generate now") { generation.generateNow() }
                    .disabled(status.isRunning)
            }
        } header: {
            Text("Generation").bookHeading()
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                // Says why **Generate now** is dimmed.
                if status.isRunning, !generation.isGenerating {
                    Text("A background run is in progress.")
                }
                // The worklist choice explains why a run may design books the shelf's gauge
                // doesn't count.
                if model.account.isSignedIn, !model.isPreview {
                    Text(
                        "When your Apple TV lists books to design, Bookworms designs those instead of your Hardcover library."
                    )
                }
            }
        }
    }

    /// The run's model tier: Private Cloud Compute with its daily limit, or, when it isn't
    /// available, the reader's model with an API key, the on-device model, or local defaults.
    /// **Choose model** opens the model settings. A provider the reader chose but didn't set up,
    /// or that rejected its settings, says why beside it. The info button explains what
    /// a design costs at this tier and, in builds with Private Cloud Compute, why it is
    /// unavailable. Builds without it (`NO_PCC`) never name it. The reasons come from the cached
    /// status, so the body reads no Keychain item.
    private var designModel: some View {
        let status = generation.status.model
        // Until the first status arrives, the best tier this build could use names the model.
        let tier = status?.tier ?? Self.expectedTier
        let name = status?.designerName ?? Self.expectedTier.name(backup: .current)
        return Section {
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    Text(tier == .privateCloudCompute ? "Apple \(name)" : name)
                    Button("About the model", systemImage: "info.circle") {
                        showsModelInfo = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showsModelInfo) {
                        modelInfo(status: status, tier: tier, name: name)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            if let status, !status.isAvailable, let reason = status.unavailableReason {
                LabeledContent("Unavailable") { Text(reason) }
            }
            if tier == .privateCloudCompute {
                LabeledContent("Daily limit", value: status.map(Self.quotaText) ?? "Checking")
                if let suggestion = status?.limitIncreaseSuggestion {
                    Button("Increase limit") { suggestion.show() }
                }
            }
            #if os(macOS)
                Button("Choose model…") {
                    settingsPane = .backupModel
                    openSettings()
                }
                if let reason = status?.backupUnavailableReason {
                    LabeledContent("Chosen model") { Text(reason) }
                }
            #else
                NavigationLink {
                    Form { SpineDesignerSettings() }
                        .navigationTitle("Design model")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent("Choose model") {
                        Text(status?.backupUnavailableReason ?? Self.choiceName)
                    }
                }
            #endif
        } header: {
            Text("Design model").bookHeading()
        } footer: {
            #if NO_PCC
                Text(
                    "Apple's on-device model designs spines by default, on this \(ThisDevice.name) and at no cost. For better results, you can use a model such as Google Gemini, Claude, or OpenAI's with your own API key."
                )
            #endif
        }
    }

    /// The saved model choice, as **Choose model** shows it: Apple's on-device model or the
    /// provider's name.
    private static var choiceName: String {
        let provider = SpineDesigner.current.provider
        return provider == .apple ? "Apple on-device" : provider.name
    }

    /// What a design costs at `tier`, whose model is `name`, and why the better tiers are
    /// unavailable.
    private func modelInfo(status: ModelStatus?, tier: ModelTier, name: String) -> some View {
        let note: String
        switch tier {
        case .privateCloudCompute:
            note =
                "Each new design uses one request from your daily limit. Books in a series often reuse a design without a request."
        case .backup:
            #if NO_PCC
                note =
                    "\(name) designs each new spine. Each design is one request, billed to your API account. Books in a series often reuse a design without a request."
            #else
                note =
                    "Private Cloud Compute isn't available, so your backup model designs. Each new design uses one request to this provider, billed to your API account. Books in a series often reuse a design without a request. When Private Cloud Compute becomes available, runs redesign the spines a weaker model made."
            #endif
        case .onDevice:
            #if NO_PCC
                note =
                    "Apple's on-device model designs each new spine on this \(ThisDevice.name), at no cost and with no daily limit. Books in a series often reuse a design. A model with your own API key can give better results. \(Self.upgradeNote)"
            #else
                note =
                    "Private Cloud Compute isn't available, so each new design runs on this \(ThisDevice.name), with no daily limit. Books in a series often reuse a design. \(Self.upgradeNote)"
            #endif
        case .local:
            note =
                "No model is available on this \(ThisDevice.name), so new spines use a default style from the cover's colors and lettering and the book's genres. \(Self.upgradeNote)"
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(note)
                #if !NO_PCC
                    if let reason = status?.pccUnavailableReason {
                        LabeledContent("Private Cloud Compute") { Text(reason) }
                    }
                #endif
                if let reason = status?.onDeviceUnavailableReason {
                    LabeledContent("Apple on-device model") { Text(reason) }
                }
            }
            .padding()
            .frame(idealWidth: 340, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: 420)
    }

    private static let upgradeNote =
        "When a better model becomes available, such as one you add with an API key, runs redesign the spines a weaker model made."

    /// The best tier this build could use: Private Cloud Compute, or in `NO_PCC` builds the saved
    /// backup model or the on-device model. It reads no Keychain item, so it doesn't know whether
    /// the backup is set up.
    private static var expectedTier: ModelTier {
        #if NO_PCC
            SpineDesigner.current.provider == .apple ? .onDevice : .backup
        #else
            .privateCloudCompute
        #endif
    }

    /// Whether the account sheet shows a problem: Hardcover rejected the saved login, the library
    /// failed to download or load, also while an older copy shows.
    private var accountNeedsAttention: Bool {
        let account = model.account
        return account.needsReconnect || account.syncError != nil || model.loadError != nil
    }

    /// The toolbar's account symbol, badged when the account sheet shows a problem.
    private var accountSymbol: String {
        if accountNeedsAttention { return "person.crop.circle.badge.exclamationmark.fill" }
        return model.account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle"
    }

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

/// The top of the Spines tab: a bindery shelf of the latest designed spines, newest at the
/// right, and under it a gauge of the library in its designed books' colors. While a run
/// designs, the book in progress stands at the shelf's end in blank cloth, with its cover in a
/// row below; when its design saves, its lettering appears like a foil stamp. Without a library,
/// the shelf stands empty with **Connect Hardcover**. A spine opens its book's details.
///
/// The shelf's books and the gauge's colors are prepared when the books' designs change
/// (`AppModel.designRevision`) or a run moves to another book, not in the body. The header is
/// equal for the same book in progress, and SwiftUI compares an equatable view that isn't plain
/// data by its `==`, so a run's other progress updates skip it. `.equatable()` would also hide
/// the section's rows from the form, which then draws them as one.
private struct BinderyHeader: View, Equatable {
    let current: CloudBook?
    /// The tab's navigation path, which a spine pushes its book's details onto.
    @Binding var path: NavigationPath
    @Binding var showsAccount: Bool

    @Environment(AppModel.self) private var model
    @State private var prepared = Prepared()

    /// What the header draws, prepared from every design in the library.
    private struct Prepared {
        /// The latest designed books, oldest first, without the book in progress.
        var designed: [CloudBook] = []
        /// The designed books' spine colors, in the library's order, for the gauge.
        var colors: [ColorValue] = []
    }

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
                let length = books.reduce(0) { $0 + $1.size.width + 1 }
                let shelf = ShortShelf(height: Bookcase.height(scale: Self.scale), length: length) {
                    _ in
                    HStack(alignment: .bottom, spacing: 1) {
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
                }
                ViewThatFits(in: .horizontal) {
                    shelf
                    ScrollView(.horizontal) { shelf }.defaultScrollAnchor(.trailing)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Latest designs")
                DesignGauge(colors: prepared.colors, total: model.books.count)
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
        .onChange(of: model.designRevision, initial: true) { prepare() }
        .onChange(of: current?.id) { prepare() }
    }

    /// The prepared designed books, then the book in progress without a look.
    private var shelfBooks: [(book: CloudBook, look: SpineLook?, size: CGSize)] {
        var books = prepared.designed.map { (book: $0, look: Optional(model.look(for: $0))) }
        if let current {
            books.append((book: model.books.first { $0.id == current.id } ?? current, look: nil))
        }
        return books.map { ($0.book, $0.look, $0.book.shelfSpineSize(scale: Self.scale)) }
    }

    private func prepare() {
        guard let library = model.library else {
            prepared = Prepared()
            return
        }
        let latest = library.designs.values
            .filter { $0.bookID != current?.id }
            .sorted { $0.generatedAt > $1.generatedAt }
            .prefix(Self.shown)
        prepared = Prepared(
            designed: latest.reversed()
                .compactMap { design in
                    model.books.first { $0.id == design.bookID }
                },
            colors: model.books.compactMap {
                model.design(for: $0).flatMap { ColorValue(hex: $0.backgroundHex) }
            })
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
/// designed books' in their spines' colors from the left. The canvas draws again only when the
/// colors change.
private struct DesignGauge: View {
    /// The designed books' spine colors.
    let colors: [ColorValue]
    /// The library's book count.
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(colors.count) of \(total) books designed").font(.headline)
            GaugeSlivers(colors: colors, total: total)
                .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation {
            ProgressView(
                "Books designed", value: Double(colors.count), total: Double(max(total, 1)))
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
