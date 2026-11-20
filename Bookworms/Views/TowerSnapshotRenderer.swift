import RealityKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Renders the Tall Stack share image: a time frame's books in one tower (`BookTower`) on the
/// desk under the lamp, seen from a low camera, with a tape measure hooked over the top book, a
/// worm at the base, and a loupe that magnifies the newest books.
///
/// It renders as `PileSnapshotRenderer` does, offscreen in a `RealityRenderer`, and takes turns
/// with it (`PileSnapshotRenderer.claim()`), with the same books, spine designs, and lamp.
/// RealityKit draws the scene over a clear background, and SwiftUI draws it over the share
/// theme's backdrop (`ShareTheme`), under the headline.
@MainActor
enum TowerSnapshotRenderer {
    /// Renders `books`, oldest first, finished in the time frame named `title`, at the pixel
    /// size of `aspect`, with `username`'s profile link when there is one. `seed` varies each
    /// book's shift and turn. Returns the image and the books whose covers missed the wait.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, and `PileSnapshotError` when
    ///   Metal fails or the frame is blank.
    static func render(
        books: [CloudBook], title: String, aspect: ShareAspect, seed: UInt64,
        username: String? = nil, model: AppModel
    ) async throws -> (image: UIImage, late: [CloudBook]) {
        try await PileSnapshotRenderer.claim()
        defer { PileSnapshotRenderer.release() }
        let stage = try await TowerStage(books: books, aspect: aspect, seed: seed, model: model)
        defer { stage.renderer.entities.removeAll() }
        let frames = try await stage.renderStill()
        let renderer = ImageRenderer(
            content: TowerSnapshotCard(
                tower: frames.tower, loupe: frames.loupe, facts: stage.facts(title: title),
                layout: stage.layout, theme: stage.theme, topPoint: stage.topPoint,
                showsCredit: false, username: username))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { throw PileSnapshotError.drawingFailed }
        return (image, stage.late)
    }
}

/// What the headline says: the time frame, the height in the reader's units, and the count.
struct TowerFacts {
    let title: String
    let height: String
    let count: Int
    let pages: Int
}

/// The tower's scene, cameras, and frames, for a still image or a clip.
@MainActor
final class TowerStage {
    let tower: BookTower
    let layout: TowerLayout
    let scene: BookPileScene
    let renderer: RealityRenderer
    let theme: ShareTheme
    let late: [CloudBook]
    let props: TowerProps
    /// The books' bodies, bottom up.
    let books: [ModelEntity]
    /// The camera that frames the tower in `layout.towerRect`.
    let camera: TowerCamera
    /// The camera of the loupe, or `nil` when every spine reads without one.
    let loupeCamera: TowerCamera?
    private let loupeEntity = PerspectiveCamera()
    let target: FrameTarget
    let loupeTarget: FrameTarget?

    init(books: [CloudBook], aspect: ShareAspect, seed: UInt64, model: AppModel) async throws {
        let shown = BookTower(books: books, seed: seed).slots.map(\.book)
        let scene = BookPileScene(textureScale: shown.count <= 60 ? 2 : 1)
        late = await scene.prepareStill(shown, model: model)
        try Task.checkCancellation()
        let tower = BookTower(books: books, seed: seed) { scene.shape(of: $0.id) ?? BookShape(of: $0, coverAspect: 2 / 3) }
        self.tower = tower
        self.scene = scene
        theme = ShareTheme(looks: shown.map(model.look(for:)))
        let height = tower.stackHeight
        await scene.light(pool: [0, height / 2, 0], radius: max(height * 0.6, 3))
        try Task.checkCancellation()
        self.books = scene.place(
            tower.slots.map { PileSlot(book: $0.book, transform: $0.transform) }, mode: .static)
        props = TowerProps(tower: tower)
        scene.addLit(props.root)

        layout = TowerLayout(
            aspect: aspect, hasLoupe: tower.slots.count > TowerLayout.loupeThreshold)
        let size = aspect.size
        camera = TowerCamera.framing(
            tower.corners + props.extent, eyeHeight: max(0.8, height * 0.12),
            in: layout.towerRect, of: size)
        scene.look(from: camera.transform, aspect: Float(size.width / size.height))
        target = try FrameTarget(width: Int(size.width), height: Int(size.height))
        if let loupe = layout.loupeRect {
            let top = tower.slots.suffix(TowerLayout.loupeBooks)
            let corners = top.flatMap(\.corners)
            let middle = corners.reduce(SIMD3<Float>.zero, +) / Float(max(corners.count, 1))
            let square = CGSize(width: loupe.width, height: loupe.height)
            loupeCamera = TowerCamera.framing(
                corners, eyeHeight: middle.y + 0.3,
                in: CGRect(origin: .zero, size: square)
                    .insetBy(dx: loupe.width * 0.12, dy: loupe.height * 0.12),
                of: square, standsOnBottom: false)
            loupeTarget = try FrameTarget(width: Int(loupe.width), height: Int(loupe.height))
            loupeEntity.camera = scene.camera.camera
            scene.root.addChild(loupeEntity)
        } else {
            loupeCamera = nil
            loupeTarget = nil
        }

        renderer = try RealityRenderer()
        renderer.entities.append(scene.root)
        renderer.activeCamera = scene.camera
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.isToneMappingEnabled = true
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
    }

    /// The headline's facts for the time frame `title`, in the reader's units.
    func facts(title: String) -> TowerFacts {
        TowerFacts(
            title: title, height: BookTower.heightText(tower.height), count: tower.count,
            pages: tower.pages)
    }

    /// Renders the tower and the loupe once.
    func renderStill() async throws -> (tower: CGImage, loupe: CGImage?) {
        for _ in 0..<3 { try renderer.update(1.0 / 60) }
        let tower = try await frame(target, from: scene.camera, value: 1)
        var loupe: CGImage?
        if let loupeTarget, let loupeCamera {
            loupeEntity.transform = loupeCamera.transform
            loupe = try await frame(loupeTarget, from: loupeEntity, value: 2)
        }
        return (tower, loupe)
    }

    /// Renders one frame through `camera` into `target`, and copies it into an image with
    /// premultiplied alpha.
    private func frame(_ target: FrameTarget, from camera: Entity, value: UInt64) async throws
        -> CGImage
    {
        renderer.activeCamera = camera
        defer { renderer.activeCamera = scene.camera }
        try renderer.updateAndRender(
            deltaTime: 1.0 / 60, cameraOutput: target.output,
            actionsAfterRender: [.signal(target.event, value: value)])
        try await target.read(after: value, before: .now + .seconds(10))
        let width = target.texture.width
        let height = target.texture.height
        let pixels = Data(bytes: target.buffer.contents(), count: target.bytesPerRow * height)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
            let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: target.bytesPerRow, space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw PileSnapshotError.drawingFailed }
        return image
    }

    /// Where the top book's tail end shows in the image, in pixels, which the loupe's line
    /// points at.
    var topPoint: CGPoint {
        let end = tower.slots.last.flatMap { $0.corners.map(\.x).max() } ?? 0
        return camera.pixel(of: [end, tower.stackHeight, 0], in: layout.aspect.size)
    }
}

/// Where a Tall Stack image puts its headline, its tower, and its loupe.
struct TowerLayout: Equatable {
    /// How many of the newest books the loupe magnifies.
    static let loupeBooks = 4
    /// The most books a tower stacks without a loupe: up to about this many, a Story image
    /// letters every spine at least as large as the loupe does.
    static let loupeThreshold = 16

    let aspect: ShareAspect
    let titleSize: CGFloat
    /// The bottom of the headline's lines.
    let headlineBottom: CGFloat
    let hasLoupe: Bool

    init(aspect: ShareAspect, hasLoupe: Bool) {
        self.aspect = aspect
        self.hasLoupe = hasLoupe
        titleSize = aspect == .story ? 104 : 84
        // Two lines of the headline and the count's line.
        headlineBottom = aspect.insets.top + titleSize * 2.3 + 60
    }

    /// The part of the image the tower, the tape, and the worm are framed in: below the
    /// headline and above the bottom margin, on the left beside the loupe when there is one.
    var towerRect: CGRect {
        let size = aspect.size
        let top = headlineBottom + 40
        let width = hasLoupe ? size.width * 0.56 : size.width - 2 * aspect.insets.leading
        return CGRect(
            x: aspect.insets.leading, y: top, width: width,
            height: size.height - aspect.insets.bottom - top)
    }

    /// The loupe's square, at the right beside the tower's top, or `nil` without a loupe.
    var loupeRect: CGRect? {
        guard hasLoupe else { return nil }
        let size = aspect.size
        let side = (size.width * 0.38).rounded()
        return CGRect(
            x: size.width - aspect.insets.leading / 2 - side, y: towerRect.minY + 10,
            width: side, height: side)
    }
}

/// A camera at a fixed eye height that looks at a target, with the pile's field of view.
struct TowerCamera: Equatable {
    var eye: SIMD3<Float>
    var target: SIMD3<Float>

    var rotation: simd_quatf {
        let back = simd_normalize(eye - target)
        let right = simd_normalize(simd_cross([0, 1, 0], back))
        let up = simd_cross(back, right)
        return simd_quatf(simd_float3x3(columns: (right, up, back)))
    }

    var transform: Transform { Transform(rotation: rotation, translation: eye) }

    /// Where `point` appears in normalized device coordinates, as `PileCamera.project` maps it.
    func project(_ point: SIMD3<Float>, aspect: Float) -> SIMD2<Float> {
        let local = rotation.inverse.act(point - eye)
        return SIMD2(local.x / aspect, local.y) / (-local.z * tan(PileCamera.fieldOfView / 2))
    }

    /// Where `point` appears in an image of `size`, in pixels from the top left.
    func pixel(of point: SIMD3<Float>, in size: CGSize) -> CGPoint {
        let ndc = project(point, aspect: Float(size.width / size.height))
        return CGPoint(
            x: CGFloat(ndc.x + 1) / 2 * size.width, y: CGFloat(1 - ndc.y) / 2 * size.height)
    }

    /// A camera at `eyeHeight` that frames `points` to fill as much of `rect`, in the pixels of
    /// an image of `size`, as they can while staying inside it.
    ///
    /// Each pass moves the eye nearer or farther by how much the points over- or underfill
    /// `rect`, and slides the target to center them, as `PileCamera.framing` slides its
    /// target. With `standsOnBottom`, the points sit on the rect's bottom instead of in its
    /// middle, so a short, wide tower leaves its spare room above it, under the headline,
    /// rather than an empty floor below. The eye
    /// keeps its height, so the camera looks up at a tall tower.
    static func framing(
        _ points: [SIMD3<Float>], eyeHeight: Float, in rect: CGRect, of size: CGSize,
        standsOnBottom: Bool = true
    ) -> TowerCamera {
        let aspect = Float(size.width / size.height)
        let low = SIMD2(
            Float(2 * rect.minX / size.width - 1), Float(1 - 2 * rect.maxY / size.height))
        let high = SIMD2(
            Float(2 * rect.maxX / size.width - 1), Float(1 - 2 * rect.minY / size.height))
        guard let first = points.first else { return TowerCamera(eye: [0, eyeHeight, 10], target: .zero) }
        let least = points.reduce(first, pointwiseMin)
        let most = points.reduce(first, pointwiseMax)
        let middle = (least + most) / 2
        var distance = max(most.y - least.y, most.x - least.x) * 2 + 4
        var camera = TowerCamera(
            eye: [middle.x, eyeHeight, most.z + distance], target: [middle.x, middle.y, middle.z])
        for _ in 0..<24 {
            let projected = points.map { camera.project($0, aspect: aspect) }
            let lowest = projected.reduce(projected[0], pointwiseMin)
            let highest = projected.reduce(projected[0], pointwiseMax)
            let fill = ((highest - lowest) / (high - low)).max()
            let centering = (lowest + highest - low - high) / 2
            let offset = SIMD2(centering.x, standsOnBottom ? lowest.y - low.y : centering.y)
            let reach = simd_distance(camera.eye, camera.target) * tan(PileCamera.fieldOfView / 2)
            camera.target.x += offset.x * reach * aspect
            camera.target.y += offset.y * reach
            distance = max(distance * fill / 0.97, 1)
            camera.eye = [camera.target.x, eyeHeight, middle.z + distance]
        }
        return camera
    }
}

/// The tape measure and the worm beside the tower, sized to it.
@MainActor
struct TowerProps {
    let root = Entity()
    /// The points that bound the tape's case and the worm, for framing. The tape's blade
    /// reaches no higher than the tower, and a clip retracts it.
    let extent: [SIMD3<Float>]
    /// Where the tape's hook ends over the top book, in x.
    let hookEnd: Float
    /// The tape's blade, which a clip retracts into its case.
    let blade: ModelEntity
    let hook: ModelEntity
    /// The height of the case's slot, where the blade leaves the case.
    let slotHeight: Float

    /// The tape's yellow.
    private static let yellow = UIColor(red: 0.95, green: 0.74, blue: 0.16, alpha: 1)
    /// The hook's riveted brass.
    private static let brass = UIColor(red: 0.78, green: 0.62, blue: 0.32, alpha: 1)
    /// The worm's skin.
    private static let pink = UIColor(red: 0.87, green: 0.56, blue: 0.55, alpha: 1)

    init(tower: BookTower) {
        let height = tower.stackHeight
        // Props grow with a tall tower so they stay visible in the frame, from life size at a
        // meter.
        let scale = min(max(height / 10, 1), 3)
        let corners = tower.corners
        let left = corners.map(\.x).min() ?? -1.2
        let right = corners.map(\.x).max() ?? 1.2

        // The blade hangs plumb beside the tower, clear of every book's shift, not leaning on
        // it, and its hook reaches over the top book's head end.
        let topLeft =
            tower.slots.last.flatMap { $0.corners.map(\.x).min() } ?? left
        let bladeX = left - 0.1 * scale
        let bladeWidth: Float = 0.19 * scale
        let caseSize = SIMD3<Float>(0.75, 0.75, 0.38) * scale
        slotHeight = caseSize.y * 0.85
        let length = max(height - slotHeight, 0.1)
        blade = ModelEntity(
            mesh: .generateBox(width: 0.004 * scale, height: 1, depth: bladeWidth),
            materials: [Self.bladeMaterial()])
        // The blade's box is one unit tall, scaled to its length, so a clip can retract it.
        blade.scale = [1, length, 1]
        blade.position = [bladeX, slotHeight + length / 2, 0]
        // Turned so its face with the ticks faces the camera.
        blade.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        hookEnd = topLeft + 0.25
        let hookLength = hookEnd - bladeX
        hook = ModelEntity(
            mesh: .generateBox(width: hookLength, height: 0.03 * scale, depth: bladeWidth),
            materials: [BookFactory.surface(nil, tint: Self.brass, roughness: 0.3, specular: 0.7)])
        hook.position = [bladeX + hookLength / 2, height + 0.015 * scale, 0]
        let tapeCase = ModelEntity(
            mesh: .generateBox(size: caseSize, cornerRadius: caseSize.x * 0.18),
            materials: [BookFactory.surface(nil, tint: Self.yellow, roughness: 0.45, specular: 0.4)])
        tapeCase.position = [bladeX - caseSize.x / 2 + 0.05 * scale, caseSize.y / 2, 0]
        let band = ModelEntity(
            mesh: .generateBox(
                size: [caseSize.x * 1.01, caseSize.y * 0.3, caseSize.z * 1.02],
                cornerRadius: caseSize.x * 0.05),
            materials: [BookFactory.surface(nil, tint: .darkGray, roughness: 0.6)])
        band.position = [0, -caseSize.y * 0.12, 0]
        tapeCase.addChild(band)

        let worm = Self.makeWorm(scale: scale)
        let wormX = right + 0.55 * scale
        worm.position = [wormX, 0, 0.4 * scale]
        for entity in [blade, hook, tapeCase, worm] {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
            root.addChild(entity)
        }
        // A clip's tower topples toward the tape, and its books land on the case.
        let caseShape = ShapeResource.generateBox(size: caseSize)
        tapeCase.components.set(CollisionComponent(shapes: [caseShape]))
        tapeCase.components.set(PhysicsBodyComponent(shapes: [caseShape], mass: 0, mode: .static))
        let caseLeft = tapeCase.position.x - caseSize.x / 2
        extent = [
            [caseLeft, 0, caseSize.z / 2], [caseLeft, caseSize.y, -caseSize.z / 2],
            [wormX + 0.7 * scale, 0, 0.4 * scale], [wormX + 0.7 * scale, 1.6 * scale, 0.4 * scale],
        ]
    }

    /// Yellow tape with a tick every centimeter, longer every 5, and longest every 10. One
    /// tile of the texture spans a decimeter.
    private static func bladeMaterial() -> PhysicallyBasedMaterial {
        let width = 48
        let height = 480
        var texture: TextureResource?
        if let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
            context.setFillColor(yellow.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(UIColor(white: 0.1, alpha: 1).cgColor)
            for centimeter in 0..<10 {
                let y = CGFloat(centimeter * height / 10)
                let reach: CGFloat = centimeter == 0 ? 0.7 : centimeter == 5 ? 0.5 : 0.3
                context.fill(CGRect(x: 0, y: y, width: CGFloat(width) * reach, height: 4))
            }
            if let image = context.makeImage() {
                texture = try? TextureResource(image: image, options: .init(semantic: .color))
            }
        }
        var material = BookFactory.surface(texture, roughness: 0.4, specular: 0.4)
        if let texture {
            let sampler = MTLSamplerDescriptor()
            sampler.sAddressMode = .repeat
            sampler.tAddressMode = .repeat
            sampler.minFilter = .linear
            sampler.magFilter = .linear
            sampler.mipFilter = .linear
            material.baseColor.texture = .init(texture, sampler: .init(sampler))
        }
        return material
    }

    /// Repeats the blade's ticks along `length` units of tape.
    static func setLength(_ length: Float, of blade: ModelEntity) {
        guard var model = blade.model,
            var material = model.materials.first as? PhysicallyBasedMaterial
        else { return }
        material.textureCoordinateTransform = .init(scale: [1, max(length, 0.01)])
        model.materials = [material]
        blade.model = model
    }

    /// A worm sitting on the desk, as a chain of overlapping spheres, so it is round at both
    /// ends: its back lies flat and coils once and a half around its base, and its front rises
    /// upright from the middle of the coil, its head facing the camera (+z), with two dark eyes.
    private static func makeWorm(scale: Float) -> Entity {
        let worm = Entity()
        let skin = BookFactory.surface(nil, tint: pink, roughness: 0.55, specular: 0.25)
        let radius: Float = 0.15 * scale
        var points: [(SIMD3<Float>, Float)] = []
        // The coil, from the tail inward to the base of the upright front, flat on the desk.
        let turns: Float = 1.5
        let steps = 70
        for step in 0...steps {
            let fraction = Float(step) / Float(steps)
            let angle = fraction * turns * 2 * .pi
            let reach = (0.62 - 0.4 * fraction) * scale
            let girth = radius * (0.7 + 0.3 * fraction)
            points.append(([cos(angle) * reach, girth, sin(angle) * reach], girth))
        }
        // The front: bends up from the coil's end and rises to the head over the coil's middle.
        let base = points.last!.0
        let rise = 1.25 * scale
        for step in 1...40 {
            let fraction = Float(step) / 40
            let bend = min(fraction * 3, 1)
            let x = base.x * (1 - bend)
            let z = base.z * (1 - bend) + 0.08 * scale * fraction * fraction
            points.append(([x, radius + rise * fraction, z], radius))
        }
        for (center, size) in points {
            let sphere = ModelEntity(mesh: .generateSphere(radius: size), materials: [skin])
            sphere.position = center
            worm.addChild(sphere)
        }
        let head = points.last!.0
        let eye = BookFactory.surface(nil, tint: UIColor(white: 0.08, alpha: 1), roughness: 0.2, specular: 0.8)
        for side: Float in [-1, 1] {
            let dot = ModelEntity(mesh: .generateSphere(radius: radius * 0.22), materials: [eye])
            dot.position = head + SIMD3(side * radius * 0.42, radius * 0.25, radius * 0.86)
            worm.addChild(dot)
        }
        return worm
    }
}

/// The Tall Stack image: the headline over the share theme's backdrop, the rendered tower, and
/// the loupe.
struct TowerSnapshotCard: View {
    /// The rendered tower over a clear background, or `nil` for the rest alone, over a clear
    /// background, which a clip draws over each frame.
    let tower: CGImage?
    let loupe: CGImage?
    let facts: TowerFacts
    let layout: TowerLayout
    let theme: ShareTheme
    /// Where the tower's top shows, which the loupe's line points at.
    var topPoint: CGPoint?
    var showsBackdrop = true
    var showsHeadline = true
    var showsCredit = true
    var username: String?

    var body: some View {
        let size = layout.aspect.size
        ZStack(alignment: .topLeading) {
            Color.clear
            if showsBackdrop {
                LinearGradient(
                    colors: [theme.backdropLight.color, theme.backdropDark.color],
                    startPoint: .top, endPoint: .bottom)
            }
            if let tower { Image(decorative: tower, scale: 1).resizable() }
            if let loupe, let rect = layout.loupeRect {
                loupeView(loupe, in: rect)
            }
            if showsHeadline {
                headline
                    .padding(.horizontal, layout.aspect.insets.leading)
                    .padding(.top, layout.aspect.insets.top)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottom) {
            if showsCredit { ShareCredit() }
        }
        .overlay(alignment: .bottom) {
            if let username { ShareProfileLink(username: username, aspect: layout.aspect) }
        }
        .environment(\.colorScheme, .dark)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My \(facts.title) is \(Text(facts.height).foregroundStyle(ShareStyle.gold)) tall")
                .font(ShareStyle.serif(layout.titleSize, .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(countLine)
                .font(ShareStyle.serif(40))
                .opacity(0.8)
        }
        .foregroundStyle(ShareStyle.cream.color)
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }

    private var countLine: String {
        let books = facts.count == 1 ? "1 book" : "\(facts.count.formatted()) books"
        return facts.pages > 0 ? "\(books) · \(facts.pages.formatted()) pages" : books
    }

    private func loupeView(_ loupe: CGImage, in rect: CGRect) -> some View {
        ZStack {
            if let topPoint {
                Path { path in
                    path.move(to: topPoint)
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                }
                .stroke(ShareStyle.cream.color.opacity(0.7), lineWidth: 3)
            }
            Image(decorative: loupe, scale: 1)
                .resizable()
                .background(theme.backdropLight.color)
                .clipShape(.circle)
                .overlay(Circle().stroke(ShareStyle.cream.color, lineWidth: 8))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .frame(width: layout.aspect.size.width, height: layout.aspect.size.height)
    }
}
