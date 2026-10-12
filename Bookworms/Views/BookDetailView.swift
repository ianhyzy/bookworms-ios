import SwiftUI

/// A book's details: a 3D model to turn with a drag and its title, over three tabs that switch
/// only the content below them: **Details** (facts about the book and **Change cover**),
/// **Journal** (the reader's reading dates, progress, and review), and **Spine** (the spine's
/// design and colors).
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
    @State private var tab = DetailTab.details
    /// The scroll view's visible height, which every tab's content fills at least, so switching
    /// to a shorter tab never scrolls the book.
    @State private var viewport: CGFloat = 0

    init(book: CloudBook, hostedBook: HostedBook? = nil) {
        opened = book
        self.hostedBook = hostedBook
        _designedCover = State(initialValue: book.chosenCoverURL)
        #if DEBUG
            // `-BookwormsDetailTab <details|journal|spine>` opens that tab, for Simulator checks.
            let debugTab = UserDefaults.standard.string(forKey: "BookwormsDetailTab")
            if let debugTab, let tab = DetailTab(rawValue: debugTab) {
                _tab = State(initialValue: tab)
            }
        #endif
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
                Picker("Section", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                tabContent(look: look, design: design)
                    .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.containerSize.height
        } action: {
            viewport = $1
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
            // A new cover can call for a new spine, so the **Spine** tab shows its offer.
            CoverPickerView(book: book) {
                coverChangedAt = .now
                if design != nil { tab = .spine }
            }
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

    @ViewBuilder
    private func tabContent(look: SpineLook, design: SpineDesignV1?) -> some View {
        switch tab {
        case .details:
            VStack(spacing: 24) {
                Button("Change cover", systemImage: "photo.on.rectangle") { choosesCover = true }
                    .buttonStyle(.bordered)
                rows(facts)
            }
        case .journal:
            journal
        case .spine:
            VStack(spacing: 24) {
                if design != nil, book.chosenCoverURL != designedCover { redesignCard }
                designCard(look: look, design: design)
            }
        }
    }

    /// Facts about the book itself, as Hardcover records them.
    private var facts: [(String, String)] {
        let genres = (book.genres ?? []).prefix(3).joined(separator: ", ")
        return [
            book.seriesPosition.map { ("Series", "Book \($0.formatted())") },
            book.publicationYear.map { ("Published", String($0)) },
            ShelfLabels.length(of: book).map { ("Length", $0) },
            ShelfLabels.format(book.format).map { ("Format", $0) },
            genres.isEmpty ? nil : ("Genres", genres),
            book.communityRating.flatMap { rating in
                guard rating > 0, let count = book.ratingsCount, count > 0 else { return nil }
                let average = rating.formatted(.number.precision(.fractionLength(1)))
                return ("Readers' rating", "\(average) from \(count.formatted()) ratings")
            },
        ]
        .compactMap(\.self)
    }

    /// The reader's own record of the book: when they read it, how far they are, and their
    /// review, all from their reading service.
    @ViewBuilder private var journal: some View {
        let started = book.startedDate
        let finished = book.finishedDate
        let progress = book.isReading == true ? book.progress : nil
        let entries: [(String, String)] = [
            book.isReading == true
                ? (
                    "Status",
                    progress.map {
                        "Reading now, \($0.formatted(.percent.precision(.fractionLength(0))))"
                    } ?? "Reading now"
                )
                : nil,
            started.map { ("Started", $0.formatted(ShelfLabels.finishedFormat)) },
            finished.map { ("Finished", $0.formatted(ShelfLabels.finishedFormat)) },
            ShelfLabels.readingTime(from: started, to: finished).map { ("Reading time", $0) },
        ]
        .compactMap(\.self)
        let review = book.review?.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 24) {
            rows(entries)
            if let review, !review.isEmpty {
                Card {
                    Text("Your review").font(.headline)
                    Text(review)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } else {
                Text(
                    entries.isEmpty
                        ? "Your reading dates and review from Hardcover appear here."
                        : "A review you write on Hardcover appears here."
                )
                .font(.footnote)
                .foregroundStyle(cardNote)
                .multilineTextAlignment(.center)
            }
        }
    }

    /// Labeled values on a card, or nothing without any.
    @ViewBuilder private func rows(_ rows: [(String, String)]) -> some View {
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
        SpineDesignCard(book: book, look: look, design: design)
    }
}

/// The parts of a book's details that the tabs under its title switch between.
enum DetailTab: String, CaseIterable, Identifiable {
    case details
    case journal
    case spine

    var id: Self { self }
    var title: String { rawValue.capitalized }
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
    /// centered where the details center their book, in global coordinates, whenever it moves,
    /// including as it drifts.
    let place: (CGRect) -> Void
    /// Receives the pose the details' book would show, drift included, whenever it changes.
    let turn: (BookPose) -> Void
    /// Whether the host's book has landed in the details, which starts its drift. The drift
    /// then runs until the details leave, so a return starts from the drifted frame and pose.
    let hasLanded: Bool
}

/// A `Book3DView` to turn with a drag. Yaw is unbounded and pitch stays within a gentle tilt.
/// On release the book coasts with the swipe's momentum and its tilt eases back to rest, unless
/// Reduce Motion is on, when it stays where the finger left it. Once the book arrives, it floats
/// gently (see `Drift`), unless Reduce Motion is on. With a `host`, the book is a transparent
/// stand-in that reports its frame and pose for the host to draw.
///
/// The coast and the drift are functions of time that `TimelineView` samples, rather than
/// SwiftUI animations, so a drag that interrupts a coast starts from the pose on screen. The
/// drift adds to the dragged or coasting pose, so a drag neither stops nor restarts it. The
/// timeline renders the drift alone at most 30 times a second, enough for its slow motion,
/// and pauses while the book's stage is scrolled out of view. The drag claims touches that
/// start on the book, so the page scrolls from the text below.
private struct TurningBook: View {
    nonisolated static let bookHeight: CGFloat = 380

    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    let host: HostedBook?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pose under the finger, or the pose a coast comes to rest at.
    @State private var pose = BookPose.resting
    /// The coast in progress, if any.
    @State private var coast: Coast?
    /// The idle float, from the moment the book arrives in its details, or `nil` with Reduce
    /// Motion on.
    @State private var drift: Drift?
    /// Whether some of the book's stage shows in the details' scroll view.
    @State private var isOnScreen = true
    /// When the stage last scrolled out of view, while it stays out.
    @State private var hiddenSince: Date?
    /// The pose on screen when the current drag began. SwiftUI resets it when a drag ends or
    /// is cancelled, so the next drag starts from the current pose.
    @GestureState private var dragStart: BookPose?

    var body: some View {
        let drifts = drift != nil && isOnScreen
        TimelineView(
            .animation(
                minimumInterval: coast == nil ? 1.0 / 30 : nil, paused: coast == nil && !drifts)
        ) { context in
            let turned = coast?.pose(at: context.date) ?? pose
            let float = drift?.offset(at: context.date)
            let shown = BookPose(yaw: turned.yaw + (float?.yaw ?? 0), pitch: turned.pitch)
            let shift = float?.translation ?? .zero
            if let host {
                Color.clear
                    .frame(height: Self.bookHeight)
                    // Inside the offset, so the reported frame drifts with it.
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        host.place($0)
                    }
                    .offset(shift)
                    .onChange(of: shown, initial: true) { host.turn(shown) }
                    .accessibilityElement()
                    .accessibilityLabel("\(book.title), by \(book.author)")
            } else {
                Book3DView(
                    book: book, look: look, cover: cover, height: Self.bookHeight,
                    yaw: shown.yaw, pitch: shown.pitch
                )
                .offset(shift)
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
        // The pushed details' book arrives as they appear, and a host's book once it lands.
        .onChange(of: host?.hasLanded ?? true, initial: true) { _, arrived in
            if arrived, drift == nil, !reduceMotion { drift = Drift(start: .now) }
        }
        // Reduce Motion stops the drift at once, and turning it off eases the drift in again.
        .onChange(of: reduceMotion) { _, reduced in
            drift = reduced || host?.hasLanded == false ? nil : Drift(start: .now)
        }
        // The drift pauses while the stage is out of view and resumes where it paused, so it
        // never jumps, whatever part of the stage counts as visible.
        .onScrollVisibilityChange(threshold: 0.01) { visibilityChanged($0) }
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

    /// Pauses the drift while the stage is out of view, and resumes it where it paused.
    private func visibilityChanged(_ visible: Bool) {
        isOnScreen = visible
        if !visible {
            hiddenSince = .now
        } else if let hiddenSince, let current = drift {
            drift = Drift(
                start: current.start.addingTimeInterval(Date.now.timeIntervalSince(hiddenSince)))
            self.hiddenSince = nil
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

/// The details' book's idle float, as the Apple TV's Book Wall floats a book in its details.
///
/// Three independent sine waves move the book up and down over 40 seconds, from side to side
/// over 48 seconds, and sway its yaw 2 degrees each way over 60 seconds, rising first. A
/// smootherstep ramp eases them in over their first 4 seconds, so the offset and its velocity
/// both start at zero and the book leaves the pose it arrived in without a jump.
///
/// The Book Wall drifts its detail book, roughly 600 points tall on the TV's 1080-point screen,
/// 24 points vertically and 6 horizontally: about 4 and 1 percent of its height. The phone keeps
/// those shares of its own book's height, about 15 and 4 points, so the book floats as far for
/// its size.
struct Drift: Equatable {
    static let verticalAmplitude = 0.04 * TurningBook.bookHeight
    static let horizontalAmplitude = 0.01 * TurningBook.bookHeight
    static let swayAmplitude = Double.pi / 90
    static let rampDuration = 4.0

    /// When the book arrived in its details.
    let start: Date

    /// The book's displacement at `date`: `translation` in points, with y down, and `yaw` in
    /// radians to add to its pose.
    func offset(at date: Date) -> (translation: CGSize, yaw: Double) {
        let time = max(0, date.timeIntervalSince(start))
        let ramp = min(1, time / Self.rampDuration)
        let eased = ramp * ramp * ramp * (ramp * (ramp * 6 - 15) + 10)
        func wave(_ amplitude: Double, period: Double) -> Double {
            amplitude * sin(2 * .pi * time / period) * eased
        }
        return (
            CGSize(
                width: wave(Self.horizontalAmplitude, period: 48),
                height: -wave(Self.verticalAmplitude, period: 40)),
            wave(Self.swayAmplitude, period: 60)
        )
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
/// The picker's sheet covers the lower half of the screen. While it shows, the card adds room
/// below itself and scrolls its top to the top of the details, so the spine, the contrast note,
/// and the swatches stay above the sheet.
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
    /// The color whose picker shows.
    @State private var picking: ColorRole?

    private static let cardID = "spine-design-card"

    private var saved: SpineColors {
        SpineColors(background: look.background, foreground: look.foreground, accent: look.accent)
    }

    var body: some View {
        let shown = draft ?? saved
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                card(shown: shown).id(Self.cardID)
                if picking != nil {
                    Color.clear.containerRelativeFrame(.vertical)
                }
            }
            .animation(.smooth, value: picking == nil)
            .onChange(of: picking == nil) {
                guard picking != nil else { return }
                withAnimation(.smooth) { proxy.scrollTo(Self.cardID, anchor: .top) }
            }
        }
        .sheet(item: $picking) { role in
            SystemColorPicker(
                title: "\(role.name) color", initial: shown[keyPath: role.keyPath]
            ) { color in
                var colors = draft ?? saved
                colors[keyPath: role.keyPath] = color
                draft = colors
            } finish: {
                picking = nil
            }
            .presentationDetents([.medium])
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
                    ForEach(ColorRole.allCases) { role in
                        Swatch(role: role, color: shown[keyPath: role.keyPath]) { picking = role }
                    }
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

/// A spine color the reader can change.
private enum ColorRole: CaseIterable, Identifiable {
    case background, text, accent

    var id: Self { self }

    var name: String {
        switch self {
        case .background: "Background"
        case .text: "Text"
        case .accent: "Accent"
        }
    }

    var keyPath: WritableKeyPath<SpineColors, ColorValue> {
        switch self {
        case .background: \.background
        case .text: \.foreground
        case .accent: \.accent
        }
    }
}

/// One design color: a button with its swatch, its role, and its hex value, which opens the
/// color picker.
///
/// A column for a row of three; at accessibility sizes, where a column breaks the words, a row
/// with the text beside the swatch.
private struct Swatch: View {
    let role: ColorRole
    let color: ColorValue
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let isRow = typeSize.isAccessibilitySize
        let layout =
            isRow ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 6))
        Button(action: action) {
            layout {
                Circle()
                    .fill(color.color)
                    .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    .frame(width: 40, height: 40)
                VStack(alignment: isRow ? .leading : .center, spacing: isRow ? 2 : 6) {
                    Text(role.name).font(.caption)
                    Text(color.hex).font(.caption.monospaced()).foregroundStyle(cardNote)
                }
            }
            .frame(maxWidth: isRow ? nil : .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(role.name) color")
        .accessibilityValue(color.hex)
    }
}

/// The system color picker, without opacity, reporting each pick and the picker's close.
///
/// SwiftUI's `ColorPicker` opens the same picker but reports neither its opening nor its close,
/// which the **Spine design** card needs to move above the picker's sheet and back. The card
/// presents this picker in its own sheet instead.
private struct SystemColorPicker: UIViewControllerRepresentable {
    let title: String
    let initial: ColorValue
    let pick: (ColorValue) -> Void
    let finish: () -> Void

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.title = title
        picker.supportsAlpha = false
        picker.selectedColor = initial.uiColor
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: SystemColorPicker

        init(parent: SystemColorPicker) { self.parent = parent }

        func colorPickerViewController(
            _ picker: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool
        ) {
            parent.pick(ColorValue(Color(uiColor: color)))
        }

        func colorPickerViewControllerDidFinish(_ picker: UIColorPickerViewController) {
            parent.finish()
        }
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
