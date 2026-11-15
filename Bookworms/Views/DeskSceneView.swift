import RealityKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Shows a desk scene in an `ARView` whose life follows the window, so a hidden Desk tab runs
/// no frame loop and the scene is as the reader left it on return.
///
/// SwiftUI keeps a hidden tab's views and defers their platform changes until the tab shows
/// again, and UIKit takes the tab's view out of the window before SwiftUI renders the switch,
/// so a `RealityView` removed from a hidden tab keeps RealityKit's frame loop running out of
/// sight, and one torn down late, on return, leaves the next view drawing nothing. UIKit tells
/// a view at once when it leaves or enters a window, so `SceneWindowView` adds its `ARView`
/// when it enters one and removes it when it leaves, keeping it for the next time. `attach`
/// puts the scene's entities in the view each time it enters a window.
///
/// The view draws with a transparent background, so the wall shows around the table, and
/// takes no gestures of its own: the SwiftUI gestures on it find books with the scene's rays.
struct DeskSceneView {
    /// Puts the scene that shows in `view`'s scene and starts its updates (see
    /// `DeskScenes.attach(to:)`).
    let attach: @MainActor (ARView) -> Void
}

#if os(macOS)
    extension DeskSceneView: NSViewRepresentable {
        func makeNSView(context: Context) -> SceneWindowView { SceneWindowView(attach: attach) }

        func updateNSView(_ view: SceneWindowView, context: Context) { view.attach = attach }

        static func dismantleNSView(_ view: SceneWindowView, coordinator: ()) { view.dropView() }
    }
#else
    extension DeskSceneView: UIViewRepresentable {
        func makeUIView(context: Context) -> SceneWindowView { SceneWindowView(attach: attach) }

        func updateUIView(_ view: SceneWindowView, context: Context) { view.attach = attach }

        static func dismantleUIView(_ view: SceneWindowView, coordinator: ()) { view.dropView() }
    }
#endif

#if os(macOS)
    typealias PlatformView = NSView
#else
    typealias PlatformView = UIView
#endif

/// The container that holds an `ARView` only while it is in a window.
@MainActor
final class SceneWindowView: PlatformView {
    var attach: @MainActor (ARView) -> Void
    private var arView: ARView?

    init(attach: @escaping @MainActor (ARView) -> Void) {
        self.attach = attach
        super.init(frame: .zero)
        #if os(iOS)
            backgroundColor = .clear
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    #if os(macOS)
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged()
        }
    #else
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged()
        }
    #endif

    private func windowChanged() {
        if window == nil {
            dropView()
        } else if arView == nil {
            makeView()
        }
    }

    /// A view made ahead of the Desk tab, or the last to leave a window, which the next
    /// container to enter a window takes. It is shared, since SwiftUI may make a new container
    /// rather than reuse the one it dropped. Out of a window, it draws nothing.
    private static var spare: ARView?

    /// Makes an `ARView` ahead of the Desk tab, so the tab opens without making one, as
    /// `DeskScenes.prewarm()` does. Does nothing while a spare waits.
    static func prewarm() {
        if spare == nil { spare = newView() }
    }

    /// Lets the spare go, with its drawables, as the desk frees memory under pressure. The next
    /// container to enter a window makes a view.
    static func releaseSpare() {
        spare = nil
    }

    private static func newView() -> ARView {
        #if os(macOS)
            let view = ARView(frame: .zero)
            view.environment.background = .color(.clear)
            view.autoresizingMask = [.width, .height]
        #else
            let view = ARView(
                frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
            view.environment.background = .color(.clear)
            view.backgroundColor = .clear
            view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain]
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        return view
    }

    private func makeView() {
        let view = Self.spare ?? Self.newView()
        Self.spare = nil
        view.frame = bounds
        addSubview(view)
        arView = view
        attach(view)
    }

    /// Removes the `ARView`, which ends its frame loop, empties its scene, and keeps it as the
    /// spare, since making a view holds the main actor for several frames. The desk's entities
    /// wait under their orphaned anchor for the next `attach`, so a desk that takes the spare,
    /// such as a reopened window's, never draws another's.
    func dropView() {
        guard let view = arView else { return }
        view.removeFromSuperview()
        view.scene.anchors.removeAll()
        arView = nil
        Self.spare = view
    }
}

#if os(macOS)
    /// Reports the scroll wheel over its frame, for a view whose SwiftUI layer takes the
    /// pointer's clicks.
    ///
    /// SwiftUI has no scroll wheel modifier, and the gesture layer over the desk's view keeps
    /// AppKit from sending the wheel to any view under it, so this view reads the wheel with a
    /// local event monitor while it is in a window. The monitor sees the app's every scroll, so
    /// it passes on those in other windows, such as sheets, outside its frame, or that
    /// `onScroll` declines. The view itself takes no events.
    struct ScrollWheelReader: NSViewRepresentable {
        /// Called with each scroll over the view and where it is, in the view's points with y
        /// growing downward, as SwiftUI measures; returns whether it used the scroll.
        let onScroll: @MainActor (NSEvent, CGPoint) -> Bool

        func makeNSView(context: Context) -> ReaderView { ReaderView(onScroll: onScroll) }

        func updateNSView(_ view: ReaderView, context: Context) { view.onScroll = onScroll }

        static func dismantleNSView(_ view: ReaderView, coordinator: ()) { view.stopMonitoring() }

        @MainActor
        final class ReaderView: NSView {
            var onScroll: @MainActor (NSEvent, CGPoint) -> Bool
            private var monitor: Any?

            init(onScroll: @escaping @MainActor (NSEvent, CGPoint) -> Bool) {
                self.onScroll = onScroll
                super.init(frame: .zero)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { nil }

            override var isFlipped: Bool { true }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                stopMonitoring()
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                    [weak self] event in
                    let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
                    return used ? nil : event
                }
            }

            func stopMonitoring() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }

            private func handle(_ event: NSEvent) -> Bool {
                guard let window, event.window === window else { return false }
                let point = convert(event.locationInWindow, from: nil)
                return bounds.contains(point) && onScroll(event, point)
            }
        }
    }
#endif
