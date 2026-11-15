import XCTest

@testable import Bookworms

/// Covers what a run reports to its continued-processing task while a book is in flight
/// (`TaskProgress`), and the limit on how long a design waits for a model's answer
/// (`BookAnalyzer.answer(within:tries:_:)`).
final class TaskProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(
        completed: Int, queue: Int, designing: Bool = true, book: Int = 7, startedAt: Date? = nil
    ) -> WorkerSnapshot {
        WorkerSnapshot(
            isRunning: true,
            phase: designing ? WorkerSnapshot.designingPhase : "Checking the library",
            queue: queue, completed: completed,
            currentBook: CloudBook(
                id: book, title: "The Glass Orchard", author: "Mara Quill", coverURL: nil,
                detailCoverURL: nil),
            startedAt: startedAt ?? now)
    }

    private func units(_ fraction: Double) -> Int64 { Int64(fraction * Double(TaskProgress.total)) }

    func testABookInFlightAdvancesWithTimeAndStaysBelowItsFinish() {
        var progress = TaskProgress()
        let waiting = run(completed: 2, queue: 8)
        var last = progress.units(for: waiting, now: now)
        XCTAssertEqual(last, units(0.2))
        // Every tick moves the count, through a book far slower than any limit allows.
        for tick in 1...240 {
            let next = progress.units(for: waiting, now: now.addingTimeInterval(5 * Double(tick)))
            XCTAssertGreaterThan(next, last, "tick \(tick)")
            last = next
        }
        // However long the book takes, the estimate stays below what its finish reaches.
        let finished = run(completed: 3, queue: 7)
        XCTAssertLessThan(
            progress.units(for: waiting, now: now.addingTimeInterval(86_400)),
            units(finished.fraction))
        // The next book's estimate starts from the bar, not from the last book's time.
        let later = now.addingTimeInterval(86_400)
        XCTAssertEqual(progress.units(for: finished, now: later), units(finished.fraction))
    }

    func testOnlyABookInFlightAdvancesAndItsTimeCountsFromItsStart() {
        var progress = TaskProgress()
        // While a pass checks the library, time alone moves nothing, even with books queued.
        let checking = run(completed: 2, queue: 8, designing: false)
        XCTAssertEqual(progress.units(for: checking, now: now), units(0.2))
        XCTAssertEqual(progress.units(for: checking, now: now.addingTimeInterval(120)), units(0.2))
        // The book that then starts counts its own time, not the check's.
        let started = now.addingTimeInterval(120)
        XCTAssertEqual(progress.units(for: run(completed: 2, queue: 8), now: started), units(0.2))
        // A requeued book hands over to another without a finish, and the time starts again.
        let advanced = progress.units(
            for: run(completed: 2, queue: 8), now: started.addingTimeInterval(60))
        XCTAssertGreaterThan(advanced, units(0.2))
        XCTAssertEqual(
            progress.units(
                for: run(completed: 2, queue: 8, book: 8), now: started.addingTimeInterval(65)),
            advanced, "The count holds until the new book's own estimate passes it")
    }

    func testProgressHoldsWithinARunAndStartsAgainForAnotherRun() {
        var progress = TaskProgress()
        let waiting = run(completed: 2, queue: 8)
        _ = progress.units(for: waiting, now: now)
        let advanced = progress.units(for: waiting, now: now.addingTimeInterval(120))
        // A later pass that finds more books lowers the bar's share for each, and the count holds.
        var more = run(completed: 2, queue: 80, designing: false)
        more.passStart = (waiting.fraction, 2)
        XCTAssertEqual(progress.units(for: more, now: now.addingTimeInterval(125)), advanced)
        // A run that waited behind another one starts the count again from its own bar.
        let own = run(completed: 0, queue: 10, startedAt: now.addingTimeInterval(130))
        XCTAssertEqual(progress.units(for: own, now: now.addingTimeInterval(130)), 0)
    }

    func testAnAnswerPastItsLimitTimesOutAndAPromptOneReturns() async throws {
        let prompt = try await BookAnalyzer.answer(within: .seconds(30)) { 7 }
        XCTAssertEqual(prompt, 7)
        let unlimited = try await BookAnalyzer.answer(within: nil) { "kept" }
        XCTAssertEqual(unlimited, "kept")
        // An optional answer of `nil`, such as a refused crop, is an answer, not a timeout.
        let refused: Int? = try await BookAnalyzer.answer(within: .seconds(30)) { nil }
        XCTAssertNil(refused)
        do {
            _ = try await BookAnalyzer.answer(within: .milliseconds(20)) {
                try await Task.sleep(for: .seconds(30))
                return 7
            }
            XCTFail("A request past its limit must throw")
        } catch CompanionError.modelTimedOut {}
    }

    /// A request that ignores its cancellation, as one that got no answer may, holds up neither
    /// the limit nor a stopped run.
    func testALimitAndAStopDoNotWaitForARequestThatIgnoresCancellation() async throws {
        let deaf: @Sendable () async throws -> Int = {
            await Task.detached { try? await Task.sleep(for: .seconds(20)) }.value
            return 7
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await BookAnalyzer.answer(within: .milliseconds(20), deaf)
            XCTFail("A request past its limit must throw")
        } catch CompanionError.modelTimedOut {}
        let run = Task { try await BookAnalyzer.answer(within: .seconds(60), deaf) }
        try await Task.sleep(for: .milliseconds(20))
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("A stopped run's request must throw")
        } catch is CancellationError {}
        let unlimited = Task { try await BookAnalyzer.answer(within: nil, deaf) }
        try await Task.sleep(for: .milliseconds(20))
        unlimited.cancel()
        do {
            _ = try await unlimited.value
            XCTFail("A stopped run's request must throw")
        } catch is CancellationError {}
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(5))
    }

    func testAnEndedSnapshotKeepsTheRunsCounts() {
        var running = run(completed: 12, queue: 30)
        running.designed = 9
        XCTAssertNotNil(running.designingBook)
        let date = now.addingTimeInterval(60)
        let own = running.ended(at: date)
        let stopped = running.ended(at: date, phase: WorkerSnapshot.stoppedPhase)
        XCTAssertEqual(own.phase, WorkerSnapshot.designingPhase)
        XCTAssertEqual(stopped.phase, WorkerSnapshot.stoppedPhase)
        for ended in [own, stopped] {
            XCTAssertFalse(ended.isRunning)
            XCTAssertNil(ended.currentBook)
            XCTAssertEqual(ended.lastRunAt, date)
            XCTAssertEqual([ended.completed, ended.designed, ended.queue], [12, 9, 30])
        }
    }

    /// The second request is the one that answers, and each request gets the whole limit.
    func testAnUnansweredRequestIsSentOnceMore() async throws {
        let sent = CallLog()
        let answer = try await BookAnalyzer.answer(within: .seconds(1)) {
            await sent.append("request")
            if await sent.calls.count == 1 { try await Task.sleep(for: .seconds(30)) }
            return 7
        }
        XCTAssertEqual(answer, 7)
        let requests = await sent.calls.count
        XCTAssertEqual(requests, 2)
    }

    func testATimedOutAnswerFailsItsBookAndPausesTheRun() throws {
        let now = Date()
        XCTAssertEqual(
            SpineWorker.disposition(of: CompanionError.modelTimedOut, now: now),
            .skipBookAndStop(retryAfter: now.addingTimeInterval(SpineWorker.busyRetryDelay)))
        // iOS ends a background app whose model request is still open after about 30 seconds,
        // and a cancelled request needs time to let go.
        for tier in [ModelTier.privateCloudCompute, .onDevice] {
            XCTAssertLessThan(try XCTUnwrap(BookAnalyzer.answerTimeout(at: tier)), .seconds(25))
        }
        XCTAssertNil(BookAnalyzer.answerTimeout(at: .backup))
    }
}
