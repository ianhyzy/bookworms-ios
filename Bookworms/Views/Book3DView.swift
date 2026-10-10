import SwiftUI
import simd

/// A book drawn as a lit box in perspective, built from ordinary SwiftUI faces.
///
/// Each visible face is a flat view (cover image, `SpineView`, page edges) mapped onto the
/// screen with the homography that a pinhole camera gives that face. Faces share one camera, so
/// their edges meet exactly, and the whole book stays pure SwiftUI: `ImageRenderer` exports it
/// for share images, which a RealityKit view cannot do.
struct Book3DView: View {
    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    /// The book's height in points. Width follows the cover's aspect ratio; thickness follows
    /// the page count.
    var height: CGFloat
    /// Rotation about the vertical axis in radians. Positive turns the spine toward the viewer.
    var yaw: Double = 0.45
    /// Rotation about the horizontal axis in radians. Negative tips the head toward the viewer.
    var pitch: Double = -0.12

    var body: some View {
        let projection = BookProjection(
            width: height * coverAspect, height: height, thickness: height * book.thicknessRatio,
            yaw: yaw, pitch: pitch)
        ZStack(alignment: .topLeading) {
            ForEach(projection.visibleFaces) { face in
                content(for: face.kind, size: face.size)
                    .frame(width: face.size.width, height: face.size.height)
                    .overlay(Color.black.opacity(face.shade))
                    .projectionEffect(face.transform)
            }
        }
        .frame(
            width: projection.bounds.width, height: projection.bounds.height,
            alignment: .topLeading
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title), by \(book.author)")
    }

    private var coverAspect: CGFloat { Self.aspect(of: cover) }

    /// The book's width-to-height ratio: the cover's, clamped to 0.55...0.85, else 2:3.
    /// Layouts that size a book before drawing it use this, so their space matches the book.
    static func aspect(of cover: UIImage?) -> CGFloat {
        guard let cover, cover.size.height > 0 else { return 2 / 3 }
        return min(0.85, max(0.55, cover.size.width / cover.size.height))
    }

    @ViewBuilder
    private func content(for kind: BookProjection.FaceKind, size: CGSize) -> some View {
        switch kind {
        case .front:
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            } else {
                ZStack {
                    look.background.color
                    Text(look.text(book.spineTitle))
                        .font(look.font(size: size.width * 0.14))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(look.foreground.color)
                        .padding(size.width * 0.12)
                }
            }
        case .back:
            look.background.color
        case .spine:
            SpineView(book: book, look: look)
        case .top, .bottom:
            PageEdgeView(board: look.background.color, linesRunHorizontally: true)
        case .foreEdge:
            PageEdgeView(board: look.background.color, linesRunHorizontally: false)
        }
    }
}

/// Paper leaves seen edge on, framed by the cover boards.
private struct PageEdgeView: View {
    let board: Color
    /// Whether the leaves run along the view's width (head and tail) or its height (fore edge).
    let linesRunHorizontally: Bool

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(red: 0.93, green: 0.90, blue: 0.82)))
            let across = linesRunHorizontally ? size.height : size.width
            let along = linesRunHorizontally ? size.width : size.height
            var seed: UInt32 = 0x9E37_79B9
            var position: CGFloat = 0
            while position < across {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let alpha = Double(seed >> 24) / 255 * 0.12
                let rect =
                    linesRunHorizontally
                    ? CGRect(x: 0, y: position, width: along, height: 0.5)
                    : CGRect(x: position, y: 0, width: 0.5, height: along)
                context.fill(
                    Path(rect),
                    with: .color(Color(red: 0.45, green: 0.38, blue: 0.28, opacity: alpha)))
                position += 1.25
            }
            // The boards: the covers' edges at the front and back of the page block.
            let board = max(1, across * 0.07)
            let edges =
                linesRunHorizontally
                ? [
                    CGRect(x: 0, y: 0, width: along, height: board),
                    CGRect(x: 0, y: size.height - board, width: along, height: board),
                ]
                : [
                    CGRect(x: 0, y: 0, width: board, height: along),
                    CGRect(x: size.width - board, y: 0, width: board, height: along),
                ]
            for edge in edges { context.fill(Path(edge), with: .color(self.board)) }
        }
    }
}

/// The perspective projection of a book-shaped box.
///
/// Coordinates follow SwiftUI: x right, y down, z toward the viewer. The book stands upright with
/// its front cover facing +z and its spine on the left (-x). A pinhole camera sits on the z axis.
struct BookProjection {
    enum FaceKind: CaseIterable { case front, back, spine, foreEdge, top, bottom }

    struct Face: Identifiable {
        let kind: FaceKind
        /// The face view's size in points, equal to the face's size in the model.
        let size: CGSize
        /// Maps the face view's local coordinates to the container's.
        let transform: ProjectionTransform
        /// The opacity of a black overlay that darkens faces turned from the light.
        let shade: Double
        var id: FaceKind { kind }
    }

    let visibleFaces: [Face]
    /// The projected book's size; faces map into `0...width` by `0...height`.
    let bounds: CGSize

    init(width w: CGFloat, height h: CGFloat, thickness t: CGFloat, yaw: Double, pitch: Double) {
        let rotation = Self.rotation(yaw: yaw, pitch: pitch)
        let distance = 3.2 * Double(max(w, h))
        func project(_ point: SIMD3<Double>) -> SIMD2<Double> {
            let p = rotation * point
            let scale = distance / (distance - p.z)
            return SIMD2(p.x * scale, p.y * scale)
        }
        let (x, y, z) = (Double(w) / 2, Double(h) / 2, Double(t) / 2)
        let corners = [-x, x]
            .flatMap { cx in
                [-y, y].flatMap { cy in [-z, z].map { cz in project(SIMD3(cx, cy, cz)) } }
            }
        let minimum = corners.reduce(corners[0]) { simd_min($0, $1) }
        let maximum = corners.reduce(corners[0]) { simd_max($0, $1) }
        bounds = CGSize(width: maximum.x - minimum.x, height: maximum.y - minimum.y)

        // Light from the upper left, in front of the book.
        let light = simd_normalize(SIMD3<Double>(-0.35, -0.6, 0.72))
        let camera = SIMD3<Double>(0, 0, distance)
        visibleFaces = FaceKind.allCases.compactMap { kind in
            // Each face: its local origin, then the model vectors of its local x and y axes.
            let (origin, u, v): (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) =
                switch kind {
                case .front: (SIMD3(-x, -y, z), SIMD3(2 * x, 0, 0), SIMD3(0, 2 * y, 0))
                case .back: (SIMD3(x, -y, -z), SIMD3(-2 * x, 0, 0), SIMD3(0, 2 * y, 0))
                // Head to tail along the spine's length, front to back across it.
                case .spine: (SIMD3(-x, -y, z), SIMD3(0, 2 * y, 0), SIMD3(0, 0, -2 * z))
                case .foreEdge: (SIMD3(x, -y, z), SIMD3(0, 0, -2 * z), SIMD3(0, 2 * y, 0))
                case .top: (SIMD3(-x, -y, -z), SIMD3(2 * x, 0, 0), SIMD3(0, 0, 2 * z))
                case .bottom: (SIMD3(-x, y, z), SIMD3(2 * x, 0, 0), SIMD3(0, 0, -2 * z))
                }
            let o = rotation * origin
            let ru = rotation * u
            let rv = rotation * v
            let normal = simd_normalize(simd_cross(ru, rv))
            guard simd_dot(normal, camera - (o + ru / 2 + rv / 2)) > 0 else { return nil }
            let size = CGSize(width: simd_length(u), height: simd_length(v))
            return Face(
                kind: kind, size: size,
                transform: Self.homography(
                    origin: o, u: ru / Double(size.width), v: rv / Double(size.height),
                    distance: distance, offset: -minimum),
                shade: 0.42 * (1 - max(0, simd_dot(normal, light))))
        }
    }

    /// Rotation by `yaw` about y, then by `pitch` about x.
    static func rotation(yaw: Double, pitch: Double) -> simd_double3x3 {
        let yawMatrix = simd_double3x3(
            rows: [
                SIMD3(cos(yaw), 0, sin(yaw)), SIMD3(0, 1, 0), SIMD3(-sin(yaw), 0, cos(yaw)),
            ])
        let pitchMatrix = simd_double3x3(
            rows: [
                SIMD3(1, 0, 0), SIMD3(0, cos(pitch), -sin(pitch)),
                SIMD3(0, sin(pitch), cos(pitch)),
            ])
        return pitchMatrix * yawMatrix
    }

    /// The projective map from a face's local point `(a, b)`, at model point
    /// `origin + a·u + b·v`, to the screen, shifted by `offset`.
    ///
    /// SwiftUI applies `[a b 1] · M` and divides by the third component, so the camera's
    /// perspective divide, `distance / (distance - z)`, becomes the third column.
    static func homography(
        origin o: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>, distance d: Double,
        offset: SIMD2<Double>
    ) -> ProjectionTransform {
        let w33 = d - o.z
        var m = ProjectionTransform()
        m.m11 = CGFloat((d * u.x - offset.x * u.z) / w33)
        m.m21 = CGFloat((d * v.x - offset.x * v.z) / w33)
        m.m31 = CGFloat((d * o.x + offset.x * w33) / w33)
        m.m12 = CGFloat((d * u.y - offset.y * u.z) / w33)
        m.m22 = CGFloat((d * v.y - offset.y * v.z) / w33)
        m.m32 = CGFloat((d * o.y + offset.y * w33) / w33)
        m.m13 = CGFloat(-u.z / w33)
        m.m23 = CGFloat(-v.z / w33)
        m.m33 = 1
        return m
    }
}
