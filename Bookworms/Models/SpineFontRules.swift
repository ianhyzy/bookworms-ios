import Foundation

extension SpineFamily {
    /// The family that replaces Impact in a saved design.
    ///
    /// Bebas Neue is a heavy condensed sans in Impact's role. Google Fonts serves it, and tvOS
    /// ships it as a system font, so every Bookworms app uses the same replacement.
    static let impactReplacement = SpineFamily.bebasNeue

    /// Upright stand-ins, keyed by lowercased name, for catalog families that slant by design
    /// without declaring it: the allowed decorative or hand-drawn family nearest in weight and
    /// role.
    static let slantedReplacements: [String: SpineFamily] = [
        "bangers": .bungee, "shrikhand": .changaOne, "dancing script": .kalam,
        "pacifico": .permanentMarker, "satisfy": .caveat, "great vibes": .caveat,
        "lobster": .permanentMarker, "courgette": .kalam, "homemade apple": .caveat,
        "rock salt": .permanentMarker,
    ]

    /// The allowed upright family that a saved design shows in place of `family`, which the type
    /// rules block (`BookAnalyzer.allowsFamily`), or `nil` for the design's system typeface.
    ///
    /// | Saved family | Shown as |
    /// | --- | --- |
    /// | Impact, in any spelling | Bebas Neue (`impactReplacement`) |
    /// | Bangers | Bungee |
    /// | Shrikhand | Changa One |
    /// | Dancing Script, Pacifico, or another slanted script | An upright hand-drawn family |
    /// | An italic, oblique, or slanted variant, such as "Lora Italic" | Its upright family, Lora |
    /// | Anything else blocked | `nil` |
    static func uprightReplacement(for family: String) -> String? {
        if family.lowercased().contains("impact") { return impactReplacement.rawValue }
        let upright = family.split(whereSeparator: \.isWhitespace)
            .filter { !["italic", "oblique", "slanted"].contains($0.lowercased()) }
            .joined(separator: " ")
        if let mapped = slantedReplacements[upright.lowercased()] { return mapped.rawValue }
        guard !upright.isEmpty, BookAnalyzer.allowsFamily(upright) else { return nil }
        return allCases.first { $0.rawValue.lowercased() == upright.lowercased() }?.rawValue
            ?? upright
    }
}

extension SpineDesignV1 {
    /// The design as readers show it, in an allowed upright face.
    ///
    /// When the family or PostScript name is blocked (`BookAnalyzer.allowsFamily`), such as
    /// Impact, Bangers, or an italic face in a design another app saved, the family becomes
    /// `SpineFamily.uprightReplacement(for:)` and the PostScript name and instance weight clear,
    /// so `GoogleFonts` picks the upright instance nearest `weight`. A blocked PostScript name
    /// alone, such as "Lora-Italic", keeps its allowed family. `SpineFonts` also rejects a
    /// loaded face with the italic trait or a slant.
    ///
    /// Only the in-memory copy changes, so the stored record and its wire format stay as written.
    var withAllowedFont: SpineDesignV1 {
        let names = [fontFamily, fontPostScriptName].compactMap { $0 }
        guard !names.allSatisfy(BookAnalyzer.allowsFamily) else { return self }
        var design = self
        design.fontFamily =
            names.contains { $0.lowercased().contains("impact") }
            ? SpineFamily.impactReplacement.rawValue
            : fontFamily.flatMap {
                BookAnalyzer.allowsFamily($0) ? $0 : SpineFamily.uprightReplacement(for: $0)
            }
        design.fontPostScriptName = nil
        design.instanceWeight = nil
        return design
    }
}
