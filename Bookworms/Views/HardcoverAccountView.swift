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
/// **Done** once signed in or while a sign-in runs. Sign-in prompts open it as **Hardcover**, with
/// only the account. On the iPhone, the Spines tab's gear opens it as **Settings**
/// (`showsSettings`), with the app's settings after the account.
///
/// Signed out, **Not now** is the cancel action (Escape on the Mac), and **Connect Hardcover** in
/// the form is the default action (Return).
///
/// The sheet tints its controls with the accent wherever it opens, also from book details, whose
/// walnut room's lamp tint would wash out **Connect Hardcover**'s white label.
struct HardcoverAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Whether the sheet is the iPhone's **Settings**, with the app's settings after the account.
    /// Only the Spines tab's gear passes `true`; the Mac's Settings window has panes of its own.
    var showsSettings = false

    var body: some View {
        let account = model.account
        NavigationStack {
            form
                .navigationTitle(showsSettings ? "Settings" : "Hardcover")
                .navigationBarTitleDisplayMode(.inline)
                #if os(macOS)
                    .frame(minWidth: 480, minHeight: 440)
                #endif
                .toolbar {
                    // Settings closes with Done; Not now declines the sign-in a prompt offers.
                    if showsSettings || account.isSignedIn || account.signIn != nil {
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
        .tint(.accentColor)
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

    @ViewBuilder private var form: some View {
        #if DEBUG && os(iOS)
            // `-BookwormsSettingsScroll YES` scrolls to **Credits** a second after the sheet
            // opens, for Simulator checks of the form's end.
            ScrollViewReader { proxy in
                HardcoverAccountForm(showsSettings: showsSettings)
                    .task {
                        guard UserDefaults.standard.bool(forKey: "BookwormsSettingsScroll") else {
                            return
                        }
                        try? await Task.sleep(for: .seconds(1))
                        proxy.scrollTo(HardcoverAccountForm.settingsID, anchor: .bottom)
                    }
            }
        #else
            HardcoverAccountForm(showsSettings: showsSettings)
        #endif
    }
}

/// The Hardcover account: why to connect, the device-code sign-in on a library card, and the
/// signed-in account's bookplate with **Sync now** and **Sign out**. It shows when the library
/// last synced, from Hardcover or, without a sign-in, from iCloud, whose library its own **Sync
/// now** loads again. The account sheet and the Mac's **Settings > Hardcover** show it. With
/// `showsSettings` on the iPhone, the app's settings follow the account (`CardStylePicker`), then
/// **Privacy Policy** and **Credits** (`CreditsView`).
///
/// Hardcover's approval page opens with the code already copied: on the iPhone, in Safari over
/// this form, which closes it when polling sees the approval, and on the Mac, in the default
/// browser, where it stays open. The device flow has no redirect back to the app, which is what
/// `ASWebAuthenticationSession` waits for.
struct HardcoverAccountForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copiedCode = false
    @State private var confirmsSignOut = false
    @State private var showsApprovalPage = false
    @Environment(\.openURL) private var openURL
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    /// Whether the app's settings follow the account. The Mac shows them in its Settings window.
    var showsSettings = false

    private var account: HardcoverAccount { model.account }

    #if os(iOS)
        /// The ID of the form's last section, **Privacy Policy** and **Credits**.
        static let settingsID = "settings"
    #endif

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
            // while a sign-in is in progress, until it finishes. The example profile never syncs.
            if (model.isPreview || !account.isSignedIn) && !model.isExample {
                libraryWithoutSignIn
            }
            // The Mac chooses the cards in **Settings > General**.
            #if os(iOS)
                if showsSettings {
                    Section { CardStylePicker() }
                    Section {
                        Link("Privacy Policy", destination: .privacyPolicy)
                        NavigationLink("Credits") { CreditsView() }
                    }
                    .id(Self.settingsID)
                }
            #endif
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
                "Bookworms reads your library and never changes it on Hardcover.",
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
            exampleButton
        } footer: {
            Text(
                "Your Hardcover login stays in this \(ThisDevice.name)'s keychain. Bookworms sends it only to Hardcover and never syncs it."
            )
        }
    }

    /// **View example profile**, which closes the sheet and shows the bundled example while the
    /// device has no library, or **Leave example profile** while it shows. Builds without the
    /// example and preview mode show neither.
    @ViewBuilder private var exampleButton: some View {
        if model.isExample {
            exampleRow("Leave example profile") {
                model.leaveExample()
                // The example's reloads returned early, so a library that iCloud saved meanwhile
                // shows now.
                Task { await model.reload() }
            }
        } else if AppModel.exampleFolder != nil, !model.isPreview, model.library == nil {
            exampleRow("View example profile") {
                dismiss()
                Task { await model.showExample() }
                #if os(macOS)
                    // From the Settings window, the main window may be closed.
                    openWindow(id: BookwormsMenu.windowID)
                    NSApplication.shared.activate()
                #endif
            }
        }
    }

    /// The example button's row, under **Connect Hardcover** and as wide.
    private func exampleRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(model.isLoading)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
    }

    /// The library shown without a Hardcover sign-in: the one in iCloud, or in preview mode the
    /// local folder. Load errors show even while an older copy shows.
    private var libraryWithoutSignIn: some View {
        Section {
            if let library = model.library {
                LabeledContent("Last synced", value: LibrarySync.time(of: library.syncedAt))
            } else if model.loadError == nil, !model.isPreview {
                Text("No library in iCloud yet.")
            }
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if model.iCloudIsOff, !model.isPreview { turnOnICloudStorage }
            Button("Sync now") { Task { await model.reload() } }
                .disabled(model.isLoading)
        } header: {
            Text(model.isPreview ? "Preview library" : "iCloud library")
        } footer: {
            if model.isPreview {
                Text("Preview mode reads a local library. Designs stay on this \(ThisDevice.name).")
            }
        }
    }

    /// Undoes **Keep iCloud Off**, which runs the iCloud account check again.
    private var turnOnICloudStorage: some View {
        Button("Turn on iCloud storage") { Task { await model.turnOnICloudStorage() } }
            .disabled(model.isLoading)
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
            if let issue = model.iCloudIssue {
                Label(issue, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.secondary)
            }
            if model.iCloudIsOff, !model.isPreview { turnOnICloudStorage }
            if account.needsReconnect {
                Button("Reconnect") { account.startSignIn() }
            } else {
                Button("Sync now") { Task { await account.sync() } }
                    .disabled(account.isSyncing)
            }
        } footer: {
            Text(
                model.iCloudIssue == nil
                    ? "Bookworms keeps a copy of your Hardcover library, including your reviews, on this \(ThisDevice.name) and in your private iCloud storage. Your other iPhones and Macs use it, and so does your Apple TV when iCloud storage is on there. It refreshes the copy about once a day."
                    : "Bookworms keeps a copy of your Hardcover library, including your reviews, on this \(ThisDevice.name). It refreshes the copy about once a day."
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
                        "Bookworms removes your login and its copy of your library from this \(ThisDevice.name). Any copy in your iCloud stays, and Bookworms can still show it. Your Hardcover account is unchanged."
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
                    Text(syncLabel).font(.catalogLabel).foregroundStyle(Stationery.labelInk)
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
        .accessibilityValue("\(syncLabel): \(syncLine)")
    }

    private var syncLabel: String { progress == nil ? "Last synced" : "Downloading" }

    private var syncLine: String {
        if let progress { return progress.description }
        if isSyncing { return "Syncing…" }
        return syncedAt.map { LibrarySync.time(of: $0) } ?? "Not yet"
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
