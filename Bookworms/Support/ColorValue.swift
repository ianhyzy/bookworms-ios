import CoreGraphics
import Foundation

struct ColorValue: Hashable, Sendable {
    let red: Int
    let green: Int
    let blue: Int

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        guard Self.isValidHex(hex), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: (value >> 16) & 255, green: (value >> 8) & 255, blue: value & 255)
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    static func isValidHex(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 7 && bytes[0] == 35
            && bytes.dropFirst()
                .allSatisfy { byte in
                    (48...57).contains(byte) || (65...70).contains(byte)
                }
    }

    func contrast(with other: Self) -> Double {
        let upper = max(luminance, other.luminance)
        let lower = min(luminance, other.luminance)
        return (upper + 0.05) / (lower + 0.05)
    }

    private var luminance: Double {
        func linear(_ value: Int) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

enum CoverPalette {
    /// Returns up to six representative cover colors, most common first.
    ///
    /// Clusters a 128-pixel downsample in OKLab with k-means. Initial centers are spread across
    /// the lightness order of the pixels, so the same image always yields the same palette.
    static func sample(_ image: CGImage) throws -> [ColorValue] {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard didDraw else { throw CompanionError.invalidCover }

        // Skip a border where scans and thumbnails often carry frames or edge artifacts.
        var points: [SpineContrast.Lab] = []
        for y in 12..<(side - 12) {
            for x in 12..<(side - 12) {
                let offset = (y * side + x) * 4
                guard pixels[offset + 3] > 200 else { continue }
                points.append(
                    SpineContrast.lab(
                        ColorValue(
                            red: Int(pixels[offset]), green: Int(pixels[offset + 1]),
                            blue: Int(pixels[offset + 2]))))
            }
        }
        guard !points.isEmpty else { throw CompanionError.invalidCover }

        let k = 6
        let byLightness = points.sorted { $0.l < $1.l }
        var centers = (0..<k).map { byLightness[(2 * $0 + 1) * byLightness.count / (2 * k)] }
        var counts = [Int](repeating: 0, count: k)
        for _ in 0..<12 {
            var sums = [(l: Double, a: Double, b: Double)](repeating: (0, 0, 0), count: k)
            counts = [Int](repeating: 0, count: k)
            for point in points {
                let nearest = nearestCenter(to: point, in: centers)
                sums[nearest].l += point.l
                sums[nearest].a += point.a
                sums[nearest].b += point.b
                counts[nearest] += 1
            }
            // An empty cluster keeps its center and is dropped from the result.
            for index in 0..<k where counts[index] > 0 {
                let count = Double(counts[index])
                centers[index] = SpineContrast.Lab(
                    l: sums[index].l / count, a: sums[index].a / count, b: sums[index].b / count)
            }
        }
        let clusters: [(color: ColorValue, count: Int)] = (0..<k).filter { counts[$0] > 0 }
            .map { (SpineContrast.color(centers[$0]), counts[$0]) }
        let ranked = clusters.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs.color.hex < rhs.color.hex
        }
        var seen = Set<ColorValue>()
        return ranked.map(\.color).filter { seen.insert($0).inserted }
    }

    /// Returns a dark and a light ink derived from each palette color, darks first.
    ///
    /// Each ink keeps 60% of its source color's OKLab chroma at a fixed lightness (0.22 or 0.93),
    /// so lettering stays tinted by the cover while reading clearly on a contrasting cloth.
    static func inkCandidates(for palette: [ColorValue]) -> [ColorValue] {
        var seen = Set<ColorValue>()
        let lightnesses: [Double] = [0.22, 0.93]
        return
            lightnesses
            .flatMap { lightness in
                palette.map { color in
                    let lab = SpineContrast.lab(color)
                    return SpineContrast.color(
                        SpineContrast.Lab(l: lightness, a: lab.a * 0.6, b: lab.b * 0.6))
                }
            }
            .filter { seen.insert($0).inserted }
    }

    private static func nearestCenter(
        to point: SpineContrast.Lab, in centers: [SpineContrast.Lab]
    ) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (index, center) in centers.enumerated() {
            let dl = point.l - center.l
            let da = point.a - center.a
            let db = point.b - center.b
            let distance = dl * dl + da * da + db * db
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    static func readableForeground(for background: ColorValue) -> ColorValue {
        let black = ColorValue(red: 0, green: 0, blue: 0)
        let white = ColorValue(red: 255, green: 255, blue: 255)
        return background.contrast(with: black) >= background.contrast(with: white)
            ? black : white
    }

    static func readableAccent(
        for background: ColorValue, proposed: ColorValue, palette: [ColorValue]
    ) -> ColorValue {
        if proposed != background, background.contrast(with: proposed) >= 3.0 {
            return proposed
        }
        // Prefer a real cover color before using a neutral text color.
        let sampled = palette.filter { $0 != background && background.contrast(with: $0) >= 3.0 }
            .sorted { lhs, rhs in
                let left = background.contrast(with: lhs)
                let right = background.contrast(with: rhs)
                return left == right ? lhs.hex < rhs.hex : left > right
            }
        return sampled.first ?? readableForeground(for: background)
    }
}
