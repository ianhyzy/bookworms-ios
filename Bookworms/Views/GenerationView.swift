import FoundationModels
import SwiftUI

/// The **Spines** tab: design coverage, generator progress, the Private Cloud Compute quota,
/// and the charging preference.
struct GenerationView: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation

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
                    Text(
                        "iOS runs generation when this iPhone is charging and idle on a network, typically overnight. The Apple TV picks up new designs through iCloud."
                    )
                }
                appleTV
            }
            .navigationTitle("Spines")
            .task { await generation.refreshModelStatus() }
        }
    }

    private var summary: some View {
        let total = model.library?.books.count ?? 0
        let designs = model.library?.designs.values.map(\.generatorVersion) ?? []
        let byPCC = designs.filter { $0 == CloudContract.generatorVersion }.count
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(designs.count) of \(total) books designed")
                    .font(.headline)
                Text("\(byPCC) by Private Cloud Compute")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            ProgressView(value: Double(designs.count), total: Double(max(total, 1)))
                .accessibilityLabel("Books designed")
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
                    Text(status.currentTitle ?? "\(done) of \(done + status.queue)")
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

    @ViewBuilder private var appleTV: some View {
        Section {
            if let library = model.library {
                LabeledContent(
                    "Library synced",
                    value: library.syncedAt.formatted(.relative(presentation: .named)))
            } else if let error = model.loadError {
                Text(error)
            } else {
                Text("Waiting for the Apple TV to upload its library to iCloud.")
            }
        } header: {
            Text("Apple TV")
        } footer: {
            if model.isPreview {
                Text("Preview mode reads a local library. Designs stay on this iPhone.")
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
