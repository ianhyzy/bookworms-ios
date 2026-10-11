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
    /// Half a stack's footprint, as (x, z), for a stack of typical books: half a book's height,
    /// lying along x, and half its width.
    static let stackHalfSize = SIMD2<Float>(1.15, 0.75)
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

    /// Where the worm's head, at `head`, stops to eat the stack whose middle is at `stack`,
    /// both as (x, z): on the line between them, just outside the stack's footprint of half
    /// size `halfSize`, so the mouth reaches into the stack and the face stays in sight. A head
    /// already that close stays where it is.
    static func biteSpot(
        stack: SIMD2<Float>, from head: SIMD2<Float>, halfSize: SIMD2<Float> = stackHalfSize
    ) -> SIMD2<Float> {
        let offset = stack - head
        let distance = simd_length(offset)
        guard distance > 1e-4 else { return head }
        let direction = offset / distance
        let edge = simd_reduce_min(halfSize / simd_max(abs(direction), .init(repeating: 1e-4)))
        let reach = edge + headRadius * 0.3
        return distance > reach + 0.1 ? stack - direction * reach : head
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

    /// The closest camera that shows every one of `points`, looking down `pitch` radians below
    /// the horizon, toward -z, with the vertical `fieldOfView`, in a view of width-to-height
    /// `aspect`. Returns the point the camera looks at and its distance from it.
    ///
    /// The points land within `width` of the middle from side to side and between `bottom` and
    /// `top` from top to bottom, in normalized device coordinates (-1 to 1 each way), so they
    /// stay clear of the bars over the view's edges. The camera moves in its own image plane,
    /// so each point's depth depends only on the distance, and the points fit at a distance
    /// if and only if they fit at every greater one, which a bisection finds.
    static func framing(
        _ points: [SIMD3<Float>], pitch: Float, fieldOfView: Float, aspect: Float,
        width: Float, bottom: Float, top: Float
    ) -> (target: SIMD3<Float>, distance: Float) {
        let back = SIMD3<Float>(0, sin(pitch), cos(pitch))
        let up = SIMD3<Float>(0, cos(pitch), -sin(pitch))
        let slope = tan(fieldOfView / 2)
        // The camera's offset from the origin along its right and up axes that fits the points
        // at `distance`, if any offset does.
        func offset(at distance: Float) -> SIMD2<Float>? {
            var low = SIMD2<Float>(repeating: -.infinity)
            var high = SIMD2<Float>(repeating: .infinity)
            for point in points {
                let depth = distance - simd_dot(point, back)
                guard depth > 0 else { return nil }
                let reach = SIMD2(width * aspect, 1) * slope * depth
                let projected = SIMD2(point.x, simd_dot(point, up))
                low = pointwiseMax(low, projected - SIMD2(reach.x, top * reach.y))
                high = pointwiseMin(high, projected - SIMD2(-reach.x, bottom * reach.y))
            }
            return any(low .> high) ? nil : (low + high) / 2
        }
        guard !points.isEmpty, aspect > 0, width > 0, top > bottom else { return (.zero, 30) }
        var near: Float = 0
        var far: Float = 500
        for _ in 0..<32 {
            let middle = (near + far) / 2
            if offset(at: middle) == nil { near = middle } else { far = middle }
        }
        let shift = offset(at: far) ?? .zero
        return (SIMD3(shift.x, 0, 0) + up * shift.y, far)
    }

    /// The triangles of a tube of radius `tube` bent along `arc` radians of a unit circle in
    /// the xy-plane, centered on the circle's bottom (-y), so a full turn makes a glasses lens
    /// and a shorter arc a smile. The ends stay open. Triangles wind counterclockwise seen from
    /// outside, as RealityKit draws front faces.
    static func ring(arc: Float, tube: Float) -> (
        positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]
    ) {
        let along = 32
        let around = 8
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for step in 0...along {
            let angle = arc * (Float(step) / Float(along) - 0.5)
            let center = SIMD3<Float>(sin(angle), -cos(angle), 0)
            for turn in 0...around {
                let twist = 2 * Float.pi * Float(turn) / Float(around)
                let normal = center * cos(twist) + [0, 0, sin(twist)]
                positions.append(center + normal * tube)
                normals.append(normal)
            }
        }
        var indices: [UInt32] = []
        let row = UInt32(around + 1)
        for step in 0..<UInt32(along) {
            for turn in 0..<UInt32(around) {
                let corner = step * row + turn
                indices += [corner, corner + row, corner + 1]
                indices += [corner + 1, corner + row, corner + row + 1]
            }
        }
        return (positions, normals, indices)
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
        for back in points.reversed() {
            if next == distances.count { break }
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
