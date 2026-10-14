import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Shares the pile as an image: the pile's books spread front cover up across the table
/// (`PileSpread`) under the name of its time frame, in a share size the reader picks.
///
/// Each size change or shuffle renders a new image and cancels one in progress. A change to the
/// books, such as a library update, draws again once the image in progress, if any, is ready. The previous image stays in view
/// under a progress indicator until the new one is ready, and sharing waits for it. The preview
/// leaves out the credit, which the shared file carries. **Video** films the same books falling
/// into the same spread (`PileVideoSheet`).
struct PileSnapshotSheet: View {
    let books: [CloudBook]
    let title: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var aspect = ShareAspect.story
    @State private var seed: UInt64 = 0
    /// `books` as last passed in, which the render loop reads between renders.
    @State private var latest: [CloudBook]
    @State private var image: ShareImage?
    /// The options of the last finished render, whether it drew `image` or failed.
    @State private var rendered: Options?
    @State private var failed = false
    /// The render loops running. A cancelled loop can finish its frame after its replacement
    /// starts.
    @State private var drawing = 0
    /// Counts book changes that arrived while no loop ran; each starts a loop.
    @State private var redraws = 0
    @State private var filmsPile = false
    /// The files the share sheet offers while it is open.
    @State private var files: SharedFiles?
    /// Whether **Share** is adding the credit and writing the file.
    @State private var isPreparing = false

    private struct Options: Equatable {
        var aspect: ShareAspect
        var seed: UInt64
        /// The books and heading, so a new library never leaves an image of the old one.
        var ids: [Int]
        var title: String

        /// The options without the books, which restart a render in progress when they change.
        var restartKey: Options {
            var key = self
            key.ids = []
            return key
        }
    }

    private struct LoopKey: Equatable {
        var options: Options
        var redraws: Int
    }

    init(books: [CloudBook], title: String) {
        self.books = books
        self.title = title
        _latest = State(initialValue: books)
        #if DEBUG
            if let aspect = UserDefaults.standard.string(forKey: "BookwormsPileShareAspect")
                .flatMap(ShareAspect.init(rawValue:))
            {
                _aspect = State(initialValue: aspect)
            }
            _seed = State(
                initialValue: UInt64(
                    max(0, UserDefaults.standard.integer(forKey: "BookwormsPileShareSeed"))))
        #endif
    }

    var body: some View {
        let options = Options(aspect: aspect, seed: seed, ids: books.map(\.id), title: title)
        let isPending = rendered != options
        NavigationStack {
            VStack(spacing: 20) {
                preview(isPending: isPending)
                Picker("Size", selection: $aspect) {
                    ForEach(ShareAspect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 24) {
                    Button("Shuffle", systemImage: "shuffle") { seed = .random(in: 1 ... .max) }
                    Button("Video", systemImage: "video") { filmsPile = true }
                }
            }
            .padding()
            .navigationTitle("Share desk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                if let image {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Share", systemImage: "square.and.arrow.up") {
                            Task { await share(image) }
                        }
                        .disabled(isPending || isPreparing)
                    }
                }
            }
        }
        .shareSheet($files)
        .task(id: LoopKey(options: options.restartKey, redraws: redraws)) { await render() }
        .sheet(isPresented: $filmsPile) {
            PileVideoSheet(books: latest, title: title, aspect: aspect, seed: seed)
        }
        #if DEBUG
            .task {
                // Lets this sheet finish presenting before it presents another.
                guard PileVideoDebug.opensSheet else { return }
                try? await Task.sleep(for: .seconds(1))
                filmsPile = true
            }
        #endif
        .onChange(of: books.map(\.id)) {
            latest = books
            if drawing == 0 { redraws += 1 }
        }
        // The shelf's dark scheme reaches this content but not the sheet's own background.
        .preferredColorScheme(.dark)
    }

    private func preview(isPending: Bool) -> some View {
        ZStack {
            // Fills the image's shape before there is an image.
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image.image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("\(image.name) preview")
            } else if failed && !isPending {
                ContentUnavailableView(
                    "Couldn't draw the desk", systemImage: "exclamationmark.triangle",
                    description: Text("Try Shuffle or another size."))
            }
            if isPending {
                ProgressView("Dropping books")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .aspectRatio(aspect.size.width / aspect.size.height, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .frame(maxHeight: .infinity)
    }

    /// Opens the share sheet with the image and its credit, which the preview leaves out.
    private func share(_ image: ShareImage) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            files = try await SharedFiles.images([image])
        } catch {
            model.toasts.show(.failure("Couldn't prepare the image"))
        }
    }

    /// Renders until the image shows the latest books.
    private func render() async {
        drawing += 1
        defer { drawing -= 1 }
        while !Task.isCancelled {
            let books = latest
            let options = Options(aspect: aspect, seed: seed, ids: books.map(\.id), title: title)
            guard rendered != options else { return }
            await render(books, options)
        }
    }

    private func render(_ books: [CloudBook], _ options: Options) async {
        do {
            let drawn = try await PileSnapshotRenderer.render(
                books: books, title: options.title, aspect: options.aspect, seed: options.seed,
                model: model)
            // A render cancelled after its last check still returns; a newer one is on its way.
            try Task.checkCancellation()
            image = ShareImage(image: drawn, name: "Desk \(title)")
            failed = false
            #if DEBUG
                PileSnapshotDebug.write(drawn)
                if options.seed < PileSnapshotDebug.lastSeed { seed = options.seed + 1 }
            #endif
        } catch is CancellationError {
            return
        } catch {
            // A blank or failed render must not leave an older image to share.
            image = nil
            failed = true
        }
        rendered = options
    }
}

#if DEBUG
    /// Simulator hooks, since a script cannot tap the share button.
    ///
    /// `-BookwormsPileShare YES` opens the pile's share sheet when the pile appears, and
    /// `-BookwormsPileShareAspect <story|portrait|square>` picks its size. Each image is then
    /// written, with the credit that sharing adds, to
    /// `Library/Caches/Bookworms/pile-share-debug.png`. `-BookwormsPileShareSeed <n>`
    /// sets the first image's seed, and `-BookwormsPileRedrops <n>` renders an image for each
    /// seed after it up to n.
    enum PileSnapshotDebug {
        static var opensSheet: Bool { UserDefaults.standard.bool(forKey: "BookwormsPileShare") }
        static var lastSeed: UInt64 {
            UInt64(max(0, UserDefaults.standard.integer(forKey: "BookwormsPileRedrops")))
        }

        @MainActor static func write(_ image: UIImage) {
            guard opensSheet else { return }
            let url = URL.cachesDirectory.appending(path: "Bookworms/pile-share-debug.png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? image.withShareCredit()?.pngData()?.write(to: url, options: .atomic)
        }
    }
#endif
