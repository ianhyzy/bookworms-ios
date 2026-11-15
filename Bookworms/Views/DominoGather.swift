import RealityKit
import simd

extension DominoFinale {
    /// The shortest and longest a book's flight into the spread takes, in seconds, and how much
    /// longer a flight takes for each unit it carries across the table.
    static let hopTimes: ClosedRange<Float> = 0.75...1.05
    static let hopPace: Float = 0.02
    /// The shares of a flight over which the book slides out from over the books still
    /// hovering, over which it then sinks to the height it glides at, from which it carries
    /// across the table, from which it tips to lie as its place does, and after which it moves
    /// straight down onto its place.
    static let escapeShare: Float = 0.3
    static let sinkShares: ClosedRange<Float> = 0.3...0.45
    static let acrossShare: Float = 0.35
    static let tiltShare: Float = 0.4
    static let gatherArrival: Float = 0.85
    /// How much of its flight a book covers drifting slowly out of the cloud before it speeds
    /// up, and how high it rises as it slides out, in units, clear of the tilted books it hovers
    /// over, unless it slides out level from under a tilted book still hovering over it.
    static let creepShare: Float = 0.12
    static let escapeLift: Float = 0.3
    /// The most a flight's path bows to one side, as a share of the way across, and in units.
    static let bowShare: Float = 0.1
    static let longestBow: Float = 1.5
    /// How long after the books its place rests on land a book lands, at least, in seconds.
    static let landGap: Float = 0.1
    /// How long the books take to rise off the table into the air, in seconds.
    static let hoverTime: Float = 0.7
    /// About how much higher than the cloud's lowest books the highest hovers, in units, so
    /// the books hover at heights of their own, as a cloud does, rather than lifted whole.
    static let cloudDepth: Float = 2
    /// How far a hovering book floats up and down, in units, and how long one float takes, in
    /// seconds, as a book floats in its details (`Drift`), only quicker.
    static let floatHeight: Float = 0.06
    static let floatPeriod: Float = 1.6
    /// How far across the table from where it lay a book may hover, in units, the share of
    /// books that hover just above the table, and how far above where they lay they hover, in
    /// units: their bottoms, however they turn, at least as far above where they lay and
    /// farther than they float, so they float clear of the table.
    static let cloudScatter: Float = 2.5
    static let lowShare: Float = 0.3
    static let lowLift: ClosedRange<Float> = 0.1...0.45
    /// How long after the books have risen the spread's first book speeds up out of the cloud,
    /// and how long after each book the next may, at most, in seconds: within `leaveSpan` of
    /// the first, so the more books, the more leave at once.
    static let firstLeave: Float = 0.2
    static let leaveStep: Float = 0.06
    static let leaveSpan: Float = 0.8
    /// The most a hovering book turns about the axis through its covers, and tips about its
    /// other axes, in radians, at random, so the cloud's books hover at angles of their own.
    static let hoverSpin: Float = 0.9
    static let hoverTip: Float = 0.35
    /// The most a gathering may speed up to land in time, as a share of its pace.
    static let fastest: Float = 2.2

    /// The fallen books' ways into the spread, planned once as they start to gather, so that
    /// no book passes through another.
    ///
    /// Every book but the last rises off the table at once, over `hoverTime`, into a messy cloud
    /// (`cloud`): scattered across the table from where it lay, turned at odd angles, a few
    /// just above the table and the rest at random heights above a lane clear of the spread's
    /// places, a book that lay under another often above it, along ways that meet no other
    /// book's. The books then leave one by one in the spread's order, the first `firstLeave`
    /// after they have risen and each next `leaveStep` later at soonest, or sooner for many
    /// books, all within `leaveSpan`. A book
    /// drifts slowly out from over the books still hovering, toward its place, from as soon as
    /// the books have risen where its way allows, then speeds up: it finishes sliding out,
    /// rising a little (`escapeLift`), or level from under a book still hovering over it,
    /// sinks into the lane, glides across it as it tips to lie
    /// as its place does, bowing a little to one side, and settles straight down onto its place.
    /// In the lane it passes over the books in their places and under the cloud. Each flight
    /// takes its own time, longer the farther it carries, so the books land at their own pace
    /// rather than together.
    ///
    /// The spread's last book, the last book read, rises too but stays in the air for the
    /// finale's flourish. The chain's last book, it lies under the books that fell onto it, so
    /// it waits while they rise, slides out from under the cloud along the table, and rises
    /// beside the cloud, as high as the cloud's lowest books, out of every other book's way.
    /// Its flight never starts.
    ///
    /// The books are planned one at a time, first the book ready first whose place's books are
    /// planned. Each speeds up as soon as its way, checked every `checkStep` with room to spare
    /// in the air, meets none of the books planned before it or still hovering, landing
    /// `landGap` after the books its place rests on; while it would meet one, it drifts not at
    /// all, waits longer, flies a little longer or shorter, or glides higher. A
    /// gathering that would land later than `budget` speeds up, by up to `fastest`, which keeps
    /// every book's way and so keeps them apart.
    struct Gather: Sendable {
        /// One book's way into its place. Times are seconds after the books start to rise.
        struct Flight: Sendable {
            /// Where the book lies as the books start to rise, where it hovers once risen, and
            /// its place.
            let from: Transform
            let hover: Transform
            let to: Transform
            /// When the book starts to drift out of the cloud, when it speeds up, and when it
            /// lands, at the planned pace: never, for the spread's last book.
            let drift: Float
            let hop: Float
            let lands: Float
            /// How far the book slides across the table out from over the books still hovering,
            /// and, as y, how far it rises meanwhile.
            let escape: SIMD3<Float>
            /// The height of the book's middle as it glides across the lane, and how far its
            /// path bows to its left, across the table, at its middle.
            let glide: Float
            let bow: Float
            /// How many times faster than planned the book moves once the books have risen.
            let pace: Float
            /// Whether the book slides out across the table before it rises, as the spread's
            /// last book does, how far it floats up and down as it hovers, and when its float
            /// passes its middle going up, at the planned pace.
            var slides = false
            var float: Float = 0
            var beat: Float = 0
            /// The height the book climbs at, with the books it lay against, while it slides out
            /// across the table, before it climbs to where it hovers (see `rise`).
            var ramp: Float?

            /// When the book has risen, starts to move again, and lands.
            var hovers: Float { DominoFinale.hoverTime }
            var start: Float { Self.paced(drift, pace) }
            var landing: Float { Self.paced(lands, pace) }

            /// `time`, at the planned pace, at `pace` times that pace once the books have risen.
            static func paced(_ time: Float, _ pace: Float) -> Float {
                time <= DominoFinale.hoverTime
                    ? time : DominoFinale.hoverTime + (time - DominoFinale.hoverTime) / pace
            }

            /// How far above where it hovers the book floats `time` seconds after the books start
            /// to rise, at the planned pace: none until it has risen, then easing in.
            private func floating(at time: Float) -> Float {
                let settled = DominoCameraRig.ease(
                    min(max((time - DominoFinale.hoverTime) / 0.4, 0), 1))
                return float * settled * sin(2 * .pi * (time - beat) / DominoFinale.floatPeriod)
            }

            /// `time` at the planned pace, given at the pace the book moves.
            private func planned(_ time: Float) -> Float {
                time <= DominoFinale.hoverTime
                    ? time : DominoFinale.hoverTime + (time - DominoFinale.hoverTime) * pace
            }

            /// How far along its way into its place the book is `time` seconds after the books
            /// start to rise, at the planned pace, from 0 as it starts to drift to 1 as it lands:
            /// slowly at first, gaining speed as it drifts, then steadily once it speeds up.
            func share(at time: Float) -> Float {
                guard time > drift else { return 0 }
                guard time < lands else { return 1 }
                let crept = hop > drift ? DominoFinale.creepShare : 0
                guard time >= hop else {
                    let drifted = (time - drift) / (hop - drift)
                    return crept * drifted * drifted
                }
                return crept + (1 - crept) * (time - hop) / (lands - hop)
            }

            /// The book's pose `time` seconds after the books start to rise.
            func pose(at time: Float) -> Transform {
                let time = planned(time)
                guard time >= drift else {
                    var pose = Gather.rise(
                        from: from, to: hover, slides: slides,
                        share: time / DominoFinale.hoverTime, ramp: ramp)
                    pose.translation.y += floating(at: time)
                    return pose
                }
                guard time < lands else { return to }
                let share = share(at: time)
                func eased(_ low: Float, _ high: Float) -> Float {
                    DominoCameraRig.ease(min(max((share - low) / (high - low), 0), 1))
                }
                let out = eased(0, DominoFinale.escapeShare)
                let across = eased(DominoFinale.acrossShare, DominoFinale.gatherArrival)
                let hovered = SIMD2(hover.translation.x, hover.translation.z)
                let first = hovered + SIMD2(escape.x, escape.z)
                let way = SIMD2(to.translation.x, to.translation.z) - first
                let length = simd_length(way)
                let side = length > 1e-4 ? SIMD2(-way.y, way.x) / length : .zero
                let point =
                    hovered + SIMD2(escape.x, escape.z) * out + way * across
                    + side * bow * sin(.pi * across)
                // Its float fades as it slides out, rising a little, and it sinks from there.
                let left =
                    hover.translation.y + escape.y * out + floating(at: time) * (1 - out)
                let height =
                    share < DominoFinale.gatherArrival
                    ? left + (glide - left)
                        * eased(
                            DominoFinale.sinkShares.lowerBound, DominoFinale.sinkShares.upperBound)
                    : glide + (to.translation.y - glide) * eased(DominoFinale.gatherArrival, 1)
                return Transform(
                    scale: to.scale,
                    rotation: DominoSetup.turn(
                        hover.rotation, to: to.rotation,
                        by: eased(DominoFinale.tiltShare, DominoFinale.gatherArrival)),
                    translation: SIMD3(point.x, height, point.y))
            }
        }

        /// Each book's way, in the spread's order.
        let flights: [Flight]

        /// When the last book to land lands.
        var landed: Float { flights.map(\.landing).filter(\.isFinite).max() ?? 0 }

        private init(flights: [Flight]) { self.flights = flights }

        /// The same ways, their flights sped up as much as they must to land by `budget`, by up
        /// to `fastest` as planned, as a gathering that started later than planned needs. The
        /// rise keeps its pace.
        func paced(within budget: Float) -> Gather {
            let last = flights.map(\.lands).filter(\.isFinite).max() ?? 0
            let rise = DominoFinale.hoverTime
            let pace =
                last > budget
                ? min((last - rise) / max(budget - rise, 1e-3), DominoFinale.fastest) : 1
            guard pace > (flights.first?.pace ?? 1) else { return self }
            return Gather(
                flights: flights.map {
                    Flight(
                        from: $0.from, hover: $0.hover, to: $0.to, drift: $0.drift, hop: $0.hop,
                        lands: $0.lands, escape: $0.escape, glide: $0.glide, bow: $0.bow,
                        pace: pace, slides: $0.slides, float: $0.float, beat: $0.beat,
                        ramp: $0.ramp)
                })
        }

        /// The ways of `books`, in the spread's order, each from where it lies to its place, with
        /// its size (see `BookShape.size`), every book landing by `budget`, in seconds after
        /// the books start to rise, if speeding up allows. The last book stays in the air.
        init(
            _ books: [(from: Transform, to: Transform, size: SIMD3<Float>)],
            budget: Float = .infinity
        ) {
            let count = books.count
            guard count > 0 else {
                self.flights = []
                return
            }
            let last = count - 1
            let lying = books.map { DominoSetup.Box($0.from, size: $0.size, grow: -0.01) }
            let places = books.map { DominoSetup.Box($0.to, size: $0.size, grow: -0.01) }
            // Each book glides with its lowest corner clear above the spread's places, as high
            // as it reaches over the turn from how it hovers to how its place lies, and the
            // cloud's books, but for the few that hover low and leave first, hover clear above
            // the highest gliding book, however `cloud` turns them.
            func reach(_ from: simd_quatf, _ book: Int) -> Float {
                stride(from: Float(0), through: 1, by: 0.1)
                    .map { share in
                        DominoSetup.Box(
                            Transform(
                                rotation: DominoSetup.turn(
                                    from, to: books[book].to.rotation, by: share)),
                            size: books[book].size
                        )
                        .bounds.high.y
                    }
                    .max() ?? 0
            }
            let reaches = books.indices.dropLast()
                .map { book in
                    ([books[book].from.rotation]
                        + Self.hoverTurns(book, from: books[book].from.rotation))
                        .map { reach($0, book) }.max() ?? 0
                }
            let top = places.map(\.bounds.high.y).max() ?? 0
            let floor = top + 2 * (reaches.max() ?? 0) + 2 * Self.laneRoom + Self.laneDepth
            let lowest = lying.map(\.bounds.low.y).min() ?? 0
            var hovers = books.map { book in
                var hover = book.from
                hover.translation.y += floor - lowest
                return hover
            }
            hovers[last].translation +=
                Self.slide(lying[last], clearOf: lying.dropLast())
            let float = DominoFinale.floatHeight
            let ramp = Self.ramp(under: Self.under(lying), skipping: last)
            for book in books.indices { hovers[book].translation.y += ramp[book] }
            let ramps = hovers.map(\.translation.y)
            hovers = Self.cloud(
                books, hovers: hovers, sliding: last, floating: float, lift: floor - lowest)
            let turns = hovers.map(\.rotation)
            let glides = books.indices.map { top + reach(turns[$0], $0) + Self.laneRoom }
            let hovering = books.indices.map {
                DominoSetup.Box(hovers[$0], size: books[$0].size, grow: -0.01)
            }
            let rests = Self.under(places, earlierOnly: true)
            let preferred = books.indices.map {
                Self.hopTime(from: hovers[$0], to: books[$0].to, $0)
            }
            let bows = books.indices.map { Self.bow(from: hovers[$0], to: books[$0].to, $0) }
            // The books leave one by one in the spread's order.
            func ready(_ book: Int) -> Float {
                DominoFinale.hoverTime + DominoFinale.firstLeave
                    + min(DominoFinale.leaveStep, DominoFinale.leaveSpan / Float(count))
                    * Float(book)
            }
            // Every book's boxes, hovering until it is planned, then along its way.
            var field = Field(count: count)
            for book in books.indices { field.set(Track(still: hovering[book]), for: book) }
            var planned = [Flight?](repeating: nil, count: count)
            planned[last] = Flight(
                from: books[last].from, hover: hovers[last], to: books[last].to,
                drift: .infinity, hop: .infinity, lands: .infinity, escape: .zero, glide: 0,
                bow: 0, pace: 1, slides: true, float: float)
            // The books fly one at a time into the plan, each as soon as its way meets none of
            // the books planned before it: the first book ready whose place's books have been
            // planned goes next. Each slides out from over the books still hovering, toward its
            // place.
            var left = Set(books.indices.dropLast())
            var deferred = Set<Int>()
            while !left.isEmpty {
                let free = left.filter { book in rests[book].allSatisfy { planned[$0] != nil } }
                let choices = (free.isEmpty ? left : free).subtracting(deferred)
                let forced = choices.isEmpty
                guard
                    let book = (forced ? (free.isEmpty ? left : free) : choices)
                        .min(by: { (ready($0), $0) < (ready($1), $1) })
                else { break }
                let staying =
                    books.indices.filter { $0 != book && planned[$0] == nil }
                    .map { hovering[$0] } + [hovering[last]]
                let toward =
                    SIMD2(books[book].to.translation.x, books[book].to.translation.z)
                    - SIMD2(hovers[book].translation.x, hovers[book].translation.z)
                let escape = Self.slide(hovering[book], clearOf: staying[...], toward: toward)
                // A book sliding out from under a book still hovering slides out level: rising
                // takes it into that book, and sinking into the ways of the low books planned
                // before it.
                let under = staying.contains {
                    $0.center.y > hovering[book].center.y
                        && DominoSetup.Footprint($0).overlaps(DominoSetup.Footprint(hovering[book]))
                }
                guard
                    let flight = Self.plan(
                        book, earliest: ready(book), preferred: preferred[book], bow: bows[book],
                        escape: escape + [0, under ? 0 : DominoFinale.escapeLift, 0],
                        glides: [0, 0.5, 1].map { glides[book] + Self.laneDepth * $0 },
                        from: books[book].from, hover: hovers[book],
                        to: books[book].to, size: books[book].size,
                        after: rests[book].compactMap { planned[$0]?.lands }, field: field,
                        planned: planned.map { $0 != nil }, forced: forced)
                else {
                    deferred.insert(book)
                    continue
                }
                planned[book] = Flight(
                    from: flight.from, hover: flight.hover, to: flight.to, drift: flight.drift,
                    hop: flight.hop, lands: flight.lands, escape: flight.escape,
                    glide: flight.glide, bow: flight.bow, pace: 1, float: float,
                    beat: DominoFinale.floatPeriod * Self.unit(book, 15), ramp: ramps[book])
                field.set(
                    Track(
                        planned[book] ?? flight, size: books[book].size, hovering: hovering[book],
                        arrived: places[book]), for: book)
                left.remove(book)
                deferred = []
            }
            self = Gather(flights: planned.compactMap { $0 }).paced(within: budget)
        }

        /// How far a gliding book's farthest corner passes above the spread's places and below
        /// the cloud, in units.
        static let laneRoom: Float = 0.25
        /// How much higher than its lowest a book may glide, in units, so books whose ways
        /// cross can pass over one another.
        static let laneDepth: Float = 1
        /// How much longer or shorter than preferred the planner may make a flight, in seconds.
        static let reshape: Float = 0.15

        /// A book's pose `share` of the way through the books' rise from `from` to `to`, where
        /// it hovers, turning as it goes: straight there, or, for a book that `slides`, waiting
        /// while the books over it rise, sliding out from under them, then rising. A book with a
        /// `ramp` slides out across the table over the first half, climbing toward that height
        /// as the books it lay against climb toward theirs, then climbs or sinks to where it
        /// hovers.
        static func rise(
            from: Transform, to: Transform, slides: Bool, share: Float, ramp: Float? = nil
        ) -> Transform {
            let share = min(max(share, 0), 1)
            let way = to.translation - from.translation
            func eased(_ low: Float, _ high: Float) -> Float {
                DominoCameraRig.ease(min(max((share - low) / (high - low), 0), 1))
            }
            if !slides, let ramp {
                let climb = eased(0, 1)
                let height =
                    (ramp - from.translation.y) * climb
                    + (to.translation.y - ramp) * eased(0.4, 1)
                let slide = eased(0, 0.5)
                return Transform(
                    scale: from.scale,
                    rotation: DominoSetup.turn(from.rotation, to: to.rotation, by: climb),
                    translation: from.translation + [way.x * slide, height, way.z * slide])
            }
            let (slide, lift) =
                slides ? (eased(0.35, 0.65), eased(0.65, 1)) : (eased(0, 1), eased(0, 1))
            return Transform(
                scale: from.scale,
                rotation: DominoSetup.turn(from.rotation, to: to.rotation, by: lift),
                translation: from.translation + [way.x * slide, way.y * lift, way.z * slide])
        }

        /// How much higher than the cloud's lowest books each book may always hover, for books
        /// lying on the books `under` them, other than the book it is `skipping`: higher than
        /// every book it lay on, by more than both float, so rising together at one pace, the
        /// books part without touching.
        static func ramp(under: [[Int]], skipping: Int) -> [Float] {
            let step = 2 * DominoFinale.floatHeight + 0.02
            var heights = [Float?](repeating: nil, count: under.count)
            func height(_ book: Int) -> Float {
                if let known = heights[book] { return known }
                heights[book] = 0
                let found = book == skipping ? 0 : (under[book].map(height).max() ?? -step) + step
                heights[book] = found
                return found
            }
            return under.indices.map(height)
        }

        /// Where each of `books` hovers: scattered at random across the table from where it lay,
        /// up to `DominoFinale.cloudScatter`, at a random height, a few of the books that leave
        /// first just above the table (`DominoFinale.lowShare` of all books) and the rest up to `DominoFinale.cloudDepth` above `lift`,
        /// and turned at random (`hoverTurns`), so the books hover in a messy cloud, a book that
        /// lay under another often above it. A turned book rises by as much farther as the turn
        /// takes its bottom below its middle, so a book hovering high stays above the lane, and
        /// one hovering low above the table.
        ///
        /// The books are placed one at a time, in a shuffled order. Each takes the first of
        /// several tries, out across the chain's line first, each nearer to how it lay than the
        /// last, then turned where it may always hover, that hovers clear of the book `sliding`
        /// out from under the rest, across the table, and whose way up, as it rises
        /// and as it floats `floating` up and down, meets no book placed so far or still to be
        /// placed, at `hovers`, except where its way to `hovers` would meet that book too. A
        /// book that no try fits hovers at `hovers`, which keeps it apart from the others, and
        /// the book `sliding` out from under the rest always does.
        static func cloud(
            _ books: [(from: Transform, to: Transform, size: SIMD3<Float>)],
            hovers: [Transform], sliding last: Int, floating: Float, lift: Float
        ) -> [Transform] {
            var hovers = hovers
            let ramps = hovers.map(\.translation.y)
            func box(_ book: Int, _ share: Float) -> DominoSetup.Box {
                DominoSetup.Box(
                    rise(
                        from: books[book].from, to: hovers[book], slides: book == last,
                        share: share, ramp: ramps[book]), size: books[book].size, grow: -0.01)
            }
            // Fine throughout, so a book that climbs or turns past another late in the rise meets
            // it at one of the shares too.
            let shares = (1...80).map { Float($0) / 80 }
            let floats: [SIMD3<Float>] = [[0, 2 * floating, 0], [0, -2 * floating, 0]]
            // Each book's boxes through the rise, as placed so far, and their bounds, grown by
            // its float.
            func track(_ book: Int) -> [(box: DominoSetup.Box, near: DominoSetup.Bounds)] {
                shares.map { share in
                    let box = box(book, share)
                    var near = box.bounds
                    near.low.y -= 2 * floating
                    near.high.y += 2 * floating
                    return (box, near)
                }
            }
            var tracks = books.indices.map(track)
            // No book hovers over or under the last book, which rises beside the cloud.
            let beside =
                DominoSetup.Footprint(
                    DominoSetup.Box(hovers[last], size: books[last].size)
                )
                .grown(by: 0.02)
            for book in books.indices.sorted(by: { unit($0, 18) < unit($1, 18) }) where book != last
            {
                let from = books[book].from
                let turns = hoverTurns(book, from: from.rotation)
                // How much farther a turned book reaches below its middle than it did as it lay,
                // so a book raised by that keeps its bottom above the lane, or, hovering low,
                // above the table.
                func dip(_ rotation: simd_quatf) -> Float {
                    func depth(_ rotation: simd_quatf) -> Float {
                        DominoSetup.Box(Transform(rotation: rotation), size: books[book].size)
                            .bounds.high.y
                    }
                    return max(depth(rotation) - depth(from.rotation), 0)
                }
                let ramped = hovers[book]
                let plain = tracks[book]
                // Only books that leave early hover low, out of the lane before most fly.
                let low =
                    book < books.count / 2 && unit(book, 19) < 2 * DominoFinale.lowShare
                // Out across the chain's line first, away from the books it lay against, then
                // any way.
                let across = from.rotation.act([1, 0, 0])
                let side = atan2(across.z, across.x)
                let tries = (0..<12)
                    .map { attempt in
                        func random(_ salt: Int) -> Float { unit(book * 12 + attempt, salt) }
                        let reach = 1 - Float(attempt) / 12
                        let angle =
                            attempt < 8
                            ? side + (attempt % 2 == 0 ? 0 : .pi) + (random(20) - 0.5) * 0.8
                            : 2 * Float.pi * random(20)
                        // Across the line, far enough to clear its row, short of the next.
                        let distance =
                            attempt < 8
                            ? 1.3 + 1.1 * random(21)
                            : DominoFinale.cloudScatter * reach * (0.3 + 0.7 * random(21))
                        let height =
                            low
                            ? DominoFinale.lowLift.lowerBound
                                + (DominoFinale.lowLift.upperBound - DominoFinale.lowLift.lowerBound)
                                * random(22)
                            : lift + DominoFinale.cloudDepth * random(22)
                        let rotation = turns[attempt]
                        return Transform(
                            scale: from.scale, rotation: rotation,
                            translation: from.translation
                                + [
                                    cos(angle) * distance, height + dip(rotation),
                                    sin(angle) * distance,
                                ])
                    }
                // Failing those, it hovers where it may always hover, turned.
                let turned = turns[tries.count...]
                    .map { rotation in
                        var hover = ramped
                        hover.rotation = rotation
                        hover.translation.y += dip(rotation)
                        return hover
                    }
                let chosen = (tries + turned)
                    .first { hover in
                        hovers[book] = hover
                        guard
                            !beside.overlaps(
                                DominoSetup.Footprint(
                                    DominoSetup.Box(hover, size: books[book].size)))
                        else { return false }
                        return shares.indices.allSatisfy { step in
                            let mine = box(book, shares[step])
                            let reach = mine.bounds
                            return books.indices.allSatisfy { other in
                                guard other != book else { return true }
                                let (theirs, near) = tracks[other][step]
                                guard near.overlaps(reach) else { return true }
                                let moves = step == shares.count - 1 ? [.zero] + floats : [.zero]
                                return moves.allSatisfy {
                                    !mine.moved(by: $0).overlaps(theirs)
                                        || plain[step].box.moved(by: $0).overlaps(theirs)
                                }
                            }
                        }
                    }
                hovers[book] = chosen ?? ramped
                tracks[book] = track(book)
            }
            return hovers
        }

        /// Every turn `cloud` may give the `book`th as it hovers, from how it lay, `from`: one
        /// for each of its 12 tries, each turned less than the last, up to `hoverSpin` about the
        /// axis through its covers and `hoverTip` about its other axes, then 4 for where it may
        /// always hover.
        static func hoverTurns(_ book: Int, from: simd_quatf) -> [simd_quatf] {
            func turned(_ turn: (_ salt: Int, _ most: Float) -> Float) -> simd_quatf {
                from
                    * simd_quatf(angle: turn(23, DominoFinale.hoverSpin), axis: [0, 0, 1])
                    * simd_quatf(angle: turn(24, DominoFinale.hoverTip), axis: [1, 0, 0])
                    * simd_quatf(angle: turn(25, DominoFinale.hoverTip), axis: [0, 1, 0])
            }
            let tries = (0..<12)
                .map { attempt in
                    let reach = 1 - Float(attempt) / 12
                    return turned { (2 * unit(book * 12 + attempt, $0) - 1) * $1 * reach }
                }
            let fallbacks = [Float(1), -1, 0.5, -0.5]
                .map { share in turned { (2 * unit(book, $0) - 1) * $1 * share } }
            return tries + fallbacks
        }

        /// The shortest move across the table, up to `longestSlide`, that takes `book` clear of
        /// `others` by `slideRoom`, so it can rise or sink beside them, the most nearly `toward`
        /// of those as short: none when none does.
        static func slide(
            _ book: DominoSetup.Box, clearOf others: ArraySlice<DominoSetup.Box>,
            toward: SIMD2<Float> = .zero
        ) -> SIMD3<Float> {
            let footprints = others.map { DominoSetup.Footprint($0).grown(by: slideRoom) }
            for step in 0...Int(longestSlide / 0.25) {
                let distance = Float(step) * 0.25
                let clear = (0..<(step == 0 ? 1 : 24))
                    .map { turn in
                        let angle = Float(turn) * .pi / 12
                        return SIMD2(cos(angle), sin(angle)) * distance
                    }
                    .filter { move in
                        let moved = DominoSetup.Footprint(book).offset(by: move)
                        return !footprints.contains(where: { $0.overlaps(moved) })
                    }
                if let move = clear.max(by: { simd_dot($0, toward) < simd_dot($1, toward) }) {
                    return [move.x, 0, move.y]
                }
            }
            return .zero
        }
        static let longestSlide: Float = 20
        static let slideRoom: Float = 0.3

        /// How often a hop's way is checked against the others, and the step by which a book
        /// waits longer while its way meets another, in seconds, and the longest it waits.
        static let checkStep: Float = 1.0 / 120
        static let waitStep: Float = 1.0 / 30
        static let longestWait: Float = 3
        /// How far a hopping book's box grows on every side as the planner checks it in the
        /// air, in units, beyond how far it moves in a step, so books pass with room to spare.
        static let margin: Float = 0.03

        /// A book's boxes, shrunk a hair, and their bounds, on the planner's clock, every
        /// `checkStep` from 0: hovering before `start`, one for each step while it flies, and
        /// still after. The planner checks no flight before the books have risen, so a track
        /// leaves out the rise.
        struct Track {
            let start: Int
            let boxes: [(box: DominoSetup.Box, bounds: DominoSetup.Bounds)]
            let before: (box: DominoSetup.Box, bounds: DominoSetup.Bounds)
            let after: (box: DominoSetup.Box, bounds: DominoSetup.Bounds)

            /// The track of a book that stays at `still`.
            init(still: DominoSetup.Box) {
                start = 0
                boxes = []
                before = (still, still.bounds)
                after = before
            }

            /// The track of a book of `size` along `flight`, from where it hovers, `hovering`, to
            /// where it arrives, `arrived`.
            init(
                _ flight: Flight, size: SIMD3<Float>, hovering: DominoSetup.Box,
                arrived: DominoSetup.Box
            ) {
                start = Int((flight.start / checkStep).rounded(.down))
                let end = max(Int((flight.landing / checkStep).rounded(.up)), start)
                boxes = (start...end)
                    .map { step in
                        let box = DominoSetup.Box(
                            flight.pose(at: Float(step) * checkStep), size: size, grow: -0.01)
                        return (box, box.bounds)
                    }
                before = (hovering, hovering.bounds)
                after = (arrived, arrived.bounds)
            }
        }

        /// The books' tracks on the planner's clock, kept by where their boxes lie across the
        /// table, in squares `cell` units across, so a check finds the books near a box at once.
        ///
        /// The planner checks millions of boxes for a long chain, so the field keeps its boxes in
        /// flat arrays of plain structs and walks them with plain loops, which stay quick in an
        /// unoptimized build too.
        struct Field {
            static let cell: Float = 3
            /// A book's box, its bounds, and the steps it holds for.
            struct Entry {
                let book: Int
                let box: DominoSetup.Box
                let bounds: DominoSetup.Bounds
                let steps: Range<Int>
            }
            /// By square, each book's still boxes.
            private var still: [Int64: [Entry]] = [:]
            /// By step and square, each book's box while it moves.
            private var moving: [[Int64: [Entry]]] = []
            /// Each book's squares, still and by step.
            private var stills: [Set<Int64>]
            private var moves: [[(step: Int, square: Int64)]]

            init(count: Int) {
                stills = Array(repeating: [], count: count)
                moves = Array(repeating: [], count: count)
            }

            /// The columns and rows of the squares that `bounds` covers.
            private static func cells(_ bounds: DominoSetup.Bounds) -> (
                x: ClosedRange<Int>, z: ClosedRange<Int>
            ) {
                let low = (bounds.low / cell).rounded(.down)
                let high = (bounds.high / cell).rounded(.down)
                return (Int(low.x)...Int(high.x), Int(low.z)...Int(high.z))
            }

            /// The key of the square in column `x` and row `z`.
            private static func square(_ x: Int, _ z: Int) -> Int64 {
                Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(z)))
            }

            /// The squares `bounds` covers.
            private static func squares(_ bounds: DominoSetup.Bounds) -> [Int64] {
                let cells = cells(bounds)
                return cells.x.flatMap { x in cells.z.map { z in square(x, z) } }
            }

            /// Keeps `track` as `book`'s, in place of any it had.
            mutating func set(_ track: Track, for book: Int) {
                for square in stills[book] { still[square]?.removeAll { $0.book == book } }
                for (step, square) in moves[book] {
                    moving[step][square]?.removeAll { $0.book == book }
                }
                stills[book] = []
                moves[book] = []
                let end = track.start + track.boxes.count
                for (steps, entry) in [
                    (0..<track.start, track.before), (end..<Int.max, track.after),
                ] {
                    let entry = Entry(
                        book: book, box: entry.box, bounds: entry.bounds, steps: steps)
                    for square in Self.squares(entry.bounds) {
                        still[square, default: []].append(entry)
                        stills[book].insert(square)
                    }
                }
                if moving.count < end { moving += Array(repeating: [:], count: end - moving.count) }
                for (offset, entry) in track.boxes.enumerated() {
                    let step = track.start + offset
                    let entry = Entry(
                        book: book, box: entry.box, bounds: entry.bounds, steps: step..<step + 1)
                    for square in Self.squares(entry.bounds) {
                        moving[step][square, default: []].append(entry)
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
                func meets(_ entry: Entry) -> Bool {
                    entry.book != book && only(entry.book) && entry.bounds.overlaps(bounds)
                        && entry.box.overlaps(box)
                }
                let cells = Self.cells(bounds)
                let now = step < moving.count ? moving[step] : [:]
                var x = cells.x.lowerBound
                while x <= cells.x.upperBound {
                    var z = cells.z.lowerBound
                    while z <= cells.z.upperBound {
                        let square = Self.square(x, z)
                        if let entries = now[square] {
                            var index = 0
                            while index < entries.count {
                                if meets(entries[index]) { return false }
                                index += 1
                            }
                        }
                        if let entries = still[square] {
                            var index = 0
                            while index < entries.count {
                                let entry = entries[index]
                                if entry.steps.lowerBound <= step, step < entry.steps.upperBound,
                                    meets(entry)
                                {
                                    return entry.steps.upperBound == .max
                                }
                                index += 1
                            }
                        }
                        z += 1
                    }
                    x += 1
                }
                return nil
            }
        }

        /// The flight of the `book`th, of `size`, lying at `from`, from `hover` to `to`, sliding
        /// out of the cloud by `escape` and gliding at one of `glides`: speeding up as soon after
        /// `earliest` as its way meets none of the other books' tracks in `field`, those
        /// `planned` and those still to fly, landing `DominoFinale.landGap` after the landings
        /// it lands `after`. It drifts out of the cloud from as soon as the books have risen,
        /// or, where that meets a book, not at all. Each wait also tries the flight a
        /// little longer and a little shorter than `preferred`, and higher in the lane. When
        /// only books still to fly block it however long it waits, up to `longestWait`, there
        /// is none, so they can go first, unless `forced`; a flight that planned books block
        /// goes as soon as it may, as a last resort.
        static func plan(
            _ book: Int, earliest: Float, preferred: Float, bow: Float, escape: SIMD3<Float>,
            glides: [Float], from: Transform, hover: Transform, to: Transform,
            size: SIMD3<Float>, after: [Float], field: Field, planned: [Bool], forced: Bool
        ) -> Flight? {
            // Hops start and last whole steps of the planner's clock.
            let times = [preferred, preferred + reshape, preferred - reshape]
                .map {
                    (min(
                        max($0, DominoFinale.hopTimes.lowerBound), DominoFinale.hopTimes.upperBound)
                        / checkStep)
                        .rounded()
                }
            let landing = (after.max() ?? -.infinity) + DominoFinale.landGap
            let risen = (DominoFinale.hoverTime / checkStep).rounded(.up)
            func flight(_ drift: Float, _ start: Float, _ steps: Float, glide: Float) -> Flight {
                Flight(
                    from: from, hover: hover, to: to, drift: drift * checkStep,
                    hop: start * checkStep, lands: (start + steps) * checkStep, escape: escape,
                    glide: glide, bow: bow, pace: 1)
            }
            /// The pose `hop`, first checked at step `first`, is checked in at `step`. A scan
            /// carries each pose on from the step before, a step on from that step's time, so a
            /// check at a single step finds the pose the same way, to the bit.
            func pose(_ hop: Flight, at step: Int, first: Int) -> Transform {
                hop.pose(
                    at: step == first
                        ? Float(first) * checkStep : Float(step - 1) * checkStep + checkStep)
            }
            /// The box `hop` is checked with at `step`, at `pose`, moving to `next` by the next
            /// step: with room to spare in the air, as far as it moves in a step, so it passes
            /// others between the checks too; it slides out from over the books hovering by it
            /// and settles onto the books under its place.
            func box(_ hop: Flight, _ pose: Transform, _ next: Transform, at step: Int)
                -> DominoSetup.Box
            {
                let share = hop.share(at: Float(step) * checkStep)
                let room =
                    share >= DominoFinale.sinkShares.upperBound
                        && share < DominoFinale.gatherArrival
                    ? margin + simd_distance(next.translation, pose.translation) : -0.01
                return DominoSetup.Box(pose, size: size, grow: room)
            }
            /// The first step from `from` through `through` at which `hop` meets another book,
            /// of those planned unless `all`, and whether that book stays still from then on, in
            /// its place or hovering, which no wait gets past.
            func scan(_ hop: Flight, all: Bool, from: Int, through: Int) -> (
                still: Bool, step: Int
            )? {
                let first = Int((hop.drift / checkStep).rounded())
                var pose = pose(hop, at: from, first: first)
                var step = from
                while step <= through {
                    let next = hop.pose(at: Float(step) * checkStep + checkStep)
                    if let still = field.meets(
                        box(hop, pose, next, at: step), at: step, skipping: book,
                        only: { all || planned[$0] })
                    {
                        return (still, step)
                    }
                    pose = next
                    step += 1
                }
                return nil
            }
            /// Whether `hop` meets any other book, of those planned unless `all`, at which step,
            /// and, when a scan from its start found it, whether the first book it meets stays
            /// still. It is checked first at the `hints`, the steps at which similar hops met a
            /// book, so a hop that meets one usually needs no scan. Until it speeds up, a hop
            /// drifts the same way however long it then flies and however high it glides, so
            /// hops that drift together share the scan of their drift, `drifted`: `nil` until
            /// scanned, then the meeting it found, if any.
            func meets(
                _ hop: Flight, all: Bool, hints: [Int] = [],
                drifted: inout (still: Bool, step: Int)??
            ) -> (meets: Bool, still: Bool?, step: Int) {
                let first = Int((hop.drift / checkStep).rounded())
                let start = Int((hop.hop / checkStep).rounded())
                let last = Int((hop.lands / checkStep).rounded())
                if case let met?? = drifted { return (true, met.still, met.step) }
                for step in hints where step >= first && step <= last {
                    let box = box(
                        hop, pose(hop, at: step, first: first),
                        pose(hop, at: step + 1, first: first), at: step)
                    if field.meets(box, at: step, skipping: book, only: { all || planned[$0] })
                        != nil
                    {
                        return (true, nil, step)
                    }
                }
                var from = first
                if first < start {
                    if drifted == nil {
                        drifted = scan(hop, all: all, from: first, through: start - 1)
                    }
                    if case let met?? = drifted { return (true, met.still, met.step) }
                    from = start
                }
                guard let met = scan(hop, all: all, from: from, through: last) else {
                    return (false, nil, 0)
                }
                return (true, met.still, met.step)
            }
            func first(all: Bool) -> Flight? {
                var start = (earliest / checkStep).rounded(.up)
                let latest = start + (longestWait / checkStep).rounded()
                let wait = (waitStep / checkStep).rounded()
                // Where each kind of hop, by its drift, time, and glide, and any hop last met a
                // book.
                var met: [Int: Int] = [:]
                var last: Int?
                while start <= latest {
                    // Each hop that met a book, whether that book stays still if known, and how
                    // many steps after its drift it met one.
                    var blocked: [(hop: Flight, still: Bool?, after: Int)] = []
                    for drift in Set([risen, start]).sorted() {
                        var drifted: (still: Bool, step: Int)?? = nil
                        for (time, steps) in times.enumerated()
                        where (start + steps) * checkStep >= landing {
                            for (height, glide) in glides.enumerated() {
                                let hop = flight(drift, start, steps, glide: glide)
                                let drifts = drift == risen ? 0 : 1
                                let kind = (drifts * times.count + time) * glides.count + height
                                let hints = [met[kind].map { $0 + Int(wait) }, met[kind], last]
                                let meeting = meets(
                                    hop, all: all, hints: hints.compactMap { $0 },
                                    drifted: &drifted)
                                guard meeting.meets else { return hop }
                                blocked.append((hop, meeting.still, meeting.step - Int(drift)))
                                met[kind] = meeting.step
                                last = meeting.step
                            }
                        }
                    }
                    // A book that stays still in its way stays there however long it waits. The
                    // hops that met a book at a hint are scanned from their starts for the first
                    // book they meet, the soonest met first, until one meets a book that moves.
                    if start * checkStep >= landing,
                        blocked.allSatisfy({ $0.still != false }),
                        blocked.filter({ $0.still == nil }).sorted(by: { $0.after < $1.after })
                            .allSatisfy({
                                var drifted: (still: Bool, step: Int)?? = nil
                                return meets($0.hop, all: all, drifted: &drifted).still == true
                            })
                    {
                        return nil
                    }
                    start += wait
                }
                return nil
            }
            if let hop = first(all: true) { return hop }
            if !forced, first(all: false) != nil { return nil }
            let start = (max(earliest, landing - preferred) / checkStep).rounded(.up)
            return flight(start, start, (preferred / checkStep).rounded(), glide: glides[0])
        }

        /// How long the flight of the `index`th book in the spread's order, from `hover` to `to`,
        /// takes before any repair: longer the farther it carries, varied by up to 15 percent
        /// either way.
        static func hopTime(from hover: Transform, to: Transform, _ index: Int) -> Float {
            let way = simd_distance(
                SIMD2(hover.translation.x, hover.translation.z),
                SIMD2(to.translation.x, to.translation.z))
            let base = DominoFinale.hopTimes.lowerBound + DominoFinale.hopPace * way
            let time = base * (0.85 + 0.3 * unit(index, 1))
            return min(
                max(time, DominoFinale.hopTimes.lowerBound), DominoFinale.hopTimes.upperBound)
        }

        /// How far the flight of the `index`th book in the spread's order, from `hover` to `to`,
        /// bows to its left: up to `bowShare` of the way across, to either side, and at most
        /// `longestBow`.
        static func bow(from hover: Transform, to: Transform, _ index: Int) -> Float {
            let way = simd_distance(
                SIMD2(hover.translation.x, hover.translation.z),
                SIMD2(to.translation.x, to.translation.z))
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
