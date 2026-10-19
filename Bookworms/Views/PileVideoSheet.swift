import AVKit
import Photos
import SwiftUI
import UniformTypeIdentifiers
import os

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Films the pile as a six-second video, then shares the MP4, saves it to a file on a Mac, or
/// saves the clip as a Live Photo.
///
/// **Share desk** pushes it in its own navigation stack, so only one sheet ever shows; the Share
/// tab's Desk template presents it in a sheet of its own, with `showsClose` on.
///
/// The video renders as soon as the sheet opens, with its progress and its latest frame in the
/// preview (see `PileSnapshotRenderer.renderMovie`). Pile images and videos take turns in the
/// order they start. The screen stays awake while the video renders. When the app stops being
/// active, the render stops, since iOS suspends the GPU and the encoder in the background; it
/// starts again when the app is active again, and the seed makes the same clip. Closing the
/// sheet cancels a render in progress, and the video's files are deleted once the sheet is
/// gone. The finished clip loops in the preview, except with Reduce Motion on, when it waits
/// for **Play**; a tap pauses or plays it. The preview leaves out the credit at the clip's
/// bottom edge, which the shared MP4 and the Live Photo carry. **Share** offers the MP4 in the
/// share sheet, which reports the result in a toast (`shareSheet(_:onComplete:)`). **Save as
/// Live Photo** asks to add to Photos, then saves the clip's last frame paired with the clip's
/// QuickTime copy; once saved, the button says so. On an iPhone, a toast reports the result.
///
/// On a Mac, **Save Video…** saves the MP4 where the reader chooses, Space plays and pauses the
/// clip, and failures show in an alert in the sheet, since the main window's toasts sit behind
/// it.
struct PileVideoSheet: View {
    let books: [CloudBook]
    let title: String
    let aspect: ShareAspect
    let seed: UInt64
    /// Whether the view is a sheet's root, which closes with **Cancel** or the close button,
    /// rather than pushed, which goes back with the back button.
    var showsClose = false

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
    @State private var isPlaying = false
    @State private var looper: AVPlayerLooper?
    @State private var files: SharedFiles?
    @State private var isSaving = false
    /// Whether **Save as Live Photo** has saved this clip.
    @State private var savedLivePhoto = false
    #if os(macOS)
        @State private var savesVideo = false
        /// A failure to show in the sheet's alert.
        @State private var failure: String?
    #endif

    /// Owns the video's files, and deletes them when the sheet's state goes away. The sheet's
    /// `onDisappear` cannot tell that from the share sheet covering it.
    private final class Footage {
        var movie: PileMovie?
        deinit { movie?.remove() }
    }

    var body: some View {
        VStack(spacing: 20) {
            preview
            if let movie { actions(movie) }
        }
        .padding()
        .navigationTitle("Desk video")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsClose {
                ToolbarItem(placement: .cancellationAction) {
                    if movie == nil && !failed {
                        Button("Cancel", role: .cancel) { dismiss() }
                    } else {
                        Button(role: .close) { dismiss() }
                    }
                }
            }
            if let movie {
                ToolbarItem(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        files = SharedFiles(urls: [movie.movie])
                    }
                    #if os(macOS)
                        .shareSheet($files, fromButton: true)
                    #endif
                }
            }
        }
        #if os(iOS)
            .shareSheet($files)
        #endif
        #if os(macOS)
            .fileExporter(
                isPresented: $savesVideo, item: movie.map { MovieFile(url: $0.movie) },
                contentTypes: [.mpeg4Movie], defaultFilename: movie?.name
            ) { result in
                if case .failure(let error) = result {
                    Self.log.error("The video could not be saved: \(error)")
                    failure = "Couldn't save the video."
                }
            }
            .alert(
                failure ?? "",
                isPresented: Binding {
                    failure != nil
                } set: { _ in
                    failure = nil
                }
            ) {}
        #endif
        // Stops the render when the app stops being active, and starts it again on return; a
        // finished clip stays.
        .task(id: scenePhase == .active) {
            if scenePhase == .active { await render() }
        }
        // Dark from either tab, like Share desk: the clip's heading and table are dark.
        .preferredColorScheme(.dark)
    }

    /// The clip, or its latest frame and progress while it renders. The frames end in the
    /// credit, which the app leaves out: the preview is `ShareCredit.height` shorter than the
    /// clip at the bottom, and as much at the top, above the heading, and fills its width, so
    /// the credit falls outside it. The clip has no system controls, whose full-screen view
    /// would show the whole frame: a tap pauses or plays it, and **Play** shows while it is
    /// paused.
    private var preview: some View {
        ZStack {
            // Fills the video's shape before there is one.
            Rectangle().fill(.quaternary)
            Color.clear.overlay {
                if let player {
                    FilledPlayer(player: player)
                        .onTapGesture { play(!isPlaying) }
                        .accessibilityElement()
                        .accessibilityLabel("Video preview")
                        .accessibilityAction(named: isPlaying ? "Pause" : "Play") {
                            play(!isPlaying)
                        }
                } else if let frame, !failed {
                    Image(decorative: frame, scale: 1).resizable().scaledToFill()
                }
            }
            if player != nil, !isPlaying {
                Button("Play", systemImage: "play.fill") { play(true) }
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
            }
            if failed {
                ContentUnavailableView(
                    "Couldn't film the desk", systemImage: "exclamationmark.triangle",
                    description: Text("Close this, then try Shuffle or another size."))
            } else if player == nil {
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
        .aspectRatio(
            aspect.size.width / (aspect.size.height - 2 * ShareCredit.height), contentMode: .fit
        )
        .clipShape(.rect(cornerRadius: 12))
        .frame(maxHeight: .infinity)
    }

    private func render() async {
        guard movie == nil, !failed else { return }
        // No one touches the screen or keyboard while it renders.
        #if os(macOS)
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Rendering a video")
            defer { ProcessInfo.processInfo.endActivity(activity) }
        #else
            let application = UIApplication.shared
            let wasIdleTimerDisabled = application.isIdleTimerDisabled
            application.isIdleTimerDisabled = true
            defer { application.isIdleTimerDisabled = wasIdleTimerDisabled }
        #endif
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
            play(!reduceMotion)
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

    /// What to do with the finished clip: on a Mac, play or pause it (Space) and save it as a
    /// file or a Live Photo; on an iPhone, whose share sheet saves the video, save it as a Live
    /// Photo.
    @ViewBuilder
    private func actions(_ movie: PileMovie) -> some View {
        let livePhoto = Button(
            savedLivePhoto ? "Saved to Photos" : "Save as Live Photo",
            systemImage: savedLivePhoto ? "checkmark.circle" : "livephoto"
        ) {
            Task { await saveLivePhoto() }
        }
        .disabled(isSaving || savedLivePhoto)
        #if os(macOS)
            HStack(spacing: 12) {
                Button(
                    isPlaying ? "Pause" : "Play",
                    systemImage: isPlaying ? "pause.fill" : "play.fill"
                ) {
                    play(!isPlaying)
                }
                .keyboardShortcut(.space, modifiers: [])
                Spacer()
                livePhoto
                Button("Save Video…") { savesVideo = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        #else
            livePhoto
        #endif
    }

    /// Plays or pauses the clip.
    private func play(_ plays: Bool) {
        isPlaying = plays
        if plays { player?.play() } else { player?.pause() }
    }

    /// Saves the clip's QuickTime copy and its last frame to Photos as one Live Photo, with the
    /// app's permission to add photos, and reports the result.
    private func saveLivePhoto() async {
        guard let movie, let livePhoto = movie.livePhoto else { return }
        isSaving = true
        defer { isSaving = false }
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else {
            #if os(macOS)
                failure =
                    "Allow Bookworms in System Settings > Privacy & Security > Photos."
            #else
                model.toasts.show(.failure("Allow Bookworms to add to Photos in Settings"))
            #endif
            return
        }
        do {
            try await PHPhotoLibrary.shared()
                .performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: movie.still, options: nil)
                    request.addResource(with: .pairedVideo, fileURL: livePhoto, options: nil)
                }
            savedLivePhoto = true
            #if os(iOS)
                model.toasts.show(
                    Toast(message: "Saved to Photos", systemImage: "checkmark.circle.fill"))
            #endif
        } catch {
            Self.log.error("The Live Photo could not be saved: \(error)")
            #if os(macOS)
                failure = "Couldn't save to Photos."
            #else
                model.toasts.show(.failure("Couldn't save to Photos"))
            #endif
        }
    }
}

#if os(macOS)
    /// The clip's MP4, which **Save Video…** copies where the reader chooses.
    private struct MovieFile: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(exportedContentType: .mpeg4Movie) { SentTransferredFile($0.url) }
        }
    }
#endif

/// A player layer whose video fills its view, cropping the video's edges, which SwiftUI's
/// `VideoPlayer` cannot do.
#if os(macOS)
    private struct FilledPlayer: NSViewRepresentable {
        let player: AVPlayer

        final class PlayerView: NSView {
            let playerLayer = AVPlayerLayer()

            override func makeBackingLayer() -> CALayer { playerLayer }
        }

        func makeNSView(context: Context) -> PlayerView {
            let view = PlayerView()
            view.wantsLayer = true
            view.playerLayer.videoGravity = .resizeAspectFill
            view.playerLayer.player = player
            return view
        }

        func updateNSView(_ view: PlayerView, context: Context) {
            view.playerLayer.player = player
        }
    }
#else
    private struct FilledPlayer: UIViewRepresentable {
        let player: AVPlayer

        final class PlayerView: UIView {
            override static var layerClass: AnyClass { AVPlayerLayer.self }
            var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        }

        func makeUIView(context: Context) -> PlayerView {
            let view = PlayerView()
            view.playerLayer.videoGravity = .resizeAspectFill
            view.playerLayer.player = player
            return view
        }

        func updateUIView(_ view: PlayerView, context: Context) {
            view.playerLayer.player = player
        }
    }
#endif

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
