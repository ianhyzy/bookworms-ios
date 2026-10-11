import XCTest
import simd

@testable import Bookworms

/// The Follow camera's math: the smoothed front, the springs' limits, how fast the view sweeps
/// and turns, clearance from the chain, and its establishing move, cobweb push in, and reveal;
/// and the overview camera's spring.
final class DominoCameraTests: XCTestCase {
    private static let fieldOfView: Float = 38 * .pi / 180
    /// An iPhone in portrait, composing between its bars.
    private static let aspect: Float = 402.0 / 874
    private static let area = DominoCameraRig.Area(low: [-0.92, -0.78], high: [0.92, 0.57])
    private static let tallest: Float = 2.8
    /// A high view of the whole table from the side the camera films from, as the scene frames
    /// the finale.
    private static let finale = DominoCameraPose(eye: [-90, 110, -20], target: .zero)

    /// One frame of a simulated run.
    private struct Frame {
        var time: Float
        var step: Float
        /// The front as `DominoScene` reports it.
        var raw: Float
        var running: Bool
        var pose: DominoCameraPose
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
        let done = time + 1
        func raw(at time: Float) -> Float {
            guard let index = starts.lastIndex(where: { $0 <= time }) else { return 0 }
            guard index + 1 < count else { return Float(index) * spacing }
            let share = min(1, (time - starts[index]) / (starts[index + 1] - starts[index]))
            return (Float(index) + share * share) * spacing
        }
        var frames: [Frame] = []
        var clock: Float = 0
        var index = 0
        while clock < done + rig.revealTime + 4 {
            let step: Float = !even && index % 7 == 3 ? 1.0 / 40 : 1.0 / 60
            clock += step
            index += 1
            let front = raw(at: clock)
            let pose = rig.step(
                .init(distance: front, started: clock >= wait, done: clock >= done), by: step)
            frames.append(
                Frame(
                    time: clock, step: step, raw: front, running: clock >= wait && clock < done,
                    pose: pose))
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
                time: 0, step: 1.0 / 60, raw: 0, running: false,
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
        }
    }

    func testTheCameraReadsTheTurnsAndStaysClearOfTheChain() {
        for count in [39, 120, 276] {
            var (rig, books) = chain(count)
            // A short chain fits the view whole, and a long one is trucked across.
            XCTAssertEqual(rig.holdsChain, count < 100, "\(count)")
            let frames = run(&rig, count: count, speed: count > 200 ? 20 : 15)
            let floor = Self.tallest + DominoCameraRig.clearance
            var shown = 0
            var sweeps: [Float] = []
            var lastSide: Float?
            var lastSpin: SIMD3<Float>?
            for (index, after) in frames.enumerated().dropFirst() {
                let before = frames[index - 1]
                let pose = after.pose
                // Above the tallest book, so it never passes through a book or the table.
                XCTAssertGreaterThanOrEqual(pose.eye.y, floor - 1e-3, "\(count) at \(after.time)")
                guard after.running else {
                    lastSpin = nil
                    continue
                }
                // The view turns gently even as the front swings through the half turns, and
                // a short chain's turn changes gently too.
                let spin = spin(from: before.pose, to: pose) / after.step
                XCTAssertLessThan(simd_length(spin), 0.35, "\(count) at \(after.time)")
                if count < 100, let lastSpin {
                    XCTAssertLessThan(
                        simd_length(spin - lastSpin) / ((before.step + after.step) / 2),
                        10 * .pi / 180, "\(count) at \(after.time)")
                }
                lastSpin = spin
                // A point of the table the camera looked at crosses the view slowly.
                let looked = pose.project(
                    before.pose.target, fieldOfView: Self.fieldOfView, aspect: Self.aspect)
                sweeps.append(abs(looked.x) / 2 / after.step)
                // From low over the first rows, rising and falling a little, as the brief asks.
                XCTAssertGreaterThan(elevation(of: pose), 15 * .pi / 180, "\(count)")
                XCTAssertLessThan(elevation(of: pose), 35 * .pi / 180, "\(count)")
                // The eye stays beyond the rows' near ends, rather than swinging round each
                // turn to the other side of the chain.
                let side = pose.eye.x - books.map(\.x).min()!
                XCTAssertLessThan(side, -2, "\(count) at \(after.time)")
                if let lastSide {
                    XCTAssertEqual(side, lastSide, accuracy: 20 * after.step, "\(count)")
                }
                lastSide = side
                // The front shows clear of the bars.
                let front = rig.point(at: after.raw)
                let point = pose.project(
                    [front.x, 1.2, front.y], fieldOfView: Self.fieldOfView, aspect: Self.aspect)
                if point.x > Self.area.low.x, point.x < Self.area.high.x,
                    point.y > Self.area.low.y, point.y < Self.area.high.y
                {
                    shown += 1
                }
            }
            XCTAssertGreaterThan(Float(shown), Float(sweeps.count) * 0.95, "\(count)")
            XCTAssertLessThan(sweeps.sorted()[sweeps.count * 95 / 100], 0.25, "\(count)")
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
            XCTAssertLessThanOrEqual(rig.establishTime, 5)
            let start = rig.pose
            var time: Float = 0
            while time < rig.establishTime + 1 {
                time += 1.0 / 60
                rig.step(.init(distance: 0, started: false, done: false), by: 1.0 / 60)
            }
            let settled = rig.pose
            XCTAssertLessThan(elevation(of: settled), 30 * .pi / 180, "\(count)")
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
        let web = DominoCameraRig.Cobweb(distance: 70, density: 1)
        var (plain, _) = chain(120)
        // A web over a gap of about two months, and another dense web too soon after the
        // first, draw nothing.
        var (webbed, _) = chain(
            120,
            cobwebs: [web, .init(distance: 30, density: 0.4), .init(distance: 100, density: 0.8)])
        XCTAssertEqual(webbed.cobwebs, [web])
        let without = run(&plain, count: 120)
        let with = run(&webbed, count: 120)
        func range(_ index: Int) -> Float {
            simd_distance(with[index].pose.eye, with[index].pose.target)
                / simd_distance(without[index].pose.eye, without[index].pose.target)
        }
        // The camera comes closest, a quarter closer or more than without the web, as the
        // front reaches the web and tears it.
        let tear = with.firstIndex { $0.raw >= web.distance }!
        let closest = with.indices.min { range($0) < range($1) }!
        XCTAssertLessThan(range(closest), 0.75)
        XCTAssertEqual(with[closest].time, with[tear].time, accuracy: 0.5)
    }

    func testTheRevealEndsOnTheFinale() {
        for count in [39, 120] {
            var (rig, _) = chain(count)
            let frames = run(&rig, count: count)
            XCTAssertEqual(rig.pose, Self.finale, "\(count)")
            // It rises before it pulls back: by half way, most of the climb is done, and
            // little of the pull back.
            let done = frames.lastIndex { $0.running }!
            let half = frames[(done + 1)...]
                .first { $0.time > frames[done].time + rig.revealTime / 2 }!
            let climb =
                (elevation(of: half.pose) - elevation(of: frames[done].pose))
                / (elevation(of: Self.finale) - elevation(of: frames[done].pose))
            XCTAssertGreaterThan(climb, 0.6, "\(count)")
            func range(_ pose: DominoCameraPose) -> Float {
                log(simd_distance(pose.eye, pose.target))
            }
            let pulled =
                (range(half.pose) - range(frames[done].pose))
                / (range(Self.finale) - range(frames[done].pose))
            XCTAssertLessThan(pulled, 0.3, "\(count)")
            // It settles onto the finale without passing it and creeping back.
            let near = frames[done...]
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

    /// How far above its target a pose's eye looks down from, in radians.
    private func elevation(of pose: DominoCameraPose) -> Float {
        asin((pose.eye.y - pose.target.y) / simd_distance(pose.eye, pose.target))
    }
}
