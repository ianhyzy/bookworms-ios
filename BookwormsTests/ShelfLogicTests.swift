import Foundation
import SwiftUI
import XCTest

@testable import Bookworms

final class ShelfLogicTests: XCTestCase {
    private func book(
        _ id: Int, _ title: String, by author: String = "An Author", rating: Double? = nil,
        pages: Int? = nil
    ) -> CloudBook {
        var book = CloudBook(
            id: id, title: title, author: author, coverURL: nil, detailCoverURL: nil)
        book.rating = rating
        book.pages = pages
        return book
    }

    func testSortsKeepRecentlyFinishedOrderForTies() {
        // Arrives most recently finished first, as `AppModel.books` provides it.
        let books = [
            book(1, "Volume 10", by: "Zed Writer", rating: 4),
            book(2, "Volume 2", by: "Ann Author"),
            book(3, "An Atlas", by: "Mid Writer", rating: 5),
            book(4, "Volume 1", by: "Ann Author", rating: 4),
        ]
        XCTAssertEqual(ShelfSort.finished.sorted(books).map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(ShelfSort.title.sorted(books).map(\.id), [3, 4, 2, 1])
        XCTAssertEqual(ShelfSort.author.sorted(books).map(\.id), [2, 4, 3, 1])
        XCTAssertEqual(ShelfSort.rating.sorted(books).map(\.id), [3, 1, 4, 2])
    }

    func testFormatLabelsMatchTheAppleTV() {
        XCTAssertEqual(ShelfLabels.format("Read"), "Physical")
        XCTAssertEqual(ShelfLabels.format("Listened"), "Audiobook")
        XCTAssertEqual(ShelfLabels.format("Ebook"), "Ebook")
        XCTAssertEqual(ShelfLabels.format("Both"), "Physical & audiobook")
        XCTAssertEqual(ShelfLabels.format("Scroll"), "Scroll")
        XCTAssertNil(ShelfLabels.format(nil))
    }

    func testSlabThicknessStaysInTheComfortableRange() {
        XCTAssertEqual(book(1, "Short", pages: 40).slabThickness, 44, accuracy: 0.001)
        XCTAssertEqual(book(2, "Long", pages: 2_000).slabThickness, 96, accuracy: 0.001)
        let typical = book(3, "Unknown length").slabThickness
        XCTAssertGreaterThan(typical, 44)
        XCTAssertLessThan(typical, book(4, "Longer", pages: 600).slabThickness)
    }

    func testStackLaysBooksSlightlyAskewWithinTheScreen() {
        let layout = StackArrangement(width: 402)
        let books = (1...200).map { book($0, "Book \($0)", pages: 60 + $0 * 7) }
        for book in books {
            let spine = layout.spine(of: book)
            let shelved = book.shelfSpineSize(scale: layout.scale)
            XCTAssertEqual(spine, CGSize(width: shelved.height, height: shelved.width))
            XCTAssertLessThanOrEqual(
                abs(layout.shift(of: book)), 402 * StackArrangement.maximumShift)
            XCTAssertLessThanOrEqual(
                abs(StackArrangement.twist(of: book)), StackArrangement.maximumTwist)
            // Even the longest book, shifted, stays clear of the screen's edges.
            XCTAssertGreaterThanOrEqual(layout.leading(of: book), StackArrangement.margin - 0.001)
            XCTAssertLessThanOrEqual(
                layout.leading(of: book) + spine.width, 402 - StackArrangement.margin + 0.001)
        }
        XCTAssertLessThanOrEqual(
            layout.scale * CGFloat(BookShape.longest) + 2 * 402 * StackArrangement.maximumShift,
            402 - 2 * StackArrangement.margin + 0.001)
        // Most books face nearly straight out, and the spread is the same on every launch.
        let twists = books.map { abs(StackArrangement.twist(of: $0)) }
        let straight = twists.filter { $0 < StackArrangement.maximumTwist / 2 }.count
        XCTAssertGreaterThan(straight, books.count * 6 / 10)
        XCTAssertEqual(
            StackArrangement.twist(of: book(4, "Renamed", pages: 900)),
            StackArrangement.twist(of: books[3]))
        XCTAssertNotEqual(StackArrangement.twist(of: books[3]), 0)
        // Each book lies flat on the one below it, touching along its length.
        let track = layout.track(of: books)
        XCTAssertEqual(track.ids, books.map(\.id))
        for index in books.indices.dropLast() {
            let (above, below) = (books[index], books[index + 1])
            let step = (layout.spine(of: above).height + layout.spine(of: below).height) / 2
            XCTAssertEqual(track.offsets[index + 1] - track.offsets[index], step, accuracy: 0.001)
        }
    }

    func testStackMaskHidesTheEndsThenFadesIn() {
        func assertLocations(_ stops: [Gradient.Stop], _ expected: [CGFloat]) {
            XCTAssertEqual(stops.count, expected.count)
            for (stop, location) in zip(stops, expected) {
                XCTAssertEqual(stop.location, location, accuracy: 1e-9)
            }
        }
        let fade = StackArrangement.fade
        let stops = StackArrangement.maskStops(height: 1000, top: 30, bottom: 90)
        assertLocations(stops, [0.03, (30 + fade) / 1000, 1 - (90 + fade) / 1000, 0.91])
        XCTAssertEqual(stops.map(\.color), [.clear, .black, .black, .clear])
        // A short scroll view fades in to its middle, keeping the stops in order.
        assertLocations(
            StackArrangement.maskStops(height: 200, top: 30, bottom: 90), [0.15, 0.5, 0.5, 0.55])
        XCTAssertEqual(StackArrangement.maskStops(height: 0, top: 30, bottom: 90).count, 0)
    }

    func testStackedBooksStartTheirFlightAsTheyLie() {
        let top = book(1, "Top", pages: 300)
        let twist = StackArrangement.twist(of: top)
        XCTAssertEqual(StackStyle.flat.rest(of: top), PullOutPath.Rest(pitch: twist))
        XCTAssertEqual(
            StackStyle.threeD.rest(of: top),
            PullOutPath.Rest(
                yaw: -StackStyle.lookDown, pitch: twist, lighting: StackStyle.lighting))
    }

    func testShelvedDoorstoppersStandTallerAndThickerThanNovellas() {
        // Every variety of a 900-page book outsizes every variety of a 120-page one.
        let novellas = (1...20).map { book($0, "Novella", pages: 120).shelfSpineSize(scale: 150) }
        let doorstoppers = (21...40)
            .map {
                book($0, "Doorstopper", pages: 900).shelfSpineSize(scale: 150)
            }
        let novella = (
            width: novellas.map(\.width).max()!, height: novellas.map(\.height).max()!
        )
        XCTAssertGreaterThan(doorstoppers.map(\.width).min()!, novella.width * 1.8)
        XCTAssertGreaterThan(doorstoppers.map(\.height).min()!, novella.height)
        // Thin spines keep room for lettering; tall ones stay within the longest book.
        XCTAssertGreaterThanOrEqual(novellas.map(\.width).min()!, 150 * 0.17)
        XCTAssertLessThanOrEqual(
            doorstoppers.map(\.height).max()!, 150 * CGFloat(BookShape.longest) + 0.001)
    }

    /// A track of `books` with their detail spines' thicknesses, `spacing` apart.
    private func track(_ books: [CloudBook], spacing: CGFloat) -> SpineTrack {
        SpineTrack(books: books, thickness: \.slabThickness) { _, _ in spacing }
    }

    func testTrackCentersEachSpineAndFindsTheNearest() {
        // 40, 600, and 1,400 pages make spines 44, ~70.6, and 96 points thick.
        let books = [book(1, "A", pages: 40), book(2, "B", pages: 600), book(3, "C", pages: 1_400)]
        let thickness = books.map(\.slabThickness)
        let track = self.track(books, spacing: 6)

        XCTAssertEqual(track.ids, [1, 2, 3])
        XCTAssertEqual(track.offsets[0], 0)
        // Each step is half of each neighbor plus the spacing.
        XCTAssertEqual(track.offsets[1], (thickness[0] + thickness[1]) / 2 + 6, accuracy: 0.001)
        XCTAssertEqual(
            track.offsets[2] - track.offsets[1], (thickness[1] + thickness[2]) / 2 + 6,
            accuracy: 0.001)

        let between = (track.offsets[0] + track.offsets[1]) / 2
        XCTAssertEqual(track.index(nearest: -500), 0)
        XCTAssertEqual(track.index(nearest: between - 0.5), 0)
        XCTAssertEqual(track.index(nearest: between + 0.5), 1)
        XCTAssertEqual(track.index(nearest: 10_000), 2)
        XCTAssertEqual(track.id(nearest: track.offsets[2] - 3), 3)
        XCTAssertEqual(track.offset(of: 3), track.offsets[2])
        XCTAssertEqual(track.offset(of: 99), 0)
        XCTAssertNil(self.track([], spacing: 6).index(nearest: 0))

        // With the end spaces, the last offset is the content's end less the viewport.
        let viewport: CGFloat = 500
        let pagesLength = CGFloat(track.pages.count) * SpineTrack.pageLength
        let content =
            track.leadingSpace(viewport: viewport) + pagesLength
            + track.trailingSpace(viewport: viewport)
        XCTAssertEqual(content - viewport, track.offsets[2], accuracy: 0.001)
    }

    func testTrackPagesHoldTheSpinesCenteredInThem() {
        let books = (1...40).map { book($0, "Book \($0)", pages: 40 + $0 * 37) }
        let track = self.track(books, spacing: 6)
        var start: CGFloat = 0
        var order: [Int] = []
        for (page, slots) in track.pages.enumerated() {
            for slot in slots {
                let pageStart = CGFloat(page) * SpineTrack.pageLength
                let thickness = slot.book.slabThickness
                XCTAssertEqual(pageStart + slot.inset, start, accuracy: 0.001)
                XCTAssertLessThanOrEqual(pageStart, start + thickness / 2)
                XCTAssertLessThan(start + thickness / 2, pageStart + SpineTrack.pageLength)
                start += thickness + 6
                order.append(slot.id)
            }
        }
        XCTAssertEqual(order, track.ids)
    }

    func testShelfTrackLaysOutTheShelvedSpines() {
        let books = (1...40).map { book($0, "Book \($0)", pages: 60 + $0 * 33) }
        let widths = books.map { $0.shelfSpineSize(scale: 150).width }
        let track = SpineTrack(books: books) {
            $0.shelfSpineSize(scale: 150).width
        } gap: { _, _ in
            1
        }
        XCTAssertEqual(
            track.length, widths.reduce(0, +) + CGFloat(books.count - 1), accuracy: 0.001)
        // The shelf's scroll view reaches past the screen by half of this.
        XCTAssertEqual(track.maxThickness, widths.max()!)
        var start: CGFloat = 0
        var order: [Int] = []
        for (page, slots) in track.pages.enumerated() {
            for slot in slots {
                let pageStart = CGFloat(page) * SpineTrack.pageLength
                XCTAssertEqual(pageStart + slot.inset, start, accuracy: 0.001)
                XCTAssertEqual(slot.index, order.count)
                start += widths[slot.index] + 1
                order.append(slot.id)
            }
        }
        XCTAssertEqual(order, track.ids)
    }

    func testCoastSpringsFromTheShownPoseToTheTarget() {
        let start = Date(timeIntervalSince1970: 1_000)
        let coast = Coast(
            from: BookPose(yaw: 0, pitch: 0.2), to: BookPose(yaw: 3, pitch: -0.12), start: start)
        XCTAssertEqual(coast.pose(at: start), coast.from)
        let midway = coast.pose(at: start.addingTimeInterval(0.3))
        XCTAssertGreaterThan(midway.yaw, 0)
        XCTAssertLessThan(midway.pitch, 0.2)
        let settled = coast.pose(at: start.addingTimeInterval(Coast.spring.settlingDuration))
        XCTAssertEqual(settled.yaw, 3, accuracy: 0.01)
        XCTAssertEqual(settled.pitch, -0.12, accuracy: 0.01)
    }

    func testDriftEasesInFromRestThenFloatsAtFullAmplitude() {
        let start = Date(timeIntervalSince1970: 1_000)
        let drift = Drift(start: start)
        func offset(_ seconds: Double) -> (translation: CGSize, yaw: Double) {
            drift.offset(at: start.addingTimeInterval(seconds))
        }
        // No offset at arrival or before it, and no velocity: the book leaves its pose smoothly.
        for seconds in [-1.0, 0] {
            XCTAssertEqual(offset(seconds).translation, .zero)
            XCTAssertEqual(offset(seconds).yaw, 0)
        }
        let step = 0.01
        XCTAssertEqual(offset(step).translation.width / step, 0, accuracy: 1e-4)
        XCTAssertEqual(offset(step).translation.height / step, 0, accuracy: 1e-4)
        XCTAssertEqual(offset(step).yaw / step, 0, accuracy: 1e-6)
        // From the end of the ramp, each wave reaches its full amplitude a quarter period in.
        XCTAssertEqual(offset(10).translation.height, -Drift.verticalAmplitude, accuracy: 1e-9)
        XCTAssertEqual(offset(12).translation.width, Drift.horizontalAmplitude, accuracy: 1e-9)
        XCTAssertEqual(offset(15).yaw, Drift.swayAmplitude, accuracy: 1e-12)
        XCTAssertEqual(
            offset(Drift.rampDuration).translation.height,
            -Drift.verticalAmplitude * sin(2 * .pi * Drift.rampDuration / 40), accuracy: 1e-9)
        // It moves noticeably within ten seconds, and never past its amplitudes.
        XCTAssertGreaterThan(abs(offset(6).translation.height), 10)
        for seconds in stride(from: 0.0, through: 240, by: 0.25) {
            let sample = offset(seconds)
            XCTAssertLessThanOrEqual(abs(sample.translation.width), Drift.horizontalAmplitude)
            XCTAssertLessThanOrEqual(abs(sample.translation.height), Drift.verticalAmplitude)
            XCTAssertLessThanOrEqual(abs(sample.yaw), Drift.swayAmplitude)
        }
    }

    /// The size `pose` draws a book at on screen, before its roll: its projected bounds, scaled.
    private func drawnSize(_ pose: PullOutPath.Pose, aspect: CGFloat) -> CGSize {
        let projection = BookProjection(
            width: pose.height * aspect, height: pose.height,
            thickness: pose.height * pose.thicknessRatio, yaw: pose.yaw, pitch: pose.pitch)
        return CGSize(
            width: projection.bounds.width * pose.scale,
            height: projection.bounds.height * pose.scale)
    }

    func testPulledBookStartsAsItsSpineAndLandsInTheStage() {
        let home = CGRect(x: 100, y: 300, width: 30, height: 280)
        let stage = CGRect(x: 0, y: 120, width: 402, height: 380)
        let path = PullOutPath(
            home: home, upright: true, stage: stage, pose: .resting, aspect: 2 / 3,
            thicknessRatio: 0.08)

        // The book lays its spine out at the shelf spine's size and draws it exactly over it.
        let start = path.pose(at: 0)
        XCTAssertEqual(start.height, 280, accuracy: 0.001)
        XCTAssertEqual(start.height * start.thicknessRatio, 30, accuracy: 0.001)
        XCTAssertEqual(start.yaw, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(start.roll, 0)
        XCTAssertEqual(start.center, CGPoint(x: 115, y: 440))
        XCTAssertEqual(start.lift, 0)
        // Unshaded and casting no shadow, as the flat spine it replaces.
        XCTAssertEqual(start.lighting, 0)
        XCTAssertEqual(start.shadow, 0)
        let size = drawnSize(start, aspect: 2 / 3)
        XCTAssertEqual(size.width, 30, accuracy: 0.01)
        XCTAssertEqual(size.height, 280, accuracy: 0.01)
        // A spring's undershoot leaves the book in its place.
        XCTAssertEqual(path.pose(at: -0.1), start)

        // The slide out grows the spine toward the reader without moving or turning it, and
        // its shadow shows.
        let pulled = path.pose(at: PullOutPath.floatStart)
        XCTAssertGreaterThan(pulled.scale / start.scale, 1.1)
        XCTAssertLessThanOrEqual(pulled.scale / start.scale, PullOutPath.pullScale)
        XCTAssertEqual(pulled.center, start.center)
        XCTAssertEqual(pulled.yaw, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(pulled.height, 280, accuracy: 0.001)
        XCTAssertGreaterThan(pulled.shadow, 0.5)

        // It lands in the details' pose, size, and place.
        let end = path.pose(at: 1)
        XCTAssertEqual(end.height, 380, accuracy: 0.001)
        XCTAssertEqual(end.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(end.thicknessRatio, 0.08, accuracy: 0.0001)
        XCTAssertEqual(end.yaw, BookPose.resting.yaw, accuracy: 0.0001)
        XCTAssertEqual(end.pitch, BookPose.resting.pitch, accuracy: 0.0001)
        XCTAssertEqual(end.center.x, stage.midX, accuracy: 0.001)
        XCTAssertEqual(end.center.y, stage.midY, accuracy: 0.001)
        XCTAssertEqual(end.lift, 1, accuracy: 0.0001)
        XCTAssertEqual(end.lighting, 1, accuracy: 0.0001)
        XCTAssertEqual(end.shadow, 0, accuracy: 0.0001)
        XCTAssertEqual(path.pose(at: 1.2), end)
    }

    func testPulledBookLeavesItsPlaceBeforeItTurnsAndTheShelfDims() {
        let path = PullOutPath(
            home: CGRect(x: 100, y: 200, width: 60, height: 420), upright: true,
            stage: CGRect(x: 0, y: 150, width: 402, height: 380), pose: .resting, aspect: 2 / 3,
            thicknessRatio: 0.08)
        for step in 0...1000 {
            let progress = Double(step) / 1000
            let pose = path.pose(at: progress)
            if progress <= PullOutPath.turnStart {
                XCTAssertEqual(pose.yaw, .pi / 2, accuracy: 0.0001)
                XCTAssertEqual(pose.pitch, 0, accuracy: 0.0001)
            }
            if progress <= PullOutPath.veilStart { XCTAssertEqual(pose.lift, 0) }
        }
        // It has almost finished its slide out, and its shading has faded in, by the time it
        // turns.
        let turning = path.pose(at: PullOutPath.turnStart)
        XCTAssertGreaterThan(turning.scale / path.pose(at: 0).scale, 1.13)
        XCTAssertEqual(turning.lighting, 1, accuracy: 0.0001)
        XCTAssertLessThan(path.pose(at: PullOutPath.turnStart + 0.05).yaw, .pi / 2)
    }

    func testPulledBookMovesSmoothlyWithoutStopping() {
        let path = PullOutPath(
            home: CGRect(x: 250, y: 320, width: 40, height: 300),
            upright: true, stage: CGRect(x: 0, y: 100, width: 402, height: 380),
            pose: .resting, aspect: 0.66, thicknessRatio: 0.1)
        var previous = path.pose(at: 0)
        var previousSize = drawnSize(previous, aspect: 0.66).height
        for step in 1...1000 {
            let pose = path.pose(at: Double(step) / 1000)
            let size = drawnSize(pose, aspect: 0.66).height
            // No jumps between neighboring moments.
            XCTAssertLessThan(abs(pose.center.y - previous.center.y), 1)
            XCTAssertLessThan(abs(pose.yaw - previous.yaw), 0.01)
            XCTAssertLessThan(abs(size - previousSize), 1)
            // The book never turns back on its way, and the shelf never brightens.
            XCTAssertLessThanOrEqual(pose.yaw, previous.yaw + 0.0001)
            XCTAssertGreaterThanOrEqual(pose.lift, previous.lift)
            previous = pose
            previousSize = size
        }
    }

    func testStackedBookStandsUpAndSpunBookTurnsBackTheShortWay() {
        let home = CGRect(x: 20, y: 400, width: 362, height: 65)
        let spun = BookPose(yaw: BookPose.resting.yaw + 4 * .pi + 0.3, pitch: 0.2)
        let path = PullOutPath(
            home: home, upright: false, stage: CGRect(x: 0, y: 100, width: 402, height: 380),
            pose: spun, aspect: 2 / 3, thicknessRatio: 0.11)

        // Lying flat, head on the left: the upright spine turned a quarter turn back.
        let start = path.pose(at: 0)
        XCTAssertEqual(start.roll, -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(start.height, 362, accuracy: 0.001)
        XCTAssertEqual(start.height * start.thicknessRatio, 65, accuracy: 0.001)
        let size = drawnSize(start, aspect: 2 / 3)
        XCTAssertEqual(size.width, 65, accuracy: 0.01)
        XCTAssertEqual(size.height, 362, accuracy: 0.01)
        XCTAssertLessThan(abs(start.yaw - spun.yaw), .pi)
        XCTAssertEqual(sin(start.yaw), 1, accuracy: 0.0001)

        // A book that faces straight out comes straight toward the reader before it stands up.
        let slid = path.pose(at: PullOutPath.turnStart)
        XCTAssertEqual(slid.center.x, home.midX, accuracy: 0.001)
        XCTAssertGreaterThan(slid.scale / start.scale, 1.1)
        XCTAssertEqual(slid.roll, -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(slid.yaw, start.yaw, accuracy: 0.0001)

        let end = path.pose(at: 1)
        XCTAssertEqual(end.roll, 0, accuracy: 0.0001)
        XCTAssertEqual(end.yaw, spun.yaw, accuracy: 0.0001)
        XCTAssertEqual(end.pitch, spun.pitch, accuracy: 0.0001)
    }

    func testThreeDStackedBookStartsAsItLiesAndLandsInTheDetails() {
        let home = CGRect(x: 40, y: 400, width: 280, height: 32)
        let rest = PullOutPath.Rest(
            yaw: -0.3, pitch: 0.2, lighting: 0.6)
        let path = PullOutPath(
            home: home, upright: false, stage: CGRect(x: 0, y: 100, width: 402, height: 380),
            pose: .resting, aspect: 2 / 3, thicknessRatio: 0.1, rest: rest)

        // Drawn as the stack draws it: turned to show its top board and an end, and shaded.
        let start = path.pose(at: 0)
        XCTAssertEqual(start.center, CGPoint(x: home.midX, y: home.midY))
        XCTAssertEqual(start.height, 280, accuracy: 0.001)
        XCTAssertEqual(start.thicknessRatio, 32 / 280, accuracy: 0.0001)
        XCTAssertEqual(
            start.scale,
            1 / PullOutPath.spineMagnification(aspect: 2 / 3, thicknessRatio: 32 / 280),
            accuracy: 0.0001)
        XCTAssertEqual(start.roll, -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(sin(start.yaw - rest.yaw), 1, accuracy: 0.0001)
        XCTAssertEqual(start.pitch, 0.2, accuracy: 0.0001)
        XCTAssertEqual(start.lighting, 0.6, accuracy: 0.0001)
        XCTAssertEqual(path.pose(at: -0.1), start)
        // Turned to face a little left, it comes out toward the reader and a little left.
        let pulled = path.pose(at: PullOutPath.floatStart)
        XCTAssertLessThan(pulled.center.x, start.center.x)
        XCTAssertEqual(pulled.center.y, start.center.y, accuracy: 0.001)
        XCTAssertGreaterThan(pulled.scale / start.scale, 1.1)

        let end = path.pose(at: 1)
        XCTAssertEqual(end.roll, 0, accuracy: 0.0001)
        XCTAssertEqual(end.yaw, BookPose.resting.yaw, accuracy: 0.0001)
        XCTAssertEqual(end.pitch, BookPose.resting.pitch, accuracy: 0.0001)
        XCTAssertEqual(end.lighting, 1, accuracy: 0.0001)
    }
}
