import SwiftUI

/// Presents Forward with the same window-level modal host as the media viewer.
/// The workspace remains geometrically stable while the full-window host owns
/// pointer, accessibility, keyboard, and closing-animation behavior.
struct ForwardMessageWindowOverlay: View {
    let model: AppModel

    var body: some View {
        WindowModalOverlay(
            presentation: model.forwardingMessage,
            zPosition: 100_100,
            dismiss: model.dismissForwarding
        ) { message, animationState in
            ForwardMessageOverlay(
                model: model,
                message: message,
                animationState: animationState,
                dismiss: {
                    animationState.dismiss(committingPresentation: true)
                }
            )
        }
        // The index is built when the picker opens, not before. This overlay
        // is mounted for the whole session, and forwardSearchSourceRevision
        // advances on ordinary gateway traffic, so warming here rebuilt an
        // index over every channel, user and guild each time a message
        // arrived -- continuous CPU spent on a feature nobody had invoked.
        // The picker's own revisioned task still populates it on open.
    }
}
