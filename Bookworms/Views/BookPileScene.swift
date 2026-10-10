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

    /// Where `ray` meets the horizontal plane at `height`, or `nil` if it never does.
    static func intersect(
        _ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>), height: Float
    ) -> SIMD3<Float>? {
        guard abs(ray.direction.y) > 1e-4 else { return nil }
        let distance = (height - ray.origin.y) / ray.direction.y
        return distance > 0 ? ray.origin + ray.direction * distance : nil
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
    /// Fits the tray to what the default camera sees between `safeTop` and `safeBottom`, given
    /// as normalized device y coordinates, in a view of width-to-height `aspect`.
    ///
    /// A pile against the far or side walls rises toward the top or sides of the screen, so
    /// those walls stand where the view's edges meet a pile `pileHeight` high: room for a
    /// 2.4-unit book standing on end on a 2-unit pile. A pile against the near wall rises
    /// toward the middle of the screen, so that wall stands where the bottom edge meets the
    /// table.
    init?(aspect: Float, safeTop: Float, safeBottom: Float, pileHeight: Float = 4.5) {
        let camera = PileCamera()
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
}

/// A book's starting pose in the pile.
struct PileSlot {
    let book: CloudBook
    let transform: Transform
    var spin: SIMD3<Float> = .zero
}

/// Book sizes, starting poses, and tilt gravity for the pile. Poses are repeatable for a seed.
enum PileLayout {
    /// About 0.56 g at decimeter scale. Full gravity makes a phone-sized pile fall too fast to
    /// follow.
    static let gravity: Float = 55
    static let waveSize = 16
    static let spawnHeight: Float = 9
    static let ceiling: Float = 13
    /// Half the longest book's length plus a little, which keeps a new book clear of the walls.
    static let reach: Float = 1.3
    /// The largest sideways gravity tilt allows, as a fraction of `gravity` (about 27 degrees).
    static let maximumTilt: Float = 0.5

    /// A book's box: x from spine to fore edge (the cover's width), y from tail to head, and z
    /// from back to front cover. Heights vary by book between 2.1 and 2.4 units.
    static func size(of book: CloudBook, coverAspect: CGFloat) -> SIMD3<Float> {
        let height = 2.1 + 0.3 * Float(ShareStyle.unit(0, book.id, 40))
        return [height * Float(coverAspect), height, height * Float(book.thicknessRatio)]
    }

    /// A book lying front cover up with its head to the left (-x) and its spine toward the
    /// camera (+z), so its spine reads left to right like `SpineView`.
    static let lyingFlat = simd_quatf(
        simd_float3x3(columns: ([0, 0, -1], [-1, 0, 0], [0, 1, 0])))

    /// Drop poses above the tray, in waves of `waveSize` books.
    ///
    /// Each wave fills a 2 × 8 grid of cells once, in a shuffled order, and alternate cells
    /// start 1.6 units higher, so books in a wave start apart. Each book starts at a random yaw,
    /// tumbled up to about 57 degrees, and spinning.
    static func dropPlan(_ books: [CloudBook], in tray: PileTray, seed: UInt64) -> [PileSlot] {
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
                let z = tray.farZ + reach + (tray.nearZ - tray.farZ - 2 * reach) * depth
                let across = (Float(column) + 0.2 + 0.6 * random(3)) / Float(columns) * 2 - 1
                let x = across * max(0, tray.halfWidth(at: z) - reach)
                let y = spawnHeight + Float((row + column) % 2) * 1.6 + random(4) * 0.4
                let axis = random(5) * 2 * .pi
                let tumble = simd_quatf(
                    angle: (random(6) - 0.5) * 2, axis: [cos(axis), 0, sin(axis)])
                let yaw = simd_quatf(angle: random(7) * 2 * .pi, axis: [0, 1, 0])
                return PileSlot(
                    book: book,
                    transform: Transform(
                        rotation: yaw * tumble * lyingFlat, translation: [x, y, z]),
                    spin: (SIMD3(random(8), random(9), random(10)) - 0.5) * 5)
            }
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
                let thickness = size(of: book, coverAspect: 2 / 3).z
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
        return simd_quatf(angle: yaw, axis: [0, 1, 0]).act(
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

/// The pile's RealityKit content: a wooden table, invisible walls and ceiling, warm lights, and
/// one rigid body per book.
///
/// Books arrive a wave at a time. Each wave waits for its own fonts and textures, and at most
/// `coverWait` for its covers, so the first books fall within a second or two while later
/// covers download. A new drop reuses the textures of books whose look has not changed.
///
/// GPU memory stays bounded by the texture sizes. A cover is at most 224 pixels on its long
/// side, cropped to its box's 0.55 to 0.85 aspect: 149 × 224 × 4 bytes (178 KB with mipmaps)
/// for a 2:3 cover, and at most 190 × 224 (227 KB). A spine is 384 pixels long and 5 to 20
/// percent as thick (39 to 158 KB with mipmaps). Three hundred books therefore need about
/// 75 MB, and at most 116 MB, plus 6 MB for the table. Each texture has one material, and books
/// share the page and cloth materials, so materials add nothing per book beyond their textures.
@MainActor
final class BookPileScene {
    /// The scene root, which runs the physics simulation.
    let root = Entity()
    var canTilt: Bool { motion.isDeviceMotionAvailable }

    private static let coverPixels = 224
    private static let coverWait = Duration.seconds(1.5)
    private static let spineLength: CGFloat = 384
    private static let paper = PhysicsMaterialResource.generate(
        staticFriction: 0.6, dynamicFriction: 0.45, restitution: 0)
    /// One unit box with a book's material slots, scaled to each book.
    private static let bookMesh = try? makeBookMesh()

    private let camera = PerspectiveCamera()
    private let shelf = Entity()
    private let environment = Entity()
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
    private var parts: [Int: BookParts] = [:]
    private var cloths: [ColorValue: PhysicallyBasedMaterial] = [:]
    private lazy var pages = Self.surface(
        nil, tint: UIColor(red: 0.93, green: 0.90, blue: 0.82, alpha: 1), roughness: 0.85)
    private var drag: Drag?
    /// Whether the books stand still in tidy stacks, as kinematic bodies. Picking up a book
    /// frees only that book and the books resting on it. Tall stacks of uneven books can slip
    /// as the simulation settles them, and Reduce Motion asks for no motion the reader did not
    /// start.
    private var holdsStill = false
    private var tiltReference: SIMD3<Double>?
    private var gravity = SIMD3<Float>(0, -PileLayout.gravity, 0)
    private var updates: EventSubscription?

    private struct PlanKey: Equatable {
        let ids: [Int]
        let tidy: Bool
        let generation: Int
    }

    /// A book's size and materials, in `bookMesh` slot order: cover, spine, pages, cloth, and
    /// the look they were drawn with, so a changed design or a newly loaded font redraws them.
    private struct BookParts {
        let size: SIMD3<Float>
        var materials: [any RealityKit.Material]
        let look: SpineLook
    }

    /// A book held under a finger. It is kinematic, steered toward `target` on a plane above
    /// where it was picked up, and keeps its offset from the finger.
    private struct Drag {
        let book: ModelEntity
        let height: Float
        let offset: SIMD3<Float>
        var target: SIMD3<Float>
        var velocity = SIMD3<Float>.zero
    }

    init() {
        var simulation = PhysicsSimulationComponent()
        simulation.gravity = gravity
        simulation.solverIterations = .init(positionIterations: 12, velocityIterations: 2)
        root.components.set(simulation)
        camera.camera = PerspectiveCameraComponent(
            near: 0.5, far: 150, fieldOfViewInDegrees: PileCamera.fieldOfView * 180 / .pi,
            fieldOfViewOrientation: .vertical)
        camera.transform = view.transform
        root.addChild(camera)
        root.addChild(shelf)
    }

    /// Calls `update` every frame while the view shows the scene.
    func attach(to content: inout RealityViewCameraContent) {
        content.add(root)
        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.update()
        }
    }

    // MARK: Building

    /// Adds the table, walls, and lights the first time the view has a size.
    private func build(_ viewport: PileViewport) {
        guard tray == nil, viewport.size.width > 0, viewport.size.height > 0 else { return }
        let height = Float(viewport.size.height)
        aspect = Float(viewport.size.width) / height
        guard
            let tray = PileTray(
                aspect: aspect, safeTop: 1 - 2 * Float(viewport.insets.top) / height,
                safeBottom: -1 + 2 * Float(viewport.insets.bottom) / height)
        else { return }
        self.tray = tray
        if let image = Self.studioEnvironment(),
            let resource = try? EnvironmentResource(equirectangular: image, options: .init())
        {
            environment.components.set(
                ImageBasedLightComponent(source: .single(resource), intensityExponent: 0.3))
        }
        root.addChild(environment)
        root.addChild(makeTable())
        root.addChild(Self.makeWalls(around: tray))
        // A warm lamp above and to the left of the reader, with soft shadows.
        let lamp = DirectionalLight()
        lamp.light = DirectionalLightComponent(
            color: UIColor(red: 1, green: 0.9, blue: 0.78, alpha: 1), intensity: 2400)
        lamp.shadow = DirectionalLightComponent.Shadow(
            shadowProjection: .automatic(maximumDistance: 45), depthBias: 1.5)
        lamp.look(at: .zero, from: [-7, 20, 9], relativeTo: nil)
        root.addChild(lamp)
    }

    private func makeTable() -> Entity {
        var material = Self.surface(
            nil, tint: UIColor(red: 0.68, green: 0.5, blue: 0.36, alpha: 1), roughness: 0.7)
        if let image = UIImage(named: "TableWood")?.cgImage,
            let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        {
            let sampler = MTLSamplerDescriptor()
            sampler.sAddressMode = .repeat
            sampler.tAddressMode = .repeat
            sampler.minFilter = .linear
            sampler.magFilter = .linear
            sampler.mipFilter = .linear
            sampler.maxAnisotropy = 8
            material.baseColor.texture = .init(texture, sampler: .init(sampler))
            // One 1024-pixel tile spans 10 units (a meter) of the 90-unit table.
            material.textureCoordinateTransform = .init(scale: [9, 9])
        }
        let table = ModelEntity(mesh: .generatePlane(width: 90, depth: 90), materials: [material])
        table.components.set(
            CollisionComponent(shapes: [
                ShapeResource.generateBox(width: 90, height: 2, depth: 90)
                    .offsetBy(translation: [0, -1, 0])
            ]))
        table.components.set(
            PhysicsBodyComponent(
                massProperties: .default,
                material: .generate(staticFriction: 0.7, dynamicFriction: 0.55, restitution: 0.1),
                mode: .static))
        table.components.set(ImageBasedLightReceiverComponent(imageBasedLight: environment))
        return table
    }

    /// Static walls along the tray's edges and a ceiling above the drop height. They have no
    /// model, so books seem to bump into the edges of the screen.
    private static func makeWalls(around tray: PileTray) -> Entity {
        let walls = Entity()
        let material = PhysicsMaterialResource.generate(
            staticFriction: 0.1, dynamicFriction: 0.1, restitution: 0.3)
        func add(_ shape: ShapeResource, at position: SIMD3<Float>, yaw: Float = 0) {
            let wall = Entity()
            wall.components.set(CollisionComponent(shapes: [shape]))
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

    /// Drops `books` onto the table, or stacks them when `tidy`, continuing a drop that an
    /// earlier call started for the same books and generation.
    ///
    /// Returns when every book is in the pile or the task is cancelled. A cancelled drop, such
    /// as one interrupted by opening a book, resumes at its next wave.
    func fill(
        _ books: [CloudBook], tidy: Bool, generation: Int, viewport: PileViewport,
        model: AppModel
    ) async {
        build(viewport)
        guard let tray else { return }
        let key = PlanKey(ids: books.map(\.id), tidy: tidy, generation: generation)
        if key != planKey {
            reset(keeping: Set(key.ids))
            planKey = key
            plan =
                tidy
                ? PileLayout.stackPlan(books, in: tray)
                : PileLayout.dropPlan(books, in: tray, seed: UInt64(generation))
            holdsStill = tidy
        }
        while spawned < plan.count {
            let end = min(spawned + PileLayout.waveSize, plan.count)
            let wave = plan[spawned..<end]
            let next = plan[end..<min(end + PileLayout.waveSize, plan.count)]
            await prepare(wave.map(\.book), prefetching: next.map(\.book), model: model)
            if !tidy {
                // Lets the previous wave fall clear of the spawn cells first.
                try? await Task.sleep(until: lastWave + .milliseconds(350))
            }
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
        spawned = 0
        parts = parts.filter { ids.contains($0.key) }
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
        cloths = [:]
        plan = []
        planKey = nil
    }

    /// Builds the parts of the books that lack them or whose look changed. Covers download in
    /// parallel; spines render on the main actor once their fonts load, because
    /// `ImageRenderer` draws synchronously.
    ///
    /// A book whose cover takes longer than `coverWait` is built with its title on the cloth,
    /// and its cover replaces the title when the download finishes. Once this wave's covers
    /// arrive or time out, the covers of `upcoming` books start downloading, so the next wave
    /// finds them in the cover store while this one builds and falls. The cover store shares
    /// downloads still in flight with later requests.
    private func prepare(
        _ books: [CloudBook], prefetching upcoming: [CloudBook], model: AppModel
    ) async {
        let missing = books.filter { parts[$0.id]?.look != model.look(for: $0) }
        guard !missing.isEmpty else { return }
        await model.fonts.load(missing.compactMap { model.library?.designs[$0.id] })
        let covers = model.covers
        let pixels = Self.coverPixels
        let (arrivals, delivery) = AsyncStream.makeStream(of: (Int, UIImage?).self)
        for book in missing {
            Task { delivery.yield((book.id, await covers.image(for: book, maximumPixelSize: pixels))) }
        }
        let deadline = Task {
            try? await Task.sleep(for: Self.coverWait)
            delivery.finish()
        }
        var arrived = Set<Int>()
        var images: [Int: UIImage] = [:]
        for await (id, image) in arrivals {
            arrived.insert(id)
            images[id] = image
            if arrived.count == missing.count { break }
        }
        deadline.cancel()
        for book in upcoming where parts[book.id] == nil {
            Task { _ = await covers.image(for: book, maximumPixelSize: pixels) }
        }
        for book in missing where !Task.isCancelled {
            parts[book.id] = await makeParts(
                book, cover: images[book.id], look: model.look(for: book))
            if !arrived.contains(book.id) {
                Task { [weak self] in
                    guard let cover = await covers.image(for: book, maximumPixelSize: pixels)
                    else { return }
                    await self?.addCover(cover, to: book.id)
                }
            }
        }
    }

    /// Puts a cover that arrived after its book was built onto the book's front, cropped to
    /// the book's box, and onto the book in the pile.
    private func addCover(_ cover: UIImage, to id: Int) async {
        guard let size = parts[id]?.size, let image = Self.crop(cover, to: size),
            let texture = await Self.texture(image)
        else { return }
        let material = Self.coverSurface(texture)
        parts[id]?.materials[0] = material
        for case let book as ModelEntity in shelf.children where bookIDs[book.id] == id {
            book.children.first?.components[ModelComponent.self]?.materials[0] = material
        }
    }

    private func makeParts(_ book: CloudBook, cover: UIImage?, look: SpineLook) async -> BookParts {
        let size = PileLayout.size(of: book, coverAspect: Book3DView.aspect(of: cover))
        let thickness = max(16, (Self.spineLength * book.thicknessRatio).rounded())
        let spine = Self.render(
            SpineView(book: book, look: look)
                .frame(width: Self.spineLength, height: thickness)
                .background(look.background.color))
        // Facing the camera, `Book3DView` draws only its front: the cover, or the title on the
        // spine's cloth when there is none.
        let front =
            cover.flatMap { Self.crop($0, to: size) }
            ?? Self.render(
                Book3DView(
                    book: book, look: look, cover: nil, height: CGFloat(Self.coverPixels), yaw: 0,
                    pitch: 0
                )
                .background(look.background.color))
        let coverTexture = await Self.texture(front)
        let spineTexture = await Self.texture(spine)
        let cloth =
            cloths[look.background]
            ?? Self.surface(nil, tint: UIColor(look.background.color), roughness: 0.56)
        cloths[look.background] = cloth
        return BookParts(
            size: size,
            materials: [
                coverTexture.map(Self.coverSurface) ?? cloth,
                spineTexture.map { Self.surface($0, roughness: 0.56) } ?? cloth,
                pages, cloth,
            ],
            look: look)
    }

    private func spawn(_ slot: PileSlot, mode: PhysicsBodyMode) {
        guard let parts = parts[slot.book.id], let mesh = Self.bookMesh else { return }
        let size = parts.size
        let shape = ShapeResource.generateBox(size: size)
        let book = ModelEntity()
        book.components.set(CollisionComponent(shapes: [shape]))
        book.components.set(InputTargetComponent())
        // Paper weighs about 0.7 kg per liter, and a cubic decimeter is a liter.
        var body = PhysicsBodyComponent(
            shapes: [shape], mass: size.x * size.y * size.z * 0.7, material: Self.paper,
            mode: mode)
        body.isContinuousCollisionDetectionEnabled = true
        body.linearDamping = 0.05
        body.angularDamping = 0.3
        book.components.set(body)
        book.components.set(PhysicsMotionComponent(angularVelocity: slot.spin))
        book.transform = slot.transform
        let model = Entity()
        model.components.set(ModelComponent(mesh: mesh, materials: parts.materials))
        model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: environment))
        model.scale = size
        book.addChild(model)
        shelf.addChild(book)
        bookIDs[book.id] = slot.book.id
    }

    /// The ID of the book an entity belongs to, or `nil` for the table.
    func bookID(for entity: Entity) -> Int? { bookIDs[entity.id] }

    // MARK: Interaction

    private func update() {
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
            setMode(.kinematic, of: book)
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

    // MARK: Tilt

    /// Starts or stops following the phone's tilt. Stopping returns gravity to straight down.
    func setTilt(_ enabled: Bool) {
        if enabled {
            guard canTilt, !motion.isDeviceMotionActive else { return }
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

    // MARK: Resources

    private static func texture(_ image: CGImage?) async -> TextureResource? {
        guard let image else { return nil }
        return try? await TextureResource(image: image, options: .init(semantic: .color))
    }

    /// The middle of `cover` at the width-to-height aspect of a box of `size`.
    private static func crop(_ cover: UIImage, to size: SIMD3<Float>) -> CGImage? {
        guard let image = cover.cgImage else { return nil }
        return image.cropping(
            to: PileLayout.crop(
                CGSize(width: image.width, height: image.height), to: CGFloat(size.x / size.y)))
    }

    private static func coverSurface(_ texture: TextureResource) -> PhysicallyBasedMaterial {
        surface(texture, roughness: 0.5, specular: 0.25)
    }

    private static func render(_ content: some View) -> CGImage? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage
    }

    /// A nonmetallic surface with low reflectance. The bright environment otherwise lays a gray
    /// haze over dark covers, as on the Apple TV Book Wall.
    private static func surface(
        _ texture: TextureResource?, tint: UIColor = .white, roughness: Float,
        specular: Float = 0.1
    ) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: tint, texture: texture.map { .init($0) })
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: 0)
        material.specular = .init(floatLiteral: specular)
        return material
    }

    /// A warm studio gradient for image-based light, bright above and dim below. It varies only
    /// from top to bottom, so its orientation does not matter.
    private static func studioEnvironment() -> CGImage? {
        let size = CGSize(width: 256, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                let colors = [
                    UIColor(red: 1, green: 0.96, blue: 0.9, alpha: 1),
                    UIColor(red: 0.86, green: 0.8, blue: 0.72, alpha: 1),
                    UIColor(red: 0.36, green: 0.3, blue: 0.25, alpha: 1),
                ]
                guard
                    let gradient = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.5, 1])
                else { return }
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            .cgImage
    }

    /// A unit cube centered on the origin, in a book's axes (see `PileLayout.size`), with four
    /// material slots: 0 for the front cover, 1 for the spine, 2 for the page edges, and 3 for
    /// the back cover and the boards' edges.
    ///
    /// Each face's texture runs along its `u` and `v` edges, and `u × v` points out of the
    /// book, so every quad winds counterclockwise seen from outside. The front cover's image
    /// stands upright with its left edge at the spine. The spine's image runs head to tail
    /// with its top toward the front cover, matching `UprightSpineView`. The head, tail, and
    /// fore edge show cloth-colored boards across their outer eighths, like `Book3DView`.
    private static func makeBookMesh() throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var coordinates: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var slots: [UInt32] = []
        func face(
            _ origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, slot: UInt32,
            from start: Float = 0, to end: Float = 1
        ) {
            let base = UInt32(positions.count)
            for (a, b) in [(0, start), (1, start), (1, end), (0, end)] as [(Float, Float)] {
                positions.append(origin + a * u + b * v)
                normals.append(simd_normalize(simd_cross(u, v)))
                coordinates.append([a, b])
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            slots += [slot, slot]
        }
        let h: Float = 0.5
        face([-h, -h, h], u: [1, 0, 0], v: [0, 1, 0], slot: 0)
        face([-h, h, -h], u: [0, -1, 0], v: [0, 0, 1], slot: 1)
        face([h, -h, -h], u: [-1, 0, 0], v: [0, 1, 0], slot: 3)
        let board: Float = 0.125
        for (origin, u, v) in [
            (SIMD3<Float>(h, -h, -h), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)),
            ([h, h, -h], [-1, 0, 0], [0, 0, 1]),
            ([-h, -h, -h], [1, 0, 0], [0, 0, 1]),
        ] {
            face(origin, u: u, v: v, slot: 3, to: board)
            face(origin, u: u, v: v, slot: 2, from: board, to: 1 - board)
            face(origin, u: u, v: v, slot: 3, from: 1 - board)
        }
        var descriptor = MeshDescriptor(name: "book")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(coordinates)
        descriptor.primitives = .triangles(indices)
        descriptor.materials = .perFace(slots)
        return try MeshResource.generate(from: [descriptor])
    }

    #if DEBUG
        /// Simulator hooks that run once a drop finishes: `-BookwormsPileTilt <x,y>` applies a
        /// device tilt (the change in device gravity, in g), and `-BookwormsPileThrow YES`
        /// throws the top book through the drag path.
        private func runDebugActions() async {
            let defaults = UserDefaults.standard
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

extension ClosedRange where Bound == Float {
    fileprivate func clamp(_ value: Float) -> Float {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
