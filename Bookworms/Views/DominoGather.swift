import RealityKit
import simd

extension DominoFinale {
    /// How long each stage of the gathering takes, in seconds: the books lift off the desk
    /// together, cross to over the spread, settle to the height they hover at, close in over
    /// their places, and drop onto them one after another (`Gather`).
    static let liftTime: Float = 0.5
    static let crossTime: Float = 1
    static let settleTime: Float = 0.25
    static let closeTime: Float = 0.45
    static let dropTime: Float = 0.3
    /// How long after the first drop the last drop starts, in the spread's order.
    static let dropSpread: Float = 0.4
    /// The lowest a book lifts, and how far above its place a book hovers before it drops, in
    /// units.
    static let liftFloor: Float = 1.5
    static let hoverHeight: Float = 1.5
    /// How steeply a book climbs to pass over another, and comes down after, as the height it
    /// would change over a whole crossing at that pace, in units: a book that must climb more
    /// steeply starts climbing sooner.
    static let steepest: Float = 6
    /// The least gap between books that pass over and under each other in the air, in units.
    static let airGap: Float = 0.1

    /// The fallen books' ways into the spread, planned once as they start to gather, so that
    /// no book passes through another.
    ///
    /// Every book lifts straight up off the desk at once, turning to lie level, each to its
    /// own height: a book that lay on another rises higher than it, and books that lay close
    /// to each other rise far enough apart to leave `airGap` between them. The books then
    /// cross together, along straight lines across the table, to over their places, turning
    /// to lie as their places do. Books that come close as they cross pass at heights apart:
    /// taking the books from the lowest lift up, each climbs over the books before it wherever
    /// it comes close to them (`knots`). A book can so arrive above a book its place rests on.
    /// Every such pair waits apart instead: the books from a line across the table between the
    /// two on cross to `clearing` beyond where their places meet, farther from the camera, into
    /// the room the finale leaves its heading (`staging`), and the crossings are planned again.
    /// Each book then settles to hover over where it waits, twice as far above the books its
    /// place rests on as it lies on them, the books close in over their places together, which
    /// moves books only toward the camera and keeps them apart, and each drops straight down
    /// onto its place, in the spread's order, no sooner than the books under it, which fall the
    /// shorter way.
    ///
    /// The spread's last book hovers over its place and does not drop: its flourish takes it
    /// from there (`DominoFinale.snapPose`).
    struct Gather: Sendable {
        /// One book's way into its place. Times are seconds after the books start to gather.
        struct Flight: Sendable {
            /// Where the book lies as it starts, and lying level, turned as it lay.
            let from: Transform
            let level: simd_quatf
            /// The book's height every `1 / (knots.count - 1)` of the way across.
            let knots: [Float]
            /// Where across the table the crossing ends, over the book's place or farther from
            /// the camera, and how high the book hovers over its place.
            let staging: SIMD2<Float>
            let hover: Float
            /// The book's place, and when it starts to drop onto it, or `.infinity` for a book
            /// that stays hovering.
            let to: Transform
            let drop: Float

            /// When the book lands in its place.
            var landing: Float { drop + DominoFinale.dropTime }

            /// The book hovering over its place, once the books have closed in.
            var hovering: Transform {
                Transform(
                    scale: to.scale, rotation: to.rotation,
                    translation: [to.translation.x, hover, to.translation.z])
            }

            /// The book's pose `time` seconds after the books start to gather.
            func pose(at time: Float) -> Transform {
                let ease = DominoCameraRig.ease
                let lifted = DominoFinale.liftTime
                let crossed = lifted + DominoFinale.crossTime
                let settled = crossed + DominoFinale.settleTime
                guard time > 0 else { return from }
                if time < lifted {
                    let share = ease(time / lifted)
                    var point = from.translation
                    point.y += (knots[0] - point.y) * share
                    return Transform(
                        scale: to.scale,
                        rotation: DominoSetup.turn(from.rotation, to: level, by: share),
                        translation: point)
                }
                if time < crossed {
                    let share = ease((time - lifted) / DominoFinale.crossTime)
                    let start = SIMD2(from.translation.x, from.translation.z)
                    let point = start + (staging - start) * share
                    return Transform(
                        scale: to.scale,
                        rotation: DominoSetup.turn(level, to: to.rotation, by: share),
                        translation: [point.x, height(at: share), point.y])
                }
                if time < settled {
                    let share = ease((time - crossed) / DominoFinale.settleTime)
                    let height = knots[knots.count - 1]
                    return Transform(
                        scale: to.scale, rotation: to.rotation,
                        translation: [staging.x, height + (hover - height) * share, staging.y])
                }
                if time < drop {
                    let share = ease(min((time - settled) / DominoFinale.closeTime, 1))
                    let point =
                        staging + (SIMD2(to.translation.x, to.translation.z) - staging) * share
                    return Transform(
                        scale: to.scale, rotation: to.rotation,
                        translation: [point.x, hover, point.y])
                }
                // It falls as a dropped book does, gathering speed until it lands.
                let share = min((time - drop) / DominoFinale.dropTime, 1)
                var point = to.translation
                point.y = hover + (point.y - hover) * share * share
                return Transform(scale: to.scale, rotation: to.rotation, translation: point)
            }

            /// The book's height `share` of the way across, along straight lines between its
            /// knots.
            func height(at share: Float) -> Float {
                let place = min(max(share, 0), 1) * Float(knots.count - 1)
                let knot = min(Int(place), knots.count - 2)
                return knots[knot] + (knots[knot + 1] - knots[knot]) * (place - Float(knot))
            }
        }

        /// Each book's way, in the spread's order.
        let flights: [Flight]

        /// When the books close in over their places.
        static var closing: Float {
            DominoFinale.liftTime + DominoFinale.crossTime + DominoFinale.settleTime
        }

        /// When the last book to drop has landed, for any number of books.
        static var landed: Float {
            closing + DominoFinale.closeTime + DominoFinale.dropSpread + DominoFinale.dropTime
        }

        /// The ways of `books`, in the spread's order, each from where it lies to its place,
        /// with its size (see `BookShape.size`). The last book stays hovering over its place.
        init(_ books: [(from: Transform, to: Transform, size: SIMD3<Float>)]) {
            let count = books.count
            guard count > 0 else {
                flights = []
                return
            }
            let levels = books.map { Self.level($0.from.rotation) }
            // The most each book reaches above and below its middle as it crosses, turning.
            let reaches = books.indices.map { index -> Float in
                (0...8)
                    .map { step -> Float in
                        let turn = DominoSetup.turn(
                            levels[index], to: books[index].to.rotation, by: Float(step) / 8)
                        return DominoSetup.Box(Transform(rotation: turn), size: books[index].size)
                            .bounds.high.y
                    }
                    .max() ?? 0
            }
            func apart(_ first: Int, _ second: Int) -> Float {
                reaches[first] + reaches[second] + DominoFinale.airGap
            }
            let lying = books.map { DominoSetup.Box($0.from, size: $0.size, grow: -0.01) }
            let places = books.map { DominoSetup.Box($0.to, size: $0.size, grow: -0.01) }
            // Each book's books under it as it lies, and in the spread, where a book rests only
            // on books before it.
            let underLying = Self.under(lying)
            let underPlaced = Self.under(places, earlierOnly: true)

            // Each book's height every `1 / segments` of the way across to `staging`.
            func crossings(to staging: [SIMD2<Float>]) -> [[Float]] {
                let close = Self.closeness(books, staging: staging)
                // The lift: a book above every book under it, and apart from the books it comes
                // close to before the first knot of its crossing, which the crossing then keeps
                // apart.
                var lifts = [Float](repeating: .nan, count: count)
                let firstKnot = 1 / Float(Self.segments)
                for index in Self.upward(underLying) {
                    var low = DominoFinale.liftFloor + reaches[index]
                    for under in underLying[index] where !lifts[under].isNaN {
                        low = max(low, lifts[under] + apart(index, under))
                    }
                    let taken = close[index]
                        .filter { $0.span.lowerBound <= firstKnot && !lifts[$0.other].isNaN }
                        .map { (lifts[$0.other], apart(index, $0.other)) }
                    lifts[index] = Self.lowest(from: low, clear: taken)
                }
                // The crossing: from the lowest lift up, each book climbs over the books before
                // it wherever it comes close to them, and otherwise heads for its hovering height.
                let segments = Self.segments
                var knots = [[Float]](repeating: [], count: count)
                for index in books.indices.sorted(by: { (lifts[$0], $0) < (lifts[$1], $1) }) {
                    let hover = Self.hover(over: books[index].to)
                    var path = [lifts[index]]
                    for knot in 1...segments {
                        // Pairs close anywhere along either segment that meets this knot.
                        let low = Float(knot - 1) / Float(segments)
                        let high = Float(min(knot + 1, segments)) / Float(segments)
                        var least = DominoFinale.liftFloor + reaches[index]
                        for pair in close[index]
                        where !knots[pair.other].isEmpty && pair.span.lowerBound <= high
                            && pair.span.upperBound >= low
                        {
                            least = max(least, knots[pair.other][knot] + apart(index, pair.other))
                        }
                        let previous = path[knot - 1]
                        path.append(
                            max(previous + (hover - previous) / Float(segments - knot + 1), least))
                    }
                    // Raise the path where it would turn sharply, never lower it, so it still
                    // clears every book it passes over.
                    let step = DominoFinale.steepest / Float(segments)
                    for knot in stride(from: segments - 1, through: 1, by: -1) {
                        path[knot] = max(path[knot], path[knot + 1] - step)
                    }
                    for knot in 1...segments { path[knot] = max(path[knot], path[knot - 1] - step) }
                    knots[index] = path
                }
                return knots
            }

            // Where each crossing ends: over the book's place, unless two books whose places
            // meet would arrive the wrong way up. Then every book from a line between the two on
            // waits farther from the camera, just far enough that their places no longer meet,
            // and the crossings are planned again.
            // Their places grown by `clearing`, so books that swap heights there pass well apart.
            let roomy = books.map { DominoSetup.Box($0.to, size: $0.size, grow: Self.clearing) }
            let spots = books.map { SIMD2($0.to.translation.x, $0.to.translation.z) }
            let ahead = Self.ahead(books)
            let depths = spots.map { simd_dot($0, ahead) }
            var lines: [(at: Float, shift: Float)] = []
            var staging = spots
            var knots = crossings(to: staging)
            // ponytail: gives up after `stagings` rounds; every captured gathering took one.
            for _ in 1..<Self.stagings {
                let wrong = Self.wrongWayUp(
                    roomy, under: underPlaced, staging: staging, knots: knots, depths: depths)
                guard !wrong.isEmpty else { break }
                // A pair shares a line already between the two, or adds one halfway. A line
                // moves as far as its farthest pair needs.
                var needs = [Float](repeating: 0, count: lines.count)
                for (front, back) in wrong.sorted(by: { depths[$0.back] < depths[$1.back] }) {
                    let line =
                        lines.firstIndex { depths[front] <= $0.at && $0.at < depths[back] }
                        ?? {
                            lines.append(((depths[front] + depths[back]) / 2, 0))
                            needs.append(0)
                            return lines.count - 1
                        }()
                    needs[line] = max(
                        needs[line],
                        Self.clearance(
                            roomy[back], at: staging[back], from: roomy[front],
                            at: staging[front], along: ahead))
                }
                for line in lines.indices { lines[line].shift += needs[line] }
                staging = spots.indices.map { index in
                    spots[index] + ahead
                        * lines.filter { depths[index] > $0.at }.map(\.shift).reduce(0, +)
                }
                knots = crossings(to: staging)
            }

            // The drops: in the spread's order, `dropSpread` across, so a book drops no sooner
            // than the books under it, which fall the shorter way and stay under it.
            flights = books.indices.map { index in
                Flight(
                    from: books[index].from, level: levels[index], knots: knots[index],
                    staging: staging[index], hover: Self.hover(over: books[index].to),
                    to: books[index].to,
                    drop: index == count - 1
                        ? .infinity
                        : Self.closing + DominoFinale.closeTime + DominoFinale.dropSpread
                            * Float(index) / Float(max(count - 1, 1)))
            }
        }

        /// How many straight stretches a crossing's height follows.
        static let segments = 16

        /// How high a book hovers over its place `to`: `hoverHeight` above it, and twice as
        /// far apart from the books under it as it lies on them, so the spread hovers stacked
        /// apart as it closes in.
        static func hover(over to: Transform) -> Float {
            DominoFinale.hoverHeight + 2 * to.translation.y
        }

        /// `rotation` turned the shortest way to lie level, front cover up: a book lying on its
        /// front cover turns over about its width.
        static func level(_ rotation: simd_quatf) -> simd_quatf {
            let up = SIMD3<Float>(0, 1, 0)
            let front = rotation.act([0, 0, 1])
            let angle = acos(min(max(simd_dot(front, up), -1), 1))
            let axis = simd_cross(front, up)
            guard simd_length(axis) > 1e-5 else {
                return angle < 1
                    ? rotation : simd_quatf(angle: .pi, axis: rotation.act([1, 0, 0])) * rotation
            }
            return simd_quatf(angle: angle, axis: simd_normalize(axis)) * rotation
        }

        /// For each of `boxes`, the boxes it rests on, of the boxes before it when
        /// `earlierOnly`.
        static func under(_ boxes: [DominoSetup.Box], earlierOnly: Bool = false) -> [[Int]] {
            let bounds = boxes.map(\.bounds)
            return boxes.indices.map { upper in
                boxes.indices.filter { lower in
                    lower != upper && (!earlierOnly || lower < upper)
                        && rests(boxes[upper], bounds[upper], on: boxes[lower], bounds[lower])
                }
            }
        }

        /// Whether `upper`, with its `top` bounds, rests on `lower`, with its `bottom` bounds:
        /// lifted straight up through the upper box's height, the lower box meets it.
        static func rests(
            _ upper: DominoSetup.Box, _ top: DominoSetup.Bounds, on lower: DominoSetup.Box,
            _ bottom: DominoSetup.Bounds
        ) -> Bool {
            guard bottom.low.x < top.high.x, top.low.x < bottom.high.x, bottom.low.z < top.high.z,
                top.low.z < bottom.high.z, top.high.y > bottom.low.y
            else { return false }
            var lift: Float = 0.05
            while lift < top.high.y - bottom.low.y {
                if lower.moved(by: [0, lift, 0]).overlaps(upper) { return true }
                lift += 0.05
            }
            return false
        }

        /// How many times the gathering plans the crossings, moving books apart, at most, and
        /// how far apart, in units, it keeps two books whose places meet when they wait the
        /// wrong way up.
        static let stagings = 12
        static let clearing: Float = 0.03

        /// The direction across the table, as x and z, from the spread's side near the camera
        /// to its far side: the way the books' heads point, on average, as they lie head away
        /// from the camera.
        static func ahead(_ books: [(from: Transform, to: Transform, size: SIMD3<Float>)])
            -> SIMD2<Float>
        {
            let heads = books.reduce(SIMD2<Float>.zero) { total, book in
                let head = book.to.rotation.act([0, 1, 0])
                return total + SIMD2(head.x, head.z)
            }
            return simd_length(heads) > 1e-4 ? simd_normalize(heads) : [0, -1]
        }

        /// The pairs of books whose `places` meet where their crossings end, at `staging`, and
        /// whose crossings, `knots`, end with the lower place's book the higher, nearer the
        /// camera first by their `depths`. A book rests on the books `under` it.
        static func wrongWayUp(
            _ places: [DominoSetup.Box], under: [[Int]], staging: [SIMD2<Float>],
            knots: [[Float]], depths: [Float]
        ) -> [(front: Int, back: Int)] {
            under.enumerated()
                .flatMap { upper, lowers in
                    lowers.filter { lower in
                        knots[lower][knots[lower].count - 1]
                            >= knots[upper][knots[upper].count - 1]
                            && level(places[upper], at: staging[upper])
                                .overlaps(level(places[lower], at: staging[lower]))
                    }
                    .map { depths[$0] <= depths[upper] ? ($0, upper) : (upper, $0) }
                }
        }

        /// How much farther along `ahead` the `back` box, at `spot` across the table, moves to
        /// clear the `front` box, at `other`, both lying at one height.
        static func clearance(
            _ back: DominoSetup.Box, at spot: SIMD2<Float>, from front: DominoSetup.Box,
            at other: SIMD2<Float>, along ahead: SIMD2<Float>
        ) -> Float {
            let still = level(front, at: other)
            var need: Float = 0.02
            while level(back, at: spot + ahead * need).overlaps(still), need < 4 { need += 0.02 }
            return need
        }

        /// `box` moved to lie at height 0 over `spot` across the table.
        static func level(_ box: DominoSetup.Box, at spot: SIMD2<Float>) -> DominoSetup.Box {
            box.moved(by: [spot.x - box.center.x, -box.center.y, spot.y - box.center.z])
        }

        /// For each book, the books that come close to it as they cross together, and the
        /// shares of the way across over which they are close: within the circles that hold
        /// them whichever way they turn.
        static func closeness(
            _ books: [(from: Transform, to: Transform, size: SIMD3<Float>)],
            staging: [SIMD2<Float>]
        ) -> [[(other: Int, span: ClosedRange<Float>)]] {
            let radii = books.map { simd_length(SIMD2($0.size.x, $0.size.y)) / 2 }
            let starts = books.map { SIMD2($0.from.translation.x, $0.from.translation.z) }
            var close = Array(
                repeating: [(other: Int, span: ClosedRange<Float>)](), count: books.count)
            for first in books.indices {
                for second in books.indices where second > first {
                    let reach = radii[first] + radii[second] + 0.05
                    guard
                        let span = Self.span(
                            from: starts[first] - starts[second],
                            to: staging[first] - staging[second], within: reach)
                    else { continue }
                    close[first].append((second, span))
                    close[second].append((first, span))
                }
            }
            return close
        }

        /// The shares of the way, from 0 to 1, over which an offset moving evenly from `start`
        /// to `end` lies within `reach` of zero, if any.
        static func span(from start: SIMD2<Float>, to end: SIMD2<Float>, within reach: Float)
            -> ClosedRange<Float>?
        {
            let way = end - start
            let a = simd_length_squared(way)
            let b = 2 * simd_dot(start, way)
            let c = simd_length_squared(start) - reach * reach
            guard a > 1e-9 else { return c < 0 ? 0...1 : nil }
            let discriminant = b * b - 4 * a * c
            guard discriminant > 0 else { return nil }
            let root = discriminant.squareRoot()
            let (low, high) = (max((-b - root) / (2 * a), 0), min((-b + root) / (2 * a), 1))
            return low <= high ? low...high : nil
        }

        /// The books in an order in which every book comes after the books in `under` it.
        static func upward(_ under: [[Int]]) -> [Int] {
            var over = Array(repeating: [Int](), count: under.count)
            for (index, books) in under.enumerated() {
                for book in books { over[book].append(index) }
            }
            var waiting = under.map(\.count)
            var ready = Array(under.indices.filter { waiting[$0] == 0 }.reversed())
            var order: [Int] = []
            while let index = ready.popLast() {
                order.append(index)
                for book in over[index] {
                    waiting[book] -= 1
                    if waiting[book] == 0 { ready.append(book) }
                }
            }
            // Books lying on each other in a loop, which the desk's physics can leave, go last.
            let placed = Set(order)
            return order + under.indices.filter { !placed.contains($0) }
        }

        /// The lowest height from `low` up that keeps at least each `taken` gap from each
        /// taken height.
        static func lowest(from low: Float, clear taken: [(height: Float, gap: Float)]) -> Float {
            var height = low
            for (other, gap) in taken.sorted(by: { $0.height - $0.gap < $1.height - $1.gap })
            where other + gap > height && other - gap < height {
                height = other + gap
            }
            return height
        }
    }
}
