import SwiftUI

// The paper props inside the app's screens: the library card that holds the Hardcover sign-in
// code, the bookplate of the signed-in account, a book's date-due card, review page, and
// catalog cards (`CatalogCard`), and the rubber-stamped buttons and taped tag on them.
// They are objects, not chrome, so they keep their colors in both appearances, as a real card
// would. Each is a flat fill with a static dither tile and, on ruled cards, rules that a canvas
// draws only when the card's size changes; their shadows are one baked image (`SoftShadow`).
// Nothing here draws per frame, except a stamp while it is restamped: its shader
// (`RestampEffect`) and the baked stamp that comes down on it (`StampFall`), which the window
// draws above all its content (`stampStage()`). The only blurs are inside a stamp's canvas
// (`StampInk`), which draws again only when the stamp changes, so scrolling moves finished
// images.

/// The colors of card stock and the inks on it. Every ink keeps 7:1 or more on the stock
/// (`StationeryTests`).
enum Stationery {
    /// Library card stock.
    static let stockValue = ColorValue(red: 0xEF, green: 0xE3, blue: 0xCC)
    /// Typed and printed text.
    static let inkValue = ColorValue(red: 0x2B, green: 0x21, blue: 0x17)
    /// Printed labels, such as a card's column headings.
    static let labelInkValue = ColorValue(red: 0x4E, green: 0x3E, blue: 0x2F)
    /// A date stamp's violet ink.
    static let stampInkValue = ColorValue(red: 0x2E, green: 0x2A, blue: 0x6B)
    /// A ballpoint pen's blue-black ink, for handwriting.
    static let penInkValue = ColorValue(red: 0x1B, green: 0x2A, blue: 0x55)

    static let stock = stockValue.color
    static let ink = inkValue.color
    static let labelInk = labelInkValue.color
    static let stampInk = stampInkValue.color
    static let penInk = penInkValue.color
    /// A date stamp's day, month, and year. Reading dates are days, kept at midnight GMT.
    static let stampFormat = Date.FormatStyle(timeZone: .gmt).day().month(.abbreviated).year()
    /// A library card's printed rules: faint ink, decoration only.
    static let rule = inkValue.color.opacity(0.14)
    /// The red rule under a library card's heading, a bookmark ribbon's cloth, and a catalog
    /// card's red pencil, which keeps 4.5:1 on the stock.
    static let redValue = ColorValue(red: 0x8E, green: 0x2B, blue: 0x24)
    static let red = redValue.color
    /// The kraft paper of a photo corner: decoration only.
    static let photoCorner = ColorValue(red: 0xA8, green: 0x8A, blue: 0x62).color
    /// The dark wall that shows through a catalog card's rod hole, and the desk stamp's shadow
    /// (`StampFall`): decoration only.
    static let rodHole = ColorValue(red: 0x1C, green: 0x14, blue: 0x0E).color
    /// Translucent washi tape that holds a tag to the wall: decoration only.
    static let tape = ColorValue(red: 0xD6, green: 0xC8, blue: 0xAA).color.opacity(0.7)
}

extension EnvironmentValues {
    /// Whether the view lies on card stock (`CardStockSheet`), where notes take the stock's label
    /// ink (`CardNote`).
    @Entry var onPaper = false
    /// The ink of the stamp whose live label holds the view (`StampButtonStyle`), or `nil` in the
    /// stamp's printed copy and outside stamps. Parts that move, such as `StampSpinner`, draw only
    /// on the live label, since the printed copy is a still image.
    @Entry var liveStampInk: Color? = nil
    /// Where the restamp of the stamps inside the view is, on every frame of it (`RestampButton`).
    @Entry var restamp = Restamp()
    /// How a `RestampButton` prints the stamp's copy inside the view, or `nil` for a stamp that
    /// prints itself.
    @Entry var stampCopy: StampCopy? = nil
    /// The window's desk stamp (`stampStage()`), or `nil` in a view outside one, where a
    /// `RestampButton` changes its label at once.
    @Entry var stampStage: StampStage? = nil
}

/// A piece of card stock behind `content`, with its ink as the foreground style, a printed rule
/// every `ruleSpacing` points when set, and a soft shadow on whatever it lies on.
struct CardStockSheet<Content: View>: View {
    var ruleSpacing: CGFloat?
    var cornerRadius: CGFloat = 4
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(Stationery.ink)
            .environment(\.bookTextGround, Stationery.stockValue)
            .environment(\.onPaper, true)
            .background {
                ZStack {
                    Stationery.stock
                    Image(.paperDither).resizable(resizingMode: .tile).opacity(0.05)
                    if let ruleSpacing { CardRules(spacing: ruleSpacing) }
                }
                .clipShape(.rect(cornerRadius: cornerRadius))
                .background { SoftShadow(cornerRadius: cornerRadius) }
                .accessibilityHidden(true)
            }
    }
}

/// Printed rules across a card, `spacing` points apart, starting one space below its top.
private struct CardRules: View {
    let spacing: CGFloat

    var body: some View {
        Canvas { context, size in
            var y = spacing
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.75)),
                    with: .color(Stationery.rule))
                y += spacing
            }
        }
    }
}

/// The soft shadow under a flat object of the frame's size: one baked, blurred image
/// (`SoftShadow`, from `script/room-textures.swift`) stretched between fixed corners, so it
/// costs no blur pass. It falls a little below the object, as under a lamp above.
struct SoftShadow: View {
    var cornerRadius: CGFloat = 4
    var opacity = 0.55

    var body: some View {
        // The image is 96 points square: a 24-point blur around a 48-point rectangle.
        Image(.softShadow)
            .resizable(
                capInsets: EdgeInsets(top: 40, leading: 40, bottom: 40, trailing: 40),
                resizingMode: .stretch
            )
            .padding(-24)
            .offset(y: 3)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A button printed on card stock as a rubber stamp's impression: the label in the date stamps'
/// type and violet ink, inside a rounded frame, a fraction of a degree off level.
///
/// `book` and `salt` place the stamp's tilt and how its ink took (`StampInk`), so each button
/// keeps its own impression across redraws. Increase Contrast and Reduce Transparency print solid
/// ink. Pressing prints a heavier, more even impression with a faint wash of ink inside the
/// frame; a disabled stamp's ink is faded, unless the stamp is `busy`. On the Mac, the pointer
/// over an enabled stamp turns into a pointing hand, and the uneven ink deepens a little: its
/// lighter patches and grain fill in partway. At accessibility text sizes, the symbol stands
/// above the title, so the title wraps between words. A `RestampButton` restamps its label when
/// a tap changes it.
struct StampButtonStyle: ButtonStyle {
    let book: Int
    let salt: UInt64
    /// Whether the stamp reports work in progress, such as "Designing spines" beside a
    /// `StampSpinner`. The caller disables it, and it keeps full ink so the report stays legible.
    var busy = false

    func makeBody(configuration: Configuration) -> some View {
        StampImpression(configuration: configuration, book: book, salt: salt, busy: busy)
    }
}

private struct StampImpression: View {
    let configuration: ButtonStyleConfiguration
    let book: Int
    let salt: UInt64
    let busy: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.stampCopy) private var copy
    /// The frame's line, which grows with the type, as the frame's margins do.
    @ScaledMetric(relativeTo: .body) private var line: CGFloat = 2.5
    @State private var hovering = false

    #if DEBUG
        /// `-BookwormsStampPressed YES` prints every stamp as pressed, and
        /// `-BookwormsStampHovered YES` every enabled stamp as under the Mac's pointer, for
        /// screenshots.
        private static let debugPressed = UserDefaults.standard.bool(
            forKey: "BookwormsStampPressed")
        private static let debugHovered = UserDefaults.standard.bool(
            forKey: "BookwormsStampHovered")
    #else
        private static let debugPressed = false
        private static let debugHovered = false
    #endif
    #if os(iOS)
        /// The frame's height at the smallest text sizes: a touch target's.
        private static let minHeight: CGFloat = 44
    #else
        private static let minHeight: CGFloat = 0
    #endif
    private static let frame = RoundedRectangle(cornerRadius: 5)

    var body: some View {
        let pressed = (copy?.pressed ?? configuration.isPressed) || Self.debugPressed
        let hovered = isEnabled && ((copy?.hovered ?? hovering) || Self.debugHovered)
        let solid = contrast == .increased || reduceTransparency
        let ink = Stationery.stampInk.opacity(isEnabled || busy ? 1 : 0.5)
        let wash = Self.frame.fill(Stationery.stampInk.opacity(pressed ? 0.07 : 0))
        // The label lays out the stamp and carries its accessibility. With uneven ink, its own
        // ink is clear and a canvas prints it.
        impression(type: solid ? ink : .clear, frame: solid ? ink : .clear, pressed: pressed)
            .environment(\.liveStampInk, ink)
            .background {
                if solid {
                    wash
                } else if copy?.prints ?? true {
                    ZStack {
                        wash
                        StampInk(
                            book: book, salt: salt, ink: ink,
                            // Pressing evens the ink more than the pointer does.
                            lightening: pressed ? 0.4 : hovered ? 0.7 : 1, line: line,
                            inset: CGSize(width: 12 + line, height: 5 + line),
                            type: impression(type: ink, frame: .clear, pressed: pressed),
                            frame: impression(type: .clear, frame: ink, pressed: pressed)
                        )
                    }
                    .modifier(RestampFromEnvironment(label: copy?.label, ink: ink))
                }
            }
            .rotationEffect(.degrees((ShareStyle.unit(0, book, salt) - 0.5) * 0.7))
            .contentShape(.rect)
            .preference(key: StampPressing.self, value: configuration.isPressed)
            #if os(macOS)
                .onHover { hovering = $0 }
                .pointerStyle(isEnabled ? .link : nil)
            #endif
    }

    /// The label in `type` ink inside a frame in `frame` ink; pressing prints them heavier. SF
    /// Mono's weights share one advance, so the heavier type doesn't move the layout.
    private func impression(type: Color, frame: Color, pressed: Bool) -> some View {
        configuration.label
            .labelStyle(StampLabelStyle(stacked: typeSize.isAccessibilitySize))
            .font(.system(.body, design: .monospaced, weight: pressed ? .heavy : .bold))
            .multilineTextAlignment(.leading)
            // Room inside the frame's line, which takes its width from this padding.
            .padding(.horizontal, 12 + line)
            .padding(.vertical, 5 + line)
            .frame(minHeight: Self.minHeight)
            .overlay { Self.frame.strokeBorder(frame, lineWidth: pressed ? line * 1.12 : line) }
            .foregroundStyle(type)
    }
}

/// A stamp button (`StampButtonStyle`) whose label shows `isOn`, as **Pin to Top Five** becomes
/// **Unpin from Top Five**, restamped when a tap changes it.
///
/// A tap runs `action`, and a wooden desk stamp comes in from above the window's top, straight down
/// onto the label (`StampFall`), over every card and the navigation and tab bars, though under the
/// iPhone's status bar, while the label stays as it is. On the frame the stamp touches the paper,
/// its rubber face covering the label, the label for the latest `isOn` lands under it, unpressed,
/// with a soft thunk (`StampThunk`) and, on the iPhone, a soft haptic tap. The stamp presses for a
/// moment, its rubber giving a little, and lifts away out of the window, and once it clears the
/// label the fresh ink soaks in (`RestampEffect`): its heavier strokes land thinner and spread out
/// with soft edges. One clock runs all of it (`RestampTimeline`), so the stamp, the new label, the
/// thunk, and the haptic tap meet on one frame. If `action` leaves `isOn` as it was, the stamp
/// lands the same label again.
///
/// Another tap before the stamp touches the paper runs `action` again, and the label lands for the
/// value it leaves; a tap after it runs `action`, and the stamp restamps again once the label
/// settles. If the button leaves the screen during a restamp, as for another tab, the stamp stops
/// and the label for the latest `isOn` shows when the button returns. With Reduce Motion, at
/// accessibility text sizes, where the label stands far taller than the stamp's rubber face, or
/// outside a `stampStage()`, the label changes at once, without the stamp; with Increase Contrast
/// or Reduce Transparency, whose ink is solid, the stamp comes down and the solid label changes
/// under it, without the soak-in. Either way the thunk and the haptic tap play. A change from
/// elsewhere, such as Share's pins, changes the label at once and silently. **Sounds** in the
/// Desk's options turns the thunk off, and the silent switch silences it.
///
/// Both labels take the wider label's room, so the stamp keeps its size. With uneven ink, each
/// label has a printed copy of its own, which never draws another label: the stamp's own copy
/// prints **Pin to Top Five**, and a copy behind it **Unpin from Top Five**. At rest only the
/// shown label's copy prints. A press prints the other one out of sight, so the label it lands
/// is ready, and the copy under the press keeps its pressed look until the stamp covers it.
///
/// The printed label trails `isOn` during a restamp, so the caller labels the button for
/// VoiceOver from `isOn`. Unless `stamped`, as with glass cards, the button shows the label for
/// `isOn` at its own size and a tap only runs `action`.
struct RestampButton<Content: View>: View {
    let isOn: Bool
    let stamped: Bool
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Content

    /// The label the stamp shows: before a restamp touches the paper, the label it covers, and
    /// from then on, the label that landed.
    @State private var shown: Bool
    /// The label the restamp in progress lands: `isOn` as of the last change before it touches
    /// the paper.
    @State private var landing: Bool
    /// `isOn` as of the last change.
    @State private var latest: Bool
    /// The stamp's frame in its window, for a tap and for the button's return to the screen,
    /// kept out of the view's state so a scroll doesn't draw the button again.
    @State private var place = Place()
    /// Whether a restamp is in progress, from the tap until the new label settles.
    @State private var restamping = false
    /// Whether the restamp in progress has touched the paper.
    @State private var touched = false
    /// Counts the stamp's landings, for the haptic tap.
    @State private var landings = 0
    /// Whether the stamp is held down.
    @State private var pressing = false
    /// The label whose copy looks pressed: the one under the press, through the restamp that the
    /// press's tap starts, so it doesn't draw again before the stamp covers it.
    @State private var pressedLabel: Bool?
    @State private var hovering = false
    @AppStorage(ImpactSound.storageKey) private var sounds = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.stampStage) private var stage
    #if DEBUG
        @Environment(\.isEnabled) private var isEnabled
        /// `isEnabled` as of the last change, which the demo's task reads at each tap.
        @State private var demoEnabled = false
    #endif

    init(
        _ isOn: Bool, stamped: Bool, action: @escaping () -> Void,
        @ViewBuilder label: @escaping (Bool) -> Content
    ) {
        self.isOn = isOn
        self.stamped = stamped
        self.action = action
        self.label = label
        _shown = State(initialValue: isOn)
        _landing = State(initialValue: isOn)
        _latest = State(initialValue: isOn)
    }

    var body: some View {
        if stamped {
            stamp
        } else {
            Button(action: action) { label(isOn) }
        }
    }

    private var stamp: some View {
        Button(action: tap) { widest(copies ? false : shown) }
            .environment(\.stampCopy, copy(of: false))
            .background {
                if copies {
                    if copy(of: true)?.prints == true {
                        Button(action: {}) { widest(true) }
                            .environment(\.stampCopy, copy(of: true))
                            .focusable(false)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    RestampEffect.Primer()
                }
            }
            // The window always draws the stamp (`stampStage()`), so nothing is made at a tap.
            // The button moves it only for a restamp, so a scroll at rest draws nothing more.
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { frame in
                place.frame = frame
                if restamping && place.onScreen { stage?.frame = frame }
            }
            .onAppear { place.onScreen = true }
            .onDisappear {
                place.onScreen = false
                // A stamp whose label left the screen, as for another tab, stops at once.
                guard let stage, stage.frame == place.frame else { return }
                stage.frame = nil
                stage.restamping = false
            }
            .modifier(
                RestampClock(
                    restamp: Restamp(
                        clock: stage?.clock ?? 0, restamping: restamping, shown: shown,
                        landing: landing),
                    onContact: contact)
            )
            .onPreferenceChange(StampPressing.self) { pressed in
                pressing = pressed
                if pressed {
                    pressedLabel = shown
                } else {
                    // A tap runs after the release that makes it, and a restamp it starts keeps
                    // the pressed look.
                    Task { @MainActor in
                        if !restamping && !pressing { pressedLabel = nil }
                    }
                }
            }
            #if os(macOS)
                .onHover { hovering = $0 }
            #endif
            .onChange(of: isOn) {
                latest = isOn
                if restamping {
                    if !touched { landing = isOn }
                    return
                }
                shown = isOn
                landing = isOn
            }
            #if os(iOS)
                .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: landings)
            #endif
            #if DEBUG
                // `-BookwormsRestampDemo <seconds>` taps an enabled stamp that many seconds
                // after it appears and three more times 2 seconds apart; 2 seconds later, twice
                // 0.15 seconds apart, as the stamp comes down; and 2 seconds after that, twice 0.8
                // seconds apart, as the new label soaks in, so a recording shows restamps without
                // a touch. The eight taps leave `isOn` as it was.
                .onChange(of: isEnabled, initial: true) { demoEnabled = isEnabled }
                .task {
                    let demo = UserDefaults.standard.string(forKey: "BookwormsRestampDemo")
                    guard let delay = demo.flatMap(Double.init) else { return }
                    try? await Task.sleep(for: .seconds(delay))
                    for pause in [2, 2, 2, 2, 0.15, 2, 0.8, 2.0] {
                        guard !Task.isCancelled else { return }
                        if demoEnabled { tap() }
                        try? await Task.sleep(for: .seconds(pause))
                    }
                }
            #endif
    }

    private var solid: Bool { contrast == .increased || reduceTransparency }
    /// Whether the stamp comes down for a restamp. It doesn't with Reduce Motion, at
    /// accessibility text sizes, whose labels stack their symbols above their titles and stand
    /// far taller than the stamp's rubber face, or outside a window that draws it.
    private var travels: Bool { stage != nil && !reduceMotion && !typeSize.isAccessibilitySize }
    /// Whether each label prints in a copy of its own, which a restamp covers and lands.
    private var copies: Bool { travels && !solid }

    /// How the copy that prints `on`'s label prints, or `nil` when the stamp prints its label
    /// itself. Every copy that prints follows the Mac's pointer, so the other copy, which prints
    /// only around a press and a restamp, is ready to land.
    private func copy(of on: Bool) -> StampCopy? {
        guard copies else { return nil }
        return StampCopy(
            label: on, prints: on == shown || pressing || restamping,
            pressed: pressedLabel == on, hovered: hovering)
    }

    /// The label for `on`, in a frame that also fits the other label, each in a pressed stamp's
    /// heavier type, whose symbols are wider. A copy behind the stamp takes the stamp's frame, so
    /// its pressed label must fit it.
    private func widest(_ on: Bool) -> some View {
        ZStack {
            label(false).fontWeight(.heavy).hidden()
            label(true).fontWeight(.heavy).hidden()
            label(on)
        }
    }

    private func tap() {
        guard !restamping else { return action() }
        action()
        if travels { restamp() } else { land() }
    }

    /// Brings the stamp down, landing `isOn` as of the last change before it touches the paper.
    /// Then restamps again if a tap after that changed `isOn`.
    private func restamp() {
        guard let stage else { return }
        if sounds { StampThunk.prepare() }
        restamping = true
        landing = latest
        if let frame = place.frame { stage.frame = frame }
        stage.restamping = true
        withAnimation(.linear(duration: RestampTimeline.duration)) {
            stage.clock += 1
        } completion: {
            // A restamp whose frames didn't draw, as in the background, never touched.
            if !touched { shown = landing }
            touched = false
            if latest != shown && place.onScreen {
                restamp()
            } else {
                shown = latest
                landing = latest
                restamping = false
                if stage.frame == place.frame { stage.restamping = false }
                if !pressing { pressedLabel = nil }
            }
        }
    }

    /// The stamp's touch on the paper (`RestampClock`): the new label lands, under the stamp.
    private func contact() {
        guard restamping, !touched else { return }
        touched = true
        // When the stamp lands the label it covers, that label's copy, which keeps the press's
        // look until now, lands the fresh ink. It redraws unpressed here, under the stamp.
        if !pressing && pressedLabel == landing { pressedLabel = nil }
        shown = landing
        land()
    }

    private func land() {
        if sounds { StampThunk.play() }
        landings += 1
    }
}

/// A `RestampButton`'s frame in its window, which a scroll changes without drawing the button,
/// and whether the button is on screen.
private final class Place {
    var frame: CGRect?
    var onScreen = false
}

/// Whether a stamp is held down, for its `RestampButton`.
private struct StampPressing: PreferenceKey {
    static var defaultValue: Bool { false }

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// How a `RestampButton` prints one of its stamp's copies (`StampImpression`), which reads this
/// in place of its own press and the Mac's pointer.
struct StampCopy: Equatable {
    /// The label the copy prints.
    var label: Bool
    /// Whether the copy prints its impression. A copy that can't show prints nothing.
    var prints: Bool
    var pressed: Bool
    var hovered: Bool
}

/// The restamp's timeline, in seconds from the tap. The stamp comes down from above the window,
/// touches the paper at `contact`, where the new label lands, presses for `press`, and lifts away
/// over `lift`, its face clearing the label by `clears`, while the new label soaks in until
/// `duration`.
enum RestampTimeline {
    static let duration = 0.84
    static let contact = 0.24
    static let press = 0.072
    static let lift = 0.216

    /// About when the lifting stamp's face has cleared the label.
    static let clears = contact + press + 0.4 * lift

    /// How far the new label's fresh ink is from soaking in at `time`: 1 from the stamp's touch
    /// until its face clears the label, so the ink soaks in where it can be seen, then easing to
    /// 0 at the end.
    static func bleed(at time: Double) -> Double { 1 - smoothstep(clears, duration, time) }

    /// The stamp at `time`: its height above the paper, as a share of the height it comes down
    /// from, out of sight above the window (`StampFall`), and how far its rubber gives, as a share
    /// of the stamp's height. It comes down already moving, lands fastest, and lifts away as a
    /// hand lifts it.
    static func stamp(at time: Double) -> (height: Double, squeeze: Double) {
        guard time > 0 else { return (1, 0) }
        if time < contact {
            let fall = time / contact
            return (1 - fall * (0.3 + 0.7 * fall), 0)
        }
        let pressed = time - contact
        if pressed < press {
            // The rubber gives under the blow, then springs back as the hand holds it down.
            let squeeze = 0.014 * min(pressed / 0.012, 1) * (1 - smoothstep(0.012, press, pressed))
            return (0, squeeze)
        }
        return (smoothstep(0, 1, min((pressed - press) / lift, 1)), 0)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Where a window's desk stamp restamps a `RestampButton`, which the window draws above all its
/// content (`stampStage()`), so the stamp comes in from above the window's top edge, over the
/// navigation and tab bars, and no card or scroll view clips it. Its `clock` is the restamp's one clock,
/// which the stamp and the button's labels both follow.
@MainActor @Observable final class StampStage {
    /// The frame in the window (`.global`) of the button the stamp last restamped, or `nil` once
    /// that button leaves the screen.
    var frame: CGRect?
    /// Rises by 1 for each restamp, steadily over `RestampTimeline.duration` (`Restamp.clock`).
    var clock = 0.0
    var restamping = false
}

extension View {
    /// Draws the desk stamp of the `RestampButton`s inside the view above all of it. Apply it to
    /// a window's root view.
    func stampStage() -> some View { modifier(StampStageHost()) }
}

private struct StampStageHost: ViewModifier {
    @State private var stage = StampStage()

    func body(content: Content) -> some View {
        content
            .environment(\.stampStage, stage)
            .overlay { StampStageOverlay(stage: stage).ignoresSafeArea() }
    }
}

/// The desk stamp over the window, always drawn, too faint to see at rest, so its view and images
/// are ready when it comes down: over the button it last restamped, or before any restamp, at the
/// window's top leading corner, at about a tag's size.
private struct StampStageOverlay: View {
    let stage: StampStage

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.frame(in: .global).origin
            let frame = stage.frame ?? CGRect(x: window.x, y: window.y, width: 220, height: 32)
            StampFall(frame: frame.offsetBy(dx: -window.x, dy: -window.y), top: -window.y)
        }
        .modifier(
            RestampClock(
                restamp: Restamp(clock: stage.clock, restamping: stage.restamping),
                onContact: {})
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where a restamp is (`RestampButton`, `RestampEffect`, `StampFall`).
struct Restamp: Equatable {
    /// Rises by 1 for each restamp, steadily over `RestampTimeline.duration`.
    var clock = 0.0
    /// Whether a restamp is in progress. At rest the stamp is at rest whatever `clock` says, so
    /// a frame of a restamp that didn't draw, as off screen, never lingers.
    var restamping = false
    /// The label the stamp shows at rest, and before the stamp touches the paper, the label it
    /// covers.
    var shown = false
    /// The label the restamp lands as the stamp touches the paper.
    var landing = false

    /// Seconds into the restamp in progress, or 0 at rest.
    var time: Double {
        restamping ? (clock - clock.rounded(.down)) * RestampTimeline.duration : 0
    }
    /// Whether the stamp of the restamp in progress has touched the paper.
    var touched: Bool { time >= RestampTimeline.contact }
}

/// Animates a restamp's `clock` and passes its every frame to the stamp's copies and the falling
/// stamp through the environment, so a copy or the stamp that appears partway through is in
/// step. Calls `onContact` on the frame the stamp touches the paper.
private struct RestampClock: ViewModifier, Animatable {
    var restamp: Restamp
    let onContact: () -> Void

    nonisolated var animatableData: Double {
        get { restamp.clock }
        set { restamp.clock = newValue }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.restamp, restamp)
            .onChange(of: restamp.touched) { _, touched in
                if touched { onContact() }
            }
    }
}

/// Restamps a stamp's printed copy of `label` as its `restamp` says (`RestampButton`): soaks in
/// the fresh ink of the label that landed through a shader (`Restamp.metal`) that runs only while
/// it soaks in, so a stamp at rest costs nothing.
struct RestampEffect: ViewModifier {
    let restamp: Restamp
    let label: Bool
    let ink: Color

    /// How far the copy printing `label` is from soaking in its fresh ink, from 0 to 1, and
    /// whether it shows. The copy of the label that was shown shows as printed until the stamp
    /// touches the paper, and from then the copy of the label that lands shows with its fresh ink;
    /// they are one copy when the label lands again. At rest, the shown label's copy shows.
    nonisolated static func stage(of restamp: Restamp, label: Bool) -> (
        bleed: Double, shows: Bool
    ) {
        if !restamp.touched { return (0, label == restamp.shown) }
        guard label == restamp.landing else { return (0, false) }
        return (RestampTimeline.bleed(at: restamp.time), true)
    }

    /// Whether a `Primer` has drawn through the shader in this launch.
    private static var primed = false

    /// Draws a speck through the shader, out of sight, a second after it appears, then goes, once
    /// a launch. The first draw through the shader sets up its pipeline, which holds up the
    /// app's drawing for a moment; without the speck, that happens at the first restamp's touch.
    struct Primer: View {
        @State private var drawn = RestampEffect.primed
        @State private var drawing = false

        var body: some View {
            if !drawn {
                Color.black.opacity(0.01)
                    .frame(width: 2, height: 2)
                    .layerEffect(
                        RestampEffect.shader(bleed: 0.5, ink: .black),
                        maxSampleOffset: RestampEffect.reach, isEnabled: drawing
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, !RestampEffect.primed else { return }
                        drawing = true
                        try? await Task.sleep(for: .seconds(1))
                        RestampEffect.primed = true
                        drawn = true
                    }
            }
        }
    }

    /// How far the heaviest fresh ink spreads as it soaks in, in points: the shader's reach.
    private static let reach = CGSize(width: 0.9, height: 0.9)

    private static func shader(bleed: Double, ink: Color) -> Shader {
        ShaderLibrary.restamp(.float(bleed), .float(reach.width), .color(ink))
    }

    func body(content: Content) -> some View {
        let stage = Self.stage(of: restamp, label: label)
        content
            .layerEffect(
                Self.shader(bleed: stage.bleed, ink: ink), maxSampleOffset: Self.reach,
                isEnabled: stage.shows && stage.bleed > 0
            )
            // A copy out of sight stays drawn, too faint to see, so it is ready to land; at no
            // opacity at all, it would not draw until it shows.
            .opacity(stage.shows ? 1 : 0.001)
    }
}

/// Applies `RestampEffect` to the printed copy of `label` as the environment's `restamp` says,
/// or nothing to a stamp that prints itself. Reading the environment here, rather than in the
/// stamp, keeps a restamp from drawing the stamp's ink again.
private struct RestampFromEnvironment: ViewModifier {
    let label: Bool?
    let ink: Color
    @Environment(\.restamp) private var restamp

    func body(content: Content) -> some View {
        if let label {
            content.modifier(RestampEffect(restamp: restamp, label: label, ink: ink))
        } else {
            content
        }
    }
}

/// The wooden desk stamp that restamps a label (`RestampButton`), as the environment's
/// `restamp` says: a still baked from a 3D model (`script/stamp-still.py`), seen from in front and
/// a little above through a long lens, as the flat page is, so moving the still is moving the
/// stamp. It comes in from above the window's top, straight down onto the label at `frame`, its
/// rubber face covering it, with its shadow on the paper under it, presses, and lifts away out of
/// the window (`RestampTimeline.stamp(at:)`). It stays opaque all the way. `top` is the window's
/// top edge.
private struct StampFall: View {
    let frame: CGRect
    let top: CGFloat
    @Environment(\.restamp) private var restamp

    /// The still's size in pixels.
    private static let still = CGSize(width: 1006, height: 661)
    /// The rubber face's outline on the paper, from its far edge down to its near edge, which
    /// touches the paper first in the picture, at its widest, in the still's pixels.
    private static let face = CGRect(x: 5.4, y: 467.2, width: 995.2, height: 188.2)
    /// The shadows' frames in the still's pixels, with the stamp touching the paper and lifted a
    /// third of its height.
    private static let nearShadow = CGRect(x: -7, y: 462, width: 1052, height: 261)
    private static let farShadow = CGRect(x: -81, y: 447, width: 1258, height: 349)
    /// How much wider than the label the rubber face is, so it covers the label's frame.
    private static let cover = 1.04
    /// The least the stamp comes down, and the height above the paper from which its shadow is
    /// at its faintest and widest, as shares of the stamp's height on the screen.
    private static let drop = 1.2

    var body: some View {
        let stamp = RestampTimeline.stamp(at: restamp.time)
        let scale = frame.width * Self.cover / Self.face.width
        // Puts the still's face over the label.
        let origin = CGPoint(
            x: frame.midX - Self.face.midX * scale, y: frame.midY - Self.face.midY * scale)
        let height = Self.still.height * scale
        // From the top of its travel, the stamp's foot is above the window's top edge.
        let travel = max(Self.drop * height, origin.y + height - top)
        // At rest, the stamp lies where the overlay rests it, too faint to see, so its images are ready.
        let resting = !restamp.restamping
        let lift = resting ? 0 : stamp.height * travel
        let raised = min(lift / (Self.drop * height), 1)
        // The shadow darkens and sharpens as the stamp comes down. It is the warm dark of shade
        // on card stock, faint enough that the paper stays paper.
        let near = pow(max(0, 1 - raised / 0.12), 2)
        let far = pow(1 - raised, 2) * (1 - near)
        ZStack(alignment: .topLeading) {
            shadow(.stampShadowNear, in: Self.nearShadow, scale: scale, origin: origin)
                .opacity(resting ? 0.001 : max(near * 0.32, 0.001))
            // A higher stamp's shadow spreads wider.
            shadow(
                .stampShadowFar, in: Self.farShadow, scale: scale, origin: origin,
                spread: 1 + 0.35 * raised
            )
            .opacity(resting ? 0.001 : max(far * 0.32, 0.001))
            Image(.stampStill)
                .resizable()
                .frame(width: Self.still.width * scale, height: height)
                .scaleEffect(
                    x: 1, y: 1 - stamp.squeeze,
                    anchor: anchor(
                        of: CGPoint(x: Self.face.midX, y: Self.face.maxY),
                        in: CGRect(origin: .zero, size: Self.still))
                )
                .offset(x: origin.x, y: origin.y - lift)
                .opacity(resting ? 0.001 : 1)
        }
    }

    /// A shadow image whose frame in the still's pixels is `frame`, on the paper under the face,
    /// grown by `spread` around the face's middle.
    private func shadow(
        _ image: ImageResource, in frame: CGRect, scale: CGFloat, origin: CGPoint,
        spread: CGFloat = 1
    ) -> some View {
        Image(image)
            .renderingMode(.template)
            .resizable()
            .foregroundStyle(Stationery.rodHole)
            .frame(width: frame.width * scale, height: frame.height * scale)
            .scaleEffect(
                spread, anchor: anchor(of: CGPoint(x: Self.face.midX, y: Self.face.midY), in: frame)
            )
            .offset(x: origin.x + frame.minX * scale, y: origin.y + frame.minY * scale)
    }

    private func anchor(of point: CGPoint, in frame: CGRect) -> UnitPoint {
        UnitPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }
}

/// A stamp's symbol beside its title, or above it when `stacked`.
private struct StampLabelStyle: LabelStyle {
    let stacked: Bool

    func makeBody(configuration: Configuration) -> some View {
        let layout =
            stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            configuration.icon
            configuration.title
        }
    }
}

/// A busy stamp's symbol: a spinner that turns in the stamp's ink on its live label and leaves a
/// blank in its printed copy, so the stamp's canvas never draws again for it.
struct StampSpinner: View {
    @Environment(\.liveStampInk) private var ink

    var body: some View {
        Image(systemName: "progress.indicator")
            .symbolEffect(
                .variableColor.iterative.dimInactiveLayers.nonReversing,
                options: .repeat(.continuous), isActive: ink != nil
            )
            .foregroundStyle(ink ?? .clear)
    }
}

/// A stamp's impression, its `type` and `frame`, as the ink took on the paper, drawn once into a
/// canvas.
///
/// Most of the ink is full strength. Where the stamp met the paper unevenly, the frame took
/// lighter in one broad patch, about 30 percent lighter at its heart, and in a smaller patch
/// about 13 percent lighter, each with a blotchy edge, at an end, in a corner, along the top or
/// bottom, or across the middle. The type took lighter in two small, soft patches, at most about
/// 18 and 11 percent lighter, that fall across parts of neighboring letters rather than whole
/// words. The paper's tooth leaves a fine grain. In a few places away from the lighter patches,
/// the ink pooled: it is a little darker there, and it wicked into the paper's fibers, feathering
/// raggedly past the edges. On the frame, that is a blotch at one corner, one along the top or
/// bottom that feathers into the frame, and sometimes one along the other edge that feathers out,
/// up to about 1.3 points past the line; the two along the edges taper into the line at their
/// ends. On the type, it is one side of a few letters, up to about two thirds of a point past
/// them, so the counters stay open. `book` and `salt` place all of it, so the impression never
/// changes between redraws. `lightening` scales the lighter patches and the grain, so a fuller
/// impression is more even.
///
/// A stamped symbol, such as a color's reset (`ColorResetButton`), passes its parts as `type` and
/// `frame`. Each must draw some ink: a pool over a part that draws nothing prints black.
///
/// The canvas draws again only when its size or the impression changes, so scrolling moves one
/// finished image, without a live blur.
struct StampInk<TypeView: View, FrameView: View>: View {
    let book: Int
    let salt: UInt64
    let ink: Color
    /// The share of the lighter patches and the paper's grain that shows: 1 for an ordinary
    /// impression, less for a fuller one.
    let lightening: Double
    /// The width of the frame's line.
    let line: CGFloat
    /// The room between the frame's outer edge and the label.
    let inset: CGSize
    let type: TypeView
    let frame: FrameView

    /// The room around the impression for ink that bled past its frame.
    private static var margin: CGFloat { 3 }

    var body: some View {
        Canvas { context, size in
            guard let type = context.resolveSymbol(id: 0),
                let frame = context.resolveSymbol(id: 1)
            else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let area = CGRect(origin: .zero, size: size).insetBy(dx: Self.margin, dy: Self.margin)
            let label = area.insetBy(dx: inset.width, dy: inset.height)
            let framePatches = framePatches(in: area)
            let typePatches = typePatches(in: label)
            let fibers = dots(
                in: area, count: Int(area.width * area.height), seed: 3000, radius: 0.25...0.6)

            /// Draws `symbol` blurred by `blur` only inside `pools`, broken up by the paper's
            /// fibers when `fibrous`.
            func pooled(
                _ symbol: GraphicsContext.ResolvedSymbol, in context: GraphicsContext,
                pools: [Blot], fibrous: Bool, blur: CGFloat
            ) {
                context.drawLayer { mask in
                    for pool in pools { pool.fill(in: mask) }
                    if fibrous {
                        mask.blendMode = .destinationOut
                        Self.fill(fibers, in: mask, alpha: 0.4...0.85)
                    }
                    mask.blendMode = .sourceIn
                    mask.drawLayer { copy in
                        if blur > 0 { copy.addFilter(.blur(radius: blur)) }
                        copy.draw(symbol, at: center)
                    }
                }
            }

            /// Prints `symbol` in a layer of its own, so `lighten` erases only its ink. Inside
            /// `pools`, the ink is a little darker and wicked into the paper's fibers: it spreads
            /// raggedly past the edges, by about `blur`, under a faint feathered fringe.
            func impress(
                _ symbol: GraphicsContext.ResolvedSymbol, pools: [Blot], blur: CGFloat,
                erasing lighten: (GraphicsContext) -> Void
            ) {
                context.drawLayer { layer in
                    var feather = layer
                    feather.opacity = 0.5
                    pooled(symbol, in: feather, pools: pools, fibrous: true, blur: blur * 0.8)
                    var spread = layer
                    // Smooths the threshold's hard edge.
                    spread.addFilter(.blur(radius: 0.25))
                    spread.drawLayer { dense in
                        dense.addFilter(.alphaThreshold(min: 0.28, color: ink))
                        pooled(symbol, in: dense, pools: pools, fibrous: true, blur: blur)
                    }
                    layer.draw(symbol, at: center)
                    var dark = layer
                    dark.addFilter(.colorMultiply(Color(white: 0.75)))
                    pooled(symbol, in: dark, pools: pools, fibrous: false, blur: 0)
                    // Erasing part of the ink lets the paper show through.
                    var erase = layer
                    erase.blendMode = .destinationOut
                    lighten(erase)
                }
            }

            impress(frame, pools: framePools(in: area, avoiding: framePatches), blur: 1.05) {
                erase in
                for (index, patch) in framePatches.enumerated() {
                    lighten(
                        erase, across: patch, scale: lightening,
                        seed: 1100 + UInt64(index) * 100)
                }
            }
            impress(type, pools: letterPools(in: label, avoiding: typePatches), blur: 0.5) {
                erase in
                var erase = erase
                erase.opacity = lightening
                for patch in typePatches { patch.fill(in: erase) }
            }
            // The paper's tooth.
            var tooth = context
            tooth.blendMode = .destinationOut
            Self.fill(
                dots(
                    in: area, count: Int(area.width * area.height / 22), seed: 4000,
                    radius: 0.3...0.7),
                in: tooth, alpha: (0.08 * lightening)...(0.23 * lightening))
        } symbols: {
            type.padding(Self.margin).tag(0)
            frame.padding(Self.margin).tag(1)
        }
        .padding(-Self.margin)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A repeatable value in `0..<1` for this stamp and `part`.
    private func unit(_ part: UInt64) -> Double { ShareStyle.unit(part, book, salt) }

    /// A repeatable value in `range` for this stamp and `part`.
    private func value(_ part: UInt64, in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit(part) * (range.upperBound - range.lowerBound)
    }

    /// The outlines of the patches where the frame took lighter, each with its lightening at its
    /// heart as its strength: a broad patch at an end, in a corner, along the top or bottom, or
    /// across the middle, and a smaller, fainter one on the other side. Neighboring salts take
    /// different places, so the stamps on one card differ.
    private func framePatches(in area: CGRect) -> [Blot] {
        let (across, down): (ClosedRange<Double>, ClosedRange<Double>) =
            switch (UInt64(truncatingIfNeeded: book) &+ salt) % 4 {
            case 0: (0.04...0.16, 0.3...0.7)
            case 1: (0.06...0.2, 0...0.15)
            case 2: (0.3...0.5, 0...0.1)
            default: (0.35...0.5, 0.3...0.7)
            }
        // Coin flips mirror the place across the stamp and from top to bottom.
        let x = unit(1005) < 0.5 ? value(1000, in: across) : 1 - value(1000, in: across)
        let y = unit(1006) < 0.5 ? value(1001, in: down) : 1 - value(1001, in: down)
        let main = Blot(
            center: CGPoint(x: area.minX + area.width * x, y: area.minY + area.height * y),
            radii: CGSize(
                width: area.width * value(1002, in: 0.22...0.3),
                height: area.height * value(1003, in: 0.6...0.9)),
            strength: value(1004, in: 0.29...0.34))
        let other = x < 0.5 ? 0.65...0.9 : 0.1...0.35
        let second = Blot(
            center: CGPoint(
                x: area.minX + area.width * value(1010, in: other),
                y: area.minY + area.height * value(1011, in: 0.1...0.9)),
            radii: CGSize(
                width: area.width * value(1012, in: 0.12...0.16),
                height: area.height * value(1013, in: 0.45...0.7)),
            strength: value(1014, in: 0.11...0.15))
        return [main, second]
    }

    /// The patches where the type took lighter: two soft patches 20 to 30 points across, about
    /// 18 and 11 percent lighter at their middles, placed along `label` without regard to its
    /// words, so each falls across parts of neighboring letters.
    private func typePatches(in label: CGRect) -> [Blot] {
        let first = value(1500, in: 0.05...0.5)
        let places = [
            (first, 0.17...0.2, UInt64(1510)),
            (first + value(1501, in: 0.3...0.45), 0.1...0.13, UInt64(1520)),
        ]
        // A coin flip mirrors them across the stamp.
        let mirrored = unit(1502) < 0.5
        return places.map { share, strength, part in
            Blot(
                center: CGPoint(
                    x: label.minX + label.width * (mirrored ? 1 - share : share),
                    y: label.midY + value(part, in: -3...3)),
                radii: CGSize(
                    width: value(part + 1, in: 10...15),
                    height: label.height * value(part + 2, in: 1...1.3)),
                strength: value(part + 3, in: strength), core: 0.25)
        }
    }

    /// Erases up to `scale` times `patch`'s strength of the ink in `context` across `patch`,
    /// through overlapping blots placed by `seed`: broad ones make its body and small ones
    /// roughen its rim, so its edge is blotchy and varies along both axes.
    private func lighten(
        _ context: GraphicsContext, across patch: Blot, scale: Double, seed: UInt64
    ) {
        var erase = context
        erase.blendMode = .destinationOut
        erase.opacity = patch.strength * scale
        erase.drawLayer { layer in
            for index in 0..<12 {
                let part = seed + UInt64(index) * 8
                let rim = index >= 7
                let angle = unit(part) * 2 * .pi
                let reach = value(part + 1, in: rim ? 0.75...1.1 : 0...0.6)
                let size = value(part + 2, in: rim ? 0.12...0.25 : 0.35...0.6)
                Blot(
                    center: CGPoint(
                        x: patch.center.x + cos(angle) * reach * patch.radii.width,
                        y: patch.center.y + sin(angle) * reach * patch.radii.height),
                    radii: CGSize(
                        width: patch.radii.width * size,
                        height: patch.radii.height * size * value(part + 3, in: 0.8...1.3)),
                    strength: value(part + 4, in: 0.6...1)
                )
                .fill(in: layer)
            }
        }
    }

    /// Where the ink pooled on the frame, kept off the lighter `patches`: a blotch at one corner;
    /// one 12 to 30 points long along the top or bottom, in the half away from that corner, that
    /// feathers into the frame; and for about half the stamps, one 6 to 18 points long along the
    /// other edge that feathers out.
    private func framePools(in area: CGRect, avoiding patches: [Blot]) -> [Blot] {
        let lighter = { (point: CGPoint) in patches.contains { $0.covers(point) } }
        // The middle of the frame's line.
        let track = area.insetBy(dx: line / 2, dy: line / 2)
        let start = Int(unit(2000) * 4)
        let corners = (0..<4)
            .map { index in
                let corner = (start + index) % 4
                return CGPoint(
                    x: corner % 2 == 0 ? track.minX + 1 : track.maxX - 1,
                    y: corner < 2 ? track.minY + 1 : track.maxY - 1)
            }
        let corner = corners.first { !lighter($0) } ?? corners[0]
        let size = value(2001, in: 5...8.5)
        var pools = [Blot(center: corner, radii: CGSize(width: size, height: size), strength: 1)]
        let edges = unit(2002) < 0.5 ? 1 : 2
        for index in 0..<8 where pools.count <= edges {
            let part = 2010 + UInt64(index) * 8
            let first = pools.count == 1
            // The first blotch's middle lies inside the line and the second's outside it, so
            // each feathers past that side of the line and barely reaches the other.
            let out = (first ? -1 : 1) * (line / 2 + 1)
            // The first lies along the top or the bottom, and the second along the other.
            let top = first ? unit(part) < 0.5 : pools[1].center.y > track.midY
            let side: CGFloat = top ? -1 : 1
            let share =
                first ? (corner.x < track.midX ? 0.5 : 0) + unit(part + 1) / 2 : unit(part + 1)
            let center = CGPoint(
                x: track.minX + share * track.width,
                y: track.midY + side * (track.height / 2 + out))
            guard !lighter(center) else { continue }
            let length = value(part + 2, in: first ? 12...30 : 6...18)
            // The blot fades from its middle to its ends, so the blotch tapers into the line,
            // and its faded rim leaves no bleed, so it reaches past the blotch's ends.
            pools.append(
                Blot(
                    center: center,
                    radii: CGSize(width: length * 0.85, height: value(part + 3, in: 4.5...5.5)),
                    strength: 1, core: 0.15))
        }
        return pools
    }

    /// Where the ink pooled on the type, kept off the lighter `patches`: a small blot in each
    /// sixth of `label` that catches one side of a letter, or nothing where it falls between
    /// letters, so a few letters bleed.
    private func letterPools(in label: CGRect, avoiding patches: [Blot]) -> [Blot] {
        (0..<6)
            .compactMap { index in
                let part = 2100 + UInt64(index) * 8
                let center = CGPoint(
                    x: label.minX + label.width * (Double(index) + unit(part)) / 6,
                    y: label.midY + value(part + 1, in: -5...5))
                guard !patches.contains(where: { $0.covers(center) }) else { return nil }
                let size = value(part + 2, in: 2.8...4.4)
                return Blot(
                    center: center,
                    radii: CGSize(width: size, height: size * value(part + 3, in: 1...1.6)),
                    strength: 1)
            }
    }

    /// `count` small dots in `area`, each a radius in `radius`, in three paths, so filling them
    /// takes three fills. `seed` places them.
    private func dots(in area: CGRect, count: Int, seed: UInt64, radius: ClosedRange<Double>)
        -> [Path]
    {
        var batches = [Path](repeating: Path(), count: 3)
        for index in 0..<count {
            let part = seed + UInt64(index) * 4
            let size = value(part + 2, in: radius)
            batches[index % 3]
                .addEllipse(
                    in: CGRect(
                        x: area.minX + unit(part) * area.width - size,
                        y: area.minY + unit(part + 1) * area.height - size,
                        width: 2 * size, height: 2 * size))
        }
        return batches
    }

    /// Fills `batches` in black in `context`, at opacities that span `alpha`. It's nonisolated so
    /// the canvas's layer closures can call it.
    nonisolated private static func fill(
        _ batches: [Path], in context: GraphicsContext, alpha: ClosedRange<Double>
    ) {
        for (level, batch) in batches.enumerated() {
            let opacity =
                alpha.lowerBound
                + (alpha.upperBound - alpha.lowerBound) * Double(level) / Double(batches.count - 1)
            context.fill(batch, with: .color(.black.opacity(opacity)))
        }
    }
}

/// A soft elliptical blot, `strength` across its `core`, a share of its radii, that fades to
/// nothing at its `radii`.
private struct Blot {
    var center: CGPoint
    var radii: CGSize
    var strength: Double
    var core = 0.4

    /// Whether `point` lies inside the blot.
    func covers(_ point: CGPoint) -> Bool {
        let x = (point.x - center.x) / radii.width
        let y = (point.y - center.y) / radii.height
        return x * x + y * y < 1
    }

    /// Fills the blot in black in `context`.
    func fill(in context: GraphicsContext) {
        var context = context
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: 1, y: radii.height / radii.width)
        let radius = radii.width
        context.fill(
            Path(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(strength), location: 0),
                    .init(color: .black.opacity(strength), location: core),
                    .init(color: .black.opacity(0), location: 1),
                ]),
                center: .zero, startRadius: 0, endRadius: radius))
    }
}

/// A paper tag on the wall, held at the top by a strip of washi tape, with `content` printed on
/// it. The tape lies under `content`, so a stamp coming down on the tag (`StampFall`) passes over
/// it.
struct TapedTag<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        CardStockSheet(cornerRadius: 3) {
            content.padding(.horizontal, 18).padding(.vertical, 16)
                .background(alignment: .top) {
                    TornStrip()
                        .fill(Stationery.tape)
                        .frame(width: 46, height: 16)
                        .rotationEffect(.degrees(-2))
                        .offset(y: -8)
                        .accessibilityHidden(true)
                }
        }
        // The tape reaches above the tag, onto the wall.
        .padding(.top, 8)
    }
}

/// A strip of tape torn from the roll, with a fine zigzag at both ends.
private struct TornStrip: Shape {
    func path(in rect: CGRect) -> Path {
        let teeth = 5
        let step = rect.height / CGFloat(teeth)
        let depth: CGFloat = 1.2
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        for tooth in 0..<teeth {
            let y = rect.minY + step * CGFloat(tooth)
            path.addLine(to: CGPoint(x: rect.maxX - depth, y: y + step / 2))
            path.addLine(to: CGPoint(x: rect.maxX, y: y + step))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        for tooth in (0..<teeth).reversed() {
            let y = rect.minY + step * CGFloat(tooth)
            path.addLine(to: CGPoint(x: rect.minX + depth, y: y + step / 2))
            path.addLine(to: CGPoint(x: rect.minX, y: y))
        }
        path.closeSubpath()
        return path
    }
}

/// A bookmark ribbon's end: a strip of cloth with a notch cut into its tip.
struct RibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let notch = min(rect.width * 0.6, rect.height * 0.25)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notch))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A red cloth bookmark ribbon, with a faint sheen along one edge.
struct Ribbon: View {
    var body: some View {
        RibbonShape()
            .fill(Stationery.red)
            .overlay {
                LinearGradient(
                    colors: [.white.opacity(0.18), .clear, .black.opacity(0.18)],
                    startPoint: .leading, endPoint: .trailing
                )
                .clipShape(RibbonShape())
            }
            .accessibilityHidden(true)
    }
}
