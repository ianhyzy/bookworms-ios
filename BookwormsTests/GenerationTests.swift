import CloudKit
import Foundation
import FoundationModels
import XCTest

@testable import Bookworms

/// Covers generation's pure decisions: error handling, quota stops, the lettering answers'
/// font choices, and title measurement. No test calls a model, the network, or iCloud.
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

    func testProviderErrorsStopTheRunWhenEveryBookWouldFail() {
        func failure(_ status: Int) -> CompanionError? {
            BookAnalyzer.modelFailure(
                ProviderError(provider: .anthropic, status: status, retryAfter: nil, message: "x"))
        }
        guard case .providerRejected = failure(401), case .providerRejected = failure(404),
            case .modelBusy = failure(429), case .modelBusy = failure(503)
        else { return XCTFail("Provider errors map to the wrong dispositions") }
        guard
            case .invalidDesign = BookAnalyzer.modelFailure(
                ProviderError(provider: .openAI, status: nil, retryAfter: nil, message: "x"))
        else { return XCTFail("An empty answer fails only the book") }
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
            LanguageModelError.unsupportedCapability(
                .init(capability: .vision, debugDescription: "")),
            LanguageModelError.unsupportedGenerationGuide(
                .init(schemaName: nil, debugDescription: "")),
        ]
        for error in perBook {
            guard case .invalidDesign = BookAnalyzer.modelFailure(error) else {
                return XCTFail("\(error) should fail only the book")
            }
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

    func testBackgroundRunsLeaveQuotaHeadroomAndForegroundRunsUseIt() {
        func status(
            available: Bool = true, reader: ModelStatus.CoverReader = .designModel,
            quota: ModelStatus.Quota
        ) -> ModelStatus {
            ModelStatus(
                isAvailable: available, unavailableReason: available ? nil : "Unavailable",
                coverReader: reader, quota: quota, quotaResetDate: now,
                limitIncreaseSuggestion: nil)
        }
        XCTAssertNil(SpineWorker.modelStop(status(quota: .belowLimit), mode: .background))
        XCTAssertNil(SpineWorker.modelStop(status(quota: .approachingLimit), mode: .foreground))
        XCTAssertEqual(
            SpineWorker.modelStop(status(quota: .approachingLimit), mode: .background)?
                .retryAfter, now)
        XCTAssertEqual(
            SpineWorker.modelStop(status(quota: .limitReached), mode: .foreground)?.retryAfter,
            now)
        // An unavailable model waits a day instead of downloading the library every charge.
        let dayLater = now.addingTimeInterval(SpineWorker.lastingStopDelay)
        XCTAssertEqual(
            SpineWorker.modelStop(
                status(available: false, quota: .belowLimit), mode: .background, now: now)?
                .retryAfter, dayLater)
        XCTAssertEqual(
            SpineWorker.modelStop(
                status(reader: .none, quota: .belowLimit), mode: .foreground, now: now)?
                .retryAfter, dayLater)
        XCTAssertNil(
            SpineWorker.modelStop(status(reader: .onDevice, quota: .belowLimit), mode: .foreground))
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

    func testLetteringAnswersNarrowTheFamiliesAndNeverOfferSlantedFaces() {
        func styles(_ reading: BookAnalyzer.LetteringReading?) -> Set<SpineFontStyle> {
            Set(BookAnalyzer.families(for: reading).compactMap { SpineFamily(rawValue: $0)?.style })
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
                    handDrawn: false, serifs: false, treatment: "outlined or multi-line neon")
            )
            .first, "Monoton")

        let script = BookAnalyzer.families(
            for: .init(handDrawn: true, serifs: true, treatment: "plain"))
        XCTAssertTrue(script.contains("Caveat"))
        let everything = BookAnalyzer.families(for: nil)
        for slanted in ["Dancing Script", "Pacifico", "Great Vibes", "Lobster", "Bangers"] {
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
        let measured = try XCTUnwrap(
            Mask.lettering(Mask(width: 100, height: 60, pixels: pixels)))
        // The gap collapses to a twelfth of the 40-pixel band: (10 + 3 + 10) / 40.
        XCTAssertEqual(measured.aspect, 23.0 / 40.0, accuracy: 0.001)
        XCTAssertEqual(measured.strokeSpread, 0, accuracy: 0.001)
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

    func testNarrowLetteringRanksCondensedFamiliesFirst() throws {
        let catalog = try XCTUnwrap(FontDescriptors.shared)
        XCTAssertEqual(catalog.fonts.count, SpineFamily.allCases.count)
        let image = try XCTUnwrap(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        func best(aspect: Double) -> SpineFontStyle? {
            let measurement = TitleLettering.Measurement(
                text: "KINDRED", crop: image, aspect: aspect, strokeSpread: 0.7,
                ink: ColorValue(hex: "#FFFFFF")!, ground: ColorValue(hex: "#000000")!)
            let sans = BookAnalyzer.families(
                for: .init(handDrawn: false, serifs: false, treatment: "plain"))
            return TitleLettering.rank(sans, for: measurement).first
                .flatMap { SpineFamily(rawValue: $0.family)?.style }
        }
        XCTAssertEqual(best(aspect: 2.6), .condensedSans)
        XCTAssertNotEqual(best(aspect: 7), .condensedSans)
    }
}
