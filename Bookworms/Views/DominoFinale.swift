import CoreGraphics
import Foundation
import RealityKit
import simd

/// The finale once every book has fallen (see `DominoScene`), timed from the moment the last
/// book falls.
///
/// At once, the camera starts one move from wherever it films to the spread's view, where it
/// comes to rest `moveTime` seconds later (`view(from:to:around:progress:)`). The spread lies
/// over the part of the table the chain fell on, so the spread's view frames about what the
/// overview did. The move starts from the view as it shows, carried on by the camera's own
/// motion for a moment (`coast`), so the camera neither stops dead nor drifts on with the
/// camera mode. It first pulls back and cranes up about the point it looked at, which, after
/// the Follow camera, moves onto where the last book lands, and from `aimDelay` turns its aim
/// toward the spread.
///
/// The fallen books lie still for `pause` seconds, so the reader can take in the fallen chain
/// as the camera settles. Then every book rises off the table at once and hovers, and the books
/// fly one by one into a face-up spread (`PileSpread`) along ways planned so that no book passes
/// through another (`Gather`), all landing within `gatherBudget`, speeding up if they must. The
/// spread's last book is the last book read, the chain's last, which the spread puts down last,
/// so no book rests on it (`PileSpread`'s `last`). It rises with the others but floats beside
/// them until `flybyLead` before the last of the rest lands. Then it zooms toward the camera, passes
/// close in front of it in slow motion, its cover turned squarely to the viewer in the middle
/// of the spread's area (`passPose(size:seenBy:in:of:)`), and slams down into its place
/// (`flybyPose(from:to:near:time:)`). The slam knocks the table down, and the spread's books,
/// rigid bodies until they settle, hop as it springs back (`table(after:kick:)`), and the camera
/// jolts (`jolt(_:time:)`). The spread
/// and the passing book fill the part of the view that the run plays in, the 9:16 frame that a recording shows in a view
/// wider than that, such as a Mac's window (`area(in:)`).
/// Out of the lamp's beam, the room lights the last book more (`DeskStage.light(_:boost:)`), so
/// it stays lit rather than going dark (`boost(at:over:radius:)`).
/// The poses are pure functions of time, so tests replay them.
enum DominoFinale {
    /// How long the camera's move to the spread's view takes, in seconds.
    static let moveTime: Float = 2
    /// The soonest and the latest the books' ways into the spread are planned, in seconds after
    /// the last book falls: once every book lies still, from the soonest, and at the latest even
    /// if one still moves. The books then hold still until `pause`.
    static let restDelay: Float = 0.3
    static let longestRest: Float = 0.9
    /// How long the fallen books lie still before they rise, in seconds after the last book
    /// falls.
    static let pause: Float = 1
    /// How long every book but the spread's last takes, at the longest, to land once the books
    /// start to rise, in seconds.
    static let gatherBudget: Float = 2.6
    /// When the camera's aim starts to turn from where the chain ended toward the spread, in
    /// seconds after the last book falls.
    static let aimDelay: Float = 0.6
    /// The last book's flourish: how long before the last of the other books lands it sets off,
    /// so one move flows into the next, how long it takes to zoom toward the camera, to pass it
    /// in slow motion, and to slam down into its place, in seconds. The pass is brief, so the
    /// flyby keeps the finale moving, yet long enough to read the book's cover.
    static let flybyLead: Float = 0.2
    static let flybyApproach: Float = 0.3
    static let flybyGlide: Float = 0.4
    static let flybyDrop: Float = 0.1
    /// The shares of the last book's way past the camera that it covers in slow motion, about
    /// the middle, where it passes the camera, and how far it turns about its own length
    /// meanwhile, in radians.
    static let slowWay: ClosedRange<Float> = 0.42...0.58
    static let glideTurn: Float = 10 * .pi / 180
    /// How much of the view the last book fills as it passes the camera: this share of the
    /// view's width, or of its height for a book that would otherwise be too tall to fit.
    static let passWidth: Float = 0.45
    static let passHeight: Float = 0.42
    /// How long the spread's books settle after the slam, in seconds, as physics moves them.
    static let settleTime: Float = 1.2
    /// The table under the slam, a heavy slab, a little hollow, that gives a few millimeters
    /// and springs back: its mass, in the dominoes' mass units (`DominoLayout.mass(height:)`),
    /// how many times a second it springs back and forth, its damping ratio, and the fastest
    /// a slam knocks it down, in units a second.
    static let tableMass: Float = 20
    static let tableRing: Float = 14
    static let tableDamping: Float = 0.3
    static let tableKick: Float = 10
    /// The longest side of the cover the last book wears from the finale on, in pixels: about as
    /// many as its cover covers on a phone's screen as it passes the camera, more than three
    /// times the chain's (`BookFactory.coverPixels(for:)`), so its lettering stays sharp.
    static let flybyCoverPixels = 768
    /// The most the room's light on the last book brightens out of the lamp's beam, in stops.
    static let boostLimit: Float = 4.5
    /// The time constant, in seconds, with which the camera's motion as the last book falls
    /// dies away in the move (`coast`): the camera carries on that many seconds' worth of it.
    static let coastTime: Float = 0.25
    /// With Reduce Motion on, how long after the last book falls the camera cuts to the
    /// spread's view and the books appear in their places, in seconds.
    static let stillWait: Float = 1
    /// The room the heading takes at the top of the spread's area (`area(in:)`), of `size`,
    /// which the spread leaves: 28 percent of the width of the 9:16 frame that the area holds
    /// (`headingWidth(in:)`), about 112 points on an iPhone, 129 in a Mac's default window,
    /// and 300 pixels on a story clip, since `DominoFinaleCard` scales with that width.
    static func headingRoom(in size: CGSize) -> CGFloat { headingWidth(in: size) * 0.28 }

    /// The width of the widest 9:16 frame that an area of `size` holds, which sizes the
    /// heading, so a **Window** video's wider frame shows it as large as a story of the same
    /// height does.
    static func headingWidth(in size: CGSize) -> CGFloat {
        let story = ShareAspect.story.size
        return min(size.width, size.height * story.width / story.height)
    }

    /// The scale of `DominoFinaleCard` in an area of `size`, 1 on a story clip.
    static func headingScale(in size: CGSize) -> CGFloat {
        headingWidth(in: size) / ShareAspect.story.size.width
    }

    /// The part of a view of `viewport` that the whole run plays in, in points: the chain
    /// stands, falls, and gathers there, the spread fills it, and the last book passes in it.
    /// In a view wider than 9:16, such as a Mac's window, recording a 9:16 story, it is the
    /// frame that a recording of the run shows (`DominoRecorder.crop(in:)`), so the video and
    /// its image show every book fall and gather, and the live view frames them the same way,
    /// with the table on either side. Otherwise, as on an iPhone or a Mac recording its
    /// window's shape, it is the whole view.
    static func area(in viewport: PileViewport) -> CGRect {
        let frame = DominoRecorder.crop(in: viewport)
        return frame.width < viewport.size.width
            ? frame : CGRect(origin: .zero, size: viewport.size)
    }

    /// The part of `area(in:)` that the bars leave clear, in points, which the dominoes'
    /// cameras frame the chain in (see `DominoScene`). On an iPhone, it is the part of the view
    /// between the bars.
    static func clearArea(in viewport: PileViewport) -> CGRect {
        area(in: viewport).intersection(viewport.clear)
    }

    /// Where the spread lays out its books in a view of `viewport`, in points: across
    /// `clearArea(in:)`, 16 points in from its sides, below the heading's room
    /// (`headingRoom(width:)`), and 24 points above the bottom bar.
    static func spreadRect(in viewport: PileViewport) -> CGRect {
        let area = area(in: viewport)
        let clear = clearArea(in: viewport)
        let top = viewport.insets.top + headingRoom(in: area.size)
        return CGRect(
            x: clear.minX + 16, y: top, width: clear.width - 32, height: clear.maxY - 24 - top)
    }

    /// How long the last book's flyby takes, from leaving its height to landing in its place.
    static var flybyTime: Float { flybyApproach + flybyGlide + flybyDrop }

    /// How long the finale of `count` books takes at the longest, from the last book's fall to
    /// the spread settling after the slam.
    static func duration(count: Int) -> Float {
        count == 0 ? 0 : pause + gatherBudget - flybyLead + flybyTime + settleTime
    }

    /// Where the last book, of `size` (see `BookShape.size`), passes the camera, seen by
    /// `camera` in a view of `view` points: in the middle of `area`, the part of the view the
    /// spread fills (`area(in:)`), facing the camera squarely, head up, as near as fills
    /// `passWidth` of the area's width or `passHeight` of its height, whichever comes first.
    /// Its cover lies parallel to the view, so it shows as a rectangle, as if held up to the
    /// viewer, also where the area's middle lies off the camera's axis. The book lies wholly
    /// within the area, and even the smallest, 1.7 units tall, passes about 10 units from the
    /// camera, well past its near plane.
    static func passPose(
        size: SIMD3<Float>, seenBy camera: PileCamera, in area: CGRect, of view: CGSize
    ) -> Transform {
        let slope = tan(PileCamera.fieldOfView / 2)
        let aspect = Float(view.width / view.height)
        let share = SIMD2(Float(area.width / view.width), Float(area.height / view.height))
        let depth =
            max(size.x / (passWidth * share.x * aspect), size.y / (passHeight * share.y))
            / (2 * slope) + size.z / 2
        // The area's middle in normalized device coordinates, whose y grows upward.
        let middle = SIMD2(
            Float(2 * area.midX / view.width - 1), Float(1 - 2 * area.midY / view.height))
        let shown = camera.transform
        return Transform(
            scale: .one, rotation: shown.rotation,
            translation: shown.translation
                + shown.rotation.act(
                    [middle.x * aspect * slope * depth, middle.y * slope * depth, -depth]))
    }

    /// How many stops brighter the room lights the last book at `point`, over its `place`,
    /// under the lamp whose pool covers a circle of `radius` around the table's middle: the
    /// stops of the lamp's light it has lost by leaving the beam that lights its place, up to
    /// `boostLimit`, and none while it is as far inside the beam as its place. The room's light
    /// is weaker than the lamp's, so this keeps a book that springs out of the beam from going
    /// dark without making it outshine the books under it.
    static func boost(at point: SIMD3<Float>, over place: SIMD3<Float>, radius: Float) -> Float {
        let lamp = DeskStage.lampPlacement(pool: .zero, radius: radius)
        let axis = simd_normalize(lamp.aim - lamp.position)
        // The share of full light at a point: all of it inside the inner cone, fading out to
        // none at the outer cone's edge.
        func beam(_ point: SIMD3<Float>) -> Float {
            let cosine = simd_dot(simd_normalize(point - lamp.position), axis)
            let (inner, outer) = (
                cos(lamp.innerAngle / 2 * .pi / 180), cos(lamp.outerAngle / 2 * .pi / 180)
            )
            let share = min(max((cosine - outer) / (inner - outer), 0), 1)
            return share * share * (3 - 2 * share)
        }
        let lost = log2(max(beam(place), 1e-3) / max(beam(point), 1e-3))
        return min(max(lost, 0), boostLimit)
    }

    /// `from` carried on for `time` seconds by the camera's motion as the move starts,
    /// `velocity` in units a second and `spin` in radians a second about its own axis, slowing
    /// to a stop with the time constant `coastTime`. The move starts from this view, so the
    /// camera keeps its speed and heading as the finale starts and turns smoothly into the
    /// move, which takes over as the coast dies away.
    static func coast(
        _ from: Transform, velocity: SIMD3<Float>, spin: SIMD3<Float>, time: Float
    ) -> Transform {
        let carried = coastTime * (1 - exp(-max(time, 0) / coastTime))
        let angle = simd_length(spin) * carried
        let turn =
            angle > 1e-6
            ? simd_quatf(angle: angle, axis: simd_normalize(spin))
            : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        return Transform(
            scale: from.scale, rotation: turn * from.rotation,
            translation: from.translation + velocity * carried)
    }

    /// The last book's pose `time` seconds into its flyby, from `from`, where it hovers, to
    /// `to`, its place in the spread, past `near`, where it passes the camera
    /// (`passPose(size:seenBy:in:of:)`).
    ///
    /// Its way is one curve, from where it hovers out toward the camera, through `near`, and
    /// back down onto its place, which it reaches in a nearly straight line. It never stops on
    /// it: it zooms out toward the camera over `flybyApproach`, turning its cover to the viewer,
    /// passes the camera in slow motion over `flybyGlide`, covering only the middle of its way
    /// (`slowWay`) as it turns `glideTurn` about its length, then slams down onto its place
    /// over `flybyDrop`, speeding up hard all the way, as a book thrown down does. It lies flat
    /// by the last third of the drop, so it comes down flat onto the books under its place,
    /// and lands at full speed.
    static func flybyPose(from: Transform, to: Transform, near: Transform, time: Float)
        -> Transform
    {
        // A quadratic curve whose middle is `near`.
        let bend = near.translation * 2 - (from.translation + to.translation) / 2
        func point(_ way: Float) -> SIMD3<Float> {
            from.translation * (1 - way) * (1 - way) + bend * 2 * way * (1 - way)
                + to.translation * way * way
        }
        func spun(_ share: Float) -> simd_quatf {
            near.rotation * simd_quatf(angle: glideTurn * (share - 0.5), axis: [0, 1, 0])
        }
        let (first, last) = (slowWay.lowerBound, slowWay.upperBound)
        // The slow stretch's pace, in shares of the way a second, which the zoom slows to and
        // the slam starts from.
        let slow = (last - first) / flybyGlide
        if time < flybyApproach {
            // From rest, slowing into the slow stretch's pace.
            let share = max(time, 0) / flybyApproach
            let way =
                first * share * share * (3 - 2 * share)
                + slow * flybyApproach * share * share * (share - 1)
            // The turn starts from rest too, so a book hovering upside down doesn't flip.
            return Transform(
                scale: to.scale,
                rotation: DominoSetup.turn(
                    from.rotation, to: spun(0), by: DominoCameraRig.ease(share)),
                translation: point(way))
        }
        if time < flybyApproach + flybyGlide {
            let share = (time - flybyApproach) / flybyGlide
            return Transform(
                scale: to.scale, rotation: spun(share),
                translation: point(first + (last - first) * share))
        }
        // From the slow stretch's pace, speeding up hard to land at full speed.
        let drop = min((time - flybyApproach - flybyGlide) / flybyDrop, 1)
        let start = slow * flybyDrop
        let way =
            last + start * (drop * drop * drop - 2 * drop * drop + drop)
            + (1 - last) * drop * drop * drop
        return Transform(
            scale: to.scale,
            rotation: DominoSetup.turn(
                spun(1), to: to.rotation, by: DominoCameraRig.ease(min(drop * 1.5, 1))),
            translation: point(way))
    }

    /// How far the table has given, in units, `time` seconds after a slam knocked it down at
    /// `kick` units a second: down at once, then springing back and forth, dying away.
    static func table(after time: Float, kick: Float) -> Float {
        guard time > 0 else { return 0 }
        let ring = 2 * .pi * tableRing
        let damped = ring * (1 - tableDamping * tableDamping).squareRoot()
        return -kick / damped * exp(-tableDamping * ring * time) * sin(damped * time)
    }

    /// How fast the table moves, in units a second, `time` seconds after the slam: the rate of
    /// change of `table(after:kick:)`, never faster than `kick`. The table follows this speed, so
    /// its motion doesn't depend on how long a frame runs.
    static func tableSpeed(after time: Float, kick: Float) -> Float {
        guard time >= 0 else { return 0 }
        let ring = 2 * .pi * tableRing
        let decay = tableDamping * ring
        let damped = ring * (1 - tableDamping * tableDamping).squareRoot()
        let swing = cos(damped * time) - decay / damped * sin(damped * time)
        return -kick * exp(-decay * time) * swing
    }

    /// How long the camera shakes once the last book slams down, in seconds: over before the
    /// books settle, so pinches and drags take over from a still camera.
    static let joltTime: Float = 0.45

    /// `view` shaken `time` seconds after the last book slams down: a quick jolt up and down,
    /// a little to the side, and a hair of roll, dying away within `joltTime`, as a camera on
    /// the table would shake. At its peak it moves under 0.17 units up or down and 0.06 to the
    /// side, and rolls under 0.006 radians.
    static func jolt(_ view: Transform, time: Float) -> Transform {
        guard time > 0, time < joltTime else { return view }
        let wave = exp(-time / 0.1) * sin(2 * .pi * time / 0.055)
        return Transform(
            scale: view.scale,
            rotation: simd_quatf(angle: 0.006 * wave, axis: view.rotation.act([0, 0, 1]))
                * view.rotation,
            translation: view.translation + view.rotation.act([0.06, 0.17, 0]) * wave)
    }

    /// How far the camera's move has come at `progress` of its time: it gets under way at
    /// once, gathering speed over the first third, and spends the rest slowing to a stop, so it
    /// leaves without a hold and settles gently. Its speed starts and ends at 0, and its
    /// acceleration ends at 0.
    static func glide(_ progress: Float) -> Float {
        let time = min(max(progress, 0), 1)
        return time * time * (6 - 8 * time + 3 * time * time)
    }

    /// The camera `progress` of the way from `from` to the spread's view `to`, along
    /// `glide(_:)`. It swings about the point it looks at, so it cranes and pulls back in one
    /// sweep rather than sliding along a line: the turn and pitch change evenly, and the
    /// distance by an even ratio, so the zoom keeps one pace. The point starts where the view's
    /// axis meets the table, or as deep as `focus`, such as where the last book lands, and moves
    /// onto `focus` by `aimDelay`, so the camera centers on it as it pulls back, or holds still
    /// without one. It then moves straight to the spread's, easing in and out, and arrives with
    /// the rest of the move, so the camera keeps the books where the spread's view frames them
    /// as they gather. Any roll `from` has eases out.
    static func view(
        from: Transform, to: PileCamera, around focus: SIMD3<Float>? = nil, progress: Float
    ) -> Transform {
        let share = glide(progress)
        let aim = DominoCameraRig.ease(
            min(max(progress * moveTime - aimDelay, 0) / (moveTime - aimDelay), 1))
        let forward = from.rotation.act([0, 0, -1])
        // A view that looks level or up meets the table nowhere; it turns about a point ahead.
        let reach =
            focus.map { simd_dot($0 - from.translation, forward) }
            ?? PileCamera.intersect((from.translation, forward), height: 0)
            .map { simd_distance($0, from.translation) } ?? PileCamera.distance
        let depth = min(max(reach, 1), 4 * PileCamera.distance)
        let start = PileCamera(
            target: from.translation + forward * depth, yaw: atan2(-forward.x, -forward.z),
            zoom: PileCamera.distance / depth, pitch: asin(min(max(-forward.y, -1), 1)))
        let centered =
            focus.map {
                start.target
                    + ($0 - start.target)
                    * DominoCameraRig.ease(min(max(progress * moveTime / aimDelay, 0), 1))
            } ?? start.target
        let camera = PileCamera(
            target: centered + (to.target - centered) * aim,
            yaw: start.yaw + remainder(to.yaw - start.yaw, 2 * .pi) * share,
            zoom: start.zoom * pow(to.zoom / start.zoom, share),
            pitch: start.pitch + (to.pitch - start.pitch) * share)
        // The roll about the view that `start` leaves out, in the camera's own frame.
        let roll = start.rotation.inverse * from.rotation
        return Transform(
            rotation: camera.rotation
                * DominoSetup.turn(roll, to: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), by: share),
            translation: camera.transform.translation)
    }

    /// The spread's `slots` and `camera` turned by `yaw` about the table's center, so a camera
    /// that films the chain from `yaw` sees the spread as the share image's camera does, with
    /// the books' heads away from it.
    static func turned(_ slots: [PileSlot], camera: PileCamera, by yaw: Float) -> (
        slots: [PileSlot], camera: PileCamera
    ) {
        let turn = simd_quatf(angle: yaw, axis: [0, 1, 0])
        let turned = slots.map { slot in
            var slot = slot
            slot.transform = Transform(
                scale: slot.transform.scale, rotation: turn * slot.transform.rotation,
                translation: turn.act(slot.transform.translation))
            return slot
        }
        var camera = camera
        camera.target = turn.act(camera.target)
        camera.yaw += yaw
        return (turned, camera)
    }
}

/// How a recording of a dominoes run (`DominoRecorder`) fits in `longest` seconds: which of the
/// live view's frames it keeps, and when the hits sound in it.
///
/// The recording starts at the push and ends `hold` seconds after the heading starts to show.
/// The movie then shows its last frame for `lastFrameHold` seconds more, outside `longest`, so
/// it lasts up to `longest` plus `lastFrameHold` seconds.
/// The finale, from the last book's fall, keeps live speed, so the run before it gets what is
/// left (`runBudget`). While the books fall, the recording keeps fewer frames than the view
/// shows when the run would otherwise run long: it estimates the run's live length from how long
/// the chain has taken to fall as far as it has, scaled by the share of the whole run that part
/// takes at the camera's typical pace as the chain speeds up (`DominoCameraRig.fallTime(to:)`),
/// or, before a twentieth of the way, from that typical run's length alone, and plays the rest
/// of the run as fast as it must to end within the budget, easing between speeds over about half
/// a second. The recording's frames come at
/// `PileMovieTiming.framesPerSecond`, each showing the view as it was at its start. Live time
/// the recording leaves out, such as while a book is out at its details, passes with no frames
/// (`skip(_:)`), and its hits are left out too.
struct DominoMovieTiming {
    /// The longest a recording gets, in seconds, before the movie's `lastFrameHold`.
    static let longest: Double = 30
    /// How long the recording runs on once the heading starts to fade in, in seconds.
    static let hold: Double = 2
    /// How long the movie shows the recording's last frame still, in seconds, so viewers see
    /// the gathered books under the heading before it ends. The writer repeats the frame
    /// (`PileMovieWriter.repeatFrame(_:for:before:)`), which costs no rendering and keeps the
    /// run's pacing within `longest`. A recording that ends before the books gather, at
    /// `frameLimit`, has no hold.
    static let lastFrameHold: Double = 3
    /// The seconds of video the run before the finale may take: what `longest` leaves after
    /// the finale and the hold, less a second for a finale that starts a little late.
    static let runBudget = longest - Double(DominoFinale.duration(count: 2)) - hold - 1
    /// The most frames a recording keeps.
    static let frameLimit = Int(longest) * Int(PileMovieTiming.framesPerSecond)

    /// The live seconds the run is estimated to take before it has a pace of its own.
    let estimate: Double
    /// The path's length, up to the last book.
    private let length: Float
    /// Seconds of the live view since the push.
    private(set) var live: Double = 0
    /// Seconds of video since the push.
    private(set) var video: Double = 0
    /// How many times faster than live the video plays.
    private(set) var speed: Double = 1
    /// The stretches of live seconds since the push that the recording leaves out.
    private(set) var gaps: [Range<Double>] = []
    private var next = 0

    /// The timing of a run along a path `length` units long.
    init(length: Float) {
        self.length = length
        estimate = Double(DominoCameraRig.fallTime(to: length))
    }

    /// Whether the recording has its most frames.
    var isFull: Bool { next >= Self.frameLimit }

    /// Moves on by `deltaTime` seconds of the live view, after which the run has come
    /// `progress` of its way, from 0 at the push to 1 as the last book falls, or `nil` once the
    /// finale has started. Returns the numbers of the frames that start within the step, if
    /// any, which show the view as it is after the step.
    mutating func advance(by deltaTime: Double, progress: Double?) -> ClosedRange<Int>? {
        live += deltaTime
        if let progress {
            let total =
                progress < 0.05
                ? max(estimate, live)
                : live * estimate / Double(DominoCameraRig.fallTime(to: Float(progress) * length))
            let wanted = max(1, (total - live) / max(Self.runBudget - video, 0.25))
            speed += (wanted - speed) * min(1, deltaTime / 0.5)
        } else {
            speed = 1
        }
        video += deltaTime / speed
        let due = min(Int(video * Double(PileMovieTiming.framesPerSecond)), Self.frameLimit - 1)
        guard due >= next else { return nil }
        defer { next = due + 1 }
        return next...due
    }

    /// Moves on by `deltaTime` seconds of the live view that the recording leaves out: no
    /// frames show them, and `hits(_:shownAt:skipping:)` leaves out their hits.
    mutating func skip(_ deltaTime: Double) {
        if let last = gaps.last, last.upperBound == live {
            gaps[gaps.count - 1] = last.lowerBound..<live + deltaTime
        } else {
            gaps.append(live..<live + deltaTime)
        }
        live += deltaTime
    }

    /// `records`, hits timed in live seconds since the push, timed instead by a recording
    /// whose frames show the live view at `times`, in order: each sounds with the first frame
    /// that shows it, after the live throttle's 30 milliseconds in the video's time, so a run
    /// that plays faster than live does not pile up its knocks. Hits after the last frame, or
    /// within `gaps`, are left out.
    static func hits(
        _ records: [ImpactRecord], shownAt times: [Double], skipping gaps: [Range<Double>] = []
    ) -> [ImpactRecord] {
        var throttle = ImpactThrottle(interval: ImpactSound.knockInterval)
        var frame = 0
        var kept: [ImpactRecord] = []
        for record in records where !gaps.contains(where: { $0.contains(record.time) }) {
            while frame < times.count, times[frame] < record.time { frame += 1 }
            guard frame < times.count else { break }
            var moved = record
            // `PileMovieTiming.frame(showing:)` takes this time to frame `frame`.
            moved.time = Double(frame + 1) / Double(PileMovieTiming.framesPerSecond)
            if throttle.admit(record.volume, at: moved.time) { kept.append(moved) }
        }
        return kept
    }
}
