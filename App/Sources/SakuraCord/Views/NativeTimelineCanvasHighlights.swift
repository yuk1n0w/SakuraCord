import AppKit

extension NativeTimelineCanvasView {
    func drawMessageJumpHighlight(at index: Int) {
        guard let presentation = messageJumpHighlightPresentation(at: index)
        else { return }
        NSColor.sakuraCordAccentColor.withAlphaComponent(
            0.12 * presentation.opacity
        ).setFill()
        let layout = layouts[index]
        if layout.messageBubbleFrame != nil,
           layout.highlightBackgroundCornerRadius > 0
        {
            NSBezierPath(
                concentricRoundedRect: presentation.frame,
                cornerRadius: layout.highlightBackgroundCornerRadius
            ).fill()
        } else if let bubble = layout.bubbleRegion {
            let rowFrame = rowFrame(at: index)
            NativeTimelineBubbleDrawing.path(for: NativeTimelineBubbleRegion(
                frame: bubble.frame.offsetBy(
                    dx: rowFrame.minX,
                    dy: rowFrame.minY
                ),
                isOutgoing: bubble.isOutgoing,
                showsTail: bubble.showsTail
            )).fill()
        } else {
            presentation.frame.fill()
        }
    }
}
