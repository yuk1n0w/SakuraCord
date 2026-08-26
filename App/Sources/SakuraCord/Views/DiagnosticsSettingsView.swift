import DiscordProtocol
import SwiftUI

struct DiagnosticsSettingsView: View {
    @AppStorage("saveAPIDiagnosticsToDisk") private var savesAPIDiagnosticsToDisk = false
    @State private var apiDiagnosticEntryCount = 0
    @State private var apiDiagnosticStatus: String?
    @State private var capturesDetailedAPIPayloads =
        DiscordAPIDiagnosticStore.shared.capturesPayloadDetails
    @State private var performanceSnapshot = AppPerformanceSnapshot.empty
    @State private var performanceDiagnosticStatus: String?

    var body: some View {
        Form {
            performanceSection
            apiSection
        }
        .formStyle(.grouped)
        .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        .task {
            refreshAPIDiagnosticCount()
            while !Task.isCancelled {
                performanceSnapshot =
                    AppPerformanceDiagnostics.shared.currentSnapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var performanceSection: some View {
        Section("Performance") {
            LabeledContent("Process CPU") {
                Text(currentCPUDescription)
                    .monospacedDigit()
            }
            LabeledContent("Physical memory") {
                Text(currentMemoryDescription)
                    .monospacedDigit()
            }

            if performanceSnapshot.hotspots.isEmpty {
                Text(
                    "No slow signposted operations have been recorded yet. CPU and memory sampling continues once per second."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Slow operation totals") {
                    ForEach(performanceSnapshot.hotspots) { hotspot in
                        LabeledContent(hotspot.name) {
                            Text(hotspotDescription(hotspot))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            if !performanceSnapshot.recentEvents.isEmpty {
                DisclosureGroup("Recent spikes") {
                    ForEach(performanceSnapshot.recentEvents) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(performanceEventTitle(event))
                                .font(.callout.weight(.medium))
                            Text(event.context.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Text(
                "Keeps three minutes of one-second process samples and a bounded list of slow signposted operations in memory. "
                    + "Exports contain feature-state booleans only—never messages, song titles, usernames, credentials, cookies, or URLs."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Export Performance Log…") {
                    Task { await exportPerformanceDiagnostics() }
                }
                Button("Reset Performance Log") {
                    AppPerformanceDiagnostics.shared.reset()
                    performanceSnapshot =
                        AppPerformanceDiagnostics.shared.currentSnapshot()
                    performanceDiagnosticStatus = "Performance history was reset."
                }
            }

            if let performanceDiagnosticStatus {
                Text(performanceDiagnosticStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var apiSection: some View {
        Section("Discord API logs") {
            Toggle(
                "Capture detailed sanitized payloads",
                isOn: $capturesDetailedAPIPayloads
            )
            .onChange(of: capturesDetailedAPIPayloads) { _, captures in
                DiscordAPIDiagnosticStore.shared.capturesPayloadDetails = captures
            }

            Toggle(
                "Save diagnostics to disk",
                isOn: $savesAPIDiagnosticsToDisk
            )
            .onChange(of: savesAPIDiagnosticsToDisk) { _, savesToDisk in
                updateDiskLogging(savesToDisk)
            }

            LabeledContent("Retained entries") {
                Text(apiDiagnosticEntryCount.formatted())
                    .monospacedDigit()
            }

            Text(
                "Exports retained Discord REST, attachment, authentication, and Gateway request/response metadata from this app session. "
                    + "Detailed sanitized payload capture is off by default because processing large responses increases CPU and energy use. "
                    + "Message text, names, usernames, profile text, credentials, cookies, challenge data, filenames, and URLs are discarded before logging. "
                    + "IDs, nonces, request IDs, and rate-limit bucket IDs are always redacted. "
                    + "Disk capture is off by default and keeps at most four private JSON Lines session files of up to 64 MiB each in Application Support/SakuraCord/Diagnostics."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Export API Logs…") {
                    Task { await exportAPILogs() }
                }
                Button("Clear Logs", role: .destructive) {
                    clearAPILogs()
                }
            }

            if let apiDiagnosticStatus {
                Text(apiDiagnosticStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var currentCPUDescription: String {
        guard let current = performanceSnapshot.currentSample else {
            return "Measuring…"
        }
        return "\(oneDecimal(current.cpuPercent))% current · "
            + "\(oneDecimal(performanceSnapshot.peakCPUPercent))% peak"
    }

    private var currentMemoryDescription: String {
        guard let current = performanceSnapshot.currentSample else {
            return "Measuring…"
        }
        let currentMemory = ByteCountFormatter.string(
            fromByteCount: Int64(current.physicalMemoryBytes),
            countStyle: .memory
        )
        let peakMemory = ByteCountFormatter.string(
            fromByteCount: Int64(performanceSnapshot.peakPhysicalMemoryBytes),
            countStyle: .memory
        )
        return "\(currentMemory) current · \(peakMemory) peak"
    }

    private func hotspotDescription(_ hotspot: AppPerformanceHotspot) -> String {
        "\(oneDecimal(hotspot.totalDurationMilliseconds)) ms total · "
            + "\(oneDecimal(hotspot.maximumDurationMilliseconds)) ms max · "
            + "\(hotspot.invocationCount.formatted())×"
    }

    private func performanceEventTitle(_ event: AppPerformanceEvent) -> String {
        switch event.kind {
        case .cpuSpike:
            return "CPU \(oneDecimal(event.value))%"
        case .slowOperation:
            return "\(event.detail) · \(oneDecimal(event.value)) ms"
        }
    }

    private func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func exportPerformanceDiagnostics() async {
        do {
            guard let url = try await PerformanceDiagnosticExporter.export() else {
                performanceDiagnosticStatus = "Export cancelled."
                return
            }
            performanceDiagnosticStatus = "Exported \(url.lastPathComponent)"
        } catch {
            performanceDiagnosticStatus =
                "Export failed: \(error.localizedDescription)"
        }
    }

    private func refreshAPIDiagnosticCount() {
        apiDiagnosticEntryCount =
            DiscordAPIDiagnosticStore.shared.retainedEntryCount
    }

    private func clearAPILogs() {
        let store = DiscordAPIDiagnosticStore.shared
        let wasSavingToDisk = store.savesDiagnosticsToDisk
        do {
            try store.clearMemoryAndDisk()
            apiDiagnosticEntryCount = 0
            if wasSavingToDisk, let fileURL = store.currentDiskLogURL {
                apiDiagnosticStatus =
                    "Retained and saved API logs were cleared. Saving continues to \(fileURL.lastPathComponent)."
            } else {
                apiDiagnosticStatus = "Retained and saved API logs were cleared."
            }
        } catch {
            savesAPIDiagnosticsToDisk = store.savesDiagnosticsToDisk
            apiDiagnosticStatus =
                "Could not clear every saved API log: \(error.localizedDescription)"
        }
    }

    private func updateDiskLogging(_ savesToDisk: Bool) {
        do {
            try DiscordAPIDiagnosticStore.shared
                .setSavesDiagnosticsToDisk(savesToDisk)
            if savesToDisk,
               let fileURL = DiscordAPIDiagnosticStore.shared.currentDiskLogURL
            {
                apiDiagnosticStatus = "Saving diagnostics to \(fileURL.lastPathComponent)"
            } else {
                apiDiagnosticStatus = "Diagnostics are no longer being saved to disk."
            }
        } catch {
            savesAPIDiagnosticsToDisk = false
            apiDiagnosticStatus =
                "Could not save diagnostics to disk: \(error.localizedDescription)"
        }
    }

    private func exportAPILogs() async {
        do {
            guard let url = try await DiscordAPILogExporter.export() else {
                apiDiagnosticStatus = "Export cancelled."
                refreshAPIDiagnosticCount()
                return
            }
            apiDiagnosticStatus = "Exported \(url.lastPathComponent)"
        } catch {
            apiDiagnosticStatus = "Export failed: \(error.localizedDescription)"
        }
        refreshAPIDiagnosticCount()
    }
}
