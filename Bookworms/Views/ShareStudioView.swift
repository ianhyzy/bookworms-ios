import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Share tab: choose a template and its options, preview the exact export, and share it.
///
/// Each option change renders the image again after a short pause and cancels a render still in
/// progress; a new design for a drawn book renders after it instead. Covers and spine fonts
/// load before each render, because `ImageRenderer` draws synchronously and would capture
/// anything still loading as a placeholder. The Pile template renders with
/// `PileSnapshotRenderer`, which loads its own covers and fonts.
///
/// Without a library, the tab shows `NoLibraryView` instead, which can open the Hardcover sheet.
struct ShareStudioView: View {
    @Environment(AppModel.self) private var model
    @State private var template = ShareTemplate.yearStack
    @State private var aspect = ShareAspect.story
    /// The chosen time frame: `nil`, or a frame without finished books, is the newest year.
    @State private var frame: TimeFrame?
    /// The featured book of a single-book template: `nil` is its newest choice.
    @State private var bookID: Int?
    @State private var coverStyle = ShareCoverStyle.threeD
    @State private var direction = HotTakeDirection.lovedMore
    @State private var showsRatings = true
    @State private var seed: UInt64 = 0
    /// The years and months with finished books, kept with the library so the body need not
    /// recompute them.
    @State private var periods: (years: [Int], months: [TimeFrame]) = ([], [])
    @State private var image: ShareImage?
    /// The request that drew `image`. While it differs from the current request, a newer image
    /// is on its way, so the preview shows progress and sharing waits.
    @State private var renderedRequest: RenderRequest?
    /// Whether the last render failed, so no image is shown or shared.
    @State private var failed = false
    @State private var showsAccount = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init() {
        #if DEBUG
            let defaults = UserDefaults.standard
            guard let raw = defaults.string(forKey: "BookwormsShareTemplate") else { return }
            _template = State(initialValue: ShareTemplate(rawValue: raw) ?? .yearStack)
            _aspect = State(
                initialValue: defaults.string(forKey: "BookwormsShareAspect")
                    .flatMap(ShareAspect.init(rawValue:)) ?? .story)
            _frame = State(
                initialValue: ShareDebug.frame(defaults.string(forKey: "BookwormsShareFrame")))
            _bookID = State(
                initialValue: defaults.string(forKey: "BookwormsShareBook").flatMap { Int($0) })
            _coverStyle = State(
                initialValue: defaults.string(forKey: "BookwormsShareCover")
                    .flatMap(ShareCoverStyle.init(rawValue:)) ?? .threeD)
            _direction = State(
                initialValue: defaults.string(forKey: "BookwormsShareDirection")
                    .flatMap(HotTakeDirection.init(rawValue:)) ?? .lovedMore)
            _seed = State(
                initialValue: defaults.string(forKey: "BookwormsShareSeed").flatMap { UInt64($0) }
                    ?? 0)
        #endif
    }

    /// The books the studio draws from. Debug builds can add fictional reviews and current reads
    /// for screenshots (`ShareDebug.samples`).
    private var library: [CloudBook] {
        #if DEBUG
            ShareDebug.samples(model.books)
        #else
            model.books
        #endif
    }

    /// The frame the image uses: the chosen one while it still has books, else the newest year.
    private var shownFrame: TimeFrame {
        if let frame,
            frame == .lifetime || periods.months.contains(frame)
                || periods.years.contains(where: { .year($0) == frame })
        {
            return frame
        }
        return periods.years.first.map { .year($0) } ?? .lifetime
    }

    /// The image the current options and library call for.
    private var request: RenderRequest {
        let frame = shownFrame
        let bookID = template.isSingleBook ? bookID : nil
        var books = template.books(from: library, in: frame, bookID: bookID, direction: direction)
        if template == .pile { books = Array(books.prefix(PileSnapshotRenderer.maximumBooks)) }
        // Only the drawn books' designs, so a design saved for another book changes nothing.
        let designs = books.map { model.library?.designs[$0.id] }
        // Spine Spectrum draws no lettering, and the pile renderer waits for its own fonts, so a
        // newly loaded face changes neither; restarting a pile would only delay it. Other
        // templates re-render only when a face for one of their own books arrives.
        let loadedFaces =
            template == .spectrum || template == .pile
            ? 0 : designs.count { model.fonts.face(for: $0) != nil }
        return RenderRequest(
            template: template, aspect: aspect, frame: frame, bookID: bookID,
            coverStyle: coverStyle, direction: direction, showsRatings: showsRatings, seed: seed,
            syncedAt: model.library?.syncedAt, covers: books.map(\.coverCandidates.first),
            designs: designs, loadedFaces: loadedFaces)
    }

    var body: some View {
        let request = request
        // A newer design alone keeps the image shareable while the render loop draws it.
        let isPending = renderedRequest?.options != request.options
        NavigationStack {
            if model.library == nil {
                NoLibraryView(showsAccount: $showsAccount)
                    .navigationTitle("Share")
            } else {
                // The request lists one cover candidate per drawn book, so it shows emptiness
                // at once, before the debounced render catches up.
                form(isPending: isPending, hasNoBooks: request.covers.isEmpty)
            }
        }
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        .task(id: request.options) {
            // A saved design draws after the image in progress instead of restarting it.
            for await _ in Observations({ [model] in model.library?.designs }) { await render() }
        }
        .onChange(of: model.books, initial: true) { _, books in
            periods = TimeFrame.periods(in: books)
        }
        .onChange(of: model.shareBookID, initial: true) { _, id in
            guard let id else { return }
            model.shareBookID = nil
            let book = library.first { $0.id == id }
            if book?.isReading == true && book?.finishedDate == nil {
                template = .currentlyReading
            } else {
                template = .justFinished
                if let year = book?.finishedYear { frame = .year(year) }
            }
            bookID = id
        }
        #if DEBUG
            .task(id: periods.years) { await renderBatch() }
            .onAppear { ShareDebug.switchTabs(model) }
        #endif
    }

    private func form(isPending: Bool, hasNoBooks: Bool) -> some View {
        Form {
            Section {
                preview(isPending: isPending, hasNoBooks: hasNoBooks)
                Picker("Size", selection: $aspect) {
                    ForEach(ShareAspect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section("Template") {
                if dynamicTypeSize >= .xLarge {
                    // Names in a grid truncate above the default text size.
                    Picker("Template", selection: $template) {
                        ForEach(ShareTemplate.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } else {
                    templateGrid
                }
            }
            if template.usesTimeFrame && !periods.years.isEmpty {
                Section("Time frame") { frameControls }
            }
            if template.isSingleBook {
                Section("Book") { bookRow }
            }
            // Year in Books draws covers only for its records, which Square leaves out.
            if template.hasCoverStyle && !(template == .yearInBooks && aspect == .square) {
                Section {
                    Picker("Cover style", selection: $coverStyle) {
                        ForEach(ShareCoverStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Cover")
                } footer: {
                    if template == .yearInBooks {
                        Text("Applies to the records, which appear when they fit.")
                    }
                }
            }
            if template == .hotTakes || template.hasRatingOption || showsShuffle {
                Section("Options") { options }
            }
        }
        .navigationTitle("Share")
        .toolbar {
            if let image {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: image,
                        preview: SharePreview(image.name, image: Image(uiImage: image.image))
                    )
                    .disabled(isPending)
                }
            }
        }
    }

    #if DEBUG
        /// Renders each entry of `-BookwormsShareBatch`, such as
        /// `yearInBooks,story,month:2025-08,flat`, separated by spaces, and saves it as
        /// `share-debug-<entry>.png`, so one launch checks many options.
        private func renderBatch() async {
            guard
                let batch = UserDefaults.standard.string(forKey: "BookwormsShareBatch"),
                !periods.years.isEmpty
            else { return }
            for entry in batch.split(separator: " ") {
                let parts = entry.split(separator: ",").map(String.init) + ["", "", "", ""]
                template = ShareTemplate(rawValue: parts[0]) ?? template
                aspect = ShareAspect(rawValue: parts[1]) ?? aspect
                frame = ShareDebug.frame(parts[2])
                coverStyle = ShareCoverStyle(rawValue: parts[3]) ?? .threeD
                // Waits until the image matches the options and font loads have settled.
                var settled = 0
                while settled < 5, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    settled = renderedRequest == request ? settled + 1 : 0
                }
                if let image {
                    ShareDebug.write(image.image, name: "-" + entry.replacing(":", with: "_"))
                }
            }
        }
    #endif

    @ViewBuilder
    private func preview(isPending: Bool, hasNoBooks: Bool) -> some View {
        let size = aspect.size
        // Messages sit outside the image's box, which would clip them at large text sizes.
        if image == nil && hasNoBooks && !model.isLoading {
            let empty = emptyState
            ContentUnavailableView {
                Label(empty.title, systemImage: template.systemImage)
            } description: {
                Text(empty.message)
            } actions: {
                // The Apple TV's library has no reviews; the iPhone's Hardcover sign-in adds them.
                if template == .review && !usesHardcover && !model.isPreview {
                    Button("Connect Hardcover") { showsAccount = true }
                        .buttonStyle(.bordered)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if image == nil && failed && !isPending {
            ContentUnavailableView(
                "Couldn't draw the image", systemImage: "exclamationmark.triangle",
                // A pile's drop varies with the seed, so Shuffle can succeed where it failed.
                description: Text(
                    template == .pile
                        ? "Try Shuffle or another size." : "Try another size or template.")
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ZStack {
                // Sizes the box as the image does, before there is one.
                Color.clear.frame(idealWidth: size.width, idealHeight: size.height)
                if let image {
                    Image(uiImage: image.image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("\(image.name) preview")
                }
                if template == .pile && isPending {
                    // A pile takes seconds to drop and settle.
                    ProgressView("Dropping books")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                } else if image == nil {
                    ProgressView()
                } else if isPending {
                    ProgressView()
                        .padding(12)
                        .background(.regularMaterial, in: .circle)
                        .accessibilityLabel("Updating preview")
                }
            }
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: 380)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// Whether this iPhone's Hardcover sign-in provides the library, which preview mode ignores.
    private var usesHardcover: Bool { model.account.isSignedIn && !model.isPreview }

    /// Why the template has nothing to draw, and what would give it something.
    private var emptyState: (title: String, message: String) {
        let frame = shownFrame
        let suffix = frame == .lifetime ? "" : " in \(frame.title)"
        let nextSync =
            usesHardcover ? "after the next sync with Hardcover" : "after the Apple TV syncs"
        switch template {
        case .review where !library.contains { $0.reviewText != nil }:
            return (
                "No reviews yet",
                usesHardcover
                    ? "Reviews you write on Hardcover appear here \(nextSync)."
                    : "The Apple TV's library has no reviews. Connect Hardcover on this iPhone to share yours."
            )
        case .review:
            return ("No reviews\(suffix)", "Choose another time frame to share a review.")
        case .currentlyReading:
            return ("Not reading anything", "Books you're reading appear here \(nextSync).")
        case .hotTakes:
            let other: HotTakeDirection = direction == .lovedMore ? .lovedLess : .lovedMore
            if !ShareTemplate.hotTakes.books(from: library, in: frame, direction: other).isEmpty {
                return (
                    "No hot takes\(suffix)",
                    "Choose \(other.title) to see this frame's other takes."
                )
            }
            if frame != .lifetime,
                !ShareTemplate.hotTakes.books(from: library, in: .lifetime, direction: direction)
                    .isEmpty
            {
                return ("No hot takes\(suffix)", "Choose another time frame or Lifetime.")
            }
            let side = direction == .lovedMore ? "above" : "below"
            return (
                "No hot takes\(suffix)",
                "Rate a book at least half a star \(side) its Hardcover average. Only books with "
                    + "\(HotTakeDirection.minimumRatings) or more ratings count."
            )
        default:
            return periods.years.isEmpty
                ? ("No finished books", "Books you finish appear here \(nextSync).")
                : ("No finished books\(suffix)", "Choose another time frame.")
        }
    }

    private var templateGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6
        ) {
            ForEach(ShareTemplate.allCases) { option in
                let isSelected = option == template
                Button {
                    template = option
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.systemImage)
                            .font(.title3)
                            .frame(height: 28)
                            // VoiceOver reads the template's name alone.
                            .accessibilityHidden(true)
                        Text(option.title)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .background(
                        isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 10)
                    )
                    .contentShape(.rect)
                }
                // A plain style keeps each button's tap separate inside one form row.
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: - Time frame

    private enum FrameKind: CaseIterable, Identifiable {
        case year, month, lifetime

        var id: Self { self }

        var title: String {
            switch self {
            case .year: "Year"
            case .month: "Month"
            case .lifetime: "Lifetime"
            }
        }
    }

    @ViewBuilder
    private var frameControls: some View {
        let shown = shownFrame
        Picker("Time frame", selection: kind) {
            ForEach(FrameKind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        let selection = Binding {
            shownFrame
        } set: {
            choose($0)
        }
        switch shown {
        case .year:
            Picker("Year", selection: selection) {
                ForEach(periods.years, id: \.self) { Text(String($0)).tag(TimeFrame.year($0)) }
            }
        case .month:
            Picker("Month", selection: selection) {
                ForEach(periods.months, id: \.self) { Text($0.title).tag($0) }
            }
        case .lifetime:
            EmptyView()
        }
    }

    /// Switches between a year, a month, and a lifetime, staying near the shown period: a
    /// year's newest month, or a month's year.
    private var kind: Binding<FrameKind> {
        Binding {
            switch shownFrame {
            case .year: .year
            case .month: .month
            case .lifetime: .lifetime
            }
        } set: { kind in
            let year: Int? =
                switch shownFrame {
                case .year(let year), .month(let year, _): year
                case .lifetime: nil
                }
            switch kind {
            case .year:
                choose(.year(year ?? periods.years.first ?? 0))
            case .month:
                let inYear = periods.months.first { month in
                    if case .month(let monthYear, _) = month { monthYear == year } else { false }
                }
                choose(inYear ?? periods.months.first)
            case .lifetime:
                choose(.lifetime)
            }
        }
    }

    /// Shows `frame` and drops a chosen book, which may not be in it.
    private func choose(_ frame: TimeFrame?) {
        self.frame = frame
        bookID = nil
    }

    // MARK: - Book and options

    /// The featured book, which opens a list of the template's choices.
    private var bookRow: some View {
        let choices = template.choices(from: library, in: shownFrame)
        // The same choice the render makes, so the row names the book the image shows.
        let shown = template.books(from: library, in: shownFrame, bookID: bookID).first
        return NavigationLink {
            ShareBookPicker(books: choices, current: shown?.id, selection: $bookID)
        } label: {
            LabeledContent("Book", value: shown?.spineTitle ?? "None")
        }
        .disabled(choices.isEmpty)
    }

    @ViewBuilder
    private var options: some View {
        if template == .hotTakes {
            Picker("Show", selection: $direction) {
                ForEach(HotTakeDirection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        if template.hasRatingOption {
            Toggle("Show ratings", isOn: $showsRatings)
        }
        if showsShuffle {
            Button("Shuffle", systemImage: "shuffle") { seed = .random(in: 1 ... .max) }
        }
    }

    /// Whether the seed changes the image. It varies spine stacks, the Top Five fan, a pile's
    /// drop, and the angle of 3D books; flat single covers and Spine Spectrum ignore it.
    private var showsShuffle: Bool {
        switch template {
        case .yearStack, .yearInBooks, .topFive, .pile: true
        case .spectrum: false
        case .hotTakes, .justFinished, .review, .currentlyReading: coverStyle == .threeD
        }
    }

    // MARK: - Rendering

    /// Renders until the image matches the latest request.
    ///
    /// SwiftUI skips a `task(id:)` restart when the ID changes more than once in a frame, as it
    /// does while cached fonts load in a burst. Each pass therefore reads the latest request,
    /// and the loop checks it again after drawing.
    private func render() async {
        // A short pause folds quick option changes into one render.
        try? await Task.sleep(for: .milliseconds(150))
        while !Task.isCancelled, renderedRequest != request {
            await render(request)
        }
    }

    /// Draws one request, unless the task is cancelled first. Sets `renderedRequest` otherwise.
    private func render(_ request: RenderRequest) async {
        let template = request.template
        let books = template.books(
            from: library, in: request.frame, bookID: request.bookID,
            direction: request.direction)
        var input = ShareInput(
            template: template, aspect: request.aspect, books: books, frame: request.frame,
            coverStyle: request.coverStyle, direction: request.direction,
            showsRatings: request.showsRatings, seed: request.seed)
        let rendered: UIImage?
        if books.isEmpty {
            rendered = nil
        } else if template == .pile {
            do {
                let pile = try await PileSnapshotRenderer.render(
                    books: books, title: input.period, aspect: request.aspect,
                    seed: request.seed, model: model)
                // A render cancelled after its last check still returns; a newer one is coming.
                try Task.checkCancellation()
                rendered = pile
            } catch is CancellationError {
                return
            } catch {
                rendered = nil
            }
        } else {
            // The books drawn with covers. Year in Books draws covers only for its records.
            let covered: [CloudBook] =
                switch template {
                case .yearStack, .spectrum, .pile: []
                case .yearInBooks: YearInBooks(frame: request.frame, library: books).records
                default: books
                }
            // Spines carry lettering on Year Stack and on 3D books, so their fonts load first.
            // This waits for every face, including ones another feature is already downloading.
            let lettered =
                template == .yearStack ? books : request.coverStyle == .threeD ? covered : []
            await model.fonts.load(lettered.compactMap { model.library?.designs[$0.id] })
            let coverSize = template.isSingleBook ? 1200 : template == .topFive ? 900 : 700
            input.covers = await loadCovers(covered, maximumPixelSize: coverSize)
            guard !Task.isCancelled else { return }
            input.looks = Dictionary(books.map { ($0.id, model.look(for: $0)) }) { first, _ in
                first
            }
            rendered = input.render()
        }
        // Without a new image, the old one must not stay to be shared.
        image = rendered.map { rendered in
            var name = template.title
            if !template.isSingleBook { name += " " + input.period }
            return ShareImage(image: rendered, name: name)
        }
        failed = !books.isEmpty && rendered == nil
        renderedRequest = request
        #if DEBUG
            if let rendered { ShareDebug.write(rendered) }
        #endif
    }

    private func loadCovers(_ books: [CloudBook], maximumPixelSize: Int) async -> [Int: UIImage] {
        let store = model.covers
        return await withTaskGroup(of: (Int, UIImage?).self) { group in
            for book in books {
                group.addTask {
                    (book.id, await store.image(for: book, maximumPixelSize: maximumPixelSize))
                }
            }
            var covers: [Int: UIImage] = [:]
            for await (id, cover) in group { covers[id] = cover }
            return covers
        }
    }
}

/// The options that change the rendered image, including library and font changes.
private struct RenderRequest: Equatable {
    var template: ShareTemplate
    var aspect: ShareAspect
    var frame: TimeFrame
    var bookID: Int?
    var coverStyle: ShareCoverStyle
    var direction: HotTakeDirection
    var showsRatings: Bool
    var seed: UInt64
    var syncedAt: Date?
    /// The covers the image draws, so choosing another cover redraws it.
    var covers: [URL?]
    /// The designs of the books the image draws, in their order.
    var designs: [SpineDesignV1?]
    var loadedFaces: Int

    /// The request without its designs. The render task restarts only when these change: a
    /// pile takes seconds to drop, and a generation run saves a design every few seconds, so a
    /// new design waits for the image in progress and draws next.
    var options: RenderRequest {
        var options = self
        options.designs = []
        return options
    }
}

/// A rendered share image, which the share sheet receives as PNG data.
struct ShareImage: Transferable {
    let image: UIImage
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let data = item.image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
        .suggestedFileName { $0.name }
    }
}

/// A searchable list of the books a single-book template can feature.
private struct ShareBookPicker: View {
    let books: [CloudBook]
    let current: Int?
    @Binding var selection: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List(filtered) { book in
            Button {
                selection = book.id
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).lineLimit(2)
                        Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if book.id == current {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Selected")
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .searchable(text: $query)
        .navigationTitle("Book")
    }

    private var filtered: [CloudBook] {
        guard !query.isEmpty else { return books }
        return books.filter {
            $0.title.localizedStandardContains(query) || $0.author.localizedStandardContains(query)
        }
    }
}

#if DEBUG
    /// Simulator hooks, since a script cannot tap the Share tab.
    ///
    /// Launching with `-BookwormsShareTemplate <name>` opens the Share tab with that template,
    /// where the name is a `ShareTemplate` raw value such as `yearStack`, `hotTakes`, or `pile`.
    /// `-BookwormsShareAspect <story|portrait|square>`,
    /// `-BookwormsShareFrame <year:2025|month:2025-08|lifetime>`, `-BookwormsShareBook <id>`,
    /// `-BookwormsShareCover <threeD|flat>`, `-BookwormsShareDirection <lovedMore|lovedLess>`,
    /// and `-BookwormsShareSeed <n>` set its options, and `-BookwormsShareSamples <n>` adds
    /// fictional reviews and current reads (`samples(_:)`). Each render is then written to
    /// `Library/Caches/Bookworms/share-debug.png`; `-BookwormsShareBatch` renders a list of
    /// option sets in one launch (`ShareStudioView.renderBatch()`).
    enum ShareDebug {
        static func write(_ image: UIImage, name: String = "") {
            guard UserDefaults.standard.string(forKey: "BookwormsShareTemplate") != nil else {
                return
            }
            let url = URL.cachesDirectory.appending(path: "Bookworms/share-debug\(name).png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? image.pngData()?.write(to: url, options: .atomic)
        }

        @MainActor private static var switchesTabs = false

        /// With `-BookwormsShareTabs "shelf:0 share:8"`, selects each tab once its seconds pass
        /// after the previous entry. It checks the Shelf's pile while the Share tab renders one.
        @MainActor static func switchTabs(_ model: AppModel) {
            guard !switchesTabs,
                let schedule = UserDefaults.standard.string(forKey: "BookwormsShareTabs")
            else { return }
            switchesTabs = true
            // Unstructured, so leaving the Share tab does not cancel it.
            Task {
                for entry in schedule.split(separator: " ") {
                    let parts = entry.split(separator: ":")
                    try? await Task.sleep(for: .seconds(Double(parts.last ?? "") ?? 0))
                    model.selectedTab = parts.first == "shelf" ? .shelf : .share
                }
            }
        }

        /// Parses `year:2025`, `month:2025-08`, or `lifetime`.
        static func frame(_ text: String?) -> TimeFrame? {
            guard let text else { return nil }
            if text == "lifetime" { return .lifetime }
            let parts = text.split(separator: ":")
            let numbers = parts.last?.split(separator: "-").compactMap { Int($0) } ?? []
            switch (parts.first, numbers.count) {
            case ("year", 1): return .year(numbers[0])
            case ("month", 2): return .month(year: numbers[0], month: numbers[1])
            default: return nil
            }
        }

        /// Fictional review text, from a short line to one long enough to need an excerpt.
        private static let reviews = [
            "A quiet book that kept getting louder. By the last chapter I had stopped reading "
                + "for the plot and was reading for the sentences.",
            "Perfect comfort read.",
            "The middle sags and the ending hurries, but the characters carried me. I would "
                + "follow these two through a phone book. The banter alone earns the stars, and "
                + "the final scene on the pier will stay with me for a while.",
            "I expected a thriller and got a meditation on memory, which turned out to be "
                + "better. The structure is the trick: each chapter moves a year back, so you "
                + "learn the ending first and spend the rest of the book discovering why it "
                + "matters. Some chapters work better than others, and a few side characters "
                + "vanish without much reason, but the way the author lets small objects carry "
                + "meaning across decades is remarkable. A watch, a recipe card, a key to a door "
                + "that no longer exists. I finished it in two sittings and then went back to "
                + "read the first chapter again, which now reads like a completely different "
                + "story. I will be recommending this to everyone who will listen, and to a few "
                + "people who won't.",
        ]

        /// With `-BookwormsShareSamples <n>`, gives the newest rated finished books the
        /// fictional reviews, starting with review `n`, and marks the first two unfinished books
        /// as current reads with progress. The preview library has neither.
        static func samples(_ books: [CloudBook]) -> [CloudBook] {
            guard let value = UserDefaults.standard.string(forKey: "BookwormsShareSamples")
            else { return books }
            let start = Int(value) ?? 0
            var reviewed = 0
            var reading = 0
            return books.map { book in
                var book = book
                if book.finishedDate != nil, book.rating != nil, reviewed < reviews.count {
                    book.review = reviews[(start + reviewed) % reviews.count]
                    reviewed += 1
                } else if book.finishedDate == nil, reading < 2 {
                    book.isReading = true
                    book.progress = [0.62, 0.18][reading]
                    book.started = ["2026-09-21", "2026-10-02"][reading]
                    reading += 1
                }
                return book
            }
        }
    }
#endif
