import ObjectiveC
import SwiftUI
import UIKit
import simd

/// A book drawn as `Book3DView` draws its box, from the same camera and light, with the parts
/// of a bound book: boards as thick as `BookShape` makes them, which overhang the page block on
/// a hardcover, with a headband; a hardcover's French groove or a paperback's hinge score
/// beside the spine; rounded outer edges that catch the light; a contact shadow where the
/// leaves meet the boards; and the cover's art folding a little onto the spine's cloth.
///
/// Flat faces (board edges, page block) are polygons that one `Canvas` per run draws; faces
/// with lettering or art (covers and spine) are views mapped by a homography, as in
/// `Book3DView`. The book's parts are convex, so the parts draw back to front, as the camera's
/// side of the planes between them decides, and each part's back-facing faces are left out.
///
/// The shading, the fold, and the spine's squared corners grow with `lighting`, so a book
/// pulled off the shelf at `lighting` 0 starts as its 2D spine (`SpineView`).
struct BoundBook: View {
    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    var height: CGFloat
    var yaw: Double
    var pitch: Double
    var thicknessRatio: CGFloat?
    var lighting: Double

    var body: some View {
        let model = BoundBookModel(
            book: book, look: look, coverAspect: Book3DView.aspect(of: cover),
            height: Double(height),
            thickness: Double(
                height * (thicknessRatio ?? Book3DView.thicknessRatio(of: book, cover: cover))),
            yaw: yaw, pitch: pitch, lighting: lighting)
        let edge = cover?.spineEdgeColors ?? []
        ZStack(alignment: .topLeading) {
            ForEach(model.items.indices, id: \.self) { index in
                switch model.items[index] {
                case .marks(let marks):
                    Canvas { context, _ in
                        for mark in marks { mark.draw(in: &context) }
                    }
                    .frame(width: model.bounds.width, height: model.bounds.height)
                case .sheet(let sheet):
                    sheetView(sheet, model, edge: edge)
                }
            }
        }
        .frame(width: model.bounds.width, height: model.bounds.height, alignment: .topLeading)
    }

    private func sheetView(
        _ sheet: BoundBookModel.Sheet, _ model: BoundBookModel, edge: [ColorValue]
    )
        -> some View
    {
        content(sheet, model, edge: edge)
            .frame(width: sheet.size.width, height: sheet.size.height)
            .overlay(Color.black.opacity(sheet.base))
            .overlay {
                if let across = sheet.across {
                    LinearGradient(stops: across, startPoint: .leading, endPoint: .trailing)
                }
            }
            .overlay {
                if let along = sheet.along {
                    LinearGradient(stops: along, startPoint: .top, endPoint: .bottom)
                }
            }
            // Lettering that overflows the spine would otherwise show on the covers.
            .clipShape(.rect)
            // One layer, so the shading's edges match the content's under the projection;
            // drawn apart, an unshaded sliver shows at each edge.
            .compositingGroup()
            .projectionEffect(sheet.transform)
    }

    @ViewBuilder
    private func content(_ sheet: BoundBookModel.Sheet, _ model: BoundBookModel, edge: [ColorValue])
        -> some View
    {
        switch sheet.content {
        case .front:
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill()
                    .frame(width: sheet.size.width, height: sheet.size.height).clipped()
                    .overlay {
                        if !edge.isEmpty {
                            coverFold(edge, model, size: sheet.size).opacity(lighting)
                        }
                    }
            } else {
                BookFrontPlaceholder(book: book, look: look, width: sheet.size.width)
            }
        case .back:
            look.background.color
        case .spine:
            // The cloth squares `SpineView`'s corners as the shading fades in.
            SpineView(book: book, look: look)
                .background(
                    RoundedRectangle(
                        cornerRadius: SpineView.cornerRadius(thickness: sheet.size.height)
                            * (1 - lighting)
                    )
                    .fill(look.background.color)
                )
                .overlay(alignment: .top) {
                    if !edge.isEmpty {
                        LinearGradient(
                            colors: edge.map(\.color), startPoint: .leading, endPoint: .trailing
                        )
                        .mask(
                            Self.fade(
                                0.5, reach: model.spineReach, length: sheet.size.height,
                                from: .top, to: .bottom)
                        )
                        .opacity(lighting)
                    }
                }
        }
    }

    /// The fold onto the front board: the cover's edge colors, then the cloth at half
    /// strength, fading out across `BoundBookModel.coverReach` from the joint.
    private func coverFold(_ edge: [ColorValue], _ model: BoundBookModel, size: CGSize)
        -> some View
    {
        let fade = { (opacity: Double) in
            Self.fade(
                opacity, reach: model.coverReach, length: size.width, from: .leading,
                to: .trailing)
        }
        return ZStack {
            LinearGradient(colors: edge.map(\.color), startPoint: .top, endPoint: .bottom)
                .mask(fade(1))
            look.background.color.mask(fade(0.5))
        }
    }

    /// A mask that eases from `opacity` to clear across `reach` points of a side `length` long.
    static func fade(
        _ opacity: Double, reach: Double, length: Double, from start: UnitPoint, to end: UnitPoint
    ) -> LinearGradient {
        let stops = stride(from: 0.0, through: 1, by: 0.125)
            .map { share in
                let eased = share * share * (3 - 2 * share)
                return Gradient.Stop(
                    color: .black.opacity(opacity * (1 - eased)),
                    location: min(1, reach * share / length))
            }
        return LinearGradient(
            stops: [.init(color: .black.opacity(opacity), location: 0)] + stops,
            startPoint: start, endPoint: end)
    }
}

/// The faces of `BoundBook`'s book, in drawing order, projected as `BookProjection` projects
/// its box: the same bounds, camera, and light.
///
/// Coordinates follow `BookProjection`: x from the spine (-x) to the fore edge, y from the
/// head (-y) to the tail, and z toward the front cover. Physical sizes (boards, squares) come
/// from `BookShape`, in proportion to the drawn height, so a thick stacked spine keeps boards
/// in proportion.
struct BoundBookModel {
    enum Item {
        case marks([Mark])
        case sheet(Sheet)
    }

    /// A projected polygon or line that a `Canvas` draws.
    struct Mark {
        enum Paint {
            case color(Color)
            case gradient(Gradient, CGPoint, CGPoint)
            case line(Color, CGFloat)
        }

        let path: Path
        let paint: Paint

        func draw(in context: inout GraphicsContext) {
            switch paint {
            case .color(let color):
                context.fill(path, with: .color(color))
                // Closes the hairline that antialiasing leaves between adjacent faces.
                context.stroke(path, with: .color(color), lineWidth: 0.6)
            case .gradient(let gradient, let start, let end):
                let shading = GraphicsContext.Shading.linearGradient(
                    gradient, startPoint: start, endPoint: end)
                context.fill(path, with: shading)
                context.stroke(path, with: shading, lineWidth: 0.6)
            case .line(let color, let width):
                context.stroke(path, with: .color(color), lineWidth: width)
            }
        }
    }

    enum Content { case front, back, spine }

    /// A face drawn as a view and mapped onto the book by `transform`.
    struct Sheet {
        let content: Content
        let size: CGSize
        let transform: ProjectionTransform
        /// The black overlay's opacity for the face's own normal.
        var base: Double
        /// Shading along the view's width and height: black for darker, white for lighter.
        var across: [Gradient.Stop]? = nil
        var along: [Gradient.Stop]? = nil
    }

    /// The share of the spine's thickness that the fold's colors cover from the front joint.
    /// It ends before `SpineView`'s bands and lettering, so `SpineContrast`'s check of the
    /// lettering against the flat cloth still holds.
    static let spineFold = 0.09

    private(set) var items: [Item] = []
    let bounds: CGSize
    /// How far the fold reaches onto the spine from the front joint, and onto the front board,
    /// in points.
    let spineReach: Double
    let coverReach: Double

    init(
        book: CloudBook, look: SpineLook, coverAspect: CGFloat, height: Double,
        thickness: Double, yaw: Double, pitch: Double, lighting: Double
    ) {
        let (bigX, bigY, bigZ) = (height * Double(coverAspect) / 2, height / 2, thickness / 2)
        let camera = BookCamera(
            width: 2 * bigX, height: height, thickness: thickness, yaw: yaw, pitch: pitch,
            lighting: lighting)
        bounds = camera.bounds
        let shape = BookShape(of: book, coverAspect: coverAspect)
        let hard = shape.binding == .hardcover
        let mm = height / Double(shape.size.y) / 100

        let board = min(hard ? 2.8 * mm : 0.8 * mm, thickness * (hard ? 0.18 : 0.1))
        // How far a hardcover's boards overhang the page block.
        let square = hard ? 3.5 * mm : 0
        let bevel = max(1, 1.2 * mm)
        let cloth = look.background
        spineReach = Self.spineFold * thickness
        coverReach = 3 * mm

        // MARK: Boards

        func boardPart(front: Bool) -> [Item] {
            let side: Double = front ? 1 : -1
            let (outside, inside) = (side * bigZ, side * (bigZ - board))
            let face = SIMD3<Double>(0, 0, side)
            var items: [Item] = []
            let width = 2 * bigX
            if camera.sees([0, 0, outside], facing: face) {
                let origin: SIMD3<Double> =
                    front ? [-bigX, -bigY, outside] : [bigX, -bigY, outside]
                let u: SIMD3<Double> = [front ? width : -width, 0, 0]
                let v: SIMD3<Double> = [0, height, 0]
                // Along the width: the joint and the fold by the spine, and the fore edge's
                // rounding.
                let spineSide =
                    Self.groove(camera: camera, face: face, hard: hard, mm: mm)
                    + Self.bevel(camera: camera, face: face, toward: [-1, 0, 0], width: bevel)
                let foreSide = Self.bevel(
                    camera: camera, face: face, toward: [1, 0, 0], width: bevel)
                let size = CGSize(width: width, height: height)
                items.append(
                    .sheet(
                        Sheet(
                            content: front ? .front : .back, size: size,
                            transform: camera.transform(origin: origin, u: u, v: v, size: size),
                            base: camera.shade(face),
                            across: Self.stops(
                                length: width, start: front ? spineSide : foreSide,
                                end: front ? foreSide : spineSide),
                            along: Self.stops(
                                length: height,
                                start: Self.bevel(
                                    camera: camera, face: face, toward: [0, -1, 0], width: bevel),
                                end: Self.bevel(
                                    camera: camera, face: face, toward: [0, 1, 0], width: bevel))
                        )))
            }
            var marks: [Mark] = []
            // The board's rim: head, tail, and fore edge, each rounded across its thickness.
            func rim(_ normal: SIMD3<Double>, _ corners: [SIMD3<Double>]) {
                guard camera.sees(corners.reduce(.zero, +) / 4, facing: normal) else { return }
                let out = simd_normalize(normal + face)
                let back = simd_normalize(normal - face)
                let shades = [out, normal, normal, back].map(camera.shade)
                let gradient = Gradient(
                    stops: zip(shades, [0, 0.35, 0.65, 1])
                        .map { .init(color: cloth.shaded($0), location: $1) })
                marks.append(
                    Mark(
                        path: camera.path(corners),
                        paint: .gradient(
                            gradient, camera.point((corners[0] + corners[1]) / 2),
                            camera.point((corners[2] + corners[3]) / 2))))
            }
            for y in [-bigY, bigY] {
                rim(
                    [0, y.sign == .minus ? -1 : 1, 0],
                    [
                        [-bigX, y, outside], [bigX, y, outside], [bigX, y, inside],
                        [-bigX, y, inside],
                    ]
                )
            }
            rim(
                [1, 0, 0],
                [
                    [bigX, -bigY, outside], [bigX, bigY, outside], [bigX, bigY, inside],
                    [bigX, -bigY, inside],
                ])
            // The board's inside, which shows where it overhangs the pages.
            if square > 0, camera.sees([0, 0, inside], facing: -face) {
                let outline: [SIMD3<Double>] = [
                    [-bigX, -bigY, inside], [bigX, -bigY, inside], [bigX, bigY, inside],
                    [-bigX, bigY, inside],
                ]
                marks.append(
                    Mark(
                        path: camera.path(outline),
                        paint: .color(
                            cloth.shaded(min(0.6, camera.shade(-face) + 0.12 * lighting)))))
            }
            if !marks.isEmpty { items.append(.marks(marks)) }
            return items
        }

        // MARK: Page block

        func blockPart() -> [Item] {
            var marks: [Mark] = []
            let half = bigZ - board
            let (head, tail, fore) = (-bigY + square, bigY - square, bigX - square)
            func pages(_ normal: SIMD3<Double>, _ corners: [SIMD3<Double>]) {
                let center = corners.reduce(.zero, +) / Double(corners.count)
                guard camera.sees(center, facing: normal) else { return }
                marks.append(
                    Mark(
                        path: camera.path(corners),
                        paint: .color(PageEdges.fresh.shaded(camera.shade(normal)))))
                marks += Self.leaves(in: corners, half: half, camera: camera)
                // Contact shadow along the boards, where the leaves meet them.
                for side: Double in [1, -1] {
                    let edge = corners.filter { abs($0.z - side * half) < 0.01 }
                    guard edge.count == 2 else { continue }
                    let reach = min(half * 0.5, 2.5 * mm + square * 0.5)
                    let inward = SIMD3<Double>(0, 0, -side * reach)
                    let band = [edge[0], edge[1], edge[1] + inward, edge[0] + inward]
                    let mid = (edge[0] + edge[1]) / 2
                    marks.append(
                        Mark(
                            path: camera.path(band),
                            paint: .gradient(
                                Gradient(colors: [
                                    .black.opacity((square > 0 ? 0.3 : 0.2) * lighting), .clear,
                                ]), camera.point(mid), camera.point(mid + inward))))
                }
            }
            for (y, normal) in [(head, SIMD3<Double>(0, -1, 0)), (tail, SIMD3<Double>(0, 1, 0))] {
                pages(
                    normal,
                    [[fore, y, half], [fore, y, -half], [-bigX, y, -half], [-bigX, y, half]])
                if square > 0 {
                    marks += Self.headband(
                        from: [-bigX, half], to: [-bigX, -half],
                        y: y + (y < 0 ? -0.8 * mm : 0.8 * mm), width: 1.6 * mm, normal: normal,
                        look: look, camera: camera)
                }
            }
            pages(
                [1, 0, 0],
                [
                    [fore, head, half], [fore, tail, half], [fore, tail, -half],
                    [fore, head, -half],
                ])
            return marks.isEmpty ? [] : [.marks(marks)]
        }

        // MARK: Spine

        func spinePart() -> [Item] {
            let normal = SIMD3<Double>(-1, 0, 0)
            guard camera.sees([-bigX, 0, 0], facing: normal) else { return [] }
            let size = CGSize(width: height, height: thickness)
            return [
                .sheet(
                    Sheet(
                        content: .spine, size: size,
                        transform: camera.transform(
                            origin: [-bigX, -bigY, bigZ], u: [0, height, 0],
                            v: [0, 0, -thickness], size: size),
                        base: 0,
                        // The head's and tail's rounding.
                        across: Self.stops(
                            length: height,
                            start: Self.bevel(
                                camera: camera, face: normal, toward: [0, -1, 0], width: bevel),
                            end: Self.bevel(
                                camera: camera, face: normal, toward: [0, 1, 0], width: bevel)),
                        // The folds into the covers, over the face's own shade.
                        along: Self.stops(
                            length: thickness,
                            start: Self.bevel(
                                camera: camera, face: normal, toward: [0, 0, 1], width: bevel),
                            end: Self.bevel(
                                camera: camera, face: normal, toward: [0, 0, -1], width: bevel),
                            base: camera.shade(normal))))
            ]
        }

        // MARK: Order

        let eye = camera.eye
        let front = boardPart(front: true)
        let back = boardPart(front: false)
        let block = blockPart()
        var stack: [Item]
        if eye.z > bigZ - board {
            stack = back + block + front
        } else if eye.z < -(bigZ - board) {
            stack = front + block + back
        } else {
            stack = block + back + front
        }
        let spine = spinePart()
        stack = eye.x < -bigX ? stack + spine : spine + stack
        // Adjacent canvases merge into one.
        for item in stack {
            if case .marks(let marks) = item, case .marks(let previous)? = items.last {
                items[items.count - 1] = .marks(previous + marks)
            } else {
                items.append(item)
            }
        }
    }

    // MARK: Helpers

    /// Relative shading across a rounded edge `width` wide, from the edge inward: the normal
    /// turns from halfway to `toward` back to the face's.
    static func bevel(
        camera: BookCamera, face: SIMD3<Double>, toward: SIMD3<Double>, width: Double
    ) -> [(Double, Double)] {
        let base = camera.shade(face) - camera.gloss(face)
        return [0, 0.25, 0.5, 0.75, 1]
            .map { share in
                let angle = Double.pi / 4 * (1 - share)
                let normal = simd_normalize(face * cos(angle) + toward * sin(angle))
                return (
                    share * width, (camera.shade(normal) - camera.gloss(normal) - base) * 1.4
                )
            }
    }

    /// Relative shading across a hardcover's French groove, 6 mm wide and 1.2 mm deep, or a
    /// paperback's hinge score 5 mm from the spine, from the spine's side outward.
    static func groove(camera: BookCamera, face: SIMD3<Double>, hard: Bool, mm: Double)
        -> [(Double, Double)]
    {
        let (start, width, depth) = hard ? (0.0, 6 * mm, 1.2 * mm) : (5 * mm, 1.4 * mm, 0.3 * mm)
        let base = camera.shade(face)
        let away = SIMD3<Double>(1, 0, 0)
        return (0...10)
            .map { step in
                let share = Double(step) / 10
                // The groove's floor follows a cosine, so its walls meet the board smoothly.
                let slope = depth * .pi / width * sin(2 * .pi * share)
                let normal = simd_normalize(face + away * slope)
                let floor = 0.06 * camera.lighting * (1 - cos(2 * .pi * share)) / 2
                return (start + share * width, (camera.shade(normal) - base) * 1.3 + floor)
            }
    }

    /// Gradient stops along a side `length` long, from relative shading samples measured in
    /// from its `start` and `end`. `base` adds a face's own shade for a gradient that replaces
    /// the face's overlay.
    static func stops(
        length: Double, start: [(Double, Double)], end: [(Double, Double)], base: Double = 0
    ) -> [Gradient.Stop] {
        var samples = start.map { ($0.0 / length, $0.1) }
        samples += end.map { (1 - $0.0 / length, $0.1) }
        return samples.sorted { $0.0 < $1.0 }
            .map { location, shade in
                let value = shade + base
                let color = value >= 0 ? Color.black.opacity(value) : .white.opacity(-value)
                return Gradient.Stop(color: color, location: min(1, max(0, location)))
            }
    }

    /// The leaves of a page face: lines where planes parallel to the covers cut it, every 1.25
    /// points across the block, as `Book3DView`'s page edges draw them.
    static func leaves(in corners: [SIMD3<Double>], half: Double, camera: BookCamera) -> [Mark] {
        var marks: [Mark] = []
        var seed: UInt32 = 0x9E37_79B9
        var z = -half + 0.6
        while z < half {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let alpha = Double(seed >> 24) / 255 * 0.12
            var cuts: [SIMD3<Double>] = []
            for index in corners.indices {
                let a = corners[index]
                let b = corners[(index + 1) % corners.count]
                guard (a.z - z) * (b.z - z) < 0 else { continue }
                cuts.append(a + (b - a) * ((z - a.z) / (b.z - a.z)))
            }
            if cuts.count >= 2 {
                marks.append(
                    Mark(
                        path: camera.path([cuts[0], cuts[1]], closed: false),
                        paint: .line(
                            Color(red: 0.45, green: 0.38, blue: 0.28, opacity: alpha), 0.5)))
            }
            z += 1.25
        }
        return marks
    }

    /// A hardcover's headband: a striped cord along the page block's spine side, from `start`
    /// to `end` in the x–z plane, raised a little above the pages.
    static func headband(
        from start: SIMD2<Double>, to end: SIMD2<Double>, y: Double, width: Double,
        normal: SIMD3<Double>, look: SpineLook, camera: BookCamera
    ) -> [Mark] {
        guard camera.sees([start.x, y, 0], facing: normal) else { return [] }
        let shade = camera.shade(normal)
        let colors = [look.accent.shaded(shade), look.foreground.shaded(shade)]
        let pieces = max(1, Int((simd_distance(start, end) / 1.4).rounded()))
        return (0..<pieces)
            .map { piece in
                let p = start + (end - start) * (Double(piece) / Double(pieces))
                let q = start + (end - start) * (Double(piece + 1) / Double(pieces))
                let band: [SIMD2<Double>] = [p, q, q + [width, 0], p + [width, 0]]
                return Mark(
                    path: camera.path(band.map { [$0.x, y, $0.y] }),
                    paint: .color(colors[piece % 2]))
            }
    }
}

/// `BookProjection`'s camera and light for a box of the given size, with a specular highlight
/// for rounded edges.
struct BookCamera {
    static let light = simd_normalize(SIMD3<Double>(-0.35, -0.6, 0.72))
    static let halfway = simd_normalize(light + SIMD3<Double>(0, 0, 1))

    let rotation: simd_double3x3
    let distance: Double
    let lighting: Double
    /// Shifts projected points into the view, as `BookProjection` does.
    let offset: SIMD2<Double>
    let bounds: CGSize

    init(
        width: Double, height: Double, thickness: Double, yaw: Double, pitch: Double,
        lighting: Double
    ) {
        rotation = BookProjection.rotation(yaw: yaw, pitch: pitch)
        distance = 3.2 * max(width, height)
        self.lighting = lighting
        let (x, y, z) = (width / 2, height / 2, thickness / 2)
        var low = SIMD2<Double>(repeating: .infinity)
        var high = SIMD2<Double>(repeating: -.infinity)
        for cx in [-x, x] {
            for cy in [-y, y] {
                for cz in [-z, z] {
                    let q = rotation * SIMD3(cx, cy, cz)
                    let point = SIMD2(q.x, q.y) * (distance / (distance - q.z))
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                }
            }
        }
        offset = -low
        bounds = CGSize(width: high.x - low.x, height: high.y - low.y)
    }

    /// The camera's position in the book's coordinates.
    var eye: SIMD3<Double> { rotation.transpose * SIMD3(0, 0, distance) }

    func point(_ p: SIMD3<Double>) -> CGPoint {
        let q = rotation * p
        let scale = distance / (distance - q.z)
        return CGPoint(x: q.x * scale + offset.x, y: q.y * scale + offset.y)
    }

    func path(_ points: [SIMD3<Double>], closed: Bool = true) -> Path {
        Path { path in
            path.addLines(points.map(point))
            if closed { path.closeSubpath() }
        }
    }

    func sees(_ point: SIMD3<Double>, facing normal: SIMD3<Double>) -> Bool {
        simd_dot(rotation * normal, SIMD3(0, 0, distance) - rotation * point) > 0
    }

    /// `BookProjection`'s shade for a face with `normal`, scaled by `lighting`.
    func shade(_ normal: SIMD3<Double>) -> Double {
        let turned = simd_normalize(rotation * normal)
        return 0.42 * (1 - max(0, simd_dot(turned, Self.light))) * lighting
    }

    /// A soft specular highlight, for rounded edges that catch the light.
    func gloss(_ normal: SIMD3<Double>) -> Double {
        let turned = simd_normalize(rotation * normal)
        return 0.3 * pow(max(0, simd_dot(turned, Self.halfway)), 16) * lighting
    }

    func transform(origin: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>, size: CGSize)
        -> ProjectionTransform
    {
        BookProjection.homography(
            origin: rotation * origin, u: rotation * u / Double(size.width),
            v: rotation * v / Double(size.height), distance: distance, offset: offset)
    }
}

/// The colors down a cover's spine-side edge, head to tail, for `BoundBook`'s fold.
enum CoverEdge {
    /// Averages the art 2 to 4 percent in from the left edge, past the frame lines that scans
    /// often carry at the very edge, in 48 rows, and softens them along the height. It redraws
    /// the cover once at 50 by 48 pixels; an unreadable image gives no colors.
    nonisolated static func colors(of image: CGImage) -> [ColorValue] {
        let (width, rows) = (50, 48)
        var pixels = [UInt8](repeating: 0, count: width * rows * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: rows, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: rows))
            return true
        }
        guard drew else { return [] }
        // The bitmap's first row is the image's top, the head.
        let column = (0..<rows)
            .map { row in
                let offset = (row * width + 1) * 4
                return SIMD3(
                    Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
            }
        let weights: [Double] = [1, 4, 6, 4, 1]
        return (0..<rows)
            .map { row in
                var sum = SIMD3<Double>.zero
                for (index, weight) in weights.enumerated() {
                    sum += column[min(rows - 1, max(0, row + index - 2))] * weight
                }
                let color = (sum / 16).rounded(.toNearestOrAwayFromZero)
                return ColorValue(red: Int(color.x), green: Int(color.y), blue: Int(color.z))
            }
    }

    /// Holds an image's colors as its associated object.
    fileprivate final class Box: Sendable {
        let colors: [ColorValue]
        init(_ colors: [ColorValue]) { self.colors = colors }
    }

    nonisolated(unsafe) fileprivate static var key: UInt8 = 0
}

extension UIImage {
    /// The colors down the cover's spine-side edge (`CoverEdge.colors(of:)`), sampled once per
    /// image and kept with it. `CoverStore` samples them as it decodes a cover, off the main
    /// actor; another image samples them where it is first drawn, which takes about a
    /// millisecond.
    nonisolated var spineEdgeColors: [ColorValue] {
        if let box = withUnsafePointer(to: &CoverEdge.key, { objc_getAssociatedObject(self, $0) })
            as? CoverEdge.Box
        {
            return box.colors
        }
        let colors = cgImage.map(CoverEdge.colors(of:)) ?? []
        withUnsafePointer(to: &CoverEdge.key) {
            objc_setAssociatedObject(
                self, $0, CoverEdge.Box(colors), .OBJC_ASSOCIATION_RETAIN)
        }
        return colors
    }
}

extension ColorValue {
    /// The color under a black overlay of opacity `shade`.
    fileprivate func shaded(_ shade: Double) -> Color {
        let light = 1 - min(1, max(0, shade))
        return Color(
            red: Double(red) / 255 * light, green: Double(green) / 255 * light,
            blue: Double(blue) / 255 * light)
    }
}
