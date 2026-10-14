import RealityKit
import SwiftUI

/// How a book leaves a 3D scene for its details and returns. Times are in seconds.
///
/// The book first rises straight up until it clears the books that lay over it, speeding up as
/// it goes; in a scene whose books are arranged, the books resting on it first make way (see
/// `BookExit`). A spring then carries it from the top of the rise to its details, starting at the
/// rise's speed and overshooting slightly. Back throws it at the place it left, on a path that
/// gravity bends, so it lands there after `whipDuration(from:to:)`, or, in a scene whose books
/// are arranged, sets it back down exactly where it lay (see `setDown`).
enum BookFlight {
    static let spring = Spring(duration: 0.8, bounce: 0.2)
    /// The shortest a throw back takes, and the fastest it flies on average, in units per
    /// second, about as fast as from a pile at the default zoom, so a throw from farther away
    /// takes longer rather than hitting harder.
    static let whipDuration: Float = 0.26
    static let whipSpeed: Float = 80
    static let setDownDuration: Float = 0.5
    /// The share of a set-down that crosses to the top of the rise over the book's place; the
    /// rest drops it in.
    static let crossing: Float = 0.6
    /// How far the veil stays behind the book's middle: more than half the largest book's
    /// diagonal, 3.72 units, so the book never passes through it.
    static let veilGap: Float = 2
    /// The highest a scene's books reach: a pile against the walls (see `PileTray`). The
    /// dominoes stand lower, at most `BookShape.longest`.
    static let sceneHeight: Float = 4.5
    /// The most a book rises: the height of the tallest pile.
    static let highestRise: Float = 6
    /// How fast a book slides out from under the books resting on it (see `BookExit`), in
    /// units per second, after a start of `slideLead` seconds.
    static let slideSpeed: Float = 12
    static let slideLead: Float = 0.12
    /// How long the books resting on a book take to be drawn back off it, or back onto it, and
    /// to tip back up beside it before that (see `BookExit`).
    static let drawDuration: Float = 0.2

    /// How a book of `size` that tips about one end falls: its angular acceleration under the
    /// desk's gravity, in radians per second squared, as for a rod pivoting about its end.
    static func tipping(_ size: SIMD3<Float>) -> Float {
        1.5 * PileLayout.gravity / max(size.x, size.y, size.z)
    }

    /// How long a slide of `distance` units takes, and none for no slide.
    static func slideDuration(_ distance: Float) -> Float {
        distance > 0 ? slideLead + distance / slideSpeed : 0
    }

    /// How far a book with `bounds` rises: until its bottom clears, by 0.15 units, the top of
    /// every book in `others` that overlaps its footprint, grown by `margin` on each side, from
    /// above, and rests on it or on another such book. A margin takes in books standing beside
    /// it, such as a domino's neighbors. A book more than 0.5 units above that stack, such as
    /// one still falling, does not count. It rises at least 0.4 units, to come free of the
    /// table, and at most `highestRise`.
    static func rise(of bounds: BoundingBox, clearing others: [BoundingBox], margin: Float = 0)
        -> Float
    {
        var top = bounds.min.y
        for other in others.sorted(by: { $0.min.y < $1.min.y })
        where other.max.y > bounds.min.y && other.max.x > bounds.min.x - margin
            && other.min.x < bounds.max.x + margin && other.max.z > bounds.min.z - margin
            && other.min.z < bounds.max.z + margin
        {
            // Sorted by height, so every later book starts higher still.
            guard other.min.y <= max(top, bounds.max.y) + 0.5 else { break }
            top = max(top, other.max.y)
        }
        return min(max(top + 0.15 - bounds.min.y, 0.4), highestRise)
    }

    /// The indices of the books in `others` that a book with `bounds` can leave unsupported or
    /// knock as it rises and stops colliding: every book whose bounds reach over its footprint,
    /// grown by `margin` on each side, and end higher than `margin` below its bottom. That takes
    /// in the books resting on it or stacked above it, those leaning on it, and those touching
    /// its sides or its bottom, and leaves out books more than `margin` beside or under it.
    static func disturbed(
        by bounds: BoundingBox, among others: [BoundingBox], margin: Float = 0.1
    ) -> [Int] {
        others.indices.filter { index in
            let other = others[index]
            return other.max.y > bounds.min.y - margin
                && other.max.x > bounds.min.x - margin && other.min.x < bounds.max.x + margin
                && other.max.z > bounds.min.z - margin && other.min.z < bounds.max.z + margin
        }
    }

    /// The index of the book in `bounds` with the most other books over it: books that overlap
    /// its footprint and start above its middle. Returns `nil` for no books.
    static func mostBuried(_ bounds: [BoundingBox]) -> Int? {
        let counts = bounds.map { book in
            bounds.count { over in
                over.min.y > book.center.y && over.max.x > book.min.x && over.min.x < book.max.x
                    && over.max.z > book.min.z && over.min.z < book.max.z
            }
        }
        return counts.indices.max { counts[$0] < counts[$1] }
    }

    /// How long a rise of `rise` takes: 0.14 seconds for the least rise, so a book with nothing
    /// on it leaves at once, up to 0.3 for a rise of 2 units or more. The books a book carries
    /// leave it at its top speed when it stops colliding, so a slower rise tosses them less
    /// high.
    static func riseDuration(_ rise: Float) -> Double { Double(min(0.3, 0.1 + rise * 0.1)) }

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

    /// How long a throw from `start` to `end` takes: `whipDuration`, or longer for a throw that
    /// would fly faster than `whipSpeed` on average.
    static func whipDuration(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Float {
        max(whipDuration, simd_distance(start, end) / whipSpeed)
    }

    /// The velocity that throws a body from `start` to `end` under `gravity` in
    /// `whipDuration(from:to:)`.
    static func launch(from start: SIMD3<Float>, to end: SIMD3<Float>, gravity: SIMD3<Float>)
        -> SIMD3<Float>
    {
        let time = whipDuration(from: start, to: end)
        return (end - start) / time - gravity * time / 2
    }

    /// A lively tumble for a book thrown at `velocity`: end over end along its path, with a
    /// twist about it.
    static func spin(for velocity: SIMD3<Float>) -> SIMD3<Float> {
        let across = simd_cross([0, 1, 0], velocity)
        let axis = simd_length(across) > 1e-3 ? simd_normalize(across) : [1, 0, 0]
        return axis * 10 + velocity / max(simd_length(velocity), 1e-3) * 8
    }

    /// The pose `progress` of the way, from 0 to 1, through setting a book down from `start` in
    /// `end`, a book's place that it rose `rise` from.
    ///
    /// Over the first `crossing` of the time, the book moves in a straight line to the top of
    /// that rise, easing in and out, and turns to its pose on the way. The line runs from in
    /// front of the camera down toward the place, so the book stays in view and does not sweep
    /// high over the scene. Then the book drops straight down into its place, easing in and
    /// out, so it clears the books beside its place, which the rise cleared, and arrives at
    /// rest, without a bounce.
    static func setDown(from start: Transform, to end: Transform, rise: Float, progress: Float)
        -> Transform
    {
        func ease(_ value: Float) -> Float {
            let value = min(1, max(0, value))
            return value * value * (3 - 2 * value)
        }
        let across = ease(progress / crossing)
        let down = ease((progress - crossing) / (1 - crossing))
        let top = end.translation + [0, rise, 0]
        return Transform(
            scale: end.scale, rotation: simd_slerp(start.rotation, end.rotation, across),
            translation: start.translation + (top - start.translation) * across
                - [0, rise * down, 0])
    }
}

/// A 3D scene that lifts a book out to its details (see `BookLifter` and `LiftedDetails`).
@MainActor
protocol LiftingScene: AnyObject {
    /// The scene's flight, which places, turns, and dresses the lifted book.
    var lifter: BookLifter { get }
    /// Starts lifting the book with `id` toward its details and returns the seconds until it
    /// gets there, or `nil`, leaving the scene as it was, when the scene cannot lift it.
    func lift(_ id: Int) -> Double?
    /// Returns the lifted book to its place once the details have faded out.
    func throwBack()
    /// Puts a lifted or returning book back at once, and the camera as the reader left it.
    func dropLifted()
    #if DEBUG
        /// The ID of the book with the most books over it, for `-BookwormsOpenBook buried`.
        func mostBuriedID() -> Int?
    #endif
}

/// A book lifted out of a 3D scene to stand in for the 3D book on its details, and returned,
/// for `BookPileScene` and `DominoScene`.
///
/// The book is kinematic. It rises at a velocity set every frame, as a held book moves, so it
/// pushes the books on it up or aside. At the top of its rise, it collides with nothing, so the
/// books it carried, which rode up on it, fall back, and it follows `BookFlight.pose` to the
/// pose that the details' frame and turn give, and stays on it. Leaving upward, it passes
/// through those books for a frame or two before they fall clear. From there until it is back
/// in its place, it is drawn as `Book3DView` draws the details' book: unlit, each face darkened
/// by that view's light, and without a ribbon. A walnut veil, a child of the camera, dims the
/// scene behind it.
///
/// A sleeping body stays put when its support leaves, so every dynamic book that reaches over
/// the lifted book or touches it (`BookFlight.disturbed`) wakes as the book starts to rise and
/// again as it stops colliding. The books it carried then fall into the gap and settle.
///
/// The book returns thrown, as in the Desk scene, whose books lie loose. A scene whose books are
/// arranged, as the dominoes are, holds still while a book is out and passes `setsDownInPlace`:
/// the book then rises and returns by its pose alone, colliding with nothing, so it shoves no
/// book, and **Back** sets it down exactly where it lay, in the body mode and with the motion it
/// had. The books resting on it make way, as `BookExit` plans: it slides out from under them,
/// or they are drawn back off it, and they fall as far as nothing holds them up; once it is
/// back, they lie exactly as they did. The scene moves its camera: each update passes `aim`
/// the camera's share of the way from the view it shows the scene from to the view it shows the
/// flight from, which the veil's opacity also follows. Collisions reach the scene first, which
/// hands them to `handle`.
@MainActor
final class BookLifter {
    private let root: Entity
    private let camera: PerspectiveCamera
    private let factory: BookFactory
    private let feedback: ImpactFeedback
    /// The collision group that a thrown book passes through until its first hit: the pile's
    /// walls, since the details pose can lie outside them.
    private let passes: CollisionGroup
    /// The share of a thrown book's sideways speed, its fall, and its tumble that its first hit
    /// keeps (see `land`).
    private let keeps: (sideways: Float, fall: Float, tumble: Float)
    /// Whether the book rises and returns by its pose and is set down exactly where it lay,
    /// rather than thrown back, for a scene that holds still while it is out.
    private let setsDownInPlace: Bool
    private var lifted: Lifted?
    private var returning: Return?
    /// The books resting on the book in flight in a scene that holds still, which make way for
    /// it (see `BookExit`), and whether they are drawn back off it rather than it sliding out
    /// from under them.
    private var riders: [Rider] = []
    private var drawsBack = false
    /// A camera-facing walnut plane that dims the scene behind a lifted book, made by the first
    /// lift.
    private var veil: ModelEntity?
    private var aspect: Float = 0.5

    private struct Lifted {
        let book: ModelEntity
        let id: Int
        let size: SIMD3<Float>
        let resting: Transform
        /// Where the book starts to rise, at the end of its slide out from under the books on
        /// it (see `BookExit`), and how long the slide, or drawing those books back off it,
        /// takes before the rise; `resting` and none for neither.
        let start: Transform
        let lead: TimeInterval
        let rise: Float
        /// The book's body mode and motion as it lay, which a book set down in place takes again.
        let mode: PhysicsBodyMode
        let motion: PhysicsMotionComponent
        /// The other books, which the lift can disturb, and the bounds the book left.
        let others: [ModelEntity]
        let bounds: BoundingBox
        /// The lit materials the book is drawn from: the scene's, then `dress`'s sharper ones.
        var materials: [any RealityKit.Material]
        var elapsed: TimeInterval = 0
        /// The book's pose at the top of its rise, once it gets there.
        var clear: Transform?
        /// Where the details draw the book, in normalized device coordinates, and the view's
        /// width-to-height aspect.
        var frame: (center: SIMD2<Float>, height: Float, aspect: Float)?
        var turn = BookPose.resting
        /// The camera's and the veil's share of the way to the details.
        var share: Float = 0
        /// Counts the prompt frames in a row since `throwBack` asked for the book back; `nil`
        /// until it does.
        var steadyFrames: Int?
        #if DEBUG
            /// The books the lift woke, and the frames since it started, for the lift log.
            var riders: [ModelEntity] = []
            var frames = 0
        #endif
    }

    /// A book resting on the book in flight, which makes way for it.
    private struct Rider {
        let book: ModelEntity
        let plan: BookExit.Rider
        /// The motion it had, which it takes again once the flight ends.
        let motion: PhysicsMotionComponent
        /// How far it has turned down, in radians, negative while it is turned up, how fast it
        /// falls, how far it is drawn back (see `BookExit.Rider.back`), and the angle a return
        /// starts from.
        var angle: Float = 0
        var speed: Float = 0
        var drawn: Float = 0
        var from: Float = 0
    }

    /// How the riders move in a frame.
    private enum Riding {
        /// They fall as far as gravity takes them and the book in flight lets them, and the
        /// book pushes them up where it meets them.
        case falling
        /// They hold their turn, drawn `drawn` of the way back if given, and the book, sliding
        /// back in under them, pushes them back up where it meets them.
        case pushed(drawn: Float? = nil)
        /// They are drawn `share` of the way back off the book, and otherwise fall as they do
        /// `falling`, so their near ends ride down its edge.
        case drawn(share: Float)
        /// They turn back up `share` of the way from where they lay.
        case righted(share: Float)
    }

    /// A book on its way back: thrown, until its first hit, or set down in `place`.
    private struct Return {
        let flight: Lifted
        /// The pose the book leaves the details from.
        let start: Transform
        let place: Transform?
        let duration: Float
        var elapsed: Float = 0
        /// Whether the book has its scene textures again: a thrown book from its first hit, and
        /// a book set down from the start of its drop.
        var landed = false
    }

    init(
        root: Entity, camera: PerspectiveCamera, factory: BookFactory, feedback: ImpactFeedback,
        passes: CollisionGroup = [],
        keeps: (sideways: Float, fall: Float, tumble: Float) = (0.25, 1, 0.5),
        setsDownInPlace: Bool = false
    ) {
        self.root = root
        self.camera = camera
        self.factory = factory
        self.feedback = feedback
        self.passes = passes
        self.keeps = keeps
        self.setsDownInPlace = setsDownInPlace
    }

    /// The ID of the lifted book, if any.
    var liftedID: Int? { lifted?.id }

    /// Whether a book is lifted or on its way back, when another book cannot lift.
    var isFlying: Bool { lifted != nil || returning != nil }

    /// The book in flight, lifted or on its way back.
    var book: ModelEntity? { lifted?.book ?? returning?.flight.book }

    /// Starts lifting `book`, the book with `id`, out from among `books`, in a view of
    /// width-to-height `aspect`, and returns the seconds until it reaches its details. It
    /// rises clear of the books over its footprint grown by `margin` (see `BookFlight.rise`).
    /// Returns `nil` while another book flies or when the book has no parts.
    func lift(
        _ book: ModelEntity, id: Int, among books: [ModelEntity], aspect: Float, margin: Float = 0
    ) -> Double? {
        guard !isFlying, let parts = factory.parts[id] else { return nil }
        self.aspect = aspect
        let others = books.filter { $0 !== book }
        let bounds = book.visualBounds(relativeTo: root)
        let mode = book.components[PhysicsBodyComponent.self]?.mode ?? .dynamic
        let motion = book.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent()
        book.components[PhysicsBodyComponent.self]?.mode = .kinematic
        book.components.set(PhysicsMotionComponent())
        var rise: Float
        var start = book.transform
        var lead: TimeInterval = 0
        riders = []
        if setsDownInPlace {
            #if DEBUG
                let began = ContinuousClock.now
            #endif
            let exit = BookExit(
                book: (book.transform, parts.shape.size),
                among: others.map { ($0.transform, Self.size(of: $0)) }, margin: margin)
            #if DEBUG
                logExit(exit, id: id, took: ContinuousClock.now - began)
            #endif
            rise = exit.rise
            start.translation += exit.slide
            drawsBack = exit.drawsBack
            lead = TimeInterval(
                drawsBack
                    ? BookFlight.drawDuration : BookFlight.slideDuration(simd_length(exit.slide)))
            riders = exit.riders.map { plan in
                let rider = others[plan.index]
                return Rider(
                    book: rider, plan: plan,
                    motion: rider.components[PhysicsMotionComponent.self]
                        ?? PhysicsMotionComponent())
            }
        } else {
            rise = BookFlight.rise(
                of: bounds, clearing: others.map { $0.visualBounds(relativeTo: root) },
                margin: margin)
        }
        lifted = Lifted(
            book: book, id: id, size: parts.shape.size, resting: book.transform, start: start,
            lead: lead, rise: rise, mode: mode, motion: motion, others: others, bounds: bounds,
            materials: parts.materials)
        if setsDownInPlace {
            // The scene holds still, so the book shoves nothing on its way out or back.
            book.components[CollisionComponent.self]?.filter = CollisionFilter(group: [], mask: [])
        } else {
            // Asleep, they would let the rising book pass through them.
            #if DEBUG
                lifted?.riders = wake(others, around: bounds)
            #else
                wake(others, around: bounds)
            #endif
        }
        if veil == nil { veil = makeVeil() }
        return lead + BookFlight.landing(rise: rise)
    }

    /// The size of the box that `book` collides as.
    private static func size(of book: ModelEntity) -> SIMD3<Float> {
        book.components[CollisionComponent.self]?.shapes.first?.bounds.extents ?? .zero
    }

    /// Sets where the details draw the lifted book: `frame`, in the points of a view of `size`
    /// that shows the whole scene. The book moves at once rather than on the scene's next
    /// update, which would always leave it a frame behind the details as they scroll.
    func place(_ frame: CGRect, in size: CGSize) {
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
    ///
    /// The book takes new materials only when a face's shade changes by a level of 8-bit color,
    /// since the details' slow drift turns it a little on every frame.
    func turn(_ pose: BookPose) {
        guard let lifted, lifted.turn != pose else { return }
        self.lifted?.turn = pose
        fly()
        func levels(_ pose: BookPose) -> [Float] {
            BookFlight.shades(of: lifted.size, at: pose).map { ($0 * 255).rounded() }
        }
        if levels(pose) != levels(lifted.turn) { redraw() }
    }

    /// Gives the lifted book textures as sharp as the details' own book at `scale` pixels per
    /// point, with `book`'s current cover and design. The book's scene textures take the cover
    /// too, so the book returns as the details last showed it; see `restyle(_:model:)` for its
    /// design.
    func dress(_ book: CloudBook, scale: CGFloat, model: AppModel) async {
        guard lifted?.id == book.id, let shape = factory.parts[book.id]?.shape else { return }
        let covers = model.covers
        let small = await covers.image(for: book, maximumPixelSize: factory.coverPixels(for: book))
        let cover = await covers.image(for: book) ?? small
        guard !Task.isCancelled, lifted?.id == book.id else { return }
        if let small { await factory.addCover(small, to: book.id) }
        guard
            let dressed = await factory.makeParts(
                book, cover: cover, look: model.look(for: book), shape: shape, scale: scale),
            !Task.isCancelled, lifted?.id == book.id
        else { return }
        lifted?.materials = dressed.materials
        redraw()
    }

    /// Draws `book`'s scene textures again when its design changed since the scene built them,
    /// so a lifted book lands back with the design its details showed, including colors the
    /// reader picked just before **Back**. A book that already landed keeps its textures.
    func restyle(_ book: CloudBook, model: AppModel) async {
        let look = model.look(for: book)
        guard let built = factory.parts[book.id], built.look != look else { return }
        let cover = await model.covers.image(
            for: book, maximumPixelSize: factory.coverPixels(for: book))
        guard !Task.isCancelled else { return }
        await factory.restyle(book, cover: cover, look: look)
    }

    /// Returns the lifted book: with `setsDownInPlace`, sets it down where it lay (see
    /// `BookFlight.setDown`), and otherwise throws it back at the place it left, fast and
    /// tumbling, so it crashes into the books that fell into its place. The camera and the veil
    /// return over the same time.
    ///
    /// The book leaves once three frames in a row follow one another closely, so a main-thread
    /// stall from the caller's own changes passes while it holds still. A thrown book's details
    /// pose can lie outside the scene's walls or above its ceiling, so it passes through them
    /// until it first hits something, which happens inside them, with a hard tap and knock.
    /// Continuous collision detection keeps it out of the table.
    func throwBack() {
        guard let lifted, lifted.steadyFrames == nil else { return }
        self.lifted?.steadyFrames = 0
        // Stops a rise in progress while the book waits.
        lifted.book.components.set(PhysicsMotionComponent())
    }

    /// Moves the book in flight and the veil by `deltaTime`, after `aim` moves the scene's
    /// camera for the flight.
    func update(by deltaTime: TimeInterval, aim: (Float) -> Void) {
        if let steady = lifted?.steadyFrames {
            // A late frame follows a main-thread stall, such as a large SwiftUI update. The
            // physics would catch up on one during the throw and skip it, so the book holds
            // still until three prompt frames in a row show the stall has passed.
            let frames = deltaTime < 0.05 ? steady + 1 : 0
            lifted?.steadyFrames = frames
            if frames >= 3 { launch() }
        } else if lifted != nil {
            moveLifted(by: deltaTime, aim: aim)
        }
        if returning != nil { moveReturn(by: Float(deltaTime), aim: aim) }
    }

    /// Lands a thrown book at its first hit and returns `true`, or returns `false` for any
    /// other collision, which the scene plays as usual.
    func handle(_ event: CollisionEvents.Began) -> Bool {
        guard let returning, returning.place == nil, !returning.landed,
            event.entityA === returning.flight.book || event.entityB === returning.flight.book
        else { return false }
        land(impulse: event.impulse)
        return true
    }

    /// Ends a lift or a return at once: puts the book back (see `put`), and the camera, through
    /// `aim`, and the veil as they were.
    func drop(aim: (Float) -> Void) {
        guard let flight = lifted ?? returning?.flight else { return }
        lifted = nil
        returning = nil
        put(flight, at: setsDownInPlace ? flight.resting : nil)
        aim(0)
        showVeil(0)
    }

    /// Forgets the flight, for a scene that removed its books, and hides the veil.
    func reset() {
        lifted = nil
        returning = nil
        riders = []
        showVeil(0)
    }

    // MARK: Flight

    /// Wakes the dynamic books among `books` that a book with `bounds` can disturb, and
    /// returns them.
    @discardableResult
    private func wake(_ books: [ModelEntity], around bounds: BoundingBox) -> [ModelEntity] {
        let disturbed =
            BookFlight.disturbed(
                by: bounds, among: books.map { $0.visualBounds(relativeTo: root) }
            )
            .map { books[$0] }
            .filter { $0.components[PhysicsBodyComponent.self]?.mode == .dynamic }
        for book in disturbed {
            book.applyLinearImpulse([0, -1e-4, 0], relativeTo: nil)
        }
        return disturbed
    }

    /// Moves the lifted book out from under the books on it, if it slides, up out of the scene,
    /// then along its flight to the details, while the camera eases to the scene's flight view
    /// and the veil darkens, and the books that rested on it make way.
    private func moveLifted(by deltaTime: TimeInterval, aim: (Float) -> Void) {
        guard var lifted else { return }
        #if DEBUG
            logLift(&lifted)
        #endif
        // A late frame, such as the one that follows mounting the details, slows the flight
        // briefly rather than skipping it ahead.
        let step = min(deltaTime, 1.0 / 20)
        lifted.elapsed += step
        let progress = Float(
            min(1, lifted.elapsed / (lifted.lead + BookFlight.landing(rise: lifted.rise))))
        lifted.share = progress * progress * (3 - 2 * progress)
        aim(lifted.share)
        let book = lifted.book
        let rising = lifted.elapsed - lifted.lead
        let led = Self.ease(Float(lifted.elapsed / max(lifted.lead, 1e-3)))
        defer {
            moveRiders(rising < 0 && drawsBack ? .drawn(share: led) : .falling, by: Float(step))
        }
        if rising < 0 {
            // Slides out from under the books on it, or holds still while they are drawn back.
            book.position =
                lifted.resting.translation
                + (lifted.start.translation - lifted.resting.translation) * led
            self.lifted = lifted
        } else if rising < BookFlight.riseDuration(lifted.rise) {
            let goal =
                lifted.start.translation + [0, BookFlight.climb(lifted.rise, at: rising), 0]
            if setsDownInPlace {
                book.position = goal
            } else {
                // A velocity, as for a held book, lets the physics shove other books aside.
                let step = Float(max(deltaTime, 1.0 / 120))
                book.components.set(
                    PhysicsMotionComponent(
                        linearVelocity: (goal - book.position(relativeTo: root)) / step))
            }
            self.lifted = lifted
        } else {
            let leaves = lifted.clear == nil
            if leaves, setsDownInPlace {
                lifted.clear = Transform(
                    scale: lifted.start.scale, rotation: lifted.start.rotation,
                    translation: lifted.start.translation + [0, lifted.rise, 0])
            } else if leaves {
                lifted.clear = book.transform
                book.components.set(PhysicsMotionComponent())
                // Above the scene now, it lets the books it carried fall back instead of
                // flinging them along.
                book.components[CollisionComponent.self]?.filter = CollisionFilter(
                    group: [], mask: [])
                // The column the book rose through, which the books it carried rest over.
                let risen = book.visualBounds(relativeTo: root)
                wake(
                    lifted.others,
                    around: BoundingBox(
                        min: pointwiseMin(lifted.bounds.min, risen.min),
                        max: pointwiseMax(lifted.bounds.max, risen.max)))
            }
            self.lifted = lifted
            if leaves { redraw() }
            fly()
        }
        showVeil(lifted.share, behind: book)
    }

    /// Puts the lifted book where its flight is at its current time, once it has risen clear.
    /// Following the details' frame and turn as they change keeps the book on them.
    private func fly() {
        guard let lifted, let clear = lifted.clear else { return }
        let target = lifted.frame.map { frame in
            PileCamera.detailPose(
                seenFrom: camera.transform, center: frame.center, height: frame.height,
                size: lifted.size, pose: lifted.turn, aspect: frame.aspect)
        }
        lifted.book.transform = BookFlight.pose(
            from: clear, speed: BookFlight.topSpeed(lifted.rise), to: target ?? clear,
            time: lifted.elapsed - lifted.lead - BookFlight.riseDuration(lifted.rise))
    }

    /// Smoothstep: eases in and out from 0 to 1.
    private static func ease(_ value: Float) -> Float {
        let value = min(1, max(0, value))
        return value * value * (3 - 2 * value)
    }

    /// Moves the books that rested on the book in flight by `deltaTime`, as `riding` says, and
    /// keeps each out of the book: a book that rests on another rider turns as far, for its
    /// own fall, as that rider has.
    private func moveRiders(_ riding: Riding, by deltaTime: Float) {
        guard !riders.isEmpty, let flight = lifted ?? returning?.flight else { return }
        let book = DominoSetup.Box(flight.book.transform, size: flight.size).shrunk
        for order in riders.indices {
            var rider = riders[order]
            let plan = rider.plan
            if let parent = plan.parent {
                let under = riders[parent]
                rider.angle =
                    under.plan.fallen > 0
                    ? plan.fallen * max(0, under.angle) / under.plan.fallen : 0
            } else {
                switch riding {
                case .falling, .drawn:
                    if case .drawn(let share) = riding { rider.drawn = share }
                    rider.speed += BookFlight.tipping(plan.size) * deltaTime
                    let next = min(plan.fallen, rider.angle + rider.speed * deltaTime)
                    let free = Self.freeAngle(
                        of: plan, upTo: next, drawn: rider.drawn, clearing: book)
                    if free < next { rider.speed = 0 }
                    rider.angle = free
                case .pushed(let drawn):
                    rider.drawn = drawn ?? rider.drawn
                    rider.angle = max(
                        0,
                        Self.freeAngle(
                            of: plan, upTo: rider.angle, drawn: rider.drawn, clearing: book))
                    rider.speed = 0
                case .righted(let share):
                    rider.angle = rider.from * (1 - share)
                    rider.speed = 0
                }
            }
            rider.book.transform = plan.pose(turned: rider.angle, drawn: rider.drawn)
            riders[order] = rider
        }
    }

    /// The largest angle up to `limit` at which `rider`, drawn `drawn` of the way back, does not
    /// meet `book`, by bisection
    /// from as far up as a rider turns (`BookExit.highest`). A rider lower than it rests meets
    /// a book under it, and one turned higher clears it.
    private static func freeAngle(
        of rider: BookExit.Rider, upTo limit: Float, drawn: Float, clearing book: DominoSetup.Box
    ) -> Float {
        func hits(_ angle: Float) -> Bool {
            let box = rider.box(turned: angle, drawn: drawn)
            return box.bounds.overlaps(book.bounds) && box.overlaps(book)
        }
        guard hits(limit) else { return limit }
        var free = -BookExit.highest
        var blocked = limit
        guard !hits(free) else { return free }
        for _ in 0..<12 {
            let middle = (free + blocked) / 2
            if hits(middle) { blocked = middle } else { free = middle }
        }
        return free
    }

    /// Sends the lifted book back: set down where it lay, or thrown.
    private func launch() {
        guard let lifted else { return }
        self.lifted = nil
        let book = lifted.book
        let place = setsDownInPlace ? lifted.resting : nil
        var duration = BookFlight.setDownDuration
        if place == nil {
            book.components[PhysicsBodyComponent.self]?.mode = .dynamic
            book.components[CollisionComponent.self]?.filter = CollisionFilter(
                group: .default, mask: CollisionGroup.all.subtracting(passes))
            let gravity =
                root.components[PhysicsSimulationComponent.self]?.gravity
                ?? [0, -PileLayout.gravity, 0]
            let start = book.position(relativeTo: root)
            let velocity = BookFlight.launch(
                from: start, to: lifted.resting.translation, gravity: gravity)
            duration = BookFlight.whipDuration(from: start, to: lifted.resting.translation)
            book.components.set(
                PhysicsMotionComponent(
                    linearVelocity: velocity, angularVelocity: BookFlight.spin(for: velocity)))
        } else {
            // It stays kinematic and collides with nothing until it is back in its place.
            book.components[CollisionComponent.self]?.filter = CollisionFilter(
                group: [], mask: [])
            // Riders drawn back tip back up beside it, then are drawn back onto it.
            duration += Float(lifted.lead) * (drawsBack ? 2 : 1)
            for order in riders.indices { riders[order].from = riders[order].angle }
        }
        returning = Return(flight: lifted, start: book.transform, place: place, duration: duration)
    }

    /// Returns the camera and veil to the scene while a book returns, and moves a book that is
    /// set down.
    ///
    /// A book set down crosses to the top of its rise and drops to where its slide out from
    /// under the books on it ended (see `BookFlight.setDown`), then slides back in under them,
    /// pushing them back up. Books drawn back off it instead tip back up beside it once it lies
    /// in its place, and are drawn back onto it.
    ///
    /// The veil stays behind the book and fades out before it would cut through the scene (see
    /// `showVeil`), so the scene shows before the book is back.
    private func moveReturn(by deltaTime: Float, aim: (Float) -> Void) {
        guard var returning else { return }
        let step = min(deltaTime, 1.0 / 20)
        returning.elapsed += step
        let flight = returning.flight
        let progress = min(1, returning.elapsed / returning.duration)
        // A book set down crosses and drops first; it then slides back in under the books that
        // rested on it, or they are drawn back onto it.
        let down =
            returning.place == nil
            ? progress : min(1, returning.elapsed / BookFlight.setDownDuration)
        let share = flight.share * (1 - Self.ease(down))
        aim(share)
        if returning.place != nil {
            // The seconds since the book reached the end of its slide, or its place.
            let after = returning.elapsed - BookFlight.setDownDuration
            let lead = max(Float(flight.lead), 1e-3)
            if down < 1 {
                flight.book.transform = BookFlight.setDown(
                    from: returning.start, to: flight.start, rise: flight.rise, progress: down)
            } else if drawsBack {
                flight.book.transform = flight.resting
                moveRiders(
                    after < lead
                        ? .righted(share: Self.ease(after / lead))
                        : .pushed(drawn: 1 - Self.ease(after / lead - 1)), by: step)
            } else {
                flight.book.transform = flight.resting
                flight.book.position =
                    flight.start.translation
                    + (flight.resting.translation - flight.start.translation)
                    * Self.ease(after / lead)
                moveRiders(.pushed(), by: step)
            }
            // Lit like the scene again as it drops into it.
            if down >= BookFlight.crossing, !returning.landed {
                returning.landed = true
                undress(flight)
            }
        }
        showVeil(share, behind: flight.book)
        self.returning = returning
        guard progress >= 1 else { return }
        if returning.place != nil {
            settle(flight)
        } else {
            // It reaches its old place now, inside the walls, if nothing stopped it on the way.
            land(impulse: nil)
        }
        self.returning = nil
    }

    /// Ends a thrown book's pass through the walls at its first hit, with a hard tap and
    /// knock through `feedback`, and gives it its scene textures again. `impulse` is the hit's,
    /// or `nil` when the book reached its place without one, which counts as a hit at its speed.
    ///
    /// The throw comes in at tens of units per second, mostly sideways, and tumbling, which
    /// would carry the book across the scene and out of it after the crash. The hit keeps
    /// `keeps` of the sideways speed, the fall, and the tumble, so the book stays near where it
    /// hit.
    private func land(impulse: Float?) {
        guard let returning, !returning.landed else { return }
        self.returning?.landed = true
        let book = returning.flight.book
        book.components[CollisionComponent.self]?.filter = .default
        let mass = book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0.5
        let speed = simd_length(
            book.components[PhysicsMotionComponent.self]?.linearVelocity ?? .zero)
        if var motion = book.components[PhysicsMotionComponent.self] {
            motion.linearVelocity *= [keeps.sideways, keeps.fall, keeps.sideways]
            motion.angularVelocity *= keeps.tumble
            book.components.set(motion)
        }
        undress(returning.flight)
        feedback.impact(
            impulse: impulse ?? mass * speed, mass: mass, position: book.position(relativeTo: root),
            pan: pan, minimum: 0.85)
    }

    /// Ends a set-down: puts the book where it lay, with a soft knock (see `put`).
    private func settle(_ flight: Lifted) {
        put(flight, at: flight.resting)
        let book = flight.book
        feedback.impact(
            impulse: 0, mass: book.components[PhysicsBodyComponent.self]?.massProperties.mass ?? 0,
            position: book.position(relativeTo: root), pan: pan, minimum: 0.3)
    }

    /// Puts the book of `flight` back and colliding again, in its scene textures: in `place`,
    /// where it lay, with the body mode and motion it had there, and the books that rested on
    /// it as they lay, or else at rest at the top of its rise over the place it left, so it
    /// falls onto the books that fell into that place.
    private func put(_ flight: Lifted, at place: Transform?) {
        for rider in riders {
            rider.book.transform = rider.plan.rest
            rider.book.components.set(rider.motion)
        }
        riders = []
        undress(flight)
        let book = flight.book
        book.components[CollisionComponent.self]?.filter = .default
        if let place {
            book.components[PhysicsBodyComponent.self]?.mode = flight.mode
            book.components.set(flight.motion)
            book.transform = place
        } else {
            book.components[PhysicsBodyComponent.self]?.mode = .dynamic
            book.components.set(PhysicsMotionComponent())
            var pose = flight.resting
            pose.translation.y += flight.rise
            book.transform = pose
        }
    }

    /// Gives a lifted book its scene textures again, which keeps their memory bounded, and its
    /// ribbon.
    private func undress(_ flight: Lifted) {
        flight.book.findEntity(named: BookFactory.ribbonName)?.isEnabled = true
        guard let materials = factory.parts[flight.id]?.materials else { return }
        flight.book.children.first?.components[ModelComponent.self]?.materials = materials
    }

    /// Draws the lifted book from its materials: lit like the scene while it rises, then unlit
    /// and shaded for its turn as `Book3DView` shades the details' own book, without a ribbon,
    /// which that book lacks.
    private func redraw() {
        guard let lifted else { return }
        lifted.book.findEntity(named: BookFactory.ribbonName)?.isEnabled = lifted.clear == nil
        let materials =
            lifted.clear == nil
            ? lifted.materials
            : zip(lifted.materials, BookFlight.shades(of: lifted.size, at: lifted.turn))
                .map { BookFactory.unlit($0, shade: $1) }
        lifted.book.children.first?.components[ModelComponent.self]?.materials = materials
    }

    private func pan(_ point: SIMD3<Float>) -> Float {
        PileCamera.pan(of: point, seenFrom: camera.transform, aspect: aspect)
    }

    // MARK: Veil

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

    /// Shows the veil at opacity `level`, `BookFlight.veilGap` behind `book`'s middle, so the
    /// book stays in front of it as it flies and the scene behind dims. At a `level` of 1, the
    /// scene does not show through.
    ///
    /// Deep enough to cut through the table or the books, the veil would draw a line across
    /// them, so it fades out over the last 4 units before the nearest point it could cut: where
    /// the bottom edge of the view meets books as high as `BookFlight.sceneHeight`. Each scene
    /// moves its camera for the flight so that this lies well behind the book.
    private func showVeil(_ level: Float, behind book: Entity? = nil) {
        guard let veil else { return }
        veil.isEnabled = level > 0.001
        guard veil.isEnabled, let book else { return }
        func depth(of point: SIMD3<Float>) -> Float {
            -camera.convert(position: point, from: root).z
        }
        let shown = camera.transform
        let slope = tan(PileCamera.fieldOfView / 2)
        let bottom = (shown.translation, shown.rotation.act(simd_normalize(SIMD3(0, -slope, -1))))
        let veilDepth = max(1, depth(of: book.position(relativeTo: root))) + BookFlight.veilGap
        let sceneDepth =
            PileCamera.intersect(bottom, height: BookFlight.sceneHeight).map(depth) ?? veilDepth
        // A little larger than the view at that depth.
        let height = 2.2 * veilDepth * slope
        veil.transform = Transform(
            scale: [height * aspect, height, 1], translation: [0, 0, -veilDepth])
        veil.components.set(
            OpacityComponent(opacity: level * min(1, max(0, (sceneDepth - veilDepth) / 4))))
    }

    #if DEBUG
        /// Whether `-BookwormsLiftLog YES` asks for the lift log, read once.
        private static let logsLift = UserDefaults.standard.bool(forKey: "BookwormsLiftLog")
        private var liftLog: [String] = []

        /// Simulator hook: with `-BookwormsLiftLog YES`, adds a line for each lift in a scene
        /// that holds still to `Library/Caches/Bookworms/lift-exit.csv`: the book's ID, how many
        /// books rest on it, how far it slides out from under them, how far it rises, whether it
        /// rises, slides, or draws them back, the milliseconds the plan took, and for each of
        /// them, how far it turns down, in radians, and is drawn back (see `BookExit`).
        private func logExit(_ exit: BookExit, id: Int, took: Duration) {
            guard Self.logsLift else { return }
            let url = URL.cachesDirectory.appending(path: "Bookworms/lift-exit.csv")
            let riders = exit.riders.map {
                String(format: "%.3f/%.3f", $0.fallen, simd_length($0.back))
            }
            let line = String(
                format: "%d,%d,%.3f,%.3f,%@,%.1f,%@", id, exit.riders.count,
                simd_length(exit.slide), exit.rise,
                exit.riders.isEmpty ? "rise" : exit.drawsBack ? "draw" : "slide",
                took / .milliseconds(1), riders.joined(separator: " "))
            let earlier =
                (try? String(contentsOf: url, encoding: .utf8))
                ?? "book,riders,slide,rise,way,ms,turns\n"
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (earlier + line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        /// Simulator hook: with `-BookwormsLiftLog YES`, logs the first 30 frames of each lift
        /// to `Library/Caches/Bookworms/lift-log.csv`: the lifted book's height, then each book
        /// the lift woke, by its order among them, with its height and velocity. It shows
        /// whether the books on the lifted one move with it as it rises.
        private func logLift(_ lifted: inout Lifted) {
            guard Self.logsLift, lifted.frames < 30 else { return }
            if lifted.frames == 0 { liftLog = ["frame,elapsed,book,y,vx,vy,vz"] }
            lifted.frames += 1
            for (index, book) in ([lifted.book] + lifted.riders).enumerated() {
                let velocity =
                    book.components[PhysicsMotionComponent.self]?.linearVelocity ?? .zero
                let values = [
                    book.position(relativeTo: root).y, velocity.x, velocity.y, velocity.z,
                ]
                liftLog.append(
                    "\(lifted.frames),\(String(format: "%.4f", lifted.elapsed)),\(index - 1),"
                        + values.map { String(format: "%.4f", $0) }.joined(separator: ","))
            }
            guard lifted.frames == 30 else { return }
            let url = URL.cachesDirectory.appending(path: "Bookworms/lift-log.csv")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? liftLog.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    #endif
}
