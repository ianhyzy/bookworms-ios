import Foundation

/// Remembers published output and schedules cover checks after source changes or one day.
actor WorkLedger {
    private struct LedgerState: Codable {
        var cloudUserRecordName: String?
        var entries: [String: Entry]
    }

    struct Entry: Codable, Sendable {
        let workItemHash: String
        let coverHash: String
        let generatorVersion: String
        let sourceSyncedAt: Date
        let checkedAt: Date
    }

    private let url: URL
    private var cloudUserRecordName: String?
    private var entries: [String: Entry]

    init(url: URL? = nil) {
        self.url =
            url
            ?? URL.applicationSupportDirectory
            .appending(path: "Bookworms Spine Companion/ledger.json")
        if let data = try? Data(contentsOf: self.url),
            let decoded = try? JSONDecoder().decode(LedgerState.self, from: data)
        {
            cloudUserRecordName = decoded.cloudUserRecordName
            entries = decoded.entries
        } else {
            cloudUserRecordName = nil
            entries = [:]
        }
    }

    func useCloudUser(_ recordName: String) throws {
        guard cloudUserRecordName != recordName else { return }
        // Private database records do not transfer between iCloud accounts.
        cloudUserRecordName = recordName
        entries = [:]
        try persist()
    }

    func needsCoverCheck(
        recordName: String, workItemHash: String, sourceSyncedAt: Date,
        force: Bool, now: Date = Date()
    ) -> Bool {
        if force { return true }
        guard let entry = entries[recordName] else { return true }
        return entry.workItemHash != workItemHash
            || entry.generatorVersion != CloudContract.generatorVersion
            || abs(entry.sourceSyncedAt.timeIntervalSince(sourceSyncedAt)) >= 0.001
            || now.timeIntervalSince(entry.checkedAt) >= 86_400
    }

    func record(
        recordName: String, workItemHash: String, coverHash: String,
        sourceSyncedAt: Date
    ) throws {
        entries[recordName] = Entry(
            workItemHash: workItemHash, coverHash: coverHash,
            generatorVersion: CloudContract.generatorVersion,
            sourceSyncedAt: sourceSyncedAt, checkedAt: Date())
        try persist()
    }

    func retain(_ recordNames: Set<String>) throws {
        let previousCount = entries.count
        entries = entries.filter { recordNames.contains($0.key) }
        if entries.count != previousCount { try persist() }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(
            LedgerState(
                cloudUserRecordName: cloudUserRecordName, entries: entries)
        )
        .write(to: url, options: .atomic)
    }
}
