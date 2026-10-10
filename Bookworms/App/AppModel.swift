import Foundation
import Observation

/// The library the app shows: the active Hardcover account's books and their saved designs.
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
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// The visible tab. Other features switch it, such as **Share** from a book's details.
    var selectedTab = AppTab.shelf
    /// A book that a share request named; the Share tab shows it, then clears this.
    var shareBookID: Int?
    let fonts = SpineFonts()
    /// This iPhone's own Hardcover sign-in and library.
    let account = HardcoverAccount()
    @ObservationIgnored let covers = CoverStore()
    @ObservationIgnored let store: any SpineStore
    /// Whether the app reads a local preview folder instead of iCloud.
    let isPreview: Bool

    @ObservationIgnored private let cacheURL = URL.cachesDirectory.appending(
        path: "Bookworms/library-snapshot.json")
    @ObservationIgnored private var lastReload: Date?
    /// Set when a saved design names a book or account the shown library lacks.
    @ObservationIgnored private var needsReload = false
    /// Designs saved while a reload's fetch runs, merged into its result so none are lost.
    @ObservationIgnored private var appliedDuringLoad: [SpineDesignV1] = []

    private init() {
        if let path = UserDefaults.standard.string(forKey: "BookwormsPreviewFolder") {
            let folder =
                path.hasPrefix("/")
                ? URL(filePath: path) : URL.cachesDirectory.appending(path: "Bookworms/\(path)")
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
    }

    /// Opens the Share tab with `book` as the featured book.
    func share(_ book: CloudBook) {
        shareBookID = book.id
        selectedTab = .share
    }

    func look(for book: CloudBook) -> SpineLook {
        let design = library?.designs[book.id]
        return SpineLook(book: book, design: design, face: fonts.face(for: design))
    }

    /// Reloads the library and designs, then loads the fonts the designs name.
    ///
    /// When signed in to Hardcover, first downloads the account's library if the copy on this
    /// iPhone is missing or a few hours old; a failed download keeps that copy and is reported.
    /// No library (an iCloud account without an Apple TV upload, or a sign-in without a
    /// downloaded copy) clears the shown and cached library, and so does a missing iCloud
    /// account when signed out, so another account's reading history never stays visible.
    /// Other errors keep the cached library and report the error.
    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        appliedDuringLoad = []
        if !isPreview { await account.syncIfStale() }
        let revision = account.libraryRevision
        do {
            let loaded = try await store.loadLibrary()
            // A sign-in, sync, or sign-out during the load replaces this result below.
            if revision == account.libraryRevision {
                if var snapshot = loaded {
                    snapshot.designs = LibrarySnapshot.latestDesigns(
                        Array(snapshot.designs.values) + appliedDuringLoad,
                        accountID: snapshot.accountID, books: snapshot.books)
                    setLibrary(snapshot)
                    persist()
                } else {
                    clearLibrary()
                }
                loadError = isPreview ? nil : account.syncError
            }
        } catch CompanionError.noICloudAccount, CompanionError.iCloudRestricted {
            clearLibrary()
            loadError = "Sign in to iCloud with the account your Apple TV uses."
        } catch {
            loadError =
                (error as? LocalizedError)?.errorDescription ?? "Could not read the library."
        }
        isLoading = false
        lastReload = .now
        needsReload = false
        // The change's own reload returned early because this one was running.
        if revision != account.libraryRevision { return await reload() }
        // Fonts load after `isLoading` clears, so a slow download never blocks the next reload.
        if let designs = library?.designs.values { await fonts.load(Array(designs)) }
    }

    /// Shows the new phone library after a Hardcover sign-in, sync, or sign-out. The shown
    /// library clears first when it belongs to another account or the reader signed out, so
    /// neither another account's books nor the signed-out account's reviews stay visible.
    private func accountLibraryChanged() {
        guard !isPreview else { return }
        if library?.accountID != account.summary?.accountID { clearLibrary() }
        Task { await reload() }
    }

    /// Reloads when the library is more than five minutes old or a saved design named a book
    /// it lacks. Called when the app becomes active and when a generation run ends.
    func reloadIfStale() async {
        guard needsReload || lastReload.map({ -$0.timeIntervalSinceNow > 300 }) ?? true else {
            return
        }
        await reload()
    }

    /// Shows a design the generator just saved, without a reload.
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
        persist()
        Task { await fonts.load([design]) }
    }

    private func clearLibrary() {
        library = nil
        books = []
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func setLibrary(_ snapshot: LibrarySnapshot) {
        let previousBooks = library?.books
        library = snapshot
        guard previousBooks != snapshot.books else { return }
        books = snapshot.books.sorted { lhs, rhs in
            switch (lhs.finished, rhs.finished) {
            case (let left?, let right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private func persist() {
        guard !isPreview, let library, let data = try? JSONEncoder().encode(library) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

enum AppTab: Hashable {
    case shelf, share, spines
}
