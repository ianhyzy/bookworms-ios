import RealityKit
import simd

/// How a book lifted out of an arranged scene, which holds still while the book is out, leaves
/// its place and comes back without passing through the books around it (see `BookLifter`), as
/// pure functions of the books' poses, so tests replay them.
///
/// The books resting on the lifted book, such as the domino that fell onto it or a book of the
/// dominoes' spread that lies across its end, are its riders, and so are the books that rest on
/// those in turn. Each rider tips about where it rests on something else (`Rider`): down once
/// nothing holds it up, until it meets the table or another book, and up while the lifted book
/// pushes it. A book without riders rises straight up. A book with riders leaves one of two
/// ways:
///
/// - **Slide.** It first slides out from under them along its own length or width, as a card is
///   drawn from a fanned deck, when it can go that way without touching any book until nothing
///   lies over it (`slide`), and rises from there. The riders follow it down as it goes and fall
///   the rest of the way, and on its way back, it slides in under them and pushes them back up.
/// - **Draw back.** Otherwise, as for a book of the spread with riders across both ends, each
///   rider is first drawn back along its own length, off the book, as a hand would draw it
///   (`Rider.back`), its near end riding down the book's edge, and tips down beside it; the
///   book then rises straight up. On its way back, the riders tip back up beside it once it
///   lies in its place, and slide back onto it.
///
/// When neither way is clear, as for a rider with a rider of its own, the book rises straight up
/// and passes through its riders.
struct BookExit: Sendable {
    /// One book: its pose and size.
    typealias Book = (pose: Transform, size: SIMD3<Float>)

    /// A book that rests on the lifted book, or on another rider, and how it moves.
    struct Rider: Sendable {
        /// The book's index among the other books, its pose, and its size.
        let index: Int
        let rest: Transform
        let size: SIMD3<Float>
        /// The point it tips about, where it rests on something other than the book under it,
        /// and the axis about which a positive turn lowers it.
        let pivot: SIMD3<Float>
        let axis: SIMD3<Float>
        /// The rider it rests on, by its index among the riders, or `nil` for one that rests on
        /// the lifted book. A rider comes before the riders that rest on it.
        let parent: Int?
        /// How far it turns down once nothing holds it up, in radians.
        var fallen: Float = 0
        /// How far it is drawn back off the lifted book, level along its own length, before it
        /// tips: zero, unless the book draws its riders back.
        var back = SIMD3<Float>.zero

        /// The book drawn `drawn` of the way back, then turned `angle` about `axis` through the
        /// pivot, which moves with it: down for a positive angle.
        func pose(turned angle: Float, drawn: Float = 1) -> Transform {
            let turn = simd_quatf(angle: angle, axis: axis)
            let pivot = pivot + back * drawn
            return Transform(
                scale: rest.scale, rotation: turn * rest.rotation,
                translation: pivot + turn.act(rest.translation + back * drawn - pivot))
        }

        /// The book's box drawn `drawn` of the way back and turned `angle`, shrunk by a hair, so
        /// books that touch do not count.
        func box(turned angle: Float, drawn: Float = 1) -> DominoSetup.Box {
            DominoSetup.Box(pose(turned: angle, drawn: drawn), size: size, grow: -BookExit.touch)
        }
    }

    /// How far a box shrinks on every side for the checks, so books that touch do not count.
    static let touch: Float = 0.01
    /// The most the lifted book pushes a rider up, in radians, about 30 degrees.
    static let highest: Float = 0.5
    /// The steps that searches move a book by, in units or radians.
    private static let stride: Float = 0.05

    /// The move along the lifted book's length or width that takes it out from under its
    /// riders, or zero for a book that rises straight up.
    let slide: SIMD3<Float>
    /// How far the book rises from the end of its slide (see `BookFlight.rise`).
    let rise: Float
    /// The riders, each before the riders that rest on it.
    let riders: [Rider]

    /// Whether the riders are drawn back off the book, rather than the book sliding out.
    var drawsBack: Bool { slide == .zero && !riders.isEmpty }

    /// The way out of `book` from among `others`. `margin` is the rise's margin beside the
    /// book (see `BookFlight.rise(of:clearing:margin:)`).
    init(book: Book, among others: [Book], margin: Float = 0) {
        let lifted = DominoSetup.Box(book.pose, size: book.size)
        let boxes = others.map { DominoSetup.Box($0.pose, size: $0.size) }
        func rise(from pose: Transform, clearing boxes: [DominoSetup.Box]) -> Float {
            BookFlight.rise(
                of: Self.bounding(DominoSetup.Box(pose, size: book.size)),
                clearing: boxes.map(Self.bounding), margin: margin)
        }
        var riders = Self.riders(on: lifted, among: others, boxes: boxes)
        guard !riders.isEmpty else {
            self.init(slide: .zero, rise: rise(from: book.pose, clearing: boxes), riders: [])
            return
        }
        Self.settle(&riders, among: boxes)
        if let slide = Self.slide(
            book, from: lifted, riders: riders, among: boxes,
            fallen: Self.fallen(riders, among: boxes))
        {
            var slid = book.pose
            slid.translation += slide
            self.init(
                slide: slide,
                rise: rise(from: slid, clearing: boxes + Self.fallen(riders, among: boxes)),
                riders: riders)
        } else if Self.drawBack(&riders, from: lifted, among: boxes) {
            // Drawn back, they tip down beside the book while it is still in its place.
            Self.settle(&riders, among: boxes, staying: lifted)
            self.init(
                slide: .zero,
                rise: rise(from: book.pose, clearing: Self.fallen(riders, among: boxes)),
                riders: riders)
        } else {
            self.init(slide: .zero, rise: rise(from: book.pose, clearing: boxes), riders: [])
        }
    }

    private init(slide: SIMD3<Float>, rise: Float, riders: [Rider]) {
        self.slide = slide
        self.rise = rise
        self.riders = riders
    }

    // MARK: Riders

    /// The books among `others`, whose boxes are `boxes`, that rest on `lifted`, and in turn on
    /// those, each before the books that rest on it. A book rests on another when a small turn
    /// down about its pivot would take it into that book.
    private static func riders(
        on lifted: DominoSetup.Box, among others: [Book], boxes: [DominoSetup.Box]
    ) -> [Rider] {
        var riders: [Rider] = []
        var taken = Set<Int>()
        // Each support, the lifted book first, and the rider it is, if any.
        var supports: [(box: DominoSetup.Box, rider: Int?)] = [(lifted, nil)]
        var next = 0
        while next < supports.count {
            let support = supports[next]
            next += 1
            let near = support.box.bounds.grown(by: 0.05)
            let held = support.box.shrunk
            for (index, box) in boxes.enumerated()
            where !taken.contains(index) && box.bounds.overlaps(near) {
                guard let tip = tip(of: box, off: support.box) else { continue }
                let rider = Rider(
                    index: index, rest: others[index].pose, size: others[index].size,
                    pivot: tip.pivot, axis: tip.axis, parent: support.rider)
                let probe = rider.box(turned: 0.04)
                guard probe.bounds.overlaps(held.bounds), probe.overlaps(held) else { continue }
                taken.insert(index)
                riders.append(rider)
                supports.append((box, riders.count - 1))
            }
        }
        return riders
    }

    /// Where `box` tips about, and the axis about which a positive turn lowers it, once
    /// `support` has gone: its lowest corner, or edge, among the corners that do not lie over
    /// `support`. Returns `nil` for a box that would not tip, such as one that lies flat.
    private static func tip(of box: DominoSetup.Box, off support: DominoSetup.Box)
        -> (pivot: SIMD3<Float>, axis: SIMD3<Float>)?
    {
        let under = DominoSetup.Footprint(support).grown(by: 0.05)
        let free = box.corners.filter { !under.contains(SIMD2($0.x, $0.z)) }
        guard let lowest = free.map(\.y).min() else { return nil }
        let low = free.filter { $0.y < lowest + 0.03 }
        var pivot: SIMD3<Float>
        var axis: SIMD3<Float>
        switch low.count {
        case 1:
            pivot = low[0]
            let away = box.center - pivot
            axis = simd_cross(SIMD3<Float>(0, 1, 0), SIMD3(away.x, 0, away.z))
        case 2:
            pivot = (low[0] + low[1]) / 2
            axis = low[1] - low[0]
        default:
            return nil
        }
        guard simd_length(axis) > 1e-4 else { return nil }
        axis = simd_normalize(axis)
        // A positive turn moves the middle by `axis × arm`, which must point down.
        let drop = simd_cross(axis, box.center - pivot).y
        guard abs(drop) > 1e-4 else { return nil }
        if drop > 0 { axis = -axis }
        return (pivot, axis)
    }

    /// Finds how far each rider falls, in order, drawn back if it is, with the lifted book gone
    /// or, given as `staying`, in its place: until it meets the table or a book, the riders it
    /// rests on where they fell. The books it rests on at its pivot, which it tips about, do not
    /// stop it.
    private static func settle(
        _ riders: inout [Rider], among boxes: [DominoSetup.Box],
        staying lifted: DominoSetup.Box? = nil
    ) {
        var placed = boxes
        let ridden = Set(riders.map(\.index))
        for order in riders.indices {
            let rider = riders[order]
            let obstacles =
                Self.obstacles(of: rider, in: placed, ridden: ridden)
                + [lifted?.shrunk].compactMap { $0 }
            func hits(_ angle: Float) -> Bool {
                let box = rider.box(turned: angle)
                // The table holds the book's lowest corner, which may sink a hair.
                return box.bounds.low.y < touch - 0.02
                    || obstacles.contains { $0.bounds.overlaps(box.bounds) && $0.overlaps(box) }
            }
            riders[order].fallen = Self.limit(of: hits, upTo: .pi / 2)
            placed[rider.index] = DominoSetup.Box(
                rider.pose(turned: riders[order].fallen), size: rider.size)
        }
    }

    /// `boxes`, with each rider where it fell.
    private static func fallen(_ riders: [Rider], among boxes: [DominoSetup.Box])
        -> [DominoSetup.Box]
    {
        var fallen = boxes
        for rider in riders {
            fallen[rider.index] = DominoSetup.Box(
                rider.pose(turned: rider.fallen), size: rider.size)
        }
        return fallen
    }

    /// The books among `placed` that can stop `rider` as it tips: all but itself and the books
    /// it rests on at its pivot, which are not riders.
    private static func obstacles(
        of rider: Rider, in placed: [DominoSetup.Box], ridden: Set<Int>
    ) -> [DominoSetup.Box] {
        let box = DominoSetup.Box(rider.rest, size: rider.size)
        let touching = DominoSetup.Box(rider.rest, size: rider.size, grow: 0.03)
        let side = SIMD2(rider.pivot.x - box.center.x, rider.pivot.z - box.center.z)
        // Every pose the rider can take lies within this reach of its pivot.
        let reach = simd_length(rider.size) + 0.5
        return placed.indices.compactMap { index -> DominoSetup.Box? in
            let other = placed[index]
            guard index != rider.index,
                simd_distance(other.center, rider.pivot) < reach + simd_length(other.half)
            else { return nil }
            let offset = SIMD2(other.center.x - box.center.x, other.center.z - box.center.z)
            let supports =
                !ridden.contains(index) && simd_dot(offset, side) > 0 && touching.overlaps(other)
            return supports ? nil : other.shrunk
        }
    }

    /// The largest angle up to `limit` before `hits` first holds, by steps and then bisection,
    /// or 0 when it holds at once.
    private static func limit(of hits: (Float) -> Bool, upTo limit: Float) -> Float {
        var free: Float = 0
        while free < limit {
            let next = min(free + stride, limit)
            guard hits(next) else {
                free = next
                continue
            }
            var blocked = next
            for _ in 0..<10 {
                let middle = (free + blocked) / 2
                if hits(middle) { blocked = middle } else { free = middle }
            }
            return free
        }
        return limit
    }

    // MARK: Ways out

    /// The slide along the lifted book's length or width, upward first, then away from its
    /// riders, that touches no book on the way (`boxes`, the riders as they rest) and ends where
    /// neither the book nor anything over it meets a book (`fallen`, the riders where they
    /// fell), or `nil` when no way is clear.
    private static func slide(
        _ book: Book, from lifted: DominoSetup.Box, riders: [Rider], among boxes: [DominoSetup.Box],
        fallen: [DominoSetup.Box]
    ) -> SIMD3<Float>? {
        let axes = [book.pose.rotation.act([0, 1, 0]), book.pose.rotation.act([1, 0, 0])]
        let resting =
            riders.map { $0.rest.translation }.reduce(.zero, +) / Float(riders.count)
            - lifted.center
        // Upward first, by tenths, so a level book's ways tie, and then away from the riders.
        func rank(_ way: SIMD3<Float>) -> (Float, Float) {
            ((way.y * 10).rounded(), -simd_dot(way, resting))
        }
        let ways = (axes + axes.map { -$0 }).sorted { rank($0) > rank($1) }
        let reach = simd_length(book.size) + 0.5
        func isNear(_ box: DominoSetup.Box) -> Bool {
            simd_distance(
                SIMD2(box.center.x, box.center.z), SIMD2(lifted.center.x, lifted.center.z))
                < reach * 2 + simd_length(box.half)
        }
        let path = boxes.filter(isNear).map(\.shrunk)
        // Where the slide ends, neither the riders as they rest nor as they fell may lie over
        // the book.
        let end = (boxes + fallen).filter(isNear).map(\.shrunk)
        for way in ways {
            var distance: Float = 0
            while distance < reach {
                distance += stride
                var pose = book.pose
                pose.translation += way * distance
                let box = DominoSetup.Box(pose, size: book.size, grow: -touch)
                guard box.bounds.low.y > -0.02,
                    !path.contains(where: { $0.bounds.overlaps(box.bounds) && $0.overlaps(box) })
                else { break }
                if isClear(box, among: end) { return way * distance }
            }
        }
        return nil
    }

    /// Whether `box`, and the column above it, meets none of `boxes`.
    private static func isClear(_ box: DominoSetup.Box, among boxes: [DominoSetup.Box]) -> Bool {
        let top = boxes.map(\.bounds.high.y).max() ?? 0
        var height: Float = 0
        while box.bounds.low.y + height < top {
            let raised = DominoSetup.Box(
                Transform(
                    scale: .one, rotation: simd_quatf(box.axes),
                    translation: box.center + [0, height, 0]), size: box.half * 2)
            if boxes.contains(where: { $0.bounds.overlaps(raised.bounds) && $0.overlaps(raised) }) {
                return false
            }
            height += 0.2
        }
        return true
    }

    /// Finds how far to draw each rider back along its own length, away from the lifted book,
    /// until nothing of it lies over the book, and returns whether every rider can go that far,
    /// at most half its length, without meeting a book. Only riders of the lifted book itself
    /// are drawn back; a rider with riders of its own is not.
    private static func drawBack(
        _ riders: inout [Rider], from lifted: DominoSetup.Box, among boxes: [DominoSetup.Box]
    ) -> Bool {
        guard riders.allSatisfy({ $0.parent == nil }) else { return false }
        let ridden = Set(riders.map(\.index))
        let column = lifted.shrunk
        for order in riders.indices {
            var rider = riders[order]
            let obstacles = Self.obstacles(of: rider, in: boxes, ridden: ridden)
            // Level, so its far end slides over what it rests on without sinking into it, and
            // away from the lifted book. Its near end comes down as it goes (see `BookLifter`).
            let length = rider.rest.rotation.act([0, 1, 0])
            guard simd_length(SIMD2(length.x, length.z)) > 0.1 else { return false }
            var away = simd_normalize(SIMD3(length.x, 0, length.z))
            if simd_dot(away, rider.rest.translation - lifted.center) < 0 { away = -away }
            var distance: Float = 0
            repeat {
                distance += stride
                guard distance <= rider.size.y / 2 else { return false }
                rider.back = away * distance
                let box = rider.box(turned: 0)
                guard
                    !obstacles.contains(where: {
                        $0.bounds.overlaps(box.bounds) && $0.overlaps(box)
                    })
                else { return false }
            } while !isClear(column, among: [rider.box(turned: 0)])
            // A little more, so it clears the book's edge as it tips.
            riders[order].back = away * (distance + 0.03)
        }
        return true
    }

    /// The bounds of `box` as RealityKit gives a book's bounds.
    private static func bounding(_ box: DominoSetup.Box) -> BoundingBox {
        let bounds = box.bounds
        return BoundingBox(min: bounds.low, max: bounds.high)
    }
}

extension DominoSetup.Box {
    /// The box's eight corners.
    var corners: [SIMD3<Float>] {
        let (x, y, z) = axes.columns
        return [-1, 1]
            .flatMap { a in
                [-1, 1]
                    .flatMap { b in
                        [-1, 1]
                            .map { (c: Float) in
                                center + x * half.x * a + y * half.y * b + z * half.z * c
                            }
                    }
            }
    }

    /// The box shrunk by `BookExit.touch` on every side.
    var shrunk: DominoSetup.Box {
        DominoSetup.Box(
            Transform(scale: .one, rotation: simd_quatf(axes), translation: center),
            size: half * 2, grow: -BookExit.touch)
    }
}

extension DominoSetup.Bounds {
    /// The bounds grown by `margin` on every side.
    func grown(by margin: Float) -> DominoSetup.Bounds {
        DominoSetup.Bounds(low: low - margin, high: high + margin)
    }
}

extension DominoSetup.Footprint {
    /// Whether `point`, across the table, lies within the footprint.
    func contains(_ point: SIMD2<Float>) -> Bool {
        let offset = point - center
        return abs(simd_dot(offset, first)) <= half.x && abs(simd_dot(offset, second)) <= half.y
    }
}
