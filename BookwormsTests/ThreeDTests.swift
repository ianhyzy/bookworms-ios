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
            for size: SIMD3<Float> in [[1.5, 2.25, 0.18], [1.2, 2.1, 0.1], [2.05, 2.4, 0.48]] {
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
            XCTAssertEqual(Set(ribbon.slots), [0])
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

    func testLampPoolCoversItsRadius() {
        let placement = DeskStage.lampPlacement(pool: [0, 0, 1], radius: 7)
        XCTAssertGreaterThan(placement.position.y, 15)
        // The pool's far edge, nearest the lamp, and its near edge both lie inside the cone.
        let axis = simd_normalize(placement.aim - placement.position)
        for edge: SIMD3<Float> in [[0, 0, -6], [0, 0, 8]] {
            let angle = acos(simd_dot(axis, simd_normalize(edge - placement.position))) * 180 / .pi
            XCTAssertLessThan(angle, placement.outerAngle / 2)
        }
        let edge = atan(7 / placement.distance) * 180 / .pi
        XCTAssertGreaterThan(placement.outerAngle / 2, edge)
        XCTAssertLessThan(placement.innerAngle / 2, edge)
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
