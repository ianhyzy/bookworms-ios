import QuartzCore
import SwiftUI

/// Whether a 3D scene is getting a new set of books ready, before the first of them enter: it
/// builds their meshes and textures, loads their fonts, and waits for their covers. It is kept
/// apart from the scene so that views update only when it changes.
@MainActor @Observable
final class SceneLoading {
    /// How long the spinner waits to fade in once loading starts, in seconds.
    static let showDelay: TimeInterval = 0.25

    var isLoading = false
}

extension View {
    /// Shows a book tumbling wildly over the middle of the view while `isLoading` (see
    /// `SpinningBook`), over the words "Setting up".
    ///
    /// The book fades in after a quarter second, so a new drop that reuses its books, such as
    /// **Drop again**, shows none, and it fades out as the first books enter.
    func settingUp(_ isLoading: Bool) -> some View {
        overlay {
            if isLoading {
                VStack(spacing: 4) {
                    SpinningBook().accessibilityHidden(true)
                    Text("Setting up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 3)
                }
                .accessibilityElement(children: .combine)
                .allowsHitTesting(false)
                .transition(
                    AnyTransition.asymmetric(
                        insertion: .opacity.animation(
                            .easeIn(duration: 0.2).delay(SceneLoading.showDelay)),
                        removal: .opacity.animation(.easeOut(duration: 0.25))))
            }
        }
    }
}

/// A small cloth-bound book that spins and tumbles in place, as a loading indicator.
///
/// Core Animation runs the spin outside the app's main thread, so the book keeps turning
/// while a scene builds its books there. With Reduce Motion on, it holds still and pulses.
struct SpinningBook: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SpinningBookLayer(reduceMotion: reduceMotion).frame(width: 96, height: 96)
    }
}

#if os(macOS)
    private struct SpinningBookLayer: NSViewRepresentable {
        let reduceMotion: Bool

        func makeNSView(context: Context) -> SpinningBookView {
            SpinningBookView(reduceMotion: reduceMotion)
        }

        func updateNSView(_ view: SpinningBookView, context: Context) {
            view.reduceMotion = reduceMotion
        }
    }
#else
    private struct SpinningBookLayer: UIViewRepresentable {
        let reduceMotion: Bool

        func makeUIView(context: Context) -> SpinningBookView {
            SpinningBookView(reduceMotion: reduceMotion)
        }

        func updateUIView(_ view: SpinningBookView, context: Context) {
            view.reduceMotion = reduceMotion
        }
    }
#endif

/// The layers of `SpinningBook`: a book of six faces in perspective, spinning about its height
/// while it rocks end over end and bounces.
@MainActor
final class SpinningBookView: PlatformView {
    /// Whether the book holds still and pulses rather than spinning. A change restarts its
    /// motion.
    var reduceMotion: Bool {
        didSet {
            guard reduceMotion != oldValue else { return }
            for layer in [stage, bounce, rock, spin] { layer.removeAllAnimations() }
            animate()
        }
    }
    private let stage = CALayer()
    private let bounce = CATransformLayer()
    private let rock = CATransformLayer()
    private let spin = CATransformLayer()

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        #if os(macOS)
            wantsLayer = true
        #endif
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 260
        stage.sublayerTransform = perspective
        stage.addSublayer(bounce)
        bounce.addSublayer(rock)
        rock.addSublayer(spin)
        for face in Self.faces() { spin.addSublayer(face) }
        #if os(macOS)
            layer?.addSublayer(stage)
        #else
            layer.addSublayer(stage)
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    #if os(macOS)
        override func layout() {
            super.layout()
            place()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            animate()
        }
    #else
        override func layoutSubviews() {
            super.layoutSubviews()
            place()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            animate()
        }
    #endif

    private func place() {
        stage.frame = bounds
        for layer in [bounce, rock, spin] {
            layer.bounds = CGRect(origin: .zero, size: bounds.size)
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        for face in spin.sublayers ?? [] {
            face.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    /// Starts the book's motion, which a view leaving its window drops.
    private func animate() {
        guard window != nil else { return }
        guard !reduceMotion else {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.5
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            stage.add(pulse, forKey: "pulse")
            return
        }
        let turn = CABasicAnimation(keyPath: "transform.rotation.y")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = 0.55
        turn.repeatCount = .infinity
        spin.add(turn, forKey: "spin")
        let tip = CAKeyframeAnimation(keyPath: "transform.rotation.x")
        tip.values = [-0.5, 0.45, -0.2, 0.6, -0.5]
        tip.keyTimes = [0, 0.3, 0.5, 0.75, 1]
        tip.duration = 1.3
        tip.repeatCount = .infinity
        tip.calculationMode = .cubic
        rock.add(tip, forKey: "rock")
        let hop = CAKeyframeAnimation(keyPath: "transform")
        hop.values = [
            CATransform3DIdentity, CATransform3DMakeTranslation(0, -10, 0),
            CATransform3DMakeScale(1.12, 0.92, 1), CATransform3DIdentity,
        ]
        .map { NSValue(caTransform3D: $0) }
        hop.keyTimes = [0, 0.4, 0.75, 1]
        hop.duration = 0.42
        hop.repeatCount = .infinity
        bounce.add(hop, forKey: "bounce")
    }

    /// The book's faces about its middle, in points: red cloth boards with gilt bands and cream
    /// page edges.
    private static func faces() -> [CALayer] {
        let (width, height, thickness): (CGFloat, CGFloat, CGFloat) = (40, 58, 13)
        let cloth = CGColor(red: 0.56, green: 0.13, blue: 0.11, alpha: 1)
        let spineCloth = CGColor(red: 0.45, green: 0.1, blue: 0.09, alpha: 1)
        let paper = CGColor(red: 0.95, green: 0.9, blue: 0.78, alpha: 1)
        let gilt = CGColor(red: 0.86, green: 0.68, blue: 0.32, alpha: 1)
        func face(
            _ size: CGSize, _ color: CGColor, bands: Bool, _ transform: CATransform3D
        ) -> CALayer {
            let layer = CALayer()
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.backgroundColor = color
            layer.isDoubleSided = false
            layer.allowsEdgeAntialiasing = true
            layer.transform = transform
            if bands {
                for y in [size.height * 0.16, size.height * 0.8] {
                    let band = CALayer()
                    band.frame = CGRect(x: 0, y: y, width: size.width, height: 3)
                    band.backgroundColor = gilt
                    layer.addSublayer(band)
                }
            }
            return layer
        }
        let half = (width / 2, height / 2, thickness / 2)
        return [
            face(
                CGSize(width: width, height: height), cloth, bands: true,
                CATransform3DMakeTranslation(0, 0, half.2)),
            face(
                CGSize(width: width, height: height), cloth, bands: false,
                CATransform3DRotate(CATransform3DMakeTranslation(0, 0, -half.2), .pi, 0, 1, 0)),
            face(
                CGSize(width: thickness, height: height), spineCloth, bands: true,
                CATransform3DRotate(CATransform3DMakeTranslation(-half.0, 0, 0), -.pi / 2, 0, 1, 0)),
            face(
                CGSize(width: thickness, height: height), paper, bands: false,
                CATransform3DRotate(CATransform3DMakeTranslation(half.0, 0, 0), .pi / 2, 0, 1, 0)),
            face(
                CGSize(width: width, height: thickness), paper, bands: false,
                CATransform3DRotate(CATransform3DMakeTranslation(0, -half.1, 0), .pi / 2, 1, 0, 0)),
            face(
                CGSize(width: width, height: thickness), paper, bands: false,
                CATransform3DRotate(CATransform3DMakeTranslation(0, half.1, 0), -.pi / 2, 1, 0, 0)),
        ]
    }
}
