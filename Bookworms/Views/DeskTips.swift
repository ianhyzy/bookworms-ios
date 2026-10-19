import SwiftUI
import TipKit

/// The Desk's gesture hints, which nothing else on screen teaches: picking up and throwing a
/// book, moving the camera, and pushing the dominoes. Each shows once, in a popover that points
/// at what it names, when that gesture can next be tried, and goes for good once the reader
/// uses the gesture or closes the hint. The Desk scene's hints show only while the desk rests,
/// over its still (`DeskScenes`), so they never cover a moving scene, and the push hint only
/// while the chain waits for its first push.
///
/// Rules decide when a hint shows: transient parameters that the views set as the desk rests
/// or wakes and as the chain stands or starts, and an event donated when a book is thrown.
/// TipKit evaluates the rules only when one of those changes, never per frame. `BookwormsApp`
/// configures TipKit at launch.
@MainActor
enum DeskTips {
    /// What this launch has already told TipKit, so a scroll or drag that runs many times
    /// tells it once.
    private static var hasPickedUp = false
    private static var throwCount = 0
    private static var hasMovedCamera = false

    /// A book was picked up, so the pick-up hint is done.
    static func pickedUp() {
        guard !hasPickedUp else { return }
        hasPickedUp = true
        PickUpTip().invalidate(reason: .actionPerformed)
    }

    /// A held book was let go, which counts toward the camera hint, twice a launch at most.
    static func thrown() {
        guard throwCount < 2, !hasMovedCamera else { return }
        throwCount += 1
        TurnTip.thrown.sendDonation()
    }

    /// The camera moved, so the camera hint is done.
    static func cameraMoved() {
        guard !hasMovedCamera else { return }
        hasMovedCamera = true
        TurnTip().invalidate(reason: .actionPerformed)
    }

    /// The first push started the dominoes, so the push hint is done.
    static func pushed() {
        PushTip().invalidate(reason: .actionPerformed)
    }

    /// The words for a press on the desk: a click on the Mac and a tap on the iPhone.
    nonisolated static var tap: String {
        #if os(macOS)
            "Click"
        #else
            "Tap"
        #endif
    }
}

/// How to pick up and throw a book, at the first rest after a drop.
struct PickUpTip: Tip {
    /// Whether the Desk scene rests, its still in place of its view.
    @Parameter(.transient) static var deskRests: Bool = false

    var title: Text { Text("Pick up a book") }

    var message: Text? {
        #if os(macOS)
            Text("Drag a book to carry it, and let go while it moves to throw it.")
        #else
            Text("Touch and hold a book to pick it up, then flick to throw it.")
        #endif
    }

    var image: Image? { Image(systemName: "hand.draw") }

    var rules: [Rule] {
        #Rule(Self.$deskRests) { $0 }
    }
}

/// How to zoom and turn the view, at a rest after the reader has thrown two books.
struct TurnTip: Tip {
    static let thrown = Event(id: "deskBookThrown")

    var title: Text { Text("Look around the desk") }

    var message: Text? {
        #if os(macOS)
            Text("Scroll to zoom, and hold Shift as you scroll to turn the desk.")
        #else
            Text("Pinch to zoom, and turn two fingers to look around the pile.")
        #endif
    }

    var image: Image? { Image(systemName: "rotate.3d") }

    var rules: [Rule] {
        #Rule(PickUpTip.$deskRests) { $0 }
        #Rule(Self.thrown) { $0.donations.count >= 2 }
    }
}

/// How to start the dominoes, by the pointing hand once the chain stands.
struct PushTip: Tip {
    /// Whether the chain stands waiting for its first push, with the camera at rest.
    @Parameter(.transient) static var chainWaits: Bool = false

    var title: Text { Text("Push the first book") }

    var message: Text? {
        Text("\(DeskTips.tap) the hand to topple the chain.")
    }

    var image: Image? { Image(systemName: "hand.point.right") }

    var rules: [Rule] {
        #Rule(Self.$chainWaits) { $0 }
    }
}

/// A point that a tip's popover points at, where TipKit shows the tip once its rules allow.
///
/// The anchor stays in the hierarchy, at its last point, whether or not the tip shows: the
/// popover modifier that presented a tip must stay to take it down when its rules no longer
/// hold, and a popover leaving from its last point does not jump across the screen.
struct TipAnchor: View {
    let tip: (any Tip)?
    let point: CGPoint?
    var arrowEdge = Edge.bottom

    @State private var last = CGPoint.zero

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .popoverTip(tip, arrowEdge: arrowEdge)
            .position(point ?? last)
            .accessibilityHidden(true)
            .onChange(of: point) { if let point { last = point } }
    }
}
