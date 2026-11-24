import CloudKit
import CoreText
import Foundation
import FoundationModels
import ImageIO
import Security
import Synchronization
import XCTest

@testable import Bookworms

/// Covers generation's decisions: error handling, quota stops, the lettering answers' font
/// choices, title measurement, and a recheck against a local store. No test calls a model, the
/// network, or iCloud.
final class GenerationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        allowThirdPartyProviders()
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testProviderSchemaDropsKeysProvidersReject() throws {
        let family = DynamicGenerationSchema(name: "family", anyOf: ["Lora", "EB Garamond"])
        let root = DynamicGenerationSchema(
            name: "Ranking",
            properties: [
                .init(
                    name: "ranked",
                    schema: DynamicGenerationSchema(
                        arrayOf: family, minimumElements: 2, maximumElements: 2))
            ])
        let schema = try ProviderConversation.jsonSchema(
            GenerationSchema(root: root, dependencies: []))
        XCTAssertNil(schema["x-order"])
        XCTAssertNil(schema["title"])
        let ranked = try XCTUnwrap(
            (schema["properties"] as? [String: Any])?["ranked"] as? [String: Any])
        XCTAssertNil(ranked["maxItems"])
        XCTAssertEqual(ranked["minItems"] as? Int, 1)
        XCTAssertEqual(schema["required"] as? [String], ["ranked"])
    }

    /// The backup model's cover-lettering request reaches the provider: a session refuses a
    /// request with a reasoning level for a model without `.reasoning`, as `ProviderModel` is
    /// without a thinking level, before it sends anything, which failed every book of a Gemini
    /// run. A stub answers for Gemini, so no request leaves the device.
    func testBackupModelRequestsReachTheProviderWithoutAReasoningLevel() async throws {
        ProviderStub.reset()
        URLProtocol.registerClass(ProviderStub.self)
        let removeKeys = try Self.saveFictionalKeys(for: [.google])
        defer {
            URLProtocol.unregisterClass(ProviderStub.self)
            removeKeys()
        }
        let model = ProviderModel(
            designer: SpineDesigner(
                provider: .google, model: "gemini-fictional-model",
                baseURL: "https://\(ProviderStub.host)/v1beta"))
        XCTAssertFalse(model.capabilities.contains(.reasoning))
        XCTAssertNil(BookAnalyzer.readingOptions(for: model).reasoningLevel)
        let answer = try await Self.askLettering(model, BookAnalyzer.readingOptions(for: model))
        XCTAssertEqual(answer, "plain")
        XCTAssertEqual(ProviderStub.requests, 1)
        let config = ProviderStub.lastBody?["generationConfig"] as? [String: Any]
        XCTAssertNil(config?["thinkingConfig"], "A model without thinking levels gets none")
        do {
            _ = try await Self.askLettering(
                model, ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .light))
            XCTFail("The session should refuse a reasoning level for this model")
        } catch LanguageModelError.unsupportedCapability {
            XCTAssertEqual(ProviderStub.requests, 1, "The refused request never reached Gemini")
        }
    }

    /// A provider request that times out or can't connect reaches the worker as
    /// `CompanionError.providerUnreachable`, which retries the book; a host that can't be found
    /// stops the run; and an `http` address that App Transport Security blocks is a lasting
    /// rejection. A stub answers, so no request leaves the device.
    func testProviderTimeoutsReachTheWorkerAsUnreachable() async throws {
        ProviderStub.reset()
        URLProtocol.registerClass(ProviderStub.self)
        let removeKeys = try Self.saveFictionalKeys(for: [.google])
        defer {
            URLProtocol.unregisterClass(ProviderStub.self)
            ProviderStub.reset()
            removeKeys()
        }
        let model = ProviderModel(
            designer: SpineDesigner(
                provider: .google, model: "gemini-fictional-model",
                baseURL: "https://\(ProviderStub.host)/v1beta"))
        for code in [
            URLError.Code.timedOut, .cannotConnectToHost, .cannotFindHost,
            .appTransportSecurityRequiresSecureConnection,
        ] {
            ProviderStub.failure = code
            do {
                _ = try await Self.askLettering(model, BookAnalyzer.readingOptions(for: model))
                XCTFail("Expected a failure for \(code)")
            } catch {
                switch (code, error) {
                case (.cannotFindHost, CompanionError.modelBusy(nil)),
                    (.timedOut, CompanionError.providerUnreachable),
                    (.cannotConnectToHost, CompanionError.providerUnreachable),
                    (.appTransportSecurityRequiresSecureConnection, CompanionError.providerRejected):
                    break
                default: XCTFail("\(code): \(error)")
                }
            }
        }
    }

    /// A preset provider without a saved key, such as after the reader removed it during a run,
    /// gets no request: the request fails as the missing key's rejection, which moves the run to
    /// the next tier. A stub would answer, so no request leaves the device either way.
    func testAProviderWithoutAKeyGetsNoRequest() async throws {
        ProviderStub.reset()
        URLProtocol.registerClass(ProviderStub.self)
        defer {
            URLProtocol.unregisterClass(ProviderStub.self)
            ProviderStub.reset()
        }
        SpineDesigner.Provider.google.key.delete()
        let model = ProviderModel(
            designer: SpineDesigner(
                provider: .google, model: "gemini-fictional-model",
                baseURL: "https://\(ProviderStub.host)/v1beta"))
        do {
            _ = try await Self.askLettering(model, BookAnalyzer.readingOptions(for: model))
            XCTFail("A request without a key should fail")
        } catch CompanionError.providerRejected(let reason) {
            XCTAssertEqual(reason, "Add your Google Gemini API key.")
        }
        XCTAssertEqual(ProviderStub.requests, 0)
    }

    /// A key that outlasts the reader's consent, as the Keychain keeps it when the app is deleted
    /// and installed again, counts as not saved: the provider isn't set up, the settings ask
    /// about the key, and no request reaches the provider. Once the reader allows the provider,
    /// the same key counts. So a custom endpoint, which may need no key, gets no request either.
    /// A stub would answer, so no request leaves the device either way.
    func testASavedKeyWithoutConsentGetsNoRequest() async throws {
        ProviderStub.reset()
        URLProtocol.registerClass(ProviderStub.self)
        let removeKeys = try Self.saveFictionalKeys(for: [.google])
        defer {
            URLProtocol.unregisterClass(ProviderStub.self)
            ProviderStub.reset()
            removeKeys()
        }
        ProviderConsent.forget()
        let google = SpineDesigner(
            provider: .google, model: "gemini-fictional-model",
            baseURL: "https://\(ProviderStub.host)/v1beta")
        let custom = SpineDesigner(
            provider: .custom, model: "local-model", baseURL: "https://\(ProviderStub.host)/v1")
        let addKey = "Add your Google Gemini API key."
        let addURL = "Enter your endpoint's base URL, starting with http:// or https://."

        XCTAssertEqual(SpineDesigner.Provider.google.savedKey(), .awaitsConsent)
        XCTAssertEqual(google.requestKey(), .missing(addKey))
        XCTAssertEqual(google.problem, addKey, "The provider counts as not set up")
        XCTAssertEqual(custom.readiness { nil }.problem, addURL)
        let check = await google.availability()
        XCTAssertNil(check, "The model check sends the key, so it waits too")
        for (designer, message) in [(google, addKey), (custom, addURL)] {
            let model = ProviderModel(designer: designer)
            do {
                _ = try await Self.askLettering(model, BookAnalyzer.readingOptions(for: model))
                XCTFail("\(designer.provider) should get no request without consent")
            } catch CompanionError.providerRejected(let reason) {
                XCTAssertEqual(reason, message)
            }
        }
        XCTAssertEqual(ProviderStub.requests, 0)

        SpineDesigner.allow(.google)
        XCTAssertEqual(SpineDesigner.Provider.google.savedKey(), .usable)
        XCTAssertEqual(google.requestKey(), .key("fictional-key-google"))
        XCTAssertNil(google.problem)
        let model = ProviderModel(designer: google)
        _ = try await Self.askLettering(model, BookAnalyzer.readingOptions(for: model))
        XCTAssertEqual(ProviderStub.requests, 1, "The saved key carries requests once allowed")
        XCTAssertEqual(
            SpineDesigner.Provider.anthropic.savedKey(), .none, "No key, so nothing to ask about")
    }

    /// Saves a fictional key for each of `providers` in the tests' own Keychain service, so
    /// their requests carry a key, and returns the closure that removes the keys.
    private static func saveFictionalKeys(for providers: [SpineDesigner.Provider]) throws
        -> () -> Void
    {
        for provider in providers { try provider.key.save("fictional-key-\(provider.rawValue)") }
        return { for provider in providers { provider.key.delete() } }
    }

    /// A backup model with a thinking level declares reasoning, so the cover-lettering request
    /// asks for a light level and reaches the provider, which receives the reader's level in its
    /// own terms. Stubs answer for each provider, so no request leaves the device.
    func testThinkingBackupModelsSendTheReadersLevel() async throws {
        ProviderStub.reset()
        URLProtocol.registerClass(ProviderStub.self)
        let removeKeys = try Self.saveFictionalKeys(for: [.google, .anthropic, .openAI])
        defer {
            URLProtocol.unregisterClass(ProviderStub.self)
            removeKeys()
        }
        let host = "https://\(ProviderStub.host)"
        let cases: [(SpineDesigner, (([String: Any]?) -> Any?))] = [
            (
                SpineDesigner(
                    provider: .google, model: "gemini-3.8-flash", baseURL: "\(host)/v1beta",
                    thinking: "low"),
                {
                    (($0?["generationConfig"] as? [String: Any])?["thinkingConfig"]
                        as? [String: Any])?["thinkingLevel"]
                }
            ),
            (
                SpineDesigner(
                    provider: .anthropic, model: "claude-haiku-5-5", baseURL: "\(host)/v1",
                    thinking: "medium"),
                { ($0?["output_config"] as? [String: Any])?["effort"] }
            ),
            (
                SpineDesigner(
                    provider: .openAI, model: "gpt-6-luna", baseURL: "\(host)/v1",
                    thinking: "high"),
                { $0?["reasoning_effort"] }
            ),
        ]
        for (designer, level) in cases {
            let model = ProviderModel(designer: designer)
            XCTAssertTrue(model.capabilities.contains(.reasoning))
            let options = BookAnalyzer.readingOptions(for: model)
            XCTAssertEqual(options.reasoningLevel, .light)
            let answer = try await Self.askLettering(model, options)
            XCTAssertEqual(answer, "plain", "\(designer.provider)")
            XCTAssertEqual(
                level(ProviderStub.lastBody) as? String, designer.thinking, "\(designer.provider)")
        }
        XCTAssertEqual(ProviderStub.requests, 3)
        let anthropic = ProviderModel(designer: cases[1].0)
        _ = try await Self.askLettering(anthropic, ContextOptions(includeSchemaInPrompt: true))
        let output = ProviderStub.lastBody?["output_config"] as? [String: Any]
        XCTAssertNotNil(output?["format"], "The effort joins the schema's output format")
    }

    /// Asks `model` the cover-lettering question about a small blank image, with `options`.
    private static func askLettering(_ model: ProviderModel, _ options: ContextOptions)
        async throws -> String
    {
        let schema = try GenerationSchema(
            root: DynamicGenerationSchema(
                name: "Reading",
                properties: [
                    .init(
                        name: "treatment",
                        schema: DynamicGenerationSchema(
                            name: "treatment", anyOf: BookAnalyzer.treatments))
                ]),
            dependencies: [])
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        return try await LanguageModelSession(model: model)
            .respond(schema: schema, contextOptions: options) {
                "Describe the title lettering."
                Attachment(image)
            }
            .content.value(String.self, forProperty: "treatment")
    }

    func testProviderErrorsStopTheRunWhenEveryBookWouldFail() {
        func failure(_ status: Int, code: String? = nil) -> CompanionError? {
            BookAnalyzer.modelFailure(
                ProviderError(
                    provider: .openAI, status: status, retryAfter: nil, message: "x", code: code))
        }
        guard case .providerRejected = failure(401), case .providerRejected = failure(403),
            case .providerRejected = failure(404),
            case .providerRejected = failure(400, code: "API_KEY_INVALID"),
            case .modelBusy = failure(429),
            case .modelBusy = failure(429, code: "rate_limit_exceeded"),
            case .providerUnreachable = failure(500), case .providerUnreachable = failure(503),
            case .providerUnreachable = failure(529)
        else { return XCTFail("Provider errors map to the wrong dispositions") }
        // An account without credit fails every book, so the run moves to the next tier.
        guard case .providerRejected = failure(402),
            case .providerRejected = failure(429, code: "insufficient_quota")
        else { return XCTFail("An account without credit should move the run to the next tier") }
        // A rejection of one request, such as a content policy's for one crop, a reply without
        // an answer, or an answer the session can't decode fails only the book. Each keeps a
        // message, so the worker can tell when it repeats.
        guard case .providerRefused("OpenAI: x") = failure(400),
            case .providerRefused("OpenAI: x") = failure(400, code: "invalid_request_error"),
            case .providerRefused("OpenAI: x") = failure(422),
            case .providerRefused("OpenAI: x") = BookAnalyzer.modelFailure(
                ProviderError(provider: .openAI, status: nil, retryAfter: nil, message: "x")),
            case .providerRefused(let undecoded) = BookAnalyzer.modelFailure(
                GeneratedContent.ParsingError(rawContent: "Sure!", debugDescription: "")),
            case .providerRefused(undecoded) = BookAnalyzer.modelFailure(
                GeneratedContent.ParsingError(rawContent: "{", debugDescription: ""))
        else { return XCTFail("A rejection of one request should fail only the book") }
        XCTAssertEqual(SpineWorker.disposition(of: CompanionError.providerRefused("x")), .skipBook)
    }

    /// A lasting rejection names the problem and its fix, and so does Anthropic's HTTP 400 for
    /// an account without credit. Any other error keeps the provider's own message.
    func testProviderErrorsNameTheProblem() {
        func text(
            _ provider: SpineDesigner.Provider, _ status: Int, code: String? = nil,
            message: String = "x", sentKey: Bool = true
        ) -> String? {
            ProviderError(
                provider: provider, status: status, retryAfter: nil, message: message, code: code,
                sentKey: sentKey
            )
            .errorDescription
        }
        let rejectedKey = "Google Gemini didn't accept your API key."
        XCTAssertEqual(text(.google, 401), rejectedKey)
        XCTAssertEqual(text(.google, 400, code: "API_KEY_INVALID"), rejectedKey)
        XCTAssertEqual(text(.openAI, 402), "Your OpenAI account is out of credit.")
        XCTAssertEqual(
            text(.openAI, 429, code: "insufficient_quota"), "Your OpenAI account is out of credit.")
        XCTAssertEqual(text(.anthropic, 403), "Anthropic can't use this model with your key.")
        XCTAssertEqual(text(.anthropic, 404), "Anthropic can't use this model with your key.")
        XCTAssertEqual(
            text(
                .anthropic, 400,
                message:
                    "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."
            ),
            "Your Anthropic account is out of credit.")
        XCTAssertEqual(
            text(.anthropic, 400, message: "Image too large."), "Anthropic: Image too large.")
        XCTAssertEqual(
            text(.openAI, 400, message: "Your credit balance is too low."),
            "OpenAI: Your credit balance is too low.")
        XCTAssertEqual(
            text(.google, 500, message: "Internal error."), "Google Gemini: Internal error.")

        // A custom endpoint may need no key, and a wrong base URL also answers 404.
        XCTAssertEqual(text(.custom, 401), "Your endpoint didn't accept your API key.")
        XCTAssertEqual(text(.custom, 403), "Your endpoint didn't accept your API key.")
        let keyless = "Your endpoint refused the request without an API key."
        XCTAssertEqual(text(.custom, 401, sentKey: false), keyless)
        XCTAssertEqual(text(.custom, 403, sentKey: false), keyless)
        XCTAssertEqual(
            text(.custom, 404),
            "Your endpoint didn't find this model. Check the model name and base URL.")
        XCTAssertEqual(
            text(.custom, 402, message: "Payment required."), "Your endpoint: Payment required.")
        XCTAssertEqual(
            text(.custom, 400, message: "Bad schema."), "Your endpoint: Bad schema.")
    }

    func testTheSameRefusalOfThreeBooksInARowIsLasting() {
        var streak = SpineWorker.RefusalStreak()
        XCTAssertFalse(streak.isLasting(after: "Your Anthropic account is out of credit."))
        XCTAssertFalse(streak.isLasting(after: "Your Anthropic account is out of credit."))
        XCTAssertFalse(
            streak.isLasting(after: "Anthropic: Could not process image."),
            "Another message starts a new streak")
        XCTAssertFalse(streak.isLasting(after: "Anthropic: Could not process image."))
        XCTAssertTrue(streak.isLasting(after: "Anthropic: Could not process image."))
        XCTAssertFalse(
            streak.isLasting(after: "Anthropic: Could not process image."),
            "A lasting refusal starts the count again")
        XCTAssertEqual(SpineWorker.RefusalStreak.limit, 3)
    }

    func testLastingBackupRejectionsLastUntilTheSettingsChange() async {
        SpineDesigner.forgetRejection()
        defer { SpineDesigner.forgetRejection() }
        // A custom endpoint needs no key, so its settings are complete without one.
        let custom = SpineDesigner(
            provider: .custom, model: "local-model", baseURL: "http://localhost:1234/v1")
        let analyzer = BookAnalyzer()
        let ready = await analyzer.status(of: .backup, designer: custom)
        XCTAssertTrue(ready.isAvailable)

        let readersRejection = UserDefaults.standard.object(forKey: "SpineDesignerRejection")
        custom.rememberRejection("Custom: Unknown model.", sentKey: custom.provider.key.read())
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: "SpineDesignerRejection") as? NSDictionary,
            readersRejection as? NSDictionary, "Tests keep their own defaults")
        let rejected = await analyzer.status(of: .backup, designer: custom)
        XCTAssertFalse(rejected.isAvailable)
        XCTAssertEqual(rejected.unavailableReason, "Custom: Unknown model.")
        // Later runs start below the rejected backup and say why.
        let best = BookAnalyzer.bestStatus(
            pcc: ModelStatus(
                tier: .privateCloudCompute, isAvailable: false, unavailableReason: "Off",
                coverReader: .designModel),
            backup: rejected,
            onDevice: ModelStatus(
                tier: .onDevice, isAvailable: true, unavailableReason: nil,
                coverReader: .onDevice))
        XCTAssertEqual(best.tier, .onDevice)
        XCTAssertEqual(best.backupUnavailableReason, "Custom: Unknown model.")

        var renamed = custom
        renamed.model = "other-model"
        XCTAssertNil(renamed.rejection, "Other settings get their own requests")
        XCTAssertEqual(custom.rejection, "Custom: Unknown model.")
        SpineDesigner.forgetRejection()
        XCTAssertNil(custom.rejection, "Forgetting clears the rejection")
    }

    func testARejectionOfAReplacedKeyIsNotRemembered() {
        SpineDesigner.forgetRejection()
        defer { SpineDesigner.forgetRejection() }
        let custom = SpineDesigner(
            provider: .custom, model: "local-model", baseURL: "http://localhost:1234/v1")
        // Whatever key this device holds, the late rejection's request sent another one.
        let current = custom.provider.key.read()
        XCTAssertFalse(
            custom.rememberRejection("Custom: Invalid key.", sentKey: (current ?? "") + "-old"))
        XCTAssertNil(custom.rejection, "A late rejection of a replaced key leaves the new one")
        XCTAssertTrue(custom.rememberRejection("Custom: Invalid key.", sentKey: current))
        XCTAssertEqual(custom.rejection, "Custom: Invalid key.")
    }

    func testModelErrorsMapToRunStopsOrBookFailures() {
        let reset = now.addingTimeInterval(3_600)
        let quota = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
            .init(resetDate: reset, debugDescription: "quota"))
        guard case .quotaReached(let date) = BookAnalyzer.modelFailure(quota) else {
            return XCTFail("Quota errors must stop the run until the reset")
        }
        XCTAssertEqual(date, reset)

        let busy: [any Error] = [
            PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "")),
            PrivateCloudComputeLanguageModel.Error.serviceUnavailable(.init(debugDescription: "")),
            LanguageModelError.timeout(.init(debugDescription: "")),
        ]
        for error in busy {
            guard case .modelBusy(nil) = BookAnalyzer.modelFailure(error) else {
                return XCTFail("\(error) should mean the model is busy")
            }
        }
        // The system's rate limit, which it enforces only on battery, keeps its reset date as
        // the retry date instead of the default delay.
        let limited = LanguageModelError.rateLimited(.init(resetDate: reset, debugDescription: ""))
        guard case .batteryRateLimited(reset) = BookAnalyzer.modelFailure(limited) else {
            return XCTFail("A rate limit should wait for power and keep its reset date")
        }
        guard
            case .batteryRateLimited(nil) = BookAnalyzer.modelFailure(
                LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "")))
        else { return XCTFail("A rate limit without a reset date should wait for power") }

        let perBook: [any Error] = [
            LanguageModelError.guardrailViolation(.init(debugDescription: "")),
            LanguageModelError.refusal(.init(explanation: "", debugDescription: "")),
            LanguageModelError.contextSizeExceeded(
                .init(contextSize: 1, tokenCount: 2, debugDescription: "")),
        ]
        for error in perBook {
            guard case .invalidDesign = BookAnalyzer.modelFailure(error) else {
                return XCTFail("\(error) should fail only the book")
            }
        }
        // A request the model can't take fails every book the same way, so it stops the run.
        let everyBook: [any Error] = [
            LanguageModelError.unsupportedCapability(
                .init(capability: .reasoning, debugDescription: "")),
            LanguageModelError.unsupportedGenerationGuide(
                .init(schemaName: nil, debugDescription: "")),
        ]
        for error in everyBook {
            guard case .modelUnavailable = BookAnalyzer.modelFailure(error) else {
                return XCTFail("\(error) should stop the run")
            }
            XCTAssertEqual(
                SpineWorker.disposition(of: BookAnalyzer.modelFailure(error)!),
                .stopRun(retryAfter: nil))
        }
        XCTAssertNil(BookAnalyzer.modelFailure(URLError(.notConnectedToInternet)))
    }

    func testWorkerStopsOnServiceErrorsAndSkipsBookErrors() {
        XCTAssertEqual(
            SpineWorker.disposition(of: CompanionError.quotaReached(now), now: now),
            .stopRun(retryAfter: now))
        // A hung cover read fails its book and stops; Vision held by it retries later.
        XCTAssertEqual(
            SpineWorker.disposition(of: CompanionError.coverTextTimedOut, now: now),
            .skipBookAndStop(retryAfter: nil))
        XCTAssertEqual(
            SpineWorker.disposition(of: CompanionError.coverTextBusy, now: now),
            .stopRun(retryAfter: now.addingTimeInterval(SpineWorker.busyRetryDelay)))
        XCTAssertEqual(
            SpineWorker.disposition(of: CompanionError.modelBusy(nil), now: now),
            .stopRun(retryAfter: now.addingTimeInterval(SpineWorker.busyRetryDelay)))
        XCTAssertEqual(
            SpineWorker.disposition(
                of: CompanionError.modelBusy(now.addingTimeInterval(7_200)), now: now),
            .stopRun(retryAfter: now.addingTimeInterval(7_200)))
        XCTAssertEqual(
            SpineWorker.disposition(
                of: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0]), now: now),
            .stopRun(retryAfter: now.addingTimeInterval(30)))
        for code in [CKError.Code.networkUnavailable, .zoneBusy, .serviceUnavailable] {
            XCTAssertEqual(
                SpineWorker.disposition(of: CKError(code), now: now), .stopRun(retryAfter: nil))
        }
        XCTAssertEqual(
            SpineWorker.disposition(of: URLError(.notConnectedToInternet), now: now),
            .stopRun(retryAfter: nil))
        XCTAssertEqual(
            SpineWorker.disposition(of: CompanionError.noICloudAccount, now: now),
            .stopRun(retryAfter: nil))

        // A dead cover link, a cover server's temporary error, or an unusable cover fails the
        // book, so it cannot block the queue.
        for error: any Error in [
            URLError(.cannotFindHost), URLError(.badServerResponse), CompanionError.invalidCover,
            CompanionError.invalidDesign, CompanionError.coverTooLarge,
        ] {
            XCTAssertEqual(SpineWorker.disposition(of: error, now: now), .skipBook, "\(error)")
        }
        // A rejected save, such as a record type missing from the production schema, would fail
        // every book after spending its model requests, so the run stops.
        XCTAssertEqual(
            SpineWorker.disposition(of: CKError(.serverRejectedRequest), now: now),
            .skipBookAndStop(retryAfter: nil))
        // A slow cover host and a failing network look alike: the book backs off and the run
        // stops, so the next run moves past the book.
        for code in [URLError.Code.timedOut, .networkConnectionLost] {
            XCTAssertEqual(
                SpineWorker.disposition(of: URLError(code), now: now),
                .skipBookAndStop(retryAfter: nil), "\(code)")
        }
        // A Google Fonts outage affects every book, so the run stops until it can clear.
        XCTAssertEqual(
            SpineWorker.disposition(of: CompanionError.fontServiceUnavailable(nil), now: now),
            .stopRun(retryAfter: now.addingTimeInterval(SpineWorker.busyRetryDelay)))
        XCTAssertEqual(
            SpineWorker.disposition(
                of: CompanionError.fontServiceUnavailable(now.addingTimeInterval(60)), now: now),
            .stopRun(retryAfter: now.addingTimeInterval(60)))
        // A full iCloud storage plan does not clear by itself.
        let full = CKError(.quotaExceeded)
        XCTAssertEqual(
            SpineWorker.disposition(of: full, now: now),
            .stopRun(retryAfter: now.addingTimeInterval(SpineWorker.lastingStopDelay)))
        XCTAssertTrue(SpineWorker.message(for: full).contains("iCloud storage is full"))
        // A background run on cellular or Low Data Mode waits for Wi-Fi.
        let cellular = URLError(
            .notConnectedToInternet,
            userInfo: [
                NSURLErrorNetworkUnavailableReasonKey:
                    URLError.NetworkUnavailableReason.expensive.rawValue
            ])
        XCTAssertEqual(SpineWorker.disposition(of: cellular, now: now), .stopRun(retryAfter: nil))
        XCTAssertTrue(SpineWorker.message(for: cellular).hasPrefix("Waiting for Wi-Fi"))
    }

    func testICloudErrorsReadAsSentences() {
        let signedOut = CKError(.notAuthenticated)
        XCTAssertEqual(
            SpineWorker.iCloudMessage(for: signedOut),
            CompanionError.noICloudAccount.errorDescription)
        XCTAssertEqual(
            SpineWorker.message(for: signedOut), CompanionError.noICloudAccount.errorDescription)
        for code in [CKError.Code.networkUnavailable, .networkFailure] {
            XCTAssertEqual(
                SpineWorker.message(for: CKError(code)),
                "Bookworms couldn't reach iCloud. Check your connection and try again.")
        }
        XCTAssertNil(SpineWorker.iCloudMessage(for: CKError(.serverRecordChanged)))
        XCTAssertNil(SpineWorker.iCloudMessage(for: CompanionError.designChanged))
        XCTAssertEqual(
            SpineWorker.message(for: CompanionError.iCloudRestricted),
            CompanionError.iCloudRestricted.errorDescription)
    }

    func testGoogleFontsRetriesOnlyFailuresThatMayPass() async throws {
        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        func run(failing failures: Int, with error: any Error) async -> (
            Result<Int, any Error>, Int
        ) {
            let attempts = Attempts()
            let result: Result<Int, any Error>
            do {
                result = .success(
                    try await GoogleFonts.retrying(delay: { _ in .zero }) {
                        let attempt = await attempts.next()
                        if attempt <= failures { throw error }
                        return attempt
                    })
            } catch {
                result = .failure(error)
            }
            return (result, await attempts.count)
        }
        // A dropped connection, a timeout, and a server error pass on a later try.
        for error in [
            URLError(.networkConnectionLost), URLError(.timedOut),
            GoogleFonts.Unavailable(retryAfter: nil, status: 503),
        ] as [any Error] {
            let (result, attempts) = await run(failing: GoogleFonts.retries, with: error)
            XCTAssertEqual(try result.get(), GoogleFonts.retries + 1)
            XCTAssertEqual(attempts, GoogleFonts.retries + 1)
        }
        let (exhausted, tries) = await run(failing: .max, with: URLError(.networkConnectionLost))
        XCTAssertThrowsError(try exhausted.get())
        XCTAssertEqual(tries, GoogleFonts.retries + 1)
        // Being offline, a rate limit, and a missing family fail at once.
        for error in [
            URLError(.notConnectedToInternet),
            GoogleFonts.Unavailable(retryAfter: nil, status: 429), CompanionError.invalidDesign,
        ] as [any Error] {
            let (result, attempts) = await run(failing: 1, with: error)
            XCTAssertThrowsError(try result.get())
            XCTAssertEqual(attempts, 1)
        }
        XCTAssertGreaterThanOrEqual(GoogleFonts.backoff(1), .seconds(1))
        XCTAssertLessThanOrEqual(GoogleFonts.backoff(1), .seconds(2))
        XCTAssertGreaterThanOrEqual(GoogleFonts.backoff(3), .seconds(4))
        XCTAssertLessThanOrEqual(GoogleFonts.backoff(3), .seconds(5))
    }

    func testABatteryRateLimitPausesUntilPluggedIn() async throws {
        let run = try LocalRun(
            books: [LocalRun.book(1, cover: CoverStub.numbered(1))], designs: [])
        defer { run.remove() }
        let worker = run.worker(
            status: .backupStub,
            designBook: { _, _, _, _, _ in throw CompanionError.batteryRateLimited(nil) },
            sleep: { _ in })
        await worker.reconcile(mode: .foreground)
        let (statuses, _) = await LocalRun.updates(of: worker)
        var status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.phase, WorkerSnapshot.pausedPhase)
        XCTAssertTrue(status.waitsForPower)
        XCTAssertEqual(status.headline, "Paused until plugged in")
        XCTAssertEqual(status.error, CompanionError.batteryRateLimited(nil).errorDescription)
        let retryAfter = try XCTUnwrap(status.retryAfter)
        // Without power, the run waits for the retry date like any other rate limit.
        XCTAssertEqual(
            GenerationController.nextRunDate(after: status, hasNewWork: false, now: now),
            retryAfter > now ? retryAfter : nil)
        let saved = try JSONDecoder()
            .decode(
                WorkerSnapshot.self, from: try JSONEncoder().encode(status))
        XCTAssertTrue(saved.waitsForPower)

        status.dropExpiredStop(now: retryAfter.addingTimeInterval(1))
        XCTAssertFalse(status.waitsForPower)
    }

    func testGoogleFontsStatusSeparatesMissingFamiliesFromOutages() throws {
        func failure(_ status: Int, retryAfter: String? = nil) throws -> any Error {
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: URL(string: "https://fonts.google.com/download/list")!,
                    statusCode: status, httpVersion: nil,
                    headerFields: retryAfter.map { ["Retry-After": $0] }))
            return GoogleFonts.failure(for: response, now: now)
        }
        func outage(_ status: Int, retryAfter: String? = nil) throws -> Date? {
            try XCTUnwrap(
                try failure(status, retryAfter: retryAfter) as? GoogleFonts.Unavailable,
                "\(status) should stop the run"
            )
            .retryAfter
        }
        for status in [404, 410] {
            guard case .invalidDesign = try failure(status) as? CompanionError else {
                return XCTFail("\(status) should only skip the family")
            }
        }
        // An outage is not a `CompanionError`, so the shelf's font loader retries the face.
        XCTAssertFalse(try failure(503) is CompanionError)
        XCTAssertNil(try outage(503))
        XCTAssertEqual(try outage(429, retryAfter: "120"), now.addingTimeInterval(120))
        XCTAssertEqual(
            try outage(503, retryAfter: "Mon, 12 Jan 1970 14:46:40 GMT"),
            now.addingTimeInterval(3_600))
        for header in ["inf", "nan", "-30", "2.5", "1e9"] {
            XCTAssertNil(try outage(429, retryAfter: header), header)
        }
        let cap = now.addingTimeInterval(SpineWorker.lastingStopDelay)
        XCTAssertEqual(try outage(429, retryAfter: "999999999"), cap)
        XCTAssertEqual(try outage(429, retryAfter: "Fri, 31 Dec 2100 23:59:59 GMT"), cap)
    }

    func testFontFilesPreferTheWeightThenTheRegularWidthAndTextSize() {
        let pick = SpineFamily.fileName(for:in:)
        let noto = [
            "NotoSans[wdth,wght].ttf", "static/NotoSans_Condensed-Bold.ttf",
            "static/NotoSans_ExtraCondensed-Bold.ttf", "static/NotoSans-Bold.ttf",
            "static/NotoSans-Regular.ttf",
        ]
        XCTAssertEqual(pick(700, noto), "static/NotoSans-Bold.ttf")
        XCTAssertEqual(pick(500, noto), "NotoSans[wdth,wght].ttf")
        let lato = ["Lato-Light.ttf", "Lato-Regular.ttf", "Lato-Bold.ttf"]
        XCTAssertEqual(pick(500, lato), "Lato-Regular.ttf")
        XCTAssertEqual(pick(600, lato), "Lato-Bold.ttf")
        // Of two equally near weights, 500 takes the lighter, in either order, and a weight
        // above 500 the heavier, as the Apple TV picks.
        let pair = ["Family-Regular.ttf", "Family-SemiBold.ttf"]
        XCTAssertEqual(pick(500, pair), "Family-Regular.ttf")
        XCTAssertEqual(pick(500, pair.reversed()), "Family-Regular.ttf")
        XCTAssertEqual(pick(600, ["Family-Medium.ttf", "Family-Bold.ttf"]), "Family-Bold.ttf")
        // A family whose own name is narrow has only such files.
        let archivo = ["static/ArchivoNarrow-Regular.ttf", "static/ArchivoNarrow-Bold.ttf"]
        XCTAssertEqual(pick(700, archivo), "static/ArchivoNarrow-Bold.ttf")
        let condensed = ["static/LeagueGothic_Condensed-Regular.ttf"]
        XCTAssertEqual(pick(500, condensed), condensed[0])
        let league = [
            "LeagueGothic-Regular-VariableFont_wdth.ttf",
            "static/LeagueGothic_Condensed-Regular.ttf",
            "static/LeagueGothic-Regular.ttf",
        ]
        XCTAssertEqual(pick(400, league), "static/LeagueGothic-Regular.ttf")
        // A width variant of the exact weight gives way to a regular-width file.
        let mixed = ["Family[wght].ttf", "static/Family_Condensed-Bold.ttf"]
        XCTAssertEqual(pick(700, mixed), "Family[wght].ttf")
        let staticsOnly = ["static/Family-Regular.ttf", "static/Family_Condensed-SemiBold.ttf"]
        XCTAssertEqual(pick(600, staticsOnly), "static/Family-Regular.ttf")
        // Optical sizes: the cut nearest a 24-point title, at the regular width.
        let merriweather = [
            "Merriweather-VariableFont_opsz,wdth,wght.ttf",
            "static/Merriweather_120pt-SemiBold.ttf",
            "static/Merriweather_120pt_SemiCondensed-SemiBold.ttf",
            "static/Merriweather_24pt_SemiCondensed-SemiBold.ttf",
            "static/Merriweather_24pt-SemiBold.ttf", "static/Merriweather_36pt-SemiBold.ttf",
        ]
        XCTAssertEqual(pick(600, merriweather), "static/Merriweather_24pt-SemiBold.ttf")
        XCTAssertEqual(pick(500, merriweather), merriweather[0])
        let bodoni = [
            "static/BodoniModa_9pt-Bold.ttf", "static/BodoniModa_18pt-Bold.ttf",
            "static/BodoniModa_28pt-Bold.ttf", "static/BodoniModa_72pt-Bold.ttf",
        ]
        XCTAssertEqual(pick(700, bodoni), "static/BodoniModa_28pt-Bold.ttf")
        XCTAssertNil(pick(400, []))
    }

    func testSavedRunOutcomeSurvivesRelaunchUntilItsRetryDatePasses() throws {
        var snapshot = WorkerSnapshot()
        snapshot.isRunning = true
        snapshot.phase = "Paused"
        snapshot.error = "Limit reached"
        snapshot.failed = 2
        snapshot.retryAfter = now
        snapshot.lastRunAt = now
        var saved = try JSONDecoder()
            .decode(
                WorkerSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertFalse(saved.isRunning)
        XCTAssertEqual(saved.phase, "Paused")
        XCTAssertEqual(saved.failed, 2)
        XCTAssertEqual(saved.lastRunAt, now)

        saved.dropExpiredStop(now: now.addingTimeInterval(-1))
        XCTAssertEqual(saved.error, "Limit reached")
        saved.dropExpiredStop(now: now)
        XCTAssertNil(saved.error)
        XCTAssertNil(saved.retryAfter)
        XCTAssertEqual(saved.phase, "Ready to continue")
    }

    /// The time left averages the latest books' times, waits for a few books and half a
    /// minute, holds against small rises, and rounds so it doesn't jump with each book.
    func testTimeLeftAveragesTheLatestBooksAndRoundsGently() {
        let five: [TimeInterval] = [10, 20, 30, 20, 20]
        XCTAssertNil(WorkerSnapshot.timeLeft(remaining: 40, durations: [10, 20, 30], elapsed: 90))
        XCTAssertNil(
            WorkerSnapshot.timeLeft(remaining: 40, durations: [1, 1, 1, 1, 1], elapsed: 6),
            "Five quick checks at the start promise nothing")
        XCTAssertNil(WorkerSnapshot.timeLeft(remaining: 0, durations: five, elapsed: 120))
        XCTAssertEqual(WorkerSnapshot.timeLeft(remaining: 40, durations: five, elapsed: 120), 800)
        // Only the latest `estimateWindow` times count.
        let slowStart = [600.0] + Array(repeating: 15, count: WorkerSnapshot.estimateWindow)
        XCTAssertEqual(
            WorkerSnapshot.timeLeft(remaining: 12, durations: slowStart, elapsed: 900), 180)
        // A slow book that raises the estimate by less than a quarter keeps the last one; a
        // larger rise or a drop replaces it.
        XCTAssertEqual(
            WorkerSnapshot.timeLeft(remaining: 40, durations: five, elapsed: 120, previous: 700),
            700)
        XCTAssertEqual(
            WorkerSnapshot.timeLeft(remaining: 40, durations: five, elapsed: 120, previous: 600),
            800)
        XCTAssertEqual(
            WorkerSnapshot.timeLeft(remaining: 40, durations: five, elapsed: 120, previous: 900),
            800)

        let seconds: [TimeInterval] = [20, 70, 180, 760, 1_680, 3_500, 5_000, 9_000]
        XCTAssertEqual(
            seconds.map(WorkerSnapshot.timeLeftText),
            [
                "Less than a minute left", "About a minute left", "About 3 minutes left",
                "About 15 minutes left", "About 30 minutes left", "About an hour left",
                "About an hour left", "About 3 hours left",
            ])
    }

    /// A run's headline and tally, and a saved outcome from before runs kept a tally, which
    /// shows its phase alone.
    func testRunHeadlineCountsTheRunAndItsOutcome() throws {
        var run = WorkerSnapshot(
            isRunning: true, phase: "Designing spines", queue: 37, completed: 10, failed: 1,
            designed: 6, fromSeries: 3,
            currentBook: CloudBook(
                id: 7, title: "The Glass Orchard", author: "Mara Quill", coverURL: nil,
                detailCoverURL: nil),
            startedAt: now, durations: [12, 14, 16], timeLeft: 540)
        XCTAssertEqual(run.headline, "Designing 12 of 48")
        XCTAssertEqual(run.fraction, 11.0 / 48)
        XCTAssertEqual(
            run.tally,
            ["6 new designs", "3 from a series", "1 up to date", "1 failed"])
        XCTAssertEqual(run.timeLeftText, "About 9 minutes left")
        run.retryAfter = now
        XCTAssertNil(run.timeLeftText, "A run waiting on a retry date shows no estimate")
        // A later pass checks the library with the last pass's book still in the bindery.
        run.phase = "Checking the library"
        XCTAssertEqual(run.headline, "Checking the library")
        XCTAssertNil(run.designingBook)

        var finished = run
        finished.isRunning = false
        finished.phase = "Finished"
        finished.currentBook = nil
        finished.retryAfter = nil
        finished.queue = 0
        finished.lastRunAt = now.addingTimeInterval(370)
        XCTAssertEqual(finished.headline, "Designed 9 spines in 6 minutes")
        let saved = try JSONDecoder()
            .decode(WorkerSnapshot.self, from: JSONEncoder().encode(finished))
        XCTAssertEqual(saved.headline, finished.headline)
        XCTAssertEqual(saved.tally, finished.tally)
        finished.phase = "All spines are up to date"
        XCTAssertEqual(
            finished.headline, "Designed 9 spines in 6 minutes",
            "A later pass found the work done after an earlier pass's designs")

        // A later pass that finds 30 more books after 40 of 48 continues the bar from there.
        var grown = WorkerSnapshot(
            isRunning: true, phase: "Designing spines", queue: 38, completed: 40,
            passStart: (fraction: 40.0 / 48, done: 40))
        XCTAssertEqual(grown.fraction, 40.0 / 48)
        grown.completed = 59
        grown.queue = 19
        XCTAssertEqual(grown.fraction, 40.0 / 48 + 8.0 / 48 / 2, accuracy: 1e-9)

        let legacy = try JSONDecoder()
            .decode(
                WorkerSnapshot.self,
                from: Data(#"{"phase":"Finished","queue":0,"completed":40,"failed":0}"#.utf8))
        XCTAssertEqual(legacy.headline, "Finished")
        XCTAssertEqual(legacy.tally, [])
    }

    func testBackgroundRunsLeaveQuotaHeadroomAndForegroundRunsUseIt() {
        func status(
            available: Bool = true, reader: ModelStatus.CoverReader = .designModel,
            quota: ModelStatus.Quota
        ) -> ModelStatus {
            ModelStatus(
                tier: .privateCloudCompute, isAvailable: available,
                unavailableReason: available ? nil : "Unavailable", coverReader: reader,
                quota: quota, quotaResetDate: now)
        }
        XCTAssertNil(SpineWorker.modelStop(status(quota: .belowLimit), mode: .background))
        XCTAssertNil(SpineWorker.modelStop(status(quota: .approachingLimit), mode: .foreground))
        XCTAssertEqual(
            SpineWorker.modelStop(status(quota: .approachingLimit), mode: .background)?
                .retryAfter, now)
        XCTAssertEqual(
            SpineWorker.modelStop(status(quota: .limitReached), mode: .foreground)?.retryAfter,
            now)
        // A tier lost during a run stops it with no retry date, so the next run, which picks
        // the best tier again, starts when it is next scheduled.
        let lost = SpineWorker.modelStop(
            status(available: false, quota: .belowLimit), mode: .background)
        XCTAssertEqual(lost?.message, "Unavailable")
        XCTAssertNil(lost?.retryAfter)
        XCTAssertNil(
            SpineWorker.modelStop(status(reader: .onDevice, quota: .belowLimit), mode: .foreground))
        // The on-device tier designs from the title measurements when its model lacks vision.
        XCTAssertNil(
            SpineWorker.modelStop(
                status(reader: .measurementsOnly, quota: .belowLimit), mode: .background))
    }

    /// Idle Mac runs fail closed: an unknown power source counts as battery power, and a run
    /// without a power-source watch, which unplugging couldn't stop, never starts.
    func testIdleMacRunsNeedACPowerAndAPowerWatch() {
        func mayProceed(_ power: GenerationController.PowerSource, watching: Bool = true) -> Bool {
            GenerationController.idleRunMayProceed(power: power, watching: watching)
        }
        XCTAssertTrue(mayProceed(.ac))
        XCTAssertFalse(mayProceed(.battery))
        XCTAssertFalse(mayProceed(.unknown))
        XCTAssertFalse(mayProceed(.ac, watching: false))
    }

    func testRunsQueueUpgradesOnlyWhenTheirTierCanTakeRequests() {
        func upgradeTier(
            _ tier: ModelTier, available: Bool = true, quota: ModelStatus.Quota = .belowLimit,
            mode: RunMode = .background
        ) -> ModelTier {
            SpineWorker.upgradeTier(
                ModelStatus(
                    tier: tier, isAvailable: available, unavailableReason: nil,
                    coverReader: .designModel, quota: quota, quotaResetDate: now),
                mode: mode)
        }
        XCTAssertEqual(upgradeTier(.privateCloudCompute), .privateCloudCompute)
        XCTAssertEqual(
            upgradeTier(.privateCloudCompute, quota: .approachingLimit, mode: .foreground),
            .privateCloudCompute)
        XCTAssertEqual(upgradeTier(.backup), .backup)
        XCTAssertEqual(upgradeTier(.local), .local)
        // A run that stops for its model queues the same books as a run without tiers.
        XCTAssertEqual(
            upgradeTier(.privateCloudCompute, quota: .limitReached, mode: .foreground), .local)
        XCTAssertEqual(upgradeTier(.privateCloudCompute, quota: .approachingLimit), .local)
        XCTAssertEqual(upgradeTier(.onDevice, available: false), .local)
    }

    func testRunsAtTheDailyLimitWaitForTheUpgradesTheyCannotQueue() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = WorkLedger(url: url)
        let book = CloudBook(
            id: 9, title: "A Quiet Orbit", author: "Ann Author", coverURL: nil,
            detailCoverURL: nil)
        let hash = CloudContract.workItemHash(accountID: "42", book: book)
        try await ledger.recordSuccess(
            recordName: CloudContract.designRecordName(accountID: "42", bookID: book.id),
            workItemHash: hash, tier: .onDevice)
        func work(tier: ModelTier, upgradeTier: ModelTier) async -> (
            queue: [Int], upgradeWaits: Bool
        ) {
            let work = await SpineWorker.work(
                [book], accountID: "42", ledger: ledger, tier: tier, upgradeTier: upgradeTier)
            return (work.queue.map(\.id), work.upgradeWaits)
        }
        // At the limit, the upgrade isn't queued, but it keeps the stop and its reset date.
        let limited = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel, quota: .limitReached, quotaResetDate: now)
        let waiting = await work(
            tier: limited.tier, upgradeTier: SpineWorker.upgradeTier(limited, mode: .foreground))
        XCTAssertEqual(waiting.queue, [])
        XCTAssertTrue(waiting.upgradeWaits)
        XCTAssertEqual(SpineWorker.modelStop(limited, mode: .foreground)?.retryAfter, now)
        // Below the limit the upgrade is queued, and at the book's own tier nothing waits.
        let open = await work(tier: .privateCloudCompute, upgradeTier: .privateCloudCompute)
        XCTAssertEqual(open.queue, [9])
        XCTAssertFalse(open.upgradeWaits)
        let current = await work(tier: .onDevice, upgradeTier: .onDevice)
        XCTAssertEqual(current.queue, [])
        XCTAssertFalse(current.upgradeWaits)

        // A new book queues before the upgrade, so the daily limit can't hold back its spine.
        let added = CloudBook(
            id: 10, title: "Salt and Static", author: "Iris Okafor", coverURL: nil,
            detailCoverURL: nil)
        let both = await SpineWorker.work(
            [book, added], accountID: "42", ledger: ledger, tier: .privateCloudCompute,
            upgradeTier: .privateCloudCompute)
        XCTAssertEqual(both.queue.map(\.id), [10, 9])
    }

    /// A weekly recheck keeps a current design without downloading its cover, even when this
    /// device last checked a design of another cover, such as one another device made from a
    /// cover the reader chose there and later removed. Both books' covers use a host that
    /// `CoverURLPolicy` refuses, so a download attempt fails the book without a request, as it
    /// does for the book that has no design.
    func testRechecksKeepACurrentDesignWithoutDownloadingItsCover() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-recheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = """
            {"version":1,"sources":[{"source":"hardcover","accountID":"42","syncedAt":800000000,
              "books":[{"id":7,"title":"The Lantern Keeper","author":"Mara Quill",
                "coverURL":"https://covers.localhost/7.jpg"},
                {"id":8,"title":"Salt and Static","author":"Iris Okafor",
                "coverURL":"https://covers.localhost/8.jpg"}]}]}
            """
        try Data(archive.utf8).write(to: folder.appending(path: "library-v1.json"))
        let book = CloudBook(
            id: 7, title: "The Lantern Keeper", author: "Mara Quill",
            coverURL: URL(string: "https://covers.localhost/7.jpg"), detailCoverURL: nil)
        let workHash = CloudContract.workItemHash(accountID: "42", book: book)
        let coverHash = String(repeating: "c", count: 64)
        let recordName = CloudContract.designRecordName(accountID: "42", bookID: 7)
        // This generator's design without a model token, from Private Cloud Compute, which no
        // tier outranks.
        let design = SpineDesignV1(
            version: 1, accountID: "42", bookID: 7, workItemHash: workHash, coverHash: coverHash,
            generatorVersion: CloudContract.generatorVersion, generatedAt: now,
            backgroundHex: "#101010", foregroundHex: "#F4EEE2", accentHex: "#7A1F1F",
            typeface: "serif", weight: 700, uppercase: false)
        try JSONEncoder().encode([recordName: design])
            .write(to: folder.appending(path: "spine-designs-v1.json"))

        let ledger = WorkLedger(url: folder.appending(path: "ledger.json"))
        try await ledger.useCloudUser("local")
        try await ledger.recordSuccess(
            recordName: recordName, workItemHash: workHash,
            now: Date().addingTimeInterval(-WorkLedger.recheckInterval - 60))
        let due = await ledger.needsCheck(recordName: recordName, workItemHash: workHash)
        XCTAssertTrue(due)

        let worker = SpineWorker(
            store: LocalSpineStore(folder: folder), ledger: ledger, modelStatus: .local)
        await worker.reconcile(mode: .foreground)
        var finished: WorkerSnapshot?
        for await update in worker.updates {
            if case .saved = update { XCTFail("The run saved a design") }
            if case .status(let status) = update, !status.isRunning {
                finished = status
                break
            }
        }
        let status = try XCTUnwrap(finished)
        XCTAssertEqual(status.phase, "Finished")
        XCTAssertEqual(status.completed, 1)
        // The book without a design tried its cover.
        XCTAssertEqual(status.failed, 1)
        let rechecked = await ledger.needsCheck(recordName: recordName, workItemHash: workHash)
        XCTAssertFalse(rechecked)
    }

    /// A run keeps an earlier generator's Private Cloud Compute design, which no tier outranks,
    /// after the book's title changes to one its face can't letter: the design stays under its
    /// old work-item hash, with no cover download or model request, and the ledger doesn't queue
    /// the book again. The cover's host is one that `CoverURLPolicy` refuses, so a download
    /// attempt would fail the book.
    func testRunsKeepADesignWhoseFaceCannotLetterTheNewTitle() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-renamed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = """
            {"version":1,"sources":[{"source":"hardcover","accountID":"42","syncedAt":800000000,
              "books":[{"id":7,"title":"東京物語","author":"Mara Quill",
                "coverURL":"https://covers.localhost/7.jpg"}]}]}
            """
        try Data(archive.utf8).write(to: folder.appending(path: "library-v1.json"))
        func book(_ title: String) -> CloudBook {
            CloudBook(
                id: 7, title: title, author: "Mara Quill",
                coverURL: URL(string: "https://covers.localhost/7.jpg"), detailCoverURL: nil)
        }
        let recordName = CloudContract.designRecordName(accountID: "42", bookID: 7)
        // Georgia has no glyphs for the new title.
        let design = SpineDesignV1(
            version: 1, accountID: "42", bookID: 7,
            workItemHash: CloudContract.workItemHash(accountID: "42", book: book("Tokyo Story")),
            coverHash: String(repeating: "c", count: 64), generatorVersion: "ios-pcc-v1",
            generatedAt: now, backgroundHex: "#101010", foregroundHex: "#F4EEE2",
            accentHex: "#7A1F1F", typeface: "serif", weight: 700, uppercase: false,
            fontPostScriptName: "Georgia-Bold")
        let designs = folder.appending(path: "spine-designs-v1.json")
        try JSONEncoder().encode([recordName: design]).write(to: designs)

        let ledger = WorkLedger(url: folder.appending(path: "ledger.json"))
        let worker = SpineWorker(
            store: LocalSpineStore(folder: folder), ledger: ledger, modelStatus: .local)
        await worker.reconcile(mode: .foreground)
        var finished: WorkerSnapshot?
        for await update in worker.updates {
            if case .saved = update { XCTFail("The run saved a design") }
            if case .status(let status) = update, !status.isRunning {
                finished = status
                break
            }
        }
        let status = try XCTUnwrap(finished)
        XCTAssertEqual(status.phase, "Finished")
        XCTAssertEqual(status.completed, 1)
        XCTAssertEqual(status.failed, 0, "The run downloaded no cover")
        let stored = try JSONDecoder()
            .decode(
                [String: SpineDesignV1].self, from: Data(contentsOf: designs))
        XCTAssertEqual(stored[recordName], design)
        let requeued = await ledger.needsCheck(
            recordName: recordName,
            workItemHash: CloudContract.workItemHash(accountID: "42", book: book("東京物語")),
            runTier: .privateCloudCompute)
        XCTAssertFalse(requeued)
    }

    /// A run moves a design that stays to the book's new title without a cover download or a
    /// model request, keeping the hash of the cover it comes from, when its face letters the new
    /// title. The cover's host is one that `CoverURLPolicy` refuses, so a download attempt would
    /// fail the book. The run's tally counts the moved design, a series copy too, as up to date.
    func testRunsMoveADesignToANewTitleItsFaceLetters() async throws {
        let renamed = LocalRun.book(7, title: "The Lantern Keeper, Revised")
        for provenance in [nil, "series-reuse:9"] {
            let design = LocalRun.design(
                for: LocalRun.book(7), coverHash: String(repeating: "c", count: 64),
                generator: "ios-pcc-v1", provenance: provenance)
            let run = try LocalRun(books: [renamed], designs: [design])
            defer { run.remove() }
            let (status, saved) = try await run.run()
            XCTAssertEqual(status.phase, "Finished")
            XCTAssertEqual(status.failed, 0, "The run downloaded no cover")
            XCTAssertEqual(status.completed, 1)
            XCTAssertEqual(status.designed, 0)
            XCTAssertEqual(status.fromSeries, 0)
            let moved = try XCTUnwrap(saved.first)
            XCTAssertEqual(saved.count, 1)
            XCTAssertEqual(moved.workItemHash, LocalRun.workHash(renamed))
            XCTAssertEqual(moved.coverHash, design.coverHash)
            XCTAssertEqual(moved.generatorVersion, "ios-pcc-v1")
            XCTAssertEqual(moved.generatedAt, design.generatedAt)
            XCTAssertEqual(try run.stored()[7], moved)
        }
    }

    /// A sync replaces a book's default cover only with a sharper one, and that one exception
    /// to keeping a design redesigns the spine from the new cover at the run's tier. A design of
    /// the same image moves, and the reader's colors stay. Only a default cover URL that changed
    /// since the device's last check counts, so a title edit alone moves a design whatever image
    /// is behind the URL now.
    func testRunsRedesignASpineWhoseDefaultCoverASyncUpgraded() async throws {
        let before = LocalRun.book(7, cover: CoverStub.defaultCover)
        let upgraded = LocalRun.book(7, cover: CoverStub.secondCover)
        let oldHash = CloudContract.digest(CoverStub.images[CoverStub.defaultCover]!)
        let newHash = CloudContract.digest(CoverStub.images[CoverStub.secondCover]!)
        let fromOld = LocalRun.design(for: before, coverHash: oldHash, generator: "ios-pcc-v1")
        // A run whose ledger saw `before`'s check.
        func checked(_ book: CloudBook, designs: [SpineDesignV1]) async throws -> LocalRun {
            let run = try LocalRun(books: [book], designs: designs)
            try await run.ledger.useCloudUser("local")
            try await run.ledger.recordSuccess(
                recordName: LocalRun.recordName(7), workItemHash: LocalRun.workHash(before),
                defaultCover: before.defaultCover)
            return run
        }
        do {
            let run = try await checked(upgraded, designs: [fromOld])
            defer { run.remove() }
            let (status, saved) = try await run.run()
            XCTAssertEqual(status.failed, 0)
            let made = try XCTUnwrap(saved.first)
            XCTAssertEqual(made.coverHash, newHash, "The spine comes from the sharper cover")
            XCTAssertEqual(made.tier, .local, "Even over a better tier's design")
            XCTAssertEqual(made.workItemHash, LocalRun.workHash(upgraded))
        }
        let sameImage = LocalRun.design(for: before, coverHash: newHash, generator: "ios-pcc-v1")
        let recolored = LocalRun.design(
            for: before, coverHash: oldHash, generator: "ios-pcc-v1",
            provenance: "generated-colors:101010,F4EEE2,7A1F1F")
        let retitled = LocalRun.book(
            7, title: "The Lantern Keeper Returns", cover: CoverStub.defaultCover)
        let unchecked = try LocalRun(books: [upgraded], designs: [fromOld])
        for (run, book, design) in [
            (try await checked(upgraded, designs: [sameImage]), upgraded, sameImage),
            (try await checked(upgraded, designs: [recolored]), upgraded, recolored),
            (try await checked(retitled, designs: [sameImage]), retitled, sameImage),
            (unchecked, upgraded, fromOld),
        ] {
            defer { run.remove() }
            let (status, saved) = try await run.run()
            XCTAssertEqual(status.failed, 0)
            let moved = try XCTUnwrap(saved.first)
            XCTAssertEqual(moved.coverHash, design.coverHash, "The design stays, moved")
            XCTAssertEqual(moved.generatedAt, design.generatedAt)
            XCTAssertEqual(moved.workItemHash, LocalRun.workHash(book))
        }
        // A cover server's temporary error fails the book and leaves the design under its old
        // work-item hash, so a later run downloads the new cover again.
        let unavailable = LocalRun.book(7, cover: CoverStub.unavailableCover)
        let run = try await checked(unavailable, designs: [fromOld])
        defer { run.remove() }
        let (status, _) = try await run.run()
        XCTAssertEqual(status.failed, 1)
        let stored = try XCTUnwrap(try run.stored()[7])
        XCTAssertEqual(stored.workItemHash, LocalRun.workHash(before), "The design doesn't move")
        XCTAssertEqual(stored.coverHash, oldHash)
        let retries = await run.ledger.defaultCoverChanged(
            recordName: LocalRun.recordName(7), defaultCover: unavailable.defaultCover)
        XCTAssertTrue(retries)
    }

    /// A redesign from a sharper default cover replaces only the design its check read, so
    /// colors the reader chose while the new cover downloaded and designed stay.
    func testASharperCoverRedesignKeepsColorsTheReaderChoseDuringIt() async throws {
        let before = LocalRun.book(7, cover: CoverStub.defaultCover)
        let upgraded = LocalRun.book(7, cover: CoverStub.secondCover)
        let oldHash = CloudContract.digest(CoverStub.images[CoverStub.defaultCover]!)
        let fromOld = LocalRun.design(for: before, coverHash: oldHash, generator: "ios-pcc-v1")
        let run = try LocalRun(books: [upgraded], designs: [fromOld])
        defer { run.remove() }
        try await run.ledger.useCloudUser("local")
        try await run.ledger.recordSuccess(
            recordName: LocalRun.recordName(7), workItemHash: LocalRun.workHash(before),
            defaultCover: before.defaultCover)
        let local = LocalSpineStore(folder: run.folder)
        let colors = SpineColors(
            background: ColorValue(hex: "#1A2B3C")!, foreground: ColorValue(hex: "#F4E9D0")!,
            accent: ColorValue(hex: "#C08040")!)
        let worker = run.worker(
            designBook: { book, accountID, workItemHash, cover, model in
                if let read = try await local.savedDesign(accountID: accountID, bookID: 7) {
                    try await local.saveRecolored(read.recolored(colors))
                }
                return LocalRun.design(
                    of: book, accountID: accountID, workItemHash: workItemHash, cover: cover,
                    model: model)
            }, sleep: { _ in })
        await worker.reconcile(mode: .foreground)
        _ = await LocalRun.updates(of: worker)
        let kept = try XCTUnwrap(try run.stored()[7])
        XCTAssertEqual(kept.colors, colors)
        XCTAssertEqual(kept.coverHash, oldHash)
        XCTAssertTrue(kept.hasReaderEdits)
    }

    /// A design with the generator's colors that doesn't come from the cover the reader chose is
    /// designed again from that cover, at the run's tier, even on a device whose ledger never
    /// saw the choice, or after a failed first design from it. A default cover downloaded
    /// because the chosen one is missing replaces nothing.
    func testRunsDesignAChosenCoverTheSavedDesignDoesNotComeFrom() async throws {
        let book = LocalRun.book(7, cover: CoverStub.defaultCover)
        // Private Cloud Compute's design of the default cover, which a local run otherwise keeps.
        let fromDefault = LocalRun.design(
            for: book, coverHash: CloudContract.digest(CoverStub.images[CoverStub.defaultCover]!),
            generator: "ios-pcc-v1")
        for failedFirst in [false, true] {
            let run = try LocalRun(
                books: [book], designs: [fromDefault], chosen: [7: CoverStub.chosenCover])
            defer { run.remove() }
            if failedFirst {
                try await run.ledger.useCloudUser("local")
                try await run.ledger.recordFailure(
                    recordName: LocalRun.recordName(7), workItemHash: LocalRun.workHash(book),
                    chosenCover: CoverStub.chosenCover,
                    now: Date().addingTimeInterval(-2 * WorkLedger.failureBackoff))
            }
            let (status, saved) = try await run.run()
            XCTAssertEqual(status.failed, 0)
            let made = try XCTUnwrap(saved.first)
            XCTAssertEqual(
                made.coverHash, CloudContract.digest(CoverStub.images[CoverStub.chosenCover]!))
            XCTAssertEqual(made.tier, .local)
            XCTAssertFalse(made.isSeriesReuse)
            XCTAssertEqual(try run.stored()[7], made)
        }

        let fromChosen = LocalRun.design(
            for: book, coverHash: CloudContract.digest(CoverStub.images[CoverStub.chosenCover]!),
            generator: "ios-pcc-v1")
        let run = try LocalRun(
            books: [book], designs: [fromChosen], chosen: [7: CoverStub.missingCover])
        defer { run.remove() }
        let (status, saved) = try await run.run()
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(saved, [])
        XCTAssertEqual(try run.stored()[7], fromChosen)
    }

    /// A series copy replaces a book's saved design only as a new design would: from a better
    /// tier, such as a design whose font downloaded over one that awaits it. A copy from the
    /// saved design's own tier is not saved, and the run designs the book at its tier instead;
    /// that design, which awaits its font too while fonts can't download, leaves the saved one.
    func testSeriesCopiesReplaceOnlyWeakerDesigns() async throws {
        let first = LocalRun.book(7, cover: CoverStub.defaultCover, series: 501, position: 1)
        let second = LocalRun.book(8, cover: CoverStub.secondCover, series: 501, position: 2)
        let awaiting = LocalRun.design(
            for: second, coverHash: String(repeating: "c", count: 64),
            provenance: "model:local font:system")
        for sourceAwaitsFont in [false, true] {
            let source = LocalRun.design(
                for: first, coverHash: String(repeating: "d", count: 64),
                provenance: sourceAwaitsFont ? "model:local font:system" : "model:local")
            let run = try LocalRun(books: [first, second], designs: [source, awaiting])
            defer { run.remove() }
            // The source's check is current, so the run checks only the second book.
            try await run.ledger.useCloudUser("local")
            try await run.ledger.recordSuccess(
                recordName: LocalRun.recordName(7), workItemHash: LocalRun.workHash(first),
                tier: .local)
            let (status, saved) = try await run.run()
            XCTAssertEqual(status.failed, 0)
            XCTAssertEqual(status.completed, 1)
            XCTAssertEqual(status.designed, sourceAwaitsFont ? 1 : 0)
            XCTAssertEqual(status.fromSeries, sourceAwaitsFont ? 0 : 1)
            XCTAssertEqual(saved.count, 1)
            let stored = try XCTUnwrap(try run.stored()[8])
            XCTAssertEqual(stored, saved.first)
            if sourceAwaitsFont {
                XCTAssertEqual(stored, awaiting)
            } else {
                XCTAssertEqual(stored.provenance, "series-reuse:7 model:local")
            }
            XCTAssertEqual(try run.stored()[7], source)
        }
    }

    /// A book that draws its series' look and keeps a copy of an older look, such as a
    /// default-styling look that a better tier upgraded since, or a look the reader recolored
    /// since, saves a copy of the look as it is now at its check, whatever tier made its copy,
    /// with no model request and no cover download. The new copies replace copies saved under
    /// the books' earlier titles. The look's source book and a book with its own design keep
    /// theirs.
    func testChecksReplaceCopiesOfAnOlderLook() async throws {
        let books = (7...10)
            .map {
                LocalRun.book($0, cover: CoverStub.numbered($0), series: 501, position: Double($0))
            }
        let gemini = "model:google/gemini-3.8-flash"
        let source = LocalRun.design(
            for: books[0], coverHash: String(repeating: "d", count: 64), provenance: gemini)
        let look = SeriesLookV1(
            design: source, key: try XCTUnwrap(SeriesDesigns.lookKey(of: books[0], link: nil)),
            createdAt: Date(timeIntervalSince1970: 1_000_000))
        let copyCover = String(repeating: "c", count: 64)
        func oldCopy(_ book: CloudBook, provenance: String) -> SpineDesignV1 {
            SpineDesignV1(
                version: 1, accountID: LocalRun.accountID, bookID: book.id,
                workItemHash: LocalRun.workHash(LocalRun.book(book.id, title: "An Earlier Title")),
                coverHash: copyCover,
                generatorVersion: CloudContract.generatorVersion,
                generatedAt: Date(timeIntervalSince1970: 1_000_000), backgroundHex: "#40FFC0",
                foregroundHex: "#000000", accentHex: "#204080", typeface: "sans", weight: 400,
                uppercase: false, provenance: provenance)
        }
        let designs = [
            source, oldCopy(books[1], provenance: "series-reuse:7 model:local"),
            oldCopy(books[2], provenance: "series-reuse:7 \(gemini)"),
            LocalRun.design(for: books[3], coverHash: copyCover, provenance: "model:local"),
        ]
        let run = try LocalRun(books: books, designs: designs, looks: [look])
        defer { run.remove() }
        let stub = DesignStub(delay: .zero)
        let (statuses, saved) = await run.run(status: .backupStub, stub: stub)

        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(status.completed, 4)
        XCTAssertEqual(status.designed, 0)
        XCTAssertEqual(status.fromSeries, 2)
        let started = await stub.started
        XCTAssertEqual(started, [], "No book sent a model request")
        XCTAssertEqual(saved.map(\.bookID).sorted(), [8, 9])
        let stored = try run.stored()
        for id in [8, 9] {
            let copy = try XCTUnwrap(stored[id])
            XCTAssertTrue(copy.isCopy(of: look.design(bookID: 7)))
            XCTAssertEqual(copy.provenance, "series-reuse:7 \(gemini)")
            XCTAssertEqual(copy.coverHash, copyCover)
            XCTAssertEqual(copy.workItemHash, LocalRun.workHash(books[id - 7]))
        }
        XCTAssertEqual(stored[7], designs[0])
        XCTAssertEqual(stored[10], designs[3])
    }

    /// A copy of an older look that the reader recolors during its book's check, such as while
    /// the copy's refresh waits for a font download, keeps the reader's colors: the refresh
    /// replaces only the copy the check read, even when it moves the copy to the book's new title.
    func testARefreshKeepsColorsTheReaderChoseDuringIt() async throws {
        let books = (7...8)
            .map {
                LocalRun.book($0, cover: CoverStub.numbered($0), series: 501, position: Double($0))
            }
        let source = LocalRun.design(
            for: books[0], coverHash: String(repeating: "d", count: 64),
            provenance: "model:google/gemini-3.8-flash")
        let look = SeriesLookV1(
            design: source, key: try XCTUnwrap(SeriesDesigns.lookKey(of: books[0], link: nil)),
            createdAt: Date(timeIntervalSince1970: 1_000_000))
        let stale = SpineDesignV1(
            version: 1, accountID: LocalRun.accountID, bookID: 8,
            workItemHash: LocalRun.workHash(LocalRun.book(8, title: "An Earlier Title")),
            coverHash: String(repeating: "c", count: 64),
            generatorVersion: CloudContract.generatorVersion,
            generatedAt: Date(timeIntervalSince1970: 1_000_000), backgroundHex: "#40FFC0",
            foregroundHex: "#000000", accentHex: "#204080", typeface: "sans", weight: 400,
            uppercase: false, provenance: "series-reuse:7 model:local")
        let run = try LocalRun(books: books, designs: [source, stale], looks: [look])
        defer { run.remove() }
        let local = LocalSpineStore(folder: run.folder)
        let colors = SpineColors(
            background: ColorValue(hex: "#1A2B3C")!, foreground: ColorValue(hex: "#F4E9D0")!,
            accent: ColorValue(hex: "#C08040")!)
        let store = HeldStore(local: local) { read in
            try await local.saveRecolored(read.recolored(colors))
        }
        let worker = run.worker(status: .backupStub, stub: DesignStub(delay: .zero), store: store)
        await worker.reconcile(mode: .foreground)
        let (statuses, saved) = await LocalRun.updates(of: worker)

        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.failed, 0)
        let kept = try XCTUnwrap(try run.stored()[8])
        XCTAssertEqual(kept.colors, colors)
        XCTAssertTrue(kept.hasReaderEdits)
        XCTAssertEqual(kept.workItemHash, stale.workItemHash)
        XCTAssertEqual(saved.last { $0.bookID == 8 }, kept, "The run reports the kept design")

        // The book is checked again after a day, not a week, and that check moves the edited
        // design to the book's new title.
        let recordName = LocalRun.recordName(8)
        let workHash = LocalRun.workHash(books[1])
        let dueNow = await run.ledger.needsCheck(recordName: recordName, workItemHash: workHash)
        XCTAssertFalse(dueNow)
        let dueTomorrow = await run.ledger.needsCheck(
            recordName: recordName, workItemHash: workHash,
            now: Date().addingTimeInterval(WorkLedger.failureBackoff))
        XCTAssertTrue(dueTomorrow)
        let later = run.worker(
            status: .backupStub, stub: DesignStub(delay: .zero),
            ledger: WorkLedger(url: run.folder.appending(path: "later-ledger.json")))
        await later.reconcile(mode: .foreground)
        _ = await LocalRun.updates(of: later)
        let moved = try XCTUnwrap(try run.stored()[8])
        XCTAssertEqual(moved.workItemHash, workHash)
        XCTAssertEqual(moved.colors, colors)
        XCTAssertTrue(moved.hasReaderEdits)
    }

    /// A run sends no request for a book that another device claimed, and leaves it unrecorded,
    /// so the next run checks it.
    func testARunLeavesABookThatAnotherDeviceClaimed() async throws {
        let books = [7, 8].map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
        let run = try LocalRun(books: books, designs: [])
        defer { run.remove() }
        let store = HeldStore(local: LocalSpineStore(folder: run.folder), claimedElsewhere: [8])
        let worker = run.worker(status: .backupStub, stub: DesignStub(delay: .zero), store: store)
        await worker.reconcile(mode: .foreground)
        let (statuses, _) = await LocalRun.updates(of: worker)

        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.designed, 1)
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(status.queue, 0)
        let stored = try run.stored()
        XCTAssertNotNil(stored[7])
        XCTAssertNil(stored[8])
        let due = await run.ledger.needsCheck(
            recordName: LocalRun.recordName(8), workItemHash: LocalRun.workHash(books[1]))
        XCTAssertTrue(due)
    }

    /// The cover the reader chose is designed even while another device holds the book's claim,
    /// such as right after that device designed the default cover.
    func testARunDesignsAChosenCoverThatAnotherDeviceClaimed() async throws {
        let book = LocalRun.book(7, cover: CoverStub.defaultCover)
        let fromDefault = LocalRun.design(
            for: book, coverHash: CloudContract.digest(CoverStub.images[CoverStub.defaultCover]!),
            generator: "ios-pcc-v1")
        let run = try LocalRun(
            books: [book], designs: [fromDefault], chosen: [7: CoverStub.chosenCover])
        defer { run.remove() }
        let store = HeldStore(local: LocalSpineStore(folder: run.folder), claimedElsewhere: [7])
        let worker = run.worker(status: .backupStub, stub: DesignStub(delay: .zero), store: store)
        await worker.reconcile(mode: .foreground)
        let (statuses, _) = await LocalRun.updates(of: worker)

        XCTAssertEqual(try XCTUnwrap(statuses.last).designed, 1)
        XCTAssertNotEqual(try run.stored()[7], fromDefault)
    }

    /// A book whose requests Apple's model never answers fails, and the run pauses with a
    /// retry time. The next run moves past the book instead of stopping at it again.
    func testABookTheModelNeverAnswersFailsAndTheNextRunMovesPastIt() async throws {
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let books = [7, 8].map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
        let run = try LocalRun(books: books, designs: [])
        defer { run.remove() }
        let stalled = run.worker(
            status: pcc, designBook: { _, _, _, _, _ in throw CompanionError.modelTimedOut })
        await stalled.reconcile(mode: .foreground)
        let (statuses, _) = await LocalRun.updates(of: stalled)

        let paused = try XCTUnwrap(statuses.last)
        XCTAssertEqual(paused.phase, WorkerSnapshot.pausedPhase)
        XCTAssertEqual(paused.failed, 1)
        XCTAssertEqual(paused.designed, 0)
        XCTAssertNotNil(paused.retryAfter)

        let next = run.worker(status: pcc, stub: DesignStub(delay: .zero))
        await next.reconcile(mode: .foreground)
        _ = await LocalRun.updates(of: next)
        let stored = try run.stored()
        XCTAssertNil(stored[7])
        XCTAssertNotNil(stored[8])
    }

    /// A group refresh after a look's upgrade keeps colors that the reader chose for a copy
    /// after the refresh read it, and refreshes the group's other copies.
    func testAGroupRefreshKeepsColorsTheReaderChoseDuringIt() async throws {
        let books = (7...9)
            .map {
                LocalRun.book($0, cover: CoverStub.numbered($0), series: 501, position: Double($0))
            }
        let fontless = LocalRun.design(
            for: books[0], coverHash: String(repeating: "d", count: 64), provenance: "model:local")
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: books[0], link: nil))
        let look = SeriesLookV1(
            design: fontless, key: key, createdAt: Date(timeIntervalSince1970: 1_000_000))
        let copies = try books.dropFirst()
            .map { book in
                try XCTUnwrap(
                    SpineDesignV1(
                        copying: look.design(bookID: 7), bookID: book.id,
                        accountID: LocalRun.accountID, workItemHash: LocalRun.workHash(book),
                        coverHash: String(repeating: "c", count: 64),
                        generatedAt: Date(timeIntervalSince1970: 1_000_000)))
            }
        let run = try LocalRun(books: books, designs: [fontless] + copies, looks: [look])
        defer { run.remove() }
        try await run.ledger.useCloudUser("local")
        for copy in copies {
            try await run.ledger.recordSuccess(
                recordName: LocalRun.recordName(copy.bookID), workItemHash: copy.workItemHash,
                tier: .backup)
        }
        let local = LocalSpineStore(folder: run.folder)
        let colors = SpineColors(
            background: ColorValue(hex: "#1A2B3C")!, foreground: ColorValue(hex: "#F4E9D0")!,
            accent: ColorValue(hex: "#C08040")!)
        // Only the group refresh checks the design it read; book 7's own design saves without.
        let store = HeldStore(local: local) { read in
            if read.bookID == 9 { try await local.saveRecolored(read.recolored(colors)) }
        }
        let worker = run.worker(status: .backupStub, stub: DesignStub(delay: .zero), store: store)
        await worker.reconcile(mode: .foreground)
        let (statuses, _) = await LocalRun.updates(of: worker)

        XCTAssertEqual(try XCTUnwrap(statuses.last).failed, 0)
        let stored = try run.stored()
        XCTAssertEqual(stored[8]?.provenance, "series-reuse:7 model:custom/stub")
        let edited = try XCTUnwrap(stored[9])
        XCTAssertEqual(edited.colors, colors)
        XCTAssertTrue(edited.hasReaderEdits)
    }

    /// A design that upgrades its series' look also gives the group's other books copies of the
    /// new look in the same run, without checking them or sending them a request.
    func testUpgradingALookRefreshesTheGroupsCopies() async throws {
        let books = (7...9)
            .map {
                LocalRun.book($0, cover: CoverStub.numbered($0), series: 501, position: Double($0))
            }
        let fontless = LocalRun.design(
            for: books[0], coverHash: String(repeating: "d", count: 64), provenance: "model:local")
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: books[0], link: nil))
        let look = SeriesLookV1(
            design: fontless, key: key, createdAt: Date(timeIntervalSince1970: 1_000_000))
        let copies = try books.dropFirst()
            .map { book in
                try XCTUnwrap(
                    SpineDesignV1(
                        copying: look.design(bookID: 7), bookID: book.id,
                        accountID: LocalRun.accountID, workItemHash: LocalRun.workHash(book),
                        coverHash: String(repeating: "c", count: 64),
                        generatedAt: Date(timeIntervalSince1970: 1_000_000)))
            }
        let run = try LocalRun(books: books, designs: [fontless] + copies, looks: [look])
        defer { run.remove() }
        // The copies' checks are current, so the run checks only the look's source book.
        try await run.ledger.useCloudUser("local")
        for copy in copies {
            try await run.ledger.recordSuccess(
                recordName: LocalRun.recordName(copy.bookID), workItemHash: copy.workItemHash,
                tier: .backup)
        }
        let stub = DesignStub(delay: .zero)
        let (statuses, saved) = await run.run(status: .backupStub, stub: stub)

        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(status.completed, 1)
        XCTAssertEqual(status.designed, 1)
        let started = await stub.started
        XCTAssertEqual(started, [7])
        let upgraded =
            try await LocalSpineStore(folder: run.folder)
            .seriesLooks(accountID: LocalRun.accountID, keys: [key])[key]
        XCTAssertEqual(upgraded?.provenance, "model:custom/stub")
        XCTAssertEqual(saved.map(\.bookID).sorted(), [7, 8, 9])
        let stored = try run.stored()
        for id in [8, 9] {
            XCTAssertEqual(stored[id]?.provenance, "series-reuse:7 model:custom/stub")
            XCTAssertEqual(stored[id]?.fontPostScriptName, "Georgia-Bold")
        }
    }

    /// A local-defaults run while fonts can't download goes on past a book whose series look's
    /// font it can't check: the book gets a design of its own in its system typeface, which
    /// awaits its font, so a later run designs it again.
    func testLocalRunsGoOnWhenASeriesFontCannotDownload() async throws {
        let source = LocalRun.book(7, cover: CoverStub.numbered(7), series: 501, position: 1)
        let later = LocalRun.book(8, cover: CoverStub.numbered(8), series: 501, position: 2)
        var lettered = LocalRun.design(
            for: source, coverHash: String(repeating: "d", count: 64),
            provenance: "model:google/gemini-3.8-flash")
        lettered.fontFamily = "Lora"
        let look = SeriesLookV1(
            design: lettered, key: try XCTUnwrap(SeriesDesigns.lookKey(of: source, link: nil)),
            createdAt: Date(timeIntervalSince1970: 1_000_000))
        let run = try LocalRun(books: [source, later], designs: [lettered], looks: [look])
        defer { run.remove() }
        let (status, saved) = try await run.run()

        XCTAssertEqual(status.phase, "Finished")
        XCTAssertEqual(status.failed, 0)
        let made = try XCTUnwrap(saved.first { $0.bookID == 8 })
        XCTAssertTrue(made.awaitsFont)
        XCTAssertFalse(made.isSeriesReuse)
        XCTAssertEqual(try run.stored()[7], lettered)
    }

    /// When another device saves a design of the book at the run's tier while the run designs
    /// it, iCloud keeps that design: the run reports and records it, and creates no series look
    /// from its own design.
    func testADesignAnotherDeviceSavedFirstIsTheOneTheRunKeeps() async throws {
        let book = LocalRun.book(7, cover: CoverStub.numbered(7), series: 501, position: 1)
        let run = try LocalRun(books: [book], designs: [])
        defer { run.remove() }
        let theirs = LocalRun.design(
            for: book, coverHash: String(repeating: "e", count: 64),
            provenance: "model:google/gemini-3.8-flash")
        let designs = run.folder.appending(path: "spine-designs-v1.json")
        let worker = run.worker(status: .backupStub) {
            book, accountID, workItemHash, cover, model in
            // Another device's run saves its design while this one waits for the model.
            try JSONEncoder().encode([LocalRun.recordName(book.id): theirs]).write(to: designs)
            return SpineDesignV1(
                version: 1, accountID: accountID, bookID: book.id, workItemHash: workItemHash,
                coverHash: cover.hash, generatorVersion: CloudContract.generatorVersion,
                generatedAt: Date(), backgroundHex: "#F4EEE2", foregroundHex: "#101010",
                accentHex: "#7A1F1F", typeface: "sans", weight: 400, uppercase: true,
                provenance: model.provenance)
        }
        await worker.reconcile(mode: .foreground)
        let (statuses, saved) = await LocalRun.updates(of: worker)

        XCTAssertEqual(statuses.last?.failed, 0)
        XCTAssertEqual(saved, [theirs])
        XCTAssertEqual(try run.stored()[7], theirs)
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: book, link: nil))
        let looks = try await LocalSpineStore(folder: run.folder)
            .seriesLooks(accountID: LocalRun.accountID, keys: [key])
        XCTAssertEqual(looks, [:], "No look comes from a design iCloud never stored")
        let due = await run.ledger.needsCheck(
            recordName: LocalRun.recordName(7), workItemHash: LocalRun.workHash(book),
            runTier: .backup)
        XCTAssertFalse(due)
    }

    /// A run with the backup model designs up to `SpineWorker.backupConcurrency` books at once,
    /// and a look group's books take turns. The first series' titles are in a script that
    /// Georgia, the stub designs' face, lacks, but its later books still copy its look, in the
    /// look's system typeface, so the series keeps one font; the second series' later book
    /// copies its look too. The counts add up in every status, and a book that fails fails
    /// alone.
    func testBackupRunsDesignSeveralBooksAtOnceAndASeriesInTurn() async throws {
        var books = (1...8)
            .map {
                LocalRun.book($0, title: "Lantern \($0)", cover: CoverStub.numbered($0))
            }
        // The first series' books stand among the others in the queue.
        let series = [20, 21, 22]
        for (index, title) in ["灯台守", "塩と雑音", "静かな軌道"].enumerated() {
            books.insert(
                LocalRun.book(
                    series[index], title: title, cover: CoverStub.numbered(series[index]),
                    series: 501, position: Double(index + 1)),
                at: index * 3)
        }
        books += [
            LocalRun.book(
                30, title: "Static One", cover: CoverStub.numbered(30), series: 502, position: 1),
            LocalRun.book(
                31, title: "Static Two", cover: CoverStub.numbered(31), series: 502, position: 2),
        ]
        let stub = DesignStub(
            delay: .milliseconds(150), failures: [5: CompanionError.invalidDesign])
        let run = try LocalRun(books: books, designs: [])
        defer { run.remove() }
        let (statuses, saved) = await run.run(status: .backupStub, stub: stub)

        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.phase, "Finished")
        XCTAssertEqual(status.completed, 12)
        XCTAssertEqual(status.failed, 1)
        XCTAssertEqual(status.designed, 9)
        XCTAssertEqual(status.fromSeries, 3)
        XCTAssertEqual(status.queue, 0)
        XCTAssertEqual(saved.count, 12)
        XCTAssertEqual(try run.stored()[31]?.provenance, "series-reuse:30 model:custom/stub")
        for id in [21, 22] {
            let copy = try XCTUnwrap(try run.stored()[id])
            XCTAssertEqual(copy.provenance, "series-reuse:20 model:custom/stub")
            XCTAssertNil(copy.fontPostScriptName, "The copy letters in the system typeface")
        }
        let mostAtOnce = await stub.mostAtOnce
        XCTAssertEqual(mostAtOnce, SpineWorker.backupConcurrency)
        let alongside = await stub.alongside
        XCTAssertFalse(
            alongside.contains { $0.intersection(series).count > 1 },
            "Two books of one series were designed at once")
        let designing = statuses.filter { $0.designingBook != nil }
        XCTAssertFalse(designing.isEmpty)
        for status in designing {
            XCTAssertEqual(status.completed + status.failed + status.queue, books.count)
            XCTAssertTrue(status.headline.hasSuffix(" of \(books.count)"), status.headline)
        }
    }

    /// A rate limit from one book stops a backup run once: the run cancels the other books in
    /// flight, starts no more, and saves or records nothing for them, so every book stays
    /// queued for the next run, which waits for the provider's retry time.
    func testARateLimitStopsTheRunAndCancelsTheOtherBooks() async throws {
        // Twice as many books as the run designs at once, so some wait in the queue.
        let books = (1...(2 * SpineWorker.backupConcurrency))
            .map {
                LocalRun.book($0, cover: CoverStub.numbered($0))
            }
        let retry = Date().addingTimeInterval(120)
        let limited = try XCTUnwrap(
            BookAnalyzer.modelFailure(
                ProviderError(
                    provider: .google, status: 429, retryAfter: retry,
                    message: "Resource exhausted.")))
        let stub = DesignStub(
            delay: .seconds(30), delays: [3: .milliseconds(300)], failures: [3: limited])
        let run = try LocalRun(books: books, designs: [])
        defer { run.remove() }
        let start = ContinuousClock.now
        let (statuses, saved) = await run.run(status: .backupStub, stub: stub)

        XCTAssertLessThan(start.duration(to: .now), .seconds(10))
        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.phase, "Paused")
        XCTAssertEqual(status.retryAfter, retry)
        XCTAssertEqual(status.completed, 0)
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(status.queue, books.count)
        XCTAssertEqual(saved, [])
        let started = Set(await stub.started)
        let cancelled = await stub.cancelled
        XCTAssertTrue(started.contains(3))
        XCTAssertTrue(
            started.isSubset(of: Set(1...SpineWorker.backupConcurrency)),
            "The run started books after the stop")
        XCTAssertEqual(Set(cancelled), started.subtracting([3]))
        XCTAssertEqual(cancelled.count, started.count - 1)
        for book in books {
            let due = await run.ledger.needsCheck(
                recordName: LocalRun.recordName(book.id), workItemHash: LocalRun.workHash(book))
            XCTAssertTrue(due, "Book \(book.id) was recorded")
        }
    }

    /// Stop cancels every book in flight at once, and the run saves nothing from them.
    func testStopCancelsEveryBookInFlight() async throws {
        // More books than the run designs at once, so some wait in the queue.
        let books = (1...(SpineWorker.backupConcurrency + 2))
            .map {
                LocalRun.book($0, cover: CoverStub.numbered($0))
            }
        let stub = DesignStub(delay: .seconds(30))
        let run = try LocalRun(books: books, designs: [])
        defer { run.remove() }
        let worker = run.worker(status: .backupStub, stub: stub)
        let start = ContinuousClock.now
        let reconcile = Task { await worker.reconcile(mode: .foreground) }
        while await stub.inFlight.count < SpineWorker.backupConcurrency {
            guard start.duration(to: .now) < .seconds(10) else {
                return XCTFail("The run never had a full set of books in flight")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        reconcile.cancel()
        await reconcile.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(10))

        let (statuses, saved) = await LocalRun.updates(of: worker)
        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.phase, "Stopped")
        XCTAssertEqual(status.completed, 0)
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(status.queue, books.count)
        XCTAssertEqual(saved, [])
        let cancelled = await stub.cancelled
        XCTAssertEqual(cancelled.sorted(), Array(1...SpineWorker.backupConcurrency))
        let started = await stub.started
        XCTAssertEqual(started.count, SpineWorker.backupConcurrency)
    }

    /// Apple's tiers design one book at a time.
    func testAppleTiersDesignOneBookAtATime() async throws {
        let tiers = [
            ModelStatus.local,
            ModelStatus(
                tier: .onDevice, isAvailable: true, unavailableReason: nil, coverReader: .onDevice),
            ModelStatus(
                tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
                coverReader: .designModel),
        ]
        for model in tiers {
            let books = (1...5).map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
            let stub = DesignStub(delay: .milliseconds(30))
            let run = try LocalRun(books: books, designs: [])
            defer { run.remove() }
            let (statuses, _) = await run.run(status: model, stub: stub)
            XCTAssertEqual(statuses.last?.designed, 5, "\(model.tier)")
            let mostAtOnce = await stub.mostAtOnce
            XCTAssertEqual(mostAtOnce, 1, "\(model.tier)")
        }
    }

    /// Concurrent designs that need one cover or one font family share its downloads: one
    /// request for the cover, and one each for the Google Fonts catalog, the family's file list,
    /// and its file.
    func testConcurrentDesignsShareCoverAndFontDownloads() async throws {
        SlowStub.reset()
        let covers = CoverDownloader(protocolClasses: [SlowStub.self])
        async let first = covers.fetch([SlowStub.cover])
        async let second = covers.fetch([SlowStub.cover])
        async let third = covers.fetch([SlowStub.cover])
        let hashes = try await [first, second, third].map(\.hash)
        XCTAssertEqual(Set(hashes).count, 1)
        XCTAssertEqual(SlowStub.count("cover"), 1)

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-fonts-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowStub.self]
        let fonts = GoogleFonts(root: folder, configuration: configuration)
        func load() async -> Bool {
            (try? await fonts.download(family: SlowStub.family, weight: 400)) != nil
        }
        async let one = load()
        async let two = load()
        async let three = load()
        // The file is not a font, so no load succeeds.
        let loaded = await [one, two, three]
        XCTAssertEqual(loaded, [false, false, false])
        for kind in ["catalog", "manifest", "file"] {
            XCTAssertEqual(SlowStub.count(kind), 1, kind)
        }
    }

    /// A candidate whose image can't decode, such as one over the pixel limit, gives way to the
    /// next before its bytes are kept, as a missing cover does.
    func testCoverDownloadSkipsACandidateTooLargeToDecode() async throws {
        let covers = CoverDownloader(protocolClasses: [CoverStub.self])
        let candidates = [CoverStub.oversizedCover, CoverStub.defaultCover]
        let cover = try await covers.fetch(candidates)
        XCTAssertEqual(cover.url, CoverStub.defaultCover)
        let kept = try await covers.fetchData(candidates, fallsBackOnServerError: true)
        XCTAssertEqual(kept.url, CoverStub.defaultCover)
    }

    /// A cover's text read that never returns, as Vision's can on a locked Mac, is cancelled and
    /// abandoned at its timeout, and the design fails rather than go on without the cover's text.
    /// While the read still holds the reader's queue, later reads fail at once; after it returns,
    /// they read again.
    func testATextReadThatHangsIsAbandonedAtItsTimeout() async throws {
        let reads = HangingReads()
        addTeardownBlock { reads.release() }
        let reader = reads.reader(timeout: .milliseconds(300))
        let start = ContinuousClock.now
        do {
            _ = try await offlineAnalyzer(textReader: reader)
                .design(
                    book: Self.orbit, accountID: "42", workItemHash: Self.hash, cover: Self.cover,
                    using: .local)
            XCTFail("A design went on without its cover's text")
        } catch CompanionError.coverTextTimedOut {}
        let waited = start.duration(to: .now)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(300))
        XCTAssertLessThan(waited, .seconds(5))
        XCTAssertEqual(reads.cancelled, 1)

        let skipped = ContinuousClock.now
        do {
            _ = try await reader.lines(in: Self.cover.image)
            XCTFail("A read waited behind the abandoned read")
        } catch CompanionError.coverTextBusy {}
        XCTAssertLessThan(skipped.duration(to: .now), .milliseconds(100))
        XCTAssertEqual(reads.performed, 1)
        reads.release()
        let released = ContinuousClock.now
        while reads.performed < 2 {
            guard released.duration(to: .now) < .seconds(5) else {
                return XCTFail("The reader never read again")
            }
            _ = try? await reader.lines(in: Self.cover.image)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A read whose caller was cancelled, as by **Stop**, hasn't shown a hang, so the next read
    /// waits behind it on the queue rather than throw `CompanionError.coverTextBusy`.
    func testACancelledTextReadLeavesTheReaderFree() async throws {
        let reads = HangingReads()
        addTeardownBlock { reads.release() }
        let reader = reads.reader(timeout: .seconds(600))
        let first = Task { try await reader.lines(in: Self.cover.image) }
        let start = ContinuousClock.now
        while reads.hanging == 0 {
            guard start.duration(to: .now) < .seconds(10) else {
                first.cancel()
                return XCTFail("The read never started")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("The cancelled read finished")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let next = Task { try await reader.lines(in: Self.cover.image) }
        try await Task.sleep(for: .milliseconds(100))
        reads.release()
        let lines = try await next.value
        XCTAssertEqual(lines.count, 0)
        XCTAssertEqual(reads.performed, 2)
    }

    /// The analyzer answers other books while a cover's text read hangs, and cancelling the
    /// design ends its wait at once and cancels the read.
    func testCancellingADesignEndsItsHungTextRead() async throws {
        let reads = HangingReads()
        addTeardownBlock { reads.release() }
        let analyzer = offlineAnalyzer(textReader: reads.reader(timeout: .seconds(600)))
        let design = Task {
            try await analyzer.design(
                book: Self.orbit, accountID: "42", workItemHash: Self.hash, cover: Self.cover,
                using: .local)
        }
        let start = ContinuousClock.now
        while reads.hanging == 0 {
            guard start.duration(to: .now) < .seconds(10) else {
                design.cancel()
                return XCTFail("The read never started")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let letters = try await analyzer.letters(
            Self.orbit, with: LocalRun.design(for: LocalRun.book(1), coverHash: Self.hash))
        XCTAssertTrue(letters)
        let cancelled = ContinuousClock.now
        design.cancel()
        do {
            _ = try await design.value
            XCTFail("The cancelled design finished")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(cancelled.duration(to: .now), .seconds(1))
        XCTAssertEqual(reads.cancelled, 1)
    }

    /// **Stop** ends a run at once while a cover's text read hangs, and saves nothing.
    func testStopEndsARunWhoseTextReadHangs() async throws {
        let reads = HangingReads()
        addTeardownBlock { reads.release() }
        let books = (1...3).map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
        let run = try LocalRun(books: books, designs: [])
        defer { run.remove() }
        let worker = run.worker(textReader: reads.reader(timeout: .seconds(600)))
        let reconcile = Task { await worker.reconcile(mode: .foreground) }
        let start = ContinuousClock.now
        while reads.hanging == 0 {
            guard start.duration(to: .now) < .seconds(10) else {
                reconcile.cancel()
                return XCTFail("The run never read a cover")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stopped = ContinuousClock.now
        reconcile.cancel()
        await reconcile.value
        XCTAssertLessThan(stopped.duration(to: .now), .seconds(2))

        let (statuses, saved) = await LocalRun.updates(of: worker)
        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.phase, "Stopped")
        XCTAssertEqual(status.completed, 0)
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(status.queue, books.count)
        XCTAssertEqual(saved, [])
        XCTAssertEqual(reads.cancelled, 1)
    }

    /// One book whose cover's text read hangs holds up a backup run only until the read's
    /// timeout. That book fails, so it isn't designed without its text, and the run stops with
    /// the books whose reads waited behind it still queued, rather than design them without
    /// their text while the read holds Vision.
    func testAHungTextReadFailsItsBookAndStopsTheRun() async throws {
        // Book 100's cover is far redder than the others', so color management can't confuse
        // them.
        let reads = HangingReads { HangingReads.red(of: $0) > 50 }
        addTeardownBlock { reads.release() }
        let books = ([100] + Array(1...7)).map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
        let run = try LocalRun(books: books, designs: [])
        defer { run.remove() }
        let worker = run.worker(
            status: .backupStub, textReader: reads.reader(timeout: .seconds(1)),
            designsLocally: true)
        let start = ContinuousClock.now
        await worker.reconcile(mode: .foreground)
        XCTAssertLessThan(start.duration(to: .now), .seconds(8))

        let (statuses, saved) = await LocalRun.updates(of: worker)
        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.phase, WorkerSnapshot.pausedPhase)
        XCTAssertEqual(status.error, CompanionError.coverTextTimedOut.errorDescription)
        XCTAssertEqual(status.failed, 1)
        // Books whose reads finished before the hang may be designed; the hung one never is, and
        // no book is designed without a finished read. The books whose reads waited behind the
        // hang stay queued: the run stops rather than start them again.
        XCTAssertFalse(saved.contains { $0.bookID == 100 })
        XCTAssertLessThanOrEqual(status.designed, reads.performed - 1)
        XCTAssertGreaterThan(status.queue, 0)
        XCTAssertEqual(reads.hanging, 1)
        XCTAssertGreaterThanOrEqual(reads.cancelled, 1)
    }

    private static let orbit = CloudBook(
        id: 9, title: "A Quiet Orbit", author: "Ann Author", coverURL: nil, detailCoverURL: nil,
        genres: ["Science Fiction"])
    private static let hash = String(repeating: "a", count: 64)
    private static let cover = CoverImage(
        image: CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(CoverStub.png(red: 30) as CFData, nil)!, 0, nil)!,
        hash: hash, url: CoverStub.defaultCover)

    /// An analyzer that reads covers' text with `textReader` and downloads no font.
    private func offlineAnalyzer(textReader: CoverTextReader) -> BookAnalyzer {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-fonts-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        return BookAnalyzer(
            fonts: GoogleFonts(root: root, configuration: configuration), textReader: textReader)
    }

    func testRunsPreferPrivateCloudComputeThenTheBackupThenTheOnDeviceModelThenLocalDefaults()
        async
    {
        func status(_ tier: ModelTier, available: Bool, quota: ModelStatus.Quota = .belowLimit)
            -> ModelStatus
        {
            ModelStatus(
                tier: tier, isAvailable: available,
                unavailableReason: available ? nil : "\(tier) unavailable",
                coverReader: .designModel, quota: quota)
        }
        // Private Cloud Compute over its daily limit still designs: the run waits for the reset.
        let pcc = BookAnalyzer.bestStatus(
            pcc: status(.privateCloudCompute, available: true, quota: .limitReached),
            backup: status(.backup, available: true), onDevice: status(.onDevice, available: true))
        XCTAssertEqual(pcc.tier, .privateCloudCompute)
        XCTAssertNil(pcc.pccUnavailableReason)
        XCTAssertNotNil(SpineWorker.modelStop(pcc, mode: .foreground))

        let backup = BookAnalyzer.bestStatus(
            pcc: status(.privateCloudCompute, available: false),
            backup: status(.backup, available: true), onDevice: status(.onDevice, available: true))
        XCTAssertEqual(backup.tier, .backup)
        XCTAssertEqual(backup.pccUnavailableReason, "privateCloudCompute unavailable")

        // Private Cloud Compute without image input reports itself unavailable, so the next
        // tier designs and records its own tier.
        var blind = status(.privateCloudCompute, available: false)
        blind.unavailableReason = "Private Cloud Compute can't design spines on this iPhone."
        let sighted = BookAnalyzer.bestStatus(
            pcc: blind, backup: status(.backup, available: false),
            onDevice: status(.onDevice, available: true))
        XCTAssertEqual(sighted.tier, .onDevice)
        XCTAssertEqual(sighted.provenance, ModelTier.onDeviceToken)
        XCTAssertEqual(sighted.pccUnavailableReason, blind.unavailableReason)

        // A backup that isn't set up on this device, such as one without a key, is skipped.
        let onDevice = BookAnalyzer.bestStatus(
            pcc: status(.privateCloudCompute, available: false),
            backup: status(.backup, available: false), onDevice: status(.onDevice, available: true))
        XCTAssertEqual(onDevice.tier, .onDevice)
        XCTAssertEqual(onDevice.pccUnavailableReason, "privateCloudCompute unavailable")
        XCTAssertNil(onDevice.backupUnavailableReason, "No backup was chosen")
        XCTAssertNil(onDevice.onDeviceUnavailableReason)

        // A backup the reader chose but didn't set up says why under the lower tier.
        let custom = SpineDesigner(provider: .custom, model: "local-model", baseURL: "")
        var unset = status(.backup, available: false)
        unset.designer = custom
        unset.unavailableReason = custom.problem
        let skipped = BookAnalyzer.bestStatus(
            pcc: status(.privateCloudCompute, available: false), backup: unset,
            onDevice: status(.onDevice, available: true))
        XCTAssertEqual(skipped.tier, .onDevice)
        XCTAssertEqual(
            skipped.backupUnavailableReason,
            "Enter your endpoint's base URL, starting with http:// or https://.")
        // An address typed without a scheme parses with its host as the scheme.
        var schemeless = custom
        schemeless.baseURL = "localhost:1234/v1"
        XCTAssertEqual(schemeless.problem, custom.problem)
        let pccOverUnset = BookAnalyzer.bestStatus(
            pcc: status(.privateCloudCompute, available: true), backup: unset,
            onDevice: status(.onDevice, available: true))
        XCTAssertNil(pccOverUnset.backupUnavailableReason)

        // With no model available, local defaults design and record why each model is missing.
        let local = BookAnalyzer.bestStatus(
            pcc: status(.privateCloudCompute, available: false),
            backup: status(.backup, available: false), onDevice: status(.onDevice, available: false)
        )
        XCTAssertEqual(local.tier, .local)
        XCTAssertEqual(local.coverReader, .measurementsOnly)
        XCTAssertEqual(local.pccUnavailableReason, "privateCloudCompute unavailable")
        XCTAssertEqual(local.onDeviceUnavailableReason, "onDevice unavailable")
        XCTAssertEqual(local.designerName, "Default styling")
        XCTAssertNil(SpineWorker.modelStop(local, mode: .background))
        let watched = await BookAnalyzer().status(of: .local, designer: .appleOnly)
        XCTAssertTrue(watched.isAvailable, "Local defaults never stop a run")
        XCTAssertNil(SpineWorker.modelStop(watched, mode: .background))

        XCTAssertEqual(
            SpineDesigner.appleOnly.problem, "Choose a provider.",
            "The on-device choice names no provider")
    }

    /// A saved key that the Keychain refused to read for now says so instead of asking for a
    /// key, and the run waits for it: no lower tier designs, and the run stops with the message
    /// before any request, until a later background run reads the key again. A read that fails
    /// the same way every time counts as no key.
    func testAnUnreadableKeyWaitsInsteadOfFallingBack() {
        let locked = KeychainSecret.Unreadable(status: errSecInteractionNotAllowed)
        let anthropic = SpineDesigner(choosing: .anthropic)
        let refused = anthropic.readiness { throw locked }
        let advice = "Unlock this \(ThisDevice.name), then try again."
        XCTAssertEqual(refused.problem, "Couldn't read your Anthropic API key. \(advice)")
        XCTAssertTrue(refused.keyIsUnreadable)
        let broken = anthropic.readiness {
            throw KeychainSecret.Unreadable(status: errSecMissingEntitlement)
        }
        XCTAssertEqual(broken.problem, "Add your Anthropic API key.")
        XCTAssertFalse(broken.keyIsUnreadable, "A read that never passes doesn't wait")
        let missing = anthropic.readiness { nil }
        XCTAssertEqual(missing.problem, "Add your Anthropic API key.")
        XCTAssertFalse(missing.keyIsUnreadable)
        let custom = SpineDesigner(
            provider: .custom, model: "local-model", baseURL: "http://endpoint.localhost")
        XCTAssertNil(custom.readiness { nil }.problem, "A custom endpoint may need no key")
        let lockedCustom = custom.readiness { throw locked }
        XCTAssertTrue(lockedCustom.keyIsUnreadable)
        XCTAssertEqual(lockedCustom.problem, "Couldn't read your endpoint's API key. \(advice)")

        func status(_ tier: ModelTier) -> ModelStatus {
            ModelStatus(
                tier: tier, isAvailable: true, unavailableReason: nil, coverReader: .designModel)
        }
        var waiting = ModelStatus(
            tier: .backup, isAvailable: false, unavailableReason: refused.problem,
            coverReader: .designModel, designer: anthropic)
        waiting.waitsForKey = true
        let unavailablePCC = ModelStatus(
            tier: .privateCloudCompute, isAvailable: false, unavailableReason: "unavailable",
            coverReader: .designModel)
        // Whenever the backup would design: without Private Cloud Compute, or before it.
        for (pcc, prefersBackup) in [(unavailablePCC, false), (status(.privateCloudCompute), true)]
        {
            let best = BookAnalyzer.bestStatus(
                pcc: pcc, backup: waiting, onDevice: status(.onDevice),
                prefersBackup: prefersBackup)
            XCTAssertEqual(best.tier, .backup)
            XCTAssertFalse(best.isAvailable)
            XCTAssertNil(best.backupUnavailableReason, "The status's own reason says why")
            let now = Date()
            let stop = SpineWorker.modelStop(best, mode: .foreground, now: now)
            XCTAssertEqual(stop?.message, refused.problem)
            XCTAssertEqual(stop?.retryAfter, now.addingTimeInterval(SpineWorker.keyRetryDelay))
        }
        // A refusal during a run stops it, so a later run reads the key again.
        let now = Date()
        XCTAssertEqual(
            SpineWorker.disposition(of: CompanionError.keyUnreadable("Couldn't read"), now: now),
            .stopRun(retryAfter: now.addingTimeInterval(SpineWorker.keyRetryDelay)))
    }

    /// With the reader's override, the backup model designs before Private Cloud Compute, which
    /// designs only while the backup can't; the on-device model and local defaults follow as
    /// before. The override is off by default, and builds without Private Cloud Compute ignore
    /// it.
    func testTheChosenModelCanDesignInsteadOfPrivateCloudCompute() throws {
        func status(_ tier: ModelTier, available: Bool) -> ModelStatus {
            ModelStatus(
                tier: tier, isAvailable: available,
                unavailableReason: available ? nil : "\(tier) unavailable",
                coverReader: .designModel)
        }
        let pcc = status(.privateCloudCompute, available: true)
        let backup = status(.backup, available: true)
        let onDevice = status(.onDevice, available: true)
        XCTAssertEqual(
            BookAnalyzer.bestStatus(pcc: pcc, backup: backup, onDevice: onDevice).tier,
            .privateCloudCompute, "Private Cloud Compute designs first by default")
        let preferred = BookAnalyzer.bestStatus(
            pcc: pcc, backup: backup, onDevice: onDevice, prefersBackup: true)
        XCTAssertEqual(preferred.tier, .backup)
        XCTAssertNil(preferred.pccUnavailableReason, "Private Cloud Compute is available")

        // A backup that can't design leaves the run to Private Cloud Compute, which says why.
        let custom = SpineDesigner(provider: .custom, model: "local-model", baseURL: "")
        var unset = status(.backup, available: false)
        unset.designer = custom
        unset.unavailableReason = custom.problem
        let fallback = BookAnalyzer.bestStatus(
            pcc: pcc, backup: unset, onDevice: onDevice, prefersBackup: true)
        XCTAssertEqual(fallback.tier, .privateCloudCompute)
        XCTAssertEqual(
            fallback.backupUnavailableReason,
            "Enter your endpoint's base URL, starting with http:// or https://.")

        // Without both, the on-device model designs, then local defaults.
        let neither = BookAnalyzer.bestStatus(
            pcc: status(.privateCloudCompute, available: false), backup: unset,
            onDevice: onDevice, prefersBackup: true)
        XCTAssertEqual(neither.tier, .onDevice)
        XCTAssertEqual(neither.pccUnavailableReason, "privateCloudCompute unavailable")
        XCTAssertEqual(
            neither.backupUnavailableReason,
            "Enter your endpoint's base URL, starting with http:// or https://.")
        let local = BookAnalyzer.bestStatus(
            pcc: status(.privateCloudCompute, available: false), backup: unset,
            onDevice: status(.onDevice, available: false), prefersBackup: true)
        XCTAssertEqual(local.tier, .local)
        XCTAssertEqual(local.onDeviceUnavailableReason, "onDevice unavailable")

        // The override saves per device and starts off.
        let key = "SpineDesignerOverridesPCC"
        let readersChoice = UserDefaults.standard.object(forKey: key) as? Bool
        let tests = try XCTUnwrap(UserDefaults(suiteName: "gay.ian.Bookworms.tests"))
        defer { tests.removeObject(forKey: key) }
        tests.removeObject(forKey: key)
        XCTAssertFalse(SpineDesigner.overridesPrivateCloudCompute)
        SpineDesigner.overridesPrivateCloudCompute = true
        #if NO_PCC
            XCTAssertFalse(SpineDesigner.overridesPrivateCloudCompute, "NO_PCC builds ignore it")
        #else
            XCTAssertTrue(SpineDesigner.overridesPrivateCloudCompute)
        #endif
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? Bool, readersChoice,
            "Tests keep their own defaults")
    }

    func testThirdPartyProvidersNeedConsentOnce() throws {
        let tests = try XCTUnwrap(UserDefaults(suiteName: "gay.ian.Bookworms.tests"))
        let thirdParty: [SpineDesigner.Provider] = [.anthropic, .openAI, .google, .custom]
        let keys = thirdParty.map { "SpineDesignerConsent.\($0.rawValue)" }
        let readersChoices = keys.map { UserDefaults.standard.object(forKey: $0) as? Bool }
        keys.forEach(tests.removeObject(forKey:))
        defer { keys.forEach(tests.removeObject(forKey:)) }

        XCTAssertTrue(SpineDesigner.hasConsent(of: .apple), "Apple's models never ask")
        for provider in thirdParty {
            XCTAssertFalse(SpineDesigner.hasConsent(of: provider), "\(provider) asks first")
        }
        SpineDesigner.allow(.google)
        XCTAssertTrue(SpineDesigner.hasConsent(of: .google))
        for provider in thirdParty where provider != .google {
            XCTAssertFalse(SpineDesigner.hasConsent(of: provider), "Each provider asks once")
        }
        XCTAssertEqual(
            keys.map { UserDefaults.standard.object(forKey: $0) as? Bool }, readersChoices,
            "Tests keep their own defaults")

        XCTAssertEqual(SpineDesignerSettings.saveChoice(for: .apple, closing: true), .store)
        XCTAssertEqual(
            SpineDesignerSettings.saveChoice(for: .google, closing: true), .store,
            "An allowed provider's entry saves without the alert")
        XCTAssertEqual(SpineDesignerSettings.saveChoice(for: .openAI, closing: false), .ask)
        XCTAssertEqual(
            SpineDesignerSettings.saveChoice(for: .openAI, closing: true), .drop,
            "A closing screen can't ask, so it saves nothing")

        XCTAssertEqual(
            SpineDesignerSettings.consentMessage(.anthropic),
            "Bookworms will send each book's cover, title, and author to Anthropic to design spines."
        )
        XCTAssertEqual(
            SpineDesignerSettings.consentMessage(.custom),
            "Bookworms will send each book's cover, title, and author to your endpoint to design spines."
        )
    }

    func testDesignsRecordTheirTierAsAModelToken() {
        let anthropic = SpineDesigner(
            provider: .anthropic, model: "claude-haiku-5-5", baseURL: "")
        func provenance(_ tier: ModelTier) -> String? {
            ModelStatus(
                tier: tier, isAvailable: true, unavailableReason: nil, coverReader: .designModel,
                designer: anthropic
            )
            .provenance
        }
        XCTAssertNil(provenance(.privateCloudCompute))
        XCTAssertEqual(provenance(.backup), "model:anthropic/claude-haiku-5-5")
        XCTAssertEqual(provenance(.onDevice), "model:apple/on-device")
        XCTAssertEqual(provenance(.local), "model:local")
        for tier in [ModelTier.privateCloudCompute, .backup, .onDevice, .local] {
            XCTAssertEqual(ModelTier(modelToken: provenance(tier)), tier)
        }
        XCTAssertLessThan(ModelTier.local, .onDevice)
        XCTAssertLessThan(ModelTier.onDevice, .backup)
        XCTAssertLessThan(ModelTier.backup, .privateCloudCompute)

        XCTAssertEqual(
            ModelStatus(
                tier: .backup, isAvailable: true, unavailableReason: nil, coverReader: .designModel,
                designer: anthropic
            )
            .designerName, "Anthropic with your API key")
        XCTAssertEqual(
            ModelTier.backup.name(
                backup: SpineDesigner(
                    provider: .custom, model: "local", baseURL: "http://localhost:1234/v1")),
            "OpenAI-compatible endpoint", "A custom endpoint may need no key")
        XCTAssertEqual(
            SpineWorker.fallbackMessage(
                rejection: "Anthropic: invalid x-api-key",
                next: ModelStatus(
                    tier: .onDevice, isAvailable: true, unavailableReason: nil,
                    coverReader: .onDevice)),
            "Anthropic: invalid x-api-key. Bookworms uses Apple's on-device model until you change your model settings or \(ThisDevice.press) Generate now."
        )
        XCTAssertEqual(
            SpineWorker.fallbackMessage(rejection: "Unknown model.", next: .local),
            "Unknown model. Bookworms uses default styling until you change your model settings or \(ThisDevice.press) Generate now."
        )
    }

    /// Every device names a design after the model token it records, never after its own model
    /// settings, so a device without the Gemini key still credits Gemini's designs.
    func testDesignsNameTheModelThatMadeThem() {
        let book = LocalRun.book(7)
        func design(_ provenance: String?, generator: String = CloudContract.generatorVersion)
            -> SpineDesignV1
        {
            LocalRun.design(
                for: book, coverHash: String(repeating: "c", count: 64), generator: generator,
                provenance: provenance)
        }
        let gemini = design("model:google/gemini-3.8-flash")
        XCTAssertEqual(gemini.madeBy, "Google Gemini (gemini-3.8-flash)")
        XCTAssertEqual(design("series-reuse:8 model:google/gemini-3.8-flash").madeBy, gemini.madeBy)
        XCTAssertEqual(
            gemini.recolored(
                SpineColors(
                    background: ColorValue(hex: "#202020")!,
                    foreground: ColorValue(hex: "#F4EEE2")!, accent: ColorValue(hex: "#7A1F1F")!)
            )
            .madeBy, gemini.madeBy, "Recoloring keeps the model")
        XCTAssertEqual(
            design("model:anthropic/claude-haiku-5-5").madeBy, "Anthropic (claude-haiku-5-5)")
        XCTAssertEqual(
            design("model:custom/qwen3-vl").madeBy, "OpenAI-compatible endpoint (qwen3-vl)")
        XCTAssertEqual(design(nil).madeBy, "Private Cloud Compute")
        XCTAssertEqual(design(ModelTier.onDeviceToken).madeBy, "Apple on-device model")
        XCTAssertEqual(
            design(nil, generator: "mac-foundation-models-v1").madeBy, "Apple on-device model")
        XCTAssertEqual(design("model:local font:system").madeBy, "Default styling")
        XCTAssertEqual(
            design(nil, generator: CloudContract.appleTVGeneratorVersion).madeBy,
            "Default styling")

        // Best tier first, then the most designs.
        let sources = GenerationView.designSources(
            [design(ModelTier.onDeviceToken), gemini, design("model:local"), design(nil)]
                + Array(repeating: design(ModelTier.onDeviceToken), count: 2)
                + [design("model:anthropic/claude-haiku-5-5"), gemini])
        XCTAssertEqual(
            sources.map(\.name),
            [
                "Private Cloud Compute", "Google Gemini (gemini-3.8-flash)",
                "Anthropic (claude-haiku-5-5)", "Apple on-device model", "Default styling",
            ])
        XCTAssertEqual(sources.map(\.count), [1, 2, 1, 3, 1])
    }

    /// **Redesign spine** designs the book anew at the run's tier, but never over a design from
    /// a better tier, such as Gemini's on a device without the key: the design stays, and the
    /// run says why.
    func testRedesignsNeverReplaceABetterModelsDesign() async throws {
        let book = LocalRun.book(7, cover: CoverStub.defaultCover)
        let coverHash = CloudContract.digest(CoverStub.images[CoverStub.defaultCover]!)
        let gemini = LocalRun.design(
            for: book, coverHash: coverHash, provenance: "model:google/gemini-3.8-flash")
        let better = try LocalRun(books: [book], designs: [gemini])
        defer { better.remove() }
        let (kept, keptSaves) = try await better.run(redesigning: (7, false))
        XCTAssertEqual(keptSaves, [])
        XCTAssertEqual(try better.stored()[7], gemini)
        XCTAssertEqual(kept.failed, 0)
        XCTAssertEqual(
            kept.error,
            "Google Gemini (gemini-3.8-flash) made this spine, so it stays. To redesign this spine here, open “Choose model” in the Spines tab and set up your own model."
        )

        let same = LocalRun.design(for: book, coverHash: coverHash, provenance: "model:local")
        let equal = try LocalRun(books: [book], designs: [same])
        defer { equal.remove() }
        let (redesigned, saved) = try await equal.run(redesigning: (7, false))
        XCTAssertNil(redesigned.error)
        XCTAssertEqual(redesigned.designed, 1)
        let made = try XCTUnwrap(saved.first)
        XCTAssertNotEqual(made.generatedAt, same.generatedAt)
        XCTAssertEqual(try equal.stored()[7], made)
    }

    /// **Redesign all spines** designs anew, with the chosen model, every design made before the
    /// request, even Private Cloud Compute's, which a run otherwise keeps. Designs made since,
    /// such as another device's redesign, and spines the reader customized stay.
    func testRedesignAllRedesignsUncustomizedDesignsMadeBeforeIt() async throws {
        let books = [7, 8, 9].map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
        let hash = String(repeating: "c", count: 64)
        let request = Date()
        let pcc = LocalRun.design(for: books[0], coverHash: hash)
        let since = LocalRun.design(
            for: books[1], coverHash: hash, generatedAt: request.addingTimeInterval(60))
        let customized = LocalRun.design(
            for: books[2], coverHash: hash, provenance: SpineDesignV1.readerFontToken)
        let run = try LocalRun(books: books, designs: [pcc, since, customized])
        defer { run.remove() }
        let worker = run.worker(
            status: .backupStub,
            designBook: { book, accountID, workItemHash, cover, model in
                LocalRun.design(
                    of: book, accountID: accountID, workItemHash: workItemHash, cover: cover,
                    model: model)
            })
        let checkedAll = await worker.reconcile(mode: .foreground, redesigningAllBefore: request)
        _ = await LocalRun.updates(of: worker)
        XCTAssertTrue(checkedAll, "The run checked the whole library")
        let stored = try run.stored()
        XCTAssertEqual(stored[7]?.tier, .backup, "The chosen model replaced the old design")
        XCTAssertEqual(stored[8], since, "A design made since the request stays")
        XCTAssertEqual(stored[9], customized, "A customized spine stays")
    }

    /// A library redesign only uses a provider's cloud model, never Apple's: at Private Cloud
    /// Compute, as when the provider has no key on this device, the run keeps the old designs,
    /// says what the redesign needs, and leaves the request for a later run.
    func testRedesignAllWaitsForTheChosenModel() async throws {
        let book = LocalRun.book(7, cover: CoverStub.numbered(7))
        let pcc = LocalRun.design(for: book, coverHash: String(repeating: "c", count: 64))
        let run = try LocalRun(books: [book], designs: [pcc])
        defer { run.remove() }
        let applesCloud = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let worker = run.worker(status: applesCloud)
        let checkedAll = await worker.reconcile(mode: .foreground, redesigningAllBefore: Date())
        let status = await LocalRun.updates(of: worker).statuses.last
        XCTAssertFalse(checkedAll, "The request waits for a later run")
        XCTAssertEqual(try run.stored()[7], pcc, "The old design stays")
        XCTAssertEqual(status?.error, "To redesign all spines, add an API key.")
    }

    /// In a look group, a library redesign designs anew only the look's source book, which remakes
    /// the look, and only while the reader left the look alone.
    func testRedesignAllRemakesOnlyAnUneditedLookThroughItsSource() throws {
        let book = LocalRun.book(7)
        let hash = String(repeating: "c", count: 64)
        let request = Date()
        let saved = LocalRun.design(for: book, coverHash: hash)
        XCTAssertEqual(
            SpineWorker.redesignsAll(saved, look: nil, bookID: 7, before: request), false)
        XCTAssertNil(
            SpineWorker.redesignsAll(
                saved, look: nil, bookID: 7, before: saved.generatedAt),
            "A design made at or after the request stays")
        let look = SeriesLookV1(
            design: saved, key: SeriesLookKey(seriesID: 501, group: "a"),
            createdAt: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(
            SpineWorker.redesignsAll(saved, look: look, bookID: 7, before: request), true)
        XCTAssertNil(
            SpineWorker.redesignsAll(saved, look: look, bookID: 8, before: request),
            "Another member copies the remade look")
        var edited = look
        edited.editedAt = request
        XCTAssertNil(SpineWorker.redesignsAll(saved, look: edited, bookID: 7, before: request))
    }

    /// A redesign that the backup model's lasting rejection moved to a weaker tier keeps the
    /// backup model's saved design or look, as a redesign from that tier would.
    func testRedesignsCheckTheTierAgainAfterAFallback() {
        let book = LocalRun.book(7)
        let coverHash = String(repeating: "c", count: 64)
        let gemini = LocalRun.design(
            for: book, coverHash: coverHash, provenance: "model:google/gemini-3.8-flash")
        let onDevice = LocalRun.design(
            for: book, coverHash: coverHash, provenance: ModelTier.onDeviceToken)
        func better(than tier: ModelTier, saved: SpineDesignV1?, look: SpineDesignV1? = nil)
            -> SpineDesignV1?
        {
            SpineWorker.betterDesign(
                than: tier, saved: saved, remadeLook: look, newCover: false, prefersBackup: false)
        }
        XCTAssertNil(better(than: .backup, saved: gemini), "The run's own tier gives way")
        XCTAssertEqual(better(than: .onDevice, saved: gemini), gemini)
        XCTAssertEqual(better(than: .local, saved: onDevice, look: gemini), onDevice)
        XCTAssertEqual(better(than: .onDevice, saved: onDevice, look: gemini), gemini)
        XCTAssertNil(better(than: .onDevice, saved: nil))
        XCTAssertNil(
            SpineWorker.betterDesign(
                than: .local, saved: gemini, remadeLook: gemini, newCover: true,
                prefersBackup: false),
            "A cover the reader chose since gives way at any tier")
    }

    /// The backup model's lasting rejection moves a run with a pinned backup status to the tier
    /// below it, as on a device: the rejected book and the books checked after it are designed
    /// there, and the Spines tab says why. The books already in flight finish at the backup
    /// tier.
    func testALastingBackupRejectionMovesARunToAnotherTier() async throws {
        SpineDesigner.forgetRejection()
        defer { SpineDesigner.forgetRejection() }
        // More books than the run designs at once, so some start after the rejection.
        let books = (1...(SpineWorker.backupConcurrency + 2))
            .map {
                LocalRun.book($0, cover: CoverStub.numbered($0))
            }
        let run = try LocalRun(books: books, designs: [])
        defer { run.remove() }
        let rejection = "Custom: Unknown model."
        let starts = TierStarts()
        let worker = run.worker(status: .backupStub, fallbackStatus: .local) {
            book, accountID, workItemHash, cover, model in
            await starts.start(model.tier)
            if model.tier == .backup {
                if book.id == 1 {
                    // Every book in flight starts at the backup tier before the rejection.
                    try await starts.wait(for: SpineWorker.backupConcurrency, at: .backup)
                    throw CompanionError.providerRejected(rejection)
                }
                // The other books in flight finish after the rejection moved the run.
                try await starts.wait(for: 1, at: .local)
            }
            return SpineDesignV1(
                version: 1, accountID: accountID, bookID: book.id, workItemHash: workItemHash,
                coverHash: cover.hash, generatorVersion: CloudContract.generatorVersion,
                generatedAt: Date(), backgroundHex: "#101010", foregroundHex: "#F4EEE2",
                accentHex: "#7A1F1F", typeface: "serif", weight: 700, uppercase: false,
                provenance: model.provenance)
        }
        await worker.reconcile(mode: .foreground)
        let (statuses, saved) = await LocalRun.updates(of: worker)

        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.phase, "Finished")
        XCTAssertEqual(status.completed, books.count)
        XCTAssertEqual(status.failed, 0)
        XCTAssertTrue(status.error?.hasPrefix(rejection) == true, status.error ?? "No message")
        for book in books {
            let design = try XCTUnwrap(saved.first { $0.bookID == book.id })
            XCTAssertEqual(
                design.tier,
                (2...SpineWorker.backupConcurrency).contains(book.id) ? .backup : .local,
                "Book \(book.id)")
            // The backup designs that finished after the move stand in for no tier.
            let standsIn = await run.ledger.standsIn(
                recordName: LocalRun.recordName(book.id), for: .local, design: design)
            XCTAssertFalse(standsIn, "Book \(book.id)")
        }
    }

    /// A backup model request that times out retries its book twice, after growing waits, and
    /// then Apple's model designs the book; without Apple's model, only that book fails. Either
    /// way the run goes on, and a later run with the backup model designs the book again.
    func testAnUnreachableBackupModelFailsOnlyItsBook() async throws {
        let books = (1...4).map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
        let onDevice = ModelStatus(
            tier: .onDevice, isAvailable: true, unavailableReason: nil, coverReader: .onDevice)
        for fallback in [onDevice, .local] {
            let run = try LocalRun(books: books, designs: [])
            defer { run.remove() }
            let attempts = Attempts()
            let worker = run.worker(
                status: .backupStub, fallbackStatus: fallback,
                designBook: { book, accountID, workItemHash, cover, model in
                    let attempt = await attempts.record(book.id, model.tier)
                    // Book 2's provider never answers; book 3's answers its second request.
                    if model.tier == .backup, book.id == 2 || book.id == 3 && attempt == 1 {
                        throw CompanionError.providerUnreachable
                    }
                    return SpineDesignV1(
                        version: 1, accountID: accountID, bookID: book.id,
                        workItemHash: workItemHash, coverHash: cover.hash,
                        generatorVersion: CloudContract.generatorVersion, generatedAt: Date(),
                        backgroundHex: "#101010", foregroundHex: "#F4EEE2", accentHex: "#7A1F1F",
                        typeface: "serif", weight: 700, uppercase: false,
                        provenance: model.provenance)
                }, sleep: { await attempts.wait($0) })
            await worker.reconcile(mode: .foreground)
            let (statuses, saved) = await LocalRun.updates(of: worker)

            let status = try XCTUnwrap(statuses.last)
            XCTAssertEqual(status.phase, "Finished", "\(fallback.tier)")
            let tries = await attempts.tiers
            XCTAssertEqual(tries[2]?.filter { $0 == .backup }.count, 3, "\(fallback.tier)")
            XCTAssertEqual(tries[3], [.backup, .backup])
            let waits = await attempts.waits
            XCTAssertEqual(waits.count, 3, "Book 2 waits twice, book 3 once")
            XCTAssertEqual(waits.filter { $0 >= .seconds(4) }.count, 1, "The second wait grows")
            for book in [1, 3, 4] {
                XCTAssertEqual(saved.first { $0.bookID == book }?.tier, .backup, "Book \(book)")
            }
            let due = await run.ledger.needsCheck(
                recordName: LocalRun.recordName(2), workItemHash: LocalRun.workHash(books[1]),
                runTier: .backup, now: Date().addingTimeInterval(WorkLedger.failureBackoff))
            XCTAssertTrue(due, "A later backup run designs book 2 again")
            if fallback.tier == .onDevice {
                XCTAssertEqual(tries[2]?.last, .onDevice)
                XCTAssertEqual(saved.first { $0.bookID == 2 }?.tier, .onDevice)
                XCTAssertEqual(status.completed, books.count)
                XCTAssertEqual(status.failed, 0)
                let dueNow = await run.ledger.needsCheck(
                    recordName: LocalRun.recordName(2),
                    workItemHash: LocalRun.workHash(books[1]), runTier: .backup)
                XCTAssertTrue(dueNow, "The on-device design gives way at once")
            } else {
                XCTAssertEqual(tries[2]?.count, 3, "Local defaults aren't a model to try")
                XCTAssertNil(saved.first { $0.bookID == 2 })
                XCTAssertEqual(status.completed, books.count - 1)
                XCTAssertEqual(status.failed, 1)
            }
        }
    }

    /// When two books in flight time out at the backup model, Apple's model designs them in its
    /// place one at a time, as Apple's tiers always design.
    func testAppleModelsDesignBooksTheBackupCantReachOneAtATime() async throws {
        let books = (1...4).map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
        let onDevice = ModelStatus(
            tier: .onDevice, isAvailable: true, unavailableReason: nil, coverReader: .onDevice)
        let run = try LocalRun(books: books, designs: [])
        defer { run.remove() }
        let overlap = Overlap()
        let worker = run.worker(
            status: .backupStub, fallbackStatus: onDevice,
            designBook: { book, accountID, workItemHash, cover, model in
                // Fewer books than pause the run (`SpineWorker.unreachableBookLimit`).
                if model.tier == .backup, book.id <= 2 { throw CompanionError.providerUnreachable }
                if model.tier == .onDevice {
                    await overlap.begin()
                    try await Task.sleep(for: .milliseconds(50))
                    await overlap.end()
                }
                return LocalRun.design(
                    of: book, accountID: accountID, workItemHash: workItemHash, cover: cover,
                    model: model)
            }, sleep: { _ in })
        await worker.reconcile(mode: .foreground)
        let (statuses, saved) = await LocalRun.updates(of: worker)

        let status = try XCTUnwrap(statuses.last)
        XCTAssertEqual(status.completed, books.count)
        XCTAssertEqual(Set(saved.map(\.bookID)), [1, 2, 3, 4])
        for design in saved {
            XCTAssertEqual(
                design.tier, design.bookID <= 2 ? .onDevice : .backup, "Book \(design.bookID)")
        }
        let most = await overlap.most
        XCTAssertEqual(most, 1, "Apple's model designed several books at once")
    }

    /// The third book in a row that can't reach the backup model pauses the run for 15 minutes,
    /// as a rate limit does, even though Apple's model designed the first two, and the paused
    /// book stays queued. A book that the backup designs between them starts the count again.
    func testSeveralBooksInARowThatCantReachTheBackupPauseTheRun() async throws {
        XCTAssertEqual(SpineWorker.unreachableBookLimit, 3)
        let books = (1...5).map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
        let onDevice = ModelStatus(
            tier: .onDevice, isAvailable: true, unavailableReason: nil, coverReader: .onDevice)
        for thirdAnswers in [true, false] {
            let run = try LocalRun(books: books, designs: [])
            defer { run.remove() }
            let start = Date()
            let worker = run.worker(
                status: .backupStub, fallbackStatus: onDevice,
                designBook: { book, accountID, workItemHash, cover, model in
                    // Books 1 and 2 fail first, book 3's answer comes next, and books 4 and 5
                    // fail after it.
                    if model.tier == .backup, book.id != 3 || !thirdAnswers {
                        try await Task.sleep(
                            for: .milliseconds([3: 300, 4: 600, 5: 600][book.id] ?? 0))
                        throw CompanionError.providerUnreachable
                    }
                    if model.tier == .backup { try await Task.sleep(for: .milliseconds(300)) }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            let (statuses, saved) = await LocalRun.updates(of: worker)

            let status = try XCTUnwrap(statuses.last)
            if thirdAnswers {
                XCTAssertEqual(status.phase, "Finished")
                XCTAssertEqual(status.completed, books.count)
                XCTAssertEqual(status.failed, 0)
                for design in saved {
                    XCTAssertEqual(
                        design.tier, design.bookID == 3 ? .backup : .onDevice,
                        "Book \(design.bookID)")
                }
                XCTAssertEqual(Set(saved.map(\.bookID)), [1, 2, 3, 4, 5])
            } else {
                XCTAssertEqual(status.phase, "Paused")
                XCTAssertEqual(status.error, CompanionError.modelBusy(nil).errorDescription)
                let retry = try XCTUnwrap(status.retryAfter)
                XCTAssertGreaterThanOrEqual(
                    retry, start.addingTimeInterval(SpineWorker.busyRetryDelay))
                XCTAssertLessThanOrEqual(
                    retry, Date().addingTimeInterval(SpineWorker.busyRetryDelay))
                XCTAssertTrue(Set(saved.map(\.bookID)).isSubset(of: [1, 2]))
                XCTAssertTrue(saved.allSatisfy { $0.tier == .onDevice })
                for book in books[2...] {
                    let due = await run.ledger.needsCheck(
                        recordName: LocalRun.recordName(book.id),
                        workItemHash: LocalRun.workHash(book))
                    XCTAssertTrue(due, "Book \(book.id) was recorded")
                }
            }
        }
    }

    /// A Private Cloud Compute design made in place of a backup model that couldn't answer
    /// stands in for it: the next run with the backup designs the book again and replaces that
    /// design. A Private Cloud Compute design that the run kept, as one from a run at Private
    /// Cloud Compute, stays, and a run at Private Cloud Compute keeps the stand-in.
    func testABackupRunRedesignsPrivateCloudComputeStandIns() async throws {
        let books = (1...3).map { LocalRun.book($0, cover: CoverStub.numbered($0)) }
        let chosen = LocalRun.design(
            for: books[2], coverHash: String(repeating: "c", count: 64), provenance: nil)
        let run = try LocalRun(books: books, designs: [chosen])
        defer { run.remove() }
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        func backupRun(reaches: Bool) async -> (designed: [Int: [ModelTier]], saved: [Int]) {
            let attempts = Attempts()
            let worker = run.worker(
                status: .backupStub, fallbackStatus: pcc,
                designBook: { book, accountID, workItemHash, cover, model in
                    _ = await attempts.record(book.id, model.tier)
                    if model.tier == .backup, !reaches, book.id == 1 {
                        throw CompanionError.providerUnreachable
                    }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            let (_, saved) = await LocalRun.updates(of: worker)
            return (await attempts.tiers, saved.map(\.bookID))
        }

        let first = await backupRun(reaches: false)
        XCTAssertEqual(first.designed[1]?.last, .privateCloudCompute)
        XCTAssertNil(first.designed[3], "The kept design sent no request")
        var stored = try run.stored()
        XCTAssertEqual(stored[1]?.tier, .privateCloudCompute)
        XCTAssertEqual(stored[2]?.tier, .backup)
        XCTAssertEqual(stored[3], chosen)
        let marked = await run.ledger.standsIn(
            recordName: LocalRun.recordName(1), for: .backup, design: try XCTUnwrap(stored[1]))
        XCTAssertTrue(marked)
        func due(_ book: CloudBook, at tier: ModelTier) async -> Bool {
            await run.ledger.needsCheck(
                recordName: LocalRun.recordName(book.id), workItemHash: LocalRun.workHash(book),
                runTier: tier)
        }
        let standInDue = await due(books[0], at: .backup)
        XCTAssertTrue(standInDue, "The backup's next run designs the stand-in again")
        let standInDueAtPCC = await due(books[0], at: .privateCloudCompute)
        XCTAssertFalse(standInDueAtPCC, "A run at Private Cloud Compute keeps it")
        let keptDue = await due(books[2], at: .backup)
        XCTAssertFalse(keptDue, "A Private Cloud Compute design the run kept is no stand-in")

        let second = await backupRun(reaches: true)
        XCTAssertEqual(second.designed[1], [.backup])
        XCTAssertNil(second.designed[2])
        XCTAssertNil(second.designed[3])
        stored = try run.stored()
        XCTAssertEqual(stored[1]?.tier, .backup)
        XCTAssertEqual(stored[3], chosen)
        let redoneDue = await due(books[0], at: .backup)
        XCTAssertFalse(redoneDue)
    }

    /// While the backup still can't answer, its redo of a stand-in from Private Cloud Compute or
    /// the on-device model keeps the stand-in, still marked, instead of making another one, and
    /// the book waits a day.
    func testAStandInStaysWhileTheBackupStillCantAnswer() async throws {
        let book = LocalRun.book(1, cover: CoverStub.numbered(1))
        for fallback in [ModelTier.privateCloudCompute, .onDevice] {
            let run = try LocalRun(books: [book], designs: [])
            defer { run.remove() }
            let apple = ModelStatus(
                tier: fallback, isAvailable: true, unavailableReason: nil,
                coverReader: .designModel)
            func unreachableRun() async -> [ModelTier] {
                let attempts = Attempts()
                let worker = run.worker(
                    status: .backupStub, fallbackStatus: apple,
                    designBook: { book, accountID, workItemHash, cover, model in
                        _ = await attempts.record(book.id, model.tier)
                        if model.tier == .backup { throw CompanionError.providerUnreachable }
                        return LocalRun.design(
                            of: book, accountID: accountID, workItemHash: workItemHash,
                            cover: cover, model: model)
                    }, sleep: { _ in })
                await worker.reconcile(mode: .foreground)
                _ = await LocalRun.updates(of: worker)
                return await attempts.tiers[1] ?? []
            }

            let first = await unreachableRun()
            XCTAssertEqual(first.last, fallback)
            let standIn = try XCTUnwrap(try run.stored()[1])
            let second = await unreachableRun()
            XCTAssertEqual(
                second, [.backup, .backup, .backup],
                "\(fallback): the redo made no second stand-in")
            XCTAssertEqual(try run.stored()[1], standIn, "\(fallback)")
            let marked = await run.ledger.standsIn(
                recordName: LocalRun.recordName(1), for: .backup, design: standIn)
            XCTAssertTrue(marked, "\(fallback): the kept stand-in still gives way to the backup")
            let waits = await run.ledger.needsCheck(
                recordName: LocalRun.recordName(1), workItemHash: LocalRun.workHash(book),
                runTier: .backup)
            XCTAssertFalse(waits, "\(fallback): the book waits a day")
            let due = await run.ledger.needsCheck(
                recordName: LocalRun.recordName(1), workItemHash: LocalRun.workHash(book),
                runTier: .backup, now: Date().addingTimeInterval(WorkLedger.failureBackoff))
            XCTAssertTrue(due, "\(fallback): a backup run a day later tries the book again")
        }
    }

    /// A check at Private Cloud Compute, as while the reader turned the backup off, keeps a
    /// stand-in marked, so the backup's next run still designs the book again.
    func testACheckThatKeepsAStandInKeepsItMarked() async throws {
        let book = LocalRun.book(1, cover: CoverStub.numbered(1))
        let run = try LocalRun(books: [book], designs: [])
        defer { run.remove() }
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        func backupRun(reaches: Bool) async -> [ModelTier] {
            let attempts = Attempts()
            let worker = run.worker(
                status: .backupStub, fallbackStatus: pcc,
                designBook: { book, accountID, workItemHash, cover, model in
                    _ = await attempts.record(book.id, model.tier)
                    if model.tier == .backup, !reaches { throw CompanionError.providerUnreachable }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            _ = await LocalRun.updates(of: worker)
            return await attempts.tiers[1] ?? []
        }

        _ = await backupRun(reaches: false)
        let standIn = try XCTUnwrap(try run.stored()[1])
        // The stand-in's weekly recheck comes due.
        try await run.ledger.recordSuccess(
            recordName: LocalRun.recordName(1), workItemHash: LocalRun.workHash(book),
            tier: .privateCloudCompute, standIn: (standIn, .backup),
            now: Date().addingTimeInterval(-WorkLedger.recheckInterval))
        let check = run.worker(
            status: pcc,
            designBook: { _, _, _, _, _ in
                XCTFail("The check sent a request")
                throw CompanionError.invalidDesign
            })
        await check.reconcile(mode: .foreground)
        _ = await LocalRun.updates(of: check)
        XCTAssertEqual(try run.stored()[1], standIn)
        let marked = await run.ledger.standsIn(
            recordName: LocalRun.recordName(1), for: .backup, design: standIn)
        XCTAssertTrue(marked, "The kept stand-in still gives way to the backup")

        let redo = await backupRun(reaches: true)
        XCTAssertEqual(redo, [.backup])
        XCTAssertEqual(try run.stored()[1]?.tier, .backup)
    }

    /// A look that the app's catch-up made from a stand-in (`SeriesDesigns.missingLooks`) gives
    /// way with it: the backup's redo designs the book instead of copying the look, and
    /// upgrades the look.
    func testAStandInsRedoUpgradesTheLookMadeFromIt() async throws {
        let book = LocalRun.book(7, cover: CoverStub.numbered(7), series: 501, position: 1)
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: book, link: nil))
        let run = try LocalRun(books: [book], designs: [])
        defer { run.remove() }
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let local = LocalSpineStore(folder: run.folder)
        func backupRun(reaches: Bool) async -> [ModelTier] {
            let attempts = Attempts()
            let worker = run.worker(
                status: .backupStub, fallbackStatus: pcc,
                designBook: { book, accountID, workItemHash, cover, model in
                    _ = await attempts.record(book.id, model.tier)
                    if model.tier == .backup, !reaches { throw CompanionError.providerUnreachable }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            _ = await LocalRun.updates(of: worker)
            return await attempts.tiers[7] ?? []
        }

        _ = await backupRun(reaches: false)
        let standIn = try XCTUnwrap(try run.stored()[7])
        var looks = try await local.seriesLooks(accountID: LocalRun.accountID, keys: [key])
        XCTAssertNil(looks[key], "The stand-in decided no look")
        let caughtUp = SeriesDesigns.missingLooks(
            books: [book], designs: [7: standIn], looks: [:], now: Date())
        XCTAssertEqual(caughtUp.count, 1)
        for look in caughtUp { _ = try await local.createLook(look) }

        let redo = await backupRun(reaches: true)
        XCTAssertEqual(redo, [.backup])
        XCTAssertEqual(try run.stored()[7]?.tier, .backup)
        looks = try await local.seriesLooks(accountID: LocalRun.accountID, keys: [key])
        XCTAssertEqual(looks[key]?.tier, .backup)
        XCTAssertNil(looks[key]?.editedAt, "A later upgrade may still replace the look")
    }

    /// A look the reader recolors while the backup redoes the stand-in it was made from, after
    /// the redo read the look, stays: the redo's upgrade saves only over the look it read.
    func testAStandInsRedoKeepsALookEditedDuringIt() async throws {
        let book = LocalRun.book(7, cover: CoverStub.numbered(7), series: 501, position: 1)
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: book, link: nil))
        let run = try LocalRun(books: [book], designs: [])
        defer { run.remove() }
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let local = LocalSpineStore(folder: run.folder)
        let colors = SpineColors(
            background: ColorValue(hex: "#1A2B3C")!, foreground: ColorValue(hex: "#F4E9D0")!,
            accent: ColorValue(hex: "#C08040")!)
        func backupRun(
            reaches: Bool, during: (@Sendable () async throws -> Void)? = nil
        ) async -> [ModelTier] {
            let attempts = Attempts()
            let worker = run.worker(
                status: .backupStub, fallbackStatus: pcc,
                designBook: { book, accountID, workItemHash, cover, model in
                    _ = await attempts.record(book.id, model.tier)
                    if model.tier == .backup, !reaches { throw CompanionError.providerUnreachable }
                    try await during?()
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            _ = await LocalRun.updates(of: worker)
            return await attempts.tiers[7] ?? []
        }

        _ = await backupRun(reaches: false)
        let standIn = try XCTUnwrap(try run.stored()[7])
        let caughtUp = try XCTUnwrap(
            SeriesDesigns.missingLooks(
                books: [book], designs: [7: standIn], looks: [:], now: Date()
            )
            .first)
        let look = try await local.createLook(caughtUp)
        let recolored = look.recolored(colors, at: Date())

        let redo = await backupRun(reaches: true) {
            try await local.saveEdited(recolored, replacing: look)
        }
        XCTAssertEqual(redo, [.backup], "The redo read the look before the edit")
        let kept = try await local.seriesLooks(accountID: LocalRun.accountID, keys: [key])
        XCTAssertEqual(kept[key], recolored, "The reader's colors stay")
    }

    /// A look that doesn't match an unedited copy of a stand-in, such as one the reader edited,
    /// one the reader remade, even from the stand-in, or one another device made from another
    /// design, stays when the backup redoes the stand-in, and the book copies it without a
    /// request.
    func testAStandInsRedoCopiesALookNotMadeFromIt() async throws {
        let book = LocalRun.book(7, cover: CoverStub.numbered(7), series: 501, position: 1)
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: book, link: nil))
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let colors = SpineColors(
            background: ColorValue(hex: "#1A2B3C")!, foreground: ColorValue(hex: "#F4E9D0")!,
            accent: ColorValue(hex: "#C08040")!)
        let variants: [(String, (SeriesLookV1) -> SeriesLookV1)] = [
            ("edited", { $0.recolored(colors, at: Date()) }),
            (
                "remade",
                { look in look.remade(from: look.design(bookID: look.sourceBookID), at: Date()) }
            ),
            (
                "another design",
                { look in
                    var other = look
                    other.backgroundHex = "#203040"
                    return other
                }
            ),
        ]
        for (name, variant) in variants {
            let run = try LocalRun(books: [book], designs: [])
            defer { run.remove() }
            let local = LocalSpineStore(folder: run.folder)
            func backupRun(reaches: Bool) async -> [ModelTier] {
                let attempts = Attempts()
                let worker = run.worker(
                    status: .backupStub, fallbackStatus: pcc,
                    designBook: { book, accountID, workItemHash, cover, model in
                        _ = await attempts.record(book.id, model.tier)
                        if model.tier == .backup, !reaches {
                            throw CompanionError.providerUnreachable
                        }
                        return LocalRun.design(
                            of: book, accountID: accountID, workItemHash: workItemHash,
                            cover: cover, model: model)
                    }, sleep: { _ in })
                await worker.reconcile(mode: .foreground)
                _ = await LocalRun.updates(of: worker)
                return await attempts.tiers[7] ?? []
            }

            _ = await backupRun(reaches: false)
            let standIn = try XCTUnwrap(try run.stored()[7])
            let caughtUp = try XCTUnwrap(
                SeriesDesigns.missingLooks(
                    books: [book], designs: [7: standIn], looks: [:], now: Date()
                )
                .first)
            let look = try await local.createLook(variant(caughtUp))

            let redo = await backupRun(reaches: true)
            XCTAssertEqual(redo, [], "\(name): the book copied the look")
            let copy = try XCTUnwrap(try run.stored()[7], name)
            XCTAssertEqual(copy.backgroundHex, look.backgroundHex, name)
            let kept = try await local.seriesLooks(accountID: LocalRun.accountID, keys: [key])
            XCTAssertEqual(kept[key], look, "\(name): the look stays")
        }
    }

    /// When the backup's lasting rejection moves its redo of a stand-in to a lower tier, such as
    /// the on-device model below a Private Cloud Compute stand-in, the stand-in and the look the
    /// catch-up made from it stay.
    func testAStandInsLookStaysWhenAFallbackRedesignsItsBook() async throws {
        SpineDesigner.forgetRejection()
        defer { SpineDesigner.forgetRejection() }
        let book = LocalRun.book(7, cover: CoverStub.numbered(7), series: 501, position: 1)
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: book, link: nil))
        let run = try LocalRun(books: [book], designs: [])
        defer { run.remove() }
        let local = LocalSpineStore(folder: run.folder)
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let onDevice = ModelStatus(
            tier: .onDevice, isAvailable: true, unavailableReason: nil, coverReader: .onDevice)
        func backupRun(fallback: ModelStatus, error: CompanionError) async {
            let worker = run.worker(
                status: .backupStub, fallbackStatus: fallback,
                designBook: { book, accountID, workItemHash, cover, model in
                    if model.tier == .backup { throw error }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            _ = await LocalRun.updates(of: worker)
        }

        await backupRun(fallback: pcc, error: .providerUnreachable)
        let standIn = try XCTUnwrap(try run.stored()[7])
        XCTAssertEqual(standIn.tier, .privateCloudCompute)
        for look in SeriesDesigns.missingLooks(
            books: [book], designs: [7: standIn], looks: [:], now: Date())
        {
            _ = try await local.createLook(look)
        }
        let caughtUp = try await local.seriesLooks(accountID: LocalRun.accountID, keys: [key])

        await backupRun(fallback: onDevice, error: .providerRejected("Custom: Unknown model."))
        XCTAssertEqual(try run.stored()[7], standIn, "The stand-in stays")
        let looks = try await local.seriesLooks(accountID: LocalRun.accountID, keys: [key])
        XCTAssertEqual(looks[key], caughtUp[key], "The look stays at Private Cloud Compute")
    }

    /// When the backup's lasting rejection moves its redo of a Private Cloud Compute stand-in to
    /// the on-device model, the on-device design doesn't replace the stand-in, which stays
    /// marked, so a later backup run designs the book again. A reader's **Redesign spine** still
    /// replaces it.
    func testAStandInStaysWhenAFallbackBelowItRedoesIt() async throws {
        SpineDesigner.forgetRejection()
        defer { SpineDesigner.forgetRejection() }
        let book = LocalRun.book(1, cover: CoverStub.numbered(1))
        let run = try LocalRun(books: [book], designs: [])
        defer { run.remove() }
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let onDevice = ModelStatus(
            tier: .onDevice, isAvailable: true, unavailableReason: nil, coverReader: .onDevice)
        func backupRun(
            fallback: ModelStatus, error: CompanionError,
            redesigning: (bookID: Int, remakesLook: Bool)? = nil
        ) async -> [ModelTier] {
            let attempts = Attempts()
            let worker = run.worker(
                status: .backupStub, fallbackStatus: fallback,
                designBook: { book, accountID, workItemHash, cover, model in
                    _ = await attempts.record(book.id, model.tier)
                    if model.tier == .backup { throw error }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground, redesigning: redesigning)
            _ = await LocalRun.updates(of: worker)
            return await attempts.tiers[1] ?? []
        }

        _ = await backupRun(fallback: pcc, error: .providerUnreachable)
        let standIn = try XCTUnwrap(try run.stored()[1])
        XCTAssertEqual(standIn.tier, .privateCloudCompute)

        let redo = await backupRun(
            fallback: onDevice, error: .providerRejected("Custom: Unknown model."))
        XCTAssertEqual(redo, [.backup, .onDevice], "The fallback designed the book")
        XCTAssertEqual(try run.stored()[1], standIn, "The stand-in stays")
        let marked = await run.ledger.standsIn(
            recordName: LocalRun.recordName(1), for: .backup, design: standIn)
        XCTAssertTrue(marked, "The kept stand-in still gives way to the backup")

        let redesign = await backupRun(
            fallback: onDevice, error: .providerRejected("Custom: Unknown model."),
            redesigning: (1, false))
        XCTAssertEqual(redesign, [.backup, .onDevice], "Redesign spine tries the backup again")
        XCTAssertEqual(
            try run.stored()[1]?.tier, .onDevice, "Redesign spine replaces the stand-in")
    }

    /// A check at Private Cloud Compute that keeps a stand-in upgrades its group's on-device look
    /// from it when the stand-in's book is the look's upgrade source, so the group doesn't keep
    /// the on-device look while the backup stays off. The backup's redo then designs the book and
    /// upgrades the look again, instead of copying the look made from the stand-in.
    func testAKeptStandInUpgradesItsLook() async throws {
        let book = LocalRun.book(7, cover: CoverStub.numbered(7), series: 501, position: 1)
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: book, link: nil))
        let onDeviceDesign = LocalRun.design(
            for: book, coverHash: String(repeating: "a", count: 64),
            provenance: ModelTier.onDeviceToken)
        let run = try LocalRun(books: [book], designs: [onDeviceDesign])
        defer { run.remove() }
        let local = LocalSpineStore(folder: run.folder)
        let look = try await local.createLook(
            SeriesLookV1(design: onDeviceDesign, key: key, createdAt: Date()))
        XCTAssertEqual(look.tier, .onDevice)
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        func backupRun(reaches: Bool) async -> [ModelTier] {
            let attempts = Attempts()
            let worker = run.worker(
                status: .backupStub, fallbackStatus: pcc,
                designBook: { book, accountID, workItemHash, cover, model in
                    _ = await attempts.record(book.id, model.tier)
                    if model.tier == .backup, !reaches { throw CompanionError.providerUnreachable }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            _ = await LocalRun.updates(of: worker)
            return await attempts.tiers[7] ?? []
        }
        func savedLook() async throws -> SeriesLookV1? {
            try await local.seriesLooks(accountID: LocalRun.accountID, keys: [key])[key]
        }

        _ = await backupRun(reaches: false)
        let standIn = try XCTUnwrap(try run.stored()[7])
        XCTAssertEqual(standIn.tier, .privateCloudCompute)
        var current = try await savedLook()
        XCTAssertEqual(current, look, "The stand-in decided no look")
        // The stand-in's weekly recheck comes due.
        try await run.ledger.recordSuccess(
            recordName: LocalRun.recordName(7), workItemHash: LocalRun.workHash(book),
            tier: .privateCloudCompute, standIn: (standIn, .backup),
            now: Date().addingTimeInterval(-WorkLedger.recheckInterval))
        let check = run.worker(
            status: pcc,
            designBook: { _, _, _, _, _ in
                XCTFail("The check sent a request")
                throw CompanionError.invalidDesign
            })
        await check.reconcile(mode: .foreground)
        _ = await LocalRun.updates(of: check)
        XCTAssertEqual(try run.stored()[7], standIn)
        current = try await savedLook()
        XCTAssertEqual(current?.tier, .privateCloudCompute, "The kept stand-in upgraded the look")
        let marked = await run.ledger.standsIn(
            recordName: LocalRun.recordName(7), for: .backup, design: standIn)
        XCTAssertTrue(marked, "The kept stand-in still gives way to the backup")

        let redo = await backupRun(reaches: true)
        XCTAssertEqual(redo, [.backup], "The redo designed the book")
        XCTAssertEqual(try run.stored()[7]?.tier, .backup)
        current = try await savedLook()
        XCTAssertEqual(current?.tier, .backup, "The redo upgraded the look")
    }

    /// When the backup's lasting rejection moves its redo of a Private Cloud Compute stand-in to
    /// the on-device model, the kept stand-in upgrades its group's on-device look when its book
    /// is the look's upgrade source.
    func testAStandInKeptOverALowerRedoUpgradesItsLook() async throws {
        SpineDesigner.forgetRejection()
        defer { SpineDesigner.forgetRejection() }
        let book = LocalRun.book(7, cover: CoverStub.numbered(7), series: 501, position: 1)
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: book, link: nil))
        let onDeviceDesign = LocalRun.design(
            for: book, coverHash: String(repeating: "a", count: 64),
            provenance: ModelTier.onDeviceToken)
        let run = try LocalRun(books: [book], designs: [onDeviceDesign])
        defer { run.remove() }
        let local = LocalSpineStore(folder: run.folder)
        let look = try await local.createLook(
            SeriesLookV1(design: onDeviceDesign, key: key, createdAt: Date()))
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let onDevice = ModelStatus(
            tier: .onDevice, isAvailable: true, unavailableReason: nil, coverReader: .onDevice)
        func backupRun(fallback: ModelStatus, error: CompanionError) async {
            let worker = run.worker(
                status: .backupStub, fallbackStatus: fallback,
                designBook: { book, accountID, workItemHash, cover, model in
                    if model.tier == .backup { throw error }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            _ = await LocalRun.updates(of: worker)
        }
        func savedLook() async throws -> SeriesLookV1? {
            try await local.seriesLooks(accountID: LocalRun.accountID, keys: [key])[key]
        }

        await backupRun(fallback: pcc, error: .providerUnreachable)
        let standIn = try XCTUnwrap(try run.stored()[7])
        XCTAssertEqual(standIn.tier, .privateCloudCompute)
        var current = try await savedLook()
        XCTAssertEqual(current, look, "The stand-in decided no look")

        await backupRun(fallback: onDevice, error: .providerRejected("Custom: Unknown model."))
        XCTAssertEqual(try run.stored()[7], standIn, "The stand-in stays")
        current = try await savedLook()
        XCTAssertEqual(current?.tier, .privateCloudCompute, "The kept stand-in upgraded the look")
    }

    /// While the backup still can't answer, its redo of the on-device model's stand-in gets a
    /// new stand-in from Private Cloud Compute once that is available, still marked.
    func testAnOnDeviceStandInUpgradesWhileTheBackupCantAnswer() async throws {
        let book = LocalRun.book(1, cover: CoverStub.numbered(1))
        let run = try LocalRun(books: [book], designs: [])
        defer { run.remove() }
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let onDevice = ModelStatus(
            tier: .onDevice, isAvailable: true, unavailableReason: nil, coverReader: .onDevice)
        func unreachableRun(fallback: ModelStatus) async -> [ModelTier] {
            let attempts = Attempts()
            let worker = run.worker(
                status: .backupStub, fallbackStatus: fallback,
                designBook: { book, accountID, workItemHash, cover, model in
                    _ = await attempts.record(book.id, model.tier)
                    if model.tier == .backup { throw CompanionError.providerUnreachable }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            _ = await LocalRun.updates(of: worker)
            return await attempts.tiers[1] ?? []
        }

        _ = await unreachableRun(fallback: onDevice)
        XCTAssertEqual(try run.stored()[1]?.tier, .onDevice)
        let upgrade = await unreachableRun(fallback: pcc)
        XCTAssertEqual(upgrade.last, .privateCloudCompute)
        let upgraded = try XCTUnwrap(try run.stored()[1])
        XCTAssertEqual(upgraded.tier, .privateCloudCompute)
        let marked = await run.ledger.standsIn(
            recordName: LocalRun.recordName(1), for: .backup, design: upgraded)
        XCTAssertTrue(marked, "The new stand-in still gives way to the backup")
    }

    /// A stand-in whose colors the reader changed stays, and its next check drops the stand-in
    /// marker, so the backup stops checking it on every run.
    func testAStandInTheReaderEditedLosesItsMarker() async throws {
        let book = LocalRun.book(1, cover: CoverStub.numbered(1))
        let run = try LocalRun(books: [book], designs: [])
        defer { run.remove() }
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let colors = SpineColors(
            background: ColorValue(hex: "#1A2B3C")!, foreground: ColorValue(hex: "#F4E9D0")!,
            accent: ColorValue(hex: "#C08040")!)
        let first = run.worker(
            status: .backupStub, fallbackStatus: pcc,
            designBook: { book, accountID, workItemHash, cover, model in
                if model.tier == .backup { throw CompanionError.providerUnreachable }
                return LocalRun.design(
                    of: book, accountID: accountID, workItemHash: workItemHash, cover: cover,
                    model: model)
            }, sleep: { _ in })
        await first.reconcile(mode: .foreground)
        _ = await LocalRun.updates(of: first)
        let standIn = try XCTUnwrap(try run.stored()[1])
        try await LocalSpineStore(folder: run.folder).saveRecolored(standIn.recolored(colors))
        func due() async -> Bool {
            await run.ledger.needsCheck(
                recordName: LocalRun.recordName(1), workItemHash: LocalRun.workHash(book),
                runTier: .backup)
        }
        var isDue = await due()
        XCTAssertTrue(isDue)

        let check = run.worker(
            status: .backupStub,
            designBook: { _, _, _, _, _ in
                XCTFail("The check sent a request")
                throw CompanionError.invalidDesign
            })
        await check.reconcile(mode: .foreground)
        _ = await LocalRun.updates(of: check)
        let kept = try XCTUnwrap(try run.stored()[1])
        XCTAssertEqual(kept.colors, colors)
        let marked = await run.ledger.standsIn(
            recordName: LocalRun.recordName(1), for: .backup, design: kept)
        XCTAssertFalse(marked)
        isDue = await due()
        XCTAssertFalse(isDue, "The backup's next run skips the edited stand-in")
    }

    /// When Apple's model, designing in the backup's place, hits a problem that stops a run at
    /// its own tier, such as a Google Fonts outage, the run stops and the book stays queued. A
    /// design that Apple's model can't make fails only its book.
    func testAStandInsRunStoppingErrorStopsTheRun() async throws {
        let book = LocalRun.book(1, cover: CoverStub.numbered(1))
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let cases: [(CompanionError, stops: Bool)] = [
            (.fontServiceUnavailable(nil), true), (.quotaReached(nil), true),
            (.invalidDesign, false), (.modelUnavailable, false),
        ]
        for (error, stops) in cases {
            let run = try LocalRun(books: [book], designs: [])
            defer { run.remove() }
            let worker = run.worker(
                status: .backupStub, fallbackStatus: pcc,
                designBook: { _, _, _, _, model in
                    throw model.tier == .backup ? CompanionError.providerUnreachable : error
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            let (statuses, saved) = await LocalRun.updates(of: worker)

            let status = try XCTUnwrap(statuses.last)
            XCTAssertTrue(saved.isEmpty, "\(error)")
            let due = await run.ledger.needsCheck(
                recordName: LocalRun.recordName(1), workItemHash: LocalRun.workHash(book),
                runTier: .backup)
            if stops {
                XCTAssertEqual(status.phase, "Paused", "\(error)")
                XCTAssertEqual(status.failed, 0, "\(error)")
                XCTAssertTrue(due, "\(error): the book stays queued")
            } else {
                XCTAssertEqual(status.phase, "Finished", "\(error)")
                XCTAssertEqual(status.failed, 1, "\(error)")
                XCTAssertFalse(due, "\(error): the book waits a day")
            }
        }
    }

    /// The backup's redo of a Private Cloud Compute stand-in replaces only the design it read,
    /// so colors the reader chose during the backup's request stay.
    func testAStandInsRedoKeepsColorsTheReaderChoseDuringIt() async throws {
        let book = LocalRun.book(1, cover: CoverStub.numbered(1))
        let run = try LocalRun(books: [book], designs: [])
        defer { run.remove() }
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let local = LocalSpineStore(folder: run.folder)
        let colors = SpineColors(
            background: ColorValue(hex: "#1A2B3C")!, foreground: ColorValue(hex: "#F4E9D0")!,
            accent: ColorValue(hex: "#C08040")!)
        func backupRun(reaches: Bool) async {
            let worker = run.worker(
                status: .backupStub, fallbackStatus: pcc,
                designBook: { book, accountID, workItemHash, cover, model in
                    if model.tier == .backup, !reaches { throw CompanionError.providerUnreachable }
                    if model.tier == .backup,
                        let read = try await local.savedDesign(accountID: accountID, bookID: 1)
                    {
                        try await local.saveRecolored(read.recolored(colors))
                    }
                    return LocalRun.design(
                        of: book, accountID: accountID, workItemHash: workItemHash,
                        cover: cover, model: model)
                }, sleep: { _ in })
            await worker.reconcile(mode: .foreground)
            _ = await LocalRun.updates(of: worker)
        }

        await backupRun(reaches: false)
        XCTAssertEqual(try run.stored()[1]?.tier, .privateCloudCompute)
        await backupRun(reaches: true)
        let kept = try XCTUnwrap(try run.stored()[1])
        XCTAssertEqual(kept.tier, .privateCloudCompute)
        XCTAssertEqual(kept.colors, colors)
        XCTAssertTrue(kept.hasReaderEdits)
    }

    /// A whole-series redesign that Apple's model answers in the backup model's place remakes
    /// the series look, as the reader asked, and stays.
    func testAStandInRemakesTheLookTheReaderAskedFor() async throws {
        let books = (7...8)
            .map {
                LocalRun.book($0, cover: CoverStub.numbered($0), series: 501, position: Double($0))
            }
        let source = LocalRun.design(
            for: books[0], coverHash: String(repeating: "d", count: 64),
            provenance: "model:google/gemini-3.8-flash")
        let key = try XCTUnwrap(SeriesDesigns.lookKey(of: books[0], link: nil))
        let look = SeriesLookV1(
            design: source, key: key, createdAt: Date(timeIntervalSince1970: 1_000_000))
        let run = try LocalRun(books: books, designs: [source], looks: [look])
        defer { run.remove() }
        let pcc = ModelStatus(
            tier: .privateCloudCompute, isAvailable: true, unavailableReason: nil,
            coverReader: .designModel)
        let worker = run.worker(
            status: .backupStub, fallbackStatus: pcc,
            designBook: { book, accountID, workItemHash, cover, model in
                if model.tier == .backup, book.id == 7 { throw CompanionError.providerUnreachable }
                return LocalRun.design(
                    of: book, accountID: accountID, workItemHash: workItemHash, cover: cover,
                    model: model)
            }, sleep: { _ in })
        await worker.reconcile(mode: .foreground, redesigning: (7, true))
        _ = await LocalRun.updates(of: worker)

        let stored = try XCTUnwrap(try run.stored()[7])
        XCTAssertEqual(stored.tier, .privateCloudCompute)
        let remade =
            try await LocalSpineStore(folder: run.folder)
            .seriesLooks(accountID: LocalRun.accountID, keys: [key])[key]
        XCTAssertEqual(remade?.tier, .privateCloudCompute)
        let standsIn = await run.ledger.standsIn(
            recordName: LocalRun.recordName(7), for: .backup, design: stored)
        XCTAssertFalse(standsIn, "The remade look keeps the stand-in")
    }

    /// While the reader's model overrides Private Cloud Compute, the reader's redesign with it
    /// replaces Private Cloud Compute's designs and looks; without the override, or from a
    /// weaker tier, they stay. Runs the reader didn't ask for never replace them either way.
    func testTheChosenModelRedesignsPrivateCloudComputeSpinesWhileItOverridesIt() {
        let book = LocalRun.book(7)
        let coverHash = String(repeating: "c", count: 64)
        let pcc = LocalRun.design(for: book, coverHash: coverHash, provenance: nil)
        XCTAssertEqual(pcc.tier, .privateCloudCompute)
        func better(
            than tier: ModelTier, saved: SpineDesignV1?, look: SpineDesignV1? = nil,
            prefersBackup: Bool
        ) -> SpineDesignV1? {
            SpineWorker.betterDesign(
                than: tier, saved: saved, remadeLook: look, newCover: false,
                prefersBackup: prefersBackup)
        }
        XCTAssertEqual(better(than: .backup, saved: pcc, prefersBackup: false), pcc)
        XCTAssertNil(better(than: .backup, saved: pcc, prefersBackup: true))
        XCTAssertNil(better(than: .backup, saved: nil, look: pcc, prefersBackup: true))
        XCTAssertEqual(
            better(than: .onDevice, saved: pcc, prefersBackup: true), pcc,
            "Only the backup model ranks with Private Cloud Compute")
        XCTAssertEqual(ModelTier.local.redesignRank(prefersBackup: true), .local)
        XCTAssertFalse(ModelTier.privateCloudCompute.isReplaced(by: .backup))
    }

    /// A redesign note says where the controls are that would let this device redesign a better
    /// model's spine, and builds without Private Cloud Compute can't redesign its spines.
    func testRedesignAdviceNamesWhereToRedesign() {
        let setUp =
            "To redesign this spine here, open “Choose model” in the Spines tab and set up your own model."
        XCTAssertEqual(SpineWorker.redesignAdvice(for: .backup, deviceTier: .onDevice), setUp)
        XCTAssertEqual(SpineWorker.redesignAdvice(for: .onDevice, deviceTier: .local), setUp)
        let pcc = SpineWorker.redesignAdvice(for: .privateCloudCompute, deviceTier: .backup)
        #if NO_PCC
            let noPCC =
                "To redesign this spine, use a Bookworms build with Private Cloud Compute."
            XCTAssertEqual(pcc, noPCC)
            XCTAssertEqual(
                SpineWorker.redesignAdvice(for: .privateCloudCompute, deviceTier: .onDevice), noPCC)
        #else
            XCTAssertEqual(
                pcc,
                "To redesign this spine here, open “Choose model” in the Spines tab and turn on “Use this model instead of Private Cloud Compute”."
            )
            XCTAssertEqual(
                SpineWorker.redesignAdvice(for: .privateCloudCompute, deviceTier: .local),
                "To redesign this spine here, open “Choose model” in the Spines tab and set up your own model, then turn on “Use this model instead of Private Cloud Compute”."
            )
        #endif
    }

    /// The **Design model** footer suggests a fix only while Apple's on-device model or default
    /// styling designs, and the info button gives one reason at most, none of which the footer
    /// already gives.
    @MainActor func testDesignModelTextSaysEachFixOnce() {
        func status(_ tier: ModelTier, pcc: String? = nil, onDevice: String? = nil)
            -> ModelStatus
        {
            var status = ModelStatus(
                tier: tier, isAvailable: true, unavailableReason: nil, coverReader: .designModel)
            status.pccUnavailableReason = pcc
            status.onDeviceUnavailableReason = onDevice
            return status
        }
        let off = status(.local, onDevice: BookAnalyzer.appleIntelligenceOff)
        let turnOn = "turn on Apple Intelligence in \(ThisDevice.settingsApp)"
        let provider = "choose Anthropic, OpenAI, or Google Gemini and add your API key"
        XCTAssertEqual(
            GenerationView.tip(status: off, tier: .local, provider: .apple),
            "For better spines, \(turnOn), or \(provider).")
        XCTAssertEqual(
            GenerationView.tip(status: off, tier: .local, provider: .google),
            "For better spines, \(turnOn).")
        XCTAssertEqual(
            GenerationView.tip(status: status(.onDevice), tier: .onDevice, provider: .apple),
            "For better spines, \(provider).")
        XCTAssertNil(
            GenerationView.tip(status: status(.onDevice), tier: .onDevice, provider: .custom))
        XCTAssertNil(GenerationView.tip(status: nil, tier: .backup, provider: .apple))
        XCTAssertNil(
            GenerationView.tip(status: nil, tier: .privateCloudCompute, provider: .apple))

        let unsupportedPCC = "This iPhone doesn't support Private Cloud Compute."
        let unsupportedAI = "This iPhone doesn't support Apple Intelligence."
        func reason(_ status: ModelStatus, overrides: Bool = false) -> String? {
            GenerationView.infoReason(status: status, tier: status.tier, overrides: overrides)
        }
        XCTAssertNil(reason(off), "The footer says to turn on Apple Intelligence")
        XCTAssertEqual(
            reason(status(.local, pcc: unsupportedPCC, onDevice: unsupportedAI)), unsupportedAI,
            "One reason covers both models")
        #if NO_PCC
            XCTAssertNil(reason(status(.onDevice, pcc: unsupportedPCC)))
        #else
            XCTAssertEqual(reason(status(.onDevice, pcc: unsupportedPCC)), unsupportedPCC)
            XCTAssertEqual(reason(status(.backup, pcc: unsupportedPCC)), unsupportedPCC)
            XCTAssertNil(reason(status(.backup, pcc: unsupportedPCC), overrides: true))
        #endif
    }

    func testTitleNoFamilyCoversUsesTheStyleSystemTypeface() throws {
        let palette = ["#1F3A5A", "#D8CBB0"].compactMap(ColorValue.init(hex:))
        let choice = BookAnalyzer.DesignChoice(
            background: palette[0], ink: ColorValue(hex: "#F4EEE2")!, accent: palette[1],
            weight: 600)
        let book = CloudBook(
            id: 9, title: "\u{68EE}\u{306E}\u{5BB6}", author: "An Author", coverURL: nil,
            detailCoverURL: nil)
        let hash = String(repeating: "a", count: 64)
        let design = try BookAnalyzer.design(
            choice: choice, style: .bookSerif, font: nil, uppercase: false, palette: palette,
            book: book, accountID: "42", workItemHash: hash, coverHash: hash)
        XCTAssertEqual(design.typeface, "serif")
        XCTAssertEqual(design.weight, 600)
        XCTAssertNil(design.fontFamily)
        XCTAssertNil(design.fontPostScriptName)
        XCTAssertNil(design.instanceWeight)
    }

    func testLocalDefaultsUseTheStyleSystemTypefaceWhenFontsCannotDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-fonts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        let analyzer = BookAnalyzer(fonts: GoogleFonts(root: root, configuration: configuration))
        // A textless cover in two dark blues, so no title line is measured.
        let side = 64
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                pixels[offset] = 20
                pixels[offset + 1] = x < side / 2 ? 40 : 60
                pixels[offset + 2] = 90
            }
        }
        let image = try XCTUnwrap(
            pixels.withUnsafeMutableBytes { buffer in
                CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .makeImage()
            })
        let hash = String(repeating: "a", count: 64)
        let book = CloudBook(
            id: 9, title: "A Quiet Orbit", author: "Ann Author", coverURL: nil,
            detailCoverURL: nil, genres: ["Science Fiction"])
        let design = try await analyzer.design(
            book: book, accountID: "42", workItemHash: hash,
            cover: CoverImage(
                image: image, hash: hash, url: URL(string: "https://covers.example.com/9.jpg")!),
            using: .local)
        XCTAssertNil(design.fontFamily)
        XCTAssertNil(design.fontPostScriptName)
        XCTAssertEqual(design.typeface, SpineFontStyle.geometricSans.fallbackTypeface)
        XCTAssertEqual(design.weight, 700)
        XCTAssertEqual(design.tier, .local)
        // The design awaits its font, so a later run designs the book again.
        XCTAssertEqual(design.provenance, "model:local font:system")
        XCTAssertTrue(design.awaitsFont)
        // Without a model, the design records no reading, only the families it tried.
        let choice = try XCTUnwrap(design.choice)
        XCTAssertNil(choice.making)
        XCTAssertNil(choice.category)
        XCTAssertNil(choice.themes)
        XCTAssertFalse(choice.candidates.isEmpty)
        XCTAssertLessThanOrEqual(choice.candidates.count, 6)
        let lc = SpineContrast.apca(
            text: try XCTUnwrap(ColorValue(hex: design.foregroundHex)),
            background: try XCTUnwrap(ColorValue(hex: design.backgroundHex)))
        XCTAssertGreaterThanOrEqual(abs(lc), 75)
        // With the system typeface, a series copy of the design needs no download either.
        let letters = try await analyzer.letters(book, with: design)
        XCTAssertTrue(letters)
    }

    func testTitlesTheAtlasCannotRankFallBackToGenreOrHumanistFaces() throws {
        let atlas = try XCTUnwrap(FontAtlas.shared)
        let font = try XCTUnwrap(atlas.fonts.first { $0.family == "Oswald" && $0.weight == 400 })
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        func measurement(_ text: String) throws -> TitleLettering.Measurement {
            TitleLettering.Measurement(
                text: text, crop: image, profile: try XCTUnwrap(font.compose("KESTRAN")?.profile()),
                ink: ColorValue(hex: "#FFFFFF")!, ground: ColorValue(hex: "#000000")!)
        }
        func candidates(
            _ text: String, genres: [String]? = nil, local: Bool = true
        ) throws -> [TitleLettering.Match] {
            let book = CloudBook(
                id: 9, title: text, author: "Ann Author", coverURL: nil, detailCoverURL: nil,
                genres: genres)
            let families =
                local
                ? BookAnalyzer.localFamilies(genres: genres, measured: true)
                : BookAnalyzer.families(for: nil)
            return BookAnalyzer.candidates(
                families, lettering: try measurement(text), book: book, local: local)
        }
        func styles(_ matches: [TitleLettering.Match]) -> Set<SpineFontStyle> {
            Set(matches.compactMap { SpineFamily(rawValue: $0.family)?.style })
        }

        // The atlas has only Latin glyphs, so a Cyrillic title line ranks nothing.
        let cyrillic = "ВОЙНА"
        XCTAssertTrue(
            TitleLettering.rank(
                SpineFamily.allCases.map(\.rawValue), for: try measurement(cyrillic)
            )
            .isEmpty)
        let local = try candidates(cyrillic)
        XCTAssertEqual(styles(local), [.humanistSans], "Not the whole catalog")
        XCTAssertTrue(local.allSatisfy { $0.weight == 700 })
        XCTAssertEqual(styles(try candidates(cyrillic, genres: ["Horror"])), [.condensedSans])
        // A model's families keep their order at the lightest title weight.
        let model = try candidates(cyrillic, local: false)
        XCTAssertEqual(
            Set(model.map(\.family)), Set(BookAnalyzer.families(for: nil)))
        XCTAssertTrue(model.allSatisfy { $0.weight == TitleLettering.minimumWeight })
        // A Latin title line ranks the families it was given.
        XCTAssertTrue(styles(try candidates("KESTRAN")).count > 1)
    }

    func testLocalDefaultsChooseFamiliesFromTheFirstRecognizedGenre() {
        func styles(_ genres: [String]?, measured: Bool = true) -> Set<SpineFontStyle> {
            Set(
                BookAnalyzer.localFamilies(genres: genres, measured: measured)
                    .compactMap { SpineFamily(rawValue: $0)?.style })
        }
        XCTAssertEqual(styles(["Fantasy"]), [.classicalCaps, .bookSerif])
        XCTAssertEqual(styles(["LitRPG"]), [.classicalCaps, .bookSerif])
        XCTAssertEqual(styles(["Space Opera"]), [.geometricSans])
        XCTAssertEqual(styles(["Crime Fiction"]), [.condensedSans])
        XCTAssertEqual(styles(["Gothic"]), [.condensedSans])
        XCTAssertEqual(styles(["Historical Fiction"]), [.bookSerif])
        XCTAssertEqual(styles(["Memoir"]), [.humanistSans])
        XCTAssertEqual(styles(["Romance"]), [.humanistSans])
        XCTAssertEqual(styles(["Literary Fiction"]), [.humanistSans])
        XCTAssertEqual(styles(["Graphic Novel"]), [.humanistSans])
        XCTAssertEqual(styles(["Poetry"]), [.humanistSans])
        XCTAssertEqual(styles(["Young Adult"]), [.rounded])
        XCTAssertEqual(styles(["Humor"]), [.monospace, .decorative])
        XCTAssertTrue(
            BookAnalyzer.localFamilies(genres: ["Satire"], measured: true)
                .contains(SpineFamily.specialElite.rawValue))
        // The first genre that names a recognized one decides, in Hardcover's order.
        XCTAssertEqual(styles(["Adventure", "Mystery", "Fantasy"]), [.condensedSans])
        XCTAssertEqual(styles(["fantasy", "Science Fiction"]), [.classicalCaps, .bookSerif])

        // Without a recognized genre, the measurements rank the serif and sans families but
        // rounded faces, which only the young adult and middle grade row gets, and without a
        // reading, no themed faces.
        let unranked = styles(["Adventure"])
        XCTAssertEqual(
            unranked,
            [
                .bookSerif, .didone, .classicalCaps, .slab, .humanistSans, .geometricSans,
                .condensedSans,
            ])
        XCTAssertEqual(styles(nil), unranked)
        // With nothing measured either, the Apple TV's general-fiction face: a humanist sans.
        XCTAssertEqual(styles(nil, measured: false), [.humanistSans])
        XCTAssertEqual(styles(["Adventure"], measured: false), [.humanistSans])
        XCTAssertEqual(styles(["Horror"], measured: false), [.condensedSans])

        for genres in [nil, ["Fantasy"], ["Humor"], ["Young Adult"], ["Horror"]] as [[String]?] {
            for measured in [true, false] {
                let families = BookAnalyzer.localFamilies(genres: genres, measured: measured)
                XCTAssertFalse(families.isEmpty)
                XCTAssertTrue(families.allSatisfy(BookAnalyzer.allowsFamily), "\(families)")
            }
        }
        XCTAssertNil(BookAnalyzer.genreFamilies(["Adventure", "Nonfiction"]))
        // Genre rows name whole style groups, which include faces new designs never use.
        let rows = [
            "Fantasy", "LitRPG", "Thriller", "Horror", "Mystery", "Romance", "History",
            "Young Adult", "Humor", "Poetry",
        ]
        for genre in rows {
            for measured in [true, false] {
                let families = Set(BookAnalyzer.localFamilies(genres: [genre], measured: measured))
                XCTAssertTrue(
                    families.isDisjoint(with: SpineFamily.neverGenerated.map(\.rawValue)), genre)
            }
        }
    }

    func testLetteringAnswersNarrowTheFamiliesAndNeverOfferSlantedFaces() throws {
        typealias Reading = BookAnalyzer.CoverReading
        let tags = try XCTUnwrap(SpineFontTags.shared)
        func families(
            _ category: String, making: String = "typeset font", subclass: String? = nil,
            themes: [String] = [], moods: [String] = []
        ) -> [String] {
            BookAnalyzer.families(
                for: Reading(
                    making: making, category: category, subclass: subclass, themes: themes,
                    moods: moods))
        }
        func groups(_ families: [String]) -> Set<SpineFontTags.Group> {
            Set(families.compactMap(tags.group(of:)))
        }
        let serif = families("serif")
        XCTAssertEqual(groups(serif), [.serif, .slab])
        XCTAssertGreaterThan(serif.count, 100, "The whole atlas, not just the catalog")
        XCTAssertFalse(serif.contains("Italiana"), "Italiana is never generated")
        // A subclass shortlists the faces tagged with it when six or more remain.
        let didone = families("serif", subclass: "Serif / Didone")
        XCTAssertGreaterThanOrEqual(didone.count, 6)
        XCTAssertTrue(
            didone.allSatisfy {
                tags.score($0, anyOf: ["Serif/Didone", "Serif/Modern", "Serif/Fat Face"]) >= 50
            })
        // Each family joins only its identity's pools, so themed, blackletter, monospace, and
        // script faces never set a plain title, and display faces only from the catalog.
        func plain(_ family: String) -> Bool {
            switch tags.identity(of: family) {
            case .serif?, .slab?, .sans?: true
            case .display?: SpineFamily(rawValue: family) != nil
            default: false
            }
        }
        let sans = families("sans serif")
        for pool in [
            serif, sans, families("sans serif", moods: ["Playful"]), families("decorative"),
        ] {
            XCTAssertEqual(pool.filter { !plain($0) }, [])
        }
        // Faces whose Google tags mix identities.
        XCTAssertEqual(
            tags.identity(of: "Bodoni Moda"), .serif, "Tagged Serif/Modern and blackletter")
        XCTAssertTrue(serif.contains("Bodoni Moda"))
        XCTAssertEqual(tags.identity(of: "Fruktur"), .blackletter, "Tagged script and blackletter")
        XCTAssertEqual(
            tags.identity(of: "Tomorrow"), .themed("Techno"), "A geometric sans tagged Techno")
        XCTAssertEqual(tags.identity(of: "Space Mono"), .themed("Techno"))
        XCTAssertEqual(tags.identity(of: "Noto Sans Mono"), .monospace, "Filed as sans")
        XCTAssertEqual(tags.identity(of: "VT323"), .themed("Pixel"), "Pixel 100, Techno 90")
        XCTAssertEqual(tags.identity(of: "Madimi One"), .display, "Tagged sans and script")
        XCTAssertEqual(tags.identity(of: "Artifika"), .display, "Filed serif, tagged script")
        XCTAssertEqual(tags.identity(of: "Kalam"), .script, "Brush lettering is handwriting")
        // Playful and rounded faces need a playful mood, whatever the subclass.
        XCTAssertFalse(families("sans serif", subclass: "Sans / Rounded").contains("Fredoka"))
        XCTAssertTrue(families("sans serif", moods: ["Playful"]).contains("Fredoka"))
        // Themes that narrow nothing.
        for theme in ["Distressed", "Shaded", "Wacky", "Blobby"] {
            XCTAssertEqual(families("sans serif", themes: [theme]), sans, theme)
        }
        // A serif title keeps serif faces: a theme narrows them only to its faces with serifs.
        let woodtype = families("serif", themes: ["Woodtype"])
        XCTAssertTrue(woodtype.contains("Rye"))
        XCTAssertEqual(groups(woodtype).subtracting([.serif, .slab]), [])
        XCTAssertEqual(families("serif", themes: ["Pixel"]), serif)
        XCTAssertTrue(families("decorative", themes: ["Art Deco"]).contains("Federo"))
        let techno = families("sans serif", themes: ["Techno"])
        XCTAssertTrue(techno.contains("Geo"))
        XCTAssertFalse(techno.contains("VT323"))
        XCTAssertTrue(families("sans serif", themes: ["Pixel"]).contains("VT323"))
        // The on-device crop reader's combined answer keeps both.
        let tech = families("sans serif", themes: ["Pixel or Techno"])
        XCTAssertTrue(tech.contains("VT323") && tech.contains("Geo"))
        // A theme with fewer than three faces narrows nothing.
        XCTAssertEqual(families("decorative", themes: ["Inline"]), families("decorative"))
        let gothic = families("blackletter")
        XCTAssertTrue(gothic.contains("UnifrakturCook"))
        XCTAssertTrue(gothic.contains("Fruktur"))
        XCTAssertFalse(gothic.contains("Bodoni Moda"))
        // Handwriting gets the script faces; custom-drawn letters follow their category.
        let script = families("sans serif", making: "handwriting")
        XCTAssertTrue(script.contains("Patrick Hand"))
        XCTAssertTrue(script.allSatisfy { tags.identity(of: $0) == .script })
        XCTAssertEqual(families("blackletter", making: "handwriting"), gothic)
        XCTAssertEqual(families("sans serif", making: "brush or marker"), script)
        XCTAssertEqual(groups(families("sans serif", making: "custom-drawn letters")), [.sans])
        // Without a reading, as for local defaults, the catalog's serif and sans families.
        let everything = BookAnalyzer.families(for: nil)
        XCTAssertTrue(everything.allSatisfy { SpineFamily(rawValue: $0) != nil })
        XCTAssertFalse(
            everything.contains { [.script, .rounded].contains(SpineFamily(rawValue: $0)?.style) })
        let offered = Set(script + families("decorative") + everything)
        let unchosen =
            ["Dancing Script", "Pacifico", "Great Vibes", "Lobster", "Bangers"]
            + SpineFamily.neverGenerated.map(\.rawValue)
        for slanted in unchosen {
            XCTAssertFalse(offered.contains(slanted), slanted)
        }
        XCTAssertFalse(BookAnalyzer.allowsFamily("Impact"))
        XCTAssertFalse(BookAnalyzer.allowsFamily("Lora Italic"))
        XCTAssertFalse(BookAnalyzer.allowsFamily("Noto Sans Oblique"))
        XCTAssertTrue(BookAnalyzer.allowsFamily("EB Garamond"))
    }

    func testTitleMeasurementIgnoresLetterSpacingAndNeighbouringLines() throws {
        // Two 10 × 40 letters 30 pixels apart, with a thin neighbouring line above them.
        var pixels = [Float](repeating: 0, count: 100 * 60)
        for y in 15..<55 {
            for x in 10..<20 { pixels[y * 100 + x] = 1 }
            for x in 50..<60 { pixels[y * 100 + x] = 1 }
        }
        for x in 0..<100 { pixels[2 * 100 + x] = 1 }
        let profile = try XCTUnwrap(Mask(width: 100, height: 60, pixels: pixels).profile())
        // The gap collapses to a twelfth of the 40-pixel band: (10 + 3 + 10) / 40, rounded to
        // the 48-pixel grid.
        XCTAssertEqual(profile.aspect, Double(23 * 48 / 40) / 48, accuracy: 0.001)
        // Box filtering leaves one partial column at each letter edge, so even strokes vary
        // by a pixel.
        XCTAssertLessThan(profile.strokeSpread, 0.2)
        XCTAssertEqual(profile.shape.count, 320 * 48)
    }

    /// The owner's standing rule: no spine ever uses Impact, in any spelling, from any source.
    func testImpactCanNeverBeChosenOrRendered() throws {
        for name in [
            "Impact", "impact", "IMPACT", "Impact-Regular", "Impact Bold", "ImpactMT", " Impact ",
        ] {
            XCTAssertFalse(BookAnalyzer.allowsFamily(name), name)
        }
        let catalog = SpineFamily.allCases.map { $0.rawValue.lowercased() }
        XCTAssertFalse(catalog.contains { $0.contains("impact") })
        let offered = BookAnalyzer.families(for: nil)
        XCTAssertFalse(offered.contains { $0.lowercased().contains("impact") })
        XCTAssertTrue(BookAnalyzer.allowsFamily(SpineFamily.impactReplacement.rawValue))
        XCTAssertEqual(SpineFamily.impactReplacement.style, .condensedSans)

        // A design saved elsewhere that names Impact loads as stored and draws as the
        // replacement.
        let saved = Data(
            """
            {"version":1,"accountID":"account","bookID":5,"workItemHash":"\(String(repeating: "a", count: 64))",
            "coverHash":"\(String(repeating: "b", count: 64))","generatorVersion":"tv-v1","generatedAt":0,
            "backgroundHex":"#101010","foregroundHex":"#F4EEE2","accentHex":"#7A1F1F",
            "typeface":"sans","weight":700,"uppercase":true,"fontFamily":"Impact",
            "fontPostScriptName":"Impact","instanceWeight":400}
            """
            .utf8)
        let design = try JSONDecoder().decode(SpineDesignV1.self, from: saved)
        let book = CloudBook(
            id: 5, title: "A Title", author: "An Author", coverURL: nil, detailCoverURL: nil,
            genres: nil)
        let stored = try XCTUnwrap(
            LibrarySnapshot.latestDesigns([design], accountID: "account", books: [book])[5])
        XCTAssertEqual(stored, design, "The library keeps the record as stored")
        XCTAssertFalse(SeriesDesigns.isUsableSource(stored), "No series look copies Impact")
        var unnamed = stored
        unnamed.fontFamily = nil
        XCTAssertFalse(
            SeriesDesigns.isUsableSource(unnamed),
            "Nor one that names Impact only by PostScript name")
        let loaded = stored.withAllowedFont
        XCTAssertEqual(loaded.fontFamily, "Bebas Neue")
        XCTAssertNil(loaded.fontPostScriptName)
        XCTAssertNil(loaded.instanceWeight)
        XCTAssertEqual(loaded.backgroundHex, design.backgroundHex)
        XCTAssertNoThrow(try loaded.validate())
        let postScriptOnly = design.withFontFamily("Anton", postScriptName: "Impact-Regular")
        XCTAssertEqual(postScriptOnly.withAllowedFont.fontFamily, "Bebas Neue")
        let allowed = design.withFontFamily("Anton", postScriptName: "Anton-Regular")
        XCTAssertEqual(allowed.withAllowedFont, allowed)
    }

    /// The owner's standing rule: no italics. Saved designs in a slanted or italic face load in
    /// an allowed upright one; the stored record is untouched.
    func testBlockedOrItalicSavedFontsLoadUpright() throws {
        let base = SpineDesignV1(
            version: 1, accountID: "account", bookID: 5,
            workItemHash: String(repeating: "a", count: 64),
            coverHash: String(repeating: "b", count: 64), generatorVersion: "tv-v1",
            generatedAt: Date(), backgroundHex: "#101010", foregroundHex: "#F4EEE2",
            accentHex: "#7A1F1F", typeface: "sans", weight: 700, uppercase: true,
            instanceWeight: 400)
        func loaded(_ family: String?, _ postScriptName: String?) -> SpineDesignV1 {
            var design = base
            design.fontFamily = family
            design.fontPostScriptName = postScriptName
            return design.withAllowedFont
        }
        let expected: [(String?, String?, String?)] = [
            ("Impact", "Impact", "Bebas Neue"),
            ("Bangers", "Bangers-Regular", "Bungee"),
            ("Shrikhand", "Shrikhand-Regular", "Changa One"),
            ("Bangers Italic", nil, "Bungee"),
            ("Lora Italic", "Lora-Italic", "Lora"),
            ("eb garamond oblique", nil, "EB Garamond"),
            ("EB Garamond", "EBGaramond-Italic", "EB Garamond"),
            ("Lora", "Lora-BoldIt", "Lora"),
            ("Italic", nil, nil),
            ("Dancing Script", "DancingScript-Bold", "Patrick Hand"),
            ("Great Vibes", "GreatVibes-Regular", "Patrick Hand"),
            ("Pacifico", nil, "Patrick Hand"),
            // Faces whose letters lean without declaring it draw upright too.
            ("Caveat", "Caveat-Regular", "Patrick Hand"),
            ("Kalam", nil, "Patrick Hand"),
            ("Shadows Into Light", "ShadowsIntoLight", "Patrick Hand"),
            // A PostScript name alone, as an Apple TV look saves it, shows its family's stand-in.
            (nil, "DancingScript-Bold", "Patrick Hand"),
            (nil, "GreatVibes-Regular", "Patrick Hand"),
            (nil, "EBGaramond-Italic", "EB Garamond"),
            (nil, "Georgia-Italic", nil),
        ]
        for (family, postScriptName, replacement) in expected {
            let design = loaded(family, postScriptName)
            XCTAssertEqual(design.fontFamily, replacement, "\(family ?? "-")")
            XCTAssertNil(design.fontPostScriptName)
            XCTAssertNil(design.instanceWeight)
            XCTAssertTrue(design.fontFamily.map(BookAnalyzer.allowsFamily) ?? true)
            XCTAssertNoThrow(try design.validate())
        }
        XCTAssertEqual(loaded("Lora", "Lora-Bold"), loaded("Lora", "Lora-Bold").withAllowedFont)
        XCTAssertEqual(loaded("Lora", "Lora-Bold").fontPostScriptName, "Lora-Bold")
        for replacement in SpineFamily.slantedReplacements.values {
            XCTAssertTrue(BookAnalyzer.allowsFamily(replacement.rawValue))
            XCTAssertTrue([.decorative, .script].contains(replacement.style))
        }
        // A replaced family is blocked, or a saved design in it would never be replaced.
        for family in ["Dancing Script", "Shadows Into Light", "Bangers"] {
            XCTAssertFalse(BookAnalyzer.allowsFamily(family), family)
        }

        // A loaded face with the italic trait is passed over for an upright one, whatever the
        // saved PostScript name asks for.
        func face(_ name: String) throws -> CTFontDescriptor {
            let font = CTFontCreateWithName(name as CFString, 24, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name)
            return CTFontCopyFontDescriptor(font)
        }
        let italic = try face("Georgia-Italic")
        let upright = try face("Georgia")
        XCTAssertFalse(FontFiles.isUpright(italic))
        XCTAssertTrue(FontFiles.isUpright(upright))
        let chosen = try XCTUnwrap(
            GoogleFonts.uprightDescriptor(
                preferring: ["Georgia-Italic", nil], in: [italic, upright]))
        XCTAssertEqual(FontFiles.postScriptName(of: chosen), "Georgia")
        XCTAssertNil(GoogleFonts.uprightDescriptor(preferring: ["Georgia-Italic"], in: [italic]))
    }

    func testTitleSplitTakesTheGroundFromTheBorder() throws {
        // Light letters on a navy ground: the ink is the lighter, smaller cluster.
        let width = 120
        let height = 40
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.1, green: 0.15, blue: 0.35, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.95, green: 0.9, blue: 0.8, alpha: 1)
        for x in stride(from: 10, to: 110, by: 20) {
            context.fill(CGRect(x: x, y: 8, width: 8, height: 24))
        }
        let split = try XCTUnwrap(TitleLettering.split(try XCTUnwrap(context.makeImage())))
        XCTAssertGreaterThan(SpineContrast.lab(split.ink).l, SpineContrast.lab(split.ground).l)
        XCTAssertLessThan(SpineContrast.lab(split.ground).l, 0.4)
    }

    func testRankingPicksTheFamilyTheLetteringWasSetIn() throws {
        let atlas = try XCTUnwrap(FontAtlas.shared)
        XCTAssertTrue(
            Set(SpineFamily.allCases.map(\.rawValue)).isSubset(of: atlas.fonts.map(\.family)))
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        // Lettering composed from the atlas itself must rank its own family first.
        for family in ["Oswald", "EB Garamond", "Josefin Sans", "Bodoni Moda", "Arvo"] {
            let font = try XCTUnwrap(atlas.fonts.first { $0.family == family && $0.weight == 400 })
            let profile = try XCTUnwrap(font.compose("KESTRAN")?.profile())
            let measurement = TitleLettering.Measurement(
                text: "KESTRAN", crop: image, profile: profile,
                ink: ColorValue(hex: "#FFFFFF")!, ground: ColorValue(hex: "#000000")!)
            let ranked = TitleLettering.rank(SpineFamily.allCases.map(\.rawValue), for: measurement)
            XCTAssertEqual(ranked.first?.family, family)
        }
    }

    func testFallbackTypefacesFollowTheLetterformClass() {
        XCTAssertEqual(BookAnalyzer.style(of: "Grenze"), .bookSerif, "Blackletter with serifs")
        XCTAssertEqual(BookAnalyzer.style(of: "Share Tech Mono"), .monospace, "Themed Techno")
        XCTAssertEqual(BookAnalyzer.style(of: "Handlee"), .script)
        XCTAssertEqual(BookAnalyzer.style(of: "Aladin"), .decorative)
        XCTAssertEqual(BookAnalyzer.style(of: "Not A Family"), .humanistSans)
        XCTAssertEqual(BookAnalyzer.style(of: "Oswald"), SpineFamily.oswald.style)
    }

    func testProviderRefusalsReadAsGuardrailViolations() {
        let refusal: [String: Any] = ["stop_reason": "refusal", "content": []]
        XCTAssertTrue(ProviderHTTP.isRefusal(refusal, provider: .anthropic))
        XCTAssertFalse(ProviderHTTP.isRefusal(["stop_reason": "end_turn"], provider: .anthropic))
        XCTAssertFalse(ProviderHTTP.isRefusal(refusal, provider: .google))

        // Gemini blocks a prompt without candidates, or stops a candidate for safety.
        let blocked: [String: Any] = ["promptFeedback": ["blockReason": "SAFETY"]]
        XCTAssertTrue(ProviderHTTP.isRefusal(blocked, provider: .google))
        for reason in ["SAFETY", "PROHIBITED_CONTENT", "IMAGE_SAFETY", "BLOCKLIST", "SPII"] {
            let stopped: [String: Any] = ["candidates": [["finishReason": reason]]]
            XCTAssertTrue(ProviderHTTP.isRefusal(stopped, provider: .google), reason)
        }
        let answered: [String: Any] = [
            "candidates": [["finishReason": "STOP", "content": ["parts": [["text": "{}"]]]]]
        ]
        XCTAssertFalse(ProviderHTTP.isRefusal(answered, provider: .google))
        XCTAssertFalse(ProviderHTTP.isRefusal(blocked, provider: .openAI))

        // OpenAI-compatible endpoints answer a refusal message instead of content.
        let declined: [String: Any] = [
            "choices": [["message": ["content": NSNull(), "refusal": "No."]]]
        ]
        XCTAssertTrue(ProviderHTTP.isRefusal(declined, provider: .openAI))
        XCTAssertTrue(ProviderHTTP.isRefusal(declined, provider: .custom))
        let replied: [String: Any] = [
            "choices": [["message": ["content": "{}", "refusal": NSNull()]]]
        ]
        XCTAssertFalse(ProviderHTTP.isRefusal(replied, provider: .openAI))
        let empty: [String: Any] = ["choices": [["message": ["content": "{}", "refusal": ""]]]]
        XCTAssertFalse(ProviderHTTP.isRefusal(empty, provider: .custom))
        XCTAssertFalse(ProviderHTTP.isRefusal(nil, provider: .openAI))
    }

    /// A design model's line is measured by its place among the listed lines, and a rejected
    /// cover falls back to Vision's line, whose crop the lettering questions read.
    func testDesignModelsMeasureTheirLineOrFallBackToVisions() async throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Two lines of three letters each; Core Graphics counts rows from the bottom.
        for x in [40, 60, 80] {
            context.fill(CGRect(x: x, y: 62, width: 8, height: 26))
            context.fill(CGRect(x: x, y: 12, width: 8, height: 26))
        }
        let image = try XCTUnwrap(context.makeImage())
        let top = TitleLettering.Line(
            text: "TOP", box: CGRect(x: 0.15, y: 0.6, width: 0.4, height: 0.3))
        let bottom = TitleLettering.Line(
            text: "BOTTOM", box: CGRect(x: 0.15, y: 0.1, width: 0.4, height: 0.3))
        typealias Reading = BookAnalyzer.CoverReading
        // The cover reading notes the lines it was given, and the lettering reading the size of
        // the crop it read.
        func read(_ answer: Reading?) async throws -> (
            lettering: TitleLettering.Measurement?, reading: Reading?
        ) {
            try await BookAnalyzer.designModelReading(
                of: image, lines: [bottom, top], title: "Bottom Line",
                readCover: { listed in
                    answer.map { answer in
                        var reading = answer
                        reading.note = listed.map(\.text).joined(separator: " ")
                        return reading
                    }
                },
                readLettering: { crop in Reading(note: "\(crop.width)x\(crop.height)") })
        }

        // OCR order doesn't matter: the listed lines run top to bottom.
        let chosen = try await read(Reading(titleLine: 0))
        XCTAssertEqual(chosen.lettering?.text, "TOP")
        XCTAssertEqual(chosen.reading?.note, "TOP BOTTOM")
        // A title on no listed line, such as stacked or curved lettering, is not measured.
        let unlisted = try await read(Reading())
        XCTAssertNil(unlisted.lettering)
        XCTAssertEqual(unlisted.reading?.note, "TOP BOTTOM")
        // Vision's line shares a word with the title.
        let rejected = try await read(nil)
        let lettering = try XCTUnwrap(rejected.lettering)
        XCTAssertEqual(lettering.text, "BOTTOM")
        XCTAssertLessThan(lettering.crop.width, image.width)
        XCTAssertEqual(rejected.reading?.note, "\(lettering.crop.width)x\(lettering.crop.height)")
    }

    /// A model that refuses the whole cover or its title crop gives no reading, as a guardrail
    /// does, so the design falls back to the crop and then to the measurements alone.
    func testDesignModelRefusalsGiveNoReading() async throws {
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        let options = ContextOptions(includeSchemaInPrompt: true)
        let cover = try await BookAnalyzer.readCover(
            image, lines: [], book: LocalRun.book(7), model: RefusingModel(),
            contextOptions: options)
        XCTAssertNil(cover)
        let crop = try await BookAnalyzer.readLettering(
            image, model: RefusingModel(), contextOptions: options)
        XCTAssertNil(crop)
    }

    func testCoverReadingKeepsOnlyAnswersFromItsLists() {
        typealias Reading = BookAnalyzer.CoverReading
        let content = GeneratedContent(properties: [
            "titleLine": "L2", "titleText": "QUIET\nORBIT", "titleCase": "all capitals",
            "making": "typeset font", "category": "serif", "subclass": "Sans / Grotesque",
            "themes": ["Woodtype", "Woodtype", "Stencil", "Inline"],
            "moods": ["Calm", "Bright", "Calm"], "weight": "bold", "width": "huge",
        ])
        let reading = BookAnalyzer.coverReading(from: content, lineCount: 3)
        XCTAssertEqual(reading.titleLine, 1)
        XCTAssertEqual(reading.titleText, "QUIET ORBIT")
        XCTAssertEqual(reading.category, "serif")
        XCTAssertNil(reading.subclass, "A sans subclass doesn't describe a serif")
        XCTAssertEqual(reading.themes, ["Woodtype", "Stencil"])
        XCTAssertEqual(reading.moods, ["Calm"])
        XCTAssertEqual(reading.weight, "bold")
        XCTAssertNil(reading.width)
        // "none", or a line the cover doesn't list, leaves the title unmeasured.
        for line in ["none", "L4"] {
            XCTAssertNil(
                BookAnalyzer.coverReading(
                    from: GeneratedContent(properties: ["titleLine": line]), lineCount: 3
                )
                .titleLine)
        }
    }

    func testOnDeviceCropAnswersKeepTheirThemes() {
        func reading(_ serifs: String, _ treatment: String) -> BookAnalyzer.CoverReading {
            BookAnalyzer.letteringReading(
                making: "typeset font", serifs: serifs, treatment: treatment)
        }
        let tech = reading("small bracketed serifs", "pixel or sci-fi tech")
        XCTAssertEqual(tech.category, "decorative", "The theme sets the pool, not the serifs")
        let faces = BookAnalyzer.families(for: tech)
        XCTAssertTrue(faces.contains("VT323") && faces.contains("Geo"))
        XCTAssertEqual(
            reading("hairline serifs", "outlined or multi-line neon").category, "decorative")
        let woodtype = reading("thick square slab serifs", "western wood type")
        XCTAssertEqual(woodtype.category, "slab serif")
        XCTAssertEqual(woodtype.themes, ["Woodtype"])
        XCTAssertEqual(reading("none", "gothic broken strokes").category, "blackletter")
        XCTAssertEqual(reading("hairline serifs", "plain").subclass, "Serif / Didone")
        XCTAssertEqual(
            BookAnalyzer.letteringReading(
                making: "hand-drawn, brush, or handwritten", serifs: "none", treatment: "plain"
            )
            .making, "handwriting")
    }

    func testModelsChooseFromTheSixteenTallestLinesTopToBottom() throws {
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        // Twenty level lines, taller toward the bottom of the cover, and one set vertically.
        var lines = (0..<20)
            .map { index in
                TitleLettering.Line(
                    text: "LINE \(index)",
                    box: CGRect(
                        x: 0.1, y: 0.9 - Double(index) * 0.04, width: 0.8,
                        height: 0.01 + Double(index) * 0.001))
            }
        lines.append(
            TitleLettering.Line(
                text: "VERTICAL", box: CGRect(x: 0.9, y: 0.1, width: 0.02, height: 0.8)))
        let listed = TitleLettering.listed(lines, in: image).map(\.text)
        XCTAssertEqual(listed, (4..<20).map { "LINE \($0)" })
    }

    func testMoodPenaltiesSettleOnlyNearTies() throws {
        let atlas = try XCTUnwrap(FontAtlas.shared)
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        let catalog = SpineFamily.allCases.map(\.rawValue)
        // Mood penalties between a reading's families differ by at most about 0.85, which
        // doesn't outweigh the family the lettering was set in; only twins as close as EB
        // Garamond and Lora flip near 1.
        for family in ["Oswald", "EB Garamond", "Josefin Sans", "Bodoni Moda", "Arvo"] {
            let font = try XCTUnwrap(atlas.fonts.first { $0.family == family && $0.weight == 400 })
            let measurement = TitleLettering.Measurement(
                text: "KESTRAN", crop: image,
                profile: try XCTUnwrap(font.compose("KESTRAN")?.profile()),
                ink: ColorValue(hex: "#FFFFFF")!, ground: ColorValue(hex: "#000000")!)
            let ranked = TitleLettering.rank(
                catalog, for: measurement, penalties: [family: 0.85])
            XCTAssertEqual(ranked.first?.family, family)
        }
        // On the width ranking, a penalty settles a near tie but never outweighs the width
        // answer: the farthest face stays out of first however well it fits the mood.
        let sans = BookAnalyzer.families(
            for: BookAnalyzer.CoverReading(making: "typeset font", category: "sans serif"))
        func first(_ penalties: [String: Double]) -> String? {
            TitleLettering.rank(
                sans, width: "normal", weight: nil, text: "QUIET ORBIT", penalties: penalties
            )
            .first?
            .family
        }
        let plain = TitleLettering.rank(sans, width: "normal", weight: nil, text: "QUIET ORBIT")
            .map(\.family)
        guard plain.count > 100 else { return XCTFail("Only \(plain.count) sans faces ranked") }
        XCTAssertEqual(first([plain[0]: 1]), plain[1])
        for far in [plain[60], plain[plain.count - 1]] {
            XCTAssertNotEqual(
                first(Dictionary(uniqueKeysWithValues: sans.map { ($0, $0 == far ? 0 : 1) })),
                far)
        }
    }

    func testCoverColorsKeepToTheHouseStyle() throws {
        let atlas = try XCTUnwrap(FontAtlas.shared)
        let font = try XCTUnwrap(atlas.fonts.first { $0.family == "Oswald" && $0.weight == 400 })
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        func choice(ink: String, ground: String) throws -> BookAnalyzer.DesignChoice {
            let measurement = TitleLettering.Measurement(
                text: "KESTRAN", crop: image,
                profile: try XCTUnwrap(font.compose("KESTRAN")?.profile()),
                ink: try XCTUnwrap(ColorValue(hex: ink)),
                ground: try XCTUnwrap(ColorValue(hex: ground)))
            return BookAnalyzer.choice(
                measurement, palette: [try XCTUnwrap(ColorValue(hex: ground))], weight: 500)
        }
        func lab(_ color: ColorValue) -> (l: Double, chroma: Double) {
            let lab = SpineContrast.lab(color)
            return (lab.l, hypot(lab.a, lab.b))
        }

        // A neon ground becomes a pastel cloth, which takes dark ink.
        let neon = try choice(ink: "#101010", ground: "#40FFC0")
        XCTAssertLessThanOrEqual(lab(neon.background).chroma, 0.06)
        XCTAssertLessThan(lab(neon.ink).l, 0.3)
        // Dark lettering on a mid-tone red cover gets light ink on red cloth.
        let red = try choice(ink: "#101010", ground: "#CD2828")
        XCTAssertGreaterThan(lab(red.ink).l, 0.9)
        XCTAssertLessThanOrEqual(lab(red.background).chroma, 0.121)
        XCTAssertGreaterThan(lab(red.background).chroma, 0.1, "The cloth stays red")
        // A deliberate deep red title on cream keeps its color; a faint tint becomes near-black.
        let deliberate = try choice(ink: "#8B1E1E", ground: "#F4EFE4")
        XCTAssertGreaterThan(lab(deliberate.ink).chroma, 0.08)
        let faint = try choice(ink: "#4A4540", ground: "#F4EFE4")
        XCTAssertLessThanOrEqual(lab(faint.ink).chroma, 0.021)
        XCTAssertLessThan(lab(faint.ink).l, 0.25)
        // The resolved designs still pass the shared contrast rule.
        let book = CloudBook(
            id: 9, title: "Kestran", author: "An Author", coverURL: nil, detailCoverURL: nil)
        let hash = String(repeating: "a", count: 64)
        for choice in [neon, red, deliberate, faint] {
            XCTAssertNoThrow(
                try BookAnalyzer.design(
                    choice: choice, style: .condensedSans, font: nil, uppercase: true,
                    palette: [choice.background], book: book, accountID: "42",
                    workItemHash: hash, coverHash: hash))
        }
    }

    func testRankingMatchesStrokeWeightAtSemiboldOrHeavier() throws {
        XCTAssertEqual(TitleLettering.weight(regular: 0.1, bold: 0.2, cover: 0.05), 600)
        XCTAssertEqual(TitleLettering.weight(regular: 0.1, bold: 0.2, cover: 0.165), 600)
        XCTAssertEqual(TitleLettering.weight(regular: 0.1, bold: 0.2, cover: 0.19), 700)
        XCTAssertEqual(TitleLettering.weight(regular: 0.1, bold: 0.1, cover: 0.3), 600)

        let atlas = try XCTUnwrap(FontAtlas.shared)
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        func measurement(_ profile: Mask.Profile) -> TitleLettering.Measurement {
            TitleLettering.Measurement(
                text: "KESTRAN", crop: image, profile: profile,
                ink: ColorValue(hex: "#FFFFFF")!, ground: ColorValue(hex: "#000000")!)
        }
        func composed(_ family: String, weight: Int = 400) throws -> TitleLettering.Measurement {
            let font = try XCTUnwrap(
                atlas.fonts.first { $0.family == family && $0.weight == weight })
            return measurement(try XCTUnwrap(font.compose("KESTRAN")?.profile()))
        }
        let families = SpineFamily.allCases.map(\.rawValue)
        let oswald = TitleLettering.rank(families, for: try composed("Oswald"))
        XCTAssertEqual(Set(oswald.map(\.family)).count, oswald.count, "One match per family")
        XCTAssertTrue(oswald.allSatisfy { (600...700).contains($0.weight) })
        // Bold lettering ranks a family at a heavier weight than its regular does.
        let bold = try XCTUnwrap(
            TitleLettering.rank(families, for: try composed("Oswald", weight: 700))
                .first { $0.family == "Oswald" })
        let regular = try XCTUnwrap(oswald.first { $0.family == "Oswald" })
        XCTAssertGreaterThan(bold.weight, regular.weight)
        // A didone's hairline crossbars are thinner than a slab's.
        XCTAssertLessThan(
            try composed("Bodoni Moda").profile.crossStroke,
            try composed("Arvo").profile.crossStroke)
        // Heavy lettering leaves out single-weight faces too light to match it; regular
        // lettering keeps them.
        let light = ["Libre Caslon Display", "Castoro Titling"]
        let heavy = TitleLettering.rank(families, for: try composed("Alfa Slab One"))
        XCTAssertFalse(heavy.contains { light.contains($0.family) })
        let plain = TitleLettering.rank(families, for: try composed("EB Garamond"))
        XCTAssertTrue(light.allSatisfy { family in plain.contains { $0.family == family } })

        // Seven letters drawn as 2-pixel outlines have hairline strokes; solid ones don't.
        var pixels = [Float](repeating: 0, count: 230 * 40)
        for letter in 0..<7 {
            for y in 0..<40 {
                for x in (letter * 32)..<(letter * 32 + 20)
                where y < 2 || y >= 38 || x < letter * 32 + 2 || x >= letter * 32 + 18 {
                    pixels[y * 230 + x] = 1
                }
            }
        }
        let outlined = measurement(
            try XCTUnwrap(Mask(width: 230, height: 40, pixels: pixels).profile()))
        XCTAssertTrue(TitleLettering.hasHairlineStrokes(outlined))
        XCTAssertFalse(TitleLettering.hasHairlineStrokes(try composed("Oswald")))
        // The model's Inline theme stands only for such lettering.
        let neon = BookAnalyzer.CoverReading(category: "sans serif", themes: ["Inline", "Techno"])
        XCTAssertEqual(BookAnalyzer.checked(neon, against: outlined), neon)
        XCTAssertEqual(
            BookAnalyzer.checked(neon, against: try composed("Oswald"))?.themes, ["Techno"])
        XCTAssertNil(BookAnalyzer.checked(nil, against: outlined))
        // Other answers stand, whatever the book's genres, as for a history book's gothic title.
        let gothic = BookAnalyzer.CoverReading(category: "blackletter")
        XCTAssertEqual(BookAnalyzer.checked(gothic, against: try composed("Oswald")), gothic)
    }

    func testTitleMeasurementSkipsVerticalLinesAndRowsBelowTheLine() throws {
        // Two 10 × 40 letters at rows 30 to 70 of a white cover, a dark picture touching their
        // feet from row 70 down, and a tall vertical line of text at the right.
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Core Graphics counts rows from the bottom.
        context.fill(CGRect(x: 20, y: 30, width: 10, height: 40))
        context.fill(CGRect(x: 60, y: 30, width: 10, height: 40))
        context.fill(CGRect(x: 0, y: 0, width: 140, height: 30))
        context.fill(CGRect(x: 180, y: 5, width: 8, height: 90))
        let image = try XCTUnwrap(context.makeImage())
        // Vision's box for the letters stops 4 rows above their feet; the vertical line is taller.
        let letters = TitleLettering.Line(
            text: "II", box: CGRect(x: 0.08, y: 0.34, width: 0.3, height: 0.36))
        let vertical = TitleLettering.Line(
            text: "TITLE", box: CGRect(x: 0.89, y: 0.05, width: 0.05, height: 0.9))
        let measurement = try XCTUnwrap(
            TitleLettering.measure(image, lines: [letters, vertical], title: "Title"))
        XCTAssertEqual(measurement.text, "II")
        // The letters alone: (10 + 3 + 10) columns for about 38 rows. The picture's full-width
        // rows would leave no gap to collapse and make the line about three times as wide.
        XCTAssertEqual(measurement.profile.aspect, 0.6, accuracy: 0.08)
    }
}

extension GenerationTests {
    func testTiltedTitleLinesMeasureLevel() throws {
        // Two 10 × 40 letters 30 pixels apart, turned 30 degrees about the image's center.
        let size = 300.0
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let angle = Double.pi / 6
        context.translateBy(x: size / 2, y: size / 2)
        context.rotate(by: angle)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: -25, y: -20, width: 10, height: 40))
        context.fill(CGRect(x: 15, y: -20, width: 10, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        // Vision's quadrilateral, normalized with a bottom-left origin as Core Graphics draws.
        let corners = [(-25.0, -20.0), (25, -20), (25, 20), (-25, 20)]
            .map { u, v in
                CGPoint(
                    x: (size / 2 + u * cos(angle) - v * sin(angle)) / size,
                    y: (size / 2 + u * sin(angle) + v * cos(angle)) / size)
            }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let box = CGRect(
            x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!,
            height: ys.max()! - ys.min()!)
        let tilted = try XCTUnwrap(
            TitleLettering.measure(
                image, lines: [TitleLettering.Line(text: "II", box: box, corners: corners)],
                title: "II"))
        // As level: (10 + 3 + 10) columns for 40 rows.
        XCTAssertEqual(tilted.profile.aspect, 0.6, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(tilted.inkSpan), 1, accuracy: 0.1)
        let upright = try XCTUnwrap(
            TitleLettering.measure(
                image, lines: [TitleLettering.Line(text: "II", box: box)], title: "II"))
        XCTAssertGreaterThan(abs(upright.profile.aspect - tilted.profile.aspect), 0.2)
    }

    /// A turned line in a mask whose axes scale apart keeps its area: its thickness across its
    /// new direction is the area over its new length.
    func testTurnedLineThicknessScalesAcrossItsNewDirection() {
        let level = TitleLettering.scaling(angle: 0, scaleX: 1, scaleY: 2)
        XCTAssertEqual(level.length, 1, accuracy: 1e-9)
        XCTAssertEqual(level.thickness, 2, accuracy: 1e-9)
        let turned = TitleLettering.scaling(angle: .pi / 4, scaleX: 1, scaleY: 2)
        XCTAssertEqual(turned.length, sqrt(2.5), accuracy: 1e-9)
        XCTAssertEqual(turned.thickness, 2 / sqrt(2.5), accuracy: 1e-9)
        XCTAssertEqual(turned.angle, atan(2), accuracy: 1e-9)
        // A unit square on the line maps to a parallelogram of area 2; its height across the
        // new direction is the distance from the mapped normal's tip to the mapped line.
        let normal = (x: -sin(Double.pi / 4), y: 2 * cos(Double.pi / 4))
        let height = abs(normal.x * sin(turned.angle) - normal.y * cos(turned.angle))
        XCTAssertEqual(turned.thickness, height, accuracy: 1e-9)
    }

    func testTitleMeasurementSwapsASplitThatTookTheGroundForInk() throws {
        func cover(_ draw: (CGContext) -> Void) throws -> CGImage {
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            draw(context)
            return try XCTUnwrap(context.makeImage())
        }
        // The box covers x 60...120 and rows 30...70, so the padded crop spans rows 25...75.
        let line = TitleLettering.Line(
            text: "II", box: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.4))
        // Two light 6 × 40 letters on a dark band. The light art above and below the band
        // touches the crop's border more than the band does, so the split takes the band for
        // ink, and its padding is as inky as the box.
        let night = try cover { context in
            context.setFillColor(red: 0.1, green: 0.12, blue: 0.3, alpha: 1)
            context.fill(CGRect(x: 0, y: 27, width: 200, height: 46))
            context.setFillColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1)
            context.fill(CGRect(x: 62, y: 30, width: 6, height: 40))
            context.fill(CGRect(x: 112, y: 30, width: 6, height: 40))
        }
        let swapped = try XCTUnwrap(TitleLettering.measure(night, lines: [line], title: "II"))
        // The letters: (6 + 3 + 6) columns for 40 rows, in their own light color.
        XCTAssertEqual(swapped.profile.aspect, 0.375, accuracy: 0.08)
        XCTAssertGreaterThan(
            SpineContrast.lab(swapped.ink).l, SpineContrast.lab(swapped.ground).l)
        // Heavy dark letters also fill most of the crop, but its padding is clear, so the
        // split stands.
        let heavy = try cover { context in
            context.setFillColor(red: 0.1, green: 0.12, blue: 0.3, alpha: 1)
            context.fill(CGRect(x: 61, y: 30, width: 25, height: 40))
            context.fill(CGRect(x: 94, y: 30, width: 25, height: 40))
        }
        let found = try XCTUnwrap(TitleLettering.measure(heavy, lines: [line], title: "II"))
        // (25 + 3 + 25) columns for 40 rows.
        XCTAssertEqual(found.profile.aspect, 1.33, accuracy: 0.1)
        XCTAssertLessThan(SpineContrast.lab(found.ink).l, SpineContrast.lab(found.ground).l)
        // The night cover with its letters crowded into about a quarter of the line passes the
        // share and padding checks, but its swapped letters span too little of the line for any
        // face to set them (`TitleLettering.isPlausible(_:composed:)`), so the split stands.
        let crowded = try cover { context in
            context.setFillColor(red: 0.1, green: 0.12, blue: 0.3, alpha: 1)
            context.fill(CGRect(x: 0, y: 27, width: 200, height: 46))
            context.setFillColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1)
            context.fill(CGRect(x: 62, y: 30, width: 6, height: 40))
            context.fill(CGRect(x: 72, y: 30, width: 6, height: 40))
        }
        let kept = try XCTUnwrap(TitleLettering.measure(crowded, lines: [line], title: "II"))
        XCTAssertLessThan(SpineContrast.lab(kept.ink).l, SpineContrast.lab(kept.ground).l)
    }

    func testUnmeasuredTitlesRankByTheReadingsWidthAndWeight() {
        let sans = SpineFamily.allCases
            .filter { [.humanistSans, .geometricSans, .condensedSans].contains($0.style) }
            .map(\.rawValue)
        func first(_ width: String, _ weight: String? = nil) -> TitleLettering.Match? {
            TitleLettering.rank(sans, width: width, weight: weight, text: "QUIET ORBIT").first
        }
        let narrow = first("extra condensed", "bold")
        XCTAssertEqual(narrow.flatMap { SpineFamily(rawValue: $0.family)?.style }, .condensedSans)
        XCTAssertEqual(narrow?.weight, 700)
        let wide = first("extra wide")
        XCTAssertNotEqual(wide.flatMap { SpineFamily(rawValue: $0.family)?.style }, .condensedSans)
        XCTAssertEqual(wide?.weight, TitleLettering.minimumWeight)
        XCTAssertTrue(
            TitleLettering.rank(sans, width: "very narrow", weight: nil, text: "QUIET ORBIT")
                .isEmpty)
        // A design model's reading ranks a title it found on no line.
        let reading = BookAnalyzer.CoverReading(
            titleText: "QUIET ORBIT", category: "sans serif", weight: "bold",
            width: "extra condensed")
        let book = CloudBook(
            id: 9, title: "Quiet Orbit", author: "Ann Author", coverURL: nil,
            detailCoverURL: nil)
        XCTAssertEqual(
            BookAnalyzer.candidates(
                sans, lettering: nil, reading: reading, book: book, local: false
            )
            .first, narrow)
    }

    func testCapitalsFollowTheModelOrTheMeasuredTitleLine() {
        typealias Reading = BookAnalyzer.CoverReading
        func upper(_ titleCase: String?, _ line: String?, _ observed: String = "") -> Bool {
            BookAnalyzer.uppercase(
                reading: Reading(titleCase: titleCase), titleLine: line, observedText: observed)
        }
        XCTAssertTrue(upper("all capitals", "Quiet Orbit"))
        // An all-caps title line wins over a title-case answer or no answer.
        XCTAssertTrue(upper("title case", "THE LANTERN KEEPER"))
        XCTAssertTrue(upper(nil, "THE LANTERN KEEPER"))
        XCTAssertFalse(upper("title case", "Salt Harbor"))
        XCTAssertFalse(upper("lowercase", "moth"))
        // Without a measured line, the answer stands, and without one either, the OCR text.
        XCTAssertFalse(upper("title case", nil, "THE GLASS ORCHARD · ANN AUTHOR"))
        XCTAssertTrue(
            BookAnalyzer.uppercase(
                reading: nil, titleLine: nil, observedText: "THE GLASS ORCHARD · ANN AUTHOR"))
    }

    func testMeasurementsThatLostLettersRankNothing() throws {
        let atlas = try XCTUnwrap(FontAtlas.shared)
        let font = try XCTUnwrap(atlas.fonts.first { $0.family == "Oswald" && $0.weight == 400 })
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        func measurement(_ text: String, profileOf drawn: String, inkSpan: Double? = nil) throws
            -> TitleLettering.Measurement
        {
            TitleLettering.Measurement(
                text: text, crop: image, profile: try XCTUnwrap(font.compose(drawn)?.profile()),
                ink: ColorValue(hex: "#FFFFFF")!, ground: ColorValue(hex: "#000000")!,
                inkSpan: inkSpan)
        }
        let families = SpineFamily.allCases.map(\.rawValue)
        XCTAssertFalse(
            TitleLettering.rank(families, for: try measurement("METHOD", profileOf: "METHOD"))
                .isEmpty)
        // Only "ME" of a two-color "METHOD" survived the ink mask: narrower than any face.
        XCTAssertTrue(
            TitleLettering.rank(families, for: try measurement("METHOD", profileOf: "ME")).isEmpty)
        // A gray byline OCR read with the title: the letters span a third of the line.
        let byline = try measurement(
            "MAREN HOLT BY CASIMIR ODEGARD", profileOf: "MAREN HOLT", inkSpan: 0.35)
        XCTAssertTrue(TitleLettering.rank(families, for: byline).isEmpty)
        XCTAssertFalse(TitleLettering.hasHairlineStrokes(byline))
        let book = CloudBook(
            id: 9, title: "Maren Holt", author: "Casimir Odegard", coverURL: nil,
            detailCoverURL: nil)
        let unranked = BookAnalyzer.candidates(
            BookAnalyzer.families(for: nil), lettering: byline, book: book, local: false)
        XCTAssertTrue(unranked.allSatisfy { $0.weight == TitleLettering.minimumWeight })
    }
}

extension SpineDesignV1 {
    fileprivate func withFontFamily(_ family: String, postScriptName: String) -> SpineDesignV1 {
        var design = self
        design.fontFamily = family
        design.fontPostScriptName = postScriptName
        return design
    }
}

/// A design model that refuses every request, as Apple's models can refuse a cover.
private struct RefusingModel: LanguageModel {
    typealias Executor = RefusingExecutor

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.vision, .guidedGeneration])
    }

    var executorConfiguration: Int { 0 }
}

private struct RefusingExecutor: LanguageModelExecutor {
    typealias Model = RefusingModel

    init(configuration: Int) {}

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest, model: RefusingModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        throw LanguageModelError.refusal(.init(explanation: "", debugDescription: ""))
    }
}

/// Fails every request as an offline device does, and counts the requests.
final class OfflineURLProtocol: URLProtocol {
    private static let requests = Mutex(0)

    static var count: Int { requests.withLock { $0 } }
    static func reset() { requests.withLock { $0 = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Answers every request to `host` as Gemini's `generateContent` would, with a lettering answer
/// of a plain typeset title, and counts the requests.
private final class ProviderStub: URLProtocol {
    static let host = "provider.localhost"
    nonisolated(unsafe) static var requests = 0
    /// The JSON body of the last request.
    nonisolated(unsafe) static var lastBody: [String: Any]?
    /// The error that each request fails with instead of an answer, when set.
    nonisolated(unsafe) static var failure: URLError.Code?

    static func reset() {
        requests = 0
        lastBody = nil
        failure = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        // URLSession moves a request's body into a stream before a protocol sees it.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        // Each provider's answer shape: Anthropic's content blocks, OpenAI's choices, or
        // Gemini's candidates.
        let answer = #"{"treatment":"plain"}"#
        let path = request.url?.path ?? ""
        let reply: [String: Any] =
            if path.hasSuffix("/messages") {
                ["content": [["type": "text", "text": answer]]]
            } else if path.hasSuffix("/chat/completions") {
                ["choices": [["message": ["content": answer]]]]
            } else {
                ["candidates": [["content": ["parts": [["text": answer]]]]]]
            }
        let body = try! JSONSerialization.data(withJSONObject: reply)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A local store's folder for a generation run at local defaults that reads covers from
/// `CoverStub` and downloads no font.
private struct LocalRun {
    static let accountID = "42"
    let folder: URL
    let ledger: WorkLedger

    /// Saves `books` as a Hardcover snapshot, with `designs`, the reader's `chosen` covers by
    /// book ID, and series `looks`.
    init(
        books: [CloudBook], designs: [SpineDesignV1], chosen: [Int: URL] = [:],
        looks: [SeriesLookV1] = []
    ) throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "bookworms-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ledger = WorkLedger(url: folder.appending(path: "ledger.json"))
        struct Archive: Encodable {
            let version = 1
            let sources: [CloudSourceSnapshot]
        }
        let snapshot = CloudSourceSnapshot(
            source: "hardcover", accountID: Self.accountID, books: books,
            syncedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        try JSONEncoder().encode(Archive(sources: [snapshot]))
            .write(to: folder.appending(path: "library-v1.json"))
        try JSONEncoder()
            .encode(
                Dictionary(uniqueKeysWithValues: designs.map { (Self.recordName($0.bookID), $0) })
            )
            .write(to: folder.appending(path: "spine-designs-v1.json"))
        let choices = chosen.map { bookID, url in
            (
                CloudContract.coverChoiceRecordName(accountID: Self.accountID, bookID: bookID),
                CoverChoiceV1(
                    version: 1, accountID: Self.accountID, bookID: bookID, coverURL: url,
                    editionID: 31, chosenAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
            )
        }
        try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: choices))
            .write(to: folder.appending(path: "cover-choices-v1.json"))
        let named = looks.map {
            (CloudContract.seriesLookRecordName(accountID: Self.accountID, key: $0.key), $0)
        }
        try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: named))
            .write(to: folder.appending(path: "series-looks-v1.json"))
    }

    static func book(
        _ id: Int, title: String = "The Lantern Keeper",
        cover: URL = URL(string: "https://covers.localhost/7.jpg")!, series: Int? = nil,
        position: Double? = nil
    ) -> CloudBook {
        CloudBook(
            id: id, title: title, author: "Mara Quill", coverURL: cover, detailCoverURL: nil,
            seriesID: series, seriesPosition: position)
    }

    static func workHash(_ book: CloudBook) -> String {
        CloudContract.workItemHash(accountID: accountID, book: book)
    }

    static func recordName(_ bookID: Int) -> String {
        CloudContract.designRecordName(accountID: accountID, bookID: bookID)
    }

    /// A design that `model` made of `book` from `cover`, as a test's `designBook` returns it.
    static func design(
        of book: CloudBook, accountID: String, workItemHash: String, cover: CoverImage,
        model: ModelStatus
    ) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: accountID, bookID: book.id, workItemHash: workItemHash,
            coverHash: cover.hash, generatorVersion: CloudContract.generatorVersion,
            generatedAt: Date(), backgroundHex: "#101010", foregroundHex: "#F4EEE2",
            accentHex: "#7A1F1F", typeface: "serif", weight: 700, uppercase: false,
            provenance: model.provenance)
    }

    /// A design of `book` as it is now, in the system typeface, which letters any title.
    static func design(
        for book: CloudBook, coverHash: String, generator: String = CloudContract.generatorVersion,
        provenance: String? = nil, generatedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: accountID, bookID: book.id, workItemHash: workHash(book),
            coverHash: coverHash, generatorVersion: generator,
            generatedAt: generatedAt, backgroundHex: "#101010",
            foregroundHex: "#F4EEE2", accentHex: "#7A1F1F", typeface: "serif", weight: 700,
            uppercase: false, provenance: provenance)
    }

    /// A worker for this folder at `status`'s tier that reads covers from `CoverStub`, reads
    /// their text with `textReader`, and downloads no font, and that falls back to
    /// `fallbackStatus` after the backup's lasting rejection. `designBook`, else `stub`, stands in
    /// for the model's designs. Without either, the analyzer designs at `status`'s tier, or with
    /// `designsLocally` at local defaults, while `status`'s tier still sets how many books the
    /// run designs at once. `store` and `ledger` replace the folder's own, such as for a later
    /// run whose ledger has no checks yet.
    func worker(
        status: ModelStatus = .local, stub: DesignStub? = nil,
        textReader: CoverTextReader = CoverTextReader(), designsLocally: Bool = false,
        fallbackStatus: ModelStatus? = nil, designBook: SpineWorker.DesignBook? = nil,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil, store: (any SpineStore)? = nil,
        ledger: WorkLedger? = nil
    ) -> SpineWorker {
        let offline = URLSessionConfiguration.ephemeral
        offline.protocolClasses = [OfflineURLProtocol.self]
        let analyzer = BookAnalyzer(
            fonts: GoogleFonts(root: folder.appending(path: "fonts"), configuration: offline),
            textReader: textReader)
        let local: SpineWorker.DesignBook = { book, accountID, workItemHash, cover, _ in
            try await analyzer.design(
                book: book, accountID: accountID, workItemHash: workItemHash, cover: cover,
                using: .local)
        }
        return SpineWorker(
            store: store ?? LocalSpineStore(folder: folder), ledger: ledger ?? self.ledger,
            analyzer: analyzer,
            covers: CoverDownloader(protocolClasses: [CoverStub.self]), modelStatus: status,
            fallbackStatus: fallbackStatus,
            designBook: designBook ?? stub?.designBook ?? (designsLocally ? local : nil),
            sleep: sleep ?? { try await Task.sleep(for: $0) })
    }

    /// Runs a worker at local defaults once, which first redesigns the book `redesigning`
    /// names, and returns its final status and the designs it reported saving.
    func run(redesigning: (bookID: Int, remakesLook: Bool)? = nil) async throws -> (
        status: WorkerSnapshot, saved: [SpineDesignV1]
    ) {
        let worker = worker()
        await worker.reconcile(mode: .foreground, redesigning: redesigning)
        let (statuses, saved) = await Self.updates(of: worker)
        guard let status = statuses.last else { throw CompanionError.invalidCloudData }
        return (status, saved)
    }

    /// Runs a worker at `status`'s tier once, with `stub`'s designs, and returns every status
    /// it published and the designs it reported saving.
    func run(status: ModelStatus, stub: DesignStub) async -> (
        statuses: [WorkerSnapshot], saved: [SpineDesignV1]
    ) {
        let worker = worker(status: status, stub: stub)
        await worker.reconcile(mode: .foreground)
        return await Self.updates(of: worker)
    }

    /// Reads a finished run's updates: its statuses through the one that ends the run, and the
    /// designs it reported saving.
    static func updates(of worker: SpineWorker) async -> (
        statuses: [WorkerSnapshot], saved: [SpineDesignV1]
    ) {
        var statuses: [WorkerSnapshot] = []
        var saved: [SpineDesignV1] = []
        for await update in worker.updates {
            if case .saved(let design) = update { saved.append(design) }
            if case .status(let status) = update {
                statuses.append(status)
                if !status.isRunning { break }
            }
        }
        return (statuses, saved)
    }

    /// The store's designs by book ID.
    func stored() throws -> [Int: SpineDesignV1] {
        let designs = try JSONDecoder()
            .decode(
                [String: SpineDesignV1].self,
                from: Data(contentsOf: folder.appending(path: "spine-designs-v1.json")))
        return Dictionary(uniqueKeysWithValues: designs.values.map { ($0.bookID, $0) })
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

/// Serves solid-color PNG covers: three named ones and a numbered one per book (`numbered(_:)`),
/// a PNG too large to decode (`oversizedCover`), a 503 (`unavailableCover`), and a 404 for any
/// other URL.
private final class CoverStub: URLProtocol {
    static let defaultCover = URL(string: "https://covers.example.com/7.png")!
    static let secondCover = URL(string: "https://covers.example.com/8.png")!
    static let chosenCover = URL(string: "https://covers.example.com/7-chosen.png")!
    static let missingCover = URL(string: "https://covers.example.com/7-missing.png")!
    static let unavailableCover = URL(string: "https://covers.example.com/7-unavailable.png")!
    /// A PNG whose header declares 20,000 by 20,000 pixels, over the 100-megapixel limit, and
    /// which holds no pixels.
    static let oversizedCover = URL(string: "https://covers.example.com/7-oversized.png")!
    static let images: [URL: Data] = [
        defaultCover: png(red: 30), secondCover: png(red: 90), chosenCover: png(red: 200),
        oversizedCover: Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
            0x44, 0x52, 0x00, 0x00, 0x4E, 0x20, 0x00, 0x00, 0x4E, 0x20, 0x08, 0x02, 0x00, 0x00,
            0x00, 0x6C, 0x12, 0xD1, 0x6E, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ]),
    ]

    /// A cover of its own for book `number`.
    static func numbered(_ number: Int) -> URL {
        URL(string: "https://covers.example.com/book-\(number).png")!
    }

    private static func image(at url: URL) -> Data? {
        if let image = images[url] { return image }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("book-"), let number = Int(name.dropFirst("book-".count)) else {
            return nil
        }
        return png(red: UInt8(number % 256))
    }

    static func png(red: UInt8) -> Data {
        let side = 32
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = red
            pixels[offset + 1] = 40
            pixels[offset + 2] = 90
        }
        let data = NSMutableData()
        pixels.withUnsafeMutableBytes { buffer in
            guard
                let image = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .makeImage(),
                let destination = CGImageDestinationCreateWithData(
                    data, "public.png" as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return data as Data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let image = Self.image(at: url)
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: url == Self.unavailableCover ? 503 : image == nil ? 404 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let image { client?.urlProtocol(self, didLoad: image) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ModelStatus {
    /// A backup model whose designs a `DesignStub` makes, on an endpoint that no request reaches.
    fileprivate static let backupStub = ModelStatus(
        tier: .backup, isAvailable: true, unavailableReason: nil, coverReader: .designModel,
        designer: SpineDesigner(
            provider: .custom, model: "stub", baseURL: "https://provider.localhost/v1"))
}

/// Counts the designs under way at once, and the most it saw.
private actor Overlap {
    private var current = 0
    private(set) var most = 0

    func begin() {
        current += 1
        most = max(most, current)
    }

    func end() { current -= 1 }
}

/// Records each book's design attempts by tier, and the waits between them.
private actor Attempts {
    private(set) var tiers: [Int: [ModelTier]] = [:]
    private(set) var waits: [Duration] = []

    /// Records an attempt and returns how many the book has made.
    func record(_ bookID: Int, _ tier: ModelTier) -> Int {
        tiers[bookID, default: []].append(tier)
        return tiers[bookID]?.count ?? 0
    }

    func wait(_ duration: Duration) { waits.append(duration) }
}

/// Records the tier of each design a run starts, so a stub can hold a book until other books
/// reach a tier.
private actor TierStarts {
    private var tiers: [ModelTier] = []

    func start(_ tier: ModelTier) { tiers.append(tier) }

    /// Waits until `count` designs have started at `tier`, and throws after 10 seconds.
    func wait(for count: Int, at tier: ModelTier) async throws {
        let start = ContinuousClock.now
        while tiers.count(where: { $0 == tier }) < count {
            guard start.duration(to: .now) < .seconds(10) else {
                throw CompanionError.invalidDesign
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Stands in for the model's designs in a run. Each design waits `delay`, or its book's own
/// delay, then throws its book's failure or returns a design in Georgia Bold, and the stub
/// records which books it designed at once.
private actor DesignStub {
    private let delay: Duration
    private let delays: [Int: Duration]
    private let failures: [Int: any Error]
    /// The books whose designs started, in order.
    private(set) var started: [Int] = []
    /// The books whose designs the run cancelled.
    private(set) var cancelled: [Int] = []
    private(set) var inFlight = Set<Int>()
    /// The books in flight as each design started, the starting book included.
    private(set) var alongside: [Set<Int>] = []

    init(delay: Duration, delays: [Int: Duration] = [:], failures: [Int: any Error] = [:]) {
        self.delay = delay
        self.delays = delays
        self.failures = failures
    }

    /// The most books in flight at once.
    var mostAtOnce: Int { alongside.map(\.count).max() ?? 0 }

    /// The stub as the worker's `designBook`.
    nonisolated var designBook: SpineWorker.DesignBook {
        { book, accountID, workItemHash, cover, model in
            try await self.design(
                book, accountID: accountID, workItemHash: workItemHash, cover: cover, model: model)
        }
    }

    private func design(
        _ book: CloudBook, accountID: String, workItemHash: String, cover: CoverImage,
        model: ModelStatus
    ) async throws -> SpineDesignV1 {
        started.append(book.id)
        inFlight.insert(book.id)
        alongside.append(inFlight)
        defer { inFlight.remove(book.id) }
        do {
            try await Task.sleep(for: delays[book.id] ?? delay)
        } catch {
            cancelled.append(book.id)
            throw error
        }
        if let failure = failures[book.id] { throw failure }
        return SpineDesignV1(
            version: 1, accountID: accountID, bookID: book.id, workItemHash: workItemHash,
            coverHash: cover.hash, generatorVersion: CloudContract.generatorVersion,
            generatedAt: Date(), backgroundHex: "#101010", foregroundHex: "#F4EEE2",
            accentHex: "#7A1F1F", typeface: "serif", weight: 700, uppercase: false,
            fontPostScriptName: "Georgia-Bold", provenance: model.provenance)
    }
}

/// Stands in for Vision's text reads. A read of a cover that `hangs` blocks until `release()`,
/// even after a cancel, as Vision's read can on a locked Mac; any other read finds no text. It
/// counts the reads that started, hung, and were cancelled.
private final class HangingReads: Sendable {
    private let hangs: @Sendable (CGImage) -> Bool
    private let gate = DispatchSemaphore(value: 0)
    private let counts = Mutex((performed: 0, hanging: 0, cancelled: 0, released: false))

    init(hangs: @escaping @Sendable (CGImage) -> Bool = { _ in true }) { self.hangs = hangs }

    var performed: Int { counts.withLock { $0.performed } }
    var hanging: Int { counts.withLock { $0.hanging } }
    var cancelled: Int { counts.withLock { $0.cancelled } }

    /// Lets every hung read return, and later reads return at once.
    func release() {
        let hung = counts.withLock { counts in
            counts.released = true
            return counts.hanging
        }
        for _ in 0..<hung { gate.signal() }
    }

    func reader(timeout: Duration) -> CoverTextReader {
        CoverTextReader(timeout: timeout) { image in
            CoverTextReader.Read(
                perform: {
                    let hangs = self.counts.withLock { counts in
                        counts.performed += 1
                        let hangs = !counts.released && self.hangs(image)
                        if hangs { counts.hanging += 1 }
                        return hangs
                    }
                    if hangs { self.gate.wait() }
                    return []
                },
                cancel: { self.counts.withLock { $0.cancelled += 1 } })
        }
    }

    /// The red value of `image`'s pixels, which tells `CoverStub`'s numbered covers apart.
    static func red(of image: CGImage) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel[0]
    }
}

/// Answers each request after a short wait, as a slow network does, so concurrent callers
/// overlap: a cover, a Google Fonts catalog of fictional families, one family's file list, and
/// a file that is not a font. It counts the requests by kind.
private final class SlowStub: URLProtocol {
    static let cover = URL(string: "https://covers.example.com/slow.png")!
    static let family = "Stub Serif"
    private static let requests = Mutex<[String: Int]>([:])

    static func count(_ kind: String) -> Int { requests.withLock { $0[kind] ?? 0 } }
    static func reset() { requests.withLock { $0 = [:] } }

    private static func kind(of url: URL) -> String {
        switch (url.host(), url.path()) {
        case ("covers.example.com", _): "cover"
        case ("fonts.google.com", "/metadata/fonts"): "catalog"
        case ("fonts.google.com", "/download/list"): "manifest"
        default: "file"
        }
    }

    private static func body(for kind: String) -> Data {
        switch kind {
        case "cover": return CoverStub.png(red: 120)
        case "catalog":
            let families = [family] + (1...100).map { "Stub Family \($0)" }
            return try! JSONSerialization.data(withJSONObject: [
                "familyMetadataList": families.map { ["family": $0] }
            ])
        case "manifest":
            return try! JSONSerialization.data(withJSONObject: [
                "manifest": [
                    "files": [["filename": "OFL.txt", "contents": "SIL OPEN FONT LICENSE"]],
                    "fileRefs": [
                        [
                            "filename": "static/StubSerif-Regular.ttf",
                            "url": "https://fonts.gstatic.com/stub-serif.ttf",
                        ]
                    ],
                ]
            ])
        default: return Data("not a font".utf8)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return }
        let kind = Self.kind(of: url)
        Self.requests.withLock { $0[kind, default: 0] += 1 }
        Thread.sleep(forTimeInterval: 0.3)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body(for: kind))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
