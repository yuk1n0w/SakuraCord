import Darwin
import Foundation
import Observation

nonisolated struct AppPerformanceContext: Codable, Equatable, Sendable {
    var isMusicPlaying = false
    var showsLyrics = false
    var showsYouTubeMusic = false
    var showsMessageSearch = false
    var showsMemberInspector = false

    static let idle = AppPerformanceContext()

    var summary: String {
        var activities: [String] = []
        if isMusicPlaying { activities.append("music playing") }
        if showsLyrics { activities.append("lyrics visible") }
        if showsYouTubeMusic { activities.append("music browser visible") }
        if showsMessageSearch { activities.append("message search visible") }
        if showsMemberInspector { activities.append("member inspector visible") }
        return activities.isEmpty ? "ordinary workspace" : activities.joined(separator: ", ")
    }
}

nonisolated struct AppPerformanceSample: Codable, Identifiable, Sendable {
    let id: UInt64
    let capturedAt: Date
    let cpuPercent: Double
    let physicalMemoryBytes: UInt64
    let context: AppPerformanceContext
}

nonisolated struct AppPerformanceHotspot: Codable, Identifiable, Sendable {
    var id: String { name }

    let name: String
    let invocationCount: Int
    let totalDurationMilliseconds: Double
    let maximumDurationMilliseconds: Double
}

nonisolated struct AppPerformanceEvent: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case cpuSpike
        case slowOperation
    }

    let id: UInt64
    let capturedAt: Date
    let kind: Kind
    let value: Double
    let detail: String
    let context: AppPerformanceContext
}

nonisolated struct AppPerformanceSnapshot: Sendable {
    static let empty = AppPerformanceSnapshot(
        currentSample: nil,
        peakCPUPercent: 0,
        peakPhysicalMemoryBytes: 0,
        hotspots: [],
        recentEvents: []
    )

    let currentSample: AppPerformanceSample?
    let peakCPUPercent: Double
    let peakPhysicalMemoryBytes: UInt64
    let hotspots: [AppPerformanceHotspot]
    let recentEvents: [AppPerformanceEvent]
}

@Observable
final class AppPerformanceDiagnostics {
    static let shared = AppPerformanceDiagnostics()

    private(set) var snapshot = AppPerformanceSnapshot.empty

    @ObservationIgnored private var samplerTask: Task<Void, Never>?
    nonisolated private static let recorder = AppPerformanceRecorder()

    private init() {}

    func start() {
        guard samplerTask == nil else { return }
        samplerTask = Task { [weak self] in
            var previous = ProcessResourceReader.read()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let current = ProcessResourceReader.read()
                if let previous, let current {
                    Self.recorder.recordSample(
                        previous: previous,
                        current: current
                    )
                    snapshot = Self.recorder.snapshot()
                }
                previous = current
            }
        }
    }

    func setContext(_ context: AppPerformanceContext) {
        Self.recorder.setContext(context)
    }

    func reset() {
        Self.recorder.reset()
        snapshot = Self.recorder.snapshot()
    }

    func currentSnapshot() -> AppPerformanceSnapshot {
        let current = Self.recorder.snapshot()
        snapshot = current
        return current
    }

    func exportData() throws -> Data {
        try Self.recorder.exportData()
    }

    nonisolated static func recordOperation(
        _ name: StaticString,
        durationNanoseconds: UInt64,
        recordsEveryInvocation: Bool = false
    ) {
        // Naming the operation allocates a String, and every signposted
        // operation in the app now passes through here. Rejecting an
        // ordinary fast call on its duration alone keeps instrumentation
        // meant to find cost from becoming a cost of its own.
        guard recordsEveryInvocation
            || durationNanoseconds
            >= AppPerformanceRecorder.slowOperationThresholdNanoseconds
        else { return }
        recorder.recordOperation(
            String(describing: name),
            durationNanoseconds: durationNanoseconds,
            recordsEveryInvocation: recordsEveryInvocation
        )
    }
}

nonisolated private struct ProcessResourceReading: Sendable {
    let capturedAt: Date
    let uptimeNanoseconds: UInt64
    let consumedCPUSeconds: Double
    let physicalMemoryBytes: UInt64
}

nonisolated private enum ProcessResourceReader {
    static func read() -> ProcessResourceReading? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let userSeconds = Double(usage.ru_utime.tv_sec)
            + Double(usage.ru_utime.tv_usec) / 1_000_000
        let systemSeconds = Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_stime.tv_usec) / 1_000_000

        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return ProcessResourceReading(
            capturedAt: .now,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            consumedCPUSeconds: userSeconds + systemSeconds,
            physicalMemoryBytes: information.phys_footprint
        )
    }
}

nonisolated private final class AppPerformanceRecorder: @unchecked Sendable {
    private struct OperationAggregate {
        var invocationCount = 0
        var totalDurationNanoseconds: UInt64 = 0
        var maximumDurationNanoseconds: UInt64 = 0
    }

    private struct State {
        var nextID: UInt64 = 1
        var context = AppPerformanceContext.idle
        var samples: [AppPerformanceSample] = []
        var operations: [String: OperationAggregate] = [:]
        var events: [AppPerformanceEvent] = []
        var lastCPUEventAt: Date?
        var lastOperationEventAt: [String: Date] = [:]
    }

    private struct Export: Codable {
        let format: String
        let generatedAt: Date
        let samples: [AppPerformanceSample]
        let hotspots: [AppPerformanceHotspot]
        let events: [AppPerformanceEvent]
        let privacy: String
    }

    private static let sampleCapacity = 180
    private static let eventCapacity = 80
    static let slowOperationThresholdNanoseconds: UInt64 = 1_000_000
    private static let eventOperationThresholdNanoseconds: UInt64 = 16_000_000
    private static let cpuSpikeThreshold = 20.0

    private let lock = NSLock()
    private var state = State()

    func setContext(_ context: AppPerformanceContext) {
        withLock { $0.context = context }
    }

    func recordSample(
        previous: ProcessResourceReading,
        current: ProcessResourceReading
    ) {
        guard current.uptimeNanoseconds > previous.uptimeNanoseconds,
              current.consumedCPUSeconds >= previous.consumedCPUSeconds
        else { return }
        let wallSeconds = Double(
            current.uptimeNanoseconds - previous.uptimeNanoseconds
        ) / 1_000_000_000
        guard wallSeconds > 0 else { return }
        let cpuPercent = min(
            max(
                (current.consumedCPUSeconds - previous.consumedCPUSeconds)
                    / wallSeconds * 100,
                0
            ),
            Double(ProcessInfo.processInfo.processorCount) * 100
        )

        withLock { state in
            let sample = AppPerformanceSample(
                id: nextID(in: &state),
                capturedAt: current.capturedAt,
                cpuPercent: cpuPercent,
                physicalMemoryBytes: current.physicalMemoryBytes,
                context: state.context
            )
            state.samples.append(sample)
            trim(&state.samples, to: Self.sampleCapacity)

            guard cpuPercent >= Self.cpuSpikeThreshold,
                  state.lastCPUEventAt.map({
                      current.capturedAt.timeIntervalSince($0) >= 5
                  }) ?? true
            else { return }
            state.lastCPUEventAt = current.capturedAt
            state.events.append(
                AppPerformanceEvent(
                    id: nextID(in: &state),
                    capturedAt: current.capturedAt,
                    kind: .cpuSpike,
                    value: cpuPercent,
                    detail: "Process CPU",
                    context: state.context
                )
            )
            trim(&state.events, to: Self.eventCapacity)
        }
    }

    func recordOperation(
        _ name: String,
        durationNanoseconds: UInt64,
        recordsEveryInvocation: Bool
    ) {
        guard recordsEveryInvocation
            || durationNanoseconds >= Self.slowOperationThresholdNanoseconds
        else { return }

        withLock { state in
            var aggregate = state.operations[name, default: OperationAggregate()]
            aggregate.invocationCount += 1
            aggregate.totalDurationNanoseconds &+= durationNanoseconds
            aggregate.maximumDurationNanoseconds = max(
                aggregate.maximumDurationNanoseconds,
                durationNanoseconds
            )
            state.operations[name] = aggregate

            let now = Date.now
            guard durationNanoseconds >= Self.eventOperationThresholdNanoseconds,
                  state.lastOperationEventAt[name].map({
                      now.timeIntervalSince($0) >= 2
                  }) ?? true
            else { return }
            state.lastOperationEventAt[name] = now
            state.events.append(
                AppPerformanceEvent(
                    id: nextID(in: &state),
                    capturedAt: now,
                    kind: .slowOperation,
                    value: Self.milliseconds(durationNanoseconds),
                    detail: name,
                    context: state.context
                )
            )
            trim(&state.events, to: Self.eventCapacity)
        }
    }

    func snapshot() -> AppPerformanceSnapshot {
        withLock { state in
            AppPerformanceSnapshot(
                currentSample: state.samples.last,
                peakCPUPercent: state.samples.map(\.cpuPercent).max() ?? 0,
                peakPhysicalMemoryBytes:
                    state.samples.map(\.physicalMemoryBytes).max() ?? 0,
                hotspots: hotspots(in: state),
                recentEvents: Array(state.events.suffix(12).reversed())
            )
        }
    }

    func reset() {
        withLock { state in
            let context = state.context
            state = State()
            state.context = context
        }
    }

    func exportData() throws -> Data {
        let export = withLock { state in
            Export(
                format: "sakuracord-performance-v1",
                generatedAt: .now,
                samples: state.samples,
                hotspots: hotspots(in: state),
                events: state.events,
                privacy: "Contains only process resource totals, app feature-state booleans, and signpost names."
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    private func hotspots(in state: State) -> [AppPerformanceHotspot] {
        state.operations.map { name, aggregate in
            AppPerformanceHotspot(
                name: name,
                invocationCount: aggregate.invocationCount,
                totalDurationMilliseconds: Self.milliseconds(
                    aggregate.totalDurationNanoseconds
                ),
                maximumDurationMilliseconds: Self.milliseconds(
                    aggregate.maximumDurationNanoseconds
                )
            )
        }
        .sorted {
            if $0.totalDurationMilliseconds == $1.totalDurationMilliseconds {
                return $0.maximumDurationMilliseconds > $1.maximumDurationMilliseconds
            }
            return $0.totalDurationMilliseconds > $1.totalDurationMilliseconds
        }
        .prefix(12)
        .map { $0 }
    }

    private func nextID(in state: inout State) -> UInt64 {
        defer { state.nextID &+= 1 }
        return state.nextID
    }

    private func trim<Element>(_ values: inout [Element], to capacity: Int) {
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private func withLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
