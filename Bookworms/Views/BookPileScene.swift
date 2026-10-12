import CoreMotion
import RealityKit
import SwiftUI
import UIKit

/// The pile's camera, and how points on the screen map onto the table.
///
/// Scene units are decimeters, so a book is 1.7 to 2.8 units long (see `BookShape`). The table
/// is the plane y = 0. The camera looks at `target` from `distance / zoom` away, pitched down by
/// `pitch` and turned about the vertical axis by `yaw`. The field of view is vertical, as
/// RealityKit applies it, so a narrower view sees less of the table from side to side.
struct PileCamera: Equatable {
    static let fieldOfView: Float = 38 * .pi / 180
    /// The pitch the pile and the dominoes' overview look down at.
    static let pitch: Float = 62 * .pi / 180
    static let distance: Float = 30
    static let zoomRange: ClosedRange<Float> = 1...2.5

    var target = SIMD3<Float>.zero
    var yaw: Float = 0
    var zoom: Float = 1
    /// Another pitch lets pinches and drags take over from the dominoes' Follow camera, which
    /// looks down less steeply, without tilting the view.
    var pitch = Self.pitch

    var rotation: simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
    }

    var transform: Transform {
        Transform(
            rotation: rotation, translation: target + rotation.act([0, 0, Self.distance / zoom]))
    }

    /// The ray from the camera through a point in normalized device coordinates: x runs from -1
    /// at the left edge to 1 at the right, and y from -1 at the bottom to 1 at the top.
    func ray(ndc: SIMD2<Float>, aspect: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let slope = tan(Self.fieldOfView / 2)
        let direction = simd_normalize(SIMD3(ndc.x * slope * aspect, ndc.y * slope, -1))
        return (transform.translation, rotation.act(direction))
    }

    /// Where `point` appears in normalized device coordinates, the inverse of `ray`.
    func project(_ point: SIMD3<Float>, aspect: Float) -> SIMD2<Float> {
        let local = rotation.inverse.act(point - transform.translation)
        return SIMD2(local.x / aspect, local.y) / (-local.z * tan(Self.fieldOfView / 2))
    }

    /// Where `ray` meets the horizontal plane at `height`, or `nil` if it never does.
    static func intersect(
        _ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>), height: Float
    ) -> SIMD3<Float>? {
        guard abs(ray.direction.y) > 1e-4 else { return nil }
        let distance = (height - ray.origin.y) / ray.direction.y
        return distance > 0 ? ray.origin + ray.direction * distance : nil
    }

    /// The pose that shows a book of `size` (see `BookShape.size`) as `Book3DView` draws it at
    /// `pose`, in a view of width-to-height `aspect`, to a camera at `camera` with this camera's
    /// field of view.
    ///
    /// `center` and `height` give the book's place in normalized device coordinates, where the
    /// view is 2 units tall. The book's middle sits on `center`, at the depth where its height
    /// spans `height`, as `Book3DView` draws its height at the book's middle. The book faces
    /// along the ray to the camera rather than the camera's axis, so off center it turns as it
    /// would in front of `Book3DView`'s camera, which looks straight at it.
    static func detailPose(
        seenFrom camera: Transform, center: SIMD2<Float>, height: Float, size: SIMD3<Float>,
        pose: BookPose, aspect: Float
    ) -> Transform {
        let slope = tan(Self.fieldOfView / 2)
        let depth = size.y / (height * slope)
        let local = SIMD3(center.x * slope * aspect, center.y * slope, -1) * depth
        // The book's axes: spine to fore edge, tail to head, and back to front cover.
        let front = simd_normalize(-local)
        let right = simd_normalize(simd_cross([0, 1, 0], front))
        let facing = simd_quatf(simd_float3x3(columns: (right, simd_cross(front, right), front)))
        // `Book3DView` turns by yaw, then tips by pitch about the view's horizontal axis, with y
        // pointing down, so its negative pitch tips the head toward the viewer.
        let turn =
            simd_quatf(angle: Float(-pose.pitch), axis: [1, 0, 0])
            * simd_quatf(angle: Float(pose.yaw), axis: [0, 1, 0])
        return Transform(
            rotation: camera.rotation * facing * turn,
            translation: camera.translation + camera.rotation.act(local)
        )
    }

    /// Where `point` shows from left to right to a camera at `camera`, as a stereo position
    /// from -0.8 to 0.8, so no hit plays from one side alone.
    static func pan(of point: SIMD3<Float>, seenFrom camera: Transform, aspect: Float) -> Float {
        let local = camera.rotation.inverse.act(point - camera.translation)
        let x = local.x / (max(-local.z, 0.01) * tan(fieldOfView / 2) * aspect)
        return min(1, max(-1, x)) * 0.8
    }

    /// The least height at which a ball of `radius` over `point`, given as x and z on the table,
    /// lies wholly above the top of the view of a camera at `camera`, with this camera's field
    /// of view; or `nil` when the top of the view does not slope down, so no height clears it.
    ///
    /// The top of the view is the plane through the camera along the view's top edge. Its
    /// outward normal is the camera's up axis tipped back by half the field of view.
    static func heightAboveView(
        of point: SIMD2<Float>, radius: Float, seenFrom camera: Transform
    ) -> Float? {
        let half = fieldOfView / 2
        let normal = camera.rotation.act([0, cos(half), sin(half)])
        guard normal.y > 0.05 else { return nil }
        let eye = camera.translation
        let across = normal.x * (point.x - eye.x) + normal.z * (point.y - eye.z)
        return eye.y + (radius - across) / normal.y
    }

    /// This camera moved `fraction` of the way to `other`.
    func mixed(with other: PileCamera, _ fraction: Float) -> PileCamera {
        PileCamera(
            target: target + (other.target - target) * fraction,
            yaw: yaw + (other.yaw - yaw) * fraction, zoom: zoom + (other.zoom - zoom) * fraction,
            pitch: pitch + (other.pitch - pitch) * fraction)
    }
}

/// The part of the table the books stay on, with an invisible wall along each edge.
///
/// It is a trapezoid, symmetric about x = 0, that the default camera sees between the
/// navigation bar and the tab bar. Perspective makes its far edge, at the top of the screen,
/// wider than its near edge.
struct PileTray: Equatable {
    var farZ: Float
    var nearZ: Float
    var farHalfWidth: Float
    var nearHalfWidth: Float

    func halfWidth(at z: Float) -> Float {
        farHalfWidth + (nearHalfWidth - farHalfWidth) * (z - farZ) / (nearZ - farZ)
    }

    /// The corners on the table, clockwise from the far left as seen from above.
    var corners: [SIMD3<Float>] {
        [
            [-farHalfWidth, 0, farZ], [farHalfWidth, 0, farZ], [nearHalfWidth, 0, nearZ],
            [-nearHalfWidth, 0, nearZ],
        ]
    }

    /// `point` moved inside the tray, at least `margin` from its edges, at the same height.
    func clamp(_ point: SIMD3<Float>, margin: Float) -> SIMD3<Float> {
        let z = min(max(point.z, farZ + margin), nearZ - margin)
        let half = max(0, halfWidth(at: z) - margin)
        return [min(max(point.x, -half), half), point.y, z]
    }
}

extension PileTray {
    /// Fits the tray to what `camera` sees between `safeTop` and `safeBottom`, given as
    /// normalized device y coordinates, in a view of width-to-height `aspect`. The camera must
    /// look at the table's center without turning, as the default camera and a zoomed one do.
    ///
    /// A pile against the far or side walls rises toward the top or sides of the screen, so
    /// those walls stand where the view's edges meet a pile `pileHeight` high: room for the
    /// longest book, 2.8 units, standing on end on a 1.7-unit pile. `PileLayout.maximumVolume`
    /// keeps a pile of long books from rising much higher. A pile against the near wall rises
    /// toward the middle of the screen, so that wall stands where the bottom edge meets the
    /// table.
    init?(
        aspect: Float, safeTop: Float, safeBottom: Float, pileHeight: Float = 4.5,
        camera: PileCamera = PileCamera()
    ) {
        let top = camera.ray(ndc: [1, safeTop], aspect: aspect)
        let bottom = camera.ray(ndc: [1, safeBottom], aspect: aspect)
        guard let far = PileCamera.intersect(top, height: pileHeight),
            let nearSide = PileCamera.intersect(bottom, height: pileHeight),
            let near = PileCamera.intersect(bottom, height: 0)
        else { return nil }
        let sides = PileTray(
            farZ: far.z, nearZ: nearSide.z, farHalfWidth: far.x, nearHalfWidth: nearSide.x)
        let margin: Float = 0.4
        self.init(
            farZ: far.z + margin, nearZ: near.z - margin,
            farHalfWidth: sides.halfWidth(at: far.z + margin) - margin,
            nearHalfWidth: sides.halfWidth(at: near.z - margin) - margin)
    }

    /// Fits the tray between the bars that cover `viewport`'s edges, as `camera` sees it.
    init?(viewport: PileViewport, pileHeight: Float = 4.5, camera: PileCamera = PileCamera()) {
        let height = Float(viewport.size.height)
        guard viewport.size.width > 0, height > 0 else { return nil }
        self.init(
            aspect: Float(viewport.size.width) / height,
            safeTop: 1 - 2 * Float(viewport.insets.top) / height,
            safeBottom: -1 + 2 * Float(viewport.insets.bottom) / height, pileHeight: pileHeight,
            camera: camera)
    }

    /// The tray's area on the table, in square units.
    var area: Float { (farHalfWidth + nearHalfWidth) * (nearZ - farZ) }

    /// The tray shrunk by `factor` toward its middle.
    func scaled(by factor: Float) -> PileTray {
        let middle = (farZ + nearZ) / 2
        return PileTray(
            farZ: middle + (farZ - middle) * factor, nearZ: middle + (nearZ - middle) * factor,
            farHalfWidth: farHalfWidth * factor, nearHalfWidth: nearHalfWidth * factor)
    }

    /// The tray grown about its middle, if needed, until its depth and its narrower near edge
    /// both span at least `span`.
    func scaled(toFit span: Float) -> PileTray {
        scaled(by: max(1, span / min(nearZ - farZ, 2 * nearHalfWidth)))
    }
}

/// A book's starting pose in the pile.
struct PileSlot {
    let book: CloudBook
    var transform: Transform
    var spin: SIMD3<Float> = .zero
    /// The book's index among a drop's `PilePeriod`s, when the pile drops period by period.
    var period = 0
}

/// Book sizes, starting poses, and tilt gravity for the pile. Poses are repeatable for a seed.
enum PileLayout {
    /// About 0.56 g at decimeter scale. Full gravity makes a phone-sized pile fall too fast to
    /// follow.
    static let gravity: Float = 55
    static let waveSize = 16
    /// The least time from one wave to the next. It lets the previous wave's highest books
    /// fall below the next wave's lowest cells, under `airDrag`, before those books start.
    static let waveInterval = Duration.milliseconds(950)
    /// The linear damping of a live drop's falling books, as air drag, until they first touch
    /// something. A drop starts out of view, high above the table (see `spawnHeight(over:)`).
    /// Drag lands its books at 37 to 41 units a second, about as fast as a drop of 9 to 20
    /// units without drag, so about nine in ten land front cover up. Without drag they land at
    /// 51 to 62 units a second, and about twice as many land face down.
    static let airDrag: Float = 1
    /// Above the highest start a drop plan gives on an iPhone, with room for a book lifted over
    /// others (see `dropPlan`). The walls reach it.
    static let ceiling: Float = 44
    /// Half the largest book's diagonal, 3.72 units, and a little more: a book whose middle lies
    /// this far outside the view is wholly out of it.
    static let entryClearance: Float = 1.9
    /// How long after the last wave the box of **Phone is the box** closes: longer than a book
    /// takes to fall from the ceiling under `airDrag`, so none is still in the air.
    static let boxDelay = Duration.seconds(2.5)
    /// Half the longest book's length (`BookShape.longest`) plus a little, which keeps a new
    /// book clear of the walls.
    static let reach: Float = 1.5
    /// The share of a still image's or a video's books that start turned over (see
    /// `settleGroups`): about as many as land face down in the live pile.
    static let turnedOver = 0.05
    /// The most book volume a live drop takes, in liters, which an iPhone's tray holds between
    /// the bars. A typical library's 300 books take about 200 liters.
    static let maximumVolume: Float = 250
    /// The largest sideways gravity tilt allows, as a fraction of `gravity` (about 27 degrees).
    static let maximumTilt: Float = 0.5

    /// The first of `books`, in order: at most `count` of them, and only as many as
    /// `maximumVolume` holds, so a library of long books still fits between the bars.
    static func dropped(_ books: [CloudBook], count: Int) -> ArraySlice<CloudBook> {
        var volume: Float = 0
        for (index, book) in books.prefix(count).enumerated() {
            let size = BookShape(of: book, coverAspect: 2 / 3).size
            volume += size.x * size.y * size.z
            if volume > maximumVolume { return books.prefix(index) }
        }
        return books.prefix(count)
    }

    /// A book lying front cover up with its head to the left (-x) and its spine toward the
    /// camera (+z), so its spine reads left to right like `SpineView`.
    static let lyingFlat = simd_quatf(
        simd_float3x3(columns: ([0, 0, -1], [-1, 0, 0], [0, 1, 0])))

    /// The height from which a drop over `tray` starts: low enough to fall soon, and high enough
    /// that every book starts wholly out of view, by `entryClearance`, and falls in past the top
    /// of the screen, however the reader has turned or zoomed the camera.
    ///
    /// The top of the view is the plane through the camera along the view's top edge. It slopes
    /// down by the camera's pitch less half the field of view. A camera `distance` from its target
    /// sees a point `d` across the table from the target, on the side toward the camera, above
    /// that plane at heights over (`distance` × sin(half the field of view) + `d` × sin(slope)) /
    /// cos(slope). Turning can put any point of the tray on that side. Zooming in brings the
    /// camera nearer, and lets the target move toward the tray's edges (see
    /// `BookPileScene.moveCamera`), so `d` can grow by the target's reach. The height is linear
    /// in 1 / zoom, so it is largest at one end of the zoom range.
    static func spawnHeight(over tray: PileTray) -> Float {
        let half = PileCamera.fieldOfView / 2
        let slope = PileCamera.pitch - half
        let farthest = tray.corners.map { simd_length(SIMD2($0.x, $0.z)) }.max() ?? 0
        let reach = simd_length(SIMD2(tray.farHalfWidth, max(-tray.farZ, tray.nearZ)))
        return [PileCamera.zoomRange.lowerBound, PileCamera.zoomRange.upperBound]
            .map { zoom in
                let distance = PileCamera.distance / zoom
                let across = farthest + reach * (1 - 1 / zoom)
                return (distance * sin(half) + entryClearance + across * sin(slope)) / cos(slope)
            }
            .max() ?? 0
    }

    /// The seconds until the first of the books starting at `slots` can show in `camera`'s
    /// view: the least time one takes to fall, from rest under `gravity` and `airDrag`, until
    /// its middle comes within `entryClearance` of the plane along the view's top edge.
    static func entryDelay(of slots: some Sequence<PileSlot>, seenBy camera: PileCamera)
        -> TimeInterval
    {
        // The top plane's normal, pointing away from what the view shows.
        let half = PileCamera.fieldOfView / 2
        let normal = camera.rotation.act(SIMD3(0, cos(half), sin(half)))
        let eye = camera.transform.translation
        let drop =
            slots.map {
                (simd_dot(normal, $0.transform.translation - eye) - entryClearance) / normal.y
            }
            .min() ?? 0
        // A fall under drag has no closed-form time for a distance, so this steps through it.
        var time: Float = 0
        while gravity / airDrag * (time - (1 - exp(-airDrag * time)) / airDrag) < drop {
            time += 0.01
        }
        return TimeInterval(time)
    }

    /// Drop poses above the tray, in waves of `waveSize` books, from `spawnHeight(over:)` up.
    ///
    /// Each wave fills a 2 × 8 grid of cells once, in a shuffled order. Cells start at six
    /// heights 2.2 units apart, repeating every three rows, so books in a wave start spread out.
    /// Each book starts at a random yaw, front cover up but tumbled up to `tumble` radians
    /// (about 46 degrees by default), and spinning up to 2 radians a second about each level
    /// axis and 3 about the vertical, so it twirls more than it turns over as it falls. A tray
    /// too shallow to keep `reach` from its walls drops every book over its middle.
    ///
    /// Large books in nearby cells can still reach into each other, which the physics would
    /// resolve with a visible jolt. So each book, lowest first, rises above every lower book of
    /// its wave whose bounds, at the widest cover, overlap its own across the table. A typical
    /// library lifts about one book in a hundred, mostly by a centimeter or two.
    static func dropPlan(
        _ books: [CloudBook], in tray: PileTray, seed: UInt64, tumble: Float = 0.8
    ) -> [PileSlot] {
        let columns = 2
        let rows = waveSize / columns
        let base = spawnHeight(over: tray)
        var order: [Int] = []
        var slots = books.enumerated()
            .map { index, book in
                let wave = index / waveSize
                if index % waveSize == 0 {
                    func rank(_ cell: Int) -> Double {
                        ShareStyle.unit(seed, wave * waveSize + cell, 1)
                    }
                    order = (0..<waveSize).sorted { rank($0) < rank($1) }
                }
                let cell = order[index % waveSize]
                let (row, column) = cell.quotientAndRemainder(dividingBy: columns)
                func random(_ salt: UInt64) -> Float { Float(ShareStyle.unit(seed, book.id, salt)) }
                let depth = (Float(row) + 0.2 + 0.6 * random(2)) / Float(rows)
                let z =
                    (tray.farZ + tray.nearZ) / 2
                    + max(0, tray.nearZ - tray.farZ - 2 * reach) * (depth - 0.5)
                let across = (Float(column) + 0.2 + 0.6 * random(3)) / Float(columns) * 2 - 1
                let x = across * max(0, tray.halfWidth(at: z) - reach)
                let y = base + Float((row % 3) * 2 + column) * 2.2 + random(4) * 0.4
                let axis = random(5) * 2 * .pi
                let tumble = simd_quatf(
                    angle: (random(6) - 0.5) * 2 * tumble, axis: [cos(axis), 0, sin(axis)])
                let yaw = simd_quatf(angle: random(7) * 2 * .pi, axis: [0, 1, 0])
                return PileSlot(
                    book: book,
                    transform: Transform(
                        rotation: yaw * tumble * lyingFlat, translation: [x, y, z]),
                    spin: (SIMD3(random(8), random(9), random(10)) - 0.5) * [4, 6, 4])
            }
        for start in stride(from: 0, to: slots.count, by: waveSize) {
            let wave = (start..<min(start + waveSize, slots.count))
                .sorted {
                    (slots[$0].transform.translation.y, $0) < (
                        slots[$1].transform.translation.y, $1
                    )
                }
            let extents = wave.map { halfExtent(of: slots[$0]) }
            for rank in wave.indices {
                for below in 0..<rank {
                    let position = slots[wave[rank]].transform.translation
                    let lower = slots[wave[below]].transform.translation
                    let reach = extents[rank] + extents[below]
                    if abs(position.x - lower.x) < reach.x, abs(position.z - lower.z) < reach.z {
                        slots[wave[rank]].transform.translation.y = max(
                            position.y, lower.y + reach.y + 0.05)
                    }
                }
            }
        }
        return slots
    }

    /// Half the size of the box around `slot`'s book, at the widest cover, as it starts.
    private static func halfExtent(of slot: PileSlot) -> SIMD3<Float> {
        let half = BookShape(of: slot.book, coverAspect: 0.85).size / 2
        let turn = simd_float3x3(slot.transform.rotation)
        return abs(turn.columns.0) * half.x + abs(turn.columns.1) * half.y
            + abs(turn.columns.2) * half.z
    }

    /// Starting poses for a still image's pile, in groups that fall together, with heights
    /// above the pile so far.
    ///
    /// Books start over the middle 70 percent of `tray`, tilted a little and without spin. A
    /// fall that short turns no book over, so `turnedOver` of the books, rounded, start front
    /// cover down, about as many as land face down in the live pile. The seed picks them from
    /// the first half of `books`, which lands first and lower in the pile, so the top of the pile
    /// keeps its covers up; a pile of fewer than 10 books turns none over. A group's books start
    /// in up to three
    /// layers, 1.2, 2.45, and 3.7 units up, so they land within the 0.4 seconds before the next
    /// group; layers 1.25 apart clear two tilted books. A book takes the lowest layer that no
    /// book of its group within 3.8 units uses, since two books farther apart cannot touch: each
    /// reaches at most half its diagonal, 1.86 units, from its middle. A book with no free layer
    /// starts the next group.
    static func settleGroups(_ books: [CloudBook], in tray: PileTray, seed: UInt64)
        -> [[PileSlot]]
    {
        let turned =
            books.count < 10
            ? []
            : Set(
                books.prefix(books.count / 2).map(\.id)
                    .sorted { ShareStyle.unit(seed, $0, 12) < ShareStyle.unit(seed, $1, 12) }
                    .prefix(Int((Double(books.count) * turnedOver).rounded())))
        var groups: [[PileSlot]] = []
        var layers: [(spot: SIMD2<Float>, layer: Int)] = []
        for var slot in dropPlan(books, in: tray.scaled(by: 0.7), seed: seed, tumble: 0.25) {
            let spot = SIMD2(slot.transform.translation.x, slot.transform.translation.z)
            var taken = Set(layers.filter { simd_distance($0.spot, spot) < 3.8 }.map(\.layer))
            if groups.isEmpty || taken.count == 3 {
                groups.append([])
                layers = []
                taken = []
            }
            let layer = (0..<3).first { !taken.contains($0) } ?? 0
            layers.append((spot, layer))
            slot.transform.translation.y = 1.2 + Float(layer) * 1.25
            slot.spin = .zero
            if turned.contains(slot.book.id) {
                // Over about the book's length, so its outline stays where it was.
                slot.transform.rotation *= simd_quatf(angle: .pi, axis: [0, 1, 0])
            }
            groups[groups.count - 1].append(slot)
        }
        return groups
    }

    /// The books in `books` that `ids` lacks, when `books` keeps every book of `ids` in the
    /// same order; otherwise `nil`.
    static func added(to ids: [Int], in books: [CloudBook]) -> [CloudBook]? {
        var remaining = ids[...]
        var added: [CloudBook] = []
        for book in books {
            if book.id == remaining.first {
                remaining.removeFirst()
            } else {
                added.append(book)
            }
        }
        return remaining.isEmpty ? added : nil
    }

    /// Tidy stacks for Reduce Motion, listed bottom up so each book rests on the one before it.
    ///
    /// Rows of stacks run from the near wall to the far wall, each with as many stacks as its
    /// width allows, so stacks stay low enough to stand. Rows are 2.6 units deep and stacks 3
    /// units wide, more than the widest and longest books, 2.4 and 2.8 units. Books keep their
    /// order: the first books fill the nearest stacks, and each stack's first book lies on top.
    static func stackPlan(_ books: [CloudBook], in tray: PileTray) -> [PileSlot] {
        let rows = max(1, Int((tray.nearZ - tray.farZ) / 2.6))
        let rowDepth = (tray.nearZ - tray.farZ) / Float(rows)
        var stacks: [SIMD2<Float>] = []
        for row in 0..<rows {
            let z = tray.nearZ - (Float(row) + 0.5) * rowDepth
            // The tray narrows toward the viewer, so the row's near side limits its width.
            let half = tray.halfWidth(at: z + rowDepth / 2)
            let columns = max(1, Int(2 * half / 3))
            for column in 0..<columns {
                stacks.append([((Float(column) + 0.5) / Float(columns) * 2 - 1) * half, z])
            }
        }
        let perStack = max(1, (books.count + stacks.count - 1) / stacks.count)
        var slots: [PileSlot] = []
        for (stack, start) in stride(from: 0, to: books.count, by: perStack).enumerated() {
            var y: Float = 0
            for book in books[start..<min(start + perStack, books.count)].reversed() {
                let thickness = BookShape(of: book, coverAspect: 2 / 3).size.z
                // A slight turn and shift, so the stacks look placed by hand.
                let jitter = Float(ShareStyle.unit(0, book.id, 11)) - 0.5
                slots.append(
                    PileSlot(
                        book: book,
                        transform: Transform(
                            rotation: simd_quatf(angle: jitter * 0.06, axis: [0, 1, 0]) * lyingFlat,
                            translation: [
                                stacks[stack].x + jitter * 0.08, y + thickness / 2, stacks[stack].y,
                            ])))
                y += thickness
            }
        }
        return slots
    }

    /// The scene's gravity for a device gravity reading, both in the device's axes and in g,
    /// with the camera turned by `yaw` about the vertical axis.
    ///
    /// Only the change from `reference`, the reading when tilting began, counts, so the pile
    /// rests however the phone is held. Tipping the right edge down slides books toward the
    /// screen's right, and tipping the top edge down slides them up the screen, however the
    /// camera has turned. Gravity always presses books onto the table, with at most
    /// `maximumTilt` of it sideways and a small dead zone so a steady hand leaves the pile asleep.
    static func gravity(
        device: SIMD3<Double>, reference: SIMD3<Double>, yaw: Float
    ) -> SIMD3<Float> {
        let change = SIMD3<Float>(device - reference)
        var sideways = SIMD2(change.x, -change.y) * 1.4
        let length = simd_length(sideways)
        if length < 0.04 {
            sideways = .zero
        } else if length > maximumTilt {
            sideways *= maximumTilt / length
        }
        // The unturned camera's right is +x and its up the table is -z.
        return simd_quatf(angle: yaw, axis: [0, 1, 0])
            .act(
                SIMD3(sideways.x, -1, sideways.y) * gravity)
    }

    /// Where a dropped book's center of mass lies, in the book's axes (see `BookShape.size`),
    /// for a book of `size`: a quarter of its thickness behind its middle, toward the back board.
    ///
    /// A book that lands on an edge or leans against another then tips onto its back cover
    /// more often than onto its front, so more books end up cover up. Nothing shows it: a book
    /// lying flat rests the same way, and a tumbling book turns about a point at most about a
    /// centimeter off its middle.
    static func centerOfMass(of size: SIMD3<Float>) -> SIMD3<Float> { [0, 0, -size.z / 4] }

    /// Whether a book turned by `rotation` lies front cover up: its front cover's normal, the
    /// book's +z axis, within 45 degrees of straight up.
    static func isCoverUp(_ rotation: simd_quatf) -> Bool {
        rotation.act([0, 0, 1]).y > Float(0.5).squareRoot()
    }

    /// The middle of an image of `size` at the width-to-height `aspect`, as `Book3DView` fills
    /// and clips its front, so a cover outside a box's aspect range is trimmed, not stretched.
    static func crop(_ size: CGSize, to aspect: CGFloat) -> CGRect {
        let rect =
            size.width > size.height * aspect
            ? CGRect(
                x: (size.width - size.height * aspect) / 2, y: 0, width: size.height * aspect,
                height: size.height)
            : CGRect(
                x: 0, y: (size.height - size.width / aspect) / 2, width: size.width,
                height: size.width / aspect)
        return rect.integral
    }
}

/// The pile's RealityKit content: the desk and its lamp (`DeskStage`), invisible walls and
/// ceiling, and one rigid body per book (`BookFactory`).
///
/// Books arrive a wave at a time. Each wave waits for its own fonts and textures, and at most
/// `coverWait` for its covers, so the first books fall within a second or two while later
/// covers download. `loading` is set until a new pile's first wave, which also waits for the
/// room's light, falls. Every falling book starts out of view (`PileLayout.spawnHeight(over:)`)
/// and falls in past the top of the screen. A new drop reuses the parts of books whose look has
/// not changed. While the view shows the scene, collisions play taps and sounds through
/// `feedback`.
///
/// While it follows motion (`setTilt`), the pile tilts as `PileTilt` says, and a hard shake
/// throws the books. In **Phone is the box**, the box's walls and glass (`PileBox`) close once
/// nothing waits to fall, and gravity follows the phone while they are closed.
@MainActor
final class BookPileScene {
    /// The scene root, which runs the physics simulation.
    let root = Entity()
    /// Whether the device reports motion, which tilt and shaking need. The Simulator does not,
    /// unless a Debug build fakes it with `-BookwormsPileGravity`.
    static let canTilt: Bool = {
        #if DEBUG
            if debugGravity != nil { return true }
        #endif
        return CMMotionManager().isDeviceMotionAvailable
    }()

    private static let coverWait = Duration.seconds(1.5)

    /// The camera the pile is seen through, for a renderer that draws the scene without a view.
    let camera = PerspectiveCamera()
    /// Haptics and sounds for collisions, which `BookPileView` starts and stops.
    let feedback = ImpactFeedback()
    /// Set from a new pile's plan until its first books fall (see `planDrop`).
    let loading = SceneLoading()
    private let factory: BookFactory
    private let stage = DeskStage()
    private let shelf = Entity()
    private let walls = Entity()
    private lazy var motion = CMMotionManager()
    private var view = PileCamera()
    private var aspect: Float = 0.5
    private var tray: PileTray?
    private var cameraMove: (start: PileCamera, focus: SIMD3<Float>)?
    private var plan: [PileSlot] = []
    private var planKey: PlanKey?
    private var spawned = 0
    private var lastWave = ContinuousClock.now
    private var bookIDs: [Entity.ID: Int] = [:]
    /// The books of a live drop that have not yet touched anything, with their damping before
    /// `PileLayout.airDrag`.
    private var falling: [Entity.ID: Float] = [:]
    private var drag: Drag?
    /// Whether the books stand still in tidy stacks, as kinematic bodies. Picking up a book
    /// frees only that book and the books resting on it. Tall stacks of uneven books can slip
    /// as the simulation settles them, and Reduce Motion asks for no motion the reader did not
    /// start.
    private var holdsStill = false
    private var tiltReference: SIMD3<Double>?
    private var tilt = PileTilt.off
    /// Whether motion is sampled, for tilt and shakes.
    private var tracksMotion = false
    /// Counts down the seconds until a shake can throw the books again.
    private var shakeRest: TimeInterval = 0
    /// The box of **Phone is the box**, fitted with the tray, and its walls, which are in the
    /// scene while it is closed.
    private var box: PileBox?
    private let boxWalls = Entity()
    /// The drop's periods, when the pile drops period by period.
    private var periods: [PilePeriod]?
    private let calendar = PileCalendar()
    private var gravity = SIMD3<Float>(0, -PileLayout.gravity, 0)
    private var updates: EventSubscription?
    private var collisions: EventSubscription?
    /// The flight of a book lifted to its details, and the reader's camera when it lifted,
    /// which returns with the book.
    let lifter: BookLifter
    private var readerCamera = PileCamera()

    /// The walls' collision group, which a thrown-back book passes through.
    private static let wallGroup = CollisionGroup(rawValue: 1 << 1)

    private struct PlanKey: Equatable {
        let ids: [Int]
        let tidy: Bool
        let periods: TimeFrame?
        let generation: Int
    }

    /// A book held under a finger, steered toward `target` on a plane above where it was picked
    /// up, keeping its offset from the finger. It is kinematic, so it pushes other books aside.
    /// Among Reduce Motion's kinematic stacks it is dynamic instead: kinematic bodies pass
    /// through one another, and only a dynamic book is stopped by a stack.
    private struct Drag {
        let book: ModelEntity
        let height: Float
        let offset: SIMD3<Float>
        var target: SIMD3<Float>
        var velocity = SIMD3<Float>.zero
    }

    /// Creates an empty pile. `textureScale` multiplies the texture sizes, for still images that
    /// frame a few books closely; their GPU memory grows with its square.
    init(textureScale: CGFloat = 1) {
        factory = BookFactory(textureScale: textureScale)
        lifter = BookLifter(
            root: root, camera: camera, factory: factory, feedback: feedback,
            passes: Self.wallGroup)
        var simulation = PhysicsSimulationComponent()
        simulation.gravity = gravity
        simulation.solverIterations = .init(positionIterations: 12, velocityIterations: 2)
        root.components.set(simulation)
        camera.camera = PerspectiveCameraComponent(
            near: 0.5, far: 150, fieldOfViewInDegrees: PileCamera.fieldOfView * 180 / .pi,
            fieldOfViewOrientation: .vertical)
        camera.transform = view.transform
        root.addChild(camera)
        root.addChild(stage.root)
        root.addChild(shelf)
        root.addChild(calendar.label)
        factory.coverArrived = { [weak self] id, material in self?.retexture(id, cover: material) }
    }

    /// Calls `update` every frame, and plays collisions through `feedback`, while the view
    /// shows the scene. A thrown-back book's first hit lands it instead (see
    /// `BookLifter.handle`).
    func attach(to content: inout RealityViewCameraContent) {
        content.add(root)
        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.update(event.deltaTime)
        }
        collisions = content.subscribe(to: CollisionEvents.Began.self) { [weak self] event in
            guard let self else { return }
            land(event.entityA)
            land(event.entityB)
            guard !lifter.handle(event) else { return }
            feedback.collide(event, pan: pan)
        }
    }

    /// Where `point` shows from left to right on screen, as a stereo position from -0.8 to 0.8,
    /// so no hit plays from one side alone.
    private func pan(_ point: SIMD3<Float>) -> Float {
        min(1, max(-1, view.project(point, aspect: aspect).x)) * 0.8
    }

    /// Shows or hides the dust in the lamp's beam.
    func setDust(_ enabled: Bool) { stage.setDust(enabled) }

    // MARK: Building

    /// Adds the table, walls, and lights the first time the view has a size.
    private func build(_ viewport: PileViewport) {
        guard tray == nil, let tray = PileTray(viewport: viewport) else { return }
        aspect = Float(viewport.size.width / viewport.size.height)
        box = PileBox(viewport: viewport)
        build(tray)
    }

    /// Lays the lamp's pool over the tray, with its edges a little past the tray's corners.
    private func build(_ tray: PileTray) {
        self.tray = tray
        let middle = (tray.farZ + tray.nearZ) / 2
        stage.build(
            pool: [0, 0, middle],
            radius: simd_length(
                SIMD2(max(tray.farHalfWidth, tray.nearHalfWidth), tray.nearZ - middle)) * 1.05)
        root.addChild(walls)
        walls.addChild(Self.makeWalls(around: tray))
    }

    /// Static walls along the tray's edges and a ceiling above the drop height. They have no
    /// model, so books seem to bump into the edges of the screen.
    private static func makeWalls(around tray: PileTray) -> Entity {
        let walls = Entity()
        let material = PhysicsMaterialResource.generate(
            staticFriction: 0.1, dynamicFriction: 0.1, restitution: 0.3)
        func add(_ shape: ShapeResource, at position: SIMD3<Float>, yaw: Float = 0) {
            let wall = Entity()
            wall.components.set(
                CollisionComponent(
                    shapes: [shape], filter: CollisionFilter(group: wallGroup, mask: .all)))
            wall.components.set(
                PhysicsBodyComponent(massProperties: .default, material: material, mode: .static))
            wall.transform = Transform(
                rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: position)
            walls.addChild(wall)
        }
        let corners = tray.corners
        let center = corners.reduce(.zero, +) / Float(corners.count)
        for (index, start) in corners.enumerated() {
            let end = corners[(index + 1) % corners.count]
            let along = end - start
            var outward = simd_normalize(SIMD3(along.z, 0, -along.x))
            if simd_dot(outward, (start + end) / 2 - center) < 0 { outward = -outward }
            // Two units thick and long enough to close the corners, so a thrown book cannot
            // slip between walls.
            add(
                .generateBox(width: 2, height: PileLayout.ceiling, depth: simd_length(along) + 4),
                at: (start + end) / 2 + outward + [0, PileLayout.ceiling / 2, 0],
                yaw: atan2(along.x, along.z))
        }
        add(.generateBox(width: 90, height: 2, depth: 90), at: [0, PileLayout.ceiling + 1, 0])
        return walls
    }

    // MARK: Filling the pile

    /// Plans a drop of `books`, or tidy stacks when `tidy`, as `fill` does, without dropping
    /// any. Call it before `fill` to learn at once whether the plan kept the lifted book.
    ///
    /// With `periods` set, the books drop period by period through that frame (see
    /// `PileLayout.periods`). Otherwise, books added to a dropped list, such as a newly
    /// designed book under **Designed only**, join the books still waiting, when the list keeps
    /// the earlier books in their order. Any other change starts a new pile, which removes
    /// every book, the lifted one too.
    func planDrop(
        _ books: [CloudBook], tidy: Bool, periods: TimeFrame? = nil, generation: Int,
        viewport: PileViewport
    ) {
        build(viewport)
        guard let tray else { return }
        let periods = tidy ? nil : periods
        let key = PlanKey(
            ids: books.map(\.id), tidy: tidy, periods: periods, generation: generation)
        guard key != planKey else { return }
        if !tidy, periods == nil, let planKey, !planKey.tidy, planKey.periods == nil,
            planKey.generation == generation,
            let added = PileLayout.added(to: planKey.ids, in: books)
        {
            // Plans the waiting books again with the new ones, so the next wave starts in a
            // fresh set of cells.
            let waiting = plan[spawned...].map(\.book) + added
            plan =
                Array(plan[..<spawned])
                + PileLayout.dropPlan(waiting, in: tray, seed: UInt64(generation))
        } else if let periods {
            reset(keeping: Set(key.ids))
            let groups = PileLayout.periods(books, frame: periods)
            // Each period fills a fresh set of cells, from its own seed.
            plan = groups.enumerated()
                .flatMap { index, group in
                    PileLayout.dropPlan(
                        group.books, in: tray, seed: UInt64(generation) &+ UInt64(index) &* 7919
                    )
                    .map { slot in
                        var slot = slot
                        slot.period = index
                        return slot
                    }
                }
            self.periods = groups
            holdsStill = false
            loading.isLoading = !plan.isEmpty
        } else {
            reset(keeping: Set(key.ids))
            plan =
                tidy
                ? PileLayout.stackPlan(books, in: tray)
                : PileLayout.dropPlan(books, in: tray, seed: UInt64(generation))
            holdsStill = tidy
            loading.isLoading = !plan.isEmpty
        }
        planKey = key
        // Opens the box before the new books spawn above it.
        updateBox()
    }

    /// Drops `books` onto the table, or stacks them when `tidy`, continuing a drop that an
    /// earlier call started for the same books and generation (see `planDrop`).
    ///
    /// Books added to a dropped list fall onto the pile as it is, after the books still
    /// waiting. Returns when every book is in the pile or the task is cancelled. A cancelled
    /// drop, such as one interrupted by opening a book, resumes at its next wave.
    ///
    /// Period by period, a wave never spans two periods, and each period's first wave waits
    /// `PileLayout.periodInterval` after the last period's, then shows the period's name and
    /// season through `calendar`.
    func fill(
        _ books: [CloudBook], tidy: Bool, periods: TimeFrame? = nil, generation: Int,
        viewport: PileViewport, model: AppModel
    ) async {
        let began = ContinuousClock.now
        planDrop(books, tidy: tidy, periods: periods, generation: generation, viewport: viewport)
        guard tray != nil else { return }
        let key = PlanKey(
            ids: books.map(\.id), tidy: tidy, periods: tidy ? nil : periods,
            generation: generation)
        while spawned < plan.count {
            let period = plan[spawned].period
            let starts = self.periods != nil && (spawned == 0 || plan[spawned - 1].period != period)
            let full = min(spawned + PileLayout.waveSize, plan.count)
            let end = plan[spawned..<full].firstIndex { $0.period != period } ?? full
            let wave = plan[spawned..<end]
            let next = plan[end..<min(end + PileLayout.waveSize, plan.count)]
            await factory.prepare(
                wave.map(\.book), prefetching: next.map(\.book), coverWait: Self.coverWait,
                model: model)
            // Renders the period's name while its books wait to fall.
            let group = starts ? self.periods?[period] : nil
            var label: TextureResource?
            if let group, let span = group.span {
                label = await PileCalendar.texture(
                    YearInBooksCard.busiest(span, isCompact: false).value, season: group.season)
            }
            // A new pile's first wave falls at once, since no earlier books are left to clear.
            if !tidy, spawned > 0 {
                try? await Task.sleep(
                    until: lastWave
                        + (starts ? PileLayout.periodInterval : PileLayout.waveInterval))
            }
            // Keeps the first books until the room's light is ready, so they enter lit.
            if spawned == 0 { await stage.lit() }
            guard !Task.isCancelled, planKey == key else { return }
            for slot in wave {
                guard let book = spawn(slot, mode: holdsStill ? .kinematic : .dynamic),
                    !holdsStill
                else { continue }
                startFall(book)
            }
            if let group, let groups = self.periods {
                calendar.show(
                    isFlying ? nil : label, season: group.season,
                    isLast: period == groups.count - 1, facing: view)
            }
            spawned += wave.count
            lastWave = .now
            if loading.isLoading {
                // Keeps a spinner that has shown until the first books can show, so it fades
                // out as they fall into view. A quicker setup, such as **Drop again**, shows none.
                if !holdsStill, lastWave - began > .seconds(SceneLoading.showDelay) {
                    try? await Task.sleep(
                        for: .seconds(PileLayout.entryDelay(of: wave, seenBy: view)))
                }
                guard planKey == key else { return }
                loading.isLoading = false
            }
        }
        #if DEBUG
            await runDebugActions()
            if root.scene != nil, UserDefaults.standard.bool(forKey: "BookwormsPileCoverLog") {
                await waitForRest()
                let frame = UserDefaults.standard.string(forKey: "BookwormsPileFrame") ?? ""
                let order = self.periods == nil ? "" : " by period"
                logCovers("live \(frame)\(order) gen \(generation)")
            }
        #endif
    }

    /// Removes every book and returns the camera and gravity to rest. Keeps the parts of the
    /// books in `ids` for the next drop.
    private func reset(keeping ids: Set<Int>) {
        shelf.children.removeAll()
        bookIDs = [:]
        falling = [:]
        drag = nil
        cameraMove = nil
        lifter.reset()
        spawned = 0
        periods = nil
        calendar.reset()
        stage.setLampColor(nil)
        factory.release(keeping: ids)
        view = PileCamera()
        #if DEBUG
            // Simulator screenshot hooks: `-BookwormsPileZoom <1...2.5>` and
            // `-BookwormsPileYaw <radians>` set the camera for each drop.
            let defaults = UserDefaults.standard
            view.zoom = PileCamera.zoomRange.clamp(defaults.float(forKey: "BookwormsPileZoom"))
            view.yaw = defaults.float(forKey: "BookwormsPileYaw")
        #endif
        camera.transform = view.transform
        tiltReference = nil
        setGravity([0, -PileLayout.gravity, 0])
    }

    /// Removes the books and their textures while the pile is out of sight. The next `fill`
    /// drops the books again.
    func release() {
        reset(keeping: [])
        plan = []
        planKey = nil
    }

    /// Drops `books` onto `tray` for a still image seen through `camera`, without a view.
    /// `step` advances the simulation by one 60 Hz frame, so the caller's renderer runs it.
    ///
    /// Unlike `fill`, every book is built before the first one falls, and covers get up to 10
    /// seconds to load. Books start over the middle 70 percent of the tray, just above the pile
    /// so far, tilted a little and without spin, so they land close to where they start and the
    /// side up they start: front cover up, except the few that `PileLayout.settleGroups` turns
    /// over. Each group falls for 0.4 seconds before the next one appears, and the pile settles
    /// for 2.5 seconds inside the walls, which keep it compact. The walls stand at least 3.9
    /// units apart, so even a tray framed closely around one book lets it lie flat at any turn.
    /// The walls then go for a last half second, so no book stays propped against one. Every 10
    /// steps the interface gets a turn, and a cancelled task stops with `CancellationError`.
    func settle(
        _ books: [CloudBook], on tray: PileTray, camera: PileCamera, seed: UInt64,
        model: AppModel, step: () throws -> Void
    ) async throws {
        look(through: camera)
        // Room for the largest book, 3.72 units corner to corner, tilted a little.
        build(tray.scaled(toFit: 3.9))
        await factory.prepare(books, prefetching: [], coverWait: .seconds(10), model: model)
        await stage.lit()
        func run(_ steps: Int) async throws {
            for index in 0..<steps {
                if index % 10 == 0 {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                try step()
            }
        }
        for group in PileLayout.settleGroups(books, in: tray, seed: seed) {
            let top = max(0, shelf.visualBounds(relativeTo: root).max.y)
            for var slot in group {
                slot.transform.translation.y += top
                spawn(slot, mode: .dynamic)
            }
            try await run(24)
        }
        try await run(150)
        walls.removeFromParent()
        try await run(30)
    }

    /// Shows the pile through `camera`.
    func look(through camera: PileCamera) {
        view = camera
        self.camera.transform = camera.transform
    }

    /// The corners of each book's bounding box, in scene coordinates.
    var bookCorners: [SIMD3<Float>] {
        shelf.children.flatMap { book in
            let bounds = book.visualBounds(relativeTo: root)
            return (0..<8)
                .map { corner -> SIMD3<Float> in
                    SIMD3(
                        corner & 1 == 0 ? bounds.min.x : bounds.max.x,
                        corner & 2 == 0 ? bounds.min.y : bounds.max.y,
                        corner & 4 == 0 ? bounds.min.z : bounds.max.z)
                }
        }
    }

    /// Puts a cover that arrived after its book was built onto the book in the pile.
    private func retexture(_ id: Int, cover: any RealityKit.Material) {
        for case let book as ModelEntity in shelf.children where bookIDs[book.id] == id {
            book.children.first?.components[ModelComponent.self]?
                .materials[
                    Int(BookSlot.cover)] = cover
        }
    }

    /// Adds a book at its slot's pose and spin, and returns it. A dynamic book's center of mass
    /// moves toward its back board (see `PileLayout.centerOfMass`); a still stack's books keep
    /// theirs.
    @discardableResult
    private func spawn(_ slot: PileSlot, mode: PhysicsBodyMode) -> ModelEntity? {
        guard let book = factory.makeBook(slot.book.id, mode: mode, lighting: stage.lighting),
            let size = factory.parts[slot.book.id]?.shape.size
        else { return nil }
        if mode == .dynamic {
            book.components[PhysicsBodyComponent.self]?.massProperties.centerOfMass.position =
                PileLayout.centerOfMass(of: size)
        }
        book.components.set(PhysicsMotionComponent(angularVelocity: slot.spin))
        book.transform = slot.transform
        shelf.addChild(book)
        bookIDs[book.id] = slot.book.id
        return book
    }

    /// Slows a live drop's falling book with `PileLayout.airDrag` until it first touches
    /// something (see `land`).
    private func startFall(_ book: ModelEntity) {
        guard let body = book.components[PhysicsBodyComponent.self] else { return }
        falling[book.id] = body.linearDamping
        book.components[PhysicsBodyComponent.self]?.linearDamping = PileLayout.airDrag
    }

    /// Gives a falling book that touches something its own damping back, so it slides, tumbles,
    /// and flies when thrown as any other book does.
    private func land(_ entity: Entity) {
        guard let damping = falling.removeValue(forKey: entity.id) else { return }
        entity.components[PhysicsBodyComponent.self]?.linearDamping = damping
    }

    /// The ID of the book an entity belongs to, or `nil` for the table.
    func bookID(for entity: Entity) -> Int? { bookIDs[entity.id] }

    // MARK: Interaction

    private func update(_ deltaTime: TimeInterval) {
        feedback.advance(by: deltaTime)
        lifter.update(by: deltaTime, aim: aim)
        if let drag {
            // Steers the held book toward its target. Velocity, rather than a new position,
            // lets the physics push other books out of the way.
            var velocity = (drag.target - drag.book.position(relativeTo: root)) * 14
            let speed = simd_length(velocity)
            if speed > 50 { velocity *= 50 / speed }
            drag.book.components.set(PhysicsMotionComponent(linearVelocity: velocity))
            self.drag?.velocity = velocity
        }
        if tilt == .box {
            updateBox()
            if !isFlying { squareView(by: Float(deltaTime)) }
        }
        if let reading = motionReading() {
            switch tilt {
            case .table:
                let device = reading.gravity
                if tiltReference == nil { tiltReference = device }
                setGravity(
                    PileLayout.gravity(
                        device: device, reference: tiltReference ?? device, yaw: view.yaw))
            case .box where boxWalls.parent != nil:
                setGravity(PileLayout.boxGravity(device: reading.gravity, camera: view.rotation))
            default: break
            }
            shakeRest -= deltaTime
            shake(reading.acceleration)
        }
        if let color = calendar.advance(by: Float(deltaTime)) { stage.setLampColor(color) }
    }

    /// Picks up `entity` if it is a book, or moves the held book under the finger on `ray`.
    func drag(_ entity: Entity, along ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)?) {
        guard let ray, let tray else { return }
        if drag == nil {
            guard let book = entity as? ModelEntity, bookIDs[book.id] != nil else { return }
            let position = book.position(relativeTo: root)
            guard let grabbed = PileCamera.intersect(ray, height: position.y) else { return }
            if holdsStill {
                // Lets the books resting on this one settle into its place. Stacks stand at
                // least 2.3 units apart, so other stacks hold still.
                for case let other as ModelEntity in shelf.children {
                    let resting = other.position(relativeTo: root)
                    if resting.y > position.y,
                        simd_distance(SIMD2(resting.x, resting.z), SIMD2(position.x, position.z))
                            < 0.5
                    {
                        setMode(.dynamic, of: other)
                    }
                }
            }
            setMode(holdsStill ? .dynamic : .kinematic, of: book)
            let height = min(position.y + 1.2, PileLayout.ceiling - 2)
            drag = Drag(
                book: book, height: height, offset: (position - grabbed) * [1, 0, 1],
                target: [position.x, height, position.z])
        }
        guard let drag, let point = PileCamera.intersect(ray, height: drag.height) else { return }
        let target = tray.clamp(point + drag.offset, margin: 1)
        // A held book is kinematic, which walls do not stop.
        self.drag?.target =
            boxWalls.parent != nil ? box?.clamp(target, margin: 1.2) ?? target : target
    }

    /// Lets go of the held book with the velocity it had, tumbling forward a little.
    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        setMode(.dynamic, of: drag.book)
        let speed = simd_length(drag.velocity)
        let velocity = speed > 40 ? drag.velocity * 40 / speed : drag.velocity
        drag.book.components.set(
            PhysicsMotionComponent(
                linearVelocity: velocity, angularVelocity: simd_cross([0, 1, 0], velocity) * 0.15))
    }

    private func setMode(_ mode: PhysicsBodyMode, of book: ModelEntity) {
        book.components[PhysicsBodyComponent.self]?.mode = mode
    }

    /// Zooms toward the point under `focus` and turns the camera about the pile. In **Phone is
    /// the box**, the camera only zooms, since the box fits the unturned view.
    func moveCamera(magnification: CGFloat, rotation: Angle, focus: CGPoint?, in size: CGSize) {
        guard let tray, size.width > 0, size.height > 0 else { return }
        if cameraMove == nil {
            let point = focus ?? CGPoint(x: size.width / 2, y: size.height / 2)
            let ndc = SIMD2(
                Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
            let ray = view.ray(ndc: ndc, aspect: aspect)
            cameraMove = (view, PileCamera.intersect(ray, height: 0) ?? view.target)
        }
        guard let move = cameraMove else { return }
        view.zoom = PileCamera.zoomRange.clamp(move.start.zoom * Float(magnification))
        if tilt != .box { view.yaw = move.start.yaw - Float(rotation.radians) }
        // Keeps the focus point in place while zooming. Zoomed out fully, the camera returns
        // to the tray's center, and zoomed in it may move only as far as the tray reaches.
        let target = move.focus + (move.start.target - move.focus) * move.start.zoom / view.zoom
        let reach = 1 - 1 / view.zoom
        view.target = [
            min(max(target.x, -tray.farHalfWidth * reach), tray.farHalfWidth * reach), 0,
            min(max(target.z, tray.farZ * reach), tray.nearZ * reach),
        ]
        camera.transform = view.transform
    }

    func endCameraMove() { cameraMove = nil }

    /// Eases a turned view back to the nearest whole turn, where the box of **Phone is the
    /// box** fits it: its glass parallel to the screen and its sides along the screen's edges.
    private func squareView(by deltaTime: Float) {
        let square = (view.yaw / (2 * .pi)).rounded() * 2 * .pi
        guard view.yaw != square else { return }
        view.yaw += (square - view.yaw) * min(1, deltaTime * 4)
        if abs(view.yaw - square) < 0.002 { view.yaw = square }
        camera.transform = view.transform
    }

    // MARK: Details

    /// The ID of the lifted book, if any.
    var liftedID: Int? { lifter.liftedID }

    /// Whether a book is lifted or on its way back, when another book cannot lift.
    var isFlying: Bool { lifter.isFlying }

    /// Starts lifting the book with `id` toward its details, which `BookLifter.place` places,
    /// and returns the seconds until it gets there. Returns `nil`, leaving the pile as it was,
    /// when the book is not in the pile or the view does not show the scene.
    ///
    /// The camera eases to its default framing, keeping its turn, so the book in front of it
    /// clears the pile at any zoom (see `aim`). The pile keeps simulating behind the veil.
    func lift(_ id: Int) -> Double? {
        guard !isFlying, root.scene != nil, factory.parts[id] != nil,
            let book = shelf.children.first(where: { bookIDs[$0.id] == id }) as? ModelEntity
        else { return nil }
        endDrag()
        cameraMove = nil
        calendar.endGlow()
        readerCamera = view
        return lifter.lift(
            book, id: id, among: shelf.children.compactMap { $0 as? ModelEntity },
            aspect: aspect)
    }

    /// Throws the lifted book back at the place it left (see `BookLifter.throwBack`).
    func throwBack() { lifter.throwBack() }

    /// Ends a lift or a throw at once: puts the book back above the place it left, at rest, in
    /// its pile textures, and the camera and veil as they were.
    func dropLifted() { lifter.drop(aim: aim) }

    /// Moves the camera `share` of the way from the reader's camera to its default framing,
    /// with the reader's turn, for a book's flight.
    private func aim(_ share: Float) {
        look(through: readerCamera.mixed(with: PileCamera(yaw: readerCamera.yaw), share))
    }

    // MARK: Tilt and shake

    /// Sets how the pile follows the phone's tilt, and starts or stops sampling motion, which
    /// tilt and shakes need. `.off` samples nothing. Without sampling, gravity points straight
    /// down, except in a closed box, which keeps its last gravity until sampling resumes, since
    /// the phone has not moved for it. A new mode or a new start of sampling in `.table` takes
    /// a new reference.
    func setTilt(_ tilt: PileTilt, tracking: Bool) {
        let tracking = tracking && tilt != .off && Self.canTilt
        if tilt != self.tilt || tracking != tracksMotion { tiltReference = nil }
        self.tilt = tilt
        if tracking != tracksMotion {
            tracksMotion = tracking
            if tracking {
                // Shakes peak for a few hundredths of a second.
                motion.deviceMotionUpdateInterval = 1 / 60
                motion.startDeviceMotionUpdates()
            } else {
                motion.stopDeviceMotionUpdates()
            }
        }
        // In `.box`, the next update gives the box's gravity once the box is closed.
        let keepsGravity =
            (tracking && tilt == .table) || (tilt == .box && boxWalls.parent != nil)
        if !keepsGravity { setGravity([0, -PileLayout.gravity, 0]) }
        updateBox()
    }

    /// The device's gravity and the acceleration the user gives it, in g in the device's axes,
    /// while motion is sampled.
    private func motionReading() -> (gravity: SIMD3<Double>, acceleration: SIMD3<Double>)? {
        guard tracksMotion else { return nil }
        if let sample = motion.deviceMotion {
            return (
                [sample.gravity.x, sample.gravity.y, sample.gravity.z],
                [sample.userAcceleration.x, sample.userAcceleration.y, sample.userAcceleration.z]
            )
        }
        #if DEBUG
            if let gravity = Self.debugGravity { return (gravity, .zero) }
        #endif
        return nil
    }

    /// Throws every free book against a hard shake's jolt (see `PileLayout.shakeKick`), each a
    /// little differently and tumbling, at most once per `PileLayout.shakeRest`. The books'
    /// hits play through `feedback` as any others do. Held, lifted, and returning books, and
    /// Reduce Motion's still stacks, stay put.
    private func shake(_ acceleration: SIMD3<Double>) {
        guard shakeRest <= 0, !holdsStill,
            let kick = PileLayout.shakeKick(
                acceleration: acceleration, camera: view.rotation, up: -simd_normalize(gravity))
        else { return }
        shakeRest = PileLayout.shakeRest
        let speed = simd_length(kick)
        for case let book as ModelEntity in shelf.children
        where book !== drag?.book && book !== lifter.book
            && book.components[PhysicsBodyComponent.self]?.mode == .dynamic
        {
            let mass = book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0.5
            book.applyLinearImpulse(
                (kick + .random(in: -0.35...0.35) * speed) * mass, relativeTo: nil)
            book.applyAngularImpulse(.random(in: -1...1) * mass * 2, relativeTo: nil)
        }
    }

    /// Closes the box of **Phone is the box** once nothing waits to fall, `PileLayout.boxDelay`
    /// after the last wave, and opens it in the other modes, while books wait to fall, which
    /// start above it, and while a book flies to or from its details, with gravity straight down
    /// until it closes again.
    ///
    /// Books past the glass or the sides when it closes, such as one high on the pile against
    /// the far wall, which the box's top side cuts off, move just inside them. They are off
    /// screen there. Books lying on the table stay put.
    private func updateBox() {
        let closes =
            tilt == .box && !holdsStill && !isFlying && spawned == plan.count
            && ContinuousClock.now - lastWave > PileLayout.boxDelay
        guard closes != (boxWalls.parent != nil) else { return }
        guard closes else {
            boxWalls.removeFromParent()
            setGravity([0, -PileLayout.gravity, 0])
            return
        }
        guard let box else { return }
        if boxWalls.children.isEmpty { boxWalls.addChild(box.makeWalls(group: Self.wallGroup)) }
        for case let book as ModelEntity in shelf.children where book !== drag?.book {
            let position = book.position(relativeTo: root)
            guard !box.contains(position, margin: 0.3) else { continue }
            // ponytail: the book may land inside another and be pushed apart; check the
            // books near it if that ever shows.
            book.setPosition(box.clamp(position, margin: 1.2), relativeTo: root)
            book.components.set(PhysicsMotionComponent())
        }
        root.addChild(boxWalls)
    }

    /// Changes gravity and wakes the books, which sleeping bodies need to notice the change.
    /// Small changes are ignored, so a resting pile stays asleep.
    private func setGravity(_ gravity: SIMD3<Float>) {
        guard simd_distance(gravity, self.gravity) > PileLayout.gravity * 0.03 else { return }
        self.gravity = gravity
        root.components[PhysicsSimulationComponent.self]?.gravity = gravity
        for case let book as ModelEntity in shelf.children where book !== drag?.book {
            book.applyLinearImpulse(simd_normalize(gravity) * 1e-4, relativeTo: nil)
        }
    }

    #if DEBUG
        /// Simulator hook: `-BookwormsPileGravity <x,y,z>` stands in for the device's gravity,
        /// in g in its axes, while the pile samples motion, so the tilt modes work without
        /// motion hardware. For example, `0,0,1` holds the phone face down.
        private static let debugGravity = vector("BookwormsPileGravity")

        /// The launch argument `key` as a vector of three comma-separated numbers. Spaces
        /// around a number are ignored, so a value can start with a space before a minus sign,
        /// which would otherwise make the argument parser read it as a key.
        private static func vector(_ key: String) -> SIMD3<Double>? {
            let parts = UserDefaults.standard.string(forKey: key)?.split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard let parts, parts.count == 3 else { return nil }
            return SIMD3(parts[0], parts[1], parts[2])
        }

        /// Simulator hooks that run once a drop finishes: `-BookwormsPileFocus <book ID>` zooms
        /// all the way in on that book three seconds later, `-BookwormsPileTilt <x,y>` applies a
        /// device tilt (the change in device gravity, in g), `-BookwormsPileShake <x,y,z>`
        /// shakes the phone with that user acceleration (in g, in the device's axes), and
        /// `-BookwormsPileThrow YES` throws the top book through the drag path. The last three
        /// wait four seconds.
        private func runDebugActions() async {
            let defaults = UserDefaults.standard
            if let id = defaults.string(forKey: "BookwormsPileFocus").flatMap(Int.init),
                let book = shelf.children.first(where: { bookIDs[$0.id] == id })
            {
                try? await Task.sleep(for: .seconds(3))
                var camera = view
                camera.target = book.position(relativeTo: root)
                camera.zoom = PileCamera.zoomRange.upperBound
                look(through: camera)
            }
            let tilt = defaults.string(forKey: "BookwormsPileTilt")?.split(separator: ",")
                .compactMap { Double($0) }
            let throwsBook = defaults.bool(forKey: "BookwormsPileThrow")
            let jolt = Self.vector("BookwormsPileShake")
            guard tilt?.count == 2 || throwsBook || jolt != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if let tilt, tilt.count == 2 {
                setGravity(
                    PileLayout.gravity(
                        device: [tilt[0], tilt[1] - 1, 0], reference: [0, -1, 0], yaw: view.yaw))
            }
            if let jolt { shake(jolt) }
            guard throwsBook, let book = Array(shelf.children).last else { return }
            let start = book.position(relativeTo: root)
            drag(book, along: (start + [0, 20, 0], [0, -1, 0]))
            for step in 1...20 {
                try? await Task.sleep(for: .milliseconds(16))
                let point = start + [Float(step) * 0.25, 0, -Float(step) * 0.4]
                drag(book, along: (point + [0, 20, 0], [0, -1, 0]))
            }
            endDrag()
        }

        func mostBuriedID() -> Int? {
            let books = shelf.children.compactMap { $0 as? ModelEntity }
            return BookFlight.mostBuried(books.map { $0.visualBounds(relativeTo: root) })
                .flatMap { bookIDs[books[$0].id] }
        }

        /// Waits, for at most 20 seconds, until no book moves faster than a crawl.
        private func waitForRest() async {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                let moving = shelf.children.contains { book in
                    guard let motion = book.components[PhysicsMotionComponent.self] else {
                        return false
                    }
                    return simd_length(motion.linearVelocity) > 0.05
                        || simd_length(motion.angularVelocity) > 0.1
                }
                if !moving { return }
            }
        }

        /// Simulator hook: with `-BookwormsPileCoverLog YES`, appends how the books lie to
        /// `Library/Caches/Bookworms/pile-cover-up.log` under `label`: how many lie front cover
        /// up (`PileLayout.isCoverUp`), how many front cover down, and how many on an edge or
        /// leaning; how many book shapes, and so meshes, the pile uses; and the books' volume in
        /// liters and the height of the pile's top.
        func logCovers(_ label: String) {
            guard UserDefaults.standard.bool(forKey: "BookwormsPileCoverLog") else { return }
            let flip = simd_quatf(angle: .pi, axis: [1, 0, 0])
            let turns = shelf.children.map { $0.orientation(relativeTo: root) }
            let up = turns.filter(PileLayout.isCoverUp).count
            let down = turns.filter { PileLayout.isCoverUp($0 * flip) }.count
            let shapes = Set(factory.parts.values.map(\.shape)).count
            let share = turns.isEmpty ? 0 : 100 * up / turns.count
            let liters = factory.parts.values
                .map { $0.shape.size.x * $0.shape.size.y * $0.shape.size.z }
                .reduce(0, +)
            let top = shelf.visualBounds(relativeTo: root).max.y
                .formatted(.number.precision(.fractionLength(1)))
            let line =
                "\(label): \(turns.count) books, \(up) up (\(share)%), \(down) down, "
                + "\(turns.count - up - down) other, \(shapes) shapes, "
                + "\(Int(liters.rounded())) L, top \(top)\n"
            let url = URL.cachesDirectory.appending(path: "Bookworms/pile-cover-up.log")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let file = try? FileHandle(forWritingTo: url) {
                file.seekToEndOfFile()
                file.write(Data(line.utf8))
                try? file.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    #endif
}

extension BookPileScene: LiftingScene {}

extension BookPileScene {
    /// Sets the scene up for a video of `books` dropping onto `tray`, seen through `camera` in
    /// a frame of width-to-height `aspect`, as `settle` sets it up for a still image: it builds
    /// every book, giving covers up to 10 seconds, and waits for the room's light.
    func prepareFilm(
        _ books: [CloudBook], on tray: PileTray, camera: PileCamera, aspect: Float,
        model: AppModel
    ) async {
        look(through: camera)
        self.aspect = aspect
        build(tray.scaled(toFit: 3.9))
        await factory.prepare(books, prefetching: [], coverWait: .seconds(10), model: model)
        await stage.lit()
    }

    /// Drops `group`, from `PileLayout.settleGroups`, with heights counted from the top of the
    /// pile or from `base`, whichever is higher, and returns the new books' entity IDs. A video
    /// passes the base that starts its books out of view (see `PileMovieTiming.dropBase`).
    ///
    /// The pile's top leaves out `falling`, the IDs the previous call returned, since those
    /// books can still be in the air; counting them would start each group higher than the last.
    /// The books get `PileMovieTiming`'s drag, so a fall from behind the heading lands softly
    /// enough that books land the side up they start, as an image's do.
    func drop(_ group: [PileSlot], base: Float, above falling: Set<Entity.ID>) -> Set<Entity.ID> {
        let landed = shelf.children.filter { !falling.contains($0.id) }
        let top = landed.map { $0.visualBounds(relativeTo: root).max.y }.max() ?? 0
        let count = shelf.children.count
        for var slot in group {
            slot.transform.translation.y += max(top, base, 0)
            spawn(slot, mode: .dynamic)
        }
        let books = shelf.children.dropFirst(count)
        for book in books {
            book.components[PhysicsBodyComponent.self]?.linearDamping = PileMovieTiming.airDrag
            book.components[PhysicsBodyComponent.self]?.angularDamping = PileMovieTiming.spinDrag
        }
        return Set(books.map(\.id))
    }

    /// Plays a collision through `feedback`, panned to where it shows, for a renderer that
    /// steps the scene without a view.
    func collide(_ event: CollisionEvents.Began) { feedback.collide(event, pan: pan) }
}

extension ClosedRange where Bound == Float {
    fileprivate func clamp(_ value: Float) -> Float {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
