import Foundation

/// Remembers which books were checked or failed, so a run spends cover downloads and model
/// requests only on books that need them.
///
/// A book is rechecked when it has no entry, its work-item hash, chosen cover, or the generator
/// changed, its last check ran at a model tier below the run's, or its last check is seven days
/// old. A failed book waits 24 hours unless its work-item hash or chosen cover changed. An Apple TV sync alone does not trigger a recheck: on a phone,
/// re-downloading every cover after each sync costs too much time and data.
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
        /// The reader's chosen cover (`CloudBook.chosenCoverURL`); `nil` for the default cover,
        /// so entries written before cover choices existed still match.
        var chosenCover: URL?
        let checkedAt: Date
        /// When the last attempt failed; `nil` after a success.
        var failedAt: Date?
        /// The run's model tier at the last successful check. `nil` when unknown, as after a
        /// failure or in an entry saved without it, and an unknown tier never forces a recheck.
        var tier: ModelTier?
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

    /// Whether a run at `runTier` should check the book. A last check at a lower tier makes a
    /// better tier recheck the book at once, rather than after `recheckInterval`; `.local`, the
    /// lowest tier, forces no recheck.
    func needsCheck(
        recordName: String, workItemHash: String, chosenCover: URL? = nil,
        runTier: ModelTier = .local, now: Date = Date()
    ) -> Bool {
        guard let entry = entries[recordName], entry.workItemHash == workItemHash,
            entry.chosenCover == chosenCover,
            entry.generatorVersion == CloudContract.generatorVersion
        else { return true }
        if let failedAt = entry.failedAt {
            return now.timeIntervalSince(failedAt) >= Self.failureBackoff
        }
        if let tier = entry.tier, tier < runTier { return true }
        return now.timeIntervalSince(entry.checkedAt) >= Self.recheckInterval
    }

    /// Whether `chosenCover` differs from the reader's chosen cover at the book's last check. A
    /// book without an entry counts as unchanged, so a lost ledger never discards colors the
    /// reader chose.
    func readerChoseCover(recordName: String, chosenCover: URL?) -> Bool {
        entries[recordName].map { $0.chosenCover != chosenCover } ?? false
    }

    /// Records a successful check by a run at `tier`.
    func recordSuccess(
        recordName: String, workItemHash: String, coverHash: String, chosenCover: URL? = nil,
        tier: ModelTier? = nil, now: Date = Date()
    ) throws {
        entries[recordName] = Entry(
            workItemHash: workItemHash, coverHash: coverHash,
            generatorVersion: CloudContract.generatorVersion, chosenCover: chosenCover,
            checkedAt: now, tier: tier)
        try persist()
    }

    /// Records a failure that retrying soon would repeat, such as an unreadable cover or a
    /// design the model could not produce.
    func recordFailure(
        recordName: String, workItemHash: String, chosenCover: URL? = nil, now: Date = Date()
    ) throws {
        entries[recordName] = Entry(
            workItemHash: workItemHash, coverHash: nil,
            generatorVersion: CloudContract.generatorVersion, chosenCover: chosenCover,
            checkedAt: now, failedAt: now)
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
