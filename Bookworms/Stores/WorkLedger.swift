import Foundation

/// Remembers which books were checked or failed, so a run spends iCloud reads, cover downloads,
/// and model requests only on books that need them.
///
/// A book is rechecked when it has no entry, its work-item hash or chosen cover changed, its last
/// check ran at a tier that the run's tier replaces (`ModelTier.isReplaced(by:)`), its last check
/// saved another model's design in place of the run's tier and that tier runs again
/// (`Entry.standInFor`), or its last check is seven days old, or one day old when it saved a
/// design that awaits its font (`SpineDesignV1.awaitsFont`). A new generator version alone queues
/// no book, because a run keeps a design from its tier or a better one whatever generator made it
/// (`SpineDesignV1.action`). A recheck reads the book's saved design first and downloads the
/// cover only when the run would not keep that design or the reader chose a cover
/// (`SpineWorker`). So a weekly recheck of a current design downloads no default cover and sends
/// no model request, and a design deleted from iCloud is still made again within a week. A
/// failed book waits 24 hours unless its work-item hash or chosen cover changed. A library sync
/// alone does not trigger a recheck: it would read every book's design from iCloud, and download
/// every chosen cover, after each sync.
actor WorkLedger {
    private struct LedgerState: Codable {
        var cloudUserRecordName: String?
        var entries: [String: Entry]
    }

    struct Entry: Codable, Sendable {
        let workItemHash: String
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
        /// Whether the last check saved a design that awaits its font, or kept a design under
        /// the book's old metadata (`SpineWorker.runPass`), so the book is checked again after
        /// `failureBackoff`; `nil` in an entry saved without it.
        var awaitsFont: Bool?
        /// The run's tier when a check saved another model's design in its place, as when the
        /// backup model couldn't answer (`SpineWorker.designWithoutBackup`), so the next run at
        /// that tier checks the book again; `nil` otherwise. A failed check keeps it, and so does
        /// a check that keeps the unedited stand-in. A check that keeps a stand-in the reader
        /// edited drops it.
        var standInFor: ModelTier?
        /// When that stand-in was generated (`SpineDesignV1.generatedAt`), so another design
        /// saved since, such as another device's, is no stand-in.
        var standInGeneratedAt: Date?
        /// Whether a failed check's `chosenCover` is a choice the reader made since the last
        /// successful check, so the retry still designs from it (`readerChoseCover`). Only a
        /// success clears it; `nil` in an entry saved without it.
        var pendingChoice: Bool?
        /// The book's first default cover candidate at the last successful check, which a
        /// failed check keeps, so a check after a sync swaps in a sharper default cover knows it
        /// changed (`defaultCoverChanged(recordName:defaultCover:)`); `nil` when unknown, as in
        /// an entry saved without it.
        var defaultCover: URL?
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
        // Private database records do not transfer between iCloud accounts or between CloudKit
        // environments.
        cloudUserRecordName = recordName
        entries = [:]
        try persist()
    }

    /// Whether a run at `runTier` should check the book. A last check at local defaults or the
    /// on-device model makes a better tier recheck the book at once, rather than after
    /// `recheckInterval`, because that tier replaces those designs (`ModelTier.isReplaced(by:)`);
    /// `.local`, the lowest tier, forces no recheck. A design that stood in for `runTier`'s model
    /// (`Entry.standInFor`) makes that tier recheck the book at once too.
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
        if let tier = entry.tier, tier.isReplaced(by: runTier) { return true }
        if entry.standInFor == runTier, runTier > .local { return true }
        let interval = entry.awaitsFont == true ? Self.failureBackoff : Self.recheckInterval
        return now.timeIntervalSince(entry.checkedAt) >= interval
    }

    /// Whether `chosenCover` differs from the reader's chosen cover at the book's last
    /// successful check: it differs from the last check's, or a failed check of it left the
    /// choice pending (`Entry.pendingChoice`). A book without an entry counts as unchanged, so a
    /// lost ledger never discards colors the reader chose.
    func readerChoseCover(recordName: String, chosenCover: URL?) -> Bool {
        entries[recordName].map { $0.chosenCover != chosenCover || $0.pendingChoice == true }
            ?? false
    }

    /// Whether `defaultCover` differs from the book's default cover at its last successful
    /// check (`Entry.defaultCover`). A book without an entry, or with an entry that doesn't
    /// record it, counts as unchanged.
    func defaultCoverChanged(recordName: String, defaultCover: URL?) -> Bool {
        entries[recordName]?.defaultCover.map { $0 != defaultCover } ?? false
    }

    /// Records a successful check at `tier` (`Entry.tier`). With `awaitsFont`, such as for a
    /// saved design that awaits its font, the book is checked again after `failureBackoff`. With
    /// `standIn`, the check saved another model's design in place of that tier's
    /// (`Entry.standInFor`).
    func recordSuccess(
        recordName: String, workItemHash: String, chosenCover: URL? = nil, tier: ModelTier? = nil,
        awaitsFont: Bool = false, standIn: (design: SpineDesignV1, tier: ModelTier)? = nil,
        defaultCover: URL? = nil, now: Date = Date()
    ) throws {
        entries[recordName] = Entry(
            workItemHash: workItemHash, generatorVersion: CloudContract.generatorVersion,
            chosenCover: chosenCover, checkedAt: now, tier: tier, awaitsFont: awaitsFont,
            standInFor: standIn?.tier, standInGeneratedAt: standIn?.design.generatedAt,
            defaultCover: defaultCover)
        try persist()
    }

    /// Whether `design`, the book's saved design, is the one that stood in for `runTier`'s model
    /// (`Entry.standInFor`), so a run at that tier designs the book again.
    func standsIn(recordName: String, for runTier: ModelTier, design: SpineDesignV1) -> Bool {
        guard let entry = entries[recordName] else { return false }
        return entry.standInFor == runTier && entry.standInGeneratedAt == design.generatedAt
    }

    /// Records a failure that retrying soon would repeat, such as an unreadable cover or a
    /// design the model could not produce. A stand-in the book's saved design is still
    /// (`Entry.standInFor`) stays recorded, so a later check designs it again, and so does a
    /// cover choice the failed check didn't design (`Entry.pendingChoice`) and the last
    /// successful check's default cover (`Entry.defaultCover`).
    func recordFailure(
        recordName: String, workItemHash: String, chosenCover: URL? = nil,
        defaultCover: URL? = nil, now: Date = Date()
    ) throws {
        let previous = entries[recordName]
        let pending = previous.map {
            $0.chosenCover != chosenCover || $0.pendingChoice == true
        }
        entries[recordName] = Entry(
            workItemHash: workItemHash, generatorVersion: CloudContract.generatorVersion,
            chosenCover: chosenCover, checkedAt: now, failedAt: now,
            standInFor: previous?.standInFor, standInGeneratedAt: previous?.standInGeneratedAt,
            pendingChoice: pending == true ? true : nil,
            defaultCover: previous.map(\.defaultCover) ?? defaultCover)
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
