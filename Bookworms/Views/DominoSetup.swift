import RealityKit
import simd

/// How the books lying on the desk set themselves up as the domino chain (see `DominoScene`),
/// as pure functions of the books' poses and time, so tests replay them.
///
/// Before any book moves, `offset(of:aspect:)` moves the lying books across the table by whole
/// tiles of its wood, which repeats every `tile` units, so the table looks the same while each
/// slot lies clear of the books that are still lying when its book lands there.
///
/// The books then go one after another in finish order, ever faster, `step(count:)` apart on
/// average (`step(after:count:)`), so a large frame sets up within a few seconds, and never many
/// in one frame
/// (`nextStart(after:startedAt:step:)`). Each book's move (`Move`) starts from where the book
/// lies at that moment, since the books still lying are rigid bodies that settle as books under
/// them leave:
///
/// 1. The book rights itself where it lies: it turns up onto its tail edge, about that edge's
///    lowest point, until it stands upright on its tail, as a book stands on a shelf.
/// 2. It hops to its slot on an arc under the desk's gravity, turning about the vertical only, so
///    it stays upright in the air. It carries across while it is high enough to clear the books
///    it passes over (`lift(from:to:size:over:)`) and drops the last stretch straight down onto
///    its slot, so it never sweeps through the books standing beside the slot.
///
/// `Schedule` holds a book back while its way would cross a book that moves or stands, and
/// raises its arc over books that stand in its way, so books never pass through each other.
enum DominoSetup {
    /// The period of the table's wood texture, in units (see `DeskStage`).
    static let tile = DeskStage.tile
    /// How far a slot stays from the footprint of a book that is still lying when its book
    /// lands. Lying books shift a little as the books under them leave, so it is generous.
    static let pileMargin: Float = 1.5
    /// How long a book takes to turn a quarter turn up onto its tail, in seconds: slowly enough
    /// that the books lying on it slide off rather than fly off.
    static let quarterTurn: Float = 0.55
    /// The share of a hop after which the book moves straight down onto its slot.
    static let arrival: Float = 0.8
    /// How far a hopping book's underside clears the tops of the books it passes over.
    static let clearance: Float = 0.25
    /// The least and most a hop's arc rises above the line between its ends, at its middle.
    static let lifts: ClosedRange<Float> = 0.5...9
    /// The shortest a hop takes, in seconds, for a book that barely moves.
    static let shortestHop: Float = 0.3
    /// The most time from one book's start to the next, and the latest the last book starts
    /// after the first while no book is held back, in seconds.
    static let longestStep: Float = 0.2
    static let spread: Float = 3.5
    /// The time step at which `Schedule` checks a move against the others, in seconds.
    static let checkStep: Float = 1.0 / 30
    /// The longest a book is held back while its way is blocked, in seconds, and how far into
    /// the setup books may still be held back, so a setup's time stays capped.
    static let longestHold: Float = 1
    static let latestStart: Float = spread + 1.5
    /// How long a book whose way is blocked waits before its way is checked again, in seconds,
    /// so a held book costs a frame no planning while it waits.
    static let retryStep: Float = 0.1
    /// The longest time step a setup takes in one frame, in seconds, so a stalled frame slows
    /// the moves rather than skipping them.
    static let longestFrame: Float = 1.0 / 20

    /// How long a book whose way is blocked waits `time` seconds into the setup before it goes
    /// regardless: `longestHold`, and none once the setup has run past `latestStart`.
    static func hold(at time: Float) -> Float {
        time < latestStart ? longestHold : 0
    }

    /// The average seconds from one book's start to the next in a setup of `count` books:
    /// `longestStep`, or less for a long chain, so every book starts within `spread` of the
    /// first unless one is held back or frames come slowly.
    static func step(count: Int) -> Float {
        min(longestStep, spread / Float(max(count - 1, 1)))
    }

    /// The seconds from the start of the book at `index` to the next one's in a setup of
    /// `count` books: the books start ever faster, averaging `step(count:)`, as they drop into
    /// a chain standing up from above (`DominoLayout.entryShare(_:of:)`).
    static func step(after index: Int, count: Int) -> Float {
        Float(DominoLayout.entryGap(after: index, of: count, step: Double(step(count: count))))
    }

    /// When the next book is due after a book due at `due` starts at `time`: `step` after `due`,
    /// or, for a book that started more than a step late, held back or slowed by a slow frame,
    /// `step` after `time - step`. The books keep their pace while frames come faster than
    /// they are due, but lag at most one step, so a late book never leaves a backlog that would
    /// start many books in one frame: a frame starts at most two books more than are due in it.
    static func nextStart(after due: Float, startedAt time: Float, step: Float) -> Float {
        max(due, time - step) + step
    }

    // MARK: Placement

    /// How far to move the lying books across the table, by whole `tile`s in x and z, so that
    /// each slot lies at least `pileMargin` from the footprint of every book that goes after its
    /// own, which is still lying when its book lands. `books` are in chain order, with each
    /// book's size, its lying pose, and its slot's standing pose.
    ///
    /// Of the moves that clear every slot and keep the books within `reach` of the table's
    /// middle, it takes the one that leaves the books and the chain together in the smallest
    /// view of width-to-height `aspect`, so the camera can show both, and the shorter move of
    /// two that fit alike. When no move clears every slot, it takes the one that clears the
    /// most.
    static func offset(
        of books: [(size: SIMD3<Float>, lying: Transform, slot: Transform)], aspect: Float,
        reach: Float = 80
    ) -> SIMD3<Float> {
        guard !books.isEmpty else { return .zero }
        let slots = books.map { Footprint(Box($0.slot, size: $0.size)).grown(by: pileMargin / 2) }
        let lying = books.map { Footprint(Box($0.lying, size: $0.size)).grown(by: pileMargin / 2) }
        let chain = (
            low: slots.map(\.low).reduce(slots[0].low, pointwiseMin),
            high: slots.map(\.high).reduce(slots[0].high, pointwiseMax)
        )
        let pile = (
            low: lying.map(\.low).reduce(lying[0].low, pointwiseMin),
            high: lying.map(\.high).reduce(lying[0].high, pointwiseMax)
        )
        var candidates: [(offset: SIMD2<Float>, size: Float)] = []
        for x in -5...5 {
            for z in -5...5 {
                let offset = SIMD2(Float(x), Float(z)) * tile
                let moved = (low: pile.low + offset, high: pile.high + offset)
                guard all(abs(moved.low) .< reach), all(abs(moved.high) .< reach) else {
                    continue
                }
                let extent =
                    pointwiseMax(chain.high, moved.high) - pointwiseMin(chain.low, moved.low)
                // The view's height that shows the books, about, with the table foreshortened
                // by the camera's pitch.
                let size = max(extent.x / aspect, extent.y * sin(PileCamera.pitch))
                candidates.append((offset, size + simd_length(offset) * 1e-3))
            }
        }
        candidates.sort { $0.size < $1.size }
        var best: (offset: SIMD2<Float>, blocked: Int)?
        for candidate in candidates {
            var blocked = 0
            for (index, slot) in slots.enumerated() {
                for later in lying[(index + 1)...]
                where slot.overlaps(later.offset(by: candidate.offset)) {
                    blocked += 1
                }
                if let best, blocked >= best.blocked { break }
            }
            if blocked == 0 { return [candidate.offset.x, 0, candidate.offset.y] }
            if blocked < best?.blocked ?? .max { best = (candidate.offset, blocked) }
        }
        let offset = best?.offset ?? .zero
        return [offset.x, 0, offset.y]
    }

    // MARK: Moves

    /// One book's way from where it lies to its slot: it turns up onto its tail, then hops.
    struct Move: Sendable {
        /// When the book starts, in seconds since the setup started.
        let start: Float
        /// Where the book lies as it starts, and its size.
        let from: Transform
        let size: SIMD3<Float>
        /// The point the book turns about to stand up, the axis, and the angle of the turn.
        let pivot: SIMD3<Float>
        let axis: SIMD3<Float>
        let angle: Float
        /// The book standing upright where it rose, and in its slot.
        let upright: Transform
        let to: Transform
        /// How far the hop's arc rises above the line between its ends, at its middle.
        let lift: Float
        /// The bounds the book passes through on its way, standing in its slot included.
        let sweep: Bounds

        /// The move of a book of `size`, lying at `from`, starting at `start` toward its slot's
        /// standing pose `to`, with an arc that rises `lift`.
        ///
        /// The book turns about the axis that tips its tail-to-head axis straight up the
        /// shortest way, through the lowest point of its tail face, the edge it rests on. A book
        /// lying flat turns up about its tail edge's bottom, and a fallen domino rises back the
        /// way it fell.
        init(start: Float, from: Transform, size: SIMD3<Float>, to: Transform, lift: Float) {
            self.start = start
            self.from = from
            self.size = size
            self.to = to
            self.lift = lift
            let up = SIMD3<Float>(0, 1, 0)
            let length = from.rotation.act([0, 1, 0])
            angle = acos(min(max(simd_dot(length, up), -1), 1))
            var axis = simd_cross(length, up)
            if simd_length(axis) < 1e-4 {
                // Upright already, or on its head: any level axis across the book.
                let across = from.rotation.act([1, 0, 0])
                axis =
                    simd_length(SIMD2(across.x, across.z)) > 1e-4
                    ? [across.x, 0, across.z] : [1, 0, 0]
            }
            self.axis = simd_normalize(axis)
            let tail = from.translation - length * size.y / 2
            let across = from.rotation.act([1, 0, 0]) * size.x / 2
            let depth = from.rotation.act([0, 0, 1]) * size.z / 2
            let corners = [
                tail - across - depth, tail + across - depth, tail + across + depth,
                tail - across + depth,
            ]
            let lowest = corners.map(\.y).min() ?? tail.y
            let low = corners.filter { $0.y < lowest + 1e-3 }
            pivot = low.reduce(.zero, +) / Float(max(low.count, 1))
            let turn = simd_quatf(angle: angle, axis: self.axis)
            upright = Transform(
                rotation: turn * from.rotation,
                translation: pivot + turn.act(from.translation - pivot))
            sweep = Self.sweep(
                from: from, upright: upright, to: to, size: size, lift: lift, pivot: pivot,
                axis: self.axis, angle: angle)
        }

        /// How long the turn up onto the tail takes: `quarterTurn` for a quarter turn, in
        /// proportion to the angle, and none for a book that stands already.
        var rightingTime: Float {
            angle < 0.01 ? 0 : max(0.12, quarterTurn * angle / (.pi / 2))
        }

        /// How long the hop takes: as long as a body thrown up by `lift` takes to come down under
        /// the desk's gravity, so the arc falls as a book would, and at least `shortestHop`.
        var hopTime: Float { Self.hopTime(lift: lift) }

        static func hopTime(lift: Float) -> Float {
            max(shortestHop, (8 * lift / PileLayout.gravity).squareRoot())
        }

        /// When the book stands in its slot, in seconds since the setup started.
        var end: Float { start + rightingTime + hopTime }

        /// Whether the book is in the air `time` seconds into the setup: from the end of its turn
        /// until it stands in its slot.
        func isHopping(at time: Float) -> Bool {
            time >= start + rightingTime && time < end
        }

        /// The book's pose `time` seconds into the setup: lying until it starts, turning up onto
        /// its tail, hopping, and then standing in its slot.
        func pose(at time: Float) -> Transform {
            let local = time - start
            guard local > 0 else { return from }
            let righting = rightingTime
            if local < righting {
                // Smoothstep, whose top speed, half again the average, is lower than
                // smootherstep's.
                let share = local / righting
                return Self.righted(
                    from, pivot: pivot, axis: axis, angle: angle * share * share * (3 - 2 * share))
            }
            let progress = (local - righting) / hopTime
            guard progress < 1 else { return to }
            return Self.hop(from: upright, to: to, size: size, lift: lift, progress: progress)
        }

        /// `from` turned by `angle` about `axis` through `pivot`.
        static func righted(
            _ from: Transform, pivot: SIMD3<Float>, axis: SIMD3<Float>, angle: Float
        )
            -> Transform
        {
            let turn = simd_quatf(angle: angle, axis: axis)
            return Transform(
                rotation: turn * from.rotation,
                translation: pivot + turn.act(from.translation - pivot))
        }

        /// The pose `progress` of the way, from 0 to 1, through a hop from `upright` to `to`.
        ///
        /// The underside follows a parabola that rises `lift` above the line between the ends,
        /// so the book leaves upward and lands falling. It carries across along smootherstep,
        /// done at `arrival` of the way, and turns about the vertical as it goes, so it drops the
        /// rest straight down onto its slot.
        static func hop(
            from upright: Transform, to: Transform, size: SIMD3<Float>, lift: Float, progress: Float
        ) -> Transform {
            let share = min(max(progress, 0), 1)
            let across = DominoCameraRig.ease(min(1, share / arrival))
            let start = upright.translation
            let end = to.translation
            let low = start.y - size.y / 2
            let bottom = low + (end.y - size.y / 2 - low) * share + 4 * lift * share * (1 - share)
            let middle =
                SIMD2(start.x, start.z) + (SIMD2(end.x, end.z) - SIMD2(start.x, start.z)) * across
            return Transform(
                rotation: DominoSetup.turn(upright.rotation, to: to.rotation, by: across),
                translation: [middle.x, bottom + size.y / 2, middle.y])
        }

        /// The bounds of the book's way, sampled every `checkStep`, standing in its slot
        /// included.
        private static func sweep(
            from: Transform, upright: Transform, to: Transform, size: SIMD3<Float>, lift: Float,
            pivot: SIMD3<Float>, axis: SIMD3<Float>, angle: Float
        ) -> Bounds {
            var bounds = Box(from, size: size).bounds.union(Box(to, size: size).bounds)
            for step in 1...8 {
                let pose = righted(from, pivot: pivot, axis: axis, angle: angle * Float(step) / 8)
                bounds = bounds.union(Box(pose, size: size).bounds)
            }
            let steps = max(8, Int(hopTime(lift: lift) / checkStep))
            for step in 0...steps {
                let pose = hop(
                    from: upright, to: to, size: size, lift: lift,
                    progress: Float(step) / Float(steps))
                bounds = bounds.union(Box(pose, size: size).bounds)
            }
            return bounds
        }
    }

    /// The least lift, within `lifts`, for a hop from `upright` to `to` whose underside clears,
    /// by `clearance`, each of `obstacles` that the book's footprint crosses while it carries
    /// across. Obstacles the book stands among as it leaves, such as the pile around it, do not
    /// count: it rises out of them.
    static func lift(
        from upright: Transform, to: Transform, size: SIMD3<Float>, over obstacles: [Box]
    ) -> Float {
        let start = Footprint(Box(upright, size: size))
        let first = SIMD2(upright.translation.x, upright.translation.z)
        let last = SIMD2(to.translation.x, to.translation.z)
        // The book turns only about the vertical, so its footprint stays within half its
        // diagonal across the table of the line between its ends. Books farther from that
        // line cannot lie under it, which leaves out most of a large pile at once.
        let reach = simd_length(SIMD2(size.x, size.z)) / 2
        let crossed = obstacles.compactMap { box -> (footprint: Footprint, top: Float)? in
            let middle = SIMD2(box.center.x, box.center.z)
            guard distance(from: middle, toSegment: first, last) < reach + simd_length(box.half)
            else { return nil }
            let footprint = Footprint(box)
            return start.overlaps(footprint) ? nil : (footprint, box.bounds.high.y)
        }
        guard !crossed.isEmpty else { return lifts.lowerBound }
        let low = upright.translation.y - size.y / 2
        let end = to.translation.y - size.y / 2
        // A sample every 0.2 units of the way, at least, so the footprints overlap from one to
        // the next and pass over no book unseen.
        let travel = simd_distance(
            SIMD2(upright.translation.x, upright.translation.z),
            SIMD2(to.translation.x, to.translation.z))
        let samples = min(max(24, Int(travel / 0.2)), 400)
        var lift = lifts.lowerBound
        for sample in 1..<samples {
            let across = Float(sample) / Float(samples)
            // The share of the hop at which the book has carried `across` of the way.
            let share = arrival * inverseEase(across)
            let pose = Move.hop(from: upright, to: to, size: size, lift: 0, progress: share)
            let footprint = Footprint(Box(pose, size: size))
            var top: Float?
            for obstacle in crossed where footprint.overlaps(obstacle.footprint) {
                top = max(top ?? obstacle.top, obstacle.top)
            }
            guard let top else { continue }
            let line = low + (end - low) * share
            lift = max(lift, (top + clearance - line) / (4 * share * (1 - share)))
        }
        return min(lift, lifts.upperBound)
    }

    /// The distance from `point` to the segment from `start` to `end`.
    static func distance(
        from point: SIMD2<Float>, toSegment start: SIMD2<Float>, _ end: SIMD2<Float>
    ) -> Float {
        let line = end - start
        let length = simd_length_squared(line)
        let share = length > 1e-8 ? min(max(simd_dot(point - start, line) / length, 0), 1) : 0
        return simd_distance(point, start + line * share)
    }

    /// The progress at which smootherstep reaches `value`, by bisection.
    static func inverseEase(_ value: Float) -> Float {
        var (low, high): (Float, Float) = (0, 1)
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if DominoCameraRig.ease(middle) < value { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// `from` turned `share` of the way to `to`, the shorter way.
    static func turn(_ from: simd_quatf, to: simd_quatf, by share: Float) -> simd_quatf {
        var turn = to * from.inverse
        if turn.real < 0 { turn = simd_quatf(vector: -turn.vector) }
        return turn.angle < 1e-4
            ? to : simd_quatf(angle: turn.angle * share, axis: turn.axis) * from
    }

    // MARK: Schedule

    /// The moves under way and done, in chain order, which `move(from:size:to:at:among:)`
    /// checks each new move against.
    struct Schedule: Sendable {
        private(set) var moves: [Move] = []
        /// Each move's book standing in its slot, and its bounds.
        private var standing: [Box] = []
        private var standingBounds: [Bounds] = []

        init() {}

        /// A move for the next book, of `size`, lying at `from`, toward its slot's standing pose
        /// `to`, starting at `time`, or `nil` while its way would cross a book that still moves
        /// there. `lying` holds the books that have yet to go, which its arc clears too.
        ///
        /// The arc first rises just high enough over the books it passes over
        /// (`lift(from:to:size:over:)`). Should the book still cross a book standing in its slot,
        /// on the way or once it stands, the arc rises higher, up to the most `lifts` allow.
        func move(
            from: Transform, size: SIMD3<Float>, to: Transform, at time: Float, among lying: [Box]
        ) -> Move? {
            let righted = Move(start: time, from: from, size: size, to: to, lift: lifts.lowerBound)
            var lift = DominoSetup.lift(
                from: righted.upright, to: to, size: size, over: standing + lying)
            while true {
                let move = Move(start: time, from: from, size: size, to: to, lift: lift)
                switch conflict(move) {
                case nil: return move
                case .moving: return nil
                case .standing:
                    guard lift < lifts.upperBound else { return nil }
                    // Half again as high, at least 0.75 higher, so few checks reach the top.
                    lift = min(lift + max(0.75, lift / 2), lifts.upperBound)
                }
            }
        }

        /// Adds `move`, which later moves then keep clear of.
        mutating func commit(_ move: Move) {
            moves.append(move)
            let box = Box(move.to, size: move.size)
            standing.append(box)
            standingBounds.append(box.bounds)
        }

        private enum Conflict {
            case moving, standing
        }

        /// Whether `move` crosses an earlier book, while that book moves or once it stands,
        /// sampled every `checkStep` until every book it can meet stands. Boxes shrink by a
        /// hair, so books that touch, as neighbors on a turn nearly do, do not count. At each
        /// sample, a book whose whole way lies clear of the moving book's bounds costs no pose.
        private func conflict(_ move: Move) -> Conflict? {
            let near = moves.indices.filter { moves[$0].sweep.overlaps(move.sweep) }
            guard !near.isEmpty else { return nil }
            let last = near.map { moves[$0].end }.reduce(move.end, max)
            var time = move.start
            while true {
                let box = Box(move.pose(at: time), size: move.size, grow: -0.01)
                let bounds = box.bounds
                for index in near {
                    let other = moves[index]
                    guard other.sweep.overlaps(bounds) else { continue }
                    if time >= other.end {
                        if standingBounds[index].overlaps(bounds), standing[index].overlaps(box) {
                            return .standing
                        }
                        continue
                    }
                    let book = Box(other.pose(at: time), size: other.size, grow: -0.01)
                    if book.bounds.overlaps(bounds), book.overlaps(box) { return .moving }
                }
                guard time < last else { return nil }
                time = min(time + checkStep, last)
            }
        }
    }

    // MARK: Geometry

    /// A book's box: its middle, its axes as columns, and half its size along them.
    struct Box: Sendable {
        let center: SIMD3<Float>
        let axes: simd_float3x3
        let half: SIMD3<Float>

        /// The box of a book of `size` at `pose`, grown by `grow` on every side.
        init(_ pose: Transform, size: SIMD3<Float>, grow: Float = 0) {
            center = pose.translation
            axes = simd_float3x3(pose.rotation)
            half = pointwiseMax(size / 2 + grow, .zero)
        }

        /// The box's bounds along the table's axes.
        var bounds: Bounds {
            let reach =
                abs(axes.columns.0) * half.x + abs(axes.columns.1) * half.y
                + abs(axes.columns.2) * half.z
            return Bounds(low: center - reach, high: center + reach)
        }

        /// Whether the boxes overlap, by the separating axis test: they do unless some axis,
        /// one of either box's or a cross product of one of each, separates their projections.
        func overlaps(_ other: Box) -> Bool {
            let offset = other.center - center
            let (a0, a1, a2) = axes.columns
            let (b0, b1, b2) = other.axes.columns
            func separates(_ axis: SIMD3<Float>) -> Bool {
                guard simd_length_squared(axis) > 1e-8 else { return false }
                let reach =
                    half.x * abs(simd_dot(a0, axis)) + half.y * abs(simd_dot(a1, axis))
                    + half.z * abs(simd_dot(a2, axis)) + other.half.x * abs(simd_dot(b0, axis))
                    + other.half.y * abs(simd_dot(b1, axis))
                    + other.half.z * abs(simd_dot(b2, axis))
                return abs(simd_dot(offset, axis)) > reach
            }
            return
                !(separates(a0) || separates(a1) || separates(a2) || separates(b0)
                || separates(b1) || separates(b2) || separates(simd_cross(a0, b0))
                || separates(simd_cross(a0, b1)) || separates(simd_cross(a0, b2))
                || separates(simd_cross(a1, b0)) || separates(simd_cross(a1, b1))
                || separates(simd_cross(a1, b2)) || separates(simd_cross(a2, b0))
                || separates(simd_cross(a2, b1)) || separates(simd_cross(a2, b2)))
        }
    }

    /// Bounds along the table's axes.
    struct Bounds: Sendable, Equatable {
        var low: SIMD3<Float>
        var high: SIMD3<Float>

        func union(_ other: Bounds) -> Bounds {
            Bounds(low: pointwiseMin(low, other.low), high: pointwiseMax(high, other.high))
        }

        func overlaps(_ other: Bounds) -> Bool {
            all(low .< other.high) && all(other.low .< high)
        }
    }

    /// A box's footprint on the table: a rectangle along the box's own level axes for a box that
    /// stands or lies level, and its bounds across the table for a tilted one. Points on the
    /// table are x and z.
    struct Footprint: Sendable {
        let center: SIMD2<Float>
        let first: SIMD2<Float>
        let second: SIMD2<Float>
        let half: SIMD2<Float>
        /// The footprint's bounds across the table, as its least and greatest x and z.
        let low: SIMD2<Float>
        let high: SIMD2<Float>

        init(_ box: Box) {
            let (x, y, z) = box.axes.columns
            let center = SIMD2(box.center.x, box.center.z)
            func level(_ axis: SIMD3<Float>) -> SIMD2<Float> {
                simd_normalize(SIMD2(axis.x, axis.z))
            }
            if abs(y.y) > 0.9999 {
                self.init(
                    center: center, first: level(x), second: level(z),
                    half: [box.half.x, box.half.z])
            } else if abs(z.y) > 0.9999 {
                self.init(
                    center: center, first: level(x), second: level(y),
                    half: [box.half.x, box.half.y])
            } else if abs(x.y) > 0.9999 {
                self.init(
                    center: center, first: level(y), second: level(z),
                    half: [box.half.y, box.half.z])
            } else {
                let bounds = box.bounds
                let half = SIMD2(bounds.high.x - bounds.low.x, bounds.high.z - bounds.low.z) / 2
                self.init(center: center, first: [1, 0], second: [0, 1], half: half)
            }
        }

        private init(
            center: SIMD2<Float>, first: SIMD2<Float>, second: SIMD2<Float>, half: SIMD2<Float>
        ) {
            self.center = center
            self.first = first
            self.second = second
            self.half = half
            let reach = abs(first) * half.x + abs(second) * half.y
            low = center - reach
            high = center + reach
        }

        /// The footprint grown by `margin` on every side.
        func grown(by margin: Float) -> Footprint {
            Footprint(center: center, first: first, second: second, half: half + margin)
        }

        /// The footprint moved by `offset` across the table.
        func offset(by offset: SIMD2<Float>) -> Footprint {
            Footprint(center: center + offset, first: first, second: second, half: half)
        }

        /// Whether the footprints overlap: their bounds first, then by the separating axis test.
        func overlaps(_ other: Footprint) -> Bool {
            guard all(low .< other.high), all(other.low .< high) else { return false }
            let offset = other.center - center
            for axis in [first, second, other.first, other.second] {
                let reach =
                    half.x * abs(simd_dot(first, axis)) + half.y * abs(simd_dot(second, axis))
                    + other.half.x * abs(simd_dot(other.first, axis))
                    + other.half.y * abs(simd_dot(other.second, axis))
                if abs(simd_dot(offset, axis)) >= reach { return false }
            }
            return true
        }
    }
}
