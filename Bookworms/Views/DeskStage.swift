import RealityKit
import SwiftUI
import UIKit

/// The setting every 3D view shares: a wooden desk at night under a warm desk lamp.
///
/// A spotlight from above the pool's far side lays a warm pool of light on the books, with
/// soft shadows, and the table falls off into the dark room outside it, which also hides the
/// repeats of the table's texture. An image-based light, a dim room drawn in code with the
/// lamp's glare in it, lights the shadows and gives glossy jackets something to reflect. Each lit entity receives it through `light(_:)`. Dust motes drift through the beam
/// while `setDust(true)`.
///
/// Scene units are decimeters, but RealityKit treats them as meters, so the lamp's intensity
/// grows with the square of its distance in those units to keep the pool equally bright.
@MainActor
final class DeskStage {
    /// The table, lights, and dust.
    let root = Entity()
    /// Holds the image-based light, which lit entities receive through `light(_:)`.
    let lighting = Entity()
    private let dust = Entity()
    private var isBuilt = false

    /// The lamp's color: an incandescent bulb's warm white, about 2700 K.
    static let lampColor = UIColor(red: 1, green: 0.78, blue: 0.55, alpha: 1)

    init() {
        root.addChild(lighting)
    }

    /// Adds the table and the lamp, whose pool of light covers a circle of `radius` around
    /// `center` on the table. Later calls do nothing.
    func build(pool center: SIMD3<Float>, radius: Float) {
        guard !isBuilt else { return }
        isBuilt = true
        if let image = Self.room(),
            let resource = try? EnvironmentResource(equirectangular: image, options: .init())
        {
            lighting.components.set(
                ImageBasedLightComponent(
                    source: .single(resource), intensityExponent: 1.4))
        }
        root.addChild(makeTable())
        let placement = Self.lampPlacement(pool: center, radius: radius)
        let lamp = SpotLight()
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
        root.addChild(lamp)
        dust.components.set(Self.dustMotes(radius: radius))
        dust.position = center + [0, 4.5, 0]
    }

    /// Lets `entity` reflect the room and be lit by it.
    func light(_ entity: Entity) {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
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

    /// Where the lamp stands for a pool of `radius` around `pool`, and where it points: above
    /// and a little left of the pool's far side, about 66 degrees up, where glossy covers lying
    /// flat reflect it toward the default camera. It aims a tenth of the way toward the near
    /// side, which is farther from it, to even out the pool. The pool's edge lies inside the
    /// cone's outer angle, and full light spans its middle. Angles are the
    /// cone's full angles, in degrees.
    nonisolated static func lampPlacement(pool: SIMD3<Float>, radius: Float) -> (
        position: SIMD3<Float>, aim: SIMD3<Float>, distance: Float, innerAngle: Float,
        outerAngle: Float
    ) {
        let position = pool + SIMD3(-0.25, 2.4, -0.95) * radius
        let aim = pool + SIMD3(0, 0, 0.1) * radius
        let distance = simd_distance(position, aim)
        let outer = 2 * atan(radius / distance) * 180 / .pi
        return (position, aim, distance, outer * 0.6, outer * 1.4)
    }

    private func makeTable() -> Entity {
        var material = BookFactory.surface(
            nil, tint: UIColor(red: 0.6, green: 0.44, blue: 0.32, alpha: 1), roughness: 0.62,
            specular: 0.3)
        // A thin varnish, which shows the lamp's glare beyond the books.
        material.clearcoat = .init(floatLiteral: 0.35)
        material.clearcoatRoughness = .init(floatLiteral: 0.3)
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
            // One 1024-pixel tile spans 15 units (1.5 meters) of the 90-unit table.
            material.textureCoordinateTransform = .init(scale: [6, 6])
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
        table.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: true))
        light(table)
        return table
    }

    /// Slow motes in the beam above the pool, lit by the lamp so that only those in its light
    /// show. About 200 drift at a time, each for 6 to 10 seconds.
    private static func dustMotes(radius: Float) -> ParticleEmitterComponent {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.birthLocation = .volume
        emitter.emitterShapeSize = [radius * 0.8, 8, radius * 0.8]
        emitter.speed = 0.03
        emitter.speedVariation = 0.03
        emitter.timing = .repeating(warmUp: 10, emit: .init(duration: 60))
        var motes = emitter.mainEmitter
        motes.birthRate = 14
        motes.lifeSpan = 8
        motes.lifeSpanVariation = 2
        motes.size = 0.045
        motes.sizeVariation = 0.02
        motes.opacityCurve = .gradualFadeInOut
        motes.color = .constant(.single(UIColor(red: 1, green: 0.93, blue: 0.82, alpha: 0.45)))
        motes.noiseStrength = 0.04
        motes.noiseScale = 0.6
        motes.noiseAnimationSpeed = 0.1
        motes.acceleration = [0, -0.004, 0]
        motes.isLightingEnabled = true
        motes.blendMode = .alpha
        emitter.mainEmitter = motes
        return emitter
    }

    /// A warm, dim room at night as a 512 × 256 equirectangular image, for image-based light:
    /// the lamp's bright shade high above the table's far side, its glow on the ceiling, a
    /// moonlit window to the right, dark bookshelves behind the viewer, and a darker floor.
    ///
    /// The image's middle column faces -z, away from the default camera, and x grows to the
    /// right, as RealityKit maps equirectangular environments.
    private static func room() -> CGImage? {
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
                // Bookshelves behind the viewer: dim spines of muted colors.
                var seed: UInt32 = 0x2545_F491
                for shelf in 0..<3 {
                    let top = spot(azimuth: 0, elevation: 32 - CGFloat(shelf) * 14).y
                    var x = spot(azimuth: 125, elevation: 0).x
                    let end = spot(azimuth: 235, elevation: 0).x
                    while x < end {
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        let width = 3 + CGFloat(seed >> 28)
                        let tone = 0.05 + CGFloat((seed >> 20) & 15) / 15 * 0.07
                        UIColor(red: tone * 1.3, green: tone, blue: tone * 0.8, alpha: 1)
                            .setFill()
                        let height = 26 - CGFloat((seed >> 12) & 7)
                        cg.fill(CGRect(x: x, y: top + 26 - height, width: width, height: height))
                        x += width + 0.5
                    }
                }
                // A window to the right, faintly moonlit.
                let window = spot(azimuth: 80, elevation: 38)
                UIColor(red: 0.1, green: 0.13, blue: 0.19, alpha: 1).setFill()
                cg.fill(CGRect(x: window.x, y: window.y, width: 46, height: 50))
                // The lamp's glow on the ceiling and walls around it, then its bright shade.
                let lamp = spot(azimuth: -15, elevation: 66)
                if let glow = gradient(
                    [
                        UIColor(red: 0.55, green: 0.38, blue: 0.22, alpha: 0.75),
                        UIColor(red: 0.2, green: 0.13, blue: 0.08, alpha: 0),
                    ], [0, 1])
                {
                    cg.drawRadialGradient(
                        glow, startCenter: lamp, startRadius: 0, endCenter: lamp, endRadius: 110,
                        options: [])
                }
                if let shade = gradient(
                    [
                        UIColor(red: 1, green: 0.95, blue: 0.85, alpha: 1),
                        UIColor(red: 1, green: 0.82, blue: 0.6, alpha: 1),
                        UIColor(red: 1, green: 0.75, blue: 0.5, alpha: 0),
                    ], [0, 0.5, 1])
                {
                    cg.drawRadialGradient(
                        shade, startCenter: lamp, startRadius: 0, endCenter: lamp, endRadius: 16,
                        options: [])
                }
            }
            .cgImage
    }
}
