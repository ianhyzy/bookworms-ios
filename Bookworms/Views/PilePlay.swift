import RealityKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// How the pile follows the phone's tilt, which **Tilt** in the desk's options menu sets.
/// Throwing books by hand is the scene's main play, so tilt starts **Off**.
enum PileTilt: String, CaseIterable, Identifiable {
    /// The table stays level, and the pile reads no motion, so shakes do nothing either.
    case off
    /// Tilting tips the table a little, from how the phone was held when tilting began.
    case table
    /// The pile is a closed box fixed to the phone, under the screen's glass, and real gravity
    /// moves the books (see `PileBox`).
    case box

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .table: "Tip the table"
        case .box: "Phone is the box"
        }
    }
}

/// How a finger picks up, carries, and throws a book on the desk (see `BookPileScene.pickUp`).
enum PileCarry {
    /// How long a finger rests on a book before it picks the book up. A finger that lifts
    /// sooner taps the book instead.
    static let holdDelay = Duration.milliseconds(250)
    /// How far, in points, a finger can move before the hold and still pick up or tap.
    static let slop: CGFloat = 10
    /// How high a held book rides over what lies under it: 8 cm at the scene's scale.
    static let lift: Float = 0.8
    /// The fastest a thrown book flies across the desk, in units a second: 3 m/s at the scene's
    /// scale. A hard flick reaches it, and the walls still stop the book.
    static let maximumThrowSpeed: Float = 30

    /// `rotation` turned the least way to lie flat, front or back cover up, whichever is
    /// nearer, keeping the book's turn on the table.
    static func level(_ rotation: simd_quatf) -> simd_quatf {
        let cover = rotation.act([0, 0, 1])
        return simd_quatf(from: cover, to: cover.y < 0 ? [0, -1, 0] : [0, 1, 0]) * rotation
    }

    /// The velocity of a book let go while the finger moves at `finger` across the desk:
    /// the finger's speed, at most `maximumThrowSpeed`, tossed up by a fifth of it, so the
    /// book flies in a low arc instead of skimming the books under it.
    static func throwVelocity(_ finger: SIMD3<Float>) -> SIMD3<Float> {
        var across = SIMD3(finger.x, 0, finger.z)
        let speed = simd_length(across)
        if speed > maximumThrowSpeed { across *= maximumThrowSpeed / speed }
        return across + [0, min(speed, maximumThrowSpeed) / 5, 0]
    }

    /// The rotation from `current` to `target` the shorter way, as an axis scaled by the angle
    /// in radians: the angular velocity that turns a body there in one second.
    static func turn(from current: simd_quatf, to target: simd_quatf) -> SIMD3<Float> {
        var change = target * current.inverse
        if change.real < 0 { change = simd_quatf(vector: -change.vector) }
        let sine = simd_length(change.imag)
        guard sine > 1e-6 else { return change.imag * 2 }
        return change.imag / sine * 2 * atan2(sine, change.real)
    }
}

/// How a held book swings under the finger, as if it hung from the fingertip on its top cover.
///
/// When the finger speeds up, the book's middle, below the fingertip, lags behind, so the
/// book leans its leading edge down; it swings back past level and settles once the finger
/// moves steadily. Slowing down leans it the other way. The pendulum is stiff, so a brisk drag
/// tips the book by several degrees, never more than `maximumTilt`.
struct PileSwing {
    /// The swing's angular frequency, in radians a second: about 1.5 swings a second.
    static let frequency: Float = 10
    /// How fast a swing dies away, per second: it fades to a fifth in about half a second.
    static let damping: Float = 6
    /// The lean, in radians, for each unit a second squared of steady acceleration.
    static let sensitivity: Float = 0.002
    /// The most the book leans, in radians (20 degrees).
    static let maximumTilt: Float = 0.35

    /// Where the book's up axis leans, across the table as x and z, in radians before
    /// `maximumTilt` softly caps it.
    private(set) var lean = SIMD2<Float>.zero
    private var rate = SIMD2<Float>.zero

    /// Advances the swing by `deltaTime` seconds while the fingertip accelerates at
    /// `acceleration` across the table, as x and z.
    mutating func advance(acceleration: SIMD2<Float>, by deltaTime: Float) {
        let stiffness = Self.frequency * Self.frequency
        rate +=
            (stiffness * (Self.sensitivity * acceleration - lean) - Self.damping * rate)
            * deltaTime
        lean += rate * deltaTime
    }

    /// The book's lean as a rotation that tips its up axis toward `lean`.
    var tilt: simd_quatf {
        let amount = simd_length(lean)
        guard amount > 1e-5 else { return simd_quatf(angle: 0, axis: [0, 1, 0]) }
        let toward = SIMD3(lean.x, 0, lean.y) / amount
        return simd_quatf(
            angle: Self.maximumTilt * tanh(amount / Self.maximumTilt),
            axis: simd_normalize(simd_cross([0, 1, 0], toward)))
    }
}

extension PileLayout {
    /// The least user acceleration, in g, that counts as a hard shake. It assumes that walking
    /// and tapping stay below it, which a device check must confirm.
    static let shakeThreshold: Float = 1.8
    /// The least time from one shake's throw to the next, in seconds, so one jolt that spans
    /// several motion samples throws once.
    static let shakeRest: TimeInterval = 0.3
    /// The least time from one period's first wave to the next period's, when the pile drops
    /// period by period, so each period's name can be read.
    static let periodInterval = Duration.milliseconds(1400)

    /// The scene's gravity in **Phone is the box** for a device gravity reading, in g in the
    /// device's axes: x toward the screen's right, y toward its top, and z out of the glass.
    ///
    /// The scene is fixed to the phone as the camera is, so the reading maps into the scene
    /// through `camera`, the camera's rotation, at full strength in any direction. Held at the
    /// camera's pitch, the table is level; upright, books fall toward the bottom of the screen;
    /// face down, they fall onto the glass.
    static func boxGravity(device: SIMD3<Double>, camera: simd_quatf) -> SIMD3<Float> {
        camera.act(SIMD3<Float>(device)) * gravity
    }

    /// The velocity a hard shake gives the books, or `nil` for anything gentler than
    /// `shakeThreshold`. `acceleration` is the user acceleration in g in the device's axes,
    /// `camera` the camera's rotation, and `up` the unit vector against the scene's gravity.
    ///
    /// The books keep still while the phone jolts, so they move against the jolt relative to
    /// the table, and they hop up from it. Harder shakes throw faster, up to 20 units per second.
    static func shakeKick(acceleration: SIMD3<Double>, camera: simd_quatf, up: SIMD3<Float>)
        -> SIMD3<Float>?
    {
        let jolt = camera.act(SIMD3<Float>(acceleration))
        let strength = simd_length(jolt)
        guard strength >= shakeThreshold else { return nil }
        let speed = min(20, 8 + (strength - shakeThreshold) * 6)
        return (-jolt / strength + up * 0.6) * speed
    }

    /// The books in drop order for a drop period by period: the chart columns of `frame` that
    /// have books (see `YearInBooks.columns`), earliest first, each with its books in finish
    /// order. A year drops by month, a month by week, and every book by year. Books that
    /// `frame` leaves out, such as unfinished books under **All books**, drop last.
    static func periods(_ books: [CloudBook], frame: TimeFrame) -> [PilePeriod] {
        let finished = frame.books(in: books)
            .sorted { ($0.finished ?? "", $0.id) < ($1.finished ?? "", $1.id) }
        let columns = YearInBooks.columns(for: frame, books: finished).filter { !$0.books.isEmpty }
        var periods = columns.enumerated()
            .map { index, column in
                PilePeriod(
                    span: column.span,
                    season: PileSeasons.season(of: column.span, index: index, count: columns.count),
                    books: column.books)
            }
        let rest = books.filter { !frame.contains($0) }
        if !rest.isEmpty { periods.append(PilePeriod(span: nil, season: nil, books: rest)) }
        return periods
    }
}

/// Books that drop together when the pile drops period by period.
struct PilePeriod: Equatable {
    /// The period, or `nil` for books outside the frame, which drop without a name.
    let span: YearInBooks.Column.Span?
    /// How far through a year the period falls, from 0 to 1, which sets the lamp's color; `nil`
    /// keeps the lamp's usual light.
    let season: Float?
    let books: [CloudBook]
}

/// The lamp's colors through the seasons, for a drop period by period.
enum PileSeasons {
    static let winter = SIMD3<Float>(0.56, 0.72, 1)
    static let summer = SIMD3<Float>(1, 0.8, 0.42)
    static let autumn = SIMD3<Float>(1, 0.56, 0.24)

    /// The lamp's color `season` of the way through a year: winter blue until mid-January,
    /// warming through a pale spring to summer gold in mid-July, then to autumn amber by
    /// mid-October, where it stays through December.
    static func lampColor(season: Float) -> SIMD3<Float> {
        let keys: [(at: Float, color: SIMD3<Float>)] = [
            (0.5 / 12, winter), (6.5 / 12, summer), (9.5 / 12, autumn),
        ]
        guard let after = keys.firstIndex(where: { season < $0.at }) else { return autumn }
        guard after > 0 else { return winter }
        let (start, end) = (keys[after - 1], keys[after])
        return simd_mix(
            start.color, end.color, SIMD3(repeating: (season - start.at) / (end.at - start.at)))
    }

    /// Where `span` falls in a year: a month's middle, a week's middle within its month, or,
    /// for the year at `index` of `count` years, its place in the run, so a lifetime runs from
    /// winter to autumn.
    static func season(of span: YearInBooks.Column.Span, index: Int, count: Int) -> Float {
        switch span {
        case .month(let month): (Float(month) - 0.5) / 12
        case .days(let days, let month):
            (Float(month - 1) + Float(days.lowerBound + days.upperBound) / 62) / 12
        case .year: (Float(index) + 0.5) / Float(max(count, 1))
        }
    }
}

/// The closed box of **Phone is the box**: what the default camera sees between the bars, from
/// the table up to a pane of glass parallel to the screen, `glassDepth` units in front of the
/// camera.
///
/// Its sides are the planes through the camera along the bars' edges and the screen's sides,
/// so books inside it stay on screen, and books that fall onto the glass lie flat against it.
/// The pile's walls still stand, so the books stay inside both. The box fits only the camera
/// it was built with, so the scene keeps the view from turning while it is in use.
struct PileBox {
    /// The faces other than the table, each as its four corners: the glass, then the sides.
    let faces: [[SIMD3<Float>]]
    /// Each face's plane, in `faces` order, as a unit normal pointing into the box and an
    /// offset: a point `p` is inside when `simd_dot(normal, p) >= offset` for each plane. The
    /// table has no plane here: its own collider keeps books above it, and a book lying on it
    /// sits closer to it than any useful margin.
    let planes: [(normal: SIMD3<Float>, offset: Float)]

    /// Fits the box to what `camera` sees between `safeTop` and `safeBottom`, as normalized
    /// device y coordinates, in a view of width-to-height `aspect`, a little inside the edges.
    init?(
        aspect: Float, safeTop: Float, safeBottom: Float, glassDepth: Float = 20,
        camera: PileCamera = PileCamera()
    ) {
        let inset: Float = 0.04
        let forward = camera.rotation.act([0, 0, -1])
        var glass: [SIMD3<Float>] = []
        var table: [SIMD3<Float>] = []
        // Clockwise from the top left, as the screen shows them.
        for corner: SIMD2<Float> in [
            [-1 + inset, safeTop - inset], [1 - inset, safeTop - inset],
            [1 - inset, safeBottom + inset], [-1 + inset, safeBottom + inset],
        ] {
            let ray = camera.ray(ndc: corner, aspect: aspect)
            guard let floor = PileCamera.intersect(ray, height: 0) else { return nil }
            glass.append(ray.origin + ray.direction * glassDepth / simd_dot(ray.direction, forward))
            table.append(floor)
        }
        let sides = (0..<4)
            .map { index -> [SIMD3<Float>] in
                let next = (index + 1) % 4
                return [glass[index], glass[next], table[next], table[index]]
            }
        let middle: SIMD3<Float> = (glass + table).reduce(.zero, +) / 8
        faces = [glass] + sides
        planes =
            faces.map { face in
                var normal = simd_normalize(simd_cross(face[1] - face[0], face[3] - face[0]))
                if simd_dot(normal, middle - face[0]) < 0 { normal = -normal }
                return (normal, simd_dot(normal, face[0]))
            }
    }

    /// Fits the box between the bars that cover `viewport`'s edges.
    init?(viewport: PileViewport, glassDepth: Float = 20) {
        let height = Float(viewport.size.height)
        guard viewport.size.width > 0, height > 0 else { return nil }
        self.init(
            aspect: Float(viewport.size.width) / height,
            safeTop: 1 - 2 * Float(viewport.insets.top) / height,
            safeBottom: -1 + 2 * Float(viewport.insets.bottom) / height, glassDepth: glassDepth)
    }

    /// Whether `point` lies inside the glass and the sides, at least `margin` from each.
    func contains(_ point: SIMD3<Float>, margin: Float) -> Bool {
        planes.allSatisfy { simd_dot($0.normal, point) >= $0.offset + margin }
    }

    /// `point` moved inside the glass and the sides, about `margin` from them, by pushing it
    /// back across each face it is outside of. A few passes settle a point near a corner.
    func clamp(_ point: SIMD3<Float>, margin: Float) -> SIMD3<Float> {
        var point = point
        for _ in 0..<4 {
            for plane in planes {
                let depth = simd_dot(plane.normal, point) - plane.offset - margin
                if depth < 0 { point -= plane.normal * depth }
            }
        }
        return point
    }

    /// Static walls behind every face but the table, in collision group `group`. Each is a
    /// slab 2 units thick, a little larger than its face so neighbors close the corners.
    @MainActor func makeWalls(group: CollisionGroup) -> Entity {
        let walls = Entity()
        let material = PhysicsMaterialResource.generate(
            staticFriction: 0.1, dynamicFriction: 0.1, restitution: 0.3)
        for (face, plane) in zip(faces, planes) {
            let middle = face.reduce(.zero, +) / 4
            let inner = face.map { middle + ($0 - middle) * 1.1 }
            let wall = Entity()
            wall.components.set(
                CollisionComponent(
                    shapes: [.generateConvex(from: inner + inner.map { $0 - plane.normal * 2 })],
                    filter: CollisionFilter(group: group, mask: .all)))
            wall.components.set(
                PhysicsBodyComponent(massProperties: .default, material: material, mode: .static))
            walls.addChild(wall)
        }
        return walls
    }
}

/// The name of each period glowing on the table as its books fall, and the lamp's color for its
/// season, for a drop period by period.
///
/// One label shows at a time: it fades in, holds, and fades out over `glowDuration`, drawn over
/// the books so the pile cannot hide it, and its texture is released once it fades. The lamp
/// eases to each period's color and holds it until the next period, and after the last
/// period's glow it returns to its usual light. `advance` reports each new lamp color.
@MainActor
final class PileCalendar {
    /// The label, which the scene adds to its root. Hidden between glows.
    let label = ModelEntity()

    private static let glowDuration: Float = 1.6
    private static let resting: SIMD3<Float> = {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        DeskStage.lampColor.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return SIMD3(Float(red), Float(green), Float(blue))
    }()

    /// About two thirds of the view's width where the label lies, at the texture's aspect.
    private lazy var plane = MeshResource.generatePlane(width: 6.4, height: 2)
    private var glow: (elapsed: Float, isLast: Bool)?
    private var lamp = PileCalendar.resting
    private var target = PileCalendar.resting

    init() {
        label.isEnabled = false
        // A glow casts no shadow, and one from the lamp would darken the table under the label.
        label.components.set(DynamicLightShadowComponent(castsShadow: false))
    }

    /// The label for a period named `text` in `season`'s color, for `show`. The image renders
    /// off the main actor, so prepare it before the period's books fall.
    static func texture(_ text: String, season: Float?) async -> TextureResource? {
        guard let image = await image(text, color: season.map(PileSeasons.lampColor) ?? resting)
        else { return nil }
        return try? await TextureResource(image: image, options: .init(semantic: .color))
    }

    /// Starts a period's glow with `texture` (see `texture(_:season:)`), flat on the table about
    /// a third of the way from the middle of `camera`'s view to its bottom edge and facing it,
    /// and eases the lamp toward `season`'s color, or its usual light for `nil`. `isLast`
    /// returns the lamp to its usual light once this glow ends. Without a texture, the glow
    /// keeps its time with the label hidden.
    func show(
        _ texture: TextureResource?, season: Float?, isLast: Bool, facing camera: PileCamera
    ) {
        target = season.map(PileSeasons.lampColor) ?? Self.resting
        glow = (0, isLast)
        guard let texture else { return hide() }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.readsDepth = false
        label.model = ModelComponent(mesh: plane, materials: [material])
        // Zooming scales the camera's distance about its target, so scaling the label's offset
        // and size by the same factor keeps it where, and as large as, the default camera
        // shows it.
        let turn = simd_quatf(angle: camera.yaw, axis: [0, 1, 0])
        label.transform = Transform(
            scale: SIMD3(repeating: 1 / camera.zoom),
            rotation: turn * simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]),
            translation: camera.target + turn.act([0, 0.03, 4 / camera.zoom]))
        label.components.set(OpacityComponent(opacity: 0))
        label.isEnabled = true
    }

    /// Whether a period's name glows on the table.
    var isGlowing: Bool { glow != nil }

    /// Ends the glow at once, as its end would, such as when a book lifts toward its details,
    /// where the label would show over the book.
    func endGlow() {
        if glow?.isLast == true { target = Self.resting }
        glow = nil
        hide()
    }

    /// Hides the label and gives the lamp its usual light at once.
    func reset() {
        glow = nil
        hide()
        lamp = Self.resting
        target = Self.resting
    }

    /// Hides the label and releases its texture.
    private func hide() {
        label.isEnabled = false
        label.model = nil
    }

    /// Advances the glow and the lamp's easing by `deltaTime` seconds, and returns the lamp's
    /// new color when it changed.
    func advance(by deltaTime: Float) -> UIColor? {
        if var glow {
            glow.elapsed += deltaTime
            let fade = min(1, glow.elapsed / 0.25, (Self.glowDuration - glow.elapsed) / 0.5)
            label.components.set(OpacityComponent(opacity: max(0, fade)))
            if glow.elapsed >= Self.glowDuration {
                hide()
                if glow.isLast { target = Self.resting }
                self.glow = nil
            } else {
                self.glow = glow
            }
        }
        guard lamp != target else { return nil }
        lamp += (target - lamp) * min(1, deltaTime * 3)
        if simd_distance(lamp, target) < 0.004 { lamp = target }
        return UIColor(
            red: CGFloat(lamp.x), green: CGFloat(lamp.y), blue: CGFloat(lamp.z), alpha: 1)
    }

    /// `text` in New York, white tinged with `color`, glowing in it over a soft dark halo that
    /// keeps it legible on bright covers, on a clear 1024 × 320 image, about 1.3 MB of GPU
    /// memory. Long names shrink to fit.
    @concurrent nonisolated private static func image(_ text: String, color: SIMD3<Float>)
        async -> CGImage?
    {
        let size = CGSize(width: 1024, height: 320)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let tint = UIColor(
            red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        let face = simd_mix(color, .one, SIMD3(repeating: 0.75))
        let base = UIFont.systemFont(ofSize: 150, weight: .semibold)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        #if os(macOS)
            var font = UIFont(descriptor: descriptor, size: 150) ?? base
        #else
            var font = UIFont(descriptor: descriptor, size: 150)
        #endif
        let room = size.width - 140
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        if width > room { font = font.withSize(150 * room / width) }
        let string = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: UIColor(
                    red: CGFloat(face.x), green: CGFloat(face.y), blue: CGFloat(face.z), alpha: 1),
            ])
        let bounds = string.size()
        let origin = CGPoint(
            x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2)
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                // The dark halo first, then a wide and a tight glow, each under the text.
                let layers: [(color: UIColor, blur: CGFloat)] = [
                    (.black.withAlphaComponent(0.55), 60), (tint.withAlphaComponent(0.9), 28),
                    (tint, 6),
                ]
                for (color, blur) in layers {
                    context.cgContext.setShadow(offset: .zero, blur: blur, color: color.cgColor)
                    string.draw(at: origin)
                }
            }
            .cgImage
    }
}
