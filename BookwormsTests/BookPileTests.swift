import RealityKit
import XCTest

@testable import Bookworms

final class BookPileTests: XCTestCase {
    /// Fictional books from 90 to 1,200 pages, with one of unknown length.
    private static let books: [CloudBook] = (1...40)
        .map { index in
            CloudBook(
                id: 1_000 + index, title: "Fictional Book \(index)", author: "Author \(index)",
                coverURL: nil, detailCoverURL: nil,
                pages: index == 7 ? nil : 90 + (index * 263) % 1_110)
        }

    /// An iPhone-shaped view, 402 × 874 points, with bars of 116 and 83 points.
    private static let tray = PileTray(
        aspect: 402.0 / 874, safeTop: 1 - 2 * 116.0 / 874, safeBottom: -1 + 2 * 83.0 / 874)!

    /// The corners of a slot's book at the widest cover, in scene coordinates.
    private func corners(of slot: PileSlot) -> [SIMD3<Float>] {
        let half = BookShape(of: slot.book, coverAspect: 0.85).size / 2
        return (0..<8)
            .map { corner in
                slot.transform.translation
                    + slot.transform.rotation.act(
                        SIMD3(
                            corner & 1 == 0 ? -half.x : half.x, corner & 2 == 0 ? -half.y : half.y,
                            corner & 4 == 0 ? -half.z : half.z))
            }
    }

    /// Whether two slots' books, at the widest cover, intersect: the separating axis test for
    /// oriented boxes, over both boxes' axes and the cross products of their edges.
    private func overlap(_ a: PileSlot, _ b: PileSlot) -> Bool {
        func axes(_ slot: PileSlot) -> [SIMD3<Float>] {
            [[1, 0, 0], [0, 1, 0], [0, 0, 1]].map { slot.transform.rotation.act($0) }
        }
        func radius(_ slot: PileSlot, along axis: SIMD3<Float>) -> Float {
            let half = BookShape(of: slot.book, coverAspect: 0.85).size / 2
            return zip(axes(slot), [half.x, half.y, half.z])
                .map { abs(simd_dot($0, axis)) * $1 }
                .reduce(0, +)
        }
        let edges = axes(a).flatMap { u in axes(b).map { simd_cross(u, $0) } }
        let candidates = axes(a) + axes(b) + edges.filter { simd_length($0) > 0.0001 }
        let offset = b.transform.translation - a.transform.translation
        return !candidates.contains { axis in
            let axis = simd_normalize(axis)
            return abs(simd_dot(offset, axis)) > radius(a, along: axis) + radius(b, along: axis)
        }
    }

    /// Projects a point to normalized device coordinates for the default camera.
    private func project(_ point: SIMD3<Float>, aspect: Float = 402.0 / 874) -> SIMD2<Float> {
        let camera = PileCamera()
        let local = camera.rotation.inverse.act(point - camera.transform.translation)
        let slope = tan(PileCamera.fieldOfView / 2)
        return [local.x / (-local.z * slope * aspect), local.y / (-local.z * slope)]
    }

    func testBookSizesFollowTheCoverAndPageCount() {
        let book = Self.books[0]
        let size = BookShape(of: book, coverAspect: 0.7).size
        XCTAssertEqual(size, BookShape(of: book, coverAspect: 0.7).size)
        // Sizes snap to `BookShape.step`, so they follow the rules to within a step.
        let variety = SIMD2(
            Float(ShareStyle.unit(0, book.id, 40)), Float(ShareStyle.unit(0, book.id, 41)))
        let exact = BookShape.size(pages: book.pages, coverAspect: 0.7, variety: variety)
        XCTAssertTrue(all(abs(size - exact) .<= BookShape.step / 2 + 0.0001), "\(size) \(exact)")
        // The cover changes only the width.
        let narrow = BookShape(of: book, coverAspect: 2 / 3).size
        XCTAssertEqual(narrow.y, size.y)
        XCTAssertEqual(narrow.z, size.z)
    }

    func testPageCountMakesClearlyDifferentBooks() {
        func size(_ pages: Int?, _ variety: SIMD2<Float> = .zero) -> SIMD3<Float> {
            BookShape.size(pages: pages, coverAspect: 2 / 3, variety: variety)
        }
        let (novella, novel, brick) = (size(120), size(350), size(900))
        // 17, 19, and 23 cm long, and 8 mm, 16 mm, and 3.6 cm thick.
        XCTAssertEqual(novella.y, 1.7, accuracy: 0.001)
        XCTAssertEqual(novel.y, 1.9, accuracy: 0.001)
        XCTAssertEqual(brick.y, 2.3, accuracy: 0.001)
        XCTAssertEqual(novella.z, 0.08, accuracy: 0.001)
        XCTAssertEqual(novel.z, 0.16, accuracy: 0.001)
        XCTAssertEqual(brick.z, 0.36, accuracy: 0.001)
        // The 2:3 aspect rounds to 0.65.
        XCTAssertEqual(brick.x, brick.y * 0.65, accuracy: 0.001)
        // The floor keeps short books the same length; only their thickness differs. Length
        // keeps growing up to 800 pages.
        XCTAssertEqual(size(100).y, size(200).y)
        XCTAssertLessThan(size(100).z, size(250).z)
        XCTAssertLessThan(size(500).y, size(700).y)
        XCTAssertLessThan(size(700).y, size(800).y)
        // A book without a page count is as large as a 320-page book.
        XCTAssertEqual(size(nil), size(320))

        // Variety lengthens a book by up to 22 percent and thickens it by up to 25 percent, in
        // three levels.
        let varied = size(350, [1, 1])
        XCTAssertEqual(varied.y, 2.3, accuracy: 0.001)
        XCTAssertEqual(varied.z, 0.2, accuracy: 0.001)
        XCTAssertEqual(size(350, [0.2, 0.2]), novel)
        XCTAssertEqual(size(350, [0.4, 0.6]), size(350, [0.5, 0.5]))
        XCTAssertEqual(size(350, [0.8, 0.9]), varied)

        // Thickness stops at 4 cm before variety. A book at least 6 times as long as it is
        // thick would be 31 cm, so the length cap makes it chunky instead.
        XCTAssertEqual(size(1_400).z, 0.4, accuracy: 0.001)
        let chunky = size(1_400, [0, 1])
        XCTAssertEqual(chunky.z, 0.52, accuracy: 0.001)
        XCTAssertEqual(chunky.y, BookShape.longest, accuracy: 0.001)
        var sizes = Set<SIMD3<Float>>()
        for pages in stride(from: 100, through: 1_400, by: 10) {
            for variety in [SIMD2<Float>(0, 0), [0.5, 0.5], [1, 0], [0, 1], [1, 1]] {
                let book = size(pages, variety)
                XCTAssertLessThanOrEqual(book.y, BookShape.longest + 0.0001)
                XCTAssertGreaterThanOrEqual(book.y, min(6 * book.z, BookShape.longest) - 0.0001)
                // Length rounds to 1 cm and thickness to 4 mm.
                XCTAssertEqual(book.y * 10, (book.y * 10).rounded(), accuracy: 0.001)
                XCTAssertEqual(book.z * 25, (book.z * 25).rounded(), accuracy: 0.001)
                sizes.insert(book)
            }
        }
        // About 60 sizes for each cover aspect, so many books share a mesh.
        XCTAssertLessThan(sizes.count, 75)
    }

    func testCameraLooksAtItsTarget() {
        var camera = PileCamera()
        for (zoom, yaw) in [(1, 0), (2.5, 1.2)] as [(Float, Float)] {
            camera.zoom = zoom
            camera.yaw = yaw
            camera.target = [1, 0, -2]
            let center = PileCamera.intersect(camera.ray(ndc: .zero, aspect: 0.5), height: 0)
            XCTAssertEqual(simd_distance(center ?? .zero, camera.target), 0, accuracy: 0.001)
        }
        // A ray parallel to the table, or pointing away from it, never meets it.
        XCTAssertNil(PileCamera.intersect(([0, 5, 0], [1, 0, 0]), height: 0))
        XCTAssertNil(PileCamera.intersect(([0, 5, 0], [0, 1, 0]), height: 0))
    }

    func testTrayStaysBetweenTheBars() {
        let tray = Self.tray
        XCTAssertLessThan(tray.farZ, 0)
        XCTAssertGreaterThan(tray.nearZ, 0)
        // Perspective widens the far edge.
        XCTAssertGreaterThan(tray.farHalfWidth, tray.nearHalfWidth)
        let safeTop: Float = 1 - 2 * 116.0 / 874
        let safeBottom: Float = -1 + 2 * 83.0 / 874
        for corner in tray.corners {
            // On the table, and with a pile 4.5 units high against the wall.
            for height in [0, 4.5] as [Float] {
                let ndc = project(corner + [0, height, 0])
                XCTAssertLessThanOrEqual(abs(ndc.x), 1)
                XCTAssertLessThanOrEqual(ndc.y, safeTop)
                XCTAssertGreaterThanOrEqual(ndc.y, safeBottom)
            }
        }
    }

    func testTrayFitsThePlannedPile() throws {
        func book(_ id: Int, pages: Int) -> CloudBook {
            CloudBook(
                id: id, title: "Fictional Book \(id)", author: "An Author", coverURL: nil,
                detailCoverURL: nil, pages: pages)
        }
        let viewport = PileViewport(
            size: CGSize(width: 402, height: 874),
            insets: .init(top: 116, leading: 0, bottom: 83, trailing: 0))
        let tallest = try XCTUnwrap(PileTray(viewport: viewport))
        // A drop that fills the volume budget keeps the tallest pile's walls.
        let long = (1...300).map { book($0, pages: 600 + ($0 * 337) % 600) }
        let full = Array(PileLayout.dropped(long, count: 300))
        XCTAssertEqual(PileTray(viewport: viewport, books: full), tallest)
        // A year's 40 typical books pile under 2 units, so the far and side walls move out
        // toward the screen's edges, and the near wall, where the bottom edge meets the table,
        // stays.
        let year = (1...40).map { book($0, pages: 150 + ($0 * 97) % 400) }
        let height = PileTray.pileHeight(of: year, over: tallest)
        XCTAssertGreaterThan(height, 1)
        XCTAssertLessThan(height, 2)
        let tray = try XCTUnwrap(PileTray(viewport: viewport, books: year))
        XCTAssertEqual(tray, PileTray(viewport: viewport, pileHeight: height))
        XCTAssertLessThan(tray.farZ, tallest.farZ - 2)
        XCTAssertGreaterThan(tray.farHalfWidth, tallest.farHalfWidth)
        XCTAssertGreaterThan(tray.nearHalfWidth, tallest.nearHalfWidth)
        XCTAssertEqual(tray.nearZ, tallest.nearZ, accuracy: 0.0001)
        // The far edge shows higher, nearer the bar's edge.
        XCTAssertGreaterThan(
            project([0, 0, tray.farZ]).y, project([0, 0, tallest.farZ]).y + 0.1)
        // The emptiest drop's tray, the largest, still starts every book under the ceiling and
        // keeps its far edge inside the box of Phone is the box.
        let largest = try XCTUnwrap(PileTray(viewport: viewport, books: []))
        let starts = (0..<3 as Range<UInt64>)
            .flatMap { PileLayout.dropPlan(Self.books, in: largest, seed: $0) }
        XCTAssertLessThan(
            starts.map(\.transform.translation.y).max()! + 1.86, PileLayout.ceiling)
        let box = try XCTUnwrap(PileBox(viewport: viewport))
        for corner in largest.corners.prefix(2) {
            XCTAssertTrue(box.contains(corner + [0, 0.1, 0], margin: 0.3))
        }
    }

    func testClampKeepsPointsInsideTheTray() {
        let tray = Self.tray
        let inside = SIMD3<Float>(0.5, 2, 0)
        XCTAssertEqual(tray.clamp(inside, margin: 1), inside)
        let clamped = tray.clamp([40, 2, -40], margin: 1)
        XCTAssertEqual(clamped.y, 2)
        XCTAssertEqual(clamped.z, tray.farZ + 1, accuracy: 0.0001)
        XCTAssertEqual(clamped.x, tray.halfWidth(at: tray.farZ + 1) - 1, accuracy: 0.0001)
        let near = tray.clamp([-40, 0, 40], margin: 1)
        XCTAssertEqual(near.z, tray.nearZ - 1, accuracy: 0.0001)
        XCTAssertEqual(near.x, -(tray.halfWidth(at: tray.nearZ - 1) - 1), accuracy: 0.0001)
    }

    func testDropPlanIsRepeatableAndSpreadsEachWave() {
        let plan = PileLayout.dropPlan(Self.books, in: Self.tray, seed: 3)
        let again = PileLayout.dropPlan(Self.books, in: Self.tray, seed: 3)
        let other = PileLayout.dropPlan(Self.books, in: Self.tray, seed: 4)
        XCTAssertEqual(plan.map(\.book.id), Self.books.map(\.id))
        XCTAssertEqual(plan.map(\.transform), again.map(\.transform))
        XCTAssertNotEqual(plan.map(\.transform), other.map(\.transform))

        // No two books of a wave start inside each other, at the widest cover, even when every
        // book is as large as a book gets. Each starts clear of the walls by half a book, and
        // between the drop height and the ceiling.
        let largest = BookShape(
            size: BookShape.size(pages: 1_400, coverAspect: 0.85, variety: [1, 1]),
            binding: .hardcover
        )
        .size
        XCTAssertTrue(all(abs(largest - [2.4, 2.8, 0.52]) .< 0.001), "\(largest)")
        XCTAssertEqual(simd_length(largest), 3.72, accuracy: 0.01)
        let bricks = (2_000...).lazy
            .map { id in
                CloudBook(
                    id: id, title: "Fictional Brick \(id)", author: "An Author", coverURL: nil,
                    detailCoverURL: nil, pages: 1_400)
            }
            .filter { BookShape(of: $0, coverAspect: 0.85).size == largest }
            .prefix(40)
        for books in [Self.books, Array(bricks)] {
            for seed in 0..<200 as Range<UInt64> {
                let plan = PileLayout.dropPlan(books, in: Self.tray, seed: seed)
                for slot in plan {
                    let position = slot.transform.translation
                    let reach = simd_length(BookShape(of: slot.book, coverAspect: 0.85).size) / 2
                    XCTAssertEqual(Self.tray.clamp(position, margin: PileLayout.reach), position)
                    XCTAssertGreaterThanOrEqual(
                        position.y, PileLayout.spawnHeight(over: Self.tray))
                    XCTAssertLessThan(position.y + reach, PileLayout.ceiling)
                }
                for wave in stride(from: 0, to: plan.count, by: PileLayout.waveSize) {
                    let slots = plan[wave..<min(wave + PileLayout.waveSize, plan.count)]
                    for (index, slot) in slots.enumerated() {
                        for other in slots.dropFirst(index + 1) {
                            XCTAssertFalse(
                                overlap(slot, other),
                                "seed \(seed): \(slot.book.id), \(other.book.id)")
                        }
                    }
                }
            }
        }
    }

    func testDropsStartOutOfViewOfEveryCamera() throws {
        // iPhone-shaped views, from a small phone to a large one, with and without the time
        // frame button's inset.
        let views: [(CGSize, CGFloat, CGFloat)] = [
            (CGSize(width: 375, height: 812), 100, 83), (CGSize(width: 402, height: 874), 116, 83),
            (CGSize(width: 402, height: 874), 166, 83), (CGSize(width: 440, height: 956), 170, 83),
        ]
        let slope = tan(PileCamera.fieldOfView / 2)
        for (size, top, bottom) in views {
            let tray = try XCTUnwrap(
                PileTray(
                    viewport: PileViewport(
                        size: size,
                        insets: .init(top: top, leading: 0, bottom: bottom, trailing: 0))))
            let plan = (0..<3 as Range<UInt64>)
                .flatMap { PileLayout.dropPlan(Self.books, in: tray, seed: $0) }
            let points = plan.flatMap(corners)
            XCTAssertLessThan(
                plan.map(\.transform.translation.y).max()! + 1.86, PileLayout.ceiling, "\(size)")
            var shown = 0
            for zoom in [PileCamera.zoomRange.lowerBound, 1.6, PileCamera.zoomRange.upperBound] {
                // The targets a zoomed camera can move to (see `BookPileScene.moveCamera`).
                let reach = 1 - 1 / zoom
                for x in [-tray.farHalfWidth, tray.farHalfWidth] {
                    for z in [tray.farZ, tray.nearZ] {
                        for step in 0..<16 {
                            let camera = PileCamera(
                                target: [x * reach, 0, z * reach], yaw: Float(step) * .pi / 8,
                                zoom: zoom)
                            let eye = camera.transform.translation
                            // Counts the corners on or under the plane through the camera
                            // and the view's top edge.
                            shown += points.count(where: { corner in
                                let local = camera.rotation.inverse.act(corner - eye)
                                return local.y <= -local.z * slope
                            })
                        }
                    }
                }
            }
            XCTAssertEqual(shown, 0, "\(size)")
        }
        // The box closes only once a book from the ceiling has landed.
        let fall = stride(from: Float(0), to: 10, by: 0.01)
            .first { fallen(after: $0) > PileLayout.ceiling }!
        XCTAssertLessThan(Double(fall) + 0.5, PileLayout.boxDelay / .seconds(1))
    }

    /// How far a falling book drops in `time` seconds from rest, under gravity and air drag.
    private func fallen(after time: Float) -> Float {
        let drag = PileLayout.airDrag
        return PileLayout.gravity / drag * (time - (1 - exp(-drag * time)) / drag)
    }

    func testSpinnerLastsUntilTheFirstBooksCanShow() {
        let camera = PileCamera()
        let eye = camera.transform.translation
        let slope = tan(PileCamera.fieldOfView / 2)
        for seed: UInt64 in 0..<5 {
            let wave = PileLayout.dropPlan(Self.books, in: Self.tray, seed: seed)
                .prefix(PileLayout.waveSize)
            let delay = Float(PileLayout.entryDelay(of: wave, seenBy: camera))
            // About a third of a second, so the spinner's fade overlaps the first books coming in.
            XCTAssertGreaterThan(delay, 0.2)
            XCTAssertLessThan(delay, 0.6)
            // No corner shows before then.
            let drop = SIMD3(0, fallen(after: delay - 0.02), 0)
            let shown = wave.flatMap(corners)
                .contains { corner in
                    let local = camera.rotation.inverse.act(corner - drop - eye)
                    return local.y <= -local.z * slope
                }
            XCTAssertFalse(shown, "\(seed)")
        }
    }

    func testAirDragLandsBooksAboutAsFastAsALowDrop() {
        let starts = PileLayout.dropPlan(Self.books, in: Self.tray, seed: 2)
            .map(\.transform.translation.y)
        for height in [starts.min()!, starts.max()!] {
            let time = stride(from: Float(0), to: 10, by: 0.001)
                .first { fallen(after: $0) > height }!
            let speed =
                PileLayout.gravity / PileLayout.airDrag * (1 - exp(-PileLayout.airDrag * time))
            // A drop from 9 to 20 units without drag lands at 31 to 47 units a second.
            XCTAssertGreaterThan(speed, 35, "\(height)")
            XCTAssertLessThan(speed, 43, "\(height)")
        }
    }

    func testEachWaveFallsBelowTheNextWaveBeforeItStarts() {
        let starts = (0..<20 as Range<UInt64>)
            .flatMap { PileLayout.dropPlan(Self.books, in: Self.tray, seed: $0) }
            .map(\.transform.translation.y)
        let reach = Self.books.map { simd_length(BookShape(of: $0, coverAspect: 0.85).size) / 2 }
            .max()!
        // Physics starts a frame after a wave spawns.
        let time = Float(PileLayout.waveInterval / .seconds(1)) - 1 / 60
        XCTAssertLessThan(starts.max()! - fallen(after: time) + reach, starts.min()! - reach)
    }

    func testLiveDropsStartCoverUp() {
        // A live drop starts every book front cover up, tumbled at most 0.8 radians, spinning
        // more about the vertical than about the level axes.
        for slot in PileLayout.dropPlan(Self.books, in: Self.tray, seed: 7) {
            XCTAssertGreaterThanOrEqual(
                slot.transform.rotation.act([0, 0, 1]).y, cos(0.8) - 0.0001)
            XCTAssertLessThanOrEqual(abs(slot.spin.x), 2)
            XCTAssertLessThanOrEqual(abs(slot.spin.z), 2)
            XCTAssertLessThanOrEqual(abs(slot.spin.y), 3)
        }
    }

    /// Up to 150 fictional books, as `testShelfBooks` sizes them, at a 2:3 cover.
    private func spreadBooks(_ count: Int) -> [(book: CloudBook, shape: BookShape)] {
        (1...count)
            .map { index in
                let book = CloudBook(
                    id: 3_000 + index, title: "Fictional Book \(index)", author: "Author",
                    coverURL: nil, detailCoverURL: nil, pages: 90 + (index * 263) % 1_110)
                return (book, BookShape(of: book, coverAspect: 2 / 3))
            }
    }

    /// The share images' frames and counts the spread tests cover, from one book to the most.
    private static let spreadCases: [(ShareAspect, Int)] = [
        (.story, 1), (.story, 3), (.story, 12), (.story, 40), (.story, 150), (.portrait, 2),
        (.portrait, 8), (.portrait, 40), (.square, 5), (.square, 25), (.square, 150),
    ]

    func testSpreadShowsEveryCoverFaceUpInsideTheFrame() {
        for (aspect, count) in Self.spreadCases {
            let layout = PileSnapshotLayout(aspect: aspect, count: count)
            let books = spreadBooks(count)
            for seed: UInt64 in [0, 1] {
                let spread = PileSpread(
                    books, in: layout.pileRect, of: aspect.size, seed: seed)
                let label = "\(aspect) \(count) seed \(seed)"
                XCTAssertEqual(Set(spread.slots.map(\.book.id)), Set(books.map(\.book.id)), label)
                let boxes = zip(spread.slots, spread.shapes).map { ($0.transform, $1) }
                // Every front cover faces up, tilted at most 20 degrees, as books lying on
                // the edges of others do.
                for slot in spread.slots {
                    XCTAssertTrue(PileLayout.isCoverUp(slot.transform.rotation), label)
                    XCTAssertGreaterThan(
                        slot.transform.rotation.act([0, 0, 1]).y, cos(20 * .pi / 180), label)
                }
                // At least four fifths of each cover shows, measured more finely than the
                // layout measures it.
                let shares = PileSpread.visibility(
                    of: boxes, camera: spread.camera, in: layout.pileRect, of: aspect.size,
                    samples: [24, 32])
                XCTAssertGreaterThanOrEqual(shares.map(\.share).min() ?? 0, 0.8, label)
                // No book reaches past the pile rect, under the heading or the credit.
                for corner in boxes.flatMap({ corners(of: $0) }) {
                    let point = pixel(spread.camera, corner, aspect.size)
                    XCTAssertTrue(layout.pileRect.insetBy(dx: -1, dy: -1).contains(point), label)
                }
            }
        }
    }

    func testSpreadFillsTheFrame() {
        for (aspect, count) in Self.spreadCases {
            let layout = PileSnapshotLayout(aspect: aspect, count: count)
            let rect = layout.pileRect
            let spread = PileSpread(spreadBooks(count), in: rect, of: aspect.size, seed: 3)
            let boxes = zip(spread.slots, spread.shapes).map { ($0.transform, $1) }
            let points = boxes.flatMap { corners(of: $0) }
                .map { pixel(spread.camera, $0, aspect.size) }
            let low = CGPoint(x: points.map(\.x).min()!, y: points.map(\.y).min()!)
            let high = CGPoint(x: points.map(\.x).max()!, y: points.map(\.y).max()!)
            // The books reach across the rect or down it, centered, whatever their number.
            let fill = max((high.x - low.x) / rect.width, (high.y - low.y) / rect.height)
            XCTAssertGreaterThan(fill, 0.95, "\(aspect) \(count)")
            XCTAssertEqual((low.x + high.x) / 2, rect.midX, accuracy: 10)
            XCTAssertEqual((low.y + high.y) / 2, rect.midY, accuracy: 10)
            // Books cover most of the rect, short of the gaps that a few books leave in a frame
            // of another shape.
            let coverage = PileSpread.coverage(
                of: boxes, camera: spread.camera, in: rect, of: aspect.size, step: 12)
            XCTAssertGreaterThan(coverage.books, count < 12 ? 0.35 : 0.5, "\(aspect) \(count)")
        }
    }

    func testALastBookGoesDownLastSoNothingRestsOnIt() {
        for (aspect, count) in [(ShareAspect.story, 1), (.story, 3), (.story, 40), (.square, 150)] {
            let layout = PileSnapshotLayout(aspect: aspect, count: count)
            let books = spreadBooks(count)
            for last in Set([books[0].book.id, books[count / 2].book.id, books[count - 1].book.id])
            {
                let spread = PileSpread(
                    books, in: layout.pileRect, of: aspect.size, seed: 1, last: last)
                let label = "\(aspect) \(count) last \(last)"
                // A book rests only on books before it, so nothing rests on the last.
                XCTAssertEqual(spread.slots.last?.book.id, last, label)
                XCTAssertEqual(Set(spread.slots.map(\.book.id)), Set(books.map(\.book.id)), label)
                // Every cover still shows at least four fifths.
                let boxes = zip(spread.slots, spread.shapes).map { ($0.transform, $1) }
                let shares = PileSpread.visibility(
                    of: boxes, camera: spread.camera, in: layout.pileRect, of: aspect.size,
                    samples: [24, 32])
                XCTAssertGreaterThanOrEqual(shares.map(\.share).min() ?? 0, 0.8, label)
            }
        }
        // Without a last book, the seed alone decides, as the share images need.
        let layout = PileSnapshotLayout(aspect: .portrait, count: 30)
        XCTAssertEqual(
            PileSpread(spreadBooks(30), in: layout.pileRect, of: layout.aspect.size, seed: 4)
                .slots.map(\.transform),
            PileSpread(
                spreadBooks(30), in: layout.pileRect, of: layout.aspect.size, seed: 4, last: nil
            )
            .slots.map(\.transform))
    }

    func testSpreadIsRepeatableAndShuffleVariesIt() {
        let layout = PileSnapshotLayout(aspect: .portrait, count: 30)
        let books = spreadBooks(30)
        func spread(_ seed: UInt64) -> PileSpread {
            PileSpread(books, in: layout.pileRect, of: layout.aspect.size, seed: seed)
        }
        XCTAssertEqual(spread(4).slots.map(\.transform), spread(4).slots.map(\.transform))
        XCTAssertEqual(spread(4).camera, spread(4).camera)
        // Another seed moves most books.
        let first = Dictionary(uniqueKeysWithValues: spread(4).slots.map { ($0.book.id, $0) })
        let moved = spread(5).slots
            .filter { slot in
                simd_distance(
                    slot.transform.translation, first[slot.book.id]!.transform.translation)
                    > 0.5
            }
        XCTAssertGreaterThan(moved.count, 20)
    }

    func testSpreadBooksRestOnWhatIsUnderThem() {
        for (aspect, count) in [(ShareAspect.story, 40), (.square, 150)] {
            let layout = PileSnapshotLayout(aspect: aspect, count: count)
            let spread = PileSpread(
                spreadBooks(count), in: layout.pileRect, of: aspect.size, seed: 2)
            let boxes = zip(spread.slots, spread.shapes).map { ($0.transform, $1) }
            for (index, box) in boxes.enumerated() {
                // No book sinks into the table or into a book before it, give or take half a
                // millimeter.
                let bottom = corners(of: box).map(\.y).min()!
                XCTAssertGreaterThanOrEqual(bottom, -0.005)
                for earlier in boxes.prefix(index) {
                    XCTAssertFalse(intersect(box, earlier, margin: 0.005), "\(aspect) \(index)")
                }
                // A book that does not lie on the table touches a book under it.
                guard bottom > 0.005 else { continue }
                XCTAssertTrue(
                    boxes.prefix(index).contains { intersect(box, $0, margin: -0.01) },
                    "\(aspect) \(index)")
            }
        }
    }

    func testABookOnTheEdgeOfAnotherTiltsOntoIt() {
        let lower = BookShape(size: [1.4, 2.0, 0.3], binding: .paperback)
        let upper = BookShape(size: [1.4, 2.0, 0.2], binding: .paperback)
        func piece(_ id: Int, _ shape: BookShape, at spot: SIMD2<Float>) -> PileSpread.Piece {
            PileSpread.Piece(
                book: CloudBook(
                    id: id, title: "Book \(id)", author: "Author", coverURL: nil,
                    detailCoverURL: nil),
                shape: shape, spot: spot, turn: 0)
        }
        // The upper book's tail lies 0.2 units over the lower book's head.
        let slots = PileSpread.rest([
            piece(1, lower, at: [0, 0]), piece(2, upper, at: [0, -1.8]),
        ])
        XCTAssertEqual(slots[0].transform.translation.y, 0.15, accuracy: 1e-4)
        XCTAssertEqual(slots[0].transform.rotation.act([0, 0, 1]).y, 1, accuracy: 1e-5)
        // Its head lies on the table, and its underside rests on the lower book's edge, so it
        // slopes away from the camera by the lower book's thickness over 1.8 units.
        let box = (slots[1].transform, upper)
        let bottom = corners(of: box).sorted { $0.y < $1.y }
        XCTAssertEqual(bottom[0].y, 0, accuracy: 5e-3)
        XCTAssertEqual(bottom[0].z, -2.8, accuracy: 0.03)
        let normal = slots[1].transform.rotation.act([0, 0, 1])
        XCTAssertEqual(atan2(-normal.z, normal.y), atan(0.3 / 1.8), accuracy: 2e-3)
        // A book across two books of one thickness lies flat on them.
        let bridge = PileSpread.rest([
            piece(1, lower, at: [0, 0]), piece(3, lower, at: [0, -3.6]),
            piece(2, upper, at: [0, -1.8]),
        ])
        XCTAssertEqual(bridge[2].transform.rotation.act([0, 0, 1]).y, 1, accuracy: 1e-4)
        XCTAssertEqual(bridge[2].transform.translation.y, 0.3 + 0.1, accuracy: 1e-3)
    }

    /// The corners of a book's box in scene coordinates.
    private func corners(of box: (transform: Transform, shape: BookShape)) -> [SIMD3<Float>] {
        let half = box.shape.size / 2
        return (0..<8)
            .map { corner in
                box.transform.translation
                    + box.transform.rotation.act(
                        SIMD3(
                            corner & 1 == 0 ? -half.x : half.x, corner & 2 == 0 ? -half.y : half.y,
                            corner & 4 == 0 ? -half.z : half.z))
            }
    }

    /// Whether two books' boxes, each shrunk by `margin` on every side, intersect: the
    /// separating axis test over both boxes' axes and their edges' cross products.
    private func intersect(
        _ a: (transform: Transform, shape: BookShape),
        _ b: (transform: Transform, shape: BookShape),
        margin: Float
    ) -> Bool {
        func axes(_ box: (transform: Transform, shape: BookShape)) -> [SIMD3<Float>] {
            [[1, 0, 0], [0, 1, 0], [0, 0, 1]].map { box.transform.rotation.act($0) }
        }
        func radius(_ box: (transform: Transform, shape: BookShape), _ axis: SIMD3<Float>)
            -> Float
        {
            let half = box.shape.size / 2 - margin
            return zip(axes(box), [half.x, half.y, half.z])
                .map { abs(simd_dot($0, axis)) * $1 }
                .reduce(0, +)
        }
        let edges = axes(a).flatMap { u in axes(b).map { simd_cross(u, $0) } }
        let candidates = axes(a) + axes(b) + edges.filter { simd_length($0) > 0.0001 }
        let offset = b.transform.translation - a.transform.translation
        return !candidates.contains { axis in
            let axis = simd_normalize(axis)
            return abs(simd_dot(offset, axis)) > radius(a, axis) + radius(b, axis)
        }
    }

    /// Where `camera` shows a scene point in an image of `size`, in pixels with y growing
    /// downward.
    private func pixel(_ camera: PileCamera, _ point: SIMD3<Float>, _ size: CGSize) -> CGPoint {
        let ndc = camera.project(point, aspect: Float(size.width / size.height))
        return CGPoint(
            x: CGFloat(ndc.x + 1) / 2 * size.width, y: CGFloat(1 - ndc.y) / 2 * size.height)
    }

    func testLiveDropsStopAtTheVolumeBudget() {
        func book(_ id: Int, pages: Int) -> CloudBook {
            CloudBook(
                id: id, title: "Fictional Book \(id)", author: "An Author", coverURL: nil,
                detailCoverURL: nil, pages: pages)
        }
        func liters(_ books: some Sequence<CloudBook>) -> Float {
            books.map { BookShape(of: $0, coverAspect: 2 / 3).size }
                .map { $0.x * $0.y * $0.z }
                .reduce(0, +)
        }
        // Three hundred typical books all drop.
        let typical = (1...400).map { book($0, pages: 150 + ($0 * 97) % 400) }
        XCTAssertEqual(PileLayout.dropped(typical, count: 300).count, 300)
        // Long books drop in order until the next would pass the budget.
        let long = (1...300).map { book($0, pages: 600 + ($0 * 337) % 600) }
        let dropped = PileLayout.dropped(long, count: 300)
        XCTAssertLessThan(dropped.count, 200)
        XCTAssertEqual(dropped.map(\.id), long.prefix(dropped.count).map(\.id))
        XCTAssertLessThanOrEqual(liters(dropped), PileLayout.maximumVolume)
        XCTAssertGreaterThan(liters(long.prefix(dropped.count + 1)), PileLayout.maximumVolume)
        // Spread evenly over an iPhone's tray, the budget would stand under 2.6 units deep,
        // which leaves the pile's peaks and a book on end room under the walls' `pileHeight`.
        XCTAssertLessThan(PileLayout.maximumVolume / Self.tray.area, 2.6)
    }

    func testCoverUpMeansWithin45DegreesOfUp() {
        let flat = PileLayout.lyingFlat
        XCTAssertTrue(PileLayout.isCoverUp(flat))
        XCTAssertTrue(PileLayout.isCoverUp(simd_quatf(angle: 0.7, axis: [1, 0, 0]) * flat))
        XCTAssertFalse(PileLayout.isCoverUp(simd_quatf(angle: 0.9, axis: [0, 0, 1]) * flat))
        XCTAssertFalse(PileLayout.isCoverUp(simd_quatf(angle: .pi, axis: [1, 0, 0]) * flat))
    }

    func testCenterOfMassLeansTowardTheBackBoard() {
        let size = SIMD3<Float>(1.5, 2.25, 0.3)
        let center = PileLayout.centerOfMass(of: size)
        XCTAssertEqual(center.x, 0)
        XCTAssertEqual(center.y, 0)
        // Behind the middle, toward the back cover at -z, and inside the book.
        XCTAssertLessThan(center.z, 0)
        XCTAssertGreaterThan(center.z, -size.z / 2)
    }

    func testAddedBooksMustKeepTheEarlierOrder() {
        let books = Array(Self.books.prefix(5))
        let ids = books.map(\.id)
        XCTAssertEqual(
            PileLayout.added(to: [ids[1], ids[3]], in: books)?.map(\.id), [ids[0], ids[2], ids[4]])
        XCTAssertEqual(PileLayout.added(to: [], in: books)?.map(\.id), ids)
        // A reordered or shortened list starts a new pile.
        XCTAssertNil(PileLayout.added(to: [ids[3], ids[1]], in: books))
        XCTAssertNil(PileLayout.added(to: ids + [99], in: books))
    }

    func testStackPlanStacksBooksBottomUpInsideTheTray() {
        let plan = PileLayout.stackPlan(Self.books, in: Self.tray)
        XCTAssertEqual(Set(plan.map(\.book.id)), Set(Self.books.map(\.id)))
        XCTAssertEqual(plan.count, Self.books.count)

        // Slots arrive bottom up, so each book rests on the books listed before it in its stack.
        var stacks: [(center: SIMD2<Float>, top: Float, firstID: Int?)] = []
        for slot in plan {
            let position = slot.transform.translation
            let thickness = BookShape(of: slot.book, coverAspect: 2 / 3).size.z
            let center = SIMD2(position.x, position.z)
            if let index = stacks.firstIndex(where: { simd_distance($0.center, center) < 0.2 }) {
                XCTAssertEqual(position.y - thickness / 2, stacks[index].top, accuracy: 0.0001)
                stacks[index].top += thickness
                stacks[index].firstID = slot.book.id
            } else {
                XCTAssertEqual(position.y, thickness / 2, accuracy: 0.0001)
                stacks.append((center, thickness, slot.book.id))
            }
            // A flat book, 2.8 units long and 2.4 wide at most, stays inside the tray.
            XCTAssertEqual(
                Self.tray.clamp(position, margin: 1.4).x, position.x, accuracy: 0.0001)
            XCTAssertEqual(
                Self.tray.clamp(position, margin: 1.2).z, position.z, accuracy: 0.0001)
        }
        XCTAssertGreaterThan(stacks.count, 1)
        // The first book in the order lies on top of the first stack.
        XCTAssertEqual(stacks[0].firstID, Self.books[0].id)
        // Stacks never overlap: they are a book's length apart across, or a width apart in depth.
        for (index, stack) in stacks.enumerated() {
            for other in stacks.dropFirst(index + 1) {
                let gap = abs(stack.center - other.center)
                XCTAssertTrue(gap.x > 2.8 || gap.y > 2.4, "\(stack.center) \(other.center)")
            }
        }
        // Lying flat, front cover up, with the spine toward the camera and the head to the left.
        let rotation = PileLayout.lyingFlat
        XCTAssertEqual(simd_distance(rotation.act([0, 0, 1]), [0, 1, 0]), 0, accuracy: 0.0001)
        XCTAssertEqual(simd_distance(rotation.act([-1, 0, 0]), [0, 0, 1]), 0, accuracy: 0.0001)
        XCTAssertEqual(simd_distance(rotation.act([0, 1, 0]), [-1, 0, 0]), 0, accuracy: 0.0001)
    }

    func testTiltGravityFollowsTheChangeAndStaysOnTheTable() {
        let upright = SIMD3<Double>(0, -1, 0)
        let down = SIMD3<Float>(0, -PileLayout.gravity, 0)
        XCTAssertEqual(PileLayout.gravity(device: upright, reference: upright, yaw: 0), down)
        // A steady hand stays in the dead zone.
        XCTAssertEqual(
            PileLayout.gravity(device: [0.02, -1, 0], reference: upright, yaw: 0), down)

        // Right edge down slides books right; top edge down slides them up the screen.
        let right = PileLayout.gravity(device: [0.2, -1, 0], reference: upright, yaw: 0)
        XCTAssertGreaterThan(right.x, 0)
        XCTAssertEqual(right.z, 0, accuracy: 0.0001)
        XCTAssertEqual(right.y, -PileLayout.gravity)
        let flat = SIMD3<Double>(0, 0, -1)
        let away = PileLayout.gravity(device: [0, 0.2, -0.98], reference: flat, yaw: 0)
        XCTAssertLessThan(away.z, 0)

        // A hard tilt is clamped, so books slide but keep pressing on the table.
        let hard = PileLayout.gravity(device: [1, 0, 0], reference: upright, yaw: 0)
        XCTAssertEqual(
            simd_length(SIMD2(hard.x, hard.z)), PileLayout.maximumTilt * PileLayout.gravity,
            accuracy: 0.001)
        XCTAssertEqual(hard.y, -PileLayout.gravity)

        // Turned a quarter, the camera's right is -z, and tipping the right edge down still
        // slides books toward the screen's right.
        var camera = PileCamera()
        camera.yaw = .pi / 2
        let turned = PileLayout.gravity(device: [0.2, -1, 0], reference: upright, yaw: camera.yaw)
        let screenRight = camera.rotation.act([1, 0, 0])
        XCTAssertEqual(
            simd_dot(SIMD2(turned.x, turned.z), SIMD2(screenRight.x, screenRight.z)),
            simd_length(SIMD2(right.x, right.z)), accuracy: 0.001)
        XCTAssertEqual(turned.y, -PileLayout.gravity, accuracy: 0.001)
    }

    func testDetailPoseFillsTheDetailsStage() {
        let camera = PileCamera()
        let aspect: Float = 402.0 / 874
        let size = SIMD3<Float>(1.5, 2.25, 0.3)
        // A 380-point book centered 350 points from the top of an 874-point view.
        let center = SIMD2<Float>(0.1, 1 - 2 * 350.0 / 874)
        let height: Float = 2 * 380.0 / 874
        let upright = PileCamera.detailPose(
            seenFrom: camera.transform, center: center, height: height, size: size,
            pose: BookPose(yaw: 0, pitch: 0),
            aspect: aspect)
        let middle = camera.project(upright.translation, aspect: aspect)
        XCTAssertEqual(middle.x, center.x, accuracy: 0.0001)
        XCTAssertEqual(middle.y, center.y, accuracy: 0.0001)
        // Facing the camera, the book's height spans the stage's height, as in `Book3DView`.
        let half = upright.rotation.act([0, size.y / 2, 0])
        let top = camera.project(upright.translation + half, aspect: aspect)
        let bottom = camera.project(upright.translation - half, aspect: aspect)
        XCTAssertEqual(top.y - bottom.y, height, accuracy: height * 0.01)
        XCTAssertEqual(top.x, bottom.x, accuracy: 0.001)

        // At rest, the front cover, the spine, and the head face the camera, as in the details.
        let resting = PileCamera.detailPose(
            seenFrom: camera.transform, center: center, height: height, size: size,
            pose: .resting, aspect: aspect)
        let toCamera = camera.transform.translation - resting.translation
        func faces(_ axis: SIMD3<Float>) -> Bool {
            simd_dot(resting.rotation.act(axis), toCamera) > 0
        }
        XCTAssertTrue(faces([0, 0, 1]))
        XCTAssertTrue(faces([-1, 0, 0]))
        XCTAssertTrue(faces([0, 1, 0]))
        XCTAssertFalse(faces([1, 0, 0]))
        XCTAssertFalse(faces([0, 0, -1]))
    }

    func testRiseClearsTheBooksOverTheLiftedOne() {
        let book = BoundingBox(min: [-1, 0, -0.7], max: [1, 0.3, 0.7])
        let onTop = BoundingBox(min: [-0.5, 0.3, -0.5], max: [0.8, 0.9, 0.5])
        let beside = BoundingBox(min: [1.2, 0, -0.7], max: [3, 4, 0.7])
        let below = BoundingBox(min: [-1, -0.4, -0.7], max: [1, 0, 0.7])
        XCTAssertEqual(
            BookFlight.rise(of: book, clearing: [onTop, beside, below]), 1.05, accuracy: 0.0001)
        // A book still falling high above the stack does not count.
        let falling = BoundingBox(min: [-0.6, 3, -0.4], max: [0.9, 3.5, 0.6])
        XCTAssertEqual(
            BookFlight.rise(of: book, clearing: [falling, onTop]), 1.05, accuracy: 0.0001)
        XCTAssertEqual(BookFlight.rise(of: book, clearing: [falling]), 0.4)
        // A book with nothing over it still comes free of the table, and a tall pile caps it.
        XCTAssertEqual(BookFlight.rise(of: book, clearing: [beside, below]), 0.4)
        let tower = BoundingBox(min: [0, 0.3, 0], max: [0.5, 20, 0.5])
        XCTAssertEqual(BookFlight.rise(of: book, clearing: [tower]), 6)
    }

    func testRiseClearsStandingNeighborsWithinItsMargin() {
        // A standing domino, a taller neighbor 0.6 units off its back cover, and the book past
        // that one.
        let book = BoundingBox(min: [-0.75, 0, -0.15], max: [0.75, 2.2, 0.15])
        let neighbor = BoundingBox(min: [-0.8, 0, 0.75], max: [0.8, 2.8, 1.05])
        let beyond = BoundingBox(min: [-0.8, 0, 1.9], max: [0.8, 3.5, 2.2])
        // Without a margin, it rises only to come free of the table, and its top stays below
        // its neighbor's.
        XCTAssertEqual(BookFlight.rise(of: book, clearing: [neighbor, beyond]), 0.4)
        // With the dominoes' margin, it rises until its bottom clears its neighbor's top, but
        // not the book past it.
        XCTAssertEqual(
            BookFlight.rise(of: book, clearing: [neighbor, beyond], margin: 0.89), 2.95,
            accuracy: 0.0001)
    }

    func testLiftWakesTheBooksOnAndAgainstTheLiftedOne() {
        let book = BoundingBox(min: [-1, 0, -0.7], max: [1, 0.3, 0.7])
        let others = [
            // Resting on it, stacked high above it, and leaning on its side.
            BoundingBox(min: [-0.5, 0.3, -0.5], max: [0.8, 0.9, 0.5]),
            BoundingBox(min: [-0.5, 5, -0.5], max: [0.5, 5.5, 0.5]),
            BoundingBox(min: [1.05, 0, -0.5], max: [2, 1, 0.5]),
            // Under it and touching, which its leaving can shift.
            BoundingBox(min: [-1, -0.4, -0.7], max: [1, 0, 0.7]),
            // Beside it and under it, out of reach.
            BoundingBox(min: [1.2, 0, -0.7], max: [3, 4, 0.7]),
            BoundingBox(min: [-1, -0.6, -0.7], max: [1, -0.2, 0.7]),
        ]
        XCTAssertEqual(BookFlight.disturbed(by: book, among: others), [0, 1, 2, 3])
        XCTAssertEqual(BookFlight.disturbed(by: book, among: []), [])
    }

    func testMostBuriedBookHasTheMostBooksOverIt() {
        let bottom = BoundingBox(min: [-1, 0, -1], max: [1, 0.3, 1])
        let middle = BoundingBox(min: [-0.8, 0.3, -0.8], max: [0.8, 0.6, 0.8])
        let top = BoundingBox(min: [-0.5, 0.6, -0.5], max: [0.5, 0.9, 0.5])
        let aside = BoundingBox(min: [3, 0, 3], max: [4, 0.3, 4])
        XCTAssertEqual(BookFlight.mostBuried([top, aside, bottom, middle]), 2)
        XCTAssertNil(BookFlight.mostBuried([]))
    }

    func testFlightLeavesTheRiseAtItsSpeedAndSettlesOnTheTarget() {
        let rise: Float = 1.2
        let end = BookFlight.riseDuration(rise)
        // A book with nothing on it leaves sooner than one under a stack.
        XCTAssertLessThan(BookFlight.riseDuration(0.4), end)
        XCTAssertEqual(BookFlight.riseDuration(6), 0.3, accuracy: 1e-6)
        XCTAssertEqual(BookFlight.landing(rise: rise), end + BookFlight.spring.duration)
        XCTAssertEqual(BookFlight.climb(rise, at: 0), 0)
        XCTAssertEqual(BookFlight.climb(rise, at: end), rise, accuracy: 0.0001)
        let step = 0.0001
        let riseSpeed =
            (BookFlight.climb(rise, at: end) - BookFlight.climb(rise, at: end - step))
            / Float(step)
        XCTAssertEqual(riseSpeed, BookFlight.topSpeed(rise), accuracy: 0.05)

        let clear = Transform(rotation: PileLayout.lyingFlat, translation: [1, 2, -2])
        let target = Transform(
            rotation: simd_quatf(angle: 2.5, axis: simd_normalize([0.3, 1, 0.2])),
            translation: [0, 20, 10])
        func pose(_ time: Double) -> Transform {
            BookFlight.pose(
                from: clear, speed: BookFlight.topSpeed(rise), to: target, time: time)
        }
        // The flight starts where the rise ends, at the rise's speed, with no hard stop.
        XCTAssertEqual(simd_distance(pose(0).translation, clear.translation), 0, accuracy: 0.0001)
        let velocity = (pose(step).translation - pose(0).translation) / Float(step)
        XCTAssertEqual(
            simd_distance(velocity, [0, BookFlight.topSpeed(rise), 0]), 0, accuracy: 0.2)
        // It overshoots a little, then settles on the target.
        let distance = simd_distance(target.translation, clear.translation)
        let farthest = stride(from: 0, through: 2, by: 0.01)
            .map {
                simd_dot(
                    pose($0).translation - clear.translation, target.translation - clear.translation
                ) / distance
            }
            .max()!
        XCTAssertGreaterThan(farthest, distance)
        XCTAssertLessThan(farthest, distance * 1.05)
        let landed = pose(3)
        XCTAssertEqual(simd_distance(landed.translation, target.translation), 0, accuracy: 0.01)
        // A quaternion and its negation are the same rotation.
        XCTAssertEqual(
            abs(simd_dot(landed.rotation.vector, target.rotation.vector)), 1, accuracy: 0.0001)
    }

    func testThrowBackLandsWhereTheBookLay() {
        let start = SIMD3<Float>(0, 20, 10)
        let resting = SIMD3<Float>(1, 0.3, -2)
        let gravity = SIMD3<Float>(0, -PileLayout.gravity, 0)
        let velocity = BookFlight.launch(from: start, to: resting, gravity: gravity)
        let time = BookFlight.whipDuration(from: start, to: resting)
        let landed = start + velocity * time + gravity * time * time / 2
        XCTAssertEqual(simd_distance(landed, resting), 0, accuracy: 0.001)
        // Fast enough to scatter the books it hits, and tumbling.
        XCTAssertGreaterThan(simd_length(velocity), 40)
        // A short throw takes the shortest time; a long one takes longer, so it flies no faster
        // on average than `whipSpeed`.
        XCTAssertEqual(
            BookFlight.whipDuration(from: [0, 10, 5], to: [0, 0.3, 0]), BookFlight.whipDuration)
        let far = SIMD3<Float>(20, 30, 25)
        let farTime = BookFlight.whipDuration(from: far, to: resting)
        XCTAssertEqual(simd_distance(far, resting) / farTime, BookFlight.whipSpeed, accuracy: 0.001)
        let farVelocity = BookFlight.launch(from: far, to: resting, gravity: gravity)
        XCTAssertEqual(
            simd_distance(far + farVelocity * farTime + gravity * farTime * farTime / 2, resting),
            0, accuracy: 0.001)
        XCTAssertGreaterThan(simd_length(BookFlight.spin(for: velocity)), 10)
        XCTAssertEqual(
            simd_length(BookFlight.spin(for: [0, -50, 0])), simd_length(SIMD2<Float>(10, 8)),
            accuracy: 0.001)
    }

    func testLiftedBookIsShadedLikeTheDetailsBook() {
        let size = SIMD3<Float>(1.5, 2.25, 0.3)
        let shades = BookFlight.shades(of: size, at: .resting)
        XCTAssertEqual(shades.count, 4)
        // At rest, `Book3DView` darkens the cover to about 76 percent and the spine a little
        // less, since the spine turns toward its light from the upper left.
        XCTAssertEqual(shades[0], 0.24, accuracy: 0.01)
        XCTAssertLessThan(shades[1], shades[0])
        // Facing the viewer squarely, the cover takes more of the light.
        XCTAssertLessThan(BookFlight.shades(of: size, at: BookPose(yaw: 0, pitch: 0))[0], shades[0])
    }

    func testCameraMixesTowardAnother() {
        let start = PileCamera(target: [2, 0, -1], yaw: 0.5, zoom: 2)
        let end = PileCamera(yaw: 0.5)
        XCTAssertEqual(start.mixed(with: end, 0), start)
        XCTAssertEqual(start.mixed(with: end, 1), end)
        XCTAssertEqual(start.mixed(with: end, 0.5).zoom, 1.5)
    }

    func testCoversAreCroppedToTheBoxLikeTheDetailsView() {
        // A square cover on a box clamped to 0.85 keeps its middle 85 percent of width.
        XCTAssertEqual(
            PileLayout.crop(CGSize(width: 200, height: 200), to: 0.85),
            CGRect(x: 15, y: 0, width: 170, height: 200))
        // A narrow cover keeps its middle height.
        XCTAssertEqual(
            PileLayout.crop(CGSize(width: 100, height: 250), to: 0.5),
            CGRect(x: 0, y: 25, width: 100, height: 200))
        // A cover that already fits is untouched.
        XCTAssertEqual(
            PileLayout.crop(CGSize(width: 150, height: 225), to: 2 / 3),
            CGRect(x: 0, y: 0, width: 150, height: 225))
    }
}
