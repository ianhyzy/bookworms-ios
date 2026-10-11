import RealityKit
import SwiftUI
import UIKit

/// The Bookworm's RealityKit content: the desk and its lamp (`DeskStage`), a block of books
/// (`BookFactory`) laid out by `BookwormLayout`, and a cartoon worm that eats through them.
///
/// The worm is a green head with a face (eyes, round glasses, cheeks, and a smile), a short
/// green tail, and a body that gains one segment per book, in the book's spine color, as long
/// as `BookwormLayout.segmentLength` gives for its pages. Every round part is the same unit
/// sphere mesh, scaled; the glasses and the smile share two ring meshes; and parts of one
/// color share a material. The body follows the head's `WormTrail` and sways from side to
/// side behind it. The worm has no physics: it passes through books, and only books collide.
///
/// The camera frames the block between the bars (`BookwormLayout.framing`). The head crawls to
/// each stack in turn, stops just outside it (`BookwormLayout.biteSpot`), and eats it from the
/// bottom up, pecking as it chews. A book being eaten turns kinematic and shrinks into the
/// mouth in a burst of paper crumbs while the books on it sink with its top, then leaves the
/// scene, and the books above settle onto the table or the books below. After the last book,
/// the worm curls up in the middle of the table, facing the camera, which moves in to frame
/// it, and the worm blinks now and then. A tapped segment swells for a moment. The caption
/// reads `eatenBooks`, `eatenPages`, and `isFinished`.
@MainActor
@Observable
final class BookwormScene {
    /// The books the worm has eaten so far, and their pages, for the caption.
    private(set) var eatenBooks = 0
    private(set) var eatenPages = 0
    /// Set once the worm has eaten every book and curled up.
    private(set) var isFinished = false
    /// Set while the books' textures are prepared, before the worm starts.
    private(set) var isLoading = false
    /// Whether the worm moves. Pausing stops the worm, its sway, and the book it is eating;
    /// books already falling still settle.
    var isPlaying = true {
        didSet {
            // A kinematic body keeps its velocity, so the book being eaten would sink on.
            guard !isPlaying, case .eating(let index, _) = phase else { return }
            books[meal[index].book.id]?.components.set(PhysicsMotionComponent())
        }
    }

    /// The scene root, which runs the physics simulation.
    let root = Entity()
    /// Haptics and sounds for collisions and bites, which `BookwormView` starts and stops.
    let feedback = ImpactFeedback()
    private let camera = PerspectiveCamera()
    private let factory = BookFactory()
    private let stage = DeskStage()
    private let block = Entity()
    private let worm = Entity()

    /// A book in eating order, with what it adds to the worm.
    private struct Course {
        let book: CloudBook
        let stack: Int
        /// The middle of its stack on the table, as (x, z).
        let spot: SIMD2<Float>
        let color: ColorValue
        let length: Float
    }

    private struct Segment {
        let entity: ModelEntity
        let length: Float
        let radius: Float
        /// How far the segment has grown in behind the head, from 0 to 1.
        var growth: Float
    }

    /// A book being eaten: where its bottom was when the bite began, and its thickness.
    private struct Bite {
        var elapsed: Float = 0
        let bottom: Float
        let thickness: Float
    }

    /// A camera's place: the point it looks at, and its distance from it.
    private struct Shot {
        var target = SIMD3<Float>.zero
        var distance: Float = 30
    }

    private enum Phase {
        case idle
        case crawling(to: Int, target: SIMD2<Float>)
        case eating(Int, Bite)
        case curling(elapsed: Float)
        case done
    }

    /// Parts built by the first `start`, so a view that SwiftUI creates and drops right away
    /// costs little.
    private struct Parts {
        let head: ModelEntity
        let eyes: [Entity]
        let sphere: MeshResource
        let shape: ShapeResource
        let crumbs: Entity
    }

    @ObservationIgnored private var parts: Parts?
    @ObservationIgnored private var skins: [ColorValue: PhysicallyBasedMaterial] = [:]
    @ObservationIgnored private var meal: [Course] = []
    @ObservationIgnored private var books: [Int: ModelEntity] = [:]
    /// The book each tappable entity, a book or a segment, stands for.
    @ObservationIgnored private var names: [Entity.ID: Int] = [:]
    /// The body behind the head, newest segment first, ending with the tail.
    @ObservationIgnored private var segments: [Segment] = []
    @ObservationIgnored private var trail = WormTrail(head: .zero, heading: [0, -1])
    @ObservationIgnored private var heading = SIMD2<Float>(0, -1)
    @ObservationIgnored private var phase = Phase.idle
    /// Seconds the worm has moved, which drive its sway.
    @ObservationIgnored private var clock: Float = 0
    @ObservationIgnored private var sways = true
    /// Each part's place on the table, head first, when the curl starts and ends.
    @ObservationIgnored private var curlStart: [SIMD2<Float>] = []
    @ObservationIgnored private var curlEnd: [SIMD2<Float>] = []
    @ObservationIgnored private var curlTurn = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    @ObservationIgnored private var viewport = PileViewport(size: .zero, insets: .init())
    /// The corners of boxes around the block and around the curled worm, which the camera
    /// keeps in view before and after the curl, and the camera's place for each.
    @ObservationIgnored private var blockBox: [SIMD3<Float>] = []
    @ObservationIgnored private var curlBox: [SIMD3<Float>] = []
    @ObservationIgnored private var shots = (block: Shot(), curl: Shot())
    /// How far the camera has moved from the block's shot to the curl's, from 0 to 1.
    @ObservationIgnored private var shotBlend: Float = 0
    /// Counts `start` and `release` calls, so a start that an earlier call began stops.
    @ObservationIgnored private var run = 0
    /// The tapped segment that swells, and seconds since the tap.
    @ObservationIgnored private var pop: (id: Entity.ID, elapsed: Float)?
    /// Buffers that `layoutBody` reuses every frame.
    @ObservationIgnored private var distances: [Float] = []
    @ObservationIgnored private var samples: [(point: SIMD2<Float>, forward: SIMD2<Float>)] = []
    @ObservationIgnored private var updates: EventSubscription?
    @ObservationIgnored private var collisions: EventSubscription?

    private static let fieldOfView: Float = 38 * .pi / 180
    private static let pitch: Float = 50 * .pi / 180
    private static let curlDuration: Float = 1.6
    private static let growDuration: Float = 0.35
    /// The worm's green, for its head and tail.
    private static let green = ColorValue(red: 122, green: 176, blue: 72)
    /// Segments are triggers in their own group that collide with nothing: their mask holds
    /// only a group no entity is in. Tap hit tests skip an entity whose mask is empty.
    private static let wormGroup = CollisionGroup(rawValue: 1 << 2)
    private static let nothing = CollisionGroup(rawValue: 1 << 3)
    /// How long a tapped segment swells and settles, in seconds.
    private static let popDuration: Float = 0.4

    init() {
        var simulation = PhysicsSimulationComponent()
        simulation.gravity = [0, -PileLayout.gravity, 0]
        simulation.solverIterations = .init(positionIterations: 12, velocityIterations: 2)
        root.components.set(simulation)
        camera.camera = PerspectiveCameraComponent(
            near: 0.5, far: 200, fieldOfViewInDegrees: Self.fieldOfView * 180 / .pi,
            fieldOfViewOrientation: .vertical)
        root.addChild(camera)
        root.addChild(stage.root)
        root.addChild(block)
        root.addChild(worm)
        factory.coverArrived = { [weak self] id, material in
            self?.books[id]?.children.first?.components[ModelComponent.self]?
                .materials[Int(BookSlot.cover)] = material
        }
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

    /// Frames the block, or the curled worm, between the bars over `viewport`.
    func setViewport(_ viewport: PileViewport) {
        guard viewport.size.height > 0, viewport != self.viewport else { return }
        self.viewport = viewport
        frame()
    }

    /// The book that a tapped book or segment stands for, if any.
    func bookID(for entity: Entity) -> Int? { names[entity.id] }

    /// Swells a tapped segment for a moment, so the reader sees which one names its book.
    func pop(_ entity: Entity) {
        guard segments.contains(where: { $0.entity == entity }) else { return }
        pop = (entity.id, 0)
    }

    // MARK: Building

    /// Builds the block of `meal`, books in eating order, and starts the worm toward the first
    /// stack. With `finished`, as Reduce Motion asks, shows the worm curled up after the meal
    /// instead, without the books. Waits up to 1.5 seconds for covers; a book whose cover
    /// arrives later shows its title until it does. Returns early if cancelled or restarted.
    func start(_ meal: [CloudBook], finished: Bool, model: AppModel) async {
        reset()
        let token = run
        let bricks = BookwormLayout.block(meal)
        guard !bricks.isEmpty else { return }
        makeParts()
        self.meal = bricks.map { brick in
            Course(
                book: brick.book, stack: brick.stack, spot: [brick.center.x, brick.center.z],
                color: model.look(for: brick.book).background,
                length: BookwormLayout.segmentLength(pages: brick.book.pages))
        }
        // Each stack's footprint is about its pitch, and the worm's head, which bites from
        // the stack's near side, reaches a little past it. The camera keeps at least two
        // stacks' width in view, so a small block does not fill the screen. The worm crawls in
        // from below the screen.
        let corner = bricks.reduce(SIMD3<Float>.zero) { pointwiseMax($0, abs($1.center)) }
        let half = pointwiseMax(
            SIMD2(corner.x, corner.z) + BookwormLayout.stackPitch / 2, BookwormLayout.stackPitch)
        blockBox = Self.box([-half.x, 0, -half.y], [half.x, corner.y + 0.3, half.y + 0.3])
        shotBlend = 0
        frame()
        addSegment(color: Self.green, length: 0.3, radius: BookwormLayout.bodyRadius * 0.7)
        sways = !finished
        if finished {
            for course in self.meal { eat(course) }
            worm.isEnabled = true
            startCurl()
            place(curl: 1)
            shotBlend = 1
            placeCamera()
            phase = .done
            isFinished = true
            return
        }
        isLoading = true
        await factory.prepare(meal, prefetching: [], coverWait: .seconds(1.5), model: model)
        guard run == token else { return }
        isLoading = false
        guard !Task.isCancelled else { return }
        for brick in bricks {
            guard
                let book = factory.makeBook(
                    brick.book.id, mode: .dynamic, lighting: stage.lighting)
            else { continue }
            // A slight turn, so the stacks look placed by hand.
            let jitter = Float(ShareStyle.unit(0, brick.book.id, 11)) - 0.5
            book.transform = Transform(
                rotation: simd_quatf(angle: jitter * 0.06, axis: [0, 1, 0]) * PileLayout.lyingFlat,
                translation: brick.center)
            block.addChild(book)
            books[brick.book.id] = book
            names[book.id] = brick.book.id
        }
        // The worm comes in from the near side, toward the first stack.
        heading = [0, -1]
        trail = WormTrail(head: self.meal[0].spot + [0, 3.2], heading: heading)
        worm.isEnabled = true
        phase = .crawling(to: 0, target: biteSpot(0))
        layoutBody()
    }

    /// Removes the books and the worm, and releases the books' textures while the view is out
    /// of sight. The next `start` builds them again.
    func release() {
        reset()
        factory.release(keeping: [])
    }

    private func reset() {
        run &+= 1
        curlBox = []
        pop = nil
        block.children.removeAll()
        for segment in segments { segment.entity.removeFromParent() }
        segments = []
        books = [:]
        names = [:]
        meal = []
        phase = .idle
        clock = 0
        worm.isEnabled = false
        eatenBooks = 0
        eatenPages = 0
        isFinished = false
        isLoading = false
        isPlaying = true
    }

    private func makeParts() {
        guard parts == nil else { return }
        stage.build(pool: .zero, radius: 7)
        let sphere = MeshResource.generateSphere(radius: 1)
        let head = ModelEntity(mesh: sphere, materials: [skin(Self.green)])
        head.components.set(GroundingShadowComponent(castsShadow: true))
        stage.light(head)
        worm.addChild(head)
        // The face, in the head's unit-sphere space with the front toward +z: eyes high on the
        // head that look up toward the camera, round glasses that sit just off the face, rosy
        // cheeks, and a smile.
        let white = BookFactory.surface(nil, tint: .white, roughness: 0.3, specular: 0.4)
        let black = BookFactory.surface(nil, tint: .black, roughness: 0.2, specular: 0.5)
        let rims = BookFactory.surface(
            nil, tint: UIColor(red: 0.2, green: 0.12, blue: 0.08, alpha: 1), roughness: 0.25,
            specular: 0.5)
        let blush = BookFactory.surface(
            nil, tint: UIColor(red: 0.96, green: 0.52, blue: 0.5, alpha: 1), roughness: 0.7,
            specular: 0.1)
        let ring = Self.mesh(BookwormLayout.ring(arc: 2 * .pi, tube: 0.09))
        let arc = Self.mesh(BookwormLayout.ring(arc: .pi * 0.6, tube: 0.12))
        let facing = simd_normalize(SIMD3<Float>(0, 0.55, 0.66))
        let lenses = simd_quatf(from: [0, 0, 1], to: facing)
        var eyes: [Entity] = []
        func add(
            _ mesh: MeshResource?, _ material: PhysicallyBasedMaterial, to parent: Entity,
            scale: SIMD3<Float>, at position: SIMD3<Float>,
            rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        ) -> Entity {
            let part = ModelEntity(mesh: mesh ?? sphere, materials: [material])
            part.transform = Transform(scale: scale, rotation: rotation, translation: position)
            stage.light(part)
            parent.addChild(part)
            return part
        }
        for side: Float in [-1, 1] {
            let center = SIMD3<Float>(side * 0.38, 0.55, 0.66)
            let eye = add(sphere, white, to: head, scale: .init(repeating: 0.3), at: center)
            _ = add(
                sphere, black, to: eye, scale: .init(repeating: 0.5),
                at: simd_normalize(SIMD3<Float>(side * -0.08, 0.6, 0.8)) * 0.68)
            eyes.append(eye)
            _ = add(
                ring, rims, to: head, scale: .init(repeating: 0.33), at: center + facing * 0.2,
                rotation: lenses)
            let cheek = simd_normalize(SIMD3<Float>(side * 0.62, 0.12, 0.78))
            _ = add(
                sphere, blush, to: head, scale: [0.14, 0.09, 0.04], at: cheek,
                rotation: simd_quatf(from: [0, 0, 1], to: cheek))
        }
        // The bridge arches over the nose between the lenses, and the smile curves down.
        _ = add(
            arc, rims, to: head, scale: .init(repeating: 0.09),
            at: SIMD3(0, 0.55, 0.66) + facing * 0.2 + SIMD3(0, 0.02, 0),
            rotation: lenses * simd_quatf(angle: .pi, axis: [0, 0, 1]))
        _ = add(
            arc, black, to: head, scale: .init(repeating: 0.24), at: [0, 0.2, 0.99],
            rotation: simd_quatf(from: [0, 0, 1], to: simd_normalize(SIMD3<Float>(0, 0.2, 1))))
        let crumbs = Entity()
        crumbs.components.set(Self.crumbEmitter())
        root.addChild(crumbs)
        parts = Parts(
            head: head, eyes: eyes, sphere: sphere, shape: .generateSphere(radius: 1),
            crumbs: crumbs)
    }

    /// A mesh of `ring`'s triangles, or `nil` if RealityKit cannot build it.
    private static func mesh(
        _ ring: (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32])
    ) -> MeshResource? {
        var descriptor = MeshDescriptor(name: "ring")
        descriptor.positions = MeshBuffers.Positions(ring.positions)
        descriptor.normals = MeshBuffers.Normals(ring.normals)
        descriptor.primitives = .triangles(ring.indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Finds the camera's shots of the block and of the curled worm for the viewport, and
    /// places the camera `shotBlend` of the way between them.
    private func frame() {
        let height = Float(viewport.size.height)
        guard height > 0 else { return }
        // Leaves room under the top bars and over the caption and the tab bar.
        let top = 1 - 2 * (Float(viewport.insets.top) + 16) / height
        let bottom = -1 + 2 * (Float(viewport.insets.bottom) + 72) / height
        func shot(_ box: [SIMD3<Float>]) -> Shot {
            let fit = BookwormLayout.framing(
                box, pitch: Self.pitch, fieldOfView: Self.fieldOfView, aspect: aspect,
                width: 0.94, bottom: bottom, top: top)
            return Shot(target: fit.target, distance: fit.distance)
        }
        shots = (shot(blockBox), shot(curlBox.isEmpty ? blockBox : curlBox))
        placeCamera()
    }

    private func placeCamera() {
        let blend = simd_smoothstep(0, 1, shotBlend)
        let target = simd_mix(shots.block.target, shots.curl.target, .init(repeating: blend))
        let distance = shots.block.distance + (shots.curl.distance - shots.block.distance) * blend
        camera.look(
            at: target, from: target + [0, sin(Self.pitch), cos(Self.pitch)] * distance,
            relativeTo: root)
    }

    private var aspect: Float {
        viewport.size.height > 0 ? Float(viewport.size.width / viewport.size.height) : 0.5
    }

    /// The eight corners of the box from `low` to `high`.
    private static func box(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> [SIMD3<Float>] {
        (0..<8)
            .map { corner in
                SIMD3(
                    corner & 1 == 0 ? low.x : high.x, corner & 2 == 0 ? low.y : high.y,
                    corner & 4 == 0 ? low.z : high.z)
            }
    }

    /// A glossy, cartoonish skin, shared by every part of one color.
    private func skin(_ color: ColorValue) -> PhysicallyBasedMaterial {
        if let skin = skins[color] { return skin }
        let skin = BookFactory.surface(nil, tint: color.uiColor, roughness: 0.5, specular: 0.25)
        skins[color] = skin
        return skin
    }

    /// Adds a segment right behind the head. It grows in from nothing over `growDuration`,
    /// pushing the rest of the body back along the trail.
    private func addSegment(color: ColorValue, length: Float, radius: Float, book: Int? = nil) {
        guard let parts else { return }
        let entity = ModelEntity(mesh: parts.sphere, materials: [skin(color)])
        entity.components.set(
            CollisionComponent(
                shapes: [parts.shape], mode: .trigger,
                filter: CollisionFilter(group: Self.wormGroup, mask: Self.nothing)))
        entity.components.set(InputTargetComponent())
        entity.components.set(GroundingShadowComponent(castsShadow: true))
        stage.light(entity)
        worm.addChild(entity)
        if let book { names[entity.id] = book }
        segments.insert(
            Segment(entity: entity, length: length, radius: radius, growth: book == nil ? 1 : 0),
            at: 0)
    }

    /// Paper crumbs that burst from a book as the worm bites it, then fall to the table.
    private static func crumbEmitter() -> ParticleEmitterComponent {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.birthLocation = .volume
        emitter.emitterShapeSize = [0.5, 0.2, 0.5]
        emitter.emissionDirection = [0, 1, 0]
        emitter.speed = 2.2
        emitter.speedVariation = 1
        emitter.isEmitting = false
        emitter.burstCount = 40
        emitter.burstCountVariation = 10
        var crumbs = emitter.mainEmitter
        crumbs.image = paperFlake()
        crumbs.lifeSpan = 0.7
        crumbs.lifeSpanVariation = 0.2
        crumbs.size = 0.09
        crumbs.sizeVariation = 0.04
        crumbs.spreadingAngle = 1.2
        crumbs.acceleration = [0, -10, 0]
        crumbs.angularSpeed = 8
        crumbs.angularSpeedVariation = 5
        crumbs.opacityCurve = .linearFadeOut
        crumbs.isLightingEnabled = true
        crumbs.blendMode = .alpha
        emitter.mainEmitter = crumbs
        return emitter
    }

    /// A white scrap of paper, wider than it is tall, which the crumbs tint.
    private static func paperFlake() -> TextureResource? {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 1, width: 8, height: 6))
            }
        return image.cgImage.flatMap {
            try? TextureResource(image: $0, options: .init(semantic: .color))
        }
    }

    // MARK: Eating

    private func update(_ deltaTime: TimeInterval) {
        feedback.advance(by: deltaTime)
        // A late frame, such as one after a stall, slows the worm rather than skipping it on.
        let step = Float(min(deltaTime, 1.0 / 20))
        if var popped = pop {
            popped.elapsed += step
            pop = popped.elapsed < Self.popDuration ? popped : nil
            // A still worm places its body again only while the segment swells.
            switch phase {
            case .done: place(curl: 1)
            case .crawling, .eating: if !isPlaying { layoutBody() }
            case .idle, .curling: break
            }
        }
        guard isPlaying else { return }
        let pace = BookwormLayout.pace(books: meal.count)
        switch phase {
        case .idle: return
        case .done:
            clock += step
            blink()
            return
        case .crawling(let index, let target):
            crawl(toward: target, by: BookwormLayout.crawlSpeed * pace * step)
            if trail.head == target { bite(index) }
        case .eating(let index, var bite):
            bite.elapsed += step * pace
            if bite.elapsed >= BookwormLayout.biteDuration {
                swallow(index)
            } else {
                chew(meal[index].book.id, bite, step: step)
                phase = .eating(index, bite)
            }
        case .curling(var elapsed):
            elapsed += step
            place(curl: simd_smoothstep(0, 1, elapsed / Self.curlDuration))
            shotBlend = min(1, elapsed / Self.curlDuration)
            placeCamera()
            if elapsed >= Self.curlDuration {
                phase = .done
                clock = 0
                isFinished = true
            } else {
                phase = .curling(elapsed: elapsed)
            }
            return
        }
        clock += step
        for index in segments.indices where segments[index].growth < 1 {
            segments[index].growth = min(
                1, segments[index].growth + step * pace / Self.growDuration)
        }
        layoutBody()
    }

    /// Where the head stops to eat the book at `index`.
    private func biteSpot(_ index: Int) -> SIMD2<Float> {
        BookwormLayout.biteSpot(stack: meal[index].spot, from: trail.head)
    }

    /// Moves the head `step` toward `target`, turning it toward the way it goes.
    private func crawl(toward target: SIMD2<Float>, by step: Float) {
        let offset = target - trail.head
        let distance = simd_length(offset)
        guard distance > step else { return trail.move(to: target) }
        let direction = offset / distance
        let turned = heading + (direction - heading) * min(1, step * 3)
        heading = simd_length(turned) > 1e-3 ? simd_normalize(turned) : direction
        trail.move(to: trail.head + direction * step)
    }

    /// Starts eating the book at `index`: it stops moving with the physics, crumbs burst from
    /// it, and it plays a papery bite.
    private func bite(_ index: Int) {
        let course = meal[index]
        guard let book = books[course.book.id],
            let thickness = factory.parts[course.book.id]?.shape.size.z
        else { return swallow(index) }
        book.components[PhysicsBodyComponent.self]?.mode = .kinematic
        let position = book.position(relativeTo: root)
        phase = .eating(index, Bite(bottom: position.y - thickness / 2, thickness: thickness))
        if let crumbs = parts?.crumbs,
            var emitter = crumbs.components[ParticleEmitterComponent.self]
        {
            crumbs.position = mouth
            emitter.mainEmitter.color = .constant(
                .random(a: PageEdges.fresh.uiColor, b: course.color.uiColor))
            emitter.burst()
            crumbs.components.set(emitter)
        }
        feedback.impact(impulse: 0, mass: 0.3, position: position, pan: pan, minimum: 0.35)
    }

    /// Shrinks the book being eaten into the worm's mouth, and lowers its body with its top,
    /// so the books on it sink with it.
    ///
    /// The book moves by velocity rather than to a new position, as a held book in the pile
    /// does, so the books resting on it follow it down. Its model, centered on its physics
    /// box, shrinks and slides out of the unchanged box toward the mouth.
    private func chew(_ id: Int, _ bite: Bite, step: Float) {
        guard let book = books[id] else { return }
        let eaten = simd_smoothstep(0, 1, bite.elapsed / BookwormLayout.biteDuration)
        let position = book.position(relativeTo: root)
        let goal = bite.bottom + bite.thickness * (0.5 - eaten)
        let sink = (goal - position.y) / max(step, 1 / 120)
        book.components.set(PhysicsMotionComponent(linearVelocity: [0, sink, 0]))
        book.children.first?.transform = Transform(
            scale: .init(repeating: max(0.001, 1 - eaten)),
            translation: book.convert(position: mouth, from: root) * eaten)
    }

    /// The middle of the worm's mouth, on the front of its head.
    private var mouth: SIMD3<Float> {
        let radius = BookwormLayout.headRadius
        let front = trail.head + heading * radius * 0.8
        return [front.x, radius * 0.55, front.y]
    }

    /// Closes the curled worm's eyes for a moment every few seconds.
    private func blink() {
        guard sways, let eyes = parts?.eyes else { return }
        let moment = clock.truncatingRemainder(dividingBy: 3.4) - 2.6
        let open = moment > 0 && moment < 0.16 ? abs(moment / 0.08 - 1) : 1
        for eye in eyes { eye.scale = [0.3, 0.3 * max(0.08, open), 0.3] }
    }

    /// Finishes the book at `index`: it leaves the scene, the worm grows its segment and
    /// counts it, and the worm moves on to the next book, or curls up after the last.
    private func swallow(_ index: Int) {
        let course = meal[index]
        if let book = books.removeValue(forKey: course.book.id) {
            names[book.id] = nil
            book.removeFromParent()
        }
        eat(course)
        let next = index + 1
        guard next < meal.count else { return startCurl() }
        if meal[next].stack == course.stack {
            bite(next)
        } else {
            phase = .crawling(to: next, target: biteSpot(next))
        }
    }

    private func eat(_ course: Course) {
        addSegment(
            color: course.color, length: course.length, radius: BookwormLayout.bodyRadius,
            book: course.book.id)
        eatenBooks += 1
        eatenPages += course.book.pages ?? 0
    }

    // MARK: The body

    /// Puts the head at the trail's end and each segment along the trail behind it, half its
    /// own and its neighbor's lengths apart, swaying from side to side more the farther it is
    /// from the head. While eating, the head chews.
    private func layoutBody() {
        guard let head = parts?.head else { return }
        distances.removeAll(keepingCapacity: true)
        var distance = BookwormLayout.headRadius * 0.75
        var previous: Float = 0
        for segment in segments {
            let length = segment.length * segment.growth
            distance += (previous + length) / 2
            distances.append(distance)
            previous = length
        }
        trail.sample(distances, into: &samples)
        for (index, segment) in segments.enumerated() {
            let (point, forward) = samples[index]
            let along = distances[index]
            let sway = sways ? 0.1 * min(1, along) * sin(clock * 5 - along * 2.5) : 0
            let place = point + SIMD2(forward.y, -forward.x) * sway
            let radius = segment.radius * (0.4 + 0.6 * segment.growth) * swell(segment.entity)
            segment.entity.transform = Transform(
                scale: [radius, radius, max(radius, segment.length * segment.growth / 2 + 0.12)],
                rotation: Self.yaw(forward), translation: [place.x, radius, place.y])
        }
        // While eating, the head pecks at the book and swells as it chews.
        var chew: Float = 1
        var peck: Float = 0
        if case .eating = phase {
            chew += 0.05 * sin(clock * 22)
            peck = 0.1 * max(0, sin(clock * 22))
        }
        let radius = BookwormLayout.headRadius
        let place = trail.head + heading * peck
        head.transform = Transform(
            scale: .init(repeating: radius * chew), rotation: Self.yaw(heading),
            translation: [place.x, radius, place.y])
    }

    /// Starts curling the worm up in the middle of the table, from where its parts are now.
    private func startCurl() {
        for index in segments.indices { segments[index].growth = 1 }
        layoutBody()
        curlStart =
            [trail.head]
            + segments.map { SIMD2($0.entity.position.x, $0.entity.position.z) }
        curlEnd = BookwormLayout.curl(
            lengths: [BookwormLayout.headRadius * 1.5] + segments.map(\.length))
        curlTurn = Self.yaw(heading)
        // A short worm curls up no smaller on screen than a worm of about 20 books.
        let reach = curlEnd.reduce(SIMD2<Float>.zero) { pointwiseMax($0, abs($1)) }
        let half = pointwiseMax(reach + BookwormLayout.headRadius + 0.1, .init(repeating: 1.8))
        curlBox = Self.box(
            [-half.x, 0, -half.y], [half.x, BookwormLayout.headRadius * 2, half.y])
        frame()
        phase = .curling(elapsed: 0)
    }

    /// Places the worm `progress` of the way from where the curl started to curled up. Each
    /// segment points from the part behind it to the part ahead, and the head turns to face
    /// the camera.
    private func place(curl progress: Float) {
        guard let head = parts?.head, curlEnd.count == segments.count + 1 else { return }
        func at(_ index: Int) -> SIMD2<Float> {
            let index = min(index, curlEnd.count - 1)
            return curlStart[index] + (curlEnd[index] - curlStart[index]) * progress
        }
        for (index, segment) in segments.enumerated() {
            let point = at(index + 1)
            let span = at(index) - at(index + 2)
            let forward = simd_length(span) > 1e-4 ? simd_normalize(span) : SIMD2<Float>(0, 1)
            let radius = segment.radius * swell(segment.entity)
            segment.entity.transform = Transform(
                scale: [radius, radius, max(radius, segment.length / 2 + 0.12)],
                rotation: Self.yaw(forward), translation: [point.x, radius, point.y])
        }
        let radius = BookwormLayout.headRadius
        head.transform = Transform(
            scale: .init(repeating: radius),
            rotation: simd_slerp(curlTurn, Self.yaw([0, 1]), progress),
            translation: [at(0).x, radius, at(0).y])
    }

    /// How much larger than usual `entity` draws: up to a quarter larger while it pops.
    private func swell(_ entity: Entity) -> Float {
        guard let pop, pop.id == entity.id else { return 1 }
        return 1 + 0.25 * sin(.pi * pop.elapsed / Self.popDuration)
    }

    /// The turn about the vertical axis that points a part's +z along `forward`, given as
    /// (x, z).
    private static func yaw(_ forward: SIMD2<Float>) -> simd_quatf {
        simd_quatf(angle: atan2(forward.x, forward.y), axis: [0, 1, 0])
    }

    /// Where `point` shows from left to right on screen, as a stereo position from -0.8 to 0.8.
    private func pan(_ point: SIMD3<Float>) -> Float {
        let local = camera.convert(position: point, from: root)
        guard local.z < -0.01 else { return 0 }
        let slope = tan(Self.fieldOfView / 2) * aspect
        return min(1, max(-1, local.x / (-local.z * slope))) * 0.8
    }
}
