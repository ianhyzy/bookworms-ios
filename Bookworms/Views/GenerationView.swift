import FoundationModels
import SwiftUI
import UIKit

/// The **Spines** tab: design coverage, generator progress, the Private Cloud Compute quota,
/// the charging preference, and where the library comes from. The toolbar opens the Hardcover
/// account sheet.
struct GenerationView: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAccount = false
    /// This app's Background App Refresh status. iOS refuses the charging task while it is off,
    /// so the view rereads it on appearance, on return to the foreground, and when it changes.
    @State private var backgroundRefresh = UIBackgroundRefreshStatus.available

    var body: some View {
        @Bindable var generation = generation
        NavigationStack {
            Form {
                summary
                progress
                privateCloudCompute
                Section {
                    Toggle("Generate while charging", isOn: $generation.generatesWhileCharging)
                } footer: {
                    if generation.generatesWhileCharging, let warning = backgroundRefreshWarning {
                        Text(warning)
                    } else {
                        Text(
                            "iOS runs generation when this iPhone is charging and idle on a network, typically overnight. The Apple TV picks up new designs through iCloud."
                        )
                    }
                }
                librarySource
            }
            .navigationTitle("Spines")
            .toolbar {
                Button("Hardcover account", systemImage: accountSymbol) { showsAccount = true }
            }
            .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
            .task {
                backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
                await generation.refreshModelStatus()
            }
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

    /// Why the charging task cannot run, when Background App Refresh is off for this app.
    private var backgroundRefreshWarning: String? {
        switch backgroundRefresh {
        case .denied:
            "Turn on Background App Refresh for Bookworms in Settings to generate while charging."
        case .restricted:
            "Background App Refresh is restricted on this iPhone, so Bookworms generates spines only when you tap Generate now."
        default: nil
        }
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

    private var privateCloudCompute: some View {
        let status = generation.status.model
        return Section {
            LabeledContent("Availability") {
                Text(
                    status.map { $0.isAvailable ? "Available" : $0.unavailableReason ?? "" }
                        ?? "Checking")
            }
            LabeledContent("Daily limit", value: status.map(Self.quotaText) ?? "Checking")
            if let suggestion = status?.limitIncreaseSuggestion {
                Button("Increase limit") { suggestion.show() }
            }
        } header: {
            Text("Private Cloud Compute")
        } footer: {
            Text(
                "Most new designs use two or three requests from your daily limit. Books in a series often reuse a design without a request."
            )
        }
    }

    /// The toolbar's account symbol, badged when Hardcover rejected the saved login.
    private var accountSymbol: String {
        let account = model.account
        if account.needsReconnect { return "person.crop.circle.badge.exclamationmark.fill" }
        return account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle"
    }

    /// The library's source: this iPhone's Hardcover sign-in, or the Apple TV's iCloud upload.
    ///
    /// A signed-in iPhone never shows the Apple TV's library (see `CloudSpineStore`), so the
    /// sign-in decides the label. Load and sync errors show even while an older copy is shown.
    @ViewBuilder private var librarySource: some View {
        let account = model.account
        let fromHardcover = account.isSignedIn && !model.isPreview
        Section {
            if let library = model.library {
                LabeledContent(
                    "Library synced",
                    value: library.syncedAt.formatted(.relative(presentation: .named)))
            } else if model.loadError == nil {
                Text(
                    fromHardcover
                        ? "Loading your Hardcover library."
                        : "Waiting for the Apple TV to upload its library to iCloud.")
            }
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            // Preview mode ignores the sign-in.
            if !model.isPreview, account.needsReconnect {
                Button("Reconnect") {
                    account.startSignIn()
                    showsAccount = true
                }
            } else if !model.isPreview, !account.isSignedIn, model.library == nil {
                Button("Connect Hardcover instead") { showsAccount = true }
            }
        } header: {
            Text(fromHardcover ? "Hardcover" : "Apple TV")
        } footer: {
            if model.isPreview {
                Text("Preview mode reads a local library. Designs stay on this iPhone.")
            } else if fromHardcover {
                Text(
                    "Your books come from your Hardcover account on this iPhone. When your Apple TV lists books to design, Bookworms designs those instead."
                )
            }
        }
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
