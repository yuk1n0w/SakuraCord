import AppKit
import SwiftUI

/// Replaces the opaque window background with a desktop-sampling blur so
/// floating chrome and message bubbles have varied content to refract. The
/// bubbles are painted into a canvas that cannot host its own glass, so the
/// depth has to come from what sits behind the window.
struct WindowGlassBackdropBridge: NSViewRepresentable {
    /// Darkens the blur so timeline text keeps its contrast over a bright
    /// desktop. Without it the backdrop washes out light-on-dark content.
    static let tintOpacity: CGFloat = 0.45

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        // This bridge takes no inputs, so updateNSView is not guaranteed to
        // run again after the view lands in a window. Attaching from the
        // view's own window callback is what makes the hookup reliable.
        let view = WindowGlassBackdropAnchorView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.update(window: window)
        }
        DispatchQueue.main.async {
            context.coordinator.update(window: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.update(window: view.window)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var backdrop: NSVisualEffectView?
        private var tint: NSView?
        private var restoresOpaque: Bool?
        private var restoresBackgroundColor: NSColor?

        func update(window: NSWindow?) {
            guard self.window !== window else { return }
            guard let window else {
                detach()
                return
            }
            attach(to: window)
        }

        func detach() {
            if let window, let restoresOpaque, let restoresBackgroundColor {
                window.isOpaque = restoresOpaque
                window.backgroundColor = restoresBackgroundColor
            }
            restoresOpaque = nil
            restoresBackgroundColor = nil
            tint?.removeFromSuperview()
            tint = nil
            backdrop?.removeFromSuperview()
            backdrop = nil
            window = nil
        }

        private func attach(to window: NSWindow) {
            detach()
            self.window = window
            guard let frameView = window.contentView?.superview else { return }

            restoresOpaque = window.isOpaque
            restoresBackgroundColor = window.backgroundColor
            window.isOpaque = false
            window.backgroundColor = .clear

            let backdrop = NSVisualEffectView(frame: frameView.bounds)
            backdrop.material = .underWindowBackground
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.autoresizingMask = [.width, .height]

            let tint = NSView(frame: frameView.bounds)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.black
                .withAlphaComponent(WindowGlassBackdropBridge.tintOpacity)
                .cgColor
            tint.autoresizingMask = [.width, .height]
            backdrop.addSubview(tint)

            frameView.addSubview(backdrop, positioned: .below, relativeTo: nil)
            self.backdrop = backdrop
            self.tint = tint
        }
    }
}

private final class WindowGlassBackdropAnchorView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
