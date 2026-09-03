import SwiftUI

struct PerformanceDiagnosticsSection: View {
    @State private var snapshot = AppPerformanceSnapshot.empty
    @State private var exportStatus: String?

    var body: some View {
        Section("Performance") {
            LabeledContent("Process CPU") {
                Text(cpuDescription)
                    .monospacedDigit()
            }
            LabeledContent("Physical memory") {
                Text(memoryDescription)
                    .monospacedDigit()
            }

            if snapshot.hotspots.isEmpty {
                Text(
                    "No slow signposted operations have been recorded yet. "
                        + "CPU and memory sampling continues once per second."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Slow operation totals") {
                    ForEach(snapshot.hotspots) { hotspot in
                        LabeledContent(hotspot.name) {
                            Text(hotspotDescription(hotspot))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            if !snapshot.recentEvents.isEmpty {
                DisclosureGroup("Recent spikes") {
                    ForEach(snapshot.recentEvents) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(eventTitle(event))
                                .font(.callout.weight(.medium))
                            Text(event.context.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Text(
                "Keeps three minutes of one-second process samples and a bounded list of slow "
                    + "operations in memory. Exports contain feature-state booleans only—never "
                    + "messages, song titles, usernames, credentials, cookies, or URLs."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Export Performance Log…") {
                    Task { await exportDiagnostics() }
                }
                Button("Reset Performance Log") {
                    AppPerformanceDiagnostics.shared.reset()
                    snapshot = AppPerformanceDiagnostics.shared.currentSnapshot()
                    exportStatus = "Performance history was reset."
                }
            }

            if let exportStatus {
                Text(exportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .task {
            while !Task.isCancelled {
                snapshot = AppPerformanceDiagnostics.shared.currentSnapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var cpuDescription: String {
        guard let current = snapshot.currentSample else { return "Measuring…" }
        return "\(oneDecimal(current.cpuPercent))% current · "
            + "\(oneDecimal(snapshot.peakCPUPercent))% peak"
    }

    private var memoryDescription: String {
        guard let current = snapshot.currentSample else { return "Measuring…" }
        let currentMemory = ByteCountFormatter.string(
            fromByteCount: Int64(current.physicalMemoryBytes),
            countStyle: .memory
        )
        let peakMemory = ByteCountFormatter.string(
            fromByteCount: Int64(snapshot.peakPhysicalMemoryBytes),
            countStyle: .memory
        )
        return "\(currentMemory) current · \(peakMemory) peak"
    }

    private func hotspotDescription(_ hotspot: AppPerformanceHotspot) -> String {
        "\(oneDecimal(hotspot.totalDurationMilliseconds)) ms total · "
            + "\(oneDecimal(hotspot.maximumDurationMilliseconds)) ms max · "
            + "\(hotspot.invocationCount.formatted())×"
    }

    private func eventTitle(_ event: AppPerformanceEvent) -> String {
        switch event.kind {
        case .cpuSpike:
            "CPU \(oneDecimal(event.value))%"
        case .slowOperation:
            "\(event.detail) · \(oneDecimal(event.value)) ms"
        }
    }

    private func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func exportDiagnostics() async {
        do {
            guard let url = try await PerformanceDiagnosticExporter.export() else {
                exportStatus = "Export cancelled."
                return
            }
            exportStatus = "Exported \(url.lastPathComponent)"
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }
}
