import Foundation
import XCTest
import simd

@testable import Bookworms

/// The shared 3D pieces: book shapes and meshes, page edges, the lamp, and impact feedback.
final class ThreeDTests: XCTestCase {
    private func book(_ id: Int, pages: Int? = 320) -> CloudBook {
        var book = CloudBook(
            id: id, title: "Fictional Book \(id)", author: "An Author", coverURL: nil,
            detailCoverURL: nil)
        book.pages = pages
        return book
    }

    func testShapesSnapToTheMeshGrid() {
        let shape = BookShape(size: [1.51, 2.26, 0.171], binding: .hardcover)
        XCTAssertEqual(shape.cells, [30, 45, 9])
        XCTAssertEqual(shape.size.x, 1.5, accuracy: 0.0001)
        XCTAssertEqual(shape.size.y, 2.25, accuracy: 0.0001)
        XCTAssertEqual(shape.size.z, 0.18, accuracy: 0.0001)
        // Nearby sizes share a shape, and so a mesh.
        XCTAssertEqual(shape, BookShape(size: [1.49, 2.24, 0.179], binding: .hardcover))
        XCTAssertNotEqual(shape, BookShape(size: [1.51, 2.26, 0.171], binding: .paperback))
    }

    func testBindingIsStableAndFavorsHardcoversForNewReleases() {
        let books = (1...400).map { book($0) }
        XCTAssertEqual(books.map(\.binding), books.map(\.binding))
        func hardcovers(_ books: [CloudBook]) -> Int {
            books.filter { $0.binding == .hardcover }.count
        }
        let old = hardcovers(books)
        let new = hardcovers(
            books.map { book in
                var book = book
                book.finished = "2025-06-01"
                book.publicationYear = 2025
                return book
            })
        XCTAssertGreaterThan(old, 100)
        XCTAssertLessThan(old, 220)
        XCTAssertGreaterThan(new, 250)
    }

    /// Checks that a mesh lies within `half` of the origin, faces outward from it, and uses
    /// only `slots`.
    private func checkMesh(
        _ mesh: BookGeometry, within half: SIMD3<Float>, slots: Set<UInt32>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(mesh.indices.count, mesh.slots.count * 3, file: file, line: line)
        XCTAssertEqual(mesh.positions.count, mesh.normals.count, file: file, line: line)
        XCTAssertEqual(mesh.positions.count, mesh.coordinates.count, file: file, line: line)
        XCTAssertEqual(Set(mesh.slots), slots, file: file, line: line)
        for position in mesh.positions {
            XCTAssertTrue(
                all(abs(position) .<= half + 0.0001), "\(position) outside \(half)", file: file,
                line: line)
        }
        for normal in mesh.normals {
            XCTAssertEqual(simd_length(normal), 1, accuracy: 0.001, file: file, line: line)
        }
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            let corners = mesh.indices[triangle..<triangle + 3].map { mesh.positions[Int($0)] }
            let facing = simd_cross(corners[1] - corners[0], corners[2] - corners[0])
            let normal = mesh.indices[triangle..<triangle + 3].map { mesh.normals[Int($0)] }
                .reduce(.zero, +)
            XCTAssertGreaterThanOrEqual(simd_dot(facing, normal), 0, file: file, line: line)
        }
    }

    func testBookMeshesFillTheirBoxWithEveryMaterialSlot() {
        for binding in [BookBinding.hardcover, .paperback] {
            // A typical book, a thin one, a thick one, the largest, and a short paperback.
            for size: SIMD3<Float> in [
                [1.5, 2.25, 0.18], [1.2, 2.1, 0.1], [2.05, 2.4, 0.48], [2.4, 2.8, 0.52],
                [1.15, 1.7, 0.08],
            ] {
                let shape = BookShape(size: size, binding: binding)
                let mesh = BookGeometry.book(shape)
                checkMesh(mesh, within: shape.size / 2, slots: [0, 1, 2, 3])
                // The mesh reaches each face of its box.
                let low = mesh.positions.reduce(SIMD3(repeating: .infinity), pointwiseMin)
                let high = mesh.positions.reduce(SIMD3(repeating: -.infinity), pointwiseMax)
                XCTAssertLessThan(simd_length(low + shape.size / 2), 0.0001)
                XCTAssertLessThan(simd_length(high - shape.size / 2), 0.0001)
            }
        }
    }

    func testHardcoverPagesSitInsideTheBoardsAndPaperbackPagesAreFlush() {
        func pageTop(_ binding: BookBinding) -> Float {
            let mesh = BookGeometry.book(BookShape(size: [1.5, 2.25, 0.18], binding: binding))
            return zip(mesh.indices, mesh.indices.indices)
                .filter { mesh.slots[$1 / 3] == BookSlot.pages }
                .map { mesh.positions[Int($0.0)].y }
                .max() ?? 0
        }
        XCTAssertEqual(pageTop(.hardcover), 2.25 / 2 - 0.035, accuracy: 0.0001)
        XCTAssertEqual(pageTop(.paperback), 2.25 / 2, accuracy: 0.0001)
    }

    func testSpineImageKeepsOneScaleAcrossTheCurve() {
        for binding in [BookBinding.hardcover, .paperback] {
            let shape = BookShape(size: [1.5, 2.25, 0.18], binding: binding)
            let mesh = BookGeometry.book(shape)
            // The spine face's corners along its tail edge, in order around the curve.
            let bevel = min(binding == .hardcover ? 0.008 : 0.004, shape.board * 0.6)
            let tail = -shape.size.y / 2 + bevel
            var corners: [(point: SIMD2<Float>, v: Float)] = []
            for (triangle, slot) in mesh.slots.enumerated() where slot == BookSlot.spine {
                for index in mesh.indices[triangle * 3..<triangle * 3 + 3].map(Int.init) {
                    let position = mesh.positions[index]
                    guard abs(position.y - tail) < 0.0001,
                        !corners.contains(where: { $0.v == mesh.coordinates[index].y })
                    else { continue }
                    corners.append((SIMD2(position.x, position.z), mesh.coordinates[index].y))
                }
            }
            corners.sort { $0.v < $1.v }
            XCTAssertEqual(corners.count, 15)
            let lengths = zip(corners, corners.dropFirst())
                .map { simd_distance($0.point, $1.point) }
            let total = lengths.reduce(0, +)
            for (index, length) in lengths.enumerated() {
                XCTAssertEqual(
                    corners[index + 1].v - corners[index].v, length / total, accuracy: 0.002,
                    "\(binding) segment \(index)")
            }
        }
    }

    func testCoverFillsTheFrontBoardAndFoldsOverItsEdges() {
        let shape = BookShape(size: [1.5, 2.25, 0.3], binding: .hardcover)
        XCTAssertEqual(shape.coverAspect, (1.5 - shape.spineDepth) / 2.25, accuracy: 0.0001)
        let mesh = BookGeometry.book(shape)
        let half = shape.size / 2
        var front: [SIMD2<Float>] = []
        var head: [Float] = []
        for (triangle, slot) in mesh.slots.enumerated() where slot == BookSlot.cover {
            for index in mesh.indices[triangle * 3..<triangle * 3 + 3].map(Int.init) {
                let position = mesh.positions[index]
                if abs(position.z - half.z) < 0.0001 { front.append(mesh.coordinates[index]) }
                if abs(position.y - half.y) < 0.0001 { head.append(mesh.coordinates[index].y) }
            }
        }
        // The front face spans the image from the spine's joint to the fore edge.
        XCTAssertEqual(front.map(\.x).min() ?? 1, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(front.map(\.x).max() ?? 0, 0.99)
        // The head's edge shows a band inside the image's top border as deep as the board.
        let fold = (head.max() ?? 0) - (head.min() ?? 0)
        XCTAssertEqual(fold, (shape.board - 0.008) / shape.size.y, accuracy: 0.0001)
    }

    func testSpineProfileMeetsTheCoversSquare() {
        for exponent: Float in [2, 4] {
            let profile = BookGeometry.spineProfile(
                x: -0.6, depth: 0.04, half: 0.09, exponent: exponent, segments: 14)
            XCTAssertEqual(profile.first?.point.y ?? 0, -0.09, accuracy: 0.0001)
            XCTAssertEqual(profile.last?.point.y ?? 0, 0.09, accuracy: 0.0001)
            XCTAssertEqual(profile[7].point.x, -0.64, accuracy: 0.0001)
            XCTAssertEqual(profile.first?.normal.y ?? 0, -1, accuracy: 0.0001)
            XCTAssertEqual(profile.last?.normal.y ?? 0, 1, accuracy: 0.0001)
            XCTAssertEqual(profile[7].normal.x, -1, accuracy: 0.0001)
        }
    }

    func testRibbonHangsFromTheTailToTheBackCover() {
        let shape = BookShape(size: [1.5, 2.25, 0.3], binding: .hardcover)
        let half = shape.size / 2
        for progress: Float in [0, 0.5, 1] {
            let ribbon = BookGeometry.ribbon(shape, progress: progress)
            checkMesh(ribbon, within: half + [0, 0.5, 0], slots: [0])
            let low = ribbon.positions.reduce(SIMD3(repeating: .infinity), pointwiseMin)
            XCTAssertLessThan(low.y, -half.y - 0.4)
            XCTAssertGreaterThan(low.z, -half.z)
        }
        // A ribbon further into the book leaves the pages closer to the back cover.
        func start(_ progress: Float) -> Float {
            BookGeometry.ribbon(shape, progress: progress).positions[0].z
        }
        XCTAssertGreaterThan(start(0.2), start(0.8))
    }

    func testPageEdgesYellowWithAgeAndFiveStarBooksAreSprayed() {
        let accent = ColorValue(red: 180, green: 30, blue: 40)
        let now = try! Date("2026-10-01T12:00:00Z", strategy: .iso8601)
        var fresh = book(1)
        XCTAssertEqual(PageEdges.color(of: fresh, accent: accent, now: now), PageEdges.fresh)
        fresh.finished = "2026-09-01"
        var old = fresh
        old.finished = "2014-01-01"
        var ancient = fresh
        ancient.finished = "1990-01-01"
        let recent = PageEdges.color(of: fresh, accent: accent, now: now)
        let aged = PageEdges.color(of: old, accent: accent, now: now)
        XCTAssertLessThan(aged.blue, recent.blue)
        XCTAssertEqual(PageEdges.color(of: ancient, accent: accent, now: now), PageEdges.aged)
        var loved = old
        loved.rating = 5
        XCTAssertTrue(PageEdges.isSprayed(loved))
        XCTAssertEqual(
            PageEdges.color(of: loved, accent: accent, now: now),
            accent.mixed(with: PageEdges.fresh, 0.12))
    }

    func testLampLightsThePoolAndTheFacesTowardTheCamera() {
        let pool: SIMD3<Float> = [0, 0, 1]
        let placement = DeskStage.lampPlacement(pool: pool, radius: 7)
        // High above the ceiling, which every drop starts under, and toward the camera, so
        // faces turned toward the camera (+z) catch its light.
        XCTAssertGreaterThan(placement.position.y, PileLayout.ceiling + 4)
        XCTAssertGreaterThan(placement.position.z, pool.z + 7)
        XCTAssertEqual(placement.aim, pool)
        func angle(to point: SIMD3<Float>) -> Float {
            let axis = simd_normalize(placement.aim - placement.position)
            return acos(simd_dot(axis, simd_normalize(point - placement.position))) * 180 / .pi
        }
        // Full light spans the middle of the pool, and light reaches every edge.
        XCTAssertLessThan(angle(to: pool + [0, 0, 3]), placement.innerAngle / 2)
        XCTAssertLessThan(angle(to: pool + [3, 0, 0]), placement.innerAngle / 2)
        for edge: SIMD3<Float> in [[0, 0, -7], [0, 0, 7], [-7, 0, 0], [7, 0, 0]] {
            XCTAssertGreaterThan(angle(to: pool + edge), placement.innerAngle / 2)
            XCTAssertLessThan(angle(to: pool + edge), placement.outerAngle / 2)
        }
    }

    func testImpactStrengthFollowsSpeedAndMass() {
        XCTAssertEqual(ImpactSound.strength(impulse: 0.5, mass: 0.5), 0)
        let light = ImpactSound.strength(impulse: 0.3 * 10, mass: 0.3)
        let heavy = ImpactSound.strength(impulse: 0.9 * 10, mass: 0.9)
        XCTAssertGreaterThan(heavy, light)
        XCTAssertLessThan(
            ImpactSound.strength(impulse: 0.5 * 6, mass: 0.5),
            ImpactSound.strength(impulse: 0.5 * 12, mass: 0.5))
        XCTAssertEqual(ImpactSound.strength(impulse: 100, mass: 1), 1)
        XCTAssertEqual(ImpactSound.kind(mass: 0.9), .thud)
        XCTAssertEqual(ImpactSound.kind(mass: 0.2), .slap)
    }

    func testImpactSoundsAreRepeatableShortAndNormalized() {
        for kind in ImpactSound.Kind.allCases {
            let samples = ImpactSound.samples(kind, variant: 1)
            XCTAssertEqual(samples, ImpactSound.samples(kind, variant: 1))
            XCTAssertNotEqual(samples, ImpactSound.samples(kind, variant: 2))
            XCTAssertLessThanOrEqual(Double(samples.count) / ImpactSound.sampleRate, 0.25)
            XCTAssertEqual(samples.map(abs).max() ?? 0, 0.9, accuracy: 0.0001)
            // It fades out rather than ending in a click.
            XCTAssertLessThan(samples.suffix(100).map(abs).max() ?? 1, 0.05)
        }
    }

    func testABurstOfImpactsLeavesHeadroom() {
        // Eight full-strength sounds 30 to 60 ms apart, the most that overlap, each taking the
        // next variant, panned 0.8 to one side, where the mixer plays a sound at 0.99.
        for kinds in [[ImpactSound.Kind.thud], [.slap], [.thud, .slap]] {
            for spacing in [0.03, 0.04, 0.06] {
                let gap = Int(spacing * ImpactSound.sampleRate)
                var mix = [Float](repeating: 0, count: gap * 8 + 12_000)
                for hit in 0..<8 {
                    let samples = ImpactSound.bank[kinds[hit % kinds.count]]![hit % 4]
                    for (index, sample) in samples.enumerated() { mix[hit * gap + index] += sample }
                }
                let peak = (mix.map(abs).max() ?? 0) * ImpactSound.level * 0.99
                XCTAssertLessThan(peak, 0.92, "\(kinds) \(spacing)")
            }
        }
    }

    @MainActor
    func testRecordingKeepsTheSoundsThatPlay() {
        let feedback = ImpactFeedback()
        feedback.startRecording()
        func hit(_ impulse: Float, mass: Float, after seconds: TimeInterval) {
            feedback.advance(by: seconds)
            feedback.impact(impulse: impulse, mass: mass, position: [1, 0, 0], pan: { $0.x / 2 })
        }
        hit(0.4 * 20, mass: 0.4, after: 0.1)
        // Too soon after the first, and no stronger: throttled.
        hit(0.4 * 20, mass: 0.4, after: 0.01)
        // Too weak to hear.
        hit(0.01, mass: 0.4, after: 0.1)
        hit(0.8 * 20, mass: 0.8, after: 0.1)
        let records = feedback.finishRecording()
        XCTAssertEqual(records.map(\.kind), [.slap, .thud])
        XCTAssertEqual(records.map(\.variant), [0, 1])
        XCTAssertEqual(records[0].time, 0.1, accuracy: 0.0001)
        XCTAssertEqual(records[1].time, 0.31, accuracy: 0.0001)
        XCTAssertEqual(records.map(\.pan), [0.5, 0.5])
        XCTAssertEqual(
            records[0].volume, ImpactSound.strength(impulse: 8, mass: 0.4), accuracy: 0.0001)
        XCTAssertEqual(feedback.finishRecording(), [])
    }

    func testWearFollowsTheReadingHistory() {
        let accent = ColorValue(red: 180, green: 30, blue: 40)
        var reading = book(1)
        reading.isReading = true
        reading.progress = 0.42
        let wear = BookFactory.Wear(reading, accent: accent)
        XCTAssertEqual(wear.ribbon, 4)
        reading.progress = 0.61
        XCTAssertNotEqual(BookFactory.Wear(reading, accent: accent), wear)
        reading.isReading = false
        XCTAssertNil(BookFactory.Wear(reading, accent: accent).ribbon)
        var loved = book(2)
        loved.rating = 5
        XCTAssertTrue(BookFactory.Wear(loved, accent: accent).pages.sprayed)
    }

    func testThrottleLetsBurstsThroughAtABoundedRate() {
        var throttle = ImpactThrottle(interval: 0.05)
        XCTAssertTrue(throttle.admit(0.4, at: 0))
        XCTAssertFalse(throttle.admit(0.5, at: 0.01))
        // Half again as strong breaks through.
        XCTAssertTrue(throttle.admit(0.7, at: 0.02))
        XCTAssertFalse(throttle.admit(0.2, at: 0.06))
        XCTAssertTrue(throttle.admit(0.2, at: 0.08))
    }

    func testThreeDViewsAreTitledByName() {
        XCTAssertEqual(ThreeDView.pile.title, "Pile")
        XCTAssertEqual(ThreeDView(rawValue: "pile"), .pile)
    }
}
