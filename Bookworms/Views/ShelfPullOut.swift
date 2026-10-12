import SwiftUI

/// A book that **Stack** or **Shelf** pulls off the shelf to show its details, as the Pile lifts
/// a book and the Apple TV's Book Wall pulls one out.
///
/// The tapped spine, the flying book, and the shelf's bars share this state. The spine hides
/// while its book is out, leaving a shadowed gap, and reports the gap's frame. The details'
/// transparent stand-in reports the frame of their book stage and the pose a drag gives their
/// book. One spring on `progress` drives the flight, and `PullOutPath` turns it into the book's
/// place, size, and pose, so **Back** during the flight reverses it from where it is.
@MainActor
@Observable
final class ShelfPullOut {
    /// The opening spring, which overshoots slightly, as the Pile's flight does.
    static let opening = Animation.spring(duration: 1.3, bounce: 0.06)
    /// When the details fade in after the flight starts: once the opening spring has brought the
    /// book within a few points of the stage.
    static let landing = Duration.seconds(0.9)
    /// The return, which starts as the details finish fading out. It eases in and out rather
    /// than springing: a spring from rest would rush the float back and leave the slide into the
    /// gap to its long, slow tail.
    static let closing = Animation.easeInOut(duration: 0.9).delay(0.12)

    /// The book that is out, from the tap until it is back in its place.
    private(set) var book: CloudBook?
    /// Whether the book stood upright in its place, as on **Shelf**, or lay flat, as on **Stack**.
    private(set) var upright = true
    /// Set while the flying book stands in for the spine: from the flight's first frame until the
    /// book is back in its place.
    private(set) var isOut = false
    /// The spine's place in global coordinates, which the hidden spine reports.
    var home: CGRect?
    /// The details' book stage in global coordinates, which `HostedBook.place` reports.
    var stage: CGRect?
    /// The pose the details give their book, which `HostedBook.turn` reports.
    var pose = BookPose.resting
    /// The flight's progress: 0 with the book in its place, 1 in the details' stage.
    private(set) var progress = 0.0
    /// Whether the details show: set once the book lands, and cleared by **Back**.
    private(set) var showsText = false
    /// Set by **Back**, until the book is back in its place.
    private(set) var isReturning = false
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
        pose = .resting
        progress = 0
        showsText = false
        isReturning = false
        self.upright = upright
        self.book = book
    }

    /// Flies the book from its place to the stage, then fades the details in. The flying book
    /// calls this when it first appears, drawn over its spine.
    func fly() {
        guard book != nil, !isOut, !isReturning else { return }
        let revision = revision
        isOut = true
        withAnimation(Self.opening) { progress = 1 }
        Task {
            try? await Task.sleep(for: Self.landing)
            guard self.revision == revision else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsText = true }
            AccessibilityNotification.ScreenChanged(nil).post()
            #if DEBUG
                // Simulator hook: `-BookwormsPileBack <seconds>` goes back that long after the
                // details appear, as it does for the Pile.
                if let delay = UserDefaults.standard.string(forKey: "BookwormsPileBack")
                    .flatMap(Double.init)
                {
                    try? await Task.sleep(for: .seconds(delay))
                    if self.revision == revision { putBack() }
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
            close()
            AccessibilityNotification.ScreenChanged(nil).post()
        }
    }

    /// Puts the book back in its place at once, without the flight, and closes its details.
    func close() {
        guard book != nil else { return }
        revision &+= 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
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
/// The flight has two overlapping parts. First the book slides straight out of its place toward
/// the reader, which shows as its spine growing by `pullScale`; it does not turn, so it clears
/// its neighbors. Then it floats to the stage, grows to the stage's height, and turns from facing
/// its spine to the details' pose, while a book from **Stack** also stands up from lying on its
/// back. The float starts before the slide ends, so the book never stops on the way. Progress
/// past 1, from a spring's overshoot, carries the float past the stage; progress below 0 leaves
/// the book in its place.
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
        /// A turn in the screen's plane, in radians: -π/2 lays an upright book on its back with
        /// its head on the left, as **Stack** shows spines.
        var roll: Double
        /// How far the float has gone, 0...1, which dims the shelf and lights the stage.
        var lift: Double
    }

    /// The progress at which the slide out of the shelf ends.
    static let pullEnd = 0.32
    /// The progress at which the float to the stage begins.
    static let floatStart = 0.26
    /// How much larger the spine looks once the book has slid out toward the reader.
    static let pullScale = 1.1

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

    func pose(at progress: Double) -> Pose {
        let pull = Self.easeOut(min(1, max(0, progress / Self.pullEnd)))
        let float = Self.easeIn(max(0, (progress - Self.floatStart) / (1 - Self.floatStart)))
        let length = upright ? home.height : home.width
        let spineRatio = (upright ? home.width : home.height) / max(1, length)
        // Facing the viewer, the spine lies in front of the book's center, so `Book3DView`
        // draws it larger than the book's height by this factor.
        let magnification = BookProjection(
            width: aspect, height: 1, thickness: spineRatio, yaw: .pi / 2, pitch: 0
        )
        .bounds.height
        let pulled = (1 + (Self.pullScale - 1) * pull) / magnification
        // The spine-on pose nearest the details' pose, so a book the reader spun turns back the
        // short way.
        let spineYaw = .pi / 2 + 2 * .pi * ((pose.yaw - .pi / 2) / (2 * .pi)).rounded()
        return Pose(
            center: CGPoint(
                x: Self.mix(home.midX, stage.midX, float), y: Self.mix(home.midY, stage.midY, float)
            ),
            height: Self.mix(length, stage.height, float),
            scale: Self.mix(pulled, 1, float),
            // Late in the float, so a change in the lettering's line count, which a spine's
            // thickness sets, happens once the spine has turned away from the reader.
            thicknessRatio: Self.mix(spineRatio, thicknessRatio, float * float),
            yaw: Self.mix(spineYaw, pose.yaw, float),
            pitch: Self.mix(0, pose.pitch, float),
            roll: upright ? 0 : Self.mix(-.pi / 2, 0, float),
            lift: min(1, float))
    }

    private static func mix<T: BinaryFloatingPoint>(_ from: T, _ to: T, _ amount: Double) -> T {
        from + (to - from) * T(amount)
    }

    /// Starts at full speed and slows to a stop at 1.
    private static func easeOut(_ x: Double) -> Double { x * (2 - x) }

    /// Starts from rest and reaches 1 at full speed, so the spring's own easing ends the float.
    private static func easeIn(_ x: Double) -> Double { x * x * (2 - x) }
}

/// The pulled-out book's flight and details, over the shelf.
///
/// The details join the hierarchy at the tap, hidden, since the book flies to their stand-in's
/// frame. They fade in once the book lands, and their stand-in then places and turns the flying
/// book, so the book scrolls and turns with them. A scroll view's edge effect darkens the tab
/// bar's glass even while the details are hidden, so it shows only while they do.
struct ShelfPullOutLayer: View {
    let book: CloudBook
    let pullOut: ShelfPullOut

    var body: some View {
        ZStack {
            PullOutFlightHost(book: book, pullOut: pullOut)
            BookDetailView(
                book: book,
                hostedBook: HostedBook(
                    place: { [pullOut] in pullOut.stage = $0 },
                    turn: { [pullOut] in pullOut.pose = $0 })
            )
            .scrollEdgeEffectHidden(!pullOut.showsText)
            .opacity(pullOut.showsText ? 1 : 0)
            .allowsHitTesting(pullOut.showsText)
            .accessibilityHidden(!pullOut.showsText)
            // Pushed details close with VoiceOver's escape gesture through the navigation stack.
            .accessibilityAction(.escape) { pullOut.putBack() }
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
                            thicknessRatio: Book3DView.thicknessRatio(of: current, cover: cover)),
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

/// The book in flight, with the walnut veil that dims the shelf behind it and the lamp's glow
/// that the details show behind their book.
///
/// SwiftUI animates `progress`, and the body samples `path` at each value, so the book follows
/// the path rather than a straight blend of its endpoints.
private struct PullOutFlight: View, Animatable {
    let book: CloudBook
    let look: SpineLook
    let cover: UIImage?
    let path: PullOutPath
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let pose = path.pose(at: progress)
        Book3DView(
            book: book, look: look, cover: cover, height: pose.height, yaw: pose.yaw,
            pitch: pose.pitch, thicknessRatio: pose.thicknessRatio
        )
        .scaleEffect(pose.scale)
        .rotationEffect(.radians(pose.roll))
        .position(pose.center)
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
        .background { ShelfPalette.wall.ignoresSafeArea().opacity(pose.lift) }
    }
}
