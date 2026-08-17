import AppKit
import SakuraCordModels

/// Top-down coordinate space, matching the timeline canvas.
final class NativeTimelineFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Backs direct-message bubbles with real Liquid Glass.
///
/// The timeline paints every row into one canvas, and subviews always render
/// above their host's own drawing, so glass parented to the canvas would
/// cover the message text. This host therefore sits *behind* the canvas in
/// the document view; the canvas stays non-opaque and draws only the text
/// over the glass beneath it.

@MainActor
final class NativeTimelineGlassBubbleHost: NSView {
    struct Bubble: Equatable {
        let key: MessageID
        let frame: CGRect
        let cornerRadius: CGFloat
        let isOutgoing: Bool

        /// Everything except the frame. Scrolling changes the frame on every
        /// pass, so comparing the whole bubble would re-apply glass
        /// properties continuously and defeat the cache.
        var presentation: Presentation {
            Presentation(cornerRadius: cornerRadius, isOutgoing: isOutgoing)
        }
    }

    struct Presentation: Equatable {
        let cornerRadius: CGFloat
        let isOutgoing: Bool
    }

    override var isFlipped: Bool { true }

    /// The container merges nearby glass into shared render passes. Without
    /// it each bubble costs its own backdrop, which a scrolling timeline
    /// cannot afford.
    private let container = NSGlassEffectContainerView()
    /// Must be flipped: the glass views are its children, and every frame fed
    /// to them is top-down document geometry. A plain NSView is bottom-up,
    /// which stacks the bubbles in reverse order down the conversation.
    private let content = NativeTimelineFlippedView()
    private var bubbles: [MessageID: NSGlassEffectView] = [:]
    private var presentations: [MessageID: Presentation] = [:]
    /// Evicted views are parked here rather than destroyed. Building a glass
    /// view allocates backdrop storage, and scrolling evicts and re-admits
    /// rows continuously, so recycling is what keeps a scroll affordable.
    private var pool: [NSGlassEffectView] = []
    private static let poolLimit = 24
    /// The last set actually applied, so an unchanged pass costs one compare.
    private var lastApplied: [Bubble] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // No autoresizing: apply(_:) sets frame and bounds explicitly, and a
        // mask would fight the shifted bounds it installs.
        // Zero, not a positive spacing: the container fuses glass views that
        // fall within `spacing` of each other, and consecutive bubbles sit
        // ~14pt apart. Zero still batches them into shared render passes but
        // keeps each bubble a distinct shape.
        container.spacing = 0
        container.contentView = content
        addSubview(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The glass is decoration behind the canvas; all interaction belongs to
    /// the canvas drawing on top of it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(_ desired: [Bubble]) {
        // A pass that changes nothing must touch nothing. Reconcile is driven
        // from several display and layout paths, so without this the same
        // frames get rewritten continuously and every write asks the glass
        // container to re-evaluate its backdrop.
        if desired == lastApplied,
           container.frame == bounds,
           content.frame == bounds
        {
            return
        }
        lastApplied = desired

        if container.frame != bounds {
            container.frame = bounds
        }
        if content.frame != bounds {
            content.frame = bounds
        }

        let desiredKeys = Set(desired.map(\.key))
        for key in Array(bubbles.keys) where !desiredKeys.contains(key) {
            guard let view = bubbles.removeValue(forKey: key) else { continue }
            presentations[key] = nil
            if pool.count < Self.poolLimit {
                view.isHidden = true
                pool.append(view)
            } else {
                view.removeFromSuperview()
            }
        }

        for bubble in desired {
            let view: NSGlassEffectView
            if let existing = bubbles[bubble.key] {
                view = existing
            } else if let recycled = pool.popLast() {
                // The key is new, so presentations has no entry and the
                // corner radius and tint below are reapplied for this bubble.
                recycled.isHidden = false
                bubbles[bubble.key] = recycled
                view = recycled
            } else {
                let created = NSGlassEffectView()
                // Clear rather than regular, matching the DM composer's
                // `.clear.tint(black)`. Regular glass reads as a pale plate;
                // clear keeps the body dark and translucent so the lit rim
                // is what defines the shape.
                created.style = .clear
                // The effect embeds a content view rather than applying
                // itself behind one, so a nil contentView renders nothing.
                // The canvas draws the text, so this only reserves the shape.
                let embedded = NSView()
                embedded.autoresizingMask = [.width, .height]
                created.contentView = embedded
                content.addSubview(created)
                bubbles[bubble.key] = created
                view = created
            }
            let presentation = bubble.presentation
            if presentations[bubble.key] != presentation {
                view.cornerRadius = bubble.cornerRadius
                // A dark tint, as the composer uses. Both sides stay neutral
                // so the thread reads as one surface; outgoing sits a few
                // percent lighter purely so the sender is legible at a glance.
                view.tintColor = NSColor.black.withAlphaComponent(
                    bubble.isOutgoing ? 0.16 : 0.22
                )
                presentations[bubble.key] = presentation
            }
            if view.frame != bubble.frame {
                view.frame = bubble.frame
            }
        }
    }
}

extension NativeTimelineCanvasView {
    /// Mirrors the visible rows' bubble geometry into the glass host.
    ///
    /// The canvas is an overscanned window whose `bounds` origin is set to its
    /// own `frame.minY`, so canvas-local y is really document-space y. Bubble
    /// rects are built in canvas space and converted with AppKit's own
    /// coordinate math. The host keeps zero-based bounds because the glass
    /// container manages its own backdrop and renders nothing under a shifted
    /// origin, and stays viewport-sized because a container spanning a long
    /// conversation allocates backdrop storage for the entire height.
    func reconcileGlassBubbles() {
        guard let host = glassBubbleHost, !isReconcilingGlassBubbles else {
            return
        }
        isReconcilingGlassBubbles = true
        defer { isReconcilingGlassBubbles = false }
        if host.frame != frame {
            host.frame = frame
        }
        let hostBounds = CGRect(origin: .zero, size: frame.size)
        if host.bounds != hostBounds {
            host.bounds = hostBounds
        }

        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            host.apply([])
            return
        }

        var desired: [NativeTimelineGlassBubbleHost.Bubble] = []
        desired.reserveCapacity(16)
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            if layouts.indices.contains(index),
               case let .message(row, _, _) = items[index],
               let bubbleFrame = layouts[index].messageBubbleFrame
            {
                desired.append(
                    NativeTimelineGlassBubbleHost.Bubble(
                        key: row.message.id,
                        frame: host.convert(
                            bubbleFrame.offsetBy(
                                dx: 0,
                                dy: displayedRowOrigin(at: index)
                            ),
                            from: self
                        ),
                        cornerRadius: min(18, bubbleFrame.height / 2),
                        isOutgoing: layouts[index].messageBubbleIsOutgoing
                    )
                )
            }
            index += 1
        }
        host.apply(desired)
    }
}
