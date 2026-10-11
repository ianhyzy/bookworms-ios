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
    /// Downloads in progress, shared so every caller waits for the same face.
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    /// Faces whose family or file is unusable. Network failures are not listed, so they retry.
    @ObservationIgnored private var unusable = Set<String>()

    func face(for design: SpineDesignV1?) -> FontFace? {
        guard let design, let key = Self.key(design) else { return nil }
        return faces[key]
    }

    /// Loads each missing face one at a time and returns when all of them have loaded or failed,
    /// or when the calling task is cancelled.
    ///
    /// A face another caller is already downloading is awaited, not skipped, so a share image
    /// never renders before its fonts arrive. Each download runs in its own task and records
    /// its own result, so a cancelled caller stops waiting at once while the download continues
    /// for others. Otherwise a call waits as long as its downloads take; `GoogleFonts` gives up
    /// on a request after 40 seconds without data. A family that is missing or unusable is not
    /// retried until the next launch; a network failure retries on the next load.
    func load(_ designs: some Sequence<SpineDesignV1>) async {
        for design in designs where !Task.isCancelled {
            guard let key = Self.key(design), let family = design.fontFamily, faces[key] == nil,
                !unusable.contains(key)
            else { continue }
            let task = loads[key] ?? download(family: family, design: design, key: key)
            // Awaiting the task itself would ignore cancellation; the stream's iteration ends
            // when the download finishes or the caller is cancelled.
            let (finished, finish) = AsyncStream.makeStream(of: Never.self)
            Task {
                await task.value
                finish.finish()
            }
            for await _ in finished {}
        }
    }

    /// Starts downloading `design`'s face and records the result under `key` when it ends.
    private func download(family: String, design: SpineDesignV1, key: String) -> Task<Void, Never> {
        let task = Task { [downloader] in
            do {
                let font = try await downloader.download(family: family, weight: design.weight)
                let name = design.fontPostScriptName ?? font.postScriptName
                let descriptors = GoogleFonts.descriptors(at: font.fileURL)
                if let descriptor =
                    descriptors.first(where: { GoogleFonts.postScriptName(of: $0) == name })
                    ?? descriptors.first
                {
                    faces[key] = FontFace(descriptor: descriptor, postScriptName: name)
                } else {
                    unusable.insert(key)
                }
            } catch is CompanionError {
                unusable.insert(key)
            } catch {}
            loads[key] = nil
        }
        loads[key] = task
        return task
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
