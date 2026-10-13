import AVKit
import Photos
import SwiftUI
import UIKit
import os

/// Films the pile as a six-second video, then shares the movie or saves it as a Live Photo;
/// or films a run of the dominoes, then shares the movie or its last frame as an image.
///
/// The video renders as soon as the sheet opens, with its progress and its latest frame in the
/// preview (see `PileSnapshotRenderer.renderMovie` and `renderDominoMovie`). Pile images and
/// videos take turns in the order they start. The screen stays awake while the video renders.
/// When the app stops being active, the render stops, since iOS suspends the GPU and the
/// encoder in the background; it starts again when the app is active again, and the seed makes
/// the same clip. Closing the sheet cancels a render in progress, and the video's files are
/// deleted once the sheet is gone. The finished clip loops in the preview, except with Reduce
/// Motion on, when it waits for Play. For the pile, **Share** offers the movie file, and
/// **Save as Live Photo** asks to add to Photos, then saves the clip's last frame paired with
/// the clip. For the dominoes, **Video** and **Image** share the movie file and its last frame.
struct PileVideoSheet: View {
    /// What the sheet films.
    enum Subject {
        /// The pile's books falling into the share image's spread, at `aspect` and `seed`.
        case pile(books: [CloudBook], title: String, aspect: ShareAspect, seed: UInt64)
        /// A run of the dominoes of `books`, as a story-size clip.
        case dominoes(books: [CloudBook], title: String)
    }

    let subject: Subject

    nonisolated private static let log = Logger(
        subsystem: "gay.ian.Bookworms.iOS", category: "video")

    /// Films the pile of `books` under the heading `title`.
    init(books: [CloudBook], title: String, aspect: ShareAspect, seed: UInt64) {
        subject = .pile(books: books, title: title, aspect: aspect, seed: seed)
    }

    /// Films a run of the dominoes of `books` under the heading `title`.
    init(dominoes books: [CloudBook], title: String) {
        subject = .dominoes(books: books, title: title)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// `nil` while the render waits its turn and loads fonts and covers, then the fraction of
    /// frames done.
    @State private var progress: Double?
    /// The latest frame rendered, shown under the progress until the clip is ready.
    @State private var frame: CGImage?
    @State private var movie: PileMovie?
    @State private var failed = false
    @State private var footage = Footage()
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var saving = Saving.idle

    private enum Saving: Equatable {
        case idle, inProgress, saved
        case failed(String)
    }

    /// Owns the video's files, and deletes them when the sheet's state goes away. The sheet's
    /// `onDisappear` cannot tell that from the share sheet covering it.
    private final class Footage {
        var movie: PileMovie?
        deinit { movie?.remove() }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                preview
                if let movie { saveControls(movie) }
            }
            .padding()
            .navigationTitle(isPile ? "Pile video" : "Dominoes video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if movie == nil && !failed {
                        Button("Cancel", role: .cancel) { dismiss() }
                    } else {
                        Button(role: .close) { dismiss() }
                    }
                }
                if let movie, isPile {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(
                            item: movie.movie,
                            preview: SharePreview(
                                movie.name, image: Image(decorative: movie.poster, scale: 1)))
                    }
                }
            }
        }
        // Stops the render when the app stops being active, and starts it again on return; a
        // finished clip stays.
        .task(id: scenePhase == .active) {
            if scenePhase == .active { await render() }
        }
        // Dark from either tab, like Share pile: the clip's heading and table are dark.
        .preferredColorScheme(.dark)
    }

    private var preview: some View {
        ZStack {
            // Fills the video's shape before there is one.
            Rectangle().fill(.quaternary)
            if let player {
                VideoPlayer(player: player)
            } else if failed {
                ContentUnavailableView(
                    isPile ? "Couldn't film the pile" : "Couldn't film the dominoes",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        isPile
                            ? "Close this, then try Shuffle or another size."
                            : "Close this, then try again."
                    ))
            } else {
                if let frame {
                    Image(decorative: frame, scale: 1).resizable()
                }
                Group {
                    if let progress {
                        ProgressView(value: progress) {
                            Text("Filming books")
                        } currentValueLabel: {
                            Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        }
                    } else {
                        ProgressView(isPile ? "Dropping books" : "Standing books up")
                    }
                }
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                .padding()
                // Below the pile once frames show, so the books stay in sight.
                .frame(maxHeight: .infinity, alignment: frame == nil ? .center : .bottom)
            }
        }
        .aspectRatio(aspect.size.width / aspect.size.height, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .frame(maxHeight: .infinity)
    }

    private var isPile: Bool {
        if case .pile = subject { return true }
        return false
    }

    private var aspect: ShareAspect {
        if case .pile(_, _, let aspect, _) = subject { return aspect }
        return .story
    }

    /// The pile's **Save as Live Photo**, or the dominoes' choice of the movie or its last
    /// frame.
    @ViewBuilder
    private func saveControls(_ movie: PileMovie) -> some View {
        if !isPile {
            HStack(spacing: 24) {
                ShareLink(
                    item: movie.movie,
                    preview: SharePreview(
                        movie.name, image: Image(decorative: movie.poster, scale: 1))
                ) {
                    Label("Video", systemImage: "video")
                }
                ShareLink(
                    item: ShareImage(image: UIImage(cgImage: movie.poster), name: movie.name),
                    preview: SharePreview(
                        movie.name, image: Image(decorative: movie.poster, scale: 1))
                ) {
                    Label("Image", systemImage: "photo")
                }
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button("Save as Live Photo", systemImage: "livephoto") {
                Task { await save(movie) }
            }
            .disabled(saving == .inProgress || saving == .saved)
        }
        switch saving {
        case .idle, .inProgress:
            EmptyView()
        case .saved:
            Label("Saved to Photos", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func render() async {
        guard movie == nil, !failed else { return }
        let application = UIApplication.shared
        let wasIdleTimerDisabled = application.isIdleTimerDisabled
        // No one touches the screen while it renders, which takes up to a minute.
        application.isIdleTimerDisabled = true
        defer { application.isIdleTimerDisabled = wasIdleTimerDisabled }
        do {
            let made: PileMovie =
                switch subject {
                case .pile(let books, let title, let aspect, let seed):
                    try await PileSnapshotRenderer.renderMovie(
                        books: books, title: title, aspect: aspect, seed: seed, model: model,
                        progress: { progress = $0 }, preview: { frame = $0 })
                case .dominoes(let books, let title):
                    try await PileSnapshotRenderer.renderDominoMovie(
                        books: books, title: title, model: model, progress: { progress = $0 },
                        preview: { frame = $0 })
                }
            frame = nil
            // A render cancelled after its last check still returns.
            guard !Task.isCancelled else { return made.remove() }
            footage.movie = made
            movie = made
            let player = AVQueuePlayer()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: made.movie))
            self.player = player
            if !reduceMotion { player.play() }
            AccessibilityNotification.Announcement("Video ready").post()
            #if DEBUG
                if isPile { PileVideoDebug.write(made) } else { DominoVideoDebug.write(made) }
            #endif
        } catch is CancellationError {
            return
        } catch {
            // A frame that fails as the app leaves, after the render was cancelled, is no
            // failure: the render starts again on return.
            guard !Task.isCancelled else { return }
            Self.log.error("The video failed: \(error)")
            failed = true
        }
    }

    /// Saves the clip and its last frame to Photos as one Live Photo, with the app's permission
    /// to add photos.
    private func save(_ movie: PileMovie) async {
        saving = .inProgress
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else {
            saving = .failed("To save, allow Bookworms to add to Photos in Settings.")
            return
        }
        do {
            try await PHPhotoLibrary.shared()
                .performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: movie.still, options: nil)
                    request.addResource(with: .pairedVideo, fileURL: movie.movie, options: nil)
                }
            saving = .saved
            AccessibilityNotification.Announcement("Saved to Photos").post()
        } catch {
            saving = .failed("The Live Photo could not be saved.")
        }
    }
}

#if DEBUG
    /// Simulator hooks, since a script cannot tap **Video**.
    ///
    /// With `-BookwormsPileShare YES`, `-BookwormsPileVideo YES` also opens the pile's video
    /// sheet, and each finished video is copied to `Library/Caches/Bookworms/pile-video-debug.mov`
    /// with its still at `pile-video-debug.jpg`.
    enum PileVideoDebug {
        static var opensSheet: Bool { UserDefaults.standard.bool(forKey: "BookwormsPileVideo") }

        static func write(_ movie: PileMovie) {
            guard opensSheet else { return }
            let folder = URL.cachesDirectory.appending(path: "Bookworms")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (source, name) in [
                (movie.movie, "pile-video-debug.mov"), (movie.still, "pile-video-debug.jpg"),
            ] {
                let target = folder.appending(path: name)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: source, to: target)
            }
        }
    }
#endif
