import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Share tab: choose a template and its options, preview the exact export, and share it.
///
/// Each option change renders the image again after a short pause and cancels a render still in
/// progress. Covers and spine fonts load before each render, because `ImageRenderer` draws
/// synchronously and would capture anything still loading as a placeholder.
struct ShareStudioView: View {
    @Environment(AppModel.self) private var model
    @State private var template = ShareTemplate.yearStack
    @State private var aspect = ShareAspect.story
    /// The chosen year: `nil` is every year for Spine Spectrum and the newest year otherwise.
    @State private var year: Int?
    /// The Just Finished book: `nil` is the most recently finished book.
    @State private var bookID: Int?
    @State private var showsRatings = true
    @State private var seed: UInt64 = 0
    @State private var image: ShareImage?
    @State private var hasNoBooks = false

    init() {
        #if DEBUG
            let defaults = UserDefaults.standard
            guard let raw = defaults.string(forKey: "BookwormsShareTemplate") else { return }
            _template = State(initialValue: ShareTemplate(rawValue: raw) ?? .yearStack)
            _aspect = State(
                initialValue: defaults.string(forKey: "BookwormsShareAspect")
                    .flatMap(ShareAspect.init(rawValue:)) ?? .story)
            _year = State(
                initialValue: defaults.string(forKey: "BookwormsShareYear").flatMap { Int($0) })
            _bookID = State(
                initialValue: defaults.string(forKey: "BookwormsShareBook").flatMap { Int($0) })
            _seed = State(
                initialValue: defaults.string(forKey: "BookwormsShareSeed").flatMap { UInt64($0) }
                    ?? 0)
            ShareDebug.openShareTab()
        #endif
    }

    var body: some View {
        let years = Set(model.books.compactMap(\.finishedYear)).sorted(by: >)
        let shownYear = template == .spectrum ? year : year ?? years.first
        let request = RenderRequest(
            template: template, aspect: aspect,
            year: template == .justFinished ? nil : shownYear,
            bookID: template == .justFinished ? bookID : nil,
            showsRatings: showsRatings, seed: seed, syncedAt: model.library?.syncedAt,
            designCount: model.library?.designs.count ?? 0, fontCount: model.fonts.faces.count)
        NavigationStack {
            Form {
                Section {
                    preview
                    Picker("Size", selection: $aspect) {
                        ForEach(ShareAspect.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section("Template") { templatePicker }
                Section("Options") { options(years: years, shownYear: shownYear) }
            }
            .navigationTitle("Share")
            .toolbar {
                if let image {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(
                            item: image,
                            preview: SharePreview(image.name, image: Image(uiImage: image.image)))
                    }
                }
            }
        }
        .task(id: request) { await render(request) }
        .onChange(of: model.shareBookID, initial: true) { _, id in
            guard let id else { return }
            bookID = id
            template = .justFinished
            model.shareBookID = nil
        }
    }

    private var preview: some View {
        let size = aspect.size
        return ZStack {
            if let image {
                Image(uiImage: image.image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("\(image.name) preview")
            } else if hasNoBooks && !model.isLoading {
                ContentUnavailableView(
                    "No Finished Books", systemImage: "books.vertical",
                    description: Text("Books you finish appear here after the Apple TV syncs."))
            } else {
                ProgressView()
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: 380)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var templatePicker: some View {
        HStack(spacing: 6) {
            ForEach(ShareTemplate.allCases) { option in
                let isSelected = option == template
                Button {
                    template = option
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.systemImage)
                            .font(.title3)
                            .frame(height: 28)
                        Text(option.title)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2, reservesSpace: true)
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

    @ViewBuilder
    private func options(years: [Int], shownYear: Int?) -> some View {
        if template == .justFinished {
            let current = bookID ?? model.books.first { $0.finishedYear != nil }?.id
            NavigationLink {
                ShareBookPicker(books: model.books, current: current, selection: $bookID)
            } label: {
                LabeledContent(
                    "Book", value: model.books.first { $0.id == current }?.spineTitle ?? "None")
            }
        } else {
            Picker("Year", selection: Binding(get: { shownYear }, set: { year = $0 })) {
                if template == .spectrum { Text("All time").tag(Int?.none) }
                ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
            }
            .pickerStyle(.menu)
        }
        if template != .spectrum {
            Toggle("Show ratings", isOn: $showsRatings)
            Button("Shuffle", systemImage: "shuffle") { seed = .random(in: 1 ... .max) }
        }
    }

    private func render(_ request: RenderRequest) async {
        // A short pause folds quick option changes into one render.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let books = request.template.books(
            from: model.books, year: request.year, bookID: request.bookID)
        hasNoBooks = books.isEmpty
        guard !books.isEmpty else {
            image = nil
            return
        }
        await model.fonts.load(books.compactMap { model.library?.designs[$0.id] })
        let covers: [Int: UIImage] =
            switch request.template {
            case .justFinished: await loadCovers(books, maximumPixelSize: 1200)
            case .topFive: await loadCovers(books, maximumPixelSize: 900)
            case .yearStack, .spectrum: [:]
            }
        guard !Task.isCancelled else { return }
        let input = ShareInput(
            template: request.template, aspect: request.aspect, books: books,
            looks: Dictionary(books.map { ($0.id, model.look(for: $0)) }) { first, _ in first },
            covers: covers, year: request.year, showsRatings: request.showsRatings,
            seed: request.seed)
        guard let rendered = input.render() else { return }
        var name = request.template.title
        if request.template != .justFinished { name += " " + input.period }
        image = ShareImage(image: rendered, name: name)
        #if DEBUG
            ShareDebug.write(rendered)
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
    var year: Int?
    var bookID: Int?
    var showsRatings: Bool
    var seed: UInt64
    var syncedAt: Date?
    var designCount: Int
    var fontCount: Int
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

/// A searchable list of the library's books for Just Finished.
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
    /// Launching with `-BookwormsShareTemplate <yearStack|justFinished|topFive|spectrum>` opens the
    /// Share tab with that template. `-BookwormsShareAspect <story|portrait|square>`,
    /// `-BookwormsShareYear <year>`, `-BookwormsShareBook <id>`, and `-BookwormsShareSeed <n>` set
    /// its options. Each render is then written to `Library/Caches/Bookworms/share-debug.png`.
    enum ShareDebug {
        @MainActor private static var didOpenTab = false

        @MainActor
        static func openShareTab() {
            guard !didOpenTab else { return }
            didOpenTab = true
            // The tab view is building its tabs now; switch after this update.
            Task { AppModel.shared.selectedTab = .share }
        }

        static func write(_ image: UIImage) {
            guard UserDefaults.standard.string(forKey: "BookwormsShareTemplate") != nil else {
                return
            }
            let url = URL.cachesDirectory.appending(path: "Bookworms/share-debug.png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? image.pngData()?.write(to: url, options: .atomic)
        }
    }
#endif
