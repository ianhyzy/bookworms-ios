import SwiftUI

#if os(iOS)
    import SafariServices
#endif
#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The Hardcover account sheet: why to connect, the device-code sign-in, and the signed-in
/// account with **Sync now** and **Sign out**. It is the one place that shows when the library
/// last synced, from Hardcover or, without a sign-in, from iCloud.
///
/// Hardcover's approval page opens in Safari over this sheet, with the code already copied, and
/// closes when polling sees the approval. The device flow has no redirect back to the app, which is
/// what `ASWebAuthenticationSession` waits for.
struct HardcoverAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copiedCode = false
    @State private var confirmsSignOut = false
    @State private var showsApprovalPage = false
    @Environment(\.openURL) private var openURL

    private var account: HardcoverAccount { model.account }

    var body: some View {
        NavigationStack {
            Form {
                if let signIn = account.signIn {
                    signInSections(signIn)
                } else if account.isSignedIn {
                    signedIn
                } else {
                    signedOut
                }
                // Preview mode ignores the sign-in.
                if model.isPreview || (account.signIn == nil && !account.isSignedIn) {
                    libraryWithoutSignIn
                }
            }
            .navigationTitle("Hardcover")
            .navigationBarTitleDisplayMode(.inline)
            #if os(macOS)
                // A Mac sheet is its own window, outside the main window's grouped style.
                .formStyle(.grouped)
                .frame(minWidth: 480, minHeight: 440)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(account.isSignedIn || account.signIn != nil ? "Done" : "Not now") {
                        dismiss()
                    }
                }
            }
            #if os(macOS)
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

    @ViewBuilder private var signedOut: some View {
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
            Button("Connect Hardcover") { account.startSignIn() }
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

    private func reason(_ title: String, _ detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    @ViewBuilder private func signInSections(_ signIn: HardcoverAccount.SignIn) -> some View {
        switch signIn {
        case .requestingCode:
            Section { LabeledContent("Getting a code") { ProgressView() } }
        case .waiting(let code, _):
            Section {
                VStack(spacing: 8) {
                    Text("Your code")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .speechSpellsOutCharacters()
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                Button(
                    copiedCode ? "Copied" : "Copy code",
                    systemImage: copiedCode ? "checkmark" : "doc.on.doc"
                ) {
                    UIPasteboard.general.string = code
                    copiedCode = true
                }
                Button("Open Hardcover", systemImage: "safari") {
                    UIPasteboard.general.string = code
                    copiedCode = true
                    showsApprovalPage = true
                }
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
            LabeledContent(
                "Account", value: account.summary?.username.map { "@\($0)" } ?? "Hardcover")
            LabeledContent("Last synced") {
                if account.isSyncing {
                    ProgressView()
                } else {
                    Text(
                        account.summary?.syncedAt?.formatted(.relative(presentation: .named))
                            ?? "Not yet")
                }
            }
            // A design load from iCloud can fail while the Hardcover sync works. In preview mode,
            // the preview library's section shows the load error instead.
            if let error = account.syncError ?? (model.isPreview ? nil : model.loadError) {
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
