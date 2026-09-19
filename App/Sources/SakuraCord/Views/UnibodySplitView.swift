import SwiftUI

/// Places the sidebar and the workspace on one continuous surface.
///
/// On macOS 26 `NavigationSplitView` always floats its sidebar on a separate
/// Liquid Glass panel, and neither SwiftUI nor `NSSplitViewItem` can opt out
/// (the sidebar behavior is fixed when the split item is created). SakuraCord
/// owns the split instead, so the sidebar list sits directly on the window's
/// frosted backdrop like the rest of the window.
struct UnibodySplitView<Sidebar: View, Detail: View>: View {
    @Binding var sidebarWidth: CGFloat
    let isSidebarVisible: Bool
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                sidebar
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(width: $sidebarWidth)
                    }
                    .transition(.move(edge: .leading))
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// An invisible strip straddling the sidebar's trailing edge. It resizes the
/// sidebar within the bounds `NavigationSplitView` used to enforce.
private struct SidebarResizeHandle: View {
    private static let hitWidth: CGFloat = 8

    @Binding var width: CGFloat
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: Self.hitWidth)
            .contentShape(Rectangle())
            .offset(x: Self.hitWidth / 2)
            .pointerStyle(.frameResize(position: .trailing, directions: [.inward, .outward]))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        dragStartWidth = start
                        width = ChatChromeMetrics.clampedChannelSidebarWidth(
                            start + value.translation.width
                        )
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .accessibilityHidden(true)
    }
}
