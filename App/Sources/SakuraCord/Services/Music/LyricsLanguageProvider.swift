import Foundation

/// A language offered by the native lyrics menu.
///
/// Better Lyrics permits an arbitrary target code. A compact native menu is
/// more useful with the languages people actually choose, while the stored
/// code remains the ordinary BCP-47 value the service expects.
nonisolated struct LyricsTranslationLanguage: Hashable, Identifiable, Sendable {
    let code: String
    let name: String

    var id: String { code }

    static let supported: [Self] = [
        Self(code: "en", name: "English"),
        Self(code: "ar", name: "Arabic"),
        Self(code: "zh-CN", name: "Chinese, Simplified"),
        Self(code: "zh-TW", name: "Chinese, Traditional"),
        Self(code: "fr", name: "French"),
        Self(code: "de", name: "German"),
        Self(code: "hi", name: "Hindi"),
        Self(code: "id", name: "Indonesian"),
        Self(code: "it", name: "Italian"),
        Self(code: "ja", name: "Japanese"),
        Self(code: "ko", name: "Korean"),
        Self(code: "pt", name: "Portuguese"),
        Self(code: "ru", name: "Russian"),
        Self(code: "es", name: "Spanish"),
        Self(code: "tr", name: "Turkish"),
        Self(code: "uk", name: "Ukrainian")
    ]

    static func named(_ code: String) -> String {
        supported.first { $0.code == code }?.name ?? code
    }
}

/// Better Lyrics' batch request contract for Google's public translation
/// surface. It is deliberately kept as a pure request/parser boundary so a
/// response shape change fails as a missing decoration, never as missing
/// primary lyrics.
nonisolated enum LyricsLanguageRequest {
    struct Batch: Equatable, Sendable {
        var indices: [Int]
        var texts: [String]
        var url: URL
    }

    struct ParsedBatch: Equatable, Sendable {
        var texts: [String?]
        var detectedLanguage: String?
    }

    static let batchSeparator = "\n\n;\n\n"
    private static let maximumURLLength = 15_000
    private static let endpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!

    static func translationBatches(
        _ indexedLines: [(Int, String)],
        targetLanguage: String
    ) -> [Batch] {
        batches(indexedLines) { text in
            url(source: "auto", target: targetLanguage, text: text, romanizes: false)
        }
    }

    static func romanizationBatches(
        _ indexedLines: [(Int, String)],
        sourceLanguage: String
    ) -> [Batch] {
        batches(indexedLines) { text in
            url(
                source: sourceLanguage,
                target: "\(sourceLanguage)-Latn",
                text: text,
                romanizes: true
            )
        }
    }

    /// A single short request whose only purpose is the language the
    /// service reports having detected.
    static func detectionURL(text: String) -> URL {
        url(source: "auto", target: "en", text: text, romanizes: false)
    }

    static func detectedLanguage(_ body: Data) -> String? {
        parse(body, expectedCount: 1, romanization: false).detectedLanguage
    }

    static func parseTranslation(_ body: Data, expectedCount: Int) -> ParsedBatch {
        parse(body, expectedCount: expectedCount, romanization: false)
    }

    static func parseRomanization(_ body: Data, expectedCount: Int) -> ParsedBatch {
        parse(body, expectedCount: expectedCount, romanization: true)
    }

    private static func batches(
        _ indexedLines: [(Int, String)],
        makeURL: (String) -> URL
    ) -> [Batch] {
        var result: [Batch] = []
        var indices: [Int] = []
        var texts: [String] = []

        func finish() {
            guard !texts.isEmpty else { return }
            let combined = texts.joined(separator: batchSeparator)
            result.append(Batch(indices: indices, texts: texts, url: makeURL(combined)))
            indices = []
            texts = []
        }

        for (index, rawText) in indexedLines {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "♪" else { continue }
            let candidate = (texts + [text]).joined(separator: batchSeparator)
            if !texts.isEmpty, makeURL(candidate).absoluteString.utf8.count > maximumURLLength {
                finish()
            }
            indices.append(index)
            texts.append(text)
        }
        finish()
        return result
    }

    private static func url(
        source: String,
        target: String,
        text: String,
        romanizes: Bool
    ) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // Google's anonymous gtx client is aggressively rate-limited and
            // currently answers even short lyric requests with 429. The
            // dictionary Chrome client exposes the same response shape for
            // translation and romanization without that broken quota path.
            URLQueryItem(name: "client", value: "dict-chrome-ex"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t")
        ]
        if romanizes {
            components.queryItems?.append(URLQueryItem(name: "dt", value: "rm"))
        }
        components.queryItems?.append(URLQueryItem(name: "q", value: text))
        return components.url!
    }

    private static func parse(
        _ body: Data,
        expectedCount: Int,
        romanization: Bool
    ) -> ParsedBatch {
        guard expectedCount > 0,
              let root = try? JSONSerialization.jsonObject(with: body) as? [Any]
        else { return ParsedBatch(texts: Array(repeating: nil, count: expectedCount), detectedLanguage: nil) }

        let detectedLanguage = root.indices.contains(2) ? root[2] as? String : nil
        let parts = root.first as? [Any] ?? []
        let combined = parts.compactMap { rawPart -> String? in
            guard let part = rawPart as? [Any] else { return nil }
            if romanization {
                if part.indices.contains(3), let text = part[3] as? String { return text }
                if part.indices.contains(2), let text = part[2] as? String { return text }
                return nil
            }
            return part.first as? String
        }.joined()

        let split = split(combined, expectedCount: expectedCount)
        return ParsedBatch(texts: split, detectedLanguage: detectedLanguage)
    }

    private static func split(_ text: String, expectedCount: Int) -> [String?] {
        let candidates: [[String]] = [
            text.components(separatedBy: batchSeparator),
            text.split(separator: ";", omittingEmptySubsequences: true).map(String.init),
            text.split(whereSeparator: \.isNewline).map(String.init)
        ]
        for candidate in candidates where candidate.count == expectedCount {
            return candidate.map { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        if expectedCount == 1 {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return [trimmed.isEmpty ? nil : trimmed]
        }
        return Array(repeating: nil, count: expectedCount)
    }
}

/// Fetches a decoration request from the music page rather than from the app.
///
/// Google's public translation endpoint answers a native client 429 no
/// matter which host, header or user agent it is asked with, while the exact
/// same request from a page succeeds. The music page is already open to keep
/// playback alive, so these requests are made from there. Returning nil for
/// every failure keeps a decoration that could not be fetched from ever
/// affecting the primary lyric.
typealias LyricsPageFetch = @Sendable (URL) async -> Data?

/// Adds only the language decorations a lyric source did not already carry.
/// Results are held in memory like the lyrics themselves; no song text is
/// persisted to disk.
actor LyricsLanguageService {
    private struct TranslationResult: Sendable {
        var sourceLanguage: String?
        var text: String
    }

    private var fetch: LyricsPageFetch?
    private var romanizationCache: [String: String] = [:]
    private var translationCache: [String: TranslationResult] = [:]

    func enrich(
        _ source: TimedLyrics,
        romanizes: Bool,
        translationLanguage: String?,
        fetch: @escaping LyricsPageFetch
    ) async -> TimedLyrics {
        self.fetch = fetch
        var enriched = source
        if romanizes {
            await addRomanization(to: &enriched)
        }
        if let translationLanguage {
            await addTranslation(to: &enriched, targetLanguage: translationLanguage)
        }
        return enriched
    }

    private func addRomanization(to lyrics: inout TimedLyrics) async {
        var missing: [(Int, String)] = []
        for index in lyrics.lines.indices {
            let line = lyrics.lines[index]
            guard line.romanization == nil,
                  Self.containsNonLatinLetters(line.text)
            else { continue }
            if let cached = romanizationCache[line.text] {
                lyrics.lines[index].romanization = cached
            } else {
                missing.append((index, line.text))
            }
        }
        guard !missing.isEmpty,
              let sourceLanguage = await romanizationLanguage(
                  declared: lyrics.language,
                  sample: missing.first?.1
              )
        else { return }

        for batch in LyricsLanguageRequest.romanizationBatches(
            missing,
            sourceLanguage: sourceLanguage
        ) {
            guard !Task.isCancelled,
                  let body = await body(for: batch.url)
            else { return }
            let parsed = LyricsLanguageRequest.parseRomanization(
                body,
                expectedCount: batch.texts.count
            )
            for offset in batch.texts.indices {
                guard let result = parsed.texts[offset],
                      !Self.sameText(result, batch.texts[offset])
                else { continue }
                romanizationCache[batch.texts[offset]] = result
                lyrics.lines[batch.indices[offset]].romanization = result
            }
        }
    }

    private func addTranslation(
        to lyrics: inout TimedLyrics,
        targetLanguage: String
    ) async {
        if Self.languageCodesMatch(lyrics.language, targetLanguage) { return }

        var missing: [(Int, String)] = []
        for index in lyrics.lines.indices {
            let line = lyrics.lines[index]
            guard line.translation(for: targetLanguage) == nil,
                  !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let cacheKey = "\(targetLanguage)_\(line.text)"
            if let cached = translationCache[cacheKey] {
                lyrics.lines[index].translations[targetLanguage] = cached.text
            } else {
                missing.append((index, line.text))
            }
        }
        guard !missing.isEmpty else { return }

        for batch in LyricsLanguageRequest.translationBatches(
            missing,
            targetLanguage: targetLanguage
        ) {
            guard !Task.isCancelled,
                  let body = await body(for: batch.url)
            else { return }
            let parsed = LyricsLanguageRequest.parseTranslation(
                body,
                expectedCount: batch.texts.count
            )
            for offset in batch.texts.indices {
                guard let result = parsed.texts[offset],
                      !Self.sameText(result, batch.texts[offset])
                else { continue }
                let key = "\(targetLanguage)_\(batch.texts[offset])"
                translationCache[key] = TranslationResult(
                    sourceLanguage: parsed.detectedLanguage,
                    text: result
                )
                lyrics.lines[batch.indices[offset]].translations[targetLanguage] = result
            }
        }
    }

    /// The language to transliterate from.
    ///
    /// Asking for `auto-Latn` does not transliterate: the service quietly
    /// answers with an English translation instead, which would put a
    /// translation where the romanization belongs and then be discarded for
    /// arriving in the wrong shape. Most lyric sources declare no language
    /// at all, so one is detected before asking.
    private func romanizationLanguage(
        declared: String?,
        sample: String?
    ) async -> String? {
        if let declared, let base = Self.transliterableBase(of: declared) {
            return base
        }
        guard let sample,
              let body = await body(for: LyricsLanguageRequest.detectionURL(text: sample)),
              let detected = LyricsLanguageRequest.detectedLanguage(body)
        else { return nil }
        return Self.transliterableBase(of: detected)
    }

    private func body(for url: URL) async -> Data? {
        guard let fetch else { return nil }
        return await fetch(url)
    }

    /// The bare language code, when it is one the service transliterates.
    ///
    /// The bare code is what the `-Latn` target is built from: a regional
    /// code has no transliteration of its own, so `zh-CN` has to ask as
    /// `zh` to be answered at all.
    static func transliterableBase(of language: String) -> String? {
        let supported = Set([
            "ar", "bn", "el", "fa", "gu", "he", "hi", "ja", "ka", "km",
            "kn", "ko", "lo", "ml", "mr", "my", "pa", "ru", "si", "ta",
            "te", "th", "ur", "zh"
        ])
        let base = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
        return supported.contains(base) ? base : nil
    }

    private static func languageCodesMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let left = lhs.lowercased()
        let right = rhs.lowercased()
        return left == right
            || left.split(separator: "-").first == right.split(separator: "-").first
    }

    private static func containsNonLatinLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar.properties.generalCategory == .uppercaseLetter
                || scalar.properties.generalCategory == .lowercaseLetter
                || scalar.properties.generalCategory == .titlecaseLetter
                || scalar.properties.generalCategory == .otherLetter
            else { return false }
            let value = scalar.value
            let isLatin = (0x0041 ... 0x007A).contains(value)
                || (0x00C0 ... 0x024F).contains(value)
                || (0x1E00 ... 0x1EFF).contains(value)
                || (0xAB30 ... 0xAB6F).contains(value)
            return !isLatin
        }
    }

    private static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ text: String) -> String {
            text.lowercased().unicodeScalars.filter {
                !$0.properties.generalCategory.isPunctuation
                    && !$0.properties.isWhitespace
            }.map(String.init).joined()
        }
        return normalized(lhs) == normalized(rhs)
    }
}

private nonisolated extension Unicode.GeneralCategory {
    var isPunctuation: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .closePunctuation,
             .finalPunctuation, .initialPunctuation, .openPunctuation,
             .otherPunctuation:
            true
        default:
            false
        }
    }
}
