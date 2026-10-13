import CoreGraphics
import Foundation
import RealityKit
import simd

/// How the fallen books gather into a face-up spread once the chain is done (see
/// `DominoScene`): each book lifts off the desk, flies in an arc to its place in the spread,
/// turning face up on the way, and settles flat, one after another in the spread's order, so
/// a book lands only after the books it rests on (`PileSpread`). The poses are pure functions
/// of time, so tests and the offline renderer replay them.
enum DominoFinale {
    /// How long each book's flight takes, in seconds.
    static let flightTime: Float = 1.4
    /// The latest a flight starts after the first, in seconds, so a long chain gathers in a
    /// wave rather than one book at a time, and the most time from one start to the next, for
    /// a short chain.
    static let spreadTime: Float = 3.5
    static let longestStep: Float = 0.12
    /// How high a flight's arc peaks above the higher of its ends, in units, and how much
    /// higher every fourth book's does, so books in the air at once cross at different heights.
    static let rise: Float = 2.6
    static let riseStep: Float = 0.4
    /// The seconds a done chain waits before it gathers, with the Overview camera, which eases
    /// back to the whole path meanwhile; the Follow camera gathers once its reveal ends.
    static let overviewWait: TimeInterval = 2.5
    /// The room the heading takes at the top of a view `width` wide, which the spread leaves:
    /// 28 percent of the width, about 112 points on an iPhone and 300 pixels on a story
    /// clip, since `DominoFinaleCard` scales with the width.
    static func headingRoom(width: CGFloat) -> CGFloat { width * 0.28 }

    /// The seconds from one flight's start to the next: `longestStep`, or less so that every
    /// flight of `count` starts within `spreadTime`.
    static func step(count: Int) -> Float {
        min(longestStep, spreadTime / Float(max(count - 1, 1)))
    }

    /// When the flight of the book at `index` of `count` starts, in seconds from the first.
    static func start(of index: Int, count: Int) -> Float { Float(index) * step(count: count) }

    /// How long the whole gathering takes: the last flight's end.
    static func duration(count: Int) -> Float {
        count == 0 ? 0 : start(of: count - 1, count: count) + flightTime
    }

    /// How high the arc of the book at `index` peaks above the higher of its ends.
    static func peak(of index: Int) -> Float { rise + riseStep * Float(index % 4) }

    /// The pose `progress` of the way, from 0 to 1, from `from` to `to`: along the line between
    /// them, lifted on a parabola that peaks `peak` above the higher end at the middle, turning
    /// the shorter way, all eased with smootherstep so the book leaves and lands at rest.
    static func pose(from: Transform, to: Transform, peak: Float, progress: Float)
        -> Transform
    {
        let share = min(max(progress, 0), 1)
        let eased = share * share * share * (share * (share * 6 - 15) + 10)
        let line = from.translation + (to.translation - from.translation) * eased
        let top = max(from.translation.y, to.translation.y) + peak
        let lift = (top - (from.translation.y + to.translation.y) / 2) * 4 * eased * (1 - eased)
        var turn = to.rotation * from.rotation.inverse
        if turn.real < 0 { turn = simd_quatf(vector: -turn.vector) }
        let rotation =
            turn.angle < 1e-4
            ? to.rotation : simd_quatf(angle: turn.angle * eased, axis: turn.axis) * from.rotation
        return Transform(
            scale: to.scale, rotation: rotation, translation: line + [0, lift, 0])
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
