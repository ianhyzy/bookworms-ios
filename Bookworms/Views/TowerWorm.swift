import RealityKit

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The bookworm of the app icon and the promo video, sitting coiled on the desk.
///
/// The shape follows the icon's Blender model (`design/icon/bookworms.py` in the Apple TV
/// repository) and the promo's coiled pose: a plump pink tube whose front rises upright to a
/// domed head with two cream eyes, dark pupils, and a plum smile, and whose back lies flat on
/// the desk, curls 200 degrees around the base, and narrows toward a rounded tail.
///
/// Sizes are in the worm's units, where the top of the head stands `height` above the desk;
/// `make(height:)` scales them to scene units. The worm faces +z, toward the camera, and its
/// coil curls round on its right (+x).
@MainActor
enum TowerWorm {
    /// The model's proportions, from the promo scene's body and coil, with the front risen
    /// higher so it stands upright beside a tower: a head 2.6 units high, a body 0.54 units
    /// thick, and a coil 1.05 units from the base.
    private static let modelHeight: Float = 2.6
    private static let bodyRadius: Float = 0.54
    private static let coil: Float = 1.05
    /// How much thinner the tail end is than the body.
    private static let taper: Float = 0.4

    private static let pink = UIColor(red: 0.94, green: 0.56, blue: 0.65, alpha: 1)
    private static let cream = UIColor(red: 0.97, green: 0.93, blue: 0.86, alpha: 1)
    private static let pupil = UIColor(red: 0.04, green: 0.02, blue: 0.03, alpha: 1)
    private static let plum = UIColor(red: 0.31, green: 0.2, blue: 0.3, alpha: 1)

    /// How far the worm reaches from its base, in units of `height`: left, right, back, and
    /// front, for framing.
    static let reach = (
        left: (0.64 * coil + bodyRadius) / modelHeight, right: (coil + bodyRadius) / modelHeight,
        front: (coil + bodyRadius) / modelHeight
    )

    /// A worm whose head's top stands `height` scene units above the desk, at the origin.
    static func make(height: Float) -> Entity {
        let root = Entity()
        let scale = height / modelHeight
        root.scale = SIMD3(repeating: scale)
        let path = spline(through: centerline(), samples: 160)
        let length = zip(path, path.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        var run: Float = 0
        var radii: [Float] = []
        for (index, point) in path.enumerated() {
            if index > 0 { run += simd_distance(path[index - 1], point) }
            let fromTail = run / length
            let body = bodyRadius * (1 - taper * max(0, 1 - fromTail / 0.5))
            // Both ends close in domes: the radius falls off over the last body radius.
            let tip = min(1, min(run, length - run) / body)
            radii.append(max(body * (1 - (1 - tip) * (1 - tip)).squareRoot(), 0.002))
        }
        if let body = tube(along: path, radii: radii, sides: 40) {
            root.addChild(model(body, pink, roughness: 0.42))
        }

        // The face sits on the head, a sphere of the body's radius one radius below its top.
        let center =
            path[path.count - 1] - simd_normalize(path[path.count - 1] - path[path.count - 8])
            * bodyRadius
        let front = simd_normalize(SIMD3<Float>(0, 0.1, 1))
        let up = simd_normalize(SIMD3<Float>(0, 1, 0) - front * front.y)
        let side = simd_cross(front, up)
        func onHead(_ direction: SIMD3<Float>, _ depth: Float) -> SIMD3<Float> {
            center + simd_normalize(direction) * bodyRadius * depth
        }
        let eyeRadius = 0.36 * bodyRadius
        for sign: Float in [-1, 1] {
            let eye = onHead(front + side * 0.5 * sign + up * 0.2, 0.84)
            let white = model(.generateSphere(radius: eyeRadius), cream, roughness: 0.3)
            white.position = eye
            root.addChild(white)
            let dot = model(.generateSphere(radius: eyeRadius * 0.4), pupil, roughness: 0.1)
            dot.position = eye + front * eyeRadius * 0.74
            root.addChild(dot)
        }
        let smile = (0...24)
            .map { step -> SIMD3<Float> in
                let across = -0.3 + 0.6 * Float(step) / 24
                return onHead(front + side * across + up * (-0.5 + 1.6 * across * across), 1.01)
            }
        if let line = tube(
            along: smile,
            radii: smile.indices.map { index in
                let end = Float(min(index, smile.count - 1 - index)) / 3
                return 0.065 * bodyRadius * min(1, 0.4 + end)
            }, sides: 10)
        {
            root.addChild(model(line, plum, roughness: 0.5))
        }
        return root
    }

    /// The body's centerline, tail first, in model units: the coil flat on the desk round the
    /// base on the worm's right, from its front round to its back, where it bends up into the
    /// body that rises to the head.
    private static func centerline() -> [SIMD3<Float>] {
        // Angles about the base: 0 is the worm's right, 90 its back, -90 its front.
        let end: Float = 70
        let sweep: Float = 200
        let steps = 12
        var points = (0...steps)
            .map { step -> SIMD3<Float> in
                let angle = (end - sweep * (1 - Float(step) / Float(steps))) * .pi / 180
                return [coil * cos(angle), 0, -coil * sin(angle)]
            }
        let tuck = (end + 25) * .pi / 180
        points.append([0.45 * cos(tuck), 0, -0.45 * sin(tuck)])
        // The lying part rests on the desk at its own radius, which the taper narrows toward
        // the tail, pressed a little into it.
        var run: [Float] = [0]
        for (from, to) in zip(points, points.dropFirst()) {
            run.append(run[run.count - 1] + simd_distance(from, to))
        }
        let total = run[run.count - 1] + 0.9 + modelHeight
        for index in points.indices {
            let narrowing = 1 - taper * max(0, 1 - run[index] / total / 0.5)
            points[index].y = bodyRadius * 0.94 * narrowing * (index == points.count - 1 ? 1.25 : 1)
        }
        points.append([0, modelHeight * 0.55, -0.02])
        points.append([0, modelHeight - 0.02, 0.04])
        return points
    }

    /// `samples` points along a Catmull-Rom spline through `points`.
    private static func spline(through points: [SIMD3<Float>], samples: Int) -> [SIMD3<Float>] {
        (0..<samples)
            .map { sample in
                let position = Float(sample) / Float(samples - 1) * Float(points.count - 1)
                let index = min(Int(position), points.count - 2)
                let t = position - Float(index)
                let p0 = points[max(index - 1, 0)]
                let p1 = points[index]
                let p2 = points[index + 1]
                let p3 = points[min(index + 2, points.count - 1)]
                let t2 = t * t
                let t3 = t2 * t
                let a = 2 * p1 + (p2 - p0) * t
                let b = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                let c = (3 * p1 - p0 - 3 * p2 + p3) * t3
                return (a + b + c) * 0.5
            }
    }

    /// A smooth tube along `path` with a radius per point, framed by parallel transport so it
    /// doesn't twist.
    private static func tube(along path: [SIMD3<Float>], radii: [Float], sides: Int)
        -> MeshResource?
    {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let tangents = path.indices.map { index in
            simd_normalize(path[min(index + 1, path.count - 1)] - path[max(index - 1, 0)])
        }
        let seed = abs(tangents[0].y) < 0.9 ? SIMD3<Float>(0, 1, 0) : [1, 0, 0]
        var normal = simd_normalize(simd_cross(tangents[0], seed))
        for (index, point) in path.enumerated() {
            let tangent = tangents[index]
            normal = simd_normalize(normal - tangent * simd_dot(normal, tangent))
            let binormal = simd_cross(tangent, normal)
            for side in 0..<sides {
                let angle = 2 * Float.pi * Float(side) / Float(sides)
                let out = normal * cos(angle) + binormal * sin(angle)
                positions.append(point + out * radii[index])
                normals.append(out)
            }
        }
        for ring in 0..<(path.count - 1) {
            for side in 0..<sides {
                let a = UInt32(ring * sides + side)
                let b = UInt32(ring * sides + (side + 1) % sides)
                let c = a + UInt32(sides)
                let d = b + UInt32(sides)
                indices += [a, b, c, b, d, c]
            }
        }
        var descriptor = MeshDescriptor(name: "worm")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private static func model(_ mesh: MeshResource, _ color: UIColor, roughness: Float)
        -> ModelEntity
    {
        ModelEntity(
            mesh: mesh,
            materials: [BookFactory.surface(nil, tint: color, roughness: roughness, specular: 0.3)])
    }
}
