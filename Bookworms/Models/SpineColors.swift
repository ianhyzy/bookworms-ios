import Foundation

/// A spine design's cloth, lettering, and accent colors.
struct SpineColors: Hashable, Sendable {
    var background: ColorValue
    var foreground: ColorValue
    var accent: ColorValue

    /// Whether the lettering reaches the 4.5:1 contrast with the cloth that
    /// `SpineDesignV1.validate()` and every reader of the design require.
    var isReadable: Bool { background.contrast(with: foreground) >= 4.5 }
}

/// What a generation run does with a book's saved design.
enum SavedDesignAction: Equatable {
    /// Leaves the saved design in place.
    case keep
    /// Saves this copy of the saved design, which keeps the reader's colors under the book's new
    /// work-item hash, so readers that check the hash, such as the Apple TV, still accept it.
    case save(SpineDesignV1)
    /// Designs the book again.
    case redesign
}

/// Colors the reader chose for a spine, recorded in the design's `provenance`.
///
/// A recolored design keeps its record, work-item and cover hashes, generator version, font, and
/// `generatedAt`, and records the generator's colors in a `provenance` token:
/// `generated-colors:` followed by the background, text, and accent colors as six uppercase
/// hexadecimal digits each, separated by commas, such as
/// `generated-colors:1A2B3C,F4E9D0,C08040`. A space separates the token from any other
/// provenance, such as `series-reuse:12 generated-colors:1A2B3C,F4E9D0,C08040`. The token's
/// presence marks the colors as the reader's; recoloring a design back to the generator's colors
/// removes it.
extension SpineDesignV1 {
    private static let generatedColorsPrefix = "generated-colors:"

    /// The design's colors, or `nil` for a design with an invalid color, which `validate()`
    /// rejects.
    var colors: SpineColors? {
        guard let background = ColorValue(hex: backgroundHex),
            let foreground = ColorValue(hex: foregroundHex), let accent = ColorValue(hex: accentHex)
        else { return nil }
        return SpineColors(background: background, foreground: foreground, accent: accent)
    }

    /// The colors the generator chose, when the reader replaced them; `nil` when the design
    /// shows the generator's colors.
    var generatedColors: SpineColors? {
        guard
            let token = provenance?.split(separator: " ")
                .first(where: { $0.hasPrefix(Self.generatedColorsPrefix) })
        else { return nil }
        let hexes = token.dropFirst(Self.generatedColorsPrefix.count).split(separator: ",")
        guard hexes.count == 3, let background = ColorValue(hex: "#\(hexes[0])"),
            let foreground = ColorValue(hex: "#\(hexes[1])"),
            let accent = ColorValue(hex: "#\(hexes[2])")
        else { return nil }
        return SpineColors(background: background, foreground: foreground, accent: accent)
    }

    /// Returns this design with `colors`, recording the generator's colors in `provenance` so
    /// they can be restored. Colors equal to the generator's remove the record.
    ///
    /// The result fails `validate()` when `colors` is not readable. When the other provenance
    /// and the token together exceed `provenance`'s 80 characters, only the token is kept.
    func recolored(_ colors: SpineColors) -> SpineDesignV1 {
        let other =
            provenance?.split(separator: " ")
            .filter { !$0.hasPrefix(Self.generatedColorsPrefix) }
            .joined(separator: " ") ?? ""
        var token = ""
        if let generated = generatedColors ?? self.colors, colors != generated {
            token =
                Self.generatedColorsPrefix
                + [generated.background, generated.foreground, generated.accent]
                .map { $0.hex.dropFirst() }.joined(separator: ",")
        }
        var joined = [other, token].filter { !$0.isEmpty }.joined(separator: " ")
        if joined.count > 80 { joined = token }
        return rebuilt(
            workItemHash: workItemHash, colors: colors, provenance: joined.isEmpty ? nil : joined)
    }

    /// Whether `other` is this design or a recoloring of it: the same account, book, work-item
    /// and cover hashes, generator, and `generatedAt`.
    func isSameDesign(as other: SpineDesignV1) -> Bool {
        accountID == other.accountID && bookID == other.bookID
            && workItemHash == other.workItemHash && coverHash == other.coverHash
            && generatorVersion == other.generatorVersion && generatedAt == other.generatedAt
    }

    /// What a generation run does with this saved design for a book whose work-item hash is
    /// `workItemHash` and whose cover, downloaded for this run, hashes to `coverHash`.
    ///
    /// A design of another cover is redesigned. Otherwise the reader's colors outlast generator
    /// and metadata changes: only a new cover, such as one chosen with **Change cover**,
    /// redesigns a recolored spine. A design with the generator's colors is kept while it comes
    /// from this generator and its work-item hash matches.
    func action(workItemHash: String, coverHash: String) -> SavedDesignAction {
        guard self.coverHash == coverHash else { return .redesign }
        if generatedColors != nil, let colors {
            guard self.workItemHash != workItemHash else { return .keep }
            return .save(
                rebuilt(workItemHash: workItemHash, colors: colors, provenance: provenance))
        }
        return self.workItemHash == workItemHash
            && generatorVersion == CloudContract.generatorVersion ? .keep : .redesign
    }

    private func rebuilt(workItemHash: String, colors: SpineColors, provenance: String?)
        -> SpineDesignV1
    {
        SpineDesignV1(
            version: version, accountID: accountID, bookID: bookID, workItemHash: workItemHash,
            coverHash: coverHash, generatorVersion: generatorVersion, generatedAt: generatedAt,
            backgroundHex: colors.background.hex, foregroundHex: colors.foreground.hex,
            accentHex: colors.accent.hex, typeface: typeface, weight: weight,
            uppercase: uppercase, fontFamily: fontFamily, fontPostScriptName: fontPostScriptName,
            instanceWeight: instanceWeight, provenance: provenance)
    }
}
