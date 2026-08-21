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
                    stamps.append(seconds)
                }
                searchStart = range.upperBound
            }
            guard !stamps.isEmpty else { continue }
            let text = line[searchStart...].trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                lines.append(LyricLine(id: lines.count, start: stamp, text: text))
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
            LyricLine(
                id: index,
                start: paragraph.start,
                text: paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines),
                words: paragraph.words
            )
        }
        return TimedLyrics(lines: ordered(lines), synchronisation: .line)
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
    private static func ordered(_ lines: [LyricLine]) -> [LyricLine] {
        let sorted = lines.sorted { $0.start < $1.start }
        return sorted.enumerated().map { index, line in
            // A line runs until the next one starts. The last line has no
            // successor, so it is given a plausible span rather than none:
            // zero would make it read as finished the instant it began.
            let next = index + 1 < sorted.count ? sorted[index + 1].start : line.start + 5
            return LyricLine(
                id: index,
                start: line.start,
                end: max(next, line.start),
                text: line.text,
                words: line.words
            )
        }
    }

    /// `[mm:ss.cc]` or `[mm:ss]`. Hundredths and milliseconds both appear,
    /// so the fraction is read as a decimal rather than a fixed width.
    private static func stampSeconds(_ stamp: String) -> TimeInterval? {
        let body = stamp.dropFirst().dropLast()
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
            var start: TimeInterval
            var text: String
            var words: [LyricWord]
        }

        private(set) var paragraphs: [Paragraph] = []
        private var current: Paragraph?
        private var wordStart: TimeInterval?
        private var wordEnd: TimeInterval?
        private var wordText = ""

        func parser(
            _: XMLParser,
            didStartElement element: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes: [String: String]
        ) {
            switch element {
            case "p":
                let begin = attributes["begin"].flatMap(LyricsParser.ttmlSeconds) ?? 0
                current = Paragraph(start: begin, text: "", words: [])
            case "span":
                // Only a span carrying its own start is a timed word; the
                // format also uses spans for grouping and annotation.
                guard current != nil, let begin = attributes["begin"] else { return }
                wordStart = LyricsParser.ttmlSeconds(begin)
                wordEnd = attributes["end"].flatMap(LyricsParser.ttmlSeconds)
                wordText = ""
            default:
                return
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            current?.text += string
            if wordStart != nil { wordText += string }
        }

        func parser(
            _: XMLParser,
            didEndElement element: String,
            namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            switch element {
            case "span":
                guard let start = wordStart else { return }
                // The span's own spacing is kept rather than trimmed: the
                // words are concatenated back into a line to draw, and a
                // language that does not space between words - Japanese
                // among them - would gain spaces it never had.
                if !wordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current?.words.append(
                        LyricWord(text: wordText, start: start, end: wordEnd ?? start)
                    )
                }
                wordStart = nil
                wordEnd = nil
                wordText = ""
            case "p":
                guard let paragraph = current else { return }
                paragraphs.append(paragraph)
                current = nil
            default:
                return
            }
        }
    }

    /// TTML writes a time as clock (`00:01:02.500`) or as an offset (`62.5s`).
    static func ttmlSeconds(_ value: String) -> TimeInterval? {
        if value.hasSuffix("s"), let offset = Double(value.dropLast()) {
            return offset
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
