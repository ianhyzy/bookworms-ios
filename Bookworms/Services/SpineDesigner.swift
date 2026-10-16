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
/// The choice and model name live in `UserDefaults`; each provider's API key lives in this
/// device's Keychain (`KeychainSecret`), never synced. Third-party providers answer through
/// `ProviderModel`, so `BookAnalyzer` asks every provider the same questions with the same
/// schemas.
struct SpineDesigner: Hashable, Sendable {
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case apple, anthropic, openAI, google, custom

        var id: Self { self }

        var name: String {
            switch self {
            case .apple: "None"
            case .anthropic: "Anthropic"
            case .openAI: "OpenAI"
            case .google: "Google Gemini"
            case .custom: "Custom (OpenAI compatible)"
            }
        }

        /// The model a new choice of this provider starts with: each provider's fast, low-cost
        /// tier. The reader can type another.
        var defaultModel: String {
            switch self {
            case .apple: ""
            case .anthropic: "claude-haiku-5-5"
            case .openAI: "gpt-6-luna"
            case .google: "gemini-3.8-flash"
            case .custom: ""
            }
        }

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
        var key: KeychainSecret {
            KeychainSecret(service: "gay.ian.Bookworms.ai-provider", account: rawValue)
        }
    }

    /// No backup model.
    static let appleOnly = SpineDesigner(provider: .apple, model: "", baseURL: "")

    var provider: Provider
    var model: String
    var baseURL: String

    private static let providerKey = "SpineDesignerProvider"
    private static let modelKey = "SpineDesignerModel"
    private static let baseURLKey = "SpineDesignerBaseURL"
    private static let rejectionKey = "SpineDesignerRejection"

    /// The saved choice, or no backup model.
    static var current: SpineDesigner {
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: providerKey).flatMap(Provider.init) ?? .apple
        return SpineDesigner(
            provider: provider,
            model: defaults.string(forKey: modelKey) ?? provider.defaultModel,
            baseURL: defaults.string(forKey: baseURLKey) ?? provider.defaultBaseURL)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(baseURL, forKey: Self.baseURLKey)
    }

    /// Why this choice cannot design yet, such as no backup model or a missing key or model name;
    /// `nil` when it can. It reads the Keychain. The text names no place, because the Spines tab
    /// shows it beside **Choose Backup Model**, which opens Settings on the Mac.
    var problem: String? {
        switch provider {
        case .apple: return "Choose a backup model."
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
    /// The rejection lasts until the reader changes the provider, model name, base URL, or key
    /// (`forgetRejection()`), so runs don't send each book's first request to a model that
    /// refuses them all.
    var rejection: String? {
        guard
            let saved = UserDefaults.standard.dictionary(forKey: Self.rejectionKey)
                as? [String: String],
            saved["settings"] == settingsID
        else { return nil }
        return saved["message"]
    }

    /// Remembers `message` as the provider's lasting rejection of these settings (`rejection`).
    func rememberRejection(_ message: String) {
        UserDefaults.standard.set(
            ["settings": settingsID, "message": message], forKey: Self.rejectionKey)
    }

    /// Forgets a remembered rejection, because the reader changed the settings, and returns its
    /// message, or `nil` without one. A new key needs this: the settings ID records only whether
    /// a key exists.
    @discardableResult static func forgetRejection() -> String? {
        let defaults = UserDefaults.standard
        let message = (defaults.dictionary(forKey: rejectionKey) as? [String: String])?["message"]
        defaults.removeObject(forKey: rejectionKey)
        return message
    }

    /// Identifies these settings for `rejection`: the provider, model name, base URL, and
    /// whether this device holds a key, never the key itself, which stays in the Keychain.
    private var settingsID: String {
        let hasKey = !(provider.key.read()?.isEmpty ?? true)
        return [provider.rawValue, model, baseURL, hasKey ? "key" : "no key"]
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
struct ProviderModel: LanguageModel {
    typealias Executor = ProviderExecutor

    let designer: SpineDesigner

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.vision, .guidedGeneration])
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
            body = anthropicBody(conversation, schema: schema, model: designer.model)
        case .google:
            request = URLRequest(
                url: root.appending(path: "models/\(designer.model):generateContent"))
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            body = googleBody(conversation, schema: schema)
        case .openAI, .custom:
            request = URLRequest(url: root.appending(path: "chat/completions"))
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            body = openAIBody(conversation, schema: schema, model: designer.model)
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
            // (`SpineDesigner.rememberRejection(_:)`), so a key that an endpoint echoes is
            // removed from it.
            if !key.isEmpty { message = message.replacingOccurrences(of: key, with: "…") }
            let details = error?["details"] as? [[String: Any]]
            throw ProviderError(
                provider: provider, status: status, retryAfter: retryAfter, message: message,
                code: error?["code"] as? String ?? error?["type"] as? String
                    ?? details?.lazy.compactMap { $0["reason"] as? String }.first)
        }
        guard let text = answer(in: json, provider: provider), !text.isEmpty else {
            throw ProviderError(
                provider: provider, status: nil, retryAfter: nil,
                message: "The response had no answer.")
        }
        return text
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
        _ conversation: ProviderConversation, schema: [String: Any]?, model: String
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
            "model": model, "max_tokens": 16000, "messages": messages,
            "system": conversation.system,
        ]
        if let schema {
            body["output_config"] = ["format": ["type": "json_schema", "schema": schema]]
        }
        return body
    }

    private static func openAIBody(
        _ conversation: ProviderConversation, schema: [String: Any]?, model: String
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
        var body: [String: Any] = ["model": model, "messages": messages]
        if let schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "answer", "schema": schema, "strict": false],
            ]
        }
        return body
    }

    private static func googleBody(_ conversation: ProviderConversation, schema: [String: Any]?)
        -> [String: Any]
    {
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
        return [
            "systemInstruction": ["parts": [["text": conversation.system]]],
            "contents": contents, "generationConfig": config,
        ]
    }
}
