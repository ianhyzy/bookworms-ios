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
/// a view at once when it leaves or enters a window, so `SceneWindowView` makes its `ARView`
/// when it enters one and drops it when it leaves. The scene's entities outlive the view:
/// `attach` puts them in each new `ARView`.
///
/// The view draws with a transparent background, so the wall shows around the table, and
/// takes no gestures of its own: the SwiftUI gestures on it find books with the scene's rays.
struct DeskSceneView {
    /// Whether the desk saves power under heat or in Low Power Mode, when an iPhone's view
    /// draws no grounding shadows (see `DeskScenes.reducesEffects`).
    // ponytail: a Mac's `ARView` has no render options, so the Mac keeps its grounding shadows;
    // remove the books' `GroundingShadowComponent` there if that ever matters.
    var reducesEffects = false
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
        func makeUIView(context: Context) -> SceneWindowView {
            let view = SceneWindowView(attach: attach)
            view.reducesEffects = reducesEffects
            return view
        }

        func updateUIView(_ view: SceneWindowView, context: Context) {
            view.attach = attach
            view.reducesEffects = reducesEffects
        }

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
    #if os(iOS)
        /// Leaves out the soft shadows under the books while set, as each new `ARView` does.
        var reducesEffects = false {
            didSet { if reducesEffects != oldValue { setRenderOptions() } }
        }
    #endif

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

    private func makeView() {
        #if os(macOS)
            let view = ARView(frame: bounds)
            view.environment.background = .color(.clear)
            view.autoresizingMask = [.width, .height]
        #else
            let view = ARView(
                frame: bounds, cameraMode: .nonAR, automaticallyConfigureSession: false)
            view.environment.background = .color(.clear)
            view.backgroundColor = .clear
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        addSubview(view)
        arView = view
        #if os(iOS)
            setRenderOptions()
        #endif
        attach(view)
    }

    #if os(iOS)
        /// Turns off the camera effects a nonAR view has no use for, and the grounding shadows
        /// while the desk saves power.
        private func setRenderOptions() {
            var options: ARView.RenderOptions = [
                .disableMotionBlur, .disableDepthOfField, .disableCameraGrain,
            ]
            if reducesEffects { options.insert(.disableGroundingShadows) }
            arView?.renderOptions = options
        }
    #endif

    /// Removes the `ARView`, which ends its frame loop. Its scene goes with it and leaves the
    /// scene's entities for the next view.
    func dropView() {
        arView?.removeFromSuperview()
        arView = nil
    }
}
