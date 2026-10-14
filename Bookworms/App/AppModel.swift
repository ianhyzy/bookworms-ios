import Foundation
import Observation

/// The library the app shows: the active Hardcover account's books, their saved designs, and the
/// covers the reader chose.
///
/// Signed in to Hardcover on this iPhone, the books come from that account (`HardcoverAccount`);
/// otherwise from the Apple TV's iCloud archive. Either way `CloudSpineStore` adds the designs
/// from iCloud. Launching with `-BookwormsPreviewFolder <path>` reads a local folder instead and
/// ignores the sign-in (see `script/load-preview-data.py`); a relative path resolves inside the
/// app's `Caches/Bookworms` folder. The last library is cached so launch shows it immediately.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var library: LibrarySnapshot?
    /// The library's books, most recently finished first, then unfinished books by title.
    private(set) var books: [CloudBook] = []
    /// Maps each book that shares a series design to the book whose design it draws with
    /// (`SeriesDesigns.sources`). Recomputed when the library changes or any face loads.
    private(set) var seriesSources: [Int: Int] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// The visible tab. Other features switch it, such as **Share** from a book's details.
    var selectedTab = AppTab.share
    /// A book that a share request named; the Share tab shows it, then clears this.
    var shareBookID: Int?
    let fonts = SpineFonts()
    /// Short confirmations, such as "Saved to Photos", that any screen can show.
    let toasts = ToastCenter()
    /// This iPhone's own Hardcover sign-in and library.
    let account = HardcoverAccount()
    /// The readers the Hardcover account follows or looked up, for the Share tab's
    /// comparisons.
    let social = SocialModel()
    @ObservationIgnored let covers = CoverStore()
    @ObservationIgnored let store: any SpineStore
    /// Whether the app reads a local preview folder instead of iCloud.
    let isPreview: Bool

    @ObservationIgnored private let cacheURL = URL.cachesDirectory.appending(
        path: "Bookworms/library-snapshot.json")
    /// When a load last returned a result; a failed load does not count.
    @ObservationIgnored private var lastReload: Date?
    /// Set when a saved design names a book or account the shown library lacks, or a failed load
    /// showed the phone library without designs.
    @ObservationIgnored private var needsReload = false
    /// Designs saved while a reload's fetch runs, merged into its result so none are lost.
    @ObservationIgnored private var appliedDuringLoad: [SpineDesignV1] = []
    /// Covers chosen while a reload's fetch runs, applied to its result for the same reason.
    @ObservationIgnored private var coversChosenDuringLoad:
        [(accountID: String, bookID: Int, url: URL?)] = []
    /// The cache write that `apply(_:)` deferred until a run's saves pause.
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// Glyph checks by face and lettering, so each runs once rather than on every library change.
    @ObservationIgnored private var coverage: [String: Bool] = [:]

    private convenience init() {
        self.init(
            previewFolder: UserDefaults.standard.string(forKey: "BookwormsPreviewFolder")
                .map {
                    $0.hasPrefix("/")
                        ? URL(filePath: $0) : URL.cachesDirectory.appending(path: "Bookworms/\($0)")
                })
    }

    /// Creates a model that reads `previewFolder` instead of iCloud when one is given. The app
    /// uses `shared`; tests make their own model with a preview folder.
    init(previewFolder: URL?) {
        if let folder = previewFolder {
            self.store = LocalSpineStore(folder: folder)
            isPreview = true
        } else {
            self.store = CloudSpineStore()
            isPreview = false
            if let data = try? Data(contentsOf: cacheURL),
                let cached = try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
            {
                setLibrary(cached)
            }
        }
        account.onLibraryChange = { [unowned self] in self.accountLibraryChanged() }
        // A face that any screen loads can change which books its source's font can letter.
        fonts.onFaceLoaded = { [unowned self] in self.alignSeries() }
        #if DEBUG
            if SocialSamples.isEnabled { social.useSamples() }
        #endif
        if !isPreview, account.isSignedIn, let accountID = account.summary?.accountID {
            Task { await social.restore(accountID: accountID) }
        }
    }

    /// Opens the Share tab with `book` as the featured book.
    func share(_ book: CloudBook) {
        shareBookID = book.id
        selectedTab = .share
    }

    func look(for book: CloudBook) -> SpineLook {
        let design = design(for: book)
        return SpineLook(book: book, design: design, face: fonts.face(for: design))
    }

    /// The design `book` draws with: its series source's design when it shares one (see
    /// `SeriesDesigns`), otherwise its own.
    func design(for book: CloudBook) -> SpineDesignV1? {
        library?.designs[seriesSources[book.id] ?? book.id]
    }

    /// The book whose design and cover set `book`'s spine: its series source, or `book` itself.
    func designSource(for book: CloudBook) -> CloudBook {
        guard let id = seriesSources[book.id], id != book.id else { return book }
        return library?.books.first { $0.id == id } ?? book
    }

    /// Whether `book` shares its spine design with other books in its series, so changing the
    /// design changes theirs too.
    func sharesSeriesDesign(_ book: CloudBook) -> Bool { seriesSources[book.id] != nil }

    /// Reloads the library and designs, then loads the fonts the designs name.
    ///
    /// When signed in to Hardcover, first downloads the account's library if the copy on this
    /// iPhone is missing or a few hours old; a failed download keeps that copy and is reported.
    /// No library (an iCloud account without an Apple TV upload, or a sign-in without a
    /// downloaded copy) clears the shown and cached library, and so does a missing iCloud
    /// account when signed out, so another account's reading history never stays visible.
    /// Other errors keep the shown library and report the error. When signed in without that
    /// account's library on screen, such an error shows the downloaded Hardcover library without
    /// designs until the next reload, and does not cache it.
    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        appliedDuringLoad = []
        coversChosenDuringLoad = []
        if !isPreview { await account.syncIfStale() }
        let revision = account.libraryRevision
        do {
            let loaded = try await store.loadLibrary()
            // A sign-in, sync, or sign-out during the load replaces this result below.
            if revision == account.libraryRevision {
                if var snapshot = loaded {
                    // The newest design wins, and of designs made at the same time, the last one
                    // applied: a recoloring keeps its design's `generatedAt`.
                    snapshot.designs = LibrarySnapshot.latestDesigns(
                        appliedDuringLoad.reversed() + Array(snapshot.designs.values),
                        accountID: snapshot.accountID, books: snapshot.books)
                    for chosen in coversChosenDuringLoad
                    where chosen.accountID == snapshot.accountID {
                        snapshot.setChosenCover(chosen.url, bookID: chosen.bookID)
                    }
                    // A design saved during the load for a book the result lacks needs another
                    // reload to show.
                    needsReload = appliedDuringLoad.contains { snapshot.designs[$0.bookID] == nil }
                    setLibrary(snapshot)
                    persist()
                } else {
                    clearLibrary()
                    needsReload = false
                }
                lastReload = .now
                loadError = isPreview ? nil : account.syncError
            }
        } catch CompanionError.noICloudAccount, CompanionError.iCloudRestricted {
            clearLibrary()
            loadError = "Sign in to iCloud with the account your Apple TV uses."
            lastReload = .now
            needsReload = false
        } catch {
            loadError = error.localizedDescription
            if !isPreview, revision == account.libraryRevision,
                let accountID = account.summary?.accountID, library?.accountID != accountID,
                let phone = PhoneLibrary.load(), phone.accountID == accountID
            {
                setLibrary(
                    LibrarySnapshot(
                        accountID: phone.accountID, syncedAt: phone.syncedAt, books: phone.books,
                        designs: [:]))
                needsReload = true
            }
        }
        isLoading = false
        // The change's own reload returned early because this one was running.
        if revision != account.libraryRevision { return await reload() }
        // Social data refreshes on its own, so its downloads never hold up the next reload.
        Task { await syncSocial() }
        // Fonts load after `isLoading` clears, so a slow download never blocks the next reload.
        if let designs = library?.designs.values {
            await fonts.load(Array(designs))
        }
    }

    /// Whether the Share tab can compare with other readers: signed in to Hardcover on this
    /// iPhone outside preview mode, or showing Debug builds' fictional readers.
    var canCompare: Bool {
        #if DEBUG
            if SocialSamples.isEnabled { return true }
        #endif
        return canLookUpReaders
    }

    /// Whether this iPhone can ask Hardcover about other readers.
    var canLookUpReaders: Bool { account.isSignedIn && !isPreview }

    /// Refreshes the readers the Share tab compares with when signed in to Hardcover on this
    /// iPhone: when their data is a day old, or at once with `force`, such as a pull to
    /// refresh. Preview mode and a rejected login skip it.
    func syncSocial(force: Bool = false) async {
        guard !isPreview, account.isSignedIn, !account.needsReconnect,
            let accountID = account.summary?.accountID, let token = HardcoverTokenStore().read()
        else { return }
        if force {
            await social.sync(token: token, accountID: accountID)
        } else {
            await social.syncIfStale(token: token, accountID: accountID)
        }
    }

    /// Finds a public Hardcover reader by username and adds them to the readers to compare
    /// with (`SocialModel.lookUp(_:token:)`). Needs this iPhone's Hardcover sign-in.
    func lookUpReader(_ username: String) async throws -> ReaderProfile {
        guard !isPreview, account.isSignedIn, let token = HardcoverTokenStore().read() else {
            throw HardcoverError.invalidToken
        }
        return try await social.lookUp(username, token: token)
    }

    /// Downloads a chosen reader's library when the last refresh left it out.
    func downloadReader(_ id: Int) async {
        guard !isPreview, account.isSignedIn, let token = HardcoverTokenStore().read() else {
            return
        }
        await social.downloadIfMissing(id, token: token)
    }

    /// Shows the new phone library after a Hardcover sign-in, sync, or sign-out. The shown
    /// library clears first when it belongs to another account or the reader signed out, so
    /// neither another account's books nor the signed-out account's reviews stay visible.
    private func accountLibraryChanged() {
        guard !isPreview else { return }
        if library?.accountID != account.summary?.accountID { clearLibrary() }
        // A sign-out or another account must not keep this account's friends.
        let accountID = account.summary?.accountID
        if accountID == nil || social.snapshot.map({ String($0.owner.id) != accountID }) == true {
            social.clear()
        }
        Task { await reload() }
    }

    /// Reloads when the last load that returned a result is more than five minutes old or a
    /// saved design named a book the library lacks. Called when the app becomes active and when
    /// a generation run ends. First writes any cache update that `apply(_:)` deferred, so a run's
    /// designs reach the cache when it ends.
    func reloadIfStale() async {
        if persistTask != nil { persist() }
        guard needsReload || lastReload.map({ -$0.timeIntervalSinceNow > 300 }) ?? true else {
            return
        }
        await reload()
    }

    /// Shows a design that the generator or `recolor(_:to:)` saves, without a reload.
    ///
    /// The library cache is written once saves pause for 20 seconds or `reloadIfStale()` runs,
    /// so a run does not encode and write the whole library on the main actor for each design.
    func apply(_ design: SpineDesignV1) {
        if isLoading { appliedDuringLoad.append(design) }
        guard var library, design.accountID == library.accountID,
            library.books.contains(where: { $0.id == design.bookID })
        else {
            // The Apple TV changed the library since it loaded; the next reload shows it.
            needsReload = true
            return
        }
        library.designs[design.bookID] = design
        setLibrary(library)
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            persist()
        }
        Task { await fonts.load([design]) }
    }

    /// Shows `colors` on the spine `book` draws and saves them to that design as the reader's
    /// colors (see `SpineDesignV1.recolored(_:)`), through the store the library comes from.
    /// A book that shares its series' design recolors the series source, which recolors every
    /// book in the series.
    ///
    /// Throws when the colors cannot be saved, and then they stay on screen until the next
    /// reload. Throws `CompanionError.invalidDesign`, before showing anything, when the colors
    /// are not readable, and `CompanionError.bookNotInLibrary` when the book has no design.
    /// When iCloud holds another design, such as a redesign from another device, reloads to show
    /// it and throws `CompanionError.designChanged`.
    func recolor(_ book: CloudBook, to colors: SpineColors) async throws {
        guard let design = design(for: book) else {
            throw CompanionError.bookNotInLibrary
        }
        let recolored = design.recolored(colors)
        try recolored.validate()
        apply(recolored)
        do {
            try await store.saveRecolored(recolored)
        } catch CompanionError.designChanged {
            await reload()
            throw CompanionError.designChanged
        }
    }

    /// Returns the covers of `book`'s Hardcover editions for the cover picker. Needs this
    /// iPhone's Hardcover sign-in.
    func editionCovers(for book: CloudBook) async throws -> [EditionCover] {
        #if DEBUG
            if CoverPickerDebug.stubsExpiredLogin { throw HardcoverError.invalidToken }
            if CoverPickerDebug.stubsCovers { return CoverPickerDebug.covers(for: book) }
        #endif
        guard account.isSignedIn, let token = KeychainSecret().read() else {
            throw HardcoverError.invalidToken
        }
        return try await HardcoverClient().editionCovers(bookID: book.id, token: token)
    }

    /// Saves `cover` as `book`'s cover for the shown account, or deletes the choice when `cover`
    /// is `nil` or the default cover, then shows the result without a reload.
    ///
    /// The choice goes to iCloud, so other devices and generation runs use it too. Throws when
    /// it cannot be saved, and then nothing changes. Throws `CompanionError.bookNotInLibrary`
    /// unless the shown library includes `book`, for example after a sign-in to another account.
    func chooseCover(_ cover: EditionCover?, for book: CloudBook) async throws {
        guard let shown = library, shown.books.contains(where: { $0.id == book.id }) else {
            throw CompanionError.bookNotInLibrary
        }
        let accountID = shown.accountID
        let chosen = cover?.url == (book.detailCoverURL ?? book.coverURL) ? nil : cover
        if let chosen {
            try await store.save(
                CoverChoiceV1(
                    version: 1, accountID: accountID, bookID: book.id, coverURL: chosen.url,
                    editionID: chosen.editionID, chosenAt: .now))
        } else {
            try await store.deleteCoverChoice(accountID: accountID, bookID: book.id)
        }
        if isLoading { coversChosenDuringLoad.append((accountID, book.id, chosen?.url)) }
        guard var library, library.accountID == accountID else { return }
        library.setChosenCover(chosen?.url, bookID: book.id)
        setLibrary(library)
        persist()
    }

    private func clearLibrary() {
        // A deferred write would restore the cleared library.
        persistTask?.cancel()
        persistTask = nil
        library = nil
        books = []
        social.prepare(mine: [])
        alignSeries()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func setLibrary(_ snapshot: LibrarySnapshot) {
        let previousBooks = library?.books
        library = snapshot
        // Before the early return: a new or recolored design can change a series' source.
        alignSeries()
        guard previousBooks != snapshot.books else { return }
        books = snapshot.books.sorted { lhs, rhs in
            switch (lhs.finished, rhs.finished) {
            case (let left?, let right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
        social.prepare(mine: books)
    }

    /// Recomputes `seriesSources` from the library and the loaded faces. A book whose lettering
    /// the source's loaded face lacks glyphs for keeps its own design; until a face loads, the
    /// source's system typeface letters every book.
    private func alignSeries() {
        let sources =
            library.map { library in
                SeriesDesigns.sources(books: library.books, designs: library.designs) {
                    book, design in
                    guard let face = fonts.face(for: design) else { return true }
                    let text = SeriesDesigns.lettering(of: book, uppercase: design.uppercase)
                    let key = face.postScriptName + "\n" + text
                    if let covered = coverage[key] { return covered }
                    let covered = face.covers(text)
                    coverage[key] = covered
                    return covered
                }
            } ?? [:]
        if sources != seriesSources { seriesSources = sources }
    }

    /// Writes the shown library to the launch cache, replacing any deferred write.
    private func persist() {
        persistTask?.cancel()
        persistTask = nil
        guard !isPreview, let library, let data = try? JSONEncoder().encode(library) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

extension LibrarySnapshot {
    fileprivate mutating func setChosenCover(_ url: URL?, bookID: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].chosenCoverURL = url
    }
}

/// The app's tabs, in the tab bar's order. Debug launch arguments name them by raw value, such
/// as `-BookwormsTab desk`.
enum AppTab: String, Hashable {
    case share, library, desk, spines
}
