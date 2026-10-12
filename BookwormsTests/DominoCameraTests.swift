import XCTest
import simd

@testable import Bookworms

/// The Follow camera's math: the smoothed front, the springs' limits, the close, low chase and
/// its swings round the turns, clearance from the books, following to the last book, the
/// establishing move, cobweb push in, and reveal; and the overview camera's spring.
final class DominoCameraTests: XCTestCase {
    private static let fieldOfView: Float = 38 * .pi / 180
    /// An iPhone in portrait, composing between its bars.
    private static let aspect: Float = 402.0 / 874
    private static let area = DominoCameraRig.Area(low: [-0.92, -0.78], high: [0.92, 0.57])
    private static let tallest: Float = 2.8
    /// A typical book's height, which the camera plans its distance for.
    private static let typical = tallest * DominoCameraRig.typicalHeight
    /// A high view of the whole table from the side the camera films from, as the scene frames
    /// the finale.
    private static let finale = DominoCameraPose(eye: [-90, 110, -20], target: .zero)

    /// One frame of a simulated run.
    private struct Frame {
        var time: Float
        var step: Float
        /// The front as `DominoScene` reports it.
        var raw: Float
        var started: Bool
        /// Whether the last book has started to fall.
        var done: Bool
        var revealing: Bool
        var pose: DominoCameraPose

        var running: Bool { started && !done }
    }

    /// A chain of `count` books `spacing` apart on a path shaped as `DominoLayout.plan` shapes
    /// it for a phone, centered on the table, and its books' places.
    private func chain(
        _ count: Int, spacing: Float = 1.05, cobwebs: [DominoCameraRig.Cobweb] = []
    ) -> (rig: DominoCameraRig, books: [SIMD2<Float>]) {
        let length = Float(count - 1) * spacing
        let path = DominoPath(rowLength: DominoLayout.rowLength(for: length, aspect: 0.45))
        let places = (0..<count).map { path.point(at: Float($0) * spacing).position }
        let low = places.reduce(places[0], pointwiseMin)
        let high = places.reduce(places[0], pointwiseMax)
        let offset = (low + high) / 2
        let rig = DominoCameraRig(
            path: path, offset: offset, length: length, tallest: Self.tallest, cobwebs: cobwebs,
            finale: Self.finale, fieldOfView: Self.fieldOfView, aspect: Self.aspect,
            area: Self.area)
        return (rig, places.map { $0 - offset })
    }

    /// Runs `rig` through a chain of `count` books `spacing` apart, pushed after `wait` seconds,
    /// whose front tips from book to book at about `speed` units a second, each book a little
    /// faster or slower than the last and gathering speed as it tips, as the scene's front
    /// does. Steps are a 60th of a second, with a 40th every seventh frame unless `even`.
    private func run(
        _ rig: inout DominoCameraRig, count: Int, spacing: Float = 1.05, speed: Float = 18,
        wait: Float = 6, even: Bool = false
    ) -> [Frame] {
        var starts: [Float] = []
        var time = wait
        for index in 0..<count {
            starts.append(time)
            // A fixed, uneven pattern of book times, and a slow first tip from the push.
            let jitter: Float = [1, 0.85, 1.12, 0.93, 1.1, 0.9, 1.05][index % 7]
            time += spacing / speed * jitter * (index == 0 ? 3 : 1)
        }
        let done = time
        func raw(at time: Float) -> Float {
            guard let index = starts.lastIndex(where: { $0 <= time }) else { return 0 }
            guard index + 1 < count else { return Float(index) * spacing }
            let share = min(1, (time - starts[index]) / (starts[index + 1] - starts[index]))
            return (Float(index) + share * share) * spacing
        }
        var frames: [Frame] = []
        var clock: Float = 0
        var index = 0
        while clock < done + DominoCameraRig.landTime + rig.revealTime + 4 {
            let step: Float = !even && index % 7 == 3 ? 1.0 / 40 : 1.0 / 60
            clock += step
            index += 1
            let front = raw(at: clock)
            let pose = rig.step(
                .init(distance: front, started: clock >= wait, done: clock >= done), by: step)
            frames.append(
                Frame(
                    time: clock, step: step, raw: front, started: clock >= wait,
                    done: clock >= done, revealing: rig.isRevealing, pose: pose))
        }
        return frames
    }

    func testTheFrontRunsSmoothlyAndNeverBackward() {
        var (rig, _) = chain(120)
        let spacing: Float = 1.05
        var previous: Float = 0
        var estimate: Float = 0
        var paces: [Float] = []
        var time: Float = 0
        while time < 7.5 {
            time += 1.0 / 60
            // Books tip one after another at 18 units a second, each gathering speed as it
            // tips, so the raw front runs in a staircase of ramps.
            let books = time * 18 / spacing
            let whole = books.rounded(.down)
            let raw = min((whole + (books - whole) * (books - whole)) * spacing, 119 * spacing)
            rig.step(.init(distance: raw, started: true, done: false), by: 1.0 / 60)
            XCTAssertGreaterThanOrEqual(rig.front, previous, "at \(time)")
            XCTAssertGreaterThanOrEqual(rig.estimate, estimate, "at \(time)")
            previous = rig.front
            estimate = rig.estimate
            guard time > 1, raw < 110 else { continue }
            paces.append(rig.pace)
            // The estimate keeps within about a book of the books themselves.
            XCTAssertEqual(rig.estimate, raw, accuracy: 1.2, "at \(time)")
        }
        // Between books the raw front stops and starts; the smoothed one keeps its pace.
        XCTAssertLessThan(paces.max()! - paces.min()!, 1.8)
        XCTAssertEqual(paces.reduce(0, +) / Float(paces.count), 18, accuracy: 0.5)
    }

    func testTheEstimateStopsWithAStalledChain() {
        var (rig, _) = chain(120)
        let spacing: Float = 1.05
        let speed: Float = 13
        // The chain stalls for two seconds when the 48th book fails to tip, and then runs on
        // from a second push.
        let stall: Float = 48 * spacing
        let stopped = stall / speed
        var estimate: Float = 0
        var time: Float = 0
        while time < 7 {
            time += 1.0 / 60
            let run = time < stopped ? time : max(stopped, time - 2)
            let books = run * speed / spacing
            let whole = books.rounded(.down)
            let raw = min((whole + (books - whole) * (books - whole)) * spacing, 119 * spacing)
            rig.step(.init(distance: raw, started: true, done: false), by: 1.0 / 60)
            // It never runs backward, and it stops just past the stalled front.
            XCTAssertGreaterThanOrEqual(rig.estimate, estimate - 1e-4, "at \(time)")
            estimate = rig.estimate
            if time > stopped, time < stopped + 2 {
                XCTAssertLessThan(rig.estimate, stall + 0.6, "at \(time)")
            }
            // Once the chain runs again, it catches up.
            if time > stopped + 3, raw < 110 {
                XCTAssertEqual(rig.estimate, raw, accuracy: 1.2, "at \(time)")
            }
        }
    }

    func testSpringsKeepToTheirLimits() {
        var (rig, _) = chain(276)
        // From far off, the springs would pull hard; the limits hold them back.
        rig.reset(to: DominoCameraPose(eye: [80, 5, -80], target: [60, 0, -90]))
        var frames = run(&rig, count: 276, speed: 20, even: true)
        frames.insert(
            Frame(
                time: 0, step: 1.0 / 60, raw: 0, started: false, done: false, revealing: false,
                pose: DominoCameraPose(eye: [80, 5, -80], target: [60, 0, -90])), at: 0)
        var lastVelocity: SIMD3<Float>?
        for (before, after) in zip(frames, frames.dropFirst()) {
            // The limits grow with the distance from the eye to the target.
            let scale = max(
                DominoCameraRig.limitScale(before.pose), DominoCameraRig.limitScale(after.pose))
            let velocity = (after.pose.eye - before.pose.eye) / after.step
            XCTAssertLessThanOrEqual(
                simd_length(velocity), DominoCameraRig.maximumSpeed * scale * 1.001,
                "at \(after.time)")
            if let lastVelocity {
                XCTAssertLessThanOrEqual(
                    simd_length(velocity - lastVelocity) / after.step,
                    DominoCameraRig.maximumAcceleration * scale * 1.01, "at \(after.time)")
            }
            lastVelocity = velocity
            XCTAssertLessThanOrEqual(
                turn(from: before.pose, to: after.pose) / after.step,
                DominoCameraRig.maximumTurnRate * 1.01, "at \(after.time)")
            XCTAssertLessThanOrEqual(abs(after.pose.roll), DominoCameraRig.maximumRoll)
        }
    }

    func testTheCameraChasesTheFrontLowAndClose() {
        for count in [39, 120, 276] {
            // A dense web halfway along the third row, and another on the fifth turn.
            let path = chain(count).rig.path
            let webs = [
                2 * path.period + path.rowLength / 2,
                4 * path.period + path.rowLength + .pi * path.radius / 2,
            ]
            .map { DominoCameraRig.Cobweb(distance: $0, density: 1) }
            var (rig, _) = chain(count, cobwebs: webs)
            // At about the chain's pace in the scene, which times the swings.
            let frames = run(&rig, count: count, speed: 13)
            var shares: [Float] = []
            var elevations: [Float] = []
            var rolls: [Float] = []
            var shown = 0
            var lastSpin: SIMD3<Float>?
            var hardest: Float = 0
            for (index, frame) in frames.enumerated().dropFirst() where frame.running {
                let pose = frame.pose
                // The book at the front: the last the chain has reached.
                let front = rig.point(at: (frame.raw / 1.05).rounded(.down) * 1.05)
                let base = SIMD3(front.x, 0, front.y)
                let middle = base + [0, Self.typical / 2, 0]
                let bottom = pose.project(base, fieldOfView: Self.fieldOfView, aspect: Self.aspect)
                let top = pose.project(
                    base + [0, Self.typical, 0], fieldOfView: Self.fieldOfView,
                    aspect: Self.aspect)
                shares.append(abs(top.y - bottom.y) / 2)
                elevations.append(elevation(of: pose.eye, above: middle))
                rolls.append(pose.roll)
                let point = pose.project(
                    middle, fieldOfView: Self.fieldOfView, aspect: Self.aspect)
                if point.x > Self.area.low.x, point.x < Self.area.high.x,
                    point.y > Self.area.low.y, point.y < Self.area.high.y
                {
                    shown += 1
                }
                // The view swings smoothly, cobwebs and all: its turn never changes faster than
                // a swing's ease allows, so it never snaps.
                let before = frames[index - 1]
                let spin = spin(from: before.pose, to: pose) / frame.step
                if let lastSpin {
                    hardest = max(
                        hardest, simd_length(spin - lastSpin) / ((before.step + frame.step) / 2))
                }
                lastSpin = spin
            }
            XCTAssertLessThan(hardest, 8, "\(count)")
            // A typical book at the front fills about a quarter of the view's height, closer
            // as the camera pushes in on the webs.
            let close = shares.filter { $0 >= 0.2 && $0 <= 0.35 }.count
            XCTAssertGreaterThan(Float(close), Float(shares.count) * 0.85, "\(count)")
            // From low over the table, at heights that vary from row to row.
            XCTAssertGreaterThan(elevations.min()!, 8 * .pi / 180, "\(count)")
            XCTAssertLessThan(elevations.max()!, 25 * .pi / 180, "\(count)")
            XCTAssertGreaterThan(elevations.max()! - elevations.min()!, 6 * .pi / 180, "\(count)")
            // The front shows clear of the bars, and the camera banks as it swings.
            XCTAssertGreaterThan(Float(shown), Float(shares.count) * 0.95, "\(count)")
            if rig.swings.contains(where: { $0.reach * 2 > DominoCameraRig.typicalPace }) {
                XCTAssertGreaterThan(rolls.map(abs).max()!, 1 * .pi / 180, "\(count)")
            }
        }
    }

    func testTheCameraFilmsEachRowFromTheFallenSide() {
        for count in [60, 276] {
            var (rig, _) = chain(count)
            let frames = run(&rig, count: count, speed: 13)
            let path = rig.path
            var rows = 0
            for row in 0..<Int(rig.length / path.period) {
                let middle = Float(row) * path.period + path.rowLength / 2
                guard let frame = frames.first(where: { $0.raw >= middle }), frame.running
                else { continue }
                rows += 1
                // Mid row, the eye is on the side of the fallen rows, so no standing row hides
                // the front, and behind the front, so the books fall away from it.
                let offset = SIMD2(frame.pose.eye.x, frame.pose.eye.z) - rig.point(at: frame.raw)
                let heading = path.point(at: frame.raw).heading
                XCTAssertLessThan(offset.y, 0, "\(count) row \(row)")
                XCTAssertLessThan(
                    simd_dot(simd_normalize(offset), heading), 0, "\(count) row \(row)")
            }
            XCTAssertGreaterThan(rows, 3, "\(count)")
        }
    }

    func testShotsVaryAndSwingsFitBetweenTheTurns() {
        for count in [39, 120, 276] {
            let rig = chain(count).rig
            let pace = DominoCameraRig.typicalPace
            XCTAssertEqual(rig.swings.count, rig.shots.count - 1, "\(count)")
            for (row, shot) in rig.shots.enumerated() {
                XCTAssertGreaterThanOrEqual(shot.elevation, DominoCameraRig.elevations.lowerBound)
                XCTAssertLessThanOrEqual(shot.elevation, DominoCameraRig.elevations.upperBound)
                XCTAssertGreaterThanOrEqual(shot.share, DominoCameraRig.shares.lowerBound)
                XCTAssertLessThanOrEqual(shot.share, DominoCameraRig.tightShare)
                // Every row's shot chases the front from behind or beside it, on the side of the
                // fallen rows, and never films it from ahead.
                let side = sides(of: rig)[row]
                XCTAssertGreaterThanOrEqual(
                    side, DominoCameraRig.sides.lowerBound - 1e-4, "\(count) \(row)")
                XCTAssertLessThanOrEqual(
                    side, DominoCameraRig.sides.upperBound + 1e-4, "\(count) \(row)")
                guard row > 0 else { continue }
                // Neighboring rows differ in bearing, height, or distance.
                let before = rig.shots[row - 1]
                let bearing = abs(shot.azimuth - before.azimuth) > 10 * .pi / 180
                let height = abs(shot.elevation - before.elevation) > 1 * .pi / 180
                let distance = abs(shot.share - before.share) > 0.01
                XCTAssertTrue(bearing || height || distance, "\(count) \(row)")
            }
            // Rows long enough for the longest swing keep `dwell` steady between swings.
            let roomy =
                rig.path.period / pace - DominoCameraRig.dwell
                >= DominoCameraRig.swingTimes.upperBound
            for (turn, swing) in rig.swings.enumerated() {
                // A swing keeps within its average rate at a typical pace, and leaves part of
                // each row and turn steady before the next.
                let size = abs(rig.shots[turn + 1].azimuth - rig.shots[turn].azimuth)
                let time = 2 * swing.reach / pace
                XCTAssertLessThanOrEqual(size, DominoCameraRig.swingRate * time * 1.001)
                XCTAssertLessThanOrEqual(time, DominoCameraRig.swingTimes.upperBound + 1e-4)
                if turn + 1 < rig.swings.count {
                    let next = rig.swings[turn + 1]
                    XCTAssertLessThanOrEqual(
                        swing.middle + swing.reach + (roomy ? DominoCameraRig.dwell * pace : 0),
                        next.middle - next.reach + 1e-3, "\(count) \(turn)")
                }
                // The camera swings round every turn, a short chain's too, rather than holding
                // a locked view, and halfway round, it cranes up above both rows.
                XCTAssertGreaterThan(size, 20 * .pi / 180 - 1e-4, "\(count) \(turn)")
                XCTAssertGreaterThan(swing.lift, 0, "\(count) \(turn)")
                let middle = rig.plan(at: swing.middle).shot.elevation
                XCTAssertGreaterThan(
                    middle, max(rig.shots[turn].elevation, rig.shots[turn + 1].elevation),
                    "\(count) \(turn)")
            }
        }
        // A long chain gets wide swings, and small ones where the camera cranes high over a
        // turn instead.
        let rig = chain(276).rig
        let sizes = rig.swings.indices.map {
            abs(rig.shots[$0 + 1].azimuth - rig.shots[$0].azimuth) * 180 / .pi
        }
        XCTAssertGreaterThan(sizes.filter { $0 > 50 }.count, 1)
        XCTAssertTrue(
            rig.swings.indices.contains {
                sizes[$0] < 40 && rig.swings[$0].lift > 6 * .pi / 180
            })
    }

    func testSwingsLeaveEachRowSteady() {
        var (rig, _) = chain(276)
        let frames = run(&rig, count: 276, speed: DominoCameraRig.typicalPace)
        let path = rig.path
        var rates: [Float] = []
        var steady: [Int: (now: Float, longest: Float)] = [:]
        for (before, frame) in zip(frames, frames.dropFirst()) where frame.running {
            let rate = turn(from: before.pose, to: frame.pose) / frame.step
            rates.append(rate)
            let row = Int(frame.raw / path.period)
            var stretch = steady[row] ?? (0, 0)
            stretch.now = rate < 15 * .pi / 180 ? stretch.now + frame.step : 0
            stretch.longest = max(stretch.longest, stretch.now)
            steady[row] = stretch
        }
        // The view mostly holds steady and swings fast but rarely.
        let sorted = rates.sorted()
        XCTAssertLessThan(sorted[sorted.count * 95 / 100], 95 * .pi / 180)
        XCTAssertGreaterThan(
            Float(rates.filter { $0 < 15 * .pi / 180 }.count), Float(rates.count) * 0.4)
        // Every whole row and its turn has a stretch of at least 0.4 seconds without a swing.
        for row in 0..<Int(rig.length / path.period) {
            XCTAssertGreaterThan(steady[row]?.longest ?? 0, 0.4, "row \(row)")
        }
    }

    func testTheCameraStaysClearOfTheBooks() {
        let spacing: Float = 1.05
        for count in [39, 276] {
            var (rig, books) = chain(count, spacing: spacing)
            for frame in run(&rig, count: count, spacing: spacing) {
                let eye = frame.pose.eye
                // Over the fallen books, and over any book still standing near the eye.
                XCTAssertGreaterThan(eye.y, DominoCameraRig.lowest - 1e-3, "\(count)")
                for (index, place) in books.enumerated()
                where Float(index) * spacing > frame.raw
                    && simd_distance(SIMD2(eye.x, eye.z), place) < 1.2
                {
                    XCTAssertGreaterThan(eye.y, Self.tallest + 0.3, "\(count) at \(frame.time)")
                }
            }
        }
    }

    func testTheCameraFollowsTheFrontToTheLastBook() {
        for count in [39, 276] {
            var (rig, _) = chain(count)
            let frames = run(&rig, count: count)
            // A short chain is followed too: the eye travels with the front across the rows.
            let running = frames.filter(\.running)
            let travel = zip(running, running.dropFirst())
                .map { simd_distance($0.pose.eye, $1.pose.eye) }.reduce(0, +)
            XCTAssertGreaterThan(travel, rig.length * 0.6, "\(count)")
            // The reveal waits while the last book falls and lands, which takes it about a
            // book's height along the path, and the camera keeps it in view until then.
            let fell = frames.firstIndex(where: \.done)!
            let reveal = frames.firstIndex(where: \.revealing)!
            XCTAssertGreaterThan(frames[reveal].time - frames[fell].time, 0.5, "\(count)")
            let end = rig.point(at: rig.length)
            let heading = rig.path.point(at: rig.length).heading
            let landed = end + heading * Self.typical / 2
            for frame in frames[fell...reveal] {
                let point = frame.pose.project(
                    [landed.x, 0.3, landed.y], fieldOfView: Self.fieldOfView, aspect: Self.aspect)
                XCTAssertGreaterThan(point.x, Self.area.low.x, "\(count) at \(frame.time)")
                XCTAssertLessThan(point.x, Self.area.high.x, "\(count) at \(frame.time)")
                XCTAssertGreaterThan(point.y, Self.area.low.y, "\(count) at \(frame.time)")
                XCTAssertLessThan(point.y, Self.area.high.y, "\(count) at \(frame.time)")
                XCTAssertLessThan(range(of: frame.pose), 20, "\(count) at \(frame.time)")
            }
            // By then, it looks down on the fallen books from at least about
            // `landingElevation`, with where the last book lands in the middle third of the
            // view's height rather than under a band of far table.
            let held = frames[reveal - 1].pose
            XCTAssertGreaterThan(
                elevation(of: held.eye, above: [landed.x, 0.3, landed.y]),
                DominoCameraRig.landingElevation - 3 * .pi / 180, "\(count)")
            let shown = held.project(
                [landed.x, 0.3, landed.y], fieldOfView: Self.fieldOfView, aspect: Self.aspect)
            let third = (Self.area.high.y - Self.area.low.y) / 3
            XCTAssertGreaterThan(shown.y, Self.area.low.y + third, "\(count)")
            XCTAssertLessThan(shown.y, Self.area.high.y - third, "\(count)")
            // Over the run's last second, the camera stays close on the front.
            for frame in frames[..<fell] where frame.time > frames[fell].time - 1 {
                let front = rig.point(at: frame.raw)
                let point = frame.pose.project(
                    [front.x, Self.typical / 2, front.y], fieldOfView: Self.fieldOfView,
                    aspect: Self.aspect)
                XCTAssertGreaterThan(point.x, Self.area.low.x, "\(count) at \(frame.time)")
                XCTAssertLessThan(point.x, Self.area.high.x, "\(count) at \(frame.time)")
                XCTAssertLessThan(range(of: frame.pose), 20, "\(count) at \(frame.time)")
            }
        }
    }

    func testTheSameInputsGiveTheSamePoses() {
        var (one, _) = chain(60)
        var (two, _) = chain(60)
        XCTAssertEqual(
            run(&one, count: 60).map(\.pose), run(&two, count: 60).map(\.pose))
    }

    func testEstablishingMoveSettlesOnTheFirstBook() {
        for count in [39, 276] {
            var (rig, books) = chain(count)
            // It starts on the finale, so a clip opens and ends on the same frame.
            XCTAssertEqual(rig.pose, Self.finale)
            XCTAssertLessThanOrEqual(rig.establishTime, DominoCameraRig.establishTimes.upperBound)
            let start = rig.pose
            var time: Float = 0
            var closest = Float.infinity
            while time < rig.establishTime {
                time += 1.0 / 60
                closest = min(
                    closest,
                    range(
                        of: rig.step(.init(distance: 0, started: false, done: false), by: 1.0 / 60)
                    ))
            }
            let settled = rig.pose
            // It lands on its rest pose, low behind the first book, without diving past it and
            // backing off.
            XCTAssertGreaterThan(closest, range(of: settled) * 0.97, "\(count)")
            XCTAssertLessThan(elevation(of: settled), 20 * .pi / 180, "\(count)")
            XCTAssertLessThan(
                simd_distance(settled.eye, settled.target), simd_distance(start.eye, start.target))
            // The first book, the one to push, shows clear of the bars and above the hint, a
            // band about 0.2 high over the bottom bar.
            let first = settled.project(
                [books[0].x, 0, books[0].y], fieldOfView: Self.fieldOfView, aspect: Self.aspect)
            XCTAssertGreaterThan(first.x, Self.area.low.x, "\(count)")
            XCTAssertLessThan(first.x, Self.area.high.x, "\(count)")
            XCTAssertGreaterThan(first.y, Self.area.low.y + 0.2, "\(count)")
            XCTAssertLessThan(first.y, Self.area.high.y, "\(count)")
        }
    }

    func testTheCameraPushesInAsTheFrontNearsADenseCobweb() {
        let web = DominoCameraRig.Cobweb(distance: 80, density: 1)
        var (plain, _) = chain(160)
        // A web over a gap of about two months, another dense web too soon after the first,
        // and a dense web at the push, which the opening frames already, draw nothing.
        var (webbed, _) = chain(
            160,
            cobwebs: [
                web, .init(distance: 30, density: 0.4), .init(distance: 110, density: 0.5),
                .init(distance: 1, density: 1),
            ])
        XCTAssertEqual(webbed.cobwebs, [web])
        // At about the chain's pace in the scene. The runs match frame for frame until the
        // reveal, whose length depends on the view.
        let without = run(&plain, count: 160, speed: 13).filter(\.running)
        let with = run(&webbed, count: 160, speed: 13).filter(\.running)
        func ratio(_ index: Int) -> Float {
            range(of: with[index].pose) / range(of: without[index].pose)
        }
        // The camera comes closest, about a quarter closer than without the web, as the front
        // reaches the web and tears it.
        let tear = with.firstIndex { $0.raw >= web.distance }!
        let closest = with.indices.min { ratio($0) < ratio($1) }!
        XCTAssertLessThan(ratio(closest), 0.8)
        XCTAssertEqual(with[closest].time, with[tear].time, accuracy: 0.5)
    }

    func testAWebTearsWithoutJoltingTheView() {
        // A dense web along the fourth row, which the camera films from nearly behind.
        let path = chain(276).rig.path
        let web = DominoCameraRig.Cobweb(
            distance: 3 * path.period + path.rowLength / 2, density: 1)
        var (rig, _) = chain(276, cobwebs: [web])
        XCTAssertEqual(rig.cobwebs, [web])
        XCTAssertEqual(sides(of: rig)[3], sides(of: rig).min()!)
        let frames = run(&rig, count: 276, speed: 13, even: true)
        let tear = frames.first { $0.running && $0.raw >= web.distance }!.time
        // Within a second of the tear, the view's turn changes no faster than a swing's ease
        // allows, as in `testTheCameraChasesTheFrontLowAndClose`: the push in and the lean
        // toward the web ease in and out.
        var hardest: Float = 0
        for index in 2..<frames.count where abs(frames[index].time - tear) < 1 {
            let one = spin(from: frames[index - 2].pose, to: frames[index - 1].pose)
            let two = spin(from: frames[index - 1].pose, to: frames[index].pose)
            hardest = max(
                hardest,
                simd_length(two / frames[index].step - one / frames[index - 1].step)
                    / frames[index].step)
        }
        XCTAssertGreaterThan(hardest, 0)
        XCTAssertLessThan(hardest, 8)
    }

    func testAWebOnATurnTearsInView() {
        // The middle of the fourth row's turn, which the camera swings round as the web tears.
        let path = chain(160).rig.path
        let distance = 3 * path.period + path.rowLength + .pi * path.radius / 2
        let web = DominoCameraRig.Cobweb(distance: distance, density: 1)
        var (rig, _) = chain(160, cobwebs: [web])
        XCTAssertEqual(rig.cobwebs, [web])
        let frames = run(&rig, count: 160, speed: 13)
        let tear = frames.firstIndex { $0.raw >= web.distance }!
        let place = rig.point(at: web.distance)
        // The swing follows the front round the turn, so the web holds its place in the view:
        // it shows inside the area as it tears and through most of the half second before.
        func shows(_ frame: Frame) -> Bool {
            let point = frame.pose.project(
                [place.x, Self.typical * 0.9, place.y], fieldOfView: Self.fieldOfView,
                aspect: Self.aspect)
            return point.x > Self.area.low.x && point.x < Self.area.high.x
                && point.y > Self.area.low.y && point.y < Self.area.high.y
        }
        XCTAssertTrue(shows(frames[tear]))
        let before = frames[..<tear].filter { $0.time > frames[tear].time - 0.5 }
        XCTAssertGreaterThan(Float(before.filter(shows).count), Float(before.count) * 0.8)
    }

    func testATornWebNoLongerDrawsTheCamera() {
        // A web that a lifted book tore before the front reached it: the camera no longer
        // pushes in on it or leans toward it.
        let path = chain(276).rig.path
        let web = DominoCameraRig.Cobweb(
            distance: 3 * path.period + path.rowLength / 2, density: 1)
        var (torn, _) = chain(276, cobwebs: [web])
        var (whole, _) = chain(276, cobwebs: [web])
        torn.forgetCobweb(at: web.distance + 1e-4)
        XCTAssertEqual(torn.cobwebs, [])
        XCTAssertEqual(whole.cobwebs, [web])
        XCTAssertNotEqual(
            run(&torn, count: 276, speed: 13, even: true).map(\.pose),
            run(&whole, count: 276, speed: 13, even: true).map(\.pose))
    }

    func testAWebAtThePushLeavesTheCameraAlone() {
        // The opening already frames the first books, so a dense web between the first two
        // books, which tears on the push, changes nothing.
        var (plain, _) = chain(120)
        var (webbed, _) = chain(120, cobwebs: [.init(distance: 0.5, density: 1)])
        XCTAssertEqual(webbed.cobwebs, [])
        XCTAssertEqual(run(&plain, count: 120).map(\.pose), run(&webbed, count: 120).map(\.pose))
    }

    func testTheRevealEndsOnTheFinale() {
        for count in [39, 120] {
            var (rig, _) = chain(count)
            let frames = run(&rig, count: count)
            XCTAssertEqual(rig.pose, Self.finale, "\(count)")
            // It rises before it pulls back: by half way, most of the climb is done, and less
            // than half of the pull back.
            let start = frames.firstIndex(where: \.revealing)! - 1
            let half = frames[start...]
                .first { $0.time > frames[start].time + rig.revealTime / 2 }!
            let climb =
                (elevation(of: half.pose) - elevation(of: frames[start].pose))
                / (elevation(of: Self.finale) - elevation(of: frames[start].pose))
            XCTAssertGreaterThan(climb, 0.6, "\(count)")
            func scale(_ pose: DominoCameraPose) -> Float { log(range(of: pose)) }
            let pulled =
                (scale(half.pose) - scale(frames[start].pose))
                / (scale(Self.finale) - scale(frames[start].pose))
            XCTAssertLessThan(pulled, 0.45, "\(count)")
            // It settles onto the finale without passing it and creeping back.
            let near = frames[start...]
                .firstIndex { simd_distance($0.pose.eye, Self.finale.eye) < 1 }!
            for (before, after) in zip(frames[near...], frames[(near + 1)...]) {
                XCTAssertLessThanOrEqual(
                    simd_distance(after.pose.eye, Self.finale.eye),
                    simd_distance(before.pose.eye, Self.finale.eye) + 1e-4,
                    "\(count) at \(after.time)")
            }
        }
    }

    func testPosesLookAtTheirTargets() {
        let pose = DominoCameraPose(eye: [-20, 12, -6], target: [1, 1, 2])
        let shown = pose.project(pose.target, fieldOfView: Self.fieldOfView, aspect: Self.aspect)
        XCTAssertEqual(shown.x, 0, accuracy: 1e-5)
        XCTAssertEqual(shown.y, 0, accuracy: 1e-5)
        // The camera stays level: its right points along the table.
        XCTAssertEqual(pose.rotation.act([1, 0, 0]).y, 0, accuracy: 1e-5)
        // A roll turns the view about the target, banking left: its right side rises.
        var rolled = pose
        rolled.roll = 0.1
        let centered = rolled.project(
            rolled.target, fieldOfView: Self.fieldOfView, aspect: Self.aspect)
        XCTAssertEqual(simd_length(centered), 0, accuracy: 1e-5)
        XCTAssertGreaterThan(rolled.rotation.act([1, 0, 0]).y, 0.08)
    }

    func testOverviewSpringIsStableOnLongFramesAndSettles() {
        var spring = DominoOverviewSpring(.zero)
        let aim = SIMD8<Float>(10, -4, 0.5, 0.3, -0.2, 0, 0, 0)
        for _ in 0..<40 {
            // Half-second frames, as after a hitch, neither diverge nor pass the goal.
            spring.step(toward: aim, lag: DominoOverviewSpring.followingLag, by: 0.5)
            for lane in 0..<5 {
                XCTAssertLessThanOrEqual(abs(spring.value[lane]), abs(aim[lane]) * 1.001)
            }
        }
        // Once there, it rests exactly on the goal.
        XCTAssertEqual(spring.value, aim)
        XCTAssertEqual(spring.velocity, .zero)
    }

    func testCameraModes() {
        XCTAssertEqual(DominoCameraMode.allCases.map(\.title), ["Overview", "Follow"])
        XCTAssertEqual(DominoCameraMode(rawValue: "follow"), .follow)
    }

    /// How far from straight behind the front each row's shot films it, in radians: rows run
    /// along +x and -x in turn.
    private func sides(of rig: DominoCameraRig) -> [Float] {
        rig.shots.enumerated()
            .map { row, shot in
                row.isMultiple(of: 2) ? shot.azimuth - .pi : 2 * .pi - shot.azimuth
            }
    }

    /// The angle between two poses' views, in radians.
    private func turn(from a: DominoCameraPose, to b: DominoCameraPose) -> Float {
        simd_length(spin(from: a, to: b))
    }

    /// The turn from one pose's view to another's, as an axis scaled by radians.
    private func spin(from a: DominoCameraPose, to b: DominoCameraPose) -> SIMD3<Float> {
        let one = simd_normalize(a.target - a.eye)
        let two = simd_normalize(b.target - b.eye)
        let axis = simd_cross(one, two)
        let sine = simd_length(axis)
        return sine > 1e-9 ? axis / sine * atan2(sine, simd_dot(one, two)) : .zero
    }

    /// The distance from a pose's eye to the point it looks at.
    private func range(of pose: DominoCameraPose) -> Float {
        simd_distance(pose.eye, pose.target)
    }

    /// How far above its target a pose's eye looks down from, in radians.
    private func elevation(of pose: DominoCameraPose) -> Float {
        elevation(of: pose.eye, above: pose.target)
    }

    /// How far above `point` the eye looks down from, in radians.
    private func elevation(of eye: SIMD3<Float>, above point: SIMD3<Float>) -> Float {
        asin((eye.y - point.y) / simd_distance(eye, point))
    }
}
