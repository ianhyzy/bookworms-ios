import Foundation
import Observation

/// The readers the signed-in Hardcover account can compare with, their ratings, and the
/// comparisons the Share tab draws.
///
/// A refresh reads the owner's profile, block list, and followed readers, then downloads the
/// libraries of up to `readerLimit` followed readers, the most recently active first, plus
/// readers looked up by username. Each library refreshes when it is more than a day old, and
/// libraries download one at a time with a pause between them. Choosing a followed reader
/// outside that limit downloads their library on request.
///
/// A temporary failure keeps the saved snapshot and reports the failure; a later attempt waits
/// `retryInterval`. A rejected login or denied social access clears the snapshot and its file.
/// Each refresh of the followed readers removes blocked and unfollowed readers and their
/// libraries. A result that arrives after `clear()` is dropped.
///
/// Comparisons (`readers`) are prepared off the main actor whenever the snapshot or the owner's
/// library changes, never while a view draws. The snapshot is saved in `Caches/Bookworms`, so
/// the Share tab works offline; iOS may evict it, and the next refresh downloads it again.
@MainActor
@Observable
final class SocialModel {
    /// Someone to compare with and, once their library downloads, the comparison.
    struct Reader: Identifiable, Equatable, Sendable {
        let profile: ReaderProfile
        let isFollowed: Bool
        /// `nil` until the reader's library downloads.
        let match: TasteMatch?
        /// Whether Hardcover returned no rated books for the reader, as for a private profile.
        let hasNoRatings: Bool

        var id: Int { profile.id }
    }

    /// The most followed readers whose libraries a refresh downloads.
    nonisolated static let readerLimit = 15
    /// How long a refresh's results stay fresh.
    static let staleInterval: TimeInterval = 24 * 60 * 60
    /// How long a failed refresh waits before an automatic retry.
    static let retryInterval: TimeInterval = 5 * 60

    /// The signed-in reader, once known.
    private(set) var owner: ReaderProfile?
    /// Everyone to compare with: readers with a match score first, highest first, then readers
    /// with fewer books in common, then readers whose libraries have not downloaded.
    private(set) var readers: [Reader] = []
    /// Increases whenever `readers` changes, so a render request can compare it cheaply.
    private(set) var revision = 0
    private(set) var isSyncing = false
    /// Readers whose libraries are downloading on request.
    private(set) var loadingReaders: Set<Int> = []
    /// Why the last refresh or download failed, or `nil`.
    private(set) var failure: String?

    @ObservationIgnored private(set) var snapshot: SocialSnapshot?
    @ObservationIgnored private var mine: [CloudBook] = []
    @ObservationIgnored private let client: HardcoverClient
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let pause: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var lastFailure: Date?
    /// Increases with each `clear()`, so a result that arrives afterward is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var comparisonTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    #if DEBUG
        @ObservationIgnored private var usesSamples = false
    #endif

    /// Tests pass their own client, file, a zero pause, and a clock.
    init(
        client: HardcoverClient = HardcoverClient(),
        cacheURL: URL = URL.cachesDirectory.appending(path: "Bookworms/social-snapshot.json"),
        pause: Duration = HardcoverClient.pagePause,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.cacheURL = cacheURL
        self.pause = pause
        self.now = now
    }

    /// The reader with `id`, or `nil` when there is none.
    func reader(_ id: Int?) -> Reader? { readers.first { $0.id == id } }

    /// Shows the saved snapshot of `accountID`, if there is one, without a network request.
    func restore(accountID: String) async {
        guard snapshot == nil else { return }
        let generation = generation
        guard let saved = await Self.read(cacheURL), String(saved.owner.id) == accountID,
            generation == self.generation, snapshot == nil
        else { return }
        install(saved, persists: false)
    }

    /// Compares with `mine`, the owner's library, from now on.
    func prepare(mine: [CloudBook]) {
        self.mine = mine
        #if DEBUG
            if usesSamples {
                install(SocialSamples.snapshot(mine: mine), persists: false)
                return
            }
        #endif
        rebuild()
    }

    /// Refreshes when the snapshot is missing, belongs to another account, or is more than a
    /// day old, unless a refresh failed within `retryInterval`.
    func syncIfStale(token: String, accountID: String) async {
        if let lastFailure, now().timeIntervalSince(lastFailure) < Self.retryInterval { return }
        if let snapshot, String(snapshot.owner.id) == accountID, let syncedAt = snapshot.syncedAt,
            now().timeIntervalSince(syncedAt) < Self.staleInterval
        {
            return
        }
        await sync(token: token, accountID: accountID)
    }

    /// Refreshes the followed readers and the libraries that are missing or more than a day
    /// old. Does nothing while a refresh runs, or when the token belongs to another account
    /// than `accountID`.
    func sync(token: String, accountID: String) async {
        #if DEBUG
            guard !usesSamples else { return }
        #endif
        guard !isSyncing else { return }
        isSyncing = true
        let generation = generation
        defer { if generation == self.generation { isSyncing = false } }
        do {
            let owner = try await client.owner(token: token)
            guard generation == self.generation, String(owner.id) == accountID else { return }
            if snapshot?.owner.id != owner.id { install(SocialSnapshot(owner: owner)) }
            let blocked = try await client.blockedReaders(owner: owner.id, token: token)
            let following = try await client.following(
                owner: owner.id, blocked: blocked, token: token)
            guard generation == self.generation else { return }
            update {
                $0.owner = owner
                $0.following = following
                $0.prune(blocked: blocked)
            }
            // The order only picks whose libraries download, so a failure falls back on the
            // order of following.
            let active =
                (try? await client.recentlyActive(among: following.map(\.id), token: token)) ?? []
            let targets = Self.readersToSync(
                following: following, active: active, lookedUp: snapshot?.lookedUp ?? [])
            var failed = 0
            var isFirst = true
            for id in targets where isStale(id) && !loadingReaders.contains(id) {
                if !isFirst { try await Task.sleep(for: pause) }
                isFirst = false
                guard generation == self.generation else { return }
                if await !download(id, token: token, generation: generation) { failed += 1 }
            }
            guard generation == self.generation else { return }
            if failed == 0 {
                update { $0.syncedAt = now() }
                failure = nil
                lastFailure = nil
            } else {
                failure = "Some readers' ratings couldn't refresh. Showing earlier copies."
                lastFailure = now()
            }
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            if Self.deniesAccess(error) {
                clear()
                failure = Self.deniedMessage
            } else {
                failure = "Couldn't refresh the people you follow. " + Self.message(for: error)
            }
            lastFailure = now()
        }
    }

    /// Downloads the library of a followed or looked-up reader that has none, such as a
    /// followed reader outside the refresh's limit.
    func downloadIfMissing(_ id: Int, token: String) async {
        guard let snapshot, snapshot.libraries[id] == nil,
            snapshot.readers.contains(where: { $0.id == id }), !loadingReaders.contains(id)
        else { return }
        loadingReaders.insert(id)
        let generation = generation
        let succeeded = await download(id, token: token, generation: generation)
        guard generation == self.generation else { return }
        loadingReaders.remove(id)
        if !succeeded {
            let name = snapshot.readers.first { $0.id == id }?.displayName ?? "this reader"
            failure = "Couldn't download \(name)'s ratings. Try again later."
        }
    }

    /// Finds the public reader that `input` names, downloads their library, and keeps them
    /// among the readers to compare with. Returns them.
    ///
    /// A reader the owner follows or already looked up returns at once. Throws a
    /// `ReaderLookupError` for an invalid username, an unknown or private reader, a blocked
    /// reader, the owner's own account, or a reader without ratings, and a `HardcoverError`
    /// when Hardcover fails.
    func lookUp(_ input: String, token: String) async throws -> ReaderProfile {
        guard let username = ReaderProfile.username(from: input) else {
            throw ReaderLookupError.invalidUsername
        }
        let generation = generation
        let key = username.lowercased()
        let owner: ReaderProfile
        if let known = snapshot?.owner {
            owner = known
        } else {
            owner = try await client.owner(token: token)
            guard generation == self.generation else { throw CancellationError() }
            if snapshot == nil { install(SocialSnapshot(owner: owner)) }
        }
        if owner.username.lowercased() == key { throw ReaderLookupError.yourself }
        if let known = snapshot?.readers.first(where: { $0.username.lowercased() == key }) {
            await downloadIfMissing(known.id, token: token)
            return known
        }
        let found = try await client.readers(named: Array(Set([username, key])), token: token)
        guard let reader = found.first(where: { $0.username.lowercased() == key }) else {
            throw ReaderLookupError.notFound(username)
        }
        if reader.id == owner.id { throw ReaderLookupError.yourself }
        let blocked = try await client.blockedReaders(owner: owner.id, token: token)
        if blocked.contains(reader.id) { throw ReaderLookupError.blocked(reader.username) }
        let books = try await client.readerLibrary(user: reader.id, token: token)
        guard books.contains(where: { $0.rating != nil }) else {
            throw ReaderLookupError.noRatings(reader.username)
        }
        guard generation == self.generation else { throw CancellationError() }
        update {
            $0.lookedUp.removeAll { $0.id == reader.id }
            $0.lookedUp.insert(reader, at: 0)
            $0.libraries[reader.id] = ReaderLibrary(books: books, syncedAt: now())
            $0.prune(blocked: blocked)
        }
        return reader
    }

    /// Forgets every reader and deletes the saved snapshot, as after a sign-out.
    func clear() {
        #if DEBUG
            guard !usesSamples else { return }
        #endif
        generation += 1
        comparisonTask?.cancel()
        snapshot = nil
        owner = nil
        readers = []
        revision += 1
        isSyncing = false
        loadingReaders = []
        failure = nil
        lastFailure = nil
        persist()
    }

    #if DEBUG
        /// Replaces Hardcover with fictional readers (`SocialSamples`) for Simulator renders.
        func useSamples() {
            usesSamples = true
            install(SocialSamples.snapshot(mine: mine), persists: false)
        }
    #endif

    // MARK: - Downloads

    /// Downloads one reader's library into the snapshot. Returns `false` after a failure,
    /// which keeps any earlier copy. Hardcover denying this one library saves it as empty; a
    /// rejected login or denied social access clears the snapshot.
    private func download(_ id: Int, token: String, generation: Int) async -> Bool {
        let books: [CloudBook]
        do {
            books = try await client.readerLibrary(user: id, token: token)
        } catch HardcoverError.forbidden {
            books = []
        } catch {
            if Self.deniesAccess(error), generation == self.generation {
                clear()
                failure = Self.deniedMessage
            }
            return false
        }
        guard generation == self.generation else { return true }
        update { snapshot in
            guard snapshot.readers.contains(where: { $0.id == id }) else { return }
            snapshot.libraries[id] = ReaderLibrary(books: books, syncedAt: now())
        }
        return true
    }

    private func isStale(_ id: Int) -> Bool {
        guard let library = snapshot?.libraries[id] else { return true }
        return now().timeIntervalSince(library.syncedAt) >= Self.staleInterval
    }

    /// The readers a refresh downloads: up to `readerLimit` followed readers, the recently
    /// `active` first, then in the order followed, and every looked-up reader.
    nonisolated static func readersToSync(
        following: [ReaderProfile], active: [Int], lookedUp: [ReaderProfile]
    ) -> [Int] {
        let followed = following.map(\.id)
        let followedSet = Set(followed)
        var seen = Set<Int>()
        let ordered = (active.filter(followedSet.contains) + followed)
            .filter { seen.insert($0).inserted }
        return Array(ordered.prefix(readerLimit))
            + lookedUp.map(\.id).filter { !followedSet.contains($0) }
    }

    private static let deniedMessage =
        "Hardcover didn't allow access to the people you follow. Reconnect Hardcover to compare with them."

    private static func deniesAccess(_ error: any Error) -> Bool {
        guard let error = error as? HardcoverError else { return false }
        return [.invalidToken, .insufficientScope, .forbidden].contains(error)
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Snapshot

    private func update(_ change: (inout SocialSnapshot) -> Void) {
        guard var next = snapshot else { return }
        change(&next)
        install(next)
    }

    private func install(_ next: SocialSnapshot, persists: Bool = true) {
        let ownerChanged = owner != next.owner
        let readersChanged =
            snapshot?.readers != next.readers || snapshot?.libraries != next.libraries
        snapshot = next
        if ownerChanged { owner = next.owner }
        if readersChanged || readers.isEmpty { rebuild() }
        if persists { persist() }
    }

    /// Prepares `readers` from the snapshot and the owner's library off the main actor. A newer
    /// change cancels a preparation in progress.
    private func rebuild() {
        comparisonTask?.cancel()
        guard let snapshot else {
            if !readers.isEmpty {
                readers = []
                revision += 1
            }
            return
        }
        let mine = mine
        comparisonTask = Task {
            let prepared = await Self.compare(mine: mine, snapshot: snapshot)
            guard !Task.isCancelled else { return }
            readers = prepared
            revision += 1
        }
    }

    @concurrent
    nonisolated private static func compare(mine: [CloudBook], snapshot: SocialSnapshot) async
        -> [Reader]
    {
        let followed = Set(snapshot.following.map(\.id))
        let readers = snapshot.readers.map { profile in
            let library = snapshot.libraries[profile.id]
            return Reader(
                profile: profile, isFollowed: followed.contains(profile.id),
                match: library.map { TasteMatch(mine: mine, theirs: $0.books) },
                hasNoRatings: library.map { !$0.books.contains { $0.rating != nil } } ?? false)
        }
        return readers.sorted { lhs, rhs in
            let left = (lhs.match?.score ?? -1, lhs.match?.shared.count ?? -1)
            let right = (rhs.match?.score ?? -1, rhs.match?.shared.count ?? -1)
            if left != right { return left > right }
            return lhs.profile.displayName.localizedStandardCompare(rhs.profile.displayName)
                == .orderedAscending
        }
    }

    /// Writes the snapshot, or deletes the file without one, after any write in progress.
    private func persist() {
        let snapshot = snapshot
        let url = cacheURL
        let previous = writeTask
        writeTask = Task {
            await previous?.value
            await Self.write(snapshot, to: url)
        }
    }

    @concurrent
    nonisolated private static func write(_ snapshot: SocialSnapshot?, to url: URL) async {
        guard let snapshot else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    @concurrent
    nonisolated private static func read(_ url: URL) async -> SocialSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SocialSnapshot.self, from: data)
    }
}

#if DEBUG
    /// Fictional readers for Simulator renders, enabled with `-BookwormsShareFriends YES`.
    ///
    /// Their ratings derive from the shown library's rated books, so each comparison has books
    /// in common: Robin mostly agrees, Sam mostly disagrees, Marisol has a long name and a
    /// middling match, and Jun shares too few books for a score. Each also rates a few
    /// fictional books the owner doesn't have, and gives 5 stars to the first book the owner
    /// shelved without starting, for Book Swap. None has a profile photo.
    enum SocialSamples {
        static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "BookwormsShareFriends") }

        static let owner = ReaderProfile(id: -1, username: "averyreads", name: "Avery Quill")

        static func snapshot(mine: [CloudBook]) -> SocialSnapshot {
            let rated = mine.filter { ($0.rating ?? 0) >= 0.5 }
            let listed = mine.filter(\.isUnstarted).prefix(1)
                .map { book in
                    var book = book
                    book.rating = 5
                    return book
                }
            let readers: [(ReaderProfile, Int, (Double, Int) -> Double)] = [
                (
                    ReaderProfile(id: -2, username: "robinvale", name: "Robin Vale"), 18,
                    { rating, id in rating + [0, 0, 0.5, -0.5, 0][abs(id) % 5] }
                ),
                (
                    ReaderProfile(id: -3, username: "samokafor", name: "Sam Okafor"), 22,
                    { rating, id in id % 3 == 0 ? rating : 5.5 - rating }
                ),
                (
                    ReaderProfile(
                        id: -4, username: "marisol_ow", name: "Marisol Ortega-Whitfield"), 12,
                    { rating, id in rating + [1, -1, 0, 0.5][abs(id) % 4] }
                ),
                (ReaderProfile(id: -5, username: "junpark", name: "Jun Park"), 3, { r, _ in r }),
            ]
            var snapshot = SocialSnapshot(owner: owner)
            snapshot.following = readers.map(\.0)
            snapshot.syncedAt = .now
            for (index, (reader, count, rate)) in readers.enumerated() {
                let shared = rated.prefix(count)
                    .map { book in
                        var book = book
                        let rating = rate(book.rating ?? 0, book.id)
                        book.rating = min(5, max(0.5, (rating * 2).rounded() / 2))
                        book.review = nil
                        return book
                    }
                snapshot.libraries[reader.id] = ReaderLibrary(
                    books: shared + listed + extras(offset: index), syncedAt: .now)
            }
            return snapshot
        }

        /// Three fictional books rated four stars or more, different for each reader.
        private static func extras(offset: Int) -> [CloudBook] {
            let titles = [
                ("The Lantern Orchard", "Ida Marrow"), ("Salt and Sparrow", "Teo Lindqvist"),
                ("A Map of Small Hours", "Ruth Calloway"), ("The Glass Cartographer", "Nell Ashby"),
                ("Winter Bees", "Omar Keane"), ("The Quiet Tide", "Pia Albright"),
            ]
            return (0..<3)
                .map { index in
                    let (title, author) = titles[(offset + index) % titles.count]
                    return CloudBook(
                        id: -1000 - (offset + index) % titles.count, title: title, author: author,
                        coverURL: nil, detailCoverURL: nil, pages: 280 + index * 40,
                        finished: "2026-0\(index + 3)-12", rating: [5, 4.5, 4][index])
                }
        }
    }
#endif
