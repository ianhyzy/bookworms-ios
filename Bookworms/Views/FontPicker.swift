import SwiftUI

/// The font picker that the **Font** row of a book's **Spine design** card opens.
///
/// It lists the families the book's design tried, best match first (`AppModel.fontChoices(for:)`),
/// then **Other**, which searches the Google Fonts families a reader may pick by name
/// (`AppModel.pickableFamilies()`, `AppModel.listsInPicker(_:)`). Each row sets the book's
/// title in its family, with the family's name in small italics below, and a check marks the
/// family the spine shows. A pick saves at once as the reader's font
/// (`AppModel.setFont(_:for:)`) and leaves the picker open, so the reader can compare picks on
/// the card's spine above it. The picker takes no other pick until a save ends, and reports a
/// failed save in an alert, which, unlike a toast, shows over a sheet on the Mac too.
struct FontPicker: View {
    /// A page the picker pushes.
    private enum Page: Hashable {
        case other
    }

    /// The book as its details showed it. The picker shows the library's current copy, so a saved
    /// pick appears at once.
    let opened: CloudBook

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The families listed first, as the picker opened, so a pick never reorders them.
    @State private var choices: [String] = []
    /// The family being saved, until its save ends.
    @State private var saving: String?
    /// Why the last pick wasn't saved, until the reader dismisses the alert.
    @State private var saveError: String?
    @State private var path: [Page] = []

    init(book: CloudBook) { opened = book }

    private var book: CloudBook { model.book(id: opened.id) ?? opened }

    var body: some View {
        let book = book
        let design = model.design(for: book)
        let current = design?.fontFamily
        let uppercase = design?.uppercase ?? false
        let context = FontRow.Context(
            title: uppercase ? book.spineTitle.uppercased() : book.spineTitle,
            lettering: model.sharedLettering(of: book, uppercase: uppercase),
            weight: design?.weight ?? 600, current: current, saving: saving, pick: pick)
        // A family picked under **Other** leads the list until the picker closes.
        let listed = current.map { choices.contains($0) ? choices : [$0] + choices } ?? choices
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(listed, id: \.self) { FontRow(family: $0, context: context) }
                }
                Section {
                    NavigationLink("Other", value: Page.other)
                }
            }
            .navigationTitle("Font")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { _ in
                FontSearch(context: context).toolbar { done }
            }
            .toolbar { done }
        }
        .onAppear {
            if choices.isEmpty { choices = model.fontChoices(for: book) }
        }
        #if DEBUG
            .task { await applyDebugLaunch() }
        #endif
        .alert(
            "The font was not changed",
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

    private var done: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }

    private func pick(_ family: String) {
        let book = book
        guard saving == nil, family != model.design(for: book)?.fontFamily else { return }
        saving = family
        Task { [model] in
            do {
                try await model.setFont(family, for: book)
            } catch {
                saveError = Self.message(for: error)
            }
            saving = nil
        }
    }

    #if DEBUG
        @MainActor private static var appliedDebugLaunch = false

        /// Simulator hooks, once per launch, for a picker that `-BookwormsFontPicker YES` opens
        /// (`SpineDesignCard`): `-BookwormsFontSearch <query>` opens **Other** with that search,
        /// and `-BookwormsSpineFont <family>` picks that family two seconds later, as a tap does.
        private func applyDebugLaunch() async {
            guard !Self.appliedDebugLaunch else { return }
            Self.appliedDebugLaunch = true
            let defaults = UserDefaults.standard
            if defaults.string(forKey: "BookwormsFontSearch") != nil { path = [.other] }
            guard let family = defaults.string(forKey: "BookwormsSpineFont") else { return }
            try? await Task.sleep(for: .seconds(2))
            pick(family)
        }
    #endif

    /// Why a pick failed, in the reader's terms.
    private static func message(for error: any Error) -> String {
        switch error {
        case CompanionError.designChanged: "The spine was redesigned on another device."
        case CompanionError.invalidDesign: "Bookworms can't letter this spine in it."
        case is GoogleFonts.Unavailable: "Google Fonts is unavailable. Try again later."
        default: SpineWorker.iCloudMessage(for: error) ?? error.localizedDescription
        }
    }
}

/// One family in the font picker: the book's title set in it, the family's name in small
/// italics below, and a check when the spine shows it.
///
/// The title shows as a placeholder, and the row can't be picked, while the face downloads
/// (`SpineFonts.previewFace(family:weight:)`). A family that can't download, or that lacks a
/// glyph of the lettering of any book that shares the spine's design, is dimmed and can't be
/// picked.
private struct FontRow: View {
    /// What every row of one picker shares.
    struct Context {
        /// The title as the spine letters it.
        let title: String
        /// The title and author of every book that shares the spine's design
        /// (`AppModel.sharedLettering(of:uppercase:)`), which a family must have glyphs for.
        let lettering: String
        /// The design's title weight, so a row shows the instance the spine would draw.
        let weight: Int
        /// The family the spine shows.
        let current: String?
        /// The family being saved, if any.
        let saving: String?
        let pick: (String) -> Void
    }

    private enum Preview {
        case loading
        case ready(FontFace)
        case unusable
    }

    let family: String
    let context: Context

    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 24
    @State private var preview = Preview.loading

    var body: some View {
        let isCurrent = family == context.current
        let isReady = if case .ready = preview { true } else { false }
        Button {
            context.pick(family)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    title
                    Text(family).font(.caption).italic().foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if context.saving == family {
                    ProgressView()
                } else if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isReady || context.saving != nil)
        .accessibilityLabel(family)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .task(id: family) {
            if case .ready = preview { return }
            let face = await model.fonts.previewFace(family: family, weight: context.weight)
            guard !Task.isCancelled else { return }
            preview =
                face.map { $0.covers(context.lettering) ? .ready($0) : .unusable } ?? .unusable
        }
    }

    @ViewBuilder private var title: some View {
        let text = Text(context.title).lineLimit(1).minimumScaleFactor(0.5)
        switch preview {
        case .ready(let face): text.font(face.font(size: titleSize))
        case .loading: text.font(.title2).redacted(reason: .placeholder)
        case .unusable: text.font(.title2).foregroundStyle(.tertiary)
        }
    }
}

/// **Other** in the font picker: the Google Fonts families that spines may use
/// (`BookAnalyzer.allowsFamily`) and the picker lists (`AppModel.listsInPicker(_:)`), most
/// popular first, narrowed by a search of their names.
private struct FontSearch: View {
    let context: FontRow.Context

    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// The families to search, or `nil` until the catalog loads.
    @State private var families: [String]?
    @State private var failed = false
    @State private var results: [String] = []

    init(context: FontRow.Context) {
        self.context = context
        #if DEBUG
            _query = State(
                initialValue: UserDefaults.standard.string(forKey: "BookwormsFontSearch") ?? "")
        #endif
    }

    var body: some View {
        List(results, id: \.self) { FontRow(family: $0, context: context) }
            .overlay {
                if families == nil {
                    if failed {
                        ContentUnavailableView(
                            "Google Fonts is unavailable", systemImage: "wifi.exclamationmark")
                    } else {
                        ProgressView()
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query)
            .navigationTitle("Google Fonts")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard families == nil else { return }
                do {
                    let pickable = await AppModel.pickableFamilies()
                    let allowed = try await model.fonts.downloader.families()
                        .filter { pickable.contains($0) && AppModel.listsInPicker($0) }
                    families = allowed
                    results = Self.matches(in: allowed, for: query)
                } catch {
                    failed = true
                }
            }
            .task(id: query) {
                // Waits for typing to pause, so each keystroke doesn't start downloads of its own.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let families else { return }
                results = Self.matches(in: families, for: query)
            }
    }

    /// The first 50 of `families` whose names contain `query`, or the first 50 without one.
    // ponytail: the cap keeps a short query from listing, and downloading, hundreds of families;
    // typing more narrows it. Page through more results if readers need a broad browse.
    private static func matches(in families: [String], for query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(families.prefix(50)) }
        return Array(families.lazy.filter { $0.localizedStandardContains(query) }.prefix(50))
    }
}
