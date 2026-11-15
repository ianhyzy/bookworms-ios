import XCTest

@testable import Bookworms

/// Covers when the next background run, the charging task or the Mac's idle run, is worth
/// starting (`GenerationController.nextRunDate(after:hasNewWork:stoppedAt:now:)`), and when a
/// paused run the reader started starts again in the app
/// (`GenerationController.resumeDate(after:now:)`).
final class GenerationScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func next(_ status: WorkerSnapshot, hasNewWork: Bool = false) -> Date? {
        GenerationController.nextRunDate(after: status, hasNewWork: hasNewWork, now: now)
    }

    func testAStopWithoutARetryDateWaitsAndAFinishedRunWaitsADay() {
        var stopped = WorkerSnapshot()
        stopped.phase = "Paused"
        stopped.lastRunAt = now
        stopped.queue = 3
        stopped.error = "Waiting for Wi-Fi."
        XCTAssertEqual(next(stopped), now.addingTimeInterval(SpineWorker.busyRetryDelay))
        XCTAssertNil(next(stopped, hasNewWork: true), "A new worklist starts a run at once")
        stopped.retryAfter = now.addingTimeInterval(3_600)
        XCTAssertEqual(next(stopped), stopped.retryAfter)
        stopped.retryAfter = now.addingTimeInterval(-60)
        XCTAssertNil(next(stopped), "A passed retry date, such as a quota reset, ends the stop")

        // A stop before the run loaded its queue, such as one offline, waits as long, counted
        // from the stop.
        var offline = WorkerSnapshot()
        offline.phase = "Paused"
        offline.lastRunAt = now.addingTimeInterval(-600)
        offline.error = "The Internet connection appears to be offline."
        XCTAssertEqual(
            next(offline), now.addingTimeInterval(SpineWorker.busyRetryDelay - 600))

        // A finished run's message about the books it skipped keeps the day's wait.
        var finished = WorkerSnapshot()
        finished.phase = "Finished"
        finished.lastRunAt = now
        finished.error = "Some books could not be designed. Bookworms tries them again tomorrow."
        XCTAssertEqual(next(finished), now.addingTimeInterval(24 * 60 * 60))
        XCTAssertNil(next(finished, hasNewWork: true), "New work skips the day's wait")
        // The day counts from the run, so scheduling again later doesn't add to it.
        finished.lastRunAt = now.addingTimeInterval(-2 * 60 * 60)
        XCTAssertEqual(next(finished), now.addingTimeInterval(22 * 60 * 60))
        finished.lastRunAt = now.addingTimeInterval(-3 * 24 * 60 * 60)
        XCTAssertNil(next(finished), "A day that has passed means as soon as possible")

        // A run that iOS, a switch to battery power, or the reader's stop of a user-started run
        // cancelled may run again at once.
        var cancelled = WorkerSnapshot()
        cancelled.phase = "Stopped"
        cancelled.lastRunAt = now
        cancelled.queue = 3
        XCTAssertNil(next(cancelled))
        // So may one cancelled before it counted its queue, which the run starts at zero.
        cancelled.queue = 0
        XCTAssertNil(next(cancelled))
    }

    func testAStoppedIdleRunWaitsADayFromTheStop() {
        var cancelled = WorkerSnapshot()
        cancelled.phase = "Stopped"
        cancelled.lastRunAt = now
        cancelled.queue = 3
        let stoppedAt = now.addingTimeInterval(-600)
        let dayAfterStop = stoppedAt.addingTimeInterval(24 * 60 * 60)
        func next(_ status: WorkerSnapshot, hasNewWork: Bool = false, at date: Date? = nil)
            -> Date?
        {
            GenerationController.nextRunDate(
                after: status, hasNewWork: hasNewWork, stoppedAt: stoppedAt, now: date ?? now)
        }
        XCTAssertEqual(next(cancelled), dayAfterStop)
        XCTAssertEqual(next(cancelled, hasNewWork: true), dayAfterStop, "New work waits too")
        cancelled.retryAfter = dayAfterStop.addingTimeInterval(3_600)
        XCTAssertEqual(next(cancelled), cancelled.retryAfter, "A later retry date still holds")
        cancelled.retryAfter = nil
        XCTAssertNil(next(cancelled, at: dayAfterStop), "The stop ends after a day")
    }

    func testAPausedRunThatDesignedBooksResumesAtItsRetryDate() {
        func resume(_ status: WorkerSnapshot) -> Date? {
            GenerationController.resumeDate(after: status, now: now)
        }
        var paused = WorkerSnapshot()
        paused.phase = "Paused"
        paused.lastRunAt = now
        paused.queue = 3
        paused.designed = 2
        XCTAssertNil(resume(paused), "A stop without a retry date waits for the background run")
        paused.retryAfter = now.addingTimeInterval(900)
        XCTAssertEqual(resume(paused), paused.retryAfter)
        paused.retryAfter = now
        XCTAssertEqual(
            resume(paused), now.addingTimeInterval(60), "No sooner than a minute after the pause")

        paused.waitsForPower = true
        XCTAssertNil(resume(paused), "A run that waits for power resumes when plugged in")
        paused.waitsForPower = false
        paused.designed = 0
        XCTAssertNil(resume(paused), "A run that designed nothing leaves the retry to the next one")
    }
}
