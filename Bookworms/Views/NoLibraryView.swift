import SwiftUI

/// Why there is no library to show, from the library load and the Hardcover account.
enum LibraryStatus: Equatable {
    /// A load from iCloud or the preview folder is running.
    case loading
    /// The signed-in account's library is downloading.
    case downloading
    /// Signed out, and the Apple TV has not uploaded a library. `note` is the error from loading
    /// the Apple TV's library, such as a missing iCloud account.
    case signedOut(note: String?)
    /// Hardcover rejected the saved login; `error` says how.
    case reconnect(error: String?)
    /// Signed in, but the library did not download or load.
    case failed(error: String?)

    /// - Parameter isSignedIn: Whether this iPhone's Hardcover sign-in provides the library.
    init(
        isLoading: Bool, isSignedIn: Bool, isSyncing: Bool, needsReconnect: Bool,
        syncError: String?, loadError: String?
    ) {
        if !isSignedIn {
            self = isLoading ? .loading : .signedOut(note: loadError)
        } else if needsReconnect {
            self = .reconnect(error: syncError)
        } else if isLoading || isSyncing {
            self = .downloading
        } else {
            self = .failed(error: syncError ?? loadError)
        }
    }

    /// The model's status. Preview mode ignores the sign-in. Debug builds launched with
    /// `-BookwormsLibraryStatus <signedOut|downloading|failed|reconnect>` show that status, with
    /// a fictional error, for Simulator checks.
    @MainActor init(_ model: AppModel) {
        #if DEBUG
            if let debug = UserDefaults.standard.string(forKey: "BookwormsLibraryStatus") {
                switch debug {
                case "downloading": self = .downloading
                case "failed": self = .failed(error: HardcoverError.http(503).errorDescription)
                case "reconnect":
                    self = .reconnect(error: HardcoverError.invalidToken.errorDescription)
                default: self = .signedOut(note: nil)
                }
                return
            }
        #endif
        let account = model.account
        self.init(
            isLoading: model.isLoading, isSignedIn: account.isSignedIn && !model.isPreview,
            isSyncing: account.isSyncing, needsReconnect: account.needsReconnect,
            syncError: account.syncError, loadError: model.loadError)
    }

    var title: String {
        switch self {
        case .loading: "Loading your library"
        case .downloading: "Downloading your Hardcover library"
        case .signedOut: "No library yet"
        case .reconnect: "Reconnect Hardcover"
        case .failed: "Couldn't download your library"
        }
    }

    /// What to do next, or what went wrong; empty while loading.
    var message: String {
        switch self {
        case .loading, .downloading: ""
        case .signedOut(let note):
            // The note concerns only the Apple TV's library, so it must not read as a step that
            // connecting Hardcover also needs.
            [
                "Connect Hardcover to bring in the books you've read, or turn on iCloud storage in the Bookworms app on your Apple TV.",
                note.map { "Apple TV library: \($0)" },
            ]
            .compactMap(\.self).joined(separator: "\n\n")
        case .reconnect(let error):
            error ?? "Hardcover no longer accepts this \(ThisDevice.name)'s login."
        case .failed(let error):
            error ?? "Your Hardcover library isn't on this \(ThisDevice.name) yet."
        }
    }
}

/// The Library, Desk, and Share tabs' content without a library: progress, or how to get one,
/// with **Connect Hardcover**, **Reconnect**, or **Try again**.
///
/// The caller presents the account sheet when `showsAccount` is set, from a view that outlives
/// this one, so the sheet stays open when the library arrives.
struct NoLibraryView: View {
    @Binding var showsAccount: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = LibraryStatus(model)
        switch status {
        case .loading, .downloading:
            ProgressView(status.title)
        case .signedOut, .reconnect, .failed:
            ContentUnavailableView {
                Label(status.title, systemImage: systemImage(status))
            } description: {
                Text(status.message)
            } actions: {
                actions(status)
            }
        }
    }

    private func systemImage(_ status: LibraryStatus) -> String {
        switch status {
        case .reconnect: "person.crop.circle.badge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        default: "books.vertical"
        }
    }

    @ViewBuilder private func actions(_ status: LibraryStatus) -> some View {
        let tryAgain = Button("Try again") { Task { await model.reload() } }
        switch status {
        case .signedOut:
            // Preview mode ignores the sign-in.
            if !model.isPreview {
                Button("Connect Hardcover") { showsAccount = true }
                    .buttonStyle(.bordered)
            }
            tryAgain
        case .reconnect:
            Button("Reconnect") {
                model.account.startSignIn()
                showsAccount = true
            }
            .buttonStyle(.bordered)
        default:
            tryAgain
        }
    }
}

/// The Library and Desk tabs' content for a library without read books.
struct NoBooksYetView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView(
            "No books yet", systemImage: "books.vertical",
            description: Text(
                model.account.isSignedIn && !model.isPreview
                    ? "Books on your Hardcover shelves appear here after the next sync."
                    : "Books you finish appear here after your Apple TV syncs."))
    }
}
