import SwiftUI

/// Chooses the model that designs spines: Apple's models, the default, or a preset provider or
/// any OpenAI-compatible endpoint with the reader's own API key. Builds with Private Cloud Compute
/// design with it whenever it is available. Otherwise the chosen provider designs, then Apple's
/// on-device model, then local defaults (`ModelTier`). In those builds, a provider's
/// **Use this model instead of Private Cloud Compute** puts the provider first
/// (`SpineDesigner.overridesPrivateCloudCompute`); it saves at once, per device.
///
/// A preset provider's **Model name** picker lists `DesignModels`, with a star on the
/// recommended model, and **Custom…**, which shows a field for any model ID; a saved ID that the
/// list doesn't name shows as **Custom…** with its ID. The custom endpoint has only the field.
/// **Thinking** appears only for a model that the list names with thinking levels, and saves for
/// each provider; a custom model ID sends no level
/// (`SpineDesigner.thinking(saved:provider:model:)`).
///
/// A field saves when it loses focus, on Return, and when the screen or window closes, so typing
/// neither reads the Keychain nor rechecks the model for each character. A key the Keychain refuses
/// says so under the field. A typed key also saves to its provider when **Model** changes,
/// silently: with no toast, and with no message if the Keychain refuses it. Keys go straight to
/// this device's Keychain and never show again; the row of a saved key says **Saved** and only
/// removes it. On the iPhone, saving a key also shows a "Key saved" toast; the Mac's Settings
/// window has no toasts. When the screen appears, a key is saved, or a preset provider's model
/// changes, one request asks the provider whether the key can use the model, and a note says when
/// it can't (`SpineDesigner.availability()`); saving never waits for it.
///
/// Before a third-party provider's first key, or a custom endpoint's first base URL, saves on
/// this device, an alert asks the reader to allow it to receive each book's cover, title, and
/// author (`SpineDesigner.hasConsent(of:)`). **Cancel** saves nothing. A key or base URL that
/// would save without the alert, when the screen closes or **Model** changes, is dropped until
/// the reader allows its provider (`saveChoice(for:closing:)`).
///
/// The same alert asks once when the screen shows a provider whose key is in the Keychain
/// although the reader hasn't allowed the provider on this device: deleting the app clears that
/// answer and can leave the key. **Allow** makes the key count as saved, and **Cancel** removes
/// it. Until the reader answers, the key counts as not saved, here and for every request
/// (`SpineDesigner.requestKey(loadKey:)`), so the row shows the key field.
struct SpineDesignerSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @State private var designer = SpineDesigner.current
    /// The settings as last saved, so a field that loses focus unchanged saves nothing.
    @State private var saved = SpineDesigner.current
    @State private var newKey = ""
    @State private var keyError: String?
    /// Whether the **Model name** picker shows **Custom…** and the model ID field.
    @State private var customModel = false
    /// The chosen model's thinking levels, cheapest first; empty hides **Thinking**.
    @State private var thinkingLevels: [String] = []
    /// Why the key can't use the chosen model, from the provider's answer.
    @State private var availabilityNote: String?
    @State private var availabilityCheck: Task<Void, Never>?
    @State private var overridesPCC = SpineDesigner.overridesPrivateCloudCompute
    /// The entry that waits for the reader to allow its provider.
    @State private var pending: PendingConsent?
    @State private var asksConsent = false
    @FocusState private var focus: Field?

    private enum Field { case model, baseURL, key }

    private struct PendingConsent {
        enum Entry {
            /// A typed key, trimmed and as typed.
            case key(trimmed: String, typed: String)
            /// A custom endpoint's base URL, which saves with the settings.
            case baseURL
            /// A key the Keychain already holds, which counts as saved once the reader allows
            /// and is removed when the reader declines.
            case savedKey
        }

        let provider: SpineDesigner.Provider
        let entry: Entry
    }

    /// What happens to a typed key or base URL for `provider`.
    enum SaveChoice { case store, ask, drop }

    /// Saves for a provider the reader allowed, else asks, unless the screen is `closing` or
    /// shows another provider and so can't show the alert, when the entry is dropped.
    static func saveChoice(for provider: SpineDesigner.Provider, closing: Bool) -> SaveChoice {
        if SpineDesigner.hasConsent(of: provider) { return .store }
        return closing ? .drop : .ask
    }

    var body: some View {
        Section {
            Picker("Model", selection: $designer.provider) {
                ForEach(SpineDesigner.Provider.allCases) { Text($0.name).tag($0) }
            }
            if designer.provider == .custom {
                TextField("Model name", text: $designer.model, prompt: Text("Model name"))
                    .plainEntry()
                    .focused($focus, equals: .model)
                    .onSubmit { commit() }
                TextField(
                    "Base URL", text: $designer.baseURL,
                    prompt: Text("https://example.com/v1")
                )
                .plainEntry()
                .focused($focus, equals: .baseURL)
                .onSubmit { commit() }
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
                        .onSubmit { commit() }
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
                            Button("Remove key", role: .destructive) {
                                let provider = designer.provider
                                Task {
                                    await generation.removeKey(of: provider)
                                    guard designer.provider == provider else { return }
                                    settingsChanged()
                                    checkModel()
                                }
                            }
                        }
                    }
                } else {
                    SecureField("API key", text: $newKey)
                        .focused($focus, equals: .key)
                        .onSubmit { saveKey() }
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
        .alert(
            Self.consentMessage(pending?.provider ?? .custom), isPresented: $asksConsent,
            presenting: pending
        ) { pending in
            Button("Allow") {
                let provider = pending.provider
                SpineDesigner.allow(provider)
                switch pending.entry {
                case .key(let trimmed, let typed): store(trimmed, typed: typed, for: provider)
                case .baseURL: commit()
                case .savedKey:
                    Task {
                        await showKey(of: provider)
                        // The provider is set up now, so the Spines tab and the next run see it.
                        await generation.refreshModelStatus()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                switch pending.entry {
                case .key: break
                case .baseURL:
                    designer.baseURL = saved.baseURL
                    commit()
                case .savedKey:
                    // A declined key goes, so the alert asks about it once.
                    let provider = pending.provider
                    Task { await generation.removeKey(of: provider) }
                }
            }
        }
        .onChange(of: designer.provider) { old, provider in
            // A key typed for the previous provider saves to it, because its field may still
            // have focus when the picker changes. A refused save is dropped: the next provider's
            // field can't report it, and keeping the text would save it to that provider. So is
            // a key for a provider the reader hasn't allowed, because the alert would name a
            // provider the screen no longer shows.
            let typed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, Self.saveChoice(for: old, closing: true) == .store {
                Task { try? await generation.saveKey(typed, for: old) }
            }
            designer = SpineDesigner(choosing: provider)
            newKey = ""
            keyError = nil
            commit()
            // A choice of provider, not typing, reads the Keychain.
            Task { await showKey(of: provider) }
        }
        .onChange(of: designer.thinking) { commit() }
        .onChange(of: focus) { left, _ in
            if left == .key { saveKey() } else if left != nil { commit() }
        }
        .onAppear {
            showModel()
            checkModel()
            let provider = designer.provider
            Task { await showKey(of: provider) }
        }
        // **Back** and closing the Settings window save what was typed. A focus change just
        // before can raise the alert on the closing screen, so it is cleared, or the Mac's
        // Settings window could show it on reopen.
        .onDisappear {
            asksConsent = false
            pending = nil
            saveKey(closing: true)
            commit(closing: true)
            availabilityCheck?.cancel()
        }
        #if !NO_PCC
            if designer.provider != .apple {
                Section {
                    Toggle("Use this model instead of Private Cloud Compute", isOn: $overridesPCC)
                        .onChange(of: overridesPCC) { _, overrides in
                            SpineDesigner.overridesPrivateCloudCompute = overrides
                            Task { await generation.refreshModelStatus() }
                        }
                } footer: {
                    // On, the reader's redesign ranks with Private Cloud Compute
                    // (`ModelTier.redesignRank(prefersBackup:)`). Off, a run waits for Private
                    // Cloud Compute's reset rather than spend the reader's key
                    // (`BookAnalyzer.bestStatus`).
                    Text(
                        "When it's on, this model can also redesign Private Cloud Compute's spines."
                    )
                }
            }
        #endif
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

    /// The footer for Apple's models. What a design costs is in the Spines tab's info button
    /// (`GenerationView.modelInfo`).
    #if NO_PCC
        private static let appleNote =
            "Apple's on-device model designs spines on this \(ThisDevice.name)."
    #else
        private static let appleNote =
            "Private Cloud Compute designs spines, and Apple's on-device model designs when it isn't available."
    #endif

    /// The footer for a third-party `provider`: who bills its requests, what it receives, and
    /// where the key stays. How many requests a design takes is in the Spines tab's info button
    /// (`GenerationView.modelInfo`). A custom endpoint may need no key and bill no account, so
    /// its footer claims neither.
    private static func providerNote(_ provider: SpineDesigner.Provider) -> String {
        provider == .custom
            ? "Your endpoint receives each book's cover, title, and author. Your key, if it needs one, stays on this \(ThisDevice.name)."
            : "\(provider.name) bills your API account and receives each book's cover, title, and author. Your key stays on this \(ThisDevice.name)."
    }

    /// The consent alert's text for a third-party `provider`. A custom endpoint is the reader's
    /// own, so the alert calls it "your endpoint", as its footer does.
    static func consentMessage(_ provider: SpineDesigner.Provider) -> String {
        let name = provider == .custom ? "your endpoint" : provider.name
        return
            "Bookworms will send each book's cover, title, and author to \(name) to design spines."
    }

    /// Saves a typed key, after the consent alert when the reader hasn't allowed its provider
    /// yet. The field empties at once, so the focus change that follows Return or the alert
    /// doesn't save the key again. A `closing` screen can't show the alert, so a key that needs
    /// it is dropped.
    private func saveKey(closing: Bool = false) {
        let typed = newKey
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let provider = designer.provider
        newKey = ""
        switch Self.saveChoice(for: provider, closing: closing) {
        case .store: store(key, typed: typed, for: provider, closing: closing)
        case .ask:
            pending = PendingConsent(provider: provider, entry: .key(trimmed: key, typed: typed))
            asksConsent = true
        case .drop: break
        }
    }

    /// Saves `key` in the Keychain, then the settings, and checks the model against it unless
    /// the screen is `closing`, when no note can show. A key the Keychain refuses comes back as
    /// `typed`, with the message.
    private func store(
        _ key: String, typed: String, for provider: SpineDesigner.Provider, closing: Bool = false
    ) {
        Task {
            do {
                try await generation.saveKey(key, for: provider)
            } catch {
                guard designer.provider == provider else { return }
                newKey = typed
                keyError = "Couldn't save the key. Try again."
                return
            }
            #if os(iOS)
                model.toasts.show(Toast(message: "Key saved", systemImage: "key.fill"))
            #endif
            guard designer.provider == provider else { return }
            keyError = nil
            settingsChanged()
            if !closing { checkModel() }
        }
    }

    /// Whether the chosen provider has a saved key that its requests can carry, from the flag
    /// that launch and the last save, removal, or read left (`GenerationController.savedKeys`),
    /// so the first frame and each provider change show it at once. Before the first read, the
    /// key field shows.
    private var hasKey: Bool { generation.savedKeys[designer.provider] ?? false }

    /// Reads whether `provider` has a saved key again, and asks for consent when the Keychain
    /// holds the key of a provider the reader hasn't allowed, unless the alert is already up.
    /// The model was checked against the flag already shown, so it is checked again only when
    /// the read changes the flag.
    private func showKey(of provider: SpineDesigner.Provider) async {
        let shown = hasKey
        let awaitsConsent = await generation.readSavedKey(of: provider)
        guard designer.provider == provider else { return }
        if awaitsConsent, !asksConsent {
            pending = PendingConsent(provider: provider, entry: .savedKey)
            asksConsent = true
        }
        if hasKey != shown { checkModel() }
    }

    /// Saves the settings when they changed since the last save. A new provider or model also
    /// updates the model rows and is checked against the key. A custom endpoint's new base URL
    /// waits for the consent alert, or is dropped when the screen is `closing`.
    private func commit(closing: Bool = false) {
        if designer.provider == .custom, !designer.baseURL.isEmpty,
            designer.baseURL != saved.baseURL
        {
            switch Self.saveChoice(for: .custom, closing: closing) {
            case .store: break
            case .ask:
                pending = PendingConsent(provider: .custom, entry: .baseURL)
                asksConsent = true
                return
            case .drop: designer.baseURL = saved.baseURL
            }
        }
        let newModel = designer.provider != saved.provider || designer.model != saved.model
        if newModel { showModel() }
        guard designer != saved else { return }
        settingsChanged()
        if newModel { checkModel() }
    }

    /// Matches the rows to the chosen model: the picker selects a listed model, else
    /// **Custom…**, and **Thinking** offers the list's levels for it, so a model that the list
    /// doesn't name shows no **Thinking** and sends no level. A level the model doesn't take
    /// becomes its default.
    private func showModel() {
        let listed = DesignModels.bundled.model(designer.model, of: designer.provider)
        customModel = listed == nil
        thinkingLevels = listed?.thinking ?? []
        designer.thinking = SpineDesigner.thinking(
            saved: designer.thinking, provider: designer.provider, model: designer.model)
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
            case .unavailable:
                availabilityNote = "This key can't use \(checked.model). Choose another model."
            case .keyRejected:
                availabilityNote =
                    "\(checked.provider.name) didn't accept your API key. Remove it and add a new one."
            case .available, nil: break
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
