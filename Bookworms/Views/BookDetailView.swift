import SwiftUI

/// A book's details: a 3D model to turn with a drag, its reading record, its spine design, and
/// **Change cover**.
///
/// With a `HostedBook`, the details draw no book, backdrop, or **Share** button of their own: a
/// transparent stand-in takes the book's place and turns as it would, the host draws the book
/// there behind the details, such as the Pile's RealityKit book or the shelf's pulled-out book,
/// and the host's bar offers **Share**.
struct BookDetailView: View {
    /// The book as the shelf opened it. The view shows the library's current copy, so a new
    /// cover or design appears at once.
    let opened: CloudBook
    let hostedBook: HostedBook?

    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var cover: UIImage?
    @State private var choosesCover = false
    /// When the reader last changed the cover here.
    @State private var coverChangedAt: Date?
    /// The chosen cover the shown spine design comes from, as far as this screen knows: the
    /// cover when the details opened, then the cover when a new design arrives.
    @State private var designedCover: URL?
    /// Whether the reader picked a spine color since last scrolling, which keeps room below the
    /// **Spine design** card for the color picker's sheet.
    @State private var picksColors = false

    init(book: CloudBook, hostedBook: HostedBook? = nil) {
        opened = book
        self.hostedBook = hostedBook
        _designedCover = State(initialValue: book.chosenCoverURL)
    }

    private var book: CloudBook { model.books.first { $0.id == opened.id } ?? opened }

    var body: some View {
        let book = book
        let look = model.look(for: book)
        let design = model.library?.designs[book.id]
        ScrollView {
            VStack(spacing: 24) {
                TurningBook(book: book, look: look, cover: cover, host: hostedBook)
                header
                Button("Change cover", systemImage: "photo.on.rectangle") { choosesCover = true }
                    .buttonStyle(.bordered)
                if design != nil, book.chosenCoverURL != designedCover {
                    redesignCard
                }
                record
                designCard(look: look, design: design)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        // The color picker's sheet blocks scrolling while it shows, so a scroll means it closed.
        // The room goes once the scroll settles, so its removal does not jerk the reader's drag.
        .onScrollPhaseChange { old, new in
            if new == .idle, old == .interacting || old == .decelerating {
                withAnimation { picksColors = false }
            }
        }
        .background {
            if hostedBook == nil { ShelfPalette.wall.ignoresSafeArea() }
        }
        .toolbar {
            // A host shows its own bar, which outlasts these details as they leave.
            if hostedBook == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") { model.share(book) }
                }
            }
        }
        // A new cover choice changes the first candidate; the old cover shows until it loads.
        .task(id: book.coverCandidates.first) { cover = await model.covers.image(for: book) }
        .onChange(of: design?.generatedAt) { designedCover = book.chosenCoverURL }
        .sheet(isPresented: $choosesCover) {
            // The shelf sets a dark scheme for its walnut backdrop, which the sheet's content
            // inherits; the sheet's own background must match it to keep text readable.
            CoverPickerView(book: book) { coverChangedAt = .now }
                .preferredColorScheme(.dark)
        }
        #if DEBUG
            .onAppear { if CoverPickerDebug.opensPicker { choosesCover = true } }
        #endif
    }

    /// Offers a run that redesigns the spine from the new cover. The ledger rechecks a book
    /// whose chosen cover changed, so the next run includes this book.
    private var redesignCard: some View {
        Card {
            Text("Redesign the spine?").font(.headline)
            Text("The spine was designed from the previous cover.")
                .font(.footnote)
                .foregroundStyle(cardNote)
            if generation.status.isRunning {
                LabeledContent("Designing spines") { ProgressView() }
            } else {
                Button("Redesign spine", systemImage: "wand.and.sparkles") {
                    generation.generateNow()
                }
                .buttonStyle(.bordered)
                // A run since the change left the old design, for example after a quota stop or
                // when the new cover did not load.
                if let lastRunAt = generation.status.lastRunAt, let coverChangedAt,
                    lastRunAt > coverChangedAt
                {
                    Label(
                        generation.status.error ?? "The last run did not redesign this spine.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(cardNote)
                }
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
            ShelfLabels.length(of: book).map { ("Length", $0) },
            ShelfLabels.format(book.format).map { ("Format", $0) },
        ]
        .compactMap(\.self)
        if !rows.isEmpty {
            Card {
                ForEach(rows, id: \.0) { row in
                    // Side by side at accessibility sizes, the label and value break mid-word.
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0).foregroundStyle(.secondary)
                            Text(row.1)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        LabeledContent(row.0, value: row.1)
                    }
                    if row.0 != rows.last?.0 { Divider() }
                }
            }
        }
    }

    private func designCard(look: SpineLook, design: SpineDesignV1?) -> some View {
        SpineDesignCard(book: book, look: look, design: design, isPicking: $picksColors)
    }
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

/// Where a host behind `BookDetailView` draws the details' book, and how it turns.
struct HostedBook {
    /// Receives the frame of the book's height, `TurningBook.bookHeight` points tall and
    /// centered where the details center their book, in global coordinates, whenever it moves.
    let place: (CGRect) -> Void
    /// Receives the pose the details' book would show, whenever it changes.
    let turn: (BookPose) -> Void
}

/// A `Book3DView` to turn with a drag. Yaw is unbounded and pitch stays within a gentle tilt.
/// On release the book coasts with the swipe's momentum and its tilt eases back to rest, unless
/// Reduce Motion is on, when it stays where the finger left it. With a `host`, the book is a
/// transparent stand-in that reports its frame and pose for the host to draw.
///
/// The coast is a function of time that `TimelineView` samples, rather than a SwiftUI
/// animation, so a drag that interrupts it starts from the pose on screen. The drag claims
/// touches that start on the book, so the page scrolls from the text below.
private struct TurningBook: View {
    static let bookHeight: CGFloat = 380

    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    let host: HostedBook?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pose under the finger, or the pose a coast comes to rest at.
    @State private var pose = BookPose.resting
    /// The coast in progress, if any.
    @State private var coast: Coast?
    /// The pose on screen when the current drag began. SwiftUI resets it when a drag ends or
    /// is cancelled, so the next drag starts from the current pose.
    @GestureState private var dragStart: BookPose?

    var body: some View {
        TimelineView(.animation(paused: coast == nil)) { context in
            let shown = coast?.pose(at: context.date) ?? pose
            if let host {
                Color.clear
                    .frame(height: Self.bookHeight)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        host.place($0)
                    }
                    .onChange(of: shown, initial: true) { host.turn(shown) }
                    .accessibilityElement()
                    .accessibilityLabel("\(book.title), by \(book.author)")
            } else {
                Book3DView(
                    book: book, look: look, cover: cover, height: Self.bookHeight,
                    yaw: shown.yaw, pitch: shown.pitch)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 460)
        .background {
            // Larger than the stage so the glow's falloff never meets an edge. A host's book
            // lies behind the details, where the glow would veil it.
            if host == nil {
                RadialGradient(
                    colors: [ShelfPalette.lamp.opacity(0.22), .clear], center: .center,
                    startRadius: 0, endRadius: 280
                )
                .frame(width: 640, height: 640)
                .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .gesture(spin)
        // Pauses the timeline once the coast settles.
        .task(id: coast) {
            guard coast != nil else { return }
            try? await Task.sleep(for: .seconds(Coast.spring.settlingDuration))
            if !Task.isCancelled { coast = nil }
        }
        .accessibilityHint("Swipe up or down to turn the book.")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? Double.pi / 4 : -Double.pi / 4
            let target = BookPose(yaw: pose.yaw + step, pitch: pose.pitch)
            if reduceMotion { pose = target } else { settle(at: target) }
        }
        #if DEBUG
            .onAppear(perform: applyDebugPose)
        #endif
    }

    private var spin: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dragStart) { _, start, _ in
                if start == nil { start = coast?.pose(at: .now) ?? pose }
            }
            .onChanged { value in
                guard let dragStart else { return }
                coast = nil
                pose = dragStart.turned(by: value.translation)
            }
            .onEnded { value in
                guard !reduceMotion else { return }
                let momentum = CGSize(
                    width: value.predictedEndTranslation.width - value.translation.width,
                    height: value.predictedEndTranslation.height - value.translation.height)
                let yaw = pose.turned(by: momentum).yaw
                settle(at: BookPose(yaw: yaw, pitch: BookPose.resting.pitch))
            }
    }

    /// Springs from the pose on screen to `target`.
    private func settle(at target: BookPose) {
        coast = Coast(from: coast?.pose(at: .now) ?? pose, to: target, start: .now)
        pose = target
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

/// A spring from one pose to another, sampled by time.
struct Coast: Equatable {
    static let spring = Spring(duration: 1.1, bounce: 0.12)

    let from: BookPose
    let to: BookPose
    let start: Date

    func pose(at date: Date) -> BookPose {
        let progress = Self.spring.value(target: 1.0, time: date.timeIntervalSince(start))
        return BookPose(
            yaw: from.yaw + (to.yaw - from.yaw) * progress,
            pitch: from.pitch + (to.pitch - from.pitch) * progress)
    }
}

/// Small secondary text on a `Card`. The `.secondary` style reaches only about 4.1:1 on the
/// card fill, below the 4.5:1 that footnote and caption text need.
private let cardNote = ShelfPalette.paper.opacity(0.7)

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

/// The **Spine design** card: the spine, the design's font, and its colors, which the reader can
/// change.
///
/// Each color opens the system color picker. The card's spine shows picked colors at once. The
/// rest of the app shows them, and the library's store saves them, one second after the last
/// change or when the card leaves (`AppModel.recolor(_:to:)`), so dragging in the picker
/// neither redraws 3D textures nor writes to iCloud for each frame. Colors whose text and
/// background contrast less than 4.5:1 show only here, with a note, and are never saved.
///
/// The picker's sheet covers the lower part of the screen, so once the reader picks a color,
/// the card adds room below itself and scrolls its spine and contrast note to the top, above
/// the sheet. The room stays until the details scroll again. The picker's opening tap goes to a
/// UIKit color well that reports nothing to SwiftUI, and its closing reports nothing either.
private struct SpineDesignCard: View {
    let book: CloudBook
    /// The look of the saved design, as the rest of the app shows it.
    let look: SpineLook
    let design: SpineDesignV1?

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Picked colors that the library does not show yet, or that it shows but failed to save.
    @State private var draft: SpineColors?
    @State private var saveError: String?
    /// Set when the reader picks a color; the details clear it when they scroll.
    @Binding var isPicking: Bool

    private static let previewID = "spine-preview"

    private var saved: SpineColors {
        SpineColors(background: look.background, foreground: look.foreground, accent: look.accent)
    }

    var body: some View {
        let shown = draft ?? saved
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                card(shown: shown)
                if isPicking {
                    Color.clear.containerRelativeFrame(.vertical) { height, _ in height * 0.6 }
                }
            }
            .onChange(of: isPicking) {
                guard isPicking else { return }
                withAnimation { proxy.scrollTo(Self.previewID, anchor: .top) }
            }
        }
        .task(id: draft) {
            guard let draft else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { await save(draft) }
        }
        .onDisappear {
            // The card cannot report a failure once it is gone; the colors stay on screen until
            // the next reload.
            guard let draft, draft.isReadable else { return }
            Task { [model, book] in try? await model.recolor(book, to: draft) }
        }
        // A new design, such as a redesign from a new cover, replaces the colors being picked.
        .onChange(of: design?.generatedAt) { draft = nil }
        #if DEBUG
            .onAppear(perform: applyDebugColors)
        #endif
    }

    private func card(shown: SpineColors) -> some View {
        Card {
            Text("Spine design").font(.headline)
            SpineView(book: book, look: look(with: shown))
                .frame(height: book.slabThickness)
                .accessibilityHidden(true)
                .id(Self.previewID)
            if let design {
                // Under the spine, so the note shows above the picker's sheet.
                if !shown.isReadable {
                    note(
                        "The text needs more contrast with the background. Choose a lighter or darker color to save.",
                        systemImage: "exclamationmark.triangle")
                }
                LabeledContent("Font") {
                    Text(design.fontFamily ?? design.typeface.capitalized)
                        .font(look.font(size: 19))
                }
                Divider()
                let swatches =
                    typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top))
                swatches {
                    Swatch(name: "Background", color: color(\.background))
                    Swatch(name: "Text", color: color(\.foreground))
                    Swatch(name: "Accent", color: color(\.accent))
                }
                if shown.isReadable {
                    if let saveError {
                        note(saveError, systemImage: "exclamationmark.icloud")
                    } else {
                        Text("Tap a color to change it.").font(.footnote).foregroundStyle(cardNote)
                    }
                }
                if let generated = design.generatedColors ?? design.colors, shown != generated {
                    Button("Reset colors", systemImage: "arrow.uturn.backward") {
                        draft = generated
                        Task { await save(generated) }
                    }
                    .buttonStyle(.bordered)
                }
                Divider()
            }
            if let design {
                Text("Created \(design.generatedAt, format: .dateTime.year().month().day())")
                    .font(.footnote)
                    .foregroundStyle(cardNote)
            } else {
                Text("The spine shows a placeholder cloth until it is designed.")
                    .font(.footnote)
                    .foregroundStyle(cardNote)
            }
        }
    }

    /// A binding to one of the shown colors, which makes the picked colors the draft.
    private func color(_ role: WritableKeyPath<SpineColors, ColorValue>) -> Binding<ColorValue> {
        Binding {
            (draft ?? saved)[keyPath: role]
        } set: { value in
            var colors = draft ?? saved
            colors[keyPath: role] = value
            draft = colors
            isPicking = true
        }
    }

    private func look(with colors: SpineColors) -> SpineLook {
        var look = look
        look.background = colors.background
        look.foreground = colors.foreground
        look.accent = colors.accent
        return look
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.footnote).foregroundStyle(cardNote)
    }

    /// Shows and saves readable `colors`, then clears the draft unless the reader has picked
    /// other colors since.
    private func save(_ colors: SpineColors) async {
        guard colors.isReadable else { return }
        do {
            try await model.recolor(book, to: colors)
            saveError = nil
            if draft == colors { draft = nil }
        } catch is CancellationError {
            // A newer draft replaced these colors.
        } catch {
            saveError = error.localizedDescription
        }
    }

    #if DEBUG
        @MainActor private static var appliedDebugColors = false

        /// Simulator hook: with `-BookwormsOpenBook <book ID>`,
        /// `-BookwormsSpineColors "RRGGBB,RRGGBB,RRGGBB"` picks those background, text, and accent
        /// colors for that book once per launch, as the color pickers would.
        private func applyDebugColors() {
            let defaults = UserDefaults.standard
            guard !Self.appliedDebugColors, design != nil,
                defaults.string(forKey: "BookwormsOpenBook").flatMap(Int.init) == book.id,
                let hexes = defaults.string(forKey: "BookwormsSpineColors")?.split(separator: ","),
                hexes.count == 3,
                let background = ColorValue(hex: "#\(hexes[0].uppercased())"),
                let foreground = ColorValue(hex: "#\(hexes[1].uppercased())"),
                let accent = ColorValue(hex: "#\(hexes[2].uppercased())")
            else { return }
            Self.appliedDebugColors = true
            draft = SpineColors(background: background, foreground: foreground, accent: accent)
        }
    #endif
}

/// One design color: a swatch that opens the system color picker, its role, and its hex value.
///
/// A column for a row of three; at accessibility sizes, where a column breaks the words, a row
/// with the text beside the swatch.
private struct Swatch: View {
    let name: String
    @Binding var color: ColorValue

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let isRow = typeSize.isAccessibilitySize
        let layout =
            isRow ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 6))
        layout {
            // The swatch covers the system color well and lets touches through to it, so the
            // card keeps its look while the well opens the picker.
            ColorPicker(
                "\(name) color",
                selection: Binding {
                    color.color
                } set: {
                    color = ColorValue($0)
                },
                supportsOpacity: false
            )
            .labelsHidden()
            .accessibilityValue(color.hex)
            .overlay {
                Circle()
                    .fill(color.color)
                    .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    .frame(width: 40, height: 40)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: isRow ? .leading : .center, spacing: isRow ? 2 : 6) {
                Text(name).font(.caption)
                Text(color.hex).font(.caption.monospaced()).foregroundStyle(cardNote)
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: isRow ? nil : .infinity)
    }
}

extension ColorValue {
    /// The sRGB color nearest `color`, which can lie outside sRGB, such as a Display P3 color
    /// from the system color picker.
    fileprivate init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        func byte(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        self.init(red: byte(resolved.red), green: byte(resolved.green), blue: byte(resolved.blue))
    }
}
