import Foundation
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

    func testStackedBooksTouchWhereTheyMeetAndNeverOverlap() {
        // Opposite tilts meet at one end and open a wedge at the other.
        let above = StackArrangement.Lie(center: -6, length: 260, tilt: 0.02)
        let below = StackArrangement.Lie(center: 8, length: 300, tilt: -0.015)
        let gap = StackArrangement.gap(above: above, below: below)
        // The upper book's bottom edge and the lower book's top edge, with the lower book's top
        // at its center `gap` below the upper book's bottom at its center.
        func clearance(at x: CGFloat) -> CGFloat {
            (gap + (x - below.center) * tan(below.tilt)) - (x - above.center) * tan(above.tilt)
        }
        let start = max(above.center - above.length / 2, below.center - below.length / 2)
        let end = min(above.center + above.length / 2, below.center + below.length / 2)
        let samples = (0...100).map { clearance(at: start + (end - start) * CGFloat($0) / 100) }
        XCTAssertGreaterThanOrEqual(samples.min()!, -0.0001)
        XCTAssertEqual(min(samples.first!, samples.last!), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(max(samples.first!, samples.last!), 5)

        // Level books touch along their whole length.
        let level = StackArrangement.Lie(center: 10, length: 200, tilt: 0)
        let levelBelow = StackArrangement.Lie(center: -6, length: 260, tilt: 0)
        XCTAssertEqual(StackArrangement.gap(above: level, below: levelBelow), 0)
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
                abs(StackArrangement.tilt(of: book)), StackArrangement.maximumTilt)
            // Even the longest book, shifted, stays clear of the screen's edges.
            XCTAssertGreaterThanOrEqual(layout.leading(of: book), StackArrangement.margin - 0.001)
            XCTAssertLessThanOrEqual(
                layout.leading(of: book) + spine.width, 402 - StackArrangement.margin + 0.001)
        }
        XCTAssertLessThanOrEqual(
            layout.scale * CGFloat(BookShape.longest) + 2 * 402 * StackArrangement.maximumShift,
            402 - 2 * StackArrangement.margin + 0.001)
        // Most books lie nearly straight, and the spread is the same on every launch.
        let tilts = books.map { abs(StackArrangement.tilt(of: $0)) }
        let straight = tilts.filter { $0 < StackArrangement.maximumTilt / 2 }.count
        XCTAssertGreaterThan(straight, books.count * 6 / 10)
        XCTAssertEqual(StackArrangement.tilt(of: books[3]), StackArrangement.tilt(of: books[3]))
        // Each book rests on the one below it.
        let track = layout.track(of: books)
        XCTAssertEqual(track.ids, books.map(\.id))
        for index in books.indices.dropLast() {
            let (above, below) = (books[index], books[index + 1])
            let step =
                (layout.spine(of: above).height + layout.spine(of: below).height) / 2
                + StackArrangement.gap(above: layout.lie(of: above), below: layout.lie(of: below))
            XCTAssertEqual(track.offsets[index + 1] - track.offsets[index], step, accuracy: 0.001)
        }
    }

    func testStackedBooksFadeOutAsTheirCentersReachTheEnds() {
        XCTAssertEqual(StackArrangement.opacity(inset: -10), 0)
        XCTAssertEqual(StackArrangement.opacity(inset: 0), 0)
        XCTAssertEqual(
            StackArrangement.opacity(inset: StackArrangement.fade / 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(StackArrangement.opacity(inset: StackArrangement.fade), 1)
        XCTAssertEqual(StackArrangement.opacity(inset: 500), 1)
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
        XCTAssertEqual(start.faces, 1)
        let size = drawnSize(start, aspect: 2 / 3)
        XCTAssertEqual(size.width, 30, accuracy: 0.01)
        XCTAssertEqual(size.height, 280, accuracy: 0.01)
        // A spring's undershoot leaves the book in its place.
        XCTAssertEqual(path.pose(at: -0.1), start)

        // The slide out grows the spine toward the reader without moving or turning it, and
        // its shadow shows.
        let pulled = path.pose(at: PullOutPath.floatStart)
        XCTAssertGreaterThan(pulled.scale / start.scale, 1.1)
        XCTAssertLessThanOrEqual(pulled.scale / start.scale, PullOutPath.shelfPullScale)
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

        // It slides most of the way along its length, out of the wheel, before it stands up.
        let slid = path.pose(at: PullOutPath.turnStart)
        XCTAssertGreaterThan(slid.center.x - home.midX, 0.9 * PullOutPath.stackSlide * home.width)
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
            tilt: 0.02, yaw: -0.3, pitch: 0.2, lighting: 0.6, isCovered: true)
        let path = PullOutPath(
            home: home, upright: false, stage: CGRect(x: 0, y: 100, width: 402, height: 380),
            pose: .resting, aspect: 2 / 3, thicknessRatio: 0.1, rest: rest)

        // Drawn as the stack draws it: askew, turned to show its top board and an end, shaded.
        let start = path.pose(at: 0)
        XCTAssertEqual(start.center, CGPoint(x: home.midX, y: home.midY))
        XCTAssertEqual(start.height, 280, accuracy: 0.001)
        XCTAssertEqual(start.thicknessRatio, 32 / 280, accuracy: 0.0001)
        XCTAssertEqual(
            start.scale,
            1 / PullOutPath.spineMagnification(aspect: 2 / 3, thicknessRatio: 32 / 280),
            accuracy: 0.0001)
        XCTAssertEqual(start.roll, -.pi / 2 + 0.02, accuracy: 0.0001)
        XCTAssertEqual(sin(start.yaw - rest.yaw), 1, accuracy: 0.0001)
        XCTAssertEqual(start.pitch, 0.2, accuracy: 0.0001)
        XCTAssertEqual(start.lighting, 0.6, accuracy: 0.0001)
        XCTAssertEqual(path.pose(at: -0.1), start)
        // Only the spine shows until the book lifts away from the books above it.
        XCTAssertEqual(start.faces, 0)
        XCTAssertEqual(path.pose(at: PullOutPath.floatStart).faces, 0)
        XCTAssertEqual(path.pose(at: PullOutPath.veilStart).faces, 1, accuracy: 0.0001)

        let end = path.pose(at: 1)
        XCTAssertEqual(end.roll, 0, accuracy: 0.0001)
        XCTAssertEqual(end.yaw, BookPose.resting.yaw, accuracy: 0.0001)
        XCTAssertEqual(end.pitch, BookPose.resting.pitch, accuracy: 0.0001)
        XCTAssertEqual(end.lighting, 1, accuracy: 0.0001)
        XCTAssertEqual(end.faces, 1)
    }
}
