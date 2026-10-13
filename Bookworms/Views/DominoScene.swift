import Combine
import CoreMedia
import RealityKit
import SwiftUI
import UIKit

/// A book's place in the domino chain.
struct DominoSlot {
    let book: CloudBook
    /// The book's size as `BookShape` gives it for a 2:3 cover. Its height and thickness do not
    /// depend on the cover, so they match the built book's.
    let size: SIMD3<Float>
    /// The whole days from the chain's first finish to this book's, so the days between any
    /// two books are the difference of theirs.
    let day: Int
    /// How far along the path the book's middle stands.
    let distance: Float
    /// Where the book stands on the table, as x and z.
    var position: SIMD2<Float>
    /// The direction the chain runs at the book, a unit vector in x and z.
    let heading: SIMD2<Float>
}

/// A path that winds across the table in rows `2 * radius` apart, joined by half turns.
///
/// The first row runs from left to right at the far side of the table, the next one back from
/// right to left, nearer the camera, and so on. Each row has a length of its own: `rowLengths`
/// gives them in order, and rows past the last given keep its length, so a path of one length
/// winds on without end. The first row starts at (-`rowLengths[0]` / 2, 0) in x and z. Each
/// turn is a half circle `radius` past the row's end, toward the next row, and the next row
/// starts where the turn ends and runs back. Distances run along the path from the start of
/// the first row; rows advance toward +z, the camera.
struct DominoPath: Equatable {
    let rowLengths: [Float]
    let radius: Float
    /// Where each given row starts, as a distance along the path and an x on the table.
    private let starts: [Float]
    private let origins: [Float]

    init(rowLengths: [Float], radius: Float = DominoLayout.turnRadius) {
        let lengths = rowLengths.isEmpty ? [DominoLayout.shortestRow] : rowLengths
        self.rowLengths = lengths
        self.radius = radius
        var starts: [Float] = []
        var origins: [Float] = []
        var start: Float = 0
        var x = -lengths[0] / 2
        for (index, length) in lengths.enumerated() {
            starts.append(start)
            origins.append(x)
            start += length + .pi * radius
            x += (index.isMultiple(of: 2) ? 1 : -1) * length
        }
        self.starts = starts
        self.origins = origins
    }

    /// A path whose every row is `rowLength` long.
    init(rowLength: Float, radius: Float = DominoLayout.turnRadius) {
        self.init(rowLengths: [rowLength], radius: radius)
    }

    /// The first row's length, and the length of a row and the turn after it: every row's when
    /// the rows are alike.
    var rowLength: Float { rowLengths[0] }
    var period: Float { period(0) }

    /// The length of row `row`, counting from 0.
    func rowLength(_ row: Int) -> Float { rowLengths[min(row, rowLengths.count - 1)] }

    /// The length of row `row` and the turn after it.
    func period(_ row: Int) -> Float { rowLength(row) + .pi * radius }

    /// The distance along the path at which row `row` starts.
    func start(ofRow row: Int) -> Float {
        let last = rowLengths.count - 1
        guard row > last else { return starts[row] }
        return starts[last] + Float(row - last) * period(last)
    }

    /// The row that `distance` lies on, or on the turn after, and how far along the row it lies.
    func row(at distance: Float) -> (row: Int, along: Float) {
        let distance = max(distance, 0)
        let last = rowLengths.count - 1
        if distance < starts[last] + period(last) {
            let row = starts.lastIndex { $0 <= distance } ?? 0
            return (row, distance - starts[row])
        }
        let beyond = Int((distance - starts[last]) / period(last))
        return (last + beyond, distance - starts[last] - Float(beyond) * period(last))
    }

    /// Whether `distance` lies on a turn.
    func isTurning(at distance: Float) -> Bool {
        let (row, along) = self.row(at: distance)
        return along > rowLength(row)
    }

    /// The point `distance` along the path, and the path's direction there as a unit vector.
    func point(at distance: Float) -> (position: SIMD2<Float>, heading: SIMD2<Float>) {
        let (row, along) = self.row(at: distance)
        let direction: Float = row.isMultiple(of: 2) ? 1 : -1
        let x = origin(ofRow: row)
        let z = Float(row) * 2 * radius
        let length = rowLength(row)
        guard along > length else { return ([x + direction * along, z], [direction, 0]) }
        let angle = (along - length) / radius
        let end = x + direction * length
        return (
            [end + direction * radius * sin(angle), z + radius * (1 - cos(angle))],
            [direction * cos(angle), sin(angle)]
        )
    }

    /// The x at which row `row` starts. Past the given rows, the rows alternate between the
    /// last row's ends.
    private func origin(ofRow row: Int) -> Float {
        let last = rowLengths.count - 1
        guard row > last else { return origins[row] }
        let direction: Float = last.isMultiple(of: 2) ? 1 : -1
        return (row - last).isMultiple(of: 2)
            ? origins[last] : origins[last] + direction * rowLengths[last]
    }
}

/// The chain's path and where each book stands on it, centered on the table.
struct DominoPlan {
    let path: DominoPath
    let slots: [DominoSlot]
    /// Half the span of the books' middles in x and z, about the table's center.
    let extent: SIMD2<Float>
}

/// Where the dominoes stand: in finish order along a winding path, evenly spaced for their
/// heights, so one push topples the whole chain. Time does not space the books; a cobweb marks
/// each long gap between finishes instead. Scene units are decimeters, as in the pile.
enum DominoLayout {
    /// The most books a chain stands: the most recently finished.
    static let maximumBooks = 300
    /// The days without a finish that string a cobweb between two books.
    static let cobwebDays = 30
    /// The days at and past which a cobweb is as dense as it gets (see `cobweb(days:)`).
    static let densestCobwebDays = 240
    /// The turns' radius, half the distance between rows. It exceeds half the widest book, so
    /// books on a turn keep their inner corners apart (see `turnSpacing`).
    static let turnRadius: Float = 2
    static let shortestRow: Float = 6
    /// How deep the rows may reach, and the longest a row may be. The longest chain, 300 of the
    /// thickest and longest books, runs about 410 units, which fits in rows well short of this,
    /// so the path and the books that fall past its ends stay on the 90-unit table.
    static let deepest: Float = 72
    /// The space a turn keeps between the inner corners of neighboring books.
    static let clearance: Float = 0.05

    /// The gap from a book's back cover to the next book's front cover, as a share of the
    /// first book's height.
    static let spacing: Float = 0.3
    /// How long a book takes to drop into its place as the chain stands up, in seconds.
    static let entryFall: TimeInterval = 0.35
    /// How long a cobweb takes to fade in once the book behind it lands, in seconds.
    static let webFade: TimeInterval = 0.25
    /// The latest a book of the chain starts its drop after the first, in seconds.
    static let entrySpread: TimeInterval = 1.2

    /// The seconds from one book's drop to the next one's down a chain of `count` books: 0.05, or
    /// less in a chain too long for that, so every drop starts within `entrySpread` of the first.
    static func entryStep(count: Int) -> TimeInterval {
        min(0.05, entrySpread / Double(max(count - 1, 1)))
    }

    /// How much longer than a book takes to build the drops wait from one to the next, so the
    /// books waiting to drop build up while later books build, and the longest they wait.
    static let buildMargin: Double = 1.15
    static let slowestStep: TimeInterval = 0.08

    /// The seconds from one drop to the next down a chain of `count` books that have taken
    /// `perBook` seconds each to build on average: `entryStep(count:)`, or `buildMargin` times
    /// the build time when that is longer, up to `slowestStep`. The drops then run on steadily,
    /// a little slower than the books build, instead of a batch at once and then a pause while
    /// the next builds, and a chain built at once still drops within `entrySpread`.
    static func entryStep(count: Int, perBook: TimeInterval) -> TimeInterval {
        max(entryStep(count: count), min(slowestStep, perBook * buildMargin))
    }

    /// The gap from the back cover of a book of `height` to the next book's front cover on a
    /// row: `spacing` times the height, whatever the days between their finishes.
    ///
    /// A toppling book pivots on its leading bottom edge, the back cover's, so its head reaches
    /// at most `height` past that edge: its reach. At 30 percent of its height, the falling
    /// book strikes the next one about 95 percent of its own height up, or at the next book's
    /// top edge when that book is shorter, so every pair of sizes knocks over: a short book
    /// strikes a doorstopper more than half way up it.
    static func gap(height: Float) -> Float { height * spacing }

    /// How dense a cobweb hangs over a gap of `days` between two finishes: `nil` under
    /// `cobwebDays`, then from 0 at `cobwebDays` to 1 at `densestCobwebDays` or more, by equal
    /// steps for each doubling of the gap.
    static func cobweb(days: Int) -> Float? {
        guard days >= cobwebDays else { return nil }
        let doublings = log2(Float(densestCobwebDays) / Float(cobwebDays))
        return min(1, log2(Float(days) / Float(cobwebDays)) / doublings)
    }

    /// `books` in finish order, oldest first, with the whole days from each finish to the next.
    /// Books without a finish date, such as current reads, stand last, and the days to and
    /// between them are 0, since they mark no gap between finishes. Books finished on the same
    /// day stand in ID order, so the order of `books` does not matter. Past `maximumBooks`, only
    /// the most recent books stand. The last book's days are 0.
    static func chain(_ books: [CloudBook]) -> [(book: CloudBook, days: Int)] {
        let ordered = Array(
            books.sorted {
                ($0.finishedDate ?? .distantFuture, $0.id) < (
                    $1.finishedDate ?? .distantFuture, $1.id
                )
            }
            .suffix(maximumBooks))
        return ordered.indices.map { index in
            guard index + 1 < ordered.count, let date = ordered[index].finishedDate,
                let next = ordered[index + 1].finishedDate
            else { return (ordered[index], 0) }
            return (ordered[index], max(0, Int((next.timeIntervalSince(date) / 86_400).rounded())))
        }
    }

    /// Stands `chain` along a path centered on the table: the silhouette of one of the app
    /// icon's worms for a chain long enough (`wormRowLengths(for:)`), and otherwise even rows
    /// whose width is about `aspect` times their depth, such as the visible table's.
    ///
    /// Each book's middle stands half its thickness, `gap(height:)`, and half the next book's
    /// thickness from the next book's along the path. On a turn the books fan out, so they stand
    /// farther apart where their inner corners would otherwise touch (see `turnSpacing`).
    static func plan(_ chain: [(book: CloudBook, days: Int)], aspect: Float) -> DominoPlan {
        let sizes = chain.map { BookShape(of: $0.book, coverAspect: 2 / 3).size }
        let spacings = chain.indices.dropLast()
            .map { index in
                (sizes[index].z + sizes[index + 1].z) / 2 + gap(height: sizes[index].y)
            }
        let length = spacings.reduce(0, +)
        let path =
            wormRowLengths(for: length).map { DominoPath(rowLengths: $0) }
            ?? DominoPath(rowLength: rowLength(for: length, aspect: aspect))
        var slots: [DominoSlot] = []
        var distance: Float = 0
        var day = 0
        for (index, link) in chain.enumerated() {
            if index > 0 {
                day += chain[index - 1].days
                let previous = distance
                distance += spacings[index - 1]
                if path.isTurning(at: previous) || path.isTurning(at: distance) {
                    distance =
                        previous
                        + max(spacings[index - 1], turnSpacing(sizes[index - 1], sizes[index]))
                }
            }
            let point = path.point(at: distance)
            slots.append(
                DominoSlot(
                    book: link.book, size: sizes[index], day: day, distance: distance,
                    position: point.position, heading: point.heading))
        }
        guard let first = slots.first?.position else {
            return DominoPlan(path: path, slots: [], extent: .zero)
        }
        let low = slots.map(\.position).reduce(first, pointwiseMin)
        let high = slots.map(\.position).reduce(first, pointwiseMax)
        for index in slots.indices { slots[index].position -= (low + high) / 2 }
        return DominoPlan(path: path, slots: slots, extent: (high - low) / 2)
    }

    /// The length of each row for a path of `length`, so the path's width is about `aspect`
    /// times its depth, and its rows reach no deeper than `deepest`, unless that takes rows
    /// longer than `deepest`: rows stop at that length, and the path reaches deeper.
    ///
    /// Rows of length L, each taking L plus a half turn of the path, span L + 2R across and
    /// about 2R for each row in depth, where R is `turnRadius`. The aspect fit solves
    /// (L + 2R)(L + πR) = 2R × aspect × length for L.
    static func rowLength(for length: Float, aspect: Float) -> Float {
        let radius = turnRadius
        let b = (2 + Float.pi) * radius
        let fitted =
            ((b * b - 8 * .pi * radius * radius + 8 * radius * aspect * length).squareRoot() - b)
            / 2
        let shallow = 2 * radius * length / deepest - .pi * radius
        return min(deepest, max(shortestRow, fitted, shallow))
    }

    /// The worm's shape, from the app icon, in head radii: its height from the top of the
    /// head, and how much its body narrows at the bottom, which the icon's book hides.
    static let wormHeight: Float = 3.48
    static let wormTaper: Float = 0.1
    /// How far below the top of the head the first row lies.
    static let wormHeadInset: Float = 2.4
    /// The fewest rows that read as the worm's shape: about 54 units of chain, or 60 books of
    /// typical thickness. A shorter chain winds in even rows.
    static let wormRows = 5

    /// The rows that fill the silhouette of one of the app icon's worms with a chain `length`
    /// long, head first, or `nil` for a chain too short to read as the shape (`wormRows`).
    ///
    /// The worm stands upright on the screen as in the icon, its semicircular head at the far
    /// side of the table and its body narrowing a little toward the bottom. Rows lie
    /// `2 * turnRadius` apart from `wormHeadInset` below the top of the head. Each row runs
    /// between the outline's two sides, less the turn's bulge of `turnRadius` past each end, so
    /// the turns reach the outline: the first row's length is twice its half-width, and each
    /// later row's the half-widths of it and the row before, since a row starts where the turn
    /// from the row before ends. The head's radius is found by bisection so that the rows and
    /// their turns just hold the chain, which ends partway along the last row, as the icon's
    /// worms end behind the book.
    static func wormRowLengths(for length: Float) -> [Float]? {
        func rows(headRadius radius: Float) -> (lengths: [Float], total: Float) {
            let height = wormHeight * radius
            var halves: [Float] = []
            var depth = wormHeadInset
            while depth <= height {
                let outline =
                    depth <= radius
                    ? (2 * radius * depth - depth * depth).squareRoot()
                    : radius * (1 - wormTaper * (depth - radius) / (height - radius))
                halves.append(max(outline - turnRadius, 0.5))
                depth += 2 * turnRadius
            }
            let lengths = halves.indices.map {
                $0 == 0 ? 2 * halves[0] : halves[$0 - 1] + halves[$0]
            }
            let total = lengths.reduce(0, +) + Float(lengths.count - 1) * .pi * turnRadius
            return (lengths, total)
        }
        var (low, high): (Float, Float) = (2, 60)
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if rows(headRadius: middle).total < length { low = middle } else { high = middle }
        }
        let fitted = rows(headRadius: high)
        return fitted.lengths.count >= wormRows ? fitted.lengths : nil
    }

    /// A domino's mass in kilograms: 0.2 per unit of `height`, whatever the book's thickness.
    ///
    /// Neighbors then weigh within a factor of 1.7 of each other. A book as heavy as paper of
    /// its volume can weigh a sixth as much as the next one, and bounces back off it instead
    /// of knocking it over.
    static func mass(height: Float) -> Float { 0.2 * height }

    /// The widest a book of `height` can be: as wide as the widest cover aspect that
    /// `Book3DView.aspect(of:)` allows, rounded up to the next mesh step.
    static func widest(_ height: Float) -> Float { height * 0.85 + BookShape.step.x }

    /// The least distance along a turn between the middles of books of sizes `a` and `b`.
    ///
    /// Books on a turn fan out from its middle, so their facing covers come closest at their
    /// inner corners, `turnRadius` less half the book's width from the middle. There, the arc
    /// between the books' middles shrinks in proportion to the radius, while their thicknesses
    /// do not.
    static func turnSpacing(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let inner = turnRadius - max(widest(a.y), widest(b.y)) / 2
        return turnRadius * ((a.z + b.z) / 2 + clearance) / inner
    }

    /// Points that bound the books of `slots` standing and fallen, for framing them: each
    /// book's footprint across the path, at the table and at its height, and the corners of
    /// its head where it lands, its height past its leading bottom edge along its heading. On
    /// a turn, that lies off the path, to the outside of the turn.
    static func outline(of slots: [DominoSlot]) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(slots.count * 6)
        for slot in slots {
            let across = SIMD2(-slot.heading.y, slot.heading.x) * slot.size.x / 2
            let landing = slot.position + slot.heading * (slot.size.y + slot.size.z / 2)
            for side in [-across, across] {
                let standing = slot.position + side
                points.append([standing.x, 0, standing.y])
                points.append([standing.x, slot.size.y, standing.y])
                points.append([landing.x + side.x, 0, landing.y + side.y])
            }
        }
        return points
    }

    /// The book a push tips, given `next`, the first of `count` books that has not fallen.
    ///
    /// It is the first book from `next` that stands upright, looking at most two books past
    /// `next`, or the last book looked at. A book that leans on the one after it without
    /// knocking it over is not upright: pushing it again would only press it against that
    /// book, so the push tips the book it leans on instead, and each push moves the chain on.
    static func pushTarget(next: Int, count: Int, isUpright: (Int) -> Bool) -> Int {
        var index = next
        while index + 1 < min(count, next + 3), !isUpright(index) { index += 1 }
        return index
    }

    /// The chain's phase once every book stands, given `next`, the first of `count` books that
    /// has not fallen; whether a push or a book falling on its own has `started` the chain; and
    /// whether no book has started to fall for a while (`settled`).
    ///
    /// Once no book is left standing, the chain is running or done, whether or not it was
    /// pushed, so a chain without books, or one that fell on its own, never waits for a push.
    static func phase(next: Int, count: Int, started: Bool, settled: Bool) -> DominoPhase {
        if next >= count { return settled ? .done : .running }
        guard started else { return .standing }
        return settled ? .stalled(fallen: next) : .running
    }

    /// Whether a book lifted out of the chain from `index` stands in its place again when it
    /// returns, rather than being thrown back, given `next`, the first book that has not
    /// fallen. `place` is the box the book stands in, and `others` the other books' bounds, in
    /// the frame of the book's standing pose (`standingPose(of:)`), whose y axis points up.
    ///
    /// It stands again when it had not fallen, at or past the front, and no other book reaches
    /// into its place or over it. A book that had fallen is thrown back. So is a book whose place
    /// another book has filled, such as the book before it, fallen in: standing in that place,
    /// it would start inside that book, and the two would fly apart.
    static func standsAgain(index: Int, next: Int, place: BoundingBox, others: [BoundingBox])
        -> Bool
    {
        index >= next && BookFlight.disturbed(by: place, among: others, margin: 0).isEmpty
    }

    /// The pose of the book of `slot` standing in its place, a hair above the table, so it
    /// settles onto the table rather than starting inside it.
    static func standingPose(of slot: DominoSlot) -> Transform {
        Transform(
            rotation: standing(heading: slot.heading),
            translation: [slot.position.x, slot.size.y / 2 + 0.002, slot.position.y])
    }

    /// A book standing on its tail with its front cover facing back along `heading`, so it
    /// falls onto its back cover with the cover up. Its axes run spine to fore edge, tail to
    /// head, and back to front cover, as `BookShape` lays them out.
    static func standing(heading: SIMD2<Float>) -> simd_quatf {
        let up: SIMD3<Float> = [0, 1, 0]
        let front = -SIMD3(heading.x, 0, heading.y)
        return simd_quatf(simd_float3x3(columns: (simd_cross(up, front), up, front)))
    }
}

/// How far the chain has fallen.
enum DominoPhase: Equatable {
    /// The books are being built and stood up.
    case settingUp
    /// Every book stands, waiting for the first push.
    case standing
    /// Books are falling.
    case running
    /// The chain stopped after `fallen` books, where a book stayed standing, such as one that
    /// leans on the next book without knocking it over.
    case stalled(fallen: Int)
    /// Every book has fallen.
    case done
    /// The fallen books are gathering into the spread (`DominoFinale`).
    case gathering
    /// The books lie in the spread under the heading.
    case finished

    /// Whether the chain has run its course, and the books are gathering or lie gathered.
    var hasEnded: Bool { self == .gathering || self == .finished }

    /// Whether the chain waits for a push: before the first one, or after it stopped.
    var waitsForPush: Bool {
        switch self {
        case .standing, .stalled: true
        default: false
        }
    }
}

/// The chain's phase and its number of cobwebs, kept apart from the scene so that views update
/// only when they change.
@MainActor @Observable
final class DominoStatus {
    fileprivate(set) var phase = DominoPhase.settingUp
    /// The cobwebs hanging in the chain, each over a gap of `DominoLayout.cobwebDays` or more
    /// between finishes, torn or not.
    fileprivate(set) var cobwebs = 0
}

/// The dominoes' RealityKit content: the desk and its lamp (`DeskStage`), whose pool of light
/// covers the path, one rigid body per book (`BookFactory`), standing where `DominoLayout`
/// places it, and a cobweb (`Cobweb`) between each pair of books whose finishes lie
/// `DominoLayout.cobwebDays` or more apart.
///
/// The simulation runs in slow motion, at `slowMotion` of real time, except while a book flies
/// to or from its details. Frame times, such as the books' drops into place, the stall time, and
/// the cameras, stay in real time.
///
/// As the chain stands up, its books drop one after another down the path from above the top
/// of the view onto their places, and each cobweb fades in once the book behind it lands. With
/// Reduce Motion on, they appear standing. The chain waits for a push once every book stands.
///
/// The chain's front is the book after the last one that tilted past about 26 degrees. Each
/// frame checks only the next three books, so the work per frame does not grow with the
/// chain, and a book that the chain skips counts as passed. A book that falls before the first
/// push starts the chain as a push does. The chain is stalled once its front has not moved
/// on for `stallTime`: no book has started to fall, and the book at the front has stopped
/// tipping, so a slow first tip after a push does not count as a stall. While the chain waits
/// for a push, a pointing hand floats before the book a push tips (`DominoLayout.pushTarget`),
/// hovering with a faint glow behind it (see `updateHand`).
///
/// The camera follows `DominoCameraMode`. Overview frames the whole path; after a push it eases
/// a little closer, to at most `followRoom` times the overview's zoom, and across the rows with
/// the front where the path is deeper than the view. Follow hands the camera to
/// `DominoCameraRig`, built once the books stand, which chases the falling front low and close.
/// Both cameras run while the chain runs, so switching between them blends from one moving view
/// to the other, over a time that keeps the blend's turn and travel gentle. A pinch or drag
/// takes over from either, from the view as it shows, until the next push. With Reduce Motion
/// on, the camera follows nothing, and Follow shows the overview. Once every book has fallen,
/// the finale takes the camera to the gathered books (see `updateFinale`).
///
/// Once the chain has started, a cobweb tears when either of its books tilts past `tearTilt`,
/// as the near book's back cover starts to sweep into it. Like the front, each frame checks
/// only the webs near the front.
///
/// A book lifted to its details (`BookLifter`) tears the cobwebs it holds, and the Follow camera
/// no longer pushes in on them. While it flies, the chain counts it as standing in its place, so
/// its flight neither moves the front on nor starts the chain, and the camera modes give the
/// camera to the flight (see `aim`), which brings it back to them as the book returns. A book
/// the chain has not reached stands in its place again when it returns, while no other book
/// fills that place (`DominoLayout.standsAgain`): it is set down rather than thrown, so it
/// knocks nothing over and does not push the chain. Any other book is thrown back into the
/// books around its place, more softly than in the pile, which has walls to stop it.
@MainActor
final class DominoScene {
    /// The scene root, which runs the physics simulation.
    let root = Entity()
    /// Haptics and sounds for collisions, which `DominoesView` starts and stops.
    let feedback = ImpactFeedback()
    let status = DominoStatus()
    /// Set from a new chain's plan until its first books start to drop in (see `planSetUp`).
    let loading = SceneLoading()
    /// The flight of a book lifted to its details.
    let lifter: BookLifter

    /// How far beside a lifted book its rise clears the books (`BookFlight.rise`): past the
    /// widest gap to a standing neighbor (`DominoLayout.gap`), and short of the books past them.
    private static let riseMargin = DominoLayout.gap(height: BookShape.longest) + 0.05
    /// The share of real time the simulation runs at: a uniform slow motion, as film shot at a
    /// higher frame rate shows. Gravity, the push, and every collision slow together, so the
    /// books fall as they would at full speed, only slower.
    static let slowMotion: Double = 0.8
    /// How fast a push tips a book forward, in radians per second.
    private static let pushSpeed: Float = 2.5
    private static let stallTime: TimeInterval = 1
    /// The cosine of the tilt past which a book counts as fallen.
    private static let fallenTilt: Float = 0.9
    /// The overview's zoom as a share of the zoom that fits the path, so the path has room
    /// around it, and the Follow camera's opening view's.
    private static let overviewRoom: Float = 0.88
    private static let openingRoom: Float = 0.9
    /// The most the overview camera eases in past the overview while the chain falls, as a
    /// share of the overview's zoom, so the fallen books keep their room in the view.
    private static let followRoom: Float = 1.05
    /// How fast a blend from one camera to another turns and travels on average, in radians
    /// and units per second, and the shortest and longest it takes, in seconds.
    private static let handoffTurnRate: Float = 0.3
    private static let handoffSpeed: Float = 15
    private static let handoffTime: ClosedRange<Float> = 0.7...5
    private static let coverWait = Duration.seconds(1.5)
    /// How many books are built and stood up at a time.
    private static let batchSize = 16
    /// The cosine of the tilt under which a book counts as upright, about 6 degrees: more
    /// than a book rocks when it stands up, and less than it leans against the next book.
    private static let uprightTilt: Float = 0.995
    /// The cosine of the tilt past which a book tears its cobwebs, about 3 degrees, as soon as
    /// its back cover starts to sweep into the web.
    private static let tearTilt: Float = 0.9986
    /// The hand's size in units, how far its plane's edge floats from the first book's cover,
    /// how far it pokes forward at a push and how long that takes, how long it then takes to
    /// fade, and how far it hovers for each point the details' book drifts.
    private static let handSize: Float = 1.25
    private static let handTipGap: Float = 0.3
    private static let pokeReach: Float = 0.35
    private static let pokeTime: TimeInterval = 0.22
    private static let handFade: TimeInterval = 0.35
    private static let handDriftScale: Float = 0.008
    /// The glow's size as a share of the hand's, how far behind the hand's middle, toward the
    /// wrist, it centers, so it never reaches the book, even at a poke, and its opacity, which
    /// pulses `haloPulse` either way.
    private static let haloSize: Float = 1.1
    private static let haloBack: Float = 0.15
    private static let haloOpacity: Float = 0.2
    private static let haloPulse: Float = 0.04

    /// The camera that shows, which a renderer without a view films through.
    let camera = PerspectiveCamera()
    /// The current view's anchor that holds `root` (see `attach`).
    private var holder: AnchorEntity?
    private let factory = BookFactory()
    private let stage = DeskStage()
    private var poolRadius: Float?
    private let shelf = Entity()
    /// Holds the pointing hand at the book a push tips, with its halo, and takes that book's
    /// taps with `hitBox`.
    private let marker = Entity()
    /// A box a little larger than the marked book, since a thin book is hard to hit from the
    /// overview. `tap(at:in:)` finds it with a raycast. It is a trigger, so books pass through
    /// it, and its overlaps play no sound. Its filter is the default one, because a raycast
    /// skips a shape whose filter collides with nothing.
    private let hitBox = Entity()
    /// An empty entity in a returning book's standing pose, in whose frame `returnPose`
    /// measures the other books.
    private let probe = Entity()
    private let hand: ModelEntity
    private let halo: ModelEntity
    /// The index of the book `marker` marks, if it shows.
    private var marked: Int?
    /// The hand's idle hover, from when it last appeared, or `nil` with Reduce Motion on.
    private var handDrift: Drift?
    /// Seconds since a push sent the hand poking forward, while it pokes and fades.
    private var poke: TimeInterval?
    /// Seconds the hand has shown, which time its halo's pulse.
    private var handClock: TimeInterval = 0
    private var key: Key?
    /// The viewport the plan was framed for.
    private var plannedViewport: PileViewport?
    private var plan: [DominoSlot] = []
    private var extent = SIMD2<Float>.zero
    private var spawned = 0
    /// The standing books and their slots, in chain order.
    private var books: [ModelEntity] = []
    private var slots: [DominoSlot] = []
    /// The cobwebs that still hang, in chain order, and those tearing.
    private var cobwebs: [HangingCobweb] = []
    private var torn: [HangingCobweb] = []
    private lazy var silk = HangingCobweb.silk()
    private var indices: [Entity.ID: Int] = [:]
    /// The index of the next book to fall.
    private var next = 0
    private var started = false
    /// Seconds of simulation since the books stood up, when the front last moved on, and the
    /// farthest it has come (`frontDistance`).
    private var clock: TimeInterval = 0
    private var lastAdvance: TimeInterval = 0
    private var farthest: Float = 0
    /// The overview camera, and the camera that pinches and drags move.
    private var view = PileCamera()
    /// The camera that shows the whole path.
    private var overview = PileCamera()
    /// The zoom at which the overview camera follows the front: close enough to fit a row and
    /// its turns, and the books that land past them, across the view, or the overview's, and
    /// at most `followRoom` times the overview's.
    private var followZoom: Float = 1
    private var aspect: Float = 0.5
    /// Whether the camera mode drives the camera, rather than the reader's last pinch or drag.
    private var follows = false
    private var reducesMotion = false
    private var cameraMode = DominoCameraMode.overview
    /// The path, the part of the view the Follow camera composes in, and its opening view,
    /// from `frame`, for the Follow camera, which `makeRig` builds once the books stand. Until
    /// then, the Follow camera holds the opening view.
    private var path: DominoPath?
    private var area: DominoCameraRig.Area?
    private var opening = DominoCameraPose(eye: [0, 30, 0], target: .zero)
    /// The Follow camera for the current chain.
    private var rig: DominoCameraRig?
    /// The view the camera blends from while another one takes over, the seconds since, and
    /// how long the blend takes.
    private var handoff: (from: Shot, time: Float, duration: Float)?
    /// The overview camera's motion while it follows the chain, or `nil` to start it afresh
    /// from `view`.
    private var steering: DominoOverviewSpring?
    #if DEBUG
        /// The camera log's lines, and whether it has ended (see `logCamera`).
        private var cameraLog: [String] = []
        private var cameraLogEnded = false
    #endif
    /// The camera and the table point under the fingers when they started moving the camera,
    /// whether they pinch, and the drag's translation then.
    private var cameraMove:
        (start: PileCamera, focus: SIMD3<Float>, pinches: Bool, translation: CGSize)?
    private var updates: (any Cancellable)?
    private var collisions: (any Cancellable)?
    /// The books dropping into their places, in chain order (see `enter(by:)`).
    private var entering: [Entry] = []
    /// Seconds of frames since the scene was attached, which time the books' drops, and when the
    /// latest drop starts.
    private var entryClock: TimeInterval = 0
    private var lastEntry = -TimeInterval.infinity
    /// The clock the simulation runs by: `slowMotion` of real time, or real time while a book
    /// flies, because `BookLifter` times the flight's rise and throw by the frame clock.
    private let simulationClock: CMTimebase?
    /// The index of the book in flight, while one flies.
    private var flying: Int? {
        didSet { try? simulationClock?.setRate(flying == nil ? Self.slowMotion : 1) }
    }
    /// While a book flies, the view the camera rises from, until **Back** returns the book to
    /// the camera mode's view (`nil`), and the view the flight rises to.
    private var flightViews: (from: Transform?, flight: Transform)?
    /// The spread the books gather into, laid out once every book stands, and the task laying
    /// it out.
    private var spread: PileSpread?
    private var spreadTask: Task<Void, Never>?
    /// The finale, from the moment every book has fallen until the books stand again.
    private var ending: Ending?
    /// The finale's progress (see `DominoFinale`).
    private struct Ending {
        /// Seconds since the last book fell.
        var clock: Float = 0
        /// The view the camera moves from: the camera mode's as it moves on, or the view as it
        /// showed when the camera mode did not film.
        let source: Shot
        /// The spread's places and view, turned to the camera's yaw.
        let slots: [PileSlot]
        let camera: PileCamera
        /// The books' flights into the spread, in its order, once they start to gather, and how
        /// many have landed.
        var flights: [Flight] = []
        var landed = 0

        /// Whether the camera still moves to the spread's view.
        var movesCamera: Bool { clock < DominoFinale.moveTime }
    }
    /// A book's flight into the spread, whose arc peaks `peak` above its ends. The last flight
    /// is the flourish instead (`DominoFinale.snapPose`).
    private struct Flight {
        /// The book's index in the chain.
        let book: Int
        let from: Transform
        let to: Transform
        let start: Float
        let peak: Float
    }

    private struct Key: Equatable {
        let ids: [Int]
        let generation: Int
    }

    /// A book dropping into its place as the chain stands up.
    private struct Entry {
        /// The book's index in the chain.
        let book: Int
        /// When the drop starts, on `entryClock`.
        let start: TimeInterval
        /// The cobweb between the book and the one before it, which fades in once it lands.
        let web: Entity?
        /// The height the book's middle drops from, set as the drop starts.
        var height: Float?
        var landed = false
    }

    /// A view to blend from: one that holds still, or a camera mode's, which moves on.
    private enum Shot {
        case still(Transform)
        case live(DominoCameraMode)
    }

    /// Creates an empty chain. An `offline` scene, for a video, keeps the simulation on the
    /// renderer's steps instead of a slow-motion clock, so the renderer scales its steps.
    init(offline: Bool = false) {
        var simulation = PhysicsSimulationComponent()
        simulation.gravity = [0, -PileLayout.gravity, 0]
        simulation.solverIterations = .init(positionIterations: 12, velocityIterations: 2)
        // A new timebase stands still until it has a rate, so without one the simulation keeps
        // its default clock.
        let clock = offline ? nil : try? CMTimebase(sourceClock: .hostTimeClock)
        if let clock, (try? clock.setRate(Self.slowMotion)) != nil { simulation.clock = clock }
        simulationClock = clock
        root.components.set(simulation)
        // Far enough for the Follow camera's opening view, which can stand 250 units from a long
        // path.
        camera.camera = PerspectiveCameraComponent(
            near: 0.5, far: 500, fieldOfViewInDegrees: PileCamera.fieldOfView * 180 / .pi,
            fieldOfViewOrientation: .vertical)
        camera.transform = view.transform
        root.addChild(camera)
        root.addChild(stage.root)
        root.addChild(shelf)
        // No walls stop a book that bounces off the chain, so its first hit keeps little speed.
        lifter = BookLifter(
            root: root, camera: camera, factory: factory, feedback: feedback,
            keeps: (sideways: 0.1, fall: 0.25, tumble: 0.2))
        hand = Self.makeHand()
        halo = Self.makeHalo()
        marker.addChild(halo)
        marker.addChild(hand)
        marker.addChild(hitBox)
        hitBox.components.set(InputTargetComponent())
        marker.isEnabled = false
        root.addChild(marker)
        root.addChild(probe)
        factory.coverArrived = { [weak self] id, material in self?.retexture(id, cover: material) }
        lifter.standing = { [weak self] in self?.returnPose }
        feedback.speeds = ImpactSound.dominoSpeeds
    }

    /// Shows the scene in `view`, and calls `update` every frame and plays collisions through
    /// `feedback` while `root` is active there. Each view gets an anchor of its own, under
    /// which the root hangs; a view that goes leaves the root under its orphaned anchor, and
    /// the next view's anchor takes it (see `DeskSceneView`).
    func attach(to view: ARView) {
        let holder = AnchorEntity(world: .zero)
        holder.addChild(root)
        view.scene.addAnchor(holder)
        self.holder = holder
        updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            // Physics stops while the root is inactive, disabled out of sight or out of the
            // scene while a pile image renders, so the scene's clocks and camera wait too.
            guard let self, root.isActive else { return }
            update(event.deltaTime)
        }
        collisions = view.scene.subscribe(to: CollisionEvents.Began.self) { [weak self] event in
            guard let self, event.entityA != hitBox, event.entityB != hitBox,
                !lifter.handle(event)
            else { return }
            feedback.collide(event, pan: pan)
        }
    }

    /// Takes the root out of the view's scene, so nothing draws while a pile image renders.
    func detach() { root.removeFromParent() }

    /// Puts the root back under the current view's anchor after `detach`.
    func reattach() {
        guard root.parent == nil, let holder else { return }
        holder.addChild(root)
    }

    /// Plays collisions through `feedback` in a renderer's `scene`, which holds the root,
    /// for a video. The renderer steps the scene itself with `advance(by:)`.
    func listen(to scene: RealityKit.Scene) {
        collisions = scene.subscribe(to: CollisionEvents.Began.self) { [weak self] event in
            guard let self, event.entityA != hitBox, event.entityB != hitBox,
                !lifter.handle(event)
            else { return }
            feedback.collide(event, pan: pan)
        }
    }

    /// Moves the chain's clocks, cameras, and books on by `deltaTime` of a video's time, as a
    /// frame's update does, for a renderer without a view, with the chain's own time running
    /// `tempo` times as fast. The hits keep the video's time, so their sounds fall on the
    /// frames that show them.
    func advance(by deltaTime: TimeInterval, tempo: Float) {
        feedback.advance(by: deltaTime)
        update(deltaTime * Double(tempo), timesHits: false)
    }

    /// Whether the Follow camera has landed on the first book, so a push can come.
    var isEstablished: Bool { rig?.isEstablished ?? false }

    /// How long the Follow camera's establishing move takes, in seconds, once the books stand.
    var establishTime: Float { rig?.establishTime ?? 0 }

    /// Hides the dust, holds the pointing hand still, and stops the camera from following the
    /// chain while `reduces`, leaving it where it is. Turning it on with the Follow camera cuts
    /// to the overview; turning it off blends to the Follow camera. Once every book has fallen,
    /// the finale keeps the camera.
    func setReduceMotion(_ reduces: Bool) {
        let before = mode
        reducesMotion = reduces
        stage.setDust(!reduces)
        handDrift = reduces ? nil : Drift(start: .now)
        guard ending == nil else { return }
        if reduces {
            follows = false
            handoff = nil
            if before == .follow { view = overview }
        } else if mode != before {
            switchCamera(from: before)
        }
    }

    /// Films the chain with `mode` from now on, blending from the current view when `blends`,
    /// and cutting to it otherwise, as when the view first appears. Once every book has fallen,
    /// the finale keeps the camera, and `mode` applies from the next chain.
    func setCameraMode(_ mode: DominoCameraMode, blends: Bool) {
        let before = self.mode
        cameraMode = mode
        guard ending == nil, self.mode != before else { return }
        switchCamera(from: before)
        if !blends { handoff = nil }
    }

    /// Whether every book stands in its place, so the chain can start.
    private var isReady: Bool { !plan.isEmpty && spawned == plan.count && entering.isEmpty }

    /// Whether the finale runs: from the last book's fall until the books lie gathered.
    private var isGathering: Bool { ending != nil && status.phase != .finished }

    // MARK: Setting up

    /// Stands `books` along a new path, or continues standing them up after an earlier call
    /// for the same chain and generation, such as one interrupted by pushed details.
    ///
    /// The chain is `DominoLayout.chain(_:)`, so the order of `books`, the desk's sort
    /// order, does not matter. A new chain or generation removes every book, frames the whole
    /// path between the bars of `viewport`, and lays the lamp's pool over it. Books stand up
    /// `batchSize` at a time. Each batch waits at most `coverWait` for its covers, and the next
    /// batch builds while its cobwebs' meshes generate, so it stands up only once the next
    /// batch is built; the first batch also waits for the room's light. Each book then drops
    /// into its place from above the view (see `spawn`), as far behind the one before as the
    /// books have taken to build on average (`DominoLayout.entryStep(count:perBook:)`), so
    /// the drops run on without a pause while later books build. `loading` is set until the
    /// first batch starts to drop. Returns when every book is built or the task is cancelled;
    /// the chain waits for a push once the last book has landed.
    func setUp(_ books: [CloudBook], generation: Int, viewport: PileViewport, model: AppModel)
        async
    {
        guard planSetUp(books, generation: generation, viewport: viewport), let key else {
            return
        }
        // When this call began, on `entryClock`, and the books built since, which pace the
        // drops.
        let began = entryClock
        let first = spawned
        await prepare(from: spawned, model: model)
        while spawned < plan.count {
            guard !Task.isCancelled, self.key == key else { return }
            let end = min(spawned + Self.batchSize, plan.count)
            let batch = plan[spawned..<end]
            async let next: Void = prepare(from: end, model: model)
            let cobwebs = await makeCobwebs(before: batch)
            await next
            // Keeps the first books until the room's light is ready, so they enter lit.
            if spawned == 0 { await stage.lit() }
            guard !Task.isCancelled, self.key == key else { return }
            // A chain built in one batch waits for no later build.
            let built = min(end + Self.batchSize, plan.count) - first
            let perBook = end - first == plan.count ? 0 : (entryClock - began) / Double(built)
            let step = DominoLayout.entryStep(count: plan.count, perBook: perBook)
            for slot in batch { spawn(slot, cobweb: cobwebs[slot.book.id], step: step) }
            spawned = end
            if loading.isLoading { loading.isLoading = false }
        }
        if rig == nil { rig = makeRig() }
        #if DEBUG
            // The hooks start once every book stands.
            while !Task.isCancelled, self.key == key, !isReady {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.key == key else { return }
            showDebugCobweb()
            // Apart from the setting up, so the details hook times from the standing chain.
            Task { await runDebugPushes(key: key) }
        #endif
    }

    /// Builds the batch of books from `start`, if any, and starts the covers of the two
    /// batches after it downloading.
    private func prepare(from start: Int, model: AppModel) async {
        guard start < plan.count else { return }
        let end = min(start + Self.batchSize, plan.count)
        await factory.prepare(
            plan[start..<end].map(\.book),
            prefetching: plan[end..<min(end + 2 * Self.batchSize, plan.count)].map(\.book),
            coverWait: Self.coverWait, model: model)
    }

    /// Stands every book of `books` at once, as a renderer without a view needs: the plan for
    /// `viewport`, every cover given up to 10 seconds, the cobwebs, and the Follow camera,
    /// with no drop in. Returns the chain's length along the path, up to the last book.
    func setUpOffline(_ books: [CloudBook], viewport: PileViewport, model: AppModel) async
        -> Float
    {
        planSetUp(books, generation: 0, viewport: viewport)
        await factory.prepare(
            plan.map(\.book), prefetching: [], coverWait: .seconds(10), model: model)
        await stage.lit()
        let cobwebs = await makeCobwebs(before: plan[...])
        let enters = reducesMotion
        reducesMotion = true
        for slot in plan { spawn(slot, cobweb: cobwebs[slot.book.id], step: 0) }
        reducesMotion = enters
        spawned = plan.count
        loading.isLoading = false
        rig = makeRig()
        return slots.last?.distance ?? 0
    }

    /// Plans the chain of `books` as `setUp` does, without standing any book. Call it before
    /// `setUp` to learn at once whether a new chain removed the lifted book. Returns `false`
    /// when `viewport` leaves no room for the chain.
    ///
    /// Until the first book drops, a new viewport frames the chain again: a tab's first
    /// layouts pass through sizes it never shows, such as one with a large title.
    @discardableResult
    func planSetUp(_ books: [CloudBook], generation: Int, viewport: PileViewport) -> Bool {
        let chain = DominoLayout.chain(books)
        let key = Key(ids: chain.map { $0.book.id }, generation: generation)
        guard key != self.key || (spawned == 0 && viewport != plannedViewport) else {
            return true
        }
        let size = viewport.size
        let insets = viewport.insets
        let safe = CGSize(
            width: size.width - insets.leading - insets.trailing,
            height: size.height - insets.top - insets.bottom)
        guard safe.width > 0, safe.height > 0 else { return false }
        reset(keeping: Set(key.ids))
        // The table seen at the camera's pitch is deeper than the screen is tall.
        let plan = DominoLayout.plan(
            chain, aspect: Float(safe.width / safe.height) * sin(PileCamera.pitch))
        self.plan = plan.slots
        extent = plan.extent
        light(radius: max(6, simd_length(plan.extent) + 3))
        frame(plan, in: viewport)
        self.key = key
        plannedViewport = viewport
        loading.isLoading = !plan.slots.isEmpty
        return true
    }

    /// Removes the books and their textures while the chain is out of sight. The next `setUp`
    /// stands the books again.
    func release() {
        reset(keeping: [])
        plan = []
        key = nil
    }

    private func reset(keeping ids: Set<Int>) {
        shelf.children.removeAll()
        books = []
        slots = []
        cobwebs = []
        torn = []
        indices = [:]
        spawned = 0
        next = 0
        started = false
        follows = false
        rig = nil
        handoff = nil
        steering = nil
        clock = 0
        lastAdvance = 0
        farthest = 0
        cameraMove = nil
        lifter.reset()
        entering = []
        lastEntry = -.infinity
        flying = nil
        flightViews = nil
        spread = nil
        spreadTask?.cancel()
        spreadTask = nil
        ending = nil
        mark(nil)
        #if DEBUG
            cameraLog = []
            cameraLogEnded = false
        #endif
        factory.release(keeping: ids)
        status.phase = .settingUp
        status.cobwebs = 0
    }

    /// Lays the lamp's pool over a circle of `radius` about the table's center: the first
    /// call builds the stage, and later ones only re-aim its lamp.
    private func light(radius: Float) {
        guard poolRadius != radius else { return }
        if poolRadius == nil {
            stage.build(pool: .zero, radius: radius)
        } else {
            stage.aim(pool: .zero, radius: radius)
        }
        poolRadius = radius
    }

    /// Frames every book of `plan`, standing or fallen (`DominoLayout.outline`), between the
    /// bars of `viewport`, with room around them and more at the bottom, for the overview and,
    /// from the side the Follow camera films from, for its opening view, and sets up the Follow
    /// camera to compose between the bars.
    private func frame(_ plan: DominoPlan, in viewport: PileViewport) {
        let size = viewport.size
        let insets = viewport.insets
        aspect = Float(size.width / size.height)
        let rect = CGRect(
            x: insets.leading + 16, y: insets.top + 8,
            width: size.width - insets.leading - insets.trailing - 32,
            height: size.height - insets.top - insets.bottom - 88)
        let outline = DominoLayout.outline(of: plan.slots)
        overview = PileCamera().framing(outline, in: rect, of: size, zoomRange: 0.2...2.5)
        overview.zoom *= Self.overviewRoom
        var high = PileCamera(
            yaw: DominoCameraRig.openingYaw, pitch: DominoCameraRig.openingPitch
        )
        .framing(outline, in: rect, of: size, zoomRange: 0.1...2.5)
        high.zoom *= Self.openingRoom
        opening = DominoCameraPose(eye: high.transform.translation, target: high.target)
        // The view's width at the follow zoom fits the row with 10 percent to spare.
        let tallest = plan.slots.map(\.size.y).max() ?? 0
        let span = (plan.path.rowLengths.max() ?? 0) + 2 * plan.path.radius + 2 * tallest
        followZoom = min(
            max(
                overview.zoom,
                PileCamera.distance * 2 * tan(PileCamera.fieldOfView / 2) * aspect * 0.9 / span),
            overview.zoom * Self.followRoom)
        view = overview
        handoff = nil
        steering = nil
        rig = nil
        path = plan.path
        // The Follow camera composes down to the tab bar, in normalized device coordinates.
        let width = Float(size.width)
        let height = Float(size.height)
        area = DominoCameraRig.Area(
            low: [
                2 * Float(insets.leading + 16) / width - 1,
                1 - 2 * Float(size.height - insets.bottom - 8) / height,
            ],
            high: [
                1 - 2 * Float(insets.trailing + 16) / width, 1 - 2 * Float(insets.top + 8) / height,
            ])
        follows = mode == .follow
    }

    /// The Follow camera for the books that stand and the cobwebs that hang between them, which
    /// can differ from the plan's where RealityKit could not build a book.
    private func makeRig() -> DominoCameraRig? {
        guard let path, let area, let first = slots.first, let last = slots.last else { return nil }
        let webs = cobwebs.compactMap { web -> DominoCameraRig.Cobweb? in
            let near = slots[web.book]
            let far = slots[web.book + 1]
            return DominoLayout.cobweb(days: far.day - near.day)
                .map { .init(distance: (near.distance + far.distance) / 2, density: $0) }
        }
        let rig = DominoCameraRig(
            path: path, offset: path.point(at: first.distance).position - first.position,
            length: last.distance, tallest: slots.map(\.size.y).max() ?? 0, cobwebs: webs,
            opening: opening, fieldOfView: PileCamera.fieldOfView, aspect: aspect, area: area)
        #if DEBUG
            logRig(rig, cobwebs: webs)
        #endif
        return rig
    }

    /// Stands the book of `slot`, with `cobweb` hanging between it and the book before it.
    ///
    /// Unless Reduce Motion is on, the book waits out of sight for its turn to drop into its
    /// place, `step` seconds after the book before it, and its cobweb waits unseen for it to
    /// land (see `enter(by:)`).
    private func spawn(_ slot: DominoSlot, cobweb: HangingCobweb?, step: TimeInterval) {
        let enters = !reducesMotion
        guard
            let book = factory.makeBook(
                slot.book.id, mode: enters ? .kinematic : .dynamic, lighting: stage.lighting,
                mass: DominoLayout.mass(height: slot.size.y))
        else { return }
        book.transform = DominoLayout.standingPose(of: slot)
        shelf.addChild(book)
        indices[book.id] = books.count
        books.append(book)
        slots.append(slot)
        var web: Entity?
        if var cobweb, books.count > 1 {
            cobweb.book = books.count - 2
            shelf.addChild(cobweb.root)
            cobwebs.append(cobweb)
            status.cobwebs += 1
            web = cobweb.root
        }
        guard enters else { return }
        book.isEnabled = false
        web?.components.set(OpacityComponent(opacity: 0))
        let start = max(entryClock, lastEntry + step)
        lastEntry = start
        entering.append(Entry(book: books.count - 1, start: start, web: web))
    }

    /// Moves the entering books on by `deltaTime`. Each book, at its turn, appears with its middle
    /// just far enough above the top of the view as it shows then that the whole book is out of
    /// it, and drops straight down onto its place, speeding up as a falling book does, over
    /// `DominoLayout.entryFall`. It is kinematic while it drops, so it pushes nothing, and stands
    /// as a dynamic body once it lands, at rest. Its cobweb then fades in over
    /// `DominoLayout.webFade`.
    private func enter(by deltaTime: TimeInterval) {
        entryClock += deltaTime
        for index in entering.indices {
            let time = entryClock - entering[index].start
            // Drops start in chain order.
            guard time >= 0 else { break }
            let entry = entering[index]
            if !entry.landed {
                let book = books[entry.book]
                let place = DominoLayout.standingPose(of: slots[entry.book])
                let height = entry.height ?? dropHeight(of: slots[entry.book])
                let share = Float(min(1, time / DominoLayout.entryFall))
                book.transform = Transform(
                    rotation: place.rotation,
                    translation: [
                        place.translation.x,
                        height + (place.translation.y - height) * share * share,
                        place.translation.z,
                    ])
                book.isEnabled = true
                entering[index].height = height
                guard share == 1 else { continue }
                book.components[PhysicsBodyComponent.self]?.mode = .dynamic
                book.components.set(PhysicsMotionComponent())
                entering[index].landed = true
            }
            let fade = (time - DominoLayout.entryFall) / DominoLayout.webFade
            if fade < 1 {
                entry.web?.components.set(OpacityComponent(opacity: Float(max(0, fade))))
            } else {
                entry.web?.components.remove(OpacityComponent.self)
            }
        }
        entering.removeAll {
            $0.landed && entryClock - $0.start >= DominoLayout.entryFall + DominoLayout.webFade
        }
    }

    /// The height from which the book of `slot` drops: its middle just far enough above the top
    /// of the view as it shows that the whole book, at the widest cover, is out of view, or its
    /// place when that lies out of view already.
    private func dropHeight(of slot: DominoSlot) -> Float {
        let place = DominoLayout.standingPose(of: slot).translation.y
        let size = SIMD3(DominoLayout.widest(slot.size.y), slot.size.y, slot.size.z)
        let above = PileCamera.heightAboveView(
            of: slot.position, radius: simd_length(size) / 2, seenFrom: camera.transform)
        // A view whose top looks level or up shows every height; the book drops from high.
        return max(place, above ?? place + 30)
    }

    /// The cobwebs to hang in front of the books of `batch`, by the ID of the book behind each
    /// web: one between each book with parts and the one before it that stands, wherever
    /// `DominoLayout.cobweb(days:)` finds the days between their finishes long enough. A book
    /// without parts cannot stand, so the days across its place count toward the web between
    /// its neighbors. Each web runs between the books' facing top edges, from near their
    /// corners.
    private func makeCobwebs(before batch: ArraySlice<DominoSlot>) async -> [Int: HangingCobweb] {
        func edge(_ slot: DominoSlot, facing direction: Float) -> [SIMD3<Float>] {
            // The built book's width follows its cover, unlike the slot's.
            let size = factory.parts[slot.book.id]?.shape.size ?? slot.size
            let across = SIMD2(-slot.heading.y, slot.heading.x) * size.x * 0.42
            let middle = slot.position + slot.heading * size.z / 2 * direction
            // Just under the top edge, so the threads leave the boards rather than float.
            return [middle - across, middle + across].map { [$0.x, size.y - 0.005, $0.y] }
        }
        var cobwebs: [Int: HangingCobweb] = [:]
        var near = slots.last
        for far in batch where factory.parts[far.book.id] != nil {
            if let near, let density = DominoLayout.cobweb(days: far.day - near.day) {
                let web = Cobweb(
                    near: edge(near, facing: 1), far: edge(far, facing: -1), density: density,
                    seed: UInt64(bitPattern: Int64(near.book.id)) &* 0x9E37_79B9_7F4A_7C15
                        ^ UInt64(bitPattern: Int64(far.book.id)))
                cobwebs[far.book.id] = await HangingCobweb(
                    web, material: silk, lighting: stage.lighting)
            }
            near = far
        }
        return cobwebs
    }

    /// Puts a cover that arrived after its book was built onto the standing book.
    private func retexture(_ id: Int, cover: any RealityKit.Material) {
        for (book, slot) in zip(books, slots) where slot.book.id == id {
            book.children.first?.components[ModelComponent.self]?
                .materials[Int(BookSlot.cover)] = cover
        }
    }

    // MARK: Interaction

    /// Returns the ID of the book under `point`, in a view of `size`, when the chain has
    /// passed it, fallen or standing, for its details. A tap on `hitBox` or on any book the
    /// chain has not reached pushes the chain on (see `pushNext`), so a near miss beside a
    /// thin book still pushes, and returns `nil`, as does a tap on the table or a tap while the
    /// books gather.
    func tap(at point: CGPoint, in size: CGSize) -> Int? {
        guard !isGathering, let index = book(at: point, in: size) else { return nil }
        if index < next { return slots[index].book.id }
        pushNext()
        return nil
    }

    /// The ID of any book under `point`, in a view of `size`, the marked book's on `hitBox`,
    /// or `nil` for the table, for a touch and hold. Returns `nil` until every book stands,
    /// since `lift(_:)` cannot lift a book before then, and a touch and hold would otherwise
    /// push the details, and while the books gather.
    func bookID(at point: CGPoint, in size: CGSize) -> Int? {
        guard isReady, !isGathering else { return nil }
        return book(at: point, in: size).map { slots[$0].book.id }
    }

    /// The index of the book under `point`, in a view of `size`, the marked book's on
    /// `hitBox`, or `nil` for the table.
    ///
    /// It casts its own ray from the camera: a targeted gesture fires only on a touch that
    /// lands on a book, even where `hitBox` lies around it.
    private func book(at point: CGPoint, in size: CGSize) -> Int? {
        guard size.width > 0, size.height > 0, let scene = root.scene else { return nil }
        let ray = ray(through: point, in: size)
        guard
            let entity =
                scene.raycast(
                    origin: ray.origin, direction: ray.direction, length: 300, query: .nearest,
                    relativeTo: root
                )
                .first?
                .entity
        else { return nil }
        return entity == hitBox ? marked : indices[entity.id]
    }

    /// The book a push tips (see `DominoLayout.pushTarget`).
    private var target: Int {
        DominoLayout.pushTarget(next: next, count: books.count) {
            upright($0) > Self.uprightTilt
        }
    }

    /// Tips the book a push tips (see `target`) forward along the path, with a light tap, while
    /// the chain waits for a push. While books fall or a book flies, it does nothing.
    func pushNext() {
        guard status.phase.waitsForPush, next < books.count, flying == nil else { return }
        let book = books[target]
        let slot = slots[target]
        let forward = SIMD3(slot.heading.x, 0, slot.heading.y)
        let spin = simd_cross([0, 1, 0], forward) * Self.pushSpeed
        // About the leading bottom edge, the back cover's, so the book tips over instead of
        // sliding back.
        let arm = SIMD3(0, slot.size.y / 2, 0) - forward * slot.size.z / 2
        book.components.set(
            PhysicsMotionComponent(linearVelocity: simd_cross(spin, arm), angularVelocity: spin))
        started = true
        lastAdvance = clock
        poke = 0
        if !follows, !reducesMotion { resumeFollowing() }
        feedback.impact(
            impulse: 0, mass: book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0,
            position: book.position(relativeTo: root), pan: pan, minimum: 0.2)
    }

    /// Zooms toward the point under `focus` by `magnification`, or slides the camera across
    /// the table with a one-finger `translation`, keeping the path in view. Does nothing while
    /// the finale moves the camera to the spread.
    ///
    /// A drag that becomes a pinch, or a pinch that becomes a drag, starts a new move from the
    /// camera as it is, about the new focus and from the drag's translation so far, so the
    /// camera does not jump.
    func moveCamera(translation: CGSize, magnification: CGFloat, focus: CGPoint?, in size: CGSize) {
        guard size.width > 0, size.height > 0, ending?.movesCamera != true else { return }
        if let move = cameraMove, move.pinches != (focus != nil) { cameraMove = nil }
        if cameraMove == nil {
            // Takes over from the view as it shows, so the camera neither jumps nor tilts.
            if follows || handoff != nil { view = overviewCamera(matching: camera.transform) }
            follows = false
            handoff = nil
            let ray = ray(
                through: focus ?? CGPoint(x: size.width / 2, y: size.height / 2), in: size)
            cameraMove = (
                view, PileCamera.intersect(ray, height: 0) ?? view.target, focus != nil,
                translation
            )
        }
        guard let move = cameraMove else { return }
        let translation = CGSize(
            width: translation.width - move.translation.width,
            height: translation.height - move.translation.height)
        var camera = move.start
        camera.zoom = min(
            max(move.start.zoom * Float(magnification), min(overview.zoom, 1, move.start.zoom)),
            PileCamera.zoomRange.upperBound)
        // Keeps the focus point in place while zooming.
        var target = move.focus + (move.start.target - move.focus) * move.start.zoom / camera.zoom
        // Table units per point at the target, where the view is 2 normalized units tall.
        let scale =
            PileCamera.distance / camera.zoom * tan(PileCamera.fieldOfView / 2) * 2
            / Float(size.height)
        target -=
            simd_quatf(angle: camera.yaw, axis: [0, 1, 0])
            .act(
                SIMD3(Float(translation.width), 0, Float(translation.height) / sin(camera.pitch))
            ) * scale
        // A camera taken over from Follow can look past the path's ends; it may stay there.
        let bound = pointwiseMax(extent + 2, abs(SIMD2(move.start.target.x, move.start.target.z)))
        camera.target = [
            min(max(target.x, -bound.x), bound.x), 0, min(max(target.z, -bound.y), bound.y),
        ]
        look(through: camera)
    }

    func endCameraMove() { cameraMove = nil }

    /// The ray from the camera, as it shows, through `point` in a view of `size`.
    private func ray(through point: CGPoint, in size: CGSize) -> (
        origin: SIMD3<Float>, direction: SIMD3<Float>
    ) {
        let ndc = SIMD2(Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
        let slope = tan(PileCamera.fieldOfView / 2)
        let shown = camera.transform
        return (
            shown.translation,
            shown.rotation.act(simd_normalize(SIMD3(ndc.x * slope * aspect, ndc.y * slope, -1)))
        )
    }

    /// Moves the overview camera, which shows unless the Follow camera films.
    private func look(through camera: PileCamera) { view = camera }

    /// Where `point` shows from left to right on screen, as a stereo position from -0.8 to 0.8.
    private func pan(_ point: SIMD3<Float>) -> Float {
        PileCamera.pan(of: point, seenFrom: camera.transform, aspect: aspect)
    }

    /// An overview camera with the yaw, pitch, and eye of `transform`, looking at the table
    /// under the view's middle, so pinches and drags can take over from the view as it shows.
    private func overviewCamera(matching transform: Transform) -> PileCamera {
        let forward = transform.rotation.act([0, 0, -1])
        let target =
            PileCamera.intersect((transform.translation, forward), height: 0) ?? view.target
        let zoom = PileCamera.distance / max(simd_distance(target, transform.translation), 1)
        return PileCamera(
            target: [target.x, 0, target.z], yaw: atan2(-forward.x, -forward.z),
            zoom: min(zoom, PileCamera.zoomRange.upperBound),
            pitch: asin(min(max(-forward.y, -1), 1)))
    }

    // MARK: Following the chain

    /// Moves the scene on by `deltaTime`, and the hits' clock too unless the caller `timesHits`
    /// itself.
    private func update(_ deltaTime: TimeInterval, timesHits: Bool = true) {
        if timesHits { feedback.advance(by: deltaTime) }
        defer {
            updateCamera(Float(deltaTime))
            updateFlight(deltaTime)
        }
        enter(by: deltaTime)
        guard isReady else { return }
        clock += deltaTime
        for index in next..<min(next + 3, books.count) where upright(index) < Self.fallenTilt {
            next = index + 1
            lastAdvance = clock
            started = true
        }
        // A book still tipping toward the next moves the front on, by more than a book rocks
        // as it settles against its neighbor.
        let front = frontDistance
        if front > farthest + 0.02 {
            farthest = front
            lastAdvance = clock
        }
        tearCobwebs()
        for index in torn.indices.reversed() {
            if !torn[index].advance(by: Float(deltaTime)) { torn.remove(at: index) }
        }
        let fallen = DominoLayout.phase(
            next: next, count: books.count, started: started,
            settled: clock - lastAdvance > Self.stallTime)
        let phase = status.phase.hasEnded ? status.phase : fallen
        if status.phase != phase { status.phase = phase }
        switch phase {
        case .standing, .stalled: mark(target)
        // The hand finishes its poke before it goes.
        default: if poke == nil { mark(nil) }
        }
        updateHand(by: deltaTime)
        updateFinale(by: deltaTime)
    }

    /// How far along the path the chain's front has come: the next book's place, and as much
    /// of the way on to the book after it as that book has tilted toward counting as fallen.
    /// It runs on from book to book as each one tips, with no jump as the front moves on.
    private var frontDistance: Float {
        guard next < slots.count else { return slots.last?.distance ?? 0 }
        let share = min(1, acos(min(1, upright(next))) / acos(Self.fallenTilt))
        let following = slots[min(next + 1, slots.count - 1)].distance
        return slots[next].distance + (following - slots[next].distance) * share
    }

    /// Tears the cobwebs near the front whose books have tilted past `tearTilt`, once the chain
    /// has started, so a book that rocks as it stands up tears nothing.
    private func tearCobwebs() {
        guard started else { return }
        var index = 0
        while index < cobwebs.count, cobwebs[index].book <= next + 2 {
            let book = cobwebs[index].book
            guard min(upright(book), upright(book + 1)) < Self.tearTilt else {
                index += 1
                continue
            }
            var web = cobwebs.remove(at: index)
            web.tear(near: books[book], far: books[book + 1], fadesOnly: reducesMotion)
            torn.append(web)
        }
    }

    /// How upright the book at `index` stands: the up component of its tail-to-head axis, 1
    /// for a book standing on its tail and 0 for one lying down. A book in flight counts as
    /// standing in its place.
    private func upright(_ index: Int) -> Float {
        index == flying ? 1 : books[index].transform.rotation.act([0, 1, 0]).y
    }

    // MARK: Pointing at the next book

    /// Moves the marker to the book at `index`, or hides it for `nil` or an index past the
    /// last book.
    private func mark(_ index: Int?) {
        let index = index.flatMap { slots.indices.contains($0) ? $0 : nil }
        guard index != marked else { return }
        marked = index
        guard let index else {
            marker.isEnabled = false
            poke = nil
            return
        }
        let slot = slots[index]
        // The marker's z runs along the path, toward the book's back cover.
        marker.transform = Transform(
            rotation: simd_quatf(angle: atan2(slot.heading.x, slot.heading.y), axis: [0, 1, 0]),
            translation: [slot.position.x, 0, slot.position.y])
        // Past the book's covers by less than the gap to a neighbor (`DominoLayout.gap`), so
        // the box does not cover a neighbor's taps on a row, and back over the hand, which
        // floats before the front cover, so a tap on the hand pushes too.
        let reach = Self.handTipGap + Self.handSize
        let box = slot.size + [0.4, 1, 0.3 + reach]
        hitBox.components.set(
            CollisionComponent(
                shapes: [
                    .generateBox(size: box).offsetBy(translation: [0, box.y / 2, -reach / 2])
                ],
                mode: .trigger))
        if !marker.isEnabled {
            marker.isEnabled = true
            poke = nil
            handClock = 0
            handDrift = reducesMotion ? nil : Drift(start: .now)
        }
        updateHand(by: 0)
    }

    /// Places the hand before the marked book, pointing at it, and its faint halo behind the
    /// hand, centered toward the wrist so it stays clear of the book.
    ///
    /// Before the first book, the hand floats at the height of a pushing finger, a little off
    /// the front cover, pointing straight at it. At a stalled chain's book, whose front cover
    /// the fallen book before it leans on, it floats above and behind the book, pointing down
    /// at it. The plane turns about the finger so it faces the camera as squarely as it can,
    /// upright on screen, from either side (its back shows the glove mirrored). It hovers as
    /// the details' book drifts (`Drift`), scaled to the scene, and its halo pulses, unless
    /// Reduce Motion is on. At a push it pokes forward `pokeReach` over `pokeTime` and fades
    /// over `handFade`; with Reduce Motion on, it only fades.
    private func updateHand(by deltaTime: TimeInterval) {
        guard marker.isEnabled, let marked else { return }
        handClock += deltaTime
        let slot = slots[marked]
        let raised = next > 0
        let finger: SIMD3<Float> = raised ? simd_normalize([0, -0.7, 0.72]) : [0, 0, 1]
        var position: SIMD3<Float> =
            raised
            ? [0, slot.size.y + 0.45, -(slot.size.z / 2 + 0.45)]
            : [0, slot.size.y * 0.62, -(slot.size.z / 2 + Self.handTipGap + Self.handSize / 2)]
        let eye = marker.convert(position: camera.position(relativeTo: root), from: root)
        var normal = eye - position
        normal -= finger * simd_dot(normal, finger)
        normal = simd_length(normal) > 1e-3 ? simd_normalize(normal) : [1, 0, 0]
        var up = simd_cross(normal, finger)
        if up.y < 0 {
            up = -up
            normal = -normal
        }
        var rotation = simd_quatf(simd_float3x3(columns: (finger, up, normal)))
        var opacity: Float = 1
        if let drift = handDrift {
            let offset = drift.offset(at: .now)
            position +=
                up * Float(-offset.translation.height) * Self.handDriftScale
                + finger * Float(offset.translation.width) * Self.handDriftScale
            rotation = rotation * simd_quatf(angle: Float(offset.yaw), axis: [0, 0, 1])
        }
        if var poke {
            poke += deltaTime
            self.poke = poke
            let push = Float(min(poke / Self.pokeTime, 1))
            if !reducesMotion { position += finger * Self.pokeReach * sin(push * .pi / 2) }
            opacity = 1 - Float(min(max((poke - Self.pokeTime) / Self.handFade, 0), 1))
            if opacity == 0 {
                self.poke = nil
                mark(nil)
                return
            }
        }
        hand.transform = Transform(
            scale: SIMD3(repeating: Self.handSize), rotation: rotation, translation: position)
        hand.components.set(OpacityComponent(opacity: opacity))
        let pulse =
            Self.haloOpacity
            + (reducesMotion ? 0 : Self.haloPulse * sin(Float(handClock) * 2 * .pi / 1.8))
        halo.transform = Transform(
            scale: SIMD3(repeating: Self.handSize * Self.haloSize), rotation: rotation,
            translation: position - finger * Self.handSize * Self.haloBack - normal * 0.03)
        halo.components.set(OpacityComponent(opacity: pulse * opacity))
    }

    /// A pointing hand, the macOS cursor's glove: the `hand.point.right.fill` symbol in cream
    /// with a dark outline and a soft shadow, on a plane one unit square, drawn on both sides.
    private static func makeHand() -> ModelEntity {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        let side: CGFloat = 256
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { context in
                guard
                    let symbol = UIImage(
                        systemName: "hand.point.right.fill",
                        withConfiguration: UIImage.SymbolConfiguration(
                            pointSize: 150, weight: .medium))
                else { return }
                let rect = CGRect(
                    x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2,
                    width: symbol.size.width, height: symbol.size.height)
                let cg = context.cgContext
                cg.saveGState()
                cg.setShadow(
                    offset: CGSize(width: 4, height: 8), blur: 14,
                    color: UIColor.black.withAlphaComponent(0.5).cgColor)
                symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: rect)
                cg.restoreGState()
                // The outline: the glyph drawn dark around a circle of offsets.
                let outline = symbol.withTintColor(
                    UIColor(white: 0.12, alpha: 1), renderingMode: .alwaysOriginal)
                for step in 0..<12 {
                    let angle = CGFloat(step) / 12 * 2 * .pi
                    outline.draw(in: rect.offsetBy(dx: 5 * cos(angle), dy: 5 * sin(angle)))
                }
                symbol.withTintColor(
                    UIColor(red: 1, green: 0.96, blue: 0.88, alpha: 1),
                    renderingMode: .alwaysOriginal
                )
                .draw(in: rect)
            }
        if let cgImage = image.cgImage,
            let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color))
        {
            material.color = .init(texture: .init(texture))
            material.blending = .transparent(opacity: .init(scale: 1, texture: .init(texture)))
        }
        material.faceCulling = .none
        let hand = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
        hand.components.set(DynamicLightShadowComponent(castsShadow: false))
        return hand
    }

    /// A soft, warm glow on a plane one unit square, drawn on both sides, which hangs behind the
    /// hand. It falls off from its middle as a Gaussian, half gone about a third of the way to
    /// its edge and nearly gone by two thirds, with no ring or rim.
    private static func makeHalo() -> ModelEntity {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                let locations = (0...16).map { CGFloat($0) / 16 }
                // Tapered to nothing at the edge.
                let colors = locations.map { radius in
                    UIColor.white
                        .withAlphaComponent(
                            exp(-radius * radius / 0.18) * (1 - radius * radius)
                        )
                        .cgColor
                }
                guard
                    let gradient = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                        locations: locations)
                else { return }
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                context.cgContext.drawRadialGradient(
                    gradient, startCenter: middle, startRadius: 0, endCenter: middle,
                    endRadius: size.width / 2, options: [])
            }
        // The texture's alpha shapes the glow; its color tints the lamp's warm light gold.
        if let cgImage = image.cgImage,
            let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color))
        {
            material.color = .init(
                tint: UIColor(red: 1, green: 0.86, blue: 0.6, alpha: 1), texture: .init(texture))
            material.blending = .transparent(opacity: .init(scale: 1, texture: .init(texture)))
        }
        material.faceCulling = .none
        let halo = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
        halo.components.set(DynamicLightShadowComponent(castsShadow: false))
        return halo
    }

    // MARK: Details

    /// Starts lifting the book with `id` out of the chain toward its details, which
    /// `BookLifter.place` places, and returns the seconds until it gets there. Returns `nil`,
    /// leaving the chain as it was, while the books stand up, once every book has fallen, when
    /// the book is not in the chain, or when the view does not show the scene.
    ///
    /// The book rises clear of its standing neighbors (`riseMargin`) and tears the cobwebs it
    /// holds. The camera rises to look down at the overview's pitch on the table under the
    /// view's middle, with the view's turn, from the pile's default distance, so the book in
    /// front of it clears the chain, the veil dims the whole view, and a throw back comes from
    /// no farther than in the pile (see `BookLifter`).
    func lift(_ id: Int) -> Double? {
        guard root.scene != nil, isReady, ending == nil,
            let index = slots.firstIndex(where: { $0.book.id == id }),
            let landing = lifter.lift(
                books[index], id: id, among: books, aspect: aspect, margin: Self.riseMargin)
        else { return nil }
        endCameraMove()
        flying = index
        for web in cobwebs.indices.reversed()
        where (index - 1...index).contains(cobwebs[web].book) {
            var torn = cobwebs.remove(at: web)
            torn.tear(near: books[torn.book], far: books[torn.book + 1], fadesOnly: reducesMotion)
            self.torn.append(torn)
            rig?.forgetCobweb(at: (slots[torn.book].distance + slots[torn.book + 1].distance) / 2)
        }
        let matched = overviewCamera(matching: camera.transform)
        flightViews = (
            camera.transform, PileCamera(target: matched.target, yaw: matched.yaw).transform
        )
        return landing
    }

    /// Returns the lifted book: sets it down standing in its place when it stands again
    /// (`returnPose`), and otherwise throws it back into the books around its place. The camera
    /// returns to the camera mode's view as it moves on, rather than to the view the book left.
    func throwBack() {
        lifter.throwBack()
        flightViews?.from = nil
    }

    /// Ends a lift or a return at once: puts the book back as `throwBack` would return it, at
    /// rest, or just above its place, and the camera and veil as they were.
    func dropLifted() {
        guard flying != nil else { return }
        lifter.drop(aim: aim)
        endFlight()
    }

    /// The standing pose a returning book takes in its place, or `nil` for a book that is thrown
    /// back: one that had fallen, or one whose place another book has filled (see
    /// `DominoLayout.standsAgain`). The lifter asks as the book leaves its details and again as
    /// it lands.
    private var returnPose: Transform? {
        guard let flying else { return nil }
        let slot = slots[flying]
        let place = DominoLayout.standingPose(of: slot)
        probe.transform = place
        let size = factory.parts[slot.book.id]?.shape.size ?? slot.size
        let others = books.indices.filter { $0 != flying }
            .map { books[$0].visualBounds(relativeTo: probe) }
        return DominoLayout.standsAgain(
            index: flying, next: next, place: BoundingBox(min: -size / 2, max: size / 2),
            others: others) ? place : nil
    }

    /// Moves the book in flight, and the camera through `aim`, after the camera modes have
    /// stepped, and hands the camera back to them once the book is back.
    private func updateFlight(_ deltaTime: TimeInterval) {
        guard flying != nil else { return }
        lifter.update(by: deltaTime, aim: aim)
        if !lifter.isFlying { endFlight() }
    }

    /// Moves the camera `share` of the way to the flight's view: from the view the book left,
    /// or once the book returns, from the camera mode's view as it moves on (`current`).
    private func aim(_ share: Float) {
        guard let flightViews else { return }
        let from = flightViews.from ?? current
        camera.transform = Transform(
            rotation: simd_slerp(from.rotation, flightViews.flight.rotation, share),
            translation: from.translation + (flightViews.flight.translation - from.translation)
                * share)
    }

    /// Hands the camera back to the camera mode. A return has brought the camera to its view;
    /// a book put back during its lift left the camera at the view it lifted from, so the
    /// camera mode blends from there, as a switch between modes does.
    private func endFlight() {
        if flightViews?.from == nil {
            handoff = nil
        } else {
            blend(from: .still(camera.transform))
        }
        flying = nil
        flightViews = nil
    }

    // MARK: Finale

    /// Plays the finale (`DominoFinale`) once every book has fallen. The spread is laid out as
    /// soon as every book stands, and the finale starts once the last book tips, no book is out
    /// at its details, and the spread is ready. The camera then moves from the view it films,
    /// as that moves on, to the spread's view, turned to the camera's yaw; pinches, drags, and
    /// camera switches wait until it rests there. The books are kinematic once they gather, so
    /// the spread holds. With Reduce Motion on, the camera cuts to the spread's view and the
    /// books appear in their places `DominoFinale.stillWait` after the last book falls.
    private func updateFinale(by deltaTime: TimeInterval) {
        if spread == nil, spreadTask == nil { layOutSpread() }
        if ending == nil { startEnding() }
        guard var ending, status.phase != .finished else { return }
        defer { self.ending = ending }
        let moved = ending.movesCamera
        ending.clock += Float(deltaTime)
        if reducesMotion {
            guard ending.clock >= DominoFinale.stillWait else { return }
            rest(on: ending.camera)
            if ending.flights.isEmpty { ending.flights = flights(into: ending) }
            for flight in ending.flights { books[flight.book].transform = flight.to }
            ending.landed = ending.flights.count
            if let first = ending.flights.first { land(books[first.book], firmly: false) }
            status.phase = .finished
            return
        }
        if moved, !ending.movesCamera { rest(on: ending.camera) }
        gather(&ending)
    }

    /// Starts the finale once every book has fallen, no book flies, and the spread is laid out,
    /// from the view as it shows: the camera mode's while it films, so its motion carries on
    /// into the move, and otherwise the view held still.
    private func startEnding() {
        guard !slots.isEmpty, next >= books.count, flying == nil, let spread else { return }
        let yaw = overviewCamera(matching: camera.transform).yaw
        let placed = DominoFinale.turned(spread.slots, camera: spread.camera, by: yaw)
        let source: Shot =
            follows && cameraMove == nil && handoff == nil ? .live(mode) : .still(camera.transform)
        handoff = nil
        cameraMove = nil
        ending = Ending(source: source, slots: placed.slots, camera: placed.camera)
    }

    /// Leaves the camera on `view`, where pinches and drags take over.
    private func rest(on view: PileCamera) {
        follows = false
        steering = nil
        handoff = nil
        self.view = view
    }

    /// Lays the spread out for the view the chain was planned in, below the heading's room,
    /// away from the main actor, once every book stands.
    private func layOutSpread() {
        guard isReady, let viewport = plannedViewport, let seed = key?.generation else { return }
        let size = viewport.size
        let insets = viewport.insets
        let room = DominoFinale.headingRoom(width: size.width)
        let rect = CGRect(
            x: insets.leading + 16, y: insets.top + room,
            width: size.width - insets.leading - insets.trailing - 32,
            height: size.height - insets.top - room - insets.bottom - 24)
        let shaped = slots.map { slot in
            (
                slot.book,
                factory.parts[slot.book.id]?.shape ?? BookShape(of: slot.book, coverAspect: 2 / 3)
            )
        }
        spreadTask = Task {
            let spread = await Self.layOut(shaped, in: rect, of: size, seed: UInt64(seed))
            guard !Task.isCancelled else { return }
            self.spread = spread
        }
    }

    /// Waits for the spread's layout, so that a renderer without a view can take the
    /// finale's first frame as soon as it is ready.
    func waitForSpread() async { await spreadTask?.value }

    @concurrent
    nonisolated private static func layOut(
        _ books: [(book: CloudBook, shape: BookShape)], in rect: CGRect, of size: CGSize,
        seed: UInt64
    ) async -> PileSpread {
        PileSpread(books, in: rect, of: size, seed: seed)
    }

    /// The flights of the books into `ending`'s spread, from where they lie, which leaves them
    /// kinematic.
    private func flights(into ending: Ending) -> [Flight] {
        let placed = ending.slots.compactMap { slot in
            slots.firstIndex { $0.book.id == slot.book.id }.map { ($0, slot.transform) }
        }
        return placed.enumerated()
            .map { order, place in
                let book = books[place.0]
                book.components[PhysicsBodyComponent.self]?.mode = .kinematic
                book.components.set(PhysicsMotionComponent())
                return Flight(
                    book: place.0, from: book.transform, to: place.1,
                    start: DominoFinale.start(of: order, count: placed.count),
                    peak: DominoFinale.peak(of: order))
            }
    }

    /// Lifts the books off the desk once the gathering starts, flies them on, lands each in its
    /// place with a soft knock, and the spread's last with a firm one, and ends the finale once
    /// the last has landed.
    private func gather(_ ending: inout Ending) {
        if ending.flights.isEmpty {
            guard ending.clock >= DominoFinale.gatherDelay else { return }
            ending.flights = flights(into: ending)
            status.phase = .gathering
        }
        let last = ending.flights.count - 1
        for (order, flight) in ending.flights.enumerated().dropFirst(ending.landed) {
            let time = ending.clock - flight.start
            guard time > 0 else { break }
            let book = books[flight.book]
            let snaps = order == last
            guard time >= (snaps ? DominoFinale.snapTime : DominoFinale.flightTime) else {
                book.transform =
                    snaps
                    ? DominoFinale.snapPose(
                        from: flight.from, to: flight.to,
                        top: DominoFinale.snapTop(
                            over: flight.to.translation, seenBy: ending.camera), time: time)
                    : DominoFinale.pose(
                        from: flight.from, to: flight.to, peak: flight.peak,
                        progress: time / DominoFinale.flightTime)
                continue
            }
            book.transform = flight.to
            // Flights land in order, the flourish last, so the landed books are a prefix.
            if order == ending.landed {
                ending.landed += 1
                land(book, firmly: snaps)
            }
        }
        if ending.landed == ending.flights.count { status.phase = .finished }
    }

    /// Plays a book's landing in the spread: a soft knock, or the flourish's deep knock and
    /// firm tap.
    private func land(_ book: ModelEntity, firmly: Bool) {
        let position = book.position(relativeTo: root)
        guard !firmly else { return feedback.slam(at: position, pan: pan) }
        let mass = book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0.4
        feedback.impact(impulse: mass * 0.9, mass: mass, position: position, pan: pan)
    }

    // MARK: Camera

    /// The camera in effect: with Reduce Motion on, the overview's, whose camera then stays
    /// where the reader leaves it.
    private var mode: DominoCameraMode { reducesMotion ? .overview : cameraMode }

    /// Hands the camera from `before` to `mode`, blending from the view as it shows: from the
    /// camera `before` as it moves on, when it was filming and no blend was under way, and from
    /// the view held still otherwise. The overview camera follows the front only once the
    /// chain has started.
    private func switchCamera(from before: DominoCameraMode) {
        let source: Shot =
            follows && cameraMove == nil && handoff == nil
            ? .live(before) : .still(camera.transform)
        let wasFollowing = follows
        switch mode {
        case .follow:
            follows = true
        case .overview:
            follows = started
            if !follows {
                view = overview
            } else if !wasFollowing {
                steering = nil
            }
        }
        blend(from: source)
    }

    /// Hands the camera back to the camera mode from where a pinch or drag left it, at rest:
    /// the overview camera eases on from the view, and the Follow camera from the view looking
    /// at the table under its middle.
    private func resumeFollowing() {
        follows = true
        steering = nil
        handoff = nil
        guard mode == .follow else { return }
        rig?.reset(to: DominoCameraPose(eye: view.transform.translation, target: view.target))
    }

    /// Blends the view from `source` to the camera in effect, taking long enough that the
    /// blend turns and travels no faster than `handoffTurnRate` and `handoffSpeed` on average.
    private func blend(from source: Shot) {
        guard !reducesMotion else {
            handoff = nil
            return
        }
        let from = transform(of: source)
        let to = current
        let turn = 2 * acos(min(abs(simd_dot(from.rotation.vector, to.rotation.vector)), 1))
        let duration = max(
            turn / Self.handoffTurnRate,
            simd_distance(from.translation, to.translation) / Self.handoffSpeed)
        handoff = (
            source, 0, min(max(duration, Self.handoffTime.lowerBound), Self.handoffTime.upperBound)
        )
    }

    /// The view of the camera in effect, before any blend: the camera mode's while it films,
    /// and the overview camera's otherwise, as the reader's pinches and drags leave it.
    private var current: Transform {
        follows && cameraMove == nil ? transform(of: .live(mode)) : view.transform
    }

    private func transform(of shot: Shot) -> Transform {
        switch shot {
        case .still(let transform):
            return transform
        case .live(.overview):
            return view.transform
        case .live(.follow):
            let pose = rig?.pose ?? opening
            return Transform(rotation: pose.rotation, translation: pose.eye)
        }
    }

    /// Moves the camera for this frame. While a camera takes over, the view blends to it.
    private func updateCamera(_ deltaTime: Float) {
        // After a long frame, such as the first after the app returns, the camera moves as
        // after a quarter second, which also bounds the rig's steps.
        let deltaTime = min(deltaTime, 0.25)
        // The rig also smooths the front for the overview camera, so it runs in either mode.
        // Every book has fallen once the last one tilts past `fallenTilt`; the rig then holds on
        // it while it lands, as the finale moves the camera away.
        if isReady, var rig {
            rig.step(
                .init(distance: frontDistance, started: started, done: next >= books.count),
                by: deltaTime)
            self.rig = rig
        }
        // The overview camera follows in either mode too, so a switch to it blends from where
        // it would be.
        if follows, isReady, cameraMove == nil { steer(deltaTime) }
        // The flight moves the camera while a book flies (see `aim`).
        guard flightViews == nil else { return }
        var shown = current
        if let ending, ending.movesCamera, !reducesMotion {
            shown = DominoFinale.view(
                from: transform(of: ending.source), to: ending.camera,
                progress: ending.clock / DominoFinale.moveTime)
        } else if let blend = handoff {
            let time = blend.time + deltaTime
            let share = DominoCameraRig.ease(min(time / blend.duration, 1))
            let from = transform(of: blend.from)
            shown = Transform(
                rotation: simd_slerp(from.rotation, shown.rotation, share),
                translation: from.translation + (shown.translation - from.translation) * share)
            handoff = time < blend.duration ? (blend.from, time, blend.duration) : nil
        }
        #if DEBUG
            let moved =
                shown.translation != camera.transform.translation
                || shown.rotation != camera.transform.rotation
        #endif
        camera.transform = shown
        #if DEBUG
            logCamera(deltaTime, moved: moved)
        #endif
    }

    /// Moves the overview camera toward `overviewGoal` (`DominoOverviewSpring`).
    private func steer(_ deltaTime: Float) {
        var spring = steering ?? DominoOverviewSpring(Self.lanes(of: view))
        spring.step(
            toward: Self.lanes(of: overviewGoal), lag: DominoOverviewSpring.lag, by: deltaTime)
        steering = spring
        let lanes = spring.value
        look(
            through: PileCamera(
                target: [lanes[0], 0, lanes[1]], yaw: lanes[3], zoom: exp(lanes[2]),
                pitch: lanes[4]))
    }

    /// Where the overview camera heads: once the chain has started, `followZoom`, centered
    /// along the rows, since the view's width fits a row, and across them at the rig's smoothed
    /// front, held where the view shows no table past the path's first and last rows; before
    /// then, the whole path. The finale takes the camera from there once every book has fallen.
    private var overviewGoal: PileCamera {
        guard started, let rig else { return overview }
        let front = rig.trackPoint(
            around: rig.estimate, spread: rig.path.period(rig.path.row(at: rig.estimate).row))
        // Half the depth of table the view shows, about: half its height at the target,
        // foreshortened by the pitch.
        let reach =
            PileCamera.distance / followZoom * tan(PileCamera.fieldOfView / 2)
            / sin(PileCamera.pitch)
        let bound = max(extent.y - reach, 0)
        return PileCamera(
            target: [
                overview.target.x, 0,
                min(max(front.y, overview.target.z - bound), overview.target.z + bound),
            ],
            zoom: followZoom)
    }

    /// The overview camera's lanes for `DominoOverviewSpring`.
    private static func lanes(of camera: PileCamera) -> SIMD8<Float> {
        [camera.target.x, camera.target.z, log(camera.zoom), camera.yaw, camera.pitch, 0, 0, 0]
    }

    #if DEBUG
        /// Simulator hook: `-BookwormsDominoCobweb <n>` zooms all the way in on the chain's nth
        /// cobweb, counting from 1, once every book stands.
        private func showDebugCobweb() {
            guard
                let number = UserDefaults.standard.string(forKey: "BookwormsDominoCobweb")
                    .flatMap(Int.init), cobwebs.indices.contains(number - 1)
            else { return }
            let index = cobwebs[number - 1].book
            let middle = (slots[index].position + slots[index + 1].position) / 2
            follows = false
            look(
                through: PileCamera(
                    target: [middle.x, slots[index].size.y, middle.y],
                    zoom: PileCamera.zoomRange.upperBound))
        }

        func mostBuriedID() -> Int? {
            BookFlight.mostBuried(books.map { $0.visualBounds(relativeTo: root) })
                .map { slots[$0].book.id }
        }

        /// Simulator hook: `-BookwormsDominoPush <seconds>` pushes the next book whenever the
        /// chain has stood or stalled that long, until every book has fallen or the chain
        /// changes.
        private func runDebugPushes(key: Key) async {
            guard
                let delay = UserDefaults.standard.string(forKey: "BookwormsDominoPush")
                    .flatMap(Double.init)
            else { return }
            while self.key == key, next < books.count {
                try? await Task.sleep(for: .seconds(delay))
                pushNext()
            }
        }

        /// Whether `-BookwormsDominoCameraLog YES` asks for the camera log, read once.
        private static let logsCamera = UserDefaults.standard.bool(
            forKey: "BookwormsDominoCameraLog")
        /// The most lines the camera log keeps: two minutes at 60 frames a second.
        private static let cameraLogLimit = 7200

        /// Simulator hook: with `-BookwormsDominoCameraLog YES`, logs each frame's time step,
        /// the front, the camera's position, direction, and roll, whether every book has
        /// fallen (`done` once the chain has also settled, `fallen` as soon as the last book
        /// tips), the seconds since the finale started (`finale`, -1 before then), and how
        /// upright the last book stands, from 1 standing to 0 lying flat, once every book
        /// stands. It writes the log to `Library/Caches/Bookworms/domino-camera.csv` every 60
        /// frames. The log ends once the books lie gathered and the camera has stopped
        /// (`moved`), or at `cameraLogLimit` lines.
        private func logCamera(_ deltaTime: Float, moved: Bool) {
            guard Self.logsCamera, isReady, !cameraLogEnded else { return }
            let eye = camera.transform.translation
            let forward = camera.transform.rotation.act([0, 0, -1])
            let right = camera.transform.rotation.act([1, 0, 0])
            let values: [Float] = [
                deltaTime, frontDistance, rig?.estimate ?? 0, eye.x, eye.y, eye.z, forward.x,
                forward.y, forward.z, status.phase == .done ? 1 : 0,
                asin(min(max(right.y, -1), 1)), next >= books.count ? 1 : 0, ending?.clock ?? -1,
                books.last.map { $0.transform.rotation.act([0, 1, 0]).y } ?? 1,
            ]
            cameraLog.append(values.map { String(format: "%.5f", $0) }.joined(separator: ","))
            cameraLogEnded =
                (status.phase == .finished && !moved) || cameraLog.count >= Self.cameraLogLimit
            guard cameraLogEnded || cameraLog.count.isMultiple(of: 60) else { return }
            let url = URL.cachesDirectory.appending(path: "Bookworms/domino-camera.csv")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (["dt,front,estimate,x,y,z,fx,fy,fz,done,roll,fallen,finale,last"] + cameraLog)
                .joined(separator: "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }

        /// With the camera log on, writes the Follow camera's inputs, with every cobweb as its
        /// distance and density and every book as its distance and height, to
        /// `Library/Caches/Bookworms/domino-rig.txt`, so a logged run can be replayed through
        /// `DominoCameraRig` off the device and measured against the books it framed.
        private func logRig(_ rig: DominoCameraRig, cobwebs: [DominoCameraRig.Cobweb]) {
            guard Self.logsCamera else { return }
            func line(_ name: String, _ values: [Float]) -> String {
                ([name] + values.map { String(format: "%.5f", $0) }).joined(separator: " ")
            }
            let lines = [
                line("rowLengths", rig.path.rowLengths),
                line("offset", [rig.offset.x, rig.offset.y]),
                line("length", [rig.length]), line("tallest", [rig.tallest]),
                line("aspect", [rig.aspect]),
                line("area", [rig.area.low.x, rig.area.low.y, rig.area.high.x, rig.area.high.y]),
                line(
                    "opening",
                    [
                        rig.opening.eye.x, rig.opening.eye.y, rig.opening.eye.z,
                        rig.opening.target.x, rig.opening.target.y, rig.opening.target.z,
                    ]),
                "cobwebs "
                    + cobwebs.map { String(format: "%.4f:%.4f", $0.distance, $0.density) }
                    .joined(separator: ","),
                "books "
                    + slots.map { String(format: "%.4f:%.4f", $0.distance, $0.size.y) }
                    .joined(separator: ","),
            ]
            let url = URL.cachesDirectory.appending(path: "Bookworms/domino-rig.txt")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    #endif
}

extension DominoScene: LiftingScene {}
