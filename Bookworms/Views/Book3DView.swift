import SwiftUI
import simd

/// A book drawn as a lit box in perspective, built from ordinary SwiftUI faces, or as a bound
/// book with boards, joint, and rounded edges (`BoundBook`).
///
/// Each visible face is a flat view (cover image, `SpineView`, page edges) mapped onto the
/// screen with the homography that a pinhole camera gives that face. Faces share one camera, so
/// their edges meet exactly, and the whole book stays pure SwiftUI: `ImageRenderer` exports it
/// for share images, which a RealityKit view cannot do.
struct Book3DView: View {
    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    /// The book's height in points. Width follows the cover's aspect ratio, and thickness is in
    /// the proportion to the height that the 3D views give the book (`BookShape`).
    var height: CGFloat
    /// Rotation about the vertical axis in radians. Positive turns the spine toward the viewer.
    var yaw: Double = 0.45
    /// Rotation about the horizontal axis in radians. Negative tips the head toward the viewer.
    var pitch: Double = -0.12
    /// The thickness as a share of the height, or `nil` for the book's own proportion. A shelf's
    /// spine is thicker than its book (`CloudBook.shelfSpineSize(scale:)`), so a book pulled off
    /// the shelf starts at the spine's proportion.
    var thicknessRatio: CGFloat? = nil
    /// How much of the light's shading the faces show, from 0, every face evenly lit as a flat
    /// spine on the shelf is, to 1. A book pulled off the shelf starts unshaded, as its spine.
    var lighting: Double = 1
    /// Whether the book draws its binding (`BoundBook`). **Stack**, which draws many books at
    /// once while it scrolls, draws plain boxes, which cost about half as much, except for the
    /// book being pulled out.
    var bound = true
    /// The camera's distance from the book's center in points, or `nil` for the details'
    /// camera (`BookProjection.standardDistance`).
    var distance: CGFloat? = nil
    /// Where the camera sits across from the book's center, in points (`BookProjection`).
    var eye = SIMD2<Double>.zero
    /// For a plain box in a scroll view, where the scroll view's camera looks out from. The box
    /// follows that eye at render time, so a scrolling stack's books turn their tops and
    /// undersides to one eye without updating their bodies. It replaces `eye`.
    var scrollEye: ScrollEye? = nil

    var body: some View {
        Group {
            if bound {
                BoundBook(
                    book: book, look: look, cover: cover, height: height, yaw: yaw, pitch: pitch,
                    thicknessRatio: thicknessRatio, lighting: lighting,
                    distance: distance.map(Double.init),
                    eye: eye)
            } else {
                box
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title), by \(book.author)")
    }

    private var box: some View {
        let projection = BookProjection(
            width: height * coverAspect, height: height,
            thickness: height * (thicknessRatio ?? Self.thicknessRatio(of: book, cover: cover)),
            yaw: yaw, pitch: pitch, distance: distance.map(Double.init), eye: eye)
        let camera = projection.camera
        return ZStack(alignment: .topLeading) {
            ForEach(scrollEye == nil ? projection.visibleFaces : projection.faces) { face in
                let shaded = content(for: face.kind, size: face.size)
                    .frame(width: face.size.width, height: face.size.height)
                    .overlay(Color.black.opacity(face.shade * lighting))
                if let scrollEye {
                    shaded.projectionEffect(face.transform)
                        .visualEffect { content, proxy in
                            // Every face view starts at the box's origin, so its coordinates are
                            // the box's.
                            let eye = camera.eye(at: scrollEye.point(in: proxy))
                            let correction = camera.correction(of: face, from: eye)
                            let opacity: Double = camera.shows(face, from: eye) ? 1 : 0
                            return content.transformEffect(correction).opacity(opacity)
                        }
                } else {
                    shaded.projectionEffect(face.transform)
                }
            }
        }
        .frame(
            width: projection.bounds.width, height: projection.bounds.height,
            alignment: .topLeading
        )
    }

    private var coverAspect: CGFloat { Self.aspect(of: cover) }

    /// The book's thickness as a share of its height, in the proportion the 3D views give it
    /// (`BookShape`).
    static func thicknessRatio(of book: CloudBook, cover: UIImage?) -> CGFloat {
        let size = BookShape(of: book, coverAspect: aspect(of: cover)).size
        return CGFloat(size.z / size.y)
    }

    /// The width-to-height ratios that `aspect(of:)` allows.
    static let aspects: ClosedRange<CGFloat> = 0.55...0.85

    /// The book's width-to-height ratio: the cover's, clamped to `aspects`, else 2:3.
    /// Layouts that size a book before drawing it use this, so their space matches the book.
    static func aspect(of cover: UIImage?) -> CGFloat {
        guard let cover, cover.size.height > 0 else { return 2 / 3 }
        return min(
            aspects.upperBound, max(aspects.lowerBound, cover.size.width / cover.size.height))
    }

    @ViewBuilder
    private func content(for kind: BookProjection.FaceKind, size: CGSize) -> some View {
        switch kind {
        case .front:
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            } else {
                BookFrontPlaceholder(book: book, look: look, width: size.width)
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

/// The front of a book without a cover: its title on the spine's cloth, sized to the front's
/// `width`. `Book3DView` shades it with the other faces; the pile draws it flat and lets
/// RealityKit light it.
struct BookFrontPlaceholder: View {
    let book: CloudBook
    let look: SpineLook
    let width: CGFloat

    var body: some View {
        ZStack {
            look.background.color
            BookText(look.text(book.spineTitle), of: book, on: look)
                .font(look.font(size: width * 0.14))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
                .foregroundStyle(look.foreground.color)
                .padding(width * 0.12)
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

/// Where a scroll view's camera looks out from, for a box that follows it
/// (`Book3DView.scrollEye`).
struct ScrollEye: Sendable, Equatable {
    /// The eye's point in the scroll view's visible coordinates
    /// (`NamedCoordinateSpace.scrollView`).
    var point: CGPoint
    /// How far the box turns in the screen's plane on its way to the scroll view, as
    /// `rotationEffect` turns it. On the way, the box may also be scaled evenly and moved, but
    /// not otherwise transformed.
    var roll: Double

    /// `point` in the coordinates of the view that `proxy` measures.
    ///
    /// A geometry proxy cannot convert the scroll view's bounds through a turn, so this undoes
    /// the turn and scale from the view's frame in the scroll view, which bounds the turned view.
    func point(in proxy: GeometryProxy) -> CGPoint {
        point(inViewOf: proxy.size, framed: proxy.frame(in: .scrollView))
    }

    /// `point` in the coordinates of a view `size` big whose turned and scaled drawing `frame`
    /// bounds in the scroll view.
    func point(inViewOf size: CGSize, framed frame: CGRect) -> CGPoint {
        let (cosine, sine) = (cos(roll), sin(roll))
        let corners = [
            CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height),
            CGPoint(x: size.width, y: size.height),
        ]
        .map { CGPoint(x: $0.x * cosine - $0.y * sine, y: $0.x * sine + $0.y * cosine) }
        let low = CGPoint(x: corners.map(\.x).min()!, y: corners.map(\.y).min()!)
        let span = max(corners.map(\.x).max()! - low.x, corners.map(\.y).max()! - low.y)
        let scale = max(frame.width, frame.height) / max(span, .ulpOfOne)
        // The turned view's top-leading corner lies at `frame.origin`.
        let turned = CGPoint(
            x: (self.point.x - frame.minX) / scale + low.x,
            y: (self.point.y - frame.minY) / scale + low.y)
        return CGPoint(
            x: turned.x * cosine + turned.y * sine, y: -turned.x * sine + turned.y * cosine)
    }
}

/// The perspective projection of a book-shaped box.
///
/// Coordinates follow SwiftUI: x right, y down, z toward the viewer. The book stands upright with
/// its front cover facing +z and its spine on the left (-x). A pinhole camera sits `distance` in
/// front of the book's center. By default it sits on the z axis, as the details see their book;
/// `eye` moves it across, as one camera sees every book of **Stack** (`StackCamera`). The camera
/// moves within the plane square to the view, so points on the plane through the spine's center
/// project where they would with the camera on the axis: a stacked book's spine stays in its
/// place while its top or underside comes into view. `bounds` and every face's view space are
/// those of the camera on the axis, so a book keeps its layout as the eye moves, and faces the eye
/// reveals draw past them.
struct BookProjection {
    enum FaceKind: CaseIterable { case front, back, spine, foreEdge, top, bottom }

    /// The camera's distance from the book's center, in the longer of its width and height,
    /// unless the caller places the camera.
    static let standardDistance = 3.2

    struct Face: Identifiable, Sendable {
        let kind: FaceKind
        /// The face view's size in points, equal to the face's size in the model.
        let size: CGSize
        /// Maps the face view's local coordinates to the container's, seen from the projection's
        /// `eye`.
        fileprivate(set) var transform = ProjectionTransform()
        /// The opacity of a black overlay that darkens faces turned from the light.
        let shade: Double
        /// The face's corner, its axes per point of the face view, its center, and its outward
        /// normal, all turned toward the camera, from the book's center.
        fileprivate let origin: SIMD3<Double>
        fileprivate let u: SIMD3<Double>
        fileprivate let v: SIMD3<Double>
        fileprivate let center: SIMD3<Double>
        fileprivate let normal: SIMD3<Double>
        /// How much the camera on the axis magnifies the face at each point of the container:
        /// `x * depth.x + y * depth.y + depth.z`, since its inverse depth varies linearly over
        /// the projected plane.
        fileprivate let depth: SIMD3<Double>
        var id: FaceKind { kind }
    }

    /// The camera, apart from where `eye` places it across the view.
    struct Camera: Sendable, Equatable {
        /// The distance from the book's center along the view.
        let distance: Double
        /// The depth of the spine's center, whose plane the eye's offset leaves in place.
        let anchor: Double
        /// Shifts projected points into the view.
        let offset: SIMD2<Double>

        /// Where an eye that looks out from `point` in the view's coordinates sits across from
        /// the book's center, in the plane through the spine's center.
        func eye(at point: CGPoint) -> SIMD2<Double> {
            // The view magnifies that plane by `distance / (distance - anchor)`.
            (SIMD2(point.x, point.y) - offset) * (distance - anchor) / distance
        }

        func shows(_ face: Face, from eye: SIMD2<Double>) -> Bool {
            simd_dot(face.normal, SIMD3(eye.x, eye.y, distance) - face.center) > 0
        }

        /// What turns the face that the camera on the axis projects into the face that `eye`
        /// sees, in the container's coordinates.
        ///
        /// `transform(of:from:)` moves each point by `-eye` times its depth in front of the
        /// spine's plane over `distance - anchor`, before projecting it; once projected, that is
        /// `-eye * (k - distance / (distance - anchor))` for a point the camera on the axis
        /// magnifies by `k`. Over a face, `k` is linear (`Face.depth`), so the change is affine,
        /// which a visual effect can apply; it cannot apply a projective transform.
        func correction(of face: Face, from eye: SIMD2<Double>) -> CGAffineTransform {
            let (a, b) = (face.depth.x, face.depth.y)
            let c = face.depth.z - distance / (distance - anchor)
            return CGAffineTransform(
                a: 1 - eye.x * a, b: -eye.y * a, c: -eye.x * b, d: 1 - eye.y * b,
                tx: -eye.x * c, ty: -eye.y * c)
        }

        /// The map from `face`'s view to the container's, seen from `eye`.
        ///
        /// An eye across from the axis sees what the camera on the axis sees of the box sheared
        /// across the view in proportion to depth, by `-eye / (distance - anchor)` per point in
        /// front of the spine's plane, so the projection stays a homography.
        func transform(of face: Face, from eye: SIMD2<Double>) -> ProjectionTransform {
            let shear = -eye / (distance - anchor)
            func sheared(_ vector: SIMD3<Double>, depth: Double) -> SIMD3<Double> {
                SIMD3(vector.x + shear.x * depth, vector.y + shear.y * depth, vector.z)
            }
            return BookProjection.homography(
                origin: sheared(face.origin, depth: face.origin.z - anchor),
                u: sheared(face.u, depth: face.u.z), v: sheared(face.v, depth: face.v.z),
                distance: distance, offset: offset)
        }
    }

    /// The faces that `eye` sees.
    let visibleFaces: [Face]
    /// Every face that does not face away from the view, which an eye anywhere in front of the
    /// book might see.
    let faces: [Face]
    /// The projected book's size, seen from the axis; faces map into `0...width` by
    /// `0...height`, and faces an eye across from it reveals reach past them.
    let bounds: CGSize
    let camera: Camera

    /// - Parameters:
    ///   - distance: The camera's distance from the book's center, or `nil` for
    ///     `standardDistance` times the longer of `width` and `height`.
    ///   - eye: The camera's offset across the view from the book's center, in the plane through
    ///     the spine's center.
    init(
        width w: CGFloat, height h: CGFloat, thickness t: CGFloat, yaw: Double, pitch: Double,
        distance: Double? = nil, eye: SIMD2<Double> = .zero
    ) {
        let rotation = Self.rotation(yaw: yaw, pitch: pitch)
        let distance = distance ?? Self.standardDistance * Double(max(w, h))
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
        let camera = Camera(
            distance: distance, anchor: (rotation * SIMD3(-x, 0, 0)).z, offset: -minimum)
        self.camera = camera

        // Light from the upper left, in front of the book.
        let light = simd_normalize(SIMD3<Double>(-0.35, -0.6, 0.72))
        faces = FaceKind.allCases.compactMap { kind in
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
            // Turned more than 30 degrees away from the view, as a stacked book's fore edge is, so
            // no eye within 30 degrees of the view sees it.
            guard normal.z > -0.5 else { return nil }
            let size = CGSize(width: simd_length(u), height: simd_length(v))
            let (unitU, unitV) = (ru / Double(size.width), rv / Double(size.height))
            let center = o + ru / 2 + rv / 2
            let shade = 0.42 * (1 - max(0, simd_dot(normal, light)))
            // The camera on the axis magnifies a point `p` of the face's plane by
            // `distance / (distance - p.z)`, which is linear in its projection `q` from the
            // center: `(n.xy · q - n.z * distance) / (n · p - n.z * distance)`. A face of the box
            // never lies in a plane through the camera.
            let reach = simd_dot(normal, o) - normal.z * distance
            let slope = SIMD2(normal.x, normal.y) / reach
            let depth = SIMD3(
                slope.x, slope.y, -normal.z * distance / reach - simd_dot(slope, camera.offset))
            var face = Face(
                kind: kind, size: size, shade: shade, origin: o, u: unitU, v: unitV,
                center: center, normal: normal, depth: depth)
            face.transform = camera.transform(of: face, from: eye)
            return face
        }
        visibleFaces = faces.filter { camera.shows($0, from: eye) }
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
