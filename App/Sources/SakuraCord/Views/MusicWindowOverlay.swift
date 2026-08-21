import SwiftUI

/// Attaches the music surface above the workspace.
///
/// The host is retained when dismissed: the page is the running player, so
/// closing the panel has to hide it rather than tear it down, and reopening
/// it should not rebuild a web view that was playing a moment ago.
struct MusicWindowOverlay: View {
    let model: AppModel

    private static let behavior = WindowModalBehavior(
        animates: true,
        capturesEscape: true,
        retainsHostWhenDismissed: true
    )

    var body: some View {
        WindowModalOverlay(
            presentation: model.music.presentation,
            behavior: { _ in Self.behavior },
            dismiss: { model.music.presentation = nil },
            content: { _, animationState in
                MusicOverlayView(model: model, animationState: animationState)
            }
        )
    }
}
