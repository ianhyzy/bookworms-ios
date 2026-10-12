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
            previous = rig.front
            guard time > 1, raw < 110 else { continue }
            paces.append(rig.pace)
            // The estimate keeps within about a book of the books themselves.
            XCTAssertEqual(rig.estimate, raw, accuracy: 1.2, "at \(time)")
        }
        // Between books the raw front stops and starts; the smoothed one keeps its pace.
        XCTAssertLessThan(paces.max()! - paces.min()!, 1.8)
        XCTAssertEqual(paces.reduce(0, +) / Float(paces.count), 18, accuracy: 0.5)
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
            var (rig, _) = chain(count)
            let frames = run(&rig, count: count, speed: count > 200 ? 20 : 15)
            var shares: [Float] = []
            var elevations: [Float] = []
            var rolls: [Float] = []
            var shown = 0
            var lastSpin: SIMD3<Float>?
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
                // The view swings smoothly: its turn never changes faster than a swing's ease
                // allows, so it never snaps.
                let before = frames[index - 1]
                let spin = spin(from: before.pose, to: pose) / frame.step
                if let lastSpin {
                    XCTAssertLessThan(
                        simd_length(spin - lastSpin) / ((before.step + frame.step) / 2), 16,
                        "\(count) at \(frame.time)")
                }
                lastSpin = spin
            }
            // A typical book at the front fills about a quarter of the view's height.
            let close = shares.filter { $0 >= 0.2 && $0 <= 0.35 }.count
            XCTAssertGreaterThan(Float(close), Float(shares.count) * 0.9, "\(count)")
            // From low over the table, at heights that vary from row to row.
            XCTAssertGreaterThan(elevations.min()!, 8 * .pi / 180, "\(count)")
            XCTAssertLessThan(elevations.max()!, 26 * .pi / 180, "\(count)")
            XCTAssertGreaterThan(elevations.max()! - elevations.min()!, 4 * .pi / 180, "\(count)")
            // The front shows clear of the bars, and the camera banks as it swings.
            XCTAssertGreaterThan(Float(shown), Float(shares.count) * 0.95, "\(count)")
            XCTAssertGreaterThan(rolls.map(abs).max()!, 1 * .pi / 180, "\(count)")
        }
    }

    func testTheCameraSwingsRoundEachTurnFromBehindTheFront() {
        for count in [60, 276] {
            var (rig, _) = chain(count)
            let frames = run(&rig, count: count)
            let path = rig.path
            var bearings: [Float] = []
            for row in 0..<Int(rig.length / path.period) {
                let middle = Float(row) * path.period + path.rowLength / 2
                guard let frame = frames.first(where: { $0.raw >= middle }), frame.running
                else { continue }
                // Mid row, the eye is behind the front and on the side of the fallen rows, so
                // no standing book hides the front.
                let offset = SIMD2(frame.pose.eye.x, frame.pose.eye.z) - rig.point(at: frame.raw)
                XCTAssertLessThan(
                    simd_dot(offset, path.point(at: frame.raw).heading), 0, "\(count) row \(row)")
                XCTAssertLessThan(offset.y, 0, "\(count) row \(row)")
                bearings.append(atan2(offset.y, offset.x))
            }
            // Rows run back and forth, so the camera swings round each turn, more for longer
            // rows, which leave more time to swing.
            XCTAssertGreaterThan(bearings.count, 3, "\(count)")
            for (a, b) in zip(bearings, bearings.dropFirst()) {
                XCTAssertGreaterThan(
                    abs(remainder(b - a, 2 * .pi)), (count > 200 ? 70 : 25) * .pi / 180,
                    "\(count)")
            }
        }
    }

    func testShotsVaryFromRowToRowAndCraneUpOverTheTurns() {
        for count in [39, 276] {
            let rig = chain(count).rig
            let period = rig.path.period
            let swingTime =
                min(DominoCameraRig.swingTime * DominoCameraRig.typicalPace, period)
                / DominoCameraRig.typicalPace
            let shots = (0..<10).map(rig.shot(row:))
            // How far past straight behind each row's camera films, toward -z, where the rows
            // have fallen.
            let sides = shots.enumerated()
                .map { $0.isMultiple(of: 2) ? $1.azimuth - .pi : 2 * .pi - $1.azimuth }
            for (row, shot) in shots.enumerated() {
                XCTAssertGreaterThanOrEqual(shot.elevation, DominoCameraRig.elevations.lowerBound)
                XCTAssertLessThanOrEqual(shot.elevation, DominoCameraRig.elevations.upperBound)
                XCTAssertGreaterThanOrEqual(shot.share, DominoCameraRig.shares.lowerBound)
                XCTAssertLessThanOrEqual(shot.share, DominoCameraRig.shares.upperBound)
                XCTAssertGreaterThanOrEqual(sides[row], DominoCameraRig.sides.lowerBound)
                XCTAssertLessThan(sides[row], .pi / 2, "\(count)")
                guard row > 0 else { continue }
                // Neighboring rows differ in angle and distance.
                let before = shots[row - 1]
                XCTAssertGreaterThan(abs(sides[row] - sides[row - 1]), 3 * .pi / 180, "\(count)")
                XCTAssertGreaterThan(
                    abs(shot.share - before.share)
                        / (DominoCameraRig.shares.upperBound - DominoCameraRig.shares.lowerBound),
                    0.3, "\(count) \(row)")
                // A swing keeps within its average rate at a typical pace, however short the
                // row.
                XCTAssertLessThanOrEqual(
                    abs(shot.azimuth - before.azimuth) / swingTime,
                    DominoCameraRig.swingRate * 1.001, "\(count) \(row)")
                // Halfway round the turn before the row, the camera cranes up.
                let turn =
                    Float(row - 1) * period + rig.path.rowLength + .pi * rig.path.radius / 2
                    - DominoCameraRig.swingLead * DominoCameraRig.typicalPace
                guard turn + swingTime * DominoCameraRig.typicalPace / 2 <= rig.length else {
                    continue
                }
                XCTAssertGreaterThan(
                    rig.plan(at: turn).shot.elevation, max(shot.elevation, before.elevation),
                    "\(count) \(row)")
            }
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
            // The reveal waits while the last book lands.
            let fell = frames.firstIndex(where: \.done)!
            let reveal = frames.firstIndex(where: \.revealing)!
            XCTAssertEqual(
                frames[reveal].time - frames[fell].time, DominoCameraRig.landTime, accuracy: 0.03,
                "\(count)")
            // Over the run's last second and until the reveal, the camera stays close on the
            // front and then the last book.
            let end = rig.point(at: rig.length)
            for frame in frames[..<reveal] where frame.time > frames[fell].time - 1 {
                let front = frame.done ? end : rig.point(at: frame.raw)
                let point = frame.pose.project(
                    [front.x, Self.typical / 2, front.y], fieldOfView: Self.fieldOfView,
                    aspect: Self.aspect)
                XCTAssertGreaterThan(point.x, Self.area.low.x, "\(count) at \(frame.time)")
                XCTAssertLessThan(point.x, Self.area.high.x, "\(count) at \(frame.time)")
                XCTAssertGreaterThan(point.y, Self.area.low.y, "\(count) at \(frame.time)")
                XCTAssertLessThan(point.y, Self.area.high.y, "\(count) at \(frame.time)")
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
        // The camera comes closest, about a fifth closer than without the web, as the front
        // reaches the web and tears it.
        let tear = with.firstIndex { $0.raw >= web.distance }!
        let closest = with.indices.min { ratio($0) < ratio($1) }!
        XCTAssertLessThan(ratio(closest), 0.85)
        XCTAssertEqual(with[closest].time, with[tear].time, accuracy: 0.5)
    }

    func testAWebOnATurnTearsInView() {
        // The middle of the fourth row's turn, which the camera swings round as the web tears.
        let path = chain(160).rig.path
        let distance = 3 * path.period + path.rowLength + .pi * path.radius / 2
        let web = DominoCameraRig.Cobweb(distance: distance, density: 1)
        var (rig, _) = chain(160, cobwebs: [web])
        XCTAssertEqual(rig.cobwebs, [web])
        let frames = run(&rig, count: 160)
        let tear = frames.first { $0.raw >= web.distance }!
        let place = rig.point(at: web.distance)
        let shown = tear.pose.project(
            [place.x, Self.tallest * 0.9, place.y], fieldOfView: Self.fieldOfView,
            aspect: Self.aspect)
        XCTAssertGreaterThan(shown.x, Self.area.low.x)
        XCTAssertLessThan(shown.x, Self.area.high.x)
        XCTAssertGreaterThan(shown.y, Self.area.low.y)
        XCTAssertLessThan(shown.y, Self.area.high.y)
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
