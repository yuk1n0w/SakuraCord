import AppKit

/// Converts wheel notches and trackpad gestures into bounded navigation steps.
nonisolated struct ServerSwitcherScrollStepper {
    private var accumulatedDelta: CGFloat = 0
    private var didStepInGesture = false
    private var lastEventTime: TimeInterval = -.infinity
    private var lastStepTime: TimeInterval = -.infinity

    mutating func step(
        deltaX: CGFloat,
        deltaY: CGFloat,
        precise: Bool,
        phase: NSEvent.Phase,
        momentum: NSEvent.Phase,
        timestamp: TimeInterval
    ) -> Int? {
        // Inertial events must never select additional servers after a flick.
        guard momentum.isEmpty else { return nil }
        if phase.contains(.began) || timestamp - lastEventTime > 0.3 {
            accumulatedDelta = 0
            didStepInGesture = false
        }
        lastEventTime = timestamp
        if phase.contains(.ended) || phase.contains(.cancelled) {
            accumulatedDelta = 0
            didStepInGesture = false
            return nil
        }
        guard deltaY.isFinite, deltaX.isFinite,
              deltaY != 0, abs(deltaY) >= abs(deltaX)
        else { return nil }
        if !precise { return deltaY < 0 ? 1 : -1 }

        guard !didStepInGesture else { return nil }
        if accumulatedDelta * deltaY < 0 { accumulatedDelta = 0 }
        accumulatedDelta += deltaY
        guard abs(accumulatedDelta) >= 12 else { return nil }
        // Smooth wheels may provide precise deltas without gesture phases.
        guard !phase.isEmpty || timestamp - lastStepTime >= 0.18 else { return nil }
        accumulatedDelta = 0
        lastStepTime = timestamp
        didStepInGesture = !phase.isEmpty
        return deltaY < 0 ? 1 : -1
    }
}
