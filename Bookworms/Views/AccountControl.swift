import SwiftUI

/// What the app says about this device's Hardcover sign-in, in the iPhone's Spines toolbar and
/// the Mac's sidebar (`SidebarAccount`), so a device that doesn't sync with Hardcover says so:
/// the library it shows, from iCloud or an older download, otherwise looks the same as a
/// syncing one.
enum AccountControl: Equatable {
    /// No Hardcover sign-in on this device: **Connect Hardcover**.
    case connect
    /// Hardcover rejected the saved login, so only a new sign-in syncs again: **Reconnect
    /// Hardcover**.
    case reconnect
    /// A sign-in that Hardcover accepts, or preview mode, which ignores the sign-in. While
    /// `needsAttention`, the iPhone's gear carries a badge and the Mac's account row a mark.
    case account(needsAttention: Bool)

    /// - Parameter hasProblem: Whether the account sheet shows a problem other than a rejected
    ///   login: the library failed to download or load, also while an older copy shows, or it
    ///   shows without iCloud. A failed download, as offline or while Hardcover is down, keeps
    ///   the sign-in, so it needs attention and prompts no sign-in.
    init(isPreview: Bool, isSignedIn: Bool, needsReconnect: Bool, hasProblem: Bool) {
        if isPreview {
            self = .account(needsAttention: hasProblem)
        } else if !isSignedIn {
            self = .connect
        } else if needsReconnect {
            self = .reconnect
        } else {
            self = .account(needsAttention: hasProblem)
        }
    }

    /// The model's control. Debug builds show the control for `LibraryStatus.launchArgument`'s
    /// status when it names one, over a preview library too.
    @MainActor init(_ model: AppModel) {
        #if DEBUG
            if let status = LibraryStatus.launchArgument {
                self =
                    switch status {
                    case .signedOut: .connect
                    case .reconnect: .reconnect
                    case .failed: .account(needsAttention: true)
                    case .loading, .downloading: .account(needsAttention: false)
                    }
                return
            }
        #endif
        let account = model.account
        self.init(
            isPreview: model.isPreview, isSignedIn: account.isSignedIn,
            needsReconnect: account.needsReconnect,
            hasProblem: account.syncError != nil || model.loadError != nil
                || (account.isSignedIn && model.iCloudIssue != nil))
    }

    /// Shows the Hardcover sheet through `present`. A rejected login starts a new sign-in first,
    /// so the sheet opens on its code.
    @MainActor func open(_ account: HardcoverAccount, present: () -> Void) {
        if self == .reconnect { account.startSignIn() }
        present()
    }

    /// Whether the control asks for a sign-in: in words in the iPhone's toolbar, and in the
    /// tooltip of the Mac's account row.
    var isPrompt: Bool { self == .connect || self == .reconnect }

    /// Whether the iPhone's gear carries a badge. A prompt needs none: its words say more.
    var needsAttention: Bool { self == .account(needsAttention: true) }

    /// What VoiceOver says of the red mark on the Mac's account row, or `nil` when the row
    /// carries none. A rejected login carries it too: the row keeps the reader's name, so the
    /// mark is its only sign.
    var mark: String? {
        switch self {
        case .reconnect: "Needs reconnecting"
        case .account(needsAttention: true): "Needs attention"
        case .connect, .account: nil
        }
    }

    /// The control's words, which VoiceOver reads and a prompt shows.
    var title: String {
        switch self {
        case .connect: "Connect Hardcover"
        case .reconnect: "Reconnect Hardcover"
        case .account: "Hardcover account"
        }
    }

    /// The words beside the photo in the Mac's sidebar: the prompt on a device without a
    /// sign-in, else the reader's `username`, else the control's title.
    func label(username: String?) -> String {
        self == .connect ? title : username ?? title
    }
}

/// What the bar above Share, Library, and Desk says about the Hardcover account, so those tabs
/// say when the books on screen aren't the reader's synced library. The Spines tab needs no
/// bar: the example profile hides that tab, and the iPhone's toolbar there says **Reconnect
/// Hardcover** (`AccountControl`).
enum AccountBanner: Equatable {
    /// The example profile shows in place of a library.
    case example
    /// Hardcover rejected the saved login, so the library on screen no longer syncs.
    case reconnect

    init?(isExample: Bool, control: AccountControl) {
        if isExample {
            self = .example
            return
        }
        // The Mac's sidebar shows a rejected login in every section (`SidebarAccount`).
        #if os(iOS)
            if control == .reconnect {
                self = .reconnect
                return
            }
        #endif
        return nil
    }

    var title: String {
        switch self {
        case .example: "Example profile"
        case .reconnect: "Not syncing"
        }
    }

    /// The control whose words the bar's button shows and whose sheet it opens.
    var control: AccountControl {
        switch self {
        case .example: .connect
        case .reconnect: .reconnect
        }
    }
}

#if os(macOS)
    /// The Mac sidebar's header: the reader's Hardcover photo and username above the sections,
    /// as the Apple TV's sidebar shows them, so the account is on screen in every section.
    /// Selecting it shows the Hardcover sheet (`AccountControl.open(_:present:)`).
    ///
    /// Without a sign-in it reads **Connect Hardcover**. A rejected login, or another problem
    /// that the sheet explains, puts a mark on the photo. The photo shows once the Share
    /// section's friends list has loaded the reader's profile.
    struct SidebarAccount: View {
        @Binding var showsAccount: Bool
        @Environment(AppModel.self) private var model

        var body: some View {
            let control = AccountControl(model)
            let name = control.label(username: username)
            Button {
                control.open(model.account) { showsAccount = true }
            } label: {
                HStack(spacing: 8) {
                    photo(control)
                    // The sidebar opens narrow, so **Connect Hardcover** and a long username
                    // take two lines before they shrink or truncate.
                    Text(name)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(control.isPrompt ? control.title : "Show your Hardcover account")
            .accessibilityLabel(name)
            .accessibilityValue(control.mark ?? "")
        }

        /// The signed-in reader's username. Debug builds launched with
        /// `-BookwormsAccountName <name>` show that name, for checks with a preview library,
        /// which has no sign-in.
        private var username: String? {
            #if DEBUG
                if let name = UserDefaults.standard.string(forKey: "BookwormsAccountName") {
                    return name
                }
            #endif
            return model.account.summary?.username
        }

        private func photo(_ control: AccountControl) -> some View {
            Group {
                if control != .connect, let owner = model.social.owner {
                    ReaderAvatarView(profile: owner, size: 24)
                } else {
                    Image(
                        systemName: control == .connect
                            ? "person.crop.circle.badge.plus" : "person.crop.circle.fill"
                    )
                    .font(.system(size: 20))
                    .frame(width: 24, height: 24)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if control.mark != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .font(.system(size: 12))
                        .offset(x: 4, y: 4)
                        .accessibilityHidden(true)
                }
            }
        }
    }
#endif
