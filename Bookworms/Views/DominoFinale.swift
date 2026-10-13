import CoreGraphics
import Foundation
import RealityKit
import simd

/// The finale once every book has fallen (see `DominoScene`), timed from the moment the last
/// book falls.
///
/// At once, the camera starts one slow move from wherever it films to the spread's view, where
/// it comes to rest `moveTime` seconds later (`view(from:to:progress:)`). `gatherDelay` seconds
/// in, while the camera still moves, the books start to gather into a face-up spread
/// (`PileSpread`): each lifts off the desk, flies in an arc to its place, turning face up on
/// the way, and settles flat, one after another in the spread's order, so a book lands only
/// after the books it rests on. Every book but the spread's last has landed `settleMargin`
/// before the camera comes to rest. The last book waits where it fell; as the camera settles,
/// it springs up out of the spread toward the viewer, hangs there a beat, and slams down into
/// its place, landing `snapLanding` after the camera stops (`snapPose(from:to:top:time:)`).
/// The poses are pure functions of time, so tests and the offline renderer replay them.
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
    /// The last book's flourish: how long it takes to spring to the top of its arc, to hang
    /// there, and to drop into its place, in seconds, and how long after the camera comes to
    /// rest it lands.
    static let snapRise: Float = 0.45
    static let snapHang: Float = 0.3
    static let snapDrop: Float = 0.2
    static let snapLanding: Float = 0.2
    /// How far the last book springs from its place toward the spread's camera, as a share of
    /// the way: it rises toward the viewer, showing larger, where its place shows on screen.
    static let snapReach: Float = 0.45
    /// With Reduce Motion on, how long after the last book falls the camera cuts to the
    /// spread's view and the books appear in their places, in seconds.
    static let stillWait: Float = 1
    /// The room the heading takes at the top of a view `width` wide, which the spread leaves:
    /// 28 percent of the width, about 112 points on an iPhone and 300 pixels on a story
    /// clip, since `DominoFinaleCard` scales with the width.
    static func headingRoom(width: CGFloat) -> CGFloat { width * 0.28 }

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

    /// Where the last book hangs over its `place` before it slams into it, seen by `camera`.
    static func snapTop(over place: SIMD3<Float>, seenBy camera: PileCamera) -> SIMD3<Float> {
        place + (camera.transform.translation - place) * snapReach
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
    /// `to`, its place: it springs up and across to `top`, slowing to a stop there as it turns
    /// face up, hangs a beat, drifting on a little and back, then drops onto its place,
    /// speeding up as a falling book does, and lands at full speed.
    static func snapPose(from: Transform, to: Transform, top: SIMD3<Float>, time: Float)
        -> Transform
    {
        if time < snapRise {
            let share = max(time, 0) / snapRise
            let eased = 1 - (1 - share) * (1 - share)
            return Transform(
                scale: to.scale, rotation: turn(from.rotation, to: to.rotation, by: eased),
                translation: from.translation + (top - from.translation) * eased)
        }
        let hang = (time - snapRise) / snapHang
        let drop = min(max((time - snapRise - snapHang) / snapDrop, 0), 1)
        let float = hang < 1 ? sin(.pi * hang) : 0
        return Transform(
            scale: to.scale, rotation: to.rotation,
            translation: top + (top - to.translation) * 0.04 * float * float
                + (to.translation - top) * drop * drop)
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
    /// `glide(_:)`. It swings about the point it looks at on the table, so it cranes and pulls
    /// back in one sweep rather than sliding along a line: the point moves straight across the
    /// table, the turn and pitch change evenly, and the distance by an even ratio, so the zoom
    /// keeps one pace. Any roll `from` has eases out.
    static func view(from: Transform, to: PileCamera, progress: Float) -> Transform {
        let share = glide(progress)
        let forward = from.rotation.act([0, 0, -1])
        // A view that looks level or up meets the table nowhere; it turns about a point ahead.
        let reach =
            PileCamera.intersect((from.translation, forward), height: 0)
            .map { simd_distance($0, from.translation) } ?? PileCamera.distance
        let depth = min(max(reach, 1), 4 * PileCamera.distance)
        let start = PileCamera(
            target: from.translation + forward * depth, yaw: atan2(-forward.x, -forward.z),
            zoom: PileCamera.distance / depth, pitch: asin(min(max(-forward.y, -1), 1)))
        let camera = PileCamera(
            target: start.target + (to.target - start.target) * share,
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

/// The timeline of a dominoes video, which `PileSnapshotRenderer.renderDominoMovie` films:
/// the standing chain and the Follow camera's move down to the first book, the push, the run,
/// the landing and the reveal, the gathering, and the heading over the spread, within
/// `longest` seconds.
///
/// The frames come at `PileMovieTiming`'s rate. The chain's time runs faster than the frames
/// where the video would otherwise run long: the standing chain and the landing and reveal at
/// `hurry` times live speed, and the run at `speed(run:fixed:)`, so a long chain's fall plays
/// as a time lapse; the gathering and the hold play at live speed.
enum DominoMovieTiming {
    /// The longest a video gets, in seconds.
    static let longest: Float = 30
    /// How long the gathered books and the heading hold at the end, in seconds.
    static let hold: Float = 2.5
    /// How many times faster than live the standing chain and the landing and reveal play.
    static let hurry: Float = 2
    /// The most a run speeds up, so a very long chain still reads as books falling.
    static let fastest: Float = 4
    /// The most seconds of frames a render makes, whatever the chain does.
    static let cap: Float = 40

    /// How many times faster than live the run plays, so that it fits in `longest` less the
    /// `fixed` seconds the rest takes, at least 5 seconds, and within `fastest`.
    static func speed(run: Float, fixed: Float) -> Float {
        min(fastest, max(1, run / max(longest - fixed, 5)))
    }

    /// The seconds a chain `length` units long takes to fall live, at the Follow camera's
    /// typical pace.
    static func runEstimate(length: Float) -> Float { length / DominoCameraRig.typicalPace }
}
