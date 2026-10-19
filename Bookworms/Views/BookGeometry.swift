import Foundation
import RealityKit
import simd

/// How a book is bound: boards that overhang the pages, or soft covers trimmed flush with them.
enum BookBinding: Hashable, Sendable {
    case hardcover, paperback
}

extension CloudBook {
    /// The book's likely binding.
    ///
    /// The library does not record which edition the reader holds, so this is a deterministic
    /// guess. A book first finished within a year of its publication is most likely a new
    /// release, which publishers issue in hardcover first, so three in four such books are
    /// hardcovers; two in five other books are. The book's ID decides which books those are, so
    /// a book keeps its binding everywhere and across launches.
    var binding: BookBinding {
        let firstYear = firstFinish.flatMap { Int($0.prefix(4)) }
        let isNewRelease =
            publicationYear.flatMap { year in firstYear.map { $0 - year <= 1 } } ?? false
        return ShareStyle.unit(0, id, 60) < (isNewRelease ? 0.75 : 0.4) ? .hardcover : .paperback
    }
}

/// A book's outer size, rounded to the sizes that share one mesh, and its binding.
///
/// Scene units are decimeters. Sizes snap to 5 mm in width and height and 2 mm in thickness, so
/// a beveled mesh is never stretched to fit another size, and `size(pages:coverAspect:variety:)`
/// rounds a book's size more coarsely, so many books share a mesh. The physics box is the same
/// snapped size.
struct BookShape: Hashable, Sendable {
    static let step: SIMD3<Float> = [0.05, 0.05, 0.02]

    /// The size in steps of `step`: spine to fore edge, tail to head, and back to front cover.
    let cells: SIMD3<Int32>
    let binding: BookBinding

    init(size: SIMD3<Float>, binding: BookBinding) {
        cells = pointwiseMax(
            SIMD3<Int32>(size / Self.step, rounding: .toNearestOrAwayFromZero), [1, 1, 1])
        self.binding = binding
    }

    /// The longest a book gets: 28 cm, a doorstopper's length.
    static let longest: Float = 2.8

    /// A book's shape: its size for its page count (`size(pages:coverAspect:variety:)`), with
    /// the variety that the book's ID decides, so a book keeps its size everywhere.
    init(of book: CloudBook, coverAspect: CGFloat) {
        let variety = SIMD2(
            Float(ShareStyle.unit(0, book.id, 40)), Float(ShareStyle.unit(0, book.id, 41)))
        self.init(
            size: Self.size(pages: book.pages, coverAspect: Float(coverAspect), variety: variety),
            binding: book.binding)
    }

    /// The size of a book of `pages` pages, before snapping: from spine to fore edge, tail to
    /// head, and back to front cover, as `size` lays them out. It follows the rules of the
    /// Apple TV's Book Wall, at real books' scale.
    ///
    /// Page count grows both length and thickness. Length grows with the square root of the
    /// page count from a floor of 17 cm up to 200 pages, which keeps short books close to long
    /// ones, to 23 cm at 800 pages. Thickness grows by 0.035 mm a page from 7 mm at 100 pages,
    /// up to 4 cm at about 1,040 pages, so long books look substantially thicker. `variety`, two
    /// numbers from 0 to 1, then lengthens the book by up to 22 percent and thickens it by up to
    /// 25 percent, so books of similar length still differ. A book is at least 6 times as long
    /// as it is thick, up to `longest`, which also caps length, so a very thick book reads as
    /// chunky. The width is the length times `coverAspect`, the front board's width-to-height
    /// ratio. Page counts count from 100 to 1,400, and a book without one counts as 320 pages.
    ///
    /// Sizes are rounded coarsely, so books share meshes: each variety to none, half, or all of
    /// its range, the aspect to 0.05, the length to 1 cm, and the thickness to 4 mm. Each page
    /// adds less than real paper does, so a typical library's books average about 0.7 liters.
    static func size(pages: Int?, coverAspect: Float, variety: SIMD2<Float>) -> SIMD3<Float> {
        func round(_ value: Float, to step: Float) -> Float { (value / step).rounded() * step }
        let pages = Float(min(1_400, max(100, pages ?? 320)))
        let variety = (variety * 2).rounded(.toNearestOrAwayFromZero) / 2
        let natural = 1.7 + 0.6 * min(1, max(0, (pages / 200).squareRoot() - 1))
        let thickness = round(
            min(0.4, 0.07 + (pages - 100) * 0.00035) * (1 + variety.y * 0.25), to: 0.04)
        // The 6-to-1 minimum, rounded up, so rounding never makes a book too squat.
        let shortest = (thickness * 60).rounded(.up) / 10
        let length = min(longest, max(round(natural * (1 + variety.x * 0.22), to: 0.1), shortest))
        return [length * round(coverAspect, to: 0.05), length, thickness]
    }

    /// The book's box: x from spine to fore edge (the cover's width), y from tail to head, and
    /// z from back to front cover.
    var size: SIMD3<Float> { SIMD3<Float>(cells) * Self.step }

    /// Each board's thickness: up to 2.8 mm for a hardcover and 0.8 mm for a paperback's card,
    /// and less on a thin book, so its pages keep most of its thickness.
    var board: Float {
        binding == .hardcover ? min(0.028, size.z * 0.18) : min(0.008, size.z * 0.1)
    }

    /// How far the spine bulges out past the boards' edges.
    var spineDepth: Float { max(0.006, size.z * (binding == .hardcover ? 0.22 : 0.08)) }

    /// The width-to-height aspect of the front board, from the spine's joint to the fore edge,
    /// which the cover fills.
    var coverAspect: Float { (size.x - spineDepth) / size.y }
}

/// The material slots of a book's mesh, in the order of its materials.
enum BookSlot {
    static let cover: UInt32 = 0
    static let spine: UInt32 = 1
    static let pages: UInt32 = 2
    /// The back cover, and the boards' edges where the cover does not wrap.
    static let cloth: UInt32 = 3
}

/// The triangles of a book or a ribbon bookmark, built without RealityKit so they can be built
/// on any thread and tested.
///
/// Each face winds counterclockwise seen from outside: `quad` and `triangle` reverse corners
/// given the other way around, judged by the normals they are given.
struct BookGeometry: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var coordinates: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    /// One material slot per triangle.
    var slots: [UInt32] = []

    /// How far the page edges' line texture runs before it repeats, in units across the page
    /// block.
    static let pageLinePeriod: Float = 0.08

    var descriptor: MeshDescriptor {
        var descriptor = MeshDescriptor(name: "book")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(coordinates)
        descriptor.primitives = .triangles(indices)
        descriptor.materials = .perFace(slots)
        return descriptor
    }

    mutating func quad(
        _ corners: [SIMD3<Float>], normals: [SIMD3<Float>], coordinates: [SIMD2<Float>],
        slot: UInt32
    ) {
        polygon(corners, normals: normals, coordinates: coordinates, slot: slot)
    }

    mutating func triangle(
        _ corners: [SIMD3<Float>], normal: SIMD3<Float>, coordinates: [SIMD2<Float>],
        slot: UInt32
    ) {
        polygon(
            corners, normals: Array(repeating: normal, count: 3), coordinates: coordinates,
            slot: slot)
    }

    /// Adds a polygon as a fan from its first corner, which must see every other corner, as
    /// every corner of a convex polygon does.
    private mutating func polygon(
        _ corners: [SIMD3<Float>], normals: [SIMD3<Float>], coordinates: [SIMD2<Float>],
        slot: UInt32
    ) {
        let base = UInt32(positions.count)
        positions += corners
        self.normals += normals.map(simd_normalize)
        self.coordinates += coordinates
        let facing = simd_cross(corners[1] - corners[0], corners[2] - corners[0])
        let flipped = simd_dot(facing, normals.reduce(.zero, +)) < 0
        for index in 1..<UInt32(corners.count - 1) {
            indices +=
                flipped
                ? [base, base + index + 1, base + index] : [base, base + index, base + index + 1]
            slots.append(slot)
        }
    }
}

extension BookGeometry {
    /// Points on a spine's cross-section in the x–z plane, from the back cover to the front,
    /// with outward normals.
    ///
    /// The curve is half a superellipse of exponent `exponent` around (`x`, 0): it bulges
    /// `depth` toward -x and spans `half` to each side. An exponent of 2 gives a rounded
    /// hardcover spine; 4 gives a paperback's flat spine with soft corners. The ends meet the
    /// covers square, with normals along ±z.
    static func spineProfile(
        x: Float, depth: Float, half: Float, exponent: Float, segments: Int
    ) -> [(point: SIMD2<Float>, normal: SIMD2<Float>)] {
        let shape = 2 / exponent
        let slope = 2 * (exponent - 1) / exponent
        return (0...segments)
            .map { index in
                let t = Float(index) / Float(segments)
                let angle = (t - 0.5) * .pi
                let (cosine, sine) = (max(0, cos(angle)), sin(angle))
                let side: Float = sine < 0 ? -1 : 1
                let point = SIMD2(
                    x - depth * pow(cosine, shape), half * side * pow(abs(sine), shape))
                let normal = SIMD2(
                    -pow(cosine, slope) / depth, side * pow(abs(sine), slope) / half)
                return (point, simd_normalize(normal))
            }
    }

    /// The mesh of a book of `shape`, centered on the origin in the book's axes (see
    /// `BookShape.size`), with the material slots of `BookSlot`.
    ///
    /// A hardcover's boards (`BookShape.board`) overhang the page block by 3.5 mm at the head,
    /// tail, and fore edge, and its spine is rounded. A paperback's covers are trimmed flush
    /// with the pages, and its spine is flat with soft corners. The covers' outer edges are
    /// beveled, so they catch the light.
    ///
    /// The front cover's image spans the front board, upright, from the spine's joint to the
    /// fore edge (`BookShape.coverAspect`). Over the bevels and the board's edges it folds back
    /// on itself, as a jacket wrapped around the board shows its border there. The spine's
    /// image runs head to tail across the curved spine at an even scale, with its top toward
    /// the front cover, matching `UprightSpineView`. The page edges' line texture repeats every
    /// `pageLinePeriod` across the block, so its lines run parallel to the covers.
    static func book(_ shape: BookShape) -> BookGeometry {
        let size = shape.size
        let (w, h, t) = (size.x / 2, size.y / 2, size.z / 2)
        let hard = shape.binding == .hardcover
        let board = shape.board
        let overhang: Float = hard ? 0.035 : 0
        let bevel = min(hard ? 0.008 : 0.004, board * 0.6)
        let depth = shape.spineDepth
        let exponent: Float = hard ? 2 : 4
        // Where the boards meet the spine.
        let x0 = -w + depth
        func profile(_ inset: Float) -> [(point: SIMD2<Float>, normal: SIMD2<Float>)] {
            spineProfile(
                x: x0, depth: max(0.001, depth - inset), half: t - inset, exponent: exponent,
                segments: 14)
        }
        let outer = profile(0)
        let beveled = profile(bevel)
        let inner = profile(board)
        // The spine image's v at each profile point: the share of the curve's length up to it,
        // so the image keeps one scale where the curve turns fast and where it runs flat.
        var along: [Float] = [0]
        for index in 1..<outer.count {
            along.append(
                along[index - 1] + simd_distance(outer[index - 1].point, outer[index].point))
        }
        along = along.map { $0 / along[along.count - 1] }
        func point(_ p: SIMD2<Float>, _ y: Float) -> SIMD3<Float> { [p.x, y, p.y] }
        func normal(_ n: SIMD2<Float>) -> SIMD3<Float> { [n.x, 0, n.y] }

        var mesh = BookGeometry()
        let top = h - bevel
        // The spine: its face, the bevels at its head and tail, the cover's edge, and its
        // inside, which shows past the pages at the head and tail.
        for index in 0..<(outer.count - 1) {
            let (a, b) = (outer[index], outer[index + 1])
            let (va, vb) = (along[index], along[index + 1])
            mesh.quad(
                [
                    point(a.point, -top), point(b.point, -top), point(b.point, top),
                    point(a.point, top),
                ],
                normals: [normal(a.normal), normal(b.normal), normal(b.normal), normal(a.normal)],
                coordinates: [
                    [(h + top) / (2 * h), va], [(h + top) / (2 * h), vb],
                    [(h - top) / (2 * h), vb], [(h - top) / (2 * h), va],
                ],
                slot: BookSlot.spine)
            for end: Float in [1, -1] {
                let u: Float = end > 0 ? 0 : 1
                let edge = (h - top) / (2 * h) * end
                let (c, d) = (beveled[index], beveled[index + 1])
                mesh.quad(
                    [
                        point(a.point, top * end), point(b.point, top * end),
                        point(d.point, h * end), point(c.point, h * end),
                    ],
                    normals: [
                        normal(a.normal) + [0, end, 0], normal(b.normal) + [0, end, 0],
                        normal(b.normal) + [0, end, 0], normal(a.normal) + [0, end, 0],
                    ],
                    coordinates: [[u + edge, va], [u + edge, vb], [u, vb], [u, va]],
                    slot: BookSlot.spine)
                let (e, f) = (inner[index], inner[index + 1])
                mesh.quad(
                    [
                        point(c.point, h * end), point(d.point, h * end), point(f.point, h * end),
                        point(e.point, h * end),
                    ],
                    normals: Array(repeating: [0, end, 0], count: 4),
                    coordinates: Array(repeating: .zero, count: 4), slot: BookSlot.cloth)
            }
            let (e, f) = (inner[index], inner[index + 1])
            mesh.quad(
                [point(e.point, -h), point(f.point, -h), point(f.point, h), point(e.point, h)],
                normals: [
                    -normal(e.normal), -normal(f.normal), -normal(f.normal), -normal(e.normal),
                ],
                coordinates: Array(repeating: .zero, count: 4), slot: BookSlot.cloth)
        }
        mesh.addBoards(
            width: w, height: h, thickness: t, spine: x0, board: board, bevel: bevel)
        mesh.addPages(
            fore: w - overhang, head: h - overhang, half: t - board,
            spine: inner.map(\.point))
        return mesh
    }

    /// Adds the front and back boards between the spine at `spine` and the fore edge at
    /// `width`, beveled along their outer edges and at their outer corners.
    private mutating func addBoards(
        width w: Float, height h: Float, thickness t: Float, spine x0: Float, board: Float,
        bevel: Float
    ) {
        let (xe, ye) = (w - bevel, h - bevel)
        for side: Float in [1, -1] {
            let slot = side > 0 ? BookSlot.cover : BookSlot.cloth
            let (zo, zb, zi) = (side * t, side * (t - bevel), side * (t - board))
            // The front cover's image. Past the bevel, a point as deep in the board as the
            // board's edge maps as far back inside the image's border, so the edge shows the
            // border folded over at its own scale rather than its last row stretched.
            func cover(_ p: SIMD3<Float>) -> SIMD2<Float> {
                let fold = max(0, abs(zo - p.z) - bevel)
                var u = (p.x - x0) / (w - x0)
                var v = (p.y + h) / (2 * h)
                if p.x >= w { u = 1 - fold / (w - x0) }
                if abs(p.y) >= h { v = p.y > 0 ? 1 - fold / (2 * h) : fold / (2 * h) }
                return [min(1, max(0, u)), min(1, max(0, v))]
            }
            func face(_ corners: [SIMD3<Float>], _ normal: SIMD3<Float>) {
                if corners.count == 3 {
                    triangle(corners, normal: normal, coordinates: corners.map(cover), slot: slot)
                } else {
                    quad(
                        corners, normals: Array(repeating: normal, count: corners.count),
                        coordinates: corners.map(cover), slot: slot)
                }
            }
            face([[x0, -ye, zo], [xe, -ye, zo], [xe, ye, zo], [x0, ye, zo]], [0, 0, side])
            // Bevels along the fore edge, head, and tail, and at the two outer corners.
            face([[xe, -ye, zo], [w, -ye, zb], [w, ye, zb], [xe, ye, zo]], [1, 0, side])
            face([[x0, ye, zo], [xe, ye, zo], [xe, h, zb], [x0, h, zb]], [0, 1, side])
            face([[x0, -ye, zo], [xe, -ye, zo], [xe, -h, zb], [x0, -h, zb]], [0, -1, side])
            face([[xe, ye, zo], [w, ye, zb], [xe, h, zb]], [1, 1, side])
            face([[xe, -ye, zo], [w, -ye, zb], [xe, -h, zb]], [1, -1, side])
            // The board's edges, and the bevels down its outer corners.
            face([[w, -ye, zb], [w, ye, zb], [w, ye, zi], [w, -ye, zi]], [1, 0, 0])
            face([[x0, h, zb], [xe, h, zb], [xe, h, zi], [x0, h, zi]], [0, 1, 0])
            face([[x0, -h, zb], [xe, -h, zb], [xe, -h, zi], [x0, -h, zi]], [0, -1, 0])
            face([[w, ye, zb], [xe, h, zb], [xe, h, zi], [w, ye, zi]], [1, 1, 0])
            face([[w, -ye, zb], [xe, -h, zb], [xe, -h, zi], [w, -ye, zi]], [1, -1, 0])
            // The inside, which shows past the pages where the board overhangs them.
            let inside: [SIMD3<Float>] = [
                [x0, -h, zi], [xe, -h, zi], [w, -ye, zi], [w, ye, zi], [xe, h, zi], [x0, h, zi],
            ]
            polygon(
                inside, normals: Array(repeating: [0, 0, -side], count: inside.count),
                coordinates: inside.map(cover), slot: slot)
        }
    }

    /// Adds the page block's head, tail, and fore edge: between the boards, `half` to each
    /// side of the middle, out to `fore` and `head`, and rounded like the inside of the spine,
    /// whose cross-section `spine` gives from back to front.
    private mutating func addPages(fore: Float, head: Float, half: Float, spine: [SIMD2<Float>]) {
        let period = Self.pageLinePeriod
        let rim = spine + [[fore, half], [fore, -half]]
        let center = rim.reduce(.zero, +) / Float(rim.count)
        for end: Float in [1, -1] {
            for index in rim.indices {
                let (a, b) = (rim[index], rim[(index + 1) % rim.count])
                let corners: [SIMD3<Float>] = [
                    [center.x, head * end, center.y], [a.x, head * end, a.y],
                    [b.x, head * end, b.y],
                ]
                triangle(
                    corners, normal: [0, end, 0],
                    coordinates: corners.map { [0.5, ($0.z + half) / period] },
                    slot: BookSlot.pages)
            }
        }
        let fore: [SIMD3<Float>] = [
            [fore, -head, -half], [fore, head, -half], [fore, head, half], [fore, -head, half],
        ]
        quad(
            fore, normals: Array(repeating: [1, 0, 0], count: 4),
            coordinates: fore.map { [0.5, ($0.z + half) / period] }, slot: BookSlot.pages)
    }

    /// A ribbon bookmark's loose end for a book of `shape` read to `progress` (0...1): it leaves
    /// the page block at the tail between the pages read and the rest, then droops 1.2 cm
    /// toward the back cover, but not past it, and lies flat. A ribbon that dropped to the
    /// table would vanish under the books beside it in a pile. The ribbon is 7 mm wide, reaches
    /// 4.5 cm past the tail, ends in a notch, and has both sides, in one material.
    static func ribbon(_ shape: BookShape, progress: Float) -> BookGeometry {
        let size = shape.size
        let (w, h, t) = (size.x / 2, size.y / 2, size.z / 2)
        let half = t - shape.board
        let start = half - 2 * half * min(0.95, max(0.05, progress))
        let floor = max(-t + 0.004, start - 0.12)
        let x = -w + 0.25
        let width: Float = 0.035
        let length: Float = 0.45
        let notch: Float = 0.03
        // The path: from inside the pages to the tail, then down to the floor and along it.
        let rows = 12
        let path: [(y: Float, z: Float)] =
            [(-h + 0.3, start)]
            + (0...rows)
            .map { row in
                let s = Float(row) / Float(rows)
                let drop = min(1, s / 0.45)
                return (-h - length * s, start + (floor - start) * drop * drop * (3 - 2 * drop))
            }
        var mesh = BookGeometry()
        for side: Float in [1, -1] {
            for index in 0..<(path.count - 1) {
                let (a, b) = (path[index], path[index + 1])
                let along = simd_normalize(SIMD3(0, b.y - a.y, b.z - a.z))
                let up = simd_cross(along, [1, 0, 0]) * side
                let last = index == path.count - 2
                // The tip's notch makes its outline concave, so the notch's corner comes first:
                // every other corner shows from it, so the fan of triangles from it is valid.
                let corners: [SIMD3<Float>] = [
                    [x, last ? b.y + notch : b.y, b.z], [x - width, b.y, b.z],
                    [x - width, a.y, a.z], [x + width, a.y, a.z], [x + width, b.y, b.z],
                ]
                mesh.polygon(
                    corners, normals: Array(repeating: up, count: corners.count),
                    coordinates: corners.map { [0.5, $0.y] }, slot: 0)
            }
        }
        return mesh
    }
}
