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
    /// work-item and cover hashes, so readers that check the work-item hash, such as the Apple
    /// TV, still accept it.
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
            workItemHash: workItemHash, coverHash: coverHash, colors: colors,
            provenance: joined.isEmpty ? nil : joined)
    }

    /// Whether `other` is this design or a recoloring of it: the same account, book, work-item
    /// and cover hashes, generator, and `generatedAt`.
    func isSameDesign(as other: SpineDesignV1) -> Bool {
        accountID == other.accountID && bookID == other.bookID
            && workItemHash == other.workItemHash && coverHash == other.coverHash
            && generatorVersion == other.generatorVersion && generatedAt == other.generatedAt
    }

    /// What a generation run at `runTier` does with this saved design for a book whose work-item
    /// hash is `workItemHash` and whose cover, downloaded for this run, hashes to `coverHash`.
    /// `readerChoseCover` tells whether the reader chose another cover since the book's last
    /// check, such as with **Change cover**. `drawsSeriesLook` tells whether the book draws its
    /// look group's `SeriesLookV1` instead of this design.
    ///
    /// The reader's colors outlast generator, tier, metadata, and cover-image changes: only a
    /// cover the reader chose, with new image bytes, redesigns a recolored spine. Otherwise a
    /// recolored design whose hashes changed is saved again under the new hashes, with its colors
    /// and `generatedAt`. A design with the generator's colors is kept while both hashes match and
    /// it comes from this generator at `runTier` or a better tier (`tier`), or the book draws a
    /// series look. A run redesigns a weaker tier's design, so a better model replaces a weaker
    /// one's choices once it is available. A look can come from another generator, such as the
    /// Apple TV's, and redesigning a book that draws it changes nothing on the shelf.
    func action(
        workItemHash: String, coverHash: String, readerChoseCover: Bool, runTier: ModelTier,
        drawsSeriesLook: Bool = false
    ) -> SavedDesignAction {
        let newCover = self.coverHash != coverHash
        let isCurrent = !newCover && self.workItemHash == workItemHash
        if generatedColors != nil, let colors, !(readerChoseCover && newCover) {
            guard !isCurrent else { return .keep }
            return .save(
                rebuilt(
                    workItemHash: workItemHash, coverHash: coverHash, colors: colors,
                    provenance: provenance))
        }
        let isKept =
            (generatorVersion == CloudContract.generatorVersion && tier >= runTier)
            || drawsSeriesLook
        return isCurrent && isKept ? .keep : .redesign
    }

    /// The `provenance` token that names the model that made this design, such as
    /// "model:apple/on-device", or `nil` for Private Cloud Compute, whose designs record none.
    /// The design of an Apple TV look (`CloudContract.appleTVGeneratorVersion`) records none
    /// either but comes from no model, so it reads as `ModelTier.localToken`.
    var modelToken: String? {
        if let token = provenance?.split(separator: " ").first(where: { $0.hasPrefix("model:") }) {
            return String(token)
        }
        return generatorVersion == CloudContract.appleTVGeneratorVersion
            ? ModelTier.localToken : nil
    }

    /// The model tier that made this design, from its `modelToken`.
    var tier: ModelTier { ModelTier(modelToken: modelToken) }

    private func rebuilt(
        workItemHash: String, coverHash: String, colors: SpineColors, provenance: String?
    ) -> SpineDesignV1 {
        SpineDesignV1(
            version: version, accountID: accountID, bookID: bookID, workItemHash: workItemHash,
            coverHash: coverHash, generatorVersion: generatorVersion, generatedAt: generatedAt,
            backgroundHex: colors.background.hex, foregroundHex: colors.foreground.hex,
            accentHex: colors.accent.hex, typeface: typeface, weight: weight,
            uppercase: uppercase, fontFamily: fontFamily, fontPostScriptName: fontPostScriptName,
            instanceWeight: instanceWeight, provenance: provenance)
    }
}
