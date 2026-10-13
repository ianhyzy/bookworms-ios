import Metal
import RealityKit
import SwiftUI
import UIKit

/// Renders share images of books dropped into a pile, without a view.
///
/// `ImageRenderer` cannot capture a `RealityView`, so the renderer builds a `BookPileScene` that
/// no view shows, runs its physics in a `RealityRenderer`, renders one frame into a Metal
/// texture, and copies the frame to memory. SwiftUI then draws the heading over it; sharing adds
/// the credit (`UIImage.withShareCredit()`).
@MainActor
enum PileSnapshotRenderer {
    /// The most books one image drops. Books drop last first, so the books left out would lie
    /// under the ones that show.
    nonisolated static let maximumBooks = 150

    @MainActor @Observable fileprivate final class Activity {
        var isRendering = false
        /// Renders waiting for their turn, in the order they asked.
        @ObservationIgnored var waiting = [(id: UUID, turn: CheckedContinuation<Void, any Error>)]()
    }

    private static let activity = Activity()

    /// Whether an image or a video (`renderMovie`) is rendering. Views that read it update when
    /// it changes.
    ///
    /// `RealityRenderer` steps the same RealityKit engine that draws every `RealityView`, and
    /// RealityKit's render thread can crash drawing a view's meshes while this renderer steps
    /// it. The 3D views therefore take their entities out of their scenes while this is set,
    /// whichever tab starts the render.
    static var isRendering: Bool { activity.isRendering }

    /// Renders `books` spread front cover up across the table under the heading `title`, at the
    /// pixel size of `aspect`.
    ///
    /// Past `maximumBooks`, only the first books show, and the heading still counts every book.
    /// The books lie as `PileSpread` lays them out, so that at least four fifths of each front
    /// cover shows, and the camera fits them between the heading and the bottom margin, closer
    /// for fewer books, with sharper textures. `seed` picks the arrangement. Spine fonts load
    /// first, for as long as their downloads take (see `SpineFonts.load(_:)`), then covers, for
    /// up to 10 seconds. A cancelled render stops waiting for fonts and covers at once. The
    /// renderer, the scene, and their textures are released when this returns.
    ///
    /// One image renders at a time: a call waits for the renders that asked first, including
    /// one that is still finishing its frame after its task was cancelled. `isRendering` stays
    /// set from the start of the render until the image is ready, and the renderer starts
    /// stepping the scene a few frames after it is set, so views have time to react.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, and `PileSnapshotError` when
    ///   Metal fails or the rendered frame is one flat color.
    static func render(
        books: [CloudBook], title: String, aspect: ShareAspect, seed: UInt64, model: AppModel
    ) async throws -> UIImage {
        try await claim()
        defer { release() }
        let shown = Array(books.prefix(maximumBooks))
        let layout = PileSnapshotLayout(aspect: aspect, count: shown.count)
        let pile = try await renderPile(shown, layout: layout, seed: seed, model: model)
        let renderer = ImageRenderer(
            content: PileSnapshotCard(
                pile: pile, title: title, count: books.count, layout: layout, showsCredit: false))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { throw PileSnapshotError.drawingFailed }
        return image
    }

    /// Waits for the render in progress and the renders that asked earlier, if any, then sets
    /// `isRendering` and gives views 100 milliseconds to react. A render calls this first and
    /// `release()` when it ends, on every path. A render cancelled while it waits leaves the line.
    ///
    /// Turns go first come, first served. A still image's loop releases and claims again in
    /// one turn of the main actor, so a lock that anyone could take once free would let a run of
    /// images, such as those a generation run's saved designs trigger, keep a video waiting.
    static func claim() async throws {
        if activity.isRendering {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { turn in
                    activity.waiting.append((id, turn))
                }
            } onCancel: {
                Task { @MainActor in
                    guard let index = activity.waiting.firstIndex(where: { $0.id == id }) else {
                        return
                    }
                    activity.waiting.remove(at: index).turn.resume(throwing: CancellationError())
                }
            }
        } else {
            activity.isRendering = true
        }
        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            release()
            throw error
        }
    }

    /// Ends the render that `claim()` started, and hands the turn to the next render waiting,
    /// if any, with `isRendering` still set.
    static func release() {
        if activity.waiting.isEmpty {
            activity.isRendering = false
        } else {
            activity.waiting.removeFirst().turn.resume()
        }
    }

    /// Lays the books out, then renders one frame and copies it into a `CGImage`.
    ///
    /// RealityKit renders into a private texture, which a blit copies into memory once the
    /// render signals its event (`FrameTarget`). The texture is `bgra8Unorm_srgb`, and
    /// `RealityRenderer` writes Display P3 primaries with the sRGB transfer curve, so the image is
    /// tagged P3. The books are static bodies, so the few steps before the frame move nothing.
    private static func renderPile(
        _ books: [CloudBook], layout: PileSnapshotLayout, seed: UInt64, model: AppModel
    ) async throws -> CGImage {
        let width = Int(layout.aspect.size.width)
        let height = Int(layout.aspect.size.height)
        let target = try FrameTarget(width: width, height: height)
        let scene = BookPileScene(textureScale: layout.textureScale)
        let renderer = try RealityRenderer()
        renderer.entities.append(scene.root)
        defer { renderer.entities.removeAll() }
        renderer.activeCamera = scene.camera
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.isToneMappingEnabled = true
        let spread = await scene.prepareSpread(
            books, in: layout.pileRect, of: layout.aspect.size, seed: seed, model: model)
        try Task.checkCancellation()
        scene.place(spread.slots, mode: .static)
        for _ in 0..<3 { try renderer.update(1.0 / 60) }
        #if DEBUG
            scene.logCovers("image seed \(seed), \(books.count) books")
            scene.logSpread("image seed \(seed)", in: layout.pileRect, of: layout.aspect.size)
        #endif
        try renderer.updateAndRender(
            deltaTime: 1.0 / 60, cameraOutput: target.output,
            actionsAfterRender: [.signal(target.event, value: 1)])
        try await target.read(after: 1, before: .now + .seconds(10))
        let pixels = Data(bytes: target.buffer.contents(), count: target.bytesPerRow * height)
        guard !target.isBlank,
            let space = CGColorSpace(name: CGColorSpace.displayP3),
            let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: target.bytesPerRow, space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw PileSnapshotError.drawingFailed }
        #if DEBUG
            if UserDefaults.standard.bool(forKey: "BookwormsPileCoverLog") {
                try await checkCovers(
                    scene, renderer: renderer, target: target, camera: spread.camera,
                    layout: layout, label: "pixels seed \(seed), \(books.count) books")
            }
        #endif
        return image
    }

    #if DEBUG
        /// Simulator hook: with `-BookwormsPileCoverLog YES`, measures in rendered frames how
        /// much of each front cover an image shows, and appends the least and the mean share to
        /// the cover log (see `BookPileScene.logCovers`).
        ///
        /// It draws the covers white on black (`BookPileScene.showCovers`), without
        /// antialiasing or tone mapping, a few covers per frame: covers whose bounds in the image
        /// are apart, so that each white pixel belongs to one of them. A cover's share is its
        /// white pixels inside the pile rect over the area its corners span in the image. The
        /// cover's corners are the front board's, as `PileSpread` measures it, so bevels and
        /// rounded corners count as hidden.
        private static func checkCovers(
            _ scene: BookPileScene, renderer: RealityRenderer, target: FrameTarget,
            camera: PileCamera, layout: PileSnapshotLayout, label: String
        ) async throws {
            let size = layout.aspect.size
            let rect = layout.pileRect
            let covers = scene.showCovers([])
                .map { corners in
                    corners.map { point in
                        let ndc = camera.project(point, aspect: Float(size.width / size.height))
                        return CGPoint(
                            x: CGFloat(ndc.x + 1) / 2 * size.width,
                            y: CGFloat(1 - ndc.y) / 2 * size.height)
                    }
                }
            let bounds = covers.map { corners in
                let xs = corners.map(\.x)
                let ys = corners.map(\.y)
                return CGRect(
                    x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!,
                    height: ys.max()! - ys.min()!)
            }
            var groups: [[Int]] = []
            for index in covers.indices {
                let reach = bounds[index].insetBy(dx: -2, dy: -2)
                if let group = groups.firstIndex(where: {
                    $0.allSatisfy { !bounds[$0].intersects(reach) }
                }) {
                    groups[group].append(index)
                } else {
                    groups.append([index])
                }
            }
            renderer.cameraSettings.antialiasing = .none
            renderer.cameraSettings.isToneMappingEnabled = false
            renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 1))
            var shares = [Float](repeating: 0, count: covers.count)
            for (number, group) in groups.enumerated() {
                _ = scene.showCovers(Set(group))
                let signal = UInt64(number + 2)
                try renderer.updateAndRender(
                    deltaTime: 1.0 / 60, cameraOutput: target.output,
                    actionsAfterRender: [.signal(target.event, value: signal)])
                try await target.read(after: signal, before: .now + .seconds(10))
                let pixels = target.buffer.contents().assumingMemoryBound(to: UInt8.self)
                for index in group {
                    let box = bounds[index].intersection(rect).integral
                    var white = 0
                    for y in Int(box.minY)..<Int(box.maxY) {
                        for x in Int(box.minX)..<Int(box.maxX)
                        where pixels[y * target.bytesPerRow + x * 4 + 1] > 127 {
                            white += 1
                        }
                    }
                    let corners = covers[index]
                    let area =
                        abs(
                            corners.indices.reduce(CGFloat(0)) { sum, corner in
                                let next = corners[(corner + 1) % corners.count]
                                return sum + corners[corner].x * next.y - next.x * corners[corner].y
                            }) / 2
                    shares[index] = Float(CGFloat(white) / max(area, 1))
                }
            }
            func percent(_ value: Float) -> String {
                (value * 100).formatted(.number.precision(.fractionLength(1))) + "%"
            }
            let mean = shares.reduce(0, +) / Float(max(shares.count, 1))
            BookPileScene.appendCoverLog(
                "\(label): covers shown least \(percent(shares.min() ?? 0)), mean \(percent(mean)) "
                    + "in \(groups.count) frames")
        }
    #endif

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

/// Where a pile share image puts its heading and its books, and how sharp their textures are.
struct PileSnapshotLayout: Equatable {
    let aspect: ShareAspect
    let titleSize: CGFloat
    /// The bottom of the heading. The books lie below it and above the bottom margin, which the
    /// platforms' bars and the credit use.
    let pileTop: CGFloat
    /// How many books the image shows.
    let count: Int

    /// The scale of each book's textures (see `BookFactory`): closer books need more pixels.
    ///
    /// A cover's long side, at most the pile rect's height, spans about the square root of the
    /// rect's area per book, and a scale of 1 draws it 224 pixels long. The scale stays between
    /// 1 and 5, so the count times its square, which texture memory follows, never passes what
    /// the largest pile needs at a scale of 1.
    var textureScale: CGFloat {
        let rect = pileRect
        let side = min(
            rect.height, (rect.width * rect.height / CGFloat(max(count, 1))).squareRoot())
        return min(5, max(1, side / 224))
    }

    /// The part of the image the books are framed in: below the heading and the steepest part
    /// of its fade, above the bottom margin, and within half the side margins.
    var pileRect: CGRect {
        let size = aspect.size
        let side = aspect.insets.leading / 2
        let top = pileTop + 30
        return CGRect(
            x: side, y: top, width: size.width - 2 * side,
            height: size.height - aspect.insets.bottom - top)
    }

    /// Lays out an image of `aspect` that shows `count` books.
    init(aspect: ShareAspect, count: Int) {
        self.aspect = aspect
        self.count = count
        titleSize = aspect == .story ? 132 : 100
        // The title's line and the count's line, with room for their shadow.
        pileTop = aspect.insets.top + titleSize * 1.25 + 72
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
                [offset.x * reach * aspect, 0, -offset.y * reach / sin(camera.pitch)])
            camera.zoom = min(
                max(camera.zoom / fill * 0.97, zoomRange.lowerBound), zoomRange.upperBound)
        }
        return camera
    }
}

/// The share image: the rendered pile under its heading, with the credit in the bottom margin.
struct PileSnapshotCard: View {
    /// The rendered pile, or `nil` for the heading and credit alone, over a clear background,
    /// which a pile video draws over each frame.
    let pile: CGImage?
    let title: String
    let count: Int
    let layout: PileSnapshotLayout
    /// Whether the card draws `ShareCredit`. A still image leaves it out so its preview shows
    /// none, and sharing adds it (`UIImage.withShareCredit()`).
    var showsCredit = true

    /// The darker end of `ShelfPalette.wall`.
    private static let walnut = Color(red: 0.11, green: 0.078, blue: 0.055)

    var body: some View {
        let size = layout.aspect.size
        background
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
            .overlay(alignment: .bottom) {
                if showsCredit { ShareCredit() }
            }
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var background: some View {
        if let pile {
            Image(decorative: pile, scale: 1).resizable()
        } else {
            Color.clear
        }
    }
}
