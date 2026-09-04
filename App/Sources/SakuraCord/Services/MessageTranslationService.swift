import Foundation
import Observation

nonisolated struct MessageTranslationGlossaryEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var english: String
    var japanese: String
}

nonisolated enum MessageTranslationDirection: Equatable, Sendable {
    case incoming
    case outgoing

    nonisolated var sourceLanguage: String? {
        switch self {
        case .incoming: nil
        case .outgoing: "en"
        }
    }

    nonisolated var targetLanguage: String {
        switch self {
        case .incoming: "en"
        case .outgoing: "ja"
        }
    }
}

nonisolated struct MessageTranslationPresentation: Identifiable, Sendable {
    let id: UUID
    let direction: MessageTranslationDirection
    let sourceText: String
    var translatedText: String?
    var detectedSourceLanguage: String?
    var errorMessage: String?

    var isLoading: Bool {
        translatedText == nil && errorMessage == nil
    }
}

nonisolated struct GoogleMessageTranslationResult: Equatable, Sendable {
    let text: String
    let detectedSourceLanguage: String?
}

nonisolated enum GoogleMessageTranslationError: LocalizedError {
    case invalidResponse
    case service(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Google returned an unreadable translation response."
        case let .service(status):
            "Google Translation failed with HTTP \(status)."
        }
    }
}

actor GoogleMessageTranslationClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            self.session = URLSession(configuration: .ephemeral)
        }
    }

    func translate(
        _ text: String,
        direction: MessageTranslationDirection,
        glossary: [MessageTranslationGlossaryEntry]
    ) async throws -> GoogleMessageTranslationResult {
        let protected = MessageTranslationGlossary.protect(
            text,
            direction: direction,
            entries: glossary
        )
        let url = LyricsLanguageRequest.translationURL(
            text: protected.text,
            sourceLanguage: direction.sourceLanguage,
            targetLanguage: direction.targetLanguage
        )
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleMessageTranslationError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw GoogleMessageTranslationError.service(http.statusCode)
        }
        let parsed = LyricsLanguageRequest.parseTranslation(data, expectedCount: 1)
        guard let translatedText = parsed.texts.first ?? nil else {
            throw GoogleMessageTranslationError.invalidResponse
        }
        return GoogleMessageTranslationResult(
            text: MessageTranslationGlossary.restore(
                translatedText,
                replacements: protected.replacements
            ),
            detectedSourceLanguage: parsed.detectedLanguage
        )
    }
}

nonisolated enum MessageTranslationGlossary {
    struct ProtectedText: Equatable {
        let text: String
        let replacements: [String: String]
    }

    nonisolated static func protect(
        _ text: String,
        direction: MessageTranslationDirection,
        entries: [MessageTranslationGlossaryEntry]
    ) -> ProtectedText {
        let pairs = entries.compactMap { entry -> (String, String)? in
            let pair = switch direction {
            case .incoming:
                (entry.japanese, entry.english)
            case .outgoing:
                (entry.english, entry.japanese)
            }
            guard !pair.0.isEmpty, !pair.1.isEmpty else { return nil }
            return pair
        }.sorted { $0.0.count > $1.0.count }

        var protectedText = text
        var replacements: [String: String] = [:]
        for pair in pairs {
            guard protectedText.range(of: pair.0, options: [.caseInsensitive]) != nil else {
                continue
            }
            let token = "SakuraCordTerm\(replacements.count)X"
            protectedText = protectedText.replacingOccurrences(
                of: pair.0,
                with: token,
                options: [.caseInsensitive]
            )
            replacements[token] = pair.1
        }
        return ProtectedText(text: protectedText, replacements: replacements)
    }

    nonisolated static func restore(
        _ text: String,
        replacements: [String: String]
    ) -> String {
        replacements.reduce(text) { value, replacement in
            value.replacingOccurrences(
                of: replacement.key,
                with: replacement.value,
                options: [.caseInsensitive]
            )
        }
    }
}

@MainActor
@Observable
final class MessageTranslationController {
    private static let glossaryDefaultsKey = "dev.sakuracord.message-translation.glossary"

    var presentation: MessageTranslationPresentation?
    private(set) var glossary: [MessageTranslationGlossaryEntry]

    @ObservationIgnored private let client: GoogleMessageTranslationClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var applyTranslation: ((String) -> Void)?

    init(
        client: GoogleMessageTranslationClient = GoogleMessageTranslationClient(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.glossaryDefaultsKey),
           let values = try? JSONDecoder().decode([MessageTranslationGlossaryEntry].self, from: data)
        {
            glossary = values
        } else {
            glossary = []
        }
    }

    func addGlossaryEntry(english: String, japanese: String) {
        let english = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let japanese = japanese.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !english.isEmpty, !japanese.isEmpty else { return }
        glossary.append(.init(english: english, japanese: japanese))
        persistGlossary()
    }

    func removeGlossaryEntry(_ id: UUID) {
        glossary.removeAll { $0.id == id }
        persistGlossary()
    }

    func presentIncoming(_ text: String) {
        present(text, direction: .incoming, apply: nil)
    }

    func presentOutgoing(_ text: String, apply: @escaping (String) -> Void) {
        present(text, direction: .outgoing, apply: apply)
    }

    func updateTranslatedText(_ text: String) {
        presentation?.translatedText = text
    }

    func useTranslation() {
        guard let text = presentation?.translatedText else { return }
        applyTranslation?(text)
        dismiss()
    }

    func dismiss() {
        translationTask?.cancel()
        translationTask = nil
        applyTranslation = nil
        presentation = nil
    }

    private func present(
        _ text: String,
        direction: MessageTranslationDirection,
        apply: ((String) -> Void)?
    ) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        translationTask?.cancel()
        let id = UUID()
        presentation = MessageTranslationPresentation(
            id: id,
            direction: direction,
            sourceText: text
        )
        applyTranslation = apply
        let glossary = glossary
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.translate(
                    text,
                    direction: direction,
                    glossary: glossary
                )
                guard !Task.isCancelled, presentation?.id == id else { return }
                presentation?.translatedText = result.text
                presentation?.detectedSourceLanguage = result.detectedSourceLanguage
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, presentation?.id == id else { return }
                presentation?.errorMessage = error.localizedDescription
            }
        }
    }

    private func persistGlossary() {
        guard let data = try? JSONEncoder().encode(glossary) else { return }
        defaults.set(data, forKey: Self.glossaryDefaultsKey)
    }
}
