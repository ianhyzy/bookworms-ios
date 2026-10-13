import AVKit
import Photos
import SwiftUI
import UIKit
import os

/// Films the pile as a six-second video, then shares the MP4 or saves the clip as a Live Photo.
///
/// The video renders as soon as the sheet opens, with its progress and its latest frame in the
/// preview (see `PileSnapshotRenderer.renderMovie`). Pile images and videos take turns in the
/// order they start. The screen stays awake while the video renders. When the app stops being
/// active, the render stops, since iOS suspends the GPU and the encoder in the background; it
/// starts again when the app is active again, and the seed makes the same clip. Closing the
/// sheet cancels a render in progress, and the video's files are deleted once the sheet is
/// gone. The finished clip loops in the preview, except with Reduce Motion on, when it waits
/// for Play. **Share** offers the MP4 in the share sheet, which reports the result in a toast
/// (`shareSheet(_:onComplete:)`). **Save as Live Photo** asks to add to Photos, then saves the
/// clip's last frame paired with the clip's QuickTime copy, and reports the result in a toast.
struct PileVideoSheet: View {
    let books: [CloudBook]
    let title: String
    let aspect: ShareAspect
    let seed: UInt64

    nonisolated private static let log = Logger(
        subsystem: "gay.ian.Bookworms.iOS", category: "video")

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
    @State private var files: SharedFiles?
    @State private var isSaving = false

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
                if movie != nil {
                    Button("Save as Live Photo", systemImage: "livephoto") {
                        Task { await saveLivePhoto() }
                    }
                    .disabled(isSaving)
                }
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
                        Button("Share", systemImage: "square.and.arrow.up") {
                            files = SharedFiles(urls: [movie.movie])
                        }
                    }
                }
            }
        }
        .shareSheet($files)
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

    private func render() async {
        guard movie == nil, !failed else { return }
        let application = UIApplication.shared
        let wasIdleTimerDisabled = application.isIdleTimerDisabled
        // No one touches the screen while it renders.
        application.isIdleTimerDisabled = true
        defer { application.isIdleTimerDisabled = wasIdleTimerDisabled }
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
            // A frame that fails as the app leaves, after the render was cancelled, is no
            // failure: the render starts again on return.
            guard !Task.isCancelled else { return }
            Self.log.error("The video failed: \(error)")
            failed = true
        }
    }

    /// Saves the clip's QuickTime copy and its last frame to Photos as one Live Photo, with the
    /// app's permission to add photos, and shows the result in a toast.
    private func saveLivePhoto() async {
        guard let movie, let livePhoto = movie.livePhoto else { return }
        isSaving = true
        defer { isSaving = false }
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else {
            model.toasts.show(.failure("Allow Bookworms to add to Photos in Settings"))
            return
        }
        do {
            try await PHPhotoLibrary.shared()
                .performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: movie.still, options: nil)
                    request.addResource(with: .pairedVideo, fileURL: livePhoto, options: nil)
                }
            model.toasts.show(
                Toast(message: "Saved to Photos", systemImage: "checkmark.circle.fill"))
        } catch {
            Self.log.error("The Live Photo could not be saved: \(error)")
            model.toasts.show(.failure("Couldn't save to Photos"))
        }
    }
}

#if DEBUG
    /// Simulator hooks, since a script cannot tap **Video**.
    ///
    /// With `-BookwormsPileShare YES`, `-BookwormsPileVideo YES` also opens the pile's video
    /// sheet, and each finished video is copied to `Library/Caches/Bookworms/pile-video-debug.mp4`,
    /// with its Live Photo copy at `pile-video-debug.mov` and its still at
    /// `pile-video-debug.jpg`.
    enum PileVideoDebug {
        static var opensSheet: Bool { UserDefaults.standard.bool(forKey: "BookwormsPileVideo") }

        static func write(_ movie: PileMovie) {
            guard opensSheet else { return }
            let folder = URL.cachesDirectory.appending(path: "Bookworms")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files =
                [
                    (movie.movie, "pile-video-debug.mp4"), (movie.still, "pile-video-debug.jpg"),
                ] + [movie.livePhoto.map { ($0, "pile-video-debug.mov") }].compactMap(\.self)
            for (source, name) in files {
                let target = folder.appending(path: name)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: source, to: target)
            }
        }
    }
#endif
