import SwiftUI

nonisolated enum ChatChromeMetrics {
    static let controlHeight: CGFloat = 48
    static let composerControlHeight: CGFloat = 36
    static let composerCornerRadius = composerControlHeight / 2
    static let composerTextVerticalInset: CGFloat = 9
    static let composerAccessoryButtonSize: CGFloat = 32
    static let composerAccessoryEdgeInset: CGFloat =
        (composerControlHeight - composerAccessoryButtonSize) / 2
    static let composerSegmentSpacing: CGFloat = 8
    static let controlCornerRadius: CGFloat = 16
    static let serverRailWidth: CGFloat = 68
    static let sidebarTitleLeadingOffset: CGFloat = serverRailWidth + 24
    static let sidebarTitleTopOffset: CGFloat = 11
    static let sidebarContentCornerRadius: CGFloat = 16
    static let composerWindowInset: CGFloat = 12
    static let directMessageContentMaximumWidth: CGFloat = 640
    /// Upper bound on a bubble once it scales with the pane. Past roughly
    /// this width a line of chat text becomes tiring to read, so wide windows
    /// buy more breathing room around the thread rather than longer lines.
    static let directMessageBubbleMaximumWidth: CGFloat = 560
    /// Only a fallback for layouts where the composer isn't adjacent to a
    /// rounded container corner. macOS resolves the actual aligned radius.
    static let composerMinimumCornerRadius: CGFloat = 12
    static let channelListTopPadding: CGFloat = 10
    static let memberListWidth: CGFloat = 280
    /// Native toolbar search keeps its own outer item margin. An eight-point
    /// field inset centers the visible glass inside the fixed inspector pane.
    static let toolbarPaneEdgeInset: CGFloat = 8
    static let toolbarSearchMaximumFieldWidth: CGFloat =
        memberListWidth - (toolbarPaneEdgeInset * 2)
    static let emojiPickerWidth: CGFloat = 520
    static let pickerSearchHeaderHeight: CGFloat = 48
    static let pickerSearchHeaderInset: CGFloat = 15
    static let pickerSearchHeaderSpacing: CGFloat = 9
    static let pickerSearchHeaderIconSize: CGFloat = 14
    static let pickerSearchHeaderFontSize: CGFloat = 15
}

/// One place to tune how immediate the interface feels. Every view animation
/// divides its duration by `factor`, so raising it speeds the whole app up
/// uniformly and 1 restores the original timings.
nonisolated enum ChatAnimationSpeed {
    static let factor: Double = 1.6

    static func scaled(_ duration: Double) -> Double {
        guard factor > 0 else { return duration }
        return duration / factor
    }
}

nonisolated enum ChatDetailLayoutPolicy {
    static let timelineTopPadding: CGFloat = 12
    static let timelineBottomPadding: CGFloat = 12
    /// The former SwiftUI scroll view retained its seven-point soft-edge
    /// overlap in addition to the stack padding when a width reflow exposed
    /// the first intersecting row.
    static let timelineWidthReflowTopInset: CGFloat =
        timelineTopPadding + 7
    static let newMessagesButtonSpacing: CGFloat = 10
    static let defaultFloatingFooterHeight: CGFloat =
        ChatChromeMetrics.composerControlHeight + 12 + 18

    static func bottomContentInset(measuredFooterHeight: CGFloat) -> CGFloat {
        guard measuredFooterHeight.isFinite else { return defaultFloatingFooterHeight }
        return max(defaultFloatingFooterHeight, measuredFooterHeight)
    }

    static func timelineMinimumContentHeight(viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight)
    }

    static func newMessagesButtonBottomPadding(bottomContentInset: CGFloat) -> CGFloat {
        max(0, bottomContentInset) + newMessagesButtonSpacing
    }
}
