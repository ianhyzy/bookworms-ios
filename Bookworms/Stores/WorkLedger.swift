import Foundation

/// Remembers which books were checked or failed, so a run spends iCloud reads, cover downloads,
/// and model requests only on books that need them.
///
/// A book is rechecked when it has no entry, its work-item hash or chosen cover changed, its last
/// check ran at a model tier below the run's, or its last check is seven days old, or one day old
/// when it saved a design that awaits its font (`SpineDesignV1.awaitsFont`). A new generator
/// version alone queues no book, because a run keeps a design from its tier or a better one
/// whatever generator made it (`SpineDesignV1.action`). A recheck reads the book's saved design
/// first and downloads the cover only when the run would not keep that design or the reader
/// chose a cover (`SpineWorker`). So a weekly recheck of a current design downloads no default
/// cover and sends no model request, and a design deleted from iCloud is still made again within
/// a week. A failed book waits 24 hours unless its work-item hash or chosen cover changed. A
/// library sync alone does not trigger a recheck: it would read every book's design from iCloud,
/// and download every chosen cover, after each sync.
actor WorkLedger {
    private struct LedgerState: Codable {
        var cloudUserRecordName: String?
        var entries: [String: Entry]
    }

    struct Entry: Codable, Sendable {
        let workItemHash: String
        /// The hash of the cover that the checked design comes from; `nil` after a failure.
        let coverHash: String?
        /// The generator version at the check. Rechecks ignore it, but earlier builds can't read
        /// an entry without it, and would then check every book again.
        let generatorVersion: String
        /// The reader's chosen cover (`CloudBook.chosenCoverURL`); `nil` for the default cover,
        /// so entries written before cover choices existed still match.
        var chosenCover: URL?
        let checkedAt: Date
        /// When the last attempt failed; `nil` after a success.
        var failedAt: Date?
        /// The last successful check's tier: the run's model tier, or the tier of the design it
        /// kept or saved when that tier is better. `nil` when unknown, as after a failure or in
        /// an entry saved without it, and an unknown tier never forces a recheck.
        var tier: ModelTier?
        /// Whether the last check saved a design that awaits its font, so the book is checked
        /// again after `failureBackoff`; `nil` in an entry saved without it.
        var awaitsFont: Bool?
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
            entry.chosenCover == chosenCover
        else { return true }
        if let failedAt = entry.failedAt {
            return now.timeIntervalSince(failedAt) >= Self.failureBackoff
        }
        if let tier = entry.tier, tier < runTier { return true }
        let interval = entry.awaitsFont == true ? Self.failureBackoff : Self.recheckInterval
        return now.timeIntervalSince(entry.checkedAt) >= interval
    }

    /// Whether `chosenCover` differs from the reader's chosen cover at the book's last check. A
    /// book without an entry counts as unchanged, so a lost ledger never discards colors the
    /// reader chose.
    func readerChoseCover(recordName: String, chosenCover: URL?) -> Bool {
        entries[recordName].map { $0.chosenCover != chosenCover } ?? false
    }

    /// Records a successful check at `tier` (`Entry.tier`), which saved a design that awaits
    /// its font when `awaitsFont` is true.
    func recordSuccess(
        recordName: String, workItemHash: String, coverHash: String, chosenCover: URL? = nil,
        tier: ModelTier? = nil, awaitsFont: Bool = false, now: Date = Date()
    ) throws {
        entries[recordName] = Entry(
            workItemHash: workItemHash, coverHash: coverHash,
            generatorVersion: CloudContract.generatorVersion, chosenCover: chosenCover,
            checkedAt: now, tier: tier, awaitsFont: awaitsFont)
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
