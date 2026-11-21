import Foundation

/// Something of a known real height that stands beside a Tall Stack tower at true scale, so the
/// reader sees how tall their books are. The models are `Figures/figure-<name>.usdz`; README-AI
/// and `Credits.rtf` credit them.
struct TowerFigure: Equatable, Sendable {
    /// The model's name, which `Figures/figure-<name>.usdz` holds.
    let name: String
    /// The real height, in meters.
    let meters: Float
    /// How the comparison names it, such as "a windmill".
    let phrase: String

    /// The person on the ladder. A tower shorter than they are reaches one of their body's
    /// landmarks instead (`comparison(to:)`).
    static let person = TowerFigure(name: "ian", meters: 1.83, phrase: "Ian")

    /// The figures, shortest first, from a month's few books to a large library's All Time.
    static let ladder = [
        TowerFigure(name: "cat", meters: 0.25, phrase: "a cat"),
        // Intentionally the app's author, for fun: the person on the ladder is Ian, and every
        // reader's image compares their books with him. A 6-foot placeholder stands in for his
        // photo until it arrives.
        person,
        TowerFigure(name: "phonebooth", meters: 2.4, phrase: "a phone booth"),
        TowerFigure(name: "elephant", meters: 3.3, phrase: "an elephant"),
        TowerFigure(name: "giraffe", meters: 5.5, phrase: "a giraffe"),
        TowerFigure(name: "house", meters: 8, phrase: "a house"),
        TowerFigure(name: "windmill", meters: 12, phrase: "a windmill"),
        TowerFigure(name: "castletower", meters: 20, phrase: "a castle tower"),
        TowerFigure(name: "lighthouse", meters: 30, phrase: "a lighthouse"),
    ]

    /// Landmarks on a standing person, as shares of their height, lowest first. The lowest sits
    /// under the shortest tower that `closest(to:)` gives the person, about 26 percent of their
    /// height, so every such tower names one.
    private static let bodyParts: [(share: Float, name: String)] = [
        (0.15, "shins"), (0.28, "knees"), (0.4, "thighs"), (0.55, "waist"), (0.72, "chest"),
        (0.82, "shoulders"), (0.87, "chin"), (0.93, "eyes"),
    ]

    /// The figure closest to a tower `meters` tall, preferring a taller one: a figure the tower
    /// is growing into reads better than one it dwarfs. Nothing when the tower is under 60
    /// percent of the shortest figure, where no comparison reads well.
    static func closest(to meters: Float) -> TowerFigure? {
        guard meters >= ladder[0].meters * 0.6 else { return nil }
        // Log distance, doubled for a figure shorter than the tower.
        func cost(_ figure: TowerFigure) -> Float {
            let ratio = log(figure.meters / meters)
            return ratio >= 0 ? ratio : -2 * ratio
        }
        return ladder.min { cost($0) < cost($1) }
    }

    /// How a tower `meters` tall compares with this figure, such as "Taller than a windmill",
    /// or for the person, "Up to Ian's waist".
    func comparison(to meters: Float) -> String {
        let ratio = meters / self.meters
        if ratio >= 1.05 { return "Taller than \(phrase)" }
        if ratio >= 0.95 { return "As tall as \(phrase)" }
        if self == Self.person, let part = Self.bodyParts.last(where: { ratio >= $0.share }) {
            return "Up to \(phrase)'s \(part.name)"
        }
        return "Almost as tall as \(phrase)"
    }
}
