import AVKit
import Photos
import SwiftUI

/// Films the pile as a six-second video, then shares the movie or saves it as a Live Photo.
///
/// The video renders as soon as the sheet opens, with its progress and its latest frame in the
/// preview (see `PileSnapshotRenderer.renderMovie`). It waits for a pile image that is still rendering, and
/// a pile image waits for it. Closing the sheet cancels a render in progress, and the video's
/// files are deleted once the sheet is gone. The finished clip loops in the preview, except with
/// Reduce Motion on, when it waits for Play. **Share** offers the movie file, and **Save as Live
/// Photo** asks to add to Photos, then saves the clip's last frame paired with the clip.
struct PileVideoSheet: View {
    let books: [CloudBook]
    /// The name of the books' time frame, which heads the video.
    let title: String
    let aspect: ShareAspect
    let seed: UInt64

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .navigationTitle("Pile video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if movie == nil && !failed {
                        Button("Cancel", role: .cancel) { dismiss() }
                    } else {
                        Button(role: .close) { dismiss() }
                    }
                }
                if let movie {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(
                            item: movie.movie,
                            preview: SharePreview(
                                movie.name, image: Image(decorative: movie.poster, scale: 1)))
                    }
                }
            }
        }
        .task { await render() }
        // The shelf's dark scheme reaches this content but not the sheet's own background.
        .preferredColorScheme(.dark)
    }

    private var preview: some View {
        ZStack {
            // Fills the video's shape before there is one.
            Rectangle().fill(.quaternary)
            if let movie, let player {
                VideoPlayer(player: player)
                    .accessibilityLabel("\(movie.name) video")
            } else if failed {
                ContentUnavailableView(
                    "Couldn't film the pile", systemImage: "exclamationmark.triangle",
                    description: Text("Close this, then try Shuffle or another size."))
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
                        ProgressView("Dropping books")
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

    @ViewBuilder
    private func saveControls(_ movie: PileMovie) -> some View {
        Button("Save as Live Photo", systemImage: "livephoto") {
            Task { await save(movie) }
        }
        .disabled(saving == .inProgress || saving == .saved)
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
        do {
            let made = try await PileSnapshotRenderer.renderMovie(
                books: books, title: title, aspect: aspect, seed: seed, model: model,
                progress: { progress = $0 }, preview: { frame = $0 })
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
                PileVideoDebug.write(made)
            #endif
        } catch is CancellationError {
            return
        } catch {
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
