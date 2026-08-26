import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum PerformanceDiagnosticExporter {
    static func export() async throws -> URL? {
        let data = try AppPerformanceDiagnostics.shared.exportData()
        let panel = NSSavePanel()
        panel.title = "Export Performance Diagnostics"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue =
            "SakuraCord Performance \(fileTimestamp()).json"

        let response = await DiscordAPILogExporter.present(
            panel,
            attachedTo: NSApp.keyWindow ?? NSApp.mainWindow
        )
        guard response == .OK, let url = panel.url else { return nil }
        try await ExactDestinationFileWriter.write(data, to: url)
        return url
    }

    private static func fileTimestamp(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: now)
    }
}
