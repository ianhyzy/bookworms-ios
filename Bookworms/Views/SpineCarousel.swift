import SwiftUI

/// The shelf's two presentations of the library.
enum ShelfMode: String, CaseIterable, Identifiable {
    /// Spines lying flat, stacked top to bottom on a wheel that turns about the x axis.
    case stack
    /// Spines standing side by side, turning about the y axis like cover flow.
    case shelf

    var id: Self { self }
    var title: String { self == .stack ? "Stack" : "Shelf" }
}

/// A snapping 3D carousel of spines that reports the centered book through `centeredID`.
///
/// Each spine's 3D pose is a `visualEffect` of its distance from the viewport center, so
/// scrolling changes only render effects and never re-evaluates a body. (`scrollTransition`
/// cannot drive a wheel: its phase reaches ±1 about one spine's length from its threshold.)
/// The body does not read `centeredID`; only the button actions do, when tapped. A tap on the
/// centered spine opens it, and a tap on another spine brings it to the center. VoiceOver
/// activation always opens the book.
struct SpineCarousel: View {
    let books: [CloudBook]
    let mode: ShelfMode
    @Binding var centeredID: Int?
    /// The zoom transition's source namespace; each spine is a source keyed by its book ID.
    let namespace: Namespace.ID
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Space between the screen edges and a stacked spine's ends.
    private static let sideMargin: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            switch mode {
            case .stack: stack(in: proxy.size)
            case .shelf: shelf(in: proxy.size)
            }
        }
        .background {
            // A pool of warm light behind the centered spine, larger than the carousel so its
            // falloff never meets an edge.
            RadialGradient(
                colors: [ShelfPalette.lamp.opacity(0.22), .clear], center: .center,
                startRadius: 0, endRadius: 320
            )
            .frame(width: 700, height: 700)
            .accessibilityHidden(true)
        }
    }

    private func stack(in size: CGSize) -> some View {
        let length = size.width - 2 * Self.sideMargin
        let center = size.height / 2
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                endSpace(size.height, beside: books.first)
                LazyVStack(spacing: 6) {
                    ForEach(books) { book in
                        let thickness = book.slabThickness
                        spineButton(book) {
                            SpineView(book: book, look: model.look(for: book))
                                .frame(width: length, height: thickness)
                        }
                        .visualEffect { content, proxy in
                            let pose = WheelPose(
                                distance: proxy.frame(in: .scrollView).midY - center,
                                length: thickness, viewport: size.height)
                            return
                                content
                                .rotation3DEffect(pose.angle, axis: (x: 1, y: 0, z: 0))
                                .scaleEffect(pose.scale)
                                .offset(y: pose.offset)
                                .brightness(pose.brightness)
                                .opacity(pose.opacity)
                        }
                    }
                }
                .scrollTargetLayout()
                endSpace(size.height, beside: books.last)
            }
        }
        .modifier(CenterSnapping(centeredID: $centeredID))
    }

    /// Space before the first spine or after the last, so either end can reach the center.
    ///
    /// Spacer views instead of `contentMargins`, which make `.viewAligned(anchor: .center)`
    /// center the wrong spine after some programmatic scrolls.
    private func endSpace(_ viewport: CGFloat, beside book: CloudBook?) -> some View {
        let length = (viewport - (book?.slabThickness ?? 0)) / 2
        return Color.clear.frame(
            width: mode == .shelf ? length : nil, height: mode == .stack ? length : nil)
    }

    private func shelf(in size: CGSize) -> some View {
        // Leaves room under the spines for the shelf board.
        let height = min(440, size.height - 56)
        let center = size.width / 2
        return VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    endSpace(size.width, beside: books.first)
                    LazyHStack(alignment: .bottom, spacing: 4) {
                        ForEach(books) { book in
                            let thickness = book.slabThickness
                            spineButton(book) {
                                UprightSpineView(
                                    book: book, look: model.look(for: book), height: height,
                                    thickness: thickness)
                            }
                            .visualEffect { content, proxy in
                                let pose = CoverFlowPose(
                                    distance: proxy.frame(in: .scrollView).midX - center,
                                    length: thickness, viewport: size.width)
                                return
                                    content
                                    .rotation3DEffect(
                                        pose.angle, axis: (x: 0, y: 1, z: 0), perspective: 0.7
                                    )
                                    .scaleEffect(pose.scale, anchor: .bottom)
                                    .offset(x: pose.offset)
                                    .brightness(pose.brightness)
                                    .opacity(pose.opacity)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    endSpace(size.width, beside: books.last)
                }
            }
            .frame(height: height)
            .scrollClipDisabled()
            .modifier(CenterSnapping(centeredID: $centeredID))
            ShelfBoard()
        }
        .frame(maxHeight: .infinity)
    }

    private func spineButton(_ book: CloudBook, @ViewBuilder label: () -> some View)
        -> some View
    {
        Button {
            if voiceOver || book.id == (centeredID ?? books.first?.id) {
                open(book)
            } else {
                withAnimation(reduceMotion ? nil : .smooth) { centeredID = book.id }
            }
        } label: {
            label().matchedTransitionSource(id: book.id, in: namespace)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(book.title), by \(book.author)")
        .accessibilityHint("Opens the book's details.")
    }
}

/// Snaps the carousel so a spine always rests at the center and tracks which one it is.
private struct CenterSnapping: ViewModifier {
    @Binding var centeredID: Int?

    func body(content: Content) -> some View {
        content
            .scrollTargetBehavior(.viewAligned(anchor: .center))
            .scrollPosition(id: $centeredID, anchor: .center)
            .scrollIndicators(.hidden)
            // The spines fade out before the carousel's ends, so the bar's edge effect would
            // only draw a seam across the walnut wall.
            .scrollEdgeEffectHidden()
    }
}

/// The walnut board the upright spines stand on.
private struct ShelfBoard: View {
    var body: some View {
        LinearGradient(
            colors: [ShelfPalette.board, ShelfPalette.board.mix(with: .black, by: 0.45)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 16)
        .overlay(alignment: .top) {
            // The lit front edge of the board.
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 10, y: 8)
        .accessibilityHidden(true)
    }
}

/// A stacked spine's pose on a drum: the flat scroll strip wrapped around a cylinder whose axis
/// runs across the screen.
///
/// `distance` is the spine center's offset from the viewport center along the scroll axis.
/// Wrapping keeps arc length, so neighbors stay evenly spaced near the center and crowd
/// together as they turn away, the way a wheel looks.
struct WheelPose {
    let angle: Angle
    let scale: Double
    /// The shift along the scroll axis from the flat position to the drum position.
    let offset: Double
    let brightness: Double
    let opacity: Double

    /// The turn where a spine leaves the viewport.
    static let maximumAngle = 0.95

    init(distance: Double, length: Double, viewport: Double) {
        // The distance at which the spine has fully left the viewport.
        let reach = (viewport + length) / 2
        let phase = max(-1, min(1, distance / reach))
        let radius = reach / Self.maximumAngle
        let theta = phase * Self.maximumAngle
        // Depth behind the front of the drum, seen by a camera three radii in front of it.
        let depth = radius * (1 - cos(theta))
        scale = 1 / (1 + depth / (3 * radius))
        offset = radius * sin(theta) * scale - phase * reach
        // A positive turn about x tips the top edge away, as on the upper half of the drum.
        angle = .radians(-theta)
        brightness = -0.22 * abs(phase)
        opacity = 1 - pow(abs(phase), 1.6)
    }
}

/// An upright spine's cover-flow pose: spines beside the center turn toward it and close up.
struct CoverFlowPose {
    let angle: Angle
    let scale: Double
    let offset: Double
    let brightness: Double
    let opacity: Double

    init(distance: Double, length: Double, viewport: Double) {
        let phase = max(-1, min(1, distance / ((viewport + length) / 2)))
        // Turns fully within about one spine's width of the center.
        let turn = max(-1, min(1, distance / 70))
        angle = .degrees(48 * turn)
        // Side spines show only part of their width once turned, so they close up.
        offset = -turn * 14 - (distance - turn * 70) * 0.28
        scale = 1 - 0.1 * abs(phase)
        brightness = -0.18 * abs(turn) - 0.1 * abs(phase)
        opacity = 1 - phase * phase
    }
}

extension CloudBook {
    /// The carousel thickness of the book's spine: `thicknessRatio`, which spans 0.05...0.2,
    /// mapped linearly onto 44...96 points, so even a short book has room for a legible title.
    var slabThickness: CGFloat { 44 + (thicknessRatio - 0.05) / 0.15 * 52 }
}
