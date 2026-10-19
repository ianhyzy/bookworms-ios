import SwiftUI

/// A book that **Stack** or **Shelf** pulls off the shelf to show its details, as the Pile lifts
/// a book and the Apple TV's Book Wall pulls one out.
///
/// The tapped spine, the flying book, and the shelf's bars share this state. The spine hides
/// while its book is out, leaving a shadowed gap, and reports the gap's frame. The details'
/// transparent stand-in reports the frame of their book stage and the pose a drag gives their
/// book. One value, `progress`, drives the flight, and `PullOutPath` turns it into the book's
/// place, size, and pose, so **Back** during the flight reverses it from where it is.
@MainActor
@Observable
final class ShelfPullOut {
    /// The opening. It runs at an even pace because `PullOutPath` eases each part of the flight
    /// itself, so the parts keep their share of the time. The book lands, and the details fade
    /// in, as it ends, about when a book the Pile lifts lands.
    static let opening = Animation.linear(duration: openingDuration)
    /// The opening's length in seconds, which maps the flight's progress to time.
    nonisolated static let openingDuration = 1.1
    /// The return, which starts as the details finish fading out and retraces the opening. It
    /// eases out, so the book leaves the stage at once rather than as slowly as it settled there,
    /// and slows as it slides into its place.
    static let closing = Animation.easeOut(duration: 1).delay(0.12)

    /// The book that is out, from the tap until it is back in its place.
    private(set) var book: CloudBook?
    /// Whether the book stood upright in its place, as on **Shelf**, or lay flat, as on **Stack**.
    private(set) var upright = true
    /// Set while the flying book stands in for the spine: from the flight's first frame until the
    /// book is back in its place.
    private(set) var isOut = false
    /// The spine's place in global coordinates, which the hidden spine reports.
    var home: CGRect?
    /// How the book lies in its place, which the hidden spine reports with `home`.
    var rest = PullOutPath.Rest()
    /// Where **Stack**'s camera sits across from the book in its place (`PullOutPath.eye`),
    /// which a 3D stacked book reports as it is pulled, or `nil` until it does.
    var eye: SIMD2<Double>?
    /// The frame of **Shelf**'s lamp in global coordinates, which the lamp reports. While a book
    /// is out, the flight draws the lamp over the book, so the book keeps the light its spine had.
    var lampFrame: CGRect?
    /// How strongly **Shelf**'s lamp shines (`ShelfLamp.warmth`), which the lamp reports with
    /// its frame, so the flight's lamp matches it.
    var lampWarmth = ShelfLamp.warmth
    /// The details' book stage in global coordinates, which `HostedBook.place` reports.
    var stage: CGRect?
    /// The pose the details give their book, which `HostedBook.turn` reports.
    var pose = BookPose.resting
    /// The flight's progress: 0 with the book in its place, 1 in the details' stage.
    private(set) var progress = 0.0
    /// The book whose neighbors in **Stack** make room for it (`StackRoom`). It is set with
    /// `book` and kept after the book is back, while they close in.
    private(set) var roomID: CloudBook.ID?
    /// How far the neighbors have opened, from 0 to 1 over the opening. They hold the room while
    /// the book is out.
    private(set) var room = 0.0
    /// How far the neighbors have closed in, from 0 to 1 over `StackRoom.closingDuration`,
    /// which starts once the book is back in its place.
    private(set) var closing = 0.0
    /// Whether the details show: set once the book lands, and cleared by **Back**.
    private(set) var showsText = false
    /// Set by **Back**, until the book is back in its place.
    private(set) var isReturning = false
    /// Counts the returns that slid their book back into its place, for the haptic as it seats.
    private(set) var seats = 0
    /// The book that **Space** peeks at on the Mac (`peek(_:)`), while it slides partway out
    /// of its place and back.
    private(set) var peekID: CloudBook.ID?
    /// Set by the book's **Share**, so the details stay while the Share tab shows.
    @ObservationIgnored var keepsForShare = false
    /// Counts pulls and returns, so a completion from an earlier one changes nothing.
    @ObservationIgnored private var revision = 0

    /// Whether the book's details, rather than the shelf, have the screen and its bars: from the
    /// tap until **Back**.
    var showsDetails: Bool { book != nil && !isReturning }

    /// Takes `book` out of its place. The flight starts once its spine reports where it stands.
    /// Does nothing while another book is out.
    func pull(_ book: CloudBook, upright: Bool) {
        guard self.book == nil else { return }
        revision &+= 1
        home = nil
        eye = nil
        pose = .resting
        progress = 0
        showsText = false
        isReturning = false
        roomID = book.id
        room = 0
        closing = 0
        self.upright = upright
        self.book = book
    }

    /// Slides the book with `id` partway out of its place, straight toward the reader, and back,
    /// as a peek before a pull. Does nothing while a book is out or another peek runs.
    func peek(_ id: CloudBook.ID) {
        guard book == nil, peekID == nil else { return }
        withAnimation(.smooth(duration: 0.18)) {
            peekID = id
        } completion: { [self] in
            withAnimation(.smooth(duration: 0.3)) { peekID = nil }
        }
    }

    /// Flies the book from its place to the stage, then fades the details in. The flying book
    /// calls this when it first appears, drawn over its spine.
    func fly() {
        guard book != nil, !isOut, !isReturning else { return }
        let revision = revision
        isOut = true
        var end = 1.0
        #if DEBUG
            // Check hook: `-BookwormsPullHold <progress>` stops the flight at that progress, so
            // a screenshot shows one moment of it.
            if let hold = UserDefaults.standard.string(forKey: "BookwormsPullHold")
                .flatMap(Double.init)
            {
                end = min(1, max(0, hold))
            }
        #endif
        withAnimation(Self.opening, completionCriteria: .logicallyComplete) {
            progress = end
            room = 1
        } completion: { [self] in
            guard self.revision == revision, progress == 1 else { return }
            // As the Pile's details fade in.
            withAnimation(.easeOut(duration: 0.25)) { showsText = true }
            AccessibilityNotification.ScreenChanged(nil).post()
            #if DEBUG
                // Simulator hook: `-BookwormsPileBack <seconds>` goes back that long after the
                // details appear, as it does for the Pile.
                if let delay = UserDefaults.standard.string(forKey: "BookwormsPileBack")
                    .flatMap(Double.init)
                {
                    Task {
                        try? await Task.sleep(for: .seconds(delay))
                        if self.revision == revision { putBack() }
                    }
                }
            #endif
        }
    }

    /// **Back**: fades the details out and flies the book back into its place.
    func putBack() {
        guard book != nil, !isReturning else { return }
        revision &+= 1
        let revision = revision
        isReturning = true
        withAnimation(.easeIn(duration: 0.2)) { showsText = false }
        withAnimation(Self.closing, completionCriteria: .logicallyComplete) {
            progress = 0
        } completion: { [self] in
            guard self.revision == revision else { return }
            close(keepingRoom: true)
            seats &+= 1
            // The neighbors snap back into place now that the book is back between them.
            withAnimation(.linear(duration: StackRoom.closingDuration)) { closing = 1 }
            AccessibilityNotification.ScreenChanged(nil).post()
        }
    }

    /// Puts the book back in its place at once, without the flight, and closes its details.
    /// The neighbors close in at once too, unless `keepingRoom`.
    func close(keepingRoom: Bool = false) {
        guard book != nil else { return }
        revision &+= 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if !keepingRoom {
                roomID = nil
                room = 0
            }
            book = nil
            isOut = false
            home = nil
            stage = nil
            progress = 0
            showsText = false
            isReturning = false
        }
    }
}

/// A pulled book's flight from its place on the shelf to the details' book stage, as a function
/// of the flight's progress, in one coordinate space.
///
/// Each part of the flight runs over its own share of the progress, with its own easing:
///
/// 1. The book slides out of its place, straight toward the reader, which shows as its spine
///    growing. On **Stack**, it comes out along the way its spine faces (`slide`), so a turned
///    book also moves a little to that side, and a flat one down the screen, so it stays clear
///    of the book above, while the books above make a little room (`StackRoom`). The
///    stack draws this part itself, over the books around it (`Rest.slidesInStack`). The book
///    casts a shadow on the shelf, and the faces' shading fades in.
/// 2. As the slide ends, the book starts to float to the stage, growing or shrinking to the
///    stage's height, and to turn from the way it lay (`Rest`) to the details' pose, while a book
///    from **Stack** stands up from lying on its back. On **Shelf**, the float and the turn start
///    before the slide has quite ended, so the book never stops, but only once it is almost out
///    of its place. On **Stack**, they wait for the slide to end, so the book never moves across
///    its neighbors while it is still between them.
/// 3. Once the book is on its way, the shelf dims behind it.
///
/// The return retraces the same path. Progress outside 0...1 leaves the book at that end.
///
/// Until the float starts, `Book3DView` lays the spine out at the carousel spine's own size, so
/// its lettering matches the spine it replaces, and a uniform scale sizes it on screen. The float
/// then moves to the details' layout size and scale.
struct PullOutPath {
    /// The book at one moment of the flight.
    struct Pose: Equatable {
        /// The center of the book's drawn bounds, as the details center their book.
        var center: CGPoint
        /// The `Book3DView` height, which sets the size its faces are laid out at.
        var height: CGFloat
        /// The scale that sizes the laid-out book on screen.
        var scale: CGFloat
        /// The `Book3DView` thickness ratio.
        var thicknessRatio: CGFloat
        var yaw: Double
        var pitch: Double
        /// The `Book3DView` camera distance and eye.
        var distance: CGFloat
        var eye: SIMD2<Double>
        /// A turn in the screen's plane, in radians: -π/2 lays an upright book on its back with
        /// its head on the left, as **Stack** shows books.
        var roll: Double
        /// `Book3DView.lighting`: `Rest.lighting` in the book's place, 0 for an unshaded spine.
        var lighting: Double
        /// The opacity of the book's shadow on the shelf behind it.
        var shadow: Double
        /// How far the shelf has dimmed behind the book, 0...1, which also lights the stage.
        var lift: Double
    }

    /// The progress at which the slide out of the shelf ends.
    static let pullEnd = 0.3
    /// The progress at which the float to the stage begins.
    static let floatStart = 0.22
    /// The progress at which the book starts to turn, with its shading fully faded in.
    static let turnStart = 0.24
    /// The progress at which the shelf starts to dim.
    static let veilStart = 0.45
    /// How much larger a spine looks once its book has slid out toward the reader.
    static let pullScale = 1.15
    /// The progress along the slide out of the shelf that the pointer resting on a book eases
    /// it to: about 1.5% nearer the reader.
    static let nudge = 0.06
    /// The progress that a peek (`ShelfPullOut.peek(_:)`) slides a book to: halfway out.
    static let peek = 0.15
    /// The float gathers speed, then settles gently on the stage.
    static let floatCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.4, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))

    /// The spine's frame in its place.
    let home: CGRect
    /// Whether the spine stands upright, as on **Shelf**, rather than lying flat, as on **Stack**.
    let upright: Bool
    /// The details' book stage: the frame of the book's height, centered where they draw it.
    let stage: CGRect
    /// The details' pose for the book.
    let pose: BookPose
    /// The cover's width-to-height ratio (`Book3DView.aspect(of:)`).
    let aspect: CGFloat
    /// The book's own thickness as a share of its height.
    let thicknessRatio: CGFloat
    /// How the book lay in its place, beyond facing its spine to the reader.
    var rest = Rest()
    /// Where **Stack**'s camera sat across from the book's center as it lay, in book heights, in
    /// the upright book's frame, before the roll that lays it down (`BookProjection`). The
    /// flight moves the camera onto the book's axis as the book turns, as the details see it.
    var eye = SIMD2<Double>.zero

    /// How a book lies in its place, as turns from facing its spine to the reader, upright on
    /// **Shelf** or on its back on **Stack**. The defaults lie straight, as a flat spine.
    struct Rest: Equatable {
        /// Added to the yaw that faces the spine to the reader. Negative shows the front cover,
        /// which lies on top of a book on its back.
        var yaw = 0.0
        var pitch = 0.0
        /// `Book3DView.lighting`, 0 for a flat spine.
        var lighting = 0.0
        /// The camera's distance from the book's center, in book heights; `nil` for the
        /// details' camera (`BookProjection.standardDistance`).
        var distance: Double? = nil
        /// Whether the stack draws the book's slide out of its place itself (`slide`), among the
        /// books making room for it and under the stack's fades. The flight takes over once the
        /// book is clear of the stack.
        var slidesInStack = false
    }

    /// How much larger than the book's height `Book3DView` draws a book that faces its spine to
    /// the viewer, with the camera `distance` book heights from its center (`Rest.distance`):
    /// the spine lies in front of the book's center, nearer the camera. A book drawn in place of
    /// a spine shrinks by this factor to match the spine's length.
    static func spineMagnification(
        aspect: CGFloat, thicknessRatio: CGFloat, distance: Double? = nil
    ) -> CGFloat {
        BookProjection(
            width: aspect, height: 1, thickness: thicknessRatio, yaw: .pi / 2, pitch: 0,
            distance: distance
        )
        .bounds.height
    }

    func pose(at progress: Double) -> Pose {
        let pull = Self.phase(progress, from: 0, to: Self.pullEnd, .easeInOut)
        let floatStart = upright ? Self.floatStart : Self.pullEnd
        let turnStart = floatStart + Self.turnStart - Self.floatStart
        let float = Self.phase(progress, from: floatStart, to: 1, Self.floatCurve)
        let turn = Self.phase(progress, from: turnStart, to: 1, .easeInOut)
        let lift = Self.phase(progress, from: Self.veilStart, to: 1, .easeInOut)
        let length = upright ? home.height : home.width
        let spineRatio = (upright ? home.width : home.height) / max(1, length)
        let magnification = Self.spineMagnification(
            aspect: aspect, thicknessRatio: spineRatio, distance: rest.distance)
        // The spine-on pose nearest the details' pose, so a book the reader spun turns back the
        // short way.
        let spineYaw = .pi / 2 + 2 * .pi * ((pose.yaw - .pi / 2) / (2 * .pi)).rounded()
        // On its back, a book comes out along the way its spine faces (`slide`). Its drawn width
        // runs down the screen, and in 3D includes the top board behind its spine.
        let slide =
            upright
            ? (offset: CGSize.zero, scale: 1 + (Self.pullScale - 1) * pull)
            : Self.slide(
                at: progress, length: length, thickness: home.height,
                extent: BookProjection(
                    width: length * aspect, height: length, thickness: length * spineRatio,
                    yaw: spineYaw + rest.yaw, pitch: rest.pitch,
                    distance: rest.distance.map { $0 * Double(length) }
                )
                .bounds.width / magnification, rest: rest)
        let pulled = slide.scale / magnification
        let height = Self.mix(length, stage.height, float)
        // A book that slides out inside the stack shades and casts its shadow once it is out.
        let outStart = rest.slidesInStack ? Self.pullEnd : 0
        return Pose(
            center: CGPoint(
                x: Self.mix(home.midX + slide.offset.width, stage.midX, float),
                y: Self.mix(home.midY + slide.offset.height, stage.midY, float)),
            height: height,
            scale: Self.mix(pulled, 1, float),
            // Late in the turn, so a change in the lettering's line count, which a spine's
            // thickness sets, happens once the spine has turned away from the reader.
            thicknessRatio: Self.mix(spineRatio, thicknessRatio, turn * turn),
            yaw: Self.mix(spineYaw + rest.yaw, pose.yaw, turn),
            pitch: Self.mix(rest.pitch, pose.pitch, turn),
            distance: height
                * Self.mix(
                    rest.distance ?? BookProjection.standardDistance,
                    BookProjection.standardDistance, turn),
            eye: eye * Double(height) * (1 - turn),
            roll: Self.mix(upright ? 0 : -.pi / 2, 0, turn),
            lighting: Self.mix(
                rest.lighting, 1,
                Self.phase(
                    progress, from: outStart,
                    to: rest.slidesInStack ? Self.veilStart : Self.turnStart, .easeInOut)),
            shadow: Self.phase(progress, from: outStart, to: outStart + Self.pullEnd, .easeInOut)
                * (1 - lift),
            lift: lift)
    }

    /// How a book on its back has moved out of its place at `progress`, as an offset from its
    /// place and a scale, both relative to how it lay. The book comes straight toward the
    /// reader along the way its spine faces: it grows by up to `pullScale` and moves a little to
    /// the side it is turned to. A book seen by the 3D stack's camera (`Rest.distance`) grows
    /// about its middle, which lies about level with the camera's eye, as a book coming straight
    /// toward that eye does. A flat book, seen straight on, also moves down the screen as it
    /// grows, so its top edge stays on the top edge of its place, clear of the book above. The
    /// stack draws either over the books around it.
    ///
    /// - Parameters:
    ///   - length: The spine's length on screen.
    ///   - thickness: The height of the book's place on screen.
    ///   - extent: How far the drawn book reaches down the screen as it lay, including a 3D
    ///     book's top board, from the bottom edge of its place up.
    static func slide(
        at progress: Double, length: CGFloat, thickness: CGFloat, extent: CGFloat, rest: Rest
    ) -> (offset: CGSize, scale: CGFloat) {
        let pull = phase(progress, from: 0, to: pullEnd, .easeInOut)
        // Growing by `pullScale` moves the book that much nearer the camera, which sits
        // `distance` lengths away.
        let distance = rest.distance ?? BookProjection.standardDistance
        let side = -sin(rest.pitch) * distance * (pullScale - 1) * length
        let down = rest.distance == nil ? max(0, extent * (1 + pullScale) / 2 - thickness) : 0
        return (CGSize(width: side * pull, height: down * pull), 1 + (pullScale - 1) * pull)
    }

    /// How much larger an upright spine looks at `progress`, while it slides out of its place
    /// toward the reader.
    static func uprightScale(at progress: Double) -> CGFloat {
        1 + (pullScale - 1) * phase(progress, from: 0, to: pullEnd, .easeInOut)
    }

    /// How far `curve` has gone at `progress` through the part of the flight from `start` to
    /// `end`: 0 before it, and 1 after it.
    private static func phase(
        _ progress: Double, from start: Double, to end: Double, _ curve: UnitCurve
    ) -> Double {
        curve.value(at: min(1, max(0, (progress - start) / (end - start))))
    }

    private static func mix<T: BinaryFloatingPoint>(_ from: T, _ to: T, _ amount: Double) -> T {
        from + (to - from) * T(amount)
    }
}

/// Shows the book that `pullOut` has out, and its details, over the shelf, which VoiceOver skips
/// while the details show.
///
/// A modifier of its own, so a pull and a return update only it, not the shelf's body, which
/// sorts the library.
struct ShelfPullOutStage: ViewModifier {
    let pullOut: ShelfPullOut

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(pullOut.showsDetails)
            .overlay {
                if let book = pullOut.book { ShelfPullOutLayer(book: book, pullOut: pullOut) }
            }
            .onAppear { pullOut.keepsForShare = false }
            // Another tab closes the details at once, except for the book's Share, which
            // keeps them for the reader's return, as pushed details stay.
            .onDisappear { if !pullOut.keepsForShare { pullOut.close() } }
            // A light tap as the book leaves its place, and another as it seats again, as the
            // Desk's books knock. The Mac's trackpad has no impact, so it only marks the seat.
            #if os(iOS)
                .sensoryFeedback(trigger: pullOut.isOut) { _, isOut in
                    isOut ? .impact(weight: .light, intensity: 0.5) : nil
                }
                .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: pullOut.seats)
            #else
                .sensoryFeedback(.alignment, trigger: pullOut.seats)
            #endif
    }
}

/// Keeps the carousel from taking touches while `pullOut` has a book out, from the tap until the
/// book is back in its place, so the carousel neither scrolls the book's place away nor pulls
/// another book. A modifier of its own, for the same reason as `ShelfPullOutStage`.
struct ShelfPullOutWait: ViewModifier {
    let pullOut: ShelfPullOut

    func body(content: Content) -> some View {
        content.allowsHitTesting(pullOut.book == nil)
    }
}

/// The pulled-out book's flight and details, over the shelf.
///
/// The details join the hierarchy at the tap, hidden, since the book flies to their stand-in's
/// frame. They fade in once the book lands, and their stand-in then places and turns the flying
/// book, so the book scrolls and turns with them. Their bottom scroll edge effect stays hidden:
/// the walnut veil already darkens the tab bar's backdrop, and an edge effect that switched on
/// as the details faded in would flip the tab bar's glass from light to dark in one frame. The
/// top edge's effect, under the bar and the pinned section picker, shows once the details' text
/// does, so text that scrolls under the picker never shows through it.
private struct ShelfPullOutLayer: View {
    let book: CloudBook
    let pullOut: ShelfPullOut

    var body: some View {
        ZStack(alignment: .leading) {
            PullOutFlightHost(book: book, pullOut: pullOut)
            BookDetailView(
                book: book,
                hostedBook: HostedBook(
                    place: { [pullOut] in pullOut.stage = $0 },
                    // The return starts from the pose on screen and ignores the rest of a coast,
                    // which could otherwise carry the book past a fore-edge-on pose and flip the
                    // spine it turns back to.
                    turn: { [pullOut] in if !pullOut.isReturning { pullOut.pose = $0 } },
                    hasLanded: pullOut.showsText)
            )
            .scrollEdgeEffectHidden(for: .bottom)
            .scrollEdgeEffectHidden(!pullOut.showsText, for: .top)
            .opacity(pullOut.showsText ? 1 : 0)
            .allowsHitTesting(pullOut.showsText)
            .accessibilityHidden(!pullOut.showsText)
            // Pushed details close with VoiceOver's escape gesture through the navigation stack.
            .accessibilityAction(.escape) { pullOut.putBack() }
            // A swipe in from the leading edge goes back, as it pops pushed details.
            Color.clear
                .frame(width: 20)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { drag in
                            let width = max(
                                drag.translation.width, drag.predictedEndTranslation.width)
                            if width > 80, drag.translation.width > abs(drag.translation.height) {
                                pullOut.putBack()
                            }
                        }
                )
                .allowsHitTesting(pullOut.showsText)
                .accessibilityHidden(true)
        }
    }
}

/// Draws the flight from the shared state. It reads the frames and pose that change as the
/// details scroll and turn, so only this view, not the details, updates for them.
private struct PullOutFlightHost: View {
    let book: CloudBook
    let pullOut: ShelfPullOut

    @Environment(AppModel.self) private var model
    /// The view's origin in global coordinates, which the reported frames convert from.
    @State private var origin: CGPoint?
    @State private var cover: UIImage?

    var body: some View {
        // The library's current copy, so a new cover or design shows at once.
        let current = model.books.first { $0.id == book.id } ?? book
        Color.clear
            .overlay {
                if let origin, let home = pullOut.home {
                    let shift = CGAffineTransform(translationX: -origin.x, y: -origin.y)
                    let home = home.applying(shift)
                    // Until the details report their stage, the float keeps the book where it
                    // is, at its spine's length.
                    let length = max(home.width, home.height)
                    let stage =
                        pullOut.stage?.applying(shift)
                        ?? CGRect(x: home.midX, y: home.midY - length / 2, width: 0, height: length)
                    PullOutFlight(
                        book: current, look: model.look(for: current), cover: cover,
                        path: PullOutPath(
                            home: home, upright: pullOut.upright, stage: stage,
                            pose: pullOut.pose, aspect: Book3DView.aspect(of: cover),
                            thicknessRatio: Book3DView.thicknessRatio(of: current, cover: cover),
                            rest: pullOut.rest, eye: pullOut.eye ?? .zero),
                        lamp: pullOut.upright ? pullOut.lampFrame?.applying(shift) : nil,
                        lampWarmth: pullOut.lampWarmth,
                        progress: pullOut.progress
                    )
                    .onAppear { pullOut.fly() }
                }
            }
            .onGeometryChange(for: CGPoint.self) {
                $0.frame(in: .global).origin
            } action: {
                origin = $0
            }
            .task(id: current.coverCandidates.first) {
                cover = await model.covers.image(for: current)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The book in flight, with its shadow on the shelf, the walnut veil that dims the shelf behind
/// it, the lamp's glow that the details show behind their book, and **Shelf**'s lamp over it.
///
/// SwiftUI animates `progress`, and the body samples `path` at each value, so the book follows
/// the path rather than a straight blend of its endpoints.
private struct PullOutFlight: View, Animatable {
    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    let path: PullOutPath
    /// The frame of **Shelf**'s lamp, which the shelf hides while the book is out, and how
    /// strongly it shines.
    let lamp: CGRect?
    let lampWarmth: Double
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let pose = path.pose(at: progress)
        let bounds = BookProjection(
            width: pose.height * path.aspect, height: pose.height,
            thickness: pose.height * pose.thicknessRatio, yaw: pose.yaw, pitch: pose.pitch,
            distance: Double(pose.distance)
        )
        .bounds
        Book3DView(
            book: book, look: look, cover: cover, height: pose.height, yaw: pose.yaw,
            pitch: pose.pitch, thicknessRatio: pose.thicknessRatio, lighting: pose.lighting,
            distance: pose.distance, eye: pose.eye, roll: pose.roll
        )
        .scaleEffect(pose.scale)
        .rotationEffect(.radians(pose.roll))
        .position(pose.center)
        // The stack draws a book that slides out inside it until the book is clear.
        .opacity(path.rest.slidesInStack && progress < PullOutPath.pullEnd ? 0 : 1)
        .background {
            // Below and behind the book, as the lamp above the shelf would cast it.
            EllipticalGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0.5),
                    .init(color: .clear, location: 1),
                ]
            )
            .frame(
                width: bounds.width * pose.scale + 28, height: bounds.height * pose.scale + 28
            )
            .rotationEffect(.radians(pose.roll))
            .position(x: pose.center.x + 3, y: pose.center.y + 9)
            .opacity(pose.shadow)
        }
        .background {
            RadialGradient(
                colors: [ShelfPalette.lamp.opacity(0.22), .clear], center: .center,
                startRadius: 0, endRadius: 280
            )
            .frame(width: 640, height: 640)
            .position(x: path.stage.midX, y: path.stage.midY)
            .opacity(pose.lift)
        }
        // The pushed details' backdrop, which covers the shelf once the book lands.
        .background { WalnutWall(opacity: pose.lift).ignoresSafeArea() }
        .overlay {
            if let lamp {
                ShelfLamp(warmth: lampWarmth)
                    .frame(width: lamp.width, height: lamp.height)
                    .position(x: lamp.midX, y: lamp.midY)
                    .opacity(1 - pose.lift)
            }
        }
        .transaction { $0.animation = nil }
    }
}
