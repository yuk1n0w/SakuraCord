import SwiftUI

struct ComposerChromeLayout<Header: View, Leading: View, Input: View, Accessories: View, Send: View, Overlay: View>: View {
    let appearance: ComposerBarAppearance
    let usesDirectMessageChrome: Bool
    let focus: () -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let leading: Leading
    @ViewBuilder let input: Input
    @ViewBuilder let accessories: Accessories
    @ViewBuilder let send: Send
    @ViewBuilder let overlay: Overlay

    var body: some View {
        GlassEffectContainer(spacing: ChatChromeMetrics.composerSegmentSpacing) {
            switch appearance {
            case .defaultStyle:
                defaultLayout
            case .legacy:
                legacyLayout
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(
            .horizontal,
            usesDirectMessageChrome ? 18 : ChatChromeMetrics.composerWindowInset
        )
        .padding(
            .bottom,
            usesDirectMessageChrome ? 14 : ChatChromeMetrics.composerWindowInset
        )
        .frame(maxWidth: .infinity)
        .frame(
            maxWidth: usesDirectMessageChrome
                ? ChatChromeMetrics.directMessageContentMaximumWidth
                : .infinity
        )
    }

    private var defaultLayout: some View {
        HStack(alignment: .bottom, spacing: ChatChromeMetrics.composerSegmentSpacing) {
            leading
                .glassEffect(.regular.interactive(), in: Circle())

            VStack(alignment: .leading, spacing: 0) {
                header
                HStack(alignment: .bottom, spacing: 9) {
                    input
                    accessories
                }
                .padding(.leading, 11)
                .padding(.trailing, ChatChromeMetrics.composerAccessoryEdgeInset)
                .frame(minHeight: ChatChromeMetrics.composerControlHeight)
            }
            .frame(maxWidth: .infinity)
            .background { ComposerFocusSurface(focus: focus) }
            .glassEffect(
                .regular.interactive(),
                in: ConcentricRectangle(
                    cornerRadius: ChatChromeMetrics.composerCornerRadius,
                    style: .continuous
                )
            )
            .composerOverlay(overlay)

            send
                .glassEffect(.regular.interactive(), in: Circle())
        }
    }

    private var legacyLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .bottom, spacing: 9) {
                leading
                input
                accessories
                Capsule()
                    .fill(.primary.opacity(0.16))
                    .frame(width: 1, height: 16)
                    .frame(width: 9, height: ChatChromeMetrics.composerControlHeight)
                    .accessibilityHidden(true)
                send
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minHeight: ChatChromeMetrics.controlHeight)
        }
        .background { ComposerFocusSurface(focus: focus) }
        .glassEffect(
            usesDirectMessageChrome
                ? .clear.tint(Color.black.opacity(0.20))
                : .regular.interactive(),
            in: ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(
                        usesDirectMessageChrome
                            ? 28
                            : ChatChromeMetrics.composerMinimumCornerRadius
                    )
                ),
                isUniform: true
            )
        )
        .composerOverlay(overlay)
    }
}

private extension View {
    func composerOverlay(_ overlay: some View) -> some View {
        self.overlay(alignment: .top) {
            overlay
                .alignmentGuide(.top) { dimensions in
                    dimensions[.bottom] + 7
                }
                .zIndex(10)
        }
    }
}
