import Foundation
import simd

/// Where the Bookworm's books stand, the order the worm eats them in, and the shape of its body,
/// computed without RealityKit so they can be tested.
///
/// Scene units are decimeters, as in the pile, and the table is the plane y = 0. The books form
/// a block: a grid of stacks of books lying flat, spines toward the camera (+z). The block is
/// laid out in the order the worm eats: the stacks run in a serpentine from the near left
/// corner, row by row, so each stack stands next to the one before, and each stack holds its
/// books in finish order from the bottom up. The worm eats each stack from the bottom, so the
/// books above settle into every gap it leaves.
enum BookwormLayout {
    /// The most books the worm eats. More would make a block too deep to see and a worm too long
    /// to curl up in view.
    static let maximumBooks = 100
    static let booksPerStack = 8
    /// The distance between stack centers along x and z: a little more than the longest book's
    /// height (2.4 units, lying along x) and the widest cover (2.04 units, along z).
    static let stackPitch = SIMD2<Float>(2.55, 2.2)
    static let bodyRadius: Float = 0.3
    static let headRadius: Float = 0.42
    /// How far the worm's head stops short of a stack's middle to eat it.
    static let biteReach: Float = 0.7
    /// How far apart the curled worm's coils lie: a body's width and a little room.
    static let coilGap: Float = bodyRadius * 2.2
    /// The head's speed between stacks, in units per second, before `pace`.
    static let crawlSpeed: Float = 3.5
    /// How long the worm takes to eat one book, in seconds, before `pace`.
    static let biteDuration: Float = 0.5

    /// The finished books in `books`, at most `maximumBooks` of them, in the order the reader
    /// finished them. Books finished the same day keep their order in `books`. Unfinished books
    /// are left out, since the worm eats in finish order.
    static func eatingOrder(_ books: [CloudBook]) -> [CloudBook] {
        books.compactMap { book in book.finishedDate.map { (book, $0) } }
            .prefix(maximumBooks)
            .enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)
    }

    /// How many times faster than its usual pace the worm eats `count` books, so a long meal
    /// takes about as long as a meal of 30 books.
    static func pace(books count: Int) -> Float { max(1, Float(count) / 30) }

    /// The centers, as (x, z), of `count` stacks in the order the worm eats them, around the
    /// origin: rows from the near side (+z) to the far side, left to right and then right to
    /// left, so each stack is next to the one before. A row holds at most three stacks, which a
    /// portrait screen fits.
    static func stackCenters(count: Int) -> [SIMD2<Float>] {
        let columns = max(1, min(3, Int(Float(count).squareRoot().rounded(.up))))
        let rows = (count + columns - 1) / columns
        return (0..<count)
            .map { index in
                let (row, step) = index.quotientAndRemainder(dividingBy: columns)
                let column = row.isMultiple(of: 2) ? step : columns - 1 - step
                return SIMD2(
                    Float(column) - Float(columns - 1) / 2, Float(rows - 1) / 2 - Float(row))
                    * stackPitch
            }
    }

    /// A book's place in the block.
    struct Brick: Equatable {
        let book: CloudBook
        /// The stack's index in eating order (see `stackCenters`).
        let stack: Int
        /// The book's center at rest, lying flat.
        let center: SIMD3<Float>
    }

    /// The block for `meal`, books in eating order: as few stacks as hold `booksPerStack` books
    /// each, filled evenly in order, each from the table up. A book is as thick as its
    /// `BookShape`, which does not depend on its cover.
    static func block(_ meal: [CloudBook]) -> [Brick] {
        guard !meal.isEmpty else { return [] }
        let stacks = (meal.count + booksPerStack - 1) / booksPerStack
        let perStack = (meal.count + stacks - 1) / stacks
        let centers = stackCenters(count: stacks)
        var height: Float = 0
        return meal.enumerated()
            .map { index, book in
                let stack = index / perStack
                if index % perStack == 0 { height = 0 }
                let thickness = BookShape(of: book, coverAspect: 2 / 3).size.z
                defer { height += thickness }
                return Brick(
                    book: book, stack: stack,
                    center: [centers[stack].x, height + thickness / 2, centers[stack].y])
            }
    }

    /// The length a book adds to the worm: 0.16 units, and 0.04 more for every full hundred
    /// pages, counting up to 1,500 pages. A book without a page count adds as much as a
    /// 320-page book, as its thickness does.
    static func segmentLength(pages: Int?) -> Float {
        0.16 + 0.04 * Float(min(1500, max(0, pages ?? 320)) / 100)
    }

    /// The centers, as (x, z), of a worm curled into a flat spiral around the origin, given
    /// each part's length along the body from the head to the tail.
    ///
    /// The tail lies in the middle, one `coilGap` out, and the head at the outer end, turned to
    /// the near side (+z) so it faces the camera. Consecutive centers lie half their two
    /// lengths apart along the spiral, and each coil lies `coilGap` outside the one before.
    static func curl(lengths: [Float]) -> [SIMD2<Float>] {
        guard !lengths.isEmpty else { return [] }
        let tailFirst = Array(lengths.reversed())
        let growth = coilGap / (2 * .pi)
        let step: Float = 0.005
        var points: [SIMD2<Float>] = []
        var angle: Float = 0
        var walked: Float = 0
        var target: Float = 0
        for index in tailFirst.indices {
            if index > 0 { target += (tailFirst[index - 1] + tailFirst[index]) / 2 }
            while walked < target {
                let radius = coilGap + growth * angle
                angle += step / (radius * radius + growth * growth).squareRoot()
                walked += step
            }
            let radius = coilGap + growth * angle
            points.append(SIMD2(cos(angle), sin(angle)) * radius)
        }
        // Turns the spiral so the head, the last point, lies on the near side.
        let head = points[points.count - 1]
        let turn = Float.pi / 2 - atan2(head.y, head.x)
        let (cosine, sine) = (cos(turn), sin(turn))
        return points.reversed()
            .map { SIMD2($0.x * cosine - $0.y * sine, $0.x * sine + $0.y * cosine) }
    }

    /// The tally under the worm, such as "Ate 39 books · 12,345 pages". Pages count only the
    /// books with a page count, and the tally leaves them out when no book has one.
    static func caption(books: Int, pages: Int) -> String {
        let count = books == 1 ? "1 book" : "\(books.formatted()) books"
        return pages > 0 ? "Ate \(count) · \(pages.formatted()) pages" : "Ate \(count)"
    }
}

/// The path the worm's head has taken across the table, as (x, z), which its body follows.
///
/// Before the head has gone anywhere, the trail runs straight back from it, opposite its
/// first heading, as far as a body needs. The trail keeps a point at least every `spacing`
/// units, so its memory grows with the distance the head travels, which the block bounds.
struct WormTrail {
    /// Points the head has passed, oldest first.
    private(set) var points: [SIMD2<Float>]
    /// Where the head is now.
    private(set) var head: SIMD2<Float>
    /// The direction the trail runs toward the head before its first point.
    private let start: SIMD2<Float>
    let spacing: Float

    /// A trail that ends at `head`, which faces along `heading`.
    init(head: SIMD2<Float>, heading: SIMD2<Float>, spacing: Float = 0.1) {
        self.head = head
        points = [head]
        start = simd_normalize(heading)
        self.spacing = spacing
    }

    mutating func move(to point: SIMD2<Float>) {
        head = point
        if simd_distance(point, points[points.count - 1]) >= spacing { points.append(point) }
    }

    /// Replaces `samples` with the point `distance` behind the head along the trail, and the
    /// direction the trail runs toward the head there, for each of `distances`, which must
    /// ascend. `samples` keeps its capacity, so a caller that reuses it allocates nothing.
    func sample(
        _ distances: [Float], into samples: inout [(point: SIMD2<Float>, forward: SIMD2<Float>)]
    ) {
        samples.removeAll(keepingCapacity: true)
        var next = 0
        var covered: Float = 0
        var front = head
        for back in points.reversed() where next < distances.count {
            let length = simd_distance(front, back)
            guard length > 1e-5 else { continue }
            let forward = (front - back) / length
            while next < distances.count, distances[next] <= covered + length {
                samples.append((front - forward * (distances[next] - covered), forward))
                next += 1
            }
            covered += length
            front = back
        }
        while next < distances.count {
            samples.append((front - start * (distances[next] - covered), start))
            next += 1
        }
    }
}
