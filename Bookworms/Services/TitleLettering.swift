import CoreGraphics
import Foundation

/// Measures a cover's title lettering and matches it against the spine font catalog without a
/// language model.
///
/// The title line comes from OCR. Its crop is split into ink and ground with two-means in OKLab;
/// the ground is the cluster that touches the crop's border most. Every catalog family's version
/// of the same text is composed from `SpineFontAtlas.lzfse`, small glyph images that
/// `script/spine-font-atlas.swift` renders from the Google Fonts files, so ranking needs no font
/// downloads. Families are compared on four measurements that small vision models judge
/// poorly: letter shapes, letter width for their height with letter spacing removed, how much
/// stroke thickness varies, and stroke weight.
enum TitleLettering {
    /// An OCR line with its normalized Vision bounding box (origin at the bottom left).
    struct Line: Sendable {
        let text: String
        let box: CGRect
    }

    /// The measured title line.
    struct Measurement: Sendable {
        /// The OCR text of the line, as set on the cover.
        let text: String
        /// The crop of the line, which the model reads for the coarse lettering questions.
        let crop: CGImage
        let profile: Mask.Profile
        let ink: ColorValue
        let ground: ColorValue
    }

    /// A family and weight, best match first.
    struct Match: Equatable, Sendable {
        let family: String
        let weight: Int
    }

    /// The lightest title weight a ranked family gets. Thin strokes read badly at spine size,
    /// where `SpineView` sizes the title to the spine's thickness, so a design is never lighter
    /// than semibold even when the cover's lettering is. Many families have no medium (500)
    /// instance, and the nearest instance to 500 would be their regular.
    static let minimumWeight = 600

    /// Measures the tallest horizontal OCR line that shares a word with `title`, or the tallest
    /// horizontal line when none does. Returns `nil` when the cover has no readable line.
    ///
    /// A line set vertically, whose box is taller than it is wide, is left out: its letters
    /// stack, so the line's width says nothing about theirs.
    static func measure(_ image: CGImage, lines: [Line], title: String) -> Measurement? {
        let words = Set(wordsIn(title))
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let lines = lines.filter { $0.box.width * aspect > $0.box.height }
        let titled = lines.filter { !Set(wordsIn($0.text)).isDisjoint(with: words) }
        guard
            let line = (titled.isEmpty ? lines : titled).max(by: { $0.box.height < $1.box.height })
        else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // Vision's box is normalized with a bottom-left origin; CGImage cropping is top-left.
        var rect = CGRect(
            x: line.box.minX * width, y: (1 - line.box.maxY) * height,
            width: line.box.width * width, height: line.box.height * height)
        let box = rect
        rect =
            rect.insetBy(dx: -rect.height * 0.12, dy: -rect.height * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard let crop = image.cropping(to: rect), let split = split(crop) else { return nil }
        // The padding keeps the colors' border clear of the letters, but a line or picture just
        // above or below can touch the title's rows and join its band, which makes the
        // lettering look taller and narrower than it is. Only the box's own rows, with a little
        // slack for strokes Vision trims, are measured.
        let scale = Double(split.mask.height) / Double(crop.height)
        let slack = box.height * 0.06
        let top = Int(((box.minY - rect.minY - slack) * scale).rounded(.down))
        let bottom = Int(((box.maxY - rect.minY + slack) * scale).rounded(.up))
        guard top < bottom, let profile = split.mask.keepingRows(top..<bottom).profile() else {
            return nil
        }
        return Measurement(
            text: line.text.trimmingCharacters(in: .whitespaces), crop: crop, profile: profile,
            ink: split.ink, ground: split.ground)
    }

    /// Ranks `families` by how closely the measured lettering matches the same text composed
    /// from each family's regular and bold glyphs, one match per family. Each measurement is
    /// z-scored across the whole catalog, so a subset ranks the same way it would within the
    /// catalog. Families without glyphs for the text are left out.
    ///
    /// Stroke weight is matched against the lettering's own, but never against less than the
    /// catalog's median regular weight for the text: a design is never lighter than
    /// `minimumWeight`, so a thin title gets a face that is regular at its lightest. A family's
    /// weight is then interpolated between its regular and bold glyphs
    /// (`weight(regular:bold:cover:)`).
    /// Monoton's parallel hairlines blur into solid strokes in the atlas's small glyphs, and an
    /// outlined title measures as hairlines, so weight doesn't count against Monoton.
    static func rank(
        _ families: [String], for measurement: Measurement, atlas: FontAtlas? = .shared
    ) -> [Match] {
        guard let atlas else { return [] }
        let cover = measurement.profile
        let composed = atlas.fonts.compactMap { font in
            font.compose(measurement.text)?.profile().map { (font: font, profile: $0) }
        }
        let stroke = max(cover.strokeWeight, regularStroke(of: composed))
        var strokes: [String: [Int: Double]] = [:]
        for (font, profile) in composed {
            strokes[font.family, default: [:]][font.weight] = profile.strokeWeight
        }
        let rows = composed.map { font, profile in
            (
                family: font.family, weight: font.weight,
                values: [
                    profile.shapeDifference(from: cover),
                    abs(log(profile.aspect / cover.aspect)),
                    abs(profile.strokeSpread - cover.strokeSpread),
                    font.family == SpineFamily.monoton.rawValue
                        ? 0 : abs(log(profile.strokeWeight / stroke)),
                ]
            )
        }
        // Width carries most of the signal; stroke weight keeps a heavy title out of hairline
        // faces of the same width, and shape and stroke contrast separate the rest. The weights
        // scored best on the hand-labeled covers of the owner's library.
        let weights = [0.25, 2, 0.25, 1]
        var scores = [Double](repeating: 0, count: rows.count)
        for k in weights.indices where rows.count > 1 {
            let values = rows.map { $0.values[k] }
            let mean = values.reduce(0, +) / Double(values.count)
            let deviation =
                (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
                .squareRoot()
            for index in rows.indices {
                scores[index] += weights[k] * (values[index] - mean) / max(deviation, 1e-9)
            }
        }
        let allowed = Set(families)
        var seen = Set<String>()
        return rows.indices.filter { allowed.contains(rows[$0].family) }
            .sorted { lhs, rhs in
                if scores[lhs] != scores[rhs] { return scores[lhs] < scores[rhs] }
                let (a, b) = (rows[lhs], rows[rhs])
                return a.family != b.family ? a.family < b.family : a.weight < b.weight
            }
            .compactMap { index in
                let row = rows[index]
                guard seen.insert(row.family).inserted else { return nil }
                let reach = strokes[row.family] ?? [:]
                return Match(
                    family: row.family,
                    weight: weight(
                        regular: reach[400] ?? reach[700] ?? stroke,
                        bold: reach[700] ?? reach[400] ?? stroke, cover: stroke))
            }
    }

    /// Whether the lettering's strokes are hairlines: under 60 percent of the catalog's median
    /// regular stroke weight for the same text, as an outlined or inline title measures.
    static func hasHairlineStrokes(
        _ measurement: Measurement, atlas: FontAtlas? = .shared
    ) -> Bool {
        guard let atlas else { return false }
        let composed = atlas.fonts.filter { $0.weight == 400 }
            .compactMap { font in
                font.compose(measurement.text)?.profile().map { (font: font, profile: $0) }
            }
        return measurement.profile.strokeWeight < regularStroke(of: composed) * 0.6
    }

    /// The median stroke weight of the regular (400) fonts in `composed`, or 0 without any.
    private static func regularStroke(
        of composed: [(font: FontAtlas.Font, profile: Mask.Profile)]
    ) -> Double {
        let strokes = composed.filter { $0.font.weight == 400 }.map(\.profile.strokeWeight).sorted()
        return strokes.isEmpty ? 0 : strokes[strokes.count / 2]
    }

    /// The title weight, `minimumWeight` through 700 in steps of 100, whose stroke weight comes nearest
    /// `cover`'s, interpolating between a family's `regular` (400) and `bold` (700) stroke
    /// weights. A family whose bold is no heavier, such as a single-weight display face, gets
    /// `minimumWeight`, which loads its only instance.
    static func weight(regular: Double, bold: Double, cover: Double) -> Int {
        guard bold > regular * 1.05 else { return minimumWeight }
        let css = 400 + 300 * (cover - regular) / (bold - regular)
        return min(700, max(minimumWeight, Int((css / 100).rounded()) * 100))
    }

    private static func wordsIn(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Splits a crop into an ink mask and the ink and ground colors.
    static func split(_ image: CGImage) -> (mask: Mask, ink: ColorValue, ground: ColorValue)? {
        let scale = min(1, 600 / Double(image.width))
        let width = max(8, Int(Double(image.width) * scale))
        let height = max(8, Int(Double(image.height) * scale))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var points: [SpineContrast.Lab] = []
        points.reserveCapacity(width * height)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            points.append(
                SpineContrast.lab(
                    ColorValue(
                        red: Int(rgba[offset]), green: Int(rgba[offset + 1]),
                        blue: Int(rgba[offset + 2]))))
        }
        let byLightness = points.sorted { $0.l < $1.l }
        var centers = [byLightness[points.count / 10], byLightness[points.count * 9 / 10]]
        var cluster = [Int](repeating: 0, count: points.count)
        for _ in 0..<8 {
            var sums = [(l: 0.0, a: 0.0, b: 0.0), (l: 0.0, a: 0.0, b: 0.0)]
            var counts = [0, 0]
            for (index, point) in points.enumerated() {
                let nearest = distance(point, centers[0]) <= distance(point, centers[1]) ? 0 : 1
                cluster[index] = nearest
                sums[nearest].l += point.l
                sums[nearest].a += point.a
                sums[nearest].b += point.b
                counts[nearest] += 1
            }
            for k in 0..<2 where counts[k] > 0 {
                let n = Double(counts[k])
                centers[k] = SpineContrast.Lab(l: sums[k].l / n, a: sums[k].a / n, b: sums[k].b / n)
            }
        }
        // The ground surrounds the letters, so it is the cluster that touches the border most.
        var border = [0, 0]
        for x in 0..<width {
            border[cluster[x]] += 1
            border[cluster[(height - 1) * width + x]] += 1
        }
        for y in 0..<height {
            border[cluster[y * width]] += 1
            border[cluster[y * width + width - 1]] += 1
        }
        let ink = border[0] <= border[1] ? 0 : 1
        let mask = Mask(
            width: width, height: height, pixels: cluster.map { $0 == ink ? 1 : 0 })
        return (mask, SpineContrast.color(centers[ink]), SpineContrast.color(centers[1 - ink]))
    }

    private static func distance(_ p: SpineContrast.Lab, _ q: SpineContrast.Lab) -> Double {
        (p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b)
    }
}

/// A grayscale ink mask, 1 for ink, with rows stored top to bottom.
struct Mask: Sendable {
    var width: Int
    var height: Int
    var pixels: [Float]

    /// A line of lettering normalized for comparison.
    struct Profile: Sendable {
        /// The letters' width over their height, with gaps between letters collapsed.
        var aspect: Double
        /// The spread of horizontal ink runs, (90th − 10th percentile) / median: near 0 for
        /// even strokes, larger for thick-and-thin faces.
        var strokeSpread: Double
        /// The letters stretched to a fixed 320 × 48 grid, for shape comparison.
        var shape: [Float]
        /// The median ink in a horizontal run over the line's height, measured on the 48-pixel
        /// grid: about a vertical stem's width for its height, larger for heavier lettering.
        /// The grid's box filter fills printing texture, such as halftone dots, that would
        /// break a cover's strokes into short runs, and partial coverage counts, so the atlas's
        /// small antialiased glyphs measure as finely as large covers.
        var strokeWeight: Double

        /// The mean absolute difference between the two shape grids.
        func shapeDifference(from other: Profile) -> Double {
            var total: Float = 0
            for index in shape.indices { total += abs(shape[index] - other.shape[index]) }
            return Double(total) / Double(shape.count)
        }
    }

    /// Measures the band of rows that holds the most ink, so neighboring lines drop out, with
    /// each run of empty columns collapsed to a twelfth of the band's height so letter spacing
    /// does not count as letter width. Covers and composed fonts are measured the same way.
    func profile() -> Profile? {
        guard let letters = band()?.collapsingGaps()?.trimmed() else { return nil }
        let natural = letters.resampled(
            width: max(4, letters.width * 48 / letters.height), height: 48)
        return Profile(
            aspect: Double(natural.width) / Double(natural.height),
            strokeSpread: natural.strokeSpread,
            shape: letters.resampled(width: 320, height: 48).pixels,
            strokeWeight: natural.strokeWeight)
    }

    /// The mask with every row outside `rows` cleared.
    func keepingRows(_ rows: Range<Int>) -> Mask {
        var out = [Float](repeating: 0, count: pixels.count)
        for y in rows.clamped(to: 0..<height) {
            let row = (y * width)..<((y + 1) * width)
            out.replaceSubrange(row, with: pixels[row])
        }
        return Mask(width: width, height: height, pixels: out)
    }

    func band() -> Mask? {
        var rowInk = [Float](repeating: 0, count: height)
        for y in 0..<height {
            for x in 0..<width { rowInk[y] += pixels[y * width + x] }
        }
        let threshold = max(1, Float(width) * 0.012)
        var best: (start: Int, end: Int, ink: Float)?
        var y = 0
        while y < height {
            guard rowInk[y] >= threshold else {
                y += 1
                continue
            }
            var end = y
            var ink: Float = 0
            while end < height, rowInk[end] >= threshold {
                ink += rowInk[end]
                end += 1
            }
            if ink > best?.ink ?? 0 { best = (y, end, ink) }
            y = end
        }
        guard let best, best.end - best.start >= 4 else { return nil }
        return Mask(
            width: width, height: best.end - best.start,
            pixels: Array(pixels[(best.start * width)..<(best.end * width)]))
    }

    func collapsingGaps() -> Mask? {
        let gap = max(1, height / 12)
        var columns: [Int] = []
        var empty = 0
        for x in 0..<width {
            var ink: Float = 0
            for y in 0..<height { ink += pixels[y * width + x] }
            if ink < 0.5 {
                empty += 1
                if empty <= gap, !columns.isEmpty { columns.append(x) }
            } else {
                empty = 0
                columns.append(x)
            }
        }
        while let last = columns.last, (0..<height).allSatisfy({ pixels[$0 * width + last] < 0.5 })
        {
            columns.removeLast()
        }
        guard columns.count >= 4 else { return nil }
        var out = [Float](repeating: 0, count: columns.count * height)
        for (index, x) in columns.enumerated() {
            for y in 0..<height { out[y * columns.count + index] = pixels[y * width + x] }
        }
        return Mask(width: columns.count, height: height, pixels: out)
    }

    /// Crops to the columns with ink and the rows with more than speck-level ink.
    func trimmed() -> Mask? {
        var columnInk = [Float](repeating: 0, count: width)
        var rowInk = [Float](repeating: 0, count: height)
        for y in 0..<height {
            for x in 0..<width {
                columnInk[x] += pixels[y * width + x]
                rowInk[y] += pixels[y * width + x]
            }
        }
        let rowThreshold = max(1, Float(width) * 0.004)
        guard let minX = columnInk.firstIndex(where: { $0 >= 1 }),
            let maxX = columnInk.lastIndex(where: { $0 >= 1 }),
            let minY = rowInk.firstIndex(where: { $0 >= rowThreshold }),
            let maxY = rowInk.lastIndex(where: { $0 >= rowThreshold }), maxX > minX, maxY > minY
        else { return nil }
        var out: [Float] = []
        out.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY...maxY { out += pixels[(y * width + minX)...(y * width + maxX)] }
        return Mask(width: maxX - minX + 1, height: maxY - minY + 1, pixels: out)
    }

    /// Box-filters the mask to `targetWidth` × `targetHeight`.
    func resampled(width targetWidth: Int, height targetHeight: Int) -> Mask {
        var out = [Float](repeating: 0, count: targetWidth * targetHeight)
        for ty in 0..<targetHeight {
            let y0 = ty * height / targetHeight
            let y1 = max(y0 + 1, (ty + 1) * height / targetHeight)
            for tx in 0..<targetWidth {
                let x0 = tx * width / targetWidth
                let x1 = max(x0 + 1, (tx + 1) * width / targetWidth)
                var sum: Float = 0
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) { sum += pixels[y * width + x] }
                }
                out[ty * targetWidth + tx] = sum / Float((y1 - y0) * (x1 - x0))
            }
        }
        return Mask(width: targetWidth, height: targetHeight, pixels: out)
    }

    private var strokeWeight: Double {
        var runs: [Double] = []
        for y in 0..<height {
            var run: Double = 0
            for x in 0..<width {
                let value = Double(pixels[y * width + x])
                if value > 0.2 {
                    run += value
                } else if run > 0 {
                    runs.append(run)
                    run = 0
                }
            }
            if run > 0 { runs.append(run) }
        }
        guard !runs.isEmpty else { return 1 / Double(max(1, height)) }
        runs.sort()
        return max(0.5, runs[runs.count / 2]) / Double(height)
    }

    private var strokeSpread: Double {
        var runs: [Double] = []
        for y in 0..<height {
            var run = 0
            for x in 0..<width {
                if pixels[y * width + x] > 0.5 {
                    run += 1
                } else if run > 0 {
                    runs.append(Double(run))
                    run = 0
                }
            }
            if run > 0 { runs.append(Double(run)) }
        }
        guard !runs.isEmpty else { return 0 }
        runs.sort()
        let median = runs[runs.count / 2]
        return (runs[runs.count * 9 / 10] - runs[runs.count / 10]) / max(1, median)
    }
}

/// Every catalog family's glyphs at regular and bold weight, generated by
/// `script/spine-font-atlas.swift`.
///
/// The file is LZFSE-compressed. Decompressed, it holds little-endian fields: the magic
/// `BWA1`, the glyph height, and the UTF-8 character list; then, per font, its family name,
/// CSS weight, and, per character, the glyph's ink origin from the pen position, its advance,
/// its ink width, and its pixels at 4 bits each, row by row from the top.
struct FontAtlas: Sendable {
    struct Glyph: Sendable {
        var origin: Int
        var advance: Int
        var width: Int
        var pixels: [Float]
    }

    struct Font: Sendable {
        let family: String
        let weight: Int
        let height: Int
        let glyphs: [Character: Glyph]

        /// `text` laid out by advances, without kerning; `nil` when fewer than two of its
        /// characters have glyphs.
        func compose(_ text: String) -> Mask? {
            let parts = text.compactMap { glyphs[$0] }
            guard parts.filter({ $0.width > 0 }).count >= 2 else { return nil }
            let margin = height
            let width = parts.reduce(0) { $0 + $1.advance } + margin * 2
            var pixels = [Float](repeating: 0, count: width * height)
            var pen = margin
            for glyph in parts {
                for y in 0..<height {
                    for i in 0..<glyph.width {
                        let x = pen + glyph.origin + i
                        guard x >= 0, x < width else { continue }
                        pixels[y * width + x] = max(
                            pixels[y * width + x], glyph.pixels[y * glyph.width + i])
                    }
                }
                pen += glyph.advance
            }
            return Mask(width: width, height: height, pixels: pixels)
        }
    }

    let fonts: [Font]

    static let shared: FontAtlas? = Bundle.main
        .url(forResource: "SpineFontAtlas", withExtension: "lzfse")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { FontAtlas(compressed: $0) }

    init?(compressed: Data) {
        guard let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data else {
            return nil
        }
        var reader = Reader(bytes: [UInt8](data))
        guard reader.string(count: 4) == "BWA1", let height = reader.uint16(),
            let characterCount = reader.uint16(),
            let characters = reader.string(count: characterCount).map(Array.init)
        else { return nil }
        var fonts: [Font] = []
        while !reader.isAtEnd {
            guard let nameLength = reader.uint8(), let family = reader.string(count: nameLength),
                let weight = reader.uint16()
            else { return nil }
            var glyphs: [Character: Glyph] = [:]
            for character in characters {
                guard let origin = reader.int16(), let advance = reader.uint16(),
                    let width = reader.uint16(),
                    let pixels = reader.nibbles(count: width * height)
                else { return nil }
                glyphs[character] = Glyph(
                    origin: origin, advance: advance, width: width, pixels: pixels)
            }
            fonts.append(Font(family: family, weight: weight, height: height, glyphs: glyphs))
        }
        self.fonts = fonts
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var isAtEnd: Bool { offset >= bytes.count }

        mutating func uint8() -> Int? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return Int(bytes[offset])
        }

        mutating func uint16() -> Int? {
            guard let low = uint8(), let high = uint8() else { return nil }
            return low | high << 8
        }

        mutating func int16() -> Int? {
            uint16().map { Int(Int16(truncatingIfNeeded: $0)) }
        }

        mutating func string(count: Int) -> String? {
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return String(bytes: bytes[offset..<(offset + count)], encoding: .utf8)
        }

        /// `count` 4-bit values, two per byte, high nibble first, padded to a whole byte.
        mutating func nibbles(count: Int) -> [Float]? {
            let byteCount = (count + 1) / 2
            guard offset + byteCount <= bytes.count else { return nil }
            var values: [Float] = []
            values.reserveCapacity(count)
            for index in 0..<count {
                let byte = bytes[offset + index / 2]
                values.append(Float(index % 2 == 0 ? byte >> 4 : byte & 15) / 15)
            }
            offset += byteCount
            return values
        }
    }
}
