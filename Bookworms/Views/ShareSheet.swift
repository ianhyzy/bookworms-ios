import SwiftUI
import UIKit
import os

/// Files to offer in the system share sheet, such as share images or a video.
///
/// File URLs with their usual extensions (`.png`, `.jpg`, `.mov`, `.mp4`) are what Photos,
/// Messages, AirDrop, and social apps' share extensions accept most widely, and they keep each
/// file's name.
struct SharedFiles: Identifiable {
    let id = UUID()
    let urls: [URL]

    /// Writes `images`, each with the credit (`UIImage.withShareCredit()`), as PNG files named
    /// after them, in order. Each call first deletes the files of the previous one, so at most
    /// one share's files stay in the temporary folder.
    ///
    /// - Throws: `CocoaError(.fileWriteUnknown)` when an image cannot be drawn or encoded, and
    ///   any error from writing the files.
    @MainActor
    static func images(_ images: [ShareImage]) async throws -> SharedFiles {
        let credited = try images.map { image in
            guard let credited = image.image.withShareCredit() else {
                throw CocoaError(.fileWriteUnknown)
            }
            return (image: credited, name: image.name)
        }
        return SharedFiles(urls: try await write(credited))
    }

    @concurrent
    nonisolated private static func write(_ images: [(image: UIImage, name: String)]) async throws
        -> [URL]
    {
        let folder = URL.temporaryDirectory.appending(path: "Share")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try images.map { image, name in
            guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            let url = folder.appending(path: name.replacing("/", with: "-") + ".png")
            try data.write(to: url)
            return url
        }
    }
}

/// How a share sheet ended.
enum ShareOutcome: Equatable {
    /// **Save Image** or **Save Video** finished.
    case savedToPhotos
    /// **Copy** finished.
    case copied
    /// Any other activity finished, such as Messages or Instagram.
    case shared
    /// The reader closed the sheet, or backed out of the activity they chose.
    case cancelled
    /// The activity failed; the message says so in a few words.
    case failed(String)

    /// The outcome of `UIActivityViewController`'s completion handler. An error that reports a
    /// cancel counts as a cancel.
    init(activity: UIActivity.ActivityType?, completed: Bool, error: (any Error)?) {
        if let error, (error as? CocoaError)?.code != .userCancelled {
            self = .failed(
                activity == .saveToCameraRoll ? "Couldn't save to Photos" : "Couldn't share")
        } else if !completed {
            self = .cancelled
        } else if activity == .saveToCameraRoll {
            self = .savedToPhotos
        } else if activity == .copyToPasteboard {
            self = .copied
        } else {
            self = .shared
        }
    }

    /// The toast that reports the outcome, or `nil` for a cancel.
    var toast: Toast? {
        switch self {
        case .savedToPhotos: Toast(message: "Saved to Photos", systemImage: "checkmark.circle.fill")
        case .copied: Toast(message: "Copied", systemImage: "checkmark.circle.fill")
        case .shared: Toast(message: "Shared", systemImage: "checkmark.circle.fill")
        case .cancelled: nil
        case .failed(let message): .failure(message)
        }
    }
}

extension View {
    /// Presents the system share sheet for `files` whenever it is set, and sets it back to `nil`
    /// once the sheet closes.
    ///
    /// The outcome shows as a toast (`ShareOutcome.toast`), then goes to `onComplete`. SwiftUI's
    /// `ShareLink` cannot report either, so this presents `UIActivityViewController` from a view
    /// controller behind this view, over any sheet this view is in.
    func shareSheet(
        _ files: Binding<SharedFiles?>,
        onComplete: @escaping @MainActor (ShareOutcome) -> Void = { _ in }
    ) -> some View {
        background(ShareSheetPresenter(files: files, onComplete: onComplete))
    }
}

private struct ShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var files: SharedFiles?
    let onComplete: @MainActor (ShareOutcome) -> Void
    @Environment(AppModel.self) private var model

    private static let log = Logger(subsystem: "gay.ian.Bookworms.iOS", category: "share")

    final class Coordinator {
        /// The files the share sheet last opened with, so an update opens it once for them.
        var presented: SharedFiles.ID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard let files, context.coordinator.presented != files.id else { return }
        context.coordinator.presented = files.id
        let sheet = UIActivityViewController(activityItems: files.urls, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = host.view
        let binding = $files
        let toasts = model.toasts
        let onComplete = onComplete
        sheet.completionWithItemsHandler = { activity, completed, _, error in
            if let error { Self.log.error("Sharing failed: \(error)") }
            let outcome = ShareOutcome(activity: activity, completed: completed, error: error)
            MainActor.assumeIsolated {
                if let toast = outcome.toast { toasts.show(toast) }
                binding.wrappedValue = nil
                onComplete(outcome)
            }
        }
        host.present(sheet, animated: true)
    }
}
