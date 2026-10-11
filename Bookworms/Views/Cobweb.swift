import RealityKit
import UIKit
import simd

/// The threads of a cobweb strung across the gap between two standing books' top edges, built
/// without RealityKit so they can be tested.
///
/// Radial threads run from an off-center hub to the books' top edges and to two bridge threads
/// that span the gap at its sides, and a capture spiral winds out across them. The web sags
/// toward its middle, its threads are irregular, and a denser web has more radials, more turns,
/// a deeper sag, and stray threads across it. A seed, such as one from the books' IDs, fixes
/// the irregularity, so a chain stands the same web each time.
///
/// The threads come in pieces, one per radial, that tear away on their own (see
/// `HangingCobweb`).
struct Cobweb: Sendable {
    /// One radial's share of the web: its threads as pairs of ends, relative to `pivot`, the
    /// point on the web's edge where the radial is attached.
    struct Piece: Sendable {
        let pivot: SIMD3<Float>
        let threads: [SIMD3<Float>]
        /// The horizontal direction from the hub to `pivot`, a unit vector.
        let outward: SIMD3<Float>
        /// How far `pivot` lies across the gap: 0 at the near book's edge, 1 at the far one's.
        let along: Float
    }

    let pieces: [Piece]

    /// A web from `near`, the two ends of the near book's top edge, to `far`, the far book's,
    /// in the same order across the gap, at a `density` from 0 to 1.
    init(near: [SIMD3<Float>], far: [SIMD3<Float>], density: Float, seed: UInt64) {
        var random = BookAnalyzer.SeededGenerator(seed: seed)
        func jitter(_ range: Float) -> Float { Float.random(in: -range...range, using: &random) }
        let density = min(1, max(0, density))
        let length = (simd_distance(near[0], far[0]) + simd_distance(near[1], far[1])) / 2
        let width = (simd_distance(near[0], near[1]) + simd_distance(far[0], far[1])) / 2
        let sag = length * (0.18 + 0.17 * density)
        // A point on the web, from u = 0 at the near edge to 1 at the far one and v from one
        // side to the other. The bridges at the sides sag about a third as deep as the middle.
        func point(_ uv: SIMD2<Float>) -> SIMD3<Float> {
            let (u, v) = (uv.x, uv.y)
            let edge0 = near[0] + (far[0] - near[0]) * u
            let edge1 = near[1] + (far[1] - near[1]) * u
            let drop = sag * sin(.pi * u) * (0.35 + 0.65 * sin(.pi * v))
            return edge0 + (edge1 - edge0) * v - [0, drop, 0]
        }
        let hub = SIMD2<Float>(0.5 + jitter(0.08), 0.5 + jitter(0.08))
        let count = 7 + Int((5 * density).rounded())
        let turns = 3 + Int((5 * density).rounded())
        let step = 2 * Float.pi / Float(count)
        let first = jitter(.pi)
        // Each radial's angle on the web, where u runs `length` and v runs `width`, and where it
        // meets the web's edge. The jitter keeps the angles in order.
        let angles = (0..<count).map { first + (Float($0) + jitter(0.3)) * step }
        let ends = angles.map { angle in
            let direction = SIMD2(cos(angle) / length, sin(angle) / width)
            var reach = Float.infinity
            for axis in 0..<2 where direction[axis] != 0 {
                let bound: Float = direction[axis] > 0 ? 1 : 0
                reach = min(reach, (bound - hub[axis]) / direction[axis])
            }
            return hub + direction * reach
        }
        // Threads in (u, v), each assigned to the radial whose piece holds it.
        var threads = [[(SIMD2<Float>, SIMD2<Float>)]](repeating: [], count: count)
        func sector(of uv: SIMD2<Float>) -> Int {
            let offset = (uv - hub) * [length, width]
            let turn = (atan2(offset.y, offset.x) - angles[0])
                .truncatingRemainder(dividingBy: 2 * .pi)
            let angle = turn < 0 ? turn + 2 * .pi : turn
            return angles.lastIndex { $0 - angles[0] <= angle } ?? 0
        }
        func add(_ points: [SIMD2<Float>], to piece: Int? = nil) {
            for (a, b) in zip(points, points.dropFirst()) {
                threads[piece ?? sector(of: (a + b) / 2)].append((a, b))
            }
        }
        // Radials, in four segments each, so they follow the sag.
        for (index, end) in ends.enumerated() {
            add((0...4).map { hub + (end - hub) * Float($0) / 4 }, to: index)
        }
        // The capture spiral, from a fifth of the way out to near the edge, one chord between
        // each pair of radials.
        let chords = turns * count
        add(
            (0...chords)
                .map { index in
                    let radial = index % count
                    let out = 0.2 + 0.72 * Float(index) / Float(chords) + jitter(0.03)
                    return hub + (ends[radial] - hub) * min(0.97, out)
                })
        // The bridges along both sides, from the near edge to the far one.
        for side: Float in [0, 1] {
            add((0...6).map { SIMD2(Float($0) / 6, side) })
        }
        // Stray threads across older webs, from one edge to another.
        for _ in 0..<Int((4 * density).rounded()) {
            let tips = (0..<2)
                .map { _ in
                    let t = Float.random(in: 0...1, using: &random)
                    let side: Float = Bool.random(using: &random) ? 0 : 1
                    return Bool.random(using: &random) ? SIMD2(side, t) : SIMD2(t, side)
                }
            add((0...4).map { tips[0] + (tips[1] - tips[0]) * Float($0) / 4 })
        }
        let center = point(hub)
        pieces = ends.indices.compactMap { index in
            guard !threads[index].isEmpty else { return nil }
            let pivot = point(ends[index])
            var outward = pivot - center
            outward.y = 0
            return Piece(
                pivot: pivot,
                threads: threads[index].flatMap { [point($0.0) - pivot, point($0.1) - pivot] },
                outward: simd_length(outward) > 0 ? simd_normalize(outward) : [1, 0, 0],
                along: ends[index].x)
        }
    }

    /// Threads, given as pairs of ends, as flat ribbons `width` wide, facing up as far as each
    /// thread allows, so the steep camera sees their faces. Draw them with face culling off.
    static func ribbons(_ threads: [SIMD3<Float>], width: Float) -> MeshDescriptor {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for index in stride(from: 0, to: threads.count - 1, by: 2) {
            let (a, b) = (threads[index], threads[index + 1])
            guard simd_distance(a, b) > 1e-5 else { continue }
            let direction = simd_normalize(b - a)
            var side = simd_cross(direction, [0, 1, 0])
            if simd_length(side) < 0.1 { side = simd_cross(direction, [1, 0, 0]) }
            side = simd_normalize(side) * width / 2
            var normal = simd_normalize(simd_cross(side, direction))
            if normal.y < 0 { normal = -normal }
            let base = UInt32(positions.count)
            positions += [a - side, a + side, b + side, b - side]
            normals += Array(repeating: normal, count: 4)
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        var descriptor = MeshDescriptor(name: "cobweb")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }
}

/// A cobweb's entities between two standing dominoes, and how it tears.
///
/// A hanging web draws as one mesh. Its pieces, each its own entity, show only once it tears.
/// No part has a physics body, so the web never blocks or slows a book. Torn, each piece passes to the book whose edge it is nearer, which carries it as it
/// falls, while the piece springs back toward where its radial is attached, crumples, droops
/// from there, and fades, starting from the near book's side. With Reduce Motion on, the
/// pieces only fade. Once every piece has faded, the web removes them.
@MainActor
struct HangingCobweb {
    /// Holds the whole web, and the pieces until the web tears.
    let root = Entity()
    private let whole: ModelEntity
    /// The index of the near book in the chain.
    let book: Int
    private var pieces: [(entity: Entity, piece: Cobweb.Piece)] = []
    /// Each piece's transform in the book that holds it, from when the web tore.
    private var holds: [Transform] = []
    private var elapsed: Float?
    private var fadesOnly = false

    /// How long a piece takes to fade once it starts tearing, in seconds.
    private static let fade: Float = 0.9
    /// How long the tear takes to cross from the near book's side to the far one's.
    private static let sweep: Float = 0.15
    /// Silk's width: about a pixel at the zoom that follows the chain.
    private static let thread: Float = 0.005

    /// The pieces of `web`, between the book at `book` and the next one, in `material` and lit
    /// by `lighting`. Fails if RealityKit cannot make a piece's mesh.
    init?(_ web: Cobweb, book: Int, material: any RealityKit.Material, lighting: Entity) {
        self.book = book
        func entity(_ threads: [SIMD3<Float>]) -> ModelEntity? {
            guard
                let mesh = try? MeshResource.generate(
                    from: [Cobweb.ribbons(threads, width: Self.thread)])
            else { return nil }
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
            // Silk this thin casts no shadow worth the shadow map's work.
            entity.components.set(DynamicLightShadowComponent(castsShadow: false))
            return entity
        }
        guard
            let whole = entity(
                web.pieces.flatMap { piece in piece.threads.map { $0 + piece.pivot } })
        else { return nil }
        self.whole = whole
        root.addChild(whole)
        for piece in web.pieces {
            guard let entity = entity(piece.threads) else { return nil }
            entity.position = piece.pivot
            entity.isEnabled = false
            root.addChild(entity)
            pieces.append((entity, piece))
        }
    }

    /// Starts tearing the web, handing each piece to `near` or `far`, the books whose edges
    /// hold it. With `fadesOnly`, the pieces only fade, as Reduce Motion asks.
    mutating func tear(near: Entity, far: Entity, fadesOnly: Bool) {
        guard elapsed == nil else { return }
        elapsed = 0
        self.fadesOnly = fadesOnly
        whole.removeFromParent()
        holds = pieces.map { entity, piece in
            entity.isEnabled = true
            entity.setParent(piece.along < 0.5 ? near : far, preservingWorldTransform: true)
            return entity.transform
        }
    }

    /// Advances the tear by `deltaTime` seconds. Returns `false`, having removed the pieces from
    /// the scene, once every piece has faded.
    mutating func advance(by deltaTime: Float) -> Bool {
        guard var elapsed else { return true }
        elapsed += deltaTime
        self.elapsed = elapsed
        guard elapsed <= Self.sweep + Self.fade else {
            for (entity, _) in pieces { entity.removeFromParent() }
            root.removeFromParent()
            return false
        }
        for ((entity, piece), hold) in zip(pieces, holds) {
            let time = max(0, elapsed - piece.along * Self.sweep)
            let progress = min(1, time / Self.fade)
            entity.components.set(OpacityComponent(opacity: 1 - progress))
            guard !fadesOnly, time > 0 else { continue }
            // The cut silk springs back toward its anchor, then crumples and droops. A piece's
            // own axes are the scene's as the web hung, so "down" is down from where it hung.
            let shrink = 1 - 0.5 * (1 - pow(1 - min(1, time / 0.15), 3)) - 0.3 * progress
            let droop = 1.2 * (1 - pow(1 - progress, 2))
            let tear = Transform(
                scale: SIMD3(repeating: shrink),
                rotation: simd_quatf(
                    angle: droop, axis: simd_normalize(simd_cross(piece.outward, [0, 1, 0]))),
                translation: [0, -0.2 * progress, 0])
            entity.transform = Transform(matrix: hold.matrix * tear.matrix)
        }
        return true
    }

    /// Silk: pale and translucent, with a clear coat that catches the lamp, and a faint glow so
    /// threads in shadow still show.
    static func silk() -> PhysicallyBasedMaterial {
        var material = BookFactory.surface(
            nil, tint: UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1), roughness: 0.3,
            specular: 0.8)
        material.clearcoat = .init(floatLiteral: 0.8)
        material.clearcoatRoughness = .init(floatLiteral: 0.15)
        material.emissiveColor = .init(color: UIColor(white: 0.5, alpha: 1))
        material.emissiveIntensity = 0.25
        material.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        material.faceCulling = .none
        return material
    }
}
