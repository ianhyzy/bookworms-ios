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

    /// Stands `chain` along a path whose width is about `aspect` times its depth on the table,
    /// such as the visible table's, centered on the table.
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
        let path = DominoPath(rowLength: rowLength(for: spacings.reduce(0, +), aspect: aspect))
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
/// The chain's front is the book after the last one that tilted past about 26 degrees. Each
/// frame checks only the next three books, so the work per frame does not grow with the
/// chain, and a book that the chain skips counts as passed. A book that falls before the first
/// push starts the chain as a push does. The chain is stalled once no book has started to
/// fall for `stallTime`. While the chain waits for a push, a warm glow on the table marks the
/// book a push tips (`DominoLayout.pushTarget`), and pulses unless Reduce Motion is on. After
/// a push, without Reduce Motion, the camera eases after the front, and once every book has
/// fallen it eases back to the whole path. A pinch or drag stops it following until the next
/// push.
///
/// Once the chain has started, a cobweb tears when either of its books tilts past `tearTilt`,
/// as the near book's back cover starts to sweep into it. Like the front, each frame checks
/// only the webs near the front.
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
    /// The cosine of the tilt past which a book tears its cobwebs, about 3 degrees, as soon as
    /// its back cover starts to sweep into the web.
    private static let tearTilt: Float = 0.9986

    private let camera = PerspectiveCamera()
    private let factory = BookFactory()
    private let stage = DeskStage()
    private var poolRadius: Float?
    private let shelf = Entity()
    /// Marks the book a push tips with `glow`, and takes that book's taps with `hitBox`.
    private let marker = Entity()
    /// A box a little larger than the marked book, since a thin book is hard to hit from the
    /// overview. `tap(at:in:)` finds it with a raycast. It is a trigger, so books pass through
    /// it, and its overlaps play no sound. Its filter is the default one, because a raycast
    /// skips a shape whose filter collides with nothing.
    private let hitBox = Entity()
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
    /// The cobwebs that still hang, in chain order, and those tearing.
    private var cobwebs: [HangingCobweb] = []
    private var torn: [HangingCobweb] = []
    private lazy var silk = HangingCobweb.silk()
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
    /// The camera and the table point under the fingers when they started moving the camera,
    /// whether they pinch, and the drag's translation then.
    private var cameraMove:
        (start: PileCamera, focus: SIMD3<Float>, pinches: Bool, translation: CGSize)?
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
        marker.addChild(hitBox)
        hitBox.components.set(InputTargetComponent())
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
            guard let self, event.entityA != hitBox, event.entityB != hitBox else { return }
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
    /// The chain is `DominoLayout.chain(_:)`, so the order of `books`, the shelf's sort
    /// order, does not matter. A new chain or generation removes every book, frames the whole
    /// path between the bars of `viewport`, and lays the lamp's pool over it. Books stand up
    /// `batchSize` at a time, each batch waiting at most `coverWait` for its covers and then
    /// for its cobwebs' meshes. Returns when every book stands or the task is cancelled.
    func setUp(_ books: [CloudBook], generation: Int, viewport: PileViewport, model: AppModel)
        async
    {
        let chain = DominoLayout.chain(books)
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
            let cobwebs = await makeCobwebs(before: batch)
            guard !Task.isCancelled, self.key == key else { return }
            for slot in batch { spawn(slot, cobweb: cobwebs[slot.book.id]) }
            spawned = end
        }
        #if DEBUG
            showDebugCobweb()
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
        cobwebs = []
        torn = []
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

    /// Stands the book of `slot`, with `cobweb` hanging between it and the book before it.
    private func spawn(_ slot: DominoSlot, cobweb: HangingCobweb?) {
        guard
            let book = factory.makeBook(
                slot.book.id, mode: .dynamic, lighting: stage.lighting,
                mass: DominoLayout.mass(height: slot.size.y))
        else { return }
        // A hair above the table, so it settles onto it rather than starting inside it.
        book.transform = Transform(
            rotation: DominoLayout.standing(heading: slot.heading),
            translation: [slot.position.x, slot.size.y / 2 + 0.002, slot.position.y])
        shelf.addChild(book)
        indices[book.id] = books.count
        books.append(book)
        slots.append(slot)
        guard var cobweb, books.count > 1 else { return }
        cobweb.book = books.count - 2
        shelf.addChild(cobweb.root)
        cobwebs.append(cobweb)
        status.cobwebs += 1
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
    /// thin book still pushes, and returns `nil`, as does a tap on the table.
    ///
    /// It casts its own ray from the camera: a targeted tap gesture fires only on a touch that
    /// lands on a book, even where `hitBox` lies around it.
    func tap(at point: CGPoint, in size: CGSize) -> Int? {
        guard size.width > 0, size.height > 0, let scene = root.scene else { return nil }
        let ray = ray(through: point, in: size)
        guard
            let entity =
                scene.raycast(
                    origin: ray.origin, direction: ray.direction, length: 300, query: .nearest,
                    relativeTo: root
                )
                .first?
                .entity,
            let index = entity == hitBox ? marked : indices[entity.id]
        else { return nil }
        if index < next { return slots[index].book.id }
        pushNext()
        return nil
    }

    /// The ID of the book an entity belongs to, the marked book's for `hitBox`, or `nil` for
    /// the table.
    func bookID(for entity: Entity) -> Int? {
        (entity == hitBox ? marked : indices[entity.id]).map { slots[$0].book.id }
    }

    /// The book a push tips (see `DominoLayout.pushTarget`).
    private var target: Int {
        DominoLayout.pushTarget(next: next, count: books.count) {
            books[$0].transform.rotation.act([0, 1, 0]).y > Self.uprightTilt
        }
    }

    /// Tips the book a push tips (see `target`) forward along the path, with a light tap, while
    /// the chain waits for a push. While books fall, it does nothing.
    func pushNext() {
        guard status.phase.waitsForPush, next < books.count else { return }
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
        follows = !reducesMotion
        feedback.impact(
            impulse: 0, mass: book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0,
            position: book.position(relativeTo: root), pan: pan, minimum: 0.2)
    }

    /// Zooms toward the point under `focus` by `magnification`, or slides the camera across
    /// the table with a one-finger `translation`, keeping the path in view.
    ///
    /// A drag that becomes a pinch, or a pinch that becomes a drag, starts a new move from the
    /// camera as it is, about the new focus and from the drag's translation so far, so the
    /// camera does not jump.
    func moveCamera(translation: CGSize, magnification: CGFloat, focus: CGPoint?, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if let move = cameraMove, move.pinches != (focus != nil) { cameraMove = nil }
        if cameraMove == nil {
            follows = false
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

    /// The ray from the camera through `point` in a view of `size`.
    private func ray(through point: CGPoint, in size: CGSize) -> (
        origin: SIMD3<Float>, direction: SIMD3<Float>
    ) {
        let ndc = SIMD2(Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
        return view.ray(ndc: ndc, aspect: aspect)
    }

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
            started = true
        }
        tearCobwebs()
        for index in torn.indices.reversed() {
            if !torn[index].advance(by: Float(deltaTime)) { torn.remove(at: index) }
        }
        let phase = DominoLayout.phase(
            next: next, count: books.count, started: started,
            settled: clock - lastAdvance > Self.stallTime)
        if status.phase != phase { status.phase = phase }
        switch phase {
        case .standing, .stalled: mark(target)
        default: mark(nil)
        }
        if follows, cameraMove == nil { steer(Float(deltaTime)) }
    }

    /// Tears the cobwebs near the front whose books have tilted past `tearTilt`, once the chain
    /// has started, so a book that rocks as it stands up tears nothing.
    private func tearCobwebs() {
        guard started else { return }
        func tilt(_ index: Int) -> Float { books[index].transform.rotation.act([0, 1, 0]).y }
        var index = 0
        while index < cobwebs.count, cobwebs[index].book <= next + 2 {
            let book = cobwebs[index].book
            guard min(tilt(book), tilt(book + 1)) < Self.tearTilt else {
                index += 1
                continue
            }
            var web = cobwebs.remove(at: index)
            web.tear(near: books[book], far: books[book + 1], fadesOnly: reducesMotion)
            torn.append(web)
        }
    }

    // MARK: Marking the next book

    /// Moves the marker to the book at `index`, or hides it for `nil` or an index past the
    /// last book.
    private func mark(_ index: Int?) {
        let index = index.flatMap { slots.indices.contains($0) ? $0 : nil }
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
        // Past the book's covers by less than the gap to a neighbor (`DominoLayout.gap`), so
        // the box does not cover a neighbor's taps on a row.
        let box = slot.size + [0.4, 0.3, 0.3]
        hitBox.components.set(
            CollisionComponent(
                shapes: [.generateBox(size: box).offsetBy(translation: [0, box.y / 2, 0])],
                mode: .trigger))
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
        /// Simulator hook: `-BookwormsDominoCobweb <n>` zooms all the way in on the chain's nth
        /// cobweb, counting from 1, once every book stands.
        private func showDebugCobweb() {
            guard
                let number = UserDefaults.standard.string(forKey: "BookwormsDominoCobweb")
                    .flatMap(Int.init), cobwebs.indices.contains(number - 1)
            else { return }
            let index = cobwebs[number - 1].book
            let middle = (slots[index].position + slots[index + 1].position) / 2
            look(
                through: PileCamera(
                    target: [middle.x, slots[index].size.y, middle.y],
                    zoom: PileCamera.zoomRange.upperBound))
        }

        /// Simulator hook: `-BookwormsDominoPush <seconds>` pushes the next book whenever the
        /// chain has stood or stalled that long, until every book has fallen.
        private func runDebugPushes() async {
            guard
                let delay = UserDefaults.standard.string(forKey: "BookwormsDominoPush")
                    .flatMap(Double.init)
            else { return }
            while !Task.isCancelled, status.phase != .done {
                try? await Task.sleep(for: .seconds(delay))
                pushNext()
            }
        }
    #endif
}
