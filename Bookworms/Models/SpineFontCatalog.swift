/// The Google Fonts families the model may choose for a spine title, grouped by letterform style.
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
    // `BookAnalyzer` shuffles these per book, so case order does not bias the model.
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

extension SpineFamily {
    /// The family that replaces Impact in a saved design.
    ///
    /// Bebas Neue is a heavy condensed sans in Impact's role. Google Fonts serves it, and tvOS
    /// ships it as a system font, so every Bookworms app uses the same replacement.
    static let impactReplacement = SpineFamily.bebasNeue
}

extension SpineDesignV1 {
    /// The design as readers show it: a family or PostScript name that the owner's type rules
    /// block (`BookAnalyzer.allowsFamily`), such as Impact in a design another app saved, becomes
    /// `SpineFamily.impactReplacement`.
    ///
    /// Only the in-memory copy changes, so the stored record and its wire format stay as written.
    var withAllowedFont: SpineDesignV1 {
        let names = [fontFamily, fontPostScriptName].compactMap { $0 }
        guard !names.allSatisfy(BookAnalyzer.allowsFamily) else { return self }
        var design = self
        design.fontFamily = SpineFamily.impactReplacement.rawValue
        design.fontPostScriptName = nil
        design.instanceWeight = nil
        return design
    }
}
