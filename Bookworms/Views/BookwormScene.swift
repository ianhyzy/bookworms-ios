import RealityKit
import SwiftUI
import UIKit

/// The Bookworm's RealityKit content: the desk and its lamp (`DeskStage`), a block of books
/// (`BookFactory`) laid out by `BookwormLayout`, and a cartoon worm that eats through them.
///
/// The worm is a green head with eyes, a short green tail, and a body that gains one segment
/// per book, in the book's spine color, as long as `BookwormLayout.segmentLength` gives for its
/// pages. Every part is the same unit sphere mesh, scaled, and segments of one color share a
/// material. The body follows the head's `WormTrail` and sways from side to side behind it.
/// The worm has no physics: it passes through books, and only books collide.
///
/// The head crawls to each stack in turn and eats it from the bottom up. A book being eaten
/// turns kinematic and shrinks onto the table in a burst of paper crumbs while the books on it
/// sink with its top, then leaves the scene, and the books above settle onto the table or the
/// books below. After the last book, the worm curls up in the middle of the table, facing the
/// camera. The caption reads `eatenBooks`, `eatenPages`, and `isFinished`.
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
    @ObservationIgnored private var aspect: Float = 0.5
    /// The radius around the table's middle that the camera keeps in view.
    @ObservationIgnored private var reach: Float = 5
    /// Counts `start` and `release` calls, so a start that an earlier call began stops.
    @ObservationIgnored private var run = 0
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
    /// Segments collide with nothing but stay in their own group, which tap hit tests need.
    private static let wormGroup = CollisionGroup(rawValue: 1 << 2)

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

    /// Frames the table for a view of width-to-height `aspect`.
    func setAspect(_ aspect: Float) {
        guard aspect > 0, aspect != self.aspect else { return }
        self.aspect = aspect
        frame()
    }

    /// The book that a tapped book or segment stands for, if any.
    func bookID(for entity: Entity) -> Int? { names[entity.id] }

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
        let corner = bricks.reduce(SIMD2<Float>.zero) { corner, brick in
            pointwiseMax(corner, abs(SIMD2(brick.center.x, brick.center.z)))
        }
        // Room around the block for the worm's way in, which starts 3.2 units in front of the
        // first stack's middle.
        reach = simd_length(corner + BookwormLayout.stackPitch / 2) + 2.5
        frame()
        addSegment(color: Self.green, length: 0.3, radius: BookwormLayout.bodyRadius * 0.7)
        sways = !finished
        if finished {
            for course in self.meal { eat(course) }
            worm.isEnabled = true
            startCurl()
            place(curl: 1)
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
        // Eyes on the head's front (+z), in the head's unit-sphere space.
        let white = BookFactory.surface(nil, tint: .white, roughness: 0.3, specular: 0.4)
        let black = BookFactory.surface(nil, tint: .black, roughness: 0.15, specular: 0.6)
        for side: Float in [-1, 1] {
            let eye = ModelEntity(mesh: sphere, materials: [white])
            eye.transform = Transform(
                scale: .init(repeating: 0.32), translation: [side * 0.4, 0.42, 0.7])
            let pupil = ModelEntity(mesh: sphere, materials: [black])
            pupil.transform = Transform(
                scale: .init(repeating: 0.45), translation: [0, 0.05, 0.75])
            eye.addChild(pupil)
            head.addChild(eye)
            stage.light(eye)
            stage.light(pupil)
        }
        worm.addChild(head)
        let crumbs = Entity()
        crumbs.components.set(Self.crumbEmitter())
        root.addChild(crumbs)
        parts = Parts(
            head: head, sphere: sphere, shape: .generateSphere(radius: 1), crumbs: crumbs)
    }

    /// Looks down on the table's middle from 50 degrees up, from as far away as keeps a circle
    /// of `reach` around it in view.
    private func frame() {
        let vertical = Self.fieldOfView / 2
        let horizontal = atan(tan(vertical) * aspect)
        let distance = reach / sin(min(vertical, horizontal))
        camera.look(
            at: .zero, from: [0, sin(Self.pitch), cos(Self.pitch)] * distance, relativeTo: root)
    }

    /// A glossy, cartoonish skin, shared by every part of one color.
    private func skin(_ color: ColorValue) -> PhysicallyBasedMaterial {
        if let skin = skins[color] { return skin }
        let skin = BookFactory.surface(nil, tint: color.uiColor, roughness: 0.4, specular: 0.35)
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
                filter: CollisionFilter(group: Self.wormGroup, mask: [])))
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
        emitter.emitterShapeSize = [1.4, 0.2, 1]
        emitter.emissionDirection = [0, 1, 0]
        emitter.speed = 1.8
        emitter.speedVariation = 0.9
        emitter.isEmitting = false
        emitter.burstCount = 36
        emitter.burstCountVariation = 8
        var crumbs = emitter.mainEmitter
        crumbs.lifeSpan = 0.9
        crumbs.lifeSpanVariation = 0.2
        crumbs.size = 0.05
        crumbs.sizeVariation = 0.02
        crumbs.spreadingAngle = 1.1
        crumbs.acceleration = [0, -14, 0]
        crumbs.angularSpeed = 6
        crumbs.angularSpeedVariation = 4
        crumbs.opacityCurve = .linearFadeOut
        crumbs.isLightingEnabled = true
        crumbs.blendMode = .alpha
        emitter.mainEmitter = crumbs
        return emitter
    }

    // MARK: Eating

    private func update(_ deltaTime: TimeInterval) {
        feedback.advance(by: deltaTime)
        guard isPlaying else { return }
        // A late frame, such as one after a stall, slows the worm rather than skipping it on.
        let step = Float(min(deltaTime, 1.0 / 20))
        let pace = BookwormLayout.pace(books: meal.count)
        switch phase {
        case .idle, .done: return
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
            if elapsed >= Self.curlDuration {
                phase = .done
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

    /// Where the head stops to eat the book at `index`: `biteReach` short of its stack's
    /// middle, on the side the head comes from, or where it is when it is already there.
    private func biteSpot(_ index: Int) -> SIMD2<Float> {
        let offset = meal[index].spot - trail.head
        let distance = simd_length(offset)
        guard distance > BookwormLayout.biteReach + 0.1 else { return trail.head }
        return meal[index].spot - offset / distance * BookwormLayout.biteReach
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
            crumbs.position = position
            emitter.mainEmitter.color = .constant(
                .random(a: PageEdges.fresh.uiColor, b: course.color.uiColor))
            emitter.burst()
            crumbs.components.set(emitter)
        }
        feedback.impact(impulse: 0, mass: 0.3, position: position, pan: pan, minimum: 0.35)
    }

    /// Shrinks the book being eaten onto the table, and lowers its body with its top, so the
    /// books on it sink with it.
    ///
    /// The book moves by velocity rather than to a new position, as a held book in the pile
    /// does, so the books resting on it follow it down. Its model shrinks toward the table
    /// within its unchanged physics box: the book lies flat, so the model's z axis points up.
    private func chew(_ id: Int, _ bite: Bite, step: Float) {
        guard let book = books[id] else { return }
        let size = 1 - simd_smoothstep(0, 1, bite.elapsed / BookwormLayout.biteDuration)
        let position = book.position(relativeTo: root)
        let goal = bite.bottom + bite.thickness * (size - 0.5)
        let sink = (goal - position.y) / max(step, 1 / 120)
        book.components.set(PhysicsMotionComponent(linearVelocity: [0, sink, 0]))
        book.children.first?.transform = Transform(
            scale: .init(repeating: max(0.001, size)),
            translation: [0, 0, bite.bottom + bite.thickness * size / 2 - position.y])
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
            let radius = segment.radius * (0.4 + 0.6 * segment.growth)
            segment.entity.transform = Transform(
                scale: [radius, radius, max(radius, segment.length * segment.growth / 2 + 0.12)],
                rotation: Self.yaw(forward), translation: [place.x, radius, place.y])
        }
        var chew: Float = 1
        if case .eating = phase { chew += 0.07 * sin(clock * 22) }
        let radius = BookwormLayout.headRadius
        head.transform = Transform(
            scale: .init(repeating: radius * chew), rotation: Self.yaw(heading),
            translation: [trail.head.x, radius, trail.head.y])
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
            let radius = segment.radius
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
