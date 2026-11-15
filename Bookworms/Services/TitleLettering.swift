import CoreGraphics
import Foundation

/// Measures a cover's title lettering and matches it against the spine font atlas without a
/// language model.
///
/// The title line comes from OCR. Its crop is split into ink and ground with two-means in OKLab;
/// the ground is the cluster that touches the crop's border most. Every atlas family's version
/// of the same text is composed from `SpineFontAtlas.lzfse`, small glyph images that
/// `script/spine-font-atlas.swift` renders from the Google Fonts files, so ranking needs no font
/// downloads. Families are compared on five measurements that small vision models judge
/// poorly: letter shapes, letter width for their height with letter spacing removed, how much
/// stroke thickness varies, stroke weight, and how thick the horizontal strokes are.
enum TitleLettering {
    /// An OCR line with its normalized Vision bounding box (origin at the bottom left).
    struct Line: Sendable {
        let text: String
        let box: CGRect
        /// Vision's corners of the line's quadrilateral, normalized like `box`: bottom left,
        /// bottom right, top right, then top left. Without them the line counts as level.
        var corners: [CGPoint]? = nil
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
        /// The share of the OCR line's width that the measured letters span, or `nil` when not
        /// measured. Well under 1 means the ink mask lost letters that OCR read, such as the
        /// second color of a two-color title or a gray byline (`isPlausible(_:composed:)`).
        var inkSpan: Double? = nil
    }

    /// A family and weight, best match first.
    struct Match: Equatable, Sendable {
        let family: String
        let weight: Int
    }

    /// The atlas fonts' versions of a text (`composedProfiles(of:atlas:)`).
    typealias Composed = [(font: FontAtlas.Font, profile: Mask.Profile)]

    /// The lightest title weight a ranked family gets. Thin strokes read badly at spine size,
    /// where `SpineView` sizes the title to the spine's thickness, so a design is never lighter
    /// than semibold even when the cover's lettering is. Many families have no medium (500)
    /// instance, and the nearest instance to 500 would be their regular.
    static let minimumWeight = 600

    /// Measures the tallest measurable OCR line (`listed(_:in:)`) that shares a word with
    /// `title`, or the tallest one when none does, as `measure(_:line:atlas:)` measures it.
    /// Returns `nil` when the cover has no measurable line.
    static func measure(
        _ image: CGImage, lines: [Line], title: String, atlas: FontAtlas? = .shared
    ) -> Measurement? {
        let words = Set(wordsIn(title))
        let framed = framed(lines, in: image)
        let titled = framed.filter { !Set(wordsIn($0.line.text)).isDisjoint(with: words) }
        guard
            let line = (titled.isEmpty ? framed : titled)
                .max(by: { $0.frame.thickness < $1.frame.thickness })?
                .line
        else { return nil }
        return measure(image, line: line, atlas: atlas)
    }

    /// The lines a model may choose the title from: the 16 tallest measurable lines, top to
    /// bottom. A line set vertically, whose box is taller than it is wide, is left out: its
    /// letters stack, so the line's width says nothing about theirs. So is a line turned more
    /// than 45 degrees.
    static func listed(_ lines: [Line], in image: CGImage) -> [Line] {
        framed(lines, in: image).sorted { $0.frame.thickness > $1.frame.thickness }.prefix(16)
            .sorted { $0.frame.center.y < $1.frame.center.y }.map(\.line)
    }

    private static func framed(_ lines: [Line], in image: CGImage) -> [(line: Line, frame: Frame)] {
        lines.map {
            (line: $0, frame: Frame($0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        .filter { $0.frame.length > $0.frame.thickness && abs($0.frame.angle) <= .pi / 4 }
    }

    /// How a line turned by `angle` radians changes when its image scales by `scaleX` and
    /// `scaleY`: the factors its length and its thickness scale by, and its new angle. Unequal
    /// scales turn the line, so its thickness is measured across the new direction: the scaling
    /// multiplies the line's area by `scaleX * scaleY`, which the new length divides.
    static func scaling(
        angle: Double, scaleX: Double, scaleY: Double
    ) -> (length: Double, thickness: Double, angle: Double) {
        let (cosine, sine) = (cos(angle), sin(angle))
        let length = hypot(scaleX * cosine, scaleY * sine)
        return (length, scaleX * scaleY / length, atan2(scaleY * sine, scaleX * cosine))
    }

    /// Measures the lettering of `line`, which `listed(_:in:)` includes. A tilted line is
    /// measured level: its ink mask turns about the line's center by the angle of Vision's
    /// quadrilateral, because the upright box of a tilted line is taller than its letters and
    /// would measure them too narrow. Returns `nil` when the line's crop yields no letters.
    ///
    /// When more than `maximumInkShare` of the padded crop splits as ink, the split may have
    /// taken the letters for ground, as when cover art at the crop's edges shares the letters'
    /// colors. Heavy lettering and busy art also fill a crop, so ink and ground swap only when
    /// all of these hold:
    /// - The padding around the OCR box is nearly as inky as the box, at least three quarters
    ///   as much, as when the cover's ground was taken for ink. Letters concentrate ink inside
    ///   the box.
    /// - The swapped mask could be set in some face the app uses (`isPlausible(_:composed:)`
    ///   against the faces outside `SpineFamily.neverGenerated`).
    /// - The swapped mask matches the nearest such face's letter shapes more closely than the
    ///   split as found.
    static func measure(
        _ image: CGImage, line: Line, atlas: FontAtlas? = .shared
    ) -> Measurement? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let frame = Frame(line, width: width, height: height)
        // Vision's box is normalized with a bottom-left origin; CGImage cropping is top-left.
        var rect = CGRect(
            x: line.box.minX * width, y: (1 - line.box.maxY) * height,
            width: line.box.width * width, height: line.box.height * height)
        let box = rect
        rect =
            rect.insetBy(dx: -rect.height * 0.12, dy: -rect.height * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard let crop = image.cropping(to: rect), let found = split(crop) else { return nil }
        func measured(
            _ split: (mask: Mask, ink: ColorValue, ground: ColorValue)
        ) -> Measurement? {
            // The padding keeps the colors' border clear of the letters, but a line or picture
            // just above or below can touch the title's rows and join its band, which makes the
            // lettering look taller and narrower than it is. Only the line's own rows, with a
            // little slack for strokes Vision trims, are measured.
            var mask = split.mask
            // The mask's 8-pixel minimum (`split(_:)`) can scale its axes apart.
            let scaleX = Double(split.mask.width) / Double(crop.width)
            let scaleY = Double(split.mask.height) / Double(crop.height)
            let rows: Range<Int>
            let lineWidth: Double
            if frame.angle == 0 {
                lineWidth = box.width * scaleX
                let slack = box.height * 0.06
                let top = Int(((box.minY - rect.minY - slack) * scaleY).rounded(.down))
                let bottom = Int(((box.maxY - rect.minY + slack) * scaleY).rounded(.up))
                guard top < bottom else { return nil }
                rows = top..<bottom
            } else {
                let (lengthScale, thicknessScale, angle) = scaling(
                    angle: frame.angle, scaleX: scaleX, scaleY: scaleY)
                mask = mask.leveled(
                    angle: angle,
                    center: CGPoint(
                        x: (frame.center.x - rect.minX) * scaleX,
                        y: (frame.center.y - rect.minY) * scaleY),
                    length: frame.length * lengthScale,
                    thickness: frame.thickness * thicknessScale)
                lineWidth = frame.length * lengthScale
                let slack = frame.thickness * thicknessScale * 0.06
                let middle = Double(mask.height) / 2
                let half = frame.thickness * thicknessScale / 2 + slack
                rows = Int((middle - half).rounded(.down))..<Int((middle + half).rounded(.up))
            }
            let kept = mask.keepingRows(rows)
            guard let profile = kept.profile() else { return nil }
            return Measurement(
                text: line.text.trimmingCharacters(in: .whitespaces), crop: crop, profile: profile,
                ink: split.ink, ground: split.ground,
                inkSpan: kept.band()?.trimmed().map { Double($0.width) / max(1, lineWidth) })
        }
        guard let measurement = measured(found) else { return nil }
        // Ink inside the OCR box and in the padding around it, in mask pixels.
        let scaleX = Double(found.mask.width) / Double(crop.width)
        let scaleY = Double(found.mask.height) / Double(crop.height)
        let inside = CGRect(
            x: (box.minX - rect.minX) * scaleX, y: (box.minY - rect.minY) * scaleY,
            width: box.width * scaleX, height: box.height * scaleY)
        var ink: (inside: Float, around: Float) = (0, 0)
        var count: (inside: Float, around: Float) = (0, 0)
        for y in 0..<found.mask.height {
            for x in 0..<found.mask.width {
                let value = found.mask.pixels[y * found.mask.width + x]
                if inside.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    (ink.inside, count.inside) = (ink.inside + value, count.inside + 1)
                } else {
                    (ink.around, count.around) = (ink.around + value, count.around + 1)
                }
            }
        }
        let share = (ink.inside + ink.around) / max(1, count.inside + count.around)
        guard share > maximumInkShare,
            ink.around / max(1, count.around) >= ink.inside / max(1, count.inside) * 0.75,
            let swapped = measured(
                (
                    Mask(
                        width: found.mask.width, height: found.mask.height,
                        pixels: found.mask.pixels.map { 1 - $0 }),
                    found.ground, found.ink
                ))
        else { return measurement }
        let never = Set(SpineFamily.neverGenerated.map(\.rawValue))
        let usable = composedProfiles(of: measurement.text, atlas: atlas)
            .filter { !never.contains($0.font.family) }
        func nearestShape(_ candidate: Measurement) -> Double {
            usable.map { $0.profile.shapeDifference(from: candidate.profile) }.min() ?? .infinity
        }
        return isPlausible(swapped, composed: usable)
            && nearestShape(swapped) < nearestShape(measurement) ? swapped : measurement
    }

    /// The share of a title crop's split, padding included, above which the split may have
    /// taken the letters for ground (`measure(_:line:atlas:)`). Letters usually fill
    /// under half of a crop padded by 12 percent of the line's height on each side; an inverted
    /// split, such as one that took a cover's sky for ink, fills most of it.
    static let maximumInkShare: Float = 0.55

    /// An OCR line's position in image pixels with a top-left origin: its center, the angle of
    /// its baseline in radians (negative for a line that rises to the right), and its length
    /// and thickness along and across the baseline.
    ///
    /// A line without corners, or one tilted less than a degree, counts as level, with its
    /// box's center and size.
    private struct Frame {
        var center: CGPoint
        var angle: Double
        var length: Double
        var thickness: Double

        init(_ line: Line, width: CGFloat, height: CGFloat) {
            center = CGPoint(x: line.box.midX * width, y: (1 - line.box.midY) * height)
            angle = 0
            length = line.box.width * width
            thickness = line.box.height * height
            guard let corners = line.corners, corners.count == 4 else { return }
            let points = corners.map { CGPoint(x: $0.x * width, y: (1 - $0.y) * height) }
            let (bottomLeft, bottomRight, topRight, topLeft) =
                (points[0], points[1], points[2], points[3])
            let tilt = atan2(bottomRight.y - bottomLeft.y, bottomRight.x - bottomLeft.x)
            guard abs(tilt) >= .pi / 180 else { return }
            center = CGPoint(
                x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
            angle = tilt
            length = hypot(bottomRight.x - bottomLeft.x, bottomRight.y - bottomLeft.y)
            thickness =
                (hypot(topLeft.x - bottomLeft.x, topLeft.y - bottomLeft.y)
                    + hypot(topRight.x - bottomRight.x, topRight.y - bottomRight.y)) / 2
        }
    }

    /// Whether a measurement could be the line's text set in some face: its letters span at
    /// least three quarters of the OCR line's width, and it is at least 85 percent as wide for
    /// its height as the narrowest of the atlas's versions of the text (`composed`).
    ///
    /// A mask that lost letters, such as one color of a two-color title or a gray byline that
    /// OCR read with the title, spans part of the line and measures far narrower than the text
    /// set in any face. Ranking it would pick the narrowest face for lettering that isn't narrow.
    /// Lettering wider than every face stays plausible: widely set letters, such as an extended
    /// sans, measure that way, and the widest faces suit them.
    static func isPlausible(_ measurement: Measurement, composed: Composed) -> Bool {
        guard let narrowest = composed.map(\.profile.aspect).min() else { return false }
        return (measurement.inkSpan ?? 1) >= 0.75
            && measurement.profile.aspect >= narrowest * 0.85
    }

    /// Ranks `families` by how closely the measured lettering matches the same text composed
    /// from each family's regular and bold glyphs, one match per family. Each measurement is
    /// z-scored across the whole atlas, so a subset ranks the same way it would within the
    /// atlas. A family's `penalties` entry adds to its score, so a family that the model's
    /// reading of the cover argues against needs a closer match to rank first. Families without
    /// glyphs for the text are left out.
    ///
    /// Horizontal stroke thickness (`Mask.Profile.crossStroke`) separates faces of the same
    /// width and stem weight, such as hairline didones, bracketed book serifs, slabs, and even
    /// sans, which width alone would give to whichever allowed face is narrowest.
    ///
    /// A family whose heaviest version of the text has less than three quarters of the
    /// lettering's ink density (`Mask.Profile.density`) is left out, so a bold title never gets
    /// a face too light to match it, such as a single-weight display face. When no allowed
    /// family is that heavy, they all stay.
    ///
    /// Stroke weight is matched against the lettering's own, but never against less than the
    /// atlas's median regular weight for the text: a design is never lighter than
    /// `minimumWeight`, so a thin title gets a face that is regular at its lightest. A family's
    /// weight is then interpolated between its regular and bold glyphs
    /// (`weight(regular:bold:cover:)`). A measurement that no face could produce
    /// (`isPlausible(_:composed:)`) ranks nothing.
    ///
    /// `composed` is the shared atlas's versions of the measurement's text, which it composes
    /// when the caller hasn't (`composedProfiles(of:atlas:)`).
    static func rank(
        _ families: [String], for measurement: Measurement, composed: Composed? = nil,
        penalties: [String: Double] = [:]
    ) -> [Match] {
        let cover = measurement.profile
        let composed = composed ?? composedProfiles(of: measurement.text)
        guard isPlausible(measurement, composed: composed) else { return [] }
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
                    abs(log(profile.strokeWeight / stroke)),
                    abs(log(profile.crossStroke / cover.crossStroke)),
                ]
            )
        }
        // Width carries most of the signal; stroke weight keeps a heavy title out of hairline
        // faces of the same width, horizontal stroke thickness tells contrast and serif styles
        // apart, and shape and stroke spread separate the rest. The weights scored best on 57
        // covers from the owner's library that a Claude session labeled (`.local/spine-eval`),
        // so those scores are a regression check, not the owner's taste.
        let weights = [0.25, 2, 0.25, 1, 1]
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
        var heaviest: [String: Double] = [:]
        for (font, profile) in composed {
            heaviest[font.family] = max(heaviest[font.family] ?? 0, profile.density)
        }
        let heavyEnough = Set(families).filter { heaviest[$0] ?? 0 >= cover.density * 0.75 }
        let allowed = heavyEnough.isEmpty ? Set(families) : heavyEnough
        for index in rows.indices { scores[index] += penalties[rows[index].family] ?? 0 }
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

    /// The most a penalty can add on the width ranking, in percentile points of the atlas's widths.
    static let maximumWidthPenalty = 0.05

    /// Ranks `families` for a title that wasn't measured by how closely `text` set in each comes to
    /// the reading's `width` answer, one match per family. Each family's regular version of the
    /// text is placed among the whole atlas's: "extra condensed" asks for a face narrower than
    /// nearly every atlas face, "condensed" for one narrower than three quarters of them, "normal"
    /// for a median face, and so on. A bold or black `weight` answer sets each family's weight to
    /// 700, any other `minimumWeight`. A family's `penalties` entry, such as its distance from the
    /// reading's moods from 0 to 1, adds a twentieth of itself, so it moves a pick at most 5
    /// percentile points from the width answer, a quarter of the gap between neighboring answers,
    /// and settles only near ties. Families without glyphs for the text, and any answer outside the
    /// reading's widths, rank nothing.
    static func rank(
        _ families: [String], width: String, weight: String?, text: String,
        penalties: [String: Double] = [:], atlas: FontAtlas? = .shared
    ) -> [Match] {
        let targets = [
            "extra condensed": 0.05, "condensed": 0.25, "normal": 0.5, "wide": 0.75,
            "extra wide": 0.95,
        ]
        guard let atlas, let target = targets[width] else { return [] }
        var aspects: [String: Double] = [:]
        for (font, profile) in composedProfiles(of: text, atlas: atlas)
        where aspects[font.family] == nil || font.weight == 400 {
            aspects[font.family] = profile.aspect
        }
        let sorted = aspects.values.sorted()
        let distances = families.compactMap { family -> (family: String, distance: Double)? in
            guard let aspect = aspects[family] else { return nil }
            let below = Double(sorted.filter { $0 < aspect }.count) / Double(sorted.count)
            return (family, abs(below - target) + (penalties[family] ?? 0) * maximumWidthPenalty)
        }
        let bold = weight == "bold" || weight == "black"
        return distances.sorted { ($0.distance, $0.family) < ($1.distance, $1.family) }
            .map { Match(family: $0.family, weight: bold ? 700 : minimumWeight) }
    }

    /// Whether the lettering's strokes are hairlines: under 60 percent of the atlas's median
    /// regular stroke weight for the same text, as an outlined or inline title measures. A
    /// measurement that no face could produce (`isPlausible(_:composed:)`) doesn't count,
    /// because a mask that lost letters or caught a texture measures as hairlines too.
    /// `composed` is as `rank(_:for:composed:penalties:)` takes it.
    static func hasHairlineStrokes(_ measurement: Measurement, composed: Composed? = nil) -> Bool {
        let composed = composed ?? composedProfiles(of: measurement.text)
        return isPlausible(measurement, composed: composed)
            && measurement.profile.strokeWeight < regularStroke(of: composed) * 0.6
    }

    /// Every atlas font's version of `text` that has glyphs for it; none without an atlas.
    ///
    /// It composes and profiles the text in each of the atlas's fonts, the costly part of
    /// matching a title, so a design composes its title once for the checks and the ranking.
    /// Each profile holds a 320 by 48 shape grid of about 60 KB, so callers keep them only
    /// while they match.
    static func composedProfiles(of text: String, atlas: FontAtlas? = .shared) -> Composed {
        guard let atlas else { return [] }
        return atlas.fonts.compactMap { font in
            font.compose(text)?.profile().map { (font: font, profile: $0) }
        }
    }

    /// The median stroke weight of the regular (400) fonts in `composed`, or 0 without any.
    private static func regularStroke(of composed: Composed) -> Double {
        let strokes = composed.filter { $0.font.weight == 400 }.map(\.profile.strokeWeight).sorted()
        return strokes.isEmpty ? 0 : strokes[strokes.count / 2]
    }

    /// The title weight, `minimumWeight` through 700 in steps of 100, whose stroke weight comes
    /// nearest `cover`'s, interpolating between a family's `regular` (400) and `bold` (700) stroke
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
        /// The median vertical ink run shorter than half the line's height, measured on the
        /// 48-pixel grid like `strokeWeight`: about the thickness of the horizontal strokes,
        /// such as crossbars, serifs, and the hairlines of high-contrast faces.
        var crossStroke: Double
        /// The share of the 48-pixel grid's area that is ink, with letter spacing removed:
        /// higher for heavier lettering. Unlike `strokeWeight`, it stays high for condensed bold
        /// letters, whose stems are narrow for their height.
        var density: Double

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
            strokeWeight: natural.strokeWeight, crossStroke: natural.crossStroke,
            density: Double(natural.pixels.reduce(0, +)) / Double(natural.pixels.count))
    }

    /// The part of the mask around a line at `angle` radians (top-left origin), turned level:
    /// a mask `length` wide and `thickness` tall plus 12 percent of the thickness on each side,
    /// whose center is the line's `center`. Pixels from outside the mask are blank.
    func leveled(angle: Double, center: CGPoint, length: Double, thickness: Double) -> Mask {
        let pad = thickness * 0.12
        let outWidth = max(1, Int((length + pad * 2).rounded()))
        let outHeight = max(1, Int((thickness + pad * 2).rounded()))
        let (cosine, sine) = (cos(angle), sin(angle))
        var out = [Float](repeating: 0, count: outWidth * outHeight)
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                let dx = Double(x) - Double(outWidth) / 2
                let dy = Double(y) - Double(outHeight) / 2
                let sourceX = Int((center.x + cosine * dx - sine * dy).rounded(.down))
                let sourceY = Int((center.y + sine * dx + cosine * dy).rounded(.down))
                guard (0..<width).contains(sourceX), (0..<height).contains(sourceY) else {
                    continue
                }
                out[y * outWidth + x] = pixels[sourceY * width + sourceX]
            }
        }
        return Mask(width: outWidth, height: outHeight, pixels: out)
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

    /// Vertical ink runs that span fewer pixels than half the height are horizontal strokes;
    /// longer ones are stems and bowls. A stroke measures its summed ink, as `strokeWeight`
    /// does.
    private var crossStroke: Double {
        var runs: [Double] = []
        for x in 0..<width {
            var (length, ink) = (0, 0.0)
            for y in 0...height {
                let value = y < height ? Double(pixels[y * width + x]) : 0
                if value > 0.2 {
                    length += 1
                    ink += value
                } else if length > 0 {
                    if length * 2 < height { runs.append(ink) }
                    (length, ink) = (0, 0)
                }
            }
        }
        runs.sort()
        guard !runs.isEmpty else { return 0.5 / Double(max(1, height)) }
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

/// Glyph images of every catalog family and every Google Fonts family that passes the filter in
/// `script/spine-font-atlas.swift`, at regular and, where the family has a heavier file, bold
/// weight.
///
/// The file is LZFSE-compressed. Decompressed, it holds little-endian fields: the magic
/// `BWA3`, the glyph height, and the UTF-8 character list; then, per font, its family name, CSS
/// weight, and, per character, the glyph's ink origin from the pen position, its advance, its
/// ink width, and its pixels at 4 bits each, row by row from the top. The pixels stay packed in
/// memory, about 21 MB for the whole atlas, and decode as fonts compose text.
struct FontAtlas: Sendable {
    struct Glyph: Sendable {
        var origin: Int
        var advance: Int
        var width: Int
        /// Where the glyph's packed pixels start in `Font.pixels`.
        var offset: Int
    }

    struct Font: Sendable {
        let family: String
        let weight: Int
        let height: Int
        let glyphs: [Character: Glyph]
        /// The decompressed atlas, which every font shares.
        let pixels: [UInt8]

        /// `text` laid out by advances, without kerning; `nil` when fewer than two of its
        /// characters have glyphs.
        func compose(_ text: String) -> Mask? {
            let parts = text.compactMap { glyphs[$0] }
            guard parts.filter({ $0.width > 0 }).count >= 2 else { return nil }
            let margin = height
            let width = parts.reduce(0) { $0 + $1.advance } + margin * 2
            var out = [Float](repeating: 0, count: width * height)
            var pen = margin
            for glyph in parts {
                for y in 0..<height {
                    for i in 0..<glyph.width {
                        let x = pen + glyph.origin + i
                        guard x >= 0, x < width else { continue }
                        let index = y * glyph.width + i
                        let byte = pixels[glyph.offset + index / 2]
                        let value = Float(index % 2 == 0 ? byte >> 4 : byte & 15) / 15
                        out[y * width + x] = max(out[y * width + x], value)
                    }
                }
                pen += glyph.advance
            }
            return Mask(width: width, height: height, pixels: out)
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
        let bytes = [UInt8](data)
        var reader = Reader(bytes: bytes)
        guard reader.string(count: 4) == "BWA3", let height = reader.uint16(),
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
                    let offset = reader.skip(count: (width * height + 1) / 2)
                else { return nil }
                glyphs[character] = Glyph(
                    origin: origin, advance: advance, width: width, offset: offset)
            }
            fonts.append(
                Font(
                    family: family, weight: weight, height: height,
                    glyphs: glyphs, pixels: bytes))
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

        /// Skips `count` bytes and returns where they start.
        mutating func skip(count: Int) -> Int? {
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return offset
        }
    }
}
