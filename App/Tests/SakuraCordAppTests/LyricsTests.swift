import Foundation
import Testing
@testable import SakuraCord

@Test func `timed lyrics read their stamps and stay in order`() {
    // Sources are not reliably ordered, and the third stamp here arrives
    // before the second so the parser has to sort rather than trust it.
    let source = """
    [00:12.50]alpha
    [00:30.00]charlie
    [00:20.25]bravo
    """
    let lyrics = LyricsParser.parse(source, format: "lrc")

    #expect(lyrics.synchronisation == .line)
    #expect(lyrics.lines.map(\.text) == ["alpha", "bravo", "charlie"])
    #expect(lyrics.lines[0].start == 12.5)
    #expect(lyrics.lines[1].start == 20.25)

    // Identity follows position, so a repeated line does not collapse into
    // the one before it.
    #expect(lyrics.lines.map(\.id) == [0, 1, 2])
}

@Test func `the active line follows the clock`() {
    let lyrics = LyricsParser.parse(
        """
        [00:10.00]alpha
        [00:20.00]bravo
        [00:30.00]charlie
        """,
        format: "lrc"
    )

    // Before the first line starts, nothing is lit rather than the first
    // line being lit early.
    #expect(lyrics.activeIndex(at: 0) == nil)
    #expect(lyrics.activeIndex(at: 9.9) == nil)
    #expect(lyrics.activeIndex(at: 10) == 0)
    #expect(lyrics.activeIndex(at: 19.9) == 0)
    #expect(lyrics.activeIndex(at: 20) == 1)
    // The last line stays lit to the end of the song.
    #expect(lyrics.activeIndex(at: 600) == 2)
}

@Test func `an instrumental gap is kept as a line`() {
    // A stamp with no words is a break the writer marked, and holding on it
    // is what keeps the panel from running ahead of the singing.
    let lyrics = LyricsParser.parse("[00:05.00]alpha\n[00:09.00]\n[00:15.00]bravo", format: "lrc")

    #expect(lyrics.lines.count == 3)
    #expect(lyrics.lines[1].text.isEmpty)
    #expect(lyrics.activeIndex(at: 10) == 1)
}

@Test func `ttml paragraphs become lines`() {
    let source = """
    <tt><body><div>
    <p begin="00:00:05.000" end="00:00:08.000"><span>alpha </span><span>bravo</span></p>
    <p begin="12.5s" end="15s">charlie</p>
    </div></body></tt>
    """
    let lyrics = LyricsParser.parse(source, format: "ttml")

    #expect(lyrics.synchronisation == .line)
    // Word-level spans flatten back into the line this panel lights.
    #expect(lyrics.lines.map(\.text) == ["alpha bravo", "charlie"])
    #expect(lyrics.lines[0].start == 5)
    // An offset time is as valid as a clock time.
    #expect(lyrics.lines[1].start == 12.5)
}

@Test func `words with no timings are still worth showing`() {
    let lyrics = LyricsParser.parse("alpha\nbravo", format: "plain")

    #expect(lyrics.synchronisation == .none)
    #expect(lyrics.lines.count == 2)
    // Nothing is ever lit, so the panel must not dim every line against a
    // line that does not exist.
    #expect(lyrics.activeIndex(at: 30) == nil)
}

@Test func `a source that will not parse falls back rather than emptying`() {
    // Claiming to be LRC does not make it LRC. The words survive as plain.
    let lyrics = LyricsParser.parse("alpha\nbravo", format: "lrc")
    #expect(lyrics.synchronisation == .none)
    #expect(lyrics.lines.count == 2)

    #expect(LyricsParser.parse("", format: "plain").isEmpty)
    #expect(LyricsParser.parse("\n\n", format: "plain").isEmpty)
}

@Test func `a lookup is keyed by video id`() {
    let url = UnisonLyricsRequest.url(
        videoID: "abc123",
        title: "A Song",
        artist: "A Band",
        duration: 212.4
    )
    let query = url?.query ?? ""
    #expect(query.contains("v=abc123"))
    #expect(query.contains("duration=212"))

    // Without an id there is nothing to look up, so no request is made at
    // all rather than one that cannot match.
    #expect(
        UnisonLyricsRequest.url(videoID: "", title: "A Song", artist: "A Band", duration: 1) == nil
    )
}

@Test func `a response with no words reads as empty`() {
    let body = Data(#"{"data":{"lyrics":"[00:01.00]alpha","format":"lrc"}}"#.utf8)
    #expect(UnisonLyricsRequest.lyrics(from: body).lines.count == 1)

    // Every shape the service uses to say "nothing here" has to land as
    // empty rather than as a parse failure the panel would show as words.
    #expect(UnisonLyricsRequest.lyrics(from: Data(#"{"data":null}"#.utf8)).isEmpty)
    #expect(UnisonLyricsRequest.lyrics(from: Data(#"{"data":{"lyrics":""}}"#.utf8)).isEmpty)
    #expect(UnisonLyricsRequest.lyrics(from: Data("not json".utf8)).isEmpty)
}

@Test func `the recording that is playing is the one matched`() {
    // The same song indexed three ways: a TV edit, the playing cut, and a
    // cover. A lyric timed against a different cut drifts further out of
    // step the longer it plays, so duration decides.
    let results = [
        LRCLibRequest.Result(
            trackName: "A Song", artistName: "A Band", duration: 90,
            instrumental: false, plainLyrics: "short", syncedLyrics: "[00:01.00]short"
        ),
        LRCLibRequest.Result(
            trackName: "A Song", artistName: "A Band", duration: 211,
            instrumental: false, plainLyrics: "right", syncedLyrics: "[00:01.00]right"
        ),
        LRCLibRequest.Result(
            trackName: "A Song", artistName: "A Cover Band", duration: 226,
            instrumental: false, plainLyrics: "cover", syncedLyrics: "[00:01.00]cover"
        )
    ]

    let picked = LRCLibRequest.select(from: results, duration: 211)
    #expect(picked.lines.first?.text == "right")

    // Nothing within tolerance is a different recording, and no lyric beats
    // a confidently wrong one.
    #expect(LRCLibRequest.select(from: results, duration: 400).isEmpty)
}

@Test func `a timed lyric is preferred over a closer untimed one`() {
    let results = [
        LRCLibRequest.Result(
            trackName: "A Song", artistName: "A Band", duration: 200,
            instrumental: false, plainLyrics: "untimed", syncedLyrics: nil
        ),
        LRCLibRequest.Result(
            trackName: "A Song", artistName: "A Band", duration: 202,
            instrumental: false, plainLyrics: "timed", syncedLyrics: "[00:02.00]timed"
        )
    ]

    // The untimed result matches the duration better, but words that follow
    // the music are worth more than two seconds of accuracy.
    let picked = LRCLibRequest.select(from: results, duration: 200)
    #expect(picked.synchronisation == .line)
    #expect(picked.lines.first?.text == "timed")
}

@Test func `an instrumental is not given words`() {
    let results = [
        LRCLibRequest.Result(
            trackName: "A Song", artistName: "A Band", duration: 180,
            instrumental: true, plainLyrics: "should not show", syncedLyrics: nil
        )
    ]
    #expect(LRCLibRequest.select(from: results, duration: 180).isEmpty)
}

@Test func `a track is identified without a video id`() {
    // LRCLib matches on title and artist, so a page that has not reported
    // which video is playing is still worth looking up.
    var state = MusicPlaybackState(title: "A Song", artist: "A Band")
    #expect(LyricsModel.identity(for: state) == "A Song|A Band")

    // The id wins when present: it survives the title corrections the page
    // makes just after a track change.
    state.videoID = "abc123"
    #expect(LyricsModel.identity(for: state) == "abc123")

    #expect(LyricsModel.identity(for: MusicPlaybackState()) == nil)
}

@Test func `ttml spans carry their own timings`() {
    let source = """
    <tt><body><div>
    <p begin="10.0" end="14.0">
    <span begin="10.0" end="11.0">one </span><span begin="11.0" end="12.0">two </span><span begin="12.5" end="14.0">three</span>
    </p>
    </div></body></tt>
    """
    let lyrics = LyricsParser.parse(source, format: "ttml")
    let line = try! #require(lyrics.lines.first)

    #expect(line.isWordTimed)
    #expect(line.words.count == 3)
    // The span's own spacing is kept, so concatenating the words rebuilds
    // the line rather than inventing separators.
    #expect(line.words.map(\.text).joined() == "one two three")

    // Counting words begun, so a line whose words overlap does not flicker
    // between two "current" words.
    #expect(line.wordsSung(by: 9) == 0)
    #expect(line.wordsSung(by: 10) == 1)
    #expect(line.wordsSung(by: 11.5) == 2)
    #expect(line.wordsSung(by: 13) == 3)
}

@Test func `a paragraph without timed spans still stands on its own start`() {
    // A mixed document degrades line by line rather than all at once.
    let source = """
    <tt><body><div>
    <p begin="5.0"><span>plain grouping span</span></p>
    </div></body></tt>
    """
    let line = try! #require(LyricsParser.parse(source, format: "ttml").lines.first)

    #expect(line.start == 5)
    #expect(line.isWordTimed == false)
    #expect(line.text == "plain grouping span")
}

@Test func `line-timed sources carry no word timings`() {
    // LRC knows when a line starts and nothing finer, so the renderer must
    // not be told otherwise.
    let line = try! #require(
        LyricsParser.parse("[00:03.00]alpha bravo", format: "lrc").lines.first
    )
    #expect(line.isWordTimed == false)
    #expect(line.wordsSung(by: 99) == 0)
}

@Test func `a line knows its own span so it can be filled across`() {
    let lyrics = LyricsParser.parse(
        """
        [00:10.00]alpha
        [00:20.00]bravo
        """,
        format: "lrc"
    )
    let first = try! #require(lyrics.lines.first)

    // A line runs until the next one starts.
    #expect(first.end == 20)
    #expect(first.fractionSung(by: 10) == 0)
    #expect(first.fractionSung(by: 15) == 0.5)
    #expect(first.fractionSung(by: 20) == 1)
    // Outside its span the fill is clamped rather than running past itself.
    #expect(first.fractionSung(by: 5) == 0)
    #expect(first.fractionSung(by: 99) == 1)

    // The last line has no successor, so it is given a plausible span
    // rather than none: a zero span would read as finished the instant it
    // began.
    let last = try! #require(lyrics.lines.last)
    #expect(last.end > last.start)
    #expect(last.fractionSung(by: last.start) == 0)
}
