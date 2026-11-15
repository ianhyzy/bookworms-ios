import RealityKit
import XCTest
import simd

@testable import Bookworms

/// The dominoes' setup from the desk: where the lying books move to clear the places, how each
/// book turns up onto its tail and hops, and how the schedule keeps the books apart.
final class DominoSetupTests: XCTestCase {
    private static let up = SIMD3<Float>(0, 1, 0)

    /// Fictional books finished a day apart, with page counts that vary their sizes.
    private func books(_ count: Int) -> [CloudBook] {
        let start = Date(timeIntervalSince1970: 1_577_880_000)
        return (0..<count)
            .map { index in
                var book = CloudBook(
                    id: 5_000 + index, title: "Fictional Book \(index)", author: "An Author",
                    coverURL: nil, detailCoverURL: nil)
                book.pages = 120 + (index * 197) % 900
                book.finished = start.addingTimeInterval(Double(index) * 86_400)
                    .formatted(.iso8601.year().month().day())
                return book
            }
    }

    /// The chain of `count` books, planned for a portrait view.
    private func slots(_ count: Int) -> [DominoSlot] {
        DominoLayout.plan(DominoLayout.chain(books(count)), aspect: 0.4).slots
    }

    /// A book of `size` lying front cover up on the table at `spot`, as x and z, turned `yaw`
    /// about the vertical.
    private func lying(_ size: SIMD3<Float>, at spot: SIMD2<Float>, yaw: Float) -> Transform {
        Transform(
            rotation: simd_quatf(angle: yaw, axis: Self.up) * PileLayout.lyingFlat,
            translation: [spot.x, size.z / 2, spot.y])
    }

    /// The corners of a box of `size` at `pose`.
    private func corners(_ pose: Transform, _ size: SIMD3<Float>) -> [SIMD3<Float>] {
        [-1, 1]
            .flatMap { x in
                [-1, 1]
                    .flatMap { y in
                        [-1, 1]
                            .map { (z: Float) in
                                pose.translation + pose.rotation.act(SIMD3(x, y, z) * size / 2)
                            }
                    }
            }
    }

    // MARK: Moves

    func testABookLyingFlatTurnsUpOntoItsTailEdge() {
        let size = SIMD3<Float>(1.4, 2.2, 0.3)
        let from = lying(size, at: [1, -2], yaw: 0.6)
        let slot = Transform(
            rotation: DominoLayout.standing(heading: [1, 0]), translation: [6, 1.102, 3])
        let move = DominoSetup.Move(start: 0.5, from: from, size: size, to: slot, lift: 2)
        // It starts where it lies, and turns a quarter turn, in `quarterTurn`.
        XCTAssertEqual(move.angle, .pi / 2, accuracy: 1e-4)
        XCTAssertEqual(move.rightingTime, DominoSetup.quarterTurn, accuracy: 1e-4)
        XCTAssertEqual(move.pose(at: 0).translation, from.translation)
        XCTAssertEqual(move.pose(at: 0.5).translation, from.translation)
        // It turns about the bottom of its tail edge, which stays on the table, and no corner
        // dips below the table on the way.
        XCTAssertEqual(move.pivot.y, 0, accuracy: 1e-4)
        for step in 0...20 {
            let pose = move.pose(at: 0.5 + move.rightingTime * Float(step) / 20)
            XCTAssertGreaterThan(corners(pose, size).map(\.y).min()!, -1e-3, "\(step)")
        }
        // It ends standing on its tail, upright, on the table, where it lay.
        let upright = move.pose(at: 0.5 + move.rightingTime)
        XCTAssertEqual(upright.rotation.act([0, 1, 0]).y, 1, accuracy: 1e-4)
        XCTAssertEqual(upright.translation.y, size.y / 2, accuracy: 1e-3)
        XCTAssertLessThan(
            simd_distance(SIMD2(upright.translation.x, upright.translation.z), [1, -2]),
            size.y / 2 + size.z)
    }

    func testAFallenDominoRisesBackTheWayItFell() {
        let slot = slots(12)[5]
        let place = DominoLayout.standingPose(of: slot)
        // Tipped 80 degrees forward about its leading bottom edge, the back cover's.
        let forward = SIMD3(slot.heading.x, 0, slot.heading.y)
        let edge = SIMD3(slot.position.x, 0.002, slot.position.y) + forward * slot.size.z / 2
        let tip = simd_quatf(
            angle: 80 * .pi / 180, axis: simd_normalize(simd_cross(Self.up, forward)))
        let fallen = Transform(
            rotation: tip * place.rotation, translation: edge + tip.act(place.translation - edge))
        let move = DominoSetup.Move(start: 0, from: fallen, size: slot.size, to: place, lift: 0.5)
        // It turns back up about that edge and stands where it stood.
        XCTAssertEqual(move.angle, 80 * .pi / 180, accuracy: 1e-3)
        XCTAssertLessThan(simd_distance(move.upright.translation, place.translation), 0.01)
        XCTAssertEqual(
            abs(simd_dot(move.upright.rotation.vector, place.rotation.vector)), 1, accuracy: 1e-4)
    }

    func testAHopStaysUprightAndDropsStraightIntoItsSlot() {
        let size = SIMD3<Float>(1.3, 2.4, 0.4)
        let from = lying(size, at: [-4, 6], yaw: 2.1)
        let slot = Transform(
            rotation: DominoLayout.standing(heading: simd_normalize([1, 1])),
            translation: [5, size.y / 2 + 0.002, -3])
        let move = DominoSetup.Move(start: 0, from: from, size: size, to: slot, lift: 3)
        let leaves = move.rightingTime
        for step in 0...40 {
            let time = leaves + move.hopTime * Float(step) / 40
            let pose = move.pose(at: time)
            // Upright all the way: it turns about the vertical only.
            XCTAssertEqual(pose.rotation.act([0, 1, 0]).y, 1, accuracy: 1e-4, "\(step)")
            // Past `arrival` of the hop, it is over its slot and only drops.
            if Float(step) / 40 >= DominoSetup.arrival {
                XCTAssertEqual(pose.translation.x, slot.translation.x, accuracy: 1e-3)
                XCTAssertEqual(pose.translation.z, slot.translation.z, accuracy: 1e-3)
                XCTAssertGreaterThanOrEqual(pose.translation.y, slot.translation.y - 1e-4)
            }
        }
        // It lands in its slot, falling as fast as the arc's gravity makes it.
        XCTAssertLessThan(
            simd_distance(move.pose(at: move.end).translation, slot.translation), 1e-3)
        XCTAssertEqual(move.hopTime, (8 * 3 / DominoSetup.hopGravity).squareRoot(), accuracy: 1e-4)
        XCTAssertTrue(move.isHopping(at: leaves + 0.01))
        XCTAssertFalse(move.isHopping(at: leaves - 0.01))
        XCTAssertFalse(move.isHopping(at: move.end))
    }

    func testAHopClearsTheBooksItPassesOver() {
        let size = SIMD3<Float>(1.3, 2.2, 0.3)
        let standing = DominoLayout.standing(heading: [1, 0])
        let upright = Transform(rotation: standing, translation: [-8, size.y / 2, 0])
        let slot = Transform(rotation: standing, translation: [8, size.y / 2, 0])
        // A tall book standing halfway, and one standing beside where the hop starts.
        let tall = DominoSetup.Box(
            Transform(rotation: standing, translation: [0, 1.4, 0]), size: [1.5, 2.8, 0.5])
        let beside = DominoSetup.Box(
            Transform(rotation: standing, translation: [-8, 1.4, 0.3]), size: [1.5, 2.8, 0.5])
        let lift = DominoSetup.lift(from: upright, to: slot, size: size, over: [tall, beside])
        let move = DominoSetup.Move(start: 0, from: upright, size: size, to: slot, lift: lift)
        // Over the tall book, its underside clears that book's top.
        for step in 0...200 {
            let pose = move.pose(at: move.hopTime * Float(step) / 200)
            guard abs(pose.translation.x) < (size.z + 0.5) / 2 else { continue }
            XCTAssertGreaterThanOrEqual(
                pose.translation.y - size.y / 2, 2.8 + DominoSetup.clearance - 0.02, "\(step)")
        }
        // The book it starts beside does not raise the arc: it rises out from beside it.
        let low = DominoSetup.lift(from: upright, to: slot, size: size, over: [beside])
        XCTAssertEqual(low, DominoSetup.lifts.lowerBound)
        XCTAssertLessThanOrEqual(lift, DominoSetup.lifts.upperBound)
    }

    @MainActor func testAMoveTurnsUpAndHopsWithoutAJump() {
        let slots = slots(12)
        // A book lying flat, a fallen domino, and a book that waits on its tail before the
        // highest hop, each going to its slot as the scene sends it.
        let fallen = { (slot: DominoSlot) -> Transform in
            let place = DominoLayout.standingPose(of: slot)
            let forward = SIMD3(slot.heading.x, 0, slot.heading.y)
            let edge = SIMD3(slot.position.x, 0, slot.position.y) + forward * slot.size.z / 2
            let tip = simd_quatf(
                angle: 80 * .pi / 180, axis: simd_normalize(simd_cross(Self.up, forward)))
            return Transform(
                rotation: tip * place.rotation,
                translation: edge + tip.act(place.translation - edge))
        }
        func move(
            of slot: DominoSlot, from: Transform, lift: Float, wait: Float = 0
        ) -> (DominoSlot, DominoSetup.Move) {
            let place = DominoLayout.standingPose(of: slot)
            return (
                slot,
                DominoSetup.Move(
                    start: 0.1, from: from, size: slot.size, to: place, lift: lift, wait: wait)
            )
        }
        let moves = [
            move(
                of: slots[2], from: lying(slots[2].size, at: [-4, 6], yaw: 2.1),
                lift: DominoSetup.lifts.lowerBound),
            move(of: slots[5], from: fallen(slots[5]), lift: DominoSetup.lifts.lowerBound),
            move(
                of: slots[9], from: lying(slots[9].size, at: [7, -3], yaw: 0.6),
                lift: DominoSetup.lifts.upperBound, wait: 0.2),
        ]
        for (index, (slot, move)) in moves.enumerated() {
            let camera = PileCamera(target: [slot.position.x, 0, slot.position.y]).transform
            func sample(at time: Float) -> MotionSample {
                MotionCheck.sample(move.pose(at: time), size: slot.size, camera: camera)
            }
            let first = move.start - 0.05
            let times = (0...Int((move.end + 0.05 - first) / MotionCheck.fine))
                .map { first + Float($0) * MotionCheck.fine }
            // The hop leaves at its launch speed and lands falling, as a thrown book does
            // (`DominoSetup.Move.hop`), so it starts and ends with a step in velocity.
            let kinks = [move.leaves, move.end]
            let cuts = Set(
                kinks.flatMap { time -> [Int] in
                    let index = Int((time - first) / MotionCheck.fine)
                    return [index, index + 1]
                })
            assertContinuous(times.map(sample(at:)), cuts: cuts, "Move \(index)")
            // Across those steps, the book moves on from where it was.
            for time in kinks {
                assertHandoff(
                    sample(at: time - 1e-4), sample(at: time + 1e-4), "Move \(index) at \(time)")
            }
            // Once the setup ends, the scene stands the book at its standing pose.
            assertHandoff(
                sample(at: move.end),
                MotionCheck.sample(
                    DominoLayout.standingPose(of: slot), size: slot.size, camera: camera),
                "Move \(index) standing")
        }
    }

    // MARK: Placement

    func testABookOffTheTableDoesNotHoldBackThePilesMove() {
        let slots = slots(40)
        var lying = slots.indices.map { index in
            let size = slots[index].size
            let spot = SIMD2(Float(index % 5) * 2.4 - 4.8, Float(index / 5) * 1.8 - 7)
            return (
                size: size, lying: self.lying(size, at: spot, yaw: Float(index) * 0.3),
                slot: DominoLayout.standingPose(of: slots[index])
            )
        }
        let offset = DominoSetup.offset(of: lying, aspect: 0.46)
        XCTAssertNotEqual(offset, .zero)
        // Past the reach that every move keeps to, it would rule out every move.
        lying[20].lying.translation = [633, -691, -70]
        XCTAssertEqual(DominoSetup.offset(of: lying, aspect: 0.46), offset)
        // Under the table, it would keep a slot from clearing where nothing lies.
        lying[20].lying.translation = [slots[3].position.x, -40, slots[3].position.y]
        XCTAssertEqual(DominoSetup.offset(of: lying, aspect: 0.46), offset)
        // With every book gone, nothing needs to move.
        for index in lying.indices { lying[index].lying.translation = [0, -40, 0] }
        XCTAssertEqual(DominoSetup.offset(of: lying, aspect: 0.46), .zero)
    }

    func testOnlyABookPastTheTablesEdgeOrUnderItsTopIsOffTheTable() {
        XCTAssertFalse(DominoSetup.isOffTable([3, 0.5, -4]))
        // Pressed into the top, or moved across the table with the pile.
        XCTAssertFalse(DominoSetup.isOffTable([0, -1.4, 0]))
        XCTAssertFalse(DominoSetup.isOffTable([75, 0.5, -75]))
        XCTAssertTrue(DominoSetup.isOffTable([0, -2.5, 0]))
        XCTAssertTrue(DominoSetup.isOffTable([633, -691, -70]))
        XCTAssertTrue(DominoSetup.isOffTable([-85, 0.5, 0]))
        XCTAssertTrue(DominoSetup.isOffTable([0, 0.5, 85]))
    }

    func testAViewOfASetupLeavesOutABookOffTheTable() {
        let outline: [SIMD3<Float>] = [[-20, 0, -30], [20, 3, 30]]
        func book(at position: SIMD3<Float>) -> (position: SIMD3<Float>, bounds: BoundingBox) {
            (position, BoundingBox(min: position - 1, max: position + 1))
        }
        let framed = DominoSetup.framedPoints(
            outline: outline, books: [book(at: [5, 1, -8]), book(at: [633, -691, -70])])
        XCTAssertEqual(
            framed,
            outline + [[4, 0, -9], [6, 2, -7], [4, 0, -7], [6, 0, -9]])
    }

    func testABookOffTheTableFallsFromRestOntoItsPlace() {
        let size = SIMD3<Float>(1.5, 2.3, 0.2)
        let place = Transform(
            rotation: simd_quatf(angle: 0.7, axis: Self.up), translation: [4, size.y / 2, -6])
        let height: Float = 40
        let move = DominoSetup.Move.drop(start: 2, height: height, size: size, to: place)
        let drop = height - place.translation.y

        XCTAssertEqual(move.rightingTime, 0)
        XCTAssertEqual(move.leaves, 2)
        XCTAssertEqual(
            move.end - move.leaves, (2 * drop / DominoSetup.hopGravity).squareRoot(),
            accuracy: 1e-4)
        XCTAssertEqual(move.pose(at: 2).translation.y, height, accuracy: 1e-4)
        XCTAssertLessThan(
            simd_distance(move.pose(at: move.end).translation, place.translation), 1e-3)
        for share: Float in [0.1, 0.5, 0.9] {
            let pose = move.pose(at: move.leaves + (move.end - move.leaves) * share)
            // It speeds up as a falling book does, straight down, without turning.
            XCTAssertEqual(pose.translation.y, height - drop * share * share, accuracy: 1e-3)
            XCTAssertEqual(pose.translation.x, place.translation.x, accuracy: 1e-4)
            XCTAssertEqual(pose.translation.z, place.translation.z, accuracy: 1e-4)
            XCTAssertEqual(
                abs(simd_dot(pose.rotation.vector, place.rotation.vector)), 1, accuracy: 1e-4)
        }
    }

    func testLyingBooksMoveByWholeTilesUntilEverySlotIsClear() {
        let slots = slots(40)
        // A pile over the middle of the table, where the chain stands.
        let lying = slots.indices.map { index in
            let size = slots[index].size
            let spot = SIMD2(Float(index % 5) * 2.4 - 4.8, Float(index / 5) * 1.8 - 7)
            return (
                size: size, lying: self.lying(size, at: spot, yaw: Float(index) * 0.3),
                slot: DominoLayout.standingPose(of: slots[index])
            )
        }
        let offset = DominoSetup.offset(of: lying, aspect: 0.46)
        XCTAssertEqual(offset.y, 0)
        XCTAssertNotEqual(offset, .zero)
        for value in [offset.x, offset.z] {
            XCTAssertEqual(value.remainder(dividingBy: DominoSetup.tile), 0, accuracy: 1e-4)
        }
        // Moved, no book that is still lying when a book lands comes within `pileMargin` of its
        // slot.
        let margin = DominoSetup.pileMargin / 2
        let moved = lying.map { book -> DominoSetup.Footprint in
            var pose = book.lying
            pose.translation += offset
            return DominoSetup.Footprint(DominoSetup.Box(pose, size: book.size)).grown(by: margin)
        }
        for (index, book) in lying.enumerated() {
            let slot = DominoSetup.Footprint(DominoSetup.Box(book.slot, size: book.size))
                .grown(by: margin)
            for later in moved[(index + 1)...] { XCTAssertFalse(slot.overlaps(later), "\(index)") }
        }
    }

    // MARK: Schedule

    func testBooksStartAtAStepWithinTheSpread() {
        for count in [1, 2, 12, 40, 300] {
            let step = DominoSetup.step(count: count)
            XCTAssertLessThanOrEqual(step, DominoSetup.longestStep)
            XCTAssertLessThanOrEqual(step * Float(max(count - 1, 0)), DominoSetup.spread + 1e-4)
            // The books start ever faster, in the same time as at the average step.
            let steps = (0..<max(count - 1, 0)).map { DominoSetup.step(after: $0, count: count) }
            XCTAssertEqual(steps.reduce(0, +), step * Float(max(count - 1, 0)), accuracy: 1e-3)
            for (earlier, later) in zip(steps, steps.dropFirst()) {
                XCTAssertLessThan(later, earlier, "\(count)")
            }
        }
    }

    func testTheScheduleKeepsMovingAndStandingBooksApart() {
        let slots = slots(40)
        let poses = slots.indices.map { index in
            lying(
                slots[index].size, at: [Float(index % 5) * 3 - 6, Float(index / 5) * 3 + 12],
                yaw: Float(index) * 0.7)
        }
        let places = slots.map(DominoLayout.standingPose(of:))
        // A copy of the scene's `arrange(by:)` timing, which the test does not run: books start
        // in order, ever faster, are checked again `retryStep` later while their way is
        // blocked, and are let go once they have waited as long as they may, at the least lift
        // that clears the books in their way. The checks cover `DominoSetup.Schedule`,
        // `longestHold`, and `lift`, not the scene's own bookkeeping.
        var schedule = DominoSetup.Schedule()
        var forced = Set<Int>()
        var blocked = Set<Int>()
        var due: Float = 0
        var held: Float?
        var time: Float = 0
        while schedule.moves.count < slots.count {
            let index = schedule.moves.count
            if time >= due {
                let lying = (index + 1..<slots.count)
                    .map {
                        DominoSetup.Box(poses[$0], size: slots[$0].size)
                    }
                if let move = schedule.move(
                    from: poses[index], size: slots[index].size, to: places[index], at: time,
                    among: lying)
                {
                    schedule.commit(move)
                    held = nil
                    due += DominoSetup.step(after: index, count: slots.count)
                    continue
                }
                held = held ?? time
                blocked.insert(index)
                if let since = held, time - since >= DominoSetup.longestHold {
                    let upright =
                        DominoSetup.Move(
                            start: time, from: poses[index], size: slots[index].size,
                            to: places[index], lift: DominoSetup.lifts.upperBound
                        )
                        .upright
                    schedule.commit(
                        DominoSetup.Move(
                            start: time, from: poses[index], size: slots[index].size,
                            to: places[index],
                            lift: DominoSetup.lift(
                                from: upright, to: places[index], size: slots[index].size,
                                over: lying)))
                    forced.insert(index)
                    held = nil
                    due += DominoSetup.step(after: index, count: slots.count)
                    continue
                }
                due = time + DominoSetup.retryStep
            }
            time += 1.0 / 60
        }
        let moves = schedule.moves
        let end = moves.map(\.end).max() ?? 0
        // Every book stands within a few seconds, in order, and few are let go regardless. This
        // setup takes about 2 seconds.
        XCTAssertLessThan(end, 3)
        XCTAssertEqual(moves.map(\.start), moves.map(\.start).sorted())
        XCTAssertLessThanOrEqual(forced.count, 2)
        // The run holds at least one book, so the checks below cover a held book.
        XCTAssertFalse(blocked.isEmpty)
        // No two books that move or stand overlap, apart from the books let go regardless.
        var sample: Float = 0
        while sample <= end {
            let boxes = moves.enumerated()
                .filter { sample >= $0.element.start && !forced.contains($0.offset) }
                .map {
                    DominoSetup.Box($0.element.pose(at: sample), size: $0.element.size, grow: -0.02)
                }
            for first in boxes.indices {
                for second in boxes.indices where second > first {
                    XCTAssertFalse(
                        boxes[first].overlaps(boxes[second]), "\(sample) \(first) \(second)")
                }
            }
            sample += 1.0 / 60
        }
        // Each lands exactly in its slot.
        for (move, place) in zip(moves, places) {
            XCTAssertLessThan(
                simd_distance(move.pose(at: move.end).translation, place.translation), 1e-3)
        }
    }

    func testABookWhoseHopIsBlockedStandsAndWaits() {
        let size = SIMD3<Float>(1.3, 2.2, 0.3)
        let standing = DominoLayout.standing(heading: [1, 0])
        // Two books that start together and would hop across each other's way at the same
        // moment, the first along x and the second along z.
        let first = DominoSetup.Move(
            start: 0, from: lying(size, at: [-6, 0], yaw: 0), size: size,
            to: Transform(rotation: standing, translation: [6, size.y / 2, 0]),
            lift: DominoSetup.lifts.lowerBound)
        var schedule = DominoSetup.Schedule()
        schedule.commit(first)
        guard
            let move = schedule.move(
                from: lying(size, at: [0, 6], yaw: .pi / 2), size: size,
                to: Transform(
                    rotation: DominoLayout.standing(heading: [0, -1]),
                    translation: [0, size.y / 2, -6]), at: 0, among: [])
        else { return XCTFail("The second book should wait standing rather than be held") }
        // It turns up onto its tail at once, and stands there while the first is in the air.
        XCTAssertGreaterThan(move.wait, 0)
        XCTAssertLessThanOrEqual(move.wait, DominoSetup.longestWait)
        let waiting = move.pose(at: move.start + move.rightingTime + move.wait / 2)
        XCTAssertEqual(
            simd_distance(waiting.translation, move.upright.translation), 0, accuracy: 1e-5)
        XCTAssertFalse(move.isHopping(at: move.start + move.rightingTime + move.wait / 2))
        XCTAssertTrue(move.isHopping(at: move.leaves + 0.01))
        XCTAssertEqual(move.end, move.leaves + move.hopTime, accuracy: 1e-5)
        // The two never meet.
        var time = move.start
        while time <= max(move.end, first.end) {
            XCTAssertFalse(
                DominoSetup.Box(first.pose(at: time), size: size, grow: -0.01)
                    .overlaps(DominoSetup.Box(move.pose(at: time), size: size, grow: -0.01)),
                "\(time)")
            time += 1.0 / 120
        }
    }

    func testTheDistanceToASegment() {
        XCTAssertEqual(DominoSetup.distance(from: [1, 1], toSegment: [0, 0], [2, 0]), 1)
        XCTAssertEqual(DominoSetup.distance(from: [3, 0], toSegment: [0, 0], [2, 0]), 1)
        XCTAssertEqual(DominoSetup.distance(from: [0, 2], toSegment: [0, 0], [0, 0]), 2)
    }

    func testBoxesOverlapOnlyWhenTheyMeet() {
        let size = SIMD3<Float>(1, 2, 0.3)
        let standing = Transform(
            rotation: DominoLayout.standing(heading: [1, 0]), translation: [0, 1, 0])
        let box = DominoSetup.Box(standing, size: size)
        func at(_ x: Float, _ y: Float, turn: Float = 0) -> DominoSetup.Box {
            DominoSetup.Box(
                Transform(
                    rotation: simd_quatf(angle: turn, axis: Self.up) * standing.rotation,
                    translation: [x, y, 0]), size: size)
        }
        XCTAssertTrue(box.overlaps(at(0.2, 1)))
        XCTAssertFalse(box.overlaps(at(0.4, 1)))
        XCTAssertFalse(box.overlaps(at(0, 3.1)))
        XCTAssertTrue(box.overlaps(at(0.4, 1, turn: .pi / 2)))
        XCTAssertTrue(
            DominoSetup.Footprint(box).overlaps(DominoSetup.Footprint(at(0.2, 5))))
        XCTAssertFalse(
            DominoSetup.Footprint(box).overlaps(DominoSetup.Footprint(at(0.4, 5))))
    }
}
