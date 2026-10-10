import SwiftUI

/// The library as a 3D carousel of spines, with a caption for the centered book, or as a pile of
/// books on a table (`BookPileView`).
///
/// Both show the library snapshot that `AppModel` holds; sorting and filtering happen here when
/// the snapshot or the options change, never while scrolling.
struct ShelfView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("BookwormsShelfMode") private var mode = ShelfPresentation.stack
    @AppStorage("BookwormsShelfSort") private var sort = ShelfSort.finished
    @AppStorage("BookwormsShelfDesignedOnly") private var designedOnly = false
    /// The centered book, shared by both carousel modes so switching keeps the reader's place.
    @State private var centeredID: Int?
    @State private var path: [Int] = []
    @Namespace private var namespace

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { ShelfPalette.wall.ignoresSafeArea() }
                .navigationTitle("Shelf")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .navigationDestination(for: Int.self) { id in
                    if let book = model.books.first(where: { $0.id == id }) {
                        BookDetailView(book: book)
                            .navigationTransition(.zoom(sourceID: id, in: namespace))
                    } else {
                        ContentUnavailableView(
                            "Book unavailable", systemImage: "book.closed",
                            description: Text("The latest library no longer includes this book."))
                    }
                }
        }
        // The walnut backdrop is dark in both appearances, so text and bars use dark styles.
        .environment(\.colorScheme, .dark)
        .tint(ShelfPalette.lamp)
        .onChange(of: sort) { recenter() }
        .onChange(of: designedOnly) { recenter() }
        #if DEBUG
            .onChange(of: model.books.count, initial: true) { applyDebugArguments() }
        #endif
    }

    @ViewBuilder private var content: some View {
        if let library = model.library {
            let books = shownBooks(in: library)
            if library.books.isEmpty {
                ContentUnavailableView(
                    "No books yet", systemImage: "books.vertical",
                    description: Text("Books you finish appear here after your Apple TV syncs."))
            } else if books.isEmpty {
                ContentUnavailableView {
                    Label("No designed spines yet", systemImage: "wand.and.sparkles")
                } description: {
                    Text("Spines appear here once they are designed.")
                } actions: {
                    Button("Show all books") { designedOnly = false }
                }
            } else if let carousel = mode.carousel {
                VStack(spacing: 0) {
                    SpineCarousel(
                        books: books, mode: carousel, centeredID: $centeredID, namespace: namespace
                    ) { path.append($0.id) }
                    ShelfCaption(books: books, designs: library.designs, centeredID: $centeredID)
                        // Larger sizes overflow the caption's fixed height; the book's details
                        // show the same record at any size.
                        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                }
            } else {
                BookPileView(books: books) { path.append($0.id) }
            }
        } else if model.isLoading {
            ProgressView("Loading your library")
        } else {
            ContentUnavailableView {
                Label("Waiting for your Apple TV library", systemImage: "appletv")
            } description: {
                Text(
                    [
                        "The Bookworms app on your Apple TV uploads your library when iCloud storage is on.",
                        model.loadError,
                    ]
                    .compactMap(\.self).joined(separator: " "))
            } actions: {
                Button("Try again") { Task { await model.reload() } }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Presentation", selection: $mode) {
                ForEach(ShelfPresentation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("Sort and filter", systemImage: "line.3.horizontal.decrease") {
                Picker("Sort by", selection: $sort) {
                    ForEach(ShelfSort.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Designed only", isOn: $designedOnly)
            }
        }
    }

    private func shownBooks(in library: LibrarySnapshot) -> [CloudBook] {
        let books = sort.sorted(model.books)
        return designedOnly ? books.filter { library.designs[$0.id] != nil } : books
    }

    /// Returns to the first book after the order or filter changes.
    private func recenter() {
        guard let library = model.library else { return }
        centeredID = shownBooks(in: library).first?.id
    }

    #if DEBUG
        /// Simulator screenshot hooks, read once the library loads:
        /// `-BookwormsShelfScrollTo <index>` centers the book at that index, and
        /// `-BookwormsOpenBook <bookID>` opens that book's details.
        private func applyDebugArguments() {
            guard let library = model.library else { return }
            let books = shownBooks(in: library)
            let defaults = UserDefaults.standard
            if let index = defaults.string(forKey: "BookwormsShelfScrollTo").flatMap(Int.init),
                books.indices.contains(index)
            {
                centeredID = books[index].id
            }
            if let id = defaults.string(forKey: "BookwormsOpenBook").flatMap(Int.init),
                path.isEmpty
            {
                centeredID = id
                path = [id]
            }
        }
    #endif
}

/// The centered book's title, author, reading record, and design provenance.
///
/// Reads `centeredID` itself, so a new centered book updates only this caption. The caption
/// keeps a fixed, Dynamic Type–scaled height so the carousel above it never resizes mid-scroll.
private struct ShelfCaption: View {
    let books: [CloudBook]
    let designs: [Int: SpineDesignV1]
    @Binding var centeredID: Int?
    @ScaledMetric(relativeTo: .title3) private var height: CGFloat = 150
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let index = books.firstIndex { $0.id == centeredID } ?? 0
        let book = books[index]
        VStack(spacing: 5) {
            // The position is decorative, so accessibility sizes give its line to the title.
            if !typeSize.isAccessibilitySize {
                Text("\(index + 1) of \(books.count)")
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(book.title)
                .font(.title3.weight(.semibold))
                .fontDesign(.serif)
                .lineLimit(2)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Text(book.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            let finished = book.finishedDate.map {
                Text("Finished \($0, format: ShelfLabels.finishedFormat)")
            }
            let stars = book.rating.flatMap { $0 > 0 ? RatingStars(rating: $0) : nil }
            // Stacks the date over the stars when large text leaves no room for both.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    finished
                    stars
                }
                VStack(spacing: 4) {
                    finished
                    stars
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Label(
                ShelfLabels.provenance(of: designs[book.id]),
                systemImage: designs[book.id] == nil ? "circle.dashed" : "sparkles"
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.8)
        .foregroundStyle(ShelfPalette.paper)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// A 0...5 rating in half steps, drawn as five stars.
struct RatingStars: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: ShareStars.symbol(rating: rating, index: index))
            }
        }
        .foregroundStyle(ShelfPalette.gold)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating.formatted()) out of 5")
    }
}

/// The shelf's walnut palette, from the Apple TV's dark wood shelf.
enum ShelfPalette {
    static let wall = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.145, blue: 0.105),
            Color(red: 0.11, green: 0.078, blue: 0.055),
        ], startPoint: .top, endPoint: .bottom)
    static let board = Color(red: 0.32, green: 0.21, blue: 0.135)
    static let lamp = Color(red: 1, green: 0.8, blue: 0.56)
    static let paper = Color(red: 0.95, green: 0.9, blue: 0.82)
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.36)
}

/// The shelf's presentations: the carousel's two modes and the physics pile. The raw values
/// match `ShelfMode`, so a saved carousel mode carries over.
enum ShelfPresentation: String, CaseIterable, Identifiable {
    case stack, shelf, pile

    var id: Self { self }
    /// The carousel mode, or `nil` for the pile.
    var carousel: ShelfMode? { ShelfMode(rawValue: rawValue) }
    var title: String { carousel?.title ?? "Pile" }
}

/// How the shelf orders books.
enum ShelfSort: String, CaseIterable, Identifiable {
    case finished, title, author, rating

    var id: Self { self }

    var title: String {
        switch self {
        case .finished: "Recently finished"
        case .title: "Title"
        case .author: "Author"
        case .rating: "Your rating"
        }
    }

    /// Orders `books`, which arrive most recently finished first. The sort is stable, so ties
    /// keep that order; unrated books follow rated ones.
    func sorted(_ books: [CloudBook]) -> [CloudBook] {
        switch self {
        case .finished: books
        case .title:
            books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            books.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        case .rating: books.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        }
    }
}

/// Display text for book and design fields.
enum ShelfLabels {
    /// Finish dates are calendar days stored at noon UTC, so they format in UTC to keep the day.
    static let finishedFormat = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)

    /// Where a spine design came from, by its generator version.
    static func provenance(of design: SpineDesignV1?) -> String {
        guard let design else { return "Not designed yet" }
        if design.generatorVersion == CloudContract.generatorVersion {
            return "Designed with Private Cloud Compute"
        }
        return design.generatorVersion.hasPrefix("mac-") ? "Designed on Mac" : "Designed"
    }

    /// The reading format as the Apple TV labels it, such as "Audiobook" for "Listened".
    static func format(_ format: String?) -> String? {
        switch format?.lowercased() {
        case nil: nil
        case "read", "physical": "Physical"
        case "listened", "audio", "audiobook": "Audiobook"
        case "ebook", "e-book", "digital": "Ebook"
        case "both": "Physical & audiobook"
        default: format
        }
    }
}
