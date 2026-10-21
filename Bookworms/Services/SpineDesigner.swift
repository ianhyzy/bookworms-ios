import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

/// The reader's backup model, which designs spines when Private Cloud Compute isn't available: a
/// third-party provider chosen in Settings on the Mac or from the Spines tab on the iPhone. The
/// `.apple` choice means no backup, so Apple's on-device model, or without it local defaults,
/// designs when Private Cloud Compute isn't available (`ModelTier`).
///
/// The choice, model name, and each provider's thinking level live in `UserDefaults`; each
/// provider's API key lives in this device's Keychain (`KeychainSecret`), never synced.
/// Third-party providers answer through `ProviderModel`, so `BookAnalyzer` asks every provider
/// the same questions with the same schemas.
struct SpineDesigner: Hashable, Sendable {
    enum Provider: String, CaseIterable, Identifiable, Decodable, Sendable {
        case apple, anthropic, openAI, google, custom

        var id: Self { self }

        /// The choice's name as the **Model** picker lists it. Only third-party providers'
        /// names go into messages, because the Apple choice's name marks it as the default.
        var name: String {
            switch self {
            case .apple: "Apple on-device (default)"
            case .anthropic: "Anthropic"
            case .openAI: "OpenAI"
            case .google: "Google Gemini"
            case .custom: "Custom (OpenAI compatible)"
            }
        }

        /// The model a new choice of this provider starts with: the recommended model of
        /// `DesignModels`, each provider's fast, low-cost tier. The reader can pick or type
        /// another. Empty for the Apple choice and the custom endpoint.
        var defaultModel: String { DesignModels.bundled.recommended(for: self)?.id ?? "" }

        /// The endpoint for the provider's API. A custom provider names its own.
        var defaultBaseURL: String {
            switch self {
            case .apple, .custom: ""
            case .anthropic: "https://api.anthropic.com/v1"
            case .openAI: "https://api.openai.com/v1"
            case .google: "https://generativelanguage.googleapis.com/v1beta"
            }
        }

        /// The Keychain item that holds this provider's API key.
        var key: KeychainSecret { KeychainSecret(service: Self.keyService, account: rawValue) }

        /// Unit tests keep keys of their own, so a test run never reads the keys that the app
        /// saved on the same device.
        private static let keyService =
            SpineDesigner.isUnitTest
            ? "gay.ian.Bookworms.ai-provider.tests" : "gay.ian.Bookworms.ai-provider"
    }

    /// No backup model.
    static let appleOnly = SpineDesigner(provider: .apple, model: "", baseURL: "")

    var provider: Provider
    var model: String
    var baseURL: String
    /// The thinking level that each request asks for, in the provider's own words, such as
    /// Gemini's `thinkingLevel` "low" or Anthropic's effort "medium"; empty for a model without
    /// thinking levels and for the custom endpoint, whose requests set none. `ProviderModel`
    /// declares reasoning only when it is set.
    var thinking = ""

    private static let providerKey = "SpineDesignerProvider"
    private static let modelKey = "SpineDesignerModel"
    private static let baseURLKey = "SpineDesignerBaseURL"
    private static let rejectionKey = "SpineDesignerRejection"
    /// Each provider keeps its own thinking level, so switching providers and back restores it.
    private static func thinkingKey(_ provider: Provider) -> String {
        "SpineDesignerThinking.\(provider.rawValue)"
    }

    /// The user defaults that hold the choice and the remembered rejection. Unit tests keep a
    /// suite of their own, as they keep their own keys, so a test run never reads or changes the
    /// choice that the app saved on the same device.
    private static var defaults: UserDefaults {
        isUnitTest ? UserDefaults(suiteName: "gay.ian.Bookworms.tests")! : .standard
    }
    private static let isUnitTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// The saved choice, or no backup model.
    static var current: SpineDesigner {
        let provider = defaults.string(forKey: providerKey).flatMap(Provider.init) ?? .apple
        let model = defaults.string(forKey: modelKey) ?? provider.defaultModel
        return SpineDesigner(
            provider: provider, model: model,
            baseURL: defaults.string(forKey: baseURLKey) ?? provider.defaultBaseURL,
            thinking: thinking(
                saved: defaults.string(forKey: thinkingKey(provider)), provider: provider,
                model: model))
    }

    /// The thinking level for `model`: `saved`, unless `DesignModels` lists the model without
    /// that level, which gives the listed model's default. A model that the list doesn't name
    /// keeps `saved`, which Settings sets only after the provider confirms the model thinks.
    /// Without a saved level, as in settings saved before thinking levels, a listed model starts
    /// at its default and any other at none. The custom endpoint never sets one.
    static func thinking(saved: String?, provider: Provider, model: String) -> String {
        guard provider != .apple, provider != .custom else { return "" }
        let listed = DesignModels.bundled.model(model, of: provider)
        guard let saved else { return listed?.thinkingDefault ?? "" }
        guard let listed, !saved.isEmpty else { return saved }
        return listed.thinking?.contains(saved) == true ? saved : listed.thinkingDefault ?? ""
    }

    func save() {
        Self.defaults.set(provider.rawValue, forKey: Self.providerKey)
        Self.defaults.set(model, forKey: Self.modelKey)
        Self.defaults.set(baseURL, forKey: Self.baseURLKey)
        Self.defaults.set(thinking, forKey: Self.thinkingKey(provider))
    }

    /// Asks the provider whether this device's key can use `model` (`ProviderHTTP.check(_:key:)`),
    /// away from the main actor, because it reads the Keychain and waits for the network. Returns
    /// `nil` without a key or when the provider's answer doesn't say.
    @concurrent func availability() async -> ModelCheck? {
        guard let key = provider.key.read(), !key.isEmpty else { return nil }
        return await ProviderHTTP.check(self, key: key)
    }

    /// Why this choice cannot design yet, such as no provider or a missing key or model name;
    /// `nil` when it can. It reads the Keychain. The text names no place, because the Spines tab
    /// shows it beside **Choose model**, which opens Settings on the Mac.
    var problem: String? {
        switch provider {
        case .apple: return "Choose a provider."
        case .custom where URL(string: baseURL)?.scheme == nil:
            return "Enter the endpoint's base URL."
        case .anthropic, .openAI, .google:
            if provider.key.read()?.isEmpty ?? true {
                return "Add your \(provider.name) API key."
            }
        default: break
        }
        return model.isEmpty ? "Enter a model name." : nil
    }

    /// The provider's message when it last rejected these settings for every request, such as a
    /// revoked key, an unknown model name, or an account without credit
    /// (`ProviderError.isLasting`); `nil` when it hasn't. It reads the Keychain.
    ///
    /// The rejection lasts until the reader changes the provider, model name, base URL, thinking
    /// level, or key, or starts **Generate now** (`forgetRejection()`), so runs don't send each
    /// book's first request to a model that refuses them all.
    var rejection: String? {
        guard
            let saved = Self.defaults.dictionary(forKey: Self.rejectionKey)
                as? [String: String],
            saved["settings"] == settingsID
        else { return nil }
        return saved["message"]
    }

    /// Remembers `message` as the provider's lasting rejection of these settings (`rejection`),
    /// unless this device's key is no longer `sentKey`, the key of the rejected request. A late
    /// rejection of a key the reader has since replaced says nothing about the new key, which
    /// the settings ID can't tell apart. The keys are compared in memory, and nothing about
    /// them is saved. Returns whether it remembered the rejection.
    @discardableResult func rememberRejection(_ message: String, sentKey: String?) -> Bool {
        guard provider.key.read() == sentKey else { return false }
        Self.defaults.set(["settings": settingsID, "message": message], forKey: Self.rejectionKey)
        return true
    }

    /// Forgets a remembered rejection, because the reader changed the settings or started
    /// **Generate now**, and returns its message, or `nil` without one. A new key needs this: the
    /// settings ID records only whether a key exists.
    @discardableResult static func forgetRejection() -> String? {
        let message = (defaults.dictionary(forKey: rejectionKey) as? [String: String])?["message"]
        defaults.removeObject(forKey: rejectionKey)
        return message
    }

    /// Identifies these settings for `rejection`: the provider, model name, base URL, thinking
    /// level, and whether this device holds a key, never the key itself, which stays in the
    /// Keychain.
    private var settingsID: String {
        let hasKey = !(provider.key.read()?.isEmpty ?? true)
        return [provider.rawValue, model, baseURL, thinking, hasKey ? "key" : "no key"]
            .joined(separator: "\n")
    }

    /// The model token for a design this backup model makes, such as
    /// "model:anthropic/claude-haiku-5-5", within `provenance`'s 80 characters; `nil` without a
    /// backup model.
    var provenance: String? {
        guard provider != .apple else { return nil }
        return String("model:\(provider.rawValue)/\(model)".prefix(80))
    }
}

extension SpineDesigner {
    /// A new choice of `provider`: its recommended model and endpoint, at the thinking level
    /// saved for the provider when that model takes it.
    init(choosing provider: Provider) {
        self.init(
            provider: provider, model: provider.defaultModel, baseURL: provider.defaultBaseURL)
        thinking = Self.thinking(
            saved: Self.defaults.string(forKey: Self.thinkingKey(provider)), provider: provider,
            model: model)
    }
}

/// The models that the **Model name** picker lists for each preset provider, read from the
/// bundled `DesignModels.json`, which the README's "Design model list" describes. A monthly
/// check edits that file, so the code names no model.
struct DesignModels: Sendable {
    struct Model: Decodable, Hashable, Identifiable, Sendable {
        var provider: SpineDesigner.Provider
        var id: String
        var label: String
        /// "low-cost" or "stronger".
        var tier: String
        /// Whether a new choice of the provider starts with this model.
        var recommended: Bool?
        /// The provider's thinking levels for this model, cheapest first; `nil` for a model
        /// without them.
        var thinking: [String]?
        var thinkingDefault: String?

        /// The picker's label, with a star for the provider's recommended model.
        var pickerLabel: String { recommended == true ? "★ \(label)" : label }
    }

    /// The day someone last checked the list against the providers' model pages, as yyyy-MM-dd.
    let checked: String
    /// Each preset provider's models, in the file's order.
    let models: [SpineDesigner.Provider: [Model]]

    static let bundled = DesignModels(
        contentsOf: Bundle.main.url(forResource: "DesignModels", withExtension: "json"))

    /// Decodes the list at `url`. A missing or malformed file lists no models, so each picker
    /// offers only **Custom…**; the unit tests check the bundled file.
    init(contentsOf url: URL?) {
        struct File: Decodable {
            var checked: String
            var models: [Model]
        }
        let file = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        checked = file?.checked ?? ""
        models = Dictionary(grouping: file?.models ?? [], by: \.provider)
    }

    func model(_ id: String, of provider: SpineDesigner.Provider) -> Model? {
        models[provider]?.first { $0.id == id }
    }

    func recommended(for provider: SpineDesigner.Provider) -> Model? {
        models[provider]?.first { $0.recommended == true }
    }
}

/// What a provider's get-model endpoint says about the chosen model and key
/// (`ProviderHTTP.check(_:key:)`).
enum ModelCheck: Equatable, Sendable {
    /// The key can use the model. `thinking` lists the thinking levels that the answer confirms,
    /// cheapest first, or is empty when it says the model doesn't think; `nil` when the answer
    /// doesn't say, as OpenAI's never does.
    case available(thinking: [String]?)
    /// The provider answered 403 or 404: this key can't use the model.
    case unavailable
    /// The provider rejected the key itself.
    case keyRejected
}

/// A failed request to a third-party provider.
struct ProviderError: LocalizedError {
    let provider: SpineDesigner.Provider
    /// The HTTP status, or `nil` when the response had no usable answer.
    let status: Int?
    let retryAfter: Date?
    let message: String
    /// The error body's `error.code`, else its `error.type`, else the first reason in Gemini's
    /// error details, such as OpenAI's "insufficient_quota" or Gemini's "API_KEY_INVALID".
    var code: String? = nil

    var errorDescription: String? { "\(provider.name): \(message)" }

    /// A rejected key or model name, or an account without credit, which every later request
    /// with these settings repeats: a 401 or 403, a 402 Payment Required, a 404, OpenAI's
    /// `insufficient_quota`, which it sends with a 429, or Gemini's `API_KEY_INVALID`, which it
    /// sends with a 400. Any other 400 fails one book, such as for its crop, unless the same
    /// message refuses several books in a row (`SpineWorker.RefusalStreak`).
    var isLasting: Bool {
        [401, 402, 403, 404].contains(status)
            || ["insufficient_quota", "API_KEY_INVALID"].contains(code)
    }
    /// A rate limit or outage, which a later run can get past.
    var isTransient: Bool { status == 429 || status == 529 || (status ?? 0) >= 500 }
}

/// A third-party model behind Apple's `LanguageModel` protocol, so `LanguageModelSession`
/// drives it with the same prompts, image attachments, and generation schemas as Apple's
/// models.
///
/// The executor turns the session's transcript into one HTTP request: instructions become the
/// system prompt, prompts and responses become user and assistant turns, images go as PNG data,
/// and the request's schema becomes the provider's JSON-schema output format. The answer's JSON
/// goes back to the session, which decodes it as `GeneratedContent`.
///
/// The model declares reasoning only with a thinking level (`SpineDesigner.thinking`), because
/// a session refuses a request with a reasoning level for a model without it before sending
/// anything. Every request then carries the reader's level in the provider's own terms, whatever
/// reasoning level the session's request names.
struct ProviderModel: LanguageModel {
    typealias Executor = ProviderExecutor

    let designer: SpineDesigner

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(
            designer.thinking.isEmpty
                ? [.vision, .guidedGeneration] : [.vision, .guidedGeneration, .reasoning])
    }

    var executorConfiguration: SpineDesigner { designer }
}

struct ProviderExecutor: LanguageModelExecutor {
    typealias Model = ProviderModel

    let designer: SpineDesigner

    init(configuration: SpineDesigner) throws {
        designer = configuration
    }

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest, model: ProviderModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        var conversation = ProviderConversation(request.transcript)
        let schema = try request.schema.map(ProviderConversation.jsonSchema)
        if let schema, let text = try? JSONSerialization.data(withJSONObject: schema) {
            // Also in words, for endpoints that ignore the output format.
            conversation.system +=
                "\nAnswer with only a JSON object that matches this JSON Schema: "
                + String(decoding: text, as: UTF8.self)
        }
        let text = try await ProviderHTTP.send(
            conversation, schema: schema, designer: designer)
        await channel.send(.response(action: .appendText(text, tokenCount: 0)))
    }
}

/// A transcript flattened into the system prompt and alternating turns that HTTP chat APIs take.
struct ProviderConversation {
    enum Part {
        case text(String)
        case png(Data)
    }

    struct Turn {
        var isUser: Bool
        var parts: [Part]
    }

    var system = ""
    var turns: [Turn] = []

    init(_ transcript: Transcript) {
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                system += Self.parts(instructions.segments).compactMap(\.text).joined()
            case .prompt(let prompt):
                turns.append(Turn(isUser: true, parts: Self.parts(prompt.segments)))
            case .response(let response):
                turns.append(Turn(isUser: false, parts: Self.parts(response.segments)))
            default:
                // Reasoning and tool entries have no counterpart in these requests.
                break
            }
        }
    }

    private static func parts(_ segments: [Transcript.Segment]) -> [Part] {
        segments.compactMap { segment in
            switch segment {
            case .text(let text): .text(text.content)
            case .structure(let structure): .text(structure.content.jsonString)
            case .attachment(let attachment):
                switch attachment.content {
                case .image(let image): png(image.cgImage).map(Part.png)
                @unknown default: nil
                }
            @unknown default: nil
            }
        }
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The schema as plain JSON Schema, without Apple's `x-order` key or the array bounds and
    /// titles that some providers' structured outputs reject. Callers still check the answer.
    static func jsonSchema(_ schema: GenerationSchema) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
        return (strip(object) as? [String: Any]) ?? [:]
    }

    private static func strip(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var kept: [String: Any] = [:]
            for (key, child) in object where !["x-order", "title", "maxItems"].contains(key) {
                kept[key] = strip(child)
            }
            if let minimum = kept["minItems"] as? Int, minimum > 1 { kept["minItems"] = 1 }
            return kept
        }
        if let array = value as? [Any] { return array.map(strip) }
        return value
    }
}

extension ProviderConversation.Part {
    var text: String? {
        if case .text(let text) = self { text } else { nil }
    }
}

/// The request and response shapes of each provider's chat API.
enum ProviderHTTP {
    static func send(
        _ conversation: ProviderConversation, schema: [String: Any]?, designer: SpineDesigner
    ) async throws -> String {
        let provider = designer.provider
        let key = provider.key.read() ?? ""
        let base = designer.baseURL.isEmpty ? provider.defaultBaseURL : designer.baseURL
        guard let root = URL(string: base) else {
            throw ProviderError(
                provider: provider, status: nil, retryAfter: nil, message: "The URL is invalid.")
        }
        var request: URLRequest
        let body: [String: Any]
        switch provider {
        case .anthropic:
            request = URLRequest(url: root.appending(path: "messages"))
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = anthropicBody(conversation, schema: schema, designer: designer)
        case .google:
            request = URLRequest(
                url: root.appending(path: "models/\(designer.model):generateContent"))
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            body = googleBody(conversation, schema: schema, thinking: designer.thinking)
        case .openAI, .custom:
            request = URLRequest(url: root.appending(path: "chat/completions"))
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            body = openAIBody(conversation, schema: schema, designer: designer)
        case .apple:
            preconditionFailure("Apple's models answer through LanguageModelSession directly.")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch let error as URLError where !SpineWorker.offlineErrors.contains(error.code) {
            // An endpoint that can't be reached, such as a local server that is off, would fail
            // every book, so the run stops and a later run tries again.
            throw CompanionError.modelBusy(nil)
        }
        let (data, response) = result
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init).map { Date.now.addingTimeInterval($0) }
            let error = json?["error"] as? [String: Any]
            var message =
                error?["message"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            // The app saves the message with the run's outcome and as a remembered rejection
            // (`SpineDesigner.rememberRejection(_:sentKey:)`), so a key that an endpoint echoes is
            // removed from it.
            if !key.isEmpty { message = message.replacingOccurrences(of: key, with: "…") }
            throw ProviderError(
                provider: provider, status: status, retryAfter: retryAfter, message: message,
                code: errorCode(in: json))
        }
        guard let text = answer(in: json, provider: provider), !text.isEmpty else {
            throw ProviderError(
                provider: provider, status: nil, retryAfter: nil,
                message: "The response had no answer.")
        }
        return text
    }

    /// Asks the provider's get-model endpoint whether `key` can use `designer.model`: Gemini's
    /// `GET models/{id}`, or Anthropic's or OpenAI's `GET v1/models/{id}`. It sends one request,
    /// never retries, and returns `nil` when the answer doesn't say, such as after a network
    /// failure, a timeout, or a server error, so a failed check never claims that the model is
    /// missing. Nothing about the key leaves this function except in the request's header.
    static func check(_ designer: SpineDesigner, key: String) async -> ModelCheck? {
        let provider = designer.provider
        let base = designer.baseURL.isEmpty ? provider.defaultBaseURL : designer.baseURL
        guard let root = URL(string: base), !designer.model.isEmpty else { return nil }
        var request = URLRequest(url: root.appending(path: "models/\(designer.model)"))
        request.timeoutInterval = 15
        switch provider {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .apple, .custom:
            return nil
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let status = (response as? HTTPURLResponse)?.statusCode
        else { return nil }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch status {
        case 200..<300: return .available(thinking: thinkingLevels(in: json, provider: provider))
        case 403, 404: return .unavailable
        case 401: return .keyRejected
        case 400 where errorCode(in: json) == "API_KEY_INVALID": return .keyRejected
        default: return nil
        }
    }

    /// The thinking levels that a get-model answer confirms, cheapest first: with Gemini's
    /// `thinking` flag, the levels that current Gemini text models take, and with
    /// Anthropic's `capabilities`, its supported effort levels. Empty when the answer says the
    /// model doesn't think; `nil` when it doesn't say.
    private static func thinkingLevels(in json: [String: Any]?, provider: SpineDesigner.Provider)
        -> [String]?
    {
        func supported(_ value: Any?) -> Bool {
            (value as? [String: Any])?["supported"] as? Bool == true
        }
        switch provider {
        case .google:
            guard let thinks = json?["thinking"] as? Bool else { return nil }
            return thinks ? ["low", "medium", "high"] : []
        case .anthropic:
            guard let capabilities = json?["capabilities"] as? [String: Any] else { return nil }
            let effort = capabilities["effort"] as? [String: Any]
            guard supported(capabilities["thinking"]), supported(effort) else { return [] }
            return ["low", "medium", "high", "xhigh", "max"].filter { supported(effort?[$0]) }
        default:
            return nil
        }
    }

    /// An error body's `error.code`, else its `error.type`, else the first reason in Gemini's
    /// error details.
    private static func errorCode(in json: [String: Any]?) -> String? {
        let error = json?["error"] as? [String: Any]
        let details = error?["details"] as? [[String: Any]]
        return error?["code"] as? String ?? error?["type"] as? String
            ?? details?.lazy.compactMap { $0["reason"] as? String }.first
    }

    /// The answer's text: Anthropic's text blocks, Gemini's first candidate, or the first chat
    /// choice's message.
    private static func answer(in json: [String: Any]?, provider: SpineDesigner.Provider)
        -> String?
    {
        switch provider {
        case .anthropic:
            guard json?["stop_reason"] as? String != "refusal" else { return nil }
            return (json?["content"] as? [[String: Any]])?
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
        case .google:
            let candidate = (json?["candidates"] as? [[String: Any]])?.first
            let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            return parts?.compactMap { $0["text"] as? String }.joined()
        default:
            let choice = (json?["choices"] as? [[String: Any]])?.first
            return (choice?["message"] as? [String: Any])?["content"] as? String
        }
    }

    private static func anthropicBody(
        _ conversation: ProviderConversation, schema: [String: Any]?, designer: SpineDesigner
    ) -> [String: Any] {
        let messages = conversation.turns.map { turn in
            [
                "role": turn.isUser ? "user" : "assistant",
                "content": turn.parts.map { part -> [String: Any] in
                    switch part {
                    case .text(let text): ["type": "text", "text": text]
                    case .png(let data):
                        [
                            "type": "image",
                            "source": [
                                "type": "base64", "media_type": "image/png",
                                "data": data.base64EncodedString(),
                            ],
                        ]
                    }
                },
            ] as [String: Any]
        }
        var body: [String: Any] = [
            "model": designer.model, "max_tokens": 16000, "messages": messages,
            "system": conversation.system,
        ]
        var output: [String: Any] = [:]
        if let schema { output["format"] = ["type": "json_schema", "schema": schema] }
        // Adaptive thinking is on by default; effort sets how much the model thinks.
        if !designer.thinking.isEmpty { output["effort"] = designer.thinking }
        if !output.isEmpty { body["output_config"] = output }
        return body
    }

    private static func openAIBody(
        _ conversation: ProviderConversation, schema: [String: Any]?, designer: SpineDesigner
    ) -> [String: Any] {
        var messages: [[String: Any]] = [["role": "system", "content": conversation.system]]
        messages += conversation.turns.map { turn in
            [
                "role": turn.isUser ? "user" : "assistant",
                "content": turn.parts.map { part -> [String: Any] in
                    switch part {
                    case .text(let text): ["type": "text", "text": text]
                    case .png(let data):
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/png;base64," + data.base64EncodedString()
                            ],
                        ]
                    }
                },
            ]
        }
        var body: [String: Any] = ["model": designer.model, "messages": messages]
        if !designer.thinking.isEmpty { body["reasoning_effort"] = designer.thinking }
        if let schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "answer", "schema": schema, "strict": false],
            ]
        }
        return body
    }

    private static func googleBody(
        _ conversation: ProviderConversation, schema: [String: Any]?, thinking: String
    ) -> [String: Any] {
        let contents = conversation.turns.map { turn in
            [
                "role": turn.isUser ? "user" : "model",
                "parts": turn.parts.map { part -> [String: Any] in
                    switch part {
                    case .text(let text): ["text": text]
                    case .png(let data):
                        [
                            "inline_data": [
                                "mime_type": "image/png", "data": data.base64EncodedString(),
                            ]
                        ]
                    }
                },
            ] as [String: Any]
        }
        var config: [String: Any] = [:]
        if let schema {
            config["responseMimeType"] = "application/json"
            config["responseJsonSchema"] = schema
        }
        if !thinking.isEmpty { config["thinkingConfig"] = ["thinkingLevel": thinking] }
        return [
            "systemInstruction": ["parts": [["text": conversation.system]]],
            "contents": contents, "generationConfig": config,
        ]
    }
}
