import Foundation

/// Turns a lyric source's payload into timed lines.
///
/// Three formats arrive from the same endpoint and only one of them is
/// structured, so parsing decides how much can be shown rather than whether
/// anything can: an unparseable timing degrades that line to the plain text
/// it still is, and a payload with no timings at all is still worth showing
/// unlit.
nonisolated enum LyricsParser {
    static func parse(_ source: String, format: String) -> TimedLyrics {
        switch format.lowercased() {
        case "lrc": lrc(source)
        case "ttml": ttml(source)
        default: plain(source)
        }
    }

    /// `[mm:ss.cc]` stamps, one or more per line.
    ///
    /// A stamp with no words is a gap the writer marked deliberately - an
    /// instrumental break - and it is kept as an empty line so the display
    /// can hold on it rather than jumping ahead to the next sung line.
    static func lrc(_ source: String) -> TimedLyrics {
        var lines: [LyricLine] = []
        let offset = lrcOffset(in: source)
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            var searchStart = line.startIndex
            var stamps: [TimeInterval] = []
            // Stamps sit only at the head of a line; the first non-stamp
            // character begins the words.
            while let range = line.range(
                of: #"^\[(\d+):(\d+(?:[.:]\d+)?)\]"#,
                options: .regularExpression,
                range: searchStart ..< line.endIndex
            ), range.lowerBound == searchStart {
                if let seconds = stampSeconds(String(line[range])) {
                    stamps.append(seconds - offset)
                }
                searchStart = range.upperBound
            }
            guard !stamps.isEmpty else { continue }
            let lyric = String(line[searchStart...])
            let words = enhancedLRCWords(in: lyric, offset: offset)
            let text = lyric
                .replacingOccurrences(
                    of: #"<\d+:\d+(?:[.:]\d+)?>"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                lines.append(
                    LyricLine(
                        id: lines.count,
                        start: stamp,
                        text: text,
                        words: words
                    )
                )
            }
        }
        guard !lines.isEmpty else { return plain(source) }
        return TimedLyrics(
            lines: ordered(lines),
            synchronisation: .line
        )
    }

    /// TTML carries per-word timing in the spans inside each `<p>`.
    ///
    /// Those spans are the only source of word-level sync available: a
    /// line-timed source knows when a line starts and nothing finer. When a
    /// paragraph has no timed spans the line still stands on its own start,
    /// so a mixed document degrades line by line rather than all at once.
    static func ttml(_ source: String) -> TimedLyrics {
        let delegate = TTMLParagraphCollector()
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = delegate
        guard parser.parse(), !delegate.paragraphs.isEmpty else {
            return plain(source)
        }
        let lines = delegate.paragraphs.enumerated().map { index, paragraph in
            let translations = paragraph.key.flatMap {
                delegate.translations[$0]
            } ?? [:]
            let romanization = paragraph.key.flatMap {
                delegate.romanizations[$0]
            }
            let romanizedWords: [LyricWord]
            if let words = romanization?.words,
               let first = words.first {
                let expectedStart = paragraph.words.first?.start ?? paragraph.start
                let offset = expectedStart - first.start
                romanizedWords = words.map {
                    LyricWord(
                        text: $0.text,
                        start: $0.start + offset,
                        end: $0.end + offset
                    )
                }
            } else {
                romanizedWords = []
            }
            return LyricLine(
                id: index,
                start: paragraph.start,
                end: paragraph.end,
                text: paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines),
                words: paragraph.words,
                translations: translations,
                romanization: romanization?.text,
                romanizedWords: romanizedWords
            )
        }
        return TimedLyrics(
            lines: ordered(lines),
            synchronisation: .line,
            language: delegate.language
        )
    }

    /// Words with no timings. Still worth showing: an unsynced lyric read
    /// alongside the music beats no lyric at all.
    static func plain(_ source: String) -> TimedLyrics {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .enumerated()
            .map { LyricLine(id: $0.offset, start: 0, text: $0.element) }
        let hasWords = lines.contains { !$0.text.isEmpty }
        guard hasWords else { return .empty }
        return TimedLyrics(lines: lines, synchronisation: .none)
    }

    /// Sources are not reliably ordered, and a binary search over the lines
    /// assumes they are.
    /// How long a silence has to run before it is worth marking. Short
    /// gaps are the ordinary spacing between sung lines; a long one is an
    /// intro, a solo or an outro, and leaving it blank reads as lyrics that
    /// failed to load rather than as music playing.
    private static let instrumentalGap: TimeInterval = 9

    /// How long a line is assumed to take to sing, for deciding where a
    /// break begins. A line-timed source records when a line starts and
    /// never when it ends, so the break cannot begin at the true end of the
    /// singing - only at a plausible one.
    private static let assumedLineDuration: TimeInterval = 4

    /// Marks the silences between sung lines.
    ///
    /// A break carries no words: it is drawn as a note, and lighting it in
    /// turn is what keeps the panel moving through a solo instead of
    /// sitting on the last line sung until the next one arrives.
    private static func marked(_ lines: [LyricLine]) -> [LyricLine] {
        guard let first = lines.first else { return lines }
        var marked: [LyricLine] = []

        // An intro is a break before anything has been sung.
        if first.start >= instrumentalGap {
            marked.append(LyricLine(id: 0, start: 0, text: ""))
        }

        for (index, line) in lines.enumerated() {
            marked.append(line)
            guard index + 1 < lines.count else { continue }
            let next = lines[index + 1]
            let sungEnd = line.end > line.start
                ? line.end
                : line.start + assumedLineDuration
            let silence = next.start - sungEnd
            guard silence >= instrumentalGap else { continue }
            marked.append(
                LyricLine(id: 0, start: sungEnd, text: "")
            )
        }
        return marked
    }

    private static func ordered(_ lines: [LyricLine]) -> [LyricLine] {
        let sorted = marked(lines.sorted { $0.start < $1.start })
        return sorted.enumerated().map { index, line in
            // A line runs until the next one starts. The last line has no
            // successor, so it is given a plausible span rather than none:
            // zero would make it read as finished the instant it began.
            let next = index + 1 < sorted.count ? sorted[index + 1].start : line.start + 5
            let lineEnd = line.end > line.start
                ? min(line.end, max(next, line.start))
                : max(next, line.start)
            let words = line.words.enumerated().map { wordIndex, word in
                let followingStart = wordIndex + 1 < line.words.count
                    ? line.words[wordIndex + 1].start
                    : lineEnd
                return LyricWord(
                    text: word.text,
                    start: word.start,
                    end: word.end > word.start ? word.end : max(followingStart, word.start)
                )
            }
            let romanizedWords = line.romanizedWords.enumerated().map { wordIndex, word in
                let followingStart = wordIndex + 1 < line.romanizedWords.count
                    ? line.romanizedWords[wordIndex + 1].start
                    : lineEnd
                return LyricWord(
                    text: word.text,
                    start: word.start,
                    end: word.end > word.start ? word.end : max(followingStart, word.start)
                )
            }
            return LyricLine(
                id: index,
                start: line.start,
                end: lineEnd,
                text: line.text,
                words: words,
                translations: line.translations,
                romanization: line.romanization,
                romanizedWords: romanizedWords
            )
        }
    }

    /// Enhanced LRC puts a timestamp before each word or syllable:
    /// `<00:10.00>Hello <00:10.50>world`. Better Lyrics treats the text
    /// between two timestamps as the timed part, including its original
    /// whitespace. Keeping that spacing is important both for wrapping and
    /// for languages whose syllable boundaries are not word boundaries.
    private static func enhancedLRCWords(
        in lyric: String,
        offset: TimeInterval
    ) -> [LyricWord] {
        let pattern = #"<(\d+:\d+(?:[.:]\d+)?)>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(lyric.startIndex ..< lyric.endIndex, in: lyric)
        let matches = expression.matches(in: lyric, range: range)
        guard !matches.isEmpty else { return [] }

        return matches.enumerated().compactMap { index, match in
            guard let stampRange = Range(match.range(at: 1), in: lyric),
                  let rawStart = lrcSeconds(String(lyric[stampRange])),
                  let textStart = Range(match.range, in: lyric)?.upperBound
            else { return nil }
            let start = rawStart - offset
            let textEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: lyric) {
                textEnd = nextRange.lowerBound
            } else {
                textEnd = lyric.endIndex
            }
            let text = String(lyric[textStart ..< textEnd])
            guard !text.isEmpty else { return nil }
            let end = index + 1 < matches.count
                ? Range(matches[index + 1].range(at: 1), in: lyric)
                    .flatMap { lrcSeconds(String(lyric[$0])) }
                    .map { $0 - offset } ?? start
                : start
            return LyricWord(text: text, start: start, end: end)
        }
    }

    /// Better Lyrics interprets the LRC metadata offset in seconds and
    /// subtracts it from line and part times. Keeping both on the same shifted
    /// clock matters: shifting only the line would make its words appear to
    /// drift even though their relative timings were correct.
    private static func lrcOffset(in source: String) -> TimeInterval {
        guard let range = source.range(
            of: #"(?m)^\[offset:([^\]]*)\]$"#,
            options: .regularExpression
        ) else { return 0 }
        let tag = source[range]
        let value = tag.dropFirst("[offset:".count).dropLast()
        return Double(value) ?? 0
    }

    /// `[mm:ss.cc]` or `[mm:ss]`. Hundredths and milliseconds both appear,
    /// so the fraction is read as a decimal rather than a fixed width.
    private static func stampSeconds(_ stamp: String) -> TimeInterval? {
        lrcSeconds(String(stamp.dropFirst().dropLast()))
    }

    private static func lrcSeconds(_ body: String) -> TimeInterval? {
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let minutes = Double(parts[0]) else { return nil }
        guard let seconds = Double(parts[1].replacingOccurrences(of: ":", with: "."))
        else { return nil }
        return minutes * 60 + seconds
    }

    /// Reads `<p begin=…>` and the text inside it, flattening any word-level
    /// spans back into one line.
    private final class TTMLParagraphCollector: NSObject, XMLParserDelegate {
        struct Paragraph {
            var key: String?
            var start: TimeInterval
            var end: TimeInterval
            var text: String
            var words: [LyricWord]
        }

        struct Romanization {
            var text: String
            var words: [LyricWord]
        }

        private struct TimedSpan {
            var depth: Int
            var start: TimeInterval
            var end: TimeInterval?
            var text: String
        }

        private struct DecorationCapture {
            var key: String?
            var language: String?
            var text = ""
            var words: [LyricWord] = []
            var untimedText = ""
        }

        private(set) var paragraphs: [Paragraph] = []
        private(set) var language: String?
        private(set) var translations: [String: [String: String]] = [:]
        private(set) var romanizations: [String: Romanization] = [:]
        private var current: Paragraph?
        private var timedSpan: TimedSpan?
        private var untimedText = ""
        private var translationLanguage: String?
        private var translationCapture: DecorationCapture?
        private var isInTransliterations = false
        private var romanizationCapture: DecorationCapture?
        private var romanizedTimedSpan: TimedSpan?
        private var depth = 0

        func parser(
            _: XMLParser,
            didStartElement rawElement: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes: [String: String]
        ) {
            depth += 1
            let element = Self.localName(rawElement)
            switch element {
            case "tt", "body":
                if language == nil {
                    language = Self.attribute("lang", in: attributes)
                }
            case "p":
                startParagraph(attributes)
            case "span":
                startTimedSpan(attributes)
            default:
                startDecorationElement(element, attributes: attributes)
            }
        }

        private func startDecorationElement(
            _ element: String,
            attributes: [String: String]
        ) {
            switch element {
            case "translations":
                if let language = Self.attribute("lang", in: attributes) {
                    translationLanguage = language
                }
            case "translation":
                translationCapture = DecorationCapture(
                    key: Self.attribute("for", in: attributes),
                    language: Self.attribute("lang", in: attributes) ?? translationLanguage
                )
            case "transliterations":
                isInTransliterations = true
            case "text" where translationCapture != nil:
                if translationCapture?.key == nil {
                    translationCapture?.key = Self.attribute("for", in: attributes)
                }
                if translationCapture?.language == nil {
                    translationCapture?.language = Self.attribute("lang", in: attributes)
                        ?? translationLanguage
                }
            case "text" where isInTransliterations:
                romanizationCapture = DecorationCapture(
                    key: Self.attribute("for", in: attributes),
                    language: Self.attribute("lang", in: attributes)
                )
            default:
                return
            }
        }

        private func startParagraph(_ attributes: [String: String]) {
            let begin = Self.attribute("begin", in: attributes)
                .flatMap(LyricsParser.ttmlSeconds) ?? 0
            let end = Self.attribute("end", in: attributes)
                .flatMap(LyricsParser.ttmlSeconds) ?? 0
            current = Paragraph(
                key: Self.attribute("key", in: attributes),
                start: begin,
                end: end,
                text: "",
                words: []
            )
            timedSpan = nil
            untimedText = ""
        }

        private func startTimedSpan(_ attributes: [String: String]) {
            // Only a span carrying its own start is a timed word; the format
            // also uses spans for grouping and annotation.
            guard let begin = Self.attribute("begin", in: attributes),
                  let start = LyricsParser.ttmlSeconds(begin)
            else { return }
            let end = Self.attribute("end", in: attributes)
                .flatMap(LyricsParser.ttmlSeconds)
            if romanizationCapture != nil, romanizedTimedSpan == nil {
                let leading = romanizationCapture?.words.isEmpty == true
                    && romanizationCapture?.untimedText
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
                    ? ""
                    : romanizationCapture?.untimedText ?? ""
                romanizedTimedSpan = TimedSpan(
                    depth: depth,
                    start: start,
                    end: end,
                    text: leading
                )
                romanizationCapture?.untimedText = ""
            } else if current != nil, timedSpan == nil {
                let leading = current?.words.isEmpty == true
                    && untimedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ""
                    : untimedText
                timedSpan = TimedSpan(
                    depth: depth,
                    start: start,
                    end: end,
                    text: leading
                )
                untimedText = ""
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            if translationCapture != nil {
                translationCapture?.text += string
                return
            }
            if romanizationCapture != nil {
                romanizationCapture?.text += string
                if romanizedTimedSpan != nil {
                    romanizedTimedSpan?.text += string
                } else {
                    romanizationCapture?.untimedText += string
                }
                return
            }
            current?.text += string
            if timedSpan != nil {
                timedSpan?.text += string
            } else if current != nil {
                untimedText += string
            }
        }

        func parser(
            _: XMLParser,
            didEndElement rawElement: String,
            namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            defer { depth -= 1 }
            let element = Self.localName(rawElement)
            switch element {
            case "span":
                finishTimedSpan()
            case "p":
                finishParagraph()
            default:
                finishDecorationElement(element)
            }
        }

        private func finishTimedSpan() {
            if let span = romanizedTimedSpan, span.depth == depth {
                append(span, to: &romanizationCapture)
                romanizedTimedSpan = nil
                return
            }
            // An untimed span nested inside a timed one closes here too;
            // only the depth that opened the timed word may finish it.
            guard let span = timedSpan, span.depth == depth else { return }
            if !span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                current?.words.append(
                    LyricWord(
                        text: span.text,
                        start: span.start,
                        end: span.end ?? span.start
                    )
                )
            }
            timedSpan = nil
        }

        private func finishDecorationElement(_ element: String) {
            switch element {
            case "translation":
                guard let capture = translationCapture else { return }
                let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let key = capture.key, let language = capture.language, !text.isEmpty {
                    translations[key, default: [:]][language] = text
                }
                translationCapture = nil
            case "text" where romanizationCapture != nil:
                guard var capture = romanizationCapture else { return }
                appendTrailingText(to: &capture)
                let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let key = capture.key, !text.isEmpty {
                    romanizations[key] = Romanization(text: text, words: capture.words)
                }
                romanizationCapture = nil
                romanizedTimedSpan = nil
            case "translations":
                translationLanguage = nil
            case "transliterations":
                isInTransliterations = false
            default:
                return
            }
        }

        private func finishParagraph() {
            guard var paragraph = current else { return }
            // Whitespace between timed spans is prefixed to the next part. A
            // trailing fragment has no next part, so append it to the last
            // one. Concatenating then reproduces the paragraph exactly.
            if !untimedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let last = paragraph.words.indices.last {
                let word = paragraph.words[last]
                paragraph.words[last] = LyricWord(
                    text: word.text + untimedText,
                    start: word.start,
                    end: word.end
                )
            }
            paragraphs.append(paragraph)
            current = nil
            timedSpan = nil
            untimedText = ""
        }

        private func append(
            _ span: TimedSpan,
            to capture: inout DecorationCapture?
        ) {
            guard !span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            capture?.words.append(
                LyricWord(
                    text: span.text,
                    start: span.start,
                    end: span.end ?? span.start
                )
            )
        }

        private func appendTrailingText(to capture: inout DecorationCapture) {
            guard !capture.untimedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let last = capture.words.indices.last
            else { return }
            let word = capture.words[last]
            capture.words[last] = LyricWord(
                text: word.text + capture.untimedText,
                start: word.start,
                end: word.end
            )
        }

        private static func localName(_ qualifiedName: String) -> String {
            qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName
        }

        private static func attribute(
            _ name: String,
            in attributes: [String: String]
        ) -> String? {
            attributes[name] ?? attributes.first {
                localName($0.key) == name
            }?.value
        }
    }

    /// TTML writes a time as clock (`00:01:02.500`) or as an offset with an
    /// `h`, `m`, `s` or `ms` unit.
    static func ttmlSeconds(_ value: String) -> TimeInterval? {
        let units: [(String, TimeInterval)] = [
            ("ms", 0.001), ("h", 3_600), ("m", 60), ("s", 1)
        ]
        for (suffix, multiplier) in units where value.hasSuffix(suffix) {
            guard let offset = Double(value.dropLast(suffix.count)) else { return nil }
            return offset * multiplier
        }
        let parts = value.split(separator: ":")
        guard !parts.isEmpty else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let component = Double(part) else { return nil }
            total = total * 60 + component
        }
        return total
    }
}
