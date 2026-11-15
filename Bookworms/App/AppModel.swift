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
/// shows it immediately. A device without a library or sign-in can show the bundled example
/// profile instead (`showExample(from:)`), which nothing caches or saves.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var library: LibrarySnapshot?
    /// The library's books, most recently finished first, then unfinished books by title.
    private(set) var books: [CloudBook] = []
    /// `books` by ID (`book(id:)`), so views that follow one book don't scan the library on
    /// each pass.
    private var booksByID: [Int: CloudBook] = [:]
    /// Maps each book that shares a series design with another book to the book whose design sets
    /// its spine: for a series look, the look's source book while it draws the look too, else the
    /// book itself; in a look group without a look, its source by rank (`SeriesDesigns.sources`).
    /// Recomputed when the library changes or any face loads.
    private(set) var seriesSources: [Int: Int] = [:]
    /// The series look that each book drawing one draws, as that book's design
    /// (`SeriesLookV1.design(bookID:hashesFrom:)`), in its system typeface when its face lacks
    /// a glyph one of the look's books needs. Recomputed with `seriesSources`.
    private(set) var lookDesigns: [Int: SpineDesignV1] = [:]
    /// The series sources, by book ID, whose design the books drawing it letter in its system
    /// typeface, because its face lacks a glyph one of them needs (`SeriesDesigns`). Recomputed
    /// with `seriesSources`.
    private(set) var systemTypefaceSources: Set<Int> = []
    /// The IDs of the books that draw one shared design, a look or a series source's design, by
    /// the ID of each of them. Recomputed with `seriesSources`.
    private(set) var seriesMates: [Int: [Int]] = [:]
    /// The library's designs by book ID, in allowed upright faces (`SpineDesignV1.withAllowedFont`),
    /// so drawing reads them without remapping. Recomputed when the library's designs change.
    private var allowedDesigns: [Int: SpineDesignV1] = [:]
    /// Counts changes to the library and to the designs its books draw, so a view that prepares
    /// data from every book's design watches one number instead of comparing the designs.
    private(set) var designRevision = 0
    /// How many of the library's books draw a design (`design(for:)`), which the Mac's menu bar
    /// item shows. Recomputed with `seriesSources`, so no view walks the books to count them.
    private(set) var designedBookCount = 0
    private(set) var isLoading = false
    /// Why the last load from iCloud or the preview folder failed; a successful load clears it.
    /// A failed Hardcover download is `account.syncError`.
    private(set) var loadError: String?
    /// Why the signed-in library shows without iCloud, such as "Sign in to iCloud on this
    /// iPhone.", from the last load that showed it.
    private(set) var iCloudIssue: String?
    /// The question the last iCloud account check asks the reader, which the app's alert shows:
    /// `.otherAccounts` or `.chooseLibrary`. `nil` when nothing waits for an answer.
    private(set) var accountPrompt: CloudAccountCheck?
    /// Why the last **Merge** failed, which an alert shows until the reader dismisses it.
    var mergeError: String?
    /// Whether the alert on deleting Bookworms data from iCloud shows, after **Keep iCloud Off**.
    var showsICloudDeletion = false
    /// Whether the reader turned iCloud storage off on this device (`CloudStorage.isOff`).
    private(set) var iCloudIsOff = CloudStorage.isOff()
    /// The visible tab. Other features switch it, such as **Share** from a book's details.
    var selectedTab = AppTab.share {
        didSet { if selectedTab == .desk, oldValue != .desk { endDeskHold() } }
    }
    /// Counts each end of the wait for a sync's books on Desk (`DeskBookHold`).
    private(set) var deskHoldEnds = 0

    /// Lets the desk's scenes take the latest library: the reader entered Desk or chose a time
    /// frame.
    func endDeskHold() { deskHoldEnds &+= 1 }
    /// A book that a share request named; the Share tab shows it, then clears this.
    var shareBookID: Int?
    let fonts: SpineFonts
    /// Short confirmations, such as "Saved to Photos", that any screen can show.
    let toasts = ToastCenter()
    /// This device's own Hardcover sign-in and library.
    let account = HardcoverAccount()
    /// The readers the Hardcover account follows or looked up, for the Share tab's
    /// comparisons.
    let social = SocialModel()
    @ObservationIgnored let covers = CoverStore()
    @ObservationIgnored let store: any SpineStore
    /// The looks as iCloud last confirmed them, by group: an edit saves over its group's entry
    /// (`SpineStore.saveEdited(_:replacing:)`), so an edit retried after a failed save, whose
    /// look shows on screen unsaved, still finds its base.
    @ObservationIgnored private var persistedLooks: [SeriesLookKey: SeriesLookV1] = [:]
    /// The latest look edit saving, and the last one this device saved, by group
    /// (`saveEdited(_:over:)`).
    @ObservationIgnored private var lookSaves: [SeriesLookKey: Task<Void, any Error>] = [:]
    @ObservationIgnored private var savedEdits: [SeriesLookKey: SeriesLookV1] = [:]
    /// The latest font pick per series look or design it edits (`setFont(_:for:)`).
    @ObservationIgnored private var fontPicks: [String: UUID] = [:]
    /// Whether the app reads a local preview folder instead of iCloud.
    let isPreview: Bool
    /// Whether the app shows the bundled example profile (`showExample(from:)`), a read-only
    /// library that lives in memory only: no reload, save, cache write, or generation run touches
    /// it, and any change to the Hardcover account ends it.
    private(set) var isExample = false
    /// Schedules a background generation run for a library that may hold new books, which
    /// `leaveExample()` and an account's library change call
    /// (`GenerationController.workChanged()`), or nothing in a preview model, which runs no
    /// generation. Tests set their own.
    @ObservationIgnored var schedulesGeneration: () -> Void = {}
    /// The Desk's and Library's sort and time choices in the example profile, which stay in
    /// memory so leaving the example restores the saved ones (`choice(_:saved:)`). Showing the
    /// example clears them.
    var exampleChoices = ExampleChoices()
    /// The bundled example profile, a `LocalSpineStore` folder that
    /// `script/export-example-profile.py` writes, or `nil` in builds without it.
    static let exampleFolder: URL? = {
        guard let folder = Bundle.main.url(forResource: "ExampleProfile", withExtension: nil),
            FileManager.default.fileExists(atPath: folder.appending(path: "library-v1.json").path)
        else { return nil }
        return folder
    }()

    @ObservationIgnored private let cacheURL = URL.cachesDirectory.appending(
        path: "Bookworms/library-snapshot.json")
    /// When a load last returned a result; a failed load does not count.
    @ObservationIgnored private var lastReload: Date?
    /// Whether the shown library is a load's result from this session, with the saves made since.
    /// The launch cache and the library a failed load leaves on screen may be out of date, such as
    /// missing a look another device saved, so the catch-up (`createMissingLooks()`) skips them.
    @ObservationIgnored private var showsLoadedLibrary = false
    /// Set when a saved design names a book or account the shown library lacks, or a load failed,
    /// so the next `reloadIfStale()` loads again.
    @ObservationIgnored private var needsReload = false
    /// Set when the reader answers an iCloud question while a reload runs. That reload read
    /// iCloud before the answer, so another reload follows it.
    @ObservationIgnored private var answeredDuringLoad = false
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
    /// The reader's design and look edits whose saves are still running, by book and by look
    /// group. A reload that starts before such a save lands can fetch the record the edit
    /// replaces, so its result keeps the edit; an edit whose save lands during the load joins
    /// `appliedDuringLoad` or `looksAppliedDuringLoad`.
    @ObservationIgnored private var designEditsSaving: [Int: SpineDesignV1] = [:]
    @ObservationIgnored private var lookEditsSaving: [SeriesLookKey: SeriesLookV1] = [:]
    /// Where the Top Five pins live on this device (`TopFivePins.key`) with the pins as iCloud
    /// last confirmed them (`TopFivePins.syncedKey`): the app's user defaults, which the views'
    /// `@AppStorage` reads, or a test's suite.
    @ObservationIgnored private let pinDefaults: UserDefaults
    /// Whether the pins sync with the store: not in a preview launch, whose folder must not take
    /// the app's real pins, unless a test passes defaults of its own.
    @ObservationIgnored private let syncsPins: Bool
    /// The latest Top Five sync or prune, which the next one waits for (`syncTopFivePins()`).
    @ObservationIgnored private var pinSync: Task<Void, Never>?
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
    /// uses `shared`; tests make their own model with a preview folder, and can pass a `store`
    /// that reads the folder in place of `LocalSpineStore`, `fonts` that download from a folder
    /// of their own, and `pinDefaults` that keep the Top Five pins apart from the app's.
    init(
        previewFolder: URL?, store: (any SpineStore)? = nil, fonts: SpineFonts = SpineFonts(),
        pinDefaults: UserDefaults? = nil
    ) {
        self.fonts = fonts
        self.pinDefaults = pinDefaults ?? .standard
        syncsPins = pinDefaults != nil || previewFolder == nil
        if let folder = previewFolder {
            self.store = store ?? LocalSpineStore(folder: folder)
            isPreview = true
        } else {
            self.store = CloudSpineStore()
            isPreview = false
            schedulesGeneration = {
                Task { await GenerationController.shared.workChanged() }
            }
            account.cloud = self.store
            // The cache holds the last library a load showed: the signed-in account's, or the
            // library a device without a sign-in last cleared or chose, because a sign-in, a
            // sign-out, and a choice of another library clear it. It stays on screen while the
            // account check can't run, such as offline, since a failed load keeps it.
            if let data = try? Data(contentsOf: cacheURL),
                let cached = try? JSONDecoder().decode(LibrarySnapshot.self, from: data),
                cached.accountID == HardcoverAccount.signedInAccountID ?? cached.accountID
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

    /// Opens the Share tab with `book` as the featured book, cross-fading the window into the tab
    /// (`crossfadeWindow(_:)`).
    func share(_ book: CloudBook) {
        crossfadeWindow {
            shareBookID = book.id
            selectedTab = .share
        }
    }

    /// The date that time filters, such as Library's **Last 12 Months**, treat as now: in the
    /// example profile, its sync date, so the snapshot never empties as it ages.
    var now: Date { isExample ? library?.syncedAt ?? .now : .now }

    /// Shows the example profile from `folder` on the Library tab, when the device has no
    /// library and no Hardcover sign-in. A folder that is missing or can't be read leaves the
    /// library empty and shows a toast.
    ///
    /// `isExample` and `isLoading` are set before the read, so a reload that an activation starts
    /// meanwhile returns at once instead of replacing the example. An account change during the
    /// read ends the example and reloads once the read ends, since its own reload returned early.
    func showExample(from folder: URL? = AppModel.exampleFolder) async {
        guard !isLoading, !isExample, !account.isSignedIn, library == nil else { return }
        let revision = account.libraryRevision
        let tab = selectedTab
        isExample = true
        exampleChoices = ExampleChoices()
        // The example has no Spines tab, so the tab view needs another to show.
        selectedTab = .library
        isLoading = true
        var loaded: LibrarySnapshot?
        if let folder { loaded = try? await LocalSpineStore(folder: folder).loadLibrary() }
        isLoading = false
        guard isExample, library == nil, revision == account.libraryRevision else {
            leaveExample()
            await reload()
            return
        }
        guard let snapshot = loaded else {
            isExample = false
            selectedTab = tab
            toasts.show(.failure("Couldn't open the example profile"))
            return
        }
        setLibrary(snapshot)
        await fonts.load(Array(allowedDesigns.values) + Array(lookDesigns.values))
    }

    /// Ends the example profile and returns to the empty library. Generation skips the runs due
    /// while the example shows, and a skipped Mac idle run or iPhone charging task schedules no
    /// next one, so leaving schedules it again.
    func leaveExample() {
        guard isExample else { return }
        isExample = false
        clearLibrary()
        schedulesGeneration()
    }

    func look(for book: CloudBook) -> SpineLook {
        let design = design(for: book)
        return SpineLook(book: book, design: design, face: fonts.face(for: design))
    }

    /// The design `book` draws with: its series look, or its series source's design when it
    /// shares one (see `SeriesDesigns`), otherwise its own, in an allowed upright face
    /// (`SpineDesignV1.withAllowedFont`).
    func design(for book: CloudBook) -> SpineDesignV1? {
        if let look = lookDesigns[book.id] { return look }
        let id = seriesSources[book.id] ?? book.id
        guard let design = allowedDesigns[id] else { return nil }
        return systemTypefaceSources.contains(id) ? design.inSystemTypeface : design
    }

    /// The text a font must letter to draw `book`'s spine
    /// (`SeriesDesigns.lettering(of:uppercase:)`): that of every book that shares its design, so
    /// a series keeps one font.
    func sharedLettering(of book: CloudBook, uppercase: Bool) -> String {
        let mates = seriesMates[book.id]?.compactMap { self.book(id: $0) } ?? [book]
        return mates.map { SeriesDesigns.lettering(of: $0, uppercase: uppercase) }
            .joined(separator: " ")
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

    /// The library's book with `id`, or `nil` when the library lacks it.
    func book(id: Int) -> CloudBook? { booksByID[id] }

    /// The book whose design and cover set `book`'s spine: its series source, or `book` itself.
    func designSource(for book: CloudBook) -> CloudBook {
        guard let id = seriesSources[book.id], id != book.id else { return book }
        return self.book(id: id) ?? book
    }

    /// Whether `book` shares its spine design with other books in its series, so changing the
    /// design changes theirs too.
    func sharesSeriesDesign(_ book: CloudBook) -> Bool { seriesSources[book.id] != nil }

    /// Whether the details' **Spine design** card lets the reader choose whether edits to `book`
    /// change its series' look or only the book (`SeriesLinkV1.ownLook`): its look group has a
    /// saved look or another library book, counting books that keep their own look.
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

    /// The colors that the **Spine design** card's resets restore on the spine `book` draws, or
    /// `nil` when unknown: the generator's colors of its design (`SpineDesignV1.generatedColors`).
    /// For a series look, those of the look's source design while it is the design the look was
    /// made from: made no later than the look was made or last remade (`SeriesLookV1.remadeAt`),
    /// by the look's generator, at its weight and case, and, unless the reader chose the look's
    /// font, in its font. A source redesigned on its own afterward has unrelated colors, even once
    /// the reader edits the look.
    func generatedColors(for book: CloudBook) -> SpineColors? {
        guard let look = drawnLook(of: book) else {
            return design(for: book).flatMap { $0.generatedColors ?? $0.colors }
        }
        guard let source = library?.designs[look.sourceBookID],
            source.generatorVersion == look.origin,
            source.generatedAt <= look.remadeAt ?? look.createdAt,
            source.weight == look.weight, source.uppercase == look.uppercase,
            look.hasReaderFont || source.fontPostScriptName == look.fontPostScriptName
        else { return nil }
        return source.generatedColors ?? source.colors
    }

    /// The families the font picker lists first for the spine `book` draws: those its design
    /// tried, best match first (`SpineChoice.candidates`), after the family it shows when that
    /// isn't one of them. A series look lists its source design's families. Families that the
    /// picker hides (`listsInPicker(_:)`) stay out, except the one the spine shows.
    func fontChoices(for book: CloudBook) -> [String] {
        let source =
            drawnLook(of: book).flatMap { library?.designs[$0.sourceBookID] }
            ?? savedDesign(for: book)
        let shown = design(for: book)?.fontFamily
        var families = (source?.choice?.candidates ?? [])
            .filter {
                $0 == shown || Self.listsInPicker($0)
            }
        if let shown, !families.contains(shown) {
            families.insert(shown, at: 0)
        }
        return families
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
    /// First checks the Hardcover accounts in iCloud (`checkICloudAccounts()`), so iCloud is
    /// used only for this device's account or the reader's choice. When signed in to Hardcover,
    /// then brings the account's library up to date from iCloud or Hardcover
    /// (`HardcoverAccount.syncIfStale()`); a failed download keeps the copy on this device and
    /// is reported.
    /// No library (an iCloud account without a saved library, or a sign-in without a
    /// downloaded copy) clears the shown and cached library, and so do a missing iCloud
    /// account, iCloud storage turned off, and an unchosen library when signed out, so another
    /// account's reading history never stays visible.
    /// Other errors keep the shown library and report the error. When signed in without that
    /// account's library on screen, such an error shows the downloaded Hardcover library without
    /// designs until the next reload, and does not cache it. The example profile never reloads.
    func reload() async {
        guard !isLoading, !isExample else { return }
        isLoading = true
        answeredDuringLoad = false
        appliedDuringLoad = []
        coversChosenDuringLoad = []
        linksChosenDuringLoad = []
        looksAppliedDuringLoad = []
        let persistedBefore = persistedLooks
        if !isPreview {
            await checkICloudAccounts()
            await account.syncIfStale()
        }
        let revision = account.libraryRevision
        do {
            let loaded = try await store.loadLibrary()
            // A sign-in, sync, or sign-out during the load replaces this result below.
            if revision == account.libraryRevision {
                if var snapshot = loaded {
                    // Until the reader answers the iCloud prompt, the load reads nothing from
                    // iCloud, so this account's designs and choices come from the library shown,
                    // which only this account's loads filled.
                    if snapshot.iCloudIssue == .otherAccountInICloud, let shown = library,
                        shown.accountID == snapshot.accountID
                    {
                        snapshot.keepChoices(of: shown)
                    }
                    // A look saved during the load can be newer than the fetched one, and the
                    // next edit of its group saves over it.
                    let savedDuringLoad = persistedLooks.filter {
                        persistedBefore[$0.key] != $0.value
                            && $0.value.accountID == snapshot.accountID
                    }
                    persistedLooks = snapshot.looks.merging(savedDuringLoad) { $1 }
                    // The newest design wins, and of designs made at the same time, the last one
                    // applied: a recoloring keeps its design's `generatedAt`. Edits still saving
                    // count as applied last.
                    snapshot.designs = LibrarySnapshot.latestDesigns(
                        (appliedDuringLoad + designEditsSaving.values).reversed()
                            + Array(snapshot.designs.values),
                        accountID: snapshot.accountID, books: snapshot.books)
                    for chosen in coversChosenDuringLoad
                    where chosen.accountID == snapshot.accountID {
                        snapshot.setChosenCover(chosen.url, bookID: chosen.bookID)
                    }
                    for chosen in linksChosenDuringLoad
                    where chosen.accountID == snapshot.accountID {
                        snapshot.setSeriesLink(chosen.link, bookID: chosen.bookID)
                    }
                    for look in looksAppliedDuringLoad + lookEditsSaving.values
                    where look.accountID == snapshot.accountID {
                        snapshot.looks[look.key] = look
                    }
                    // A design saved during the load for a book the result lacks needs another
                    // reload to show.
                    needsReload = appliedDuringLoad.contains { snapshot.designs[$0.bookID] == nil }
                    setLibrary(snapshot)
                    // A library without iCloud's records seeds no look.
                    showsLoadedLibrary = snapshot.iCloudIssue == nil
                    persist()
                } else {
                    clearLibrary()
                    needsReload = false
                }
                lastReload = .now
                loadError = nil
                iCloudIssue = loaded?.iCloudIssue?.errorDescription
            }
        } catch let error as CompanionError
            where [.noICloudAccount, .iCloudRestricted, .iCloudOff, .libraryChoiceNeeded]
            .contains(error)
        {
            clearLibrary()
            // Signing in can't lift a restriction, so only a missing account asks for it.
            loadError =
                error == .noICloudAccount
                ? "Sign in to iCloud with the account your other Apple devices use."
                : error.localizedDescription
            iCloudIssue = nil
            lastReload = .now
            needsReload = false
        } catch {
            // The account check passed, so iCloud is signed in; the load failed for another
            // reason, such as the network.
            iCloudIssue = nil
            loadError = SpineWorker.iCloudMessage(for: error) ?? error.localizedDescription
            showsLoadedLibrary = false
            needsReload = true
            if !isPreview, revision == account.libraryRevision,
                let accountID = account.summary?.accountID, library?.accountID != accountID,
                let phone = await HardcoverAccount.cachedLibrary(at: PhoneLibrary.url),
                phone.accountID == accountID, revision == account.libraryRevision
            {
                setLibrary(
                    LibrarySnapshot(
                        accountID: phone.accountID, syncedAt: phone.syncedAt, books: phone.books,
                        designs: [:], series: phone.series))
            }
        }
        isLoading = false
        // The change's own reload, or an iCloud answer's, returned early because this one was
        // running.
        if revision != account.libraryRevision || answeredDuringLoad { return await reload() }
        // Social data refreshes on its own, so its downloads never hold up the next reload.
        Task { await syncSocial() }
        // The catch-up's serial saves and the font downloads run side by side, so neither waits
        // for the other; `apply(_:)` loads the faces of the looks the catch-up saves.
        async let catchUp: Void = createMissingLooks()
        async let pins: Void = syncTopFivePins()
        // Fonts load after `isLoading` clears, so a slow download never blocks the next reload.
        await fonts.load(Array(allowedDesigns.values) + Array(lookDesigns.values))
        await catchUp
        await pins
    }

    /// Brings this device's Top Five pins and the shown account's `TopFivePinsV1` record
    /// together. Called after each reload and after each pin or unpin.
    ///
    /// When the pins changed since iCloud last confirmed them, or iCloud never confirmed any, the
    /// change is saved over the record, so a pin another device saved meanwhile stays
    /// (`SpineStore.save(_:replacing:)`); otherwise the record's pins replace this device's. A
    /// missing or unreadable record while confirmed pins exist, such as after a switch of iCloud
    /// account or CloudKit environment, gets this device's pins again rather than clearing them.
    /// A sync waits for the one before it, so its result never overwrites a newer pin. A pin
    /// changed during a sync is applied over the record's pins and saved by the next sync, which
    /// its change asks for. A failed sync changes nothing, and the next one tries again. Showing
    /// another account's library drops the pins it finds, confirmed or not
    /// (`claimTopFivePins(for:)`), so one account's pins never reach another's record.
    func syncTopFivePins() async {
        await afterPinWork { await self.runTopFiveSync() }.value
    }

    /// Unpins on this device the books Top Five can't draw from the library, so the pin count
    /// matches the image and a book without a finish date, which has no **Unpin** button, can't
    /// hold a place. The confirmed pins lose them too, so no sync saves this as an unpin and
    /// another device keeps them; the next sync shows any the record still holds. Runs between
    /// syncs, so a sync never mistakes it for a pin changed while it ran, and reads the library
    /// when it runs, so a pin on a book a reload just added stays. A library without finished
    /// books, such as one still arriving, gives no reason to hide any.
    @discardableResult
    func hideUndrawableTopFivePins() -> Task<Void, Never> {
        afterPinWork {
            let finished = Set(self.books.filter(TimeFrame.lifetime.contains).map(\.id))
            guard self.holdsRealPins, !finished.isEmpty else { return }
            self.prunePins(keeping: finished)
        }
    }

    /// Whether the model may change the saved pins and sync them: not in a preview launch or the
    /// example profile, whose books aren't the reader's, or under `-TopFivePins`, which pins
    /// books for one launch.
    private var holdsRealPins: Bool {
        syncsPins && !isExample
            && pinDefaults.volatileDomain(forName: UserDefaults.argumentDomain)[TopFivePins.key]
                == nil
    }

    private func afterPinWork(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = pinSync
        let task = Task {
            await previous?.value
            await work()
        }
        pinSync = task
        return task
    }

    private func prunePins(keeping ids: Set<Int>) {
        var shown = TopFivePins(rawValue: pinDefaults.string(forKey: TopFivePins.key) ?? "")
        shown.keep(only: ids)
        if shown.rawValue != pinDefaults.string(forKey: TopFivePins.key) ?? "" {
            pinDefaults.set(shown.rawValue, forKey: TopFivePins.key)
        }
        guard var confirmed = confirmedPins(),
            confirmed.bookIDs.contains(where: { !ids.contains($0) })
        else { return }
        confirmed.bookIDs.removeAll { !ids.contains($0) }
        pinDefaults.set(try? JSONEncoder().encode(confirmed), forKey: TopFivePins.syncedKey)
    }

    /// Drops pins left from another account when the library changes account, before its pin
    /// controls show, so a pin made on this account stays its own however long an old sync runs.
    private func claimTopFivePins(for accountID: String) {
        guard holdsRealPins else { return }
        let owner = pinDefaults.string(forKey: TopFivePins.accountKey)
        guard owner != accountID else { return }
        pinDefaults.set(accountID, forKey: TopFivePins.accountKey)
        if owner != nil {
            pinDefaults.removeObject(forKey: TopFivePins.key)
            pinDefaults.removeObject(forKey: TopFivePins.syncedKey)
        }
    }

    private func confirmedPins() -> TopFivePinsV1? {
        pinDefaults.data(forKey: TopFivePins.syncedKey)
            .flatMap { try? JSONDecoder().decode(TopFivePinsV1.self, from: $0) }
    }

    private func runTopFiveSync() async {
        guard holdsRealPins, let accountID = library?.accountID else { return }
        let shown = TopFivePins(rawValue: pinDefaults.string(forKey: TopFivePins.key) ?? "")
        let confirmed = confirmedPins()
        // Pins never confirmed on this device are saved unless there are none.
        let readsSaved = confirmed.map { $0.bookIDs == shown.ids } ?? shown.ids.isEmpty
        let pins = { (ids: [Int]) in
            TopFivePinsV1(version: 1, accountID: accountID, bookIDs: ids, pinnedAt: .now)
        }
        let kept: TopFivePinsV1?
        do {
            let saved = readsSaved ? try await store.topFivePins(accountID: accountID) : nil
            if readsSaved, saved != nil || confirmed == nil {
                kept = saved
            } else {
                kept = try await store.save(
                    pins(shown.ids), replacing: readsSaved ? nil : confirmed)
            }
        } catch {
            return
        }
        guard library?.accountID == accountID else { return }
        if kept != confirmed {
            pinDefaults.set(
                kept.flatMap { try? JSONEncoder().encode($0) }, forKey: TopFivePins.syncedKey)
        }
        // A pin changed during the sync is applied over the kept pins, and the confirmed pins stay
        // the kept ones, so the next sync saves only that change.
        let current = TopFivePins(rawValue: pinDefaults.string(forKey: TopFivePins.key) ?? "")
        let synced = TopFivePins(
            ids: current == shown
                ? kept?.bookIDs ?? []
                : pins(current.ids).merged(over: kept ?? pins([]), changing: pins(shown.ids))
                    .bookIDs)
        if synced != current {
            pinDefaults.set(synced.rawValue, forKey: TopFivePins.key)
        }
    }

    /// Whether the Share tab can compare with other readers: signed in to Hardcover on this
    /// device outside preview mode, or showing Debug builds' fictional readers.
    var canCompare: Bool {
        #if DEBUG
            if SocialSamples.isEnabled { return true }
        #endif
        return canLookUpReaders
    }

    /// Whether this device can ask Hardcover about other readers.
    var canLookUpReaders: Bool { account.isSignedIn && !isPreview }

    /// Refreshes the readers the Share tab compares with when signed in to Hardcover on this
    /// device: when their data is a day old, or at once with `force`, such as a pull to
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
    /// with (`SocialModel.lookUp(_:token:)`). Needs this device's Hardcover sign-in.
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
    /// signed out, so another account's books never stay visible, and the friends and the image
    /// cache go with it. Signed out, the reload shows the iCloud archive, which can hold the
    /// library and reviews this device published; its covers download again. The
    /// library's books are new work, so a background generation run is scheduled for them
    /// without the day's wait that a run before the library arrived left.
    private func accountLibraryChanged() {
        // Any account change ends the example profile, including a sign-in to its owner's.
        // Leaving the example schedules the run itself.
        if isExample { leaveExample() } else { schedulesGeneration() }
        guard !isPreview else { return }
        if library?.accountID != account.summary?.accountID { clearLibrary() }
        // A sign-out or another account must not keep this account's friends, or the images
        // the cache holds for them, such as their profile photos.
        let accountID = account.summary?.accountID
        let forgetsFriends =
            accountID == nil || social.snapshot.map({ String($0.owner.id) != accountID }) == true
        if forgetsFriends { social.clear() }
        Task {
            // Before the reload, so the covers it shows download again and stay.
            if forgetsFriends { await covers.clear() }
            await reload()
        }
    }

    /// Runs the iCloud account check (`SpineStore.checkAccounts()`) and sets `accountPrompt`
    /// from its result. A failed check changes nothing: the prompt and the store's gate keep the
    /// last successful check's state, which is closed at launch.
    func checkICloudAccounts() async {
        guard let check = try? await store.checkAccounts() else { return }
        switch check {
        case .otherAccounts, .chooseLibrary: accountPrompt = check
        case .clear, .off: accountPrompt = nil
        }
    }

    /// The **Couldn't merge** alert's message for a failed copy or save.
    static let mergeFailedMessage = "Bookworms couldn't finish the merge. Try again later."

    /// Merges the other accounts into this one (`SpineStore.merge(_:into:)`) with this
    /// account's downloaded library, so no device asks again, and reloads. A failure sets
    /// `mergeError`, and the prompt returns at the next check.
    func mergeOtherAccounts() async {
        guard case .otherAccounts(let others)? = accountPrompt else { return }
        accountPrompt = nil
        do {
            guard let phone = await ownPhoneLibrary() else {
                throw CompanionError.libraryNotDownloaded
            }
            try await store.merge(others, into: phone)
        } catch CompanionError.libraryNotDownloaded {
            mergeError = CompanionError.libraryNotDownloaded.localizedDescription
        } catch {
            mergeError = Self.mergeFailedMessage
        }
        await reloadForAnswer()
    }

    #if DEBUG
        /// Shows one iCloud account prompt with fictional accounts for screenshots:
        /// `-BookwormsAccountPrompt <other|deletion|mergeFailed|choose>`. Pair it with
        /// `-BookwormsPreviewFolder`: other launches run the account check, which can replace
        /// `other` and `choose`.
        func showLaunchArgumentAccountPrompt() {
            let maple = CloudAccount(
                id: "-1", username: "maple_reader", bookIDs: [], syncedAt: .now)
            let birch = CloudAccount(
                id: "-2", username: "birch_pages", bookIDs: [], syncedAt: .now)
            switch UserDefaults.standard.string(forKey: "BookwormsAccountPrompt") {
            case "other": accountPrompt = .otherAccounts([maple])
            case "choose": accountPrompt = .chooseLibrary([maple, birch])
            case "deletion": showsICloudDeletion = true
            case "mergeFailed": mergeError = Self.mergeFailedMessage
            default: break
            }
        }
    #endif

    /// Turns iCloud storage off on this device, shows how to delete Bookworms data from iCloud,
    /// and reloads without iCloud.
    func keepICloudOff() async {
        CloudStorage.setOff(true)
        iCloudIsOff = CloudStorage.isOff()
        accountPrompt = nil
        showsICloudDeletion = true
        await reloadForAnswer()
    }

    /// Turns iCloud storage on again and reloads, which checks the iCloud accounts again. Then
    /// publishes this account's library when iCloud has none, since downloads while storage was
    /// off didn't upload it.
    func turnOnICloudStorage() async {
        CloudStorage.setOff(false)
        iCloudIsOff = CloudStorage.isOff()
        await reloadForAnswer()
        guard let phone = await ownPhoneLibrary() else { return }
        do { try await store.publishIfMissing(phone) } catch {
            HardcoverAccount.logDropped("Couldn't publish the library to iCloud", error)
        }
    }

    /// Remembers `library` as the iCloud library to show without a sign-in, and reloads. A
    /// library of another account on screen clears first, so it never shows past the choice.
    func chooseLibrary(_ library: CloudAccount) async {
        CloudStorage.choose(library.id)
        accountPrompt = nil
        if self.library?.accountID != library.id { clearLibrary() }
        await reloadForAnswer()
    }

    /// Reloads after the reader answers an iCloud question. A reload already running read iCloud
    /// before the answer, so it reloads again when it ends.
    private func reloadForAnswer() async {
        answeredDuringLoad = true
        await reload()
    }

    /// This device's downloaded library of the signed-in account, or `nil` before the first
    /// download.
    private func ownPhoneLibrary() async -> PhoneLibrary? {
        guard let accountID = account.summary?.accountID,
            let phone = await HardcoverAccount.cachedLibrary(at: PhoneLibrary.url),
            phone.accountID == accountID
        else { return nil }
        return phone
    }

    /// Reloads when the last load that returned a result is more than five minutes old, a later
    /// load failed, or a saved design named a book the library lacks. Called when the app
    /// becomes active and when a generation run ends. On an iPhone, first retries a read or save
    /// of the Hardcover login that the Keychain refused (`HardcoverAccount.retryKeychain()`).
    /// Then writes any cache update that `apply(_:)` deferred, so a run's designs reach the cache
    /// when it ends.
    func reloadIfStale() async {
        // On a Mac, a read can show a keychain prompt, which takes the app out of the
        // foreground, so a read on each activation could ask again as soon as the reader
        // declines. There, **Sync now** and the next launch read the login again.
        #if !os(macOS)
            account.retryKeychain()
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
        guard !isExample else { return }
        if isLoading { appliedDuringLoad.append(design) }
        guard var library, design.accountID == library.accountID,
            library.books.contains(where: { $0.id == design.bookID })
        else {
            // The account changed during the run, or the Apple TV changed the library since it
            // loaded; the next reload shows it.
            needsReload = true
            return
        }
        library.designs[design.bookID] = design
        setLibrary(library)
        persistSoon()
        Task { await fonts.load([design.withAllowedFont]) }
    }

    /// Shows series looks that the generator, the catch-up after a reload, or `recolor(_:to:)`
    /// saves, without a reload. Like `apply(_:)` for designs, it defers the cache write. An edit
    /// shows its look before saving it (`persisted` false).
    func apply(_ looks: [SeriesLookV1], persisted: Bool = true) {
        guard !isExample else { return }
        if isLoading { looksAppliedDuringLoad += looks }
        if persisted { for look in looks { persistedLooks[look.key] = look } }
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
        // The example is read-only; its views offer no edits.
        guard !isExample else { return }
        do {
            if let look = drawnLook(of: book) {
                let recolored = look.recolored(colors, at: .now)
                try recolored.validate()
                apply([recolored], persisted: false)
                try await saveEdited(recolored, over: look)
                return
            }
            guard let design = savedDesign(for: book) else {
                throw CompanionError.bookNotInLibrary
            }
            let recolored = design.recolored(colors)
            try recolored.validate()
            apply(recolored)
            try await saveEdit(recolored) { try await store.saveRecolored(recolored) }
        } catch CompanionError.designChanged {
            await reload()
            throw CompanionError.designChanged
        }
    }

    /// Shows `family` on the spine `book` draws and saves it as the reader's font, keeping the
    /// colors (see `SpineDesignV1.refonted(family:postScriptName:instanceWeight:typeface:)`),
    /// through the store the library comes from. As with `recolor(_:to:)`, a book that draws its
    /// series' look changes the look, and a book that shares its series source's design changes
    /// that design; either changes every book that draws it. Generation runs keep the font
    /// (`SpineDesignV1.hasReaderEdits`).
    ///
    /// First downloads the family's instance nearest the design's weight, so the record names the
    /// face every app draws, and finds the family's system stand-in
    /// (`SpineFontStyle.fallbackTypeface`). Throws as `GoogleFonts.download(family:weight:)` does
    /// when the family can't download, before showing anything; throws
    /// `CompanionError.invalidDesign` for a family the reader can't pick (`pickableFamilies()`)
    /// or one without glyphs for the lettering of every book that shares the design
    /// (`sharedLettering(of:uppercase:)`), and `CompanionError.bookNotInLibrary`
    /// when the book has no design. A later pick for the same look or design replaces one still
    /// downloading, which then changes nothing. A failed save leaves the
    /// font on screen until the next reload. When iCloud holds another design or look, such as a
    /// redesign from another device, reloads to show it and throws
    /// `CompanionError.designChanged`.
    func setFont(_ family: String, for book: CloudBook) async throws {
        guard !isExample else { return }
        guard let weight = drawnLook(of: book)?.weight ?? savedDesign(for: book)?.weight else {
            throw CompanionError.bookNotInLibrary
        }
        guard await Self.pickableFamilies().contains(family) else {
            throw CompanionError.invalidDesign
        }
        // Books that draw one look or share one design edit it together, so a pick supersedes
        // any earlier pick of the same look or design that is still downloading.
        let target =
            drawnLook(of: book).map { "look \($0.key.seriesID) \($0.key.group)" }
            ?? savedDesign(for: book).map { "design \($0.bookID)" } ?? "book \(book.id)"
        let pick = UUID()
        fontPicks[target] = pick
        let font = try await fonts.downloader.download(family: family, weight: weight)
        let typeface = await Self.fallbackTypeface(of: family)
        guard fontPicks[target] == pick else { return }
        let uppercase = drawnLook(of: book)?.uppercase ?? savedDesign(for: book)?.uppercase
        guard font.covers(sharedLettering(of: book, uppercase: uppercase ?? false)) else {
            throw CompanionError.invalidDesign
        }
        do {
            // Read after the download, so the edit starts from the library as it is now.
            if let look = drawnLook(of: book) {
                let refonted = look.refonted(
                    family: family, postScriptName: font.postScriptName,
                    instanceWeight: font.weight, typeface: typeface, at: .now)
                try refonted.validate()
                apply([refonted], persisted: false)
                try await saveEdited(refonted, over: look)
                return
            }
            guard let design = savedDesign(for: book) else {
                throw CompanionError.bookNotInLibrary
            }
            let refonted = design.refonted(
                family: family, postScriptName: font.postScriptName, instanceWeight: font.weight,
                typeface: typeface)
            try refonted.validate()
            apply(refonted)
            try await saveEdit(refonted) { try await store.saveRefonted(refonted) }
        } catch CompanionError.designChanged {
            await reload()
            throw CompanionError.designChanged
        }
    }

    /// Saves `edited`, the reader's edit of `look`, after any earlier edit of the group saves,
    /// over the look as iCloud last confirmed it, so overlapping edits each start from the look
    /// the previous one left and a failed one leaves the next one its base. Throws
    /// `CompanionError.designChanged` when another look, such as a redesign, replaced that base
    /// while the edit waited, so the edit never undoes it.
    private func saveEdited(_ edited: SeriesLookV1, over look: SeriesLookV1) async throws {
        let key = edited.key
        let base = persistedLooks[key] ?? look
        let previous = lookSaves[key]
        lookEditsSaving[key] = edited
        defer { if lookEditsSaving[key] == edited { lookEditsSaving[key] = nil } }
        let save = Task {
            _ = await previous?.result
            let current = persistedLooks[key] ?? look
            guard current == base || current == savedEdits[key] else {
                throw CompanionError.designChanged
            }
            try await store.saveEdited(edited, replacing: current)
            persistedLooks[key] = edited
            savedEdits[key] = edited
            if isLoading { looksAppliedDuringLoad.append(edited) }
        }
        lookSaves[edited.key] = save
        try await save.value
    }

    /// Saves `edit`, the reader's edit of a design that `apply(_:)` shows, with `save`, so that
    /// a reload that starts before the save lands still shows the edit (`designEditsSaving`).
    private func saveEdit(_ edit: SpineDesignV1, with save: () async throws -> Void) async throws {
        let id = edit.bookID
        designEditsSaving[id] = edit
        defer { if designEditsSaving[id] == edit { designEditsSaving[id] = nil } }
        try await save()
        if isLoading { appliedDuringLoad.append(edit) }
    }

    /// The families a reader may pick: the font atlas's, which passed its lean, hairline, and
    /// legibility filter, minus those new designs never use, so no pick draws a slanted spine.
    /// Off the main actor, because the first read decompresses the atlas.
    @concurrent nonisolated static func pickableFamilies() async -> Set<String> {
        let never = Set(SpineFamily.neverGenerated.map(\.rawValue))
        return Set((FontAtlas.shared?.fonts ?? []).map(\.family))
            .filter { !never.contains($0) && BookAnalyzer.allowsFamily($0) }
    }

    /// Whether the font picker lists `family`. It hides Google's Noto families made for other
    /// writing systems or number sets, such as "Noto Sans Old Hungarian", "Noto Sans Mayan
    /// Numerals", or "Noto Serif Tangut": every Noto family except Noto Sans and Noto Serif
    /// with no qualifier but Mono, Display, or a width or weight word, such as "Noto Sans Mono"
    /// or "Noto Serif Display". Designs may still use any family (`pickableFamilies()`), and the
    /// picker still shows a spine's hidden family as its current one.
    nonisolated static func listsInPicker(_ family: String) -> Bool {
        let words = family.split(separator: " ")
        guard words.first == "Noto" else { return true }
        guard words.count > 1, words[1] == "Sans" || words[1] == "Serif" else { return false }
        return words.dropFirst(2).allSatisfy(latinNotoQualifiers.contains)
    }

    /// The words after "Noto Sans" or "Noto Serif" that keep a Latin-script Noto family in the
    /// font picker (`listsInPicker(_:)`).
    private nonisolated static let latinNotoQualifiers: Set<Substring> = [
        "Mono", "Display", "UltraCondensed", "ExtraCondensed", "Condensed", "SemiCondensed",
        "SemiExpanded", "Expanded", "ExtraExpanded", "UltraExpanded", "Thin", "ExtraLight",
        "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black",
    ]

    /// The system typeface that stands in for `family` (`BookAnalyzer.style(of:tags:)`). Off the
    /// main actor, because the first lookup decodes `SpineFontTags.json`.
    @concurrent nonisolated private static func fallbackTypeface(of family: String) async
        -> String
    {
        BookAnalyzer.style(of: family).fallbackTypeface
    }

    /// Returns the covers of `book`'s Hardcover editions for the cover picker. Needs this
    /// device's Hardcover sign-in.
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
        guard !isExample else { return }
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
    /// reload. `linkedSeriesID` names the series whose look the book draws; the book's shortest
    /// series is its default, so naming it links no series, as the **Series** sheet and the Apple
    /// TV save it. `standsAlone` takes the book out of every series, and `ownLook` keeps its own
    /// design instead of its series' look.
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
        guard !isExample else { return }
        guard let shown = library, shown.books.contains(where: { $0.id == book.id }) else {
            throw CompanionError.bookNotInLibrary
        }
        let accountID = shown.accountID
        let standard = SeriesDesigns.styleSeries(of: book, link: nil)?.id
        let chosen = SeriesLinkV1(
            version: 1, accountID: accountID, bookID: book.id,
            linkedSeriesID: linkedSeriesID == standard ? nil : linkedSeriesID,
            standsAlone: standsAlone, ownLook: ownLook, chosenAt: .now)
        // Only the choices that differ from the shown link replace the saved ones, so a choice
        // another device saved meanwhile stays.
        let link = try await store.save(
            chosen, replacing: shown.books.first { $0.id == book.id }?.seriesLink)
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
        persistedLooks = [:]
        savedEdits = [:]
        library = nil
        designRevision += 1
        showsLoadedLibrary = false
        lookGroups = [:]
        allowedDesigns = [:]
        books = []
        booksByID = [:]
        social.prepare(mine: [])
        alignSeries()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func setLibrary(_ snapshot: LibrarySnapshot) {
        let previousBooks = library?.books
        let previousDesigns = library?.designs
        library = snapshot
        claimTopFivePins(for: snapshot.accountID)
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
        booksByID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        social.prepare(mine: books)
    }

    /// Recomputes `seriesSources`, `lookDesigns`, `systemTypefaceSources`, and `seriesMates`
    /// from the library and the loaded faces.
    ///
    /// The books of a look group with a saved look draw it; the books of other groups draw by
    /// rank (`SeriesDesigns.sources`). Books that draw one design letter it in its face only when
    /// the loaded face has glyphs for every one of them, uppercased when the design is uppercase;
    /// otherwise they all letter it in its system typeface. Until a face loads, the check
    /// passes. Edits to a book that draws a look, such as **Change cover** and **Redesign
    /// spine**, act on the look's source book while it draws the look too, else on the book
    /// itself. A book that alone draws its group's look shares it with no one, so it has no
    /// series source.
    private func alignSeries() {
        var sources: [Int: Int] = [:]
        var drawn: [Int: SpineDesignV1] = [:]
        var systemTypeface: Set<Int> = []
        var mates: [Int: [Int]] = [:]
        if let library {
            var unlooked: [[CloudBook]] = []
            for (key, members) in lookGroups {
                guard let look = library.looks[key] else {
                    unlooked.append(members)
                    continue
                }
                var designs = members.map {
                    look.design(bookID: $0.id, hashesFrom: library.designs[$0.id])
                }
                if !zip(members, designs).allSatisfy({ canLetter($0, with: $1) }) {
                    designs = designs.map(\.inSystemTypeface)
                }
                let ids = members.map(\.id)
                for (id, design) in zip(ids, designs) {
                    drawn[id] = design
                    mates[id] = ids
                }
                guard members.count > 1 else { continue }
                let source = ids.contains(look.sourceBookID) ? look.sourceBookID : nil
                for id in ids { sources[id] = source ?? id }
            }
            let ranked = SeriesDesigns.sources(ranked: unlooked, designs: library.designs)
            var drawers: [Int: [CloudBook]] = [:]
            for book in unlooked.joined() {
                if let source = ranked[book.id] { drawers[source, default: []].append(book) }
            }
            for (source, books) in drawers {
                if let design = allowedDesigns[source],
                    !books.allSatisfy({ canLetter($0, with: design) })
                {
                    systemTypeface.insert(source)
                }
                let ids = books.map(\.id)
                for id in ids { mates[id] = ids }
            }
            sources.merge(ranked) { $1 }
        }
        let changed =
            sources != seriesSources || drawn != lookDesigns
            || systemTypeface != systemTypefaceSources
        if sources != seriesSources { seriesSources = sources }
        if drawn != lookDesigns { lookDesigns = drawn }
        if systemTypeface != systemTypefaceSources { systemTypefaceSources = systemTypeface }
        if mates != seriesMates { seriesMates = mates }
        if changed { designRevision += 1 }
        // The snapshot's books, since `books` is sorted after this runs.
        let designed = library?.books.count { design(for: $0) != nil } ?? 0
        if designed != designedBookCount { designedBookCount = designed }
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
        guard !isPreview, !isExample, let library, let data = try? JSONEncoder().encode(library)
        else {
            return
        }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// The example profile's own sort and time choices; `nil` shows the saved choice.
struct ExampleChoices {
    var sort: ShelfSort?
    var libraryTime: LibraryTime?
    /// The scenes' time frame, as `TimeFrame.setting` writes it.
    var frameSetting: String?
}

extension LibrarySnapshot {
    /// Takes the designs, series looks, cover choices, and series links of `shown`, a library of
    /// the same account, for the books this one has.
    fileprivate mutating func keepChoices(of shown: LibrarySnapshot) {
        designs = Self.latestDesigns(shown.designs.values, accountID: accountID, books: books)
        looks = shown.looks
        for book in shown.books {
            setChosenCover(book.chosenCoverURL, bookID: book.id)
            setSeriesLink(book.seriesLink, bookID: book.id)
        }
    }

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
