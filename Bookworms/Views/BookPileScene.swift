import Combine
import RealityKit
import SwiftUI

#if os(iOS)
    import CoreMotion
#endif
#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

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
    /// of view; or `nil` when the top of the view does not slope down, as a view that looks
    /// level or up shows the space above the table to the camera's height and beyond.
    ///
    /// The top of the view is the plane through the camera along the view's top edge. Its
    /// outward normal is the camera's up axis tipped back by half the field of view.
    static func heightAboveView(
        of point: SIMD2<Float>, radius: Float, seenFrom camera: Transform
    ) -> Float? {
        let half = fieldOfView / 2
        let normal = camera.rotation.act([0, cos(half), sin(half)])
        let topEdge = camera.rotation.act([0, sin(half), -cos(half)])
        guard normal.y > 0.05, topEdge.y < -0.05 else { return nil }
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

extension PileCamera {
    /// The camera with the eye, turn, and pitch of `transform`, looking at the table under the
    /// middle of its view, or at `fallback` for a view that does not meet the table. It leaves
    /// out any roll, and stays within the zoom range's top.
    init(matching transform: Transform, fallback: SIMD3<Float> = .zero) {
        let forward = transform.rotation.act([0, 0, -1])
        let target =
            Self.intersect((transform.translation, forward), height: 0) ?? fallback
        let zoom = Self.distance / max(simd_distance(target, transform.translation), 1)
        self.init(
            target: [target.x, 0, target.z], yaw: atan2(-forward.x, -forward.z),
            zoom: min(zoom, Self.zoomRange.upperBound),
            pitch: asin(min(max(-forward.y, -1), 1)))
    }
}

/// The part of the table the books stay on, with an invisible wall along each edge.
///
/// It is a trapezoid, symmetric about x = `centerX`, that the default camera sees between the
/// bars that cover the view's edges: the navigation bar and the tab bar, and on the Mac the
/// sidebar beside the view. Perspective makes its far edge, at the top of the screen, wider
/// than its near edge. A tray fitted to a turned view, as **Back to desk** fits one to the
/// dominoes' turned overview, turns with it about the table's middle by `turn`; its other
/// measures are those of the tray before it turns.
struct PileTray: Equatable {
    var farZ: Float
    var nearZ: Float
    var farHalfWidth: Float
    var nearHalfWidth: Float
    /// Where the tray's middle lies across the table. A sidebar over one side of the view moves
    /// it toward the other.
    var centerX: Float = 0
    /// How far the tray turns about the vertical axis through the table's middle, in radians,
    /// as `PileCamera.yaw` turns a view.
    var turn: Float = 0

    /// Half the tray's width at `z`, measured from `centerX`, before the tray turns.
    func halfWidth(at z: Float) -> Float {
        farHalfWidth + (nearHalfWidth - farHalfWidth) * (z - farZ) / (nearZ - farZ)
    }

    /// `point`, given on the tray before it turns, turned with the tray.
    func turned(_ point: SIMD3<Float>) -> SIMD3<Float> {
        simd_quatf(angle: turn, axis: [0, 1, 0]).act(point)
    }

    /// `point` turned back to where it lies on the tray before it turns.
    func unturned(_ point: SIMD3<Float>) -> SIMD3<Float> {
        simd_quatf(angle: -turn, axis: [0, 1, 0]).act(point)
    }

    /// The corners on the table, clockwise from the far left as seen from above.
    var corners: [SIMD3<Float>] {
        [
            [centerX - farHalfWidth, 0, farZ], [centerX + farHalfWidth, 0, farZ],
            [centerX + nearHalfWidth, 0, nearZ], [centerX - nearHalfWidth, 0, nearZ],
        ]
        .map(turned)
    }

    /// `point` moved inside the tray, at least `margin` from its edges, at the same height.
    func clamp(_ point: SIMD3<Float>, margin: Float) -> SIMD3<Float> {
        let point = unturned(point)
        let z = min(max(point.z, farZ + margin), nearZ - margin)
        let half = max(0, halfWidth(at: z) - margin)
        return turned([min(max(point.x, centerX - half), centerX + half), point.y, z])
    }
}

extension PileTray {
    /// Fits the tray to what `camera` sees between `safeTop` and `safeBottom`, given as
    /// normalized device y coordinates, and between `safeLeading` and `safeTrailing` in x, in a
    /// view of width-to-height `aspect`. For a turned camera, the tray turns with it: it fits
    /// the view of the camera turned back, then turns by the camera's `yaw`.
    ///
    /// The far and side walls stand where the view's edges meet a pile `pileHeight` high, by
    /// default the tallest pile (`tallestPile`), so a pile up to that high stays on screen.
    /// Books pushed against those walls, as **Tip the table** pushes them, can rise past a lower
    /// `pileHeight` toward the top or sides of the screen. A pile against the near wall rises
    /// toward the middle of the screen, so that wall stands where the bottom edge meets the
    /// table.
    ///
    /// A view's side edge meets the table along a line that slants away from the camera's axis,
    /// so a sidebar over one side leaves a wedge that widens toward the far edge. The tray, which
    /// stays symmetric about its middle, fits the wedge exactly at its near edge and stays
    /// inside it beyond.
    init?(
        aspect: Float, safeTop: Float, safeBottom: Float, safeLeading: Float = -1,
        safeTrailing: Float = 1, pileHeight: Float = tallestPile,
        camera: PileCamera = PileCamera()
    ) {
        // The camera turned back to look straight across the table, and moved across it to
        // look at the table's middle line, x = 0; the tray moves back by as much.
        var camera = camera
        camera.target = simd_quatf(angle: -camera.yaw, axis: [0, 1, 0]).act(camera.target)
        let across = camera.target.x
        let turn = camera.yaw
        camera.target.x = 0
        camera.yaw = 0
        let top = camera.ray(ndc: [1, safeTop], aspect: aspect)
        let bottom = camera.ray(ndc: [1, safeBottom], aspect: aspect)
        guard safeLeading < safeTrailing, let far = PileCamera.intersect(top, height: pileHeight),
            let nearSide = PileCamera.intersect(bottom, height: pileHeight),
            let near = PileCamera.intersect(bottom, height: 0)
        else { return nil }
        // The edges at x = ±1, where a point's x on the table scales with its x on screen.
        let sides = PileTray(
            farZ: far.z, nearZ: nearSide.z, farHalfWidth: far.x, nearHalfWidth: nearSide.x)
        let margin: Float = 0.4
        let farZ = far.z + margin
        let nearZ = near.z - margin
        let farEdge = sides.halfWidth(at: farZ)
        let nearEdge = sides.halfWidth(at: nearZ)
        let center = (safeLeading + safeTrailing) / 2 * nearEdge
        self.init(
            farZ: farZ, nearZ: nearZ,
            farHalfWidth: min(center - safeLeading * farEdge, safeTrailing * farEdge - center)
                - margin,
            nearHalfWidth: (safeTrailing - safeLeading) / 2 * nearEdge - margin,
            centerX: center + across, turn: turn)
    }

    /// Fits the tray between the bars that cover `viewport`'s edges, as `camera` sees it.
    /// Returns `nil` when the bars leave no room between them.
    init?(
        viewport: PileViewport, pileHeight: Float = tallestPile, camera: PileCamera = PileCamera()
    ) {
        let height = Float(viewport.size.height)
        let width = Float(viewport.size.width)
        let insets = viewport.insets
        guard width > 0, Float(insets.top + insets.bottom) < height,
            Float(insets.leading + insets.trailing) < width
        else { return nil }
        self.init(
            aspect: width / height, safeTop: 1 - 2 * Float(insets.top) / height,
            safeBottom: -1 + 2 * Float(insets.bottom) / height,
            safeLeading: -1 + 2 * Float(insets.leading) / width,
            safeTrailing: 1 - 2 * Float(insets.trailing) / width, pileHeight: pileHeight,
            camera: camera)
    }

    /// Fits the tray between the bars for a drop of `books`, as `camera` sees it, with walls
    /// where the view's edges meet the pile those books make (`pileHeight(of:over:)`), so a
    /// small pile fills the screen as a full one does. Returns `nil` when the bars leave no
    /// room between them.
    init?(viewport: PileViewport, books: [CloudBook], camera: PileCamera = PileCamera()) {
        guard let tallest = PileTray(viewport: viewport, camera: camera) else { return nil }
        self.init(
            viewport: viewport, pileHeight: Self.pileHeight(of: books, over: tallest),
            camera: camera)
    }

    /// The most height the walls allow for: room for the longest book, 2.8 units, standing on
    /// end on a 1.7-unit pile, as books that a full pile pushes against a wall stand.
    /// `PileLayout.maximumVolume` keeps a pile of long books from rising much higher.
    static let tallestPile: Float = 4.5

    /// How high `books` pile on `tray`: their volume spread over the tray, doubled for a loose
    /// pile, and a unit more for the books that lie across others or lean on them, which also
    /// keeps the tray's far edge inside the box of **Phone is the box**, at most `tallestPile`.
    /// `tray` is the tallest pile's, the smallest tray, so its area overstates the height a
    /// little.
    static func pileHeight(of books: [CloudBook], over tray: PileTray) -> Float {
        let volume = books.map { BookShape(of: $0, coverAspect: 2 / 3).size }
            .map { $0.x * $0.y * $0.z }
            .reduce(0, +)
        return min(tallestPile, 2 * volume / tray.area + 1)
    }

    /// The tray's area on the table, in square units.
    var area: Float { (farHalfWidth + nearHalfWidth) * (nearZ - farZ) }

    /// The tray shrunk by `factor` toward its middle.
    func scaled(by factor: Float) -> PileTray {
        let middle = (farZ + nearZ) / 2
        return PileTray(
            farZ: middle + (farZ - middle) * factor, nearZ: middle + (nearZ - middle) * factor,
            farHalfWidth: farHalfWidth * factor, nearHalfWidth: nearHalfWidth * factor,
            centerX: centerX, turn: turn)
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
    /// How much higher each wave of a drop starts than the wave before it, in units, above
    /// the 2.2-unit cell heights of the wave below, so a drop's waves fall at once, one above
    /// another, without meeting in the air.
    static let waveRise: Float = 6 * 2.2
    /// The least time from one wave to the next when the next starts no higher than the last
    /// wave's highest book, as the books a library update adds to a drop do (see
    /// `waveDelay(from:to:)`). It lets a wave's highest books fall below the lowest cells of a
    /// wave that starts at the same heights, under `airDrag`.
    static let waveInterval = Duration.milliseconds(950)
    /// The linear damping of a live drop's falling books, as air drag, until they first touch
    /// something. A drop starts out of view, high above the table (see `spawnHeight(over:)`).
    /// Drag lands a drop's first wave at 37 to 41 units a second, about as fast as a drop of 9
    /// to 20 units without drag, so about nine in ten land front cover up. Without drag they
    /// land at 51 to 62 units a second, and about twice as many land face down. Each later wave
    /// starts higher (`waveRise`) and lands faster, up to `gravity` / `airDrag`, 55 units a
    /// second.
    static let airDrag: Float = 1
    /// The height of the ceiling over `tray` for a drop of `waves` waves, which the walls
    /// reach: 20 units over the drop height, above the highest start a drop plan's first wave
    /// gives there, with room for a book lifted over others (see `dropPlan`), and `waveRise`
    /// higher for each later wave. A wider tray, such as a wide Mac window's, drops from higher
    /// (`spawnHeight(over:)`), so its ceiling rises with it.
    static func ceiling(over tray: PileTray, waves: Int = 1) -> Float {
        spawnHeight(over: tray) + 20 + Float(max(0, waves - 1)) * waveRise
    }
    /// Half the largest book's diagonal, 3.72 units, and a little more: a book whose middle lies
    /// this far outside the view is wholly out of it.
    static let entryClearance: Float = 1.9
    /// How long after the last wave the box of **Phone is the box** closes, at soonest: longer
    /// than a book takes to fall from an iPhone's one-wave ceiling (`ceiling(over:waves:)`)
    /// under `airDrag`.
    static let boxDelay = Duration.seconds(2.5)
    /// How thick the walls and the ceiling stand, in units. A book struck in a falling pile can
    /// leave it at up to about 250 units a second, over 4 units per physics step, and continuous
    /// collision detection does not reliably stop one that also spins fast. Physics pushes a book
    /// it finds inside a wall out through the nearer face, so the wall's middle must lie deeper
    /// than such a step for that face to be the inner one.
    static let wallThickness: Float = 12
    /// Half the longest book's length (`BookShape.longest`) plus a little, which keeps a new
    /// book clear of the walls.
    static let reach: Float = 1.5
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
        let reach = simd_length(
            SIMD2(abs(tray.centerX) + tray.farHalfWidth, max(-tray.farZ, tray.nearZ)))
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
        return fallTime(drop)
    }

    /// The seconds a book takes to fall `drop` units from rest under `gravity` and `airDrag`.
    static func fallTime(_ drop: Float) -> TimeInterval {
        // A fall under drag has no closed-form time for a distance, so this steps through it.
        var time: Float = 0
        while gravity / airDrag * (time - (1 - exp(-airDrag * time)) / airDrag) < drop {
            time += 0.01
        }
        return TimeInterval(time)
    }

    /// How long a wave whose lowest book starts at `lowest` waits after the last wave, whose
    /// highest book started at `top` above it, as the books a library update adds to a drop and
    /// a period's first books do:
    /// until that book has fallen below this wave's lowest, by two of the largest books' half
    /// diagonals (`entryClearance`), however many waves started under it, and `waveInterval` at
    /// least. Physics starts a frame after a wave spawns, which the wait allows for.
    static func waveDelay(from top: Float, to lowest: Float) -> Duration {
        max(waveInterval, .seconds(fallTime(top - lowest + 2 * entryClearance) + 1.0 / 60))
    }

    /// Drop poses above the tray, in waves of `waveSize` books, from `spawnHeight(over:)` up,
    /// each wave `waveRise` above the last, so every book can fall at once, under the ceiling
    /// for its waves (`ceiling(over:waves:)`).
    ///
    /// Each wave fills a 2 × 8 grid of cells once, in a shuffled order. Cells start at six
    /// heights 2.2 units apart, repeating every three rows, so books in a wave start spread out.
    /// Each book starts at a random yaw, front cover up but tumbled up to `tumble` radians
    /// (about 46 degrees by default), and spinning up to 2 radians a second about each level
    /// axis and 3 about the vertical, so it twirls more than it turns over as it falls. A tray
    /// too shallow to keep `reach` from its walls drops every book over its middle.
    ///
    /// Large books in nearby cells can still reach into each other, which the physics would
    /// resolve with a visible jolt. So each book, lowest first, rises above every lower book
    /// whose bounds, at the widest cover, overlap its own across the table. A typical
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
                let x = tray.centerX + across * max(0, tray.halfWidth(at: z) - reach)
                let y =
                    base + Float(wave) * waveRise + Float((row % 3) * 2 + column) * 2.2
                    + random(4) * 0.4
                let axis = random(5) * 2 * .pi
                let tumble = simd_quatf(
                    angle: (random(6) - 0.5) * 2 * tumble, axis: [cos(axis), 0, sin(axis)])
                let yaw = simd_quatf(angle: random(7) * 2 * .pi, axis: [0, 1, 0])
                return PileSlot(
                    book: book,
                    transform: Transform(
                        rotation: yaw * tumble * lyingFlat, translation: tray.turned([x, y, z])),
                    spin: (SIMD3(random(8), random(9), random(10)) - 0.5) * [4, 6, 4])
            }
        let rising = slots.indices.sorted {
            (slots[$0].transform.translation.y, $0) < (slots[$1].transform.translation.y, $1)
        }
        let extents = rising.map { halfExtent(of: slots[$0]) }
        for rank in rising.indices {
            for below in 0..<rank {
                let position = slots[rising[rank]].transform.translation
                let lower = slots[rising[below]].transform.translation
                let reach = extents[rank] + extents[below]
                if abs(position.x - lower.x) < reach.x, abs(position.z - lower.z) < reach.z {
                    slots[rising[rank]].transform.translation.y = max(
                        position.y, lower.y + reach.y + 0.05)
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

    /// How far a book of the Reduce Motion stacks turns at most, in radians: about 4 degrees.
    static let stackTwist = 0.07

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
                stacks.append(
                    [tray.centerX + ((Float(column) + 0.5) / Float(columns) * 2 - 1) * half, z])
            }
        }
        let perStack = max(1, (books.count + stacks.count - 1) / stacks.count)
        var slots: [PileSlot] = []
        for (stack, start) in stride(from: 0, to: books.count, by: perStack).enumerated() {
            var y: Float = 0
            for book in books[start..<min(start + perStack, books.count)].reversed() {
                let thickness = BookShape(of: book, coverAspect: 2 / 3).size.z
                // A slight shift, and a turn about the vertical axis so the spine faces a
                // little left or right, so the stacks look placed by hand. At most 4 degrees
                // keeps the largest book inside its stack's 3 by 2.6 units.
                let jitter = Float(ShareStyle.unit(0, book.id, 11)) - 0.5
                let turn = Float(StackArrangement.twist(of: book, maximum: Self.stackTwist))
                slots.append(
                    PileSlot(
                        book: book,
                        transform: Transform(
                            rotation: simd_quatf(angle: turn, axis: [0, 1, 0]) * lyingFlat,
                            translation: [
                                stacks[stack].x + jitter * 0.08, y + thickness / 2, stacks[stack].y,
                            ])))
                y += thickness
            }
        }
        return slots
    }

    /// The scene's gravity for a device gravity reading, both in the screen's axes and in g,
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

/// Whether the pile still has books to drop or books in the air, kept apart from the scene so
/// that views update only when it changes.
@MainActor @Observable
final class PileStatus {
    fileprivate(set) var isDropping = false
    /// Whether the books fly into a shape (`BookPileScene.arrange(_:)`).
    fileprivate(set) var isArranging = false
}

/// The pile's RealityKit content: the desk and its lamp (`DeskStage`), invisible walls and
/// ceiling, and one rigid body per book (`BookFactory`).
///
/// Books arrive a wave at a time. A drop builds every book first, so its waves fall at once;
/// period by period, and for tidy stacks, each wave falls once it is built. Each wave waits for
/// its own textures, and for its fonts and covers, while the next wave's covers download: at
/// most `loadWait`, which a drop's waves share. A book whose font or cover comes later is built
/// without it and takes it when it arrives (`BookFactory.prepare`). `loading` is set until a
/// new pile's first wave, which also waits for the room's light, falls. Every falling book
/// starts out of view
/// (`PileLayout.spawnHeight(over:)`) and falls in past the top of the screen. A new drop reuses
/// the parts of books whose look has not changed. While the view shows the scene, collisions
/// play taps and sounds through `feedback`.
///
/// While it follows motion (`setTilt`), the pile tilts as `PileTilt` says, and a hard shake
/// throws the books. In **Phone is the box**, the box's walls and glass (`PileBox`) close once
/// nothing waits to fall, and gravity follows the phone while they are closed.
///
/// The live Desk shares its desk and book parts with the dominoes (`DeskScenes`): `handOff()`
/// gives the dominoes the books as they lie, and `adopt(_:camera:books:tidy:periods:generation:
/// viewport:)` takes them back, wherever they lie, as the desk's arrangement until the next drop.
///
/// The stage counts the pile's rest (`DeskStage.rest`), as it counts the dominoes': once nothing
/// in the scene has moved for `SceneRest.delay`, it reports that the scene rests, so
/// `DeskScenes` can stop drawing it, and the next change to the scene reports that it moves
/// again.
@MainActor
final class BookPileScene {
    /// The scene root, which runs the physics simulation.
    let root = Entity()
    /// Whether a drop still has books to drop, kept apart from the scene so that views update
    /// only when it changes.
    let status = PileStatus()
    /// Whether the device reports motion, which tilt and shaking need. The Simulator and the
    /// Mac do not, unless a Debug build fakes it with `-BookwormsPileGravity`.
    static let canTilt: Bool = {
        #if DEBUG
            if debugGravity != nil { return true }
        #endif
        #if os(iOS)
            return CMMotionManager().isDeviceMotionAvailable
        #else
            return false
        #endif
    }()

    /// How long a wave waits for its fonts and covers.
    private static let loadWait = Duration.seconds(1.5)
    /// How many books of a drop build at once before its first wave falls. Two books' textures
    /// load together, which nearly halves the build; more books stall the main actor longer
    /// than one slow book does.
    private static let buildWidth = 2

    /// The camera the pile is seen through, for a renderer that draws the scene without a view.
    let camera = PerspectiveCamera()
    /// The current view's anchor that holds `root` (see `attach`).
    private var holder: AnchorEntity?
    /// The view the scene shows in, whose interface orientation turns motion readings into the
    /// screen's axes.
    private weak var arView: ARView?
    /// Haptics and sounds for collisions, which `BookPileView` starts and stops.
    let feedback = ImpactFeedback()
    /// Set from a new pile's plan until its first books fall (see `planDrop`).
    let loading = SceneLoading()
    private let factory: BookFactory
    private let stage: DeskStage
    private let shelf = Entity()
    private let walls = Entity()
    #if os(iOS)
        private lazy var motion = CMMotionManager()
    #endif
    private var view = PileCamera()
    /// The view the camera rests at, from which it zooms in and to which a lifted book's flight
    /// takes it, keeping the reader's turn: the default camera, or, for books the dominoes
    /// handed back, the view they were handed back in, until the next drop.
    private var home = PileCamera()
    /// Whether the books are the dominoes' handed back (`adopt`), rather than a drop's.
    private var isAdopted = false
    private var aspect: Float = 0.5
    /// The part of the view that the bars and the Mac's sidebar leave clear, in normalized
    /// device coordinates, which an arranged shape fills (see `arrange(_:)`).
    private var clearView = (low: SIMD2<Float>(-1, -1), high: SIMD2<Float>(1, 1))
    private var tray: PileTray?
    private var cameraMove: (start: PileCamera, focus: SIMD3<Float>)?
    private var plan: [PileSlot] = []
    private var planKey: PlanKey?
    private var spawned = 0
    private var lastWave = ContinuousClock.now
    /// Where the highest book of the last wave started.
    private var lastTop: Float = 0
    /// The waves the walls' ceiling stands over (see `PileLayout.ceiling(over:waves:)`).
    private var waves = 1
    private var bookIDs: [Entity.ID: Int] = [:]
    /// The books of a live drop that have not yet touched anything, with their damping before
    /// `PileLayout.airDrag`.
    private var falling: [Entity.ID: Float] = [:]
    private var carry: Carry?
    /// Whether the books stand still in tidy stacks, as kinematic bodies. Picking up a book
    /// frees only that book and the books resting on it. Tall stacks of uneven books can slip
    /// as the simulation settles them, and Reduce Motion asks for no motion the reader did not
    /// start.
    private var holdsStill = false
    /// The pull of `gatherBooks()` while it lasts: the point on the table the books slide
    /// toward, and the seconds it has pulled.
    private var gather: (center: SIMD3<Float>, elapsed: Float)?
    /// The books' flight into a shape while it lasts (see `arrange(_:)`).
    private var arrangement: Arrangement?
    /// Whether a landed shape's books stand still as kinematic bodies until a book strikes
    /// them (`releaseIfStruck`). Picking up one frees it and the books resting on it, as among
    /// Reduce Motion's still stacks. Tall shapes of uneven books would otherwise slip and fall
    /// as the simulation settles them, which real books stacked as carefully don't.
    private var standing = false
    /// The view the camera eases to so a shape's height shows (see `arrange(_:)`), until it
    /// gets there or the reader moves the camera.
    private var cameraGoal: PileCamera?
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
    private var updates: (any Cancellable)?
    private var collisions: (any Cancellable)?
    /// The flight of a book lifted to its details, and the reader's camera when it lifted,
    /// which returns with the book.
    let lifter: BookLifter
    private var readerCamera = PileCamera()
    /// The camera at the last rest check (see `isStill()`).
    private var checkedCamera = Transform.identity

    /// The walls' collision group, which a thrown-back book passes through.
    private static let wallGroup = CollisionGroup(rawValue: 1 << 1)

    private struct PlanKey: Equatable {
        let ids: [Int]
        let tidy: Bool
        let periods: TimeFrame?
        let generation: Int

        /// The key of a drop of `books`; a tidy stack drops no periods.
        init(_ books: [CloudBook], tidy: Bool, periods: TimeFrame?, generation: Int) {
            ids = books.map(\.id)
            self.tidy = tidy
            self.periods = tidy ? nil : periods
            self.generation = generation
        }
    }

    /// A book held under a finger and carried `PileCarry.lift` above what lies under it (see
    /// `pickUp`).
    ///
    /// The book stays a dynamic body, so the books it meets stop or shove it and it never
    /// passes through them, as a kinematic body would. Each frame steers its velocity toward
    /// the point under the finger, which makes it trail the finger slightly, and turns it
    /// toward lying level, leaned by its swing.
    private struct Carry {
        let book: ModelEntity
        /// The book's collision box, which the scene sweeps down to find what lies under it.
        let shape: ShapeResource
        /// The book's pose lying level, front or back cover up as it was nearer to.
        let level: simd_quatf
        /// The pose the book turns toward, but for its swing: the pose it was picked up in,
        /// easing to `level`. A tilted book that turned level at once would swing its edges
        /// through the books beside it and flip them over.
        var pose: simd_quatf
        /// From the point under the finger to the book's middle, across the table, so the book
        /// keeps where the finger took hold of it.
        let offset: SIMD3<Float>
        /// The books that lay over the book when it was picked up. They ride on it until they
        /// slide off, so the carry height ignores them; otherwise it would rise under them.
        let riders: Set<Entity.ID>
        /// Half the book's thickness, the height of its middle over its lower cover while level.
        let halfThickness: Float
        /// Whether the book holds level and drops when let go, for Reduce Motion.
        let gentle: Bool
        /// The ray from the camera through the finger.
        var ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)
        /// The height of the book's middle, which eases toward riding `PileCarry.lift` over what
        /// lies under it.
        var height: Float
        var velocity = SIMD3<Float>.zero
        var swing = PileSwing()
    }

    /// The books flying into a shape: in the shape's order, with their places, their ways
    /// there once planned, the seconds since those ways started, and the books that have
    /// landed.
    private struct Arrangement {
        let books: [ModelEntity]
        var gather: DominoFinale.Gather?
        var clock: Float = 0
        var landed: [Bool]
        let planning: Task<Void, Never>?
    }

    /// The collision group of a held book, which the sweep under it leaves out.
    private static let heldGroup = CollisionGroup(rawValue: 1 << 2)

    /// Creates an empty pile. `textureScale` multiplies the texture sizes, for still images that
    /// frame a few books closely; their GPU memory grows with its square. The live Desk passes
    /// the `factory` and `stage` it shares with the dominoes, and hands the materials of books
    /// whose fonts or covers arrive late to `retexture(_:materials:)` itself.
    init(textureScale: CGFloat = 1, factory: BookFactory? = nil, stage: DeskStage? = nil) {
        self.factory = factory ?? BookFactory(textureScale: textureScale)
        self.stage = stage ?? DeskStage()
        lifter = BookLifter(
            root: root, camera: camera, factory: self.factory, feedback: feedback,
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
        root.addChild(self.stage.root)
        root.addChild(shelf)
        root.addChild(calendar.label)
        if factory == nil {
            self.factory.retextured = { [weak self] id, materials in
                self?.retexture(id, materials: materials)
            }
        }
    }

    /// Shows the scene in `view`, and calls `update` every frame and plays collisions through
    /// `feedback` while `root` is active there. A thrown-back book's first hit lands it instead
    /// (see `BookLifter.handle`). Each view gets an anchor of its own under which the root
    /// hangs, as `DominoScene.attach` explains, and the desk comes under the root, from the
    /// dominoes if they had it.
    func attach(to view: ARView) {
        arView = view
        root.addChild(stage.root)
        holder?.removeFromParent()
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
            guard let self else { return }
            land(event.entityA)
            land(event.entityB)
            releaseIfStruck(event)
            guard !lifter.handle(event) else { return }
            feedback.collide(event, pan: pan)
        }
    }

    /// Takes the root out of the view's scene, so nothing draws while a pile image renders,
    /// and lets the dust drift again for the scene that takes the desk.
    func detach() {
        root.removeFromParent()
        stage.setSettled(false)
    }

    /// Puts the root back under the current view's anchor after `detach`.
    func reattach() {
        guard root.parent == nil, let holder else { return }
        holder.addChild(root)
    }

    /// The ray from the camera, as the reader's view shows the pile, through `point` in a view
    /// of `size`, or `nil` for an empty view.
    func ray(through point: CGPoint, in size: CGSize) -> (
        origin: SIMD3<Float>, direction: SIMD3<Float>
    )? {
        guard size.width > 0, size.height > 0 else { return nil }
        // The view's own shape, not the stored `aspect`, which keeps the shape the pile was
        // built for and goes stale when a Mac window resizes.
        return view.ray(
            ndc: [Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2],
            aspect: Float(size.width / size.height))
    }

    /// The book under `point`, in a view of `size`, or `nil` for the table or an empty view.
    /// The ray passes through the walls: the camera stands outside the near wall, which would
    /// otherwise stop every ray.
    func book(at point: CGPoint, in size: CGSize) -> ModelEntity? {
        guard let ray = ray(through: point, in: size), let scene = root.scene,
            let hit =
                scene.raycast(
                    origin: ray.origin, direction: ray.direction, length: 300, query: .nearest,
                    mask: CollisionGroup.all.subtracting(Self.wallGroup), relativeTo: root
                )
                .first?
                .entity as? ModelEntity, bookIDs[hit.id] != nil
        else { return nil }
        return hit
    }

    /// The ID of the book under `point`, in a view of `size`, or `nil` for the table: the
    /// nearest book whose box the ray meets, as `book(at:in:)` finds it. It reads only the
    /// books' poses, not the view's scene, so it works while the desk pauses and its view is
    /// gone, which lets the Mac's pointer find books without waking the desk.
    func bookID(under point: CGPoint, in size: CGSize) -> Int? {
        guard let ray = ray(through: point, in: size) else { return nil }
        var nearest: (distance: Float, id: Int)?
        for book in shelf.children {
            guard let id = bookIDs[book.id], let shape = factory.parts[id]?.shape,
                let distance = PilePointer.hit(
                    origin: ray.origin, direction: ray.direction, transform: book.transform,
                    size: shape.size),
                distance < nearest?.distance ?? .infinity
            else { continue }
            nearest = (distance, id)
        }
        return nearest?.id
    }

    /// Where the book nearest the middle of a view of `size` shows, in points, or `nil` while
    /// the pile has no books: where the Desk scene's tips point.
    func middleBookPoint(in size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let points = shelf.children.filter { bookIDs[$0.id] != nil }
            .map { view.project($0.transform.translation, aspect: Float(size.width / size.height)) }
        guard let nearest = points.min(by: { simd_length($0) < simd_length($1) }) else {
            return nil
        }
        return CGPoint(
            x: CGFloat(nearest.x + 1) / 2 * size.width,
            y: CGFloat(1 - nearest.y) / 2 * size.height)
    }

    /// Where `point` shows from left to right on screen, as a stereo position from -0.8 to 0.8,
    /// so no hit plays from one side alone.
    private func pan(_ point: SIMD3<Float>) -> Float {
        PileCamera.pan(of: point, seenFrom: view.transform, aspect: aspect)
    }

    /// Shows or hides the dust in the lamp's beam.
    func setDust(_ enabled: Bool) { stage.setDust(enabled) }

    // MARK: Building

    /// Adds the table, walls, and lights once the view has room for the tray, fitted to the
    /// pile of `books`, and fits them to each new size until the first books drop: a tab's
    /// first layouts pass through sizes it never shows, such as one with a large title. A
    /// `newPile` fits them again. Returns whether the tray changed.
    ///
    /// **Tip the table** slides the whole pile against one wall, where it rises higher than it
    /// lies spread out, so with that tilt the walls leave room for the tallest pile instead.
    @discardableResult
    private func build(_ viewport: PileViewport, for books: [CloudBook], newPile: Bool = false)
        -> Bool
    {
        let tips = tilt == .table && Self.canTilt
        guard tray == nil || spawned == 0 || newPile,
            let tray = tips
                ? PileTray(viewport: viewport) : PileTray(viewport: viewport, books: books),
            tray != self.tray
        else { return false }
        aspect = Float(viewport.size.width / viewport.size.height)
        let size = SIMD2(Float(viewport.size.width), Float(viewport.size.height))
        let insets = viewport.insets
        clearView = (
            low: SIMD2(Float(insets.leading), Float(insets.bottom)) / size * 2 - 1,
            high: 1 - SIMD2(Float(insets.trailing), Float(insets.top)) / size * 2
        )
        box = PileBox(viewport: viewport)
        build(tray)
        return true
    }

    /// Lays the lamp's pool over the tray, with its edges a little past the tray's corners, and
    /// puts walls along its edges.
    private func build(_ tray: PileTray) {
        let middle = (tray.farZ + tray.nearZ) / 2
        let pool = tray.turned([tray.centerX, 0, middle])
        let radius =
            simd_length(SIMD2(max(tray.farHalfWidth, tray.nearHalfWidth), tray.nearZ - middle))
            * 1.05
        if self.tray == nil {
            stage.build(pool: pool, radius: radius)
        } else {
            stage.aim(pool: pool, radius: radius)
        }
        self.tray = tray
        root.addChild(walls)
        walls.children.removeAll()
        walls.addChild(Self.makeWalls(around: tray, waves: waves))
    }

    /// Static walls along the tray's edges and a ceiling above a drop of `waves` waves
    /// (`PileLayout.ceiling(over:waves:)`). They have no model, so books seem to bump into the
    /// edges of the screen.
    static func makeWalls(around tray: PileTray, waves: Int) -> Entity {
        let walls = Entity()
        let ceiling = PileLayout.ceiling(over: tray, waves: waves)
        let thickness = PileLayout.wallThickness
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
            // Long enough to close the corners, so a thrown book cannot slip between walls, and
            // reaching below the table, or the nearer face of a book pressed in low would be the
            // wall's bottom, which pushes it down into the table and holds it there.
            add(
                .generateBox(
                    width: thickness, height: ceiling + thickness,
                    depth: simd_length(along) + 2 * thickness),
                at: (start + end) / 2 + outward * thickness / 2
                    + [0, (ceiling - thickness) / 2, 0],
                yaw: atan2(along.x, along.z))
        }
        add(
            .generateBox(
                width: 2 * max(tray.farHalfWidth, tray.nearHalfWidth) + 8, height: thickness,
                depth: tray.nearZ - tray.farZ + 8),
            at: tray.turned(
                [tray.centerX, ceiling + thickness / 2, (tray.farZ + tray.nearZ) / 2]),
            yaw: tray.turn)
        return walls
    }

    // MARK: Filling the pile

    /// Plans a drop of `books`, or tidy stacks when `tidy`, as `fill` does, without dropping
    /// any. Call it before `fill` to learn at once whether the plan kept the lifted book.
    ///
    /// With `periods` set, the books drop period by period through that frame (see
    /// `PileLayout.periods`). Otherwise, books added to a dropped list, such as a book a library
    /// update adds, join the books still waiting, when the list keeps the earlier books in their
    /// order. Any other change starts a new pile, which removes every book, the lifted one too,
    /// and fits the walls and the lamp's pool to the new pile's books.
    func planDrop(
        _ books: [CloudBook], tidy: Bool, periods: TimeFrame? = nil, generation: Int,
        viewport: PileViewport
    ) {
        let periods = tidy ? nil : periods
        let key = PlanKey(books, tidy: tidy, periods: periods, generation: generation)
        var added: [CloudBook]?
        if !tidy, periods == nil, let planKey, !planKey.tidy, planKey.periods == nil,
            planKey.generation == generation
        {
            added = PileLayout.added(to: planKey.ids, in: books)
        }
        let refits = build(viewport, for: books, newPile: key != planKey && added == nil)
        guard let tray else { return }
        guard refits || key != planKey else { return }
        stage.rest.stir()
        if !refits, let added {
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
        // Fits the ceiling over the plan's waves before their books spawn under it. Books a
        // library update adds only lengthen the plan, so it never drops onto books in the air.
        let waves = tidy ? 1 : (plan.count + PileLayout.waveSize - 1) / PileLayout.waveSize
        if waves != self.waves {
            self.waves = waves
            walls.children.removeAll()
            walls.addChild(Self.makeWalls(around: tray, waves: waves))
        }
        updateStatus()
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
    /// Period by period, a wave never spans two periods, and each period's first wave waits at
    /// least `PileLayout.periodInterval` after the last period's, and until the last period's
    /// highest book has fallen below it (`PileLayout.waveDelay(from:to:)`), then shows the
    /// period's name through `calendar`.
    func fill(
        _ books: [CloudBook], tidy: Bool, periods: TimeFrame? = nil, generation: Int,
        viewport: PileViewport, model: AppModel
    ) async {
        let began = ContinuousClock.now
        planDrop(books, tidy: tidy, periods: periods, generation: generation, viewport: viewport)
        guard tray != nil else { return }
        let key = PlanKey(books, tidy: tidy, periods: periods, generation: generation)
        var hidesLoading = false
        // A drop builds every book first, so its waves fall at once rather than as each is
        // built: a wave at a time, each waiting for its own fonts and covers while the next
        // wave's covers download. The waves share one `loadWait`, and each waits at least a
        // tenth of a second, so slow fonts and covers hold the drop back little longer than one
        // wave's. A late font or cover reaches its book when it arrives
        // (`BookFactory.retextured`).
        let buildsFirst = !tidy && self.periods == nil
        let loadDeadline = ContinuousClock.now + Self.loadWait
        var built = spawned
        while buildsFirst, built < plan.count, !Task.isCancelled, planKey == key {
            let end = min(built + PileLayout.waveSize, plan.count)
            await factory.prepare(
                plan[built..<end].map(\.book),
                prefetching: plan[end..<min(end + PileLayout.waveSize, plan.count)].map(\.book),
                loadWait: max(.milliseconds(100), loadDeadline - .now), width: Self.buildWidth,
                model: model)
            built = end
        }
        while spawned < plan.count {
            let period = plan[spawned].period
            let starts = self.periods != nil && (spawned == 0 || plan[spawned - 1].period != period)
            let full = min(spawned + PileLayout.waveSize, plan.count)
            let end = plan[spawned..<full].firstIndex { $0.period != period } ?? full
            let wave = plan[spawned..<end]
            let next = plan[end..<min(end + PileLayout.waveSize, plan.count)]
            if !buildsFirst {
                await factory.prepare(
                    wave.map(\.book), prefetching: next.map(\.book), loadWait: Self.loadWait,
                    model: model)
            }
            // Renders the period's name while its books wait to fall.
            let group = starts ? self.periods?[period] : nil
            var label: TextureResource?
            if let group, let span = group.span {
                label = await PileCalendar.texture(
                    YearInBooksCard.busiest(span, isCompact: false).value)
            }
            // A drop's waves fall at once, each above the last and a frame after it, so no frame
            // adds more than a wave's bodies; a period waits for the last period, and a wave that
            // starts below the last wave's highest book, as added books and a period's first
            // books do, for the books above it to fall past.
            if !tidy, spawned > 0 {
                let lowest = wave.map(\.transform.translation.y).min() ?? 0
                if starts {
                    try? await Task.sleep(
                        until: lastWave
                            + max(
                                PileLayout.periodInterval,
                                PileLayout.waveDelay(from: lastTop, to: lowest)))
                } else if lowest <= lastTop {
                    try? await Task.sleep(
                        until: lastWave + PileLayout.waveDelay(from: lastTop, to: lowest))
                } else {
                    try? await Task.sleep(for: .seconds(1.0 / 60))
                }
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
            if group != nil {
                calendar.show(
                    isFlying ? nil : label, facing: view,
                    scale: PileCalendar.scale(in: viewport.size))
            }
            spawned += wave.count
            updateStatus()
            lastWave = .now
            lastTop = wave.map(\.transform.translation.y).max() ?? 0
            if loading.isLoading, !hidesLoading {
                hidesLoading = true
                // Keeps a spinner that has shown until the first books can show, so it fades
                // out as they fall into view, while the later waves start. A quicker setup, such
                // as **Drop again**, shows none.
                let delay =
                    !holdsStill && lastWave - began > .seconds(SceneLoading.showDelay)
                    ? PileLayout.entryDelay(of: wave, seenBy: view) : 0
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, planKey == key else { return }
                    loading.isLoading = false
                }
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
        stage.rest.stir()
        shelf.children.removeAll()
        bookIDs = [:]
        falling = [:]
        carry = nil
        cameraMove = nil
        gather = nil
        endArrangement()
        standing = false
        cameraGoal = nil
        lifter.reset()
        spawned = 0
        periods = nil
        calendar.endGlow()
        factory.release(keeping: ids)
        view = PileCamera()
        home = PileCamera()
        isAdopted = false
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
        updateStatus()
    }

    /// Removes the books but keeps their parts, which the dominoes share, once the pile has
    /// handed its books to the dominoes. The next `fill` drops the books again, unless `adopt`
    /// takes them back first.
    func removeBooks() {
        endDrag()
        endArrangement()
        standing = false
        lifter.reset()
        shelf.children.removeAll()
        bookIDs = [:]
        falling = [:]
        plan = []
        planKey = nil
        spawned = 0
        updateStatus()
    }

    /// Notes whether books wait to drop or have yet to touch anything. A drop's last wave
    /// spawns seconds before its books land.
    private func updateStatus() {
        let dropping = spawned < plan.count || !falling.isEmpty
        if status.isDropping != dropping { status.isDropping = dropping }
    }

    /// Shows the pile through `camera`.
    func look(through camera: PileCamera) {
        view = camera
        self.camera.transform = camera.transform
    }

    /// Draws the book in the pile from the materials its parts took after it was built, such as
    /// when its font or cover arrived. A lifted book keeps the materials its details gave it
    /// until it lands, and then takes its parts' (`BookLifter`).
    func retexture(_ id: Int, materials: [any RealityKit.Material]) {
        guard lifter.dressedID != id else { return }
        for case let book as ModelEntity in shelf.children where bookIDs[book.id] == id {
            stage.rest.stir()
            book.children.first?.components[ModelComponent.self]?.materials = materials
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
        stage.rest.stir()
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
        updateStatus()
    }

    /// The ID of the book an entity belongs to, or `nil` for the table.
    func bookID(for entity: Entity) -> Int? { bookIDs[entity.id] }

    // MARK: Interaction

    private func update(_ deltaTime: TimeInterval) {
        feedback.advance(by: deltaTime)
        lifter.update(by: deltaTime, aim: aim)
        steerCarry(by: Float(deltaTime))
        if tilt == .box {
            updateBox()
            if !isFlying, !isAdopted { squareView(by: Float(deltaTime)) }
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
        calendar.advance(by: Float(deltaTime))
        pullTogether(by: Float(deltaTime))
        moveArrangement(by: Float(deltaTime))
        easeCamera(by: Float(deltaTime))
        // A resting pile waits for its still, so a book that starts moving then stirs it at
        // once, before the still can replace the view.
        if stage.rest.isResting, shelf.children.contains(where: Self.moves) { stage.rest.stir() }
        stage.rest.advance(by: deltaTime, isStill: isStill)
    }

    /// Whether nothing in the pile moved since the last rest check (`SceneRest`). Nothing may
    /// be held, flying, waiting to fall, or falling; no camera may move; motion must not steer
    /// gravity; no period's name may glow; and every book must be slower than a crawl. The
    /// physics engine puts bodies to sleep on its own, but reports no sleep, so their speeds
    /// stand in for it. The dust does not count, since the rest fades it out.
    private func isStill() -> Bool {
        let camera = camera.transform
        defer { checkedCamera = camera }
        return carry == nil && cameraMove == nil && !isFlying && !tracksMotion
            && !loading.isLoading && spawned == plan.count && falling.isEmpty
            && camera == checkedCamera && !calendar.isGlowing && gather == nil && arrangement == nil
            && cameraGoal == nil
            && !shelf.children.contains(where: Self.moves)
    }

    /// Whether `book` moves faster than a crawl.
    private static func moves(_ book: Entity) -> Bool {
        guard let motion = book.components[PhysicsMotionComponent.self] else { return false }
        return simd_length(motion.linearVelocity) > 0.05
            || simd_length(motion.angularVelocity) > 0.1
    }

    /// Picks up the book under `point`, in a view of `size`, and returns whether there was one
    /// to pick up: not while the camera moves or a book flies to or from its details.
    ///
    /// The book lifts `PileCarry.lift` off what it rests on, carrying the books that lay over
    /// it until they slide off, and follows the finger through `carry(to:in:)` until
    /// `throwBook(velocity:at:in:)` or `endDrag` lets it go. `gentle`, for Reduce Motion, keeps
    /// it from swinging and makes a throw a drop. Among Reduce Motion's still stacks, the books
    /// that lay over it start moving too, so they settle into its place.
    func pickUp(at point: CGPoint, in size: CGSize, gentle: Bool) -> Bool {
        guard carry == nil, cameraMove == nil, arrangement == nil,
            let ray = ray(through: point, in: size),
            let book = book(at: point, in: size), book !== lifter.book
        else { return false }
        return pickUp(book, along: ray, gentle: gentle)
    }

    private func pickUp(
        _ book: ModelEntity, along ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
        gentle: Bool
    ) -> Bool {
        let position = book.position(relativeTo: root)
        guard let shape = book.components[CollisionComponent.self]?.shapes.first,
            let size = bookIDs[book.id].flatMap({ factory.parts[$0] })?.shape.size,
            let grabbed = PileCamera.intersect(ray, height: position.y)
        else { return false }
        land(book)
        let riders = freeRiders(of: book)
        setMode(.dynamic, of: book)
        book.components[CollisionComponent.self]?.filter = CollisionFilter(
            group: Self.heldGroup, mask: .all)
        let orientation = book.orientation(relativeTo: root)
        carry = Carry(
            book: book, shape: shape, level: PileCarry.level(orientation), pose: orientation,
            offset: (position - grabbed) * [1, 0, 1], riders: riders, halfThickness: size.z / 2,
            gentle: gentle, ray: ray, height: position.y)
        return true
    }

    /// Moves the held book toward the point under `point`, in a view of `size`.
    func carry(to point: CGPoint, in size: CGSize) {
        guard let ray = ray(through: point, in: size) else { return }
        carry?.ray = ray
    }

    /// Lets go of the held book, thrown as the finger moves at `velocity`, in points a second,
    /// at `point` in a view of `size` (see `PileCarry.throwVelocity`). A gentle carry drops the
    /// book instead.
    func throwBook(velocity: CGSize, at point: CGPoint, in size: CGSize) {
        guard let carry else { return }
        // The finger's velocity on the plane the book rides in, from where the finger is and
        // where it would be a twentieth of a second later.
        let step: CGFloat = 0.05
        let later = CGPoint(x: point.x + velocity.width * step, y: point.y + velocity.height * step)
        guard !carry.gentle,
            let now = ray(through: point, in: size)
                .flatMap({ PileCamera.intersect($0, height: carry.height) }),
            let next = ray(through: later, in: size)
                .flatMap({ PileCamera.intersect($0, height: carry.height) })
        else { return release(throwing: .zero) }
        release(throwing: PileCarry.throwVelocity((next - now) / Float(step)))
    }

    /// Drops the held book where it is, without a throw, such as when the touch is cancelled.
    func endDrag() { release(throwing: .zero) }

    /// Lets go of the held book at `velocity`, keeping its swing and tumbling it forward along
    /// its flight.
    private func release(throwing velocity: SIMD3<Float>) {
        guard let carry else { return }
        self.carry = nil
        carry.book.components[CollisionComponent.self]?.filter = .default
        let swing =
            carry.gentle
            ? .zero : carry.book.components[PhysicsMotionComponent.self]?.angularVelocity ?? .zero
        carry.book.components.set(
            PhysicsMotionComponent(
                linearVelocity: velocity,
                angularVelocity: swing + simd_cross([0, 1, 0], velocity) * 0.15))
    }

    /// Steers the held book for a frame of `deltaTime` seconds: toward the point under the
    /// finger, inside the walls, riding `PileCarry.lift` over what lies there, and turned level
    /// but for its swing.
    private func steerCarry(by deltaTime: Float) {
        guard var carry, let tray, deltaTime > 0,
            let point = PileCamera.intersect(carry.ray, height: carry.height)
        else { return }
        var target = tray.clamp(point + carry.offset, margin: 1)
        let rest = carry.halfThickness + PileCarry.lift
        let surface = surfaceHeight(of: carry, under: target) ?? carry.height - rest
        carry.height +=
            (min(surface + rest, PileLayout.ceiling(over: tray) - 2) - carry.height)
            * min(1, deltaTime * 10)
        target.y = carry.height
        // The box's walls and glass stop a dynamic book anyway; this keeps it from pressing on
        // them.
        if boxWalls.parent != nil, let box { target = box.clamp(target, margin: 1.2) }
        // Velocity, rather than a new position, lets the physics stop the book at the books it
        // meets. Each step's gravity is taken out in advance, so the book does not sag.
        var velocity = (target - carry.book.position(relativeTo: root)) * 12 - gravity * deltaTime
        let speed = simd_length(velocity)
        if speed > 40 { velocity *= 40 / speed }
        if !carry.gentle {
            var acceleration = (velocity - carry.velocity) / deltaTime
            // A frame's jolt, such as the first step of the lift, should not fling the swing.
            let jolt = simd_length(acceleration)
            if jolt > 300 { acceleration *= 300 / jolt }
            carry.swing.advance(acceleration: [acceleration.x, acceleration.z], by: deltaTime)
        }
        carry.velocity = velocity
        carry.pose = simd_slerp(carry.pose, carry.level, min(1, deltaTime * 3))
        var turn = PileCarry.turn(
            from: carry.book.orientation(relativeTo: root), to: carry.swing.tilt * carry.pose)
        turn *= 10
        if simd_length(turn) > 15 { turn *= 15 / simd_length(turn) }
        carry.book.components.set(
            PhysicsMotionComponent(linearVelocity: velocity, angularVelocity: turn))
        self.carry = carry
    }

    /// The height of the top of what lies under `point`, where the held book, lying level,
    /// would first touch it: the table or the highest book there, leaving out its riders.
    /// Returns `nil` while the scene is not in a view.
    ///
    /// It sweeps the book's box down from 3 units over the book, so it misses books still
    /// falling from high above. Each hit's position is the point of first touch; its distance
    /// runs from the sweep's start to that point, not along the sweep, so it is not used.
    private func surfaceHeight(of carry: Carry, under point: SIMD3<Float>) -> Float? {
        guard let scene = root.scene, let tray else { return nil }
        let top = min(carry.height + 3, PileLayout.ceiling(over: tray) - 1)
        let hits = scene.convexCast(
            convexShape: carry.shape, fromPosition: [point.x, top, point.z],
            fromOrientation: carry.level, toPosition: [point.x, 0, point.z],
            toOrientation: carry.level, query: .all,
            mask: CollisionGroup.all.subtracting([Self.wallGroup, Self.heldGroup]),
            relativeTo: root)
        return hits.filter { !carry.riders.contains($0.entity.id) }.map(\.position.y).max()
    }

    /// The books lying over `book`. Among Reduce Motion's still stacks or in a standing shape,
    /// they start moving, so they settle into its place as it leaves.
    private func freeRiders(of book: ModelEntity) -> Set<Entity.ID> {
        let bounds = book.visualBounds(relativeTo: root)
        var riders = Set<Entity.ID>()
        for case let other as ModelEntity in shelf.children where other !== book {
            let over = other.visualBounds(relativeTo: root)
            guard over.min.y > bounds.center.y, over.max.x > bounds.min.x,
                over.min.x < bounds.max.x, over.max.z > bounds.min.z, over.min.z < bounds.max.z
            else { continue }
            riders.insert(other.id)
            if holdsStill || standing { setMode(.dynamic, of: other) }
        }
        return riders
    }

    private func setMode(_ mode: PhysicsBodyMode, of book: ModelEntity) {
        book.components[PhysicsBodyComponent.self]?.mode = mode
    }

    /// Zooms toward the point under `focus` and turns the camera about the pile. In **Phone is
    /// the box**, the camera only zooms, since the box fits the unturned view.
    /// Does nothing while a finger holds a book, which keeps the view it was picked up in.
    func moveCamera(magnification: CGFloat, rotation: Angle, focus: CGPoint?, in size: CGSize) {
        guard carry == nil, let tray, size.width > 0, size.height > 0 else { return }
        cameraGoal = nil
        if cameraMove == nil {
            let point = focus ?? CGPoint(x: size.width / 2, y: size.height / 2)
            let ndc = SIMD2(
                Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
            let ray = view.ray(ndc: ndc, aspect: Float(size.width / size.height))
            cameraMove = (view, PileCamera.intersect(ray, height: 0) ?? view.target)
        }
        guard let move = cameraMove else { return }
        let farthest = min(home.zoom, move.start.zoom, PileCamera.zoomRange.lowerBound)
        let zooms = farthest...PileCamera.zoomRange.upperBound
        view.zoom = zooms.clamp(move.start.zoom * Float(magnification))
        if tilt != .box { view.yaw = move.start.yaw - Float(rotation.radians) }
        // Keeps the focus point in place while zooming. Zoomed out to the home view, the
        // camera returns to its target, and zoomed in it may move only as far as the tray
        // reaches, measured along the tray before it turns.
        let target = tray.unturned(
            move.focus + (move.start.target - move.focus) * move.start.zoom / view.zoom)
        let reach = max(0, 1 - home.zoom / view.zoom)
        let middle = tray.unturned(home.target)
        let left = tray.centerX - tray.farHalfWidth
        let right = tray.centerX + tray.farHalfWidth
        view.target = tray.turned([
            min(
                max(target.x, middle.x + (left - middle.x) * reach),
                middle.x + (right - middle.x) * reach),
            0,
            min(
                max(target.z, middle.z + (tray.farZ - middle.z) * reach),
                middle.z + (tray.nearZ - middle.z) * reach),
        ])
        camera.transform = view.transform
    }

    func endCameraMove() { cameraMove = nil }

    /// **Actual Size**: returns the camera to its home view's zoom and place, keeping its turn.
    /// Does nothing while a finger holds a book or moves the camera.
    func zoomToActualSize() {
        guard carry == nil, cameraMove == nil else { return }
        view.zoom = home.zoom
        view.target = home.target
        camera.transform = view.transform
    }

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

    /// Starts lifting the book with `id` toward its details, which `BookLifter.place` places in a
    /// view of width-to-height `aspect`, and returns the seconds until it gets there. Returns
    /// `nil`, leaving the pile as it was, when the book is not in the pile or the view does not
    /// show the scene.
    ///
    /// The camera eases to its default framing, keeping its turn, so the book in front of it
    /// clears the pile at any zoom (see `aim`). The pile keeps simulating behind the veil.
    func lift(_ id: Int, aspect: Float) -> Double? {
        guard !isFlying, arrangement == nil, root.scene != nil, factory.parts[id] != nil,
            let book = shelf.children.first(where: { bookIDs[$0.id] == id }) as? ModelEntity
        else { return nil }
        endDrag()
        cameraMove = nil
        calendar.endGlow()
        // Books on a standing shape's book fall into its place as it leaves, as they would
        // if it were picked up.
        if standing { _ = freeRiders(of: book) }
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

    /// Moves the camera `share` of the way from the reader's camera to the home view, with the
    /// reader's turn, for a book's flight.
    private func aim(_ share: Float) {
        var rest = home
        rest.yaw = readerCamera.yaw
        look(through: readerCamera.mixed(with: rest, share))
    }

    // MARK: Handing books over

    /// The books as they lie, with how they move, and the camera's view, for the dominoes to set
    /// up from (see `DeskScenes`). A held book is let go, and a lifted one put back, first.
    func handOff() -> DeskHandover {
        endDrag()
        dropLifted()
        let books = shelf.children.compactMap { entity -> DeskBook? in
            guard let id = bookIDs[entity.id] else { return nil }
            return DeskBook(
                id: id, transform: entity.transform,
                motion: entity.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent())
        }
        return DeskHandover(books: books, camera: camera.transform)
    }

    /// Takes the books of `handover` back from the dominoes as the desk's arrangement, wherever
    /// they lie: they stay where they are, moving as they moved, in tidy stacks' stillness when
    /// `tidy`. Walls go up along what the view shows between the bars, turned with it, and
    /// around any book outside it on the table, and the camera takes the handover's view, which
    /// stays its home, the view it zooms out to, until the next drop. The box of **Phone is the
    /// box** stays open meanwhile, since it fits only the default view.
    ///
    /// The pile's key becomes the one `planDrop` gives for `books`, `tidy`, `periods`, and
    /// `generation`, so the view's next drop request keeps these books rather than dropping
    /// them again.
    func adopt(
        _ handover: DeskHandover, books: [CloudBook], tidy: Bool, periods: TimeFrame?,
        generation: Int, viewport: PileViewport
    ) {
        build(viewport, for: books)
        guard let fitted = tray else { return }
        reset(keeping: Set(handover.books.map(\.id)))
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        plan = []
        for handed in handover.books {
            guard let book = byID[handed.id] else { continue }
            let slot = PileSlot(book: book, transform: handed.transform)
            guard let entity = spawn(slot, mode: tidy ? .kinematic : .dynamic) else { continue }
            if !tidy { entity.components.set(handed.motion) }
            plan.append(slot)
        }
        spawned = plan.count
        holdsStill = tidy
        planKey = PlanKey(books, tidy: tidy, periods: periods, generation: generation)
        let camera = PileCamera(matching: handover.camera)
        // What the handed-over view shows between the bars, or, for a view that does not look
        // down onto the table, the default view's tray.
        let room = PileTray(viewport: viewport, camera: camera) ?? fitted
        // Walls along what the view shows, and around the books, a little past them, should
        // any lie outside it, measured along the tray before it turns.
        var walls = room
        var low = SIMD2<Float>(repeating: .infinity)
        var high = -low
        for book in shelf.children where !DominoSetup.isOffTable(book.position(relativeTo: root)) {
            let bounds = book.visualBounds(relativeTo: root)
            for x in [bounds.min.x, bounds.max.x] {
                for z in [bounds.min.z, bounds.max.z] {
                    let corner = room.unturned([x, 0, z])
                    low = pointwiseMin(low, [corner.x, corner.z])
                    high = pointwiseMax(high, [corner.x, corner.z])
                }
            }
        }
        if low.x <= high.x {
            let side = max(abs(low.x - room.centerX), abs(high.x - room.centerX)) + PileLayout.reach
            walls = PileTray(
                farZ: min(room.farZ, low.y - PileLayout.reach),
                nearZ: max(room.nearZ, high.y + PileLayout.reach),
                farHalfWidth: max(room.farHalfWidth, side),
                nearHalfWidth: max(room.nearHalfWidth, side), centerX: room.centerX,
                turn: room.turn)
        }
        build(walls)
        look(through: camera)
        home = view
        isAdopted = true
        loading.isLoading = false
        updateStatus()
        updateBox()
    }

    // MARK: Tilt and shake

    /// Sets how the pile follows the phone's tilt, and starts or stops sampling motion, which
    /// tilt and shakes need. `.off` samples nothing. Without sampling, gravity points straight
    /// down, except in a closed box, which keeps its last gravity until sampling resumes, since
    /// the phone has not moved for it. A new mode or a new start of sampling in `.table` takes
    /// a new reference.
    func setTilt(_ tilt: PileTilt, tracking: Bool) {
        let tracking = tracking && tilt != .off && Self.canTilt
        if tilt != self.tilt || tracking != tracksMotion {
            tiltReference = nil
            stage.rest.stir()
        }
        self.tilt = tilt
        if tracking != tracksMotion {
            tracksMotion = tracking
            #if os(iOS)
                if tracking {
                    // Shakes peak for a few hundredths of a second.
                    motion.deviceMotionUpdateInterval = 1 / 60
                    motion.startDeviceMotionUpdates()
                } else {
                    motion.stopDeviceMotionUpdates()
                }
            #endif
        }
        // In `.box`, the next update gives the box's gravity once the box is closed.
        let keepsGravity =
            (tracking && tilt == .table) || (tilt == .box && boxWalls.parent != nil)
        if !keepsGravity { setGravity([0, -PileLayout.gravity, 0]) }
        updateBox()
    }

    /// The device's gravity and the acceleration the user gives it, in g in the screen's axes
    /// as the interface shows it, x toward its right, y toward its top, and z out of the glass,
    /// while motion is sampled.
    private func motionReading() -> (gravity: SIMD3<Double>, acceleration: SIMD3<Double>)? {
        guard tracksMotion else { return nil }
        #if os(iOS)
            let orientation =
                arView?.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            func screen(_ device: SIMD3<Double>) -> SIMD3<Double> {
                Self.screenAxes(device, in: orientation)
            }
            if let sample = motion.deviceMotion {
                return (
                    screen([sample.gravity.x, sample.gravity.y, sample.gravity.z]),
                    screen([
                        sample.userAcceleration.x, sample.userAcceleration.y,
                        sample.userAcceleration.z,
                    ])
                )
            }
            #if DEBUG
                if let gravity = Self.debugGravity { return (screen(gravity), .zero) }
            #endif
        #elseif DEBUG
            if let gravity = Self.debugGravity { return (gravity, .zero) }
        #endif
        return nil
    }

    #if os(iOS)
        /// A motion reading in the device's axes, x toward its right edge and y toward its top
        /// in portrait, turned into the axes of the screen as an interface in `orientation`
        /// shows it.
        nonisolated static func screenAxes(
            _ device: SIMD3<Double>, in orientation: UIInterfaceOrientation
        ) -> SIMD3<Double> {
            switch orientation {
            case .portraitUpsideDown: [-device.x, -device.y, device.z]
            // Turned clockwise from portrait: the device's top is the screen's right.
            case .landscapeLeft: [device.y, -device.x, device.z]
            case .landscapeRight: [-device.y, device.x, device.z]
            default: device
            }
        }
    #endif

    /// The books that the reader's shakes and pulls move: every dynamic book but the held one
    /// and the lifted one.
    private var freeBooks: [ModelEntity] {
        shelf.children.compactMap { $0 as? ModelEntity }
            .filter {
                $0 !== carry?.book && $0 !== lifter.book
                    && $0.components[PhysicsBodyComponent.self]?.mode == .dynamic
            }
    }

    /// Pulls the free books toward the middle of where they lie for `PileLayout.gatherTime`,
    /// as a well in the desk would, so a spread-out pile clumps together without being sorted
    /// or stacked. Reduce Motion's still stacks stay put, and so does a pile with a book out
    /// at its details.
    func gatherBooks() {
        let books = freeBooks
        guard !holdsStill, !isFlying, gather == nil, arrangement == nil, books.count > 1 else {
            return
        }
        var center =
            books.map { $0.position(relativeTo: root) }.reduce(.zero, +) / Float(books.count)
        center.y = 0
        gather = (center, 0)
        stage.rest.stir()
    }

    /// Moves the gather on by `deltaTime` seconds: each free book speeds up along the table
    /// toward the gather's center (`PileLayout.gatherPull`).
    private func pullTogether(by deltaTime: Float) {
        guard var gather else { return }
        gather.elapsed += deltaTime
        guard gather.elapsed < PileLayout.gatherTime, !isFlying else {
            self.gather = nil
            return
        }
        self.gather = gather
        for book in freeBooks {
            var offset = gather.center - book.position(relativeTo: root)
            offset.y = 0
            let mass = book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0.5
            book.applyLinearImpulse(
                PileLayout.gatherPull(toward: offset, after: gather.elapsed) * mass * deltaTime,
                relativeTo: nil)
        }
    }

    /// Flies every book on the desk into `shape` (`PileShape.places(for:in:)`), centered
    /// between the walls, along the ways the dominoes' books take into their spread
    /// (`DominoFinale.Gather`): the books rise at once into a messy cloud, then land one by one,
    /// bottom course first, along ways planned so that no book passes through another. Each
    /// lands with a soft knock. Once the last has landed, the shape stands still until a thrown
    /// book knocks it down (see `standing`). Reduce Motion's still stacks move straight to their
    /// places and stay still.
    ///
    /// Does nothing while books drop, a book is held or flies to or from its details, or the
    /// books already fly into a shape.
    func arrange(_ shape: PileShape) {
        let books = shelf.children.compactMap { $0 as? ModelEntity }
        guard let tray, !status.isDropping, !isFlying, carry == nil, arrangement == nil,
            !books.isEmpty
        else { return }
        gather = nil
        let sizes = books.map { book in
            bookIDs[book.id].flatMap { factory.parts[$0]?.shape.size } ?? [1.4, 2.1, 0.25]
        }
        let places = shape.places(for: sizes, in: tray)
        let ordered = places.map { books[$0.book] }
        // The camera looks across the shape, keeping the reader's turn.
        var goal = view
        goal.pitch = PileShape.viewPitch
        goal.target =
            places.map(\.pose.translation).reduce(.zero, +) / Float(places.count) * [1, 0, 1]
        // It zooms as close as it can while the whole shape shows clear of the bars, and out
        // past the pile's farthest view if a tall shape on a narrow view needs it.
        let bounds = places.map { DominoSetup.Box($0.pose, size: sizes[$0.book]).bounds }
        let low = bounds.map(\.low).reduce(SIMD3(repeating: .infinity)) { simd_min($0, $1) }
        let high = bounds.map(\.high).reduce(SIMD3(repeating: -.infinity)) { simd_max($0, $1) }
        let corners = (0..<8)
            .map {
                SIMD3(
                    $0 & 1 == 0 ? low.x : high.x, $0 & 2 == 0 ? low.y : high.y,
                    $0 & 4 == 0 ? low.z : high.z)
            }
        goal.zoom = PileCamera.zoomRange.upperBound
        while goal.zoom > PileShape.farthest,
            !corners.allSatisfy({
                PileShape.shows(goal.project($0, aspect: aspect), within: clearView)
            })
        {
            goal.zoom -= 0.05
        }
        for book in ordered {
            book.components[PhysicsBodyComponent.self]?.mode = .kinematic
            book.components.set(PhysicsMotionComponent())
        }
        stage.rest.stir()
        guard !holdsStill else {
            for (book, place) in zip(ordered, places) { book.transform = place.pose }
            look(through: goal)
            return
        }
        cameraGoal = goal
        let hops = zip(ordered, places)
            .map { book, place in
                (from: book.transform, to: place.pose, size: sizes[place.book])
            }
        let planning = Task { [weak self] in
            let gather = await Self.planArrangement(hops)
            guard !Task.isCancelled, let self, self.arrangement != nil else { return }
            self.arrangement?.gather = gather
        }
        arrangement = Arrangement(
            books: ordered, landed: Array(repeating: false, count: ordered.count),
            planning: planning)
        status.isArranging = true
    }

    /// The books' ways into a shape, away from the main actor, every book landing within
    /// `DominoFinale.gatherBudget` if speeding up allows.
    @concurrent
    nonisolated private static func planArrangement(
        _ books: [(from: Transform, to: Transform, size: SIMD3<Float>)]
    ) async -> DominoFinale.Gather {
        DominoFinale.Gather(books, budget: DominoFinale.gatherBudget, holdsLast: false)
    }

    /// Moves the books on their ways into the shape by `deltaTime`, at most a twentieth of a
    /// second, so a stalled frame slows them rather than skipping their moves, and lands each
    /// with a soft knock. Once every book has landed, the shape stands (see `standing`).
    private func moveArrangement(by deltaTime: Float) {
        guard var arrangement, let gather = arrangement.gather else { return }
        arrangement.clock += min(deltaTime, 1.0 / 20)
        for (order, flight) in gather.flights.enumerated() where !arrangement.landed[order] {
            let book = arrangement.books[order]
            guard arrangement.clock < flight.landing else {
                book.transform = flight.to
                arrangement.landed[order] = true
                land(book, speed: 0.9)
                continue
            }
            book.transform = flight.pose(at: arrangement.clock)
        }
        self.arrangement = arrangement
        guard !arrangement.landed.contains(false) else { return }
        endArrangement()
        standing = true
    }

    /// Turns a standing shape's books back into rigid bodies once a book strikes one of them
    /// faster than `PileShape.strike`, so the hit knocks the shape down. A book that settles
    /// onto one, such as a book resting on a book picked up, strikes too softly.
    private func releaseIfStruck(_ event: CollisionEvents.Began) {
        let bodies = [event.entityA, event.entityB]
            .compactMap { $0.components[PhysicsBodyComponent.self] }
        guard standing, event.impulse.isFinite, bodies.contains(where: { $0.mode == .kinematic }),
            let mass = bodies.filter({ $0.mode == .dynamic }).map(\.massProperties.mass).max(),
            event.impulse > PileShape.strike * mass
        else { return }
        standing = false
        for case let book as ModelEntity in shelf.children
        where book !== lifter.book && book.components[PhysicsBodyComponent.self]?.mode == .kinematic
        {
            setMode(.dynamic, of: book)
        }
    }

    /// Eases the camera toward `cameraGoal`, as the dominoes' camera eases between views, unless
    /// a book is held, the reader moves the camera, or a book flies to or from its details.
    private func easeCamera(by deltaTime: Float) {
        guard let goal = cameraGoal, carry == nil, cameraMove == nil, !isFlying else { return }
        view = view.mixed(with: goal, min(1, deltaTime * 3))
        if abs(view.pitch - goal.pitch) < 0.002, simd_distance(view.target, goal.target) < 0.01 {
            view = goal
            cameraGoal = nil
        }
        camera.transform = view.transform
    }

    /// Stops the books' flight into a shape, where they are.
    private func endArrangement() {
        arrangement?.planning?.cancel()
        arrangement = nil
        if status.isArranging { status.isArranging = false }
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
        for book in freeBooks {
            let mass = book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0.5
            book.applyLinearImpulse(
                (kick + .random(in: -0.35...0.35) * speed) * mass, relativeTo: nil)
            book.applyAngularImpulse(.random(in: -1...1) * mass * 2, relativeTo: nil)
        }
    }

    /// Closes the box of **Phone is the box** once nothing waits to fall or falls, at soonest
    /// `PileLayout.boxDelay` after the last wave, and opens it in the other modes, while books
    /// wait to fall, which start above it, and while a book flies to or from its details, with
    /// gravity straight down until it closes again.
    ///
    /// Books past the glass or the sides when it closes, such as one high on the pile against
    /// the far wall, which the box's top side cuts off, move just inside them. They are off
    /// screen there. Books lying on the table stay put.
    private func updateBox() {
        let closes =
            tilt == .box && !holdsStill && !isAdopted && !isFlying && spawned == plan.count
            && ContinuousClock.now - lastWave > PileLayout.boxDelay && falling.isEmpty
        guard closes != (boxWalls.parent != nil) else { return }
        guard closes else {
            boxWalls.removeFromParent()
            setGravity([0, -PileLayout.gravity, 0])
            return
        }
        guard let box else { return }
        if boxWalls.children.isEmpty { boxWalls.addChild(box.makeWalls(group: Self.wallGroup)) }
        for case let book as ModelEntity in shelf.children where book !== carry?.book {
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
        stage.rest.stir()
        root.components[PhysicsSimulationComponent.self]?.gravity = gravity
        for case let book as ModelEntity in shelf.children where book !== carry?.book {
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
        /// `-BookwormsPileThrow YES` picks up the top book, carries it up the screen and to the
        /// right for a third of a second, and throws it on. The last three wait four seconds.
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
            guard throwsBook, let book = Array(shelf.children).last as? ModelEntity else { return }
            let start = book.position(relativeTo: root)
            guard pickUp(book, along: (start + [0, 20, 0], [0, -1, 0]), gentle: false) else {
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            for step in 1...20 {
                try? await Task.sleep(for: .milliseconds(16))
                let point = start + [Float(step) * 0.25, 0, -Float(step) * 0.4]
                carry?.ray = (point + [0, 20, 0], [0, -1, 0])
            }
            release(throwing: PileCarry.throwVelocity([15, 0, -24]))
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
                if !shelf.children.contains(where: Self.moves) { return }
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
            Self.appendCoverLog(
                "\(label): \(turns.count) books, \(up) up (\(share)%), \(down) down, "
                    + "\(turns.count - up - down) other, \(shapes) shapes, "
                    + "\(Int(liters.rounded())) L, top \(top)")
        }

        /// Appends `line` and a line break to `Library/Caches/Bookworms/pile-cover-up.log`.
        static func appendCoverLog(_ line: String) {
            let data = Data((line + "\n").utf8)
            let url = URL.cachesDirectory.appending(path: "Bookworms/pile-cover-up.log")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let file = try? FileHandle(forWritingTo: url) {
                file.seekToEndOfFile()
                file.write(data)
                try? file.close()
            } else {
                try? data.write(to: url)
            }
        }

        /// The books as they lie in the scene, with their shapes, in the order they went down.
        var lyingBooks: [(transform: Transform, shape: BookShape)] {
            shelf.children.compactMap { book in
                guard let id = bookIDs[book.id], let shape = factory.parts[id]?.shape else {
                    return nil
                }
                return (Transform(matrix: book.transformMatrix(relativeTo: root)), shape)
            }
        }

        /// Simulator hook: with `-BookwormsPileCoverLog YES`, appends to the cover log how much
        /// of each front cover the camera shows inside `rect` of an image of `size`, measured
        /// from the books as they lie (`PileSpread.visibility`): the least and the mean share;
        /// the shares of `rect` that covers and books fill (`PileSpread.coverage`); and the
        /// steepest tilt of a front cover from straight up.
        func logSpread(_ label: String, in rect: CGRect, of size: CGSize) {
            guard UserDefaults.standard.bool(forKey: "BookwormsPileCoverLog") else { return }
            let books = lyingBooks
            let shares = PileSpread.visibility(of: books, camera: view, in: rect, of: size)
                .map(\.share)
            let fill = PileSpread.coverage(of: books, camera: view, in: rect, of: size)
            let tilt = books.map { acos(min(1, $0.transform.rotation.act([0, 0, 1]).y)) }.max()
            func percent(_ value: Float) -> String {
                (value * 100).formatted(.number.precision(.fractionLength(1))) + "%"
            }
            let mean = shares.reduce(0, +) / Float(max(shares.count, 1))
            let degrees = ((tilt ?? 0) * 180 / .pi).formatted(.number.precision(.fractionLength(1)))
            Self.appendCoverLog(
                "\(label): covers shown least \(percent(shares.min() ?? 0)), mean \(percent(mean)); "
                    + "rect \(percent(fill.covers)) covers, \(percent(fill.books)) books; "
                    + "tilt up to \(degrees)°")
        }

        /// Draws the front covers of the books at `shown`, by the order they went down, unlit
        /// white and every other surface unlit black, without the desk, the lamp, shadows, or
        /// ribbons, so that a frame's white pixels are what the camera sees of those covers.
        /// The scene stays this way. Returns each book's front cover's corners, in order.
        func showCovers(_ shown: Set<Int>) -> [[SIMD3<Float>]] {
            stage.root.isEnabled = false
            let white = UnlitMaterial(color: .white)
            let black = UnlitMaterial(color: .black)
            // `RealityRenderer` keeps drawing the materials a model first rendered with after
            // they change, so each call draws every book with a new entity in place of the last.
            for (index, book) in shelf.children.enumerated() {
                guard let model = book.children.first,
                    let mesh = model.components[ModelComponent.self]?.mesh
                else { continue }
                model.isEnabled = false
                book.findEntity(named: "cover check")?.removeFromParent()
                let check = Entity()
                check.name = "cover check"
                check.components.set(
                    ModelComponent(
                        mesh: mesh,
                        materials: [shown.contains(index) ? white : black, black, black, black]))
                book.addChild(check)
            }
            return lyingBooks.map { transform, shape in
                let half = shape.size / 2
                let left = -half.x + shape.spineDepth
                return [[left, -half.y], [half.x, -half.y], [half.x, half.y], [left, half.y]]
                    .map { (corner: SIMD2<Float>) in
                        transform.translation
                            + transform.rotation.act(SIMD3(corner.x, corner.y, half.z))
                    }
            }
        }
    #endif
}

extension BookPileScene: LiftingScene {}

extension BookPileScene {
    /// Builds every book of `books`, waiting for their fonts, since nothing draws a share image
    /// again when a font arrives, and giving covers up to 10 seconds, and lays the books out as
    /// a share image's spread (`PileSpread`), framed in `rect` of an image of `size`. The scene
    /// then looks through the spread's camera, with the lamp's pool over the spread, and the
    /// room's light has reached it; `place(_:mode:)` adds the books.
    ///
    /// The layout runs away from the main actor. A book that RealityKit cannot build is left out.
    /// Also returns the books whose covers came too late, which show their titles on the cloth.
    func prepareSpread(
        _ books: [CloudBook], in rect: CGRect, of size: CGSize, seed: UInt64, model: AppModel
    ) async -> (spread: PileSpread, late: [CloudBook]) {
        let late = await factory.prepare(
            books, prefetching: [], loadWait: .seconds(10), waitsForFonts: true, model: model)
        let shaped = books.compactMap { book in factory.parts[book.id].map { (book, $0.shape) } }
        let spread = await Self.layOut(shaped, in: rect, of: size, seed: seed)
        let reach = zip(spread.slots, spread.shapes)
            .map { slot, shape in
                let middle = slot.transform.translation
                let half = simd_length(SIMD2(shape.size.x, shape.size.y)) / 2
                return (z: middle.z - half...middle.z + half, x: abs(middle.x) + half)
            }
        let side = reach.map(\.x).max() ?? 1
        build(
            PileTray(
                farZ: reach.map(\.z.lowerBound).min() ?? -1,
                nearZ: reach.map(\.z.upperBound).max() ?? 1, farHalfWidth: side,
                nearHalfWidth: side))
        aspect = Float(size.width / size.height)
        look(through: spread.camera)
        // Building the tray builds the stage, which starts the room's light.
        await stage.lit()
        return (spread, books.filter { late.contains($0.id) })
    }

    @concurrent
    nonisolated private static func layOut(
        _ books: [(book: CloudBook, shape: BookShape)], in rect: CGRect, of size: CGSize,
        seed: UInt64
    ) async -> PileSpread {
        PileSpread(books, in: rect, of: size, seed: seed)
    }

    /// Adds the books of `slots` at their poses, in order, and returns them.
    @discardableResult
    func place(_ slots: [PileSlot], mode: PhysicsBodyMode) -> [ModelEntity] {
        let books = slots.compactMap { spawn($0, mode: mode) }
        #if DEBUG
            if UserDefaults.standard.bool(forKey: "BookwormsPileShareGlare") { faceGlare(books) }
        #endif
        return books
    }

    #if DEBUG
        /// Simulator hook: `-BookwormsPileShareGlare YES` turns each book of a share image
        /// about its middle so that its front faces halfway between the lamp and the camera,
        /// where it mirrors the lamp most brightly, and lifts it clear of the table. Books can
        /// pass through one another; the image shows how the covers' finish takes that glare.
        private func faceGlare(_ books: [ModelEntity]) {
            let lamp = DeskStage.lampPlacement(pool: stage.pool.center, radius: stage.pool.radius)
            let eye = camera.position(relativeTo: root)
            for book in books {
                let middle = book.position(relativeTo: root)
                let glare = simd_normalize(
                    simd_normalize(lamp.position - middle) + simd_normalize(eye - middle))
                let front = book.orientation(relativeTo: root).act([0, 0, 1])
                book.setOrientation(
                    simd_quatf(from: front, to: glare) * book.orientation(relativeTo: root),
                    relativeTo: root)
                let length = bookIDs[book.id].flatMap { factory.parts[$0]?.shape.size.y } ?? 0
                book.position.y += length / 2 + 0.4
            }
        }
    #endif

    /// Plays the knock of `book` landing at `speed` units a second, panned to where it shows,
    /// for a video that moves its books itself, so that no collision reports the landing.
    func land(_ book: ModelEntity, speed: Float) {
        let mass = book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0.5
        feedback.impact(
            impulse: mass * speed, mass: mass, position: book.position(relativeTo: root), pan: pan)
    }
}

extension ClosedRange where Bound == Float {
    fileprivate func clamp(_ value: Float) -> Float {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
