import Foundation
import Observation

/// The library the app shows: the active Hardcover account's books, their saved designs and series
/// looks, and the covers and series links the reader chose.
///
/// Signed in to Hardcover on this device, the books come from that account (`HardcoverAccount`),
/// which shares its library with the reader's other devices through the iCloud archive;
/// otherwise from that archive's newest Hardcover library. Either way `CloudSpineStore` adds the
/// designs, looks, and choices from iCloud. Launching with `-BookwormsPreviewFolder <path>` reads
/// a local folder instead and ignores the sign-in (see `script/load-preview-data.py`); a relative
/// path resolves inside the app's `Caches/Bookworms` folder. The last library is cached so launch
/// shows it immediately.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var library: LibrarySnapshot?
    /// The library's books, most recently finished first, then unfinished books by title.
    private(set) var books: [CloudBook] = []
    /// Maps each book that shares a series design with another book to the book whose design sets
    /// its spine: for a series look, the look's source book while it draws the look too, else the
    /// book itself; in a look group without a look, its source by rank (`SeriesDesigns.sources`).
    /// Recomputed when the library changes or any face loads.
    private(set) var seriesSources: [Int: Int] = [:]
    /// The series look that each book drawing one draws, as that book's design
    /// (`SeriesLookV1.design(bookID:hashesFrom:)`). Recomputed with `seriesSources`.
    private(set) var lookDesigns: [Int: SpineDesignV1] = [:]
    /// The library's designs by book ID, in allowed upright faces (`SpineDesignV1.withAllowedFont`),
    /// so drawing reads them without remapping. Recomputed when the library's designs change.
    private var allowedDesigns: [Int: SpineDesignV1] = [:]
    /// Counts changes to the library and to the designs its books draw, so a view that prepares
    /// data from every book's design watches one number instead of comparing the designs.
    private(set) var designRevision = 0
    private(set) var isLoading = false
    /// Why the last load from iCloud or the preview folder failed; a successful load clears it.
    /// A failed Hardcover download is `account.syncError`.
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
    /// Whether the shown library is a load's result from this session, with the saves made since.
    /// The launch cache and the library a failed load leaves on screen may be out of date, such as
    /// missing a look another device saved, so the catch-up (`createMissingLooks()`) skips them.
    @ObservationIgnored private var showsLoadedLibrary = false
    /// Set when a saved design names a book or account the shown library lacks, or a failed load
    /// showed the phone library without designs.
    @ObservationIgnored private var needsReload = false
    /// Designs saved while a reload's fetch runs, merged into its result so none are lost.
    @ObservationIgnored private var appliedDuringLoad: [SpineDesignV1] = []
    /// Covers chosen while a reload's fetch runs, applied to its result for the same reason.
    @ObservationIgnored private var coversChosenDuringLoad:
        [(accountID: String, bookID: Int, url: URL?)] = []
    /// Series links chosen while a reload's fetch runs, applied to its result for the same reason.
    @ObservationIgnored private var linksChosenDuringLoad:
        [(accountID: String, bookID: Int, link: SeriesLinkV1?)] = []
    /// Series looks saved while a reload's fetch runs, merged into its result for the same reason.
    @ObservationIgnored private var looksAppliedDuringLoad: [SeriesLookV1] = []
    /// The cache write that `apply(_:)` deferred until a run's saves pause.
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// Glyph checks by face and lettering, so each runs once rather than on every library change.
    @ObservationIgnored private var coverage: [String: Bool] = [:]
    /// The library's look groups, each in rank order (`SeriesDesigns.rankedLookGroups(_:)`).
    /// Recomputed when the library's books change rather than each time a face loads.
    @ObservationIgnored private var lookGroups: [SeriesLookKey: [CloudBook]] = [:]

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
            account.cloud = store
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

    /// The design `book` draws with: its series look, or its series source's design when it
    /// shares one (see `SeriesDesigns`), otherwise its own, in an allowed upright face
    /// (`SpineDesignV1.withAllowedFont`).
    func design(for book: CloudBook) -> SpineDesignV1? {
        lookDesigns[book.id] ?? allowedDesigns[seriesSources[book.id] ?? book.id]
    }

    /// How many books have no cover, neither Hardcover's nor one the reader chose, and draw no
    /// design, so they show the default cover and spine. A run never designs such a book
    /// (`SpineWorker.reconcile(mode:redesigning:)`), but one in a series can draw the series'
    /// design. It walks every book, so views count when `designRevision` changes, not in a body.
    func defaultStyledBookCount() -> Int {
        books.count { $0.coverCandidates.isEmpty && design(for: $0) == nil }
    }

    /// The stored design that `book` draws when it draws no series look: its series source's, or
    /// its own.
    private func savedDesign(for book: CloudBook) -> SpineDesignV1? {
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

    /// Whether **Style** lets the reader choose whether edits to `book` change its series' look
    /// or only the book (`SeriesLinkV1.ownLook`): its look group has a saved look or another
    /// library book, counting books that keep their own look.
    func choosesEditScope(for book: CloudBook) -> Bool {
        guard let library, let key = SeriesDesigns.lookKey(of: book, link: book.seriesLink) else {
            return false
        }
        // The series check skips the slower author and title keys of most books.
        return library.looks[key] != nil
            || library.books.contains {
                $0.id != book.id
                    && SeriesDesigns.styleSeries(of: $0, link: $0.seriesLink)?.id == key.seriesID
                    && SeriesDesigns.lookKey(of: $0, link: $0.seriesLink) == key
            }
    }

    /// The colors **Reset colors** restores on the spine `book` draws, or `nil` when unknown: the
    /// generator's colors of its design (`SpineDesignV1.generatedColors`). For a series look,
    /// those of the look's source design while it has the look's generator and font, so it is
    /// the design the look was made from.
    func generatedColors(for book: CloudBook) -> SpineColors? {
        guard let look = drawnLook(of: book) else {
            return design(for: book).flatMap { $0.generatedColors ?? $0.colors }
        }
        guard let source = library?.designs[look.sourceBookID],
            source.generatorVersion == look.origin,
            source.fontPostScriptName == look.fontPostScriptName
        else { return nil }
        return source.generatedColors ?? source.colors
    }

    /// The series look that `book` draws, if any.
    func drawnLook(of book: CloudBook) -> SeriesLookV1? {
        guard lookDesigns[book.id] != nil,
            let key = SeriesDesigns.lookKey(of: book, link: book.seriesLink)
        else { return nil }
        return library?.looks[key]
    }

    /// Reloads the library and designs, then, after a successful load, creates missing series
    /// looks (`createMissingLooks()`) while it loads the fonts the designs name.
    ///
    /// When signed in to Hardcover, first brings the account's library up to date from iCloud or
    /// Hardcover (`HardcoverAccount.syncIfStale()`); a failed download keeps the copy on this
    /// device and is reported.
    /// No library (an iCloud account without a saved library, or a sign-in without a
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
        linksChosenDuringLoad = []
        looksAppliedDuringLoad = []
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
                    for chosen in linksChosenDuringLoad
                    where chosen.accountID == snapshot.accountID {
                        snapshot.setSeriesLink(chosen.link, bookID: chosen.bookID)
                    }
                    for look in looksAppliedDuringLoad where look.accountID == snapshot.accountID {
                        snapshot.looks[look.key] = look
                    }
                    // A design saved during the load for a book the result lacks needs another
                    // reload to show.
                    needsReload = appliedDuringLoad.contains { snapshot.designs[$0.bookID] == nil }
                    setLibrary(snapshot)
                    showsLoadedLibrary = true
                    persist()
                } else {
                    clearLibrary()
                    needsReload = false
                }
                lastReload = .now
                loadError = nil
            }
        } catch CompanionError.noICloudAccount, CompanionError.iCloudRestricted {
            clearLibrary()
            loadError = "Sign in to iCloud with the account your other Apple devices use."
            lastReload = .now
            needsReload = false
        } catch {
            loadError = error.localizedDescription
            showsLoadedLibrary = false
            if !isPreview, revision == account.libraryRevision,
                let accountID = account.summary?.accountID, library?.accountID != accountID,
                let phone = PhoneLibrary.load(), phone.accountID == accountID
            {
                setLibrary(
                    LibrarySnapshot(
                        accountID: phone.accountID, syncedAt: phone.syncedAt, books: phone.books,
                        designs: [:], series: phone.series))
                needsReload = true
            }
        }
        isLoading = false
        // The change's own reload returned early because this one was running.
        if revision != account.libraryRevision { return await reload() }
        // Social data refreshes on its own, so its downloads never hold up the next reload.
        Task { await syncSocial() }
        // The catch-up's serial saves and the font downloads run side by side, so neither waits
        // for the other; `apply(_:)` loads the faces of the looks the catch-up saves.
        async let catchUp: Void = createMissingLooks()
        // Fonts load after `isLoading` clears, so a slow download never blocks the next reload.
        if let designs = library?.designs.values {
            await fonts.load(designs.map(\.withAllowedFont) + Array(lookDesigns.values))
        }
        await catchUp
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
            let accountID = account.summary?.accountID,
            let token = try? await account.accessToken()
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
        guard !isPreview else { throw HardcoverError.invalidToken }
        return try await account.withAccessToken { try await social.lookUp(username, token: $0) }
    }

    /// Downloads a chosen reader's library when the last refresh left it out.
    func downloadReader(_ id: Int) async {
        guard !isPreview, let token = try? await account.accessToken() else { return }
        await social.downloadIfMissing(id, token: token)
    }

    /// Shows the new phone library after a Hardcover sign-in, sync, adoption of an iCloud copy, or
    /// sign-out. The shown library clears first when it belongs to another account or the reader
    /// signed out, so another account's books never stay visible. Signed out, the reload shows
    /// the iCloud archive, which can hold the library and reviews this device published.
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
    /// a generation run ends. On an iPhone, first reads the Hardcover login again if the
    /// Keychain refused the last read (`HardcoverAccount.retryUnreadLogin()`). Then writes any
    /// cache update that `apply(_:)` deferred, so a run's designs reach the cache when it ends.
    func reloadIfStale() async {
        // On a Mac, a read can show a keychain prompt, which takes the app out of the
        // foreground, so a read on each activation could ask again as soon as the reader
        // declines. There, **Sync now** and the next launch read the login again.
        #if !os(macOS)
            account.retryUnreadLogin()
        #endif
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
        persistSoon()
        Task { await fonts.load([design.withAllowedFont]) }
    }

    /// Shows series looks that the generator, the catch-up after a reload, or `recolor(_:to:)`
    /// saves, without a reload. Like `apply(_:)` for designs, it defers the cache write.
    func apply(_ looks: [SeriesLookV1]) {
        if isLoading { looksAppliedDuringLoad += looks }
        guard var library else { return }
        for look in looks where look.accountID == library.accountID {
            library.looks[look.key] = look
        }
        setLibrary(library)
        persistSoon()
        Task { await fonts.load(looks.map { $0.design(bookID: $0.sourceBookID) }) }
    }

    /// Saves the series look of each look group that has none but has a member with a usable
    /// saved design made for the book as it is now (`SeriesDesigns.missingLooks`), and shows the
    /// look each group keeps, which another device may have saved first. Each save is tried on
    /// its own: a failed save leaves its group to the rank rule until the next reload tries
    /// again.
    ///
    /// Does nothing unless a load in this session showed the library (`showsLoadedLibrary`), so
    /// neither the launch cache nor a failed load's library seeds a look.
    private func createMissingLooks() async {
        guard showsLoadedLibrary, let library else { return }
        var saved: [SeriesLookV1] = []
        for look in SeriesDesigns.missingLooks(
            books: library.books, designs: library.designs, looks: library.looks, now: .now)
        {
            if let kept = try? await store.createLook(look) { saved.append(kept) }
        }
        if !saved.isEmpty { apply(saved) }
    }

    /// Writes the library cache once saves pause for 20 seconds.
    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    /// Shows `colors` on the spine `book` draws and saves them to that design as the reader's
    /// colors (see `SpineDesignV1.recolored(_:)`), through the store the library comes from.
    /// A book that draws its series' look recolors the look, and a book that shares its series
    /// source's design recolors that design; either recolors every book that draws it.
    ///
    /// Throws when the colors cannot be saved, and then they stay on screen until the next
    /// reload. Throws `CompanionError.invalidDesign`, before showing anything, when the colors
    /// are not readable, and `CompanionError.bookNotInLibrary` when the book has no design.
    /// When iCloud holds another design or look, such as a redesign from another device, reloads
    /// to show it and throws `CompanionError.designChanged`.
    func recolor(_ book: CloudBook, to colors: SpineColors) async throws {
        do {
            if let look = drawnLook(of: book) {
                let recolored = look.recolored(colors, at: .now)
                try recolored.validate()
                apply([recolored])
                try await store.saveRecolored(recolored)
                return
            }
            guard let design = savedDesign(for: book) else {
                throw CompanionError.bookNotInLibrary
            }
            let recolored = design.recolored(colors)
            try recolored.validate()
            apply(recolored)
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
        return try await account.withAccessToken {
            try await HardcoverClient().editionCovers(bookID: book.id, token: $0)
        }
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

    /// Saves the reader's series choice for `book` in the shown account, or deletes it when the
    /// choice changes nothing (`SeriesLinkV1.changesNothing`), then shows the result without a
    /// reload. `linkedSeriesID` names the series whose look the book draws, `standsAlone` takes
    /// it out of every series, and `ownLook` keeps its own design instead of its series' look.
    ///
    /// The choice goes to iCloud, so other devices and generation runs use it too. A look group
    /// that the book joins and that has no look yet gets one when a member has a usable, current
    /// design (`SeriesDesigns.missingLooks`) and a load in this session showed the library
    /// (`createMissingLooks()`). Throws when the choice cannot be saved, and then nothing
    /// changes. Throws `CompanionError.bookNotInLibrary` unless the shown library includes
    /// `book`.
    func setSeriesLink(
        for book: CloudBook, linkedSeriesID: Int?, standsAlone: Bool, ownLook: Bool
    ) async throws {
        guard let shown = library, shown.books.contains(where: { $0.id == book.id }) else {
            throw CompanionError.bookNotInLibrary
        }
        let accountID = shown.accountID
        let chosen = SeriesLinkV1(
            version: 1, accountID: accountID, bookID: book.id, linkedSeriesID: linkedSeriesID,
            standsAlone: standsAlone, ownLook: ownLook, chosenAt: .now)
        let link = chosen.changesNothing ? nil : chosen
        if let link {
            try await store.save(link)
        } else {
            try await store.deleteSeriesLink(accountID: accountID, bookID: book.id)
        }
        if isLoading { linksChosenDuringLoad.append((accountID, book.id, link)) }
        guard var library, library.accountID == accountID else { return }
        library.setSeriesLink(link, bookID: book.id)
        setLibrary(library)
        persist()
        await createMissingLooks()
    }

    private func clearLibrary() {
        // A deferred write would restore the cleared library.
        persistTask?.cancel()
        persistTask = nil
        library = nil
        designRevision += 1
        showsLoadedLibrary = false
        lookGroups = [:]
        allowedDesigns = [:]
        books = []
        social.prepare(mine: [])
        alignSeries()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func setLibrary(_ snapshot: LibrarySnapshot) {
        let previousBooks = library?.books
        let previousDesigns = library?.designs
        library = snapshot
        designRevision += 1
        if previousBooks != snapshot.books {
            lookGroups = SeriesDesigns.rankedLookGroups(snapshot.books)
        }
        if previousDesigns != snapshot.designs {
            allowedDesigns = snapshot.designs.mapValues(\.withAllowedFont)
        }
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

    /// Recomputes `seriesSources` and `lookDesigns` from the library and the loaded faces.
    ///
    /// The books of a look group with a saved look draw it; the books of other groups draw by
    /// rank (`SeriesDesigns.sources`). A book whose lettering, uppercased when the design is
    /// uppercase, the look's or source's loaded face lacks glyphs for draws its own design;
    /// until a face loads, the check passes. Edits to a book that draws a look, such as **Change
    /// cover** and **Redesign spine**, act on the look's source book while it draws the look
    /// too, else on the book itself. A book that alone draws its group's look shares it with no
    /// one, so it has no series source.
    private func alignSeries() {
        var sources: [Int: Int] = [:]
        var drawn: [Int: SpineDesignV1] = [:]
        if let library {
            var unlooked: [[CloudBook]] = []
            for (key, members) in lookGroups {
                guard let look = library.looks[key] else {
                    unlooked.append(members)
                    continue
                }
                var drawing: [Int] = []
                for book in members {
                    let design = look.design(bookID: book.id, hashesFrom: library.designs[book.id])
                    guard canLetter(book, with: design) else { continue }
                    drawn[book.id] = design
                    drawing.append(book.id)
                }
                guard drawing.count > 1 else { continue }
                let source = drawing.contains(look.sourceBookID) ? look.sourceBookID : nil
                for id in drawing { sources[id] = source ?? id }
            }
            sources.merge(
                SeriesDesigns.sources(
                    ranked: unlooked, designs: library.designs, canLetter: canLetter(_:with:))
            ) { $1 }
        }
        let changed = sources != seriesSources || drawn != lookDesigns
        if sources != seriesSources { seriesSources = sources }
        if drawn != lookDesigns { lookDesigns = drawn }
        if changed { designRevision += 1 }
    }

    /// Returns whether the face that draws `design` has glyphs for `book`'s lettering, or `true`
    /// before the face loads. Each face and lettering is checked once.
    private func canLetter(_ book: CloudBook, with design: SpineDesignV1) -> Bool {
        guard let face = fonts.face(for: design.withAllowedFont) else { return true }
        let text = SeriesDesigns.lettering(of: book, uppercase: design.uppercase)
        let key = face.postScriptName + "\n" + text
        if let covered = coverage[key] { return covered }
        let covered = face.covers(text)
        coverage[key] = covered
        return covered
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

    fileprivate mutating func setSeriesLink(_ link: SeriesLinkV1?, bookID: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].seriesLink = link
    }
}

/// The app's tabs, in the tab bar's order. Debug launch arguments name them by raw value, such
/// as `-BookwormsTab desk`.
enum AppTab: String, Hashable {
    case share, library, desk, spines
}
