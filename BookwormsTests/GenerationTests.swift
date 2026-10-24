import CloudKit
import CoreText
import Foundation
import FoundationModels
import ImageIO
import XCTest

@testable import Bookworms

/// Covers generation's decisions: error handling, quota stops, the lettering answers' font
/// choices, title measurement, and a recheck against a local store. No test calls a model, the
/// network, or iCloud.
final class GenerationTests: XCTestCase {
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
        defer { URLProtocol.unregisterClass(ProviderStub.self) }
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

    /// A backup model with a thinking level declares reasoning, so the cover-lettering request
    /// asks for a light level and reaches the provider, which receives the reader's level in its
    /// own terms. Stubs answer for each provider, so no request leaves the device.
    func testThinkingBackupModelsSendTheReadersLevel() async throws {
        ProviderStub.reset()
        URLProtocol.registerClass(ProviderStub.self)
        defer { URLProtocol.unregisterClass(ProviderStub.self) }
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
            case .modelBusy = failure(503)
        else { return XCTFail("Provider errors map to the wrong dispositions") }
        // An account without credit fails every book, so the run moves to the next tier.
        guard case .providerRejected = failure(402),
            case .providerRejected = failure(429, code: "insufficient_quota")
        else { return XCTFail("An account without credit should move the run to the next tier") }
        // A rejection of one request, such as a content policy's for one crop, or an empty
        // answer fails only the book. A 400 keeps its message, so the worker can tell when
        // it repeats.
        guard case .providerRefused("OpenAI: x") = failure(400),
            case .providerRefused("OpenAI: x") = failure(400, code: "invalid_request_error"),
            case .invalidDesign = failure(422),
            case .invalidDesign = BookAnalyzer.modelFailure(
                ProviderError(provider: .openAI, status: nil, retryAfter: nil, message: "x"))
        else { return XCTFail("A rejection of one request should fail only the book") }
        XCTAssertEqual(SpineWorker.disposition(of: CompanionError.providerRefused("x")), .skipBook)
    }

    func testTheSameRefusalOfThreeBooksInARowIsLasting() {
        var streak = SpineWorker.RefusalStreak()
        XCTAssertFalse(streak.isLasting(after: "Anthropic: Your credit balance is too low."))
        XCTAssertFalse(streak.isLasting(after: "Anthropic: Your credit balance is too low."))
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
        XCTAssertNil(custom.rejection, "Changed settings forget the rejection")
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
            LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "")),
            LanguageModelError.timeout(.init(debugDescription: "")),
        ]
        for error in busy {
            guard case .modelBusy(nil) = BookAnalyzer.modelFailure(error) else {
                return XCTFail("\(error) should mean the model is busy")
            }
        }
        // A rate limit's reset date becomes the retry date instead of the default delay.
        let limited = LanguageModelError.rateLimited(.init(resetDate: reset, debugDescription: ""))
        guard case .modelBusy(reset) = BookAnalyzer.modelFailure(limited) else {
            return XCTFail("A rate limit should keep its reset date")
        }

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
            .skipBookAndStop)
        // A slow cover host and a failing network look alike: the book backs off and the run
        // stops, so the next run moves past the book.
        for code in [URLError.Code.timedOut, .networkConnectionLost] {
            XCTAssertEqual(
                SpineWorker.disposition(of: URLError(code), now: now), .skipBookAndStop, "\(code)")
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
            workItemHash: hash, coverHash: hash, tier: .onDevice)
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
            coverHash: String(repeating: "d", count: 64),
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
    /// saved design's own tier is not saved, and the run designs the book at its tier instead.
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
                coverHash: source.coverHash, tier: .local)
            let (status, saved) = try await run.run()
            XCTAssertEqual(status.failed, 0)
            XCTAssertEqual(status.completed, 1)
            XCTAssertEqual(status.designed, sourceAwaitsFont ? 1 : 0)
            XCTAssertEqual(status.fromSeries, sourceAwaitsFont ? 0 : 1)
            XCTAssertEqual(saved.count, 1)
            let stored = try XCTUnwrap(try run.stored()[8])
            XCTAssertEqual(stored, saved.first)
            if sourceAwaitsFont {
                XCTAssertFalse(stored.isSeriesReuse, "The run designed the book itself")
            } else {
                XCTAssertEqual(stored.provenance, "series-reuse:7 model:local")
            }
            XCTAssertEqual(try run.stored()[7], source)
        }
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
        blind.unavailableReason = "Private Cloud Compute can't read covers on this iPhone."
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
        XCTAssertEqual(skipped.backupUnavailableReason, "Enter the endpoint's base URL.")
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
            "Your OpenAI-compatible endpoint", "A custom endpoint may need no key")
        XCTAssertEqual(
            SpineWorker.fallbackMessage(
                rejection: "Anthropic: invalid x-api-key",
                next: ModelStatus(
                    tier: .onDevice, isAvailable: true, unavailableReason: nil,
                    coverReader: .onDevice)),
            "Anthropic: invalid x-api-key. Until you change the model settings, Bookworms uses Apple's on-device model. Generate now tries your model again."
        )
        XCTAssertEqual(
            SpineWorker.fallbackMessage(rejection: "Unknown model.", next: .local),
            "Unknown model. Until you change the model settings, Bookworms uses default styling. Generate now tries your model again."
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
            "Google Gemini (gemini-3.8-flash) made this spine, so it stays. This \(ThisDevice.name) uses default styling, which never replaces a better model's design."
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
            SpineWorker.betterDesign(than: tier, saved: saved, remadeLook: look, newCover: false)
        }
        XCTAssertNil(better(than: .backup, saved: gemini), "The run's own tier gives way")
        XCTAssertEqual(better(than: .onDevice, saved: gemini), gemini)
        XCTAssertEqual(better(than: .local, saved: onDevice, look: gemini), onDevice)
        XCTAssertEqual(better(than: .onDevice, saved: onDevice, look: gemini), gemini)
        XCTAssertNil(better(than: .onDevice, saved: nil))
        XCTAssertNil(
            SpineWorker.betterDesign(
                than: .local, saved: gemini, remadeLook: gemini, newCover: true),
            "A cover the reader chose since gives way at any tier")
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
                text: text, crop: image, profile: try XCTUnwrap(font.compose("KINDRED")?.profile()),
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
                : BookAnalyzer.families(for: nil, playful: false)
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
            Set(model.map(\.family)), Set(BookAnalyzer.families(for: nil, playful: false)))
        XCTAssertTrue(model.allSatisfy { $0.weight == TitleLettering.minimumWeight })
        // A Latin title line ranks the families it was given.
        XCTAssertTrue(styles(try candidates("KINDRED")).count > 1)
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
        XCTAssertEqual(styles(["Young Adult"]), [.rounded])
        XCTAssertEqual(styles(["Humor"]), [.monospace, .decorative])
        XCTAssertTrue(
            BookAnalyzer.localFamilies(genres: ["Satire"], measured: true)
                .contains(SpineFamily.specialElite.rawValue))
        // The first genre that names a recognized one decides, in Hardcover's order.
        XCTAssertEqual(styles(["Adventure", "Mystery", "Fantasy"]), [.condensedSans])
        XCTAssertEqual(styles(["fantasy", "Science Fiction"]), [.classicalCaps, .bookSerif])

        // Without a recognized genre, the measurements rank the serif and sans families but
        // rounded faces, which need a model to judge the book playful, and without a reading,
        // no themed faces.
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

    func testLetteringAnswersNarrowTheFamiliesAndNeverOfferSlantedFaces() {
        func styles(_ reading: BookAnalyzer.LetteringReading?) -> Set<SpineFontStyle> {
            Set(
                BookAnalyzer.families(for: reading, playful: true)
                    .compactMap { SpineFamily(rawValue: $0)?.style })
        }
        XCTAssertEqual(
            styles(.init(handDrawn: false, serifs: true, treatment: "plain")),
            [.bookSerif, .didone, .classicalCaps, .slab])
        XCTAssertEqual(
            styles(.init(handDrawn: false, serifs: false, treatment: "plain")),
            [.humanistSans, .geometricSans, .condensedSans, .rounded])
        // Textured art often draws this answer for plain lettering, so it narrows nothing extra.
        XCTAssertEqual(
            styles(.init(handDrawn: false, serifs: true, treatment: "dripping or distressed")),
            styles(.init(handDrawn: false, serifs: true, treatment: "plain")))
        XCTAssertEqual(
            styles(.init(handDrawn: false, serifs: true, treatment: "gothic broken strokes")),
            [.blackletter])
        XCTAssertEqual(
            BookAnalyzer.families(
                for: .init(
                    handDrawn: false, serifs: false, treatment: "outlined or multi-line neon"),
                playful: false
            )
            .first, "Bungee")
        // Rounded faces need a playful book.
        let serious = BookAnalyzer.families(
            for: .init(handDrawn: false, serifs: false, treatment: "plain"), playful: false)
        XCTAssertFalse(serious.contains { SpineFamily(rawValue: $0)?.style == .rounded })

        // A playful book's hand-drawn title gets an upright hand-drawn or rounded face. Any
        // other book's gets the typeset faces its serifs call for.
        let handDrawn = BookAnalyzer.LetteringReading(
            handDrawn: true, serifs: true, treatment: "plain")
        let script = BookAnalyzer.families(for: handDrawn, playful: true)
        XCTAssertTrue(script.contains("Patrick Hand"))
        XCTAssertEqual(
            Set(script.compactMap { SpineFamily(rawValue: $0)?.style }), [.script, .rounded])
        XCTAssertEqual(
            BookAnalyzer.families(for: handDrawn, playful: false),
            BookAnalyzer.families(
                for: .init(handDrawn: false, serifs: true, treatment: "plain"), playful: false))
        XCTAssertFalse(
            BookAnalyzer.families(for: nil, playful: false)
                .contains { SpineFamily(rawValue: $0)?.style == .script })
        let everything = BookAnalyzer.families(for: nil, playful: true)
        let unchosen =
            ["Dancing Script", "Pacifico", "Great Vibes", "Lobster", "Bangers"]
            + SpineFamily.neverGenerated.map(\.rawValue)
        for slanted in unchosen {
            XCTAssertFalse(script.contains(slanted) || everything.contains(slanted), slanted)
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
        let offered = BookAnalyzer.families(for: nil, playful: true)
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

        // A loaded face with the italic trait is passed over for an upright one, whatever the
        // saved PostScript name asks for.
        func face(_ name: String) throws -> CTFontDescriptor {
            let font = CTFontCreateWithName(name as CFString, 24, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name)
            return CTFontCopyFontDescriptor(font)
        }
        let italic = try face("Georgia-Italic")
        let upright = try face("Georgia")
        XCTAssertFalse(GoogleFonts.isUpright(italic))
        XCTAssertTrue(GoogleFonts.isUpright(upright))
        let chosen = try XCTUnwrap(
            GoogleFonts.uprightDescriptor(
                preferring: ["Georgia-Italic", nil], in: [italic, upright]))
        XCTAssertEqual(GoogleFonts.postScriptName(of: chosen), "Georgia")
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
        XCTAssertEqual(Set(atlas.fonts.map(\.family)).count, SpineFamily.allCases.count)
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        // Lettering composed from the atlas itself must rank its own family first.
        for family in ["Oswald", "EB Garamond", "Josefin Sans"] {
            let font = try XCTUnwrap(atlas.fonts.first { $0.family == family && $0.weight == 400 })
            let profile = try XCTUnwrap(font.compose("KINDRED")?.profile())
            let measurement = TitleLettering.Measurement(
                text: "KINDRED", crop: image, profile: profile,
                ink: ColorValue(hex: "#FFFFFF")!, ground: ColorValue(hex: "#000000")!)
            let ranked = TitleLettering.rank(SpineFamily.allCases.map(\.rawValue), for: measurement)
            XCTAssertEqual(ranked.first?.family, family)
        }
    }

    func testGenresDecideWhetherABookIsPlayful() {
        XCTAssertEqual(BookAnalyzer.genreTone(["Fantasy", "Humour", "Satire"]), true)
        XCTAssertEqual(BookAnalyzer.genreTone(["Romance", "Romantic Comedy"]), true)
        // A serious genre wins over humor beside it.
        XCTAssertEqual(BookAnalyzer.genreTone(["Literary Fiction", "Classics", "Humor"]), false)
        XCTAssertEqual(BookAnalyzer.genreTone(["History", "political science"]), false)
        XCTAssertEqual(BookAnalyzer.genreTone(["Biography & Autobiography"]), false)
        XCTAssertEqual(BookAnalyzer.genreTone(["Science", "Health"]), false)
        XCTAssertEqual(BookAnalyzer.genreTone(["Science Fiction", "Politique"]), false)
        // Children's books are playful unless a serious genre says otherwise: reader tags such
        // as "Juvenile Fiction" also land on serious books.
        XCTAssertEqual(BookAnalyzer.genreTone(["Middle Grade", "Fantasy", "Animals"]), true)
        XCTAssertEqual(BookAnalyzer.genreTone(["Picture Books"]), true)
        XCTAssertEqual(BookAnalyzer.genreTone(["Juvenile Nonfiction", "Young Adult"]), false)
        let dispossessed = [
            "Science Fiction", "Fantasy", "Anarchism", "Classique", "Politique", "Philosophie",
            "Juvenile Fiction", "Literary",
        ]
        XCTAssertEqual(BookAnalyzer.genreTone(dispossessed), false)
        // Without a telling genre, the on-device model decides.
        XCTAssertNil(BookAnalyzer.genreTone(["Science Fiction", "Space Opera"]))
        XCTAssertNil(BookAnalyzer.genreTone(["Comics", "Dystopian", "Graphic Novels"]))
        XCTAssertNil(BookAnalyzer.genreTone(nil))
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
                text: "KINDRED", crop: image,
                profile: try XCTUnwrap(font.compose("KINDRED")?.profile()),
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
            id: 9, title: "Kindred", author: "An Author", coverURL: nil, detailCoverURL: nil)
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
                text: "KINDRED", crop: image, profile: profile,
                ink: ColorValue(hex: "#FFFFFF")!, ground: ColorValue(hex: "#000000")!)
        }
        func composed(_ family: String, weight: Int = 400) throws -> TitleLettering.Measurement {
            let font = try XCTUnwrap(
                atlas.fonts.first { $0.family == family && $0.weight == weight })
            return measurement(try XCTUnwrap(font.compose("KINDRED")?.profile()))
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
        // The model's outline answer stands only for such lettering.
        let neon = BookAnalyzer.LetteringReading(
            handDrawn: false, serifs: false, treatment: "outlined or multi-line neon")
        XCTAssertEqual(BookAnalyzer.checked(neon, against: outlined), neon)
        XCTAssertEqual(
            BookAnalyzer.checked(neon, against: try composed("Oswald"))?.treatment, "plain")
        XCTAssertNil(BookAnalyzer.checked(nil, against: outlined))
        // A serious book gets no themed face, whatever its lettering.
        XCTAssertEqual(
            BookAnalyzer.checked(neon, against: outlined, genres: ["History", "Classics"])?
                .treatment, "plain")
        let gothic = BookAnalyzer.LetteringReading(
            handDrawn: false, serifs: true, treatment: "gothic broken strokes")
        XCTAssertEqual(
            BookAnalyzer.checked(gothic, against: nil, genres: ["political science"])?.treatment,
            "plain")
        XCTAssertEqual(
            BookAnalyzer.checked(gothic, against: nil, genres: ["Fantasy"])?.treatment,
            "gothic broken strokes")
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
            "STEVE JOBS BY WALTER ISAACSON", profileOf: "STEVE JOBS", inkSpan: 0.35)
        XCTAssertTrue(TitleLettering.rank(families, for: byline).isEmpty)
        XCTAssertFalse(TitleLettering.hasHairlineStrokes(byline))
        let book = CloudBook(
            id: 9, title: "Steve Jobs", author: "Walter Isaacson", coverURL: nil,
            detailCoverURL: nil)
        let unranked = BookAnalyzer.candidates(
            BookAnalyzer.families(for: nil, playful: false), lettering: byline, book: book,
            local: false)
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

/// Fails every request as an offline device does.
private final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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

    static func reset() {
        requests = 0
        lastBody = nil
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

    /// Saves `books` as a Hardcover snapshot, with `designs` and the reader's `chosen` covers by
    /// book ID.
    init(books: [CloudBook], designs: [SpineDesignV1], chosen: [Int: URL] = [:]) throws {
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

    /// A design of `book` as it is now, in the system typeface, which letters any title.
    static func design(
        for book: CloudBook, coverHash: String, generator: String = CloudContract.generatorVersion,
        provenance: String? = nil
    ) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: accountID, bookID: book.id, workItemHash: workHash(book),
            coverHash: coverHash, generatorVersion: generator,
            generatedAt: Date(timeIntervalSince1970: 1_000_000), backgroundHex: "#101010",
            foregroundHex: "#F4EEE2", accentHex: "#7A1F1F", typeface: "serif", weight: 700,
            uppercase: false, provenance: provenance)
    }

    /// Runs a worker at local defaults once, which first redesigns the book `redesigning`
    /// names, and returns its final status and the designs it reported saving.
    func run(redesigning: (bookID: Int, remakesLook: Bool)? = nil) async throws -> (
        status: WorkerSnapshot, saved: [SpineDesignV1]
    ) {
        let offline = URLSessionConfiguration.ephemeral
        offline.protocolClasses = [OfflineURLProtocol.self]
        let worker = SpineWorker(
            store: LocalSpineStore(folder: folder), ledger: ledger,
            analyzer: BookAnalyzer(
                fonts: GoogleFonts(root: folder.appending(path: "fonts"), configuration: offline)),
            covers: CoverDownloader(protocolClasses: [CoverStub.self]), modelStatus: .local)
        await worker.reconcile(mode: .foreground, redesigning: redesigning)
        var saved: [SpineDesignV1] = []
        for await update in worker.updates {
            if case .saved(let design) = update { saved.append(design) }
            if case .status(let status) = update, !status.isRunning { return (status, saved) }
        }
        throw CompanionError.invalidCloudData
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

/// Serves two solid-color PNG covers, and a 404 for any other URL.
private final class CoverStub: URLProtocol {
    static let defaultCover = URL(string: "https://covers.example.com/7.png")!
    static let secondCover = URL(string: "https://covers.example.com/8.png")!
    static let chosenCover = URL(string: "https://covers.example.com/7-chosen.png")!
    static let missingCover = URL(string: "https://covers.example.com/7-missing.png")!
    static let images: [URL: Data] = [
        defaultCover: png(red: 30), secondCover: png(red: 90), chosenCover: png(red: 200),
    ]

    private static func png(red: UInt8) -> Data {
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
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: Self.images[url] == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = Self.images[url] { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
