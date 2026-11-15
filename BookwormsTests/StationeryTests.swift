import SwiftUI
import XCTest

@testable import Bookworms

/// Checks the paper props: that their inks, such as the date-due card's and the review page's,
/// keep 7:1 on their card stock, as body text needs; how a catalog title wraps; how the
/// hand-drawn pen and ratings chart draw; and how a stamp is restamped.
final class StationeryTests: XCTestCase {
    func testInksKeepSevenToOneOnTheCardStock() {
        for (name, ink) in [
            ("ink", Stationery.inkValue), ("label ink", Stationery.labelInkValue),
            ("stamp ink", Stationery.stampInkValue), ("pen ink", Stationery.penInkValue),
        ] {
            let contrast = ink.contrast(with: Stationery.stockValue)
            XCTAssertGreaterThanOrEqual(contrast, 7, "\(name): \(contrast)")
        }
    }

    /// Checkout Card's lightest stamp, at 90 percent, and lightest writing, at 92 percent
    /// (`CheckoutCard`), still keep 7:1.
    func testCheckoutCardsLightestInksKeepSevenToOne() {
        for (name, ink, strength) in [
            ("stamp ink", Stationery.stampInkValue, 0.9), ("pen ink", Stationery.penInkValue, 0.92),
            ("ink", Stationery.inkValue, 0.92),
        ] {
            let faded = ink.mixed(with: Stationery.stockValue, 1 - strength)
            let contrast = faded.contrast(with: Stationery.stockValue)
            XCTAssertGreaterThanOrEqual(contrast, 7, "\(name): \(contrast)")
        }
    }

    /// The red pencil on catalog cards, such as "yours" over the reader's rating, is large
    /// handwriting, which needs 4.5:1.
    func testRedPencilKeepsFourAndAHalfToOne() {
        let contrast = Stationery.redValue.contrast(with: Stationery.stockValue)
        XCTAssertGreaterThanOrEqual(contrast, 4.5, "red: \(contrast)")
    }

    /// Noteworthy, which stands in for Caveat until it downloads, keeps one line of handwriting
    /// a rule tall, its baseline 80 percent of the way down and its descenders inside the band,
    /// from the default text size's rules to the largest.
    func testFallbackHandWritesOneLinePerRule() {
        XCTAssertNotNil(CheckoutCard.fallbackHand)
        for rule: CGFloat in [32, 34, 80] {
            let paper = PaperType(rule: rule, face: nil)
            for hand in [PaperType.Hand.entry, .note] {
                let metrics = paper[hand]
                // Each line, with the spacing the hand's text uses, takes exactly one rule.
                XCTAssertEqual(
                    metrics.lineHeight + paper.lineSpacing(hand), rule, accuracy: 0.001,
                    "\(hand) at \(rule)")
                XCTAssertEqual(
                    paper.topInset(hand) + metrics.ascent, 0.8 * rule, accuracy: 0.001,
                    "\(hand) at \(rule)")
                XCTAssertGreaterThanOrEqual(paper.bottomInset(hand), 0, "\(hand) at \(rule)")
            }
        }
    }

    /// A restamp keeps the shown label's copy as printed until the stamp touches the paper. From
    /// that frame, the landing label's copy shows, its fresh ink soaking in, and it shows at rest,
    /// whatever frame the clock last drew. When the tap leaves `isOn` as it was, the stamp lands
    /// the same label again, in the copy it covered.
    func testRestampSwapsUnderTheStampThenSoaksIn() {
        let (contact, duration) = (RestampTimeline.contact, RestampTimeline.duration)
        func stage(
            _ time: Double, of label: Bool, landing: Bool = true
        ) -> (bleed: Double, shows: Bool) {
            RestampEffect.stage(
                of: Restamp(
                    clock: 3 + time / duration, restamping: true, shown: false, landing: landing),
                label: label)
        }

        for clock in [0.0, 1, 2, 2.15, 2.6] {
            for shown in [false, true] {
                let rest = Restamp(clock: clock, shown: shown, landing: shown)
                XCTAssertTrue(RestampEffect.stage(of: rest, label: shown) == (0, true))
                XCTAssertTrue(RestampEffect.stage(of: rest, label: !shown) == (0, false))
            }
        }
        let falling = stride(from: 0, to: contact - 0.001, by: 0.01).map { $0 }
        XCTAssertTrue(falling.allSatisfy { stage($0, of: false) == (0, true) })
        XCTAssertTrue(falling.allSatisfy { !stage($0, of: true).shows })
        // The frame the stamp touches.
        let touch = contact + 0.0001
        XCTAssertFalse(stage(touch, of: false).shows)
        XCTAssertTrue(stage(touch, of: true).shows)
        XCTAssertEqual(stage(touch, of: true).bleed, 1, accuracy: 0.001)
        let soaking = stride(from: touch, to: duration, by: 0.01).map { stage($0, of: true) }
        XCTAssertTrue(soaking.allSatisfy(\.shows))
        XCTAssertTrue(zip(soaking, soaking.dropFirst()).allSatisfy { $0.bleed >= $1.bleed })
        XCTAssertTrue(
            stride(from: touch, to: duration, by: 0.01).allSatisfy { !stage($0, of: false).shows })
        // The same label, landed again.
        XCTAssertTrue(stage(0.2, of: false, landing: false) == (0, true))
        XCTAssertEqual(stage(touch, of: false, landing: false).bleed, 1, accuracy: 0.001)
        XCTAssertFalse(stage(touch, of: true, landing: false).shows)
    }

    /// The restamp takes under a second. The stamp comes straight down from the top of its
    /// travel, faster as it falls, and touches the paper as the new label lands. It never goes
    /// below the paper, its rubber gives a little as it presses, and it lifts back to the top of
    /// its travel while the new ink soaks in.
    func testStampComesDownPressesAndLifts() {
        let (contact, duration) = (RestampTimeline.contact, RestampTimeline.duration)
        XCTAssertTrue((0.7...1).contains(duration))
        let times = stride(from: 0, through: duration, by: 0.005).map { $0 }
        let stamps = times.map(RestampTimeline.stamp(at:))
        XCTAssertTrue(RestampTimeline.stamp(at: 0) == (1, 0))
        XCTAssertTrue(stamps.allSatisfy { (0...1).contains($0.height) })
        let falling = zip(times, stamps).filter { $0.0 < contact }.map(\.1.height)
        let drops = zip(falling, falling.dropFirst()).map { $0 - $1 }
        XCTAssertTrue(drops.allSatisfy { $0 > 0 })
        XCTAssertTrue(zip(drops, drops.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(RestampTimeline.stamp(at: contact).height, 0)
        XCTAssertEqual(RestampTimeline.bleed(at: contact), 1)
        // The fresh ink stays unsoaked until the stamp's face, under a third of the stamp's
        // height, clears the label, a third of the way up its travel of at least 1.2 times the
        // stamp's height, then soaks in.
        let clears = RestampTimeline.clears
        XCTAssertGreaterThanOrEqual(RestampTimeline.stamp(at: clears).height, 1.0 / 3)
        XCTAssertTrue(
            times.filter { (contact...clears).contains($0) }
                .allSatisfy { RestampTimeline.bleed(at: $0) == 1 })
        let bleeds = times.filter { $0 > clears }.map(RestampTimeline.bleed(at:))
        XCTAssertTrue(zip(bleeds, bleeds.dropFirst()).allSatisfy { $0 > $1 })
        XCTAssertTrue(
            zip(times, stamps).filter { (contact..<contact + RestampTimeline.press).contains($0.0) }
                .allSatisfy { $0.1.height == 0 })
        let squeeze = stamps.map(\.squeeze).max() ?? 0
        XCTAssertGreaterThan(squeeze, 0.005)
        XCTAssertLessThanOrEqual(squeeze, 0.02)
        let gone = contact + RestampTimeline.press + RestampTimeline.lift
        XCTAssertLessThan(gone, duration)
        XCTAssertTrue(RestampTimeline.stamp(at: gone) == (1, 0))
        XCTAssertGreaterThan(RestampTimeline.bleed(at: gone), 0.1)
        XCTAssertEqual(RestampTimeline.bleed(at: duration), 0)
    }

    /// Fresh ink lands visibly thinner, with soft edges, and a little darker, then soaks out to
    /// the impression at rest. Faint ink barely moves.
    @MainActor
    func testFreshInkSoaksIn() throws {
        /// The label's ink and how dark it is, the mean of its color's channels, in `opacity` ink
        /// and `bleed` from soaking in, or at rest.
        func ink(_ opacity: Double, bleed: Double?) throws -> (coverage: Double, shade: Double) {
            let label = Text("Unpin from Top Five")
                .font(.system(.body, design: .monospaced, weight: .bold))
                .foregroundStyle(Stationery.stampInk.opacity(opacity))
                .padding(4)
                .modifier(bleed.map(Self.soaking) ?? Self.resting)
            let pixels = try Self.pixels(of: label, scale: 3).joined()
            let alpha = pixels.reduce(0) { $0 + $1.alpha }
            return (alpha, pixels.reduce(0) { $0 + $1.color } / alpha)
        }

        let rest = try ink(1, bleed: nil)
        let soaking = try [1, 0.6, 0.3, 0.001].map { try ink(1, bleed: $0) }
        let coverage = soaking.map { $0.coverage / rest.coverage }
        XCTAssertGreaterThan(coverage[0], 0.55)
        XCTAssertLessThan(coverage[0], 0.75)
        XCTAssertTrue(zip(coverage, coverage.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(coverage[3], 1, accuracy: 0.01)
        XCTAssertLessThan(soaking[0].shade, rest.shade - 0.004)
        XCTAssertGreaterThan(soaking[0].shade, rest.shade - 0.03)
        XCTAssertEqual(soaking[3].shade, rest.shade, accuracy: 0.002)
        let faint = try ink(0.6, bleed: 1).coverage / ink(0.6, bleed: nil).coverage
        XCTAssertGreaterThan(faint, coverage[0] + 0.05)
    }

    /// The stamp's thunk is short, peaks where the knocks do, and fades out rather than ending
    /// in a click.
    func testStampThunkIsShortAndFadesOut() {
        let samples = StampThunk.samples
        XCTAssertLessThan(Double(samples.count) / ImpactSound.sampleRate, 0.15)
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertLessThan(samples.suffix(100).map(abs).max() ?? 1, 0.05)
        XCTAssertEqual(
            ImpactSound.knock(pitch: 130, length: 0.55, seed: 0x5354_414D), samples)
    }

    /// `RestampEffect` on the shown label's copy at rest, as the Top Five pin's stamp has it.
    private static var resting: RestampEffect {
        RestampEffect(restamp: Restamp(), label: false, ink: Stationery.stampInk)
    }

    /// `RestampEffect` on the landed label's copy with its fresh ink `bleed` from soaking in.
    private static func soaking(_ bleed: Double) -> RestampEffect {
        let time = Self.time(
            in: RestampTimeline.clears...RestampTimeline.duration,
            where: RestampTimeline.bleed(at:), is: bleed)
        return RestampEffect(
            restamp: Restamp(
                clock: time / RestampTimeline.duration, restamping: true, shown: true,
                landing: true),
            label: true, ink: Stationery.stampInk)
    }

    /// The time in `range` at which `curve`, which rises or falls steadily across it, is `value`.
    private static func time(
        in range: ClosedRange<Double>, where curve: (Double) -> Double, is value: Double
    ) -> Double {
        var (low, high) = (range.lowerBound, range.upperBound)
        let rises = curve(high) > curve(low)
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if (curve(middle) < value) == rises { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// Each row of pixels of `view` drawn at `scale`, each with its alpha and the mean of its
    /// premultiplied color's channels, from 0 to 1.
    @MainActor
    private static func pixels(
        of view: some View, scale: CGFloat = 1
    ) throws -> [[(alpha: Double, color: Double)]] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        return (0..<height)
            .map { row in
                (0..<width)
                    .map { column in
                        let index = (row * width + column) * 4
                        let color =
                            Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
                        return (Double(bytes[index + 3]) / 255, Double(color) / 765)
                    }
            }
    }

    /// A title at most a tenth too wide stays on one line, written smaller. A longer one breaks
    /// where `Text` would, with as many words on each line as fit, and a word left alone on the
    /// last line is joined by the previous line's last word when both fit and that line has
    /// another word. A word wider than the card shrinks the title until it fits, down to a
    /// heading's size, then starts a line and breaks between its letters. Each character is a
    /// point wide.
    func testTitleWrapShrinksOrBreaks() {
        let measure = { (line: Substring) in CGFloat(line.count) }
        func lines(_ title: String, _ width: CGFloat) -> TitleLines {
            TitleLines.make(title, width: width, measure: measure)
        }
        let crown = "The Map of the Hollow Crown"
        XCTAssertEqual(lines(crown, 30), TitleLines(lines: [crown]))
        let nearMiss = lines(crown, 27 / 1.05)
        XCTAssertEqual(nearMiss.lines, [crown])
        XCTAssertEqual(nearMiss.scale, 1 / 1.05, accuracy: 1e-9)
        XCTAssertEqual(
            lines(crown, 27 / 1.15), TitleLines(lines: ["The Map of the", "Hollow Crown"]))
        let sea = "When We Sat Far From the Cold Sea"
        XCTAssertEqual(
            lines(sea, 33 / 1.15), TitleLines(lines: ["When We Sat Far From the", "Cold Sea"]))
        XCTAssertEqual(lines("Thunderstrokes-Nine", 16).lines, ["Thunderstrokes-", "Nine"])
        XCTAssertEqual(
            lines("Lanternfolds", 10), TitleLines(lines: ["Lanternfolds"], scale: 10 / 12))
        XCTAssertEqual(lines("Lanternfolds", 9), TitleLines(lines: ["Lanternfo", "lds"]))
        XCTAssertEqual(
            lines("The Lanternfolds Score", 9),
            TitleLines(lines: ["The", "Lanternfo", "lds Score"]))
        XCTAssertEqual(lines("Either/Or Tales", 9).lines, ["Either/", "Or Tales"])
    }

    /// A title without spaces, as in Chinese and Japanese, breaks between its characters at its
    /// full size, as `Text` breaks it, instead of shrinking to one line.
    func testTitleWithoutSpacesBreaksBetweenCharacters() {
        let title = "世界の終りとハードボイルド・ワンダーランド"
        XCTAssertEqual(
            TitleLines.make(title, width: 8) { CGFloat($0.count) },
            TitleLines(lines: ["世界の終りとハー", "ドボイルド・ワン", "ダーランド"]))
    }

    /// A hand pen draws the same line for the same book and salt, a different one for another
    /// book, and keeps every line within its wobble, its ends within their overshoot and
    /// shortfall, scaled by its slop, and its width between the pen's least pressure and its full
    /// width, or all of it when even. A long line bends visibly.
    func testHandPenIsRepeatableAndStaysNearItsLine() {
        let lines: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 60)),
            (CGPoint(x: 3, y: 50), CGPoint(x: 29, y: 50)),
            (CGPoint(x: 10, y: 40), CGPoint(x: 37, y: 13)),
            (CGPoint(x: 5, y: 5), CGPoint(x: 6, y: 7)),
        ]
        var first = HandPen(book: 301_814, salt: 2)
        var again = HandPen(book: 301_814, salt: 2)
        var other = HandPen(book: 301_815, salt: 2)
        var even = HandPen(book: 301_814, salt: 2, isEven: true)
        var tight = HandPen(book: 301_814, salt: 2)
        for (start, end) in lines {
            let marks = first.marks(from: start, to: end, width: 1.4)
            XCTAssertEqual(marks, again.marks(from: start, to: end, width: 1.4))
            XCTAssertNotEqual(marks, other.marks(from: start, to: end, width: 1.4))
            let evenMarks = even.marks(from: start, to: end, width: 1.4)
            XCTAssertEqual(evenMarks.map(\.point), marks.map(\.point))
            XCTAssertTrue(evenMarks.allSatisfy { $0.width == 1.4 })

            let length = hypot(end.x - start.x, end.y - start.y)
            let along = CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length)
            for mark in marks {
                let offset = CGVector(dx: mark.point.x - start.x, dy: mark.point.y - start.y)
                let distance = offset.dx * along.dx + offset.dy * along.dy
                let drift = abs(offset.dx * along.dy - offset.dy * along.dx)
                XCTAssertLessThanOrEqual(drift, HandPen.maxWobble + 1e-9)
                XCTAssertGreaterThanOrEqual(distance, -HandPen.maxOvershoot - 1e-9)
                XCTAssertLessThanOrEqual(distance, length + HandPen.maxOvershoot + 1e-9)
                XCTAssertTrue(
                    (HandPen.minPressure * 1.4...1.4).contains(mark.width), "width \(mark.width)")
            }
            for mark in tight.marks(from: start, to: end, width: 1.4, slop: 0.4) {
                let offset = CGVector(dx: mark.point.x - start.x, dy: mark.point.y - start.y)
                let distance = offset.dx * along.dx + offset.dy * along.dy
                XCTAssertGreaterThanOrEqual(distance, -0.4 * HandPen.maxOvershoot - 1e-9)
                XCTAssertLessThanOrEqual(distance, length + 0.4 * HandPen.maxOvershoot + 1e-9)
            }
            // A long line strays from the straight line through its own ends, not only from the
            // line it should follow.
            if length >= 28, let head = marks.first?.point, let tail = marks.last?.point {
                let chord = CGVector(dx: tail.x - head.x, dy: tail.y - head.y)
                let bend = marks.map {
                    abs(($0.point.x - head.x) * chord.dy - ($0.point.y - head.y) * chord.dx)
                        / hypot(chord.dx, chord.dy)
                }
                XCTAssertGreaterThan(bend.max() ?? 0, 0.3)
            }
        }
        XCTAssertTrue(first.marks(from: .zero, to: .zero, width: 1).isEmpty)
    }

    /// The arrow from "you" to the reader's bar slants over shorter neighbors and drops steeply
    /// between taller ones, its ink, head included, clear of every other rating's. Only columns
    /// too narrow for even a steep arrow make it cross one. The word fits on the chart, clear of
    /// the arrow and of the tallest bars, from the default text size's rules to the largest, in
    /// Caveat and in Noteworthy, with and without Increase Contrast's even lines. Each other
    /// rating's ink stands in as its column grown by `RatingChart.margin`, past which no ink
    /// reaches.
    func testRatingPointerKeepsClearOfTheOtherBars() {
        let short = [1, 1, 1, 1, 1, 3, 1, 1, 1, 10]
        let between = [1, 1, 1, 1, 10, 1, 10, 1, 1, 1]
        let first = [3, 1, 1, 1, 1, 1, 1, 1, 1, 10]
        let tall = [10, 10, 10, 10, 10, 1, 10, 10, 10, 10]
        // A 1-star rating at accessibility sizes, where only the right side has room for the word.
        let low = [0, 9, 0, 64, 4, 259, 18, 478, 21, 262]
        let charts: [([Int], Int, CGFloat, CGFloat, String)] = [
            (short, 5, 190, 34, "slants left"), (first, 0, 190, 34, "slants right"),
            (between, 5, 190, 34, "steep"), (tall, 5, 190, 32, "steep"),
            (tall, 5, 330, 80, "steep"), (low, 1, 330, 74, "slants right"),
            (between, 5, 60, 34, "crosses"),
        ]
        for book in 0..<40 {
            for (counts, index, width, rule, placement) in charts {
                let noteworthy = PaperType(rule: rule, face: nil)[.note]
                let size = 0.62 * rule
                // Caveat's metrics, and the width of its "you".
                let caveat = PaperType.Metrics(
                    font: .body, size: size, ascent: 0.96 * size, descent: 0.3 * size, leading: 0)
                let hands = [
                    (noteworthy, 1.4 * noteworthy.size, "Noteworthy"),
                    (caveat, 1.07 * size, "Caveat"),
                ]
                let chart = CGSize(width: width, height: 1.9 * rule)
                let columns = RatingChart.columns(of: counts, in: chart, rule: rule)
                var others = Path()
                for (other, column) in columns.enumerated() where other != index {
                    others.addRect(column.insetBy(dx: -RatingChart.margin, dy: -RatingChart.margin))
                }
                for (note, labelWidth, hand) in hands {
                    for isEven in [false, true] {
                        let context =
                            "\(placement) at \(width) on \(rule) in \(hand), book \(book), even \(isEven)"
                        let pointer = RatingChart.pointer(
                            to: index, of: columns, clearOf: others,
                            label: CGSize(width: labelWidth, height: note.lineHeight), note: note,
                            in: chart, pen: HandPen(book: book, salt: 10, isEven: isEven))
                        let steep = 0.3 * columns[index].width
                        switch placement {
                        case "slants left": XCTAssertLessThan(pointer.side, -steep, context)
                        case "slants right": XCTAssertGreaterThan(pointer.side, steep, context)
                        default: XCTAssertEqual(abs(pointer.side), steep, accuracy: 1e-9, context)
                        }
                        XCTAssertEqual(pointer.isClear, placement != "crosses", context)
                        XCTAssertEqual(
                            pointer.isClear, !pointer.arrow.cgPath.intersects(others.cgPath),
                            context)
                        let box = pointer.wordBox
                        XCTAssertGreaterThanOrEqual(box.boundingRect.minX, 0, context)
                        XCTAssertLessThanOrEqual(box.boundingRect.maxX, width, context)
                        XCTAssertFalse(box.cgPath.intersects(pointer.arrow.cgPath), context)
                        XCTAssertFalse(box.cgPath.intersects(others.cgPath), context)
                    }
                }
            }
        }
    }
}
