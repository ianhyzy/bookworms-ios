#if os(iOS)
    import ARKit
    import Combine
    import RealityKit
    import SwiftUI
    import UIKit

    /// What this iPhone can show in **View in my room**.
    ///
    /// The Mac and the Apple TV have no AR camera, so neither builds this file; their share
    /// sheets never list the action.
    enum RoomCamera {
        /// Whether the iPhone tracks the world, which a stack needs.
        static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

        /// Whether the iPhone has LiDAR, whose scene mesh tells a shelf's height and side panels.
        /// Without it, books could stand through the shelf above or over a panel in front of
        /// them, so iPhones without LiDAR get the stack alone.
        static var supportsShelf: Bool {
            ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }

        /// The share sheet action that opens the view (`RoomPhotoView`).
        static let action = ShareAction(
            id: "gay.ian.Bookworms.viewInMyRoom", title: "View in my room",
            systemImage: "arkit")
    }

    /// What **View in my room** places and how its photo reads: a time frame's books, oldest
    /// first, the frame's name, the share size, and the username whose profile the share text
    /// links.
    struct RoomPhotoRequest: Identifiable {
        let id = UUID()
        let books: [CloudBook]
        let period: String
        let aspect: ShareAspect
        let username: String?
    }

    /// **View in my room**: the camera, with the time frame's books at life size on a real
    /// surface, one stack or, on iPhones with LiDAR, a row in an empty shelf. The reader taps
    /// to set the books down and takes one photo, which opens the share sheet with a band that
    /// names the period, the count, and the stack's height or the shelf's length.
    ///
    /// Camera frames and the scene mesh stay in ARKit's memory and are never stored; the photo
    /// is kept only until the share sheet writes it (`SharedFiles.images`). Closing the view
    /// ends the session and releases the books' textures.
    struct RoomPhotoView: View {
        let request: RoomPhotoRequest
        @State private var scene = RoomPhotoScene()
        @State private var files: SharedFiles?
        /// Whether a photo is being made, so the shutter takes one at a time.
        @State private var isTaking = false
        @Environment(AppModel.self) private var model
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            ZStack {
                RoomARContainer(scene: scene)
                    .ignoresSafeArea()
                    .onTapGesture { scene.tap() }
                    .accessibilityHidden(true)
                // The whole screen, as the camera view and its snapshot fill it.
                GeometryReader { proxy in framing(in: proxy.size) }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                controls
            }
            .statusBarHidden()
            .task { await scene.load(request.books, model: model) }
            .onChange(of: PileSnapshotRenderer.isRendering, initial: true) { _, isRendering in
                // RealityKit's renderer and this view's share one engine (`isRendering`).
                scene.isDetached = isRendering
            }
            .shareSheet($files)
        }

        /// Dims the camera outside the part that the share image keeps, so the reader frames
        /// for the chosen size.
        private func framing(in size: CGSize) -> some View {
            let photo = RoomPhoto.photoRect(in: size, aspect: request.aspect)
            return Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(photo)
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
        }

        private var controls: some View {
            VStack {
                HStack {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                    Spacer()
                }
                Spacer()
                if RoomCamera.supportsShelf {
                    Picker("Arrangement", selection: $scene.mode) {
                        Text("Stack").tag(RoomMode.stack)
                        Text("Shelf").tag(RoomMode.shelf)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .padding(.bottom, 12)
                }
                Button {
                    Task { await takePhoto() }
                } label: {
                    Circle()
                        .fill(.white)
                        .padding(7)
                        .overlay(Circle().stroke(.white, lineWidth: 4))
                        .frame(width: 76, height: 76)
                }
                .accessibilityLabel("Take photo")
                .disabled(!scene.isShowingBooks || isTaking)
                .opacity(scene.isShowingBooks ? 1 : 0.4)
            }
            .padding()
        }

        /// Takes the photo and opens the share sheet with it, its band naming what it shows.
        private func takePhoto() async {
            isTaking = true
            defer { isTaking = false }
            // Read before the snapshot's wait, so a layout change meanwhile can't change them.
            let shown = scene.shownBooks
            let line = scene.measureLine
            let title = "My \(request.period) \(scene.mode == .stack ? "stack" : "shelf")"
            guard let photo = await scene.snapshot(),
                let image = RoomPhoto.render(
                    photo: photo, title: title, line: line, aspect: request.aspect,
                    looks: shown.map { model.look(for: $0) })
            else {
                model.toasts.show(.failure("Couldn't take the photo"))
                return
            }
            do {
                var shared = try await SharedFiles.images(
                    [ShareImage(image: image, name: title, books: shown)])
                shared.text = HardcoverInvite.readingText(
                    books: shown, username: request.username)
                files = shared
            } catch {
                model.toasts.show(.failure("Couldn't prepare the image"))
            }
        }
    }

    /// Whether the books stand in one stack or in a shelf.
    enum RoomMode: Hashable {
        case stack, shelf
    }

    /// The AR session and the books' entities behind `RoomPhotoView`.
    ///
    /// Until the reader taps, the books follow the reticle each frame: the stack stands where
    /// the screen's center meets a level surface, its spines toward the camera, and the shelf
    /// fills the space that `ShelfProbe` measures around that point. A tap sets them down,
    /// and another picks them up again. No physics runs; the books rest where the layout puts
    /// them.
    @MainActor @Observable
    final class RoomPhotoScene {
        var mode = RoomMode.stack {
            didSet { if mode != oldValue { isPlaced = false } }
        }
        var isPlaced = false {
            didSet { reticle.isEnabled = !isPlaced }
        }
        /// Whether books stand in view where the reticle found room for them.
        private(set) var isShowingBooks = false
        /// While set, the scene leaves the view, as other 3D views do while a share image renders.
        var isDetached = false {
            didSet { attach() }
        }

        @ObservationIgnored private var view: ARView?
        @ObservationIgnored private let factory = BookFactory()
        @ObservationIgnored private let anchor = AnchorEntity(world: .zero)
        @ObservationIgnored private let stackRoot = Entity()
        @ObservationIgnored private let shelfRoot = Entity()
        @ObservationIgnored private let reticle = RoomPhotoScene.makeReticle()
        @ObservationIgnored private var tower: BookTower?
        /// The books the room may show: the most popular `RoomPlacement.maximumBooks`, oldest
        /// first.
        @ObservationIgnored private var books: [CloudBook] = []
        @ObservationIgnored private var fill: ShelfFill?
        @ObservationIgnored private var space: ShelfSpace?
        /// Each stacked book's entity, by book ID.
        @ObservationIgnored private var stacked: [Int: Entity] = [:]
        /// Each shelf book's entity, by book ID, made once and reused as the space changes.
        @ObservationIgnored private var shelved: [Int: Entity] = [:]
        @ObservationIgnored private var updates: (any Cancellable)?
        @ObservationIgnored private var frame = 0
        @ObservationIgnored private let seed = UInt64.random(in: 0...UInt64.max)

        init() {
            anchor.addChild(stackRoot)
            anchor.addChild(shelfRoot)
            anchor.addChild(reticle)
            stackRoot.isEnabled = false
            shelfRoot.isEnabled = false
            // A cover or font that arrives after the books were made retextures them in both
            // arrangements.
            factory.retextured = { [weak self] id, materials in
                for entity in [self?.stacked[id], self?.shelved[id]].compactMap({ $0 }) {
                    entity.components[ModelComponent.self]?.materials = materials
                }
            }
        }

        /// Sets the books down where they show, or picks them up again. A tap with no books in
        /// view does nothing.
        func tap() {
            if isPlaced || isShowingBooks { isPlaced.toggle() }
        }

        /// The books the photo shows.
        var shownBooks: [CloudBook] {
            switch mode {
            case .stack: tower?.slots.map(\.book) ?? []
            case .shelf: fill?.slots.map(\.book) ?? []
            }
        }

        /// The band's second line, such as "11 books, 32 cm tall" or "14 books, 54 cm of
        /// shelf", in the iPhone's units.
        var measureLine: String {
            switch mode {
            case .stack:
                RoomPhoto.line(count: shownBooks.count, stackHeight: tower?.stackHeight ?? 0)
            case .shelf:
                RoomPhoto.line(count: shownBooks.count, shelfWidth: fill?.width ?? 0)
            }
        }

        /// Starts the session in `view`: world tracking with level and upright planes, the
        /// room's light on the books, people in front of the books hiding them, and on
        /// iPhones with LiDAR, the scene mesh, which hides books behind real things and which
        /// the shelf's probes measure.
        func start(in view: ARView) {
            self.view = view
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal, .vertical]
            configuration.environmentTexturing = .automatic
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                configuration.frameSemantics.insert(.personSegmentationWithDepth)
            }
            if RoomCamera.supportsShelf {
                configuration.sceneReconstruction = .mesh
                view.environment.sceneUnderstanding.options = [.occlusion, .collision]
            }
            view.renderOptions = [.disableMotionBlur, .disableDepthOfField]
            view.session.run(configuration)
            let coaching = ARCoachingOverlayView()
            coaching.session = view.session
            coaching.goal = .horizontalPlane
            coaching.activatesAutomatically = true
            coaching.frame = view.bounds
            coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(coaching)
            attach()
            updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
        }

        /// Builds the books: the most popular `RoomPlacement.maximumBooks` of `books`, given
        /// oldest first, waiting for their fonts and up to 10 seconds for their covers.
        func load(_ books: [CloudBook], model: AppModel) async {
            let shown = DroppedCard.popular(books, limit: RoomPlacement.maximumBooks)
            factory.setGroundingShadows(true, under: [])
            await factory.prepare(
                shown, prefetching: [], loadWait: .seconds(10), waitsForFonts: true, width: 4,
                model: model)
            guard !Task.isCancelled else { return }
            self.books = shown
            let tower = BookTower(books: shown, seed: seed, shape: shape(of:))
            self.tower = tower
            for slot in tower.slots {
                guard let book = factory.makeModel(slot.book.id, lighting: nil) else { continue }
                book.transform = slot.transform
                stacked[slot.book.id] = book
                stackRoot.addChild(book)
            }
        }

        /// Ends the session and releases the view, the books' entities, and their textures.
        func stop() {
            updates?.cancel()
            updates = nil
            view?.session.pause()
            view?.scene.anchors.removeAll()
            view = nil
            stackRoot.children.removeAll()
            shelfRoot.children.removeAll()
            stacked = [:]
            shelved = [:]
            factory.release(keeping: [])
        }

        /// The camera image with the books and without the reticle, or `nil` if the view
        /// can't draw one.
        func snapshot() async -> UIImage? {
            guard let view else { return nil }
            reticle.isEnabled = false
            defer { reticle.isEnabled = !isPlaced }
            return await withCheckedContinuation { done in
                view.snapshot(saveToHDR: false) { done.resume(returning: $0) }
            }
        }

        private func attach() {
            guard let view else { return }
            if isDetached {
                view.scene.removeAnchor(anchor)
            } else if anchor.scene == nil {
                view.scene.addAnchor(anchor)
            }
        }

        private func shape(of book: CloudBook) -> BookShape {
            factory.parts[book.id]?.shape ?? BookShape(of: book, coverAspect: 2 / 3)
        }

        /// Moves the books to where the screen's center meets a level surface, each frame
        /// until the reader sets them down.
        private func follow() {
            guard !isPlaced, let view, tower != nil else { return }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard
                let hit =
                    view.raycast(
                        from: center, allowing: .estimatedPlane, alignment: .horizontal
                    )
                    .first
            else {
                show(nil)
                return
            }
            let point = SIMD3(
                hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y,
                hit.worldTransform.columns.3.z)
            let camera = view.cameraTransform.translation
            reticle.transform = RoomPlacement.root(at: point, facing: camera)
            switch mode {
            case .stack:
                stackRoot.transform = RoomPlacement.root(at: point, facing: camera)
                show(stackRoot)
            case .shelf:
                // The probes cast dozens of rays, so they run on every sixth frame.
                frame += 1
                guard frame % 6 == 0 else { return }
                guard
                    let found = ShelfProbe.measure(
                        at: point, from: camera,
                        cast: { origin, direction, length in
                            view.scene
                                .raycast(
                                    origin: origin, direction: direction, length: length,
                                    query: .nearest, mask: .sceneUnderstanding, relativeTo: nil
                                )
                                .first?
                                .distance
                        })
                else {
                    show(nil)
                    return
                }
                shelfRoot.transform = found.frame
                shelve(in: found.space)
                show(fill?.slots.isEmpty == false ? shelfRoot : nil)
            }
        }

        private func show(_ root: Entity?) {
            stackRoot.isEnabled = root === stackRoot
            shelfRoot.isEnabled = root === shelfRoot
            let showing = root != nil
            if isShowingBooks != showing { isShowingBooks = showing }
        }

        /// Lays the books out in `space`, unless it is within a centimeter of the space they
        /// already fill, so the row doesn't flicker as the mesh refines.
        private func shelve(in space: ShelfSpace) {
            // An open top's clearance is infinite on both, and infinity minus itself isn't a number.
            if let old = self.space, abs(old.width - space.width) < 0.1,
                old.clearance == space.clearance || abs(old.clearance - space.clearance) < 0.1
            {
                return
            }
            self.space = space
            let fill = ShelfFill(books: books, space: space, seed: seed, shape: shape(of:))
            self.fill = fill
            let shown = Set(fill.slots.map(\.book.id))
            for (id, entity) in shelved { entity.isEnabled = shown.contains(id) }
            for slot in fill.slots {
                let entity =
                    shelved[slot.book.id] ?? factory.makeModel(slot.book.id, lighting: nil)
                guard let entity else { continue }
                if shelved[slot.book.id] == nil {
                    shelved[slot.book.id] = entity
                    shelfRoot.addChild(entity)
                }
                entity.transform = slot.transform
                entity.isEnabled = true
            }
        }

        /// A flat white ring, 14 cm across, that marks where the books will stand.
        private static func makeReticle() -> Entity {
            let ring = ModelEntity(
                mesh: .generateCylinder(height: 0.002, radius: 0.7),
                materials: [UnlitMaterial(color: .white.withAlphaComponent(0.5))])
            ring.position.y = 0.01
            let root = Entity()
            root.addChild(ring)
            return root
        }
    }

    /// Hosts the `ARView` that `RoomPhotoScene` runs. The view exists only while **View in my room**
    /// is open: taking it down stops the scene, which releases the session and the books.
    private struct RoomARContainer: UIViewRepresentable {
        let scene: RoomPhotoScene

        func makeUIView(context: Context) -> ARView {
            let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
            scene.start(in: view)
            return view
        }

        func updateUIView(_ view: ARView, context: Context) {}

        func makeCoordinator() -> RoomPhotoScene { scene }

        static func dismantleUIView(_ view: ARView, coordinator scene: RoomPhotoScene) {
            scene.stop()
        }
    }

    /// The share image that **View in my room** makes from its photo.
    enum RoomPhoto {
        /// The band under the photo, in pixels: on a Story, it reaches into the bottom strip
        /// that the platforms' bars cover, and its text stays above it (`ShareAspect.insets`).
        static func bandHeight(_ aspect: ShareAspect) -> CGFloat { aspect.insets.bottom + 190 }

        /// The part of a view of `size` that the share image's photo keeps: as wide as the
        /// view, centered, at the photo's shape for `aspect`.
        static func photoRect(in size: CGSize, aspect: ShareAspect) -> CGRect {
            let photo = CGSize(
                width: aspect.size.width, height: aspect.size.height - bandHeight(aspect))
            let scale = min(size.width / photo.width, size.height / photo.height)
            let fitted = CGSize(width: photo.width * scale, height: photo.height * scale)
            return CGRect(
                x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                width: fitted.width, height: fitted.height)
        }

        /// "1 book, 2 cm tall" or "11 books, 32 cm tall", with the height as the iPhone's region writes it
        /// (`BookTower.heightText`).
        static func line(count: Int, stackHeight: Float, locale: Locale = .current) -> String {
            "\(books(count)), \(BookTower.heightText(stackHeight, locale: locale)) tall"
        }

        /// "14 books, 54 cm of shelf".
        static func line(count: Int, shelfWidth: Float, locale: Locale = .current) -> String {
            "\(books(count)), \(BookTower.heightText(shelfWidth, locale: locale)) of shelf"
        }

        private static func books(_ count: Int) -> String {
            count == 1 ? "1 book" : "\(count.formatted()) books"
        }

        /// Draws the photo, cropped to `photoRect`'s shape, over a band in the books' colors
        /// (`ShareTheme`) with `title` and `line`, at `aspect`'s pixel size. Returns `nil` if
        /// SwiftUI can't draw it.
        @MainActor
        static func render(
            photo: UIImage, title: String, line: String, aspect: ShareAspect, looks: [SpineLook]
        ) -> UIImage? {
            let renderer = ImageRenderer(
                content: RoomPhotoCard(
                    photo: photo, title: title, line: line, aspect: aspect,
                    theme: ShareTheme(looks: looks)))
            renderer.scale = 1
            renderer.isOpaque = true
            return renderer.uiImage
        }
    }

    private struct RoomPhotoCard: View {
        let photo: UIImage
        let title: String
        let line: String
        let aspect: ShareAspect
        let theme: ShareTheme

        var body: some View {
            let band = RoomPhoto.bandHeight(aspect)
            VStack(spacing: 0) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: aspect.size.width, height: aspect.size.height - band)
                    .clipped()
                VStack(alignment: .leading, spacing: 8) {
                    ShareStyle.title(title, aspect: aspect)
                        .foregroundStyle(ShareStyle.cream.color)
                    Text(line)
                        .font(ShareStyle.serif(40))
                        .foregroundStyle(ShareStyle.gold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, aspect.insets.leading)
                .padding(.top, 40)
                .frame(width: aspect.size.width, height: band, alignment: .topLeading)
                .background(
                    LinearGradient(
                        colors: [theme.backdropLight.color, theme.backdropDark.color],
                        startPoint: .top, endPoint: .bottom))
            }
            .frame(width: aspect.size.width, height: aspect.size.height)
        }
    }
#endif
