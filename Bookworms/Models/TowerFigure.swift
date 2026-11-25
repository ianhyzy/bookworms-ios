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

    /// The figures other than the reader, shortest first, from a month's few books to a large
    /// library's All Time.
    private static let objects = [
        TowerFigure(name: "cat", meters: 0.25, phrase: "a cat"),
        TowerFigure(name: "phonebooth", meters: 2.4, phrase: "a phone booth"),
        TowerFigure(name: "elephant", meters: 3.3, phrase: "an elephant"),
        TowerFigure(name: "giraffe", meters: 5.5, phrase: "a giraffe"),
        TowerFigure(name: "house", meters: 8, phrase: "a house"),
        TowerFigure(name: "windmill", meters: 12, phrase: "a windmill"),
        TowerFigure(name: "castletower", meters: 20, phrase: "a castle tower"),
        TowerFigure(name: "lighthouse", meters: 30, phrase: "a lighthouse"),
    ]

    /// The reader, an artist's mannequin `meters` tall with their profile photo on its face. A
    /// tower shorter than they are reaches one of their body's landmarks instead
    /// (`comparison(to:)`).
    static func reader(meters: Float) -> TowerFigure {
        TowerFigure(name: "reader", meters: meters, phrase: "you")
    }

    var isReader: Bool { name == "reader" }

    /// The figures with the reader `readerMeters` tall, shortest first.
    static func ladder(readerMeters: Float) -> [TowerFigure] {
        (objects + [reader(meters: readerMeters)]).sorted { $0.meters < $1.meters }
    }

    /// Landmarks on a standing person, as shares of their height, lowest first. For a reader of
    /// average height, the lowest sits under the shortest tower that `closest(to:readerMeters:)`
    /// gives them, about a quarter of their height, so every such tower names one.
    private static let bodyParts: [(share: Float, name: String)] = [
        (0.15, "shins"), (0.28, "knees"), (0.4, "thighs"), (0.55, "waist"), (0.72, "chest"),
        (0.82, "shoulders"), (0.87, "chin"), (0.93, "eyes"),
    ]

    /// The figure closest to a tower `meters` tall, beside a reader `readerMeters` tall,
    /// preferring a taller one: a figure the tower is growing into reads better than one it
    /// dwarfs. Nothing when the tower is under 60 percent of the shortest figure, where no
    /// comparison reads well.
    static func closest(to meters: Float, readerMeters: Float) -> TowerFigure? {
        let ladder = ladder(readerMeters: readerMeters)
        guard meters >= ladder[0].meters * 0.6 else { return nil }
        // Log distance, doubled for a figure shorter than the tower.
        func cost(_ figure: TowerFigure) -> Float {
            let ratio = log(figure.meters / meters)
            return ratio >= 0 ? ratio : -2 * ratio
        }
        return ladder.min { cost($0) < cost($1) }
    }

    /// How a tower `meters` tall compares with this figure, such as "Taller than a windmill",
    /// or for the reader, "Up to your waist".
    func comparison(to meters: Float) -> String {
        let ratio = meters / self.meters
        if ratio >= 1.05 { return "Taller than \(phrase)" }
        if ratio >= 0.95 { return "As tall as \(phrase)" }
        if isReader, let part = Self.bodyParts.last(where: { ratio >= $0.share }) {
            return "Up to your \(part.name)"
        }
        return "Almost as tall as \(phrase)"
    }
}

/// The reader's height, which Tall Stack's figure of them stands at. The Share tab sets it, and
/// it stays on this device.
enum ReaderHeight {
    /// The `UserDefaults` key that holds the height in meters, absent until the reader sets one.
    static let key = "BookwormsReaderHeight"
    /// The height the figure stands at until the reader sets theirs: about an adult's average.
    static let standIn: Float = 1.7
    /// The heights the Share tab offers, in meters.
    static let range: ClosedRange<Double> = 0.9...2.3

    /// The reader's height in meters, or `standIn` when they haven't set one.
    static var meters: Float {
        let saved = UserDefaults.standard.double(forKey: key)
        return saved > 0 ? Float(saved) : standIn
    }
}
