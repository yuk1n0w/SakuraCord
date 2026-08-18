import AppKit
import SakuraCordModels

// Direct-message bubble layout. Kept apart from the standard row builder so
// each file stays readable as the bubble presentation grows to cover more
// kinds of message.
extension NativeTimelineRowLayout {
    // The bubble renderer keeps eligibility, measurement, separators, and all
    // hit-test geometry together so its painter receives one coherent layout.
    // swiftlint:disable:next function_body_length
    static func directMessageText(
        _ row: MessageRowPresentation,
        isUnreadBoundary: Bool,
        width: CGFloat,
        model: AppModel?,
        namesIncomingAuthors: Bool = false
    ) -> Self? {
        let message = row.message
        // Discord gives replies their own type (19), so matching only
        // `.default` silently excludes every real reply.
        // A call, a name change or someone joining a group is not part of
        // the conversation, so it gets a quiet centred line rather than a
        // full row with an avatar and a gutter.
        let isSystemLine = message.type.hasGeneratedContent
        guard directMessageAllowsConversationRow(message) else { return nil }

        // A forward carries its text, images and links inside the snapshot
        // rather than on the message, so the bubble is built from that and
        // marked with a small header. The source channel, guild icon and
        // date link the standard row draws are left out: they are Discord
        // routing detail, not part of the conversation.
        let effectiveMessage = message.directMessageBubbleContentSource
        let textPlan = message.forwardedSnapshot == nil
            ? row.textPlan
            : NativeTimelineTextPlan.make(for: effectiveMessage)
        let contentPresentation = NativeTimelineTextPresentation.make(
            message: effectiveMessage,
            plan: textPlan,
            model: model
        )
        // A bubble needs something to show. Text and images are both valid on
        // their own, so an image sent without a caption still gets one.
        let attributedContent = contentPresentation.attributedContent
        let hasText = (attributedContent?.length ?? 0) > 0
        // An embed counts as content on its own. A GIF sent from the picker
        // is exactly that: its text is the source URL, which is blanked
        // because the embed replaces it, leaving a message whose only
        // content is the embed. Without this it fell back to the standard
        // row, which is left-aligned whoever sent it.
        let visibleEmbeds = MessageEmbedPresentation
            .visibleEmbeds(for: effectiveMessage)
        guard directMessageHasContent(
            hasText: hasText,
            attachments: effectiveMessage.attachments,
            // Counted from the message rather than the snapshot to match
            // the painter, which resolves stickers from message.stickers.
            stickers: message.stickers,
            linkedImages: contentPresentation.linkedImages,
            embeds: visibleEmbeds
        ) else { return nil }

        let horizontalInset: CGFloat = 24
        let horizontalContentInset: CGFloat = 13
        let verticalContentInset: CGFloat = 7
        // The conversation spans the whole pane so bubbles anchor to its
        // edges rather than sitting in a centred column with dead space on
        // both sides. Bubble width still scales with the space available and
        // stays capped, so a wide window does not produce unreadably long
        // lines of text.
        let conversationWidth = width
        let conversationMinX: CGFloat = 0
        let maximumBubbleWidth = min(
            ChatChromeMetrics.directMessageBubbleMaximumWidth,
            max(96, (conversationWidth - horizontalInset * 2) * 0.62)
        )
        let maximumContentWidth = max(
            44,
            maximumBubbleWidth - horizontalContentInset * 2
        )
        var bubbleWidth: CGFloat = 0
        var contentWidth: CGFloat = 0
        var textHeight: CGFloat = 0
        if let attributedContent, hasText, !isSystemLine {
            let naturalTextWidth = measuredMaximumLineWidth(
                contentPresentation.framesetter,
                length: attributedContent.length,
                width: maximumContentWidth
            )
            // Code takes the full width it is allowed: it does not reflow
            // like prose, so sizing it to its natural width wraps lines that
            // were written to be read intact.
            // Otherwise the floor is only a guard against a degenerate
            // sliver. Set too high it pads short words like "gm" out to a
            // width their text never asked for, which reads as stray space on
            // the trailing edge while longer messages look correct.
            bubbleWidth = effectiveMessage.content.contains("```")
                ? maximumBubbleWidth
                : min(
                    maximumBubbleWidth,
                    max(40, ceil(naturalTextWidth) + horizontalContentInset * 2)
                )
            contentWidth = max(1, bubbleWidth - horizontalContentInset * 2)
            textHeight = measuredTextHeight(
                contentPresentation.framesetter,
                value: attributedContent,
                length: attributedContent.length,
                width: contentWidth
            )
        }

        let separators = directMessageSeparators(
            row,
            isUnreadBoundary: isUnreadBoundary,
            minX: conversationMinX + horizontalInset,
            width: conversationWidth - horizontalInset * 2
        )
        var prefixHeight = separators.height
        let daySeparatorFrame = separators.dayFrame
        let unreadSeparatorFrame = separators.unreadFrame

        let isOutgoing = message.author.id == model?.snapshot?.currentUser.id
        let bubbleX = isOutgoing
            ? conversationMinX + conversationWidth - horizontalInset - bubbleWidth
            : conversationMinX + horizontalInset

        // In a group, an incoming bubble is captioned with its sender, once
        // per run rather than on every message. A one-to-one thread needs no
        // name, so this stays off there.
        var authorFrame: CGRect?
        let namesAuthor = directMessageNamesAuthor(
            namesIncomingAuthors: namesIncomingAuthors,
            isOutgoing: isOutgoing,
            startsGroup: row.startsGroup,
            isSystemLine: isSystemLine
        )
        if namesAuthor {
            let authorHeight: CGFloat = 16
            authorFrame = CGRect(
                x: bubbleX + horizontalContentInset,
                y: prefixHeight,
                width: max(
                    48,
                    conversationMinX + conversationWidth
                        - horizontalInset - bubbleX
                ),
                height: authorHeight
            )
            prefixHeight += authorHeight
        }

        // The quoted line sits directly above its bubble and shares the
        // bubble's leading edge, so a reply reads as belonging to the bubble
        // under it rather than as a separate row.
        var forwardedHeaderFrame: CGRect?
        if message.forwardedSnapshot != nil {
            let headerHeight: CGFloat = 18
            forwardedHeaderFrame = CGRect(
                x: bubbleX + horizontalContentInset,
                y: prefixHeight,
                width: max(
                    64,
                    conversationMinX + conversationWidth
                        - horizontalInset - bubbleX
                ),
                height: headerHeight
            )
            prefixHeight += headerHeight
        }

        var replyFrame: CGRect?
        if row.replyMessageID != nil {
            let replyHeight: CGFloat = 20
            replyFrame = CGRect(
                x: bubbleX,
                y: prefixHeight,
                width: max(
                    96,
                    conversationMinX + conversationWidth
                        - horizontalInset - bubbleX
                ),
                height: replyHeight
            )
            prefixHeight += replyHeight
        }

        let topSeparation: CGFloat = 4
        let contentTopY = prefixHeight + topSeparation

        var bubbleFrame: CGRect?
        var contentFrame: CGRect?
        if hasText, isSystemLine, let attributedContent {
            contentFrame = directMessageSystemLineFrame(
                framesetter: contentPresentation.framesetter,
                content: attributedContent,
                available: max(44, conversationWidth - horizontalInset * 2),
                centredOn: conversationMinX + conversationWidth / 2,
                topY: contentTopY
            )
        } else if hasText {
            // The floor only matters for very short text; padding drives the
            // rest, so it tracks the insets rather than sitting well above
            // them and inflating one-word bubbles.
            let bubbleHeight = max(
                30,
                ceil(textHeight) + verticalContentInset * 2
            )
            let frame = CGRect(
                x: bubbleX,
                y: contentTopY,
                width: bubbleWidth,
                height: bubbleHeight
            )
            bubbleFrame = frame
            contentFrame = CGRect(
                x: frame.minX + horizontalContentInset,
                y: frame.minY + verticalContentInset,
                width: contentWidth,
                height: textHeight
            )
        }

        // Images are their own rounded media rather than text inside a glass
        // bubble, so they sit on the same edge as the bubble and carry no
        // bubble of their own. A caption keeps its bubble directly above.
        var attachmentRegions: [AttachmentRegion] = []
        // The row's height is measured from this frame, so a centred line
        // anchors to its own text: with no bubble to fall back on it would
        // otherwise claim no height and overlap the message below it.
        var anchorFrame = bubbleFrame ?? contentFrame ?? CGRect(
            x: bubbleX,
            y: contentTopY,
            width: 0,
            height: 0
        )
        if !effectiveMessage.attachments.isEmpty {
            let galleryWidth = max(180, maximumBubbleWidth)
            let galleryFrames = directMessageGalleryFrames(
                effectiveMessage.attachments,
                width: galleryWidth
            )
            let galleryHeight = galleryFrames.map(\.maxY).max() ?? 0
            let galleryExtent = galleryFrames.map(\.maxX).max() ?? galleryWidth
            let galleryY = hasText
                ? (bubbleFrame?.maxY ?? contentTopY) + 4
                : contentTopY
            let galleryX = isOutgoing
                ? conversationMinX + conversationWidth
                    - horizontalInset - galleryExtent
                : conversationMinX + horizontalInset
            attachmentRegions = zip(
                effectiveMessage.attachments,
                galleryFrames
            ).map { attachment, frame in
                AttachmentRegion(
                    frame: frame.offsetBy(dx: galleryX, dy: galleryY),
                    attachment: attachment
                )
            }
            anchorFrame = CGRect(
                x: galleryX,
                y: galleryY,
                width: galleryExtent,
                height: galleryHeight
            )
        }

        // A linked image - a GIF pasted as a Tenor or Giphy URL - is the
        // same media as an upload, just carried by the link rather than an
        // attachment. It follows the gallery's rules so a GIF sits on its
        // sender's edge instead of falling back to the standard row, which
        // is left-aligned no matter who sent it.
        var linkedImageRegions: [LinkedImageRegion] = []
        if !contentPresentation.linkedImages.isEmpty {
            let plan = InlineWrappingLayoutPlan.frames(
                sizes: contentPresentation.linkedImages.map(\.displaySize),
                maximumWidth: max(180, maximumBubbleWidth),
                horizontalSpacing: 4,
                verticalSpacing: 4
            )
            let linkedExtent = plan.frames.map(\.maxX).max() ?? plan.size.width
            let linkedY = anchorFrame.height > 0
                ? anchorFrame.maxY + 4
                : contentTopY
            let linkedX = isOutgoing
                ? conversationMinX + conversationWidth
                    - horizontalInset - linkedExtent
                : conversationMinX + horizontalInset
            linkedImageRegions = zip(
                contentPresentation.linkedImages,
                plan.frames
            ).map { reference, frame in
                LinkedImageRegion(
                    frame: frame.offsetBy(dx: linkedX, dy: linkedY),
                    reference: reference
                )
            }
            anchorFrame = CGRect(
                x: linkedX,
                y: linkedY,
                width: linkedExtent,
                height: plan.size.height
            )
        }

        // A sticker is media rather than text, so like an image it sits on
        // the message's edge with no bubble behind it.
        let stickers = directMessageStickers(
            // Counted from the message rather than the forwarded snapshot:
            // the painter resolves stickers from message.stickers, and a
            // mismatch would reserve space it never draws into.
            count: message.stickers.count,
            anchorFrame: anchorFrame,
            maximumWidth: maximumBubbleWidth,
            leadingX: conversationMinX + horizontalInset,
            trailingX: conversationMinX + conversationWidth - horizontalInset,
            isOutgoing: isOutgoing
        )
        let stickerFrames = stickers.frames
        anchorFrame = stickers.anchorFrame ?? anchorFrame

        // Link previews hang below the message like attachments do. An embed
        // is laid out at its final origin because its nested title, text and
        // image frames are absolute, so it cannot be repositioned afterwards;
        // it is given a band on the message's own side to occupy.
        var embedRegions: [EmbedRegion] = []
        if !visibleEmbeds.isEmpty {
            let embedWidth = min(maximumBubbleWidth, 520)
            let embedX = isOutgoing
                ? conversationMinX + conversationWidth
                    - horizontalInset - embedWidth
                : conversationMinX + horizontalInset
            var embedY = anchorFrame.maxY + (anchorFrame.height > 0 ? 4 : 0)
            for embed in visibleEmbeds {
                guard let region = NativeTimelineEmbedLayout.make(
                    embed: embed,
                    message: message,
                    model: model,
                    attachments: effectiveMessage.attachments,
                    origin: CGPoint(x: embedX, y: embedY),
                    maximumWidth: embedWidth
                ) else { continue }
                embedRegions.append(region)
                embedY = region.frame.maxY + 4
            }
            if let last = embedRegions.last {
                anchorFrame = CGRect(
                    x: embedX,
                    y: anchorFrame.minY,
                    width: embedWidth,
                    height: last.frame.maxY - anchorFrame.minY
                )
            }
        }

        let compactTimestampFrame = CGRect(
            x: isOutgoing
                ? max(0, anchorFrame.minX - 50)
                : min(width - 46, anchorFrame.maxX + 4),
            y: anchorFrame.maxY - MessageRowLayoutMetrics.compactContentHeight,
            width: 46,
            height: MessageRowLayoutMetrics.compactContentHeight
        )

        // Without this an edited message is indistinguishable from what was
        // originally sent. It tucks under the bubble on the anchored edge
        // rather than inline, which would disturb the measured text.
        var editedFrame: CGRect?
        if message.editedTimestamp != nil {
            let editedFont = NSFont.preferredFont(forTextStyle: .caption2)
            let editedWidth = NativeTimelineRowLayout.measuredTextWidth(
                "(edited)",
                font: editedFont
            )
            editedFrame = CGRect(
                x: isOutgoing
                    ? max(
                        conversationMinX + horizontalInset,
                        anchorFrame.maxX - editedWidth
                    )
                    : anchorFrame.minX,
                y: anchorFrame.maxY + 2,
                width: editedWidth,
                height: 11
            )
        }
        // Reactions hang under the bubble, aligned to the same edge the
        // bubble is anchored to. A reacted message is still ordinary text, so
        // it stays a bubble rather than dropping to a full avatar row.
        let reactions = directMessageReactions(
            message,
            anchorFrame: anchorFrame,
            topY: (editedFrame?.maxY ?? anchorFrame.maxY) + 4,
            maximumWidth: maximumBubbleWidth,
            minimumX: conversationMinX + horizontalInset,
            isOutgoing: isOutgoing
        )
        let reactionRegions = reactions.regions
        let addReactionFrame = reactions.addFrame
        let reactionsMaxY = reactions.maxY
            ?? (editedFrame?.maxY ?? anchorFrame.maxY)

        let failedFrame = message.outboxState == .failed
            ? CGRect(
                x: anchorFrame.minX,
                y: reactionsMaxY + 3,
                width: max(1, anchorFrame.width),
                height: 14
            )
            : nil
        let rowHeight = ceil((failedFrame?.maxY ?? reactionsMaxY) + 7)

        return Self(
            height: rowHeight,
            loaderLayout: nil,
            beginningLayout: nil,
            searchSectionRegion: nil,
            searchCardFrame: nil,
            highlightFrame: CGRect(
                x: 0,
                y: prefixHeight,
                width: width,
                height: rowHeight - prefixHeight
            ),
            messageBubbleFrame: bubbleFrame,
            messageBubbleIsOutgoing: isOutgoing,
            usesConversationLayout: true,
            daySeparatorFrame: daySeparatorFrame,
            unreadSeparatorFrame: unreadSeparatorFrame,
            avatarFrame: nil,
            compactTimestampFrame: compactTimestampFrame,
            authorFrame: authorFrame,
            botBadgeFrame: nil,
            timestampFrame: nil,
            editedFrame: editedFrame,
            loadingIndicatorFrame: nil,
            replyFrame: replyFrame,
            replyContentFrame: replyFrame,
            commandInvocationRegion: nil,
            systemIconFrame: nil,
            contentFrame: contentFrame,
            attributedContent: attributedContent,
            contentFramesetter: contentPresentation.framesetter,
            forwardedHeaderFrame: forwardedHeaderFrame,
            forwardedBarFrame: nil,
            forwardedSourceRegion: nil,
            linkedImageRegions: linkedImageRegions,
            attachmentRegions: attachmentRegions,
            embedFrames: embedRegions.map(\.frame),
            embedRegions: embedRegions,
            componentFrames: [],
            componentLayouts: [],
            stickerFrames: stickerFrames,
            threadFrame: nil,
            reactionRegions: reactionRegions,
            addReactionFrame: addReactionFrame,
            ephemeralRegion: nil,
            failedFrame: failedFrame
        )
    }

    struct DirectMessageReactionLayout {
        let regions: [ReactionRegion]
        let addFrame: CGRect?
        /// Nil when the message carries no reactions, so the caller keeps
        /// whatever bottom edge it already had.
        let maxY: CGFloat?
    }

    /// Reaction chips for a bubble, hung under it on the edge the message is
    /// anchored to.
    struct DirectMessageSeparatorLayout {
        let dayFrame: CGRect?
        let unreadFrame: CGRect?
        let height: CGFloat
    }

    /// Day and unread rules above a bubble. Split out to keep the bubble
    /// builder inside its complexity budget as message kinds accumulate.
    static func directMessageSeparators(
        _ row: MessageRowPresentation,
        isUnreadBoundary: Bool,
        minX: CGFloat,
        width: CGFloat
    ) -> DirectMessageSeparatorLayout {
        var height: CGFloat = 0
        var dayFrame: CGRect?
        if row.startsDay {
            dayFrame = CGRect(
                x: minX,
                y: height,
                width: width,
                height: NativeTimelineDateSeparatorMetrics.rowHeight
            )
            height += NativeTimelineDateSeparatorMetrics.rowHeight
        }
        var unreadFrame: CGRect?
        if isUnreadBoundary {
            unreadFrame = CGRect(
                x: minX,
                y: height,
                width: width,
                height: NativeTimelineUnreadSeparatorMetrics.rowHeight
            )
            height += NativeTimelineUnreadSeparatorMetrics.rowHeight
        }
        return DirectMessageSeparatorLayout(
            dayFrame: dayFrame,
            unreadFrame: unreadFrame,
            height: height
        )
    }

    struct DirectMessageStickerLayout {
        let frames: [CGRect]
        /// Nil when there are no stickers, so the caller keeps its anchor.
        let anchorFrame: CGRect?
    }

    /// Sticker squares placed on the message's own edge, plus the anchor the
    /// rest of the row should hang from.
    static func directMessageStickers(
        count: Int,
        anchorFrame: CGRect,
        maximumWidth: CGFloat,
        leadingX: CGFloat,
        trailingX: CGFloat,
        isOutgoing: Bool
    ) -> DirectMessageStickerLayout {
        guard count > 0 else {
            return DirectMessageStickerLayout(frames: [], anchorFrame: nil)
        }
        let placed = directMessageStickerFrames(
            count: count,
            maximumWidth: maximumWidth,
            topY: anchorFrame.maxY + (anchorFrame.height > 0 ? 4 : 0)
        )
        let extent = placed.frames.map(\.maxX).max() ?? 0
        let originX = isOutgoing ? trailingX - extent : leadingX
        let frames = placed.frames.map { $0.offsetBy(dx: originX, dy: 0) }
        let bottom = frames.map(\.maxY).max() ?? anchorFrame.maxY
        return DirectMessageStickerLayout(
            frames: frames,
            anchorFrame: CGRect(
                x: originX,
                y: anchorFrame.minY,
                width: max(extent, 1),
                height: bottom - anchorFrame.minY
            )
        )
    }

    /// Sticker squares, wrapped to the bubble's maximum width. Frames are
    /// produced at x = 0 so the caller can anchor the run to either edge.
    static func directMessageStickerFrames(
        count: Int,
        maximumWidth: CGFloat,
        topY: CGFloat
    ) -> DirectMessageStickerLayout {
        let size = min(maximumWidth, 112)
        let spacing: CGFloat = 8
        var frames: [CGRect] = []
        var originX: CGFloat = 0
        var originY = topY
        for _ in 0 ..< count {
            if originX > 0, originX + size > maximumWidth {
                originX = 0
                originY += size + spacing
            }
            frames.append(
                CGRect(x: originX, y: originY, width: size, height: size)
            )
            originX += size + spacing
        }
        return DirectMessageStickerLayout(frames: frames, anchorFrame: nil)
    }

    static func directMessageReactions(
        _ message: Message,
        anchorFrame: CGRect,
        topY: CGFloat,
        maximumWidth: CGFloat,
        minimumX: CGFloat,
        isOutgoing: Bool
    ) -> DirectMessageReactionLayout {
        let presented = MessageReactionPresentation.items(
            from: message.reactions
        )
        guard !presented.isEmpty else {
            return DirectMessageReactionLayout(
                regions: [],
                addFrame: nil,
                maxY: nil
            )
        }

        let sizes = presented.map(reactionSize)
            + [CGSize(
                width: ReactionActionMenuPresentation.inline.width,
                height: MessageReactionMetrics.pillHeight
            )]
        let wrapping = InlineWrappingLayoutPlan.frames(
            sizes: sizes,
            maximumWidth: maximumWidth,
            horizontalSpacing: MessageReactionMetrics.horizontalSpacing,
            verticalSpacing: MessageReactionMetrics.verticalSpacing
        )
        let originX = isOutgoing
            ? max(minimumX, anchorFrame.maxX - wrapping.size.width)
            : anchorFrame.minX
        let regions = zip(
            presented,
            wrapping.frames.prefix(presented.count)
        ).map { reaction, frame in
            NativeTimelineRowLayout.reactionRegion(
                reaction,
                frame: frame.offsetBy(dx: originX, dy: topY)
            )
        }
        return DirectMessageReactionLayout(
            regions: regions,
            addFrame: wrapping.frames.last?.offsetBy(dx: originX, dy: topY),
            maxY: topY + wrapping.size.height
        )
    }

    /// Gallery geometry for a bubble's attachments. Split out so the bubble
    /// builder stays within its complexity budget as cases accumulate.
    static func directMessageGalleryFrames(
        _ attachments: [Attachment],
        width: CGFloat
    ) -> [CGRect] {
        func intrinsicSize(_ attachment: Attachment) -> CGSize {
            guard let width = attachment.width,
                  let height = attachment.height,
                  width > 0,
                  height > 0
            else { return .zero }
            return CGSize(width: CGFloat(width), height: CGFloat(height))
        }

        return MediaGalleryPlan.frames(
            count: attachments.count,
            width: width,
            aspectRatios: attachments.map {
                let size = intrinsicSize($0)
                guard size.height > 0 else { return 16 / 9 }
                return size.width / size.height
            },
            intrinsicSizes: attachments.map(intrinsicSize),
            spacing: 4
        )
    }

    /// In a group, an incoming bubble is captioned with its sender, once
    /// per run rather than on every message. A one-to-one thread needs no
    /// name, your own messages are already on your side, and a generated
    /// notice has no sender to attribute.
    static func directMessageNamesAuthor(
        namesIncomingAuthors: Bool,
        isOutgoing: Bool,
        startsGroup: Bool,
        isSystemLine: Bool
    ) -> Bool {
        namesIncomingAuthors && !isOutgoing && startsGroup && !isSystemLine
    }

    /// Whether a message belongs in the conversation layout at all.
    ///
    /// Discord gives replies their own type (19), so matching only
    /// `.default` silently excludes every real reply. Generated notices are
    /// admitted too, as a centred line rather than a bubble. Anything that
    /// carries its own interactive chrome - buttons, a thread, a components
    /// v2 payload - keeps the standard row, which is built to lay that out.
    static func directMessageAllowsConversationRow(_ message: Message) -> Bool {
        let isConversational = message.type == .default
            || message.type == .reply
            || message.type.hasGeneratedContent
        return isConversational
            && message.components.isEmpty
            && message.thread == nil
            && !message.flags.contains(.ephemeral)
            && !message.flags.contains(.isComponentsV2)
    }

    /// A bubble needs something to show. Text, images, stickers, a linked
    /// image and an embed are each enough on their own: a GIF sent with no
    /// caption is still a message, and anything answering `false` here
    /// falls back to the standard row, which is left-aligned whoever sent
    /// it.
    static func directMessageHasContent(
        hasText: Bool,
        attachments: [Attachment],
        stickers: [MessageSticker],
        linkedImages: [LinkedImageReference],
        embeds: [MessageEmbed]
    ) -> Bool {
        hasText
            || !attachments.isEmpty
            || !stickers.isEmpty
            || !linkedImages.isEmpty
            || !embeds.isEmpty
    }

    /// Centres a generated notice on its own natural width, so the line is
    /// centred as text rather than as a full-width box that happens to hold
    /// left-aligned words.
    static func directMessageSystemLineFrame(
        framesetter: CTFramesetter,
        content: NSAttributedString,
        available: CGFloat,
        centredOn centreX: CGFloat,
        topY: CGFloat
    ) -> CGRect {
        let naturalWidth = measuredMaximumLineWidth(
            framesetter,
            length: content.length,
            width: available
        )
        let lineWidth = max(1, min(available, ceil(naturalWidth)))
        return CGRect(
            x: centreX - lineWidth / 2,
            y: topY,
            width: lineWidth,
            height: measuredTextHeight(
                framesetter,
                value: content,
                length: content.length,
                width: lineWidth
            )
        )
    }

    static func measuredMaximumLineWidth(
        _ framesetter: CTFramesetter,
        length: Int,
        width: CGFloat
    ) -> CGFloat {
        let path = CGPath(
            rect: CGRect(
                x: 0,
                y: 0,
                width: max(1, width),
                height: 100_000
            ),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: length),
            path,
            nil
        )
        let lines = CTFrameGetLines(frame) as NSArray
        var maximumWidth: CGFloat = 0
        for case let line as CTLine in lines {
            maximumWidth = max(
                maximumWidth,
                CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            )
        }
        return min(width, maximumWidth)
    }
}

extension Message {
    /// The message whose content a bubble should render.
    ///
    /// A forward is a shell: its own content is empty and the text, images
    /// and embeds it is carrying live in the snapshot. Everywhere else this
    /// is just the message itself.
    var directMessageBubbleContentSource: Message {
        guard let snapshot = forwardedSnapshot else { return self }
        var resolved = self
        resolved.content = snapshot.content
        resolved.attachments = snapshot.attachments
        resolved.embeds = snapshot.embeds
        return resolved
    }
}
