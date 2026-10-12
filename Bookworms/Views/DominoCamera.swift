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

/// A camera's place, the point it looks at, and its roll about the view, in radians, with
/// positive rolls turning the view counterclockwise. At a roll of 0, the camera's up is the
/// table's.
struct DominoCameraPose: Equatable {
    var eye: SIMD3<Float>
    var target: SIMD3<Float>
    var roll: Float = 0

    /// The rotation that turns a camera looking down -z, with +y up, toward `target`.
    var rotation: simd_quatf {
        let back = simd_normalize(eye - target)
        let right = simd_normalize(simd_cross([0, 1, 0], back))
        let level = simd_quatf(simd_float3x3(columns: (right, simd_cross(back, right), back)))
        return roll == 0 ? level : simd_quatf(angle: roll, axis: back) * level
    }

    /// Where `point` shows in normalized device coordinates, from -1 to 1 each way with y up,
    /// for a vertical `fieldOfView` and a view of width-to-height `aspect`.
    func project(_ point: SIMD3<Float>, fieldOfView: Float, aspect: Float) -> SIMD2<Float> {
        let local = rotation.inverse.act(point - eye)
        return SIMD2(local.x / aspect, local.y) / (-local.z * tan(fieldOfView / 2))
    }
}

/// The Follow camera: a camera operator who chases the chain's falling front, low, from behind
/// and beside it, with slow, eased moves.
///
/// While the chain runs, the front's book fills about a fifth of the view's height, so several
/// books either side of the front and some of the path ahead show, and the camera films from
/// about 8 to 25 degrees above the table, always from the side of the rows that have fallen, so
/// no standing book hides the front. Each row gets its own shot (`shots`): an angle, a height,
/// and a distance, with now and then a tighter one. The camera chases every row from behind and beside the front, so the books fall away from it rather
/// than toward it, and the rows' alternating directions put the camera on the front's left along
/// one row and its right along the next. Around the half turn between two rows, the camera
/// swings in an arc, craning up and banking a little. A bigger swing takes longer, and every
/// swing leaves part of each row steady. A swing starts before the front reaches the turn, so
/// the camera leads the turn rather than lagging it. Where the rows are short, as in a year's
/// chain, the camera films nearer beside the front, so each swing fits. Round some turns, it
/// films the rows either side nearly beside the front and cranes high over the turn with a
/// small swing. The camera's height, bearing, and distance also drift slowly, as a drone's
/// would. It pushes in, lowers its angle, and turns a little toward a few of the densest
/// cobwebs, at most one every six seconds or so, and films the row where one tears from as
/// near behind the front as fits, so the web comes toward the camera. It also pushes in when
/// the chain slows or stops. The pushes do not add up: the strongest sets how close the camera
/// comes.
///
/// Before the push, the camera holds `finale`, then cranes down and swings round to the first
/// book. It follows the front to the last book, eases to a stop there, and holds for
/// `landTime` while that book lands, centered on where it lands and looking down on the fallen
/// books from at least `landingElevation`. Then it cranes up, swings round, and pulls back to
/// `finale` again, so a clip of the run opens and ends on the same frame.
///
/// The rig is a deterministic value type: the same path, fronts, and time steps give the same
/// poses, so tests and an offscreen renderer can drive it as `DominoScene` does. Each `step`:
///
/// 1. Smooths the front, so the camera follows a continuous wave instead of the books one at
///    a time, and never runs back or far past a chain that stops (`estimate`), and measures
///    the chain's pace with a critically damped spring.
/// 2. Sets a goal: the establishing move, the run, or the reveal. The run's distance from the
///    eye to the front changes within `maximumZoomRate`.
/// 3. Moves the eye and the point it looks at toward the goal with critically damped springs,
///    which also follow the goal's own velocity, so they track a moving goal without lag.
///    Limits on speed and acceleration catch anything the goals do not, and the eye stays
///    above the books near it (`floor(at:front:)`).
/// 4. Turns the view toward the springs' within `maximumTurnRate`, and rolls it toward the
///    swing's bank.
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

    /// A row's shot: the eye's bearing from the front, in radians from +x toward +z and
    /// unwrapped so each swing turns the short way through -z, the side of the fallen rows;
    /// its elevation above the table; and the share of the view's height a typical book fills.
    struct Shot: Equatable {
        var azimuth: Float
        var elevation: Float
        var share: Float
    }

    /// The move from one row's shot to the next round the turn between them: where along the
    /// path it is halfway, how far along the path it reaches either side of that, and how much
    /// higher than the rows' elevations it cranes at its middle, in radians.
    struct Swing: Equatable {
        var middle: Float
        var reach: Float
        var lift: Float
    }

    // MARK: Tuning

    /// The front's spring, in radians per second, which gives the chain's pace.
    static let frontStiffness: Float = 6
    /// The rate of the three first-order lags that smooth the front the camera frames, per
    /// second (see `estimate`).
    static let estimateStiffness: Float = 7
    /// How long the raw front holds still before the chain counts as stopped, in seconds:
    /// longer than a frame, since it moves on every frame while the books fall. Then the
    /// estimate's lead fades at `leadRate` per second, and returns as fast once the front moves.
    static let stillTime: Float = 0.03
    static let leadRate: Float = 15
    /// The eye's and target's springs while the chain runs, in radians per second. They follow
    /// the goal's own velocity as well, so stiffness sets only how fast they correct an error.
    static let eyeStiffness: Float = 5
    static let targetStiffness: Float = 8
    /// Both springs for the establishing move and the reveal, whose goals ease in and out on
    /// their own: stiff, so the camera tracks them closely.
    static let scriptedStiffness: Float = 6
    /// The roll's spring, in radians per second.
    static let rollStiffness: Float = 3.5
    /// How long the springs take to stiffen again after `reset(to:)`, in seconds.
    static let returnTime: Float = 2.5
    /// The cobweb push in's spring, and the slow chain's as it pushes in and as it lets go,
    /// faster, so the view leaves the book a push tips as soon as the chain runs.
    static let webStiffness: Float = 2
    static let slowStiffness: (closer: Float, farther: Float) = (1.2, 2.5)
    /// The spring of the pace the cobweb push in is timed by: slow, so it holds steady from
    /// book to book.
    static let speedStiffness: Float = 1
    /// The fastest the eye and the point it looks at move, in units per second, and the
    /// hardest they speed up or slow down, in units per second squared, each for every
    /// `limitReach` units or less from the eye to the target: a far camera's view changes less
    /// for the same move, so it may move faster. They catch only the unplanned, such as a
    /// return from far away after a pinch: a chase round a turn stays well within them.
    static let maximumSpeed: Float = 100
    static let maximumAcceleration: Float = 320
    static let limitReach: Float = 40
    /// The fastest the view turns, in radians per second, and the steepest roll, in radians.
    static let maximumTurnRate: Float = 2
    static let maximumRoll: Float = 5 * .pi / 180
    /// How much the camera banks for each radian per second it swings round the front.
    static let bank: Float = 0.035
    /// The fastest the run's distance from the eye to the front changes, as its logarithm per
    /// second; the most that rate changes in a second; and how fast, per second, the distance
    /// closes on its goal within those limits.
    static let maximumZoomRate: Float = 0.45
    static let maximumZoomAcceleration: Float = 1.2
    static let zoomStiffness: Float = 2.5
    /// The step the springs integrate by, at most.
    static let substep: Float = 1.0 / 240
    /// The chain's typical pace in the scene's slow motion (`DominoScene.slowMotion`), in units
    /// per second, which times the swings and the moves before the chain has a pace of its own.
    static let typicalPace: Float = 9.5
    /// How long a swing round a turn takes at a typical pace, in seconds, at the least and
    /// most, and how fast it turns on average within those, in radians per second: a bigger
    /// swing takes longer. Where the rows are long enough, every swing also leaves at least
    /// `dwell` seconds of each row and turn steady, so the camera never swings from one turn
    /// straight into the next. A swing's middle comes `swingLead` seconds before the front
    /// reaches the middle of its turn.
    static let swingTimes: ClosedRange<Float> = 1.2...2.6
    static let swingRate: Float = 26 * .pi / 180
    static let dwell: Float = 0.5
    static let swingLead: Float = 0.35
    /// How far from straight behind the front the camera films a row, toward the fallen rows,
    /// in radians. It always chases the front, so the books fall away from it. Nearly behind,
    /// the standing books ahead recede up the tall view and show their covers; nearly beside,
    /// the swing to the next row is small. Where the rows are too short for a wide swing, the
    /// camera stays nearer beside the front (see `choreograph`).
    static let sides: ClosedRange<Float> = (20 * .pi / 180)...(80 * .pi / 180)
    /// How far from straight behind the front the camera films the rows either side of a turn
    /// it cranes over, in radians: nearly beside it, so the swing round that turn is small.
    static let besides: ClosedRange<Float> = (70 * .pi / 180)...(80 * .pi / 180)
    /// The share of the turns the camera cranes over with a small swing, rather than swinging
    /// round low.
    static let craneOverShare: Float = 0.2
    /// A row's elevation above the table, in radians; the least the camera comes down to as it
    /// drifts and pushes in; how much higher than either row's it cranes at the middle of a
    /// swing, for each radian it swings; and the elevation it cranes up toward over a turn it
    /// cranes over.
    static let elevations: ClosedRange<Float> = (11 * .pi / 180)...(18 * .pi / 180)
    static let lowestElevation: Float = 10 * .pi / 180
    static let crane: Float = 0.04
    static let craneOver: Float = 20 * .pi / 180
    /// The fastest the camera cranes up over a turn it cranes over, in radians per second: over
    /// a short row's turn, it rises less than `craneOver` would ask.
    static let craneRate: Float = 12 * .pi / 180
    /// The share of the view's height a typical book fills at the front, at the least and most,
    /// and in the tight shot about one row in six gets: small enough that several books either
    /// side of the front and some of the path ahead show.
    static let shares: ClosedRange<Float> = 0.175...0.21
    static let tightShare: Float = 0.23
    /// A typical book's height, as a share of the tallest, which sets how close the camera
    /// comes for a row's share.
    static let typicalHeight: Float = 0.8
    /// The pace under which the camera pushes in on the front, in units per second.
    static let cruise: Float = 7
    /// The fastest the establishing move and the reveal turn the view, in radians per second,
    /// and change its scale, as the logarithm of the distance from the eye to the point it looks
    /// at, per second. A move that would turn or zoom faster takes longer, up to its longest.
    /// The reveal moves faster, so it stays in proportion to a short run.
    static let turnRates: (establish: Float, reveal: Float) = (9 * .pi / 180, 18 * .pi / 180)
    static let zoomRates: (establish: Float, reveal: Float) = (0.28, 0.45)
    /// How long the establishing move and the reveal take, in seconds, at the least and most.
    static let establishTimes: ClosedRange<Float> = 4...9
    static let revealTimes: ClosedRange<Float> = 6...11
    /// How long the camera holds on the last book after it starts to fall, so the reveal
    /// starts only once the book has landed: it lies flat about a quarter of a second after,
    /// in the scene's slow motion.
    static let landTime: Float = 1
    /// The least distance from the eye to the front.
    static let nearest: Float = 6
    /// How far the eye stays above the tallest book while it is near a standing one, and above
    /// the table elsewhere, where only fallen books lie.
    static let clearance: Float = 1.2
    static let lowest: Float = 1.2
    /// The finale's bearing and pitch: a high view of the whole path from the side the camera
    /// films from, which `DominoScene` frames. The establishing move and the reveal then mostly
    /// crane down and up, with little swing.
    static let finaleBearing: Float = 18 * .pi / 180
    static let finalePitch: Float = 60 * .pi / 180
    /// The finale's yaw as `PileCamera` measures it, from looking along -z.
    static var finaleYaw: Float { -(.pi / 2 + finaleBearing) }
    /// Where the front shows in `area`, as shares of its width and height: below the middle, so
    /// the standing books ahead fill the view above it, but high enough that the view looks
    /// down past the table's far edge. While the last book lands, the camera raises it to
    /// `landingComposition`, and looks down from at least `landingElevation`, so the fallen
    /// books lie in the middle of the view rather than under a band of far table.
    static let composition: SIMD2<Float> = [0.5, 0.45]
    static let landingComposition: Float = 0.55
    static let landingElevation: Float = 21 * .pi / 180
    /// How widely the eye's and the front's places average the path about the front, as a
    /// Gaussian's deviation: the eye's rounds off each turn and a short row's ends.
    static let eyeSpread: Float = 4
    static let focusSpread: Float = 1.5
    /// How far behind the estimate the camera centers, in units: on the tipping book, which
    /// the front runs ahead of. Over the last `landingReach` units, it centers ahead instead,
    /// on where the last book lands, about half a typical book's height past its place.
    static let focusBack: Float = 0.3
    static let landingReach: Float = 8
    /// How much lower the camera centers while the last book lands, as a share of the middle
    /// of a typical book: near the table, where the fallen books lie.
    static let landingDrop: Float = 0.3
    /// Over how many units before the last book the estimate eases to a stop, rather than
    /// stopping against the path's end.
    static let endEase: Float = 4
    /// The least density of a cobweb the camera pushes in on, over a gap of about 85 days, and
    /// the least distance between two such webs, about six seconds of the chain's run.
    static let heroDensity: Float = 0.5
    static let heroSpacing: Float = 6 * typicalPace
    /// At the peak of a cobweb's push in, how much closer the camera comes, as a share of its
    /// distance; how much it lowers its angle, in radians; and how far the point it looks at
    /// leans from the front toward the web, in units: a little, since the narrow view shows
    /// only a few units across at the front. The lean grows smoothly with the web's distance
    /// from the front and levels off beyond about `webLean.knee` units, so it eases through 0
    /// over about half a second as the front passes the web, rather than flipping.
    static let webPush: Float = 0.3
    static let webLowering: Float = 3 * .pi / 180
    static let webLean: (most: Float, knee: Float) = (0.8, 3)
    /// How much closer the camera comes when the chain stops, as a share of its distance.
    static let slowPush: Float = 0.2
    /// How long before the front reaches a cobweb its push in peaks, in seconds, so the camera
    /// comes closest as the web tears; how long the push in takes either side of its peak; and
    /// how long it takes to grow to full strength after the chain starts, so the camera's goal
    /// never jumps as it starts.
    static let webLead: Float = 1
    static let webReach: Float = 2
    static let webRamp: Float = 2

    // MARK: Geometry

    let path: DominoPath
    /// The path's offset from the table: a path point less this is where it lies on the table.
    let offset: SIMD2<Float>
    /// The path's length, up to the last book.
    let length: Float
    let tallest: Float
    /// The cobwebs the camera pushes in on, in path order, less any that a lifted book tore
    /// (see `forgetCobweb(at:)`).
    private(set) var cobwebs: [Cobweb]
    /// The composed view the establishing move starts from and the reveal ends in.
    let finale: DominoCameraPose
    let fieldOfView: Float
    let aspect: Float
    let area: Area
    /// How long the establishing move takes, in seconds: longer for a longer chain, and long
    /// enough to keep within `turnRates` and `zoomRates`.
    private(set) var establishTime: Float = 0
    /// How long the reveal takes, in seconds, timed as `establishTime` is from the view as it
    /// starts. Until then, it is the longest the reveal can take.
    private(set) var revealTime = revealTimes.upperBound
    /// Each row's shot, and the swing round each turn from one row's shot to the next.
    let shots: [Shot]
    let swings: [Swing]

    // MARK: State

    /// The camera's pose after the last step: the eye, looking along `view`.
    private(set) var pose: DominoCameraPose
    /// The springs' eye and the point they look at, and how fast those move.
    private var eye: SIMD3<Float>
    private var target: SIMD3<Float>
    private var eyeVelocity = SIMD3<Float>.zero
    private var targetVelocity = SIMD3<Float>.zero
    /// The direction the camera looks, a unit vector, and its roll and how fast that changes.
    private var view: SIMD3<Float>
    private var roll: Float = 0
    private var rollRate: Float = 0
    private var previousGoal: DominoCameraPose?
    /// The front smoothed by a critically damped spring that never runs backward, and its
    /// speed.
    private(set) var front: Float = 0
    private(set) var pace: Float = 0
    /// The front passed through one, two, and three first-order lags (see `estimate`).
    private var lags = SIMD3<Float>.zero
    /// The front the camera frames: the front through three first-order lags, with their lag
    /// at a steady pace added back, so it neither trails a steady chain nor jitters from book
    /// to book. The third lag trails a steady pace by 3 / `estimateStiffness` seconds and the
    /// second by 2 / `estimateStiffness`, so three times the second less twice the third keeps
    /// pace exactly, and its response to the books' unevenness falls off with the square of
    /// their frequency. That lead carries it on past a chain that stops, so it fades out once
    /// the front holds still for `stillTime`, and the estimate never runs backward: it stops
    /// within about half a unit of where the chain stops.
    private(set) var estimate: Float = 0
    /// The estimate before it eases to a stop at the path's end (`endEase`), which may run
    /// past it.
    private var led: Float = 0
    /// The last raw front, how long it has held still, in seconds, and how much of the lead
    /// the estimate adds back, from 0 to 1.
    private var raw: Float = 0
    private var still: Float = 0
    private var lead: Float = 0
    /// How far the camera pushes in for cobwebs (x) and for a slow chain (y), each from 0 to
    /// 1 and smoothed, and how fast they change.
    private var push = SIMD2<Float>.zero
    private var pushSpeed = SIMD2<Float>.zero
    /// Whether the chain has reached `cruise` since the push. Before then, the chain is
    /// starting rather than slowing, so the camera does not push in on it.
    private var cruised = false
    /// The pace smoothed slowly, for timing the cobweb push in, and how fast it changes.
    private var speed: Float = 0
    private var speedChange: Float = 0
    /// The logarithm of the run's distance from the eye to the front, and how fast it changes
    /// (see `maximumZoomRate`).
    private var zoom: Float = 0
    private var zoomRate: Float = 0
    /// Seconds since the rig started, of the establishing move, since the last `reset(to:)`,
    /// since the chain started, and since every book fell.
    private var clock: Float = 0
    private var established: Float = 0
    private var sinceReset = Float.infinity
    private var sinceStart: Float = 0
    private var doneTime: Float = 0

    init(
        path: DominoPath, offset: SIMD2<Float>, length: Float, tallest: Float, cobwebs: [Cobweb],
        finale: DominoCameraPose, fieldOfView: Float, aspect: Float, area: Area
    ) {
        let length = max(0, length)
        self.path = path
        self.offset = offset
        self.length = length
        self.tallest = tallest
        self.finale = finale
        self.fieldOfView = fieldOfView
        self.aspect = aspect
        self.area = area
        // The cobwebs to push in on: dense ones clear of the first second, which the opening
        // frames already, and apart from one another.
        var heroes: [Cobweb] = []
        for web
            in cobwebs.filter({ $0.density >= Self.heroDensity && $0.distance > Self.typicalPace })
            .sorted(by: { ($0.density, -$0.distance) > ($1.density, -$1.distance) })
        where heroes.allSatisfy({ abs($0.distance - web.distance) >= Self.heroSpacing }) {
            heroes.append(web)
        }
        self.cobwebs = heroes.sorted { $0.distance < $1.distance }
        (shots, swings) = Self.choreograph(path: path, length: length, cobwebs: self.cobwebs)
        pose = finale
        eye = finale.eye
        target = finale.target
        view = simd_normalize(finale.target - finale.eye)
        // The establishing move ends on the shot of the first book. Smootherstep moves at most
        // 1.875 times its mean rate, and the move turns over its first 85 percent and zooms over
        // all of it.
        let opening = following(at: 0).orbit
        zoom = log(opening.distance)
        establishTime = min(
            max(
                0.25 * length / Self.typicalPace,
                1.875 / 0.85 * opening.turn(to: Orbit(finale)) / Self.turnRates.establish,
                1.875 * abs(log(Orbit(finale).distance / opening.distance))
                    / Self.zoomRates.establish, Self.establishTimes.lowerBound),
            Self.establishTimes.upperBound)
    }

    /// Stops pushing in on and leaning toward the cobweb at `distance`, which a book lifted
    /// out of the chain tore. The rows' shots, which the webs helped choose, stay as they are.
    mutating func forgetCobweb(at distance: Float) {
        cobwebs.removeAll { abs($0.distance - distance) < 1e-3 }
    }

    /// Continues from `pose` at rest, such as after a pinch or drag moved the camera, past the
    /// establishing move. The springs soften for `returnTime` after, so the camera eases back
    /// to the front rather than whipping round from far away.
    mutating func reset(to pose: DominoCameraPose) {
        self.pose = pose
        eye = pose.eye
        target = pose.target
        view = simd_normalize(pose.target - pose.eye)
        roll = pose.roll
        rollRate = 0
        eyeVelocity = .zero
        targetVelocity = .zero
        previousGoal = nil
        established = max(established, establishTime + 1)
        sinceReset = 0
    }

    /// Whether the reveal has started: every book has fallen, and the last has had
    /// `landTime` to land.
    var isRevealing: Bool { doneTime > Self.landTime }

    /// Advances the camera by `deltaTime` seconds, following `input`, and returns its pose.
    @discardableResult
    mutating func step(_ input: Front, by deltaTime: Float) -> DominoCameraPose {
        guard deltaTime > 0 else { return pose }
        let steps = max(1, Int((deltaTime / Self.substep).rounded(.up)))
        let step = deltaTime / Float(steps)
        let raw = input.started ? min(max(input.distance, 0), length) : 0
        still = raw > self.raw ? 0 : still + deltaTime
        self.raw = raw
        let stiffness = Self.frontStiffness
        let rate = Self.estimateStiffness * step
        // A chain that reaches its last book has ended rather than stalled, so the lead carries
        // the estimate on into the ease at the end.
        let leading: Float = still < Self.stillTime || raw >= length ? 1 : 0
        for _ in 0..<steps {
            let acceleration = stiffness * stiffness * (raw - front) - 2 * stiffness * pace
            pace = max(0, pace + acceleration * step)
            front += pace * step
            lags += SIMD3(raw - lags.x, lags.x - lags.y, lags.y - lags.z) * rate
            lead += (leading - lead) * Self.leadRate * step
            led = max(led, lags.z + 3 * (lags.y - lags.z) * lead)
        }
        // Over the last `endEase` units, the estimate closes on the end at a falling rate, so it
        // slows to a stop there rather than against it.
        let left = max(length + Self.endEase - led, 0)
        estimate = max(
            led < length - Self.endEase ? led : length - left * left / (4 * Self.endEase), 0)
        let wasRevealing = isRevealing
        clock += deltaTime
        established += deltaTime
        sinceReset += deltaTime
        sinceStart = input.started ? sinceStart + deltaTime : 0
        doneTime = input.done ? doneTime + deltaTime : 0
        // The reveal is timed from the view as it starts.
        if isRevealing, !wasRevealing { revealTime = revealDuration() }
        let running = input.started && !input.done
        // A chain that slows at its last book has ended rather than stalled.
        let ending = min(max(length - led, 0) / 2, 1)
        cruised = cruised || (input.started && pace >= Self.cruise)
        let pushGoal = SIMD2(
            running ? cobwebPush(at: estimate).push : 0,
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
        var follow = following(at: estimate)
        let wanted = log(follow.orbit.distance)
        for _ in 0..<steps { Self.approach(&zoom, &zoomRate, toward: wanted, by: step) }
        follow.orbit.distance = exp(zoom)
        let goal = self.goal(following: follow)
        let start = previousGoal ?? goal
        previousGoal = goal
        // The goal's own velocity, so the springs track a moving goal without lag. It fades out
        // over the reveal's last 20 percent, so the camera settles onto `finale` from behind
        // rather than overshooting it and creeping back.
        let fade = 1 - Self.ease(Self.unit((revealClock / revealTime - 0.8) / 0.2))
        let limit = Self.maximumSpeed * Self.limitScale(pose)
        let eyeDrift = Self.clamped((goal.eye - start.eye) / deltaTime, to: limit) * fade
        let targetDrift = Self.clamped((goal.target - start.target) / deltaTime, to: limit) * fade
        let scripted = self.scripted
        let returning = 0.3 + 0.7 * Self.ease(min(sinceReset / Self.returnTime, 1))
        let eyeStiffness =
            (Self.eyeStiffness + (Self.scriptedStiffness - Self.eyeStiffness) * scripted)
            * returning
        let targetStiffness =
            (Self.targetStiffness + (Self.scriptedStiffness - Self.targetStiffness) * scripted)
            * returning
        let floor = self.floor(at: eye, front: estimate)
        for index in 1...steps {
            let share = Float(index) / Float(steps)
            let scale = Self.limitScale(pose)
            Self.spring(
                &eye, &eyeVelocity, toward: start.eye + (goal.eye - start.eye) * share,
                moving: eyeDrift, stiffness: eyeStiffness, scale: scale, by: step)
            Self.spring(
                &target, &targetVelocity,
                toward: start.target + (goal.target - start.target) * share,
                moving: targetDrift, stiffness: targetStiffness, scale: scale, by: step)
            if eye.y < floor {
                eye.y = floor
                eyeVelocity.y = max(0, eyeVelocity.y)
            }
            Self.spring(
                &roll, &rollRate, toward: goal.roll, stiffness: Self.rollStiffness, by: step)
            turn(by: step)
            pose = DominoCameraPose(
                eye: eye, target: eye + view * max(simd_distance(eye, target), 1),
                roll: min(max(roll, -Self.maximumRoll), Self.maximumRoll))
        }
        // Once the reveal has ended, the camera rests on `finale` exactly, from close enough
        // that the step does not show at the finale's distance.
        if revealClock >= revealTime, simd_distance(pose.eye, finale.eye) < 0.02,
            simd_distance(pose.target, finale.target) < 0.02, abs(roll) < 1e-3
        {
            reset(to: finale)
        }
        return pose
    }

    // MARK: Goals

    /// Seconds since the reveal started, or 0 before then.
    private var revealClock: Float { max(doneTime - Self.landTime, 0) }

    /// How much the scripted moves drive the springs, from 0 to 1: fully through the
    /// establishing move, easing off over the second after it, and easing in over the reveal's
    /// first second.
    private var scripted: Float {
        if isRevealing { return Self.ease(min(revealClock, 1)) }
        return 1 - Self.ease(Self.unit(established - establishTime))
    }

    /// The goal for this step, given the shot that films the front.
    private func goal(following follow: Filming) -> DominoCameraPose {
        if revealClock >= revealTime { return finale }
        if isRevealing { return reveal(from: follow, progress: revealClock / revealTime) }
        guard established < establishTime else { return compose(follow) }
        return establishing(to: follow, progress: established / establishTime)
    }

    /// Each row's shot along a path `length` long, and the swing round each turn from one row's
    /// shot to the next. A row's angle, height, and distance vary from row to row by the golden
    /// ratio's steps, so neighboring rows differ and the pattern never repeats, and the first
    /// row's camera starts low, since no row stands before it. The camera chases every row and
    /// swings round each turn to chase the next, never more than fits between the turns. Round
    /// about `craneOverShare` of the turns, it films the rows either side nearly beside the
    /// front and cranes up over the turn with a small swing. It films the row where one of
    /// `cobwebs` tears from as near behind the front as fits, so the web comes toward the camera
    /// and stays in the narrow view longer.
    static func choreograph(path: DominoPath, length: Float, cobwebs: [Cobweb]) -> (
        shots: [Shot], swings: [Swing]
    ) {
        func vary(_ index: Int, _ salt: Float) -> Float {
            (Float(index) * 0.618_034 + salt).truncatingRemainder(dividingBy: 1)
        }
        let pace = typicalPace
        // The longest swing leaves `dwell` of each row and turn steady; the widest turns at
        // `swingRate` for that long.
        let longest = min(
            max(path.period / pace - dwell, swingTimes.lowerBound), swingTimes.upperBound)
        let widest = swingRate * longest
        // A swing turns the camera by a straight angle less both rows' angles from behind, so
        // a row filmed nearer behind than `low` would need a wider swing to either neighbor
        // than fits, even one filmed from as near beside as `sides` allows.
        let low = max(sides.lowerBound, .pi - sides.upperBound - widest)
        let rows = Int(length / path.period) + 1
        // The row whose shot films each web as it tears: the row it hangs along, or the next
        // row for a web past the middle of a turn.
        let webRows = Set(
            cobwebs.map { web in
                let row = (web.distance / path.period).rounded(.down)
                let along = web.distance - row * path.period
                return Int(row) + (along > path.rowLength + .pi * path.radius / 2 ? 1 : 0)
            })
        let over = (0..<(rows - 1))
            .map {
                vary($0, 0.77) < craneOverShare && !webRows.contains($0)
                    && !webRows.contains($0 + 1)
            }
        // Each row's angle from straight behind the front, toward the fallen rows. From the
        // fallen side, the standing books show their spines along the even rows, which run
        // toward +x, and their plain fore edges along the odd rows, so the camera films the
        // even rows from nearer beside the front and the odd rows from nearer behind it, where
        // their covers show. It films a web's row from as near behind as fits, the row before
        // from beside, so that swing fits, and the rows either side of a turn it cranes over
        // nearly beside the front.
        var angles: [Float] = []
        for row in 0..<rows {
            let band: Float = row.isMultiple(of: 2) ? 0.5 : 0.2
            var wanted = low + (sides.upperBound - low) * (band + 0.5 * vary(row, 0.35))
            if webRows.contains(row) {
                wanted = low
            } else if webRows.contains(row + 1) {
                wanted = sides.upperBound
            } else if (row > 0 && over[row - 1]) || (row < rows - 1 && over[row]) {
                wanted =
                    besides.lowerBound + (besides.upperBound - besides.lowerBound) * vary(row, 0.35)
            }
            angles.append(row == 0 ? wanted : max(wanted, .pi - widest - angles[row - 1]))
        }
        let shots = angles.indices.map { row in
            let low = elevations.lowerBound
            return Shot(
                azimuth: row.isMultiple(of: 2) ? .pi + angles[row] : 2 * .pi - angles[row],
                elevation: row == 0 ? low : low + (elevations.upperBound - low) * vary(row, 0.8),
                share: vary(row, 0.55) > 0.83
                    ? tightShare
                    : shares.lowerBound + (shares.upperBound - shares.lowerBound) * vary(row, 0.1))
        }
        let swings = over.indices.map { turn in
            let from = shots[turn]
            let to = shots[turn + 1]
            let swing = abs(to.azimuth - from.azimuth)
            // A swing takes longer the bigger it is. Over a turn it cranes over, the camera
            // cranes up toward `craneOver` over most of the longest swing's time, but no faster
            // than `craneRate`.
            let fitted = min(max(swing / swingRate, swingTimes.lowerBound), longest)
            let time = over[turn] ? max(longest * 0.75, fitted) : fitted
            let higher = max(from.elevation, to.elevation)
            let extra =
                over[turn] ? min(max(craneOver - higher, 0), craneRate * time / .pi) : crane * swing
            return Swing(
                middle: Float(turn) * path.period + path.rowLength + .pi * path.radius / 2
                    - swingLead * pace,
                reach: time * pace / 2,
                lift: abs(to.elevation - from.elevation) / 2 + extra)
        }
        return (shots, swings)
    }

    /// The shot `distance` along the path: the row's, swinging to the next row's over each
    /// swing's reach about its middle, and craned up at the middle of the swing. Also returns
    /// how fast the azimuth changes per unit along the path, for the bank.
    func plan(at distance: Float) -> (shot: Shot, turning: Float) {
        var shot = shots[0]
        var lift: Float = 0
        var turning: Float = 0
        for (index, swing) in swings.enumerated() {
            let progress = (distance - swing.middle + swing.reach) / (2 * swing.reach)
            guard progress > 0 else { break }
            let from = shots[index]
            let to = shots[index + 1]
            let share = min(progress, 1)
            let eased = Self.ease(share)
            let turn = to.azimuth - from.azimuth
            shot.azimuth += turn * eased
            shot.elevation += (to.elevation - from.elevation) * eased
            shot.share += (to.share - from.share) * eased
            guard progress < 1 else { continue }
            let bump = sin(.pi * share)
            lift = max(lift, swing.lift * bump * bump)
            // Smootherstep's slope is 30 p² (1 − p)².
            turning += turn * 30 * share * share * (1 - share) * (1 - share) / (2 * swing.reach)
        }
        shot.elevation += lift
        return (shot, turning)
    }

    /// Where the camera films a front at `front`, before `step` limits how fast its distance
    /// changes: the plan's shot about the front, averaged over a little of the path, with the
    /// eye about the path averaged more widely, so it rounds off the turns.
    private func following(at front: Float) -> Filming {
        // The drift fades in over two seconds once the establishing move lands, so the camera
        // holds on the first book. The reveal blends it away with the rest of the shot.
        let wander = Self.drift(at: clock) * Self.ease(Self.unit((established - establishTime) / 2))
        let (shot, turning) = plan(at: front)
        let typical = tallest * Self.typicalHeight
        let landing = Self.ease(1 - min(max(length - front, 0) / Self.landingReach, 1))
        let settling = Self.ease(min(doneTime / Self.landTime, 1))
        // Lower as the camera pushes in on a cobweb, so the web shows against the table, and
        // at least `landingElevation` as the front nears the last book, so the view looks down
        // on the fallen books.
        let low = max(shot.elevation - Self.webLowering * push.x + wander.y, Self.lowestElevation)
        let elevation = low + max(Self.landingElevation - low, 0) * max(landing, settling)
        let azimuth = shot.azimuth + wander.x
        let distance = max(
            typical * cos(elevation) / (shot.share * 2 * tan(fieldOfView / 2)) * (1 + wander.z)
                * (1 - max(Self.webPush * push.x, Self.slowPush * push.y)), Self.nearest)
        let focus =
            trackPoint(around: front - Self.focusBack, spread: Self.focusSpread)
            + path.point(at: length).heading * landing * typical / 2
        let center = trackPoint(around: front, spread: Self.eyeSpread)
        // While the last book lands, the camera lowers toward the books lying on the table.
        let height = typical / 2 * (1 - Self.landingDrop * settling)
        var eye =
            SIMD3(center.x, height, center.y)
            + distance
            * SIMD3(cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth))
        eye.y = max(eye.y, floor(at: eye, front: front))
        let orbit = Orbit(DominoCameraPose(eye: eye, target: [focus.x, height, focus.y]))
        // The view leans a little toward a cobweb as the front nears it, keeping the tear well
        // inside the view.
        let lean = cobwebPush(at: front).lean
        return Filming(
            orbit: orbit, lean: [lean.x, 0, lean.y], third: 1,
            composition: Self.composition
                + [0, (Self.landingComposition - Self.composition.y) * settling],
            roll: Self.bank * turning * pace)
    }

    /// The move from `finale` down to the first book, `progress` of the way: the camera cranes
    /// down and turns toward the first row ahead of its push in, so the first row is in place
    /// before the camera comes close.
    private func establishing(to follow: Filming, progress: Float) -> DominoCameraPose {
        let orbit = Orbit(finale)
            .blended(
                to: follow.orbit, target: Self.ease(min(progress / 0.6, 1)),
                angles: Self.ease(min(progress / 0.85, 1)), distance: Self.ease(progress))
        let share = Self.ease(progress)
        return compose(
            Filming(
                orbit: orbit, lean: follow.lean * share, third: follow.third * share,
                composition: follow.composition, roll: 0))
    }

    /// The crane up and pull back from `follow` to `finale`, `progress` of the way: the camera
    /// rises and swings round over most of the move, and pulls back to the path's middle from a
    /// fifth of the way, so it lingers over the fallen books before the whole path unrolls
    /// below it.
    private func reveal(from follow: Filming, progress: Float) -> DominoCameraPose {
        let pullBack = Self.ease(Self.unit((progress - 0.2) / 0.8))
        let orbit = follow.orbit.blended(
            to: Orbit(finale), target: pullBack, angles: Self.ease(min(progress / 0.7, 1)),
            distance: pullBack)
        let fade = 1 - Self.ease(progress)
        return compose(
            Filming(
                orbit: orbit, lean: follow.lean * fade, third: follow.third * fade,
                composition: follow.composition, roll: follow.roll * fade))
    }

    /// How long the reveal takes from the view as it starts: longer for a longer chain, and
    /// long enough to keep within `turnRates` over the 70 percent of it that turns and
    /// `zoomRates` over the 80 percent that pulls back.
    private func revealDuration() -> Float {
        let from = Orbit(pose)
        let to = Orbit(finale)
        return min(
            max(
                0.25 * length / Self.typicalPace + 5,
                1.875 / 0.7 * from.turn(to: to) / Self.turnRates.reveal,
                1.875 / 0.8 * abs(log(to.distance / from.distance)) / Self.zoomRates.reveal,
                Self.revealTimes.lowerBound), Self.revealTimes.upperBound)
    }

    /// The pose of `filming`: its view turned so the orbit's target shows at its composition,
    /// leaning toward the cobwebs, and rolled.
    private func compose(_ filming: Filming) -> DominoCameraPose {
        var pose = Self.composed(
            filming.orbit, at: filming.composition, in: area, fieldOfView: fieldOfView,
            aspect: aspect, weight: filming.third)
        pose.target += filming.lean
        pose.roll = filming.roll
        return pose
    }

    /// The pose of `orbit`, turned so its target shows at `composition`, as shares of `area`,
    /// by `weight`, from the view's middle at 0. The eye stays put.
    private static func composed(
        _ orbit: Orbit, at composition: SIMD2<Float>, in area: Area, fieldOfView: Float,
        aspect: Float, weight: Float
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

    /// How far to push in for the cobwebs near `front`, over `webReach` either side of its
    /// peak: most `webLead` before the front reaches a web, timed at the slowly smoothed
    /// `speed`, which holds steady from book to book. It grows in over `webRamp` after the chain
    /// starts. Also returns how far the view leans toward the webs: toward each, by its push
    /// (see `webLean`).
    private func cobwebPush(at front: Float) -> (push: Float, lean: SIMD2<Float>) {
        let rate = max(speed, 4)
        let ramp = Self.ease(min(sinceStart / Self.webRamp, 1))
        let here = point(at: front)
        var result: (push: Float, lean: SIMD2<Float>) = (0, .zero)
        for web in cobwebs {
            let time = ((web.distance - front) / rate - Self.webLead) / Self.webReach
            guard abs(time) < 1 else { continue }
            let push = (1 - time * time) * (1 - time * time) * ramp
            result.push = max(result.push, push)
            let toward = point(at: web.distance) - here
            let reach = simd_length(toward)
            let knee = Self.webLean.knee
            result.lean +=
                toward * (Self.webLean.most / (reach * reach + knee * knee).squareRoot()) * push
        }
        return result
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

    /// The lowest the eye may be at `eye` with the chain's front at `front`: `clearance` above
    /// the tallest book within about a book's height of a standing book, easing down over a few
    /// units to `lowest` elsewhere, where only fallen books lie. It changes smoothly with the
    /// eye's place and the front, so applying it to a goal keeps the goal smooth.
    func floor(at eye: SIMD3<Float>, front: Float) -> Float {
        // Books from the one tipping at the front on stand.
        let standing = max(front - 1, 0)
        guard standing < length else { return Self.lowest }
        let place = SIMD2(eye.x, eye.z) + offset
        let depth = 2 * path.radius
        let reach: Float = 4
        var nearest = Float.infinity
        let rows =
            Int(
                ((place.y - depth - reach) / depth).rounded(.down))...Int(
                ((place.y + reach) / depth).rounded(.up))
        for row in rows where row >= 0 {
            let start = Float(row) * path.period
            // The row's standing stretch, then its turn's, sampled along the turn.
            let low = max(start, standing)
            let high = min(start + path.rowLength, length)
            if low <= high {
                let a = path.point(at: low).position
                let b = path.point(at: high).position
                let along = b - a
                let share =
                    simd_length_squared(along) > 0
                    ? min(max(simd_dot(place - a, along) / simd_length_squared(along), 0), 1) : 0
                nearest = min(nearest, simd_distance(place, a + along * share))
            }
            let turnLow = max(start + path.rowLength, standing)
            let turnHigh = min(start + path.period, length)
            guard turnLow <= turnHigh else { continue }
            for index in 0...8 {
                let distance = turnLow + (turnHigh - turnLow) * Float(index) / 8
                nearest = min(nearest, simd_distance(place, path.point(at: distance).position))
            }
        }
        let near = 1 - Self.ease(Self.unit((nearest - 1.2) / 2.5))
        return Self.lowest + (tallest + Self.clearance - Self.lowest) * near
    }

    // MARK: Motion

    /// Slow, smooth wandering in bearing (x) and elevation (y), in radians, and distance (z),
    /// as a share: sines whose periods share no common multiple, so it never repeats within a
    /// run. The bearing wanders on one long period, so the view floats rather than rocks.
    static func drift(at time: Float) -> SIMD3<Float> {
        func wave(_ period: Float, _ phase: Float) -> Float { sin(2 * .pi * time / period + phase) }
        return [
            0.05 * wave(9.5, 0.6),
            0.02 * wave(7, 1.3) + 0.008 * wave(4.1, 0.2),
            0.03 * wave(5.3, 2.6),
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

    /// Moves the logarithm of a distance, `value`, toward `goal` at `zoomStiffness`, with its
    /// `rate` within `maximumZoomRate` and changing within `maximumZoomAcceleration`. It slows
    /// in time to stop at a still goal rather than pass it.
    private static func approach(
        _ value: inout Float, _ rate: inout Float, toward goal: Float, by step: Float
    ) {
        let error = goal - value
        let limit = min(maximumZoomRate, (2 * maximumZoomAcceleration * abs(error)).squareRoot())
        let wanted = min(max(error * zoomStiffness, -limit), limit)
        let change = maximumZoomAcceleration * step
        rate += min(max(wanted - rate, -change), change)
        value += rate * step
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
    /// What the rig aims for: an orbit about the front, how far the view leans from the
    /// orbit's target toward the cobwebs, and the camera's bank.
    fileprivate struct Filming {
        var orbit: Orbit
        var lean: SIMD3<Float>
        /// How far toward `composition` the orbit's target shows, from 0 for the middle to 1.
        var third: Float
        /// Where the orbit's target shows in the rig's area, as shares of its width and height.
        var composition: SIMD2<Float>
        var roll: Float
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
