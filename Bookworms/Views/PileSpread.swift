import CoreGraphics
import RealityKit
import simd

/// The books of a pile share image, spread across the table so that every front cover shows,
/// and the camera that frames them in the image.
///
/// Every book lies front cover up, head away from the camera, turned up to `maximumTurn` about
/// the vertical, in loose rows across the part of the table that the image's pile rect shows
/// (see `arrange(_:in:seed:rowPitch:)`). Books in a row lie side by side, and rows overlap at the books'
/// ends. Rows nearer the camera hold fewer books, as perspective narrows the table toward the
/// viewer. The seed picks each row's books, their order, shifts, and turns, so each seed gives
/// its own arrangement.
///
/// The books go down one at a time, and each rests on the table or on the books under it,
/// tilted as they hold it (see `rest(_:)`), so none floats or sinks into another. The layout
/// then measures how much of each front cover the camera sees
/// (`visibility(of:camera:in:of:samples:)`), moves apart the rows, or the books of a row, that
/// hide too much of one or that a tilted book leans into, until every cover shows at least
/// `targetVisibility`, and frames the books in the pile rect.
struct PileSpread: Sendable {
    /// The books in the order they go down, at rest. A book rests only on books before it.
    let slots: [PileSlot]
    /// Each slot's book shape, in the same order.
    let shapes: [BookShape]
    /// The camera that fits every book inside the pile rect.
    let camera: PileCamera

    /// The least share of each front cover the camera sees, which leaves a margin above the
    /// four fifths the share images promise.
    static let targetVisibility: Float = 0.83
    /// How far apart rows stand, as a share of their books' average length: they overlap at the
    /// books' ends, where a book that rests on another tilts least. Rows a frame has more room
    /// for stand at most the upper bound apart and leave margins.
    static let rowPitch: ClosedRange<Float> = 0.9...1.08
    /// The rows that go down first take books thicker than this, 2.5 cm, only once thinner books
    /// run out, since a book that rests along one side of a thicker one tilts steeply.
    static let thickBook: Float = 0.25
    /// The most a book turns about the vertical, in radians: about 10 degrees.
    static let maximumTurn: Float = 0.17
    /// A book lying front cover up with its head away from the camera (-z) and its spine on the
    /// left (-x), as a reader sets a book down in front of them.
    static let upright = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])

    /// Spreads `books` for an image of `size`, framed in `rect`, a rect in the image's pixels
    /// with y growing downward. The same books, shapes, rect, and seed give the same spread.
    ///
    /// When the rows had to move apart to show every cover, the books are laid out again with
    /// rows that much farther apart from the start, so the frame's shape, not the moves, still
    /// decides how many rows there are.
    ///
    /// `last`, the ID of one of the books, makes that book go down last, in a place where no
    /// book rests on it (see `arrange(_:in:seed:rowPitch:last:)`), as the dominoes' finale needs
    /// for the last book read. Without it, the seed alone decides the order.
    init(
        _ books: [(book: CloudBook, shape: BookShape)], in rect: CGRect, of size: CGSize,
        seed: UInt64, last: Int? = nil
    ) {
        guard !books.isEmpty else {
            slots = []
            shapes = []
            camera = PileCamera()
            return
        }
        let region = Self.region(rect, of: size)
        var result = Self.uncover(
            Self.arrange(books, in: region, seed: seed, rowPitch: Self.rowPitch, last: last),
            in: rect, of: size)
        if result.widened > 0.01 {
            let low = Self.rowPitch.lowerBound + result.widened
            let pitch = low...(Self.rowPitch.upperBound + result.widened)
            result = Self.uncover(
                Self.arrange(books, in: region, seed: seed, rowPitch: pitch, last: last), in: rect,
                of: size)
        }
        slots = result.slots
        shapes = result.pieces.map(\.shape)
        camera = result.camera
    }

    /// Rests `pieces` and frames them in `rect` of an image of `size`, moving them apart until
    /// every front cover shows at least `targetVisibility` and no book's box reaches into
    /// another's (`collisions(of:)`). Returns the pieces where they ended,
    /// at rest, the camera, and how much farther apart the rows moved on average, as a share of
    /// the books' average length.
    private static func uncover(_ pieces: [Piece], in rect: CGRect, of size: CGSize) -> (
        pieces: [Piece], slots: [PileSlot], camera: PileCamera, widened: Float
    ) {
        var pieces = pieces
        let rows = (pieces.map(\.row).max() ?? 0) + 1
        let length = pieces.map(\.shape.size.y).reduce(0, +) / Float(max(pieces.count, 1))
        var slots: [PileSlot] = []
        var camera = PileCamera()
        var widened: Float = 0
        // Coarse samples find the books to move apart; the fine ones confirm the result.
        var samples = SIMD2(6, 8)
        for pass in 0..<60 {
            slots = rest(pieces)
            let boxes = zip(slots, pieces).map { ($0.transform, $1.shape) }
            camera = frame(boxes, in: rect, of: size)
            let seen = visibility(of: boxes, camera: camera, in: rect, of: size, samples: samples)
            // The pairs to move apart, and how far: a book whose cover shows too little and each
            // book that hides it, and a book that leans into another, as a thick book tilted on
            // its neighbor's edge can, since resting accounts only for what lies under it.
            var apart = seen.enumerated()
                .flatMap { index, sight in
                    let step =
                        (targetVisibility - sight.share) * pieces[index].shape.size.y * 0.6 + 0.01
                    return sight.share < targetVisibility
                        ? sight.hiders.keys.map { (index, $0, step) } : []
                }
            apart += collisions(of: boxes).map { ($0, $1, Float(0.02)) }
            if apart.isEmpty {
                if samples == Self.samples { break }
                samples = Self.samples
                continue
            }
            // Books of different rows move apart by widening the gap between their rows, which
            // only ever grows; books of one row move apart across it.
            var gaps = [Float](repeating: 0, count: rows)
            var shifts = [Float](repeating: 0, count: pieces.count)
            for (index, other, step) in apart {
                let (row, hider) = (pieces[index].row, pieces[other].row)
                if row != hider {
                    gaps[min(row, hider)] = max(gaps[min(row, hider)], step)
                } else {
                    let side: Float = pieces[index].spot.x < pieces[other].spot.x ? -1 : 1
                    shifts[index] += side * step / 2
                    shifts[other] -= side * step / 2
                }
            }
            var offsets = [Float](repeating: 0, count: rows)
            for row in offsets.indices.dropFirst() {
                offsets[row] = offsets[row - 1] + gaps[row - 1]
            }
            widened += offsets[rows - 1] / Float(max(rows - 1, 1)) / length
            // ponytail: past 40 passes, spreading everything a little always ends the search.
            let spread: Float = pass >= 40 ? 1.02 : 1
            let middle = pieces.map(\.spot).reduce(.zero, +) / Float(pieces.count)
            for index in pieces.indices {
                let moved =
                    pieces[index].spot
                    + [shifts[index], offsets[pieces[index].row] - offsets[rows - 1] / 2]
                pieces[index].spot = middle + (moved - middle) * spread
            }
        }
        return (pieces, slots, camera, widened)
    }

    /// The samples across each front cover that the final measure takes, along its width and
    /// its length.
    static let samples = SIMD2(16, 20)

    /// A book on the table before it rests: where its middle lies across the table, as x and z,
    /// and its turn about the vertical.
    struct Piece {
        let book: CloudBook
        let shape: BookShape
        var spot: SIMD2<Float>
        let turn: Float
        /// The book's row, counting from the far side.
        var row = 0

        /// The book's width axis, from spine to fore edge, and its length axis, from tail to
        /// head, across the table, as x and z.
        var axes: (across: SIMD2<Float>, along: SIMD2<Float>) {
            ([cos(turn), -sin(turn)], [-sin(turn), -cos(turn)])
        }

        /// The corners of the book's footprint on the table.
        var footprint: [SIMD2<Float>] {
            let (across, along) = axes
            let half = shape.size / 2
            return [[-1, -1], [1, -1], [1, 1], [-1, 1]]
                .map { (sign: SIMD2<Float>) in
                    spot + across * sign.x * half.x + along * sign.y * half.y
                }
        }
    }

    /// One row of books: its middle's z, the span the books' middles may take across it, and
    /// how many books it holds at most and holds.
    private struct Row {
        let z: Float
        let span: Float
        let capacity: Int
        var count = 0
    }

    /// The part of the table that the default camera shows in `rect` of an image of `size`,
    /// taken as centered across the image. The framing (`frame(_:in:of:)`) then slides the
    /// camera so the books show in `rect` wherever it lies, such as clear of a Mac's sidebar.
    static func region(_ rect: CGRect, of size: CGSize) -> PileTray {
        let camera = PileCamera()
        let aspect = Float(size.width / size.height)
        func ground(_ y: CGFloat) -> SIMD3<Float> {
            let ndc = SIMD2(Float(rect.width / size.width), Float(1 - 2 * y / size.height))
            return PileCamera.intersect(camera.ray(ndc: ndc, aspect: aspect), height: 0) ?? .zero
        }
        let far = ground(rect.minY)
        let near = ground(rect.maxY)
        return PileTray(farZ: far.z, nearZ: near.z, farHalfWidth: far.x, nearHalfWidth: near.x)
    }

    /// Places `books` in rows across `region`, before they rest, in the order they go down.
    ///
    /// Books in a row stand as close as their turned footprints allow (`separation(_:_:)`), and
    /// rows stand `rowPitch` apart. For each number of rows, the region grows until the rows hold
    /// every book, and the rows whose books, once framed, show largest win. Rows then give up
    /// books, the most crowded row first, until they hold exactly the books, and share their spare
    /// room out as equal gaps between and beside them. When every row holds one book, the books
    /// sit a little to alternate sides, so they zigzag down the frame.
    ///
    /// Every other row goes down first, so the books of the rows between rest across the ends of
    /// the books in front of and behind them, and no book rests on a book that rests on another.
    /// Those rows take the thinnest books, give or take a size, so the books resting on them lie
    /// nearly flat. The seed decides which books share a row, their order, shifts, and turns, and,
    /// for an even number of rows, which rows go down first.
    ///
    /// The book with ID `last`, if any, joins the rows that go down second, across whose books
    /// nothing rests, or the only rows there are, and goes down after every other book.
    static func arrange(
        _ books: [(book: CloudBook, shape: BookShape)], in region: PileTray, seed: UInt64,
        rowPitch: ClosedRange<Float> = rowPitch, last: Int? = nil
    ) -> [Piece] {
        let count = books.count
        let width = books.map(\.shape.size.x).reduce(0, +) / Float(count)
        let length = books.map(\.shape.size.y).reduce(0, +) / Float(count)
        func key(_ id: Int, _ salt: UInt64) -> (Double, Int) {
            (ShareStyle.unit(seed, id, salt), id)
        }
        func random(_ id: Int, _ salt: UInt64) -> Float {
            Float(ShareStyle.unit(seed, id, salt)) * 2 - 1
        }
        // The average distance between neighbors' middles in a packed row.
        let shuffled = books.sorted { key($0.book.id, 36) < key($1.book.id, 36) }
            .map { Piece(book: $0, shape: $1, spot: .zero, turn: random($0.id, 40) * maximumTurn) }
        let pitch =
            count > 1
            ? zip(shuffled, shuffled.dropFirst()).map { separation($0, $1) + 0.02 }
                .reduce(0, +) / Float(count - 1) : width

        func rows(_ rows: Int, scale: Float) -> [Row]? {
            let tray = region.scaled(by: scale)
            let room = tray.nearZ - tray.farZ - length
            guard room >= Float(rows - 1) * rowPitch.lowerBound * length - 1e-4 else { return nil }
            let step = rows > 1 ? min(room / Float(rows - 1), rowPitch.upperBound * length) : 0
            let first = (tray.farZ + tray.nearZ) / 2 - Float(rows - 1) / 2 * step
            var result: [Row] = []
            for row in 0..<rows {
                let z = first + Float(row) * step
                // The row's near edge is its narrower one.
                let span = 2 * tray.halfWidth(at: z + length / 2) - width
                guard span >= 0 else { return nil }
                result.append(Row(z: z, span: span, capacity: Int(span / pitch) + 1))
            }
            return result
        }
        func capacity(_ rows: [Row]?) -> Int { rows?.reduce(0) { $0 + $1.capacity } ?? 0 }
        func filled(_ rows: [Row]) -> [Row] {
            var rows = rows
            for index in rows.indices { rows[index].count = rows[index].capacity }
            func density(_ index: Int) -> Float {
                Float(rows[index].count) / (rows[index].span / pitch + 1)
            }
            for _ in 0..<(capacity(rows) - count) {
                guard
                    let index = rows.indices.filter({ rows[$0].count > 1 })
                        .max(by: { density($0) < density($1) })
                else { break }
                rows[index].count -= 1
            }
            return rows
        }

        var best: (size: Float, rows: [Row])?
        for number in 1...min(count, 60) {
            var high: Float = 1
            while capacity(rows(number, scale: high)) < count { high *= 2 }
            var low: Float = 0
            for _ in 0..<30 {
                let middle = (low + high) / 2
                if capacity(rows(number, scale: middle)) >= count {
                    high = middle
                } else {
                    low = middle
                }
            }
            // More rows only need more of the region from here on.
            if let best, high > best.size * 1.6 { break }
            guard let found = rows(number, scale: high).map(filled) else { continue }
            // The camera zooms in until the rows' widest share of the region's width, or their
            // share of its depth, fills the frame, so the rows that need the least region at
            // that zoom show the books largest.
            let tray = region.scaled(by: high)
            let depth = (found[found.count - 1].z - found[0].z + length) / (tray.nearZ - tray.farZ)
            let across = found.map { row in
                let used = row.count > 1 ? Float(row.count - 1) * pitch : min(row.span, width)
                return (used + width) / (row.span + width)
            }
            let size = high * max(depth, across.max() ?? 1)
            if size < (best?.size ?? .infinity) - 1e-4 { best = (size, found) }
        }
        guard let rows = best?.rows else { return [] }

        let firstLayer = rows.count % 2 == 1 ? 0 : Int(seed % 2)
        let layers = rows.indices.map { ($0 + firstLayer) % 2 }
        // The rows that go down first take a share of the books' widths as large as their share
        // of the rows' room, from books up to `thickBook` thick in a shuffled order, then from
        // thicker books, thinnest first.
        let room = zip(rows, layers).map { row, layer in (row.span + width, layer) }
        let share =
            room.filter { $0.1 == 0 }.map(\.0).reduce(0, +) / room.map(\.0).reduce(0, +)
        // The book that goes down last comes after the rest, so it joins the second rows.
        let thinnest = shuffled.sorted {
            func thickness(_ piece: Piece) -> Float {
                piece.shape.size.z > thickBook ? piece.shape.size.z : 0
            }
            return ($0.book.id == last ? 1 : 0, thickness($0), key($0.book.id, 37).0, $0.book.id)
                < ($1.book.id == last ? 1 : 0, thickness($1), key($1.book.id, 37).0, $1.book.id)
        }
        let widths = thinnest.map(\.shape.size.x)
        var lower = 0
        var taken: Float = 0
        while lower < count, taken + widths[lower] / 2 < share * widths.reduce(0, +) {
            taken += widths[lower]
            lower += 1
        }
        // Each layer's books go, in a shuffled order, to its row with the most room left for
        // them, so rows of narrow books hold more of them and every row reaches about as far.
        var held = rows.map { _ in [Piece]() }
        var used = rows.map { _ in Float(0) }
        for (layer, group) in [thinnest.prefix(lower), thinnest.dropFirst(lower)].enumerated() {
            let choices = rows.indices.filter { layers[$0] == layer }
            for piece in group.sorted(by: { key($0.book.id, 38) < key($1.book.id, 38) }) {
                func room(_ row: Int) -> (left: Float, step: Float) {
                    let step = held[row].last.map { separation($0, piece) + 0.02 } ?? 0
                    return ((rows[row].span - used[row] - step) / (rows[row].span + width), step)
                }
                guard let row = choices.max(by: { room($0).left < room($1).left }) else { break }
                used[row] += room(row).step
                held[row].append(piece)
            }
        }
        // Rows of long books stand farther apart, so they overlap no more than short ones.
        let lengths = held.map { row in
            row.map(\.shape.size.y).reduce(0, +) / Float(max(row.count, 1))
        }
        var depths = [Float(0)]
        for index in lengths.indices.dropFirst() {
            let close = (lengths[index - 1] + lengths[index]) / 2 * rowPitch.lowerBound
            depths.append(depths[index - 1] + max(close, rows[index].z - rows[index - 1].z))
        }
        let offset = (rows[0].z + rows[rows.count - 1].z - depths[depths.count - 1]) / 2

        var placed: [(piece: Piece, layer: Int)] = []
        for (index, row) in rows.enumerated() {
            var pieces = held[index]
            for column in pieces.indices {
                pieces[column].row = index
                pieces[column].spot.y =
                    depths[index] + offset + random(pieces[column].book.id, 39) * 0.03 * length
            }
            if pieces.count == 1 {
                // Lone books zigzag when every row has one, and otherwise sit near the middle.
                let side: Float = (index + Int(seed % 2)) % 2 == 0 ? -1 : 1
                let share = Float(ShareStyle.unit(seed, index, 35))
                let shift = rows.allSatisfy { $0.count == 1 } ? 0.2 + 0.3 * share : 0.1 * share
                pieces[0].spot.x = side * shift * min(row.span, width)
            } else if pieces.count > 1 {
                for column in pieces.indices.dropFirst() {
                    pieces[column].spot.x =
                        pieces[column - 1].spot.x + separation(pieces[column - 1], pieces[column])
                        + 0.02
                }
                // The row's spare room, shared out as equal gaps between and beside its books.
                let packed = pieces[pieces.count - 1].spot.x
                let gap = max(0, row.span - packed) / Float(pieces.count + 1)
                let start = gap > 0 ? -row.span / 2 + gap : -packed / 2
                for column in pieces.indices {
                    pieces[column].spot.x += start + gap * Float(column)
                }
            }
            placed += pieces.map { ($0, layers[index]) }
        }
        return
            placed.sorted {
                let (first, second) = (key($0.piece.book.id, 41), key($1.piece.book.id, 41))
                let (isLast, otherIsLast) = (
                    $0.piece.book.id == last ? 1 : 0, $1.piece.book.id == last ? 1 : 0
                )
                return ($0.layer, isLast, first.0, first.1)
                    < ($1.layer, otherIsLast, second.0, second.1)
            }
            .map(\.piece)
    }

    /// How far right of `left` the middle of `right` must lie for their footprints not to
    /// overlap, as they lie across and along the table now: the least of the distances that
    /// separate them along the footprints' edge normals.
    static func separation(_ left: Piece, _ right: Piece) -> Float {
        let offset = right.spot.y - left.spot.y
        var least = Float.infinity
        for var normal in [left.axes.across, left.axes.along, right.axes.across, right.axes.along] {
            if normal.x < 0 { normal = -normal }
            guard normal.x > 0.05 else { continue }
            let reach = left.footprint.map { simd_dot($0 - left.spot, normal) }.max() ?? 0
            let back = right.footprint.map { simd_dot($0 - right.spot, normal) }.min() ?? 0
            least = min(least, (reach - back - offset * normal.y) / normal.x)
        }
        return least
    }

    /// Each piece at rest, in order: flat on the table, or on the books before it that lie
    /// under it.
    ///
    /// A book's underside is a plane, which rests as low as it can while it stays on or above
    /// the table at the footprint's corners and on or above each earlier book's front cover
    /// where their footprints overlap. Both are planes, so the corners of each overlap are the
    /// only places to check. The lowest such plane is where gravity leaves the book: it touches
    /// what it rests on at three or more points, around its middle, so it neither floats nor
    /// tips further. A book that overlaps the edge of a lower one therefore lies tilted from the
    /// table onto that edge, by a few degrees.
    static func rest(_ pieces: [Piece]) -> [PileSlot] {
        var slots: [PileSlot] = []
        // Each earlier book's footprint, and the plane of its front cover.
        var covers: [(piece: Piece, point: SIMD3<Float>, normal: SIMD3<Float>)] = []
        for piece in pieces {
            let (across, along) = piece.axes
            let half = piece.shape.size / 2
            let reach = simd_length(SIMD2(half.x, half.y))
            func local(_ point: SIMD2<Float>) -> SIMD2<Float> {
                [simd_dot(point - piece.spot, across), simd_dot(point - piece.spot, along)]
            }
            // Heights the underside must clear, at points in the book's own axes.
            var supports = piece.footprint.map { (local($0), Float(0)) }
            for cover in covers
            where simd_distance(cover.piece.spot, piece.spot)
                < reach + simd_length(SIMD2(cover.piece.shape.size.x, cover.piece.shape.size.y)) / 2
            {
                let overlap = clip(piece.footprint, to: cover.piece)
                // Footprints that only touch hold nothing up.
                guard area(of: overlap) > 1e-4 else { continue }
                for corner in overlap {
                    let height =
                        cover.point.y
                        - (cover.normal.x * (corner.x - cover.point.x)
                            + cover.normal.z * (corner.y - cover.point.z)) / cover.normal.y
                    supports.append((local(corner), height))
                }
            }
            func lowest(_ slope: SIMD2<Float>) -> Float {
                supports.map { $0.1 - simd_dot(slope, $0.0) }.max() ?? 0
            }
            // A slight preference for the flatter of two rests about as low, such as on a
            // support under one corner: lengthwise rather than across the narrower width.
            func settled(_ slope: SIMD2<Float>) -> Float {
                lowest(slope) + 0.05 * simd_length_squared(slope)
            }
            var slope = SIMD2<Float>.zero
            if supports.contains(where: { $0.1 > 0 }) {
                let tilt = minimum(in: -0.6...0.6) { y in
                    minimum(in: -0.6...0.6) { x in settled([x, y]) }.value
                }
                slope = [minimum(in: -0.6...0.6) { x in settled([x, tilt.at]) }.at, tilt.at]
            }
            let height = lowest(slope)
            let normal = simd_normalize(
                SIMD3(0, 1, 0) - slope.x * SIMD3(across.x, 0, across.y)
                    - slope.y * SIMD3(along.x, 0, along.y))
            let rotation =
                simd_quatf(from: [0, 1, 0], to: normal)
                * simd_quatf(angle: piece.turn, axis: [0, 1, 0]) * upright
            let bottom = SIMD3(piece.spot.x, height, piece.spot.y)
            slots.append(
                PileSlot(
                    book: piece.book,
                    transform: Transform(
                        rotation: rotation, translation: bottom + normal * half.z)))
            covers.append((piece, bottom + normal * piece.shape.size.z, normal))
        }
        return slots
    }

    /// The part of `polygon`, a convex polygon on the table, that lies over `piece`'s footprint.
    private static func clip(_ polygon: [SIMD2<Float>], to piece: Piece) -> [SIMD2<Float>] {
        let (across, along) = piece.axes
        let half = piece.shape.size / 2
        var result = polygon
        for (axis, limit) in [
            (across, half.x), (-across, half.x), (along, half.y), (-along, half.y),
        ] {
            guard !result.isEmpty else { break }
            func inside(_ point: SIMD2<Float>) -> Float {
                limit - simd_dot(point - piece.spot, axis)
            }
            var kept: [SIMD2<Float>] = []
            for (index, point) in result.enumerated() {
                let next = result[(index + 1) % result.count]
                let (here, there) = (inside(point), inside(next))
                if here >= 0 { kept.append(point) }
                if (here >= 0) != (there >= 0) {
                    kept.append(point + (next - point) * (here / (here - there)))
                }
            }
            result = kept
        }
        return result
    }

    /// The pairs of books whose boxes, each shrunk by 0.3 millimeters on every side, still
    /// overlap, each as the later book's index and the earlier one's. Books that rest on others
    /// only touch them.
    static func collisions(of books: [(transform: Transform, shape: BookShape)]) -> [(Int, Int)] {
        let boxes = books.map { Box($0.transform, size: $0.shape.size) }
        let reaches = boxes.map { simd_length($0.half) }
        return boxes.indices.flatMap { index in
            (0..<index)
                .filter { other in
                    simd_distance(boxes[index].center, boxes[other].center)
                        < reaches[index] + reaches[other]
                        && boxes[index].intersects(boxes[other], margin: 0.003)
                }
                .map { (index, $0) }
        }
    }

    /// The area of a polygon on the table.
    private static func area(of polygon: [SIMD2<Float>]) -> Float {
        abs(
            polygon.indices.reduce(Float(0)) { sum, index in
                let next = polygon[(index + 1) % polygon.count]
                return sum + polygon[index].x * next.y - next.x * polygon[index].y
            }) / 2
    }

    /// The least of a convex function over `range`, by golden-section search.
    private static func minimum(
        in range: ClosedRange<Float>, _ function: (Float) -> Float
    ) -> (at: Float, value: Float) {
        let ratio = (Float(5).squareRoot() - 1) / 2
        var (low, high) = (range.lowerBound, range.upperBound)
        var left = high - ratio * (high - low)
        var right = low + ratio * (high - low)
        var (atLeft, atRight) = (function(left), function(right))
        for _ in 0..<24 {
            if atLeft <= atRight {
                high = right
                (right, atRight) = (left, atLeft)
                left = high - ratio * (high - low)
                atLeft = function(left)
            } else {
                low = left
                (left, atLeft) = (right, atRight)
                right = low + ratio * (high - low)
                atRight = function(right)
            }
        }
        return atLeft <= atRight ? (left, atLeft) : (right, atRight)
    }

    /// The default camera, moved and zoomed so every corner of `books` lies inside `rect`.
    static func frame(
        _ books: [(transform: Transform, shape: BookShape)], in rect: CGRect, of size: CGSize
    ) -> PileCamera {
        PileCamera()
            .framing(
                books.flatMap { Box($0.transform, size: $0.shape.size).corners }, in: rect,
                of: size, zoomRange: 0.05...20)
    }

    /// How much of each book's front cover `camera` shows inside `rect` of an image of `size`,
    /// and which books hide the rest.
    ///
    /// The front cover is the front board, from where the spine starts to curve to the fore
    /// edge, as `BookFactory` lays the cover over it. A grid of `samples` points across it, along
    /// its width and length, counts as shown when the point projects inside `rect` and the line
    /// from the camera to it passes through no other book's box. `hiders` counts the points each
    /// other book hides, by its index in `books`.
    static func visibility(
        of books: [(transform: Transform, shape: BookShape)], camera: PileCamera, in rect: CGRect,
        of size: CGSize, samples: SIMD2<Int> = samples
    ) -> [(share: Float, hiders: [Int: Int])] {
        let boxes = books.map { Box($0.transform, size: $0.shape.size) }
        let eye = camera.transform.translation
        let aspect = Float(size.width / size.height)
        // A book can hide another up to its height above it times the camera's slope, at most
        // about one unit, beyond their footprints.
        let reaches = boxes.map { simd_length(SIMD2($0.half.x, $0.half.y)) }
        return books.indices.map { index in
            let box = boxes[index]
            let spot = SIMD2(box.center.x, box.center.z)
            let others = boxes.indices.filter { other in
                other != index
                    && simd_distance(SIMD2(boxes[other].center.x, boxes[other].center.z), spot)
                        < reaches[index] + reaches[other] + 1.2
            }
            let left = -box.half.x + books[index].shape.spineDepth
            var shown = 0
            var hiders: [Int: Int] = [:]
            for column in 0..<samples.x {
                for row in 0..<samples.y {
                    let point = box.world([
                        left + (Float(column) + 0.5) / Float(samples.x) * (box.half.x - left),
                        (Float(row) + 0.5) / Float(samples.y) * 2 * box.half.y - box.half.y,
                        box.half.z,
                    ])
                    let ndc = camera.project(point, aspect: aspect)
                    let pixel = CGPoint(
                        x: CGFloat(ndc.x + 1) / 2 * size.width,
                        y: CGFloat(1 - ndc.y) / 2 * size.height)
                    guard rect.contains(pixel) else { continue }
                    if let hider = others.first(where: { boxes[$0].blocks(from: eye, to: point) }) {
                        hiders[hider, default: 0] += 1
                    } else {
                        shown += 1
                    }
                }
            }
            return (Float(shown) / Float(samples.x * samples.y), hiders)
        }
    }

    /// The shares of `rect` in which `camera` shows a front cover, and any part of a book, of
    /// `books`, sampled every `step` pixels across and down.
    static func coverage(
        of books: [(transform: Transform, shape: BookShape)], camera: PileCamera, in rect: CGRect,
        of size: CGSize, step: CGFloat = 8
    ) -> (covers: Float, books: Float) {
        let boxes = books.map { Box($0.transform, size: $0.shape.size) }
        let aspect = Float(size.width / size.height)
        // Each box's bounds in the image, which skip the boxes a pixel cannot hit.
        let bounds = boxes.map { box in
            let points = box.corners.map { camera.project($0, aspect: aspect) }
            return (
                low: points.reduce(points[0], pointwiseMin),
                high: points.reduce(points[0], pointwiseMax)
            )
        }
        var (covers, any, total) = (0, 0, 0)
        for y in stride(from: rect.minY + step / 2, to: rect.maxY, by: step) {
            for x in stride(from: rect.minX + step / 2, to: rect.maxX, by: step) {
                total += 1
                let ndc = SIMD2(
                    Float(2 * x / size.width - 1), Float(1 - 2 * y / size.height))
                let ray = camera.ray(ndc: ndc, aspect: aspect)
                var nearest: (distance: Float, index: Int, front: Bool)?
                for index in boxes.indices
                where all(ndc .>= bounds[index].low) && all(ndc .<= bounds[index].high) {
                    guard let hit = boxes[index].hit(ray),
                        hit.distance < nearest?.distance ?? .infinity
                    else { continue }
                    nearest = (hit.distance, index, hit.front)
                }
                guard let nearest else { continue }
                any += 1
                if nearest.front {
                    let local = boxes[nearest.index]
                        .local(ray.origin + ray.direction * nearest.distance)
                    let left = -boxes[nearest.index].half.x + books[nearest.index].shape.spineDepth
                    if local.x >= left { covers += 1 }
                }
            }
        }
        return (Float(covers) / Float(max(total, 1)), Float(any) / Float(max(total, 1)))
    }
}

/// A book's box in the scene.
private struct Box {
    let center: SIMD3<Float>
    /// The book's axes in the scene: spine to fore edge, tail to head, and back to front cover.
    let axes: simd_float3x3
    let half: SIMD3<Float>

    init(_ transform: Transform, size: SIMD3<Float>) {
        center = transform.translation
        axes = simd_float3x3(transform.rotation)
        half = size / 2
    }

    var corners: [SIMD3<Float>] {
        (0..<8)
            .map { corner in
                world([
                    corner & 1 == 0 ? -half.x : half.x, corner & 2 == 0 ? -half.y : half.y,
                    corner & 4 == 0 ? -half.z : half.z,
                ])
            }
    }

    func world(_ local: SIMD3<Float>) -> SIMD3<Float> { center + axes * local }

    func local(_ point: SIMD3<Float>) -> SIMD3<Float> { axes.transpose * (point - center) }

    /// Whether the segment from `start` to within a twentieth of a millimeter of `end` passes
    /// through the box, by the slab test in the box's axes.
    func blocks(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Bool {
        let origin = local(start)
        let direction = axes.transpose * (end - start)
        var enter: Float = 0
        var exit = 1 - 0.0005 / max(simd_length(direction), 1e-6)
        for axis in 0..<3 {
            let (o, d, h) = (origin[axis], direction[axis], half[axis])
            if abs(d) < 1e-9 {
                if abs(o) > h { return false }
                continue
            }
            let near = (-h - o) / d
            let far = (h - o) / d
            enter = max(enter, min(near, far))
            exit = min(exit, max(near, far))
            if enter > exit { return false }
        }
        return true
    }

    /// Whether this box and `other`, each shrunk by `margin` on every side, overlap: the
    /// separating axis test over both boxes' axes and the cross products of their edges.
    func intersects(_ other: Box, margin: Float) -> Bool {
        let own = [axes.columns.0, axes.columns.1, axes.columns.2]
        let others = [other.axes.columns.0, other.axes.columns.1, other.axes.columns.2]
        func radius(_ box: Box, _ axes: [SIMD3<Float>], along axis: SIMD3<Float>) -> Float {
            let half = box.half - margin
            return abs(simd_dot(axes[0], axis)) * half.x + abs(simd_dot(axes[1], axis)) * half.y
                + abs(simd_dot(axes[2], axis)) * half.z
        }
        let offset = other.center - center
        let candidates =
            own + others + own.flatMap { axis in others.map { simd_cross(axis, $0) } }
        return !candidates.contains { axis in
            let length = simd_length(axis)
            guard length > 1e-4 else { return false }
            let unit = axis / length
            return abs(simd_dot(offset, unit))
                > radius(self, own, along: unit) + radius(other, others, along: unit)
        }
    }

    /// Where `ray` first enters the box, as a distance along its direction, and whether it
    /// enters through the front cover's face.
    func hit(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> (
        distance: Float, front: Bool
    )? {
        let origin = local(ray.origin)
        let direction = axes.transpose * ray.direction
        var enter: Float = 0
        var exit = Float.infinity
        var face = -1
        for axis in 0..<3 {
            let (o, d, h) = (origin[axis], direction[axis], half[axis])
            if abs(d) < 1e-9 {
                if abs(o) > h { return nil }
                continue
            }
            let near = min((-h - o) / d, (h - o) / d)
            let far = max((-h - o) / d, (h - o) / d)
            if near > enter {
                enter = near
                face = axis
            }
            exit = min(exit, far)
            if enter > exit { return nil }
        }
        return (enter, face == 2 && direction.z < 0)
    }
}
