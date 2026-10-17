import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The Share tab: choose a template and its options, preview the export, and share it.
///
/// The preview shows the rendered image without the credit, which only the shared files carry.
/// Each option change renders the image again after a short pause and cancels a render still in
/// progress; a new design for a drawn book renders after it instead. Covers and spine fonts
/// load before each render, because `ImageRenderer` draws synchronously and would capture
/// anything still loading as a placeholder. The Pile template renders with
/// `PileSnapshotRenderer`, which loads its own covers and fonts.
///
/// **My reading** offers templates about the reader's own books, and **With friends** offers
/// comparisons with another Hardcover reader, chosen under **Compare with**
/// (`ShareReaderSection`). Comparisons come prepared from `SocialModel`; the body only picks
/// the shown reader's.
///
/// Without a library, the tab shows `NoLibraryView` instead, which can open the Hardcover sheet.
struct ShareStudioView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = ShareMode.mine
    @State private var template = ShareTemplate.topFive
    /// The reader chosen under **Compare with**: `nil`, or a reader no longer listed, is the
    /// best match.
    @State private var readerID: Int?
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
    /// The rendered image: `nil` before the first render, without books, or after a failed
    /// render.
    @State private var image: ShareImage?
    /// The request that drew `image`. While it differs from the current request, a newer image
    /// is on its way, so the preview shows progress and sharing waits.
    @State private var renderedRequest: RenderRequest?
    /// Whether the last render failed, so no image is shown or shared.
    @State private var failed = false
    @State private var showsAccount = false
    @State private var filmsPile = false
    /// The Pile template's books and heading when **Video** was tapped, which the video films.
    @State private var film: (books: [CloudBook], title: String) = ([], "")
    /// The files the share sheet offers while it is open.
    @State private var files: SharedFiles?
    /// Whether **Share** is adding the credit and writing the files.
    @State private var isPreparing = false
    /// Whether a finger, or on a Mac the mouse button, holds the preview, which then shows
    /// full size (`RootView`).
    @GestureState private var holdsPreview = false
    @Environment(\.fullSizeShareImage) private var fullSizeImage
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    init() {
        #if DEBUG
            let defaults = UserDefaults.standard
            guard let raw = defaults.string(forKey: "BookwormsShareTemplate") else { return }
            _template = State(initialValue: ShareTemplate(rawValue: raw) ?? .topFive)
            _mode = State(
                initialValue: defaults.string(forKey: "BookwormsShareMode")
                    .flatMap(ShareMode.init(rawValue:))
                    ?? (ShareTemplate(rawValue: raw)?.isSocial == true ? .friends : .mine))
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

    /// The reader the friends' templates compare with: the chosen one while listed, else the
    /// best match, else the first reader. `nil` in **My reading**.
    private var shownReader: SocialModel.Reader? {
        guard mode == .friends else { return nil }
        let readers = model.social.readers
        return readers.first { $0.id == readerID } ?? readers.first { $0.match?.score != nil }
            ?? readers.first
    }

    /// The books `template` draws. With friends, they come from the comparison with `reader`,
    /// and there are none before the reader's library downloads.
    private func books(
        _ template: ShareTemplate, frame: TimeFrame, bookID: Int?, reader: SocialModel.Reader?
    ) -> [CloudBook] {
        if mode == .friends && reader?.match == nil { return [] }
        return template.books(
            from: library, in: frame, bookID: bookID, direction: direction, match: reader?.match)
    }

    /// The image the current options and library call for.
    private var request: RenderRequest {
        let frame = shownFrame
        let bookID = template.isSingleBook ? bookID : nil
        let reader = shownReader
        var books = books(template, frame: frame, bookID: bookID, reader: reader)
        if template == .pile { books = Array(books.prefix(PileSnapshotRenderer.maximumBooks)) }
        // Only the drawn books' designs, so a design saved for another book changes nothing.
        let designs = books.map { model.design(for: $0) }
        // The pile renderer waits for its own fonts, so a newly loaded face changes nothing;
        // restarting a pile would only delay it. Other templates re-render only when a face for
        // one of their own books arrives.
        let loadedFaces =
            template == .pile ? 0 : designs.count { model.fonts.face(for: $0) != nil }
        return RenderRequest(
            template: template, aspect: aspect, frame: frame, bookID: bookID,
            coverStyle: coverStyle, direction: direction, showsRatings: showsRatings, seed: seed,
            syncedAt: model.library?.syncedAt, readerID: reader?.id,
            socialRevision: mode == .friends ? model.social.revision : 0,
            hasScore: template == .tasteMatch && reader?.match?.score != nil,
            covers: books.map(\.coverCandidates.first), designs: designs, loadedFaces: loadedFaces)
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
                form(isPending: isPending, hasNoBooks: request.isEmpty)
            }
        }
        .shareSheet($files)
        .sheet(isPresented: $showsAccount) { HardcoverAccountView() }
        .sheet(isPresented: $filmsPile) {
            PileVideoSheet(books: film.books, title: film.title, aspect: aspect, seed: seed)
        }
        .task(id: request.options) {
            // A saved design draws after the image in progress instead of restarting it.
            for await _ in Observations({ [model] in model.library?.designs }) { await render() }
        }
        .onChange(of: model.books, initial: true) { _, books in
            periods = TimeFrame.periods(in: books)
        }
        .onChange(of: mode) { oldMode, mode in
            if mode == .mine, oldMode.templates.contains(template) {
                // My reading opens on Top Five, even from Hot takes, which both modes offer. A
                // detail's Share picks its template along with the mode, so that one stays.
                template = .topFive
            } else if !mode.templates.contains(template) {
                template = mode == .mine ? .topFive : mode.templates[0]
            }
        }
        .task(id: shownReader?.id) {
            // A reader outside the refresh's limit downloads once shown; a refresh in progress
            // downloads the others itself.
            guard let reader = shownReader, reader.match == nil, !model.social.isSyncing else {
                return
            }
            await model.downloadReader(reader.id)
        }
        .onChange(of: model.shareBookID, initial: true) { _, id in
            guard let id else { return }
            model.shareBookID = nil
            let book = library.first { $0.id == id }
            mode = .mine
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
            .onChange(of: model.social.revision, initial: true) {
                // `-BookwormsShareReader <username>` chooses that reader once they are listed.
                guard readerID == nil,
                    let username = UserDefaults.standard.string(forKey: "BookwormsShareReader")
                else { return }
                readerID = model.social.readers.first { $0.profile.username == username }?.id
            }
        #endif
    }

    /// The preview above the settings in a compact width; in a regular width, such as on the
    /// Mac, the preview fills the window beside a column of settings. The image's size and cover
    /// style sit right below the preview, then **My reading** / **With friends**, which chooses
    /// the templates listed below it.
    @ViewBuilder
    private func form(isPending: Bool, hasNoBooks: Bool) -> some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    VStack(spacing: 16) {
                        preview(isPending: isPending, hasNoBooks: hasNoBooks, maxHeight: .infinity)
                        imageRow.frame(maxWidth: 420)
                        modePicker.frame(maxWidth: 420)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Form { settings(hasNoBooks: hasNoBooks) }
                        // One background behind the preview and the settings, under one
                        // toolbar.
                        .scrollContentBackground(.hidden)
                        .frame(width: 400)
                }
            } else {
                Form {
                    Section {
                        preview(isPending: isPending, hasNoBooks: hasNoBooks, maxHeight: 380)
                        imageRow
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        modePicker
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    settings(hasNoBooks: hasNoBooks)
                }
                // The preview starts just below the bar instead of a section's height lower.
                .contentMargins(.top, 4, for: .scrollContent)
            }
        }
        .navigationTitle("Share")
        // An inline title, as Library and Desk use, leaves the preview the height a large
        // title would take.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if image != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        Task { await share() }
                    }
                    .disabled(isPending || isPreparing)
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("Templates for", selection: $mode) {
            ForEach(ShareMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    /// The image's size, and beside it whether covers draw as 3D books or flat. At accessibility
    /// text sizes the button moves below the picker, which then keeps the row's whole width.
    private var imageRow: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Picker("Size", selection: $aspect) {
                ForEach(ShareAspect.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            coverToggle
        }
    }

    /// Draws covers as 3D books when on and flat when off: a round glass button with a cube, as
    /// Photos marks its spatial scenes, filled and tinted while on. It is disabled where the
    /// template has one style: Desk's books are always 3D, and Year in Books on Square shows no
    /// covers.
    private var coverToggle: some View {
        let isOn = Binding {
            template == .pile || coverStyle == .threeD
        } set: {
            coverStyle = $0 ? .threeD : .flat
        }
        // Year in Books draws covers only for its records, which appear when they fit.
        let help =
            template == .yearInBooks
            ? "Draws the records' covers as 3D books when they fit" : "Draws covers as 3D books"
        return Toggle(
            "3D books", systemImage: isOn.wrappedValue ? "cube.fill" : "cube", isOn: isOn
        )
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityHint(help)
        .disabled(!template.hasCoverStyle || (template == .yearInBooks && aspect == .square))
    }

    @ViewBuilder
    private func settings(hasNoBooks: Bool) -> some View {
        if mode == .friends {
            ShareReaderSection(
                reader: shownReader, selection: $readerID, showsAccount: $showsAccount)
        }
        Section("Template") {
            if dynamicTypeSize >= .xLarge {
                // Names in a grid truncate above the default text size.
                Picker("Template", selection: $template) {
                    ForEach(mode.templates) { option in
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
        if template == .hotTakes || template.hasRatingOption || showsShuffle {
            Section("Options") { options(hasNoBooks: hasNoBooks) }
        }
    }

    /// Opens the share sheet with the image. Only the shared file carries the credit.
    private func share() async {
        guard let image else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            var shared = try await SharedFiles.images([image])
            // A comparison invites its viewers to compare on Hardcover.
            if renderedRequest?.readerID != nil, let owner = model.social.owner {
                shared.text = HardcoverInvite.shareText(owner.username)
            }
            files = shared
        } catch {
            model.toasts.show(.failure("Couldn't prepare the image"))
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
                // A fifth part names a reader to compare with, which also chooses With friends.
                let reader = parts.count > 4 ? parts[4] : ""
                mode = template.isSocial || !reader.isEmpty ? .friends : .mine
                if !reader.isEmpty {
                    // Comparisons are prepared shortly after the library loads.
                    for _ in 0..<50 where model.social.readers.isEmpty {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    readerID = model.social.readers.first { $0.profile.username == reader }?.id
                }
                // Waits until the image matches the options and font loads have settled.
                var settled = 0
                while settled < 5, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    settled = renderedRequest == request ? settled + 1 : 0
                }
                ShareDebug.write(image, name: "-" + entry.replacing(":", with: "_"))
            }
        }
    #endif

    @ViewBuilder
    private func preview(isPending: Bool, hasNoBooks: Bool, maxHeight: CGFloat) -> some View {
        // Messages sit outside the image's box, which would clip them at large text sizes.
        if image == nil && hasNoBooks && !model.isLoading {
            let empty = emptyState
            ContentUnavailableView {
                Label(empty.title, systemImage: template.systemImage)
            } description: {
                Text(empty.message)
            } actions: {
                // The iCloud library may carry no reviews and never carries friends; the device's
                // own Hardcover sign-in adds both.
                let needsHardcover =
                    mode == .friends ? !model.canCompare : template == .review && !usesHardcover
                if needsHardcover && !model.isPreview {
                    Button("Connect Hardcover") { showsAccount = true }
                        .buttonStyle(.bordered)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if image == nil && failed && !isPending {
            ContentUnavailableView(
                "Couldn't draw the image", systemImage: "exclamationmark.triangle",
                // A pile's arrangement varies with the seed, so Shuffle can succeed where it
                // failed.
                description: Text(
                    template == .pile
                        ? "Try Shuffle or another size." : "Try another size or template.")
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            box(isPending: isPending, maxHeight: maxHeight)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    /// The preview's image in a box shaped like it, with the render's progress over it.
    ///
    /// Holding the image shows it full size until the finger lifts; VoiceOver's **Show full
    /// size** action shows it until dismissed. The hold starts after a moment without movement,
    /// so a scroll that starts on the preview still scrolls.
    private func box(isPending: Bool, maxHeight: CGFloat) -> some View {
        let size = aspect.size
        return ZStack {
            // Sizes the box as the image does, before there is one.
            Color.clear.frame(idealWidth: size.width, idealHeight: size.height)
            if let image {
                Image(uiImage: image.image)
                    .resizable()
                    .scaledToFit()
                    .gesture(
                        LongPressGesture(minimumDuration: 0.25)
                            // The drag keeps the hold going, wherever the finger moves, until it
                            // lifts.
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .updating($holdsPreview) { value, state, _ in
                                if case .second(true, _) = value { state = true }
                            }
                    )
                    .onChange(of: holdsPreview) { _, holds in
                        fullSizeImage.wrappedValue = holds ? image.image : nil
                    }
                    .accessibilityLabel("\(image.name) preview")
                    .accessibilityAction(named: "Show full size") {
                        fullSizeImage.wrappedValue = image.image
                    }
            }
            if template == .pile && isPending {
                // A pile takes seconds to load its covers and lay its books out.
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
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
    }

    /// Whether this iPhone's Hardcover sign-in provides the library, which preview mode ignores.
    private var usesHardcover: Bool { model.account.isSignedIn && !model.isPreview }

    /// Why the template has nothing to draw, and what would give it something.
    private var emptyState: (title: String, message: String) {
        if mode == .friends { return friendsEmptyState }
        let frame = shownFrame
        let suffix = frame == .lifetime ? "" : " in \(frame.title)"
        let nextSync =
            usesHardcover
            ? "after the next sync with Hardcover"
            : "after one of your Apple devices syncs with Hardcover"
        switch template {
        case .review where !library.contains { $0.reviewText != nil }:
            return (
                "No reviews yet",
                usesHardcover
                    ? "Reviews you write on Hardcover appear here \(nextSync)."
                    : "This iCloud library has no reviews. Connect Hardcover on this \(ThisDevice.name) to share yours."
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

    /// Why a comparison has nothing to draw: no sign-in, no reader, a library still loading or
    /// hidden, or too little in common.
    private var friendsEmptyState: (title: String, message: String) {
        let social = model.social
        guard let reader = shownReader else {
            if !model.canCompare {
                return (
                    "Compare with friends",
                    "Connect Hardcover to compare your ratings with the people you follow."
                )
            }
            if social.isSyncing {
                return ("Loading the people you follow", "This takes a moment the first time.")
            }
            if let failure = social.failure {
                return ("Couldn't load the people you follow", failure)
            }
            return (
                "No one to compare with yet",
                "Follow readers on Hardcover, or look up a public username under Compare with."
            )
        }
        let name = reader.profile.shortName
        guard let match = reader.match else {
            if social.loadingReaders.contains(reader.id) || social.isSyncing {
                return ("Loading \(name)'s ratings", "This takes a moment for a big library.")
            }
            return (
                "\(name)'s ratings haven't downloaded",
                social.failure ?? "Choose \(name) again under Compare with to try again."
            )
        }
        if reader.hasNoRatings {
            return (
                "\(name) has no public ratings",
                "Their Hardcover profile may be private, or they haven't rated any books yet."
            )
        }
        let shared = match.shared.count
        let both = shared == 1 ? "1 book" : "\(shared) books"
        switch template {
        case .tasteMatch:
            return (
                "Not enough in common yet",
                "You and \(name) have both rated \(both). A taste match needs "
                    + "\(TasteMatch.minimumShared)."
            )
        case .hotTakes:
            let frame = shownFrame
            let suffix = frame == .lifetime ? "" : " in \(frame.title)"
            let other: HotTakeDirection = direction == .lovedMore ? .lovedLess : .lovedMore
            if !match.hotTakes(in: frame, direction: other).isEmpty {
                return (
                    "No hot takes\(suffix)",
                    "Choose \(other.title) to see where \(name) rated higher or lower."
                )
            }
            if frame != .lifetime, !match.hotTakes(in: .lifetime, direction: direction).isEmpty {
                return ("No hot takes\(suffix)", "Choose another time frame or Lifetime.")
            }
            return (
                "No hot takes with \(name)\(suffix)",
                "Books you both rated at least half a star apart appear here. You have \(both) "
                    + "in common."
            )
        default:
            return (
                "Nothing to swap yet",
                "Book Swap suggests books one of you rated 4 stars or more that the other "
                    + "hasn't shelved."
            )
        }
    }

    private var templateGrid: some View {
        // Rows of three, or of four where three would leave a template alone on the last row.
        let columns = mode.templates.count % 3 == 1 ? 4 : 3
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
            spacing: 6
        ) {
            ForEach(mode.templates) { option in
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

    /// The kinds of time frame, shortest first.
    private enum FrameKind: CaseIterable, Identifiable {
        case month, year, lifetime

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
            LabeledContent("Book") {
                if let shown { BookText(shown.spineTitle, of: shown) } else { Text("None") }
            }
        }
        .disabled(choices.isEmpty)
    }

    @ViewBuilder
    private func options(hasNoBooks: Bool) -> some View {
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
        if template == .pile {
            Button("Video", systemImage: "video") {
                let frame = shownFrame
                let books = ShareTemplate.pile.books(from: library, in: frame, direction: direction)
                let input = ShareInput(
                    template: .pile, aspect: aspect, books: books, frame: frame,
                    coverStyle: coverStyle, direction: direction, showsRatings: showsRatings,
                    seed: seed)
                film = (books, input.period)
                filmsPile = true
            }
            .disabled(hasNoBooks)
        }
    }

    /// Whether the seed changes the image. It varies Year in Books' spine stacks, the Top Five
    /// fan, a pile's arrangement, and the angle of 3D books; flat single covers ignore it.
    private var showsShuffle: Bool {
        switch template {
        case .yearInBooks, .topFive, .pile: true
        case .hotTakes, .justFinished, .review, .currentlyReading, .tasteMatch, .bookSwap:
            coverStyle == .threeD
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
        let reader = request.readerID.flatMap(model.social.reader)
        let books = books(
            template, frame: request.frame, bookID: request.bookID, reader: reader)
        var input = ShareInput(
            template: template, aspect: request.aspect, books: books, frame: request.frame,
            coverStyle: request.coverStyle, direction: request.direction,
            showsRatings: request.showsRatings, seed: request.seed)
        if let reader, let match = reader.match, let owner = model.social.owner {
            input.social = ShareSocial(owner: owner, reader: reader.profile, match: match)
            input.social?.avatars = await loadAvatars([owner, reader.profile])
        }
        // `nil` when there are no books or the image could not be drawn.
        var rendered: UIImage?
        if request.isEmpty {
            // Nothing to draw; the preview says why.
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
            } catch {}
        } else {
            // The books drawn with covers. Year in Books draws covers only for its records.
            let covered =
                template == .yearInBooks
                ? YearInBooks(frame: request.frame, library: books).records : books
            // The spines of 3D books carry lettering, so their fonts load first. This waits for
            // every face, including ones another feature is already downloading.
            let lettered = request.coverStyle == .threeD ? covered : []
            await model.fonts.load(lettered.compactMap { model.design(for: $0) })
            let coverSize = template.isSingleBook ? 1200 : template == .topFive ? 900 : 700
            input.covers = await loadCovers(covered, maximumPixelSize: coverSize)
            guard !Task.isCancelled else { return }
            input.looks = Dictionary(books.map { ($0.id, model.look(for: $0)) }) { first, _ in
                first
            }
            rendered = input.render()
        }
        // Without a new image, the old one must not stay to be shared.
        var name = template.title
        if template.usesTimeFrame && !template.isSingleBook { name += " " + input.period }
        if let reader = input.social?.reader { name += " with \(reader.shortName)" }
        image = rendered.map { ShareImage(image: $0, name: name) }
        failed = !request.isEmpty && rendered == nil
        renderedRequest = request
        #if DEBUG
            ShareDebug.write(image)
            // `-BookwormsShareFullSize YES` shows each image full size, as holding the preview
            // does.
            if UserDefaults.standard.bool(forKey: "BookwormsShareFullSize"), let image {
                fullSizeImage.wrappedValue = image.image
            }
        #endif
    }

    /// Loads the readers' profile photos for a social card. A reader without one, or whose
    /// photo fails to load, is left out and shows initials.
    private func loadAvatars(_ readers: [ReaderProfile]) async -> [Int: UIImage] {
        var avatars: [Int: UIImage] = [:]
        for reader in readers {
            guard let url = reader.avatarURL else { continue }
            avatars[reader.id] = await model.covers.image(at: [url], maximumPixelSize: 400)
        }
        return avatars
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
    /// The reader a comparison draws with, or `nil` outside **With friends**.
    var readerID: Int?
    /// `SocialModel.revision` for a comparison, so new ratings redraw it.
    var socialRevision: Int
    /// Whether a Taste Match has a score, which it draws even without books to show.
    var hasScore: Bool
    /// The covers the image draws, so choosing another cover redraws it.
    var covers: [URL?]
    /// The designs of the books the image draws, in their order.
    var designs: [SpineDesignV1?]
    var loadedFaces: Int

    /// Whether the image has nothing to draw.
    var isEmpty: Bool { covers.isEmpty && !hasScore }

    /// The request without its designs. The render task restarts only when these change: a
    /// pile takes seconds to render, and a generation run saves a design every few seconds, so a
    /// new design waits for the image in progress and draws next.
    var options: RenderRequest {
        var options = self
        options.designs = []
        return options
    }
}

extension EnvironmentValues {
    /// The share image that `RootView` shows full size over the tabs and bars, or `nil`. The
    /// Share tab sets it while its preview is held.
    @Entry var fullSizeShareImage: Binding<UIImage?> = .constant(nil)
}

/// A share image filling the screen at its own aspect on black, over the tabs and bars. A tap,
/// or VoiceOver's escape gesture, closes it.
struct FullSizeShareImage: View {
    let image: UIImage
    let close: () -> Void
    @AccessibilityFocusState private var isFocused: Bool

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture(perform: close)
            .accessibilityElement()
            .accessibilityLabel("Full-size preview")
            .accessibilityHint("Double-tap to close")
            .accessibilityAddTraits([.isImage, .isModal])
            .accessibilityAction(.default, close)
            .accessibilityAction(.escape, close)
            .accessibilityFocused($isFocused)
            // VoiceOver moves to the image, which it opened from the preview's action.
            .onAppear { isFocused = true }
    }
}

/// A rendered share image and the name its file takes, which `ShareLink` receives as PNG data.
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
                        BookText(book.title, of: book).lineLimit(2)
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
    /// where the name is a `ShareTemplate` raw value such as `topFive`, `hotTakes`, or `pile`.
    /// `-BookwormsShareAspect <story|portrait|square>`,
    /// `-BookwormsShareFrame <year:2025|month:2025-08|lifetime>`, `-BookwormsShareBook <id>`,
    /// `-BookwormsShareCover <threeD|flat>`, `-BookwormsShareDirection <lovedMore|lovedLess>`,
    /// and `-BookwormsShareSeed <n>` set its options, and `-BookwormsShareSamples <n>` adds
    /// fictional reviews and current reads (`samples(_:)`). Each render is then written, with
    /// the credit that sharing adds, to `Library/Caches/Bookworms/share-debug.png`;
    /// `-BookwormsShareBatch` renders a list of option sets in one launch
    /// (`ShareStudioView.renderBatch()`).
    enum ShareDebug {
        /// Writes `image` as `share-debug<name>.png`, with the credit, as sharing exports it, in
        /// a launch with `-BookwormsShareTemplate` or `-BookwormsShareBatch`.
        @MainActor static func write(_ image: ShareImage?, name: String = "") {
            let defaults = UserDefaults.standard
            guard let image,
                defaults.string(forKey: "BookwormsShareTemplate") != nil
                    || defaults.string(forKey: "BookwormsShareBatch") != nil
            else { return }
            let url = URL.cachesDirectory.appending(path: "Bookworms/share-debug\(name).png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? image.image.withShareCredit()?.pngData()?.write(to: url, options: .atomic)
        }

        @MainActor private static var switchesTabs = false

        /// With `-BookwormsShareTabs "desk:0 share:8"`, selects each tab, named by its `AppTab`
        /// raw value, once its seconds pass after the previous entry. It checks the Desk's pile
        /// while the Share tab renders one.
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
                    model.selectedTab = AppTab(rawValue: String(parts.first ?? "")) ?? .share
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
