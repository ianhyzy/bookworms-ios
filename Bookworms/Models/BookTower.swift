import Foundation
import RealityKit

/// A time frame's books stacked into one tower, first finished at the bottom, measured at the
/// books' real thickness.
///
/// The tower is plain data, with no scene or view: the share template's renderer
/// (`TowerSnapshotRenderer`) and the AR stack place the same books at the same poses. Scene
/// units are decimeters, as `BookShape` measures books, and the tower stands on the plane
/// y = 0 around the vertical axis through the origin.
///
/// Each book lies front cover up with its spine toward +z (`PileLayout.lyingFlat`), flat on the
/// book below it, shifted a little left or right and turned a few degrees about the vertical
/// axis, as a stack placed by hand. Nothing tilts out of level.
struct BookTower {
    /// The most books the tower stacks. A larger time frame stacks its most popular books
    /// (`DroppedCard.popular(_:limit:)`), in finishing order, and `height` still measures every
    /// book. At 150 books a Story image draws each spine about 7 pixels tall, as colored bands.
    static let maximumBooks = 150
    /// How far a book shifts from the tower's axis at most, in units: 1.2 cm.
    static let maximumShift: Float = 0.12
    /// How far a book turns about the vertical axis at most, in radians: about 4 degrees.
    static let maximumTwist = 0.07

    struct Slot {
        let book: CloudBook
        let shape: BookShape
        /// The book's pose: its middle, and its turn from the book's own axes.
        let transform: Transform

        /// The corners of the book's box, where they lie.
        var corners: [SIMD3<Float>] {
            let half = shape.size / 2
            return (0..<8)
                .map { corner in
                    transform.translation
                        + transform.rotation.act(
                            SIMD3(
                                corner & 1 == 0 ? -half.x : half.x,
                                corner & 2 == 0 ? -half.y : half.y,
                                corner & 4 == 0 ? -half.z : half.z))
                }
        }
    }

    /// The stacked books, bottom up.
    let slots: [Slot]
    /// The height of every book of the time frame, stacked, in units, including books past
    /// `maximumBooks` that the tower leaves out.
    let height: Float
    /// How many books the time frame has.
    let count: Int
    /// The pages of the books that record a page count.
    let pages: Int

    /// Stacks `books`, given oldest first, at the shapes `shape` gives them. `seed` varies each
    /// book's shift and turn, so the same books and seed always stack the same tower.
    ///
    /// `shape` defaults to a shape at a typical cover's aspect: a book's thickness, and so the
    /// tower's height, doesn't depend on its cover.
    init(
        books: [CloudBook], seed: UInt64,
        shape: (CloudBook) -> BookShape = { BookShape(of: $0, coverAspect: 2 / 3) }
    ) {
        count = books.count
        pages = books.reduce(0) { $0 + ($1.pages ?? 0) }
        height = books.reduce(0) { $0 + BookShape(of: $1, coverAspect: 2 / 3).size.z }
        let shown =
            books.count > Self.maximumBooks
            ? DroppedCard.popular(books, limit: Self.maximumBooks) : books
        var y: Float = 0
        slots = shown.map { book in
            let shape = shape(book)
            let thickness = shape.size.z
            let shift = (Float(ShareStyle.unit(seed, book.id, 91)) * 2 - 1) * Self.maximumShift
            let depth = (Float(ShareStyle.unit(seed, book.id, 92)) * 2 - 1) * Self.maximumShift / 2
            let turn = Float(
                StackArrangement.twist(of: book, seed: seed, maximum: Self.maximumTwist))
            defer { y += thickness }
            return Slot(
                book: book, shape: shape,
                transform: Transform(
                    rotation: simd_quatf(angle: turn, axis: [0, 1, 0]) * PileLayout.lyingFlat,
                    translation: [shift, y + thickness / 2, depth]))
        }
    }

    /// The height of the stacked books, in units, which can be less than `height` when the
    /// tower leaves books out.
    var stackHeight: Float {
        slots.last.map { $0.transform.translation.y + $0.shape.size.z / 2 } ?? 0
    }

    /// The corners of every book's box, for framing the tower in a view.
    var corners: [SIMD3<Float>] { slots.flatMap(\.corners) }

    /// `decimeters` as a reader in `locale` measures a height: feet and inches, such as
    /// "4 ft 2 in", where the locale uses US units, and otherwise centimeters below a meter, such
    /// as "48 cm", and meters with two decimals from a meter, such as "1.26 m", or one from
    /// 10 meters, such as "31.2 m". Its spaces don't break, so a headline keeps the height on
    /// one line.
    static func heightText(_ decimeters: Float, locale: Locale = .current) -> String {
        measuredText(decimeters, locale: locale).replacing(" ", with: "\u{00A0}")
    }

    private static func measuredText(_ decimeters: Float, locale: Locale) -> String {
        let meters = Double(decimeters) / 10
        if locale.measurementSystem == .us {
            let inches = Int((meters / 0.0254).rounded())
            let (feet, rest) = inches.quotientAndRemainder(dividingBy: 12)
            let format = IntegerFormatStyle<Int>(locale: locale)
            if feet == 0 { return "\(rest.formatted(format)) in" }
            return rest == 0
                ? "\(feet.formatted(format)) ft"
                : "\(feet.formatted(format)) ft \(rest.formatted(format)) in"
        }
        let style: Measurement<UnitLength>.FormatStyle
        let value: Measurement<UnitLength>
        if meters < 1 {
            value = Measurement(value: (meters * 100).rounded(), unit: .centimeters)
            style = .measurement(width: .abbreviated, usage: .asProvided)
        } else {
            value = Measurement(value: meters, unit: .meters)
            style = .measurement(
                width: .abbreviated, usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(meters < 10 ? 2 : 1)))
        }
        return value.formatted(style.locale(locale))
    }
}
