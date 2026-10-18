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
    /// The result fails `validate()` when `colors` is not readable. To fit `provenance`'s 80
    /// characters, the colors token stays, other tokens such as `series-reuse` go first, and the
    /// model token is shortened last, so the design keeps its tier (`tier`): a shortened token
    /// still names a backup model.
    func recolored(_ colors: SpineColors) -> SpineDesignV1 {
        var kept =
            provenance?.split(separator: " ").map(String.init)
            .filter { !$0.hasPrefix(Self.generatedColorsPrefix) } ?? []
        var token = ""
        if let generated = generatedColors ?? self.colors, colors != generated {
            token =
                Self.generatedColorsPrefix
                + [generated.background, generated.foreground, generated.accent]
                .map { $0.hex.dropFirst() }.joined(separator: ",")
        }
        func joined() -> String {
            (kept + [token]).filter { !$0.isEmpty }.joined(separator: " ")
        }
        while joined().count > 80, let other = kept.firstIndex(where: { !$0.hasPrefix("model:") }) {
            kept.remove(at: other)
        }
        if joined().count > 80, let model = kept.first {
            kept = [String(model.prefix(80 - token.count - 1))]
        }
        let provenance = joined()
        return rebuilt(
            workItemHash: workItemHash, coverHash: coverHash, colors: colors,
            provenance: provenance.isEmpty ? nil : provenance)
    }

    /// Whether `other` is this design or a recoloring of it: the same account, book, work-item
    /// and cover hashes, generator, and `generatedAt`.
    func isSameDesign(as other: SpineDesignV1) -> Bool {
        accountID == other.accountID && bookID == other.bookID
            && workItemHash == other.workItemHash && coverHash == other.coverHash
            && generatorVersion == other.generatorVersion && generatedAt == other.generatedAt
    }

    /// Whether saving `design` leaves this saved design in place: both are the same work from
    /// the same generator, and `design` doesn't outrank this one
    /// (`isOutranked(by:awaitingFont:)`) or this one carries the reader's colors. So the first
    /// device to save a work at a tier keeps it, and a better tier's design, or one whose font
    /// downloaded, replaces a weaker one's. With `replacing`, for a redesign the reader asked
    /// for, only a saved design that is no older stays.
    func outlasts(_ design: SpineDesignV1, replacing: Bool) -> Bool {
        guard accountID == design.accountID, bookID == design.bookID,
            workItemHash == design.workItemHash, coverHash == design.coverHash,
            generatorVersion == design.generatorVersion
        else { return false }
        return replacing
            ? generatedAt >= design.generatedAt
            : !isOutranked(by: design.tier, awaitingFont: design.awaitsFont)
                || generatedColors != nil
    }

    /// What a generation run at `runTier` does with this saved design for a book whose work-item
    /// hash is `workItemHash` and whose cover, downloaded for this run, hashes to `coverHash`.
    /// `readerChoseCover` tells whether the reader chose another cover since the book's last
    /// check, such as with **Change cover**. `drawsSeriesLook` tells whether the book draws its
    /// look group's `SeriesLookV1` instead of this design. `upgradesSeriesLook` tells whether the
    /// book's design is to replace its group's weaker look (`SeriesLookV1.upgradeSource(among:)`).
    ///
    /// The reader's colors outlast generator, tier, metadata, and cover-image changes: only a
    /// cover the reader chose, with new image bytes, redesigns a recolored spine. Otherwise a
    /// recolored design whose hashes changed is saved again under the new hashes, with its colors
    /// and `generatedAt`. A design with the generator's colors is kept while both hashes match and
    /// it comes from this generator at `runTier` or a better tier, without a font to await at
    /// `runTier` (`isOutranked(by:awaitingFont:)`), or the book draws a series look. A run
    /// redesigns a weaker tier's design, so a better model replaces a weaker one's choices once
    /// it is available. A look can come from another generator, such as the Apple TV's, and
    /// redesigning a book that draws it changes nothing on the shelf. A series copy
    /// (`isSeriesReuse`) never upgrades a look, so it is redesigned instead: it reproduces a
    /// look or another book's design, perhaps the very look it would replace, and a copy without
    /// a model token reads as Private Cloud Compute whatever made its source.
    func action(
        workItemHash: String, coverHash: String, readerChoseCover: Bool, runTier: ModelTier,
        drawsSeriesLook: Bool = false, upgradesSeriesLook: Bool = false
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
            (generatorVersion == CloudContract.generatorVersion && !isOutranked(by: runTier)
                && !(upgradesSeriesLook && isSeriesReuse))
            || drawsSeriesLook
        return isCurrent && isKept ? .keep : .redesign
    }

    /// The `provenance` token that names the model that made this design, such as
    /// "model:apple/on-device". Without one, the generator decides: `nil`, for Private Cloud
    /// Compute, from any version of this app's generator, such as `ios-pcc-v1` or
    /// `CloudContract.generatorVersion`, whose Private Cloud Compute designs record none;
    /// `ModelTier.onDeviceToken` from any version of the retired Mac companion's generator, such
    /// as `mac-foundation-models-v1` or `CloudContract.macGeneratorVersion`, which designed with
    /// Apple's on-device model; and `ModelTier.localToken` from any other generator, such as the
    /// Apple TV's looks (`CloudContract.appleTVGeneratorVersion`), which come from no model. So a
    /// design keeps its tier when a new generator version ships.
    var modelToken: String? {
        if let token = provenance?.split(separator: " ").first(where: { $0.hasPrefix("model:") }) {
            return String(token)
        }
        if generatorVersion.hasPrefix("ios-pcc-") { return nil }
        if generatorVersion.hasPrefix("mac-foundation-models-") { return ModelTier.onDeviceToken }
        return ModelTier.localToken
    }

    /// The model tier that made this design, from its `modelToken`.
    var tier: ModelTier { ModelTier(modelToken: modelToken) }

    /// The `provenance` token of a local-defaults design whose Google Fonts family couldn't
    /// download, such as while Google Fonts was unreachable, so it uses its style's system
    /// typeface (`BookAnalyzer.design(book:accountID:workItemHash:cover:using:)`).
    static let systemFontToken = "font:system"

    /// Whether the design stands in its system typeface for a family that couldn't download
    /// (`systemFontToken`). It ranks below the other designs of its tier
    /// (`isOutranked(by:awaitingFont:)`), so a later run redesigns it, and upgrades the series
    /// look made from it, once the font downloads.
    var awaitsFont: Bool {
        provenance?.split(separator: " ").contains { $0 == Self.systemFontToken } == true
    }

    /// The `provenance` tokens that place the design in the tier rule, which its series copies
    /// and looks carry: its `modelToken` and, when it awaits a font, `systemFontToken`.
    var tierTokens: [String] {
        [modelToken, awaitsFont ? Self.systemFontToken : nil].compactMap { $0 }
    }

    /// Whether a design from `tier` replaces this one under the tier rule: `tier` is better, or
    /// it is this design's tier and only this design awaits a font. `awaitingFont` tells
    /// whether the other design awaits one too.
    func isOutranked(by tier: ModelTier, awaitingFont: Bool = false) -> Bool {
        self.tier < tier || (self.tier == tier && awaitsFont && !awaitingFont)
    }

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
