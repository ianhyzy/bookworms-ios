import CoreText
import Foundation

/// A Google Fonts instance on disk, chosen as the closest match to a requested weight.
struct DownloadedFont: Sendable {
    /// The instance's weight on the 100...900 scale, which can differ from the requested weight.
    let weight: Int
    let postScriptName: String
    let fileURL: URL

    /// Returns whether the instance has a glyph for every non-whitespace character in `text`.
    ///
    /// Callers pass the text as it will render, uppercased when the design uses uppercase.
    func covers(_ text: String) -> Bool {
        guard
            let descriptor = GoogleFonts.descriptors(at: fileURL)
                .first(where: { GoogleFonts.postScriptName(of: $0) == postScriptName })
        else { return false }
        let characters = Array(
            String(text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }).utf16)
        guard !characters.isEmpty else { return true }
        let font = CTFontCreateWithFontDescriptor(descriptor, 32, nil)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    }
}

/// Downloads open-source Google Fonts families over HTTPS into the Caches folder.
///
/// The catalog is refetched when the cached copy is more than seven days old. Font files never
/// expire, but the system may evict Caches; a design keeps its family and weight, so the font is
/// downloaded again on next use. Requests send no credentials or cookies. Views create fonts from
/// the file's descriptors and do not register them with Core Text.
actor GoogleFonts {
    /// Google Fonts rate limited or failed a request, with the `Retry-After` date when given.
    ///
    /// The outage affects every family, so callers retry later instead of trying another one. It
    /// is not a `CompanionError`, which callers such as `SpineFonts` treat as a lasting problem
    /// with one family.
    struct Unavailable: Error {
        let retryAfter: Date?
    }

    private let root: URL
    private let session: URLSession
    private var catalogCache: (families: [String: Bool], fetchedAt: Date)?
    private let catalogLifetime: TimeInterval = 7 * 24 * 60 * 60
    private let maximumBytes = 30 * 1024 * 1024

    /// Creates a downloader that caches under `root`. Tests pass `configuration` to stand in for
    /// the network.
    init(
        root: URL = URL.cachesDirectory.appending(path: "Bookworms/fonts"),
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.root = root
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
        guard try await catalog()[family] == true else { throw CompanionError.invalidDesign }
        let directory = root.appending(path: CloudContract.digest("\(family):\(weight)"))
        let file = directory.appending(path: "font.ttf")
        if !FileManager.default.fileExists(atPath: file.path) {
            try await fetchFile(family: family, weight: weight, into: directory, file: file)
        }
        let instances = Self.descriptors(at: file)
            .compactMap { descriptor -> (Int, String)? in
                let traits =
                    CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
                    as? [CFString: Any]
                guard Self.isUpright(descriptor), let name = Self.postScriptName(of: descriptor)
                else { return nil }
                let trait = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
                return (Self.cssWeight(forTrait: trait), name)
            }
        guard
            let instance = instances.min(by: {
                abs($0.0 - weight) != abs($1.0 - weight)
                    ? abs($0.0 - weight) < abs($1.0 - weight) : $0.1 < $1.1
            })
        else { throw CompanionError.invalidDesign }
        return DownloadedFont(weight: instance.0, postScriptName: instance.1, fileURL: file)
    }

    static func descriptors(at url: URL) -> [CTFontDescriptor] {
        CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
    }

    /// Returns whether a face is upright: it has neither the italic trait nor a slant.
    static func isUpright(_ descriptor: CTFontDescriptor) -> Bool {
        let traits =
            CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let slant = (traits?[kCTFontSlantTrait] as? NSNumber)?.doubleValue ?? 0
        return symbolic & CTFontSymbolicTraits.traitItalic.rawValue == 0 && abs(slant) < 0.01
    }

    /// Returns the first upright face named in `names`, else the first upright face, else `nil`.
    static func uprightDescriptor(
        preferring names: [String?], in descriptors: [CTFontDescriptor]
    ) -> CTFontDescriptor? {
        let upright = descriptors.filter(isUpright)
        let named = names.compactMap { $0 }.lazy
            .compactMap { name in upright.first { postScriptName(of: $0) == name } }.first
        return named ?? upright.first
    }

    static func postScriptName(of descriptor: CTFontDescriptor) -> String? {
        CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
    }

    /// Maps a Core Text weight trait (-1...1) to the nearest CSS weight (100...900).
    ///
    /// The table holds the traits Core Text reports for Google Fonts files at each OS/2 weight
    /// class or `wght` coordinate. They differ from the `NSFont.Weight` constants above 700
    /// and below 300; for example, ExtraBold (800) reports 0.6, not 0.56.
    static func cssWeight(forTrait trait: Double) -> Int {
        let traits: [Double] = [-0.6, -0.4, -0.23, 0, 0.2, 0.3, 0.4, 0.6, 0.8]
        let index = traits.indices.min { abs(traits[$0] - trait) < abs(traits[$1] - trait) } ?? 3
        return (index + 1) * 100
    }

    /// Strips the anti-XSSI prefix line that Google prepends to its JSON responses.
    static func cleanJSON(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(")]}'"),
            let newline = text.firstIndex(of: "\n")
        else { return data }
        return Data(text[text.index(after: newline)...].utf8)
    }

    /// Returns each catalog family name mapped to whether it is open source.
    ///
    /// Uses the cached catalog while it is less than seven days old. Otherwise refetches it and
    /// falls back to the stale copy only when the refetch fails, then reuses that copy for 15
    /// minutes before refetching, so an outage does not delay every font load by a request.
    private func catalog() async throws -> [String: Bool] {
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

    /// Decodes the catalog and rejects a response too small to be the real catalog.
    private static func decodeCatalog(_ data: Data) throws -> [String: Bool] {
        struct Catalog: Decodable {
            let familyMetadataList: [Family]
            struct Family: Decodable {
                let family: String
                let isOpenSource: Bool?
            }
        }
        let list = try JSONDecoder().decode(Catalog.self, from: cleanJSON(data))
            .familyMetadataList
        guard list.count > 100 else { throw CompanionError.invalidDesign }
        return Dictionary(
            list.map { ($0.family, $0.isOpenSource != false) }, uniquingKeysWith: { $0 && $1 })
    }

    /// Downloads one font file and its license, the file `fileName(for:in:)` chooses.
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
            let license = manifest.files.first(where: {
                $0.filename.uppercased().contains("OFL")
                    || $0.filename.uppercased().contains("LICENSE")
            }),
            license.contents.contains("SIL OPEN FONT LICENSE")
                || license.contents.contains("Apache License")
        else { throw CompanionError.invalidDesign }
        let candidates = manifest.fileRefs.filter {
            $0.filename.hasSuffix(".ttf") && !$0.filename.contains("Italic")
        }
        let chosen = Self.fileName(for: weight, in: candidates.map(\.filename))
        guard let source = candidates.first(where: { $0.filename == chosen }),
            source.url.scheme == "https", source.url.host == "fonts.gstatic.com"
        else { throw CompanionError.invalidDesign }
        let fontData = try await fetch(source.url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try license.contents.write(
            to: directory.appending(path: "LICENSE.txt"), atomically: true, encoding: .utf8)
        // Write the font last: its presence marks the cache entry complete.
        try fontData.write(to: file, options: .atomic)
    }

    /// Returns the font file to download for `weight` from a family's upright `.ttf` file
    /// names: the static file of that weight, else the variable file, else the static file of
    /// the nearest weight, else the first file.
    ///
    /// A static file names its weight as a suffix, such as "Lato-Light.ttf". Of two equally near
    /// static files, a weight above 500 takes the heavier and any other the lighter. Some
    /// families ship width variants beside their regular files, named before the weight, such
    /// as "NotoSans_ExtraCondensed-Bold.ttf"; `TitleLettering` ranks the regular width, so a
    /// width variant is chosen only when the family has no other file of that weight.
    static func fileName(for weight: Int, in names: [String]) -> String? {
        let weights = [
            "Thin": 100, "ExtraLight": 200, "Light": 300, "Regular": 400, "Medium": 500,
            "SemiBold": 600, "Bold": 700, "ExtraBold": 800, "Black": 900,
        ]
        let widths = ["Condensed", "Expanded", "Narrow", "Wide", "Compressed"]
        func isWidthVariant(_ name: String) -> Bool { widths.contains { name.contains($0) } }
        let ordered = names.sorted { lhs, rhs in
            isWidthVariant(lhs) != isWidthVariant(rhs) ? !isWidthVariant(lhs) : lhs < rhs
        }
        let nearestStatic =
            ordered
            .compactMap { name -> (name: String, weight: Int)? in
                guard let style = name.dropLast(".ttf".count).split(separator: "-").last,
                    let fileWeight = weights[String(style)]
                else { return nil }
                return (name, fileWeight)
            }
            .min { lhs, rhs in
                let left = abs(lhs.weight - weight)
                let right = abs(rhs.weight - weight)
                if left != right { return left < right }
                return weight > 500 ? lhs.weight > rhs.weight : lhs.weight < rhs.weight
            }
        if let nearestStatic, nearestStatic.weight == weight { return nearestStatic.name }
        let variable = ordered.first { $0.contains("[") || $0.contains("VariableFont") }
        return variable ?? nearestStatic?.name ?? ordered.first
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard response.statusCode == 200 else { throw Self.failure(for: response) }
        guard response.url?.scheme == "https", data.count <= maximumBytes else {
            throw CompanionError.invalidDesign
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
        return Unavailable(retryAfter: retryAfter)
    }
}
