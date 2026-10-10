import Metal
import RealityKit
import SwiftUI
import UIKit

/// Renders share images of books dropped into a pile, without a view.
///
/// `ImageRenderer` cannot capture a `RealityView`, so the renderer builds a `BookPileScene` that
/// no view shows, runs its physics in a `RealityRenderer`, renders one frame into a Metal
/// texture, and copies the frame to memory. SwiftUI then draws the heading and the credit over
/// it.
@MainActor
enum PileSnapshotRenderer {
    /// The most books one image drops. Books drop last first, so the books left out would lie
    /// under the ones that show.
    nonisolated static let maximumBooks = 150

    @MainActor @Observable fileprivate final class Activity {
        var isRendering = false
    }

    private static let activity = Activity()

    /// Whether an image is rendering. Views that read it update when it changes.
    ///
    /// `RealityRenderer` steps the same RealityKit engine that draws every `RealityView`, and
    /// RealityKit's render thread can crash drawing a view's meshes while this renderer steps
    /// it. `BookPileView` therefore takes its entities out of its view's scene while this is
    /// set, whichever tab starts the render.
    static var isRendering: Bool { activity.isRendering }

    /// Renders `books` as a pile under the heading `title`, at the pixel size of `aspect`.
    ///
    /// The books drop in reverse order, so the first books land on top; past `maximumBooks`,
    /// only the first ones drop, and the heading still counts every book. Fewer books are
    /// framed closer, with sharper textures, and the camera then fits the settled pile between
    /// the heading and the bottom margin. `seed` picks their starting poses. Covers and spine
    /// fonts load first, for up to 10 seconds, and the simulation then runs on the main actor
    /// between short pauses. The renderer, the scene, and their textures are released when
    /// this returns.
    ///
    /// One image renders at a time: a call waits for the previous one, which can still be
    /// finishing its frame after its task was cancelled. `isRendering` stays set from the start
    /// of the render until the image is ready, and the simulation starts a few frames after it
    /// is set, so views have time to react.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, and `PileSnapshotError` when
    ///   Metal fails or the rendered frame is one flat color.
    static func render(
        books: [CloudBook], title: String, aspect: ShareAspect, seed: UInt64, model: AppModel
    ) async throws -> UIImage {
        while activity.isRendering { try await Task.sleep(for: .milliseconds(50)) }
        activity.isRendering = true
        defer { activity.isRendering = false }
        try await Task.sleep(for: .milliseconds(100))
        let dropped = Array(books.prefix(maximumBooks).reversed())
        guard let layout = PileSnapshotLayout(aspect: aspect, count: dropped.count) else {
            throw PileSnapshotError.drawingFailed
        }
        let pile = try await renderPile(dropped, layout: layout, seed: seed, model: model)
        let renderer = ImageRenderer(
            content: PileSnapshotCard(pile: pile, title: title, count: books.count, layout: layout))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { throw PileSnapshotError.drawingFailed }
        return image
    }

    /// Drops and settles the books, then renders one frame and copies it into a `CGImage`.
    ///
    /// RealityKit renders into a private texture, which a blit copies into a shared buffer once
    /// the render signals its event. The texture is `bgra8Unorm_srgb`, and `RealityRenderer`
    /// writes Display P3 primaries with the sRGB transfer curve, so the image is tagged P3.
    private static func renderPile(
        _ books: [CloudBook], layout: PileSnapshotLayout, seed: UInt64, model: AppModel
    ) async throws -> CGImage {
        let width = Int(layout.aspect.size.width)
        let height = Int(layout.aspect.size.height)
        let bytesPerRow = (width * 4 + 255) / 256 * 256
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
            let event = device.makeSharedEvent(),
            let texture = device.makeTexture(descriptor: descriptor),
            let buffer = device.makeBuffer(
                length: bytesPerRow * height, options: .storageModeShared)
        else { throw PileSnapshotError.drawingFailed }

        let scene = BookPileScene(textureScale: layout.textureScale)
        let renderer = try RealityRenderer()
        renderer.entities.append(scene.root)
        defer { renderer.entities.removeAll() }
        renderer.activeCamera = scene.camera
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.isToneMappingEnabled = true
        try await scene.settle(
            books, on: layout.tray, camera: layout.camera, seed: seed, model: model
        ) { try renderer.update(1.0 / 60) }
        scene.look(
            through: layout.camera.framing(
                scene.bookCorners, in: layout.pileRect, of: layout.aspect.size,
                zoomRange: 0.25...layout.camera.zoom * 1.25))
        try renderer.updateAndRender(
            deltaTime: 1.0 / 60,
            cameraOutput: RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture)),
            actionsAfterRender: [.signal(event, value: 1)])

        guard let commands = queue.makeCommandBuffer() else {
            throw PileSnapshotError.drawingFailed
        }
        commands.encodeWaitForEvent(event, value: 1)
        guard let blit = commands.makeBlitCommandEncoder() else {
            throw PileSnapshotError.drawingFailed
        }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        await withCheckedContinuation { continuation in
            commands.addCompletedHandler { _ in continuation.resume() }
            commands.commit()
        }
        let pixels = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        guard commands.status == .completed,
            !isBlank(pixels, width: width, height: height, bytesPerRow: bytesPerRow),
            let space = CGColorSpace(name: CGColorSpace.displayP3),
            let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw PileSnapshotError.drawingFailed }
        return image
    }

    /// Whether a BGRA frame is one flat color, as a renderer that drew nothing leaves it. Reads
    /// the green channel of a 32 × 32 grid of pixels.
    nonisolated static func isBlank(_ pixels: Data, width: Int, height: Int, bytesPerRow: Int)
        -> Bool
    {
        var lowest = UInt8.max
        var highest = UInt8.min
        for row in stride(from: 0, to: height, by: max(1, height / 32)) {
            for column in stride(from: 0, to: width, by: max(1, width / 32)) {
                let green = pixels[pixels.startIndex + row * bytesPerRow + column * 4 + 1]
                lowest = min(lowest, green)
                highest = max(highest, green)
            }
        }
        return highest - lowest < 8
    }
}

enum PileSnapshotError: LocalizedError {
    case drawingFailed

    var errorDescription: String? { "The pile could not be drawn." }
}

/// Where a pile share image puts its heading and its pile, and how closely it frames the books.
struct PileSnapshotLayout: Equatable {
    let aspect: ShareAspect
    let titleSize: CGFloat
    /// The bottom of the heading. The tray lies below it and above the bottom margin, which the
    /// platforms' bars and the credit use.
    let pileTop: CGFloat
    /// The default camera, zoomed within `zoomRange` until the tray gives each book about
    /// `areaPerBook`.
    let camera: PileCamera
    let tray: PileTray

    /// Table area per book, in square units: a little more than a cover, so few books spread
    /// out and many books overlap only once they pile up.
    static let areaPerBook: Float = 4.5
    /// The pile height the walls make room for. A share image's pile is lower than the view's,
    /// and its walls go before it settles, so the tray can reach closer to the heading.
    static let pileHeight: Float = 2
    /// The camera's zoom for the drop. It reaches closer than the view's, so a month of one
    /// or two books still fills the image.
    static let zoomRange: ClosedRange<Float> = 1...4

    /// The scale of each book's textures: closer books need more pixels. Memory stays bounded,
    /// because the zoom that doubles the scale fits about a quarter as many books.
    var textureScale: CGFloat { CGFloat(camera.zoom) }

    /// The part of the image the settled books are framed in: below the heading and the
    /// steepest part of its fade, above the bottom margin, and within half the side margins.
    var pileRect: CGRect {
        let size = aspect.size
        let side = aspect.insets.leading / 2
        let top = pileTop + 30
        return CGRect(
            x: side, y: top, width: size.width - 2 * side,
            height: size.height - aspect.insets.bottom - top)
    }

    /// Fits `count` books into an image of `aspect`, or returns `nil` if the camera cannot see
    /// a tray between the heading and the bottom margin.
    init?(aspect: ShareAspect, count: Int) {
        self.aspect = aspect
        titleSize = aspect == .story ? 132 : 100
        // The title's line and the count's line, with room for their shadow.
        pileTop = aspect.insets.top + titleSize * 1.25 + 72
        let viewport = PileViewport(
            size: aspect.size,
            insets: EdgeInsets(top: pileTop, leading: 0, bottom: aspect.insets.bottom, trailing: 0))
        let wanted = Float(max(1, count)) * Self.areaPerBook
        var camera = PileCamera()
        func tray() -> PileTray? {
            PileTray(viewport: viewport, pileHeight: Self.pileHeight, camera: camera)
        }
        while camera.zoom < Self.zoomRange.upperBound, let tray = tray(), tray.area > wanted {
            camera.zoom = min(camera.zoom + 0.05, Self.zoomRange.upperBound)
        }
        guard let tray = tray() else { return nil }
        self.camera = camera
        self.tray = tray
    }
}

extension PileCamera {
    /// This camera, moved across the table and zoomed within `zoomRange`, so that `points` fill
    /// as much of `rect` as they can while staying inside it. `rect` is in the pixels of an
    /// image of `size`, with y growing downward.
    ///
    /// Each pass zooms by how much the points over- or underfill `rect` and slides the target
    /// to center them, since their projection grows about in proportion to zoom and moves with
    /// the target. Perspective makes each pass inexact, so the passes aim for 97 percent of
    /// `rect`.
    func framing(
        _ points: [SIMD3<Float>], in rect: CGRect, of size: CGSize,
        zoomRange: ClosedRange<Float>
    ) -> PileCamera {
        let aspect = Float(size.width / size.height)
        // `rect` in normalized device coordinates, whose y grows upward.
        let low = SIMD2(
            Float(2 * rect.minX / size.width - 1), Float(1 - 2 * rect.maxY / size.height))
        let high = SIMD2(
            Float(2 * rect.maxX / size.width - 1), Float(1 - 2 * rect.minY / size.height))
        let turn = simd_quatf(angle: yaw, axis: [0, 1, 0])
        var camera = self
        for _ in 0..<16 {
            let projected = points.map { camera.project($0, aspect: aspect) }
            guard let first = projected.first else { break }
            let lowest = projected.reduce(first, pointwiseMin)
            let highest = projected.reduce(first, pointwiseMax)
            let fill = ((highest - lowest) / (high - low)).max()
            let offset = (lowest + highest - low - high) / 2
            // Table units per normalized device unit at the target.
            let reach = Self.distance / camera.zoom * tan(Self.fieldOfView / 2)
            camera.target += turn.act(
                [offset.x * reach * aspect, 0, -offset.y * reach / sin(Self.pitch)])
            camera.zoom = min(
                max(camera.zoom / fill * 0.97, zoomRange.lowerBound), zoomRange.upperBound)
        }
        return camera
    }
}

/// The share image: the rendered pile under its heading, with the credit in the bottom margin.
private struct PileSnapshotCard: View {
    let pile: CGImage
    let title: String
    let count: Int
    let layout: PileSnapshotLayout

    /// The darker end of `ShelfPalette.wall`.
    private static let walnut = Color(red: 0.11, green: 0.078, blue: 0.055)

    var body: some View {
        let size = layout.aspect.size
        Image(decorative: pile, scale: 1)
            .resizable()
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .top) {
                // A walnut wall behind the table holds the heading. It hides the far table,
                // whose grain streaks at that distance, and fades out quickly above the pile so
                // little grain shows through it.
                let height = layout.pileTop + 110
                LinearGradient(
                    stops: [
                        .init(color: Self.walnut, location: layout.pileTop / height),
                        .init(
                            color: Self.walnut.opacity(0.55),
                            location: (layout.pileTop + 30) / height),
                        .init(color: Self.walnut.opacity(0), location: 1),
                    ], startPoint: .top, endPoint: .bottom
                )
                .frame(height: height)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    Text(title)
                        .font(ShareStyle.serif(layout.titleSize, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(count == 1 ? "1 book" : "\(count.formatted()) books")
                        .font(ShareStyle.serif(40))
                        .opacity(0.8)
                }
                .foregroundStyle(ShareStyle.cream.color)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                .padding(.horizontal, layout.aspect.insets.leading)
                .padding(.top, layout.aspect.insets.top)
            }
            // A big pile can spread into the bottom margin; shade it so the credit stays legible.
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [Self.walnut.opacity(0), Self.walnut.opacity(0.7)], startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
            }
            // The credit that `ShareCanvas` puts on every share image.
            .overlay(alignment: .bottom) {
                Text("Created with Bookworms for iPhone")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ShareStyle.cream.color.opacity(0.45))
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .padding(.bottom, 18)
            }
            .environment(\.colorScheme, .dark)
    }
}
