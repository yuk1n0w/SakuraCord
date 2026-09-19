import AppKit
import Observation
import SakuraCordModels
import SwiftUI

/// Lets AppKit own the switcher's title-bar placement and mouse routing.
/// A left accessory sits after the traffic lights and spans the title bar
/// above the sidebar: the workspace switcher, then the sidebar toggle at the
/// sidebar's edge. Toolbar items therefore begin where the workspace begins.
struct SidebarTitlebarSwitcherBridge: NSViewRepresentable {
    let model: AppModel
    let sidebarWidth: CGFloat
    let isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, sidebarWidth: sidebarWidth, isVisible: isVisible)
    }

    func makeNSView(context: Context) -> SidebarTitlebarSwitcherAnchorView {
        let view = SidebarTitlebarSwitcherAnchorView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.update(window: window)
        }
        DispatchQueue.main.async {
            context.coordinator.update(window: view.window)
        }
        return view
    }

    func updateNSView(
        _ view: SidebarTitlebarSwitcherAnchorView,
        context: Context
    ) {
        context.coordinator.update(
            window: view.window,
            sidebarWidth: sidebarWidth,
            isVisible: isVisible
        )
    }

    static func dismantleNSView(
        _ view: SidebarTitlebarSwitcherAnchorView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private let model: AppModel
        private let presentation: SidebarTitlebarSwitcherPresentation
        private var sidebarWidth: CGFloat
        private var isVisible: Bool
        private weak var window: NSWindow?
        private var accessory: NSTitlebarAccessoryViewController?
        private var hostingView: SidebarSwitcherHostingView<SidebarTitlebarSwitcherContent>?
        private var fullScreenObservers: [NSObjectProtocol] = []

        init(model: AppModel, sidebarWidth: CGFloat, isVisible: Bool) {
            self.model = model
            self.sidebarWidth = sidebarWidth
            self.isVisible = isVisible
            presentation = SidebarTitlebarSwitcherPresentation(
                layout: ChatChromeMetrics.sidebarTitlebarLayout(
                    sidebarWidth: sidebarWidth,
                    leading: ChatChromeMetrics.titlebarAccessoryFallbackLeading
                )
            )
        }

        /// Reattaches after a window change using the latest SwiftUI inputs.
        func update(window: NSWindow?) {
            update(window: window, sidebarWidth: sidebarWidth, isVisible: isVisible)
        }

        func update(window: NSWindow?, sidebarWidth: CGFloat, isVisible: Bool) {
            self.sidebarWidth = sidebarWidth
            self.isVisible = isVisible
            if self.window !== window {
                attach(to: window)
            }
            updatePresentation()
        }

        func detach() {
            for observer in fullScreenObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            fullScreenObservers = []
            if let window, let accessory,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory)
            {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            accessory = nil
            hostingView = nil
            window = nil
        }

        private func attach(to window: NSWindow?) {
            detach()
            self.window = window
            guard let window else { return }

            let hostingView = SidebarSwitcherHostingView(rootView: SidebarTitlebarSwitcherContent(
                model: model,
                presentation: presentation
            ))
            hostingView.onScrollStep = { [weak self] step in
                self?.selectAdjacentSpace(step: step)
            }
            hostingView.onFrameOriginChange = { [weak self] in
                self?.updatePresentation()
            }
            // A title-bar host must not inset its SwiftUI content below the
            // toolbar. That draws the capsule outside its actual hit region.
            hostingView.safeAreaRegions = []
            hostingView.sizingOptions = []
            hostingView.frame = CGRect(
                x: 0,
                y: 0,
                width: presentation.layout.accessoryWidth,
                height: 28
            )
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            self.hostingView = hostingView
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .left
            accessory.view = hostingView
            self.accessory = accessory
            window.addTitlebarAccessoryViewController(accessory)

            // Full screen hides the traffic lights and moves the accessory.
            fullScreenObservers = [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ].map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePresentation() }
                }
            }
            // AppKit positions the accessory after this run loop turn.
            DispatchQueue.main.async { [weak self] in
                self?.updatePresentation()
            }
        }

        private func updatePresentation() {
            guard let hostingView, let accessory else { return }
            // AppKit owns the accessory's origin and height, including during
            // fullscreen transitions. Only its width belongs to this bridge,
            // and it runs from that origin just past the sidebar edge.
            let measuredLeading = hostingView.window == nil
                ? 0
                : hostingView.convert(NSPoint.zero, to: nil).x
            let layout = ChatChromeMetrics.sidebarTitlebarLayout(
                sidebarWidth: sidebarWidth,
                leading: measuredLeading > 0
                    ? measuredLeading
                    : ChatChromeMetrics.titlebarAccessoryFallbackLeading
            )
            if presentation.layout != layout {
                presentation.layout = layout
            }
            hostingView.switcherWidth = layout.switcherWidth
            // A hidden left accessory still reserves its width in the title
            // bar, so a closed sidebar collapses it to nothing as well.
            accessory.isHidden = !isVisible
            hostingView.isHidden = !isVisible
            let width = isVisible ? layout.accessoryWidth : 0
            if hostingView.frame.width != width {
                hostingView.setFrameSize(NSSize(width: width, height: hostingView.frame.height))
            }
        }

        private func selectAdjacentSpace(step: Int) {
            guard isVisible, !model.isSwitchingAccounts else { return }
            // Match the popover, including servers inside folders and DMs first.
            let entries = model.serverRailPresentation.items.flatMap { item in
                switch item {
                case .guild(let entry): [entry]
                case .folder(let folder): folder.guildEntries
                }
            }
            let spaces: [GuildID?] = [nil] + entries.compactMap { entry -> GuildID? in
                entry.presentation == nil ? nil : entry.id
            }.map { Optional($0) }
            guard let current = spaces.firstIndex(of: model.selectedGuildID) else { return }
            let next = current + step
            guard spaces.indices.contains(next) else { return }
            model.selectGuild(spaces[next])
        }
    }
}

private final class SidebarSwitcherHostingView<Content: View>: NSHostingView<Content> {
    var onScrollStep: ((Int) -> Void)?
    var onFrameOriginChange: (() -> Void)?
    /// Scrolling switches spaces only over the capsule, not the sidebar toggle.
    var switcherWidth: CGFloat = 0
    private var scrollStepper = ServerSwitcherScrollStepper()

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = newOrigin != frame.origin
        super.setFrameOrigin(newOrigin)
        if changed { onFrameOriginChange?() }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let pill = CGRect(x: bounds.minX, y: bounds.midY - 14, width: switcherWidth, height: 28)
        guard !isHiddenOrHasHiddenAncestor,
              CGPath(roundedRect: pill, cornerWidth: 14, cornerHeight: 14, transform: nil)
              .contains(point)
        else {
            scrollStepper = ServerSwitcherScrollStepper()
            super.scrollWheel(with: event)
            return
        }
        if let step = scrollStepper.step(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentum: event.momentumPhase,
            timestamp: event.timestamp
        ) {
            onScrollStep?(step)
        }
    }
}

@MainActor
@Observable
private final class SidebarTitlebarSwitcherPresentation {
    var layout: ChatChromeMetrics.SidebarTitlebarLayout

    init(layout: ChatChromeMetrics.SidebarTitlebarLayout) {
        self.layout = layout
    }
}

private struct SidebarTitlebarSwitcherContent: View {
    let model: AppModel
    let presentation: SidebarTitlebarSwitcherPresentation

    var body: some View {
        let layout = presentation.layout
        GlassEffectContainer(spacing: ChatChromeMetrics.sidebarTitlebarSpacing) {
            HStack(spacing: 0) {
                Group {
                    if model.isSwitchingAccounts {
                        SkeletonShimmerTimeline {
                            SkeletonShape(cornerRadius: 10)
                                .frame(width: layout.switcherWidth, height: 28)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    } else {
                        SidebarServerSwitcher(
                            model: model,
                            selectedGuild: selectedGuild,
                            width: layout.switcherWidth
                        )
                    }
                }
                .frame(width: layout.switcherWidth, height: 28)

                Spacer(minLength: 0)

                SidebarToggleButton(isSidebarVisible: true)
            }
            .frame(width: layout.controlsWidth, height: 28)
        }
        .frame(width: layout.accessoryWidth, height: 28, alignment: .leading)
    }

    private var selectedGuild: Guild? {
        guard let guildID = model.selectedGuildID else { return nil }
        return model.snapshot?.guilds.first(where: { $0.id == guildID })
    }
}

/// Shows or hides the channel sidebar. While the sidebar is open it sits at
/// the sidebar's edge in the title bar, where the system split view used to
/// put its toggle; while closed it leads the toolbar instead.
struct SidebarToggleButton: View {
    let isSidebarVisible: Bool

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .sakuracordToggleChannelSidebar, object: nil)
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 13, weight: .medium))
                .frame(
                    width: ChatChromeMetrics.sidebarToggleDiameter,
                    height: ChatChromeMetrics.sidebarToggleDiameter
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.white.opacity(0.04)).interactive(), in: Circle())
        .help(title)
        .accessibilityLabel(title)
    }

    private var title: String {
        isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
    }
}

@MainActor
final class SidebarTitlebarSwitcherAnchorView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
