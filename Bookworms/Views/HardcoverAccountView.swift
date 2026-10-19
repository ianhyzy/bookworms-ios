import SwiftUI

#if os(iOS)
    import SafariServices
#endif
#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The Hardcover account sheet: `HardcoverAccountForm` with **Not now** while signed out, and
/// **Done** once signed in or while a sign-in runs.
///
/// Signed out, **Not now** is the cancel action (Escape on the Mac), and **Connect Hardcover** in
/// the form is the default action (Return).
struct HardcoverAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let account = model.account
        NavigationStack {
            HardcoverAccountForm()
                .navigationTitle("Hardcover")
                .navigationBarTitleDisplayMode(.inline)
                #if os(macOS)
                    .frame(minWidth: 480, minHeight: 440)
                #endif
                .toolbar {
                    if account.isSignedIn || account.signIn != nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    } else {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Not now") { dismiss() }
                        }
                    }
                }
        }
        #if DEBUG
            // `-BookwormsStubSignIn YES` shows the code step with a fictional code.
            .task {
                if UserDefaults.standard.bool(forKey: "BookwormsStubSignIn"),
                    account.signIn == nil, !account.isSignedIn
                {
                    account.startSignIn()
                }
            }
        #endif
    }
}

/// The Hardcover account: why to connect, the device-code sign-in on a library card, and the
/// signed-in account's bookplate with **Sync now** and **Sign out**. It shows when the library
/// last synced, from Hardcover or, without a sign-in, from iCloud. The account sheet and the
/// Mac's **Settings > Hardcover** show it.
///
/// Hardcover's approval page opens in Safari over this form, with the code already copied, and
/// closes when polling sees the approval. The device flow has no redirect back to the app, which is
/// what `ASWebAuthenticationSession` waits for.
struct HardcoverAccountForm: View {
    @Environment(AppModel.self) private var model
    @State private var copiedCode = false
    @State private var confirmsSignOut = false
    @State private var showsApprovalPage = false
    @Environment(\.openURL) private var openURL

    private var account: HardcoverAccount { model.account }

    var body: some View {
        Form {
            if let signIn = account.signIn {
                signInSections(signIn)
            } else if account.isSignedIn {
                signedIn
            } else {
                signedOut
            }
            // Preview mode ignores the sign-in. The library without a sign-in stays visible
            // while a sign-in is in progress, until it finishes.
            if model.isPreview || !account.isSignedIn {
                libraryWithoutSignIn
            }
        }
        #if os(macOS)
            // A Mac sheet or Settings pane is a window of its own, outside the main window's
            // grouped style.
            .formStyle(.grouped)
            // The Mac opens the page in the default browser.
            .onChange(of: showsApprovalPage) { _, shows in
                guard shows else { return }
                showsApprovalPage = false
                if case .waiting(_, let url) = account.signIn { openURL(url) }
            }
        #else
            .sheet(isPresented: $showsApprovalPage) {
                if case .waiting(_, let url) = account.signIn {
                    ApprovalPage(url: url).ignoresSafeArea()
                }
            }
        #endif
        .onChange(of: account.signIn) {
            copiedCode = false
            // The page has done its job once the code is approved, cancelled, or expired.
            showsApprovalPage = false
        }
    }

    @ViewBuilder private var signedOut: some View {
        Section {
            VStack(spacing: 12) {
                Image("account.bookworms")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Bring in your reading")
                    .font(.title2.weight(.semibold))
                    .bookHeading()
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Bookworms designs a cloth spine for every book you read, and sets your books on a shelf, on a desk, and in images to share."
                )
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
        Section {
            reason(
                "Your reading history",
                "Every book on your Hardcover shelves, with the dates you finished and your ratings.",
                systemImage: "books.vertical")
            reason(
                "Bring your reviews", "Bookworms gets the reviews you wrote along with your books.",
                systemImage: "text.quote")
            reason(
                "Read-only",
                "Bookworms reads your library and never changes anything on Hardcover.",
                systemImage: "lock")
        } footer: {
            Text(
                "Without a Hardcover sign-in, Bookworms shows the library your Apple devices save to iCloud."
            )
        }
        Section {
            Button {
                account.startSignIn()
            } label: {
                Text("Connect Hardcover").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            Text(
                "Your Hardcover login stays in this \(ThisDevice.name)'s keychain. Bookworms sends it only to Hardcover and never syncs it."
            )
        }
    }

    /// The library shown without a Hardcover sign-in: the one in iCloud, or in preview mode the
    /// local folder. Load errors show even while an older copy shows.
    private var libraryWithoutSignIn: some View {
        Section {
            if let library = model.library {
                LabeledContent(
                    "Last synced",
                    value: library.syncedAt.formatted(.relative(presentation: .named)))
            } else if model.loadError == nil, !model.isPreview {
                Text("No library in iCloud yet.")
            }
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(model.isPreview ? "Preview library" : "iCloud library")
        } footer: {
            if model.isPreview {
                Text("Preview mode reads a local library. Designs stay on this \(ThisDevice.name).")
            }
        }
    }

    /// A reason to connect, its symbol in a fixed column so every reason's text lines up.
    private func reason(_ title: String, _ detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage).frame(width: 28)
        }
    }

    @ViewBuilder private func signInSections(_ signIn: HardcoverAccount.SignIn) -> some View {
        switch signIn {
        case .requestingCode:
            Section { LabeledContent("Getting a code") { ProgressView() } }
        case .waiting(let code, _):
            Section {
                LibraryCard(code: code)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    // Room for the card's shadow, which the row would clip.
                    .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 24, trailing: 0))
                VStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = code
                        copiedCode = true
                    } label: {
                        Label(
                            copiedCode ? "Copied" : "Copy code",
                            systemImage: copiedCode ? "checkmark" : "doc.on.doc"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    Button {
                        UIPasteboard.general.string = code
                        copiedCode = true
                        showsApprovalPage = true
                    } label: {
                        Label("Open Hardcover", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(
                    "Sign in to Hardcover if it asks, enter the code, and allow Bookworms to read your library. This screen updates once you approve."
                )
            }
            Section {
                LabeledContent("Waiting for approval") { ProgressView() }
                Button("Cancel", role: .cancel) { account.cancelSignIn() }
            }
        case .connecting:
            Section { LabeledContent("Checking your account") { ProgressView() } }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                Button("Get a new code") { account.startSignIn() }
                Button("Cancel", role: .cancel) { account.cancelSignIn() }
            }
        }
    }

    @ViewBuilder private var signedIn: some View {
        Section {
            Bookplate(
                username: account.summary?.username, owner: model.social.owner,
                syncedAt: account.summary?.syncedAt, isSyncing: account.isSyncing,
                progress: account.downloadProgress
            )
            .listRowBackground(Color.clear)
            // Room for the bookplate's shadow, which the row would clip.
            .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 24, trailing: 0))
        }
        Section {
            // A download from Hardcover and a design load from iCloud fail independently, so each
            // error shows on its own. In preview mode, the preview library's section shows the load
            // error instead.
            if let error = account.syncError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if !model.isPreview, let error = model.loadError, error != account.syncError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if account.needsReconnect {
                Button("Reconnect") { account.startSignIn() }
            } else {
                Button("Sync now") { Task { await account.sync() } }
                    .disabled(account.isSyncing)
            }
        } footer: {
            Text(
                "Bookworms keeps a copy of your Hardcover library, including your reviews, on this \(ThisDevice.name) and in your private iCloud storage, where your other Apple devices use it too. It refreshes the copy about once a day."
            )
        }
        Section {
            Button("Sign out", role: .destructive) { confirmsSignOut = true }
                .confirmationDialog(
                    "Sign out of Hardcover?", isPresented: $confirmsSignOut,
                    titleVisibility: .visible
                ) {
                    Button("Sign out", role: .destructive) { account.signOut() }
                } message: {
                    Text(
                        "Bookworms removes your login and its copy of your library from this \(ThisDevice.name). The copy in your iCloud stays, and Bookworms can still show it. Your Hardcover account is unchanged."
                    )
                }
        }
    }
}

/// The sign-in code on a library card: card stock with a red rule under its heading and the code
/// typed large in monospaced digits. VoiceOver spells the code out.
private struct LibraryCard: View {
    let code: String

    var body: some View {
        CardStockSheet(ruleSpacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Library card")
                    Spacer()
                    Text("Hardcover")
                }
                .font(.catalogLabel)
                .foregroundStyle(Stationery.labelInk)
                Rectangle().fill(Stationery.red).frame(height: 1.5)
                    .accessibilityHidden(true)
                Text("Your code")
                    .font(.subheadline)
                    .foregroundStyle(Stationery.labelInk)
                Text(code)
                    .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .speechSpellsOutCharacters()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .padding(16)
        }
        .padding(.horizontal, 16)
    }
}

/// The signed-in account's "Ex libris" bookplate: the reader's Hardcover photo, their username in
/// small caps, and when the library last synced on a date-due line, or the first download's
/// progress. VoiceOver reads it as one element.
struct Bookplate: View {
    let username: String?
    /// The reader's profile, when the friends list has loaded it, for the photo.
    let owner: ReaderProfile?
    let syncedAt: Date?
    let isSyncing: Bool
    let progress: HardcoverAccount.DownloadProgress?

    var body: some View {
        CardStockSheet(cornerRadius: 2) {
            VStack(spacing: 10) {
                Text("Ex libris")
                    .font(.title3.italic())
                    .bookHeading()
                Group {
                    if let owner {
                        ReaderAvatarView(profile: owner, size: 64)
                    } else {
                        Image("account.bookworms")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Stationery.labelInk)
                            .frame(width: 64, height: 64)
                    }
                }
                .accessibilityHidden(true)
                Text(username.map { "@\($0)" } ?? "Hardcover")
                    .font(.headline.smallCaps())
                    .bookHeading()
                Rectangle().fill(Stationery.rule).frame(height: 0.75)
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline) {
                    Text("Last synced").font(.catalogLabel).foregroundStyle(Stationery.labelInk)
                    Spacer()
                    Text(syncLine).monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            // A bookplate's printed double border.
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(Stationery.labelInk.opacity(0.6), lineWidth: 1)
                    .padding(6)
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(Stationery.labelInk.opacity(0.35), lineWidth: 0.5)
                    .padding(9)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hardcover account, \(username.map { "@\($0)" } ?? "Hardcover")")
        .accessibilityValue("Last synced: \(syncLine)")
    }

    private var syncLine: String {
        if let progress { return progress.description }
        if isSyncing { return "Syncing…" }
        return syncedAt?.formatted(.relative(presentation: .named)) ?? "Not yet"
    }
}

#if os(iOS)
    /// Hardcover's approval page in Safari inside the app.
    ///
    /// The account sheet presents it itself: `openURL(_:prefersInApp:)` presents Safari from the
    /// window's root view controller, which UIKit refuses while that controller presents the sheet.
    private struct ApprovalPage: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> SFSafariViewController {
            SFSafariViewController(url: url)
        }

        func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
    }
#endif
