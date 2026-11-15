import CoreText
import Observation
import SwiftUI

extension ColorValue {
    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
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

    /// Returns whether the face has a glyph for every non-whitespace character in `text`, which
    /// callers pass as it renders.
    func covers(_ text: String) -> Bool {
        let characters = Array(
            String(text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }).utf16)
        guard !characters.isEmpty else { return true }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(
            CTFontCreateWithFontDescriptor(descriptor, 32, nil), characters, &glyphs,
            characters.count)
    }
}

/// Loads the Google Fonts faces that saved designs name, so spines render in their chosen type.
///
/// Faces load after the library does, not from view bodies. Until a face arrives, spines use the
/// design's system typeface, and they re-render once it loads. A design without a family that
/// names an installed face by PostScript name, such as an Apple TV look in Georgia-Bold, uses that
/// face; without it on this device, the design's system typeface.
@MainActor
@Observable
final class SpineFonts {
    private(set) var faces: [String: FontFace] = [:]
    /// The Google Fonts downloader, which the font picker also uses for the catalog and for the
    /// instance a reader's pick names (`AppModel.setFont(_:for:)`).
    @ObservationIgnored let downloader: GoogleFonts
    /// Downloads in progress, shared so every caller waits for the same face.
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    /// Faces whose family or file is unusable. Network failures are not listed, so they retry.
    @ObservationIgnored private var unusable = Set<String>()
    /// Called on the main actor after each face loads, whichever caller started the load.
    @ObservationIgnored var onFaceLoaded: (() -> Void)?

    /// Creates fonts that download with `downloader`. Tests pass one that caches in a folder of
    /// their own.
    init(downloader: GoogleFonts = GoogleFonts()) {
        self.downloader = downloader
    }

    func face(for design: SpineDesignV1?) -> FontFace? {
        guard let design, let key = Self.key(design) else { return nil }
        return faces[key]
    }

    /// Loads each missing face one at a time, trying it once however many of `designs` name it,
    /// and returns when all of them have loaded or failed, or when the calling task is
    /// cancelled.
    ///
    /// A face another caller is already downloading is awaited, not skipped, so a share image
    /// never renders before its fonts arrive. Each download runs in its own task and records
    /// its own result, so a cancelled caller stops waiting at once while the download continues
    /// for others. Otherwise a call waits as long as its downloads take, which is minutes on a
    /// connection that stalls: `GoogleFonts` gives a request 40 seconds without data and sends
    /// it three more times. A caller that can't wait that long sets its own limit, as
    /// `BookFactory.prepare` does. A family that is missing or unusable is not retried until the
    /// next launch; a network failure retries on the next load.
    func load(_ designs: some Sequence<SpineDesignV1>) async {
        var tried = Set<String>()
        for design in designs where !Task.isCancelled {
            guard let key = Self.key(design), tried.insert(key).inserted, faces[key] == nil,
                !unusable.contains(key)
            else { continue }
            guard let family = design.fontFamily else {
                if let face = design.fontPostScriptName.flatMap(Self.installedFace(named:)) {
                    faces[key] = face
                    onFaceLoaded?()
                } else {
                    unusable.insert(key)
                }
                continue
            }
            await wait(
                for: loads[key]
                    ?? download(
                        family: family, weight: design.weight,
                        postScriptName: design.fontPostScriptName, key: key))
        }
    }

    /// Returns `family`'s face at `weight` for lettering that belongs to no spine, such as a
    /// share card's handwriting, loading it first as `load(_:)` does, or `nil` when it can't
    /// load or the calling task is cancelled.
    func face(family: String, weight: Int) async -> FontFace? {
        let key = "\(family):\(weight)"
        if faces[key] == nil, !unusable.contains(key) {
            await wait(
                for: loads[key]
                    ?? download(family: family, weight: weight, postScriptName: nil, key: key))
        }
        return faces[key]
    }

    /// `family`'s face at `weight` if it has already loaded (`face(family:weight:)`), else `nil`.
    func loadedFace(family: String, weight: Int) -> FontFace? { faces["\(family):\(weight)"] }

    /// Returns `family`'s upright face at `weight` for a preview, such as a row of the font
    /// picker, or `nil` when it can't download. Unlike `face(family:weight:)`, it keeps no face,
    /// so previewing many families neither grows `faces` nor redraws the spines that read it.
    func previewFace(family: String, weight: Int) async -> FontFace? {
        if let face = loadedFace(family: family, weight: weight) { return face }
        guard let font = try? await downloader.download(family: family, weight: weight) else {
            return nil
        }
        return await Self.uprightFace(of: font, preferring: nil)
    }

    /// Waits for `task` until it finishes or the calling task is cancelled.
    private func wait(for task: Task<Void, Never>) async {
        // Awaiting the task itself would ignore cancellation; the stream's iteration ends when
        // the download finishes or the caller is cancelled.
        let (finished, finish) = AsyncStream.makeStream(of: Never.self)
        Task {
            await task.value
            finish.finish()
        }
        for await _ in finished {}
    }

    /// Starts downloading `family`'s face at `weight`, preferring the instance named
    /// `postScriptName`, and records the result under `key` when it ends.
    private func download(family: String, weight: Int, postScriptName: String?, key: String)
        -> Task<Void, Never>
    {
        let task = Task { [downloader] in
            do {
                let font = try await downloader.download(family: family, weight: weight)
                if let face = await Self.uprightFace(of: font, preferring: postScriptName) {
                    faces[key] = face
                    onFaceLoaded?()
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

    /// The upright face in `font`'s file, preferring the instance named `postScriptName`, or
    /// `nil`. A face with the italic trait or a slant never renders, whatever its name says.
    /// It reads and parses the file off the main actor, where the loading task resumes at once
    /// when the file was already downloaded.
    @concurrent nonisolated private static func uprightFace(
        of font: DownloadedFont, preferring postScriptName: String?
    ) async -> FontFace? {
        guard
            let descriptor = GoogleFonts.uprightDescriptor(
                preferring: [postScriptName, font.postScriptName],
                in: GoogleFonts.descriptors(at: font.fileURL))
        else { return nil }
        return FontFace(
            descriptor: descriptor,
            postScriptName: FontFiles.postScriptName(of: descriptor) ?? font.postScriptName)
    }

    /// The face's key: the family and weight, or the PostScript name of an installed face.
    private static func key(_ design: SpineDesignV1) -> String? {
        design.fontFamily.map { "\($0):\(design.weight)" } ?? design.fontPostScriptName
    }

    /// The upright face installed on this device under the PostScript name `name`, or `nil`.
    nonisolated static func installedFace(named name: String) -> FontFace? {
        // Core Text substitutes another face for a missing name, so the name must match.
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let descriptor = CTFontCopyFontDescriptor(font)
        guard CTFontCopyPostScriptName(font) as String == name, FontFiles.isUpright(descriptor)
        else { return nil }
        return FontFace(descriptor: descriptor, postScriptName: name)
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
        // The Apple TV's fallback cloths and faces (`SpineStyle.fallback`), keyed by series so a
        // series shares a color: Georgia Bold or Avenir Next Condensed Demi Bold.
        let seed = UInt64(bitPattern: Int64(book.seriesID ?? book.id)) &* 2_654_435_761
        background = PlainSpine.cloths[Int(seed % 5)]
        foreground = ColorValue(red: 250, green: 240, blue: 212)
        accent = foreground.mixed(with: background, 0.45)
        self.face = nil
        typeface = seed.isMultiple(of: 2) ? "serif" : "sans"
        weight = seed.isMultiple(of: 2) ? 700 : 600
        uppercase = false
        isCondensed = !seed.isMultiple(of: 2)
    }

    /// The title font at `size`: the downloaded face, else the system design and weight.
    func font(size: CGFloat) -> Font { Font(coreTextFont(size: size)) }

    /// `font(size:)` as a Core Text font, which `SpineLettering` measures with, so a spine
    /// draws in the font it was measured in.
    func coreTextFont(size: CGFloat) -> CTFont {
        if let face { return CTFontCreateWithFontDescriptor(face.descriptor, size, nil) }
        if typeface == "serif" { return Self.systemSerif(size: size, weight: weight) }
        let sans = UIFont.systemFont(
            ofSize: size, weight: Self.systemWeight(weight),
            width: isCondensed ? .condensed : .standard)
        let design: UIFontDescriptor.SystemDesign? =
            switch typeface {
            case "rounded": .rounded
            case "monospaced": .monospaced
            default: nil
            }
        guard let design, let descriptor = sans.fontDescriptor.withDesign(design) else {
            return sans as CTFont
        }
        return CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, size, nil)
    }

    /// What tells this look's font from another's: the downloaded face, else the system design,
    /// weight, and width.
    var fontKey: String { face?.postScriptName ?? "\(typeface):\(weight):\(isCondensed)" }

    private static func systemWeight(_ weight: Int) -> UIFont.Weight {
        switch weight {
        case 700: .bold
        case 600: .semibold
        case 500: .medium
        default: .regular
        }
    }

    /// The system serif, New York, at `weight`, which falls back to the system sans's faces for
    /// characters it lacks. New York's own fallback for Japanese and Chinese is a light Mincho on
    /// iPhone and Mac; the sans's is a Gothic at the spine's weight, which the Apple TV draws.
    static func systemSerif(size: CGFloat, weight: Int) -> CTFont {
        let sans = UIFont.systemFont(ofSize: size, weight: systemWeight(weight))
        let serif = sans.fontDescriptor.withDesign(.serif) ?? sans.fontDescriptor
        let cascade = CTFontCopyDefaultCascadeListForLanguages(sans as CTFont, nil)
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            serif as CTFontDescriptor,
            [kCTFontCascadeListAttribute: cascade as Any] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    func text(_ value: String) -> String { uppercase ? value.uppercased() : value }
}
