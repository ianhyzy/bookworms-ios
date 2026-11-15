// Generates Bookworms/SpineFontAtlas.lzfse, the glyph images that `TitleLettering.rank`
// composes to compare font families with a cover's title lettering. See `FontAtlas` for the
// file format.
//
// The atlas holds every `SpineFamily` and every other Google Fonts family that passes the
// filter below. For each family it downloads only the files the app downloads for regular
// (400) and bold (700) weight (`SpineFamily.fileName(for:in:)`), after the app's license check,
// and renders every character of `characters` alone in a 32-pixel line frame from descender to
// ascender, in the upright named instance the app uses for that weight
// (`FontFiles.nearestUpright(in:weight:)`). A family whose bold glyphs match its regular's
// stores only the regular glyphs. A request that fails or answers anything but HTTP 200, or a
// Vision error, stops the run and leaves the atlas unchanged. Run it after changing
// `SpineFamily` or that file rule:
//
//   script/spine-font-atlas.sh [report.tsv]
//
// A Google Fonts family outside `SpineFamily` is left out when any of these holds:
// - Google's catalog marks it closed source, or its license is neither OFL nor Apache
//   (`FontFiles.license(in:)`).
// - It lacks the Latin subset, its primary script isn't Latin, Google classifies it as
//   symbols, or its name marks an icon, emoji, barcode, or placeholder font.
// - It has no upright file, or lacks a glyph for any character in `characters`.
// - Its metrics are broken: no ascent or cap height, capitals taller than the ascent, or a
//   quarter of its glyphs clipped by the line frame.
// - Its letters lean more than 4 degrees, or lean unevenly (`slant(_:_:)`).
// - Its stems are under 8 percent of its capitals' height even at bold weight, so a spine's
//   title would read as scratches.
// - Vision can't read a sample line set in it at 40-pixel capitals (`isLegible(_:)`), as with
//   textured, outlined, or ornamental faces.
//
// The report lists every family with its measurements and why it was left out.

import AppKit
import CoreText
import Foundation
import Vision

let characters = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'’&-.,:!?"
let height = 32

typealias Glyph = (origin: Int, advance: Int, width: Int, pixels: [UInt8])

struct CatalogFamily: Decodable {
    let family: String
    let category: String
    let stroke: String?
    let classifications: [String]
    let subsets: [String]
    let primaryScript: String?
    let isOpenSource: Bool?
}

struct Rendered {
    let family: String
    /// The glyphs per weight, regular first.
    let weights: [(weight: Int, glyphs: [Glyph])]
}

@main
struct SpineFontAtlasTool {
    static let cache = URL.cachesDirectory.appending(path: "spine-font-atlas-v3")

    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let reportPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
        let catalog = try await catalogFamilies()
        let curated = Set(SpineFamily.allCases.map(\.rawValue))
        var jobs: [(family: String, curated: Bool)] = SpineFamily.allCases.map {
            ($0.rawValue, true)
        }
        var report = ["family\tdecision\treason\tstem\tlean\tleanSpread"]
        for entry in catalog where !curated.contains(entry.family) {
            if let reason = catalogExclusion(entry) {
                report.append("\(entry.family)\tout\t\(reason)")
                continue
            }
            jobs.append((entry.family, false))
        }
        var results: [String: Rendered] = [:]
        // Eight families at a time keeps Google Fonts from rate limiting the downloads.
        for start in stride(from: 0, to: jobs.count, by: 8) {
            let batch = jobs[start..<min(start + 8, jobs.count)]
            let outcomes = await withTaskGroup(of: (String, Rendered?, String).self) { tasks in
                for job in batch {
                    tasks.addTask {
                        await render(job.family, curated: job.curated)
                    }
                }
                var outcomes: [(String, Rendered?, String)] = []
                for await outcome in tasks { outcomes.append(outcome) }
                return outcomes
            }
            for (family, rendered, line) in outcomes {
                results[family] = rendered
                report.append(line)
            }
            FileHandle.standardError.write(Data("\(min(start + 8, jobs.count))/\(jobs.count)\n".utf8))
        }
        let failed = report.filter { $0.split(separator: "\t").dropFirst().first == "failed" }
        guard failed.isEmpty else {
            let lines = ["Families failed, so the atlas is unchanged:"] + failed
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
        var data = Data("BWA3".utf8)
        data.append(uint16: height)
        data.append(uint16: characters.utf8.count)
        data.append(contentsOf: characters.utf8)
        var fonts = 0
        for job in jobs {
            guard let rendered = results[job.family] else {
                // Every catalog family must be in the atlas, so the app can rank it.
                precondition(!job.curated, "\(job.family) didn't render")
                continue
            }
            for (weight, glyphs) in rendered.weights {
                data.append(UInt8(rendered.family.utf8.count))
                data.append(contentsOf: rendered.family.utf8)
                data.append(uint16: weight)
                for glyph in glyphs { append(glyph, to: &data) }
                fonts += 1
            }
        }
        let compressed = try (data as NSData).compressed(using: .lzfse) as Data
        try compressed.write(to: output)
        if let reportPath {
            try report.joined(separator: "\n").write(
                toFile: reportPath, atomically: true, encoding: .utf8)
        }
        print(
            "\(results.count) families, \(fonts) fonts, \(data.count / 1024) KB, "
                + "\(compressed.count / 1024) KB compressed")
    }

    /// Why Google's catalog alone rules `entry` out, or `nil`.
    static func catalogExclusion(_ entry: CatalogFamily) -> String? {
        if entry.isOpenSource == false { return "closed source" }
        if !entry.subsets.contains("latin") { return "no Latin subset" }
        if let script = entry.primaryScript, !script.isEmpty, script != "Latn" {
            return "primary script \(script)"
        }
        if entry.classifications.contains("Symbols") { return "symbols" }
        let name = entry.family.lowercased()
        let marks = ["icons", "symbols", "emoji", "barcode", "redacted", "flow ", "blokk"]
        if marks.contains(where: name.contains) { return "icon or placeholder font" }
        return nil
    }

    static func catalogFamilies() async throws -> [CatalogFamily] {
        struct Catalog: Decodable { let familyMetadataList: [CatalogFamily] }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appending(path: "catalog.json")
        // A day-old catalog is fetched again, so new and updated families reach the atlas.
        let saved = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        if (saved?.contentModificationDate).map({ -$0.timeIntervalSinceNow > 86_400 }) ?? true {
            try await fetch(URL(string: "https://fonts.google.com/metadata/fonts")!).write(to: file)
        }
        let data = try Data(contentsOf: file)
        let body = data.starts(with: Data(")]}'".utf8)) ? data.drop { $0 != UInt8(ascii: "{") } : data
        return try JSONDecoder().decode(Catalog.self, from: Data(body)).familyMetadataList
    }

    /// Downloads and renders `family`, returning its glyphs, or `nil` with the reason in the
    /// report line when the filter leaves it out. `SpineFamily` families skip the filter.
    static func render(_ family: String, curated: Bool) async -> (
        String, Rendered?, String
    ) {
        func line(_ decision: String, _ reason: String, _ measures: [Double] = []) -> String {
            ([family, decision, reason] + measures.map { String(format: "%.3f", $0) })
                .joined(separator: "\t")
        }
        let directory = cache.appending(path: family)
        // Retries ride out brief outages; a family whose download still fails stops the run
        // (`main`), so an outage never drops eligible families from the atlas.
        var downloaded: [String]?
        var failure: (any Error)?
        for attempt in 0..<3 where downloaded == nil {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2 << attempt)) }
            do {
                downloaded = try await download(family, into: directory)
            } catch {
                failure = error
            }
        }
        guard let files = downloaded else {
            let reason = failure.map { "\($0)" } ?? ""
            return (family, nil, line("failed", "download failed: \(reason)"))
        }
        guard !files.isEmpty else {
            return (family, nil, line("out", "no upright license-checked file"))
        }
        var weights: [(weight: Int, glyphs: [Glyph])] = []
        var faces: [Int: CTFont] = [:]
        for weight in [400, 700] {
            guard let probe = font(files: files, directory: directory, weight: weight, size: 100)
            else { continue }
            let frame = CTFontGetAscent(probe) + CTFontGetDescent(probe)
            guard frame > 0,
                let sized = font(
                    files: files, directory: directory, weight: weight,
                    size: 100 * CGFloat(height) / frame)
            else { continue }
            let glyphs = characters.map { glyph($0, sized) }
            // A bold that repeats the regular, as from one static file, adds nothing to rank.
            if let regular = weights.first, regular.glyphs.elementsEqual(glyphs, by: { $0 == $1 }) {
                continue
            }
            weights.append((weight, glyphs))
            faces[weight] = font(files: files, directory: directory, weight: weight, size: 300)
        }
        guard let regular = faces[400] ?? faces[700], !weights.isEmpty else {
            return (family, nil, line("out", "no usable face"))
        }
        let heaviest = faces[700] ?? regular
        let boldest = max(stem(regular), stem(heaviest))
        let leans = "lIHbhkinmrpBDEFKLPR".compactMap { slant(String($0), regular) }.sorted()
        let lean = leans.isEmpty ? 0 : leans[leans.count / 2]
        let spread = leans.isEmpty ? 0 : leans[leans.count * 3 / 4] - leans[leans.count / 4]
        let measures = [boldest, lean, spread]
        let rendered = Rendered(family: family, weights: weights)
        if curated { return (family, rendered, line("in", "catalog", measures)) }
        if let missing = characters.first(where: { $0 != " " && !hasGlyph($0, regular) }) {
            return (family, nil, line("out", "no glyph for \(missing)", measures))
        }
        let ascent = CTFontGetAscent(regular)
        let capHeight = CTFontGetCapHeight(regular)
        let clipped = weights[0].glyphs.filter { glyph in
            glyph.width > 0
                && ((0..<glyph.width).contains { glyph.pixels[$0] > 0 }
                    || (0..<glyph.width).contains {
                        glyph.pixels[(height - 1) * glyph.width + $0] > 0
                    })
        }
        if ascent <= 0 || capHeight <= 0 || capHeight > ascent * 1.05
            || clipped.count * 4 > characters.count
        {
            return (family, nil, line("out", "broken metrics", measures))
        }
        if abs(lean) > 4 || spread > 5 { return (family, nil, line("out", "leans", measures)) }
        if boldest < 0.08 { return (family, nil, line("out", "hairline", measures)) }
        do {
            if try !isLegible(regular) { return (family, nil, line("out", "illegible", measures)) }
        } catch {
            return (family, nil, line("failed", "Vision failed: \(error)", measures))
        }
        return (family, rendered, line("in", "", measures))
    }

    static func hasGlyph(_ character: Character, _ font: CTFont) -> Bool {
        let units = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
            && glyphs.allSatisfy { $0 != 0 }
    }

    static let sample = "Quick Brown Fox 1984"

    /// Whether Vision reads `sample` set in `font` at 40-pixel capitals, allowing a fifth of its
    /// letters and digits to differ, case aside. Throws Vision's error.
    static func isLegible(_ font: CTFont) throws -> Bool {
        let size = 40 * CTFontGetSize(font) / max(CTFontGetCapHeight(font), 1)
        let image = render(sample, CTFontCreateCopyWithAttributes(font, size, nil, nil))
        let bytes = image.px.map { UInt8(255 - min(255, Int($0 * 255))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let cgImage = CGImage(
                width: image.w, height: image.h, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: image.w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let read = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        func letters(_ text: String) -> [Character] {
            Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let expected = letters(sample)
        return Double(distance(expected, letters(read))) <= Double(expected.count) * 0.2
    }

    /// The Levenshtein distance between two character arrays.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    /// Renders `text` and returns a gray ink mask (1 = ink), top row first.
    static func render(_ text: String, _ font: CTFont) -> (w: Int, h: Int, px: [Float]) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
        let descent = CTFontGetDescent(font)
        let width = Int(CTLineGetTypographicBounds(line, nil, nil, nil)) + 80
        let lineHeight = Int(CTFontGetAscent(font) + descent) + 40
        var gray = [UInt8](repeating: 255, count: width * lineHeight)
        gray.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: lineHeight, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: lineHeight))
            context.textPosition = CGPoint(x: 40, y: descent + 20)
            CTLineDraw(line, context)
        }
        return (width, lineHeight, gray.map { Float(255 - Int($0)) / 255 })
    }

    /// Lean in degrees, positive to the right: the Theil-Sen slope of the leftmost stroke's
    /// center against height, over the middle 70 percent of the glyph's ink rows.
    static func slant(_ character: String, _ font: CTFont) -> Double? {
        let mask = render(character, font)
        let rows = (0..<mask.h).filter { y in
            (0..<mask.w).contains { mask.px[y * mask.w + $0] > 0.5 }
        }
        guard let top = rows.first, let bottom = rows.last, bottom - top > 20 else { return nil }
        let low = top + Int(Double(bottom - top) * 0.15)
        let high = bottom - Int(Double(bottom - top) * 0.15)
        var points: [(y: Double, x: Double)] = []
        for y in stride(from: low, through: high, by: 2) {
            guard let start = (0..<mask.w).first(where: { mask.px[y * mask.w + $0] > 0.5 }) else {
                continue
            }
            var end = start
            while end + 1 < mask.w, mask.px[y * mask.w + end + 1] > 0.5 { end += 1 }
            points.append((Double(-y), Double(start + end) / 2))
        }
        var slopes: [Double] = []
        for i in points.indices {
            for j in points.indices where j > i + 3 {
                slopes.append((points[j].x - points[i].x) / (points[j].y - points[i].y))
            }
        }
        guard !slopes.isEmpty else { return nil }
        slopes.sort()
        return atan(slopes[slopes.count / 2]) * 180 / .pi
    }

    /// The median horizontal ink run of "HIlEn" over the cap height: about a stem's width.
    static func stem(_ font: CTFont) -> Double {
        let mask = render("HIlEn", font)
        var runs: [Double] = []
        for y in 0..<mask.h {
            var run = 0
            for x in 0..<mask.w {
                if mask.px[y * mask.w + x] > 0.5 {
                    run += 1
                } else if run > 0 {
                    runs.append(Double(run))
                    run = 0
                }
            }
        }
        guard !runs.isEmpty else { return 0 }
        runs.sort()
        return runs[runs.count / 2] / max(Double(CTFontGetCapHeight(font)), 1)
    }

    /// The glyph's ink columns, its ink origin from the pen position, and its advance.
    static func glyph(_ character: Character, _ font: CTFont) -> Glyph {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: String(character),
                attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
        let advance = Int(CTLineGetTypographicBounds(line, nil, nil, nil).rounded())
        let pad = height
        let width = advance + pad * 2
        var gray = [UInt8](repeating: 255, count: width * height)
        gray.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.textPosition = CGPoint(x: CGFloat(pad), y: CTFontGetDescent(font))
            CTLineDraw(line, context)
        }
        // 4-bit ink coverage, 0 for paper and 15 for solid ink.
        let ink = gray.map { UInt8((Double(255 - Int($0)) / 255 * 15).rounded()) }
        let columns = (0..<width).filter { x in (0..<height).contains { ink[$0 * width + x] > 0 } }
        guard let first = columns.first, let last = columns.last else {
            return (0, advance, 0, [])
        }
        var pixels: [UInt8] = []
        for y in 0..<height { pixels += ink[(y * width + first)...(y * width + last)] }
        return (first - pad, advance, last - first + 1, pixels)
    }

    static func append(_ glyph: Glyph, to data: inout Data) {
        data.append(uint16: Int(UInt16(bitPattern: Int16(glyph.origin))))
        data.append(uint16: glyph.advance)
        data.append(uint16: glyph.width)
        var index = 0
        while index < glyph.pixels.count {
            let high = glyph.pixels[index]
            let low = index + 1 < glyph.pixels.count ? glyph.pixels[index + 1] : 0
            data.append(high << 4 | low)
            index += 2
        }
    }

    /// The files the app downloads for regular and bold weight among `names`.
    static func wantedFiles(in names: [String]) -> Set<String> {
        Set([400, 700].compactMap { SpineFamily.fileName(for: $0, in: names) })
    }

    /// Downloads the files the app downloads for regular and bold weight, after the same
    /// license check (`GoogleFonts`), and returns every upright file name the family offers,
    /// with the downloaded ones in `directory`. Returns none for a family without an OFL or
    /// Apache license. A saved listing is reused only while the files that the current
    /// `SpineFamily.fileName(for:in:)` rule picks from it are in `directory`.
    static func download(_ family: String, into directory: URL) async throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let listing = directory.appending(path: "files.txt")
        let saved = (try? String(contentsOf: listing, encoding: .utf8))?
            .split(separator: "\n").map(String.init)
        func isSaved(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: directory.appending(path: name).path)
        }
        if let saved, wantedFiles(in: saved).allSatisfy(isSaved) { return saved }
        var components = URLComponents(string: "https://fonts.google.com/download/list")!
        components.queryItems = [URLQueryItem(name: "family", value: family)]
        let data = try await fetch(components.url!)
        // The response starts with an anti-JSON-hijacking prefix before the object.
        let body = data.drop { $0 != UInt8(ascii: "{") }
        let manifest =
            (try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])?["manifest"]
            as? [String: Any]
        let licensed =
            FontFiles.license(
                in: ((manifest?["files"] as? [[String: Any]]) ?? []).map {
                    (name: $0["filename"] as? String ?? "", contents: $0["contents"] as? String ?? "")
                }) != nil
        let references = ((manifest?["fileRefs"] as? [[String: Any]]) ?? [])
            .filter {
                let name = $0["filename"] as? String ?? ""
                return name.hasSuffix(".ttf") && !name.contains("Italic")
            }
        func file(_ reference: [String: Any]) -> String? {
            (reference["filename"] as? String).map { ($0 as NSString).lastPathComponent }
        }
        let names = licensed ? references.compactMap(file).sorted() : []
        let wanted = wantedFiles(in: names)
        for reference in references {
            guard let name = file(reference), wanted.contains(name),
                let url = URL(string: reference["url"] as? String ?? ""),
                url.host == "fonts.gstatic.com"
            else { continue }
            try await fetch(url).write(to: directory.appending(path: name))
        }
        try names.joined(separator: "\n").write(to: listing, atomically: true, encoding: .utf8)
        return names
    }

    /// The body at `url`, or an error for anything but HTTP 200.
    static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse, userInfo: ["status": status]) }
        return data
    }

    /// The face the app draws `weight` with: the file the app downloads for it, and that file's
    /// upright named instance nearest the weight.
    static func font(files: [String], directory: URL, weight: Int, size: CGFloat) -> CTFont? {
        guard let file = SpineFamily.fileName(for: weight, in: files),
            let instance = FontFiles.nearestUpright(
                in: (CTFontManagerCreateFontDescriptorsFromURL(
                    directory.appending(path: file) as CFURL) as? [CTFontDescriptor]) ?? [],
                weight: weight)
        else { return nil }
        return CTFontCreateWithFontDescriptor(instance.descriptor, size, nil)
    }
}

extension Data {
    mutating func append(uint16 value: Int) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
    }
}
