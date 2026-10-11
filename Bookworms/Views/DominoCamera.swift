import Foundation
import simd

/// The cameras that **Camera** in **Sort and filter** offers for the dominoes.
enum DominoCameraMode: String, CaseIterable, Identifiable {
    /// Frames the whole path, eases across the rows after the falling books, and eases back
    /// once all have fallen.
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
/// The chain runs too fast to swing around each half turn: a front at 12 to 20 units a second
/// takes a turn in under half a second. So the camera films from beside the rows' near ends,
/// looking along them, and the rows recede up the tall view while the front sweeps along each
/// one. When every row fits the view from not much farther than one row needs, the camera holds
/// the whole chain in a three-quarter view. Otherwise it trucks across the rows on a track, the
/// path averaged over about a row and its turn around the front, so it moves steadily from row
/// to row instead of turning with each one. It stands back far enough that the truck crosses
/// the view slowly (`truckSweep`), and so pulls back as the chain gathers speed. The front's row
/// sits left of center, with the standing rows to its right.
///
/// The run has beats: a low, close opening on the first rows, a swing toward the standing rows
/// in the middle of a long run, and a push in over the last rows.
/// The angle drifts slowly in height, bearing, and distance, as a drone's would. The camera
/// pushes in and lowers its angle as the front nears a few of the densest cobwebs, at most one
/// every five seconds or so, so their tear shows, and pushes in when the chain slows or stops.
/// Before the push, it holds `finale`, then cranes down and swings round to the first book.
/// Once every book has fallen, it cranes up, swings round, and pulls back to `finale` again, so
/// a clip of the run opens and ends on the same frame.
///
/// The rig is a deterministic value type: the same path, fronts, and time steps give the same
/// poses, so tests and an offscreen renderer can drive it as `DominoScene` does. Each `step`:
///
/// 1. Smooths the front with a critically damped spring that never runs backward, so the
///    camera follows a continuous wave instead of the books one at a time.
/// 2. Sets a goal: the establishing move, the run, or the reveal.
/// 3. Moves the eye and the point it looks at toward the goal with separate critically damped
///    springs. They are soft while the chain runs, to smooth the front, and stiff for the
///    scripted moves, whose goals ease in and out on their own, so the camera neither lags
///    them nor overshoots. Limits on speed and acceleration, and, while the chain runs, on how
///    fast the view sweeps across the table catch anything the goals do not, and the eye
///    stays above the tallest book.
/// 4. Turns the view toward the springs' within `maximumTurnRate`. The view turns on its own,
///    so a limited turn never drags the point the camera looks at off its course.
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
    /// The eye's and target's springs while the chain runs, in radians per second: soft, to
    /// smooth the front's unevenness.
    static let eyeStiffness: Float = 1.6
    static let targetStiffness: Float = 2.4
    /// Both springs for the establishing move and the reveal, whose goals ease in and out on
    /// their own: stiff, so the camera tracks them closely.
    static let scriptedStiffness: Float = 6
    /// The cobweb push in's spring, and the slow chain's as it pushes in and as it lets go,
    /// faster, so the view leaves the book a push tips as soon as the chain runs.
    static let webStiffness: Float = 2.6
    static let slowStiffness: (closer: Float, farther: Float) = (1.6, 3.5)
    /// The spring of the pace the camera's distance plans for: slow, so the camera pulls back
    /// as the chain gathers speed without breathing with each book.
    static let speedStiffness: Float = 1
    /// The fastest the eye and the point it looks at move, in units per second, and the
    /// hardest they speed up or slow down, in units per second squared, each for every
    /// `limitReach` units or less from the eye to the target: a far camera's view changes less
    /// for the same move, so it may move faster.
    static let maximumSpeed: Float = 30
    static let maximumAcceleration: Float = 26
    static let limitReach: Float = 40
    /// The fastest the view turns, in radians per second. The moves keep within it on their
    /// own; it catches only the unplanned, such as a return from far away after a pinch.
    static let maximumTurnRate: Float = 0.3
    /// While the chain runs, the fastest the point the camera looks at crosses the view, in
    /// view widths per second, and the most that speed changes in a second. A faster pan
    /// judders at 30 frames a second.
    static let maximumSweep: Float = 0.24
    static let maximumSweepAcceleration: Float = 0.4
    /// The sweep the camera stands back for as it trucks across the rows, in view widths per
    /// second: less than `maximumSweep`, so the limit rarely acts.
    static let truckSweep: Float = 0.18
    /// The step the springs integrate by, at most.
    static let substep: Float = 1.0 / 240
    /// The camera's bearing from the rows: 0 looks along +x, and larger bearings look more
    /// toward the standing rows ahead.
    static let bearing: Float = 8 * .pi / 180
    /// How far the bearing swings toward the standing rows in the middle of a long run.
    static let swing: Float = 12 * .pi / 180
    static let elevation: Float = 30 * .pi / 180
    /// The elevation at the first book: low, since no row stands before the first one.
    static let openingElevation: Float = 22 * .pi / 180
    /// The pace under which the camera pushes in on the front, in units per second.
    static let cruise: Float = 9
    /// The chain's typical pace in the scene, in units per second, which times the moves
    /// before the chain has a pace of its own.
    static let typicalPace: Float = 12
    /// The fastest the establishing move and the reveal turn the view, in radians per second.
    /// A move that would turn faster takes longer instead.
    static let scriptedTurnRate: Float = 13 * .pi / 180
    /// The least distance from the eye to the front's row, in heights of the tallest book.
    static let nearest: Float = 9
    /// How far the eye stays above the tallest book.
    static let clearance: Float = 1.2
    /// The finale's bearing and pitch: a high view of the whole path from the side the camera
    /// films from, a little farther round than the run's bearing, which `DominoScene` frames.
    /// The establishing move and the reveal then mostly crane down and up, with little swing.
    static let finaleBearing: Float = 18 * .pi / 180
    static let finalePitch: Float = 50 * .pi / 180
    /// The finale's yaw as `PileCamera` measures it, from looking along -z.
    static var finaleYaw: Float { -(.pi / 2 + finaleBearing) }
    /// Where the front's row shows in `area`, as shares of its width and height.
    static let composition: SIMD2<Float> = [0.42, 0.58]
    /// The least density of a cobweb the camera pushes in on, over a gap of about 85 days, and
    /// the least distance between two such webs, about five seconds of the chain's run.
    static let heroDensity: Float = 0.5
    static let heroSpacing: Float = 5 * typicalPace

    // MARK: Geometry

    let path: DominoPath
    /// The path's offset from the table: a path point less this is where it lies on the table.
    let offset: SIMD2<Float>
    /// The path's length, up to the last book.
    let length: Float
    let tallest: Float
    /// The cobwebs the camera pushes in on, in path order.
    let cobwebs: [Cobweb]
    /// The composed view the establishing move starts from and the reveal ends in.
    let finale: DominoCameraPose
    let fieldOfView: Float
    let aspect: Float
    let area: Area
    /// Whether the camera holds the whole chain in view rather than trucking across its rows.
    let holdsChain: Bool
    /// How long the establishing move and the reveal take, in seconds: longer for a longer
    /// chain, and long enough to keep within `scriptedTurnRate`.
    let establishTime: Float
    let revealTime: Float
    /// The chain's middle on the table, which a held view frames.
    private let middle: SIMD2<Float>
    /// Points about the orbit's target that a view of the front's row, or of the whole chain,
    /// fits: the books standing and fallen, with those past the turns and on the row before.
    private let rowPoints: [SIMD3<Float>]
    private let chainPoints: [SIMD3<Float>]

    // MARK: State

    /// The camera's pose after the last step: the eye, looking along `view`.
    private(set) var pose: DominoCameraPose
    /// The springs' eye and the point they look at, and how fast those move.
    private var eye: SIMD3<Float>
    private var target: SIMD3<Float>
    private var eyeVelocity = SIMD3<Float>.zero
    private var targetVelocity = SIMD3<Float>.zero
    /// The direction the camera looks, a unit vector.
    private var view: SIMD3<Float>
    private var previousGoal: DominoCameraPose?
    /// The smoothed front and its speed.
    private(set) var front: Float = 0
    private(set) var pace: Float = 0
    /// How far the camera pushes in for cobwebs (x) and for a slow chain (y), each from 0 to
    /// 1 and smoothed, and how fast they change.
    private var push = SIMD2<Float>.zero
    private var pushSpeed = SIMD2<Float>.zero
    /// Whether the chain has reached `cruise` since the push. Before then, the chain is
    /// starting rather than slowing, so the camera does not push in on it.
    private var cruised = false
    /// The pace smoothed slowly, for the camera's distance, and how fast it changes. From the
    /// push on, it rises toward the typical pace or the chain's, whichever is faster, and never
    /// falls, so the camera does not dive in as the chain ends; the slow chain's push in takes
    /// the camera closer when the chain slows.
    private var speed: Float = 0
    private var speedChange: Float = 0
    /// Seconds since the rig started, of the establishing move, and since every book fell.
    private var clock: Float = 0
    private var established: Float = 0
    private var doneTime: Float = 0

    init(
        path: DominoPath, offset: SIMD2<Float>, length: Float, tallest: Float, cobwebs: [Cobweb],
        finale: DominoCameraPose, fieldOfView: Float, aspect: Float, area: Area
    ) {
        self.path = path
        self.offset = offset
        self.length = max(0, length)
        self.tallest = tallest
        self.finale = finale
        self.fieldOfView = fieldOfView
        self.aspect = aspect
        self.area = area
        var heroes: [Cobweb] = []
        for web in cobwebs.filter({ $0.density >= Self.heroDensity })
            .sorted(by: { ($0.density, -$0.distance) > ($1.density, -$1.distance) })
        where heroes.allSatisfy({ abs($0.distance - web.distance) >= Self.heroSpacing }) {
            heroes.append(web)
        }
        self.cobwebs = heroes.sorted { $0.distance < $1.distance }
        let rows = (self.length / path.period).rounded(.down) + 1
        let across = (rows - 1) * 2 * path.radius
        middle = SIMD2(0, across / 2) - offset
        // Books land up to their height past the turns, and the row before lies fallen.
        let reach = path.rowLength / 2 + path.radius + tallest
        let tops = path.rowLength / 2 + path.radius
        rowPoints = [
            [-reach, 0, 0], [reach, 0, 0], [-reach, 0, -2 * path.radius],
            [reach, 0, -2 * path.radius], [-tops, tallest, 0], [tops, tallest, 0],
        ]
        chainPoints = [-reach, reach]
            .flatMap { x in
                [-across / 2 - tallest / 2, across / 2 + tallest / 2]
                    .flatMap { z in [0, tallest].map { SIMD3(x, $0, z) } }
            }
        pose = finale
        eye = finale.eye
        target = finale.target
        view = simd_normalize(finale.target - finale.eye)
        // Hold a short chain when standing back to fit it all is not much farther than one row
        // needs, or than a truck across its rows would stand back at a typical pace.
        let base = Self.bearing + .pi
        let row = max(
            Self.fit(
                rowPoints, height: tallest * 0.4, azimuth: base, elevation: Self.elevation,
                weight: 1, fieldOfView: fieldOfView, aspect: aspect, area: area),
            Self.nearest * tallest)
        let truck = Self.truckDistance(
            pace: Self.typicalPace, path: path, fieldOfView: fieldOfView, aspect: aspect)
        holdsChain =
            Self.fit(
                chainPoints, height: tallest * 0.4, azimuth: base, elevation: Self.elevation,
                weight: 0, fieldOfView: fieldOfView, aspect: aspect, area: area)
            <= max(1.5 * row, 1.3 * truck)
        // Smootherstep turns at most 1.875 times its mean rate, and the establishing move and
        // the reveal turn over the first 85 and 80 percent of their time.
        let finaleOrbit = Orbit(finale)
        let opening = Orbit(
            target: .zero, azimuth: base, elevation: Self.openingElevation, distance: 1)
        let closing = Orbit(target: .zero, azimuth: base, elevation: Self.elevation, distance: 1)
        let run = self.length / Self.typicalPace
        establishTime = min(
            max(
                0.25 * run, 1.875 / 0.85 * opening.turn(to: finaleOrbit) / Self.scriptedTurnRate, 3
            ), 5)
        revealTime = min(
            max(
                0.3 * run + 3, 1.875 / 0.8 * closing.turn(to: finaleOrbit) / Self.scriptedTurnRate,
                5.5), 7)
    }

    /// Continues from `pose` at rest, such as after a pinch or drag moved the camera, past the
    /// establishing move.
    mutating func reset(to pose: DominoCameraPose) {
        self.pose = pose
        eye = pose.eye
        target = pose.target
        view = simd_normalize(pose.target - pose.eye)
        eyeVelocity = .zero
        targetVelocity = .zero
        previousGoal = nil
        established = max(established, establishTime + 1)
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
        established += deltaTime
        doneTime = input.done ? doneTime + deltaTime : 0
        let running = input.started && !input.done
        // A chain that slows at its last book has ended rather than stalled.
        let ending = min(max(length - estimate, 0) / 2, 1)
        cruised = cruised || (input.started && pace >= Self.cruise)
        let pushGoal = SIMD2(
            running ? cobwebPush(at: estimate, pace: pace) : 0,
            cruised ? (1 - Self.ease(min(pace / Self.cruise, 1))) * ending : 0)
        let slowStiffness =
            pushGoal.y < push.y ? Self.slowStiffness.farther : Self.slowStiffness.closer
        for _ in 0..<steps {
            Self.spring(
                &push.x, &pushSpeed.x, toward: pushGoal.x, stiffness: Self.webStiffness, by: step)
            Self.spring(
                &push.y, &pushSpeed.y, toward: pushGoal.y, stiffness: slowStiffness, by: step)
            Self.spring(
                &speed, &speedChange, toward: running ? max(pace, speed, Self.typicalPace) : speed,
                stiffness: Self.speedStiffness, by: step)
        }
        let goal = self.goal()
        let start = previousGoal ?? goal
        previousGoal = goal
        // The goal's own velocity, so the springs track a steadily moving goal without lag. It
        // fades out over the reveal's last 20 percent, so the camera settles onto `finale` from
        // behind rather than overshooting it and creeping back.
        let fade = 1 - Self.ease(Self.unit((doneTime / revealTime - 0.8) / 0.2))
        let limit = Self.maximumSpeed * Self.limitScale(pose)
        let eyeDrift = Self.clamped((goal.eye - start.eye) / deltaTime, to: limit) * fade
        let targetDrift = Self.clamped((goal.target - start.target) / deltaTime, to: limit) * fade
        let scripted = self.scripted
        let eyeStiffness =
            Self.eyeStiffness + (Self.scriptedStiffness - Self.eyeStiffness) * scripted
        let targetStiffness =
            Self.targetStiffness + (Self.scriptedStiffness - Self.targetStiffness) * scripted
        for index in 1...steps {
            let share = Float(index) / Float(steps)
            let scale = Self.limitScale(pose)
            Self.spring(
                &eye, &eyeVelocity, toward: start.eye + (goal.eye - start.eye) * share,
                moving: eyeDrift, stiffness: eyeStiffness, scale: scale, by: step)
            let aim = start.target + (goal.target - start.target) * share
            let pull =
                targetStiffness * targetStiffness * (aim - target) + 2 * targetStiffness
                * (targetDrift - targetVelocity)
            var velocity = Self.clamped(
                targetVelocity + Self.clamped(pull, to: Self.maximumAcceleration * scale) * step,
                to: Self.maximumSpeed * scale)
            if running { velocity = limitSweep(velocity, by: step) }
            targetVelocity = velocity
            target += velocity * step
            let floor = tallest + Self.clearance
            if eye.y < floor {
                eye.y = floor
                eyeVelocity.y = max(0, eyeVelocity.y)
            }
            turn(by: step)
            pose = DominoCameraPose(
                eye: eye, target: eye + view * max(simd_distance(eye, target), 1))
        }
        // Once the reveal has ended, the camera rests on `finale` exactly.
        if doneTime >= revealTime, simd_distance(pose.eye, finale.eye) < 0.005,
            simd_distance(pose.target, finale.target) < 0.005
        {
            reset(to: finale)
        }
        return pose
    }

    // MARK: Goals

    /// The front the camera frames: the smoothed front plus its lag at its pace, so it leads
    /// neither the books nor the springs.
    var estimate: Float { min(front + 2 * pace / Self.frontStiffness, length) }

    /// How much the scripted moves drive the springs, from 0 to 1: fully through the
    /// establishing move, easing off over the second after it, and easing in over the reveal's
    /// first second.
    private var scripted: Float {
        if doneTime > 0 { return Self.ease(min(doneTime, 1)) }
        return 1 - Self.ease(Self.unit(established - establishTime))
    }

    private func goal() -> DominoCameraPose {
        if doneTime >= revealTime { return finale }
        let follow = following(at: estimate, pace: pace)
        if doneTime > 0 { return reveal(from: follow, progress: doneTime / revealTime) }
        guard established < establishTime else { return compose(follow) }
        return establishing(to: follow, progress: established / establishTime)
    }

    /// Where the camera films a front at `front` moving at `pace`.
    private func following(at front: Float, pace: Float) -> Shot {
        let wander = Self.drift(at: clock)
        let progress = length > 0 ? front / length : 0
        // The beats, each from 0 to 1, are as strong as the run is long, up to a run of 15
        // seconds, so a short run, whose beats would crowd together, is held nearly steady. The
        // opening and last rows each last about three seconds or more. The swing lasts a share
        // of the run, so its strength falls faster, keeping its turn as gentle as a long run's.
        let strength = min(1, length / Self.typicalPace / 15)
        let span = max(path.period, 3 * Self.typicalPace)
        let opening = strength * (1 - Self.ease(min(front / span, 1)))
        let swing =
            strength * strength
            * (Self.ease(Self.unit((progress - 0.35) / 0.25))
                - Self.ease(Self.unit((progress - 0.6) / 0.25)))
        let last = max(1.5 * path.period, span)
        let ending = strength * Self.ease(Self.unit((front - length + last) / last))
        let bearing = Self.bearing + Self.swing * swing + wander.x
        // Lower as the camera pushes in on a cobweb, so the web shows against the table.
        let elevation =
            Self.elevation - (Self.elevation - Self.openingElevation) * opening
            - 5 * .pi / 180 * push.x + wander.y
        let track: SIMD2<Float>
        let third: Float
        var distance: Float
        if holdsChain {
            track = middle
            third = 0
            distance = fit(chainPoints, azimuth: bearing + .pi, elevation: elevation, weight: 0)
        } else {
            // Across the rows, the path averaged over a row and its turns barely lags the
            // front's row; along them, over two rows, it all but stands still.
            let behind = front - 0.2 * path.period
            track = SIMD2(
                trackPoint(around: behind, spread: path.period).x,
                trackPoint(around: behind, spread: 0.45 * path.period).y)
            // Off center while rows stand ahead, and centered by the last row, which has none.
            third = Self.ease(min(max(length - front, 0) / max(2 * path.period, 3 * pace), 1))
            distance = max(
                fit(rowPoints, azimuth: bearing + .pi, elevation: elevation, weight: third),
                Self.truckDistance(
                    pace: speed, path: path, fieldOfView: fieldOfView, aspect: aspect))
        }
        // A held view does not push in for the beats, which would crop the chain's ends.
        let beats = holdsChain ? 1 : (1 - 0.3 * opening) * (1 - 0.15 * ending)
        distance =
            max(distance, Self.nearest * tallest) * (1 + wander.z) * beats * (1 - 0.3 * push.x)
            * (1 - 0.15 * push.y)
        let orbit = Orbit(
            target: [track.x, tallest * 0.4, track.y], azimuth: bearing + .pi,
            elevation: elevation, distance: distance)
        // As the chain slows, the view leans toward the front, onto the book to push when it
        // stops. As the front nears a cobweb, it leans toward the front's row, averaged along it
        // so the view does not chase the front along the row.
        let lean =
            (trackPoint(around: front, spread: 0.25 * path.period) - track) * 0.5 * push.y
            + (trackPoint(around: front, spread: path.period) - track) * 0.6 * push.x
        return Shot(orbit: orbit, lean: [lean.x, 0, lean.y], third: third)
    }

    /// The move from `finale` down to the first book, `progress` of the way: the camera cranes
    /// down and turns toward the first row a little ahead of its push in, so the first row is in
    /// place before the camera comes close.
    private func establishing(to follow: Shot, progress: Float) -> DominoCameraPose {
        let orbit = Orbit(finale)
            .blended(
                to: follow.orbit, target: Self.ease(min(progress / 0.7, 1)),
                angles: Self.ease(min(progress / 0.85, 1)),
                distance: Self.ease(Self.unit((progress - 0.15) / 0.85)))
        let share = Self.ease(progress)
        return compose(Shot(orbit: orbit, lean: follow.lean * share, third: follow.third * share))
    }

    /// The crane up and pull back from `follow` to `finale`, `progress` of the way: the camera
    /// rises and swings round first, and pulls back to the path's middle last, so it lingers
    /// over the fallen books before the whole path unrolls below it.
    private func reveal(from follow: Shot, progress: Float) -> DominoCameraPose {
        let pullBack = Self.ease(Self.unit(progress * 1.5 - 0.5))
        let orbit = follow.orbit.blended(
            to: Orbit(finale), target: pullBack, angles: Self.ease(min(progress / 0.8, 1)),
            distance: pullBack)
        let fade = 1 - Self.ease(progress)
        return compose(Shot(orbit: orbit, lean: follow.lean * fade, third: follow.third * fade))
    }

    /// The pose of `shot`: its view turned so the orbit's target shows at `composition`, and
    /// leaning toward the front.
    private func compose(_ shot: Shot) -> DominoCameraPose {
        var pose = Self.composed(
            shot.orbit, in: area, fieldOfView: fieldOfView, aspect: aspect, weight: shot.third)
        pose.target += shot.lean
        return pose
    }

    /// The pose of `orbit`, turned so its target shows at `composition` in `area` by `weight`,
    /// from the view's middle at 0. The eye stays put.
    private static func composed(
        _ orbit: Orbit, in area: Area, fieldOfView: Float, aspect: Float, weight: Float
    ) -> DominoCameraPose {
        var pose = orbit.pose
        let point = area.low + (area.high - area.low) * composition
        let forward = simd_normalize(pose.target - pose.eye)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let up = simd_cross(right, forward)
        let reach = tan(fieldOfView / 2) * orbit.distance
        pose.target -= (right * point.x * aspect + up * point.y) * reach * weight
        return pose
    }

    /// How far to push in for the cobwebs near `front`, over about four seconds: most a little
    /// before the front reaches a web, timed at `pace` so the camera, which lags its goal, is
    /// closest as the web tears.
    private func cobwebPush(at front: Float, pace: Float) -> Float {
        let speed = max(pace, 4)
        var push: Float = 0
        for web in cobwebs {
            let time = ((web.distance - front) / speed - 0.9) / 2
            guard abs(time) < 1 else { continue }
            push = max(push, (1 - time * time) * (1 - time * time))
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

    /// The distance at which a camera trucking across the rows of `path`, as a front at `pace`
    /// crosses them, sweeps the view at `truckSweep`.
    private static func truckDistance(
        pace: Float, path: DominoPath, fieldOfView: Float, aspect: Float
    ) -> Float {
        pace * 2 * path.radius / path.period / (truckSweep * 2 * tan(fieldOfView / 2) * aspect)
    }

    /// The least distance from the eye to an orbit's target that fits `points`, about the
    /// target, in `area`, from `azimuth` and `elevation`.
    private func fit(
        _ points: [SIMD3<Float>], azimuth: Float, elevation: Float, weight: Float
    ) -> Float {
        Self.fit(
            points, height: tallest * 0.4, azimuth: azimuth, elevation: elevation, weight: weight,
            fieldOfView: fieldOfView, aspect: aspect, area: area)
    }

    /// The least distance from the eye to an orbit's target, `height` above the table, that
    /// fits `points`, about the target's place on the table, in `area`, composed by `weight`.
    private static func fit(
        _ points: [SIMD3<Float>], height: Float, azimuth: Float, elevation: Float, weight: Float,
        fieldOfView: Float, aspect: Float, area: Area
    ) -> Float {
        var near: Float = 4
        var far: Float = 500
        for _ in 0..<24 {
            let middle = (near + far) / 2
            let pose = composed(
                Orbit(
                    target: [0, height, 0], azimuth: azimuth, elevation: elevation,
                    distance: middle),
                in: area, fieldOfView: fieldOfView, aspect: aspect, weight: weight)
            let forward = pose.target - pose.eye
            let fits = points.allSatisfy { point in
                let shown = pose.project(point, fieldOfView: fieldOfView, aspect: aspect)
                return simd_dot(point - pose.eye, forward) > 0 && shown.y > area.low.y
                    && shown.y < area.high.y && shown.x > area.low.x && shown.x < area.high.x
            }
            if fits { far = middle } else { near = middle }
        }
        return far
    }

    // MARK: Motion

    /// Slow, smooth wandering in bearing (x) and elevation (y), in radians, and distance (z),
    /// as a share: sums of sines whose periods share no common multiple, so it never repeats
    /// within a run.
    static func drift(at time: Float) -> SIMD3<Float> {
        func wave(_ period: Float, _ phase: Float) -> Float { sin(2 * .pi * time / period + phase) }
        return [
            0.06 * wave(9.5, 0.6) + 0.025 * wave(5.3, 2.1),
            0.05 * wave(13, 1.3) + 0.015 * wave(6.1, 0.2),
            0.05 * wave(11, 2.6),
        ]
    }

    /// How many times `maximumSpeed` and `maximumAcceleration` a camera at `pose` may move.
    static func limitScale(_ pose: DominoCameraPose) -> Float {
        max(1, simd_distance(pose.eye, pose.target) / limitReach)
    }

    /// Moves `position` toward `goal`, which moves at `drift`, with a critically damped spring
    /// of `stiffness`, within `scale` times `maximumAcceleration` and `maximumSpeed`.
    static func spring(
        _ position: inout SIMD3<Float>, _ velocity: inout SIMD3<Float>, toward goal: SIMD3<Float>,
        moving drift: SIMD3<Float>, stiffness: Float, scale: Float, by step: Float
    ) {
        let pull = stiffness * stiffness * (goal - position) + 2 * stiffness * (drift - velocity)
        velocity = clamped(
            velocity + clamped(pull, to: maximumAcceleration * scale) * step,
            to: maximumSpeed * scale)
        position += velocity * step
    }

    /// Moves `value` toward a still `goal` with a critically damped spring of `stiffness`.
    private static func spring(
        _ value: inout Float, _ velocity: inout Float, toward goal: Float, stiffness: Float,
        by step: Float
    ) {
        velocity += (stiffness * stiffness * (goal - value) - 2 * stiffness * velocity) * step
        value += velocity * step
    }

    /// `velocity` for the point the camera looks at, with its speed across the view, the
    /// table's horizontal at the target, within `maximumSweep` and changing within
    /// `maximumSweepAcceleration` of its last.
    private func limitSweep(_ velocity: SIMD3<Float>, by step: Float) -> SIMD3<Float> {
        let across = simd_normalize(simd_cross(view, [0, 1, 0]))
        let width = 2 * tan(fieldOfView / 2) * aspect * simd_distance(eye, target)
        let was = simd_dot(targetVelocity, across)
        let change = Self.maximumSweepAcceleration * width * step
        let limit = Self.maximumSweep * width
        let sweep = simd_dot(velocity, across)
        let kept = min(max(min(max(sweep, was - change), was + change), -limit), limit)
        return velocity + across * (kept - sweep)
    }

    /// Turns `view` toward the springs' view for `step` seconds, within `maximumTurnRate`. It
    /// holds while the springs' eye and target nearly meet, where their view is unsteady.
    private mutating func turn(by step: Float) {
        let offset = target - eye
        guard simd_length(offset) > 0.5 else { return }
        let wanted = simd_normalize(offset)
        let limit = Self.maximumTurnRate * step
        var axis = simd_cross(view, wanted)
        guard atan2(simd_length(axis), simd_dot(view, wanted)) > limit else {
            view = wanted
            return
        }
        // About the axis between the two views, or, for opposite views, about the vertical.
        if simd_length(axis) < 1e-6 { axis = simd_cross(view, [0, 1, 0]) }
        guard simd_length(axis) > 1e-6 else { return }
        view = simd_normalize(simd_quatf(angle: limit, axis: simd_normalize(axis)).act(view))
    }

    static func clamped(_ vector: SIMD3<Float>, to limit: Float) -> SIMD3<Float> {
        let length = simd_length(vector)
        return length > limit ? vector * (limit / length) : vector
    }

    /// Smootherstep: eases in and out of 0 to 1 with no jolt at either end, since its speed and
    /// acceleration both start and end at 0.
    static func ease(_ progress: Float) -> Float {
        progress * progress * progress * (progress * (progress * 6 - 15) + 10)
    }

    /// `value` held between 0 and 1.
    private static func unit(_ value: Float) -> Float { min(max(value, 0), 1) }
}

extension DominoCameraRig {
    /// A shot the rig aims for: an orbit about the track, and how far the view leans from the
    /// orbit's target toward the front.
    fileprivate struct Shot {
        var orbit: Orbit
        var lean: SIMD3<Float>
        /// How far toward `composition` the orbit's target shows, from 0 for the middle to 1.
        var third: Float
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

        /// The unit direction from the eye to the target.
        var direction: SIMD3<Float> {
            -SIMD3(cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth))
        }

        var pose: DominoCameraPose {
            DominoCameraPose(eye: target - distance * direction, target: target)
        }

        /// The angle between this orbit's view and `other`'s, in radians.
        func turn(to other: Orbit) -> Float {
            acos(min(max(simd_dot(direction, other.direction), -1), 1))
        }

        /// This orbit moved toward `other`: its target by `target`, its azimuth, the shorter way
        /// around, and its elevation by `angles`, and its distance by `distance`, evenly in
        /// proportion.
        func blended(to other: Orbit, target: Float, angles: Float, distance: Float) -> Orbit {
            Orbit(
                target: self.target + (other.target - self.target) * target,
                azimuth: azimuth + remainder(other.azimuth - azimuth, 2 * .pi) * angles,
                elevation: elevation + (other.elevation - elevation) * angles,
                distance: self.distance * pow(other.distance / self.distance, distance))
        }
    }
}

/// The overview camera's motion toward a goal that moves: a critically damped spring for each
/// lane, toward a goal that trails the true one at its lane's lag rate, so the camera starts
/// gently when the goal jumps, as it does at a push. The lanes are the camera's target across
/// the table in x and z, its zoom's logarithm, so it zooms at an even pace, its yaw, and its
/// pitch. It integrates in short steps, so it stays stable however long a frame lasts, and
/// snaps once it is within a ten-thousandth of its goal and nearly still, so it stops moving
/// without a visible jump.
struct DominoOverviewSpring: Equatable {
    /// The springs' stiffness, in radians per second. Zoom and the angles move slowly, so
    /// zooming in from the whole path takes a couple of seconds.
    static let stiffness: SIMD8<Float> = [5, 5, 1, 1.5, 1.5, 0, 0, 0]
    /// The rates at which the goal trails the true one while the camera follows the front,
    /// and once every book has fallen, when the target eases back as gently as the zoom.
    static let followingLag: SIMD8<Float> = [15, 15, 1.2, 1.5, 1.5, 0, 0, 0]
    static let settlingLag: SIMD8<Float> = [2.5, 2.5, 1.2, 1.5, 1.5, 0, 0, 0]
    static let substep: Float = 1.0 / 120

    private(set) var value: SIMD8<Float>
    private(set) var velocity = SIMD8<Float>.zero
    private var goal: SIMD8<Float>

    init(_ value: SIMD8<Float>) {
        self.value = value
        goal = value
    }

    /// Advances `deltaTime` seconds toward `aim`, its goal trailing at `lag`.
    mutating func step(toward aim: SIMD8<Float>, lag: SIMD8<Float>, by deltaTime: Float) {
        guard deltaTime > 0 else { return }
        let steps = max(1, Int((deltaTime / Self.substep).rounded(.up)))
        let step = deltaTime / Float(steps)
        var share = SIMD8<Float>.zero
        for lane in 0..<8 { share[lane] = 1 - exp(-lag[lane] * step) }
        let stiffness = Self.stiffness
        for _ in 0..<steps {
            goal += (aim - goal) * share
            velocity += (stiffness * stiffness * (goal - value) - 2 * stiffness * velocity) * step
            value += velocity * step
        }
        if simd_length(aim - value) < 1e-4, simd_length(velocity) < 1e-4 {
            value = aim
            goal = aim
            velocity = .zero
        }
    }
}
