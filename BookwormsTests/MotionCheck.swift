import CoreGraphics
import RealityKit
import XCTest

@testable import Bookworms

/// One moment of a book's motion as the viewer sees it.
struct MotionSample {
    /// The screen points of the book's drawn corners, in the same order in every sample of a
    /// trace.
    var points: [CGPoint]
    /// What else shows, from 0 to 1, in the same order in every sample: for a SwiftUI book, its
    /// shading, shadow, and veil (`PullOutPath.Pose`).
    var levels: [Double] = []
}

/// The tolerances and projection that motion checks share.
///
/// A check samples a motion densely: every 1e-4 of progress for a SwiftUI path, and every
/// `fine` seconds for a function of time. A jump keeps its size however fine the sampling,
/// while smooth motion's second difference shrinks with the square of the step, so one
/// tolerance tells them apart at any speed.
enum MotionCheck {
    /// How far a handoff may move any point, and how far any point's second difference may
    /// reach: a pixel at 2x.
    static let handoff: CGFloat = 0.5
    /// How much a handoff may change any level, and how far a level's second difference may
    /// reach.
    static let level = 0.02
    /// The step for functions of time, in seconds.
    static let fine: Float = 0.001
    /// An iPhone's view in portrait, in points.
    static let viewport = CGSize(width: 402, height: 874)

    /// Where `point` shows in `viewport`, in points, to a camera at `camera` with the scenes'
    /// vertical field of view (`PileCamera.fieldOfView`).
    static func project(_ point: SIMD3<Float>, camera: Transform) -> CGPoint {
        let local = camera.rotation.inverse.act(point - camera.translation)
        let aspect = Float(viewport.width / viewport.height)
        let ndc = SIMD2(local.x / aspect, local.y) / (-local.z * tan(PileCamera.fieldOfView / 2))
        return CGPoint(
            x: CGFloat(ndc.x + 1) / 2 * viewport.width,
            y: CGFloat(1 - ndc.y) / 2 * viewport.height)
    }

    /// The eight corners of a box of `size` at `transform`, projected (`project`).
    static func sample(
        _ transform: Transform, size: SIMD3<Float>, camera: Transform
    ) -> MotionSample {
        let signs: [Float] = [-1, 1]
        let corners = signs.flatMap { x in
            signs.flatMap { y in signs.map { z in SIMD3(x, y, z) * size / 2 } }
        }
        return MotionSample(
            points: corners.map {
                project(transform.translation + transform.rotation.act($0), camera: camera)
            })
    }
}

/// Fails unless the motion's first sample draws the book where its resting copy did: every
/// point within `MotionCheck.handoff`, and every level within `MotionCheck.level`.
@MainActor
func assertHandoff(
    _ rest: MotionSample, _ first: MotionSample, _ what: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard rest.points.count == first.points.count, rest.levels.count == first.levels.count
    else {
        return XCTFail("\(what): the samples draw different corners", file: file, line: line)
    }
    let moved = zip(rest.points, first.points).map { hypot($0.x - $1.x, $0.y - $1.y) }
    let changed = zip(rest.levels, first.levels).map { abs($0 - $1) }
    let farthest = moved.max() ?? 0
    let most = changed.max() ?? 0
    guard farthest > MotionCheck.handoff || most > MotionCheck.level else { return }
    attach([rest, first], marking: [1], what)
    var found = [
        String(format: "point %d moves %.3f pt", moved.firstIndex(of: farthest) ?? 0, farthest)
    ]
    if let level = changed.firstIndex(of: most) {
        found.append(String(format: "level %d changes %.4f", level, most))
    }
    XCTFail("\(what): \(found.joined(separator: ", "))", file: file, line: line)
}

/// Fails where any point's second difference exceeds `within`, or any level's exceeds
/// `MotionCheck.level`, except at `cuts`: the samples beside a declared discontinuity.
@MainActor
func assertContinuous(
    _ trace: [MotionSample], cuts: Set<Int> = [], within: CGFloat = MotionCheck.handoff,
    _ what: String, file: StaticString = #filePath, line: UInt = #line
) {
    guard let first = trace.first,
        trace.allSatisfy({
            $0.points.count == first.points.count && $0.levels.count == first.levels.count
        })
    else { return XCTFail("\(what): the samples draw different corners", file: file, line: line) }
    var failing = Set<Int>()
    var worst = (point: CGFloat(0), level: 0.0, at: 0)
    for index in trace.indices.dropFirst().dropLast() where !cuts.contains(index) {
        let (before, now, after) = (trace[index - 1], trace[index], trace[index + 1])
        let point =
            now.points.indices
            .map { corner in
                hypot(
                    after.points[corner].x - 2 * now.points[corner].x + before.points[corner].x,
                    after.points[corner].y - 2 * now.points[corner].y + before.points[corner].y)
            }
            .max() ?? 0
        let level =
            now.levels.indices
            .map {
                abs(after.levels[$0] - 2 * now.levels[$0] + before.levels[$0])
            }
            .max() ?? 0
        if point > within || level > MotionCheck.level { failing.insert(index) }
        if point > worst.point { worst.at = index }
        worst = (max(point, worst.point), max(level, worst.level), worst.at)
    }
    guard let jump = failing.min() else { return }
    attach(trace, marking: failing, what)
    XCTFail(
        String(
            format: "%@: %d samples jump, the first at %d; second differences reach %.3f pt"
                + " (at %d) and %.4f in level",
            what, failing.count, jump, worst.point, worst.at, worst.level),
        file: file, line: line)
}

/// Fails unless every point's velocity agrees on both sides of `index`, a seam where the code
/// claims the motion's velocity is continuous: the velocities over one `step`, in seconds,
/// before and after it agree within 10% of the larger speed plus 5 points a second.
@MainActor
func assertSeam(
    _ trace: [MotionSample], at index: Int, step: Double, _ what: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard index > 0, index < trace.count - 1 else {
        return XCTFail("\(what): no samples on both sides of \(index)", file: file, line: line)
    }
    let (before, now, after) = (trace[index - 1], trace[index], trace[index + 1])
    for corner in now.points.indices {
        let inward = CGVector(
            dx: (now.points[corner].x - before.points[corner].x) / step,
            dy: (now.points[corner].y - before.points[corner].y) / step)
        let outward = CGVector(
            dx: (after.points[corner].x - now.points[corner].x) / step,
            dy: (after.points[corner].y - now.points[corner].y) / step)
        let change = hypot(outward.dx - inward.dx, outward.dy - inward.dy)
        let speed = max(hypot(inward.dx, inward.dy), hypot(outward.dx, outward.dy))
        guard change > 0.1 * speed + 5 else { continue }
        attach(trace, marking: [index], what)
        return XCTFail(
            String(
                format: "%@: point %d's velocity changes by %.1f pt/s at sample %d, at %.1f pt/s",
                what, corner, change, index, speed),
            file: file, line: line)
    }
}

/// Attaches `trace` as a CSV, one row per sample with the `marked` samples flagged, so a
/// failure can be read without a rerun.
@MainActor
private func attach(_ trace: [MotionSample], marking marked: Set<Int>, _ what: String) {
    guard let first = trace.first else { return }
    let header =
        ["sample", "marked"] + first.points.indices.flatMap { ["x\($0)", "y\($0)"] }
        + first.levels.indices.map { "level\($0)" }
    let rows = trace.enumerated()
        .map { index, sample in
            ([String(index), marked.contains(index) ? "1" : "0"]
                + sample.points.flatMap { ["\($0.x)", "\($0.y)"] } + sample.levels.map { "\($0)" })
                .joined(separator: ",")
        }
    let attachment = XCTAttachment(
        data: Data(([header.joined(separator: ",")] + rows).joined(separator: "\n").utf8),
        uniformTypeIdentifier: "public.comma-separated-values-text")
    attachment.name = "\(what).csv"
    XCTContext.runActivity(named: what) { $0.add(attachment) }
}
