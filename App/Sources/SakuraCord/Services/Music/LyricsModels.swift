import Foundation

/// One word, and the moment it is sung.
///
/// Only richly-timed sources carry these. A line-timed source knows when a
/// line starts and nothing finer, which is most of what is available.
nonisolated struct LyricWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
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

    var isWordTimed: Bool { !words.isEmpty }

    /// How many words have begun by this moment. Counting rather than
    /// finding an index keeps a line whose words overlap - held notes and
    /// run-ons do - from flickering between two "current" words.
    func wordsSung(by time: TimeInterval) -> Int {
        words.reduce(0) { $1.start <= time ? $0 + 1 : $0 }
    }

    /// How far through this line the singing has reached, as a fraction.
    ///
    /// A line-timed source gives a start and nothing finer, but a line
    /// still occupies a span of the song, and sweeping across that span is
    /// what makes the words fill rather than blink on all at once. It is an
    /// estimate - singing is not evenly paced - but it tracks far better
    /// than lighting the whole line at its first instant.
    func fractionSung(by time: TimeInterval) -> Double {
        guard end > start else { return time >= start ? 1 : 0 }
        return min(max((time - start) / (end - start), 0), 1)
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

    static let empty = TimedLyrics(lines: [], synchronisation: .none)

    var isEmpty: Bool { lines.isEmpty }

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
}
