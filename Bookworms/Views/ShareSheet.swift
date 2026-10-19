import SwiftUI
import os

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Files to offer in the system share sheet, such as share images or a video.
///
/// File URLs with their usual extensions (`.png`, `.jpg`, `.mov`, `.mp4`) are what Photos,
/// Messages, AirDrop, and social apps' share extensions accept most widely, and they keep each
/// file's name.
struct SharedFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
    /// Text to send with the files, such as a comparison's invitation or an image's Hardcover
    /// links, which apps that take text, such as Messages, include.
    var text: String?
    /// The files followed by `text`, as the iPhone's share sheet takes them.
    var items: [Any] { urls + (text.map { [$0] } ?? []) }

    /// Writes `images`, each with the credit (`UIImage.withShareCredit()`), as PNG files named
    /// after them, in order, in the temporary folder named `folder`. Each call first deletes the
    /// files that the previous call wrote there, so at most one set of files stays in each
    /// folder.
    ///
    /// - Throws: `CocoaError(.fileWriteUnknown)` when an image cannot be drawn or encoded, and
    ///   any error from writing the files.
    @MainActor
    static func images(_ images: [ShareImage], in folder: String = "Share") async throws
        -> SharedFiles
    {
        let credited = try images.map { image in
            guard let credited = image.image.withShareCredit() else {
                throw CocoaError(.fileWriteUnknown)
            }
            return (image: credited, name: image.name)
        }
        return SharedFiles(urls: try await write(credited, in: folder))
    }

    @concurrent
    nonisolated private static func write(
        _ images: [(image: UIImage, name: String)], in folder: String
    ) async throws -> [URL] {
        let folder = URL.temporaryDirectory.appending(path: folder)
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

    #if os(iOS)
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
    #endif

    /// The toast that reports the outcome, or `nil` for a cancel, and on a Mac for a share,
    /// since the sharing service shows its own progress and result.
    var toast: Toast? {
        switch self {
        case .savedToPhotos: Toast(message: "Saved to Photos", systemImage: "checkmark.circle.fill")
        case .copied: Toast(message: "Copied", systemImage: "checkmark.circle.fill")
        #if os(macOS)
            case .shared: nil
        #else
            case .shared: Toast(message: "Shared", systemImage: "checkmark.circle.fill")
        #endif
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
    ///
    /// On a Mac, the sharing picker drops down from the view this modifies when `fromButton` is
    /// on: attach it to the share button itself. Otherwise it drops from near this view's top
    /// trailing corner, where a toolbar's last button sits. An iPhone's share sheet rises from
    /// the bottom wherever it is attached, so attach it to the content there, outside the
    /// toolbar.
    func shareSheet(
        _ files: Binding<SharedFiles?>, fromButton: Bool = false,
        onComplete: @escaping @MainActor (ShareOutcome) -> Void = { _ in }
    ) -> some View {
        background(
            ShareSheetPresenter(files: files, fromButton: fromButton, onComplete: onComplete))
    }
}

#if os(macOS)
    /// Shows the sharing service picker below the share button whenever `files` is set: below
    /// this view when `fromButton` is on, and else below where a toolbar's last button sits.
    ///
    /// The picker lists only the services that can take every item it holds, and services such
    /// as **Add to Photos** cannot take text. So it holds the files alone, and each service that
    /// can also take `SharedFiles.text` sends the text with them.
    private struct ShareSheetPresenter: NSViewRepresentable {
        @Binding var files: SharedFiles?
        let fromButton: Bool
        let onComplete: @MainActor (ShareOutcome) -> Void
        @Environment(AppModel.self) private var model

        private static let log = Logger(subsystem: "gay.ian.Bookworms.iOS", category: "share")

        @MainActor
        final class Coordinator: NSObject, NSSharingServicePickerDelegate,
            NSSharingServiceDelegate
        {
            /// The files the picker last opened with, so an update opens it once for them.
            var presented: SharedFiles.ID?
            /// The text that services able to take it send with the files.
            var text: String?
            var finish: (ShareOutcome) -> Void = { _ in }

            /// A service that sends the text stands in for the one the picker proposed and has
            /// no delegate: the service it performs reports how the share ended.
            nonisolated func sharingServicePicker(
                _ picker: NSSharingServicePicker, delegateFor service: NSSharingService
            ) -> (any NSSharingServiceDelegate)? { service is TextSharingService ? nil : self }

            /// The services proposed for the files, each that can also take `text` replaced by a
            /// stand-in with its title and image that sends the files and the text.
            nonisolated func sharingServicePicker(
                _ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                proposedSharingServices proposedServices: [NSSharingService]
            ) -> [NSSharingService] {
                guard let text = MainActor.assumeIsolated({ text }) else { return proposedServices }
                let all = items + [text]
                return proposedServices.map { service in
                    guard service.canPerform(withItems: all) else { return service }
                    return TextSharingService(
                        title: service.title, image: service.image,
                        alternateImage: service.alternateImage
                    ) { [weak self] in
                        service.delegate = self
                        service.perform(withItems: all)
                    }
                }
            }

            nonisolated func sharingServicePicker(
                _ picker: NSSharingServicePicker, didChoose service: NSSharingService?
            ) {
                guard service == nil else { return }
                MainActor.assumeIsolated { finish(.cancelled) }
            }

            nonisolated func sharingService(
                _ service: NSSharingService, didShareItems items: [Any]
            ) {
                MainActor.assumeIsolated { finish(.shared) }
            }

            nonisolated func sharingService(
                _ service: NSSharingService, didFailToShareItems items: [Any], error: any Error
            ) {
                Logger(subsystem: "gay.ian.Bookworms.iOS", category: "share")
                    .error("Sharing failed: \(error)")
                let outcome: ShareOutcome =
                    (error as? CocoaError)?.code == .userCancelled
                    ? .cancelled : .failed("Couldn't share")
                MainActor.assumeIsolated { finish(outcome) }
            }
        }

        /// A proposed service's stand-in that sends `SharedFiles.text` with the files.
        private final class TextSharingService: NSSharingService {}

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView { NSView() }

        func updateNSView(_ host: NSView, context: Context) {
            guard let files, context.coordinator.presented != files.id else { return }
            context.coordinator.presented = files.id
            let binding = $files
            let toasts = model.toasts
            let onComplete = onComplete
            context.coordinator.finish = { outcome in
                if let toast = outcome.toast { toasts.show(toast) }
                binding.wrappedValue = nil
                onComplete(outcome)
            }
            context.coordinator.text = files.text
            let picker = NSSharingServicePicker(items: files.urls)
            picker.delegate = context.coordinator
            // Without the button's own frame, the share button sits at the toolbar's trailing
            // end, above this view's top trailing corner, so the picker drops down from there.
            let anchor =
                fromButton
                ? host.bounds
                : CGRect(x: host.bounds.maxX - 44, y: host.bounds.maxY - 2, width: 28, height: 2)
            picker.show(relativeTo: anchor, of: host, preferredEdge: .minY)
        }
    }
#else
    private struct ShareSheetPresenter: UIViewControllerRepresentable {
        @Binding var files: SharedFiles?
        let fromButton: Bool
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
            let sheet = UIActivityViewController(
                activityItems: files.items, applicationActivities: nil)
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
#endif
