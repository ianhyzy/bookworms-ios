import SwiftUI

/// Whether a 3D scene is getting a new set of books ready, before the first of them enter: it
/// builds their meshes and textures, loads their fonts, and waits for their covers. It is kept
/// apart from the scene so that views update only when it changes.
@MainActor @Observable
final class SceneLoading {
    var isLoading = false
}

extension View {
    /// Shows a spinner labeled "Setting up" over the middle of the view while `isLoading`.
    ///
    /// The spinner fades in after a quarter second, so a new drop that reuses its books, such as
    /// **Drop again**, shows none, and it fades out as the first books enter. VoiceOver reads it
    /// as its own element.
    func settingUp(_ isLoading: Bool) -> some View {
        overlay {
            if isLoading {
                ProgressView("Setting up")
                    .controlSize(.large)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .allowsHitTesting(false)
                    .transition(
                        AnyTransition.asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.2).delay(0.25)),
                            removal: .opacity.animation(.easeOut(duration: 0.25))))
            }
        }
    }
}
