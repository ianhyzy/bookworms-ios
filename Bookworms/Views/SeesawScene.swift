import RealityKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The seesaw a Seesaw share image shows: a plank with each reader's books stacked on its ends,
/// resting on the desk under the lamp (`DeskStage`), as the Desk's books do.
///
/// Scene units are decimeters, as in `BookPileScene`. The plank runs along x, with the reader's
/// books on the left (-x) and the friend's on the right, each book lying front cover up with
/// its spine toward the camera (`PileLayout.lyingFlat`). The plank rests on a walnut fulcrum
/// and, like a playground seesaw, tips all the way to the heavier side (`SeesawBalance.lean`)
/// until its end rests on the desk. Books stand still, each on the plank or on the book below.
@MainActor
final class SeesawScene {
    /// The plank's length, thickness, and depth.
    nonisolated static let plank = SIMD3<Float>(13, 0.35, 2.6)
    /// The fulcrum's height: the plank's underside sits this high when level.
    nonisolated static let baseHeight: Float = 1.5
    /// Stacks on each end, and the most books in one stack.
    nonisolated static let stacks = 2
    nonisolated static let stackLimit = 14
    /// The middle of each end's stacks, from the plank's middle.
    nonisolated static let arm: Float = 4

    let root = Entity()
    let camera = PerspectiveCamera()
    private let factory: BookFactory
    private let stage = DeskStage()

    init(textureScale: CGFloat) {
        factory = BookFactory(textureScale: textureScale)
        camera.camera = PerspectiveCameraComponent(
            near: 0.5, far: 300, fieldOfViewInDegrees: PileCamera.fieldOfView * 180 / .pi,
            fieldOfViewOrientation: .vertical)
        root.addChild(camera)
        root.addChild(stage.root)
    }

    /// Builds the books both readers' ends show, waiting for their fonts and up to 10 seconds
    /// for covers, then places the plank, the fulcrum, and the books, and frames them in `rect`
    /// of an image of `size`. Returns the books whose covers came too late.
    func prepare(
        _ balance: SeesawBalance, in rect: CGRect, of size: CGSize, model: AppModel
    ) async -> [CloudBook] {
        let mine = balance.mine.shown(limit: Self.stacks * Self.stackLimit)
        let theirs = balance.theirs.shown(limit: Self.stacks * Self.stackLimit)
        let books = mine + theirs
        let late = await factory.prepare(
            books, prefetching: [], loadWait: .seconds(10), waitsForFonts: true, model: model)
        let pose = Self.plankPose(balance)
        root.addChild(makeFulcrum())
        root.addChild(makePlank(pose: pose))
        var points = Self.plankCorners(pose)
        for (books, side) in [(mine, Float(-1)), (theirs, 1)] {
            for (book, transform) in stackSlots(books, side: side, pose: pose) {
                guard
                    let entity = factory.makeBook(
                        book.id, mode: .static, lighting: stage.lighting)
                else { continue }
                entity.transform = transform
                root.addChild(entity)
                points.append(transform.translation)
            }
        }
        stage.build(pool: [0, 0, 0], radius: Self.plank.x * 0.6)
        let view = PileCamera(target: [0, 2, 0], yaw: 0, zoom: 1, pitch: 22 * .pi / 180)
            .framing(points, in: rect, of: size, zoomRange: 0.2...4)
        camera.transform = view.transform
        await stage.lit()
        return books.filter { late.contains($0.id) }
    }

    // MARK: Layout

    /// The plank's pose: its middle and its turn about the z axis, positive to tip the left
    /// end down.
    struct PlankPose {
        var center: SIMD3<Float>
        var angle: Float

        var rotation: simd_quatf { simd_quatf(angle: angle, axis: [0, 0, 1]) }

        /// A point in the plank's axes, with the plank's top face at y = 0, in the scene.
        func place(_ local: SIMD3<Float>) -> SIMD3<Float> {
            center + rotation.act(local + [0, SeesawScene.plank.y / 2, 0])
        }
    }

    /// The turn at which the plank's lower end touches the desk: its underside pivots on the
    /// fulcrum's ridge, so its end drops half its length times the turn's sine.
    nonisolated static let maximumTilt = asin(2 * baseHeight / plank.x)

    /// The plank turned about the fulcrum's ridge toward the heavier side, or level.
    static func plankPose(_ balance: SeesawBalance) -> PlankPose {
        let angle: Float =
            switch balance.lean {
            case .mine: maximumTilt
            case .theirs: -maximumTilt
            case .level: 0
            }
        let rotation = simd_quatf(angle: angle, axis: [0, 0, 1])
        return PlankPose(
            center: [0, baseHeight, 0] + rotation.act([0, plank.y / 2, 0]), angle: angle)
    }

    /// The plank's eight corners in the scene.
    static func plankCorners(_ pose: PlankPose) -> [SIMD3<Float>] {
        var corners: [SIMD3<Float>] = []
        for x in [-plank.x / 2, plank.x / 2] {
            for y in [-plank.y / 2, plank.y / 2] {
                for z in [-plank.z / 2, plank.z / 2] {
                    corners.append(pose.center + pose.rotation.act([x, y, z]))
                }
            }
        }
        return corners
    }

    /// Stacks `books` on one end of the plank, `side` -1 for the left and 1 for the right, and
    /// returns each book's pose.
    ///
    /// The biggest books lie lowest, and each book goes on the lowest stack, so the stacks rise
    /// evenly. Each book shifts a little along the plank and turns a few degrees about the
    /// plank's normal, as stacks placed by hand do, and lies flat on the book below it.
    func stackSlots(_ books: [CloudBook], side: Float, pose: PlankPose) -> [(
        CloudBook, Transform
    )] {
        let shaped = books.compactMap { book in factory.parts[book.id].map { (book, $0.shape.size) } }
            .sorted { $0.1.x * $0.1.y > $1.1.x * $1.1.y }
        let count = min(Self.stacks, shaped.count)
        guard count > 0 else { return [] }
        let spacing: Float = 2.6
        var heights = [Float](repeating: 0, count: count)
        var slots: [(CloudBook, Transform)] = []
        for (book, size) in shaped {
            let stack = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let x = side * (Self.arm + (Float(stack) - Float(count - 1) / 2) * spacing)
            let jitter = (Float(ShareStyle.unit(0, book.id, 11)) - 0.5) * 0.12
            let turn = Float(StackArrangement.twist(of: book, maximum: PileLayout.stackTwist))
            let local = SIMD3<Float>(x + jitter, heights[stack] + size.z / 2, 0)
            slots.append(
                (
                    book,
                    Transform(
                        rotation: pose.rotation * simd_quatf(angle: turn, axis: [0, 1, 0])
                            * PileLayout.lyingFlat,
                        translation: pose.place(local))
                ))
            heights[stack] += size.z
        }
        return slots
    }

    // MARK: Models

    private func wood(tint: UIColor) -> PhysicallyBasedMaterial {
        var material = BookFactory.surface(nil, tint: tint, roughness: 0.55, specular: 0.3)
        material.clearcoat = .init(floatLiteral: 0.25)
        material.clearcoatRoughness = .init(floatLiteral: 0.4)
        if let image = UIImage(named: "TableWood")?.cgImage,
            let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        {
            material.baseColor.texture = .init(texture)
        }
        return material
    }

    /// Light oak, which stands out from the walnut desk.
    private static let oak = UIColor(red: 0.98, green: 0.82, blue: 0.62, alpha: 1)
    private static let walnut = UIColor(red: 0.42, green: 0.28, blue: 0.19, alpha: 1)

    private func makePlank(pose: PlankPose) -> Entity {
        let entity = ModelEntity(
            mesh: .generateBox(
                width: Self.plank.x, height: Self.plank.y, depth: Self.plank.z,
                cornerRadius: 0.06),
            materials: [wood(tint: Self.oak)])
        entity.transform = Transform(rotation: pose.rotation, translation: pose.center)
        stage.light(entity)
        return entity
    }

    /// A walnut ridge block under the plank's middle, wider at the desk than at the plank.
    private func makeFulcrum() -> Entity {
        let width = Self.baseHeight * 1.3
        let profile: [SIMD2<Float>] = [
            [-width / 2, 0], [width / 2, 0], [0.08, Self.baseHeight], [-0.08, Self.baseHeight],
        ]
        let entity = ModelEntity(
            mesh: Self.extruded(profile, depth: Self.plank.z * 0.8) ?? .generateBox(size: 0.1),
            materials: [wood(tint: Self.walnut)])
        stage.light(entity)
        return entity
    }

    /// A prism: the convex polygon `profile`, counterclockwise in the xy plane, extruded
    /// `depth` along z and centered on z = 0, with flat faces.
    static func extruded(_ profile: [SIMD2<Float>], depth: Float) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var coordinates: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        let half = depth / 2
        func face(_ corners: [SIMD3<Float>], normal: SIMD3<Float>) {
            let start = UInt32(positions.count)
            for corner in corners {
                positions.append(corner)
                normals.append(normal)
                coordinates.append(SIMD2(corner.x + corner.z, corner.y) / 15)
            }
            for index in 1..<(UInt32(corners.count) - 1) {
                indices += [start, start + index, start + index + 1]
            }
        }
        face(profile.map { [$0.x, $0.y, half] }, normal: [0, 0, 1])
        face(profile.reversed().map { [$0.x, $0.y, -half] }, normal: [0, 0, -1])
        for (index, point) in profile.enumerated() {
            let next = profile[(index + 1) % profile.count]
            let along = next - point
            let normal = simd_normalize(SIMD3(along.y, -along.x, 0))
            face(
                [[point.x, point.y, -half], [next.x, next.y, -half], [next.x, next.y, half], [point.x, point.y, half]],
                normal: normal)
        }
        var descriptor = MeshDescriptor(name: "seesaw fulcrum")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(coordinates)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }
}
