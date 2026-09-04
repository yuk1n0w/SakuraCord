import SakuraCordModels
import SwiftUI

enum ComposerBuiltInCommand {
    static let gifID = "dev.sakuracord.builtin.gif"
    static let translateID = "dev.sakuracord.builtin.translate"
    static let application = ApplicationCommandApplication(
        id: "dev.sakuracord",
        name: "SakuraCord",
        description: "Native SakuraCord actions"
    )
    static let gif = ApplicationCommand(
        id: gifID,
        rootCommandID: gifID,
        applicationID: application.id,
        version: "1",
        name: "gif",
        description: "Browse and send a GIF",
        application: application
    )
    static let translate = ApplicationCommand(
        id: translateID,
        rootCommandID: translateID,
        applicationID: application.id,
        version: "1",
        name: "translate",
        description: "Toggle Japanese-to-English translation for this chat",
        application: application
    )

    static func isGIF(_ command: ApplicationCommand) -> Bool {
        command.id == gifID
    }

    static func isTranslate(_ command: ApplicationCommand) -> Bool {
        command.id == translateID
    }
}

struct AutomaticTranslationComposerHeader: View {
    let disable: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "character.bubble.fill")
                .foregroundStyle(.tint)
            Text("Japanese → English")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Turn off automatic translation", systemImage: "xmark") {
                disable()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .help("Turn off automatic translation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
