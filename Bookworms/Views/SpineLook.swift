import CoreText
import Observation
import SwiftUI

extension ColorValue {
    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// WCAG relative luminance, 0 for black through 1 for white.
    var relativeLuminance: Double {
        // Contrast against black is (L + 0.05) / 0.05, so L follows from it.
        contrast(with: ColorValue(red: 0, green: 0, blue: 0)) * 0.05 - 0.05
    }

    func mixed(with other: ColorValue, _ amount: Double) -> ColorValue {
        func channel(_ a: Int, _ b: Int) -> Int {
            Int((Double(a) + (Double(b) - Double(a)) * amount).rounded())
        }
        return ColorValue(
            red: channel(red, other.red), green: channel(green, other.green),
            blue: channel(blue, other.blue))
    }
}

/// A downloaded Google Fonts face, ready to size for SwiftUI text.
struct FontFace: @unchecked Sendable, Equatable {
    // CTFontDescriptor is an immutable Core Foundation type, so sharing it is safe.
    let descriptor: CTFontDescriptor
    let postScriptName: String

    func font(size: CGFloat) -> Font {
        Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.postScriptName == rhs.postScriptName }
}

/// Loads the Google Fonts faces that saved designs name, so spines render in their chosen type.
///
/// Faces load after the library does, not from view bodies. Until a face arrives, spines use the
/// design's system typeface, and they re-render once it loads.
@MainActor
@Observable
final class SpineFonts {
    private(set) var faces: [String: FontFace] = [:]
    @ObservationIgnored private let downloader = GoogleFonts()
    @ObservationIgnored private var attempted = Set<String>()

    func face(for design: SpineDesignV1?) -> FontFace? {
        guard let design, let key = Self.key(design) else { return nil }
        return faces[key]
    }

    /// Loads each missing face one at a time. A face that fails to load is not retried until
    /// the next launch; the spine keeps its system typeface.
    func load(_ designs: some Sequence<SpineDesignV1>) async {
        for design in designs {
            guard let key = Self.key(design), let family = design.fontFamily,
                attempted.insert(key).inserted
            else { continue }
            guard let font = try? await downloader.download(family: family, weight: design.weight)
            else { continue }
            let name = design.fontPostScriptName ?? font.postScriptName
            let descriptors = GoogleFonts.descriptors(at: font.fileURL)
            guard
                let descriptor = descriptors.first(where: {
                    GoogleFonts.postScriptName(of: $0) == name
                }) ?? descriptors.first
            else { continue }
            faces[key] = FontFace(descriptor: descriptor, postScriptName: name)
        }
    }

    private static func key(_ design: SpineDesignV1) -> String? {
        design.fontFamily.map { "\($0):\(design.weight)" }
    }
}

/// The colors and type a spine is drawn with: a saved design, or a quiet fallback before one
/// exists.
struct SpineLook: Equatable, Sendable {
    var background: ColorValue
    var foreground: ColorValue
    var accent: ColorValue
    var face: FontFace?
    var typeface: String
    var weight: Int
    var uppercase: Bool
    var isCondensed: Bool
    /// Whether a model designed this spine. The fallback look is the same for every launch.
    var isGenerated: Bool

    init(book: CloudBook, design: SpineDesignV1?, face: FontFace?) {
        if let design, let background = ColorValue(hex: design.backgroundHex),
            let foreground = ColorValue(hex: design.foregroundHex),
            let accent = ColorValue(hex: design.accentHex)
        {
            self.background = background
            self.foreground = foreground
            self.accent = accent
            self.face = face
            typeface = design.typeface
            weight = design.weight
            uppercase = design.uppercase
            isCondensed =
                design.fontFamily.flatMap(SpineFamily.init(rawValue:))?.style == .condensedSans
            isGenerated = true
            return
        }
        // The Apple TV's fallback cloths, keyed by series so a series shares a color.
        let seed = UInt64(bitPattern: Int64(book.seriesID ?? book.id)) &* 2_654_435_761
        let cloths = [
            ColorValue(red: 46, green: 74, blue: 71), ColorValue(red: 97, green: 51, blue: 41),
            ColorValue(red: 59, green: 71, blue: 99), ColorValue(red: 117, green: 92, blue: 56),
            ColorValue(red: 77, green: 56, blue: 87),
        ]
        background = cloths[Int(seed % 5)]
        foreground = ColorValue(red: 250, green: 240, blue: 212)
        accent = foreground.mixed(with: background, 0.45)
        self.face = nil
        typeface = seed.isMultiple(of: 2) ? "serif" : "sans"
        weight = 600
        uppercase = false
        isCondensed = !seed.isMultiple(of: 2)
        isGenerated = false
    }

    /// The title font at `size`: the downloaded face, else the system design and weight.
    func font(size: CGFloat) -> Font {
        if let face { return face.font(size: size) }
        let design: Font.Design =
            switch typeface {
            case "serif": .serif
            case "rounded": .rounded
            case "monospaced": .monospaced
            default: .default
            }
        let weight: Font.Weight =
            switch self.weight {
            case 700: .bold
            case 600: .semibold
            case 500: .medium
            default: .regular
            }
        return .system(size: size, weight: weight, design: design)
            .width(isCondensed ? .condensed : .standard)
    }

    func text(_ value: String) -> String { uppercase ? value.uppercased() : value }
}
