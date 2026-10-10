import Foundation

/// Remembers which books were checked or failed, so a run spends cover downloads and Private
/// Cloud Compute requests only on books that need them.
///
/// A book is rechecked when it has no entry, its work-item hash or the generator changed, the
/// caller forces it, or its last check is seven days old. A failed book waits 24 hours unless
/// forced or its work-item hash changed. An Apple TV sync alone does not trigger a recheck: on a
/// phone, re-downloading every cover after each sync costs too much time and data.
actor WorkLedger {
    private struct LedgerState: Codable {
        var cloudUserRecordName: String?
        var entries: [String: Entry]
    }

    struct Entry: Codable, Sendable {
        let workItemHash: String
        /// The cover's hash after a successful check; `nil` after a failure.
        let coverHash: String?
        let generatorVersion: String
        let checkedAt: Date
        /// When the last attempt failed; `nil` after a success.
        var failedAt: Date?
    }

    static let recheckInterval: TimeInterval = 7 * 24 * 60 * 60
    static let failureBackoff: TimeInterval = 24 * 60 * 60

    private let url: URL
    private var cloudUserRecordName: String?
    private var entries: [String: Entry]

    init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory.appending(path: "Bookworms/ledger.json")
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

    func needsCheck(
        recordName: String, workItemHash: String, force: Bool, now: Date = Date()
    ) -> Bool {
        guard !force, let entry = entries[recordName], entry.workItemHash == workItemHash,
            entry.generatorVersion == CloudContract.generatorVersion
        else { return true }
        if let failedAt = entry.failedAt {
            return now.timeIntervalSince(failedAt) >= Self.failureBackoff
        }
        return now.timeIntervalSince(entry.checkedAt) >= Self.recheckInterval
    }

    func recordSuccess(
        recordName: String, workItemHash: String, coverHash: String, now: Date = Date()
    ) throws {
        entries[recordName] = Entry(
            workItemHash: workItemHash, coverHash: coverHash,
            generatorVersion: CloudContract.generatorVersion, checkedAt: now)
        try persist()
    }

    /// Records a failure that retrying soon would repeat, such as an unreadable cover or a
    /// design the model could not produce.
    func recordFailure(recordName: String, workItemHash: String, now: Date = Date()) throws {
        entries[recordName] = Entry(
            workItemHash: workItemHash, coverHash: nil,
            generatorVersion: CloudContract.generatorVersion, checkedAt: now, failedAt: now)
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
        try encoder.encode(LedgerState(cloudUserRecordName: cloudUserRecordName, entries: entries))
            .write(to: url, options: .atomic)
    }
}
