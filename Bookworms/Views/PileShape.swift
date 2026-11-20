import RealityKit
import simd

/// A shape that **Arrange** builds from the books on the desk (`BookPileScene.arrange(_:)`).
///
/// Every book lies flat, front cover up with its spine toward the viewer, as a stacked book
/// does, in courses: rows of books side by side, each course laid on the one below. The books
/// go thickest first, so each course's books are about as thick as one another and thick books
/// carry the thin. Each book rests on the highest book under it, so none floats, and each is
/// shifted a little and turned a few degrees about the vertical, so the shape looks laid by
/// hand.
enum PileShape: String, CaseIterable, Identifiable {
    /// Rows of stacks about as wide, deep, and high as one another.
    case cube
    /// Tiers that narrow by a book on every side as they rise.
    case pyramid
    /// Courses shifted by half a book from the course below, as bricks are laid.
    case wall

    var id: Self { self }

    var title: String {
        switch self {
        case .cube: "Cube"
        case .pyramid: "Pyramid"
        case .wall: "Wall"
        }
    }

    var systemImage: String {
        switch self {
        case .cube: "cube"
        case .pyramid: "pyramid"
        case .wall: "square.grid.3x1.below.line.grid.1x2"
        }
    }

    /// The room between neighboring books in a course, in units, which also keeps their turns
    /// from touching.
    static let gap: Float = 0.1
    /// The most a book turns about the vertical, in radians, and shifts along its row, in
    /// units.
    static let turn: Float = 2 * .pi / 180
    static let shift: Float = 0.03
    /// How far two footprints may overlap without one book resting on the other, and the air
    /// under each book, in units.
    static let graze: Float = 0.05
    static let air: Float = 0.002
    /// How far a pyramid's tiers rise for each unit they step in.
    static let slope: Float = 1.1
    /// How long a wall is for its height.
    static let wallLength: Float = 2.5

    /// One course: how many books lie side by side along x, how many rows of them lie along z,
    /// and how far along x its rows shift, in units.
    struct Course: Equatable {
        let columns: Int
        let rows: Int
        var shift: Float = 0

        var count: Int { columns * rows }
    }

    /// The courses that hold `count` books of about `size` (see `BookShape.size`), lying flat,
    /// at most `width` across and `depth` deep, and, where the books allow, at most `height`
    /// high.
    func courses(count: Int, size: SIMD3<Float>, width: Float, depth: Float, height: Float)
        -> [Course]
    {
        guard count > 0 else { return [] }
        // A book lying flat spans its length along x and its width along z.
        let along = size.y + Self.gap
        let across = size.x + Self.gap
        let thickness = size.z
        let columns = max(1, Int((width + Self.gap) / along))
        let rows = max(1, Int((depth + Self.gap) / across))
        func layers(_ perCourse: Int) -> Int { (count + perCourse - 1) / perCourse }
        switch self {
        case .cube:
            // The grid whose block is nearest a cube, preferring blocks no higher than `height`.
            let grids = (1...columns).flatMap { c in (1...rows).map { r in (c, r) } }
            let (c, r) =
                grids.min { first, second in
                    func score(_ grid: (Int, Int)) -> Float {
                        let high = Float(layers(grid.0 * grid.1)) * thickness
                        let sides = [Float(grid.0) * along, Float(grid.1) * across, high]
                        let ratio = (sides.max() ?? 1) / max(sides.min() ?? 1, 1e-3)
                        return ratio + (high > height ? 100 * high / height : 0)
                    }
                    return score(first) < score(second)
                } ?? (1, 1)
            return Array(repeating: Course(columns: c, rows: r), count: layers(c * r))
        case .pyramid:
            // Each tier is a book narrower and a row shallower than the one below, and enough
            // courses high that the sides rise at about `slope`.
            func tiers(_ c: Int) -> [Course] {
                let r = min(rows, max(1, Int((Float(c) * along / across).rounded())))
                return (0..<min(c, r)).map { Course(columns: c - $0, rows: r - $0) }
            }
            let plans = (1...columns).map { c -> (tiers: [Course], high: Int) in
                let tiers = tiers(c)
                return (tiers, layers(tiers.map(\.count).reduce(0, +)))
            }
            let best =
                plans.min { first, second in
                    func score(_ plan: (tiers: [Course], high: Int)) -> Float {
                        let rise = Float(plan.high) * thickness / (along / 2)
                        let total = Float(plan.tiers.count * plan.high) * thickness
                        return abs(rise - Self.slope) + (total > height ? 100 * total / height : 0)
                    }
                    return score(first) < score(second)
                } ?? (tiers(1), count)
            // The base tier gives up whole courses the others don't need, so the top tiers stay
            // whole.
            let spare = best.tiers.map(\.count).reduce(0, +) * best.high - count
            let base = best.high - min(best.high - 1, spare / max(best.tiers[0].count, 1))
            return best.tiers.enumerated()
                .flatMap { tier, course in
                    Array(repeating: course, count: tier == 0 ? base : best.high)
                }
        case .wall:
            // The thinnest wall, one row deep if it can be, no higher than `height`, about
            // `wallLength` times as long as it is high.
            for r in 1...rows {
                let fits = (1...columns).filter {
                    Float(layers($0 * r)) * thickness <= height
                }
                guard
                    let c = fits.min(by: { first, second in
                        func miss(_ c: Int) -> Float {
                            abs(
                                Float(c) * along - Self.wallLength * Float(layers(c * r))
                                    * thickness)
                        }
                        return miss(first) < miss(second)
                    })
                else { continue }
                return (0..<layers(c * r))
                    .map {
                        Course(columns: c, rows: r, shift: $0 % 2 == 0 ? 0 : along / 2)
                    }
            }
            return (0..<layers(columns * rows))
                .map {
                    Course(columns: columns, rows: rows, shift: $0 % 2 == 0 ? 0 : along / 2)
                }
        }
    }

    /// Where each book of `sizes` lies in the shape, centered on the middle of `tray` and fitted
    /// inside it, as indices into `sizes` with their poses, bottom course first, so every book
    /// comes after the books it rests on.
    func places(for sizes: [SIMD3<Float>], in tray: PileTray) -> [(book: Int, pose: Transform)] {
        guard !sizes.isEmpty else { return [] }
        let average = sizes.reduce(.zero, +) / Float(sizes.count)
        let narrowest = min(tray.farHalfWidth, tray.nearHalfWidth)
        let courses = courses(
            count: sizes.count, size: average, width: 1.8 * narrowest,
            depth: 0.9 * (tray.nearZ - tray.farZ), height: PileTray.tallestPile)
        let order = sizes.indices.sorted { (sizes[$0].z, $1) > (sizes[$1].z, $0) }
        let center = SIMD2(tray.centerX, (tray.farZ + tray.nearZ) / 2)
        // Each laid book's footprint on the table, before the tray turns, and its top.
        var laid: [(low: SIMD2<Float>, high: SIMD2<Float>, top: Float)] = []
        var places: [(book: Int, pose: Transform)] = []
        var next = order[...]
        for course in courses where !next.isEmpty {
            let books = Array(next.prefix(course.count))
            next = next.dropFirst(books.count)
            // Rows as even as the course's books allow, so a short top course stays centered.
            let rowCount = min(course.rows, books.count)
            let rows = (0..<rowCount)
                .map { row in
                    let start = books.count * row / rowCount
                    return Array(books[start..<(books.count * (row + 1) / rowCount)])
                }
            let depths = rows.map { row in (row.map { sizes[$0].x }.max() ?? 0) + Self.gap }
            var z = center.y - depths.reduce(0, +) / 2
            for (row, depth) in zip(rows, depths) {
                let length = row.map { sizes[$0].y + Self.gap }.reduce(0, +)
                var x = center.x + course.shift - length / 2
                for book in row {
                    let size = sizes[book]
                    // From -1 to 1, the same for each book and `salt`.
                    func wobble(_ salt: Int) -> Float {
                        2 * DominoFinale.Gather.unit(book, salt) - 1
                    }
                    let yaw: Float = wobble(30) * Self.turn
                    let pitch: Float = size.y + Self.gap
                    let middle = SIMD2<Float>(
                        x + pitch / 2 + wobble(31) * Self.shift, z + depth / 2)
                    x += pitch
                    // The turned footprint's half extents.
                    let cosine: Float = abs(cos(yaw))
                    let sine: Float = abs(sin(yaw))
                    let half = SIMD2<Float>(
                        cosine * size.y + sine * size.x, sine * size.y + cosine * size.x) / 2
                    let low = middle - half
                    let high = middle + half
                    // Footprints that only graze, as turned neighbors' corners may, carry
                    // nothing. A sliver of air under each book keeps it off the book below as
                    // its physics starts.
                    let bottom =
                        (laid.filter {
                            $0.low.x < high.x - Self.graze && low.x + Self.graze < $0.high.x
                                && $0.low.y < high.y - Self.graze && low.y + Self.graze < $0.high.y
                        }
                        .map(\.top).max() ?? 0) + Self.air
                    laid.append((low, high, bottom + size.z))
                    places.append(
                        (
                            book,
                            Transform(
                                rotation: simd_quatf(angle: tray.turn + yaw, axis: [0, 1, 0])
                                    * PileLayout.lyingFlat,
                                translation: tray.turned([middle.x, bottom + size.z / 2, middle.y])
                            )
                        ))
                }
                z += depth
            }
        }
        return places
    }
}
