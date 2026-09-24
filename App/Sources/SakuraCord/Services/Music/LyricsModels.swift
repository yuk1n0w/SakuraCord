import Foundation

/// One word, and the moment it is sung.
///
/// Only richly-timed sources carry these. A line-timed source knows when a
/// line starts and nothing finer, which is most of what is available.
nonisolated struct LyricWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    /// Better Lyrics' rich-sync swipe: it leads the stated part by ten
    /// percent and crosses it over 1.6 times its duration. The generous
    /// tail keeps a short syllable from flashing while still anchoring the
    /// movement to the source's real timing.
    func highlightProgress(at time: TimeInterval) -> Double {
        let duration = end - start
        guard duration > 0 else { return time >= start ? 1 : 0 }
        let swipeStart = start - duration * 0.1
        let swipeDuration = duration * 1.6
        return min(max((time - swipeStart) / swipeDuration, 0), 1)
    }
}

/// One line of a song, and when it starts.
nonisolated struct LyricLine: Equatable, Sendable, Identifiable {
    /// Position in the lyric, which is what identifies a line: the same
    /// words can repeat many times in one song, and a repeated chorus must
    /// not collapse into a single row.
    let id: Int
    let start: TimeInterval

    /// When the line gives way to the next one. A line knows its own span,
    /// which is what lets an untimed line be filled across as it is sung.
    var end: TimeInterval = 0

    let text: String

    /// The line's words with their own timings, when the source had them.
    /// Empty means the line is lit as a whole.
    var words: [LyricWord] = []

    /// Provider-supplied language decorations. TTML can carry both beside
    /// the primary lyric; retaining them avoids translating text that the
    /// lyric author already supplied and preserves timed romanization.
    var translations: [String: String] = [:]
    var romanization: String?
    var romanizedWords: [LyricWord] = []

    var isWordTimed: Bool { !words.isEmpty }

    /// Language helpers decorate a line after its karaoke layers are already
    /// moving. Those additions must not make the primary lyric look like a
    /// different timed line and restart its sweep halfway through a word.
    func hasSamePrimaryAnimation(as other: Self) -> Bool {
        id == other.id
            && start == other.start
            && end == other.end
            && text == other.text
            && words == other.words
    }

    func translation(for languageCode: String) -> String? {
        let requested = languageCode.lowercased()
        let requestedBase = requested.split(separator: "-").first.map(String.init)
        return translations.first { code, _ in
            let candidate = code.lowercased()
            return candidate == requested
                || candidate.split(separator: "-").first.map(String.init) == requestedBase
        }?.value
    }

    /// How many words have begun by this moment. Counting rather than
    /// finding an index keeps a line whose words overlap - held notes and
    /// run-ons do - from flickering between two "current" words.
    func wordsSung(by time: TimeInterval) -> Int {
        words.reduce(0) { $1.start <= time ? $0 + 1 : $0 }
    }

    /// The shortest a line's fill may take, so a line whose successor
    /// follows immediately does not flash rather than sweep.
    private static let shortestFill: TimeInterval = 1.2

    /// The longest, so a line held open before a break does not crawl.
    private static let longestFill: TimeInterval = 6

    /// How far through this line the singing has reached, as a fraction.
    ///
    /// Paced across the line's own span - from when it starts to when the
    /// next one does - because that span is the only timing a line-synced
    /// source actually gives, and the words of a line are sung across it.
    /// An earlier version guessed a rate per character instead, which was
    /// independent of the real timings and so drifted against the voice.
    ///
    /// This is still a linear sweep, not true word timing: it cannot know
    /// which syllable is being held. Only a source carrying per-word
    /// timings can do that, and where one exists it is used instead.
    func fractionSung(by time: TimeInterval) -> Double {
        let paced = fillDuration
        guard paced > 0 else { return time >= start ? 1 : 0 }
        return min(max((time - start) / paced, 0), 1)
    }

    /// How long the fill takes. The panel needs the same span to place each
    /// word's glow when the source timed only the line, so the flare and the
    /// fill move together rather than against one another.
    var fillDuration: TimeInterval {
        let span = end - start
        guard span > 0 else { return 0 }
        return min(max(span, Self.shortestFill), Self.longestFill)
    }
}

/// A song's words, timed if the source knew the timings.
nonisolated struct TimedLyrics: Equatable, Sendable {
    enum Synchronisation: Equatable, Sendable {
        /// Timed per line.
        case line
        /// No timings; the words are all that is known.
        case none
    }

    var lines: [LyricLine]
    var synchronisation: Synchronisation
    var language: String?

    init(
        lines: [LyricLine],
        synchronisation: Synchronisation,
        language: String? = nil
    ) {
        self.lines = lines
        self.synchronisation = synchronisation
        self.language = language
    }

    static let empty = TimedLyrics(lines: [], synchronisation: .none)

    var isEmpty: Bool { lines.isEmpty }

    var isLineTimed: Bool {
        !isEmpty && synchronisation == .line
    }

    /// Whether any line carries its own word timings. Better Lyrics ranks
    /// every richly-timed source above every line-timed one, because a
    /// lyric that knows where each word falls is worth more than one that
    /// only knows where the line does.
    var isWordTimed: Bool { lines.contains { $0.isWordTimed } }

    /// Better Lyrics intentionally renders slightly ahead of the raw source
    /// timestamps: 150 ms for rich sync and 115 ms for line sync. The visual
    /// swipe then lands on the voice instead of appearing to react after it.
    var timingLead: TimeInterval {
        guard synchronisation == .line else { return 0 }
        return isWordTimed ? 0.150 : 0.115
    }

    /// The line that should be lit at this moment, or nil before the first
    /// one starts.
    ///
    /// A binary search rather than a scan: this is asked once per frame of
    /// playback, and a long song is a few hundred lines.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard synchronisation == .line, !lines.isEmpty else { return nil }
        guard time >= lines[0].start else { return nil }
        var low = 0
        var high = lines.count - 1
        var match = 0
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].start <= time {
                match = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return match
    }

    /// A presence can follow timed lines, but must not guess where an
    /// untimed copy belongs or publish a blank instrumental break.
    func activeText(at time: TimeInterval) -> String? {
        guard let index = activeIndex(at: time) else { return nil }
        let text = lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
