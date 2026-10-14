import RealityKit
import SwiftUI
import UIKit

/// The setting every 3D view shares: a wooden desk at night under a warm lamp.
///
/// A spotlight high over the reader's right shoulder lays a warm pool of light on the books,
/// lighting the covers, spines, and page edges that face the camera, and the table falls off
/// into the dark room outside the pool, which also hides the repeats of the table's texture.
/// An image-based light, a dim room drawn in code with the lamp's glow in it, lights the
/// shadows and gives the jackets' sheen something to reflect. Each lit entity receives it through
/// `light(_:)`. Dust motes drift through the beam while `setDust(true)`.
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
    /// A new emitter would simulate its 10-second warm-up in a single frame, which stalls the
    /// render for about a tenth of a second.
    func aim(pool center: SIMD3<Float>, radius: Float) {
        moveLamp(pool: center, radius: radius)
        if var motes = dust.components[ParticleEmitterComponent.self] {
            motes.emitterShapeSize = Self.dustSize(radius: radius)
            dust.components.set(motes)
        } else {
            dust.components.set(Self.dustMotes(radius: radius))
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
        dust.position = center + [0, 3.5, 0]
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
    /// motion the reader did not start.
    func setDust(_ enabled: Bool) {
        if enabled, dust.parent == nil {
            root.addChild(dust)
        } else if !enabled {
            dust.removeFromParent()
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

    /// Slow, faint motes, 2 to 4 mm across, in the beam over the middle of the pool, lit by
    /// the lamp. About 80 drift at a time, each for 6 to 10 seconds. They are small and faint
    /// enough not to show as discs when the camera zooms in close.
    private static func dustMotes(radius: Float) -> ParticleEmitterComponent {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.birthLocation = .volume
        emitter.emitterShapeSize = dustSize(radius: radius)
        emitter.speed = 0.03
        emitter.speedVariation = 0.03
        emitter.timing = .repeating(warmUp: 10, emit: .init(duration: 60))
        var motes = emitter.mainEmitter
        motes.birthRate = 10
        motes.lifeSpan = 8
        motes.lifeSpanVariation = 2
        motes.size = 0.03
        motes.sizeVariation = 0.01
        motes.opacityCurve = .gradualFadeInOut
        motes.color = .constant(.single(UIColor(red: 1, green: 0.9, blue: 0.75, alpha: 0.35)))
        motes.noiseStrength = 0.04
        motes.noiseScale = 0.6
        motes.noiseAnimationSpeed = 0.1
        motes.acceleration = [0, -0.004, 0]
        motes.isLightingEnabled = true
        motes.blendMode = .alpha
        emitter.mainEmitter = motes
        return emitter
    }

    /// The box the motes are born in over a pool of `radius`.
    private static func dustSize(radius: Float) -> SIMD3<Float> {
        [radius * 0.9, 5, radius * 0.9]
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
