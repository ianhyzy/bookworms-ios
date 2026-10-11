import RealityKit
import SwiftUI
import UIKit

/// A book's place in the domino chain.
struct DominoSlot {
    let book: CloudBook
    /// The book's size as `BookShape` gives it for a 2:3 cover. Its height and thickness do not
    /// depend on the cover, so they match the built book's.
    let size: SIMD3<Float>
    /// The days from this book's finish to the next book's.
    let days: Int
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
/// right to left, nearer the camera, and so on. Distances run along the path from the start of
/// the first row, at (-`rowLength` / 2, 0) in x and z; rows advance toward +z, the camera.
struct DominoPath: Equatable {
    var rowLength: Float
    var radius: Float = DominoLayout.turnRadius

    /// The length of a row and the turn after it.
    var period: Float { rowLength + .pi * radius }

    /// Whether `distance` lies on a turn.
    func isTurning(at distance: Float) -> Bool {
        distance.truncatingRemainder(dividingBy: period) > rowLength
    }

    /// The point `distance` along the path, and the path's direction there as a unit vector.
    func point(at distance: Float) -> (position: SIMD2<Float>, heading: SIMD2<Float>) {
        let row = (distance / period).rounded(.down)
        let along = distance - row * period
        let direction: Float = Int(row) % 2 == 0 ? 1 : -1
        let z = row * 2 * radius
        guard along > rowLength else {
            return ([direction * (along - rowLength / 2), z], [direction, 0])
        }
        // A half circle about the point `radius` past the row's end, toward the next row.
        let angle = (along - rowLength) / radius
        return (
            [direction * (rowLength / 2 + radius * sin(angle)), z + radius * (1 - cos(angle))],
            [direction * cos(angle), sin(angle)]
        )
    }
}

/// The chain's path and where each book stands on it, centered on the table.
struct DominoPlan {
    let path: DominoPath
    let slots: [DominoSlot]
    /// Half the span of the books' middles in x and z, about the table's center.
    let extent: SIMD2<Float>
}

/// Where the dominoes stand: in finish order along a winding path, spaced by the days between
/// finishes, so a reading binge is a tight run and a slump is a gap that a falling book cannot
/// cross. Scene units are decimeters, as in the pile.
enum DominoLayout {
    /// The most books a chain stands: the most recently finished.
    static let maximumBooks = 300
    /// The days without a finish that make a slump, which the chain cannot cross.
    static let slumpDays = 30
    /// The turns' radius, half the distance between rows. It exceeds half the widest book, so
    /// books on a turn keep their inner corners apart (see `turnSpacing`).
    static let turnRadius: Float = 2
    static let shortestRow: Float = 6
    /// How deep the rows may reach, which keeps the path and the books that fall past its ends
    /// on the 90-unit table.
    static let deepest: Float = 72
    /// The space a turn keeps between the inner corners of neighboring books.
    static let clearance: Float = 0.05

    /// The gap from a book's front cover to the next book's back cover, for a book of `height`
    /// whose finish came `days` before the next book's.
    ///
    /// A toppling book pivots on its front bottom edge, so its head reaches at most `height`
    /// past that edge: its reach. Books finished within `slumpDays` of each other stand 15
    /// percent of the height apart on the same day, growing evenly to 54 percent at 29 days,
    /// so the falling book strikes the next one at least 84 percent of the way up and knocks
    /// it over. A slump leaves 1.25 times the height, a quarter of a book beyond reach, and
    /// another quarter for each doubling of its length, up to 1.75 times the height at 120
    /// days or more. The falling book lands short, and the chain stops there.
    static func gap(days: Int, height: Float) -> Float {
        let days = Float(max(0, days))
        let slump = Float(slumpDays)
        guard days >= slump else { return height * (0.15 + 0.4 * days / slump) }
        return height * min(1.75, 1.25 + 0.25 * log2(days / slump))
    }

    /// `books` in finish order, oldest first, with the whole days from each finish to the next.
    /// Books without a finish date, such as current reads, stand last, as if finished `now`.
    /// Past `maximumBooks`, only the most recent books stand. The last book's days are 0.
    static func chain(_ books: [CloudBook], now: Date) -> [(book: CloudBook, days: Int)] {
        let ordered = Array(
            books.enumerated()
                .sorted {
                    ($0.element.finishedDate ?? .distantFuture, $0.offset)
                        < ($1.element.finishedDate ?? .distantFuture, $1.offset)
                }
                .map(\.element)
                .suffix(maximumBooks))
        let dates = ordered.map { $0.finishedDate ?? now }
        return ordered.indices.map { index in
            let next = index + 1 < dates.count ? dates[index + 1] : dates[index]
            let days = (next.timeIntervalSince(dates[index]) / 86_400).rounded()
            return (ordered[index], max(0, Int(days)))
        }
    }

    /// Stands `chain` along a path whose width is about `aspect` times its depth on the table,
    /// such as the visible table's, centered on the table.
    ///
    /// Each book's middle stands half its thickness, `gap`, and half the next book's thickness
    /// from the next book's along the path. On a turn the books fan out, so they stand farther
    /// apart where their inner corners would otherwise touch (see `turnSpacing`).
    static func plan(_ chain: [(book: CloudBook, days: Int)], aspect: Float) -> DominoPlan {
        let sizes = chain.map { BookShape(of: $0.book, coverAspect: 2 / 3).size }
        let spacings = chain.indices.dropLast()
            .map { index in
                (sizes[index].z + sizes[index + 1].z) / 2
                    + gap(days: chain[index].days, height: sizes[index].y)
            }
        let path = DominoPath(rowLength: rowLength(for: spacings.reduce(0, +), aspect: aspect))
        var slots: [DominoSlot] = []
        var distance: Float = 0
        for (index, link) in chain.enumerated() {
            if index > 0 {
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
                    book: link.book, size: sizes[index], days: link.days, distance: distance,
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
    /// times its depth, and its rows reach no deeper than `deepest`.
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
    /// book's footprint across the path, at the table and at its height, and the table past
    /// the last book where it lands. Every other book falls onto the path ahead of it, which
    /// these points already cover.
    static func outline(of slots: [DominoSlot]) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(slots.count * 4 + 1)
        for slot in slots {
            let across = SIMD2(-slot.heading.y, slot.heading.x) * slot.size.x / 2
            for side in [slot.position - across, slot.position + across] {
                points.append([side.x, 0, side.y])
                points.append([side.x, slot.size.y, side.y])
            }
        }
        if let last = slots.last {
            let landing = last.position + last.heading * (last.size.y + last.size.z / 2)
            points.append([landing.x, 0, landing.y])
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
    /// The chain stopped after `fallen` books: at a slump, or wherever a book stayed standing.
    /// `days` are the days between the last fallen book's finish and the next book's.
    case stalled(fallen: Int, days: Int)
    /// Every book has fallen.
    case done
}

/// The chain's phase, kept apart from the scene so that views update only when it changes.
@MainActor @Observable
final class DominoStatus {
    fileprivate(set) var phase = DominoPhase.settingUp
}

/// The dominoes' RealityKit content: the desk and its lamp (`DeskStage`), whose pool of light
/// covers the path, and one rigid body per book (`BookFactory`), standing where `DominoLayout`
/// places it.
///
/// The chain's front is the book after the last one that tilted past about 26 degrees. Each
/// frame checks only the next three books, so the work per frame does not grow with the
/// chain, and a book that the chain skips counts as passed. The chain is stalled once no book
/// has started to fall for `stallTime`. While the chain waits for a push, a warm glow on the
/// table marks the book a push tips (`DominoLayout.pushTarget`), and pulses unless Reduce
/// Motion is on. After a push, without Reduce Motion, the camera eases after the front, and
/// once every book has fallen it eases back to the whole path. A pinch or drag stops it
/// following until the next push.
@MainActor
final class DominoScene {
    /// The scene root, which runs the physics simulation.
    let root = Entity()
    /// Haptics and sounds for collisions, which `DominoesView` starts and stops.
    let feedback = ImpactFeedback()
    let status = DominoStatus()

    /// How fast a push tips a book forward, in radians per second.
    private static let pushSpeed: Float = 2.5
    private static let stallTime: TimeInterval = 1
    /// The cosine of the tilt past which a book counts as fallen.
    private static let fallenTilt: Float = 0.9
    /// The zoom at which the camera follows the front, unless the whole path shows closer.
    private static let followZoom: Float = 1.4
    private static let coverWait = Duration.seconds(1.5)
    /// How many books are built and stood up at a time.
    private static let batchSize = 16
    /// The cosine of the tilt under which a book counts as upright, about 6 degrees: more
    /// than a book rocks when it stands up, and less than it leans against the next book.
    private static let uprightTilt: Float = 0.995
    /// The marker's collision group, which collides with nothing, so books pass through its
    /// box while taps still find it.
    private static let markerGroup = CollisionGroup(rawValue: 1 << 20)

    private let camera = PerspectiveCamera()
    private let factory = BookFactory()
    private var stage = DeskStage()
    private var poolRadius: Float?
    private let shelf = Entity()
    /// Marks the book a push tips with `glow`, and takes that book's taps with a box a little
    /// larger than the book, since a thin book is hard to hit from the overview.
    private let marker = Entity()
    private let glow: ModelEntity
    private let pulse: AnimationResource?
    /// The index of the book `marker` marks, if it shows.
    private var marked: Int?
    private var key: Key?
    private var plan: [DominoSlot] = []
    private var extent = SIMD2<Float>.zero
    private var spawned = 0
    /// The standing books and their slots, in chain order.
    private var books: [ModelEntity] = []
    private var slots: [DominoSlot] = []
    private var indices: [Entity.ID: Int] = [:]
    /// The index of the next book to fall.
    private var next = 0
    private var started = false
    /// Seconds of simulation since the books stood up, and when the front last moved.
    private var clock: TimeInterval = 0
    private var lastAdvance: TimeInterval = 0
    private var view = PileCamera()
    /// The camera that shows the whole path.
    private var overview = PileCamera()
    private var aspect: Float = 0.5
    private var follows = false
    private var reducesMotion = false
    private var cameraMove: (start: PileCamera, focus: SIMD3<Float>)?
    private var updates: EventSubscription?
    private var collisions: EventSubscription?

    private struct Key: Equatable {
        let ids: [Int]
        let generation: Int
    }

    init() {
        var simulation = PhysicsSimulationComponent()
        simulation.gravity = [0, -PileLayout.gravity, 0]
        simulation.solverIterations = .init(positionIterations: 12, velocityIterations: 2)
        root.components.set(simulation)
        camera.camera = PerspectiveCameraComponent(
            near: 0.5, far: 300, fieldOfViewInDegrees: PileCamera.fieldOfView * 180 / .pi,
            fieldOfViewOrientation: .vertical)
        camera.transform = view.transform
        root.addChild(camera)
        root.addChild(stage.root)
        root.addChild(shelf)
        glow = Self.makeGlow()
        pulse = try? AnimationResource.generate(
            with: FromToByAnimation<Float>(
                from: 0.5, to: 1, duration: 0.9, timing: .easeInOut, bindTarget: .opacity,
                repeatMode: .autoReverse))
        marker.addChild(glow)
        marker.components.set(InputTargetComponent())
        marker.isEnabled = false
        root.addChild(marker)
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

    /// Hides the dust, holds the marker's glow steady, and stops the camera from following the
    /// chain while `reduces`.
    func setReduceMotion(_ reduces: Bool) {
        reducesMotion = reduces
        stage.setDust(!reduces)
        if reduces { follows = false }
        if marker.isEnabled { startGlow() }
    }

    private var isReady: Bool { !plan.isEmpty && spawned == plan.count }

    // MARK: Setting up

    /// Stands `books` along a new path, or continues standing them up after an earlier call
    /// for the same chain and generation, such as one interrupted by pushed details.
    ///
    /// The chain is `DominoLayout.chain(_:now:)`, so the shelf's sort order does not matter. A
    /// new chain or generation removes every book, frames the whole path between the bars of
    /// `viewport`, and lays the lamp's pool over it. Books stand up `batchSize` at a time, each
    /// batch waiting at most `coverWait` for its covers. Returns when every book stands or the
    /// task is cancelled.
    func setUp(_ books: [CloudBook], generation: Int, viewport: PileViewport, model: AppModel)
        async
    {
        let chain = DominoLayout.chain(books, now: .now)
        let key = Key(ids: chain.map { $0.book.id }, generation: generation)
        if key != self.key {
            let size = viewport.size
            let insets = viewport.insets
            let safe = CGSize(
                width: size.width - insets.leading - insets.trailing,
                height: size.height - insets.top - insets.bottom)
            guard safe.width > 0, safe.height > 0 else { return }
            reset(keeping: Set(key.ids))
            // The table seen at the camera's pitch is deeper than the screen is tall.
            let plan = DominoLayout.plan(
                chain, aspect: Float(safe.width / safe.height) * sin(PileCamera.pitch))
            self.plan = plan.slots
            extent = plan.extent
            light(radius: max(6, simd_length(plan.extent) + 3))
            frame(viewport)
            self.key = key
        }
        while spawned < plan.count {
            let end = min(spawned + Self.batchSize, plan.count)
            let batch = plan[spawned..<end]
            await factory.prepare(
                batch.map(\.book),
                prefetching: plan[end..<min(end + Self.batchSize, plan.count)].map(\.book),
                coverWait: Self.coverWait, model: model)
            guard !Task.isCancelled, self.key == key else { return }
            for slot in batch { spawn(slot) }
            spawned = end
        }
        #if DEBUG
            await runDebugPushes()
        #endif
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
        indices = [:]
        spawned = 0
        next = 0
        started = false
        follows = false
        clock = 0
        lastAdvance = 0
        cameraMove = nil
        mark(nil)
        factory.release(keeping: ids)
        status.phase = .settingUp
    }

    /// Lays the lamp's pool over a circle of `radius` about the table's center, replacing the
    /// stage when the radius changes, since a stage builds its lamp once.
    private func light(radius: Float) {
        guard poolRadius != radius else { return }
        if poolRadius != nil {
            stage.root.removeFromParent()
            stage = DeskStage()
            root.addChild(stage.root)
        }
        poolRadius = radius
        stage.build(pool: .zero, radius: radius)
        stage.setDust(!reducesMotion)
    }

    /// Frames every book of the chain, standing or fallen (`DominoLayout.outline`), between
    /// the bars and above the hint at the bottom of `viewport`.
    private func frame(_ viewport: PileViewport) {
        let size = viewport.size
        let insets = viewport.insets
        aspect = Float(size.width / size.height)
        let rect = CGRect(
            x: insets.leading + 16, y: insets.top + 8,
            width: size.width - insets.leading - insets.trailing - 32,
            height: size.height - insets.top - insets.bottom - 88)
        overview = PileCamera()
            .framing(DominoLayout.outline(of: plan), in: rect, of: size, zoomRange: 0.2...2.5)
        look(through: overview)
    }

    private func spawn(_ slot: DominoSlot) {
        guard
            let book = factory.makeBook(slot.book.id, mode: .dynamic, lighting: stage.lighting)
        else { return }
        // A hair above the table, so it settles onto it rather than starting inside it.
        book.transform = Transform(
            rotation: DominoLayout.standing(heading: slot.heading),
            translation: [slot.position.x, slot.size.y / 2 + 0.002, slot.position.y])
        shelf.addChild(book)
        indices[book.id] = books.count
        books.append(book)
        slots.append(slot)
    }

    /// Puts a cover that arrived after its book was built onto the standing book.
    private func retexture(_ id: Int, cover: any RealityKit.Material) {
        for (book, slot) in zip(books, slots) where slot.book.id == id {
            book.children.first?.components[ModelComponent.self]?
                .materials[Int(BookSlot.cover)] = cover
        }
    }

    // MARK: Interaction

    /// Pushes the chain on when `entity` is the marker, the next book to fall, or a book
    /// between it and the marked book, and returns `nil`. Returns any other book's ID, for its
    /// details, and `nil` for the table. A push does nothing until every book stands.
    func tap(_ entity: Entity) -> Int? {
        let index = entity == marker ? marked : indices[entity.id]
        guard let index else { return nil }
        guard index >= next, index <= target else { return slots[index].book.id }
        pushNext()
        return nil
    }

    /// The ID of the book an entity belongs to, including the marked book for the marker, or
    /// `nil` for the table.
    func bookID(for entity: Entity) -> Int? {
        (entity == marker ? marked : indices[entity.id]).map { slots[$0].book.id }
    }

    /// The book a push tips (see `DominoLayout.pushTarget`).
    private var target: Int {
        DominoLayout.pushTarget(next: next, count: books.count) {
            books[$0].transform.rotation.act([0, 1, 0]).y > Self.uprightTilt
        }
    }

    /// Tips the book a push tips (see `target`) forward along the path, with a light tap, once
    /// every book stands.
    func pushNext() {
        guard isReady, next < books.count else { return }
        let book = books[target]
        let slot = slots[target]
        let forward = SIMD3(slot.heading.x, 0, slot.heading.y)
        let spin = simd_cross([0, 1, 0], forward) * Self.pushSpeed
        // About the front bottom edge, so the book tips over instead of sliding back.
        let arm = SIMD3(0, slot.size.y / 2, 0) - forward * slot.size.z / 2
        book.components.set(
            PhysicsMotionComponent(linearVelocity: simd_cross(spin, arm), angularVelocity: spin))
        started = true
        lastAdvance = clock
        follows = !reducesMotion
        feedback.impact(
            impulse: 0, mass: book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0,
            position: book.position(relativeTo: root), pan: pan, minimum: 0.2)
    }

    /// Zooms toward the point under `focus` by `magnification`, or slides the camera across
    /// the table with a one-finger `translation`, keeping the path in view.
    func moveCamera(translation: CGSize, magnification: CGFloat, focus: CGPoint?, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if cameraMove == nil {
            follows = false
            let point = focus ?? CGPoint(x: size.width / 2, y: size.height / 2)
            let ndc = SIMD2(
                Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
            let ray = view.ray(ndc: ndc, aspect: aspect)
            cameraMove = (view, PileCamera.intersect(ray, height: 0) ?? view.target)
        }
        guard let move = cameraMove else { return }
        var camera = move.start
        camera.zoom = min(
            max(move.start.zoom * Float(magnification), min(overview.zoom, 1)),
            PileCamera.zoomRange.upperBound)
        // Keeps the focus point in place while zooming.
        var target = move.focus + (move.start.target - move.focus) * move.start.zoom / camera.zoom
        // Table units per point at the target, where the view is 2 normalized units tall.
        let scale =
            PileCamera.distance / camera.zoom * tan(PileCamera.fieldOfView / 2) * 2
            / Float(size.height)
        target -=
            SIMD3(Float(translation.width), 0, Float(translation.height) / sin(PileCamera.pitch))
            * scale
        let bound = extent + 2
        camera.target = [
            min(max(target.x, -bound.x), bound.x), 0, min(max(target.z, -bound.y), bound.y),
        ]
        look(through: camera)
    }

    func endCameraMove() { cameraMove = nil }

    private func look(through camera: PileCamera) {
        view = camera
        self.camera.transform = camera.transform
    }

    /// Where `point` shows from left to right on screen, as a stereo position from -0.8 to 0.8.
    private func pan(_ point: SIMD3<Float>) -> Float {
        min(1, max(-1, view.project(point, aspect: aspect).x)) * 0.8
    }

    // MARK: Following the chain

    private func update(_ deltaTime: TimeInterval) {
        feedback.advance(by: deltaTime)
        guard isReady else { return }
        clock += deltaTime
        for index in next..<min(next + 3, books.count)
        where books[index].transform.rotation.act([0, 1, 0]).y < Self.fallenTilt {
            next = index + 1
            lastAdvance = clock
        }
        let phase = phase
        if status.phase != phase { status.phase = phase }
        switch phase {
        case .standing, .stalled: mark(target)
        default: mark(nil)
        }
        if follows, cameraMove == nil { steer(Float(deltaTime)) }
    }

    private var phase: DominoPhase {
        guard isReady else { return .settingUp }
        guard started else { return .standing }
        let settled = clock - lastAdvance > Self.stallTime
        if next == books.count { return settled ? .done : .running }
        guard settled else { return .running }
        return .stalled(fallen: next, days: next > 0 ? slots[next - 1].days : 0)
    }

    // MARK: Marking the next book

    /// Moves the marker to the book at `index`, or hides it for `nil`.
    private func mark(_ index: Int?) {
        guard index != marked else { return }
        marked = index
        guard let index else {
            marker.isEnabled = false
            glow.stopAllAnimations()
            return
        }
        let slot = slots[index]
        // The plane's x runs across the path and its z along it.
        marker.transform = Transform(
            rotation: simd_quatf(angle: atan2(slot.heading.x, slot.heading.y), axis: [0, 1, 0]),
            translation: [slot.position.x, 0, slot.position.y])
        // A hair above the table, so the glow does not flicker against it.
        glow.transform = Transform(
            scale: [slot.size.x + 1.4, 1, slot.size.z + 1.2], translation: [0, 0.01, 0])
        // Past the book's covers by less than the closest gap, 15 percent of a book's height,
        // so the box does not cover a neighbor's taps on a row.
        let box = slot.size + [0.4, 0.3, 0.3]
        marker.components.set(
            CollisionComponent(
                shapes: [.generateBox(size: box).offsetBy(translation: [0, box.y / 2, 0])],
                mode: .trigger, filter: CollisionFilter(group: Self.markerGroup, mask: [])))
        if !marker.isEnabled {
            marker.isEnabled = true
            startGlow()
        }
    }

    /// Pulses the marker's glow, or holds it steady with Reduce Motion on.
    private func startGlow() {
        glow.stopAllAnimations()
        glow.components.set(OpacityComponent(opacity: 0.9))
        guard !reducesMotion, let pulse else { return }
        glow.playAnimation(pulse)
    }

    /// A flat, warm glow that fades from its middle to its edges, on a plane one unit square.
    private static func makeGlow() -> ModelEntity {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                // A bright middle that falls off quickly, then a faint halo.
                let colors = [1, 0.5, 0].map { UIColor.white.withAlphaComponent($0).cgColor }
                guard
                    let gradient = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                        locations: [0, 0.4, 1])
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
                tint: UIColor(red: 1, green: 0.8, blue: 0.42, alpha: 1), texture: .init(texture))
            material.blending = .transparent(opacity: .init(scale: 1, texture: .init(texture)))
        }
        return ModelEntity(mesh: .generatePlane(width: 1, depth: 1), materials: [material])
    }

    /// Eases the camera toward the next book to fall, closer in, or back to the whole path
    /// once every book has fallen. It snaps the last hundredth of a unit, so a camera that has
    /// arrived stops moving.
    private func steer(_ deltaTime: Float) {
        var goal = overview
        if status.phase != .done, !slots.isEmpty {
            let front = slots[min(next, slots.count - 1)].position
            goal = PileCamera(
                target: [front.x, 0, front.y], zoom: max(overview.zoom, Self.followZoom))
        }
        guard goal != view else { return }
        var camera = view.mixed(with: goal, 1 - exp(-deltaTime * 2.5))
        if simd_distance(camera.target, goal.target) < 0.01, abs(camera.zoom - goal.zoom) < 0.001 {
            camera = goal
        }
        look(through: camera)
    }

    #if DEBUG
        /// Simulator hook: `-BookwormsDominoPush <seconds>` pushes the next book whenever the
        /// chain has stood or stalled that long, until every book has fallen.
        private func runDebugPushes() async {
            guard
                let delay = UserDefaults.standard.string(forKey: "BookwormsDominoPush")
                    .flatMap(Double.init)
            else { return }
            while !Task.isCancelled, status.phase != .done {
                try? await Task.sleep(for: .seconds(delay))
                switch status.phase {
                case .standing, .stalled: pushNext()
                default: break
                }
            }
        }
    #endif
}
