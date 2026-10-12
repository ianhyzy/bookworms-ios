import RealityKit
import SwiftUI
import UIKit

/// Builds the books of a 3D scene as rigid bodies: their meshes, textures, materials, physics
/// boxes, and masses.
///
/// `prepare` builds each book's parts once: its shape (`BookShape`), a mesh shared by every
/// book of that shape, and its materials. Covers download in parallel and spines render on the
/// main actor, because `ImageRenderer` draws synchronously. A book's parts are kept until its
/// look or its wear changes or `release` drops them, so a new drop reuses them.
///
/// GPU memory stays bounded by the texture sizes, which grow with the book's length up to 24 cm,
/// so books up to that length are about as sharp on screen (see `textureScale(forLength:)`).
/// At a `textureScale` of 1, a book at least 24 cm long has a cover of at most 224 pixels on
/// its long side, cropped to its front board's 0.5 to 0.85 aspect: 149 × 224 × 4 bytes
/// (178 KB with mipmaps) for a 2:3 cover, and at most 192 × 224 (229 KB). Its spine is 384
/// pixels long and as thick as the book is in proportion, at most a sixth of its length
/// (131 KB). Three hundred books of a typical library's sizes therefore need about 60 MB, and
/// at most 108 MB. Each texture has one material. Books share the page-edge texture, page and
/// cloth materials by color, and meshes by shape, which adds about 25 KB per distinct shape.
@MainActor
final class BookFactory {
    /// A book's mesh, its materials in `BookSlot` order, and the look and wear they were drawn
    /// with, so a changed design, a newly loaded font, or a synced reading history redraws
    /// them. `ribbon` is a current read's bookmark.
    struct Parts {
        let shape: BookShape
        let mesh: MeshResource
        var materials: [any RealityKit.Material]
        let look: SpineLook
        let wear: Wear
        let ribbon: ModelComponent?
    }

    /// What the reading history shows on a book: its page edges' color and finish, and its
    /// ribbon's place in tenths of the book, or `nil` for a book that is not being read.
    struct Wear: Equatable {
        let pages: PageFinish
        let ribbon: Int?

        init(_ book: CloudBook, accent: ColorValue) {
            pages = PageFinish(
                color: PageEdges.color(of: book, accent: accent), sprayed: PageEdges.isSprayed(book)
            )
            ribbon =
                book.isReading == true
                ? book.progress.map { Int(($0 * 10).rounded()) } : nil
        }
    }

    /// A page edges' color and finish, by which books share page materials.
    struct PageFinish: Hashable {
        let color: ColorValue
        let sprayed: Bool
    }

    /// The name of a current read's ribbon entity, a child of the book's model entity.
    static let ribbonName = "ribbon"
    static let spineLength: CGFloat = 384

    /// The texture scale of a 24-centimeter book, which `textureScale(forLength:)` scales.
    let textureScale: CGFloat
    /// Called with a book's ID and new cover material when its cover arrives after the book was
    /// built, so the scene can retexture the book.
    var coverArrived: ((Int, any RealityKit.Material) -> Void)?

    private(set) var parts: [Int: Parts] = [:]
    private var meshes: [BookShape: Task<MeshResource?, Never>] = [:]
    private var ribbonMeshes: [RibbonKey: MeshResource] = [:]
    private var cloths: [Surface: PhysicallyBasedMaterial] = [:]
    private var pageMaterials: [PageFinish: PhysicallyBasedMaterial] = [:]
    private var ribbonMaterial: PhysicallyBasedMaterial?
    private lazy var pageLines = Self.makePageLines()

    private static let paper = PhysicsMaterialResource.generate(
        staticFriction: 0.6, dynamicFriction: 0.45, restitution: 0)

    private struct Surface: Hashable {
        let color: ColorValue
        let binding: BookBinding
    }

    private struct RibbonKey: Hashable {
        let shape: BookShape
        /// Progress in tenths.
        let tenths: Int
    }

    /// `textureScale` multiplies the texture sizes, for still images that frame a few books
    /// closely; their GPU memory grows with its square.
    init(textureScale: CGFloat = 1) {
        self.textureScale = textureScale
    }

    /// The pixels per point of the spine texture and the front drawn without a cover, for a book
    /// `length` units long: `textureScale` in proportion to the length, up to 2.4 units, so
    /// books up to that length keep one sharpness per unit, and longer books do not raise the
    /// memory ceiling.
    func textureScale(forLength length: Float) -> CGFloat {
        textureScale * CGFloat(min(length, 2.4)) / 2.4
    }

    /// The longest side of `book`'s cover texture, in pixels: 224 at its length's texture
    /// scale. A book's length does not depend on its cover.
    func coverPixels(for book: CloudBook) -> Int {
        let length = BookShape(of: book, coverAspect: 2 / 3).size.y
        return Int((224 * textureScale(forLength: length)).rounded())
    }

    /// Builds the parts of the books that lack them or whose look or wear changed.
    ///
    /// A book whose cover takes longer than `coverWait` is built with its title on the cloth,
    /// and `coverArrived` hands over its cover when the download finishes. Once these books'
    /// covers arrive or time out, the covers of `upcoming` books start downloading, so the next
    /// batch finds them in the cover store. The cover store shares downloads still in flight
    /// with later requests.
    func prepare(
        _ books: [CloudBook], prefetching upcoming: [CloudBook], coverWait: Duration,
        model: AppModel
    ) async {
        let missing = books.filter { book in
            let look = model.look(for: book)
            guard let built = parts[book.id] else { return true }
            return built.look != look || built.wear != Wear(book, accent: look.accent)
        }
        guard !missing.isEmpty else { return }
        await model.fonts.load(missing.compactMap { model.library?.designs[$0.id] })
        guard !Task.isCancelled else { return }
        let covers = model.covers
        let (arrivals, delivery) = AsyncStream.makeStream(of: (Int, UIImage?).self)
        for book in missing {
            let pixels = coverPixels(for: book)
            Task {
                delivery.yield((book.id, await covers.image(for: book, maximumPixelSize: pixels)))
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: coverWait)
            delivery.finish()
        }
        var arrived = Set<Int>()
        var images: [Int: UIImage] = [:]
        for await (id, image) in arrivals {
            arrived.insert(id)
            images[id] = image
            if arrived.count == missing.count { break }
        }
        deadline.cancel()
        for book in upcoming where parts[book.id] == nil {
            let pixels = coverPixels(for: book)
            Task { _ = await covers.image(for: book, maximumPixelSize: pixels) }
        }
        for book in missing where !Task.isCancelled {
            guard
                let built = await makeParts(
                    book, cover: images[book.id], look: model.look(for: book))
            else { continue }
            parts[book.id] = built
            if !arrived.contains(book.id) {
                let pixels = coverPixels(for: book)
                Task { [weak self] in
                    guard let cover = await covers.image(for: book, maximumPixelSize: pixels)
                    else { return }
                    await self?.addCover(cover, to: book.id)
                }
            }
        }
    }

    /// Puts a cover onto a built book's front, cropped to its front board, and hands the new
    /// material to `coverArrived`.
    func addCover(_ cover: UIImage, to id: Int) async {
        guard let parts = parts[id], let image = Self.crop(cover, to: parts.shape),
            let texture = await Self.texture(image)
        else { return }
        let material = Self.jacket(texture, binding: parts.shape.binding)
        self.parts[id]?.materials[Int(BookSlot.cover)] = material
        coverArrived?(id, material)
    }

    /// Draws a built book's parts again with `look`, keeping its shape, when its spine design
    /// changed since they were built, such as after the reader recolored it in its details.
    ///
    /// A cancelled call, or one that another restyle overtook while it drew, leaves the parts
    /// as they are, so an older look never replaces a newer one.
    func restyle(_ book: CloudBook, cover: UIImage?, look: SpineLook) async {
        guard let built = parts[book.id], built.look != look,
            let restyled = await makeParts(book, cover: cover, look: look, shape: built.shape),
            !Task.isCancelled, parts[book.id]?.look == built.look
        else { return }
        parts[book.id] = restyled
    }

    /// Builds a book's parts. `shape` keeps a built book's shape for a new cover, and `scale`
    /// overrides the shape's texture scale (`textureScale(forLength:)`) for the spine and a
    /// front without a cover. Returns `nil` if RealityKit cannot make the book's mesh.
    func makeParts(
        _ book: CloudBook, cover: UIImage?, look: SpineLook, shape: BookShape? = nil,
        scale: CGFloat? = nil
    ) async -> Parts? {
        let shape = shape ?? BookShape(of: book, coverAspect: Book3DView.aspect(of: cover))
        guard let mesh = await mesh(for: shape) else { return nil }
        let scale = scale ?? textureScale(forLength: shape.size.y)
        let thickness = max(16, (Self.spineLength * CGFloat(shape.size.z / shape.size.y)).rounded())
        let spine = Self.render(
            SpineView(book: book, look: look)
                .frame(width: Self.spineLength, height: thickness)
                .background(look.background.color), scale: scale)
        // Unshaded, since RealityKit lights the front as it does the cloth.
        let width = 224 * CGFloat(shape.coverAspect)
        let front =
            cover.flatMap { Self.crop($0, to: shape) }
            ?? Self.render(
                BookFrontPlaceholder(book: book, look: look, width: width)
                    .frame(width: width, height: 224), scale: scale)
        let coverTexture = await Self.texture(front)
        let spineTexture = await Self.texture(spine)
        let cloth = cloth(look.background, binding: shape.binding)
        let wear = Wear(book, accent: look.accent)
        return Parts(
            shape: shape, mesh: mesh,
            materials: [
                coverTexture.map { Self.jacket($0, binding: shape.binding) } ?? cloth,
                spineTexture.map { Self.jacket($0, binding: shape.binding) } ?? cloth,
                pages(wear.pages), cloth,
            ],
            look: look, wear: wear, ribbon: wear.ribbon.flatMap { ribbon(shape, tenths: $0) })
    }

    /// A rigid body for the book with `id`, from its parts: a box as large as the book, `mass`
    /// kilograms or, by default, about as heavy as one of paper, holding the book's model, lit
    /// by `lighting`'s image-based light. Returns `nil` for a book without parts.
    func makeBook(
        _ id: Int, mode: PhysicsBodyMode, lighting: Entity, mass: Float? = nil
    ) -> ModelEntity? {
        guard let parts = parts[id] else { return nil }
        let size = parts.shape.size
        let box = ShapeResource.generateBox(size: size)
        let book = ModelEntity()
        book.components.set(CollisionComponent(shapes: [box]))
        book.components.set(InputTargetComponent())
        // Paper weighs about 0.7 kg per liter, and a cubic decimeter is a liter.
        var body = PhysicsBodyComponent(
            shapes: [box], mass: mass ?? size.x * size.y * size.z * 0.7, material: Self.paper,
            mode: mode)
        body.isContinuousCollisionDetectionEnabled = true
        body.linearDamping = 0.05
        body.angularDamping = 0.3
        book.components.set(body)
        let model = Entity()
        model.components.set(ModelComponent(mesh: parts.mesh, materials: parts.materials))
        model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
        // A soft shadow right under the book, so a book on the table or the pile sits on it.
        model.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true))
        book.addChild(model)
        if let ribbon = parts.ribbon {
            let entity = Entity()
            entity.name = Self.ribbonName
            entity.components.set(ribbon)
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
            model.addChild(entity)
        }
        return book
    }

    /// Drops the parts of books not in `ids`, and the meshes no remaining book uses. With no
    /// IDs, also drops the shared materials.
    func release(keeping ids: Set<Int>) {
        parts = parts.filter { ids.contains($0.key) }
        let shapes = Set(parts.values.map(\.shape))
        meshes = meshes.filter { shapes.contains($0.key) }
        ribbonMeshes = ribbonMeshes.filter { shapes.contains($0.key.shape) }
        guard ids.isEmpty else { return }
        cloths = [:]
        pageMaterials = [:]
        ribbonMaterial = nil
    }

    // MARK: Meshes and materials

    private func mesh(for shape: BookShape) async -> MeshResource? {
        let task =
            meshes[shape]
            ?? Task { try? await MeshResource(from: [BookGeometry.book(shape).descriptor]) }
        meshes[shape] = task
        return await task.value
    }

    /// A ribbon bookmark `tenths` of the way through a book of `shape`: deep red satin, which
    /// stands out against cream page edges.
    private func ribbon(_ shape: BookShape, tenths: Int) -> ModelComponent? {
        let key = RibbonKey(shape: shape, tenths: tenths)
        guard
            let mesh = ribbonMeshes[key]
                ?? (try? MeshResource.generate(
                    from: [
                        BookGeometry.ribbon(shape, progress: Float(key.tenths) / 10).descriptor
                    ]))
        else { return nil }
        ribbonMeshes[key] = mesh
        let material =
            ribbonMaterial
            ?? Self.surface(
                nil, tint: UIColor(red: 0.62, green: 0.07, blue: 0.09, alpha: 1),
                roughness: 0.32, specular: 0.4)
        ribbonMaterial = material
        return ModelComponent(mesh: mesh, materials: [material])
    }

    private func cloth(_ color: ColorValue, binding: BookBinding) -> PhysicallyBasedMaterial {
        let key = Surface(color: color, binding: binding)
        if let cloth = cloths[key] { return cloth }
        let cloth = Self.finish(
            Self.surface(nil, tint: color.uiColor, roughness: 0.56), binding: binding)
        cloths[key] = cloth
        return cloth
    }

    /// The page edges' material: matte paper with fine lines, or a smoother sprayed finish.
    private func pages(_ key: PageFinish) -> PhysicallyBasedMaterial {
        if let pages = pageMaterials[key] { return pages }
        var pages = Self.surface(
            nil, tint: key.color.uiColor, roughness: key.sprayed ? 0.5 : 0.88,
            specular: key.sprayed ? 0.25 : 0.05)
        if let pageLines {
            let sampler = MTLSamplerDescriptor()
            sampler.sAddressMode = .repeat
            sampler.tAddressMode = .repeat
            sampler.minFilter = .linear
            sampler.magFilter = .linear
            sampler.mipFilter = .linear
            pages.baseColor.texture = .init(pageLines, sampler: .init(sampler))
        }
        pageMaterials[key] = pages
        return pages
    }

    /// A cover or spine: a glossy jacket on a hardcover, matte card on a paperback.
    private static func jacket(_ texture: TextureResource, binding: BookBinding)
        -> PhysicallyBasedMaterial
    {
        finish(surface(texture, roughness: 0.5, specular: 0.25), binding: binding)
    }

    /// `material` with a hardcover jacket's glossy clear coat, or a paperback's matte card.
    private static func finish(_ material: PhysicallyBasedMaterial, binding: BookBinding)
        -> PhysicallyBasedMaterial
    {
        var material = material
        switch binding {
        case .hardcover:
            // A satin gloss: a sharper or stronger coat mirrors the lamp as a white patch that
            // hides the cover's art.
            material.clearcoat = .init(floatLiteral: 0.5)
            material.clearcoatRoughness = .init(floatLiteral: 0.35)
        case .paperback:
            material.roughness = .init(floatLiteral: 0.74)
            material.specular = .init(floatLiteral: 0.12)
        }
        return material
    }

    /// A nonmetallic surface with low reflectance, so the environment lays no gray haze over
    /// dark covers.
    static func surface(
        _ texture: TextureResource?, tint: UIColor = .white, roughness: Float,
        specular: Float = 0.1
    ) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: tint, texture: texture.map { .init($0) })
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: 0)
        material.specular = .init(floatLiteral: specular)
        return material
    }

    /// Paper leaves seen edge on: rows of slightly varied brightness, 64 per
    /// `BookGeometry.pageLinePeriod`, which the page material tints.
    private static func makePageLines() -> TextureResource? {
        var rows = [UInt8](repeating: 0, count: 64 * 4)
        var seed: UInt32 = 0x9E37_79B9
        for row in 0..<64 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let shade = Double(seed >> 24) / 255
            // Most leaves are nearly white; one in eight is a darker line.
            let value = 255 - shade * shade * 40 - (row % 8 == 3 ? 28 : 0)
            for column in 0..<4 { rows[row * 4 + column] = UInt8(max(0, value)) }
        }
        guard let provider = CGDataProvider(data: Data(rows) as CFData),
            let image = CGImage(
                width: 4, height: 64, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color))
    }

    // MARK: Images

    static func texture(_ image: CGImage?) async -> TextureResource? {
        guard let image else { return nil }
        return try? await TextureResource(image: image, options: .init(semantic: .color))
    }

    /// The middle of `cover` at the aspect of the front board of a book of `shape`.
    static func crop(_ cover: UIImage, to shape: BookShape) -> CGImage? {
        guard let image = cover.cgImage else { return nil }
        return image.cropping(
            to: PileLayout.crop(
                CGSize(width: image.width, height: image.height),
                to: CGFloat(shape.coverAspect)))
    }

    static func render(_ content: some View, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.cgImage
    }

    /// `material`'s color and texture, unlit and without tone mapping, darkened as a black
    /// overlay of opacity `shade` darkens a SwiftUI view.
    static func unlit(_ material: any RealityKit.Material, shade: Float)
        -> any RealityKit.Material
    {
        guard let lit = material as? PhysicallyBasedMaterial else { return material }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        lit.baseColor.tint.getRed(&red, green: &green, blue: &blue, alpha: nil)
        // The tint is in sRGB, like SwiftUI's blending, and multiplies the texture in linear
        // light, which scales the texture's sRGB values by the same factor.
        let light = CGFloat(1 - shade)
        var unlit = UnlitMaterial(applyPostProcessToneMap: false)
        unlit.color = .init(
            tint: UIColor(red: red * light, green: green * light, blue: blue * light, alpha: 1),
            texture: lit.baseColor.texture)
        return unlit
    }
}

/// The color of a book's page edges, which age with the book.
enum PageEdges {
    static let fresh = ColorValue(red: 237, green: 230, blue: 209)
    /// Paper after `yellowingYears` or more.
    static let aged = ColorValue(red: 214, green: 184, blue: 124)
    static let yellowingYears = 15.0

    /// Whether the book has sprayed edges, which five-star books get.
    static func isSprayed(_ book: CloudBook) -> Bool { (book.rating ?? 0) >= 5 }

    /// A five-star book's edges are sprayed in the spine's `accent` color. Other books' edges
    /// yellow with the time since the reader finished them: quickly at first, then more slowly,
    /// until they are fully aged after `yellowingYears`. Ages round to eighths, so books share
    /// page materials. Unfinished books have fresh pages.
    static func color(of book: CloudBook, accent: ColorValue, now: Date = .now) -> ColorValue {
        if isSprayed(book) { return accent.mixed(with: fresh, 0.12) }
        guard let finished = book.finishedDate else { return fresh }
        let years = max(0, now.timeIntervalSince(finished) / (365.25 * 86_400))
        let age = (min(1, years / yellowingYears).squareRoot() * 8).rounded() / 8
        return fresh.mixed(with: aged, age)
    }
}

extension ColorValue {
    var uiColor: UIColor {
        UIColor(
            red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255,
            alpha: 1)
    }
}
