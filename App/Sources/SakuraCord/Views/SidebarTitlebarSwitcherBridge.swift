import AppKit
import Observation
import SakuraCordModels
import SwiftUI

/// Lets AppKit own the switcher's title-bar placement and mouse routing.
/// A left accessory sits after the traffic lights, before the sidebar toggle.
struct SidebarTitlebarSwitcherBridge: NSViewRepresentable {
    let model: AppModel
    let width: CGFloat
    let isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, width: width, isVisible: isVisible)
    }

    func makeNSView(context: Context) -> SidebarTitlebarSwitcherAnchorView {
        let view = SidebarTitlebarSwitcherAnchorView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.update(window: window, width: width, isVisible: isVisible)
        }
        DispatchQueue.main.async {
            context.coordinator.update(
                window: view.window,
                width: width,
                isVisible: isVisible
            )
        }
        return view
    }

    func updateNSView(
        _ view: SidebarTitlebarSwitcherAnchorView,
        context: Context
    ) {
        context.coordinator.update(
            window: view.window,
            width: width,
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
        private weak var window: NSWindow?
        private var accessory: NSTitlebarAccessoryViewController?
        private var hostingView: NSHostingView<SidebarTitlebarSwitcherContent>?

        init(model: AppModel, width: CGFloat, isVisible: Bool) {
            self.model = model
            presentation = SidebarTitlebarSwitcherPresentation(
                width: width,
                isVisible: isVisible
            )
        }

        func update(window: NSWindow?, width: CGFloat, isVisible: Bool) {
            presentation.width = width
            presentation.isVisible = isVisible
            if self.window !== window {
                attach(to: window)
            }
            updatePresentation()
        }

        func detach() {
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
            // A title-bar host must not inset its SwiftUI content below the
            // toolbar. That draws the capsule outside its actual hit region.
            hostingView.safeAreaRegions = []
            hostingView.sizingOptions = []
            hostingView.frame = CGRect(x: 0, y: 0, width: presentation.width, height: 28)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            self.hostingView = hostingView
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .left
            accessory.view = hostingView
            self.accessory = accessory
            window.addTitlebarAccessoryViewController(accessory)
        }

        private func updatePresentation() {
            guard let hostingView, let accessory else { return }
            // AppKit owns the accessory's origin and height, including during
            // fullscreen transitions. Only its width belongs to this bridge.
            hostingView.setFrameSize(NSSize(
                width: presentation.width,
                height: hostingView.frame.height
            ))
            accessory.isHidden = !presentation.isVisible
        }

        private func selectAdjacentSpace(step: Int) {
            guard presentation.isVisible, !model.isSwitchingAccounts else { return }
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
    private var scrollStepper = ServerSwitcherScrollStepper()

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let pill = CGRect(x: bounds.minX, y: bounds.midY - 14, width: bounds.width, height: 28)
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
    var width: CGFloat
    var isVisible: Bool

    init(width: CGFloat, isVisible: Bool) {
        self.width = width
        self.isVisible = isVisible
    }
}

private struct SidebarTitlebarSwitcherContent: View {
    let model: AppModel
    let presentation: SidebarTitlebarSwitcherPresentation

    var body: some View {
        Group {
            if model.isSwitchingAccounts {
                SkeletonShimmerTimeline {
                    SkeletonShape(cornerRadius: 10)
                        .frame(width: presentation.width, height: 28)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            } else {
                SidebarServerSwitcher(
                    model: model,
                    selectedGuild: selectedGuild,
                    width: presentation.width
                )
            }
        }
        .frame(width: presentation.width, height: 28)
    }

    private var selectedGuild: Guild? {
        guard let guildID = model.selectedGuildID else { return nil }
        return model.snapshot?.guilds.first(where: { $0.id == guildID })
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
