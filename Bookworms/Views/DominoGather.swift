import RealityKit
import simd

extension DominoFinale {
    /// The gravity the books' hops into the spread fall under: the desk's, so a book hops as a
    /// book thrown on this desk falls.
    static let gatherGravity: Float = PileLayout.gravity
    /// The shortest and longest a book's hop into the spread takes, in seconds, and how much
    /// longer a hop takes for each unit it carries across the table. Even the shortest hop
    /// rises well clear of the books standing beside it before it tips.
    static let hopTimes: ClosedRange<Float> = 0.75...1.25
    static let hopPace: Float = 0.02
    /// The shares of a hop until which the book springs straight up out from among the books
    /// standing beside it, until which it stays upright, and after which it moves straight down
    /// onto its place, lying as its place does, so it never sweeps through the books beside it.
    static let springShare: Float = 0.2
    static let tiltShare: Float = 0.25
    static let gatherArrival: Float = 0.8
    /// The most a hop's path bows to one side, as a share of the way across, and in units.
    static let bowShare: Float = 0.1
    static let longestBow: Float = 1.5
    /// How long after a book lying on another starts to rise that other rises, at least, in
    /// seconds, and how long after the books its place rests on land a book lands, at least.
    static let riseGap: Float = 1.0 / 240
    static let landGap: Float = 0.1
    /// When the books out of view, and the books in view, may start to rise, in seconds after
    /// the gathering starts: one after another, in the chain's order, over these spans.
    static let hiddenStarts: ClosedRange<Float> = 0...0.25
    static let shownStarts: ClosedRange<Float> = 0.3...0.9
    /// The most a gathering may speed up to land in time, as a share of its pace.
    static let fastest: Float = 1.6
    /// The longest a book stands, once it has risen, before its hop, in seconds, varied from
    /// book to book.
    static let longestIdle: Float = 0.6

    /// When each book may start to rise, in seconds after the gathering starts, for books in the
    /// chain's order that each show in the view or not: the books out of view at once, so the
    /// gathering gets going while the end of the chain still shows fallen, and the books in view
    /// after them, each group one after another down the chain, as the chain fell.
    static func starts(shown: [Bool]) -> [Float] {
        let hidden = shown.filter { !$0 }.count
        var counts = (hidden: 0, shown: 0)
        return shown.map { isShown in
            let (span, index, total) =
                isShown
                ? (shownStarts, counts.shown, shown.count - hidden)
                : (hiddenStarts, counts.hidden, hidden)
            if isShown { counts.shown += 1 } else { counts.hidden += 1 }
            let share = total > 1 ? Float(index) / Float(total - 1) : 0
            return span.lowerBound + (span.upperBound - span.lowerBound) * share
        }
    }

    /// The fallen books' ways into the spread, planned once as they start to gather, so that
    /// no book passes through another.
    ///
    /// The chain first rises back up the way it fell, as its fall played backward: each book
    /// turns back up about the edge it fell on, as the setup's books right themselves
    /// (`DominoSetup.Move`), no sooner than `starts(shown:)` lets it and once the books lying on
    /// it have started to. A book lying on others higher than `tableReach` hops from where it
    /// lies instead, and a book whose tail rests on another higher than `onTable` hops before
    /// that book rises. Where two rising books would meet, as the desk's physics can leave fallen
    /// books, one rises once the other stands, unless books would then wait on each other in a
    /// loop. Each book then stands where it rose, a moment of
    /// its own (`longestIdle`), until it hops into its place: it springs straight up out from
    /// among the books standing beside it, then tips to lie as its place does as it carries
    /// across on an arc that falls under `gatherGravity`, bowing a little to one side, and drops
    /// the last stretch straight down onto its place. Each hop takes its own time, longer the
    /// farther it carries, so the books land at their own pace rather than together.
    ///
    /// The books are planned one at a time, first the book ready first whose place's books,
    /// those it rests on and those that lie or stand there, are planned. Each hops as soon as
    /// its way, checked every `checkStep` with room to spare in the air, meets none of the books
    /// planned before it, nor the books still to hop, rising and standing, landing `landGap`
    /// after the books its place rests on; while it would meet one, it waits longer, or hops a
    /// little longer or shorter, and so higher or lower. A book that only books still to hop
    /// block waits for them to go first. A gathering that would land later than `budget` speeds
    /// up, by up to `fastest`, which keeps every book's way and so keeps them apart.
    struct Gather: Sendable {
        /// One book's way into its place. Times are seconds after the books start to gather.
        struct Flight: Sendable {
            /// The book's turn back up from where it lies, which starts as it rises and ends
            /// with it standing upright where it rose (`DominoSetup.Move.upright`).
            let rising: DominoSetup.Move
            /// The book's place.
            let to: Transform
            /// When the book hops, and when it lands in its place, at the planned pace.
            let hop: Float
            let lands: Float
            /// How far the hop's arc rises above the line between its ends, at its middle, and
            /// how far the path bows to its left, across the table, at its middle.
            let lift: Float
            let bow: Float
            /// How many times faster than planned the book moves.
            let pace: Float

            /// Where the book lies as the books start to gather.
            var from: Transform { rising.from }
            /// When the book starts to rise, stands, hops, and lands.
            var rise: Float { rising.start / pace }
            var stands: Float { (rising.start + rising.rightingTime) / pace }
            var start: Float { hop / pace }
            var landing: Float { lands / pace }

            /// The book's pose `time` seconds after the books start to gather.
            func pose(at time: Float) -> Transform {
                let time = time * pace
                guard time >= hop else {
                    return rising.pose(at: min(time, rising.start + rising.rightingTime))
                }
                guard time < lands else { return to }
                let share = (time - hop) / (lands - hop)
                let upright = rising.upright
                let across = DominoCameraRig.ease(
                    min(
                        max(
                            (share - DominoFinale.springShare)
                                / (DominoFinale.gatherArrival - DominoFinale.springShare), 0), 1))
                let first = SIMD2(upright.translation.x, upright.translation.z)
                let way = SIMD2(to.translation.x, to.translation.z) - first
                let length = simd_length(way)
                let side = length > 1e-4 ? SIMD2(-way.y, way.x) / length : .zero
                let point = first + way * across + side * bow * sin(.pi * across)
                let height =
                    upright.translation.y + (to.translation.y - upright.translation.y) * share
                    + 4 * lift * share * (1 - share)
                let tilt = DominoCameraRig.ease(
                    min(
                        max(
                            (share - DominoFinale.tiltShare)
                                / (DominoFinale.gatherArrival - DominoFinale.tiltShare), 0), 1))
                return Transform(
                    scale: to.scale,
                    rotation: DominoSetup.turn(upright.rotation, to: to.rotation, by: tilt),
                    translation: [point.x, height, point.y])
            }
        }

        /// Each book's way, in the spread's order.
        let flights: [Flight]

        /// When the last book lands.
        var landed: Float { flights.map(\.landing).max() ?? 0 }

        private init(flights: [Flight]) { self.flights = flights }

        /// The same ways, sped up as much as they must to land by `budget`, by up to `fastest`
        /// as planned, as a gathering that started later than planned needs.
        func paced(within budget: Float) -> Gather {
            let last = flights.map(\.lands).max() ?? 0
            let pace = last > budget ? min(last / max(budget, 1e-3), DominoFinale.fastest) : 1
            guard pace > (flights.first?.pace ?? 1) else { return self }
            return Gather(
                flights: flights.map {
                    Flight(
                        rising: $0.rising, to: $0.to, hop: $0.hop, lands: $0.lands, lift: $0.lift,
                        bow: $0.bow, pace: pace)
                })
        }

        /// The ways of `books`, in the spread's order, each from where it lies to its place, with
        /// its size (see `BookShape.size`), none rising sooner than its `earliest`, in seconds
        /// after the books start to gather, and every book landing by `budget`, if speeding up
        /// allows.
        init(
            _ books: [(from: Transform, to: Transform, size: SIMD3<Float>)],
            earliest: [Float]? = nil, budget: Float = .infinity
        ) {
            let count = books.count
            guard count > 0 else {
                self.flights = []
                return
            }
            let earliest = earliest ?? Array(repeating: 0, count: count)
            let lying = books.map { DominoSetup.Box($0.from, size: $0.size, grow: -0.01) }
            let places = books.map { DominoSetup.Box($0.to, size: $0.size, grow: -0.01) }
            // A book whose tail rests on the table, or a little above it, turns back up once the
            // books lying on it have started to. One lying higher on others hops from where it
            // lies, and the books under a book that rests higher than `onTable` rise once it has
            // sprung clear of them.
            var above = Array(repeating: Set<Int>(), count: count)
            for (upper, lowers) in Self.under(lying).enumerated() {
                for lower in lowers { above[lower].insert(upper) }
            }
            let pivots = books.indices.map {
                DominoSetup.Move(
                    start: 0, from: books[$0].from, size: books[$0].size, to: books[$0].to,
                    lift: 0
                )
                .pivot.y
            }
            let rights = pivots.map { $0 < Self.tableReach }
            let leavesFirst = pivots.map { $0 > Self.onTable }
            var risings = books.indices.map { index in
                DominoSetup.Move(
                    start: earliest[index], from: books[index].from, size: books[index].size,
                    to: books[index].to, lift: 0, rights: rights[index])
            }
            var planned = [Flight?](repeating: nil, count: count)
            // For each book, the books it rises once they stand.
            var waitsFor = Array(repeating: Set<Int>(), count: count)
            // When each book rises, after the books lying on it, those planned or not.
            func rise() {
                var risen = Set<Int>()
                for book in Self.order(books.indices.map { above[$0].union(waitsFor[$0]) }) {
                    var time = earliest[book]
                    for other in waitsFor[book] {
                        let rising = risings[other]
                        time = max(
                            time,
                            rising.start + rising.rightingTime + DominoFinale.riseGap)
                    }
                    for upper in above[book] where risen.contains(upper) || planned[upper] != nil {
                        if let flight = planned[upper], leavesFirst[upper] {
                            let spring =
                                flight.hop + (flight.lands - flight.hop) * DominoFinale.springShare
                            time = max(time, spring + DominoFinale.riseGap)
                        } else if !leavesFirst[upper] {
                            time = max(time, risings[upper].start + DominoFinale.riseGap)
                        } else {
                            time = max(
                                time, risings[upper].start + DominoFinale.hopTimes.upperBound)
                        }
                    }
                    if planned[book] == nil {
                        risings[book] = DominoSetup.Move(
                            start: time, from: books[book].from, size: books[book].size,
                            to: books[book].to, lift: 0, rights: rights[book])
                    }
                    risen.insert(book)
                }
            }
            rise()
            // Where a book rising back up would meet another, as the desk's physics can leave
            // fallen books, it rises once the other stands: a book that would meet one still
            // lying waits for it, and otherwise the later of the two to rise does.
            for _ in 0..<3 {
                let tracks = books.indices.map { Track(risings[$0], lying: lying[$0]) }
                var later = false
                for first in books.indices {
                    for second in books.indices
                    where second > first && tracks[first].reach.overlaps(tracks[second].reach) {
                        let (one, other) = (tracks[first], tracks[second])
                        let steps =
                            min(
                                one.start, other.start)...max(
                                one.start + one.boxes.count, other.start + other.boxes.count)
                        guard
                            let step = steps.first(where: { step in
                                let (a, b) = (one.at(step), other.at(step))
                                return a.bounds.overlaps(b.bounds) && a.box.overlaps(b.box)
                            })
                        else { continue }
                        let (waits, leads) =
                            step < other.start
                            ? (first, second)
                            : step < one.start
                                ? (second, first)
                                : (risings[first].start, first) > (risings[second].start, second)
                                    ? (first, second) : (second, first)
                        // A book never waits on a book that waits on it, however far down.
                        var seen: Set<Int> = [leads]
                        var queue = [leads]
                        while let next = queue.popLast() {
                            for other in above[next].union(waitsFor[next])
                            where seen.insert(other).inserted {
                                queue.append(other)
                            }
                        }
                        guard !seen.contains(waits) else { continue }
                        later = waitsFor[waits].insert(leads).inserted || later
                    }
                }
                guard later else { break }
                rise()
            }
            let uprights = books.indices.map {
                DominoSetup.Box(risings[$0].upright, size: books[$0].size, grow: -0.01)
            }
            // A book lands after the books its place rests on, and after the books that lay or
            // stood where it lands have left, if any do: the chain moves clear of the spread
            // first (`clearing(_:from:margin:)`).
            let rests = Self.under(places, earlierOnly: true)
            let covers = places.map { place -> Set<Int> in
                let footprint = DominoSetup.Footprint(place)
                return Set(
                    books.indices.filter {
                        footprint.overlaps(DominoSetup.Footprint(lying[$0]))
                            || footprint.overlaps(DominoSetup.Footprint(uprights[$0]))
                    })
            }
            let preferred = books.indices.map {
                Self.hopTime(from: risings[$0].upright, books[$0], $0)
            }
            let bows = books.indices.map { Self.bow(from: risings[$0].upright, books[$0], $0) }
            // Each book stands a moment of its own before it hops, so neighbors that rose
            // together hop apart.
            func ready(_ book: Int) -> Float {
                let rising = risings[book]
                return rising.start + rising.rightingTime
                    + DominoFinale.longestIdle * Self.unit(book, 3)
            }
            // Every book's boxes, rising and standing until it is planned, then along its way.
            var field = Field(count: count)
            for book in books.indices {
                field.set(Track(risings[book], lying: lying[book]), for: book)
            }
            // The books hop one at a time into the plan, each as soon as its way meets none of
            // the books planned before it, nor the books still to hop, standing where they
            // rose: the first book ready whose place's books have been planned goes next.
            // A book whose way only books still to hop block waits for them to go first.
            var left = Set(books.indices)
            var deferred = Set<Int>()
            while !left.isEmpty {
                let free = left.filter { book in
                    rests[book].allSatisfy { planned[$0] != nil }
                        && covers[book].allSatisfy { $0 == book || planned[$0] != nil }
                        && above[book].allSatisfy { !leavesFirst[$0] || planned[$0] != nil }
                }
                let choices = (free.isEmpty ? left : free).subtracting(deferred)
                let forced = choices.isEmpty
                guard
                    let book = (forced ? (free.isEmpty ? left : free) : choices)
                        .min(by: { (ready($0), $0) < (ready($1), $1) })
                else { break }
                guard
                    let flight = Self.plan(
                        book, earliest: ready(book), preferred: preferred[book], bow: bows[book],
                        rising: risings[book], to: books[book].to, size: books[book].size,
                        after: rests[book].compactMap { planned[$0]?.lands }, field: field,
                        planned: planned.map { $0 != nil }, forced: forced)
                else {
                    deferred.insert(book)
                    continue
                }
                planned[book] = flight
                field.set(Track(flight, lying: lying[book], placed: places[book]), for: book)
                left.remove(book)
                deferred = []
                if leavesFirst[book] {
                    let before = risings
                    rise()
                    for other in left where risings[other].start != before[other].start {
                        field.set(Track(risings[other], lying: lying[other]), for: other)
                    }
                }
            }
            self = Gather(flights: planned.compactMap { $0 }).paced(within: budget)
        }

        /// How far to move the fallen books across the table, by whole tiles of its wood
        /// (`DominoSetup.tile`), which the table does not show, so that none of `lying` lies
        /// within `margin` of any of `places`, where the books land: the shortest such move,
        /// along x and z, or none when none within three tiles clears every place.
        static func clearing(
            _ lying: [DominoSetup.Box], from places: [DominoSetup.Box], margin: Float = 1
        ) -> SIMD3<Float> {
            let books = lying.map { DominoSetup.Footprint($0).grown(by: margin / 2) }
            let spots = places.map { DominoSetup.Footprint($0).grown(by: margin / 2) }
            var moves: [SIMD2<Float>] = []
            for x in -3...3 {
                for z in -3...3 { moves.append(SIMD2(Float(x), Float(z)) * DominoSetup.tile) }
            }
            for move in moves.sorted(by: { simd_length($0) < simd_length($1) }) {
                let moved = books.map { $0.offset(by: move) }
                if !moved.contains(where: { book in spots.contains { $0.overlaps(book) } }) {
                    return [move.x, 0, move.y]
                }
            }
            return .zero
        }

        /// Bounds that hold the whole way of `flight`, of a book of `size`, from where it stands
        /// to its place, however it turns.
        static func reach(of flight: Flight, size: SIMD3<Float>) -> DominoSetup.Bounds {
            let ends = [flight.rising.upright.translation, flight.to.translation]
            let radius = simd_length(size) / 2 + abs(flight.bow)
            let low = ends.reduce(ends[0], pointwiseMin) - radius
            var high = ends.reduce(ends[0], pointwiseMax) + radius
            high.y += flight.lift
            return DominoSetup.Bounds(low: [low.x, 0, low.z], high: high)
        }

        /// How near the table a book's tail must rest for the book to turn back up on it, in
        /// units; a book lying higher, on other books, hops from where it lies. A book whose
        /// tail rests higher than `onTable` stands on the book under it.
        static let tableReach: Float = 0.5
        static let onTable: Float = 0.3

        /// How often a hop's way is checked against the others, and the step by which a book
        /// waits longer while its way meets another, in seconds, and the longest it waits.
        static let checkStep: Float = 1.0 / 120
        static let waitStep: Float = 1.0 / 30
        static let longestWait: Float = 3
        /// How far a hopping book's box grows on every side as the planner checks it in the
        /// air, in units, beyond how far it moves in a step, so books pass with room to spare.
        static let margin: Float = 0.03

        /// A book's boxes, shrunk a hair, and their bounds, on the planner's clock, every
        /// `checkStep` from 0: still before `start`, one for each step while it moves, and
        /// still after.
        struct Track {
            let start: Int
            let boxes: [(box: DominoSetup.Box, bounds: DominoSetup.Bounds)]
            let before: (box: DominoSetup.Box, bounds: DominoSetup.Bounds)
            let after: (box: DominoSetup.Box, bounds: DominoSetup.Bounds)
            /// Bounds that hold every box.
            let reach: DominoSetup.Bounds

            /// The track of a book that rises along `rising` from where it lies, `lying`, and
            /// stands where it rose.
            init(_ rising: DominoSetup.Move, lying: DominoSetup.Box) {
                let flight = Flight(
                    rising: rising, to: rising.upright, hop: .infinity, lands: .infinity,
                    lift: 0, bow: 0, pace: 1)
                let stood = rising.start + rising.rightingTime
                self.init(
                    from: rising.start, to: stood, size: rising.size, pose: flight.pose(at:),
                    lying: lying,
                    still: DominoSetup.Box(rising.upright, size: rising.size, grow: -0.01))
            }

            /// The track of a book along `flight`, from where it lies, `lying`, to its place,
            /// `placed`.
            init(_ flight: Flight, lying: DominoSetup.Box, placed: DominoSetup.Box) {
                self.init(
                    from: flight.rise, to: flight.landing, size: flight.rising.size,
                    pose: flight.pose(at:), lying: lying, still: placed)
            }

            private init(
                from: Float, to: Float, size: SIMD3<Float>, pose: (Float) -> Transform,
                lying: DominoSetup.Box, still: DominoSetup.Box
            ) {
                start = Int((from / checkStep).rounded(.down))
                let end = max(Int((to / checkStep).rounded(.up)), start)
                boxes = (start...end)
                    .map { step in
                        let box = DominoSetup.Box(
                            pose(Float(step) * checkStep), size: size, grow: -0.01)
                        return (box, box.bounds)
                    }
                before = (lying, lying.bounds)
                after = (still, still.bounds)
                reach = boxes.map(\.bounds)
                    .reduce(before.bounds.union(after.bounds)) {
                        $0.union($1)
                    }
            }

            /// The box at step `step` of the planner's clock.
            func at(_ step: Int) -> (box: DominoSetup.Box, bounds: DominoSetup.Bounds) {
                step < start ? before : step - start < boxes.count ? boxes[step - start] : after
            }
        }

        /// The books' tracks on the planner's clock, kept by where their boxes lie across the
        /// table, in squares `cell` units across, so a check finds the books near a box at once.
        struct Field {
            static let cell: Float = 3
            typealias Entry = (box: DominoSetup.Box, bounds: DominoSetup.Bounds)
            /// By square, each book's still boxes and the steps each holds for.
            private var still: [Int64: [Int: [(steps: Range<Int>, entry: Entry)]]] = [:]
            /// By step and square, each book's box while it moves.
            private var moving: [Int: [Int64: [Int: Entry]]] = [:]
            /// Each book's squares, still and by step.
            private var stills: [Set<Int64>]
            private var moves: [[(step: Int, square: Int64)]]

            init(count: Int) {
                stills = Array(repeating: [], count: count)
                moves = Array(repeating: [], count: count)
            }

            /// The squares `bounds` covers.
            private static func squares(_ bounds: DominoSetup.Bounds) -> [Int64] {
                let low = (bounds.low / cell).rounded(.down)
                let high = (bounds.high / cell).rounded(.down)
                var squares: [Int64] = []
                for x in Int(low.x)...Int(high.x) {
                    for z in Int(low.z)...Int(high.z) {
                        squares.append(Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(z))))
                    }
                }
                return squares
            }

            /// Keeps `track` as `book`'s, in place of any it had.
            mutating func set(_ track: Track, for book: Int) {
                for square in stills[book] { still[square]?[book] = nil }
                for (step, square) in moves[book] { moving[step]?[square]?[book] = nil }
                stills[book] = []
                moves[book] = []
                let end = track.start + track.boxes.count
                for (steps, entry) in [
                    (0..<track.start, track.before), (end..<Int.max, track.after),
                ] {
                    for square in Self.squares(entry.bounds) {
                        still[square, default: [:]][book, default: []].append((steps, entry))
                        stills[book].insert(square)
                    }
                }
                for (offset, entry) in track.boxes.enumerated() {
                    let step = track.start + offset
                    for square in Self.squares(entry.bounds) {
                        moving[step, default: [:]][square, default: [:]][book] = entry
                        moves[book].append((step, square))
                    }
                }
            }

            /// Whether `box` meets, at `step`, a book other than the one `skipping`, of those
            /// `only` lets through: `nil` when none, and otherwise whether that book stays still
            /// from then on.
            func meets(
                _ box: DominoSetup.Box, at step: Int, skipping book: Int, only: (Int) -> Bool
            ) -> Bool? {
                let bounds = box.bounds
                let low = (bounds.low / Self.cell).rounded(.down)
                let high = (bounds.high / Self.cell).rounded(.down)
                let now = moving[step]
                for x in Int(low.x)...Int(high.x) {
                    for z in Int(low.z)...Int(high.z) {
                        let square = Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(z)))
                        if let found = meets(
                            box, bounds, in: square, now, at: step, skipping: book, only: only)
                        {
                            return found
                        }
                    }
                }
                return nil
            }

            private func meets(
                _ box: DominoSetup.Box, _ bounds: DominoSetup.Bounds, in square: Int64,
                _ now: [Int64: [Int: Entry]]?, at step: Int, skipping book: Int,
                only: (Int) -> Bool
            ) -> Bool? {
                do {
                    for (other, entry) in now?[square] ?? [:]
                    where other != book && only(other) && entry.bounds.overlaps(bounds)
                        && entry.box.overlaps(box)
                    {
                        _ = entry
                        return false
                    }
                    for (other, entries) in still[square] ?? [:] where other != book && only(other)
                    {
                        for (steps, entry) in entries
                        where steps.contains(step) && entry.bounds.overlaps(bounds)
                            && entry.box.overlaps(box)
                        {
                            return steps.upperBound == .max
                        }
                    }
                }
                return nil
            }
        }

        /// The hop of the `book`th, of `size`, from `rising`'s upright pose to `to`: as soon
        /// after `earliest` as its way meets none of the other books' tracks in `field`, those
        /// `planned` and those still to hop, landing `DominoFinale.landGap` after the landings
        /// it lands `after`. Each wait also tries the hop a little longer and a little shorter than
        /// `preferred`. When only books still to hop block it however long it waits, up to
        /// `longestWait`, there is none, so they can go first, unless `forced`; a hop that
        /// planned books block goes as soon as it may, as a last resort.
        static func plan(
            _ book: Int, earliest: Float, preferred: Float, bow: Float, rising: DominoSetup.Move,
            to: Transform, size: SIMD3<Float>, after: [Float], field: Field, planned: [Bool],
            forced: Bool
        ) -> Flight? {
            // Hops start and last whole steps of the planner's clock.
            let times = [preferred, preferred + 0.15, preferred - 0.15]
                .map {
                    (min(
                        max($0, DominoFinale.hopTimes.lowerBound), DominoFinale.hopTimes.upperBound)
                        / checkStep)
                        .rounded()
                }
            let landing = (after.max() ?? -.infinity) + DominoFinale.landGap
            func flight(_ start: Float, _ steps: Float) -> Flight {
                let time = steps * checkStep
                return Flight(
                    rising: rising, to: to, hop: start * checkStep,
                    lands: (start + steps) * checkStep,
                    lift: DominoFinale.gatherGravity * time * time / 8, bow: bow, pace: 1)
            }
            /// Whether `hop` meets any other book, of those planned unless `all`, and whether it
            /// meets a book that stays still from then on, in its place or standing, which no
            /// wait gets past.
            func meets(_ hop: Flight, all: Bool) -> (meets: Bool, still: Bool) {
                let first = Int((hop.hop / checkStep).rounded())
                let last = Int((hop.lands / checkStep).rounded())
                let sprung = hop.hop + (hop.lands - hop.hop) * DominoFinale.springShare
                let carried = hop.hop + (hop.lands - hop.hop) * DominoFinale.gatherArrival
                var pose = hop.pose(at: Float(first) * checkStep)
                for step in first...last {
                    let time = Float(step) * checkStep
                    let next = hop.pose(at: time + checkStep)
                    // Room to spare in the air, as far as it moves in a step, so it passes
                    // others between the checks too; it springs up beside the books standing
                    // by it and comes down onto the books under its place.
                    let room =
                        time >= sprung && time < carried
                        ? margin + simd_distance(next.translation, pose.translation) : -0.01
                    let box = DominoSetup.Box(pose, size: size, grow: room)
                    pose = next
                    if let still = field.meets(
                        box, at: step, skipping: book, only: { all || planned[$0] })
                    {
                        return (true, still)
                    }
                }
                return (false, false)
            }
            func first(all: Bool) -> Flight? {
                var start = (earliest / checkStep).rounded(.up)
                let latest = start + (longestWait / checkStep).rounded()
                while start <= latest {
                    var still = true
                    for steps in times where (start + steps) * checkStep >= landing {
                        let hop = flight(start, steps)
                        let meeting = meets(hop, all: all)
                        guard meeting.meets else { return hop }
                        still = still && meeting.still
                    }
                    // A book that stays still in its way stays there however long it waits.
                    if still, start * checkStep >= landing { return nil }
                    start += (waitStep / checkStep).rounded()
                }
                return nil
            }
            if let hop = first(all: true) { return hop }
            if !forced, first(all: false) != nil { return nil }
            let start = (max(earliest, landing - preferred) / checkStep).rounded(.up)
            return flight(start, (preferred / checkStep).rounded())
        }

        /// The books in an order in which each comes after the books it waits for, by `after`:
        /// as soon as it may, and, where books wait on each other in a loop, the first of them
        /// first.
        static func order(_ after: [Set<Int>]) -> [Int] {
            var waiting = after.map(\.count)
            var before = Array(repeating: [Int](), count: after.count)
            for (book, others) in after.enumerated() {
                for other in others { before[other].append(book) }
            }
            var ready = Array(after.indices.filter { waiting[$0] == 0 }.reversed())
            var order: [Int] = []
            var placed = Array(repeating: false, count: after.count)
            var next = 0
            while order.count < after.count {
                if ready.isEmpty {
                    // A loop: the first book not yet placed goes next.
                    while placed[next] { next += 1 }
                    ready.append(next)
                }
                let book = ready.removeLast()
                guard !placed[book] else { continue }
                placed[book] = true
                order.append(book)
                for later in before[book] {
                    waiting[later] -= 1
                    if waiting[later] == 0, !placed[later] { ready.append(later) }
                }
            }
            return order
        }

        /// How long the hop of `book`, the `index`th in the spread's order, from `upright` takes
        /// before any repair: longer the farther it carries, varied by up to 15 percent either
        /// way.
        static func hopTime(
            from upright: Transform, _ book: (from: Transform, to: Transform, size: SIMD3<Float>),
            _ index: Int
        ) -> Float {
            let way = simd_distance(
                SIMD2(upright.translation.x, upright.translation.z),
                SIMD2(book.to.translation.x, book.to.translation.z))
            let base = DominoFinale.hopTimes.lowerBound + DominoFinale.hopPace * way
            let time = base * (0.85 + 0.3 * unit(index, 1))
            return min(
                max(time, DominoFinale.hopTimes.lowerBound), DominoFinale.hopTimes.upperBound)
        }

        /// How far the hop of `book`, the `index`th in the spread's order, from `upright` bows
        /// to its left: up to `bowShare` of the way across, to either side, and at most
        /// `longestBow`.
        static func bow(
            from upright: Transform, _ book: (from: Transform, to: Transform, size: SIMD3<Float>),
            _ index: Int
        ) -> Float {
            let way = simd_distance(
                SIMD2(upright.translation.x, upright.translation.z),
                SIMD2(book.to.translation.x, book.to.translation.z))
            return min(DominoFinale.bowShare * way, DominoFinale.longestBow)
                * (2 * unit(index, 2) - 1)
        }

        /// A number from 0 to 1 that varies from book to book, the same for each `index` and
        /// `salt`.
        static func unit(_ index: Int, _ salt: Int) -> Float {
            var value =
                UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
                ^ UInt64(truncatingIfNeeded: salt) &* 0xC2B2_AE3D_27D4_EB4F
            value ^= value >> 31
            value &*= 0xBF58_476D_1CE4_E5B9
            value ^= value >> 27
            return Float(value >> 40) / Float(1 << 24)
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
    }
}
