// Generates Bookworms/SpineFontAtlas.lzfse, the glyph images that `TitleLettering.rank`
// composes to compare every catalog family with a cover's title lettering. See `FontAtlas` for
// the file format.
//
// Downloads each catalog family from Google Fonts into a cache folder and renders every
// character of `characters` alone at regular (400) and bold (700) weight, in a 32-pixel line
// frame from descender to ascender. Bold falls back to the nearest static weight the family
// has. Run it after changing `SpineFamily`:
//
//   script/spine-font-atlas.sh

import AppKit
import CoreText
import Foundation

let characters = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'’&-.,:!?"
let height = 32

@main
struct SpineFontAtlasTool {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let cache = URL.cachesDirectory.appending(path: "spine-font-atlas")
        var data = Data("BWA1".utf8)
        data.append(uint16: height)
        data.append(uint16: characters.utf8.count)
        data.append(contentsOf: characters.utf8)
        for family in SpineFamily.allCases.map(\.rawValue) {
            let directory = cache.appending(path: family)
            let files = try await download(family, into: directory)
            for weight in [400, 700] {
                // Size the font so its ascender-to-descender frame is `height` pixels.
                guard
                    let probe = font(files: files, directory: directory, weight: weight, size: 100)
                else { continue }
                let frame = CTFontGetAscent(probe) + CTFontGetDescent(probe)
                guard
                    let font = font(
                        files: files, directory: directory, weight: weight,
                        size: 100 * CGFloat(height) / frame)
                else { continue }
                data.append(UInt8(family.utf8.count))
                data.append(contentsOf: family.utf8)
                data.append(uint16: weight)
                for character in characters { append(glyph(character, font), to: &data) }
            }
            print(family)
        }
        let compressed = try (data as NSData).compressed(using: .lzfse) as Data
        try compressed.write(to: output)
        print("\(data.count / 1024) KB, \(compressed.count / 1024) KB compressed")
    }

    /// The glyph's ink columns, its ink origin from the pen position, and its advance.
    static func glyph(_ character: Character, _ font: CTFont)
        -> (origin: Int, advance: Int, width: Int, pixels: [UInt8])
    {
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

    static func append(
        _ glyph: (origin: Int, advance: Int, width: Int, pixels: [UInt8]), to data: inout Data
    ) {
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

    static func download(_ family: String, into directory: URL) async throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".ttf") }
        if !existing.isEmpty { return existing.sorted() }
        var components = URLComponents(string: "https://fonts.google.com/download/list")!
        components.queryItems = [URLQueryItem(name: "family", value: family)]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        // The response starts with an anti-JSON-hijacking prefix before the object.
        let body = data.drop { $0 != UInt8(ascii: "{") }
        let manifest =
            (try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])?["manifest"]
            as? [String: Any]
        let references = ((manifest?["fileRefs"] as? [[String: Any]]) ?? [])
            .filter {
                let name = $0["filename"] as? String ?? ""
                return name.hasSuffix(".ttf") && !name.contains("Italic")
            }
        let variable = references.filter { ($0["filename"] as? String ?? "").contains("[") }
        var names: [String] = []
        for reference in variable.isEmpty ? references : variable {
            guard let name = reference["filename"] as? String,
                let url = URL(string: reference["url"] as? String ?? "")
            else { continue }
            let file = (name as NSString).lastPathComponent
            let (bytes, _) = try await URLSession.shared.data(from: url)
            try bytes.write(to: directory.appending(path: file))
            names.append(file)
        }
        return names.sorted()
    }

    static func font(files: [String], directory: URL, weight: Int, size: CGFloat) -> CTFont? {
        func descriptor(_ file: String) -> CTFontDescriptor? {
            (CTFontManagerCreateFontDescriptorsFromURL(directory.appending(path: file) as CFURL)
                as? [CTFontDescriptor])?
                .first
        }
        if let variable = files.first(where: { $0.contains("[") }), let d = descriptor(variable) {
            let instance =
                variable.contains("wght")
                ? CTFontDescriptorCreateCopyWithVariation(
                    d, 0x7767_6874 as CFNumber, CGFloat(weight))
                : d
            return CTFontCreateWithFontDescriptor(instance, size, nil)
        }
        let names = [400: ["Regular"], 700: ["Bold", "SemiBold", "ExtraBold", "Black"]]
        let preferred = (names[weight] ?? []) + ["Regular"]
        let file =
            preferred.lazy.compactMap { name in files.first { $0.hasSuffix("-\(name).ttf") } }
            .first ?? files.first
        return file.flatMap(descriptor).map { CTFontCreateWithFontDescriptor($0, size, nil) }
    }
}

extension Data {
    mutating func append(uint16 value: Int) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
    }
}
