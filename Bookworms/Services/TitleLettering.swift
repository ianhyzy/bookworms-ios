import CoreGraphics
import Foundation

/// Measures a cover's title lettering and matches it against the spine font catalog without a
/// language model.
///
/// The title line comes from OCR. Its crop is split into ink and ground with two-means in OKLab;
/// the ground is the cluster that touches the crop's border most. The ink mask gives two
/// measurements that small vision models judge poorly: how wide the letters are for their
/// height, with letter spacing removed, and how much stroke thickness varies. Each catalog
/// family's predicted measurements for the same text come from `SpineFontDescriptors.json`,
/// which `script/spine-font-descriptors.swift` generates from the Google Fonts files, so ranking
/// needs no font downloads.
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
        /// The letters' ink width over ink height, with gaps between letters collapsed.
        let aspect: Double
        /// The spread of horizontal stroke widths relative to their median.
        let strokeSpread: Double
        let ink: ColorValue
        let ground: ColorValue
    }

    /// A family and weight, best match first.
    struct Match: Equatable, Sendable {
        let family: String
        let weight: Int
    }

    /// Measures the tallest OCR line that shares a word with `title`, or the tallest line when
    /// none does. Returns `nil` when the cover has no readable line.
    static func measure(_ image: CGImage, lines: [Line], title: String) -> Measurement? {
        let words = Set(wordsIn(title))
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
        rect =
            rect.insetBy(dx: -rect.height * 0.12, dy: -rect.height * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard let crop = image.cropping(to: rect), let split = split(crop),
            let letters = Mask.lettering(split.mask)
        else { return nil }
        return Measurement(
            text: line.text.trimmingCharacters(in: .whitespaces), crop: crop,
            aspect: letters.aspect, strokeSpread: letters.strokeSpread, ink: split.ink,
            ground: split.ground)
    }

    /// Ranks `families` at regular and bold weight by how closely their predicted measurements
    /// for the title text match the cover's. Scores are z-scored across the whole catalog, so a
    /// subset ranks the same way it would within the catalog. Families without descriptors or
    /// glyphs for the text are left out.
    static func rank(
        _ families: [String], for measurement: Measurement,
        catalog: FontDescriptors? = .shared
    ) -> [Match] {
        guard let catalog else { return [] }
        let isCapitals = measurement.text.filter(\.isLetter).allSatisfy(\.isUppercase)
        var rows: [(match: Match, aspect: Double, contrast: Double)] = []
        for (family, weights) in catalog.fonts {
            for (weight, font) in weights {
                guard let predicted = font.aspect(of: measurement.text) else { continue }
                let spread = isCapitals ? font.spreadCapitals : font.spreadMixed
                rows.append(
                    (
                        Match(family: family, weight: weight),
                        abs(log(predicted / measurement.aspect)),
                        abs(spread - measurement.strokeSpread)
                    ))
            }
        }
        guard rows.count > 1 else { return rows.map(\.match) }
        func standardized(_ values: [Double]) -> [Double] {
            let mean = values.reduce(0, +) / Double(values.count)
            let deviation =
                (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
                .squareRoot()
            return values.map { ($0 - mean) / (deviation > 0 ? deviation : 1) }
        }
        // Width carries most of the signal; stroke contrast separates serif families.
        let aspect = standardized(rows.map(\.aspect))
        let contrast = standardized(rows.map(\.contrast))
        let allowed = Set(families)
        return rows.indices.filter { allowed.contains(rows[$0].match.family) }
            .sorted { lhs, rhs in
                let left = 2 * aspect[lhs] + 0.5 * contrast[lhs]
                let right = 2 * aspect[rhs] + 0.5 * contrast[rhs]
                if left != right { return left < right }
                let (a, b) = (rows[lhs].match, rows[rhs].match)
                return a.family != b.family ? a.family < b.family : a.weight < b.weight
            }
            .map { rows[$0].match }
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
struct Mask {
    var width: Int
    var height: Int
    var pixels: [Float]

    /// The letters' measurements: the band of rows that holds the most ink, so neighboring
    /// lines drop out, with each run of empty columns collapsed to a twelfth of the band's
    /// height so letter spacing does not count as letter width. `script/spine-font-descriptors`
    /// measures rendered fonts the same way.
    static func lettering(_ mask: Mask) -> (aspect: Double, strokeSpread: Double)? {
        guard let letters = mask.band()?.collapsingGaps() else { return nil }
        return (Double(letters.width) / Double(letters.height), letters.strokeSpread)
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

    /// The spread of horizontal ink-run lengths, (90th − 10th percentile) / median, after
    /// box-filtering the mask to a 48-pixel height: near 0 for even strokes, larger for
    /// thick-and-thin faces. Box filtering drops hairlines thinner than a sample, at every size.
    var strokeSpread: Double {
        let targetHeight = 48
        let targetWidth = max(4, width * targetHeight / max(1, height))
        var runs: [Double] = []
        for ty in 0..<targetHeight {
            let y0 = ty * height / targetHeight
            let y1 = max(y0 + 1, (ty + 1) * height / targetHeight)
            var run = 0
            for tx in 0..<targetWidth {
                let x0 = tx * width / targetWidth
                let x1 = max(x0 + 1, (tx + 1) * width / targetWidth)
                var ink: Float = 0
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) { ink += pixels[y * width + x] }
                }
                if ink / Float((y1 - y0) * (x1 - x0)) > 0.5 {
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

/// Per-family measurements generated by `script/spine-font-descriptors.swift`.
struct FontDescriptors: Decodable, Sendable {
    struct Font: Decodable, Sendable {
        /// Per character of `characters`: ink width, ink top, ink bottom, left bearing, and
        /// right bearing, in cap heights from the baseline; `nil` for a missing glyph.
        let glyphs: [[Double]?]
        let spreadCapitals: Double
        let spreadMixed: Double
        /// Filled after decoding from the file's character list.
        var index: [Character: [Double]] = [:]

        enum CodingKeys: String, CodingKey { case glyphs, spreadCapitals, spreadMixed }

        /// The predicted ink width over ink height of `text`, measured as `Mask.lettering`
        /// measures a cover: gaps between letters count up to a twelfth of the height.
        func aspect(of text: String) -> Double? {
            let characters = Array(text)
            let known = characters.compactMap { index[$0] }
            guard known.count >= 2 else { return nil }
            let top = known.map { $0[1] }.max()!
            // Descenders rarely carry enough ink rows to join the measured band.
            let bottom = max(0, known.map { $0[2] }.min()!)
            let height = top - bottom
            guard height > 0 else { return nil }
            var width = known.map { $0[0] }.reduce(0, +)
            for (left, right) in zip(characters, characters.dropFirst()) {
                guard let a = index[left], let b = index[right] else {
                    width += height / 12
                    continue
                }
                width += min(max(0, a[4] + b[3]), height / 12)
            }
            return width / height
        }
    }

    let characters: String
    /// Family name to CSS weight to measurements.
    var fonts: [String: [Int: Font]]

    static let shared: FontDescriptors? = {
        guard let url = Bundle.main.url(forResource: "SpineFontDescriptors", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(FontDescriptors.self, from: data).indexed()
    }()

    func indexed() -> FontDescriptors {
        let characters = Array(self.characters)
        var copy = self
        copy.fonts = fonts.mapValues { weights in
            weights.mapValues { font in
                var font = font
                for (character, glyph) in zip(characters, font.glyphs) {
                    if let glyph { font.index[character] = glyph }
                }
                return font
            }
        }
        return copy
    }

    enum CodingKeys: String, CodingKey { case characters, fonts }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        characters = try container.decode(String.self, forKey: .characters)
        // JSON object keys are strings; weights are integers.
        let raw = try container.decode([String: [String: Font]].self, forKey: .fonts)
        fonts = raw.mapValues { weights in
            Dictionary(
                uniqueKeysWithValues: weights.compactMap { key, font in
                    Int(key).map { ($0, font) }
                })
        }
    }
}
