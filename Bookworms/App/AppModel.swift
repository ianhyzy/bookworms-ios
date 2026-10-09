import Foundation
import Observation

/// The library the app shows: the active Hardcover account's books and their saved designs.
///
/// Reads iCloud through `CloudSpineStore`. Launching with `-BookwormsPreviewFolder <path>` reads
/// a local folder instead (see `script/load-preview-data.py`); a relative path resolves inside
/// the app's `Caches/Bookworms` folder. The last iCloud library is cached so launch shows it immediately.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var library: LibrarySnapshot?
    /// The library's books, most recently finished first, then unfinished books by title.
    private(set) var books: [CloudBook] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    let fonts = SpineFonts()
    @ObservationIgnored let covers = CoverStore()
    @ObservationIgnored let store: any SpineStore
    /// Whether the app reads a local preview folder instead of iCloud.
    let isPreview: Bool

    @ObservationIgnored private let cacheURL = URL.cachesDirectory.appending(
        path: "Bookworms/library-snapshot.json")

    init(store: (any SpineStore)? = nil) {
        if let store {
            self.store = store
            isPreview = true
        } else if let path = UserDefaults.standard.string(forKey: "BookwormsPreviewFolder") {
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
    }

    func look(for book: CloudBook) -> SpineLook {
        let design = library?.designs[book.id]
        return SpineLook(book: book, design: design, face: fonts.face(for: design))
    }

    /// Reloads the library and designs, then loads the fonts the designs name.
    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let snapshot = try await store.loadLibrary() {
                setLibrary(snapshot)
                persist()
            }
            loadError = nil
        } catch {
            loadError =
                (error as? LocalizedError)?.errorDescription ?? "Could not read the library."
        }
        if let designs = library?.designs.values { await fonts.load(Array(designs)) }
    }

    /// Shows a design the generator just saved, without a reload.
    func apply(_ design: SpineDesignV1) {
        guard var library, design.accountID == library.accountID,
            library.books.contains(where: { $0.id == design.bookID })
        else { return }
        library.designs[design.bookID] = design
        setLibrary(library)
        persist()
        Task { await fonts.load([design]) }
    }

    private func setLibrary(_ snapshot: LibrarySnapshot) {
        let previousBooks = library?.books
        library = snapshot
        guard previousBooks != snapshot.books else { return }
        books = snapshot.books.sorted { lhs, rhs in
            switch (lhs.finished, rhs.finished) {
            case let (left?, right?) where left != right: left > right
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
