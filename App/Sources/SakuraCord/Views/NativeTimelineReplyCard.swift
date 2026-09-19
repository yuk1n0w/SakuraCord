import AppKit
import SakuraCordModels

/// A reply in a direct-message conversation is a compact quote card attached
/// to its bubble: the replied-to author over one line of their message,
/// behind an accent bar. It shares the bubble's edge, so it reads as part of
/// that message rather than as another speaker, and it is sized to its text
/// so a reply to your own message never runs off the trailing edge.
enum NativeTimelineReplyCardMetrics {
    static let barWidth: CGFloat = 3
    static let horizontalPadding: CGFloat = 9
    static let verticalPadding: CGFloat = 5
    static let lineSpacing: CGFloat = 1
    static let cornerRadius: CGFloat = 10
    static let minimumWidth: CGFloat = 72

    static var authorFont: NSFont {
        .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .semibold
        )
    }

    static var summaryFont: NSFont {
        .preferredFont(forTextStyle: .caption1)
    }

    static var authorLineHeight: CGFloat {
        lineHeight(authorFont)
    }

    static var summaryLineHeight: CGFloat {
        lineHeight(summaryFont)
    }

    static var height: CGFloat {
        verticalPadding * 2 + authorLineHeight + lineSpacing + summaryLineHeight
    }

    /// Fits the card to the wider of its two lines, within the bubble's cap.
    static func width(for content: NativeTimelineReplyCardContent, maximum: CGFloat) -> CGFloat {
        let textWidth = max(
            NativeTimelineReplyMetrics.textWidth(content.author, font: authorFont),
            NativeTimelineReplyMetrics.textWidth(content.summary, font: content.summaryFont)
        )
        let chrome = barWidth + horizontalPadding * 2
        return min(max(minimumWidth, maximum), max(minimumWidth, ceil(textWidth) + chrome))
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}

/// What a reply card shows. Layout measures and the painter draws this same
/// value, so the card is always as wide as its text.
struct NativeTimelineReplyCardContent {
    var author: String
    var authorColor: NSColor
    var summary: String
    var summaryFont: NSFont

    @MainActor
    static func make(preview: MessageReplyPreview?, model: AppModel?) -> Self {
        guard let preview else {
            let baseFont = NativeTimelineReplyCardMetrics.summaryFont
            return Self(
                author: "Original message",
                authorColor: .secondaryLabelColor,
                summary: "Message could not be loaded",
                summaryFont: NSFont(
                    descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                    size: baseFont.pointSize
                ) ?? baseFont
            )
        }
        let author = model?.authorPresentation(for: preview).user ?? preview.author
        let summary = if let model {
            MessageReplySummary.text(
                content: preview.content,
                mentionLabel: MessageMentionResolver(model: model).label
            )
        } else {
            MessageReplySummary.text(content: preview.content)
        }
        return Self(
            author: author.displayName,
            authorColor: author.isBot ? .sakuraCordAccentColor : .labelColor,
            summary: summary,
            summaryFont: NativeTimelineReplyCardMetrics.summaryFont
        )
    }
}

extension NativeTimelineRowPainter {
    static func replyCard(
        preview: MessageReplyPreview?,
        frame: CGRect,
        model: AppModel?
    ) {
        typealias Metrics = NativeTimelineReplyCardMetrics
        let card = NSBezierPath(
            roundedRect: frame,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        card.fill()

        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        NSColor.sakuraCordAccentColor.setFill()
        NSBezierPath(rect: CGRect(
            x: frame.minX,
            y: frame.minY,
            width: Metrics.barWidth,
            height: frame.height
        )).fill()
        NSGraphicsContext.restoreGraphicsState()

        let content = NativeTimelineReplyCardContent.make(preview: preview, model: model)
        let textX = frame.minX + Metrics.barWidth + Metrics.horizontalPadding
        let textWidth = max(0, frame.maxX - Metrics.horizontalPadding - textX)
        let authorY = frame.minY + Metrics.verticalPadding
        text(
            content.author,
            in: CGRect(x: textX, y: authorY, width: textWidth, height: Metrics.authorLineHeight),
            font: Metrics.authorFont,
            color: content.authorColor
        )
        text(
            content.summary,
            in: CGRect(
                x: textX,
                y: authorY + Metrics.authorLineHeight + Metrics.lineSpacing,
                width: textWidth,
                height: Metrics.summaryLineHeight
            ),
            font: content.summaryFont,
            color: .secondaryLabelColor
        )
    }
}
