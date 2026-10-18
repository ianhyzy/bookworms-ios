import RealityKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The setting every 3D view shares: a wooden desk at night under a warm lamp.
///
/// A spotlight high over the reader's right shoulder lays a warm pool of light on the books,
/// lighting the covers, spines, and page edges that face the camera, and the table falls off
/// into the dark room outside the pool, which also hides the repeats of the table's texture.
/// An image-based light, a dim room drawn in code with the lamp's glow in it, lights the
/// shadows and gives the jackets' sheen something to reflect. Each lit entity receives it through
/// `light(_:)`. Dust motes drift through the beam while `setDust(true)`, catching its light, or
/// fine, faint ones for a camera that films low among them (`setDust(_:fine:)`).
/// While a scene rests (`setSettled(_:)`), and under heat or in Low Power Mode
/// (`setReducesEffects(_:)`), no new motes drift in, and those in the beam fade out.
///
/// Scene units are decimeters, but RealityKit treats them as meters, so the lamp's intensity
/// grows with the square of its distance in those units to keep the pool equally bright.
///
/// The table reaches far past the pool, and its wood repeats every `tile` units, so a scene can
/// move its books and camera by whole tiles without the table showing any change (see
/// `DominoSetup.offset(of:aspect:)`). One stage can serve two scenes in turn: each puts `root`
/// under its own root while it shows (see `DeskScenes`).
@MainActor
final class DeskStage {
    /// The table, lights, and dust.
    let root = Entity()
    /// Holds the image-based light, which lit entities receive through `light(_:)`.
    let lighting = Entity()
    private let lamp = SpotLight()
    /// Holds the brighter copy of the room's light that `light(_:boost:)` gives.
    private let boosted = Entity()
    private let dust = Entity()
    /// Whether the dust shows, which Reduce Motion turns off, and whether its motes are the fine
    /// ones (see `setDust(_:fine:)`).
    private var showsDust = false
    private var finesDust = false
    /// Whether the stage saves power under heat or in Low Power Mode.
    private var reducesEffects = false
    /// Whether the scene rests, so it can pause on a still (see `setSettled(_:)`).
    private var isSettled = false
    private var isBuilt = false
    private var environment: Task<Void, Never>?
    /// The middle and radius of the lamp's pool of light on the table.
    private(set) var pool: (center: SIMD3<Float>, radius: Float) = (.zero, 1)

    /// The distance at which the table's wood texture repeats, in units.
    nonisolated static let tile: Float = 15
    /// The table's width and depth, in units: a whole number of `tile`s.
    nonisolated static let tableSize: Float = 180

    /// The lamp's color: an incandescent bulb's warm white, about 2700 K.
    static let lampColor = UIColor(red: 1, green: 0.78, blue: 0.55, alpha: 1)
    /// Where the lamp hangs from the pool's middle, in pool radii: toward the camera (+z), a
    /// little to its right (+x), and high above.
    nonisolated static let lampOffset = SIMD3<Float>(1.2, 4.6, 2.2)
    /// The room's light, built once and shared by every stage, including share images, and
    /// its intensity, as a power of 2.
    private static var room: Task<EnvironmentResource?, Never>?
    private static let roomIntensity: Float = 2.2

    init() {
        root.addChild(lighting)
    }

    /// Adds the table and the lamp, whose pool of light covers a circle of `radius` around
    /// `center` on the table, and starts building the room's light (see `lit`). Later calls
    /// do nothing; `aim(pool:radius:)` moves the pool.
    func build(pool center: SIMD3<Float>, radius: Float) {
        guard !isBuilt else { return }
        isBuilt = true
        environment = Task { [lighting] in
            guard let resource = await Self.roomLight() else { return }
            lighting.components.set(
                ImageBasedLightComponent(
                    source: .single(resource), intensityExponent: Self.roomIntensity))
        }
        root.addChild(makeTable())
        root.addChild(lamp)
        aim(pool: center, radius: radius)
    }

    /// Moves the lamp so its pool of light covers a circle of `radius` around `center` on the
    /// table, and spreads the dust over it. The table and the room's light stay as they are.
    ///
    /// Dust that already drifts keeps its motes and spreads over the new pool as they renew.
    func aim(pool center: SIMD3<Float>, radius: Float) {
        moveLamp(pool: center, radius: radius)
        if var motes = dust.components[ParticleEmitterComponent.self] {
            motes.emitterShapeSize = Self.dustSize(radius: radius)
            dust.components.set(motes)
        } else {
            var motes = Self.dustMotes(radius: radius)
            Self.dress(&motes.mainEmitter, fine: finesDust)
            motes.isEmitting = emitsDust
            dust.components.set(motes)
        }
    }

    /// Moves the lamp so its pool of light covers a circle of `radius` around `center`, as
    /// `aim(pool:radius:)` does, and moves the dust along without starting it over, for a pool
    /// that moves from frame to frame.
    func moveLamp(pool center: SIMD3<Float>, radius: Float) {
        pool = (center, radius)
        let placement = Self.lampPlacement(pool: center, radius: radius)
        lamp.light = SpotLightComponent(
            color: Self.lampColor, intensity: 7e6 * pow(placement.distance / 19, 2),
            innerAngleInDegrees: placement.innerAngle, outerAngleInDegrees: placement.outerAngle,
            attenuationRadius: placement.distance * 3)
        // The shadow map's depths end just past the pool's far side, where the dark table no
        // longer shows shadows. A bias of 2 is the least that keeps the books' faces free of
        // shadow acne, which smaller biases draw as stripes, and shadows still meet the books
        // where they touch the table.
        var shadow = SpotLightComponent.Shadow()
        shadow.depthBias = 2
        shadow.zNear = .fixed(2)
        shadow.zFar = .fixed(placement.distance + radius * 1.5)
        // A lamp shade's opening, about 15 cm across, softens the shadows' edges.
        shadow.lightSize = 1.5
        lamp.shadow = shadow
        lamp.look(at: placement.aim, from: placement.position, relativeTo: nil)
        // Over the beam's axis, which runs from the lamp to the pool's middle, at the dust's
        // middle height (see `dustSize`).
        dust.position = center + Self.lampOffset * (2 / Self.lampOffset.y)
    }

    /// Waits until the room's light reaches the scene, as a still image needs before it
    /// renders. `build(pool:radius:)` starts the light; before it, this returns at once.
    func lit() async { await environment?.value }

    /// Lets `entity` reflect the room and be lit by it.
    func light(_ entity: Entity) {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
    }

    /// Lights the parts of `entity` that the room lights, such as a book's model, with the
    /// room's light `boost` stops brighter, as a book held out of the lamp's beam needs to stay
    /// lit, or with the room's own light for no boost. One entity at a time can have a boost: a
    /// later call sets it for every entity it lights.
    func light(_ entity: Entity, boost: Float) {
        var source = lighting
        if boost > 0, var light = lighting.components[ImageBasedLightComponent.self] {
            light.intensityExponent = Self.roomIntensity + boost
            boosted.components.set(light)
            if boosted.parent == nil { root.addChild(boosted) }
            source = boosted
        }
        let receiver = ImageBasedLightReceiverComponent(imageBasedLight: source)
        func relight(_ entity: Entity) {
            if entity.components.has(ImageBasedLightReceiverComponent.self) {
                entity.components.set(receiver)
            }
            entity.children.forEach(relight)
        }
        relight(entity)
    }

    /// Gives the lamp `color`, such as a season's tint, or its usual `lampColor` for `nil`.
    func setLampColor(_ color: UIColor?) {
        lamp.light.color = color ?? Self.lampColor
    }

    /// Shows or hides the dust drifting through the lamp's beam. Reduce Motion hides it, as
    /// motion the reader did not start. `fine` motes, the same flecks about 1 to 2.5 mm long,
    /// faint, and lit by the lamp, suit a camera that films low among them, as the dominoes'
    /// Follow camera does, where a mote of the desk's that drifts near the lens shows as a
    /// large glowing fleck.
    /// Motes already drifting keep their look until they fade.
    func setDust(_ enabled: Bool, fine: Bool = false) {
        showsDust = enabled
        finesDust = fine
        updateDust()
    }

    /// Saves power while `reduces`, as Apple asks of apps under heat or in Low Power Mode: no
    /// new dust drifts into the beam. Turning it off lets the dust drift in again.
    func setReducesEffects(_ reduces: Bool) {
        guard reduces != reducesEffects else { return }
        reducesEffects = reduces
        updateDust()
    }

    /// Lets no new dust drift into the beam while the scene is `settled`, so the motes have
    /// faded out, within `longestMoteLife`, by the time a resting scene pauses on a still,
    /// which would hold motes frozen in the air. Turning it off lets the dust drift in again,
    /// each mote fading in as it starts.
    func setSettled(_ settled: Bool) {
        guard settled != isSettled else { return }
        isSettled = settled
        updateDust()
    }

    /// Whether new motes drift into the beam.
    private var emitsDust: Bool { !reducesEffects && !isSettled }

    /// Adds the dust while it shows and removes it otherwise, and keeps it emitting unless the
    /// stage saves power or the scene rests. An emitter that stops leaves its motes to fade out
    /// over their lives, and one that starts again fills the beam over a few seconds.
    private func updateDust() {
        if showsDust, dust.parent == nil {
            root.addChild(dust)
        } else if !showsDust {
            dust.removeFromParent()
        }
        if var motes = dust.components[ParticleEmitterComponent.self],
            motes.isEmitting != emitsDust || motes.mainEmitter.isLightingEnabled != finesDust
        {
            motes.isEmitting = emitsDust
            Self.dress(&motes.mainEmitter, fine: finesDust)
            dust.components.set(motes)
        }
    }

    /// Where the lamp stands for a pool of `radius` around `pool`, and where it points.
    ///
    /// It hangs high above the pool, toward the camera and a little to its right, about 61
    /// degrees up: it lights the faces that turn toward the camera, its shadows fall up and to
    /// the left of the books, where the camera sees them, and flat covers reflect it away from
    /// the camera, though covers that tilt toward the camera reflect it into view (see
    /// `BookFactory.finish`). Over the pile's pool it hangs above the camera, so above every book
    /// in view. It aims at the pool's middle. Full light spans the middle of the pool and fades
    /// out past its edge. Angles are the cone's full angles, in degrees.
    nonisolated static func lampPlacement(pool: SIMD3<Float>, radius: Float) -> (
        position: SIMD3<Float>, aim: SIMD3<Float>, distance: Float, innerAngle: Float,
        outerAngle: Float
    ) {
        let position = pool + lampOffset * radius
        let distance = simd_distance(position, pool)
        let edge = 2 * atan(radius / distance) * 180 / .pi
        return (position, pool, distance, edge * 0.7, edge * 1.5)
    }

    private func makeTable() -> Entity {
        var material = BookFactory.surface(
            nil, tint: UIColor(red: 0.6, green: 0.44, blue: 0.32, alpha: 1), roughness: 0.62,
            specular: 0.3)
        // A thin satin varnish, which gives the wood a soft sheen without a glare.
        material.clearcoat = .init(floatLiteral: 0.2)
        material.clearcoatRoughness = .init(floatLiteral: 0.45)
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
            // One 1024-pixel tile spans `tile` units (1.5 meters) of the table.
            let tiles = Self.tableSize / Self.tile
            material.textureCoordinateTransform = .init(scale: [tiles, tiles])
        }
        let size = Self.tableSize
        let table = ModelEntity(
            mesh: .generatePlane(width: size, depth: size), materials: [material])
        table.components.set(
            CollisionComponent(shapes: [
                ShapeResource.generateBox(width: size, height: 2, depth: size)
                    .offsetBy(translation: [0, -1, 0])
            ]))
        table.components.set(
            PhysicsBodyComponent(
                massProperties: .default,
                material: .generate(staticFriction: 0.7, dynamicFriction: 0.55, restitution: 0.1),
                mode: .static))
        table.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: true))
        light(table)
        return table
    }

    /// The longest a mote drifts, in seconds: short enough that a scene that comes to rest
    /// shows its dust for several seconds before the motes must fade for its still
    /// (`BookPileScene`'s `dustStop`).
    nonisolated static let longestMoteLife: Double = 3

    /// Slow motes in the beam around its axis, over the middle of the pool. About 140 drift at
    /// a time, each fading in and out over 2 to `longestMoteLife` seconds, born at any angle
    /// and turning slowly, up to about 30 degrees a second either way, as specks of dust
    /// tumble. The emitter has no warm-up, which a new emitter simulates in a single frame,
    /// stalling the render, so the motes fill the beam over their first few seconds.
    /// `dress(_:fine:)` sets their look.
    private static func dustMotes(radius: Float) -> ParticleEmitterComponent {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.birthLocation = .volume
        emitter.emitterShapeSize = dustSize(radius: radius)
        emitter.speed = 0.03
        emitter.speedVariation = 0.03
        emitter.timing = .repeating(emit: .init(duration: 60))
        var motes = emitter.mainEmitter
        motes.birthRate = 56
        motes.lifeSpanVariation = 0.5
        motes.lifeSpan = longestMoteLife - motes.lifeSpanVariation
        motes.opacityCurve = .gradualFadeInOut
        motes.noiseStrength = 0.04
        motes.noiseScale = 0.6
        motes.noiseAnimationSpeed = 0.1
        motes.acceleration = [0, -0.004, 0]
        motes.billboardMode = .billboard
        motes.angleVariation = .pi
        motes.angularSpeedVariation = 0.5
        emitter.mainEmitter = motes
        return emitter
    }

    /// Gives `motes` the desk's look: irregular flecks (`flecks`) about 3 to 6 mm long and
    /// half as wide or less, in cells 5 to 9 mm across, specks of the lamp's warm light that
    /// brighten what lies behind them, as dust catching a beam does. `fine` motes are the same
    /// flecks about 1 to 2.5 mm long, faint, and lit by the lamp, so they show only in its
    /// beam, and stay small and faint enough not to show as discs when a camera passes close
    /// to them.
    private static func dress(_ motes: inout ParticleEmitterComponent.ParticleEmitter, fine: Bool) {
        motes.size = fine ? 0.03 : 0.07
        motes.sizeVariation = fine ? 0.01 : 0.02
        motes.color = .constant(
            .single(
                fine
                    ? UIColor(red: 1, green: 0.9, blue: 0.75, alpha: 0.35)
                    : UIColor(red: 1, green: 0.8, blue: 0.52, alpha: 0.8)))
        motes.isLightingEnabled = fine
        motes.blendMode = fine ? .alpha : .additive
        motes.image = flecks
        var cells = ParticleEmitterComponent.ParticleEmitter.ImageSequence()
        cells.rowCount = fleckColumns
        cells.columnCount = fleckColumns
        // Each mote keeps one fleck, picked at random from the sheet's cells as it is born.
        let middle = fleckColumns * fleckColumns / 2
        cells.initialFrame = middle
        cells.initialFrameVariation = middle
        cells.frameRate = 0
        motes.imageSequence = cells
    }

    /// The columns and rows of `flecks`' grid.
    private static let fleckColumns = 3

    /// The motes' images: a sheet of `fleckColumns` by `fleckColumns` cells, 32 pixels each,
    /// with one dust fleck in each. A fleck is four or five overlapping soft blobs of different
    /// sizes, strung along a slightly bent line and pushed a little to either side, so it is
    /// lumpy and longer than it is wide, with soft edges: some are compact flakes, others
    /// fibers that span most of their cell. A fixed seed draws the same flecks every launch.
    private static let flecks: TextureResource? = {
        let cell: CGFloat = 32
        let side = cell * CGFloat(fleckColumns)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var random = BookAnalyzer.SeededGenerator(seed: 0xD057)
        func jitter(_ range: CGFloat) -> CGFloat { .random(in: -range...range, using: &random) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { context in
                let colors = [0.95, 0.6, 0].map { UIColor(white: 1, alpha: $0).cgColor }
                guard
                    let blob = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                        locations: [0, 0.45, 1])
                else { return }
                let graphics = context.cgContext
                for index in 0..<(fleckColumns * fleckColumns) {
                    let middle = CGPoint(
                        x: (CGFloat(index % fleckColumns) + 0.5) * cell,
                        y: (CGFloat(index / fleckColumns) + 0.5) * cell)
                    let axis = jitter(.pi)
                    let bend = jitter(0.5)
                    // Half the distance between the end blobs' middles: compact flakes to
                    // long fibers.
                    let length = 4.25 + jitter(1.75)
                    let count = 4 + index % 2
                    // No blob reaches past 16 pixels from the cell's middle, so none spills
                    // into a neighbor's cell.
                    for part in 0..<count {
                        // From -1 at one end of the fleck to 1 at the other.
                        let along = CGFloat(part) / CGFloat(count - 1) * 2 - 1
                        let turn = axis + bend * along
                        let reach = length * along + jitter(1)
                        let aside = jitter(2)
                        graphics.saveGState()
                        graphics.translateBy(
                            x: middle.x + cos(turn) * reach - sin(turn) * aside,
                            y: middle.y + sin(turn) * reach + cos(turn) * aside)
                        graphics.rotate(by: turn + jitter(0.8))
                        graphics.scaleBy(x: 5 + jitter(1.8), y: 3.6 + jitter(1))
                        graphics.drawRadialGradient(
                            blob, startCenter: .zero, startRadius: 0, endCenter: .zero,
                            endRadius: 1, options: [])
                        graphics.restoreGState()
                    }
                }
            }
        return image.cgImage.flatMap {
            try? TextureResource(image: $0, options: .init(semantic: .color))
        }
    }()

    /// The box the motes are born in over a pool of `radius`: from half a unit to 3.5 units
    /// above the table, and 0.7 of the pool's radius across, so that, about the beam's axis,
    /// even its corners lie in the beam's full light and no mote glows where the beam would
    /// leave it dark.
    private static func dustSize(radius: Float) -> SIMD3<Float> {
        [radius * 0.7, 3, radius * 0.7]
    }

    /// Builds the room's light once, the first time a stage needs it.
    private static func roomLight() async -> EnvironmentResource? {
        let task =
            room
            ?? Task {
                guard let image = roomImage() else { return nil }
                return try? await EnvironmentResource(equirectangular: image, options: .init())
            }
        room = task
        return await task.value
    }

    /// The lamp's direction from the pool in `roomImage`'s degrees: its azimuth, where 180 is
    /// toward the camera and less turns toward its right, and its elevation.
    private nonisolated static var lampDirection: (azimuth: CGFloat, elevation: CGFloat) {
        let offset = SIMD3<Double>(lampOffset)
        return (
            180 - atan2(offset.x, offset.z) * 180 / .pi,
            atan2(offset.y, (offset.x * offset.x + offset.z * offset.z).squareRoot()) * 180 / .pi
        )
    }

    /// A warm, dim room at night as a 512 × 256 equirectangular image, for image-based light:
    /// the lamp's bright shade high behind the viewer, where `lampPlacement` hangs it, its glow
    /// on the ceiling and on the wall and bookshelves behind the viewer, which light the faces
    /// that turn toward the camera, a moonlit window to the right, and a darker floor. Flat
    /// covers reflect the dim wall above the table's far side, so the room lays no haze over
    /// dark covers.
    ///
    /// The image's middle column faces -z, away from the default camera, and x grows to the
    /// right, as RealityKit maps equirectangular environments. Its left and right edges both
    /// face +z, toward the viewer, so shapes there are drawn at both.
    nonisolated private static func roomImage() -> CGImage? {
        let size = CGSize(width: 512, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        func spot(azimuth: CGFloat, elevation: CGFloat) -> CGPoint {
            // Azimuth in degrees from -z toward +x, elevation in degrees above the horizon.
            CGPoint(
                x: (0.5 + azimuth / 360) * size.width, y: (90 - elevation) / 180 * size.height)
        }
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                let cg = context.cgContext
                let space = CGColorSpaceCreateDeviceRGB()
                func gradient(_ colors: [UIColor], _ locations: [CGFloat]) -> CGGradient? {
                    CGGradient(
                        colorsSpace: space, colors: colors.map(\.cgColor) as CFArray,
                        locations: locations)
                }
                // Draws a radial glow around a point behind the viewer, and again a full turn
                // around, so it wraps across the image's edges.
                func glow(
                    _ colors: [UIColor], azimuth: CGFloat, elevation: CGFloat, radius: CGFloat
                ) {
                    guard let glow = gradient(colors, [0, 1]) else { return }
                    for turn: CGFloat in [-360, 0] {
                        let center = spot(azimuth: azimuth + turn, elevation: elevation)
                        cg.drawRadialGradient(
                            glow, startCenter: center, startRadius: 0, endCenter: center,
                            endRadius: radius, options: [])
                    }
                }
                // Walls: a little warmer and lighter toward the ceiling, dark toward the floor.
                if let walls = gradient(
                    [
                        UIColor(red: 0.09, green: 0.065, blue: 0.045, alpha: 1),
                        UIColor(red: 0.05, green: 0.037, blue: 0.028, alpha: 1),
                        UIColor(red: 0.018, green: 0.014, blue: 0.012, alpha: 1),
                    ], [0, 0.5, 1])
                {
                    cg.drawLinearGradient(
                        walls, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
                // The lamp's light on the wall behind the viewer.
                glow(
                    [
                        UIColor(red: 0.62, green: 0.44, blue: 0.27, alpha: 1),
                        UIColor(red: 0.3, green: 0.2, blue: 0.12, alpha: 0),
                    ], azimuth: 165, elevation: 25, radius: 120)
                // Bookshelves on that wall: spines of muted colors, lit by the lamp.
                var seed: UInt32 = 0x2545_F491
                for shelf in 0..<3 {
                    let top = spot(azimuth: 0, elevation: 32 - CGFloat(shelf) * 14).y
                    var x = spot(azimuth: 125, elevation: 0).x
                    let end = spot(azimuth: 235, elevation: 0).x
                    while x < end {
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        let width = 3 + CGFloat(seed >> 28)
                        let tone = 0.12 + CGFloat((seed >> 20) & 15) / 15 * 0.14
                        UIColor(red: tone * 1.3, green: tone, blue: tone * 0.75, alpha: 0.85)
                            .setFill()
                        let height = 26 - CGFloat((seed >> 12) & 7)
                        let left = x.truncatingRemainder(dividingBy: size.width)
                        cg.fill(CGRect(x: left, y: top + 26 - height, width: width, height: height))
                        x += width + 0.5
                    }
                }
                // A window to the right, faintly moonlit.
                let window = spot(azimuth: 80, elevation: 38)
                UIColor(red: 0.1, green: 0.13, blue: 0.19, alpha: 1).setFill()
                cg.fill(CGRect(x: window.x, y: window.y, width: 46, height: 50))
                // The lamp's glow on the ceiling around it, then its bright shade.
                let lamp = Self.lampDirection
                glow(
                    [
                        UIColor(red: 0.55, green: 0.38, blue: 0.22, alpha: 0.75),
                        UIColor(red: 0.2, green: 0.13, blue: 0.08, alpha: 0),
                    ], azimuth: lamp.azimuth, elevation: lamp.elevation, radius: 90)
                glow(
                    [
                        UIColor(red: 1, green: 0.9, blue: 0.75, alpha: 1),
                        UIColor(red: 1, green: 0.75, blue: 0.5, alpha: 0),
                    ], azimuth: lamp.azimuth, elevation: lamp.elevation, radius: 16)
            }
            .cgImage
    }
}
