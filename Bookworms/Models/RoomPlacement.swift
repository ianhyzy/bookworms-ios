import Foundation
import RealityKit

/// Where **View in my room** puts a time frame's books in the camera's world, at their real
/// size: one stack on a table (`BookTower`), or a row standing in an empty shelf
/// (`ShelfFill`).
///
/// The books' scenes measure in decimeters, as `BookShape` does, and ARKit's world in meters,
/// so each placement's root scales its books by `metersPerUnit`. Nothing here simulates
/// physics: books rest where the layout puts them.
enum RoomPlacement {
    /// Meters per scene unit: a decimeter.
    static let metersPerUnit: Float = 0.1

    /// The most books the room shows, its most popular (`DroppedCard.popular(_:limit:)`).
    /// Forty typical books stack about 1.2 meters tall, about as high as a reader can frame
    /// on a table, and their textures leave the camera and tracking room on older iPhones.
    static let maximumBooks = 40

    /// The pose of a placement's root at `point`, on a level surface: turned about the
    /// vertical so that its +z axis, where the books' spines face, points toward `camera`, and
    /// scaled from scene units to meters. A camera straight above leaves the root unturned.
    static func root(at point: SIMD3<Float>, facing camera: SIMD3<Float>) -> Transform {
        let toward = camera - point
        let turn = simd_length(SIMD2(toward.x, toward.z)) < 1e-4 ? 0 : atan2(toward.x, toward.z)
        return Transform(
            scale: SIMD3(repeating: metersPerUnit),
            rotation: simd_quatf(angle: turn, axis: [0, 1, 0]), translation: point)
    }
}

/// The empty space of a shelf, in scene units: how wide it is along the board and how much
/// room it has above the board.
struct ShelfSpace: Equatable {
    var width: Float
    /// `.infinity` when nothing is above the board, as on top of a bookcase.
    var clearance: Float
}

/// Finds a shelf's empty space around a point on its board by casting rays through the
/// LiDAR scene mesh.
enum ShelfProbe {
    /// How far the probes look for the back of the shelf, in meters.
    static let deepest: Float = 0.6
    /// How far each probe looks along the board, in meters.
    static let widest: Float = 1.5
    /// How high above the board the probes along it run, in meters: above the board's own
    /// mesh, and below most things standing on it.
    static let probeHeight: Float = 0.05
    /// The distance between the checks that the board continues, in meters.
    static let step: Float = 0.04

    /// The shelf around `point`, a point on the board's top under the reticle, seen from
    /// `camera`: the frame of its space and the space's size, or `nil` when no back stands
    /// within `deepest` behind the point.
    ///
    /// `cast(origin, direction, length)` returns the distance, in meters, to the first scene
    /// surface along a ray, or `nil` if there is none within `length`. The frame's origin is
    /// the space's left end, where the board meets the back; its +x runs along the board to
    /// the right, its +y up, and its +z out of the shelf toward the camera, and it scales
    /// scene units to meters as `RoomPlacement.root` does. The space ends at each side where
    /// a ray along the board meets something, such as a side panel or a vase, or where the
    /// board itself ends, so no book stands over air.
    static func measure(
        at point: SIMD3<Float>, from camera: SIMD3<Float>,
        cast: (SIMD3<Float>, SIMD3<Float>, Float) -> Float?
    ) -> (frame: Transform, space: ShelfSpace)? {
        let up = SIMD3<Float>(0, 1, 0)
        let level = SIMD3(point.x - camera.x, 0, point.z - camera.z)
        guard simd_length(level) > 1e-4 else { return nil }
        let inward = simd_normalize(level)
        let right = simd_cross(inward, up)
        let raised = point + up * probeHeight
        guard let back = cast(raised, inward, deepest) else { return nil }
        let clearance = cast(point + up * 0.01, up, 1).map { $0 + 0.01 } ?? .infinity
        // Along the board halfway to the back, where books will stand.
        let middle = raised + inward * (back / 2)
        func reach(_ direction: SIMD3<Float>) -> Float {
            let blocked = cast(middle, direction, widest) ?? widest
            var supported: Float = 0
            while supported + step <= blocked {
                let probe = middle + direction * (supported + step)
                guard cast(probe, -up, probeHeight + 0.03) != nil else { break }
                supported += step
            }
            return supported
        }
        let left = reach(-right)
        let width = left + reach(right)
        let origin = point + inward * back - right * left
        let frame = Transform(
            scale: SIMD3(repeating: RoomPlacement.metersPerUnit),
            rotation: simd_quatf(angle: atan2(-inward.x, -inward.z), axis: up),
            translation: origin)
        let units = 1 / RoomPlacement.metersPerUnit
        return (frame, ShelfSpace(width: width * units, clearance: clearance * units))
    }
}

/// A time frame's books in an empty shelf, in the frame `ShelfProbe` measures: standing
/// upright from the left end, spines out, fore edges near the back, with the last three lying
/// flat as a bookend, as a reader shelves books by hand.
///
/// The shelf shows the most popular books that fit (`DroppedCard.popular(_:limit:)`), up to
/// `RoomPlacement.maximumBooks`, in finishing order from the left. Books taller than the
/// shelf's clearance can't stand in it and are left out. Three or fewer books lie flat as one
/// small stack. A shelf longer than the books leaves its right end empty.
struct ShelfFill {
    /// Each book's pose: its middle, and its turn from the book's own axes.
    let slots: [BookTower.Slot]
    /// How far along the board the books reach, in units.
    let width: Float

    /// The gap between the last standing book and the bookend, in units: half a centimeter.
    static let bookendGap: Float = 0.05
    /// How many books lie flat at the end.
    static let bookendCount = 3

    /// Shelves `books`, given oldest first, at the shapes `shape` gives them, in `space`.
    /// `seed` varies how far each spine sits from the board's front, so the row looks placed
    /// by hand.
    init(
        books: [CloudBook], space: ShelfSpace, seed: UInt64,
        shape: (CloudBook) -> BookShape = { BookShape(of: $0, coverAspect: 2 / 3) }
    ) {
        let standing = books.filter { shape($0).size.y <= space.clearance }
        var count = min(standing.count, RoomPlacement.maximumBooks)
        while count > 0 {
            let shown = DroppedCard.popular(standing, limit: count)
            if let fill = ShelfFill(layout: shown, in: space, seed: seed, shape: shape) {
                self = fill
                return
            }
            count -= 1
        }
        slots = []
        width = 0
    }

    /// Lays out `books` in `space`, or returns `nil` when they don't fit.
    private init?(
        layout books: [CloudBook], in space: ShelfSpace, seed: UInt64,
        shape: (CloudBook) -> BookShape
    ) {
        let shapes = books.map(shape)
        let flat = books.count <= Self.bookendCount ? books.count : Self.bookendCount
        let upright = books.count - flat
        // A standing book's thickness runs along the board; a lying one's length does.
        let rowWidth = shapes.prefix(upright).reduce(0) { $0 + $1.size.z }
        let bookend = shapes.suffix(flat).map(\.size.y).max() ?? 0
        let gap = upright > 0 && flat > 0 ? Self.bookendGap : 0
        let pile = shapes.suffix(flat).reduce(0) { $0 + $1.size.z }
        guard rowWidth + gap + bookend <= space.width, pile <= space.clearance else {
            return nil
        }
        // Standing spine out: the book's x axis, spine to fore edge, points into the shelf.
        let standing = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        var x: Float = 0
        var slots: [BookTower.Slot] = []
        for (book, shape) in zip(books.prefix(upright), shapes.prefix(upright)) {
            let inset = Float(ShareStyle.unit(seed, book.id, 93)) * 0.1
            slots.append(
                .init(
                    book: book, shape: shape,
                    transform: Transform(
                        rotation: standing,
                        translation: [
                            x + shape.size.z / 2, shape.size.y / 2, inset + shape.size.x / 2,
                        ])))
            x += shape.size.z
        }
        // The bookend: the largest book at the bottom, each flat on the one below.
        let center = x + gap + bookend / 2
        var y: Float = 0
        let lying = zip(books.suffix(flat), shapes.suffix(flat))
            .sorted { $0.1.size.x * $0.1.size.y > $1.1.size.x * $1.1.size.y }
        for (book, shape) in lying {
            let shift = (Float(ShareStyle.unit(seed, book.id, 94)) * 2 - 1) * 0.08
            let turn = Float(StackArrangement.twist(of: book, seed: seed, maximum: 0.05))
            slots.append(
                .init(
                    book: book, shape: shape,
                    transform: Transform(
                        rotation: simd_quatf(angle: turn, axis: [0, 1, 0]) * PileLayout.lyingFlat,
                        translation: [
                            center + shift, y + shape.size.z / 2, 0.05 + shape.size.x / 2,
                        ])))
            y += shape.size.z
        }
        self.slots = slots
        width = x + gap + bookend
    }
}
