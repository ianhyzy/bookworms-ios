import SwiftUI

/// Chooses the model that designs spines: Apple's on-device model, the default, or a preset
/// provider or any OpenAI-compatible endpoint with the reader's own API key. Builds with Private
/// Cloud Compute design with it whenever it is available. Otherwise the chosen provider designs,
/// then Apple's on-device model, then local defaults (`ModelTier`).
///
/// A preset provider's **Model name** picker lists `DesignModels`, with a star on the
/// recommended model, and **Custom…**, which shows a field for any model ID; a saved ID that the
/// list doesn't name shows as **Custom…** with its ID. The custom endpoint has only the field.
/// **Thinking** appears when the chosen model has thinking levels, from the provider's model
/// details or else the list, and saves for each provider.
///
/// A field saves when it loses focus, on Return, and when the screen or window closes, so typing
/// neither reads the Keychain nor rechecks the model for each character. Keys go straight to this
/// device's Keychain and never show again; the row of a saved key says **Saved** and only removes
/// it. On the iPhone, saving a key also shows a "Key saved" toast; the Mac's Settings window has
/// no toasts. A key the Keychain refuses says so under the field. When the screen appears, a key
/// is saved, or a preset provider's model changes, one request asks the provider whether the key
/// can use the model, and a note says when it can't (`SpineDesigner.availability()`); saving
/// never waits for it.
struct SpineDesignerSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @State private var designer = SpineDesigner.current
    /// The settings as last saved, so a field that loses focus unchanged saves nothing.
    @State private var saved = SpineDesigner.current
    @State private var newKey = ""
    @State private var hasKey = false
    @State private var keyError: String?
    /// Whether the **Model name** picker shows **Custom…** and the model ID field.
    @State private var customModel = false
    /// The chosen model's thinking levels, cheapest first; empty hides **Thinking**.
    @State private var thinkingLevels: [String] = []
    /// Why the key can't use the chosen model, from the provider's answer.
    @State private var availabilityNote: String?
    @State private var availabilityCheck: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field { case model, baseURL, key }

    var body: some View {
        Section {
            Picker("Model", selection: $designer.provider) {
                ForEach(SpineDesigner.Provider.allCases) { Text($0.name).tag($0) }
            }
            if designer.provider == .custom {
                TextField("Model name", text: $designer.model, prompt: Text("Model name"))
                    .plainEntry()
                    .focused($focus, equals: .model)
                    .onSubmit(commit)
                TextField(
                    "Base URL", text: $designer.baseURL,
                    prompt: Text("https://example.com/v1")
                )
                .plainEntry()
                .focused($focus, equals: .baseURL)
                .onSubmit(commit)
            } else if designer.provider != .apple {
                Picker("Model name", selection: modelChoice) {
                    ForEach(DesignModels.bundled.models[designer.provider] ?? []) { listed in
                        Text(listed.pickerLabel)
                            .accessibilityLabel(
                                listed.recommended == true
                                    ? "\(listed.label), recommended" : listed.label
                            )
                            .tag(String?.some(listed.id))
                    }
                    Text("Custom…").tag(String?.none)
                }
                if customModel {
                    TextField("Model ID", text: $designer.model, prompt: Text("Model ID"))
                        .plainEntry()
                        .focused($focus, equals: .model)
                        .onSubmit(commit)
                }
                if !thinkingLevels.isEmpty {
                    Picker("Thinking", selection: $designer.thinking) {
                        ForEach(thinkingLevels, id: \.self) { Text($0).tag($0) }
                    }
                }
                if let availabilityNote {
                    Label(availabilityNote, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            if designer.provider != .apple {
                if hasKey {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved").foregroundStyle(.secondary)
                            Button("Remove Key", role: .destructive) {
                                designer.provider.key.delete()
                                hasKey = false
                                settingsChanged()
                                checkModel()
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
            Text(
                designer.provider == .apple
                    ? Self.appleNote : Self.providerNote(designer.provider))
        }
        .onChange(of: designer.provider) { _, provider in
            designer = SpineDesigner(choosing: provider)
            newKey = ""
            keyError = nil
            // A choice of provider, not typing, reads the Keychain.
            hasKey = provider.key.read() != nil
            commit()
        }
        .onChange(of: designer.thinking) { commit() }
        .onChange(of: focus) { left, _ in
            if left == .key { saveKey() } else if left != nil { commit() }
        }
        .onAppear {
            hasKey = designer.provider.key.read() != nil
            showModel(confirmed: nil)
            checkModel()
        }
        // **Back** and closing the Settings window save what was typed.
        .onDisappear {
            saveKey()
            commit()
            availabilityCheck?.cancel()
        }
    }

    /// The **Model name** picker's choice: a listed model's ID, or `nil` for **Custom…**, which
    /// keeps the current ID in the field to edit.
    private var modelChoice: Binding<String?> {
        Binding {
            customModel ? nil : designer.model
        } set: { id in
            guard let id else {
                customModel = true
                return
            }
            customModel = false
            designer.model = id
            commit()
        }
    }

    /// The footer for Apple's on-device model.
    #if NO_PCC
        private static let appleNote =
            "Apple's on-device model designs spines on this \(ThisDevice.name) at no cost, and covers never leave it. For better results, choose a provider and add your own API key. \(localNote)"
    #else
        private static let appleNote =
            "Private Cloud Compute designs spines within its daily limit. When it isn't available, Apple's on-device model designs on this \(ThisDevice.name), unless you choose a provider. \(localNote)"
    #endif
    private static let localNote =
        "When no model is available, spines use a default style from the cover's colors and lettering and the book's genres."

    /// The footer for a third-party `provider`. A custom endpoint may need no key and bill no
    /// account, so its footer claims neither.
    private static func providerNote(_ provider: SpineDesigner.Provider) -> String {
        #if NO_PCC
            #if os(macOS)
                let press = "click"
            #else
                let press = "tap"
            #endif
            if provider == .custom {
                return
                    "Your OpenAI-compatible endpoint designs spines, with your API key if it needs one. Each new design is one request. The endpoint receives each cover, its title and author, and the colors and fonts to choose from. If it rejects the key or model name, Apple's on-device model designs until you change these settings or \(press) Generate now. A key stays in this \(ThisDevice.name)'s Keychain."
            }
            return
                "\(provider.name) designs spines with your API key, which can give better results than Apple's on-device model. Each new design is one request, billed to your API account. The provider receives each cover, its title and author, and the colors and fonts to choose from. If it rejects the key or model name, or your account runs out of credit, Apple's on-device model designs until you change these settings or \(press) Generate now. The key stays in this \(ThisDevice.name)'s Keychain."
        #else
            // A custom endpoint may need no key and bill no account.
            let billing =
                provider == .custom
                ? "A key, if the endpoint needs one, stays in this device's Keychain."
                : "Requests are billed to your API account. The key stays in this device's Keychain."
            return
                "This model designs spines only when Private Cloud Compute isn't available, before Apple's on-device model. If the provider rejects the key or model name, or the account has no credit, Bookworms uses Apple's on-device model or default styling until you change these settings or start Generate now. The provider receives each cover, its title and author, and the colors and font families to choose from. \(billing)"
        #endif
    }

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
        checkModel()
    }

    /// Saves the settings when they changed since the last save. A new provider or model also
    /// updates the model rows and is checked against the key.
    private func commit() {
        let newModel = designer.provider != saved.provider || designer.model != saved.model
        if newModel { showModel(confirmed: nil) }
        guard designer != saved else { return }
        settingsChanged()
        if newModel { checkModel() }
    }

    /// Matches the rows to the chosen model: the picker selects a listed model, else
    /// **Custom…**, and **Thinking** offers the levels that the provider's answer confirms
    /// (`confirmed`), else the list's. A level the model doesn't take becomes its default.
    private func showModel(confirmed: [String]?) {
        let listed = DesignModels.bundled.model(designer.model, of: designer.provider)
        customModel = listed == nil
        let levels: [String]?
        if confirmed?.isEmpty == true {
            levels = []
        } else if let listed {
            levels = listed.thinking ?? confirmed ?? []
        } else {
            levels = confirmed
        }
        // A model that the list doesn't name keeps its level until the provider's answer says
        // which levels it takes.
        thinkingLevels = levels ?? []
        guard let levels, !levels.contains(designer.thinking) else { return }
        designer.thinking = levels.isEmpty ? "" : listed?.thinkingDefault ?? levels.first ?? ""
    }

    /// Asks the provider whether the saved key can use the chosen preset model, and notes when
    /// it can't. Each check replaces the last one, and an answer applies only while the reader
    /// keeps that provider and model; a failed check says nothing.
    private func checkModel() {
        availabilityCheck?.cancel()
        availabilityNote = nil
        let checked = designer
        guard hasKey, checked.provider != .apple, checked.provider != .custom,
            !checked.model.isEmpty
        else { return }
        availabilityCheck = Task {
            let result = await checked.availability()
            guard !Task.isCancelled, designer.provider == checked.provider,
                designer.model == checked.model
            else { return }
            switch result {
            case .available(let thinking?): showModel(confirmed: thinking)
            case .unavailable:
                availabilityNote = "This key can't use \(checked.model); choose another model."
            case .keyRejected:
                availabilityNote = "\(checked.provider.name) didn't accept this key."
            case .available(nil), nil: break
            }
        }
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
