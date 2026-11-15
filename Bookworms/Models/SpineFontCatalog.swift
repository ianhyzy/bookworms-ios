import CoreText
import Foundation

/// The Google Fonts families a spine title may use, grouped by letterform style.
///
/// After changing the catalog, run `script/spine-font-atlas.sh` so `TitleLettering` can rank
/// the new families.
///
/// Every family is open source and was checked against the Google Fonts catalog. Raw values are
/// exact catalog names, which `GoogleFonts` uses to download the family.
enum SpineFamily: String, CaseIterable {
    // blackletter
    case unifrakturmaguntia = "UnifrakturMaguntia"
    case unifrakturcook = "UnifrakturCook"
    case pirataOne = "Pirata One"
    case grenzeGotisch = "Grenze Gotisch"
    case almendraDisplay = "Almendra Display"
    // script
    case caveat = "Caveat"
    case permanentMarker = "Permanent Marker"
    case patrickHand = "Patrick Hand"
    case kalam = "Kalam"
    case dancingScript = "Dancing Script"
    case pacifico = "Pacifico"
    case satisfy = "Satisfy"
    case greatVibes = "Great Vibes"
    case amaticSc = "Amatic SC"
    case shadowsIntoLight = "Shadows Into Light"
    case homemadeApple = "Homemade Apple"
    case rockSalt = "Rock Salt"
    case lobster = "Lobster"
    case courgette = "Courgette"
    // slab
    case alfaSlabOne = "Alfa Slab One"
    case arvo = "Arvo"
    case zillaSlab = "Zilla Slab"
    case robotoSlab = "Roboto Slab"
    case bitter = "Bitter"
    case rokkitt = "Rokkitt"
    case ultra = "Ultra"
    case bevan = "Bevan"
    case josefinSlab = "Josefin Slab"
    // didone
    case playfairDisplay = "Playfair Display"
    case abrilFatface = "Abril Fatface"
    case bodoniModa = "Bodoni Moda"
    case prata = "Prata"
    case dmSerifDisplay = "DM Serif Display"
    case libreCaslonDisplay = "Libre Caslon Display"
    case yesevaOne = "Yeseva One"
    case italiana = "Italiana"
    // bookSerif
    case ebGaramond = "EB Garamond"
    case cormorantGaramond = "Cormorant Garamond"
    case libreBaskerville = "Libre Baskerville"
    case crimsonPro = "Crimson Pro"
    case lora = "Lora"
    case merriweather = "Merriweather"
    case spectral = "Spectral"
    case cardo = "Cardo"
    case alegreya = "Alegreya"
    // classicalCaps
    case cinzel = "Cinzel"
    case cinzelDecorative = "Cinzel Decorative"
    case marcellus = "Marcellus"
    case forum = "Forum"
    case castoroTitling = "Castoro Titling"
    // geometricSans
    case montserrat = "Montserrat"
    case poppins = "Poppins"
    case josefinSans = "Josefin Sans"
    case raleway = "Raleway"
    case jost = "Jost"
    case outfit = "Outfit"
    case urbanist = "Urbanist"
    case redHatDisplay = "Red Hat Display"
    // humanistSans
    case inter = "Inter"
    case openSans = "Open Sans"
    case lato = "Lato"
    case sourceSans3 = "Source Sans 3"
    case nunitoSans = "Nunito Sans"
    case workSans = "Work Sans"
    case notoSans = "Noto Sans"
    case ptSans = "PT Sans"
    // condensedSans
    case bebasNeue = "Bebas Neue"
    case anton = "Anton"
    case oswald = "Oswald"
    case teko = "Teko"
    case fjallaOne = "Fjalla One"
    case staatliches = "Staatliches"
    case archivoNarrow = "Archivo Narrow"
    case barlowCondensed = "Barlow Condensed"
    case leagueGothic = "League Gothic"
    case sixCaps = "Six Caps"
    // rounded
    case nunito = "Nunito"
    case quicksand = "Quicksand"
    case varelaRound = "Varela Round"
    case fredoka = "Fredoka"
    case baloo2 = "Baloo 2"
    case comfortaa = "Comfortaa"
    case sniglet = "Sniglet"
    // decorative
    case rye = "Rye"
    case sancreek = "Sancreek"
    case specialElite = "Special Elite"
    case creepster = "Creepster"
    case nosifer = "Nosifer"
    case metalMania = "Metal Mania"
    case orbitron = "Orbitron"
    case audiowide = "Audiowide"
    case michroma = "Michroma"
    case pressStart2p = "Press Start 2P"
    case bangers = "Bangers"
    case bungee = "Bungee"
    case righteous = "Righteous"
    case monoton = "Monoton"
    case shrikhand = "Shrikhand"
    case changaOne = "Changa One"
    case chakraPetch = "Chakra Petch"
    case russoOne = "Russo One"
    case blackOpsOne = "Black Ops One"
    case limelight = "Limelight"
    case fascinate = "Fascinate"
    case barrio = "Barrio"
    case eater = "Eater"
    case federo = "Federo"
    case medievalsharp = "MedievalSharp"
    case uncialAntiqua = "Uncial Antiqua"
    // monospace
    case courierPrime = "Courier Prime"
    case spaceMono = "Space Mono"
    case ibmPlexMono = "IBM Plex Mono"
    case robotoMono = "Roboto Mono"

    /// Families that new designs never use, though saved designs may still name them.
    ///
    /// - Faces whose letters lean without declaring a slant, which breaks the rule that spine
    ///   lettering stays upright. The lean is the median angle of the upright strokes in
    ///   "lIHbhkinmrpBDEFKLPR": Caveat measures 19 degrees, Permanent Marker 18, and Kalam 13,
    ///   while upright faces measure under 1. Shadows Into Light's letters tilt unevenly.
    ///   `BookAnalyzer.allowsFamily` blocks these and the other leaning script and display faces
    ///   outright, so a saved design in one draws in Patrick Hand
    ///   (`SpineFamily.slantedReplacements`).
    /// - Hairline faces, whose stems are under 8 percent of their capitals' height, so at spine
    ///   size their titles read as scratches: the ultra-narrow Six Caps (7.5 percent) and
    ///   Amatic SC (at most 7), and the outlined Monoton (4.5) and Almendra Display (2.5).
    ///   League Gothic, at 15 percent, takes the narrow faces' place for narrow lettering.
    /// - Cinzel Decorative, whose swashes the title measurements cannot tell from Cinzel's plain
    ///   capitals.
    /// - Italiana, a light, single-weight display didone and the narrowest serif face, whose
    ///   capitals average 0.82 of their height wide. The catalog has no condensed serif, so the
    ///   measurements rank Italiana first for nearly every serif title narrower than the serif
    ///   faces, such as heavy condensed lettering that it doesn't resemble.
    static let neverGenerated: Set<SpineFamily> = [
        .caveat, .kalam, .permanentMarker, .shadowsIntoLight, .sixCaps, .amaticSc, .monoton,
        .almendraDisplay, .cinzelDecorative, .italiana,
    ]

    /// Returns the font file to download for `weight` from a family's upright `.ttf` file
    /// names: the static file of that weight, else the variable file, else the static file of
    /// the nearest weight, at the regular width, and only for a family with no regular-width
    /// file, in the same order among its width variants; else the first file. `GoogleFonts` downloads this file, and
    /// `script/spine-font-atlas.swift` renders the atlas from the files it chooses at 400 and
    /// 700, so ranking measures the faces that spines draw.
    ///
    /// A static file names its weight as a suffix, such as "Lato-Light.ttf". Of two equally near
    /// static files, a weight above 500 takes the heavier and any other the lighter. Some
    /// families ship width variants or optical sizes beside their regular files, named before
    /// the weight, such as "NotoSans_ExtraCondensed-Bold.ttf" or "Merriweather_120pt-Bold.ttf".
    /// Of the files of one weight and width, the optical size nearest 24 points, the size of a
    /// spine's title, comes first, then the lowest name.
    static func fileName(for weight: Int, in names: [String]) -> String? {
        let weights = [
            "Thin": 100, "ExtraLight": 200, "Light": 300, "Regular": 400, "Medium": 500,
            "SemiBold": 600, "Bold": 700, "ExtraBold": 800, "Black": 900,
        ]
        let widths = ["Condensed", "Expanded", "Narrow", "Wide", "Compressed"]
        func isWidthVariant(_ name: String) -> Bool { widths.contains { name.contains($0) } }
        func opticalDistance(_ name: String) -> Int {
            let size = name.split { $0 == "_" || $0 == "-" }.lazy
                .compactMap { $0.hasSuffix("pt") ? Int($0.dropLast(2)) : nil }.first
            return size.map { abs($0 - 24) } ?? 0
        }
        let ordered = names.sorted { lhs, rhs in
            if isWidthVariant(lhs) != isWidthVariant(rhs) { return !isWidthVariant(lhs) }
            let (left, right) = (opticalDistance(lhs), opticalDistance(rhs))
            return left != right ? left < right : lhs < rhs
        }
        let statics = ordered.compactMap { name -> (name: String, weight: Int)? in
            guard let style = name.dropLast(".ttf".count).split(separator: "-").last,
                let fileWeight = weights[String(style)]
            else { return nil }
            return (name, fileWeight)
        }
        func isVariable(_ name: String) -> Bool {
            name.contains("[") || name.contains("VariableFont")
        }
        // Regular-width files first, so a width variant of the exact weight never wins over a
        // regular-width variable or nearer file.
        for regularWidth in [true, false] {
            let nearest = statics.filter { isWidthVariant($0.name) != regularWidth }
                .min { lhs, rhs in
                    let left = abs(lhs.weight - weight)
                    let right = abs(rhs.weight - weight)
                    if left != right { return left < right }
                    return weight > 500 ? lhs.weight > rhs.weight : lhs.weight < rhs.weight
                }
            if let nearest, nearest.weight == weight { return nearest.name }
            if let variable = ordered.first(where: {
                isVariable($0) && isWidthVariant($0) != regularWidth
            }) {
                return variable
            }
            if let nearest { return nearest.name }
        }
        return ordered.first
    }

    /// The letterform style group the family belongs to.
    ///
    /// Decorative faces are themed display faces, which a design uses only when the model's
    /// reading names their treatment (`BookAnalyzer.families(for:)`). They include Federo, whose
    /// Art Deco capitals have no serifs, and MedievalSharp and Uncial Antiqua, whose medieval
    /// letters lack blackletter's broken strokes.
    var style: SpineFontStyle {
        switch self {
        case .unifrakturmaguntia, .unifrakturcook, .pirataOne, .grenzeGotisch, .almendraDisplay:
            .blackletter
        case .caveat, .permanentMarker, .patrickHand, .kalam, .dancingScript, .pacifico, .satisfy,
            .greatVibes, .amaticSc, .shadowsIntoLight, .homemadeApple, .rockSalt, .lobster,
            .courgette:
            .script
        case .alfaSlabOne, .arvo, .zillaSlab, .robotoSlab, .bitter, .rokkitt, .ultra, .bevan,
            .josefinSlab:
            .slab
        case .playfairDisplay, .abrilFatface, .bodoniModa, .prata, .dmSerifDisplay,
            .libreCaslonDisplay, .yesevaOne, .italiana:
            .didone
        case .ebGaramond, .cormorantGaramond, .libreBaskerville, .crimsonPro, .lora, .merriweather,
            .spectral, .cardo, .alegreya:
            .bookSerif
        case .cinzel, .cinzelDecorative, .marcellus, .forum, .castoroTitling:
            .classicalCaps
        case .montserrat, .poppins, .josefinSans, .raleway, .jost, .outfit, .urbanist,
            .redHatDisplay:
            .geometricSans
        case .inter, .openSans, .lato, .sourceSans3, .nunitoSans, .workSans, .notoSans, .ptSans:
            .humanistSans
        case .bebasNeue, .anton, .oswald, .teko, .fjallaOne, .staatliches, .archivoNarrow,
            .barlowCondensed, .leagueGothic, .sixCaps:
            .condensedSans
        case .nunito, .quicksand, .varelaRound, .fredoka, .baloo2, .comfortaa, .sniglet:
            .rounded
        case .rye, .sancreek, .specialElite, .creepster, .nosifer, .metalMania, .orbitron,
            .audiowide, .michroma, .pressStart2p, .bangers, .bungee, .righteous, .monoton,
            .shrikhand, .changaOne, .chakraPetch, .russoOne, .blackOpsOne, .limelight, .fascinate,
            .barrio, .eater, .federo, .medievalsharp, .uncialAntiqua:
            .decorative
        case .courierPrime, .spaceMono, .ibmPlexMono, .robotoMono:
            .monospace
        }
    }
}

/// A letterform style group, with the system typeface class that approximates it.
enum SpineFontStyle: String, CaseIterable {
    case bookSerif, humanistSans, geometricSans, condensedSans, slab, didone, classicalCaps, script,
        rounded, decorative, monospace, blackletter

    /// The `SpineDesignV1.typeface` value a reader uses when the downloaded family is missing.
    var fallbackTypeface: String {
        switch self {
        case .blackletter, .script, .slab, .didone, .bookSerif, .classicalCaps: "serif"
        case .geometricSans, .humanistSans, .condensedSans, .decorative: "sans"
        case .rounded: "rounded"
        case .monospace: "monospaced"
        }
    }
}

/// The font-file rules that the app's downloads (`GoogleFonts`) and the atlas script
/// (`script/spine-font-atlas.swift`) share, so the atlas measures the faces that designs use.
enum FontFiles {
    /// The license text among a Google Fonts family's listed files, given as names and
    /// contents: the first file named OFL or LICENSE, when it is the SIL Open Font License or the
    /// Apache License. Returns `nil` otherwise, and then neither the app nor the atlas uses the
    /// family.
    static func license(in files: [(name: String, contents: String)]) -> String? {
        guard
            let file = files.first(where: {
                $0.name.uppercased().contains("OFL") || $0.name.uppercased().contains("LICENSE")
            }),
            file.contents.contains("SIL OPEN FONT LICENSE")
                || file.contents.contains("Apache License")
        else { return nil }
        return file.contents
    }

    /// The upright named instance among `descriptors`, a font file's faces, whose CSS weight is
    /// nearest `weight`; of two as near, the one whose PostScript name sorts first.
    static func nearestUpright(in descriptors: [CTFontDescriptor], weight: Int) -> (
        weight: Int, postScriptName: String, descriptor: CTFontDescriptor
    )? {
        descriptors.compactMap { descriptor in
            let traits =
                CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
                as? [CFString: Any]
            guard isUpright(descriptor), let name = postScriptName(of: descriptor) else {
                return nil
            }
            let trait = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            return (cssWeight(forTrait: trait), name, descriptor)
        }
        .min {
            abs($0.weight - weight) != abs($1.weight - weight)
                ? abs($0.weight - weight) < abs($1.weight - weight)
                : $0.postScriptName < $1.postScriptName
        }
    }

    /// Returns whether a face is upright: it has neither the italic trait nor a slant.
    static func isUpright(_ descriptor: CTFontDescriptor) -> Bool {
        let traits =
            CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let slant = (traits?[kCTFontSlantTrait] as? NSNumber)?.doubleValue ?? 0
        return symbolic & CTFontSymbolicTraits.traitItalic.rawValue == 0 && abs(slant) < 0.01
    }

    static func postScriptName(of descriptor: CTFontDescriptor) -> String? {
        CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
    }

    /// Maps a Core Text weight trait (-1...1) to the nearest CSS weight (100...900).
    ///
    /// The table holds the traits Core Text reports for Google Fonts files at each OS/2 weight
    /// class or `wght` coordinate. They differ from the `NSFont.Weight` constants above 700
    /// and below 300; for example, ExtraBold (800) reports 0.6, not 0.56.
    static func cssWeight(forTrait trait: Double) -> Int {
        let traits: [Double] = [-0.6, -0.4, -0.23, 0, 0.2, 0.3, 0.4, 0.6, 0.8]
        let index = traits.indices.min { abs(traits[$0] - trait) < abs(traits[$1] - trait) } ?? 3
        return (index + 1) * 100
    }
}
