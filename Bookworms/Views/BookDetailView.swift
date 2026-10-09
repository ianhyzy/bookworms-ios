import SwiftUI

/// A book's details: a 3D model to turn with a drag, its reading record, and its spine design.
struct BookDetailView: View {
    let book: CloudBook

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cover: UIImage?
    @State private var pose = BookPose.resting
    /// The pose when the current drag began; `nil` between drags.
    @State private var dragStart: BookPose?

    var body: some View {
        let look = model.look(for: book)
        let design = model.library?.designs[book.id]
        ScrollView {
            VStack(spacing: 24) {
                stage(look: look)
                header
                record
                designCard(look: look, design: design)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background { ShelfPalette.wall.ignoresSafeArea() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Share", systemImage: "square.and.arrow.up") { model.share(book) }
            }
        }
        .task(id: book.id) { cover = await model.covers.image(for: book) }
        #if DEBUG
            .onAppear(perform: applyDebugPose)
        #endif
    }

    private func stage(look: SpineLook) -> some View {
        TurningBook(
            book: book, look: look, cover: cover, height: 380, yaw: pose.yaw, pitch: pose.pitch
        )
        .frame(maxWidth: .infinity)
        .frame(height: 460)
        .background {
            // Larger than the stage so the glow's falloff never meets an edge.
            RadialGradient(
                colors: [ShelfPalette.lamp.opacity(0.22), .clear], center: .center,
                startRadius: 0, endRadius: 280
            )
            .frame(width: 640, height: 640)
            .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .gesture(spin)
        .accessibilityHint("Swipe up or down to turn the book.")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? Double.pi / 4 : -Double.pi / 4
            withAnimation(reduceMotion ? nil : .smooth) { pose.yaw += step }
        }
    }

    /// Turns the book with the finger: yaw is unbounded and pitch stays within a gentle tilt.
    /// On release the book coasts with the swipe's momentum and its tilt eases back to rest,
    /// unless Reduce Motion is on, when it stays where the finger left it.
    ///
    /// The drag claims touches that start on the book, so the page scrolls from the text below.
    private var spin: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? pose
                dragStart = start
                pose = start.turned(by: value.translation)
            }
            .onEnded { value in
                let start = dragStart ?? pose
                dragStart = nil
                guard !reduceMotion else { return }
                let coast = start.turned(by: value.predictedEndTranslation)
                withAnimation(.spring(duration: 1.1, bounce: 0.12)) {
                    pose = BookPose(yaw: coast.yaw, pitch: BookPose.resting.pitch)
                }
            }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(book.title)
                .font(.title2.weight(.semibold))
                .fontDesign(.serif)
                .accessibilityAddTraits(.isHeader)
            Text(book.author)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let rating = book.rating, rating > 0 {
                RatingStars(rating: rating).font(.title3).padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(ShelfPalette.paper)
    }

    @ViewBuilder private var record: some View {
        let rows: [(String, String)] = [
            book.seriesPosition.map { ("Series", "Book \($0.formatted())") },
            book.finishedDate.map { ("Finished", $0.formatted(ShelfLabels.finishedFormat)) },
            book.isReading == true ? ("Status", "Reading now") : nil,
            book.pages.map { ("Pages", $0.formatted()) },
            ShelfLabels.format(book.format).map { ("Format", $0) },
        ]
        .compactMap(\.self)
        if !rows.isEmpty {
            Card {
                ForEach(rows, id: \.0) { row in
                    LabeledContent(row.0, value: row.1)
                    if row.0 != rows.last?.0 { Divider() }
                }
            }
        }
    }

    private func designCard(look: SpineLook, design: SpineDesignV1?) -> some View {
        Card {
            Text("Spine design").font(.headline)
            SpineView(book: book, look: look)
                .frame(height: book.slabThickness)
                .accessibilityHidden(true)
            if let design {
                LabeledContent("Font") {
                    Text(design.fontFamily ?? design.typeface.capitalized)
                        .font(look.font(size: 19))
                }
                Divider()
                HStack(alignment: .top) {
                    Swatch(name: "Background", hex: design.backgroundHex, color: look.background)
                    Swatch(name: "Text", hex: design.foregroundHex, color: look.foreground)
                    Swatch(name: "Accent", hex: design.accentHex, color: look.accent)
                }
                Divider()
            }
            Label(
                ShelfLabels.provenance(of: design),
                systemImage: design == nil ? "circle.dashed" : "sparkles"
            )
            .font(.subheadline)
            if let design {
                Text("Created \(design.generatedAt, format: .dateTime.year().month().day())")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("The spine shows a placeholder cloth until it is designed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    #if DEBUG
        /// Simulator screenshot hook: `-BookwormsBookYaw <radians>` and
        /// `-BookwormsBookPitch <radians>` set the initial pose.
        private func applyDebugPose() {
            let defaults = UserDefaults.standard
            if let yaw = defaults.string(forKey: "BookwormsBookYaw").flatMap(Double.init) {
                pose.yaw = yaw
            }
            if let pitch = defaults.string(forKey: "BookwormsBookPitch").flatMap(Double.init) {
                pose.pitch = pitch
            }
        }
    #endif
}

/// The 3D book's orientation, in radians.
struct BookPose: Equatable {
    var yaw: Double
    var pitch: Double

    /// Three-quarter view with the spine toward the viewer, as `Book3DView` defaults.
    static let resting = BookPose(yaw: 0.45, pitch: -0.12)
    static let pitchRange = -0.4...0.3

    /// The pose after a drag of `translation` from this one. Dragging right turns the spine
    /// toward the viewer; dragging down tips the head toward the viewer.
    func turned(by translation: CGSize) -> BookPose {
        BookPose(
            yaw: yaw + translation.width / 110,
            pitch: min(
                Self.pitchRange.upperBound,
                max(Self.pitchRange.lowerBound, pitch - translation.height / 260)))
    }
}

/// `Book3DView` with an animatable pose, so a released spin coasts and settles smoothly.
private struct TurningBook: View, Animatable {
    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    let height: CGFloat
    var yaw: Double
    var pitch: Double

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(yaw, pitch) }
        set { (yaw, pitch) = (newValue.first, newValue.second) }
    }

    var body: some View {
        Book3DView(book: book, look: look, cover: cover, height: height, yaw: yaw, pitch: pitch)
    }
}

/// A grouped panel on the walnut backdrop.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .foregroundStyle(ShelfPalette.paper)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: .rect(cornerRadius: 22))
    }
}

/// One design color: a swatch, its role, and its hex value.
private struct Swatch: View {
    let name: String
    let hex: String
    let color: ColorValue

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(color.color)
                .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                .frame(width: 40, height: 40)
            Text(name).font(.caption)
            Text(hex).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) color, \(hex)")
    }
}
