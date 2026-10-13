import SwiftUI
import UIKit

/// A short confirmation, such as "Saved to Photos", in a pill near the top of the screen.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let systemImage: String
    /// Whether the toast reports a failure, which tints its symbol orange instead of green.
    var isError = false

    static func failure(_ message: String) -> Toast {
        Toast(message: message, systemImage: "exclamationmark.triangle.fill", isError: true)
    }
}

/// Shows one toast at a time, over every tab, sheet, and the share sheet.
///
/// A toast stays for `duration`, then leaves; a new toast replaces the one showing and starts
/// the time again. Each toast's message is announced to VoiceOver as it appears. `RootView`
/// hosts the toasts once (`ToastWindow`).
@MainActor
@Observable
final class ToastCenter {
    static let duration = Duration.seconds(2)

    private(set) var toast: Toast?
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    func show(_ toast: Toast) {
        self.toast = toast
        // High priority, so the announcement survives the screen change of a closing sheet.
        var announcement = AttributedString(toast.message)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.duration)) != nil else { return }
            self?.toast = nil
        }
    }
}

/// Shows `ToastCenter`'s toasts in a window above the app's own.
///
/// A sheet or the share sheet covers the whole tab view, so an overlay on the tab view would
/// hide a toast behind it. A window above the app's window shows over both. The window spans
/// the screen's width just below the status bar, so it never takes over the status bar's
/// style, and it ignores touches, which reach the app below.
struct ToastWindow: UIViewRepresentable {
    let toasts: ToastCenter

    func makeUIView(context: Context) -> Anchor { Anchor(toasts: toasts) }

    func updateUIView(_ view: Anchor, context: Context) {}

    /// Creates the toast window once it joins a window scene, and keeps it for its lifetime.
    final class Anchor: UIView {
        private let toasts: ToastCenter
        private var overlay: UIWindow?

        init(toasts: ToastCenter) {
            self.toasts = toasts
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { return nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard overlay == nil, let scene = window?.windowScene else { return }
            let overlay = UIWindow(windowScene: scene)
            overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            overlay.isUserInteractionEnabled = false
            let host = UIHostingController(rootView: ToastOverlay(toasts: toasts))
            host.view.backgroundColor = .clear
            overlay.rootViewController = host
            overlay.isHidden = false
            self.overlay = overlay
            placeOverlay()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            placeOverlay()
        }

        /// Places the window under the status bar, tall enough for a toast of two large lines.
        private func placeOverlay() {
            guard let window, let overlay else { return }
            overlay.frame = CGRect(
                x: 0, y: window.safeAreaInsets.top, width: window.bounds.width, height: 160)
        }
    }
}

/// The current toast, centered at the top of the toast window. It slides down from under the
/// status bar, or fades with Reduce Motion.
private struct ToastOverlay: View {
    let toasts: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if let toast = toasts.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.systemImage)
                        .foregroundStyle(toast.isError ? .orange : .green)
                    Text(toast.message)
                        .lineLimit(2)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: .capsule)
                .accessibilityElement(children: .combine)
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .transition(
                    reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
                )
                .id(toast.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The window already starts below the status bar, but it still reports the screen's
        // top inset, which would push the toast down by that much again.
        .ignoresSafeArea()
        .animation(
            reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.2),
            value: toasts.toast)
    }
}
