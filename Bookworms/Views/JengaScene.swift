import RealityKit
import SwiftUI

/// A book's block in the tower.
struct JengaBlock {
    let book: CloudBook
    /// The block's size in the book's axes and its binding, which replace the book's own
    /// (`BookFactory.shapes`).
    let shape: BookShape
    let transform: Transform
    /// The layer, counted from the bottom.
    let layer: Int
    /// The block's place across its layer: 0 and 2 outside, 1 in the middle.
    let place: Int
}

/// The tower's layout, the finger's pull on a block, and when the tower has fallen.
///
/// Scene units are decimeters, as in the pile (`PileCamera`), and the table is the plane y = 0.
enum JengaLayout {
    /// A ray in scene coordinates.
    typealias Ray = (origin: SIMD3<Float>, direction: SIMD3<Float>)

    /// The most books the tower holds: 18 layers, as many as a boxed set of the game.
    static let maximumBooks = 54
    /// The least gap between neighboring blocks of a layer.
    static let gap: Float = 0.02
    /// Room between layers, so rounding never starts two blocks overlapping. A layer settles
    /// this far onto the one below without a sound.
    static let clearance: Float = 0.001

    /// The pull's stiffness and damping, per kilogram: a critically damped spring that brings a
    /// free block to the finger in about a fifth of a second.
    static let stiffness: Float = 600
    static let damping: Float = 49
    /// The strongest pull, in kilogram-units per second squared: about ten times a typical
    /// block's weight under the pile's gravity. A loose block slides at once. Friction can hold
    /// a block under many layers, or the pull drags the layers above it along.
    static let maximumForce: Float = 120

    /// How far, in units, a block the reader did not touch must drop below where it was built
    /// to count as fallen, and how many must fall before the tower has.
    static let fallDrop: Float = 1
    static let fallenBlocks = 3

    /// `books` from the earliest finish to the latest, then unfinished books. The sort is
    /// stable, so ties keep their order.
    static func order(_ books: [CloudBook]) -> [CloudBook] {
        books.sorted { first, second in
            guard let a = first.finishedDate else { return false }
            guard let b = second.finishedDate else { return true }
            return a < b
        }
    }

    /// The tower of the first `maximumBooks` books in `books`, bottom up: three to a layer,
    /// each layer crossing the one below at a right angle, the earliest finished books at the
    /// bottom.
    ///
    /// Each book is a block lying front cover up, with its head and tail along the layer. Every
    /// block of a layer takes the layer's length, the mean of its books' heights, and a third
    /// of it as its width, so a layer is square and the next one rests across all three of its
    /// blocks. The covers are cropped to that width.
    ///
    /// Books differ in thickness up to fourfold, and a layer that rested on its thickest block
    /// would rock. The thinnest book of a layer therefore lies in the middle at its own
    /// thickness, and the outer two share their mean thickness, so the next layer lies level
    /// on them, as on two rails. A thinner middle book is loose, as in the game. A top layer of
    /// one book lies in the middle; of two, outside. Outer blocks turn their spines outward,
    /// so the tower's sides show a spine on every other layer and page edges on the rest.
    static func tower(_ books: [CloudBook]) -> [JengaBlock] {
        let step = BookShape.step
        func snap(_ value: Float, _ step: Float) -> Float { (value / step).rounded() * step }
        let ordered = order(Array(books.prefix(maximumBooks)))
        var blocks: [JengaBlock] = []
        var base: Float = 0
        for (layer, start) in stride(from: 0, to: ordered.count, by: 3).enumerated() {
            let group = Array(ordered[start..<min(start + 3, ordered.count)])
            let sizes = group.map { BookShape(of: $0, coverAspect: 2.0 / 3).size }
            let length = snap(sizes.map(\.y).reduce(0, +) / Float(sizes.count), step.y)
            let width = ((length - 2 * gap) / 3 / step.x).rounded(.down) * step.x
            let places: [Int]
            switch group.count {
            case 1: places = [1]
            case 2: places = [0, 2]
            default:
                let thinnest = sizes.indices.min { sizes[$0].z < sizes[$1].z } ?? 0
                let first = thinnest == 0 ? 1 : 0
                places = sizes.indices.map { $0 == thinnest ? 1 : $0 == first ? 0 : 2 }
            }
            let outer = zip(places, sizes).filter { $0.0 != 1 }.map { $0.1.z }
            let rail = outer.isEmpty ? nil : snap(outer.reduce(0, +) / Float(outer.count), step.z)
            // Even layers run along x and lie side by side along z; odd layers the other way.
            let across: SIMD3<Float> = layer.isMultiple(of: 2) ? [0, 0, 1] : [1, 0, 0]
            let spacing = (length - width) / 2
            var top = base
            for (book, (place, size)) in zip(group, zip(places, sizes)) {
                let thickness = place == 1 ? min(size.z, rail ?? size.z) : rail ?? size.z
                let shape = BookShape(size: [width, length, thickness], binding: book.binding)
                // The book's x axis runs from spine to fore edge, so the block at the far side
                // of `across` turns around to show its spine there too.
                let right = across * (place == 2 ? -1 : 1)
                let rotation = simd_quatf(
                    simd_float3x3(columns: (right, simd_cross([0, 1, 0], right), [0, 1, 0])))
                let center =
                    across * Float(place - 1) * spacing + [0, base + shape.size.z / 2, 0]
                blocks.append(
                    JengaBlock(
                        book: book, shape: shape,
                        transform: Transform(rotation: rotation, translation: center),
                        layer: layer, place: place))
                top = max(top, base + shape.size.z)
            }
            base = top + clearance
        }
        return blocks
    }

    /// How far along `axis` from its origin lies the point nearest to `ray`, or `nil` when the
    /// ray runs within about 13 degrees of the axis, where the screen shows too little of the
    /// axis to steer by. `axis.direction` must be a unit vector.
    static func offset(of ray: Ray, along axis: Ray) -> Float? {
        let direction = simd_normalize(ray.direction)
        let cosine = simd_dot(direction, axis.direction)
        let denominator = 1 - cosine * cosine
        guard denominator > 0.05 else { return nil }
        let between = ray.origin - axis.origin
        return (simd_dot(axis.direction, between) - cosine * simd_dot(direction, between))
            / denominator
    }

    /// The pull along a block's axis toward the finger, `error` units ahead of the block, for
    /// a block of `mass` moving at `speed` along the axis: a damped spring, capped at
    /// `maximumForce`.
    static func drive(error: Float, speed: Float, mass: Float) -> Float {
        let force = mass * (stiffness * error - damping * speed)
        return min(maximumForce, max(-maximumForce, force))
    }

    /// Whether the tower has fallen, from how far each block the reader has not slid lies below
    /// where it was built.
    static func hasFallen(drops: [Float]) -> Bool {
        drops.lazy.filter { $0 > fallDrop }.count >= fallenBlocks
    }
}

/// The taps of a block grinding against its neighbors as the finger pulls it.
///
/// A sliding block taps every `step` of travel, harder the harder the finger pulls, so a loose
/// block whispers and a loaded one rasps. A block that the full pull cannot move creaks every
/// `strainInterval` instead.
struct JengaGrind {
    static let step: Float = 0.04
    static let strainInterval: TimeInterval = 0.15

    private var travel: Float = 0
    private var strain: TimeInterval = 0

    /// Advances by `distance` slid in `deltaTime` under `load`, the pull's share of
    /// `JengaLayout.maximumForce`, and returns a tap's strength, from 0 to 1, when one is due.
    mutating func advance(by distance: Float, load: Float, deltaTime: TimeInterval) -> Float? {
        travel += distance
        strain = load > 0.9 ? strain + deltaTime : 0
        if travel >= Self.step {
            travel = 0
            strain = 0
            return 0.12 + 0.4 * min(1, load)
        }
        guard strain >= Self.strainInterval else { return nil }
        strain = 0
        return 0.3
    }
}

/// The tower's camera, which circles the tower and looks down at it.
///
/// It looks at `target` from `distance / zoom` away, pitched down by `pitch` and turned about
/// the vertical axis by `yaw`, and it is moved up or down its own vertical axis so `target`
/// shows at the normalized device height `shift`, the middle of the space between the bars.
/// It shares the pile's vertical field of view (`PileCamera.fieldOfView`).
struct JengaCamera: Equatable {
    /// Steep enough that the top of the view still meets the table, not the room past it.
    static let pitch: Float = 30 * .pi / 180
    static let zoomRange: ClosedRange<Float> = 1...3

    var target = SIMD3<Float>.zero
    /// About 34 degrees from the pile's view, so the tower shows two faces and the lamp, over
    /// the reader's right shoulder, lights the nearer one more.
    var yaw: Float = 0.6
    var distance: Float = 12
    var zoom: Float = 1
    var shift: Float = 0

    var rotation: simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -Self.pitch, axis: [1, 0, 0])
    }

    var transform: Transform {
        let away = distance / zoom
        let slope = tan(PileCamera.fieldOfView / 2)
        return Transform(
            rotation: rotation,
            translation: target + rotation.act([0, -shift * away * slope, away]))
    }

    /// The camera that shows a tower `height` tall on a square base `width` wide, in a view of
    /// width-to-height `aspect`, between the normalized device heights `top` and `bottom`, with
    /// a little room around it.
    init(fitting height: Float, width: Float, aspect: Float, top: Float, bottom: Float) {
        target = [0, height / 2, 0]
        shift = (top + bottom) / 2
        let half = (top - bottom) / 2
        let slope = tan(PileCamera.fieldOfView / 2)
        var distance: Float = 0
        for corner in 0..<8 {
            let point = SIMD3<Float>(
                corner & 1 == 0 ? -width / 2 : width / 2, corner & 2 == 0 ? 0 : height,
                corner & 4 == 0 ? -width / 2 : width / 2)
            // Nearer points have a larger z, as the camera looks along -z.
            let local = rotation.inverse.act(point - target)
            distance = max(
                distance, local.z + abs(local.x) / (slope * aspect),
                (local.y / slope + top * local.z) / half,
                (-local.y / slope - bottom * local.z) / half)
        }
        self.distance = distance * 1.08
    }

    init() {}

    /// The ray from the camera through a point in normalized device coordinates, as
    /// `PileCamera.ray(ndc:aspect:)` gives it.
    func ray(ndc: SIMD2<Float>, aspect: Float) -> JengaLayout.Ray {
        let slope = tan(PileCamera.fieldOfView / 2)
        let direction = simd_normalize(SIMD3(ndc.x * slope * aspect, ndc.y * slope, -1))
        return (transform.translation, rotation.act(direction))
    }

    /// Where `point` appears in normalized device coordinates, the inverse of `ray`.
    func project(_ point: SIMD3<Float>, aspect: Float) -> SIMD2<Float> {
        let local = rotation.inverse.act(point - transform.translation)
        return SIMD2(local.x / aspect, local.y) / (-local.z * tan(PileCamera.fieldOfView / 2))
    }

    /// The height at which the ray through `ndc` crosses the upright plane through `target`
    /// that faces the camera, or `nil` if the ray runs along it.
    func height(under ndc: SIMD2<Float>, aspect: Float) -> Float? {
        let ray = ray(ndc: ndc, aspect: aspect)
        let facing = SIMD3<Float>(sin(yaw), 0, cos(yaw))
        let along = simd_dot(ray.direction, facing)
        guard abs(along) > 1e-4 else { return nil }
        let distance = simd_dot(target - ray.origin, facing) / along
        return ray.origin.y + ray.direction.y * distance
    }
}

/// The tower's RealityKit content: the desk and its lamp (`DeskStage`) and one rigid body per
/// book (`BookFactory`), laid out by `JengaLayout`.
///
/// A held block stays a dynamic body. Each frame, the finger's pull (`JengaLayout.drive`)
/// pushes it along its long axis with a capped impulse, so it grinds against its neighbors
/// and can drag them, and never passes through them. While the view shows the scene,
/// collisions, grinding, and a fall play taps and sounds through `feedback`.
@MainActor
final class JengaScene {
    /// The scene root, which runs the physics simulation.
    let root = Entity()
    /// Haptics and sounds, which `JengaView` starts and stops.
    let feedback = ImpactFeedback()

    /// The lamp's pool: wide enough that its full light reaches the top of a tall tower.
    private static let poolRadius: Float = 4.5
    /// Room under the navigation bar for the held book's title and rating, in points.
    private static let labelRoom: CGFloat = 72

    private let camera = PerspectiveCamera()
    private let factory = BookFactory()
    private let stage = DeskStage()
    private let tower = Entity()
    private var view = JengaCamera()
    private var aspect: Float = 0.5
    private var viewport: PileViewport?
    /// The built tower's height and widest layer, which frame the camera.
    private var size: (height: Float, width: Float) = (3, 2.4)
    private var built: BuildKey?
    private var bookIDs: [Entity.ID: Int] = [:]
    /// Each block's height when built, which tells when the tower falls.
    private var resting: [Entity.ID: Float] = [:]
    /// Blocks the reader has slid, which may fall without the tower falling.
    private var taken: Set<Entity.ID> = []
    private var grip: Grip?
    private var cameraMove: (start: JengaCamera, focus: Float)?
    private var updates: EventSubscription?
    private var collisions: EventSubscription?
    private var sinceCheck: TimeInterval = 0
    private var hasFallen = false

    private struct BuildKey: Equatable {
        let ids: [Int]
        let generation: Int
    }

    /// A block under the finger, pulled along `axis`, its long axis on the table.
    private struct Grip {
        let block: ModelEntity
        let id: Int
        let axis: SIMD3<Float>
        /// Where the block lay when grabbed, and how far along `axis` from there the finger
        /// first touched it.
        let start: SIMD3<Float>
        let grab: Float
        let mass: Float
        let length: Float
        /// How far along `axis` from `start` the finger wants the block.
        var target: Float = 0
        /// How far the block had slid at the last frame.
        var offset: Float = 0
        var grind = JengaGrind()
    }

    init() {
        var simulation = PhysicsSimulationComponent()
        simulation.gravity = [0, -PileLayout.gravity, 0]
        // More iterations than the pile's, which keep a tall stack of resting bodies still.
        simulation.solverIterations = .init(positionIterations: 16, velocityIterations: 4)
        root.components.set(simulation)
        camera.camera = PerspectiveCameraComponent(
            near: 0.5, far: 150, fieldOfViewInDegrees: PileCamera.fieldOfView * 180 / .pi,
            fieldOfViewOrientation: .vertical)
        camera.transform = view.transform
        root.addChild(camera)
        root.addChild(stage.root)
        root.addChild(tower)
        factory.coverArrived = { [weak self] id, material in self?.retexture(id, cover: material) }
    }

    /// Calls `update` every frame, and plays collisions through `feedback`, while the view
    /// shows the scene.
    func attach(to content: inout RealityViewCameraContent) {
        content.add(root)
        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.update(event.deltaTime)
        }
        collisions = content.subscribe(to: CollisionEvents.Began.self) { [weak self] event in
            guard let self else { return }
            feedback.collide(event, pan: pan)
        }
    }

    /// Shows or hides the dust in the lamp's beam.
    func setDust(_ enabled: Bool) { stage.setDust(enabled) }

    /// The ID of the book an entity belongs to, or `nil` for the table.
    func bookID(for entity: Entity) -> Int? { bookIDs[entity.id] }

    // MARK: Building

    /// Builds the tower of `books` (see `JengaLayout.tower`), replacing the one standing. Does
    /// nothing when the tower already stands for the same books and `generation`, such as on
    /// the reader's return from pushed details.
    ///
    /// Every block's parts are built before any block appears, with up to 1.5 seconds for
    /// covers; a cover that arrives later replaces the block's title. The old tower stands
    /// until then. A cancelled build leaves it standing.
    func build(_ books: [CloudBook], generation: Int, model: AppModel) async {
        let key = BuildKey(ids: books.map(\.id), generation: generation)
        guard key != built else { return }
        stage.build(pool: .zero, radius: Self.poolRadius)
        let blocks = JengaLayout.tower(books)
        factory.shapes = Dictionary(
            blocks.map { ($0.book.id, $0.shape) }, uniquingKeysWith: { first, _ in first })
        factory.release(keeping: Set(factory.shapes.keys))
        await factory.prepare(
            blocks.map(\.book), prefetching: [], coverWait: .seconds(1.5), model: model)
        guard !Task.isCancelled else { return }
        clear()
        for block in blocks { spawn(block) }
        size = (
            blocks.map { $0.transform.translation.y + $0.shape.size.z / 2 }.max() ?? 0,
            blocks.map(\.shape.size.y).max() ?? 0
        )
        built = key
        if let viewport { frame(viewport) }
        #if DEBUG
            await runDebugPull()
        #endif
    }

    /// Frames the tower between the bars that cover `viewport`'s edges, leaving room for the
    /// held book's label under the top bar, and returns the camera there.
    func frame(_ viewport: PileViewport) {
        let height = Float(viewport.size.height)
        guard viewport.size.width > 0, height > 0 else { return }
        self.viewport = viewport
        aspect = Float(viewport.size.width) / height
        cameraMove = nil
        view = JengaCamera(
            fitting: size.height, width: size.width, aspect: aspect,
            top: 1 - 2 * Float(viewport.insets.top + Self.labelRoom) / height,
            bottom: -1 + 2 * Float(viewport.insets.bottom) / height)
        camera.transform = view.transform
    }

    /// Removes the blocks and their textures while the tower is out of sight. The next
    /// `build` builds it again.
    func release() {
        clear()
        factory.shapes = [:]
        factory.release(keeping: [])
        built = nil
    }

    private func clear() {
        tower.children.removeAll()
        bookIDs = [:]
        resting = [:]
        taken = []
        grip = nil
        hasFallen = false
        sinceCheck = 0
    }

    private func spawn(_ block: JengaBlock) {
        guard
            let entity = factory.makeBook(
                block.book.id, mode: .dynamic, lighting: stage.lighting)
        else { return }
        entity.transform = block.transform
        // Lets `drive` read the block's velocity, which the simulation writes back here.
        entity.components.set(PhysicsMotionComponent())
        tower.addChild(entity)
        bookIDs[entity.id] = block.book.id
        resting[entity.id] = block.transform.translation.y
    }

    /// Puts a cover that arrived after its block was built onto the block.
    private func retexture(_ id: Int, cover: any RealityKit.Material) {
        for case let block as ModelEntity in tower.children where bookIDs[block.id] == id {
            block.children.first?.components[ModelComponent.self]?
                .materials[Int(BookSlot.cover)] = cover
        }
    }

    // MARK: Interaction

    private func update(_ deltaTime: TimeInterval) {
        feedback.advance(by: deltaTime)
        // A late frame, such as one after a main-thread stall, pulls no harder than a prompt one.
        drive(Float(min(deltaTime, 1.0 / 20)))
        watch(deltaTime)
    }

    /// Takes hold of `entity`, if it is a block, where the finger touched it on `start`, then
    /// pulls it along its long axis toward the finger on `ray`. Returns the held book's ID.
    func slide(_ entity: Entity, from start: JengaLayout.Ray?, to ray: JengaLayout.Ray?) -> Int? {
        if grip == nil, let block = entity as? ModelEntity, let id = bookIDs[block.id],
            let start
        {
            grip = makeGrip(block, id: id, touching: start)
        }
        guard let grip else { return nil }
        if let ray, let along = JengaLayout.offset(of: ray, along: (grip.start, grip.axis)) {
            self.grip?.target = along - grip.grab
        }
        return grip.id
    }

    /// Lets go of the held block, which keeps moving as the physics carries it.
    func endSlide() { grip = nil }

    /// A hold on `block` along its long axis, from where `ray` meets the axis, or from the
    /// block's middle without a ray. Returns `nil` for a block standing on end, which has no
    /// length on the table to slide along, or when the ray runs along the axis.
    private func makeGrip(_ block: ModelEntity, id: Int, touching ray: JengaLayout.Ray?) -> Grip? {
        var axis = block.orientation(relativeTo: root).act([0, 1, 0])
        axis.y = 0
        guard simd_length(axis) > 0.5, let length = factory.parts[id]?.shape.size.y else {
            return nil
        }
        axis = simd_normalize(axis)
        let start = block.position(relativeTo: root)
        var grab: Float = 0
        if let ray {
            guard let along = JengaLayout.offset(of: ray, along: (start, axis)) else { return nil }
            grab = along
        }
        taken.insert(block.id)
        return Grip(
            block: block, id: id, axis: axis, start: start, grab: grab,
            mass: block.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0.3,
            length: length)
    }

    /// Pulls the held block toward the finger for `deltaTime`, and taps while it grinds.
    ///
    /// An impulse of the pull times the frame's duration acts as the pull would however often
    /// the simulation steps. The block grinds while it still overlaps its place in the tower.
    private func drive(_ deltaTime: Float) {
        guard var grip else { return }
        let position = grip.block.position(relativeTo: root)
        let offset = simd_dot(position - grip.start, grip.axis)
        let velocity =
            grip.block.components[PhysicsMotionComponent.self]?.linearVelocity ?? .zero
        let force = JengaLayout.drive(
            error: grip.target - offset, speed: simd_dot(velocity, grip.axis), mass: grip.mass)
        grip.block.applyLinearImpulse(grip.axis * force * deltaTime, relativeTo: nil)
        if abs(offset) < grip.length,
            let strength = grip.grind.advance(
                by: abs(offset - grip.offset), load: abs(force) / JengaLayout.maximumForce,
                deltaTime: TimeInterval(deltaTime))
        {
            feedback.impact(
                impulse: 0, mass: grip.mass, position: position, pan: pan, minimum: strength)
        }
        grip.offset = offset
        self.grip = grip
    }

    /// Checks four times a second whether the tower has fallen, and plays the fall once: the
    /// hardest knock and haptic tap, over the blocks' own hits, and a VoiceOver announcement.
    private func watch(_ deltaTime: TimeInterval) {
        guard !hasFallen, !resting.isEmpty else { return }
        sinceCheck += deltaTime
        guard sinceCheck >= 0.25 else { return }
        sinceCheck = 0
        var drops: [Float] = []
        for block in tower.children where !taken.contains(block.id) {
            if let rest = resting[block.id] {
                drops.append(rest - block.position(relativeTo: root).y)
            }
        }
        guard JengaLayout.hasFallen(drops: drops) else { return }
        hasFallen = true
        feedback.impact(
            impulse: 0, mass: 1, position: [0, size.height / 2, 0], pan: pan, minimum: 1)
        AccessibilityNotification.Announcement("The tower fell").post()
    }

    /// Where `point` shows from left to right on screen, as a stereo position from -0.8 to 0.8.
    private func pan(_ point: SIMD3<Float>) -> Float {
        min(1, max(-1, view.project(point, aspect: aspect).x)) * 0.8
    }

    /// Zooms toward the height under `focus` and turns the camera about the tower.
    func moveCamera(magnification: CGFloat, rotation: Angle, focus: CGPoint?, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if cameraMove == nil {
            let point = focus ?? CGPoint(x: size.width / 2, y: size.height / 2)
            let ndc = SIMD2(
                Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
            cameraMove = (view, view.height(under: ndc, aspect: aspect) ?? view.target.y)
        }
        guard let move = cameraMove else { return }
        let range = JengaCamera.zoomRange
        view.zoom = min(
            range.upperBound, max(range.lowerBound, move.start.zoom * Float(magnification)))
        view.yaw = move.start.yaw - Float(rotation.radians)
        // Keeps the focus height in place while zooming, within the tower.
        let height = move.focus + (move.start.target.y - move.focus) * move.start.zoom / view.zoom
        view.target.y = min(max(height, 0), self.size.height)
        camera.transform = view.transform
    }

    func endCameraMove() { cameraMove = nil }

    #if DEBUG
        /// Simulator hook: `-BookwormsJengaPull <index>` slides the block at that index,
        /// counted from the bottom, out of the tower through the finger's pull, three seconds
        /// after the tower is built.
        private func runDebugPull() async {
            guard
                let index = UserDefaults.standard.string(forKey: "BookwormsJengaPull")
                    .flatMap(Int.init)
            else { return }
            let blocks = Array(tower.children)
            guard blocks.indices.contains(index), let block = blocks[index] as? ModelEntity,
                let id = bookIDs[block.id]
            else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, block.parent === tower, grip == nil,
                let hold = makeGrip(block, id: id, touching: nil)
            else { return }
            grip = hold
            for step in 1...90 {
                try? await Task.sleep(for: .milliseconds(16))
                guard grip?.block === block else { return }
                grip?.target = Float(step) / 90 * hold.length * 1.3
            }
            endSlide()
        }
    #endif
}
