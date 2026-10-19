import SwiftUI

/// Why there is no library to show, from the library load and the Hardcover account.
enum LibraryStatus: Equatable {
    /// A load from iCloud or the preview folder is running.
    case loading
    /// The signed-in account's library is downloading.
    case downloading
    /// Signed out, and none of the reader's devices has saved a library to iCloud. `note` is the
    /// error from loading the iCloud library, such as a missing iCloud account.
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
            // The note concerns only the iCloud library, so it must not read as a step that
            // connecting Hardcover also needs.
            [
                "Connect Hardcover to bring in the books you've read. You can also connect it on another of your Apple devices, or turn on iCloud storage in the Bookworms app on your Apple TV.",
                note.map { "iCloud library: \($0)" },
            ]
            .compactMap(\.self).joined(separator: "\n\n")
        case .reconnect(let error):
            error ?? "Hardcover no longer accepts this \(ThisDevice.name)'s login."
        case .failed(let error):
            error ?? "Your Hardcover library isn't on this \(ThisDevice.name) yet."
        }
    }
}

/// The tab an empty state stands in, which sets the scene it draws.
enum EmptyRoom {
    /// An empty bookcase with two brass bookends, which fills with plain books as the first
    /// download arrives.
    case library
    /// The empty desk under the lamp.
    case desk
    /// A blotter with a blank card.
    case share
}

/// The Library, Desk, and Share tabs' content without a library: the tab's empty room, with
/// progress or how to get a library, and **Connect Hardcover**, **Reconnect**, or **Try again**.
///
/// While the first download runs, it shows how many books have arrived, out of how many when
/// Hardcover says (`HardcoverAccount.downloadProgress`).
///
/// The caller presents the account sheet when `showsAccount` is set, from a view that outlives
/// this one, so the sheet stays open when the library arrives.
struct NoLibraryView: View {
    var room = EmptyRoom.library
    @Binding var showsAccount: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = LibraryStatus(model)
        let progress = downloadProgress(status)
        // Scrolls so that at accessibility sizes the actions stay reachable.
        ScrollView {
            ContentUnavailableView {
                VStack(spacing: 20) {
                    RoomScene(room: room, progress: progress)
                    Text(status.title)
                        .font(.title2.weight(.semibold))
                        .bookHeading()
                        .accessibilityAddTraits(.isHeader)
                }
            } description: {
                switch status {
                case .loading:
                    ProgressView()
                case .downloading:
                    DownloadProgressView(progress: progress)
                default:
                    Text(status.message)
                }
            } actions: {
                actions(status)
            }
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }

    /// The first download's progress, or in Debug builds launched with
    /// `-BookwormsLibraryStatus downloading`, a fictional one.
    private func downloadProgress(_ status: LibraryStatus) -> HardcoverAccount.DownloadProgress? {
        guard status == .downloading else { return nil }
        #if DEBUG
            if UserDefaults.standard.string(forKey: "BookwormsLibraryStatus") == "downloading" {
                return .init(books: 200, total: 412)
            }
        #endif
        return model.account.downloadProgress
    }

    @ViewBuilder private func actions(_ status: LibraryStatus) -> some View {
        let tryAgain = Button("Try again") { Task { await model.reload() } }
        switch status {
        case .signedOut:
            // Preview mode ignores the sign-in.
            if !model.isPreview {
                prominent(Button("Connect Hardcover") { showsAccount = true })
            }
            tryAgain
        case .reconnect:
            prominent(
                Button("Reconnect") {
                    model.account.startSignIn()
                    showsAccount = true
                })
        case .failed:
            prominent(tryAgain)
        case .loading, .downloading:
            EmptyView()
        }
    }

    /// The room's main action. Library and Desk tint controls with the lamp's pale light, on
    /// which the style's white label is unreadable, so their buttons take dark ink.
    @ViewBuilder private func prominent(_ button: some View) -> some View {
        let styled = button.buttonStyle(.glassProminent).controlSize(.large)
        if room == .share { styled } else { styled.foregroundStyle(Stationery.ink) }
    }
}

/// An empty room's scene, which VoiceOver skips.
private struct RoomScene: View {
    let room: EmptyRoom
    let progress: HardcoverAccount.DownloadProgress?

    var body: some View {
        switch room {
        case .library: EmptyBookcase(filled: filled)
        case .desk: EmptyDesk()
        case .share: BlankCardOnBlotter()
        }
    }

    /// How full the empty bookcase is: the download's share of the total, or a book for every
    /// page of 100 while the total is unknown.
    private var filled: Double {
        guard let progress else { return 0 }
        if let total = progress.total, total > 0 { return Double(progress.books) / Double(total) }
        return Double(progress.books / 100) / Double(EmptyBookcase.capacity)
    }
}

/// The first download's progress: a bar with "212 of 412 books" once Hardcover gives the total,
/// or a spinner with the count so far.
private struct DownloadProgressView: View {
    let progress: HardcoverAccount.DownloadProgress?

    var body: some View {
        VStack(spacing: 8) {
            if let progress, let total = progress.total, total > 0 {
                ProgressView(value: Double(min(progress.books, total)), total: Double(total))
                    .frame(maxWidth: 240)
            } else {
                ProgressView()
            }
            if let progress {
                Text(progress.description).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Library and Desk tabs' content for a library without read books.
struct NoBooksYetView: View {
    var room = EmptyRoom.library
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 20) {
                RoomScene(room: room, progress: nil)
                Text("No books yet").font(.title2.weight(.semibold)).bookHeading()
            }
        } description: {
            Text(
                model.account.isSignedIn && !model.isPreview
                    ? "Books on your Hardcover shelves appear here after the next sync."
                    : "Books you finish appear here after one of your Apple devices next syncs with Hardcover."
            )
        }
    }
}
