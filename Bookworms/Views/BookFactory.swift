import RealityKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Builds the books of a 3D scene as rigid bodies: their meshes, textures, materials, physics
/// boxes, and masses.
///
/// `prepare` builds each book's parts once: its shape (`BookShape`), a mesh shared by every
/// book of that shape, its collision box, and its materials. Covers download in parallel and
/// spines render on the main actor, because `ImageRenderer` draws synchronously. A book's parts
/// are kept until its look or its wear changes or `release` drops them, so a new drop reuses
/// them.
///
/// GPU memory stays bounded by the texture sizes, which grow with the book's length up to 24 cm,
/// so books up to that length are about as sharp on screen (see `textureScale(forLength:)`).
/// At a `textureScale` of 1, a book at least 24 cm long has a cover of at most 224 pixels on
/// its long side, cropped to its front board's 0.5 to 0.85 aspect: 149 × 224 × 4 bytes
/// (178 KB with mipmaps) for a 2:3 cover, and at most 192 × 224 (229 KB). Its spine is 384
/// pixels long and as thick as the book is in proportion, at most a sixth of its length
/// (131 KB). Three hundred books of a typical library's sizes therefore need about 60 MB, and
/// at most 108 MB. Each texture has one material. Books share the page-edge texture, page and
/// cloth materials by color, and meshes and collision boxes by shape, which adds about 25 KB
/// per distinct shape.
@MainActor
final class BookFactory {
    /// A book's mesh, its materials in `BookSlot` order, and the look, wear, and covers they were
    /// drawn with, so a changed design, a newly loaded font, a synced reading history, or a new
    /// cover redraws them. `ribbon` is a current read's bookmark.
    ///
    /// `box` is the book's collision box, which every rigid body of its shape shares (see
    /// `makeBook`). Each new shape resource costs RealityKit an asset load that the next
    /// frame waits for, so building hundreds of books at once, as a handover between the desk
    /// scenes does, would otherwise stall the view.
    struct Parts {
        let shape: BookShape
        let mesh: MeshResource
        let box: ShapeResource
        var materials: [any RealityKit.Material]
        let look: SpineLook
        let wear: Wear
        /// The book's cover candidates (`CloudBook.coverCandidates`), which a chosen cover
        /// changes.
        let covers: [URL]
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
    /// The name of a book's model entity, the child of its rigid body.
    static let modelName = "book model"
    static let spineLength: CGFloat = 384

    /// The texture scale of a 24-centimeter book, which `textureScale(forLength:)` scales.
    let textureScale: CGFloat
    /// Called with a built book's ID and its new materials when its cover or font arrives after
    /// the book was built, or its look changed, so the scene can retexture the book.
    var retextured: ((Int, [any RealityKit.Material]) -> Void)?
    /// Whether the books `makeBook` makes have a soft shadow right under them, which
    /// `setGroundingShadows(_:under:)` changes.
    private(set) var groundsBooks = true

    private(set) var parts: [Int: Parts] = [:]
    private var meshes: [BookShape: Task<MeshResource?, Never>] = [:]
    private var boxes: [BookShape: ShapeResource] = [:]
    private var ribbonMeshes: [RibbonKey: MeshResource] = [:]
    private var cloths: [Surface: PhysicallyBasedMaterial] = [:]
    private var pageMaterials: [PageFinish: PhysicallyBasedMaterial] = [:]
    private var ribbonMaterial: PhysicallyBasedMaterial?
    /// The last redraw of books whose fonts came late. Each `prepare` call's redraw waits for
    /// the one before it, so the books draw one at a time however many calls wait for the same
    /// fonts.
    private var lateFonts: Task<Void, Never>?
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

    /// What `prepare` waits for: its books' fonts, loaded or failed, and each book's cover by
    /// book ID, `nil` for a book without one.
    private enum Arrival {
        case fonts
        case cover(Int, UIImage?)
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
        Self.textureScale(textureScale, forLength: length)
    }

    /// `textureScale(forLength:)` for a factory of `textureScale`.
    nonisolated static func textureScale(_ textureScale: CGFloat, forLength length: Float)
        -> CGFloat
    {
        textureScale * CGFloat(min(length, 2.4)) / 2.4
    }

    /// The longest side of `book`'s cover texture, in pixels: 224 at its length's texture
    /// scale. A book's length does not depend on its cover.
    func coverPixels(for book: CloudBook) -> Int {
        Self.coverPixels(for: book, textureScale: textureScale)
    }

    /// Waits until the covers of `books` arrive or fail, at the size a factory of `textureScale`
    /// builds them, so that a still image drawn again finds them in the cover store.
    static func waitForCovers(of books: [CloudBook], textureScale: CGFloat, model: AppModel) async {
        let covers = model.covers
        await withTaskGroup(of: Void.self) { group in
            for book in books {
                let pixels = coverPixels(for: book, textureScale: textureScale)
                group.addTask { _ = await covers.image(for: book, maximumPixelSize: pixels) }
            }
        }
    }

    /// `coverPixels(for:)` for a factory of `textureScale`.
    nonisolated static func coverPixels(for book: CloudBook, textureScale: CGFloat) -> Int {
        let length = BookShape(of: book, coverAspect: 2 / 3).size.y
        return Int((224 * Self.textureScale(textureScale, forLength: length)).rounded())
    }

    /// Builds the parts of the books that lack them or whose look, wear, or covers changed.
    ///
    /// The books' fonts and covers load together, and the build waits at most `loadWait` for
    /// them, so a connection that stalls never holds a scene back. A book whose font takes
    /// longer is lettered in its design's system typeface, and one whose cover takes longer is
    /// built with its title on the cloth. Both go on loading, and `retextured` hands over the
    /// book's new materials when its font or cover arrives. With `waitsForFonts`, for a scene
    /// that nothing draws again, the build waits for every font first, however long that takes,
    /// and `loadWait` limits the covers alone. Once these books' covers arrive or time out, the
    /// covers of `upcoming` books start downloading, so the next batch finds them in the cover
    /// store. The cover store shares downloads still in flight with later requests.
    ///
    /// `width` books build at once, so their textures load together; their main-actor work
    /// then runs back to back, so each extra book lengthens the longest stall by about one
    /// book's work. A cancelled build, or one that a restyle or another build overtook while it
    /// drew, leaves the book's parts as they are.
    ///
    /// Returns the IDs of the books built without their covers because the covers came late.
    @discardableResult
    func prepare(
        _ books: [CloudBook], prefetching upcoming: [CloudBook], loadWait: Duration,
        waitsForFonts: Bool = false, width: Int = 1, model: AppModel
    ) async -> Set<Int> {
        let missing = books.filter { book in
            let look = model.look(for: book)
            guard let built = parts[book.id] else { return true }
            return built.look != look || built.wear != Wear(book, accent: look.accent)
                || built.covers != book.coverCandidates
        }
        guard !missing.isEmpty else { return [] }
        let (arrivals, delivery) = AsyncStream.makeStream(of: Arrival.self)
        let designs = missing.compactMap { model.design(for: $0) }
        var fonts: Task<Void, Never>?
        if waitsForFonts {
            await model.fonts.load(designs)
            guard !Task.isCancelled else { return [] }
        } else {
            // Nothing cancels this task, so the faces that miss the deadline still load.
            fonts = Task {
                await model.fonts.load(designs)
                delivery.yield(.fonts)
            }
        }
        let covers = model.covers
        for book in missing {
            let pixels = coverPixels(for: book)
            Task {
                delivery.yield(
                    .cover(book.id, await covers.image(for: book, maximumPixelSize: pixels)))
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: loadWait)
            delivery.finish()
        }
        var hasFonts = waitsForFonts
        var arrived = Set<Int>()
        var images: [Int: UIImage] = [:]
        for await arrival in arrivals {
            switch arrival {
            case .fonts: hasFonts = true
            case .cover(let id, let image):
                arrived.insert(id)
                images[id] = image
            }
            if hasFonts, arrived.count == missing.count { break }
        }
        deadline.cancel()
        guard !Task.isCancelled else { return [] }
        for book in upcoming where parts[book.id] == nil {
            let pixels = coverPixels(for: book)
            Task { _ = await covers.image(for: book, maximumPixelSize: pixels) }
        }
        await withTaskGroup(of: Void.self) { group in
            for (index, book) in missing.enumerated() where !Task.isCancelled {
                if index >= width { await group.next() }
                let cover = images[book.id]
                let isLate = !arrived.contains(book.id)
                group.addTask {
                    await self.build(book, cover: cover, isLate: isLate, model: model)
                }
            }
        }
        if let fonts, !hasFonts {
            // The books lettered without their faces are drawn again once the faces have loaded.
            // A drop prepares every wave before the faces arrive, so the redraws queue up: at
            // once, their main-actor work would stall the books still falling. Each redraw also
            // waits for its book's cover, so a slow cover holds back the books behind it.
            let earlier = lateFonts
            lateFonts = Task { [weak self] in
                await earlier?.value
                await fonts.value
                for book in missing { await self?.restyle(book, model: model) }
            }
        }
        return Set(missing.map(\.id)).subtracting(arrived)
    }

    /// Builds and keeps a book's parts for `prepare`, and, when its cover was late, hands the
    /// cover to `addCover` once it arrives.
    private func build(_ book: CloudBook, cover: UIImage?, isLate: Bool, model: AppModel) async {
        let previous = parts[book.id]?.look
        guard
            let built = await makeParts(book, cover: cover, look: model.look(for: book)),
            !Task.isCancelled, parts[book.id]?.look == previous
        else { return }
        parts[book.id] = built
        guard isLate else { return }
        let covers = model.covers
        let pixels = coverPixels(for: book)
        Task { [weak self] in
            guard let cover = await covers.image(for: book, maximumPixelSize: pixels)
            else { return }
            await self?.addCover(cover, to: book.id)
        }
    }

    /// Puts a cover onto a built book's front, cropped to its front board, and hands the book's
    /// materials to `retextured`.
    func addCover(_ cover: UIImage, to id: Int) async {
        // A caller cancelled while the texture loaded, such as a scene that reset, no longer
        // wants the cover.
        guard let parts = parts[id], let image = Self.crop(cover, to: parts.shape),
            let texture = await Self.texture(image), !Task.isCancelled
        else { return }
        let material = Self.jacket(texture, binding: parts.shape.binding)
        self.parts[id]?.materials[Int(BookSlot.cover)] = material
        if let materials = self.parts[id]?.materials { retextured?(id, materials) }
    }

    /// Draws a built book's parts again with its look, keeping its shape, when the look changed
    /// since they were built, such as after its font loaded or the reader recolored it in its
    /// details, and hands the new materials to `retextured`.
    ///
    /// A cancelled call, or one that another restyle or a build overtook while it drew, leaves
    /// the parts as they are, so an older look never replaces a newer one.
    func restyle(_ book: CloudBook, model: AppModel) async {
        let look = model.look(for: book)
        guard let built = parts[book.id], built.look != look else { return }
        let cover = await model.covers.image(for: book, maximumPixelSize: coverPixels(for: book))
        guard !Task.isCancelled,
            let restyled = await makeParts(book, cover: cover, look: look, shape: built.shape),
            !Task.isCancelled, parts[book.id]?.look == built.look
        else { return }
        parts[book.id] = restyled
        retextured?(book.id, restyled.materials)
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
        // Loading both textures at once takes about as long as loading one.
        async let coverTexture = Self.texture(front)
        async let spineTexture = Self.texture(spine)
        let cloth = cloth(look.background, binding: shape.binding)
        let wear = Wear(book, accent: look.accent)
        return Parts(
            shape: shape, mesh: mesh, box: box(for: shape),
            materials: [
                await coverTexture.map { Self.jacket($0, binding: shape.binding) } ?? cloth,
                await spineTexture.map { Self.jacket($0, binding: shape.binding) } ?? cloth,
                pages(wear.pages), cloth,
            ],
            look: look, wear: wear, covers: book.coverCandidates,
            ribbon: wear.ribbon.flatMap { ribbon(shape, tenths: $0) })
    }

    /// A rigid body for the book with `id`, from its parts: a box as large as the book, `mass`
    /// kilograms or, by default, about as heavy as one of paper, holding the book's model
    /// (`makeModel`) lit by `lighting`'s image-based light. Returns `nil` for a book without
    /// parts.
    func makeBook(
        _ id: Int, mode: PhysicsBodyMode, lighting: Entity, mass: Float? = nil
    ) -> ModelEntity? {
        guard let parts = parts[id], let model = makeModel(id, lighting: lighting) else {
            return nil
        }
        let size = parts.shape.size
        let box = parts.box
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
        book.addChild(model)
        return book
    }

    /// The model of the book with `id`, from its parts, with its ribbon, and with no collision
    /// or physics: lit by `lighting`'s image-based light, or by the scene's own light when it is
    /// `nil`, as in a camera view lit by the room. Returns `nil` for a book without parts.
    func makeModel(_ id: Int, lighting: Entity?) -> Entity? {
        guard let parts = parts[id] else { return nil }
        let model = Entity()
        model.name = Self.modelName
        model.components.set(ModelComponent(mesh: parts.mesh, materials: parts.materials))
        if let lighting {
            model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
        }
        Self.setGroundingShadow(groundsBooks, on: model)
        if let ribbon = parts.ribbon {
            _ = BookRibbon.registered
            let entity = Entity()
            entity.name = Self.ribbonName
            entity.components.set(ribbon)
            if let lighting {
                entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
            }
            model.addChild(entity)
            model.components.set(BookRibbon())
        }
        return model
    }

    /// Lets the ribbon of `book`, a rigid body from `makeBook`, show while the book lies front
    /// cover up, or hides it at once.
    static func allowRibbon(_ allowed: Bool, on book: Entity) {
        guard let model = book.children.first,
            model.components[BookRibbon.self]?.isAllowed != allowed
        else { return }
        model.components[BookRibbon.self]?.isAllowed = allowed
        if !allowed { model.findEntity(named: ribbonName)?.isEnabled = false }
    }

    /// Gives the books under `roots`, and the books `makeBook` makes from now on, a soft shadow
    /// right under them while `grounds`, and takes it away otherwise.
    func setGroundingShadows(_ grounds: Bool, under roots: [Entity]) {
        groundsBooks = grounds
        func update(_ entity: Entity) {
            if entity.name == Self.modelName {
                Self.setGroundingShadow(grounds, on: entity)
            } else {
                entity.children.forEach(update)
            }
        }
        roots.forEach(update)
    }

    /// Gives a book's `model` a soft shadow right under it while `grounds`, so a book on the
    /// table or the pile sits on it, and otherwise removes the component, which can cost
    /// rendering time even while it casts nothing.
    private static func setGroundingShadow(_ grounds: Bool, on model: Entity) {
        if grounds {
            model.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true))
        } else {
            model.components.remove(GroundingShadowComponent.self)
        }
    }

    /// Drops the parts of books not in `ids`, and the meshes and collision boxes no remaining
    /// book uses. With no IDs, also drops the shared materials.
    func release(keeping ids: Set<Int>) {
        parts = parts.filter { ids.contains($0.key) }
        let shapes = Set(parts.values.map(\.shape))
        meshes = meshes.filter { shapes.contains($0.key) }
        boxes = boxes.filter { shapes.contains($0.key) }
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
        let mesh = await task.value
        // A failed build is tried again the next time a book of this shape needs it.
        if mesh == nil, meshes[shape] == task { meshes[shape] = nil }
        return mesh
    }

    private func box(for shape: BookShape) -> ShapeResource {
        if let box = boxes[shape] { return box }
        let box = ShapeResource.generateBox(size: shape.size)
        boxes[shape] = box
        return box
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

    /// A cover or spine: a satin jacket on a hardcover, matte card on a paperback.
    private static func jacket(_ texture: TextureResource, binding: BookBinding)
        -> PhysicallyBasedMaterial
    {
        finish(surface(texture, roughness: 0.6, specular: 0.12), binding: binding)
    }

    /// `material` with a hardcover jacket's faint satin coat, or a paperback's matte card.
    ///
    /// The lamp hangs almost behind the camera, so a book that tilts toward the camera, as one
    /// resting on another often does, mirrors the lamp across its whole front. A glossier
    /// jacket, or a sharper or stronger coat, turns that sheen into a pale veil that lifts the
    /// cover's dark ink to gray. This finish keeps the ink dark.
    private static func finish(_ material: PhysicallyBasedMaterial, binding: BookBinding)
        -> PhysicallyBasedMaterial
    {
        var material = material
        switch binding {
        case .hardcover:
            material.clearcoat = .init(floatLiteral: 0.1)
            material.clearcoatRoughness = .init(floatLiteral: 0.7)
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
    /// yellow with the time since the reader first finished them: quickly at first, then more
    /// slowly, until they are fully aged after `yellowingYears`. Ages round to eighths, so books
    /// share page materials. Unfinished books have fresh pages.
    static func color(of book: CloudBook, accent: ColorValue, now: Date = .now) -> ColorValue {
        if isSprayed(book) { return accent.mixed(with: fresh, 0.12) }
        guard let finished = CloudBook.day(book.firstFinish) else { return fresh }
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

/// Marks the model entity of a current read, whose ribbon (`BookFactory.ribbonName`) droops
/// in the book's own frame, toward the back cover. `BookRibbonSystem` shows the ribbon only
/// while the book lies front cover up, the one way that droop falls with gravity, and while
/// `isAllowed`, which a lifted book's flight clears at its details.
struct BookRibbon: Component {
    var isAllowed = true

    /// Registers the component and its system, once.
    @MainActor static let registered: Void = {
        registerComponent()
        BookRibbonSystem.registerSystem()
    }()

    /// Whether a ribbon falls with gravity on a book whose front cover faces `front`, a unit
    /// vector in the scene: the cover must face within about 37 degrees of straight up, as on
    /// a book lying on others in a pile.
    static func falls(front: SIMD3<Float>) -> Bool { front.y > 0.8 }
}

/// Shows or hides each current read's ribbon as its book lies (see `BookRibbon`).
struct BookRibbonSystem: System {
    private static let query = EntityQuery(where: .has(BookRibbon.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        for model in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let mark = model.components[BookRibbon.self],
                let ribbon = model.children.first(where: { $0.name == BookFactory.ribbonName })
            else { continue }
            let front = model.convert(direction: [0, 0, 1], to: nil)
            let shows = mark.isAllowed && BookRibbon.falls(front: front)
            if ribbon.isEnabled != shows { ribbon.isEnabled = shows }
        }
    }
}
