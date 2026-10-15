// Generates Bookworms/SpineFontDescriptors.json, the per-family measurements that
// `TitleLettering.rank` compares with a cover's title lettering.
//
// Downloads each catalog family from Google Fonts into a cache folder, renders every glyph in
// `characters` at regular (400) and bold (700) weight, and records its ink width, ink top, ink
// bottom, and side bearings in cap heights. Stroke contrast comes from a rendered sample string
// measured with the app's own `Mask.lettering`. Run it after changing `SpineFamily`:
//
//   script/spine-font-descriptors.sh
//
// Bold falls back to the nearest static weight the family has.

import AppKit
import CoreText
import Foundation

enum CompanionError: Error { case invalidCover }  // ColorValue.swift throws this.

let characters = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'’&-.,:!?"
let weights = [400, 700]

@main
struct SpineFontDescriptorsTool {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let cache = URL.cachesDirectory.appending(path: "spine-font-descriptors")
        var fonts: [String: [String: Any]] = [:]
        for family in SpineFamily.allCases.map(\.rawValue) {
            let directory = cache.appending(path: family)
            let files = try await download(family, into: directory)
            var byWeight: [String: Any] = [:]
            for weight in weights {
                guard let font = font(files: files, directory: directory, weight: weight, size: 200)
                else { continue }
                byWeight[String(weight)] = describe(font)
            }
            fonts[family] = byWeight
            print(family, files.count)
        }
        let json: [String: Any] = ["characters": characters, "fonts": fonts]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: output)
    }

    /// Downloads the family's upright TrueType files once.
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

    /// The variable font at `weight`, or the static file nearest it.
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

    static func describe(_ font: CTFont) -> [String: Any] {
        var capHeight = Double(CTFontGetCapHeight(font))
        if capHeight <= 1 { capHeight = Double(line("H", font).bounds.height) }
        let glyphs: [Any] = characters.map { character -> Any in
            let (bounds, advance) = line(String(character), font)
            guard bounds.width > 0 else { return NSNull() }
            return [
                bounds.width, bounds.maxY, bounds.minY, bounds.minX, advance - bounds.maxX,
            ]
            .map { rounded(Double($0) / capHeight) }
        }
        func spread(_ text: String) -> Double {
            guard let mask = render(text, font), let measured = Mask.lettering(mask) else {
                return 0
            }
            return measured.strokeSpread
        }
        return [
            "glyphs": glyphs, "spreadCapitals": rounded(spread("HAMBURGEFONSTIV")),
            "spreadMixed": rounded(spread("Hamburgefonstiv")),
        ]
    }

    /// Three decimals, written without binary floating-point noise.
    static func rounded(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.3f", value))
    }

    static func line(_ text: String, _ font: CTFont) -> (bounds: CGRect, advance: CGFloat) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        return (
            CTLineGetImageBounds(line, nil),
            CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        )
    }

    /// Renders `text` black on white into an ink mask.
    static func render(_ text: String, _ font: CTFont) -> Mask? {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
        let bounds = CTLineGetImageBounds(line, nil)
        guard bounds.width > 4 else { return nil }
        let width = Int(bounds.width) + 20
        let height = Int(bounds.height) + 20
        var gray = [UInt8](repeating: 255, count: width * height)
        gray.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.textPosition = CGPoint(x: 10 - bounds.minX, y: 10 - bounds.minY)
            CTLineDraw(line, context)
        }
        return Mask(width: width, height: height, pixels: gray.map { Float(255 - Int($0)) / 255 })
    }
}
