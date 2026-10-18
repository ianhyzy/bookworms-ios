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
    case medievalsharp = "MedievalSharp"
    case uncialAntiqua = "Uncial Antiqua"
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
    case federo = "Federo"
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
    static let neverGenerated: Set<SpineFamily> = [
        .caveat, .kalam, .permanentMarker, .shadowsIntoLight, .sixCaps, .amaticSc, .monoton,
        .almendraDisplay, .cinzelDecorative,
    ]

    /// Returns the font file to download for `weight` from a family's upright `.ttf` file
    /// names: the static file of that weight, else the variable file, else the static file of
    /// the nearest weight, else the first file. `GoogleFonts` downloads this file, and
    /// `script/spine-font-atlas.swift` renders the atlas from the files it chooses at 400 and
    /// 700, so ranking measures the faces that spines draw.
    ///
    /// A static file names its weight as a suffix, such as "Lato-Light.ttf". Of two equally near
    /// static files, a weight above 500 takes the heavier and any other the lighter. Some
    /// families ship width variants or optical sizes beside their regular files, named before
    /// the weight, such as "NotoSans_ExtraCondensed-Bold.ttf" or "Merriweather_120pt-Bold.ttf".
    /// Of the files of one weight, the regular width comes first, then the optical size nearest
    /// 24 points, the size of a spine's title, then the lowest name.
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
        let nearestStatic =
            ordered
            .compactMap { name -> (name: String, weight: Int)? in
                guard let style = name.dropLast(".ttf".count).split(separator: "-").last,
                    let fileWeight = weights[String(style)]
                else { return nil }
                return (name, fileWeight)
            }
            .min { lhs, rhs in
                let left = abs(lhs.weight - weight)
                let right = abs(rhs.weight - weight)
                if left != right { return left < right }
                return weight > 500 ? lhs.weight > rhs.weight : lhs.weight < rhs.weight
            }
        if let nearestStatic, nearestStatic.weight == weight { return nearestStatic.name }
        let variable = ordered.first { $0.contains("[") || $0.contains("VariableFont") }
        return variable ?? nearestStatic?.name ?? ordered.first
    }

    /// The letterform style group the family belongs to.
    var style: SpineFontStyle {
        switch self {
        case .unifrakturmaguntia, .unifrakturcook, .pirataOne, .grenzeGotisch, .medievalsharp,
            .uncialAntiqua, .almendraDisplay:
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
        case .cinzel, .cinzelDecorative, .marcellus, .forum, .castoroTitling, .federo:
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
            .barrio, .eater:
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
