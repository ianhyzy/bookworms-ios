import CoreText
import Foundation

/// A Google Fonts instance on disk, chosen as the closest match to a requested weight.
struct DownloadedFont: Sendable {
    /// The instance's weight on the 100...900 scale, which can differ from the requested weight.
    let weight: Int
    let postScriptName: String
    let fileURL: URL

    /// Returns whether the instance has a glyph for every non-whitespace character in `text`, as
    /// the loaded face checks it (`FontFace.covers(_:)`).
    ///
    /// Callers pass the text as it will render, uppercased when the design uses uppercase.
    func covers(_ text: String) -> Bool {
        guard
            let descriptor = GoogleFonts.descriptors(at: fileURL)
                .first(where: { FontFiles.postScriptName(of: $0) == postScriptName })
        else { return false }
        return FontFace(descriptor: descriptor, postScriptName: postScriptName).covers(text)
    }
}

/// Downloads open-source Google Fonts families over HTTPS into the Caches folder.
///
/// The catalog is refetched when the cached copy is more than seven days old. Font files never
/// expire, but the system may evict Caches; a design keeps its family and weight, so the font is
/// downloaded again on next use. A change to the file rule (`SpineFamily.fileName(for:in:)`)
/// moves the cache to new keys, so every font downloads again. Requests send no credentials or
/// cookies. Views create fonts from the file's descriptors and do not register them with Core
/// Text.
actor GoogleFonts {
    /// Google Fonts rate limited or failed a request, with the `Retry-After` date when given.
    ///
    /// The outage affects every family, so callers retry later instead of trying another one. It
    /// is not a `CompanionError`, which callers such as `SpineFonts` treat as a lasting problem
    /// with one family.
    struct Unavailable: Error {
        let retryAfter: Date?
        /// The HTTP status, such as 429 for a rate limit or 503 for a server error.
        var status = 0
    }

    private let root: URL
    private let session: URLSession
    private var catalogCache: (families: [String: Int], fetchedAt: Date)?
    /// The catalog and font file downloads in progress, which concurrent designs share
    /// (`Task.sharedValue`).
    private var catalogFetch: Task<[String: Int], any Error>?
    private var fileFetches: [URL: Task<Void, any Error>] = [:]
    private let catalogLifetime: TimeInterval = 7 * 24 * 60 * 60
    private let maximumBytes = 30 * 1024 * 1024
    private let retryDelay: @Sendable (Int) -> Duration

    /// How many times a request that may pass on a later try is sent again (`retrying`).
    static let retries = 3

    /// The wait before retry `attempt`, counted from 1: about 1, 2, then 4 seconds, with up to a
    /// second of jitter so concurrent downloads don't retry together.
    static func backoff(_ attempt: Int) -> Duration {
        .seconds(Double(1 << (attempt - 1)) + .random(in: 0...1))
    }

    /// Creates a downloader that caches under `root`. Tests pass `configuration` to stand in for
    /// the network, and `retryDelay` to retry without waiting.
    init(
        root: URL = URL.cachesDirectory.appending(path: "Bookworms/fonts"),
        configuration: URLSessionConfiguration = .ephemeral,
        retryDelay: @escaping @Sendable (Int) -> Duration = GoogleFonts.backoff
    ) {
        self.root = root
        self.retryDelay = retryDelay
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 40
        session = URLSession(configuration: configuration)
    }

    /// Downloads `family` and returns the non-italic instance whose weight is closest to `weight`.
    ///
    /// Throws `CompanionError.invalidDesign` when the family is missing from the catalog, lacks an
    /// open-source license, or has no usable file, and `Unavailable` when Google Fonts rate limits
    /// or fails the request. Network failures throw `URLError`.
    func download(family: String, weight: Int) async throws -> DownloadedFont {
        guard try await catalog()[family] != nil else { throw CompanionError.invalidDesign }
        // The key names the file rule (`SpineFamily.fileName(for:in:)`), so a file that an
        // earlier rule chose, such as League Gothic's condensed width, downloads again.
        let directory = root.appending(path: CloudContract.digest("files-v2:\(family):\(weight)"))
        let file = directory.appending(path: "font.ttf")
        if !FileManager.default.fileExists(atPath: file.path) {
            let fetch =
                fileFetches[file]
                ?? Task {
                    defer { self.fileFetches[file] = nil }
                    try await self.fetchFile(
                        family: family, weight: weight, into: directory, file: file)
                }
            fileFetches[file] = fetch
            try await fetch.sharedValue
        }
        guard
            let instance = FontFiles.nearestUpright(in: Self.descriptors(at: file), weight: weight)
        else { throw CompanionError.invalidDesign }
        return DownloadedFont(
            weight: instance.weight, postScriptName: instance.postScriptName, fileURL: file)
    }

    static func descriptors(at url: URL) -> [CTFontDescriptor] {
        CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
    }

    /// Returns the first upright face named in `names`, else the first upright face, else `nil`.
    static func uprightDescriptor(
        preferring names: [String?], in descriptors: [CTFontDescriptor]
    ) -> CTFontDescriptor? {
        let upright = descriptors.filter(FontFiles.isUpright)
        let named = names.compactMap { $0 }.lazy
            .compactMap { name in upright.first { FontFiles.postScriptName(of: $0) == name } }
            .first
        return named ?? upright.first
    }

    /// Strips the anti-XSSI prefix line that Google prepends to its JSON responses.
    static func cleanJSON(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(")]}'"),
            let newline = text.firstIndex(of: "\n")
        else { return data }
        return Data(text[text.index(after: newline)...].utf8)
    }

    /// Returns the catalog's open-source family names, most popular first, as Google Fonts
    /// ranks them, such as for a search by name. Throws as `download(family:weight:)` does when
    /// the catalog can't load.
    func families() async throws -> [String] {
        try await catalog().sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key)
    }

    /// Returns each open-source catalog family name mapped to its popularity rank, which is lower
    /// for more popular families, or `Int.max` when the catalog gives none.
    ///
    /// Uses the cached catalog while it is less than seven days old. Otherwise refetches it and
    /// falls back to the stale copy only when the refetch fails, then reuses that copy for 15
    /// minutes before refetching, so an outage does not delay every font load by a request.
    /// Concurrent calls share one refetch.
    private func catalog() async throws -> [String: Int] {
        let file = root.appending(path: "catalog.json")
        if catalogCache == nil, let data = try? Data(contentsOf: file),
            let families = try? Self.decodeCatalog(data),
            let date = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        {
            catalogCache = (families, date)
        }
        if let catalogCache, -catalogCache.fetchedAt.timeIntervalSinceNow < catalogLifetime {
            return catalogCache.families
        }
        let fetch =
            catalogFetch
            ?? Task {
                defer { self.catalogFetch = nil }
                return try await self.refetchCatalog(into: file)
            }
        catalogFetch = fetch
        return try await fetch.sharedValue
    }

    /// Downloads the catalog into `file`, or returns the stale copy when the download fails, as
    /// `catalog()` describes.
    private func refetchCatalog(into file: URL) async throws -> [String: Int] {
        do {
            let data = try await fetch(URL(string: "https://fonts.google.com/metadata/fonts")!)
            let families = try Self.decodeCatalog(data)
            // A failed cache write still leaves a valid catalog for this process.
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            catalogCache = (families, Date())
            return families
        } catch {
            guard let stale = catalogCache?.families else { throw error }
            catalogCache = (stale, Date().addingTimeInterval(15 * 60 - catalogLifetime))
            return stale
        }
    }

    /// Decodes the catalog's open-source families (`catalog()`) and rejects a response too small
    /// to be the real catalog. A family listed more than once counts only when every listing is
    /// open source.
    private static func decodeCatalog(_ data: Data) throws -> [String: Int] {
        struct Catalog: Decodable {
            let familyMetadataList: [Family]
            struct Family: Decodable {
                let family: String
                let isOpenSource: Bool?
                let popularity: Int?
            }
        }
        let list = try JSONDecoder().decode(Catalog.self, from: cleanJSON(data))
            .familyMetadataList
        guard list.count > 100 else { throw CompanionError.invalidDesign }
        let closed = Set(list.filter { $0.isOpenSource == false }.map(\.family))
        return Dictionary(
            list.filter { !closed.contains($0.family) }.map { ($0.family, $0.popularity ?? .max) },
            uniquingKeysWith: min)
    }

    /// Downloads one font file and its license, the file `SpineFamily.fileName(for:in:)` chooses.
    private func fetchFile(
        family: String, weight: Int, into directory: URL, file: URL
    ) async throws {
        struct Download: Decodable {
            let manifest: Manifest
            struct Manifest: Decodable {
                let files: [File]
                let fileRefs: [Reference]
                struct File: Decodable {
                    let filename: String
                    let contents: String
                }
                struct Reference: Decodable {
                    let filename: String
                    let url: URL
                }
            }
        }
        var components = URLComponents(string: "https://fonts.google.com/download/list")!
        components.queryItems = [URLQueryItem(name: "family", value: family)]
        let manifest = try JSONDecoder()
            .decode(Download.self, from: Self.cleanJSON(try await fetch(components.url!)))
            .manifest
        guard
            let license = FontFiles.license(
                in: manifest.files.map { (name: $0.filename, contents: $0.contents) })
        else { throw CompanionError.invalidDesign }
        let candidates = manifest.fileRefs.filter {
            $0.filename.hasSuffix(".ttf") && !$0.filename.contains("Italic")
        }
        let chosen = SpineFamily.fileName(for: weight, in: candidates.map(\.filename))
        guard let source = candidates.first(where: { $0.filename == chosen }),
            source.url.scheme == "https", source.url.host == "fonts.gstatic.com"
        else { throw CompanionError.invalidDesign }
        let fontData = try await fetch(source.url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try license.write(
            to: directory.appending(path: "LICENSE.txt"), atomically: true, encoding: .utf8)
        // Write the font last: its presence marks the cache entry complete.
        try fontData.write(to: file, options: .atomic)
    }

    /// The body at `url`. It reads the body as it arrives and stops past `maximumBytes`, so a
    /// broken or hostile response never fills memory first, and reads off the actor, so other
    /// families' cache checks don't wait for it.
    @concurrent nonisolated private func fetch(_ url: URL) async throws -> Data {
        try await Self.retrying(delay: retryDelay) { try await fetchOnce(url) }
    }

    /// Runs `operation`, and runs it again after `delay(attempt)` up to `retries` times while it
    /// fails in a way that may pass on a later try: a dropped or timed-out connection, or a
    /// server error. A device being offline, a rate limit, which says when to come back, and a
    /// missing family fail at once.
    static func retrying<T: Sendable>(
        retries: Int = GoogleFonts.retries, delay: (Int) -> Duration,
        _ operation: () async throws -> T
    ) async throws -> T {
        for attempt in 1...retries {
            do {
                return try await operation()
            } catch {
                guard isTransient(error) else { throw error }
                try await Task.sleep(for: delay(attempt))
            }
        }
        return try await operation()
    }

    /// Whether `error` may pass on a later try (`retrying`).
    static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case let error as URLError:
            [.networkConnectionLost, .timedOut, .cannotConnectToHost, .badServerResponse]
                .contains(error.code)
        case let error as Unavailable: error.status >= 500
        default: false
        }
    }

    @concurrent nonisolated private func fetchOnce(_ url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard response.statusCode == 200 else { throw Self.failure(for: response) }
        guard response.url?.scheme == "https",
            response.expectedContentLength <= Int64(maximumBytes)
        else { throw CompanionError.invalidDesign }
        var data = Data()
        data.reserveCapacity(max(0, Int(response.expectedContentLength)))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw CompanionError.invalidDesign }
        }
        return data
    }

    /// Maps a response other than 200 to an error.
    ///
    /// A missing family or file (404 or 410) is `CompanionError.invalidDesign`, so the next
    /// ranked family is tried. Any other status, such as a rate limit or a server error, is
    /// `Unavailable`. `Retry-After` must be whole seconds or an HTTP date, and the date is capped
    /// at `SpineWorker.lastingStopDelay` from `now`, so a hostile or broken header cannot postpone
    /// generation indefinitely.
    static func failure(for response: HTTPURLResponse, now: Date = Date()) -> any Error {
        if [404, 410].contains(response.statusCode) { return CompanionError.invalidDesign }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { value in
                UInt(value).map { now.addingTimeInterval(TimeInterval($0)) }
                    ?? (try? Date(value, strategy: .http))
            }
            .map { min($0, now.addingTimeInterval(SpineWorker.lastingStopDelay)) }
        return Unavailable(retryAfter: retryAfter, status: response.statusCode)
    }
}
