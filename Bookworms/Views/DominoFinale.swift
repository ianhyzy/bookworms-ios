import CoreGraphics
import Foundation
import RealityKit
import simd

/// The finale once every book has fallen (see `DominoScene`), timed from the moment the last
/// book falls.
///
/// At once, the camera starts one slow move from wherever it films to the spread's view, where
/// it comes to rest `moveTime` seconds later (`view(from:to:around:progress:)`). The move starts from
/// the view as it shows, carried on by the camera's own motion for a moment (`coast`), so the
/// camera neither stops dead nor drifts on with the camera mode. It first pulls back and cranes
/// up about the point it looked at, which, after the Follow camera, moves onto where the last
/// book lands, and from `aimDelay` turns its aim toward the spread, ahead of the books. `gatherDelay` seconds in, while the camera still
/// moves, the books start to gather into a face-up spread (`PileSpread`): each lifts off the
/// desk, flies in an arc to its place, turning face up on the way, and settles flat, one after
/// another in the spread's order, so a book lands only after the books it rests on. Every book
/// but the spread's last has landed `settleMargin` before the camera comes to rest. The
/// spread's last book is the last book read, the chain's last, which the spread puts down last,
/// so no book rests on it (`PileSpread`'s `last`). It waits where it fell; as the camera comes
/// to rest, it springs up close to the camera, its cover turned squarely to the viewer and large
/// in the middle of the spread's area (`snapTop(size:seenBy:in:of:)`), hangs there a beat, and
/// slams down into its place, landing `snapLanding` after the camera stops
/// (`snapPose(from:to:top:time:)`). The spread and the hanging book fill the part of the view
/// that a recording shows, in a view wider than 9:16 such as a Mac's window (`area(in:)`).
/// Out of the lamp's beam, the room lights it more (`DeskStage.light(_:boost:)`), so it stays
/// lit rather than going dark (`boost(at:over:radius:)`).
/// The poses are pure functions of time, so tests replay them.
enum DominoFinale {
    /// How long the camera's move to the spread's view takes, in seconds.
    static let moveTime: Float = 6
    /// When the books start to gather, in seconds after the last book falls.
    static let gatherDelay: Float = 2.5
    /// How long each book's flight takes, in seconds.
    static let flightTime: Float = 1.4
    /// The most time from one flight's start to the next, for a short chain.
    static let longestStep: Float = 0.12
    /// How long before the camera comes to rest every book but the last has landed, in seconds.
    static let settleMargin: Float = 0.4
    /// How high a flight's arc peaks above the higher of its ends, in units, and how much
    /// higher every fourth book's does, so books in the air at once cross at different heights.
    static let rise: Float = 2.6
    static let riseStep: Float = 0.4
    /// When the camera's aim starts to turn from where the chain ended toward the spread, in
    /// seconds after the last book falls: a second before the books start to gather, so the aim
    /// leads them there.
    static let aimDelay: Float = 1.5
    /// The last book's flourish: how long it takes to spring up to the camera, to hang there,
    /// and to drop into its place, in seconds, and how long after the camera comes to rest it
    /// lands: late enough that the camera has come to rest by the time the book hangs in front
    /// of it.
    static let snapRise: Float = 0.35
    static let snapHang: Float = 0.4
    static let snapDrop: Float = 0.18
    static let snapLanding: Float = 0.7
    /// How much of the view the last book fills as it hangs before the camera: this share of the
    /// view's width, or of its height for a book that would otherwise be too tall to fit.
    static let snapWidth: Float = 0.7
    static let snapHeight: Float = 0.6
    /// The longest side of the cover the last book wears from the finale on, in pixels: about as
    /// many as its cover covers on a phone's screen as it hangs, more than five times the
    /// chain's (`BookFactory.coverPixels(for:)`), so its lettering stays sharp.
    static let snapCoverPixels = 1280
    /// The most the room's light on the last book brightens out of the lamp's beam, in stops.
    static let boostLimit: Float = 4.5
    /// The time constant, in seconds, with which the camera's motion as the last book falls
    /// dies away in the move (`coast`): the camera carries on that many seconds' worth of it.
    static let coastTime: Float = 0.25
    /// With Reduce Motion on, how long after the last book falls the camera cuts to the
    /// spread's view and the books appear in their places, in seconds.
    static let stillWait: Float = 1
    /// The room the heading takes at the top of the spread's area (`area(in:)`), `width` wide,
    /// which the spread leaves: 28 percent of the width, about 112 points on an iPhone, 129 in
    /// a Mac's default window, and 300 pixels on a story clip, since `DominoFinaleCard` scales
    /// with the width.
    static func headingRoom(width: CGFloat) -> CGFloat { width * 0.28 }

    /// The part of a view of `viewport` that the spread fills and the last book hangs in, in
    /// points. In a view wider than 9:16, such as a Mac's window, it is the 9:16 frame that a
    /// recording of the run shows of the finale (`DominoRecorder.crop(in:)`), so the video and
    /// its image show every gathered book, and the live view frames them the same way, with
    /// the table on either side. Otherwise, as on an iPhone, it is the whole view.
    static func area(in viewport: PileViewport) -> CGRect {
        let frame = DominoRecorder.crop(in: viewport)
        return frame.width < viewport.size.width
            ? frame : CGRect(origin: .zero, size: viewport.size)
    }

    /// Where the spread lays out its books in a view of `viewport`, in points: across the part
    /// of `area(in:)` that the bars leave clear, 16 points in from its sides, below the
    /// heading's room (`headingRoom(width:)`), and 24 points above the bottom bar.
    static func spreadRect(in viewport: PileViewport) -> CGRect {
        let area = area(in: viewport)
        let clear = area.intersection(viewport.clear)
        let top = viewport.insets.top + headingRoom(width: area.width)
        return CGRect(
            x: clear.minX + 16, y: top, width: clear.width - 32, height: clear.maxY - 24 - top)
    }

    /// How long the last book's flourish takes, from its spring to its landing.
    static var snapTime: Float { snapRise + snapHang + snapDrop }

    /// When the flight of the book at `index` of the spread's `count` starts, in seconds after
    /// the last book falls: from `gatherDelay`, `longestStep` apart or closer, so every book but
    /// the last lands `settleMargin` before the camera comes to rest. The last book springs so
    /// that it lands `snapLanding` after.
    static func start(of index: Int, count: Int) -> Float {
        if index == count - 1 { return moveTime + snapLanding - snapTime }
        let window = moveTime - settleMargin - gatherDelay - flightTime
        return gatherDelay + Float(index) * min(longestStep, window / Float(max(count - 2, 1)))
    }

    /// How long the finale of `count` books takes, from the last book's fall to the landing of
    /// the spread's last book.
    static func duration(count: Int) -> Float { count == 0 ? 0 : moveTime + snapLanding }

    /// How high the arc of the book at `index` peaks above the higher of its ends.
    static func peak(of index: Int) -> Float { rise + riseStep * Float(index % 4) }

    /// Where the last book, of `size` (see `BookShape.size`), hangs before it slams into its
    /// place, seen by `camera` in a view of `view` points: in the middle of `area`, the part of
    /// the view the spread fills (`area(in:)`), facing the camera squarely, head up, as near as
    /// fills `snapWidth` of the area's width or `snapHeight` of its height, whichever comes
    /// first. Its cover lies parallel to the view, so it shows as a rectangle, as if held up to
    /// the viewer, also where the area's middle lies off the camera's axis. The book lies
    /// wholly within the area, and even the smallest, 1.7 units tall, hangs about 4 units from
    /// the camera, well past its near plane.
    static func snapTop(
        size: SIMD3<Float>, seenBy camera: PileCamera, in area: CGRect, of view: CGSize
    ) -> Transform {
        let slope = tan(PileCamera.fieldOfView / 2)
        let aspect = Float(view.width / view.height)
        let share = SIMD2(Float(area.width / view.width), Float(area.height / view.height))
        let depth =
            max(size.x / (snapWidth * share.x * aspect), size.y / (snapHeight * share.y))
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

    /// The pose `progress` of the way, from 0 to 1, from `from` to `to`: along the line between
    /// them, lifted on a parabola that peaks `peak` above the higher end at the middle, turning
    /// the shorter way, all eased with smootherstep so the book leaves and lands at rest.
    static func pose(from: Transform, to: Transform, peak: Float, progress: Float)
        -> Transform
    {
        let share = min(max(progress, 0), 1)
        let eased = DominoCameraRig.ease(share)
        let line = from.translation + (to.translation - from.translation) * eased
        let top = max(from.translation.y, to.translation.y) + peak
        let lift = (top - (from.translation.y + to.translation.y) / 2) * 4 * eased * (1 - eased)
        return Transform(
            scale: to.scale, rotation: turn(from.rotation, to: to.rotation, by: eased),
            translation: line + [0, lift, 0])
    }

    /// The last book's pose `time` seconds into its flourish, from `from`, where it lay, to
    /// `to`, its place: it springs up to `top`, fast at first and slowing to a stop there as it
    /// turns its cover to the camera, hangs a beat, drifting a little nearer and back, then
    /// slams down onto its place, speeding up hard all the way, as a book thrown down does. It
    /// lies flat by the last third of the drop, so it comes down flat onto the books under its
    /// place, and lands at full speed.
    static func snapPose(from: Transform, to: Transform, top: Transform, time: Float)
        -> Transform
    {
        if time < snapRise {
            let share = max(time, 0) / snapRise
            let eased = 1 - (1 - share) * (1 - share) * (1 - share)
            return Transform(
                scale: to.scale, rotation: turn(from.rotation, to: top.rotation, by: eased),
                translation: from.translation + (top.translation - from.translation) * eased)
        }
        let hang = (time - snapRise) / snapHang
        let drop = min(max((time - snapRise - snapHang) / snapDrop, 0), 1)
        let float = hang < 1 ? sin(.pi * hang) : 0
        let toward = top.rotation.act([0, 0, 1])
        return Transform(
            scale: to.scale,
            rotation: turn(
                top.rotation, to: to.rotation, by: DominoCameraRig.ease(min(drop * 1.5, 1))),
            translation: top.translation + toward * 0.25 * float * float
                + (to.translation - top.translation) * drop * drop * drop)
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
                * turn(roll, to: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), by: share),
            translation: camera.transform.translation)
    }

    /// `from` turned `share` of the way to `to`, the shorter way.
    private static func turn(_ from: simd_quatf, to: simd_quatf, by share: Float) -> simd_quatf {
        var turn = to * from.inverse
        if turn.real < 0 { turn = simd_quatf(vector: -turn.vector) }
        return turn.angle < 1e-4
            ? to : simd_quatf(angle: turn.angle * share, axis: turn.axis) * from
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
    static let lastFrameHold: Double = 5
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
        var throttle = ImpactThrottle(interval: 0.03)
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
