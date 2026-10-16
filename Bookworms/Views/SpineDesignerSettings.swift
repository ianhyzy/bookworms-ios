import SwiftUI

/// Chooses the backup model that designs spines when Private Cloud Compute isn't available: none,
/// a preset provider with its own API key, or any OpenAI-compatible endpoint. Apple's Private
/// Cloud Compute designs whenever it is available. Without it, the backup designs, then Apple's
/// on-device model, then local defaults (`ModelTier`).
///
/// Keys go straight to this device's Keychain and never show again; the field only replaces or
/// removes the saved key.
struct SpineDesignerSettings: View {
    @Environment(GenerationController.self) private var generation
    @State private var designer = SpineDesigner.current
    @State private var newKey = ""
    @State private var hasKey = false

    var body: some View {
        Section {
            Picker("Backup model", selection: $designer.provider) {
                ForEach(SpineDesigner.Provider.allCases) { Text($0.name).tag($0) }
            }
            if designer.provider != .apple {
                TextField("Model", text: $designer.model, prompt: Text("Model name"))
                    .plainEntry()
                if designer.provider == .custom {
                    TextField(
                        "Base URL", text: $designer.baseURL,
                        prompt: Text("https://example.com/v1")
                    )
                    .plainEntry()
                }
                if hasKey {
                    LabeledContent("API key") {
                        Button("Remove Key", role: .destructive) {
                            designer.provider.key.delete()
                            refresh()
                        }
                    }
                } else {
                    SecureField("API key", text: $newKey)
                        .onSubmit {
                            guard !newKey.isEmpty else { return }
                            try? designer.provider.key.save(newKey)
                            newKey = ""
                            refresh()
                        }
                }
            }
        } header: {
            Text("Spine design model")
        } footer: {
            Text(designer.provider == .apple ? Self.appleNote : Self.providerNote)
        }
        .onChange(of: designer.provider) { _, provider in
            designer.model = provider.defaultModel
            designer.baseURL = provider.defaultBaseURL
        }
        .onChange(of: designer) { refresh() }
        .onAppear { hasKey = designer.provider.key.read() != nil }
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
        "If the provider rejects the key or model name, Apple's on-device model or local defaults design the rest of that run. The provider receives each cover, its title and author, and the colors and font families to choose from. Requests are billed to your API account. Press Return to save a key; it stays in this device's Keychain."

    private func refresh() {
        designer.save()
        hasKey = designer.provider.key.read() != nil
        Task { await generation.refreshModelStatus() }
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
