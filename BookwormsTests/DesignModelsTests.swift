import Foundation
import XCTest

@testable import Bookworms

/// Covers the backup model's curated list, how saved settings map onto it, and the check that a
/// key can use the chosen model. A stub answers every check, so no request leaves the device
/// and no test reads a real key.
final class DesignModelsTests: XCTestCase {
    private let presets: [SpineDesigner.Provider] = [.anthropic, .openAI, .google]

    func testTheBundledListOffersEachPresetProviderACheapRecommendedModel() throws {
        let list = DesignModels.bundled
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        date.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertNotNil(date.date(from: list.checked), "checked is a yyyy-MM-dd date")
        XCTAssertNil(list.models[.apple])
        XCTAssertNil(list.models[.custom], "The custom endpoint has only the field")
        for provider in presets {
            let models = try XCTUnwrap(list.models[provider], "\(provider)")
            XCTAssertEqual(Set(models.map(\.id)).count, models.count, "IDs are unique")
            let recommended = models.filter { $0.recommended == true }
            XCTAssertEqual(recommended.count, 1, "\(provider) recommends one model")
            XCTAssertEqual(recommended.first?.tier, "low-cost", "Never the priciest by default")
            XCTAssertEqual(provider.defaultModel, recommended.first?.id)
            XCTAssertEqual(list.recommended(for: provider)?.pickerLabel.first, "★")
            for model in models {
                XCTAssertTrue(["low-cost", "stronger"].contains(model.tier), model.id)
                XCTAssertFalse(model.label.contains("★"), "The picker adds the star")
                XCTAssertEqual(model.pickerLabel.hasPrefix("★ "), model.recommended == true)
                if let levels = model.thinking {
                    XCTAssertFalse(levels.isEmpty, model.id)
                    XCTAssertTrue(
                        levels.contains(model.thinkingDefault ?? ""), "\(model.id)'s default")
                } else {
                    XCTAssertNil(model.thinkingDefault, model.id)
                }
            }
        }
    }

    func testAMissingOrMalformedListOffersOnlyCustom() throws {
        XCTAssertTrue(DesignModels(contentsOf: nil).models.isEmpty)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "DesignModels.json")
        try Data(#"{"checked":"2026-10-21","models":[{"provider":"nobody"}]}"#.utf8).write(to: file)
        XCTAssertTrue(DesignModels(contentsOf: file).models.isEmpty)
    }

    /// A saved model ID that the list names selects it; any other shows as **Custom…** with its
    /// ID, and settings saved before thinking levels keep their provider, model, and endpoint.
    func testSavedChoicesCarryOver() throws {
        let list = DesignModels.bundled
        let google = try XCTUnwrap(list.recommended(for: .google))
        XCTAssertEqual(list.model(google.id, of: .google), google)
        XCTAssertNil(list.model("gemini-fictional-model", of: .google), "Shows as Custom…")
        XCTAssertNil(list.model(google.id, of: .anthropic), "Each provider has its own list")

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "gay.ian.Bookworms.tests"))
        let keys = [
            "SpineDesignerProvider", "SpineDesignerModel", "SpineDesignerBaseURL",
            "SpineDesignerThinking.google",
        ]
        let before = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, before) { defaults.set(value, forKey: key) }
        }
        // Settings from before the picker: a listed model starts at its default level.
        defaults.set("google", forKey: "SpineDesignerProvider")
        defaults.set(google.id, forKey: "SpineDesignerModel")
        defaults.set("https://generativelanguage.googleapis.com/v1beta", forKey: keys[2])
        defaults.removeObject(forKey: "SpineDesignerThinking.google")
        var current = SpineDesigner.current
        XCTAssertEqual(current.provider, .google)
        XCTAssertEqual(current.model, google.id)
        XCTAssertEqual(current.baseURL, "https://generativelanguage.googleapis.com/v1beta")
        XCTAssertEqual(current.thinking, google.thinkingDefault)
        // An unlisted model keeps its ID and sends no level until the provider confirms one.
        defaults.set("gemini-fictional-model", forKey: "SpineDesignerModel")
        current = SpineDesigner.current
        XCTAssertEqual(current.model, "gemini-fictional-model")
        XCTAssertEqual(current.thinking, "")
        // A saved level stays while the model takes it, and switching providers restores it.
        current.model = google.id
        current.thinking = try XCTUnwrap(google.thinking?.last)
        current.save()
        XCTAssertEqual(SpineDesigner.current, current)
        XCTAssertEqual(SpineDesigner(choosing: .google).thinking, google.thinking?.last)
        XCTAssertEqual(
            SpineDesigner.thinking(saved: "fictional-level", provider: .google, model: google.id),
            google.thinkingDefault, "A level the model doesn't take becomes its default")
        XCTAssertEqual(
            SpineDesigner.thinking(saved: "low", provider: .custom, model: "local-model"), "",
            "The custom endpoint sends no level")
    }

    func testTheCheckAsksEachProviderForTheModel() async throws {
        ModelStub.reset()
        URLProtocol.registerClass(ModelStub.self)
        defer { URLProtocol.unregisterClass(ModelStub.self) }
        func check(_ provider: SpineDesigner.Provider, _ model: String, path: String)
            async -> ModelCheck?
        {
            await ProviderHTTP.check(
                SpineDesigner(
                    provider: provider, model: model,
                    baseURL: "https://\(ModelStub.host)/\(path)"),
                key: "fictional-key")
        }

        ModelStub.reply = (200, #"{"name":"models/gemini-fictional","thinking":true}"#)
        let gemini = await check(.google, "gemini-fictional", path: "v1beta")
        XCTAssertEqual(gemini, .available(thinking: ["low", "medium", "high"]))
        XCTAssertEqual(ModelStub.last?.url?.path, "/v1beta/models/gemini-fictional")
        XCTAssertEqual(ModelStub.last?.httpMethod, "GET")
        XCTAssertEqual(
            ModelStub.last?.value(forHTTPHeaderField: "x-goog-api-key"), "fictional-key")

        ModelStub.reply = (200, #"{"name":"models/gemini-plain","thinking":false}"#)
        let plain = await check(.google, "gemini-plain", path: "v1beta")
        XCTAssertEqual(plain, .available(thinking: []))

        ModelStub.reply = (
            200,
            #"{"id":"claude-fictional","capabilities":{"thinking":{"supported":true},"effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":null,"max":{"supported":false}}}}"#
        )
        let claude = await check(.anthropic, "claude-fictional", path: "v1")
        XCTAssertEqual(claude, .available(thinking: ["low", "medium", "high"]))
        XCTAssertEqual(ModelStub.last?.url?.path, "/v1/models/claude-fictional")
        XCTAssertEqual(ModelStub.last?.value(forHTTPHeaderField: "x-api-key"), "fictional-key")
        XCTAssertNotNil(ModelStub.last?.value(forHTTPHeaderField: "anthropic-version"))

        // OpenAI's model details never say whether a model reasons.
        ModelStub.reply = (200, #"{"id":"gpt-fictional","object":"model","owned_by":"openai"}"#)
        let openAI = await check(.openAI, "gpt-fictional", path: "v1")
        XCTAssertEqual(openAI, .available(thinking: nil))
        XCTAssertEqual(
            ModelStub.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fictional-key")
        XCTAssertEqual(ModelStub.requests, 4, "Each check sends one request")
    }

    func testTheCheckReportsAMissingModelOrRejectedKeyAndOtherwiseSaysNothing() async {
        ModelStub.reset()
        URLProtocol.registerClass(ModelStub.self)
        defer { URLProtocol.unregisterClass(ModelStub.self) }
        let designer = SpineDesigner(
            provider: .google, model: "gemini-fictional",
            baseURL: "https://\(ModelStub.host)/v1beta")
        func check() async -> ModelCheck? {
            await ProviderHTTP.check(designer, key: "fictional-key")
        }

        ModelStub.reply = (404, #"{"error":{"code":404,"status":"NOT_FOUND"}}"#)
        let missing = await check()
        XCTAssertEqual(missing, .unavailable)
        ModelStub.reply = (403, #"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#)
        let denied = await check()
        XCTAssertEqual(denied, .unavailable)
        ModelStub.reply = (
            400, #"{"error":{"code":400,"details":[{"reason":"API_KEY_INVALID"}]}}"#
        )
        let invalidKey = await check()
        XCTAssertEqual(invalidKey, .keyRejected)
        ModelStub.reply = (401, #"{"error":{"type":"authentication_error"}}"#)
        let unauthorized = await check()
        XCTAssertEqual(unauthorized, .keyRejected)

        // A server error or a network failure claims nothing, and nothing retries.
        ModelStub.reply = (503, "{}")
        let outage = await check()
        XCTAssertNil(outage)
        ModelStub.reply = nil
        let offline = await check()
        XCTAssertNil(offline)
        XCTAssertEqual(ModelStub.requests, 6)

        let custom = SpineDesigner(
            provider: .custom, model: "local-model", baseURL: "https://\(ModelStub.host)/v1")
        let unchecked = await ProviderHTTP.check(custom, key: "fictional-key")
        XCTAssertNil(unchecked, "The custom endpoint isn't checked")
        XCTAssertEqual(ModelStub.requests, 6)
    }
}

/// Answers get-model requests with `reply`, or fails them as offline when it is `nil`.
private final class ModelStub: URLProtocol {
    static let host = "models.localhost"
    nonisolated(unsafe) static var reply: (status: Int, body: String)?
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var last: URLRequest?

    static func reset() {
        reply = nil
        requests = 0
        last = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.last = request
        guard let reply = Self.reply, let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
