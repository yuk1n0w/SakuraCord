import Darwin
import Dispatch
import Foundation

/// Gives memory back when the system asks for it.
///
/// The app keeps several caches so that reopening a conversation, searching,
/// or scrolling back does not re-fetch and re-parse work it has already done.
/// Each is bounded, but the bounds are sized for a machine that has memory to
/// spare. Without this, a system under pressure has no way to reclaim any of
/// it, and the app is a few hundred megabytes that never yields - which is
/// what makes an otherwise idle chat window feel expensive to keep open.
///
/// Warning drops what is cheapest to rebuild. Critical drops the rest and
/// asks malloc to return the freed pages, which it otherwise holds for reuse.
@MainActor
final class AppMemoryPressureResponder {
    static let shared = AppMemoryPressureResponder()

    /// What a pressure event asks the app to give up.
    nonisolated enum Relief: Equatable {
        /// Drop what is cheapest to rebuild.
        case partial
        /// Drop the rest and hand the freed pages back.
        case full
    }

    private var source: DispatchSourceMemoryPressure?

    private init() {}

    /// Critical wins when an event carries both levels: it is the more
    /// severe request, and running the warning purge first would spend time
    /// exactly when the system has none.
    nonisolated static func relief(
        for event: DispatchSource.MemoryPressureEvent
    ) -> Relief? {
        if event.contains(.critical) { return .full }
        if event.contains(.warning) { return .partial }
        return nil
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let event = self.source?.data else { return }
            MainActor.assumeIsolated {
                self.respond(to: event)
            }
        }
        source.resume()
        self.source = source
    }

    func respond(to event: DispatchSource.MemoryPressureEvent) {
        guard let relief = Self.relief(for: event) else { return }
        // Remote media is the cheapest to give up: it is still on disk, so
        // getting it back is a file read rather than a download. Local
        // files only go under a critical request.
        let dropsLocalFiles = relief == .full
        Task {
            await SharedMediaDataLoader.shared.purgeInMemoryCaches(
                includingLocalFiles: dropsLocalFiles
            )
        }
        ForwardDestinationSearchIndexCache.shared.purge()
        guard relief == .full else { return }
        // Freed pages are held by malloc for reuse, so they stay counted
        // against the process until it is asked to hand them back. Under
        // real pressure that reuse is worth less than the memory.
        malloc_zone_pressure_relief(nil, 0)
    }
}
