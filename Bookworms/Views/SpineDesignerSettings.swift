import SwiftUI

/// Chooses the model that designs spines: Apple's Private Cloud Compute, a preset provider
/// with its own API key, or any OpenAI-compatible endpoint.
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
            Picker("Model provider", selection: $designer.provider) {
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

    private static let appleNote =
        "Apple's model designs spines with Private Cloud Compute, within its daily limit."
    private static let providerNote =
        "The provider receives each cover, its title and author, and the colors and font families to choose from. Requests are billed to your API account. Press Return to save a key; it stays in this device's Keychain."

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
