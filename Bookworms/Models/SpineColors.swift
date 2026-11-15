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
    /// Saves this copy of the saved design, which keeps its colors, type, and cover hash under the
    /// book's new work-item hash, so readers that check the work-item hash, such as the Apple TV,
    /// still accept it.
    case save(SpineDesignV1)
    /// Designs the book again.
    case redesign
}

/// Colors and a font the reader chose for a spine, recorded in the design's `provenance`.
///
/// A recolored design keeps its record, work-item and cover hashes, generator version, font, and
/// `generatedAt`, and records the generator's colors in a `provenance` token:
/// `generated-colors:` followed by the background, text, and accent colors as six uppercase
/// hexadecimal digits each, separated by commas, such as
/// `generated-colors:1A2B3C,F4E9D0,C08040`. A space separates the token from any other
/// provenance, such as `series-reuse:12 generated-colors:1A2B3C,F4E9D0,C08040`. The token's
/// presence marks the colors as the reader's; recoloring a design back to the generator's colors
/// removes it.
///
/// A design the reader set in another font keeps the same fields and its colors, names the
/// font in its usual font fields, which every app draws, and carries the `reader-font` token
/// (`readerFontToken`). Either token keeps the design through generation runs
/// (`hasReaderEdits`).
extension SpineDesignV1 {
    private static let generatedColorsPrefix = "generated-colors:"

    /// The `provenance` token of a design whose font the reader chose
    /// (`refonted(family:postScriptName:instanceWeight:typeface:)`).
    static let readerFontToken = "reader-font"

    /// Whether the reader chose the design's font (`readerFontToken`).
    var hasReaderFont: Bool {
        provenance?.split(separator: " ").contains { $0 == Self.readerFontToken } == true
    }

    /// Whether the reader chose the design's colors or font, which keeps the design through
    /// generation runs (`action(workItemHash:coverHash:readerChoseCover:fromChosenCover:runTier:drawsSeriesLook:upgradesSeriesLook:)`,
    /// `outlasts(_:replacing:)`) and keeps a series look made from it from upgrades
    /// (`SeriesLookV1.isUpgraded(at:awaitingFont:)`).
    var hasReaderEdits: Bool { generatedColors != nil || hasReaderFont }

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
    /// The result fails `validate()` when `colors` is not readable. The provenance stays within
    /// 80 characters as `fitted(_:)` describes.
    func recolored(_ colors: SpineColors) -> SpineDesignV1 {
        let kept =
            provenance?.split(separator: " ").map(String.init)
            .filter { !$0.hasPrefix(Self.generatedColorsPrefix) } ?? []
        var token = ""
        if let generated = generatedColors ?? self.colors, colors != generated {
            token =
                Self.generatedColorsPrefix
                + [generated.background, generated.foreground, generated.accent]
                .map { $0.hex.dropFirst() }.joined(separator: ",")
        }
        return rebuilt(
            workItemHash: workItemHash, coverHash: coverHash, colors: colors,
            provenance: Self.fitted(kept + [token]))
    }

    /// Returns this design set in `family`, the reader's choice: its instance `postScriptName`,
    /// which weighs `instanceWeight`, with `typeface` as its system stand-in. Keeps the colors and
    /// every other field, so the result is the same design (`isSameDesign(as:)`).
    ///
    /// The provenance gains `readerFontToken` and loses `systemFontToken`, since the design no
    /// longer awaits a font, and stays within 80 characters as `fitted(_:)` describes.
    func refonted(
        family: String, postScriptName: String?, instanceWeight: Int?, typeface: String
    ) -> SpineDesignV1 {
        var design = self
        design.fontFamily = family
        design.fontPostScriptName = postScriptName
        design.instanceWeight = instanceWeight
        design.typeface = typeface
        design.provenance = Self.readerFontProvenance(provenance)
        return design
    }

    /// `provenance` with `readerFontToken` in place of any `systemFontToken`, as a font the
    /// reader chose leaves it (`refonted(family:postScriptName:instanceWeight:typeface:)`).
    static func readerFontProvenance(_ provenance: String?) -> String? {
        let kept = (provenance?.split(separator: " ").map(String.init) ?? [])
            .filter { $0 != systemFontToken && $0 != readerFontToken }
        return fitted(kept + [readerFontToken])
    }

    /// `tokens` as a `provenance` of at most 80 characters, or `nil` without a token. To fit,
    /// the reader's tokens (`generatedColorsPrefix`, `readerFontToken`) stay, other tokens such
    /// as `series-reuse` go first, and the model token is shortened last, so the design keeps its
    /// tier (`tier`): a shortened token still names a backup model.
    private static func fitted(_ tokens: [String]) -> String? {
        var tokens = tokens.filter { !$0.isEmpty }
        func joined() -> String { tokens.joined(separator: " ") }
        func isProtected(_ token: String) -> Bool {
            token.hasPrefix("model:") || token.hasPrefix(generatedColorsPrefix)
                || token == readerFontToken
        }
        while joined().count > 80, let other = tokens.firstIndex(where: { !isProtected($0) }) {
            tokens.remove(at: other)
        }
        if joined().count > 80, let model = tokens.firstIndex(where: { $0.hasPrefix("model:") }) {
            tokens[model] = String(tokens[model].dropLast(joined().count - 80))
        }
        return tokens.isEmpty ? nil : joined()
    }

    /// Whether `other` is this design, a recoloring or another font of it, or it moved to
    /// another work-item hash (`SavedDesignAction.save(_:)`): the same account, book, cover
    /// hash, generator, and `generatedAt`.
    func isSameDesign(as other: SpineDesignV1) -> Bool {
        accountID == other.accountID && bookID == other.bookID && coverHash == other.coverHash
            && generatorVersion == other.generatorVersion && generatedAt == other.generatedAt
    }

    /// Whether saving `design` leaves this saved design of the same book in place: `design` doesn't
    /// outrank it (`isOutranked(by:awaitingFont:)`), from any generator, or it carries the reader's
    /// colors or font (`hasReaderEdits`). So the first device to save a work at a tier keeps it, a
    /// better tier's design replaces only one from local defaults or the on-device model, one whose
    /// font downloaded replaces one that awaits it, and a save decided from an older read, such as
    /// under another library snapshot's hashes, replaces no design it wouldn't replace now. Only
    /// this design moved to a new work-item hash, with every other field as it is now
    /// (`SavedDesignAction.save(_:)`), replaces it whatever its tier, so a move decided before
    /// the reader recolored the design or set it in another font leaves it. A series copy with the
    /// generator's colors and font also gives way to a newer copy under its work-item hash from its
    /// tier or a better one, which needs its font no more than it does, because a copy follows its
    /// group's look; an untracked copy (`isUntrackedCopy`) gives way to any newer copy of its work.
    /// With `replacing`, for a redesign the reader asked for or a design of the cover the reader
    /// chose, only a saved design of the same work that is no older stays.
    func outlasts(_ design: SpineDesignV1, replacing: Bool) -> Bool {
        guard accountID == design.accountID, bookID == design.bookID else { return false }
        let sameWork = workItemHash == design.workItemHash && coverHash == design.coverHash
        if replacing { return sameWork && generatedAt >= design.generatedAt }
        if isSeriesReuse, !hasReaderEdits, design.isSeriesReuse,
            workItemHash == design.workItemHash, design.generatedAt > generatedAt,
            isUntrackedCopy || design.tier >= tier && (awaitsFont || !design.awaitsFont)
        {
            return false
        }
        // `design` is this design under another work-item hash. A move decided from an older
        // read, before the reader recolored this design or set it in another font, doesn't
        // match, so the reader's edit stays, and the next check moves the edited design.
        if !sameWork, let colors,
            rebuilt(
                workItemHash: design.workItemHash, coverHash: coverHash, colors: colors,
                provenance: provenance) == design
        {
            return false
        }
        return !isOutranked(by: design.tier, awaitingFont: design.awaitsFont)
            || hasReaderEdits
    }

    /// What a generation run at `runTier` does with this saved design for a book whose work-item
    /// hash is `workItemHash` and whose cover, downloaded for this run, hashes to `coverHash`.
    /// `readerChoseCover` tells whether the reader chose another cover since the book's last
    /// check, such as with **Change cover**, and `fromChosenCover` whether the downloaded cover is
    /// the one the reader chose. `drawsSeriesLook` tells whether the book draws its
    /// look group's `SeriesLookV1` instead of this design. `upgradesSeriesLook` tells whether the
    /// book's design is to replace its group's look (`SeriesLookV1.upgradeSource(among:)`).
    ///
    /// A run replaces a design from local defaults or the on-device model only with a better
    /// tier's, and a design from Private Cloud Compute or the backup model never
    /// (`isOutranked(by:awaitingFont:)`), except with a design of a cover the reader chose
    /// (`comesFromAnotherCover(than:readerChoseCover:fromChosenCover:)`). A design with the
    /// generator's colors and font stays when `runTier` doesn't outrank it, whatever generator
    /// version made it, and so does a design the reader recolored or set in another font
    /// (`hasReaderEdits`), at any tier, or the design of a book that
    /// draws a series look, since redesigning that book changes nothing on the shelf. A design that
    /// stays is kept while the work-item hash matches; after a metadata change it is saved again
    /// under the new work-item hash with its cover hash, colors, font, generator, and
    /// `generatedAt`, because the Apple TV ignores a design whose work-item hash doesn't match the
    /// book. A new image behind the book's default cover changes nothing, and the design keeps the
    /// hash of the cover it comes from. So a new generator version, a recheck, or a run at the same
    /// or a weaker tier never replaces a model's choices, and no run replaces a capable model's. A
    /// design that awaits its font ranks below its tier, so a run at its tier designs the book
    /// again, and that design replaces it once the font downloads (`outlasts(_:replacing:)`). A
    /// series copy without a model token (`isUntrackedCopy`) never upgrades a look, so it is
    /// redesigned instead: it reads as Private Cloud Compute whatever made its source, which may be
    /// the very look it would replace. A copy with a model token follows the tier rule, and one
    /// that stays upgrades the look.
    func action(
        workItemHash: String, coverHash: String, readerChoseCover: Bool,
        fromChosenCover: Bool = false, runTier: ModelTier, drawsSeriesLook: Bool = false,
        upgradesSeriesLook: Bool = false
    ) -> SavedDesignAction {
        let stays =
            hasReaderEdits || drawsSeriesLook
            || (!isOutranked(by: runTier) && !(upgradesSeriesLook && isUntrackedCopy))
        guard stays,
            !comesFromAnotherCover(
                than: coverHash, readerChoseCover: readerChoseCover,
                fromChosenCover: fromChosenCover),
            let colors
        else { return .redesign }
        guard self.workItemHash != workItemHash else { return .keep }
        return .save(
            rebuilt(
                workItemHash: workItemHash, coverHash: self.coverHash, colors: colors,
                provenance: provenance))
    }

    /// Whether this design comes from another cover than the one the reader chose, so a run
    /// designs the book again whatever the design's tier. The run downloaded a cover that hashes
    /// to `coverHash`, another than this design's, and either the reader chose another cover
    /// since the book's last check (`readerChoseCover`) or the downloaded cover is the reader's
    /// choice (`fromChosenCover`) and the design has the generator's colors and font. So a device
    /// that never saw the choice, or whose first design from it failed, still designs the chosen
    /// cover, and new bytes behind the chosen cover's URL redesign the book too. A default cover
    /// downloaded because the chosen one is missing replaces no design unless the choice is new,
    /// and a design the reader recolored or set in another font gives way only to a new choice.
    func comesFromAnotherCover(
        than coverHash: String, readerChoseCover: Bool, fromChosenCover: Bool
    ) -> Bool {
        self.coverHash != coverHash
            && (readerChoseCover || fromChosenCover && !hasReaderEdits)
    }

    /// Whether the design is a series copy (`isSeriesReuse`) without a model token, as copies
    /// made before copies recorded their source's tier are, so its generator alone decides its
    /// tier (`modelToken`), whatever model made its source.
    var isUntrackedCopy: Bool {
        isSeriesReuse
            && provenance?.split(separator: " ").contains { $0.hasPrefix("model:") } != true
    }

    /// A series copy of `source`, a series look's design or another book's saved design, for the
    /// book `bookID`: `source`'s type and colors, or the generator's colors when the reader
    /// recolored `source`, since the reader's colors stay with `source`'s book. Its `provenance`
    /// is `series-reuse:<source's book ID>` and `source`'s tier tokens (`tierTokens`), so the copy
    /// has its source's tier and awaits its source's font. `nil` when `source` has an invalid
    /// color.
    init?(
        copying source: SpineDesignV1, bookID: Int, accountID: String, workItemHash: String,
        coverHash: String, generatorVersion: String = CloudContract.generatorVersion,
        generatedAt: Date = Date()
    ) {
        guard let colors = source.generatedColors ?? source.colors else { return nil }
        self.init(
            version: 1, accountID: accountID, bookID: bookID, workItemHash: workItemHash,
            coverHash: coverHash, generatorVersion: generatorVersion, generatedAt: generatedAt,
            backgroundHex: colors.background.hex, foregroundHex: colors.foreground.hex,
            accentHex: colors.accent.hex, typeface: source.typeface, weight: source.weight,
            uppercase: source.uppercase, fontFamily: source.fontFamily,
            fontPostScriptName: source.fontPostScriptName, instanceWeight: source.instanceWeight,
            provenance: String(
                (["series-reuse:\(source.bookID)"] + source.tierTokens)
                    .joined(separator: " ").prefix(80)))
    }

    /// Whether this design is a series copy of `source` as `source` is now
    /// (`init(copying:bookID:accountID:workItemHash:coverHash:generatorVersion:generatedAt:)`),
    /// from any generator version and date.
    func isCopy(of source: SpineDesignV1) -> Bool {
        SpineDesignV1(
            copying: source, bookID: bookID, accountID: accountID, workItemHash: workItemHash,
            coverHash: coverHash, generatorVersion: generatorVersion, generatedAt: generatedAt)
            == self
    }

    /// The `provenance` token that names the model that made this design, such as
    /// "model:apple/on-device". Without one, the generator decides: `nil`, for Private Cloud
    /// Compute, from any version of this app's generator, such as `ios-pcc-v1` or
    /// `CloudContract.generatorVersion`, whose Private Cloud Compute designs record none;
    /// `ModelTier.onDeviceToken` from any version of the retired Mac companion's generator, such
    /// as `mac-foundation-models-v1` or `CloudContract.macGeneratorVersion`, which designed with
    /// Apple's on-device model; and `ModelTier.localToken` from any other generator, such as the
    /// Apple TV's looks (`CloudContract.appleTVGeneratorVersion`), which come from no model. So a
    /// design keeps its tier when a new generator version ships. The companion used no other
    /// model, so a `ModelTier.localToken` on its generator, which builds that read
    /// `mac-foundation-models-v1` as local defaults wrote into looks made from its designs, also
    /// reads as `ModelTier.onDeviceToken`.
    var modelToken: String? {
        let isCompanion = generatorVersion.hasPrefix("mac-foundation-models-")
        if let token = provenance?.split(separator: " ").first(where: { $0.hasPrefix("model:") }) {
            return isCompanion && token == ModelTier.localToken
                ? ModelTier.onDeviceToken : String(token)
        }
        if generatorVersion.hasPrefix("ios-pcc-") { return nil }
        if isCompanion { return ModelTier.onDeviceToken }
        return ModelTier.localToken
    }

    /// The model tier that made this design, from its `modelToken`.
    var tier: ModelTier { ModelTier(modelToken: modelToken) }

    /// The model that made this design, from its `modelToken`, as the Spines tab's **Saved
    /// designs** and a book's **Spine design** card name it
    /// (`ModelTier.designerName(modelToken:)`).
    var madeBy: String { ModelTier.designerName(modelToken: modelToken) }

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

    /// Whether a design from `tier` replaces this one under the tier rule: this design's tier is
    /// replaceable and `tier` is better (`ModelTier.isReplaced(by:)`), or it is this design's
    /// tier and only this design awaits a font. `awaitingFont` tells whether the other design
    /// awaits one too.
    func isOutranked(by tier: ModelTier, awaitingFont: Bool = false) -> Bool {
        self.tier.isReplaced(by: tier) || (self.tier == tier && awaitsFont && !awaitingFont)
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
            instanceWeight: instanceWeight, provenance: provenance, choice: choice)
    }
}
