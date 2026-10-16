import CloudKit
import CoreText
import Foundation
import FoundationModels
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

        custom.rememberRejection("Custom: Unknown model.", sentKey: custom.provider.key.read())
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

    /// A weekly recheck keeps a current design without downloading its cover. Both books' covers
    /// use a host that `CoverURLPolicy` refuses, so a download attempt fails the book without a
    /// request, as it does for the book that has no design.
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
            recordName: recordName, workItemHash: workHash, coverHash: coverHash,
            now: Date().addingTimeInterval(-WorkLedger.recheckInterval - 60))
        let due = await ledger.needsCheck(recordName: recordName, workItemHash: workHash)
        XCTAssertTrue(due)

        let worker = SpineWorker(store: LocalSpineStore(folder: folder), ledger: ledger)
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
        XCTAssertEqual(local.designerName, "Local defaults")
        XCTAssertNil(SpineWorker.modelStop(local, mode: .background))
        let watched = await BookAnalyzer().status(of: .local, designer: .appleOnly)
        XCTAssertTrue(watched.isAvailable, "Local defaults never stop a run")
        XCTAssertNil(SpineWorker.modelStop(watched, mode: .background))

        XCTAssertNotNil(SpineDesigner.appleOnly.problem, "No backup model is never set up")
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
            .designerName, "Anthropic backup model")
        XCTAssertEqual(
            SpineWorker.fallbackMessage(
                rejection: "Anthropic: invalid x-api-key",
                next: ModelStatus(
                    tier: .onDevice, isAvailable: true, unavailableReason: nil,
                    coverReader: .onDevice)),
            "Anthropic: invalid x-api-key. Until you change the backup model, Bookworms uses Apple's on-device model. Generate now tries the backup model again."
        )
        XCTAssertEqual(
            SpineWorker.fallbackMessage(rejection: "Unknown model.", next: .local),
            "Unknown model. Until you change the backup model, Bookworms uses local defaults. Generate now tries the backup model again."
        )
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
            cover: CoverImage(image: image, hash: hash), using: .local)
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
        // A model's families keep their order at regular weight.
        let model = try candidates(cyrillic, local: false)
        XCTAssertEqual(
            Set(model.map(\.family)), Set(BookAnalyzer.families(for: nil, playful: false)))
        XCTAssertTrue(model.allSatisfy { $0.weight == 400 })
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

        // Without a recognized genre, the measurements rank every family but rounded faces,
        // which need a model to judge the book playful.
        let unranked = styles(["Adventure"])
        XCTAssertFalse(unranked.contains(.rounded))
        XCTAssertTrue(unranked.isSuperset(of: [.blackletter, .script, .bookSerif, .monospace]))
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
            .first, "Monoton")
        // Rounded faces need a playful book.
        let serious = BookAnalyzer.families(
            for: .init(handDrawn: false, serifs: false, treatment: "plain"), playful: false)
        XCTAssertFalse(serious.contains { SpineFamily(rawValue: $0)?.style == .rounded })

        let script = BookAnalyzer.families(
            for: .init(handDrawn: true, serifs: true, treatment: "plain"), playful: true)
        XCTAssertTrue(script.contains("Caveat"))
        let everything = BookAnalyzer.families(for: nil, playful: true)
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
            ("Dancing Script", "DancingScript-Bold", "Kalam"),
            ("Great Vibes", "GreatVibes-Regular", "Caveat"),
            ("Pacifico", nil, "Permanent Marker"),
            // A PostScript name alone, as an Apple TV look saves it, shows its family's stand-in.
            (nil, "DancingScript-Bold", "Kalam"),
            (nil, "GreatVibes-Regular", "Caveat"),
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
