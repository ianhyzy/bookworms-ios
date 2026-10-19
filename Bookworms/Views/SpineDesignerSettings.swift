import SwiftUI

/// Chooses the backup model that designs spines when Private Cloud Compute isn't available: none,
/// a preset provider with its own API key, or any OpenAI-compatible endpoint. Apple's Private
/// Cloud Compute designs whenever it is available. Without it, the backup designs, then Apple's
/// on-device model, then local defaults (`ModelTier`).
///
/// A field saves when it loses focus, on Return, and when the screen or window closes, so typing
/// neither reads the Keychain nor rechecks the model for each character. Keys go straight to this
/// device's Keychain and never show again; the row of a saved key says **Saved** and only removes
/// it. On the iPhone, saving a key also shows a "Key saved" toast; the Mac's Settings window has
/// no toasts. A key the Keychain refuses says so under the field.
struct SpineDesignerSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @State private var designer = SpineDesigner.current
    /// The settings as last saved, so a field that loses focus unchanged saves nothing.
    @State private var saved = SpineDesigner.current
    @State private var newKey = ""
    @State private var hasKey = false
    @State private var keyError: String?
    @FocusState private var focus: Field?

    private enum Field { case model, baseURL, key }

    var body: some View {
        Section {
            Picker("Backup model", selection: $designer.provider) {
                ForEach(SpineDesigner.Provider.allCases) { Text($0.name).tag($0) }
            }
            if designer.provider != .apple {
                TextField("Model", text: $designer.model, prompt: Text("Model name"))
                    .plainEntry()
                    .focused($focus, equals: .model)
                    .onSubmit(commit)
                if designer.provider == .custom {
                    TextField(
                        "Base URL", text: $designer.baseURL,
                        prompt: Text("https://example.com/v1")
                    )
                    .plainEntry()
                    .focused($focus, equals: .baseURL)
                    .onSubmit(commit)
                }
                if hasKey {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved").foregroundStyle(.secondary)
                            Button("Remove Key", role: .destructive) {
                                designer.provider.key.delete()
                                hasKey = false
                                settingsChanged()
                            }
                        }
                    }
                } else {
                    SecureField("API key", text: $newKey)
                        .focused($focus, equals: .key)
                        .onSubmit(saveKey)
                    if let keyError {
                        Label(keyError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text(designer.provider == .apple ? Self.appleNote : Self.providerNote)
        }
        .onChange(of: designer.provider) { _, provider in
            designer.model = provider.defaultModel
            designer.baseURL = provider.defaultBaseURL
            newKey = ""
            keyError = nil
            // A choice of provider, not typing, reads the Keychain.
            hasKey = provider.key.read() != nil
            commit()
        }
        .onChange(of: focus) { left, _ in
            if left == .key { saveKey() } else if left != nil { commit() }
        }
        .onAppear { hasKey = designer.provider.key.read() != nil }
        // **Back** and closing the Settings window save what was typed.
        .onDisappear {
            saveKey()
            commit()
        }
    }

    #if NO_PCC
        private static let appleNote =
            "This test build leaves out Private Cloud Compute until Apple grants the entitlement. Without a backup model, Apple's on-device model designs spines on this \(ThisDevice.name), with no daily limit. \(localNote)"
        private static let providerNote =
            "This test build leaves out Private Cloud Compute, so this model designs spines, before Apple's on-device model. \(providerDetails)"
    #else
        private static let appleNote =
            "Private Cloud Compute designs spines within its daily limit. When it isn't available, Apple's on-device model designs on this \(ThisDevice.name), unless you choose a backup model. \(localNote)"
        private static let providerNote =
            "This model designs spines only when Private Cloud Compute isn't available, before Apple's on-device model. \(providerDetails)"
    #endif
    private static let localNote =
        "With no model available, spines come from the cover's colors and lettering and the book's genres."
    private static let providerDetails =
        "If the provider rejects the key or model name, or the account has no credit, Apple's on-device model or local defaults design until you change these settings or start Generate now. The provider receives each cover, its title and author, and the colors and font families to choose from. Requests are billed to your API account. The key stays in this device's Keychain."

    /// Saves a typed key in the Keychain, then the settings.
    private func saveKey() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try designer.provider.key.save(key)
        } catch {
            keyError =
                "The key couldn't be saved in this \(ThisDevice.name)'s keychain. Try again."
            return
        }
        newKey = ""
        keyError = nil
        hasKey = true
        #if os(iOS)
            model.toasts.show(Toast(message: "Key saved", systemImage: "key.fill"))
        #endif
        settingsChanged()
    }

    /// Saves the settings when they changed since the last save.
    private func commit() {
        guard designer != saved else { return }
        settingsChanged()
    }

    /// Saves the settings and forgets the provider's rejection of the old ones, with the last
    /// run's message about it (`GenerationController.backupSettingsChanged()`), so the next run
    /// tries the backup again.
    private func settingsChanged() {
        designer.save()
        saved = designer
        Task { await generation.backupSettingsChanged() }
    }
}

extension View {
    /// Turns off capitalization and correction for names and URLs typed on the iPhone.
    fileprivate func plainEntry() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
            self
        #endif
    }
}
