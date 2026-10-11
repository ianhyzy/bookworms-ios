import Foundation
import simd

/// The cameras that **Camera** in **Sort and filter** offers for the dominoes.
enum DominoCameraMode: String, CaseIterable, Identifiable {
    /// Frames the whole path, eases after the falling books, and eases back once all have
    /// fallen.
    case overview
    /// Films the chain as a camera operator would (`DominoCameraRig`).
    case follow

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// A camera's place and the point it looks at. The camera's up is the table's.
struct DominoCameraPose: Equatable {
    var eye: SIMD3<Float>
    var target: SIMD3<Float>

    /// The rotation that turns a camera looking down -z, with +y up, toward `target`.
    var rotation: simd_quatf {
        let back = simd_normalize(eye - target)
        let right = simd_normalize(simd_cross([0, 1, 0], back))
        return simd_quatf(simd_float3x3(columns: (right, simd_cross(back, right), back)))
    }

    /// Where `point` shows in normalized device coordinates, from -1 to 1 each way with y up,
    /// for a vertical `fieldOfView` and a view of width-to-height `aspect`.
    func project(_ point: SIMD3<Float>, fieldOfView: Float, aspect: Float) -> SIMD2<Float> {
        let local = rotation.inverse.act(point - eye)
        return SIMD2(local.x / aspect, local.y) / (-local.z * tan(fieldOfView / 2))
    }
}

/// The Follow camera: a camera operator who films the dominoes from beside the serpentine, a
/// little behind the chain's front, and looks a little ahead of it.
///
/// The chain runs too fast to swing around each half turn: a front at 15 to 20 units a second
/// takes a turn in under half a second. So the camera rides a dolly track beside the rows'
/// near ends, looking along them, and the rows recede up the tall view while the front sweeps
/// along each one. The track follows the front averaged over most of a row and turn ahead of
/// it, so the camera reads the turns before the front reaches them and trucks steadily from row
/// to row instead of turning with each one. The rows nearest the front fit the view, and the
/// front's row sits on the left third, with the standing rows to its right.
///
/// The rig is a deterministic value type: the same path, fronts, and time steps give the same
/// poses, so tests and an offscreen renderer can drive it as `DominoScene` does. Each `step`:
///
/// 1. Smooths the front with a critically damped spring that never runs backward, so the
///    camera follows a continuous wave instead of the books one at a time.
/// 2. Sets a goal: an establishing move onto the first book before the chain starts, the
///    follow pose while it runs, and a crane up and pull back to `finale` once every book has
///    fallen. While following, the angle drifts slowly in height and bearing, as a drone would,
///    the camera pushes in as the front nears a cobweb and when the chain slows or stops, and
///    pulls back as it gathers speed.
/// 3. Moves the eye and the point it looks at toward the goal with separate critically damped
///    springs, within limits on speed, acceleration, and turn rate, and keeps the eye above the
///    tallest book.
///
/// Scene units are decimeters, as in `DominoLayout`. Rows run along x and advance toward +z.
struct DominoCameraRig {
    /// What the rig follows each frame.
    struct Front: Equatable {
        /// How far along the path the chain's front has come, unfiltered.
        var distance: Float
        /// Whether the chain has started to fall.
        var started: Bool
        /// Whether every book has fallen.
        var done: Bool
    }

    /// A cobweb's place along the path and how dense it is, from 0 to 1
    /// (`DominoLayout.cobweb(days:)`).
    struct Cobweb: Equatable {
        var distance: Float
        var density: Float
    }

    /// The part of the view to compose in, in normalized device coordinates: clear of the bars
    /// over the view's edges.
    struct Area: Equatable {
        var low: SIMD2<Float>
        var high: SIMD2<Float>
    }

    // MARK: Tuning

    /// The front's spring, in radians per second. Its lag at a steady pace, twice the pace over
    /// this, is added back (see `estimate`).
    static let frontStiffness: Float = 6
    static let eyeStiffness: Float = 1.6
    static let targetStiffness: Float = 2.4
    /// The push in's spring, slow enough that pushes for nearby cobwebs blend into one.
    static let pushStiffness: Float = 1.6
    /// The fastest the eye and the point it looks at move, in units per second.
    static let maximumSpeed: Float = 30
    /// The hardest they speed up or slow down, in units per second squared.
    static let maximumAcceleration: Float = 26
    /// The fastest the view turns, in radians per second.
    static let maximumTurnRate: Float = 0.9
    /// The step the springs integrate by, at most.
    static let substep: Float = 1.0 / 240
    /// The camera's bearing from the rows: 0 looks along +x, and larger bearings look more
    /// toward the standing rows ahead.
    static let bearing: Float = 14 * .pi / 180
    /// How far the bearing turns over the whole run, from half of it before to half after.
    static let arc: Float = 10 * .pi / 180
    static let elevation: Float = 36 * .pi / 180
    /// How far ahead of the front the track looks, in seconds at the front's pace.
    static let lead: Float = 0.1
    /// The pace under which the camera pushes in on the front, in units per second.
    static let cruise: Float = 9
    /// How long the establishing move takes, in seconds.
    static let establishing: Float = 5
    /// The least distance from the eye to the front's row, in heights of the tallest book.
    static let nearest: Float = 9
    /// How far the eye stays above the tallest book.
    static let clearance: Float = 1.2

    // MARK: Geometry

    let path: DominoPath
    /// The path's offset from the table: a path point less this is where it lies on the table.
    let offset: SIMD2<Float>
    /// The path's length, up to the last book.
    let length: Float
    let tallest: Float
    let cobwebs: [Cobweb]
    /// The composed view the reveal ends in.
    let finale: DominoCameraPose
    let fieldOfView: Float
    let aspect: Float
    let area: Area
    /// The distance from the eye to the front's row that fits that row in `area`.
    let distance: Float
    /// How long the reveal takes, in seconds: 5, and up to 3 more for each doubling of the
    /// distance it pulls back, so a long path's reveal keeps an unhurried pace.
    let revealTime: Float

    // MARK: State

    /// The camera's pose after the last step.
    private(set) var pose: DominoCameraPose
    private var eyeVelocity = SIMD3<Float>.zero
    private var targetVelocity = SIMD3<Float>.zero
    private var previousGoal: DominoCameraPose?
    /// The smoothed front and its speed.
    private(set) var front: Float = 0
    private(set) var pace: Float = 0
    /// How far the camera pushes in for cobwebs (x) and for a slow chain (y), each from 0 to
    /// 1 and smoothed, and how fast they change.
    private var push: SIMD2<Float> = [0, 1]
    private var pushSpeed = SIMD2<Float>.zero
    /// Seconds since the rig started, and since every book fell.
    private var clock: Float = 0
    private var doneTime: Float = 0

    init(
        path: DominoPath, offset: SIMD2<Float>, length: Float, tallest: Float, cobwebs: [Cobweb],
        finale: DominoCameraPose, fieldOfView: Float, aspect: Float, area: Area
    ) {
        self.path = path
        self.offset = offset
        self.length = max(0, length)
        self.tallest = tallest
        self.cobwebs = cobwebs
        self.finale = finale
        self.fieldOfView = fieldOfView
        self.aspect = aspect
        self.area = area
        // Short rows fit close in, but no closer than shows a few rows of books around the
        // front.
        distance = max(
            Self.fit(
                path: path, tallest: tallest, fieldOfView: fieldOfView, aspect: aspect, area: area),
            Self.nearest * tallest)
        revealTime = min(
            8, 5 + 3 * max(0, log2(simd_distance(finale.eye, finale.target) / distance)))
        pose = finale
        pose = compose(establishing(following(at: 0, pace: 0)))
    }

    /// Continues from `pose` at rest, such as after a pinch or drag moved the camera.
    mutating func reset(to pose: DominoCameraPose) {
        self.pose = pose
        eyeVelocity = .zero
        targetVelocity = .zero
        previousGoal = nil
    }

    /// Advances the camera by `deltaTime` seconds, following `input`, and returns its pose.
    @discardableResult
    mutating func step(_ input: Front, by deltaTime: Float) -> DominoCameraPose {
        guard deltaTime > 0 else { return pose }
        let steps = max(1, Int((deltaTime / Self.substep).rounded(.up)))
        let step = deltaTime / Float(steps)
        let raw = input.started ? min(max(input.distance, 0), length) : 0
        let stiffness = Self.frontStiffness
        for _ in 0..<steps {
            let acceleration = stiffness * stiffness * (raw - front) - 2 * stiffness * pace
            pace = max(0, pace + acceleration * step)
            front += pace * step
        }
        clock += deltaTime
        doneTime = input.done ? doneTime + deltaTime : 0
        // A chain that slows at its last book has ended rather than stalled.
        let ending = min(max(length - estimate, 0) / 2, 1)
        let pushGoal = SIMD2(
            cobwebPush(at: estimate, pace: pace),
            (1 - Self.ease(min(pace / Self.cruise, 1))) * ending)
        let pushStiffness = Self.pushStiffness
        for _ in 0..<steps {
            pushSpeed +=
                (pushStiffness * pushStiffness * (pushGoal - push) - 2 * pushStiffness * pushSpeed)
                * step
            push += pushSpeed * step
        }
        let goal = self.goal()
        let start = previousGoal ?? goal
        previousGoal = goal
        // The goal's own velocity, so the springs track a steadily moving goal without lag.
        let eyeDrift = Self.clamped((goal.eye - start.eye) / deltaTime, to: Self.maximumSpeed)
        let targetDrift = Self.clamped(
            (goal.target - start.target) / deltaTime, to: Self.maximumSpeed)
        for index in 1...steps {
            let before = pose
            let share = Float(index) / Float(steps)
            Self.spring(
                &pose.eye, &eyeVelocity, toward: start.eye + (goal.eye - start.eye) * share,
                moving: eyeDrift, stiffness: Self.eyeStiffness, by: step)
            Self.spring(
                &pose.target, &targetVelocity,
                toward: start.target + (goal.target - start.target) * share, moving: targetDrift,
                stiffness: Self.targetStiffness, by: step)
            limitTurn(from: before, by: step)
            let floor = tallest + Self.clearance
            if pose.eye.y < floor {
                pose.eye.y = floor
                eyeVelocity.y = max(0, eyeVelocity.y)
            }
        }
        return pose
    }

    // MARK: Goals

    /// The front the camera frames: the smoothed front plus its lag at its pace, so it leads
    /// neither the books nor the springs.
    var estimate: Float { min(front + 2 * pace / Self.frontStiffness, length) }

    private func goal() -> DominoCameraPose {
        let follow = following(at: estimate, pace: pace)
        if doneTime > 0 {
            return reveal(from: follow, progress: min(doneTime / revealTime, 1))
        }
        let settled = Self.ease(min(clock / Self.establishing, 1))
        return compose(follow.mixed(with: establishing(follow), 1 - settled))
    }

    /// Where the camera films a front at `front` moving at `pace`: from beside the track, at
    /// the drifting bearing and elevation, closer in for cobwebs and a slow chain (`push`).
    private func following(at front: Float, pace: Float) -> Shot {
        // Across the rows, the path averaged over two rows and their turns, which repeat every
        // other row, all but stands still; along them, over half a row, it advances steadily.
        let ahead = front + pace * Self.lead
        let track = SIMD2(
            trackPoint(around: ahead, spread: path.period).x,
            trackPoint(around: ahead, spread: 0.45 * path.period).y)
        let book = point(at: front)
        let wander = Self.drift(at: clock)
        let progress = length > 0 ? front / length : 0
        let bearing = Self.bearing + (progress - 0.5) * Self.arc + wander.x
        let closer = push.max()
        let orbit = Orbit(
            target: [track.x, tallest * 0.4, track.y], azimuth: bearing + .pi,
            elevation: Self.elevation + wander.y,
            distance: distance * (1 + wander.z) * (1 - 0.15 * closer))
        // The eye rides the track. While the chain runs, the front sweeps through the view;
        // as it slows, the view leans toward it, onto the book to push when it stops.
        let lean = (book - track) * 0.5 * push.y
        // Off center while rows stand ahead, and centered by the last row, which has none.
        let third = Self.ease(min(max(length - front, 0) / path.period, 1))
        return Shot(orbit: orbit, lean: [lean.x, 0, lean.y], third: third)
    }

    /// The establishing move's start: higher, farther, and turned toward the first rows.
    private func establishing(_ follow: Shot) -> Shot {
        var start = follow
        start.orbit.azimuth += 0.7
        start.orbit.elevation = 50 * .pi / 180
        start.orbit.distance *= 1.6
        return start
    }

    /// The crane up and pull back from `follow` to `finale`, `progress` of the way: the camera
    /// rises first, swings round, and pulls back last, so the fallen path unrolls below it.
    private func reveal(from follow: Shot, progress: Float) -> DominoCameraPose {
        let start = follow.orbit
        let end = Orbit(finale)
        var orbit = start
        orbit.target += (end.target - start.target) * Self.ease(progress)
        orbit.azimuth += remainder(end.azimuth - start.azimuth, 2 * .pi) * Self.ease(progress)
        // The crane rises over the first half, so the end does not linger on the last books.
        orbit.elevation += (end.elevation - start.elevation) * Self.ease(min(progress * 2, 1))
        orbit.distance *= pow(
            end.distance / start.distance, Self.ease(min(max(progress * 1.3 - 0.3, 0), 1)))
        let fade = 1 - Self.ease(progress)
        return compose(Shot(orbit: orbit, lean: follow.lean * fade, third: follow.third * fade))
    }

    /// The pose of `shot`: its view leaning toward the front, and turned so the orbit's target
    /// shows toward the left third of `area`, halfway up.
    private func compose(_ shot: Shot) -> DominoCameraPose {
        var pose = Self.composed(
            shot.orbit, in: area, fieldOfView: fieldOfView, aspect: aspect, weight: shot.third)
        pose.target += shot.lean
        return pose
    }

    /// The pose of `orbit`, turned so its target shows on the left third of `area`, halfway
    /// up, by `weight`. The eye stays put.
    private static func composed(
        _ orbit: Orbit, in area: Area, fieldOfView: Float, aspect: Float, weight: Float = 1
    ) -> DominoCameraPose {
        var pose = orbit.pose
        let point = SIMD2(
            area.low.x + (area.high.x - area.low.x) / 3, (area.low.y + area.high.y) / 2)
        let forward = simd_normalize(pose.target - pose.eye)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let up = simd_cross(right, forward)
        let reach = tan(fieldOfView / 2) * orbit.distance
        pose.target -= (right * point.x * aspect + up * point.y) * reach * weight
        return pose
    }

    /// How far to push in for the cobwebs near `front`: most as the front reaches a web, timed
    /// at `pace` so the camera arrives as the web tears. Only the denser webs, over gaps of
    /// about 50 days or more, draw the camera in, so a run of shorter gaps does not keep it
    /// bobbing.
    private func cobwebPush(at front: Float, pace: Float) -> Float {
        let speed = max(pace, 4)
        var push: Float = 0
        for web in cobwebs where web.density > 0.25 && abs(web.distance - front) < speed * 2 {
            let time = ((web.distance - front) / speed - 0.4) / 0.9
            guard abs(time) < 1 else { continue }
            push = max(push, (1 - time * time) * (1 - time * time) * (web.density - 0.25) / 0.75)
        }
        return push
    }

    // MARK: Path

    /// The point `distance` along the path on the table, as x and z, held at the path's ends.
    func point(at distance: Float) -> SIMD2<Float> {
        path.point(at: min(max(distance, 0), length)).position - offset
    }

    /// The path averaged around `distance` with a Gaussian of deviation `spread`: it follows
    /// the rows' progress across the table but rounds off their ends and turns.
    func trackPoint(around distance: Float, spread: Float) -> SIMD2<Float> {
        var sum = SIMD2<Float>.zero
        var total: Float = 0
        for index in -24...24 {
            let share = Float(index) / 8
            let weight = exp(-share * share / 2)
            sum += point(at: distance + share * spread) * weight
            total += weight
        }
        return sum / total
    }

    // MARK: Motion

    /// Slow, smooth wandering in bearing (x) and elevation (y), in radians, and distance (z),
    /// as a share: sums of sines whose periods share no common multiple, so it never repeats
    /// within a run.
    static func drift(at time: Float) -> SIMD3<Float> {
        func wave(_ period: Float, _ phase: Float) -> Float { sin(2 * .pi * time / period + phase) }
        return [
            0.07 * wave(17, 0.6) + 0.03 * wave(7.9, 2.1),
            0.07 * wave(13, 1.3) + 0.02 * wave(6.1, 0.2),
            0.05 * wave(11, 2.6),
        ]
    }

    /// Moves `position` toward `goal`, which moves at `drift`, with a critically damped spring
    /// of `stiffness`, within `maximumAcceleration` and `maximumSpeed`.
    static func spring(
        _ position: inout SIMD3<Float>, _ velocity: inout SIMD3<Float>, toward goal: SIMD3<Float>,
        moving drift: SIMD3<Float>, stiffness: Float, by step: Float
    ) {
        let pull = stiffness * stiffness * (goal - position) + 2 * stiffness * (drift - velocity)
        velocity = clamped(
            velocity + clamped(pull, to: maximumAcceleration) * step, to: maximumSpeed)
        position += velocity * step
    }

    /// Keeps the view from turning faster than `maximumTurnRate` since `before`, by moving the
    /// point it looks at back toward the earlier direction.
    private mutating func limitTurn(from before: DominoCameraPose, by step: Float) {
        let old = simd_normalize(before.target - before.eye)
        let offset = pose.target - pose.eye
        let reach = simd_length(offset)
        let new = offset / reach
        let axis = simd_cross(old, new)
        let angle = atan2(simd_length(axis), simd_dot(old, new))
        let limit = Self.maximumTurnRate * step
        guard angle > limit, simd_length(axis) > 1e-7 else { return }
        let turned = simd_quatf(angle: limit, axis: simd_normalize(axis)).act(old)
        let target = pose.eye + turned * reach
        targetVelocity -= (pose.target - target) / step
        pose.target = target
    }

    static func clamped(_ vector: SIMD3<Float>, to limit: Float) -> SIMD3<Float> {
        let length = simd_length(vector)
        return length > limit ? vector * (limit / length) : vector
    }

    /// Smoothstep: eases in and out of 0 to 1.
    static func ease(_ progress: Float) -> Float { progress * progress * (3 - 2 * progress) }

    /// The least distance from the eye to the middle of a row that fits the row and its turns,
    /// standing books' tops included, in `area`, at the bearing farthest from along the rows
    /// that the arc and drift reach, where the row spans the view the widest.
    private static func fit(
        path: DominoPath, tallest: Float, fieldOfView: Float, aspect: Float, area: Area
    ) -> Float {
        let reach = path.rowLength / 2 + path.radius
        let points: [SIMD3<Float>] = [-reach, reach]
            .flatMap { x in
                [0, tallest].map { y in SIMD3(x, y, 0) }
            }
        var near: Float = 4
        var far: Float = 300
        for _ in 0..<32 {
            let middle = (near + far) / 2
            let pose = composed(
                Orbit(
                    target: [0, tallest * 0.4, 0], azimuth: bearing + arc / 2 + 0.1 + .pi,
                    elevation: elevation, distance: middle),
                in: area, fieldOfView: fieldOfView, aspect: aspect)
            let fits = points.allSatisfy { point in
                let shown = pose.project(point, fieldOfView: fieldOfView, aspect: aspect)
                return shown.y > area.low.y && shown.y < area.high.y
                    && shown.x > area.low.x && shown.x < area.high.x
            }
            if fits { far = middle } else { near = middle }
        }
        return far
    }
}

extension DominoCameraRig {
    /// A shot the rig aims for: an orbit about the track, and how far the view leans from the
    /// orbit's target toward the front.
    fileprivate struct Shot {
        var orbit: Orbit
        var lean: SIMD3<Float>
        /// How far toward the left third the orbit's target shows, from 0 for the middle to 1.
        var third: Float

        func mixed(with other: Shot, _ fraction: Float) -> Shot {
            Shot(
                orbit: orbit.mixed(with: other.orbit, fraction),
                lean: lean + (other.lean - lean) * fraction,
                third: third + (other.third - third) * fraction)
        }
    }

    /// A camera pose as seen from its target: the eye's bearing on the table, in radians from +x
    /// toward +z, its elevation, and its distance.
    fileprivate struct Orbit {
        var target: SIMD3<Float>
        var azimuth: Float
        var elevation: Float
        var distance: Float

        init(target: SIMD3<Float>, azimuth: Float, elevation: Float, distance: Float) {
            self.target = target
            self.azimuth = azimuth
            self.elevation = elevation
            self.distance = distance
        }

        init(_ pose: DominoCameraPose) {
            let offset = pose.eye - pose.target
            target = pose.target
            distance = simd_length(offset)
            elevation = asin(offset.y / max(distance, 1e-6))
            azimuth = atan2(offset.z, offset.x)
        }

        var pose: DominoCameraPose {
            DominoCameraPose(
                eye: target
                    + distance
                    * SIMD3(
                        cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth)
                    ),
                target: target)
        }

        /// This orbit moved `fraction` of the way to `other`, the shorter way around.
        func mixed(with other: Orbit, _ fraction: Float) -> Orbit {
            Orbit(
                target: target + (other.target - target) * fraction,
                azimuth: azimuth + remainder(other.azimuth - azimuth, 2 * .pi) * fraction,
                elevation: elevation + (other.elevation - elevation) * fraction,
                distance: distance * pow(other.distance / distance, fraction))
        }
    }
}
