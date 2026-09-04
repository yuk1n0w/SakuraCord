import AppKit
import SwiftUI

struct MessageTranslationView: View {
    let controller: MessageTranslationController

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(
                    controller.presentation?.direction == .outgoing
                        ? "Translate to Japanese"
                        : "Translate to English",
                    systemImage: "character.bubble"
                )
                .font(.headline)
                Spacer()
                Button("Done", action: controller.dismiss)
                    .buttonStyle(.glass)
            }

            if let presentation = controller.presentation {
                translationCard("Original", text: presentation.sourceText)

                if presentation.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Google is translating…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 92)
                } else if let error = presentation.errorMessage {
                    ContentUnavailableView(
                        "Translation unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else if presentation.direction == .outgoing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Japanese draft")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: Binding(
                            get: { controller.presentation?.translatedText ?? "" },
                            set: controller.updateTranslatedText
                        ))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 110)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                    }
                } else if let translated = presentation.translatedText {
                    translationCard("English", text: translated)
                }

                HStack {
                    if let language = presentation.detectedSourceLanguage {
                        Text("Detected \(language.uppercased())")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let translated = presentation.translatedText {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(translated, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        if presentation.direction == .outgoing {
                            Button("Use in Composer", action: controller.useTranslation)
                                .buttonStyle(.glassProminent)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 390)
        .presentationBackground(.ultraThinMaterial)
    }

    private func translationCard(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 72, maxHeight: 120)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
