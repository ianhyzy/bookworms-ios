import FoundationModels
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// The **Spines** tab: design coverage, generator progress, the designing model and its quota,
/// and the charging preference. The toolbar opens the Hardcover account sheet, which shows where
/// the library comes from and when it last synced.
struct GenerationView: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAccount = false
    #if os(iOS)
        /// This app's Background App Refresh status. iOS refuses the charging task while it is
        /// off, so the view rereads it on appearance, on return to the foreground, and when it
        /// changes.
        @State private var backgroundRefresh = UIBackgroundRefreshStatus.available
    #endif

    var body: some View {
        @Bindable var generation = generation
        NavigationStack {
            Form {
                summary
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
            #if os(iOS)
                // The first section has no header, so the default top margin under an inline
                // title reads as a gap.
                .contentMargins(.top, 8, for: .scrollContent)
            #endif
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
                // `-BookwormsShowAccount YES` opens the account sheet for Simulator checks.
                .onAppear {
                    if UserDefaults.standard.bool(forKey: "BookwormsShowAccount") {
                        showsAccount = true
                    }
                }
            #endif
        }
    }

    private var summary: some View {
        let total = model.library?.books.count ?? 0
        let designed = model.library?.designs.count ?? 0
        return Section {
            ProgressView(value: Double(designed), total: Double(max(total, 1))) {
                Text("\(designed) of \(total) books designed")
                    .font(.headline)
            }
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
        return Section("Generation") {
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
        }
    }

    /// The run's model tier: Private Cloud Compute with its daily limit, or, when it isn't
    /// available, the backup model, the on-device model, or local defaults, with why Private
    /// Cloud Compute, a backup model the reader chose but didn't set up or whose provider
    /// rejected its settings, and, under local defaults, the on-device model are unavailable,
    /// and what a design costs at this tier. The reasons come from the cached status, so the
    /// body reads no Keychain item.
    private var designModel: some View {
        let status = generation.status.model
        // Until the first status arrives, the best tier this build could use names the model.
        let tier = status?.tier ?? Self.expectedTier
        let note =
            switch tier {
            case .privateCloudCompute:
                "Each new design uses one request from your daily limit. Books in a series often reuse a design without a request."
            case .backup:
                "Private Cloud Compute isn't available, so your backup model designs. Each new design uses one request to this provider, billed to your API account. Books in a series often reuse a design without a request. \(Self.upgradeNote)"
            case .onDevice:
                "Private Cloud Compute isn't available, so each new design runs on this \(ThisDevice.name), with no daily limit. Books in a series often reuse a design. \(Self.upgradeNote)"
            case .local:
                "No model is available on this \(ThisDevice.name), so each new design comes from the cover's colors and lettering and the book's genres, with no model requests. \(Self.upgradeNote)"
            }
        return Section {
            LabeledContent("Availability") {
                Text(
                    status.map { $0.isAvailable ? "Available" : $0.unavailableReason ?? "" }
                        ?? "Checking")
            }
            if let reason = status?.pccUnavailableReason {
                LabeledContent("Private Cloud Compute") { Text(reason) }
            }
            if let reason = status?.backupUnavailableReason {
                LabeledContent("Backup model") { Text(reason) }
            }
            if let reason = status?.onDeviceUnavailableReason {
                LabeledContent("Apple on-device model") { Text(reason) }
            }
            if tier == .privateCloudCompute {
                LabeledContent("Daily limit", value: status.map(Self.quotaText) ?? "Checking")
                if let suggestion = status?.limitIncreaseSuggestion {
                    Button("Increase limit") { suggestion.show() }
                }
            }
            #if os(macOS)
                SettingsLink { Text("Choose Backup Model…") }
            #else
                NavigationLink("Choose Backup Model") {
                    Form { SpineDesignerSettings() }
                        .navigationTitle("Spine Design Model")
                        .navigationBarTitleDisplayMode(.inline)
                }
            #endif
        } header: {
            Text(status?.designerName ?? Self.expectedTier.name(backup: .current))
        } footer: {
            Text(note)
        }
    }

    private static let upgradeNote =
        "Once a better model is available, runs redesign the spines a weaker model made."

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

    /// Whether the account sheet shows a problem: Hardcover rejected the saved login, or the
    /// library failed to load, also while an older copy shows.
    private var accountNeedsAttention: Bool {
        model.account.needsReconnect || model.loadError != nil
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
