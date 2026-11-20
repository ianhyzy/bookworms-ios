import RealityKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// A Desk share image's pile as the image shows it, which the preview lets the reader rearrange
/// before saving (`PileArranging`): the scene that rendered the image, with its books where the
/// image shows them, and the image's heading, which draws over them.
@MainActor
struct ArrangeablePile {
    let scene: BookPileScene
    /// The image's heading and profile link over a clear background (`PileSnapshotCard`).
    let heading: PileSnapshotCard
}

/// The poses the reader moved a Desk image's books to, by book ID, for the image of one size and
/// seed with one list of books. Another size, a shuffle, or other books lay the spread out anew,
/// and the poses no longer fit it.
struct PileArrangement: Equatable {
    let aspect: ShareAspect
    let seed: UInt64
    let ids: [Int]
    let poses: [Int: Transform]

    /// The poses, when they belong to the image of `aspect` and `seed` that draws `ids`.
    func poses(aspect: ShareAspect, seed: UInt64, ids: [Int]) -> [Int: Transform]? {
        self.aspect == aspect && self.seed == seed && self.ids == ids ? poses : nil
    }
}

/// Lets the reader pick up, carry, and throw the books of a Desk share image's preview, as on
/// the Desk (`PileCarry`), so that the saved image shows their arrangement.
///
/// A drag that starts on a book picks it up at once. On the iPhone, a finger that holds still
/// instead shows the image full size; on the Mac, a drag that starts off the books drags the
/// image out. While books move, the pile's scene draws live over the image, under its heading.
/// Once every book settles, a still of the live view stands in for it until the image that
/// `arranged` asks for, from the books' poses, replaces it. Reduce Motion carries a book level
/// and drops it rather than throwing it, as on the Desk.
///
/// RealityKit's render thread can crash drawing the live view while an offscreen renderer steps
/// the same engine, so the live view gives way whenever a pile image renders, and the books stay
/// where they are.
struct PileArranging: ViewModifier {
    let pile: ArrangeablePile?
    /// Whether the preview shows the image `pile` drew, so its books can move.
    let isEnabled: Bool
    /// Whether the iPhone's full-size view covers the preview; a drag then moves nothing.
    var holdsPreview = false
    /// Set while the Mac's pointer rests on a book, where a drag moves the book instead of
    /// dragging the image out.
    @Binding var hoversBook: Bool
    let arranged: ([Int: Transform]) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set by **Sounds** in the Desk's options menu.
    @AppStorage(ImpactSound.storageKey) private var sounds = true
    @State private var size = CGSize.zero
    /// Whether the scene draws live over the image.
    @State private var isLive = false
    /// The live view as it last drew, shown from when the books settle until the new image.
    @State private var still: UIImage?
    @State private var liveView = LiveView()
    @State private var touch: Touch?
    /// Where the finger or pointer last was, which a book picked up after a wait moves to.
    @State private var latest = CGPoint.zero
    /// Waits for the books to settle, then reports their poses.
    @State private var settling: Task<Void, Never>?
    /// Counts books picked up, each of which plays a light haptic tap.
    @State private var pickups = 0
    /// Set while a drag lasts. SwiftUI resets it when the drag ends or is cancelled, so a held
    /// book is let go either way.
    @GestureState private var touches = false

    /// The `ARView` that `DeskSceneView` made, for its still. A reference nothing observes.
    @MainActor private final class LiveView {
        weak var view: ARView?
    }

    private enum Touch {
        /// Waiting for the live view, then picking up the book where the drag started.
        case lifting(Task<Void, Never>)
        /// Carrying a book it picked up.
        case holding
        /// Started off the books, or where no book could be picked up: it moves nothing.
        case idle
    }

    func body(content: Content) -> some View {
        content
            .overlay { if let pile { live(pile) } }
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                size = $0
            }
            .simultaneousGesture(carryBook, including: canCarry ? .all : .subviews)
            .sensoryFeedback(.impact(weight: .light), trigger: pickups)
            .onChange(of: touches) { if !touches, touch != nil, let pile { endTouch(pile) } }
            // A render the reader didn't start, such as for a new design, takes the engine.
            .onChange(of: PileSnapshotRenderer.isRendering) { _, isRendering in
                guard isRendering, isLive, let pile else { return }
                settling?.cancel()
                if case .lifting(let lift) = touch { lift.cancel() }
                touch = nil
                pile.scene.endDrag()
                finish(pile)
            }
            .onChange(of: isEnabled) { if isEnabled { still = nil } }
            .onChange(of: pile.map { ObjectIdentifier($0.scene) }) { still = nil }
            #if os(macOS)
                .onContinuousHover { phase in
                    var over = false
                    if case .active(let point) = phase, let pile, isEnabled {
                        over = pile.scene.bookID(under: point, in: size) != nil
                    }
                    if over != hoversBook { hoversBook = over }
                }
                .pointerStyle(isHolding ? .grabActive : hoversBook ? .grabIdle : nil)
            #endif
    }

    /// Whether a drag can move books: on the Mac, only one that starts on a book, so a drag from
    /// elsewhere drags the image out.
    private var canCarry: Bool {
        guard pile != nil, isEnabled, !holdsPreview else { return false }
        #if os(macOS)
            return hoversBook || touch != nil
        #else
            return true
        #endif
    }

    private var isHolding: Bool {
        if case .holding = touch { true } else { false }
    }

    /// The live scene or its still, under the heading, which takes no input.
    private func live(_ pile: ArrangeablePile) -> some View {
        ZStack {
            if isLive {
                DeskSceneView { [liveView] view in
                    liveView.view = view
                    pile.scene.attach(to: view)
                }
            } else if let still {
                Image(uiImage: still).resizable()
            }
            if isLive || still != nil {
                let width = pile.heading.layout.aspect.size.width
                pile.heading
                    .scaleEffect(width > 0 ? size.width / width : 1, anchor: .topLeading)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
    }

    private var carryBook: some Gesture {
        DragGesture(minimumDistance: PileCarry.slop)
            .updating($touches) { _, touches, _ in touches = true }
            .onChanged { value in
                guard let pile else { return }
                latest = value.location
                switch touch {
                case nil:
                    settling?.cancel()
                    touch =
                        pile.scene.bookID(under: value.startLocation, in: size) == nil
                        ? .idle : .lifting(lift(pile, at: value.startLocation))
                case .holding: pile.scene.carry(to: value.location, in: size)
                default: break
                }
            }
            .onEnded { value in
                guard let pile else { return }
                if isHolding {
                    pile.scene.throwBook(velocity: value.velocity, at: value.location, in: size)
                }
                endTouch(pile)
            }
    }

    /// Shows the live scene and, once it is in the live view, picks up the book under `point`
    /// and carries it to where the drag is.
    private func lift(_ pile: ArrangeablePile, at point: CGPoint) -> Task<Void, Never> {
        if !isLive {
            isLive = true
            pile.scene.feedback.playsSounds = sounds
            pile.scene.feedback.start()
        }
        return Task {
            // The scene's rays need it in the view, which attaches it as the view enters the
            // window.
            for _ in 0..<60 where pile.scene.root.scene == nil {
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            if pile.scene.pickUp(at: point, in: size, gentle: reduceMotion) {
                touch = .holding
                pickups += 1
                pile.scene.carry(to: latest, in: size)
            } else {
                touch = .idle
            }
        }
    }

    /// Ends a drag, dropping a book still held where it is, and waits for the books to settle.
    private func endTouch(_ pile: ArrangeablePile) {
        if case .lifting(let lift) = touch { lift.cancel() }
        touch = nil
        pile.scene.endDrag()
        guard isLive else { return }
        settling?.cancel()
        settling = Task {
            // Settled at two checks in a row, or after 8 seconds, for a book that keeps
            // rocking.
            var checks = 0
            for _ in 0..<40 where checks < 2 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                checks = pile.scene.isSettled ? checks + 1 : 0
            }
            let image = await snapshot()
            guard !Task.isCancelled else { return }
            still = image
            finish(pile)
        }
    }

    /// A still of the live view as it draws now, or `nil` without one.
    private func snapshot() async -> UIImage? {
        guard let view = liveView.view else { return nil }
        return await withCheckedContinuation { done in
            view.snapshot(saveToHDR: false) { done.resume(returning: $0) }
        }
    }

    /// Takes the scene out of the live view and reports where its books lie.
    private func finish(_ pile: ArrangeablePile) {
        pile.scene.feedback.stop()
        isLive = false
        arranged(pile.scene.poses)
    }
}
