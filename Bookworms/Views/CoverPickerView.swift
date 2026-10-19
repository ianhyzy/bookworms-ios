import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Lets the reader choose `book`'s cover from the covers of its Hardcover editions, or return to
/// the default cover. The covers lie like editions on the walnut table, each with a soft shadow,
/// and a ribbon marks the current one.
///
/// The choice is saved to iCloud as a `CoverChoiceV1` record, and every view, share image, and
/// generation run then uses it; the choice registers its undo with `undoManager`. Finding covers
/// needs this device's Hardcover sign-in; signed out or with a rejected login, the sheet explains
/// that and offers to connect or reconnect, which closes the picker for the account sheet.
///
/// For a series that shares a design, `book` is the book the design comes from, and the sheet
/// says so: it is titled **Series cover**, names that book, and says the cover is used for every
/// book in the series.
struct CoverPickerView: View {
    /// Whose spine the cover sets: the book's own, or its whole series'.
    enum Scope {
        case book
        /// The series, named when its memberships name it.
        case series(name: String?)
    }

    let book: CloudBook
    let scope: Scope
    let undoManager: UndoManager?
    /// Called after the book's cover changes.
    let onChange: () -> Void
    /// Called to sign in or reconnect, after which the presenter shows the account sheet in
    /// place of this one.
    let signIn: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var covers: Result<[EditionCover], any Error>?
    @State private var isSaving = false
    @State private var saveError: String?
    /// Grows with Dynamic Type, up to a width that keeps two columns on an iPhone.
    @ScaledMetric private var cellWidth: CGFloat = 104

    private var canFindCovers: Bool {
        #if DEBUG
            if CoverPickerDebug.stubsCovers { return true }
        #endif
        return model.account.isSignedIn
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { WalnutWall().ignoresSafeArea() }
                .navigationTitle(isSeries ? "Series cover" : "Change cover")
                .navigationSubtitle(isSeries ? book.title : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        // A sign-in or reconnect changes the library revision, even when it finishes after the
        // account sheet closes, so covers load again. A grid already shown stays.
        .task(id: model.account.libraryRevision) {
            if case .success = covers { return }
            await load()
        }
        .alert(
            "The cover was not changed",
            isPresented: Binding {
                saveError != nil
            } set: {
                if !$0 { saveError = nil }
            }
        ) {
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if !canFindCovers {
            unavailable(
                "Choose covers with Hardcover", systemImage: "books.vertical",
                description: Text(
                    "Bookworms finds other covers in the editions Hardcover lists for this book. Connect your Hardcover account to choose one."
                )
            ) {
                Button("Connect Hardcover", action: signIn)
                    .buttonStyle(.glassProminent)
            }
        } else {
            switch covers {
            case nil:
                ProgressView("Finding covers")
            case .failure(let error)
            where [.invalidToken, .insufficientScope].contains(error as? HardcoverError):
                // Retrying repeats the rejection, so this offers the sign-in instead.
                unavailable(
                    "Reconnect Hardcover", systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(
                        "Your Hardcover login expired, was revoked, or lacks a permission Bookworms needs. Reconnect to find other covers."
                    )
                ) {
                    Button("Reconnect Hardcover") {
                        model.account.startSignIn()
                        signIn()
                    }
                    .buttonStyle(.glassProminent)
                }
            case .failure(let error):
                unavailable(
                    "Covers unavailable", systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                ) {
                    Button("Try again") { Task { await load() } }
                }
            case .success(let covers):
                grid(covers)
            }
        }
    }

    /// A state without covers to choose. Returning to the default cover needs only iCloud, so
    /// it stays available here.
    private func unavailable(
        _ title: LocalizedStringKey, systemImage: String, description: Text,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            description
        } actions: {
            actions()
            if book.chosenCoverURL != nil {
                Button("Use default cover") { choose(nil) }
            }
        }
    }

    private func grid(_ covers: [EditionCover]) -> some View {
        let current = book.coverCandidates.first
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if book.chosenCoverURL != nil {
                    Button("Use default cover", systemImage: "arrow.uturn.backward") {
                        choose(nil)
                    }
                    .buttonStyle(.bordered)
                }
                if covers.isEmpty {
                    ContentUnavailableView(
                        "No other covers", systemImage: "photo.on.rectangle",
                        description: Text("Hardcover lists no other covers for this book."))
                }
                if case .series(let name) = scope {
                    Text(
                        name.map { "Used for every book in \($0)." }
                            ?? "Used for every book in this series."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: min(cellWidth, 160)), spacing: 16, alignment: .top)
                    ],
                    spacing: 24
                ) {
                    ForEach(covers) { cover in
                        CoverCell(book: book, cover: cover, isCurrent: cover.url == current) {
                            choose(cover)
                        }
                    }
                }
                Text(
                    "Covers come from the editions Hardcover lists for this book. Bookworms saves your choice in iCloud."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .disabled(isSaving)
        .overlay {
            if isSaving {
                ProgressView()
                    .padding(16)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .accessibilityLabel("Saving the cover")
            }
        }
    }

    private func load() async {
        guard canFindCovers else { return }
        covers = nil
        do {
            covers = .success(try await model.editionCovers(for: book))
        } catch {
            // A dismissed sheet cancels the request; it has nothing to show.
            if !Task.isCancelled { covers = .failure(error) }
        }
        #if DEBUG
            if let index = CoverPickerDebug.choice, case .success(let found) = covers,
                found.indices.contains(index)
            {
                choose(found[index])
            }
        #endif
    }

    private var isSeries: Bool {
        if case .series = scope { true } else { false }
    }

    /// Saves `cover`, or the default cover for `nil`, registers its undo, and closes the sheet
    /// once it is saved. The undo needs the previous cover's edition, so a chosen cover that
    /// Hardcover no longer lists can't be restored by an undo.
    private func choose(_ cover: EditionCover?) {
        guard !isSaving else { return }
        let unchanged =
            cover.map { $0.url == book.coverCandidates.first } ?? (book.chosenCoverURL == nil)
        guard !unchanged else { return dismiss() }
        let listed = (try? covers?.get()) ?? []
        // `nil` restores the default cover.
        let previous: EditionCover?? =
            if let url = book.chosenCoverURL {
                listed.first { $0.url == url }.map { .some($0) }
            } else {
                .some(nil)
            }
        isSaving = true
        Task { [model, book, undoManager] in
            do {
                try await model.chooseCover(cover, for: book)
                if let previous {
                    undoManager?
                        .registerStyleChange("Change Cover") {
                            try await model.chooseCover(previous, for: book)
                        } redo: {
                            try await model.chooseCover(cover, for: book)
                        }
                }
                onChange()
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// One edition's cover, with its format and year, marked when it is the book's cover.
private struct CoverCell: View {
    let book: CloudBook
    let cover: EditionCover
    let isCurrent: Bool
    let choose: () -> Void

    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        // "Hardcover" would read as the service's name.
        let format = ShelfLabels.format(cover.format).map { $0 == "Hardcover" ? "Hardback" : $0 }
        let year = cover.year.map { String($0) }
        Button(action: choose) {
            VStack(spacing: 6 + Self.ribbonReach) {
                thumbnail
                Text([format, year].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    // Larger, a word such as "Hardcover" breaks mid-word in a two-column cell;
                    // the accessibility label carries the full text.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // An unreadable image would leave the book on its default cover.
        .disabled(failed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [year, format].contains { $0 != nil }
                ? "Cover from \([year, format].compactMap(\.self).joined(separator: " ")) edition"
                : "Cover from another edition"
        )
        .accessibilityValue(failed ? "Unavailable" : "")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .task(id: cover.url) {
            // A book with only this cover, so the store loads exactly this image and caches it
            // for the details screen.
            let candidate = CloudBook(
                id: book.id, title: book.title, author: book.author, coverURL: cover.url,
                detailCoverURL: nil)
            image = await model.covers.image(for: candidate, maximumPixelSize: 480)
            failed = image == nil
        }
    }

    /// The cover lying on the table with a soft shadow, and for the current cover, a ribbon
    /// that comes out from under its foot, as a bookmark does.
    private var thumbnail: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            // The ribbon lies under the cover, so only the end that comes out shows.
            .background(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    SoftShadow(cornerRadius: 3)
                    if isCurrent {
                        Ribbon()
                            .frame(width: 13, height: 30)
                            .padding(.trailing, 14)
                            .offset(y: Self.ribbonReach)
                    }
                }
            }
    }

    /// How far the current cover's ribbon comes out past its foot.
    static let ribbonReach: CGFloat = 16
}

#if DEBUG
    /// Simulator hooks for the cover picker, which a script cannot tap.
    ///
    /// `-BookwormsCoverPicker YES` opens the picker on the details of the book that
    /// `-BookwormsOpenBook` opens. `-BookwormsStubCovers YES` answers the editions query with six
    /// fictional covers drawn on this device and placed in the cover cache, so neither Hardcover
    /// nor an image host is contacted; `-BookwormsStubCovers expired` answers as Hardcover does
    /// for a revoked login. `-BookwormsChooseCover <index>` then chooses one of the covers.
    enum CoverPickerDebug {
        static var opensPicker: Bool { UserDefaults.standard.bool(forKey: "BookwormsCoverPicker") }
        static var stubsCovers: Bool { stub == "YES" || stubsExpiredLogin }
        static var stubsExpiredLogin: Bool { stub == "expired" }
        private static var stub: String? {
            UserDefaults.standard.string(forKey: "BookwormsStubCovers")
        }
        static var choice: Int? {
            UserDefaults.standard.string(forKey: "BookwormsChooseCover").flatMap { Int($0) }
        }

        static func covers(for book: CloudBook) -> [EditionCover] {
            let editions: [(format: String?, year: Int?)] = [
                ("Hardcover", 2016), ("Paperback", 2017), ("Audiobook", 2018), ("Ebook", 2021),
                ("Mass Market Paperback", 2023), (nil, nil),
            ]
            // `CoverStore` reads its disk cache, named by the URL's digest, before the network.
            let folder = URL.cachesDirectory.appending(path: "Bookworms/covers")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return editions.enumerated()
                .map { index, edition in
                    let url = URL(string: "https://covers.example.com/\(book.id)/\(index + 1).jpg")!
                    let file = folder.appending(path: CloudContract.digest(url.absoluteString))
                    try? draw(book.spineTitle, edition: index + 1, hue: Double(index) / 6)
                        .write(to: file, options: .atomic)
                    return EditionCover(
                        editionID: 9_000 + index, url: url, format: edition.format,
                        year: edition.year)
                }
        }

        /// A plain fictional cover: a colored board with the title and an edition number.
        private static func draw(_ title: String, edition: Int, hue: Double) -> Data {
            let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(bounds: bounds, format: format)
                .jpegData(withCompressionQuality: 0.9) { context in
                    UIColor(hue: hue, saturation: 0.55, brightness: 0.5, alpha: 1).setFill()
                    context.fill(bounds)
                    UIColor(hue: hue, saturation: 0.35, brightness: 0.85, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 380, width: 400, height: 24))
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 44, weight: .bold),
                        .foregroundColor: UIColor.white, .paragraphStyle: style,
                    ]
                    (title as NSString)
                        .draw(
                            in: CGRect(x: 30, y: 90, width: 340, height: 270),
                            withAttributes: attributes)
                    ("Edition \(edition)" as NSString)
                        .draw(
                            in: CGRect(x: 30, y: 470, width: 340, height: 60),
                            withAttributes: attributes.merging(
                                [.font: UIFont.systemFont(ofSize: 30, weight: .medium)]
                            ) { $1 })
                }
        }
    }
#endif
