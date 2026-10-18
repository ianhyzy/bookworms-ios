import Foundation

extension SpineFamily {
    /// The family that replaces Impact in a saved design.
    ///
    /// Bebas Neue is a heavy condensed sans in Impact's role. Google Fonts serves it, and tvOS
    /// ships it as a system font, so every Bookworms app uses the same replacement.
    static let impactReplacement = SpineFamily.bebasNeue

    /// Stand-ins, keyed by lowercased name without spaces, for catalog families that slant by
    /// design without declaring it: the allowed decorative or hand-drawn family nearest in weight
    /// and role. Kalam, Caveat, and Permanent Marker declare no slant, but their letters lean
    /// too, so new designs never use them (`SpineFamily.neverGenerated`).
    static let slantedReplacements: [String: SpineFamily] = [
        "bangers": .bungee, "shrikhand": .changaOne, "dancingscript": .kalam,
        "pacifico": .permanentMarker, "satisfy": .caveat, "greatvibes": .caveat,
        "lobster": .permanentMarker, "courgette": .kalam, "homemadeapple": .caveat,
        "rocksalt": .permanentMarker,
    ]

    /// The allowed upright family that a saved design shows in place of `family`, which the type
    /// rules block (`BookAnalyzer.allowsFamily`), or `nil` for the design's system typeface.
    ///
    /// | Saved family | Shown as |
    /// | --- | --- |
    /// | Impact, in any spelling | Bebas Neue (`impactReplacement`) |
    /// | Bangers | Bungee |
    /// | Shrikhand | Changa One |
    /// | Dancing Script, Pacifico, or another slanted script | Kalam, Caveat, or Permanent Marker |
    /// | An italic, oblique, or slanted variant, such as "Lora Italic" | Its upright family, Lora |
    /// | Anything else blocked | `nil` |
    ///
    /// Names match without spaces, so a PostScript name's family, such as "DancingScript", maps
    /// as its catalog family does.
    static func uprightReplacement(for family: String) -> String? {
        if family.lowercased().contains("impact") { return impactReplacement.rawValue }
        let upright = family.split(whereSeparator: \.isWhitespace)
            .filter { !["italic", "oblique", "slanted"].contains($0.lowercased()) }
            .joined(separator: " ")
        let key = upright.lowercased().filter { !$0.isWhitespace }
        if let mapped = slantedReplacements[key] { return mapped.rawValue }
        guard !upright.isEmpty, BookAnalyzer.allowsFamily(upright) else { return nil }
        return allCases.first { $0.rawValue.lowercased().filter { !$0.isWhitespace } == key }?
            .rawValue ?? upright
    }
}

extension SpineDesignV1 {
    /// The design as readers show it, in an allowed upright face.
    ///
    /// When the family or PostScript name is blocked (`BookAnalyzer.allowsFamily`), such as
    /// Impact, Bangers, or an italic face in a design another app saved, the family becomes
    /// `SpineFamily.uprightReplacement(for:)` and the PostScript name and instance weight clear,
    /// so `GoogleFonts` picks the upright instance nearest `weight`. A blocked PostScript name
    /// beside an allowed family, such as "Lora-Italic" with Lora, keeps the family. Without a
    /// family, a blocked PostScript name takes the catalog's upright stand-in for the name's
    /// family, such as Kalam for "DancingScript-Bold", as the Apple TV app draws it; outside the
    /// catalog, the design's system typeface. `SpineFonts` also rejects a loaded face with the
    /// italic trait or a slant.
    ///
    /// Only the in-memory copy changes, so the stored record and its wire format stay as written.
    var withAllowedFont: SpineDesignV1 {
        let names = [fontFamily, fontPostScriptName].compactMap { $0 }
        guard !names.allSatisfy(BookAnalyzer.allowsFamily) else { return self }
        var design = self
        if names.contains(where: { $0.lowercased().contains("impact") }) {
            design.fontFamily = SpineFamily.impactReplacement.rawValue
        } else if let family = fontFamily {
            design.fontFamily =
                BookAnalyzer.allowsFamily(family)
                ? family : SpineFamily.uprightReplacement(for: family)
        } else if let name = fontPostScriptName {
            // A PostScript name starts with its family, without spaces, before any "-".
            design.fontFamily =
                SpineFamily.uprightReplacement(for: String(name.prefix { $0 != "-" }))
                .flatMap(SpineFamily.init(rawValue:))?
                .rawValue
        }
        design.fontPostScriptName = nil
        design.instanceWeight = nil
        return design
    }
}
