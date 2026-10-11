import CoreMotion
import RealityKit
import SwiftUI
import UIKit

/// The pile's camera, and how points on the screen map onto the table.
///
/// Scene units are decimeters, so a book is about 2.2 units tall. The table is the plane y = 0.
/// The camera looks at `target` from `distance / zoom` away, pitched down by `pitch` and turned
/// about the vertical axis by `yaw`. The field of view is vertical, as RealityKit applies it,
/// so a narrower view sees less of the table from side to side.
struct PileCamera: Equatable {
    static let fieldOfView: Float = 38 * .pi / 180
    static let pitch: Float = 62 * .pi / 180
    static let distance: Float = 30
    static let zoomRange: ClosedRange<Float> = 1...2.5

    var target = SIMD3<Float>.zero
    var yaw: Float = 0
    var zoom: Float = 1

    var rotation: simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -Self.pitch, axis: [1, 0, 0])
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
    /// `pose`, in a view of width-to-height `aspect`.
    ///
    /// `center` and `height` give the book's place in normalized device coordinates, where the
    /// view is 2 units tall. The book's middle sits on `center`, at the depth where its height
    /// spans `height`, as `Book3DView` draws its height at the book's middle. The book faces
    /// along the ray to the camera rather than the camera's axis, so off center it turns as it
    /// would in front of `Book3DView`'s camera, which looks straight at it.
    func detailPose(
        center: SIMD2<Float>, height: Float, size: SIMD3<Float>, pose: BookPose, aspect: Float
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
            rotation: rotation * facing * turn,
            translation: transform.translation + rotation.act(local)
        )
    }

    /// This camera moved `fraction` of the way to `other`.
    func mixed(with other: PileCamera, _ fraction: Float) -> PileCamera {
        PileCamera(
            target: target + (other.target - target) * fraction,
            yaw: yaw + (other.yaw - yaw) * fraction, zoom: zoom + (other.zoom - zoom) * fraction)
    }
}

/// How a book leaves the pile for its details and returns. Times are in seconds.
///
/// The book first rises straight up until it clears the books around and on it, speeding up as
/// it goes. A spring then carries it from the top of the rise to its details, starting at the
/// rise's speed and overshooting slightly. Back throws it at the place it left, on a path that
/// gravity bends, so it lands there after `whipDuration`.
enum PileFlight {
    static let spring = Spring(duration: 0.8, bounce: 0.2)
    static let whipDuration: Float = 0.26
    /// How far the veil stays behind the book's middle: more than half the longest book's
    /// diagonal, so the book never passes through it.
    static let veilGap: Float = 1.8

    /// How far a book with `bounds` rises: until its bottom clears, by 0.15 units, the top of
    /// every book in `others` that overlaps it from above and rests on it or on another such
    /// book. A book more than 0.5 units above that stack, such as one still falling, does not
    /// count. It rises at least 0.4 units, to come free of the table, and at most 6, the height
    /// of the tallest pile.
    static func rise(of bounds: BoundingBox, clearing others: [BoundingBox]) -> Float {
        var top = bounds.min.y
        for other in others.sorted(by: { $0.min.y < $1.min.y })
        where other.max.y > bounds.min.y && other.max.x > bounds.min.x
            && other.min.x < bounds.max.x && other.max.z > bounds.min.z
            && other.min.z < bounds.max.z
        {
            // Sorted by height, so every later book starts higher still.
            guard other.min.y <= max(top, bounds.max.y) + 0.5 else { break }
            top = max(top, other.max.y)
        }
        return min(max(top + 0.15 - bounds.min.y, 0.4), 6)
    }

    /// How long a rise of `rise` takes: 0.12 seconds for the least rise, up to 0.25 for a rise
    /// of 3 units or more, so a book with nothing on it leaves at once.
    static func riseDuration(_ rise: Float) -> Double { Double(min(0.25, 0.1 + rise * 0.05)) }

    /// When a book that rises `rise` reaches its details, to the eye; the spring settles within
    /// a few points.
    static func landing(rise: Float) -> Double { riseDuration(rise) + spring.duration }

    /// How far a rise of `rise` has climbed after `time`. It starts at a third of its top
    /// speed, so the book answers a tap at once without jolting the books on it.
    static func climb(_ rise: Float, at time: Double) -> Float {
        let progress = Float(min(1, max(0, time / riseDuration(rise))))
        return rise * progress * (1 + progress) / 2
    }

    /// The upward speed at the top of a rise of `rise`.
    static func topSpeed(_ rise: Float) -> Float { 1.5 * rise / Float(riseDuration(rise)) }

    /// The shade `Book3DView` gives each of the book mesh's material slots (front cover, spine,
    /// pages, and cloth), as the opacity of black over the face, for a book of `size` turned to
    /// `pose`. A slot that several faces share takes the lightest visible face's shade.
    static func shades(of size: SIMD3<Float>, at pose: BookPose) -> [Float] {
        let faces = BookProjection(
            width: CGFloat(size.x), height: CGFloat(size.y), thickness: CGFloat(size.z),
            yaw: pose.yaw, pitch: pose.pitch
        )
        .visibleFaces
        func shade(_ kinds: [BookProjection.FaceKind]) -> Float {
            Float(faces.filter { kinds.contains($0.kind) }.map(\.shade).min() ?? 0)
        }
        return [
            shade([.front]), shade([.spine]), shade([.top, .bottom, .foreEdge]),
            shade([.back, .top, .bottom, .foreEdge]),
        ]
    }

    /// The pose `time` after the book left `clear`, the top of its rise, rising at `speed`, on
    /// its way to `target`. Following a moving target keeps the book on it once it lands.
    static func pose(from clear: Transform, speed: Float, to target: Transform, time: Double)
        -> Transform
    {
        // The spring's share of the way, and its response to a unit initial speed.
        let progress = Float(spring.value(target: 1.0, time: time))
        let coast = Float(spring.value(target: 0.0, initialVelocity: 1.0, time: time))
        var turn = target.rotation * clear.rotation.inverse
        // The shorter way around.
        if turn.real < 0 { turn = simd_quatf(vector: -turn.vector) }
        let rotation =
            turn.angle < 1e-4
            ? target.rotation
            : simd_quatf(angle: turn.angle * progress, axis: turn.axis) * clear.rotation
        return Transform(
            scale: target.scale, rotation: rotation,
            translation: clear.translation + (target.translation - clear.translation) * progress
                + [0, speed * coast, 0])
    }

    /// The velocity that throws a body from `start` to `end` in `whipDuration` under `gravity`.
    static func launch(from start: SIMD3<Float>, to end: SIMD3<Float>, gravity: SIMD3<Float>)
        -> SIMD3<Float>
    {
        (end - start) / whipDuration - gravity * whipDuration / 2
    }

    /// A lively tumble for a book thrown at `velocity`: end over end along its path, with a
    /// twist about it.
    static func spin(for velocity: SIMD3<Float>) -> SIMD3<Float> {
        let across = simd_cross([0, 1, 0], velocity)
        let axis = simd_length(across) > 1e-3 ? simd_normalize(across) : [1, 0, 0]
        return axis * 10 + velocity / max(simd_length(velocity), 1e-3) * 8
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
    /// those walls stand where the view's edges meet a pile `pileHeight` high: room for a
    /// 2.4-unit book standing on end on a 2-unit pile. A pile against the near wall rises
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
}

/// Book sizes, starting poses, and tilt gravity for the pile. Poses are repeatable for a seed.
enum PileLayout {
    /// About 0.56 g at decimeter scale. Full gravity makes a phone-sized pile fall too fast to
    /// follow.
    static let gravity: Float = 55
    static let waveSize = 16
    /// The least time from one wave to the next. It lets the previous wave's highest books
    /// fall below the next wave's lowest cells before those books start.
    static let waveInterval = Duration.milliseconds(750)
    static let spawnHeight: Float = 9
    /// Above the highest start a drop plan gives, 11.4 units over `spawnHeight`.
    static let ceiling: Float = 22
    /// Half the longest book's length plus a little, which keeps a new book clear of the walls.
    static let reach: Float = 1.3
    /// The largest sideways gravity tilt allows, as a fraction of `gravity` (about 27 degrees).
    static let maximumTilt: Float = 0.5

    /// A book lying front cover up with its head to the left (-x) and its spine toward the
    /// camera (+z), so its spine reads left to right like `SpineView`.
    static let lyingFlat = simd_quatf(
        simd_float3x3(columns: ([0, 0, -1], [-1, 0, 0], [0, 1, 0])))

    /// Drop poses above the tray, in waves of `waveSize` books, from `spawnHeight` up.
    ///
    /// Each wave fills a 2 × 8 grid of cells once, in a shuffled order. Cells start at six
    /// heights 2.2 units apart, repeating every three rows, so books in a wave start apart:
    /// cells at one height are three rows apart, farther than a book reaches. Each book starts
    /// at a random yaw, tumbled up to `tumble` radians (about 57 degrees by default), and
    /// spinning. A tray too shallow to keep `reach` from its walls drops every book over its
    /// middle.
    static func dropPlan(
        _ books: [CloudBook], in tray: PileTray, seed: UInt64, tumble: Float = 1
    ) -> [PileSlot] {
        let columns = 2
        let rows = waveSize / columns
        var order: [Int] = []
        return books.enumerated()
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
                let y = spawnHeight + Float((row % 3) * 2 + column) * 2.2 + random(4) * 0.4
                let axis = random(5) * 2 * .pi
                let tumble = simd_quatf(
                    angle: (random(6) - 0.5) * 2 * tumble, axis: [cos(axis), 0, sin(axis)])
                let yaw = simd_quatf(angle: random(7) * 2 * .pi, axis: [0, 1, 0])
                return PileSlot(
                    book: book,
                    transform: Transform(
                        rotation: yaw * tumble * lyingFlat, translation: [x, y, z]),
                    spin: (SIMD3(random(8), random(9), random(10)) - 0.5) * 5)
            }
    }

    /// Starting poses for a still image's pile, in groups that fall together, with heights
    /// above the pile so far.
    ///
    /// Books start over the middle 70 percent of `tray`, tilted a little and without spin. A
    /// group's books start in up to three layers, 1.2, 2.45, and 3.7 units up, so they land
    /// within the 0.4 seconds before the next group; layers 1.25 apart clear two tilted books.
    /// A book takes the lowest layer that no book of its group within 3.4 units uses, since two
    /// books farther apart cannot touch, and a book with no free layer starts the next group.
    static func settleGroups(_ books: [CloudBook], in tray: PileTray, seed: UInt64)
        -> [[PileSlot]]
    {
        var groups: [[PileSlot]] = []
        var layers: [(spot: SIMD2<Float>, layer: Int)] = []
        for var slot in dropPlan(books, in: tray.scaled(by: 0.7), seed: seed, tumble: 0.25) {
            let spot = SIMD2(slot.transform.translation.x, slot.transform.translation.z)
            var taken = Set(layers.filter { simd_distance($0.spot, spot) < 3.4 }.map(\.layer))
            if groups.isEmpty || taken.count == 3 {
                groups.append([])
                layers = []
                taken = []
            }
            let layer = (0..<3).first { !taken.contains($0) } ?? 0
            layers.append((spot, layer))
            slot.transform.translation.y = 1.2 + Float(layer) * 1.25
            slot.spin = .zero
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
    /// width allows, so stacks stay low enough to stand. Books keep their order: the first books
    /// fill the nearest stacks, and each stack's first book lies on top.
    static func stackPlan(_ books: [CloudBook], in tray: PileTray) -> [PileSlot] {
        let rows = max(1, Int((tray.nearZ - tray.farZ) / 2.3))
        let rowDepth = (tray.nearZ - tray.farZ) / Float(rows)
        var stacks: [SIMD2<Float>] = []
        for row in 0..<rows {
            let z = tray.nearZ - (Float(row) + 0.5) * rowDepth
            // The tray narrows toward the viewer, so the row's near side limits its width.
            let half = tray.halfWidth(at: z + rowDepth / 2)
            let columns = max(1, Int(2 * half / 2.7))
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
/// covers download. A new drop reuses the parts of books whose look has not changed. While the
/// view shows the scene, collisions play taps and sounds through `feedback`.
@MainActor
final class BookPileScene {
    /// The scene root, which runs the physics simulation.
    let root = Entity()
    /// Whether the device reports motion, which tilt needs. The Simulator does not.
    static let canTilt = CMMotionManager().isDeviceMotionAvailable

    private static let coverWait = Duration.seconds(1.5)

    /// The camera the pile is seen through, for a renderer that draws the scene without a view.
    let camera = PerspectiveCamera()
    /// Haptics and sounds for collisions, which `BookPileView` starts and stops.
    let feedback = ImpactFeedback()
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
    private var drag: Drag?
    /// Whether the books stand still in tidy stacks, as kinematic bodies. Picking up a book
    /// frees only that book and the books resting on it. Tall stacks of uneven books can slip
    /// as the simulation settles them, and Reduce Motion asks for no motion the reader did not
    /// start.
    private var holdsStill = false
    private var tiltReference: SIMD3<Double>?
    private var gravity = SIMD3<Float>(0, -PileLayout.gravity, 0)
    private var updates: EventSubscription?
    private var collisions: EventSubscription?
    private var lifted: Lifted?
    private var whip: Whip?
    /// A camera-facing walnut plane that dims the pile behind a lifted book, made by the first
    /// lift.
    private var veil: ModelEntity?
    private var veilLevel: Float = 0

    /// The walls' collision group, which a thrown-back book passes through.
    private static let wallGroup = CollisionGroup(rawValue: 1 << 1)

    /// A book lifted out of the pile to stand in for the 3D book on its details.
    ///
    /// It is kinematic. It rises at a velocity set every frame, as a held book moves, so it
    /// shoves the books around and on it aside. Clear of the pile, it collides with nothing, so
    /// the books it carried fall back, and it follows `PileFlight.pose` to the pose that `frame`
    /// and `turn` give, and stays on it. From there until it lands back in the pile, it is drawn
    /// as `Book3DView` draws the details' book: unlit, each face darkened by that view's light.
    private struct Lifted {
        let book: ModelEntity
        let id: Int
        let size: SIMD3<Float>
        let resting: Transform
        let rise: Float
        /// The reader's camera, which returns when the book does.
        let camera: PileCamera
        /// The lit materials the book is drawn from: the pile's, then `dressLifted`'s sharper
        /// ones.
        var materials: [any RealityKit.Material]
        var elapsed: TimeInterval = 0
        /// The book's pose at the top of its rise, once it gets there.
        var clear: Transform?
        /// Where the details draw the book, in normalized device coordinates, and the view's
        /// width-to-height aspect.
        var frame: (center: SIMD2<Float>, height: Float, aspect: Float)?
        var turn = BookPose.resting
        /// Counts the prompt frames in a row since `throwBack` asked for the book back; `nil`
        /// until it does.
        var steadyFrames: Int?
    }

    /// A book thrown back into the pile, with the camera and veil returning to the pile with it.
    private struct Whip {
        /// The lift the book returns from, with its place in the pile and the reader's camera.
        let flight: Lifted
        /// The camera at the launch, which eases back to the reader's.
        let camera: PileCamera
        let veil: Float
        var elapsed: Float = 0
        /// Whether it has hit something, which ends its pass through the walls.
        var landed = false
    }

    private struct PlanKey: Equatable {
        let ids: [Int]
        let tidy: Bool
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
        factory.coverArrived = { [weak self] id, material in self?.retexture(id, cover: material) }
    }

    /// Calls `update` every frame, and plays collisions through `feedback`, while the view
    /// shows the scene. A thrown-back book's first hit lands it instead (see `land`).
    func attach(to content: inout RealityViewCameraContent) {
        content.add(root)
        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.update(event.deltaTime)
        }
        collisions = content.subscribe(to: CollisionEvents.Began.self) { [weak self] event in
            guard let self else { return }
            if let whip, !whip.landed,
                event.entityA === whip.flight.book || event.entityB === whip.flight.book
            {
                land(impulse: event.impulse)
            } else {
                feedback.collide(event, pan: pan)
            }
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
                .generateBox(width: 2, height: 30, depth: simd_length(along) + 4),
                at: (start + end) / 2 + outward + [0, 15, 0], yaw: atan2(along.x, along.z))
        }
        add(.generateBox(width: 90, height: 2, depth: 90), at: [0, PileLayout.ceiling + 1, 0])
        return walls
    }

    // MARK: Filling the pile

    /// Plans a drop of `books`, or tidy stacks when `tidy`, as `fill` does, without dropping
    /// any. Call it before `fill` to learn at once whether the plan kept the lifted book.
    ///
    /// Books added to a dropped list, such as a newly designed book under **Designed only**,
    /// join the books still waiting, when the list keeps the earlier books in their order. Any
    /// other change starts a new pile, which removes every book, the lifted one too.
    func planDrop(
        _ books: [CloudBook], tidy: Bool, generation: Int, viewport: PileViewport
    ) {
        build(viewport)
        guard let tray else { return }
        let key = PlanKey(ids: books.map(\.id), tidy: tidy, generation: generation)
        guard key != planKey else { return }
        if !tidy, let planKey, !planKey.tidy, planKey.generation == generation,
            let added = PileLayout.added(to: planKey.ids, in: books)
        {
            // Plans the waiting books again with the new ones, so the next wave starts in a
            // fresh set of cells.
            let waiting = plan[spawned...].map(\.book) + added
            plan =
                Array(plan[..<spawned])
                + PileLayout.dropPlan(waiting, in: tray, seed: UInt64(generation))
        } else {
            reset(keeping: Set(key.ids))
            plan =
                tidy
                ? PileLayout.stackPlan(books, in: tray)
                : PileLayout.dropPlan(books, in: tray, seed: UInt64(generation))
            holdsStill = tidy
        }
        planKey = key
    }

    /// Drops `books` onto the table, or stacks them when `tidy`, continuing a drop that an
    /// earlier call started for the same books and generation (see `planDrop`).
    ///
    /// Books added to a dropped list fall onto the pile as it is, after the books still
    /// waiting. Returns when every book is in the pile or the task is cancelled. A cancelled
    /// drop, such as one interrupted by opening a book, resumes at its next wave.
    func fill(
        _ books: [CloudBook], tidy: Bool, generation: Int, viewport: PileViewport,
        model: AppModel
    ) async {
        planDrop(books, tidy: tidy, generation: generation, viewport: viewport)
        guard tray != nil else { return }
        let key = PlanKey(ids: books.map(\.id), tidy: tidy, generation: generation)
        while spawned < plan.count {
            let end = min(spawned + PileLayout.waveSize, plan.count)
            let wave = plan[spawned..<end]
            let next = plan[end..<min(end + PileLayout.waveSize, plan.count)]
            await factory.prepare(
                wave.map(\.book), prefetching: next.map(\.book), coverWait: Self.coverWait,
                model: model)
            if !tidy { try? await Task.sleep(until: lastWave + PileLayout.waveInterval) }
            guard !Task.isCancelled, planKey == key else { return }
            for slot in wave { spawn(slot, mode: holdsStill ? .kinematic : .dynamic) }
            spawned += wave.count
            lastWave = .now
        }
        #if DEBUG
            await runDebugActions()
        #endif
    }

    /// Removes every book and returns the camera and gravity to rest. Keeps the parts of the
    /// books in `ids` for the next drop.
    private func reset(keeping ids: Set<Int>) {
        shelf.children.removeAll()
        bookIDs = [:]
        drag = nil
        cameraMove = nil
        lifted = nil
        whip = nil
        showVeil(0, behind: nil)
        spawned = 0
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
    /// so far, tilted a little and without spin, so they land close to where they start and few
    /// land face down, showing only their cloth (see `PileLayout.settleGroups`). Each group
    /// falls for 0.4 seconds before the next one appears, and the pile settles for 2.5 seconds
    /// inside the walls, which keep it compact. The walls stand at least 3.4 units apart, so
    /// even a tray framed closely around one book lets it lie flat at any turn. The walls then
    /// go for a last half second, so no book stays propped against one. Every 10 steps the
    /// interface gets a turn, and a cancelled task stops with `CancellationError`.
    func settle(
        _ books: [CloudBook], on tray: PileTray, camera: PileCamera, seed: UInt64,
        model: AppModel, step: () throws -> Void
    ) async throws {
        look(through: camera)
        // Room for the longest book, 3.15 units corner to corner, tilted a little.
        build(tray.scaled(toFit: 3.4))
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

    private func spawn(_ slot: PileSlot, mode: PhysicsBodyMode) {
        guard let book = factory.makeBook(slot.book.id, mode: mode, lighting: stage.lighting)
        else { return }
        book.components.set(PhysicsMotionComponent(angularVelocity: slot.spin))
        book.transform = slot.transform
        shelf.addChild(book)
        bookIDs[book.id] = slot.book.id
    }

    /// The ID of the book an entity belongs to, or `nil` for the table.
    func bookID(for entity: Entity) -> Int? { bookIDs[entity.id] }

    // MARK: Interaction

    private func update(_ deltaTime: TimeInterval) {
        feedback.advance(by: deltaTime)
        if let lifted {
            if let steady = lifted.steadyFrames {
                // A late frame follows a main-thread stall, such as a large SwiftUI update. The
                // physics would catch up on one during the throw and skip it, so the book
                // holds still until three prompt frames in a row show the stall has passed.
                let frames = deltaTime < 0.05 ? steady + 1 : 0
                self.lifted?.steadyFrames = frames
                if frames >= 3 { launch() }
            } else {
                moveLifted(by: deltaTime)
            }
        }
        if whip != nil { moveWhip(by: Float(deltaTime)) }
        if let drag {
            // Steers the held book toward its target. Velocity, rather than a new position,
            // lets the physics push other books out of the way.
            var velocity = (drag.target - drag.book.position(relativeTo: root)) * 14
            let speed = simd_length(velocity)
            if speed > 50 { velocity *= 50 / speed }
            drag.book.components.set(PhysicsMotionComponent(linearVelocity: velocity))
            self.drag?.velocity = velocity
        }
        if motion.isDeviceMotionActive, let reading = motion.deviceMotion?.gravity {
            let device = SIMD3(reading.x, reading.y, reading.z)
            if tiltReference == nil { tiltReference = device }
            setGravity(
                PileLayout.gravity(
                    device: device, reference: tiltReference ?? device, yaw: view.yaw))
        }
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
        self.drag?.target = tray.clamp(point + drag.offset, margin: 1)
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

    /// Zooms toward the point under `focus` and turns the camera about the pile.
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
        view.yaw = move.start.yaw - Float(rotation.radians)
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

    // MARK: Details

    /// The ID of the lifted book, if any.
    var liftedID: Int? { lifted?.id }

    /// Whether a book is lifted or on its way back, when another book cannot lift.
    var isFlying: Bool { lifted != nil || whip != nil }

    /// Starts lifting the book with `id` toward its details, which `placeLifted` places, and
    /// returns the seconds until it gets there. Returns `nil`, leaving the pile as it was, when
    /// the book is not in the pile or the view does not show the scene.
    ///
    /// The camera eases to its default framing, keeping its turn, so the book in front of it
    /// clears the pile at any zoom. The pile keeps simulating behind the veil.
    func lift(_ id: Int) -> Double? {
        guard !isFlying, root.scene != nil, let parts = factory.parts[id],
            let book = shelf.children.first(where: { bookIDs[$0.id] == id }) as? ModelEntity
        else { return nil }
        endDrag()
        cameraMove = nil
        let others = shelf.children.filter { $0 !== book }
            .map { $0.visualBounds(relativeTo: root) }
        setMode(.kinematic, of: book)
        book.components.set(PhysicsMotionComponent())
        let rise = PileFlight.rise(of: book.visualBounds(relativeTo: root), clearing: others)
        lifted = Lifted(
            book: book, id: id, size: parts.shape.size, resting: book.transform, rise: rise,
            camera: view, materials: parts.materials)
        if veil == nil { veil = makeVeil() }
        return PileFlight.landing(rise: rise)
    }

    /// Sets where the details draw the lifted book: `frame`, in the points of a view of `size`
    /// that shows the whole scene. The book moves at once rather than on the scene's next
    /// update, which would always leave it a frame behind the details as they scroll.
    func placeLifted(_ frame: CGRect, in size: CGSize) {
        guard lifted != nil, size.width > 0, size.height > 0, frame.height > 0 else { return }
        lifted?.frame = (
            center: [
                Float(frame.midX / size.width) * 2 - 1, 1 - Float(frame.midY / size.height) * 2,
            ],
            height: Float(frame.height / size.height) * 2,
            aspect: Float(size.width / size.height)
        )
        fly()
    }

    /// Turns the lifted book to `pose` at once, as a drag turns the details' own book.
    func turnLifted(_ pose: BookPose) {
        guard let lifted, lifted.turn != pose else { return }
        self.lifted?.turn = pose
        fly()
        dress()
    }

    /// Gives the lifted book textures as sharp as the details' own book at `scale` pixels per
    /// point, with `book`'s current cover and design. The book's pile textures take the cover
    /// too, so the book returns to the pile as the details last showed it.
    func dressLifted(_ book: CloudBook, scale: CGFloat, model: AppModel) async {
        guard lifted?.id == book.id, let shape = factory.parts[book.id]?.shape else { return }
        let covers = model.covers
        let small = await covers.image(for: book, maximumPixelSize: factory.coverPixels)
        let cover = await covers.image(for: book) ?? small
        guard !Task.isCancelled, lifted?.id == book.id else { return }
        if let small { await factory.addCover(small, to: book.id) }
        guard
            let dressed = await factory.makeParts(
                book, cover: cover, look: model.look(for: book), shape: shape, scale: scale),
            !Task.isCancelled, lifted?.id == book.id
        else { return }
        lifted?.materials = dressed.materials
        dress()
    }

    /// Throws the lifted book back at the place it left, fast and tumbling, so it crashes into
    /// the books that fell into its place. The camera and the veil return over the same time.
    ///
    /// The book leaves once three frames in a row follow one another closely, so a main-thread
    /// stall from the caller's own changes passes while it holds still. Its details pose can lie
    /// outside the walls or above the ceiling, so it passes through them until it first hits
    /// something, which happens inside them, with a hard tap and knock. Continuous
    /// collision detection keeps it out of the table.
    func throwBack() {
        guard let lifted, lifted.steadyFrames == nil else { return }
        self.lifted?.steadyFrames = 0
        // Stops a rise in progress while the book waits.
        lifted.book.components.set(PhysicsMotionComponent())
    }

    private func launch() {
        guard let lifted else { return }
        self.lifted = nil
        let book = lifted.book
        setMode(.dynamic, of: book)
        book.components[CollisionComponent.self]?.filter = CollisionFilter(
            group: .default, mask: CollisionGroup.all.subtracting(Self.wallGroup))
        let velocity = PileFlight.launch(
            from: book.position(relativeTo: root), to: lifted.resting.translation,
            gravity: gravity)
        book.components.set(
            PhysicsMotionComponent(
                linearVelocity: velocity, angularVelocity: PileFlight.spin(for: velocity)))
        whip = Whip(flight: lifted, camera: view, veil: veilLevel)
    }

    /// Ends a lift or a throw at once: puts the book back above the place it left, at rest, in
    /// its pile textures, and the camera and veil as they were.
    func dropLifted() {
        guard let flight = lifted ?? whip?.flight else { return }
        lifted = nil
        whip = nil
        undress(flight)
        let book = flight.book
        setMode(.dynamic, of: book)
        book.components[CollisionComponent.self]?.filter = .default
        book.components.set(PhysicsMotionComponent())
        var pose = flight.resting
        // Above the books that slid into its place.
        pose.translation.y += flight.rise
        book.transform = pose
        look(through: flight.camera)
        showVeil(0)
    }

    /// Gives a lifted book its pile textures again, which keeps their memory bounded, and its
    /// ribbon.
    private func undress(_ flight: Lifted) {
        flight.book.findEntity(named: BookFactory.ribbonName)?.isEnabled = true
        guard let materials = factory.parts[flight.id]?.materials else { return }
        flight.book.children.first?.components[ModelComponent.self]?.materials = materials
    }

    /// Draws the lifted book from its materials: lit like the pile while it rises, then unlit
    /// and shaded for its turn as `Book3DView` shades the details' own book, without a ribbon,
    /// which that book lacks.
    private func dress() {
        guard let lifted else { return }
        lifted.book.findEntity(named: BookFactory.ribbonName)?.isEnabled = lifted.clear == nil
        let materials =
            lifted.clear == nil
            ? lifted.materials
            : zip(lifted.materials, PileFlight.shades(of: lifted.size, at: lifted.turn))
                .map { BookFactory.unlit($0, shade: $1) }
        lifted.book.children.first?.components[ModelComponent.self]?.materials = materials
    }

    /// Moves the lifted book up out of the pile, then along its flight to the details, while
    /// the camera eases to its default framing and the veil darkens.
    private func moveLifted(by deltaTime: TimeInterval) {
        guard var lifted else { return }
        // A late frame, such as the one that follows mounting the details, slows the flight
        // briefly rather than skipping it ahead.
        lifted.elapsed += min(deltaTime, 1.0 / 20)
        let progress = Float(min(1, lifted.elapsed / PileFlight.landing(rise: lifted.rise)))
        let eased = progress * progress * (3 - 2 * progress)
        look(through: lifted.camera.mixed(with: PileCamera(yaw: lifted.camera.yaw), eased))
        let book = lifted.book
        if lifted.elapsed < PileFlight.riseDuration(lifted.rise) {
            // A velocity, as for a held book, lets the physics shove other books aside.
            let goal =
                lifted.resting.translation
                + [0, PileFlight.climb(lifted.rise, at: lifted.elapsed), 0]
            let step = Float(max(deltaTime, 1.0 / 120))
            book.components.set(
                PhysicsMotionComponent(
                    linearVelocity: (goal - book.position(relativeTo: root)) / step))
            self.lifted = lifted
        } else {
            let leaves = lifted.clear == nil
            if leaves {
                lifted.clear = book.transform
                book.components.set(PhysicsMotionComponent())
                // Above the pile now, it lets the books it carried fall back instead of
                // flinging them along.
                book.components[CollisionComponent.self]?.filter = CollisionFilter(
                    group: [], mask: [])
            }
            self.lifted = lifted
            if leaves { dress() }
            fly()
        }
        showVeil(eased, behind: book)
    }

    /// Puts the lifted book where its flight is at its current time, once it has risen clear.
    /// Following the details' frame and turn as they change keeps the book on them.
    private func fly() {
        guard let lifted, let clear = lifted.clear else { return }
        let target = lifted.frame.map { frame in
            view.detailPose(
                center: frame.center, height: frame.height, size: lifted.size,
                pose: lifted.turn, aspect: frame.aspect)
        }
        lifted.book.transform = PileFlight.pose(
            from: clear, speed: PileFlight.topSpeed(lifted.rise), to: target ?? clear,
            time: lifted.elapsed - PileFlight.riseDuration(lifted.rise))
    }

    /// Returns the camera and veil to the pile while a thrown book falls back.
    ///
    /// The veil stays behind the book and fades out before it would cut through the pile (see
    /// `showVeil`), so the pile shows before the throw ends.
    private func moveWhip(by deltaTime: Float) {
        guard var whip else { return }
        whip.elapsed += min(deltaTime, 1.0 / 20)
        let progress = min(1, whip.elapsed / PileFlight.whipDuration)
        let eased = progress * progress * (3 - 2 * progress)
        look(through: whip.camera.mixed(with: whip.flight.camera, eased))
        showVeil(whip.veil * (1 - eased), behind: whip.flight.book)
        self.whip = whip
        guard progress >= 1 else { return }
        // It reaches its old place now, inside the walls, if nothing stopped it on the way.
        land(impulse: nil)
        self.whip = nil
    }

    /// Ends a thrown book's pass through the walls at its first hit, with a hard tap and
    /// knock through `feedback`, and gives it its pile textures again. `impulse` is the hit's,
    /// or `nil` when the book reached its place without one, which counts as a hit at its speed.
    ///
    /// The throw comes in at tens of units per second, mostly sideways, and tumbling, which
    /// would carry the book across the pile and out of it after the crash. The hit keeps a
    /// quarter of the sideways speed, all of the fall, and half of the tumble, so the book
    /// stays near where it hit.
    private func land(impulse: Float?) {
        guard let whip, !whip.landed else { return }
        self.whip?.landed = true
        let book = whip.flight.book
        book.components[CollisionComponent.self]?.filter = .default
        let mass = book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0.5
        let speed = simd_length(
            book.components[PhysicsMotionComponent.self]?.linearVelocity ?? .zero)
        if var motion = book.components[PhysicsMotionComponent.self] {
            motion.linearVelocity *= [0.25, 1, 0.25]
            motion.angularVelocity *= 0.5
            book.components.set(motion)
        }
        undress(whip.flight)
        feedback.impact(
            impulse: impulse ?? mass * speed, mass: mass, position: book.position(relativeTo: root),
            pan: pan, minimum: 0.85)
    }

    /// A camera child that fills the view with the shelf's walnut wall, unlit and without tone
    /// mapping, so it matches the details' SwiftUI backdrop.
    private func makeVeil() -> ModelEntity {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        if let image = BookFactory.render(
            Rectangle().fill(ShelfPalette.wall).frame(width: 4, height: 128), scale: 1),
            let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        {
            material.color = .init(texture: .init(texture))
        }
        let veil = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
        veil.components.set(DynamicLightShadowComponent(castsShadow: false))
        veil.isEnabled = false
        camera.addChild(veil)
        return veil
    }

    /// Shows the veil at opacity `level`, `PileFlight.veilGap` behind `book`'s middle, so the
    /// book stays in front of it as it flies and the pile behind dims. At a `level` of 1, the
    /// pile does not show through.
    ///
    /// Deep enough to cut through the table or the pile, the veil would draw a line across them,
    /// so it fades out over the last 4 units before the nearest point it could cut: where the
    /// bottom edge of the view meets a pile as high as the walls allow for.
    private func showVeil(_ level: Float, behind book: Entity? = nil) {
        veilLevel = level
        guard let veil else { return }
        veil.isEnabled = level > 0.001
        guard veil.isEnabled, let book else { return }
        func depth(of point: SIMD3<Float>) -> Float {
            -camera.convert(position: point, from: root).z
        }
        let veilDepth = max(1, depth(of: book.position(relativeTo: root))) + PileFlight.veilGap
        let pileDepth =
            PileCamera.intersect(view.ray(ndc: [0, -1], aspect: aspect), height: 4.5)
            .map(depth) ?? veilDepth
        // A little larger than the view at that depth.
        let height = 2.2 * veilDepth * tan(PileCamera.fieldOfView / 2)
        veil.transform = Transform(
            scale: [height * aspect, height, 1], translation: [0, 0, -veilDepth])
        veil.components.set(
            OpacityComponent(opacity: level * min(1, max(0, (pileDepth - veilDepth) / 4))))
    }

    // MARK: Tilt

    /// Starts or stops following the phone's tilt. Stopping returns gravity to straight down.
    func setTilt(_ enabled: Bool) {
        if enabled {
            guard Self.canTilt, !motion.isDeviceMotionActive else { return }
            motion.deviceMotionUpdateInterval = 1 / 30
            motion.startDeviceMotionUpdates()
        } else {
            motion.stopDeviceMotionUpdates()
            tiltReference = nil
            setGravity([0, -PileLayout.gravity, 0])
        }
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
        /// Simulator hooks that run once a drop finishes: `-BookwormsPileFocus <book ID>` zooms
        /// all the way in on that book three seconds later, `-BookwormsPileTilt <x,y>` applies a
        /// device tilt (the change in device gravity, in g), and `-BookwormsPileThrow YES`
        /// throws the top book through the drag path.
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
            guard tilt?.count == 2 || throwsBook else { return }
            try? await Task.sleep(for: .seconds(4))
            if let tilt, tilt.count == 2 {
                setGravity(
                    PileLayout.gravity(
                        device: [tilt[0], tilt[1] - 1, 0], reference: [0, -1, 0], yaw: view.yaw))
            }
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
    #endif
}

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
        build(tray.scaled(toFit: 3.4))
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
    /// enough to leave most covers up.
    func drop(_ group: [PileSlot], base: Float, above falling: Set<Entity.ID>) -> Set<Entity.ID> {
        let top = shelf.children.filter { !falling.contains($0.id) }
            .map { $0.visualBounds(relativeTo: root).max.y }.max() ?? 0
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
