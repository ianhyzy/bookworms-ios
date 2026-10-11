import RealityKit
import SwiftUI
import UIKit

/// The Bookworm's RealityKit content: the desk and its lamp (`DeskStage`), a block of books
/// (`BookFactory`) laid out by `BookwormLayout`, and a cartoon worm that eats through them.
///
/// The worm is the app icon's worm in 3D: one pink, from its head to its short tail, with a
/// body that gains one segment per book, as long as `BookwormLayout.segmentLength` gives for
/// its pages, and a darker pink band in the crease behind each book's segment. Its face has
/// big cream eyes ringed in plum, black pupils that look down, and a plum smile; a shut eye
/// is a plum curve like the smile. Every round part is the same unit sphere mesh, scaled; all
/// bands share one ring mesh, both eye rings another, and the smile and shut eyes a third; and
/// parts of one color share a material. The body follows the head's `WormTrail` and sways from
/// side to side behind it. The worm has no physics: it passes through books, and only books
/// collide.
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

    /// A book in eating order, with its place in the block and the length of its segment.
    private struct Course {
        let book: CloudBook
        let stack: Int
        /// The middle of its stack on the table, as (x, z).
        let spot: SIMD2<Float>
        /// The spine's color, which tints the crumbs of its bite.
        let color: ColorValue
        let length: Float
    }

    private struct Segment {
        let entity: ModelEntity
        /// The band in the crease between this segment and the one behind it; the tail has
        /// none.
        let band: ModelEntity?
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
        /// Each open eye, with its pupil and ring, and the closed eye that replaces it in a
        /// blink.
        let eyes: [(open: Entity, shut: Entity)]
        let sphere: MeshResource
        let shape: ShapeResource
        /// The ring mesh of the bands.
        let band: MeshResource?
        let skin: PhysicallyBasedMaterial
        let bands: PhysicallyBasedMaterial
        let crumbs: Entity
    }

    @ObservationIgnored private var parts: Parts?
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
    /// Buffers that `layoutBody` and `place(curl:)` reuse every frame.
    @ObservationIgnored private var distances: [Float] = []
    @ObservationIgnored private var samples: [(point: SIMD2<Float>, forward: SIMD2<Float>)] = []
    /// Where the head and then each segment lie on the table, as (x, z).
    @ObservationIgnored private var points: [SIMD2<Float>] = []
    @ObservationIgnored private var updates: EventSubscription?
    @ObservationIgnored private var collisions: EventSubscription?

    private static let fieldOfView: Float = 38 * .pi / 180
    private static let pitch: Float = 50 * .pi / 180
    private static let curlDuration: Float = 1.6
    private static let growDuration: Float = 0.35
    /// Tints that show close to the app icon's worm colors under the desk's warm lamp: its
    /// pink skin (#EF9CAE) where the lamp lights it, the darker pink lines across its body
    /// (#9E687E), the plum of its eye rings and smile (#50344D), and the cream of its eyes
    /// (#F7EFDB). The lamp and the room's light keep less green and blue than red, so each tint
    /// raises them. They were matched by eye and by sampling the rendered worm in the
    /// Simulator.
    private static let pink = ColorValue(red: 0xBE, green: 0x92, blue: 0xDC)
    private static let bandPink = ColorValue(red: 0x7A, green: 0x67, blue: 0xA8)
    private static let plum = ColorValue(red: 0x40, green: 0x3D, blue: 0x72)
    private static let cream = ColorValue(red: 0xBA, green: 0xDA, blue: 0xFF)
    private static let glow = ColorValue(red: 0xF7, green: 0xEF, blue: 0xDB)
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
        // Keeps only this meal's textures, so browsing time frames holds one meal's worth.
        factory.release(keeping: finished ? [] : Set(meal.map(\.id)))
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
        addSegment(length: 0.3, radius: BookwormLayout.bodyRadius * 0.7)
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
        for segment in segments {
            segment.entity.removeFromParent()
            segment.band?.removeFromParent()
        }
        segments = []
        books = [:]
        names = [:]
        meal = []
        phase = .idle
        clock = 0
        // Opens eyes that a blink left shut.
        setEyes(shut: false)
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
        // A soft satin skin: a fairly rough base under a thin, blurry clear coat.
        var skin = BookFactory.surface(
            nil, tint: Self.pink.uiColor, roughness: 0.55, specular: 0.3)
        skin.clearcoat = .init(floatLiteral: 0.25)
        skin.clearcoatRoughness = .init(floatLiteral: 0.4)
        let bands = BookFactory.surface(
            nil, tint: Self.bandPink.uiColor, roughness: 0.55, specular: 0.3)
        let head = ModelEntity(mesh: sphere, materials: [skin])
        head.components.set(GroundingShadowComponent(castsShadow: true))
        stage.light(head)
        worm.addChild(head)
        // The face lies in the head's unit-sphere space, with the front toward +z, as the camera
        // sees the curled worm, which faces it from `pitch` above: big eyes high on the face,
        // with pupils low and toward the middle, as the icon's worms look down at their book,
        // and a smile under them. `spot` is the point on the head that shows at (x, y) on its
        // disk, from -1 to 1 each way. `facing` turns a part's +z out along `direction` and its
        // +y as near the camera's up as it can, so an eye's blink closes it from top to bottom
        // on screen.
        let toward = SIMD3<Float>(0, sin(Self.pitch), cos(Self.pitch))
        let up = SIMD3<Float>(0, cos(Self.pitch), -sin(Self.pitch))
        func spot(_ x: Float, _ y: Float) -> SIMD3<Float> {
            SIMD3(x, 0, 0) + up * y + toward * max(0, 1 - x * x - y * y).squareRoot()
        }
        func facing(_ direction: SIMD3<Float>) -> simd_quatf {
            let z = simd_normalize(direction)
            let x = simd_normalize(simd_cross(up, z))
            return simd_quatf(simd_float3x3(columns: (x, simd_cross(z, x), z)))
        }
        // A faint glow of the icon's cream keeps the eyes from looking peach under the lamp,
        // whose light has too little blue for a tint alone.
        var cream = BookFactory.surface(
            nil, tint: Self.cream.uiColor, roughness: 0.3, specular: 0.4)
        cream.emissiveColor = .init(color: Self.glow.uiColor)
        cream.emissiveIntensity = 0.25
        let black = BookFactory.surface(nil, tint: .black, roughness: 0.2, specular: 0.5)
        let plum = BookFactory.surface(nil, tint: Self.plum.uiColor, roughness: 0.4, specular: 0.3)
        let band = Self.mesh(BookwormLayout.ring(arc: 2 * .pi, tube: 0.08))
        let ring = Self.mesh(BookwormLayout.ring(arc: 2 * .pi, tube: 0.16))
        let arc = Self.mesh(BookwormLayout.ring(arc: .pi * 0.6, tube: 0.2))
        var eyes: [(open: Entity, shut: Entity)] = []
        func add(
            _ mesh: MeshResource, _ material: PhysicallyBasedMaterial, to parent: Entity,
            scale: SIMD3<Float>, at position: SIMD3<Float>,
            rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        ) -> ModelEntity {
            let part = ModelEntity(mesh: mesh, materials: [material])
            part.transform = Transform(scale: scale, rotation: rotation, translation: position)
            stage.light(part)
            parent.addChild(part)
            return part
        }
        for side: Float in [-1, 1] {
            // Each eye is an oval, taller than wide, flattened against the face. It sinks into
            // the head as deep as its ring needs to lie on the skin all the way around, as near
            // as an oval ring can.
            let center = spot(side * 0.4, 0.2)
            let eye = add(
                sphere, cream, to: head, scale: [0.34, 0.4, 0.16], at: center * 0.93,
                rotation: facing(center))
            _ = add(
                sphere, black, to: eye, scale: .init(repeating: 0.42),
                at: simd_normalize(SIMD3<Float>(side * -0.28, -0.55, 0.8)) * 0.72)
            if let ring { _ = add(ring, plum, to: eye, scale: .one, at: .zero) }
            // A shut eye is a plum curve like the smile, across the middle of the open eye.
            let shut = Entity()
            shut.isEnabled = false
            head.addChild(shut)
            if let arc {
                let lid = spot(side * 0.4, 0.5)
                _ = add(
                    arc, plum, to: shut, scale: .init(repeating: 0.38), at: lid * 0.925,
                    rotation: facing(lid))
            }
            eyes.append((eye, shut))
        }
        // The smile is the bottom of a small circle on the head, so both its ends meet the skin,
        // and it sits low enough that its ends clear the eye rings by more than a ring's width.
        if let arc {
            let middle = spot(0, -0.16)
            _ = add(
                arc, plum, to: head, scale: .init(repeating: 0.26), at: middle * 0.96,
                rotation: facing(middle))
        }
        let crumbs = Entity()
        crumbs.components.set(Self.crumbEmitter())
        root.addChild(crumbs)
        parts = Parts(
            head: head, eyes: eyes, sphere: sphere, shape: .generateSphere(radius: 1), band: band,
            skin: skin, bands: bands, crumbs: crumbs)
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

    /// Adds a segment right behind the head, with a band behind it if it stands for a book. It
    /// grows in from nothing over `growDuration`, pushing the rest of the body back along the
    /// trail.
    private func addSegment(length: Float, radius: Float, book: Int? = nil) {
        guard let parts else { return }
        let entity = ModelEntity(mesh: parts.sphere, materials: [parts.skin])
        entity.components.set(
            CollisionComponent(
                shapes: [parts.shape], mode: .trigger,
                filter: CollisionFilter(group: Self.wormGroup, mask: Self.nothing)))
        entity.components.set(InputTargetComponent())
        entity.components.set(GroundingShadowComponent(castsShadow: true))
        stage.light(entity)
        worm.addChild(entity)
        var band: ModelEntity?
        if let book {
            names[entity.id] = book
            if let mesh = parts.band {
                let ring = ModelEntity(mesh: mesh, materials: [parts.bands])
                stage.light(ring)
                worm.addChild(ring)
                band = ring
            }
        }
        segments.insert(
            Segment(
                entity: entity, band: band, length: length, radius: radius,
                growth: book == nil ? 1 : 0),
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

    /// Where the head stops to eat the book at `index`, outside the footprint of the largest
    /// book in its stack. A book lying flat has its height along x and its width along z.
    private func biteSpot(_ index: Int) -> SIMD2<Float> {
        var half = SIMD2<Float>.zero
        for course in meal where course.stack == meal[index].stack {
            guard let size = factory.parts[course.book.id]?.shape.size else { continue }
            half = pointwiseMax(half, SIMD2(size.y, size.x) / 2)
        }
        return BookwormLayout.biteSpot(
            stack: meal[index].spot, from: trail.head,
            halfSize: half == .zero ? BookwormLayout.stackHalfSize : half)
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
        guard sways else { return }
        let moment = clock.truncatingRemainder(dividingBy: 3.4) - 2.6
        setEyes(shut: moment > 0 && moment < 0.12)
    }

    private func setEyes(shut: Bool) {
        for eye in parts?.eyes ?? [] {
            eye.open.isEnabled = !shut
            eye.shut.isEnabled = shut
        }
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
            length: course.length, radius: BookwormLayout.bodyRadius, book: course.book.id)
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
        points.removeAll(keepingCapacity: true)
        points.append(trail.head)
        for ((point, forward), along) in zip(samples, distances) {
            let sway = sways ? 0.1 * min(1, along) * sin(clock * 5 - along * 2.5) : 0
            points.append(point + SIMD2(forward.y, -forward.x) * sway)
        }
        placeSegments()
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

    /// Puts each segment at `points[index + 1]`, behind the head at `points[0]`, pointing from
    /// the point behind it to the one ahead, so neighbors turn together where the body bends,
    /// and then the bands.
    ///
    /// Neighbors overlap in proportion to their lengths, so the body narrows only to 85 to 95
    /// percent of its radius at each crease, and the bands, more than the body's outline, mark
    /// the segments.
    private func placeSegments() {
        for (index, segment) in segments.enumerated() {
            let point = points[index + 1]
            let span = points[index] - points[min(index + 2, points.count - 1)]
            let forward = simd_length(span) > 1e-4 ? simd_normalize(span) : SIMD2<Float>(0, 1)
            // A segment growing in keeps its shape as it grows from 0.4 of its size.
            let size = 0.4 + 0.6 * segment.growth
            let radius = segment.radius * size * swell(segment.entity)
            segment.entity.transform = Transform(
                scale: [radius, radius, max(radius, (0.8 * segment.length + 0.1) * size)],
                rotation: Self.yaw(forward), translation: [point.x, radius, point.y])
        }
        placeBands()
    }

    /// Puts each band in the crease between its segment and the one behind it
    /// (`BookwormLayout.band`), square to the line between their centers. A segment that has
    /// just started to grow in has its band inside the one behind. Along the body, the ring
    /// scales by the band's mean radius, which sets its tube's thickness there.
    private func placeBands() {
        func part(_ entity: Entity) -> BookwormLayout.Ellipsoid {
            let transform = entity.transform
            return BookwormLayout.Ellipsoid(
                center: transform.translation, axis: transform.rotation.act([0, 0, 1]),
                radius: transform.scale.x, half: transform.scale.z)
        }
        for (front, back) in zip(segments, segments.dropFirst()) {
            guard let band = front.band else { continue }
            let crease = BookwormLayout.band(front: part(front.entity), back: part(back.entity))
            let size = pointwiseMax(crease.size, .init(repeating: 0.001))
            band.transform = Transform(
                scale: [size.x, size.y, (size.x + size.y) / 2], rotation: crease.rotation,
                translation: crease.center)
        }
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

    /// Places the worm `progress` of the way from where the curl started to curled up, with
    /// the head turning to face the camera.
    private func place(curl progress: Float) {
        guard let head = parts?.head, curlEnd.count == segments.count + 1 else { return }
        points.removeAll(keepingCapacity: true)
        for (start, end) in zip(curlStart, curlEnd) {
            points.append(start + (end - start) * progress)
        }
        placeSegments()
        let radius = BookwormLayout.headRadius
        head.transform = Transform(
            scale: .init(repeating: radius),
            rotation: simd_slerp(curlTurn, Self.yaw([0, 1]), progress),
            translation: [points[0].x, radius, points[0].y])
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
