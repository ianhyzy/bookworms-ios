import SwiftUI
import UIKit

/// The Hardcover account sheet: why to connect, the device-code sign-in, and the signed-in
/// account with **Sync now** and **Sign out**.
///
/// Hardcover's approval page opens in Safari inside the app (`openURL` with `prefersInApp`), so
/// the code stays one swipe away and the sheet updates when polling sees the approval. The device
/// flow has no redirect back to the app, which is what `ASWebAuthenticationSession` waits for.
struct HardcoverAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copiedCode = false
    @State private var confirmsSignOut = false

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
            }
            .navigationTitle("Hardcover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: account.signIn) { copiedCode = false }
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
                "Use Bookworms without an Apple TV", "Your books come straight from Hardcover.",
                systemImage: "iphone")
            reason(
                "Bring your reviews", "Bookworms gets the reviews you wrote along with your books.",
                systemImage: "text.quote")
            reason(
                "Read-only",
                "Bookworms reads your library and never changes anything on Hardcover.",
                systemImage: "lock")
        } footer: {
            Text(
                "Without a Hardcover sign-in, Bookworms shows the library your Apple TV uploads to iCloud."
            )
        }
        Section {
            Button("Connect Hardcover") { account.startSignIn() }
        } footer: {
            Text(
                "Your Hardcover login stays in this iPhone's keychain. Bookworms sends it only to Hardcover and never syncs it."
            )
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
        case .waiting(let code, let url):
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
                    openURL(url, prefersInApp: true)
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
            if let error = account.syncError {
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
                "Bookworms keeps a copy of your Hardcover library, including your reviews, on this iPhone and refreshes it every few hours."
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
                        "Bookworms removes your login and its copy of your library from this iPhone. Your Hardcover account is unchanged."
                    )
                }
        }
    }
}
