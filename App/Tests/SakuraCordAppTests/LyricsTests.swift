import Foundation
import Testing
@testable import SakuraCord

@Test func `timed lyrics read their stamps and stay in order`() {
    // Sources are not reliably ordered, and the third stamp here arrives
    // before the second so the parser has to sort rather than trust it.
    let source = """
    [00:02.50]alpha
    [00:08.00]charlie
    [00:05.25]bravo
    """
    let lyrics = LyricsParser.parse(source, format: "lrc")

    #expect(lyrics.synchronisation == .line)
    #expect(lyrics.lines.map(\.text) == ["alpha", "bravo", "charlie"])
    #expect(lyrics.lines[0].start == 2.5)
    #expect(lyrics.lines[1].start == 5.25)

    // Identity follows position, so a repeated line does not collapse into
    // the one before it.
    #expect(lyrics.lines.map(\.id) == [0, 1, 2])
}

@Test func `enhanced lrc keeps its word timings`() {
    let lyrics = LyricsParser.parse(
        "[00:10.00]<00:10.00>Hello <00:10.50>world <00:11.20>today",
        format: "lrc"
    )
    let line = try! #require(lyrics.lines.last)

    #expect(line.text == "Hello world today")
    #expect(line.isWordTimed)
    #expect(line.words.map(\.text).joined() == "Hello world today")
    #expect(line.words.map(\.start) == [10, 10.5, 11.2])
    #expect(line.words[0].end == 10.5)
    #expect(line.words[1].end == 11.2)
}

@Test func `lrc offset moves lines and rich parts together`() {
    let lyrics = LyricsParser.parse(
        "[offset:0.5]\n[00:10.00]<00:10.00>Hello <00:10.50>world",
        format: "lrc"
    )
    let line = try! #require(lyrics.lines.first(where: { !$0.text.isEmpty }))

    #expect(line.start == 9.5)
    #expect(line.words.map(\.start) == [9.5, 10])
}

@Test func `rich sync follows better lyrics swipe timing`() {
    let word = LyricWord(text: "hello", start: 10, end: 11)

    #expect(word.highlightProgress(at: 9.89) == 0)
    #expect(word.highlightProgress(at: 9.9) == 0)
    #expect(abs(word.highlightProgress(at: 10.7) - 0.5) < 0.000_001)
    #expect(abs(word.highlightProgress(at: 11.5) - 1) < 0.000_001)
}

@Test func `the active line follows the clock`() {
    let lyrics = LyricsParser.parse(
        """
        [00:02.00]alpha
        [00:05.00]bravo
        [00:08.00]charlie
        """,
        format: "lrc"
    )

    // Before the first line starts, nothing is lit rather than the first
    // line being lit early.
    #expect(lyrics.activeIndex(at: 0) == nil)
    #expect(lyrics.activeIndex(at: 1.9) == nil)
    #expect(lyrics.activeIndex(at: 2) == 0)
    #expect(lyrics.activeIndex(at: 4.9) == 0)
    #expect(lyrics.activeIndex(at: 5) == 1)
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
    <p begin="00:00:02.000" end="00:00:05.000"><span>alpha </span><span>bravo</span></p>
    <p begin="6.5s" end="9s">charlie</p>
    </div></body></tt>
    """
    let lyrics = LyricsParser.parse(source, format: "ttml")

    #expect(lyrics.synchronisation == .line)
    // Word-level spans flatten back into the line this panel lights.
    #expect(lyrics.lines.map(\.text) == ["alpha bravo", "charlie"])
    #expect(lyrics.lines[0].start == 2)
    // An offset time is as valid as a clock time.
    #expect(lyrics.lines[1].start == 6.5)
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

@Test func `a lyric lookup waits for complete track metadata and retries corrections`() {
    let incomplete = MusicPlaybackState(
        videoID: "new-video",
        title: "New Song",
        artist: "Old Artist",
        duration: 0
    )
    #expect(LyricsLookupRequest(state: incomplete) == nil)

    let stale = MusicPlaybackState(
        videoID: "new-video",
        title: "Old Song",
        artist: "Old Artist",
        duration: 180
    )
    let corrected = MusicPlaybackState(
        videoID: "new-video",
        title: "New Song",
        artist: "New Artist",
        duration: 223
    )
    #expect(LyricsLookupRequest(state: stale) != LyricsLookupRequest(state: corrected))

    var progressed = corrected
    progressed.progress = 90
    #expect(LyricsLookupRequest(state: corrected) == LyricsLookupRequest(state: progressed))
}

@Test func `youtube music plain lyrics decode from its description shelf`() {
    let response = Data(
        #"{"contents":{"sectionListRenderer":{"contents":[{"musicDescriptionShelfRenderer":{"description":{"runs":[{"text":"alpha\nbeta"}]}}}]}}}"#.utf8
    )
    let lyrics = YouTubeMusicLyricsResponse.lyrics(from: response)

    #expect(lyrics.synchronisation == .none)
    #expect(lyrics.lines.map(\.text) == ["alpha", "beta"])
    #expect(YouTubeMusicLyricsResponse.lyrics(from: Data("{}".utf8)).isEmpty)
}

@Test @MainActor func `lyric language choices persist independently`() {
    let suite = "LyricsLanguageChoices-\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = LyricsModel(defaults: defaults)
    #expect(model.showsRomanization == false)
    #expect(model.showsTranslation == false)
    #expect(model.translationLanguage == "en")

    model.setShowsRomanization(true)
    model.setShowsTranslation(true)
    model.setTranslationLanguage("ja")

    let restored = LyricsModel(defaults: defaults)
    #expect(restored.showsRomanization)
    #expect(restored.showsTranslation)
    #expect(restored.translationLanguage == "ja")

    restored.setTranslationLanguage("not-a-language")
    #expect(restored.translationLanguage == "ja")
}

@Test func `ttml spans carry their own timings`() {
    let source = """
    <tt><body><div>
    <p begin="2.0" end="6.0">
    <span begin="2.0" end="3.0">one </span><span begin="3.0" end="4.0">two </span><span begin="4.5" end="6.0">three</span>
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
    #expect(line.wordsSung(by: 1) == 0)
    #expect(line.wordsSung(by: 2) == 1)
    #expect(line.wordsSung(by: 3.5) == 2)
    #expect(line.wordsSung(by: 5) == 3)
}

@Test func `ttml keeps spaces and nested timed span text`() {
    let source = """
    <tt><body><div><p begin="2s" end="4s">
    <span begin="2s" end="3s"><span>hello</span></span> <span role="x-bg"><span begin="3s" end="4s">world</span></span>
    </p></div></body></tt>
    """
    let line = try! #require(LyricsParser.parse(source, format: "ttml").lines.first)

    #expect(line.text == "hello world")
    #expect(line.words.map(\.text).joined() == "hello world")
    #expect(line.words.map(\.start) == [2, 3])
    #expect(line.end == 4)
}

@Test func `ttml preserves translations and timed romanization`() {
    let source = """
    <tt xml:lang="ja"><head><metadata>
      <translations lang="en">
        <translation for="greeting"><text>Hello world</text></translation>
      </translations>
      <translations>
        <translation xml:lang="fr"><text for="greeting">Bonjour le monde</text></translation>
      </translations>
      <transliterations><transliteration xml:lang="ja-Latn">
        <text for="greeting"><span begin="1s" end="2s">konnichi</span><span begin="2s" end="3s">wa</span></text>
      </transliteration></transliterations>
    </metadata></head><body><div>
      <p key="greeting" begin="1s" end="3s">こんにちは</p>
      <p key="greeting" begin="4s" end="6s">こんにちは</p>
    </div></body></tt>
    """
    let lyrics = LyricsParser.parse(source, format: "ttml")

    #expect(lyrics.language == "ja")
    #expect(lyrics.lines.count == 2)
    #expect(lyrics.lines.allSatisfy { $0.translation(for: "en-US") == "Hello world" })
    #expect(lyrics.lines.allSatisfy { $0.translation(for: "fr") == "Bonjour le monde" })
    #expect(lyrics.lines.allSatisfy { $0.romanization == "konnichiwa" })
    #expect(lyrics.lines[0].romanizedWords.map(\.text).joined() == "konnichiwa")
    #expect(lyrics.lines[0].romanizedWords.map(\.start) == [1, 2])
    #expect(lyrics.lines[1].romanizedWords.map(\.start) == [4, 5])
}

@Test func `language decorations preserve primary lyric animation identity`() {
    let original = LyricLine(
        id: 4,
        start: 12,
        end: 15,
        text: "歩めと繰り返した",
        words: [
            LyricWord(text: "歩めと", start: 12, end: 13.2),
            LyricWord(text: "繰り返した", start: 13.2, end: 15),
        ]
    )
    var decorated = original
    decorated.romanization = "ayume to kurikaeshita"
    decorated.translations["en"] = "Walk, I repeated."

    #expect(original.hasSamePrimaryAnimation(as: decorated))

    let retimed = LyricLine(
        id: original.id,
        start: original.start,
        end: original.end,
        text: original.text,
        words: [LyricWord(text: original.text, start: 12, end: 15)]
    )
    #expect(!original.hasSamePrimaryAnimation(as: retimed))
}

@Test func `ttml reads every offset time unit`() {
    #expect(LyricsParser.ttmlSeconds("500ms") == 0.5)
    #expect(LyricsParser.ttmlSeconds("1.5s") == 1.5)
    #expect(LyricsParser.ttmlSeconds("2m") == 120)
    #expect(LyricsParser.ttmlSeconds("0.5h") == 1_800)
    #expect(LyricsParser.ttmlSeconds("1:02.5") == 62.5)
}

@Test func `language decoration requests follow better lyrics batches`() {
    let translation = try! #require(
        LyricsLanguageRequest.translationBatches(
            [(4, "こんにちは"), (9, "さようなら")],
            targetLanguage: "en"
        ).first
    )
    let translationItems = URLComponents(
        url: translation.url,
        resolvingAgainstBaseURL: false
    )?.queryItems ?? []

    #expect(translation.indices == [4, 9])
    #expect(translationItems.contains(URLQueryItem(name: "sl", value: "auto")))
    #expect(translationItems.contains(URLQueryItem(name: "tl", value: "en")))
    #expect(translationItems.contains(
        URLQueryItem(name: "client", value: "dict-chrome-ex")
    ))
    #expect(translationItems.filter { $0.name == "dt" }.map(\.value) == ["t"])

    let romanization = try! #require(
        LyricsLanguageRequest.romanizationBatches(
            [(0, "こんにちは")],
            sourceLanguage: "ja"
        ).first
    )
    let romanizationItems = URLComponents(
        url: romanization.url,
        resolvingAgainstBaseURL: false
    )?.queryItems ?? []
    #expect(romanizationItems.contains(URLQueryItem(name: "tl", value: "ja-Latn")))
    #expect(romanizationItems.filter { $0.name == "dt" }.map(\.value) == ["t", "rm"])

    let long = String(repeating: "界", count: 8_000)
    #expect(
        LyricsLanguageRequest.translationBatches(
            [(0, long), (1, long)],
            targetLanguage: "en"
        ).count == 2
    )
}

@Test func `language decoration responses keep line alignment`() {
    let translation = Data(
        #"[[["Hello\n\n;\n\nGoodbye","",null,null]],null,"ja"]"#.utf8
    )
    let translated = LyricsLanguageRequest.parseTranslation(
        translation,
        expectedCount: 2
    )
    #expect(translated.detectedLanguage == "ja")
    #expect(translated.texts == ["Hello", "Goodbye"])

    let romanization = Data(
        #"[[["こんにちは","こんにちは","Kon'nichiwa","konnichiwa"]],null,"ja"]"#.utf8
    )
    let romanized = LyricsLanguageRequest.parseRomanization(
        romanization,
        expectedCount: 1
    )
    #expect(romanized.detectedLanguage == "ja")
    #expect(romanized.texts == ["konnichiwa"])

    #expect(
        LyricsLanguageRequest.parseTranslation(
            Data("not json".utf8),
            expectedCount: 2
        ).texts == [nil, nil]
    )
}

@Test func `romanization asks a real language rather than auto`() {
    // Asking to transliterate from "auto" is answered with an English
    // translation instead, which would put a translation where the
    // romanization belongs. A regional code has no transliteration of its
    // own either, so it has to ask as its base language.
    #expect(LyricsLanguageService.transliterableBase(of: "ja") == "ja")
    #expect(LyricsLanguageService.transliterableBase(of: "zh-CN") == "zh")
    #expect(LyricsLanguageService.transliterableBase(of: "JA-JP") == "ja")
    #expect(LyricsLanguageService.transliterableBase(of: "en") == nil)
    #expect(LyricsLanguageService.transliterableBase(of: "auto") == nil)

    let detection = LyricsLanguageRequest.detectionURL(text: "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}")
    let items = URLComponents(url: detection, resolvingAgainstBaseURL: false)?
        .queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "sl", value: "auto")))
    #expect(items.filter { $0.name == "dt" }.map(\.value) == ["t"])
    #expect(
        LyricsLanguageRequest.detectedLanguage(
            Data(#"[[["hello","",null,null]],null,"ja"]"#.utf8)
        ) == "ja"
    )
}

@Test func `a romanized batch survives the separator the service collapses`() {
    // The service answers romanization as one run holding every line, and
    // it does not return the blank lines the batch separator was built
    // from - only the semicolon between them. Splitting on the separator
    // that was sent would leave one unusable run where three lines were
    // asked for, which is how a whole song ends up with no romanization.
    let body = Data(
        #"[[["one\n\n;\n\ntwo",null,null,null,5],[null,null,"alpha; bravo; charlie","alpha; bravo; charlie"]],null,"ja"]"#.utf8
    )
    let parsed = LyricsLanguageRequest.parseRomanization(body, expectedCount: 3)

    #expect(parsed.detectedLanguage == "ja")
    #expect(parsed.texts == ["alpha", "bravo", "charlie"])
}

@Test func `a paragraph without timed spans still stands on its own start`() {
    // A mixed document degrades line by line rather than all at once.
    let source = """
    <tt><body><div>
    <p begin="2.0"><span>plain grouping span</span></p>
    </div></body></tt>
    """
    let line = try! #require(LyricsParser.parse(source, format: "ttml").lines.first)

    #expect(line.start == 2)
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

@Test func `the fill sweeps across the line's own span`() {
    // Consecutive sung lines four seconds apart: the words of the first are
    // sung across that interval, so the fill tracks it and completes as the
    // next line begins.
    let lyrics = LyricsParser.parse(
        """
        [00:05.00]alpha bravo charlie
        [00:09.00]delta
        """,
        format: "lrc"
    )
    let first = try! #require(lyrics.lines.first)

    #expect(first.end == 9)
    #expect(first.fractionSung(by: 5) == 0)
    #expect(abs(first.fractionSung(by: 7) - 0.5) < 0.001)
    #expect(first.fractionSung(by: 9) == 1)
    // Outside its span the fill is clamped rather than running past itself.
    #expect(first.fractionSung(by: 0) == 0)
    #expect(first.fractionSung(by: 99) == 1)
}

@Test func `a line held open before a break does not crawl`() {
    // The last line before an instrumental owns the silence in its span.
    // Sweeping across all of it would still be filling long after the
    // singing stopped, so the fill is capped.
    let lyrics = LyricsParser.parse(
        """
        [00:05.00]alpha
        [00:30.00]bravo
        """,
        format: "lrc"
    )
    let first = try! #require(lyrics.lines.first)

    // A break is marked, which already bounds the span.
    #expect(first.end == 9)
    #expect(first.fractionSung(by: 9) == 1)
}

@Test func `a line whose successor follows at once still sweeps`() {
    // Half a second would read as a flash rather than a fill.
    let lyrics = LyricsParser.parse("[00:01.00]ab\n[00:01.50]cd", format: "lrc")
    let first = try! #require(lyrics.lines.first)

    #expect(first.fractionSung(by: 1.5) < 1)
    #expect(first.fractionSung(by: 2.2) == 1)
}

@Test func `the fill span the glow is placed against matches the fill`() {
    // The panel places each word's flare along the same span the fill
    // crosses. If the two ever disagreed the glow would lead or trail the
    // words it belongs to, which is the drift this span exists to prevent.
    let lyrics = LyricsParser.parse(
        """
        [00:01.00]alpha
        [00:01.50]bravo
        [00:05.50]charlie
        [00:30.00]delta
        """,
        format: "lrc"
    )
    let lines = lyrics.lines
    #expect(lines.count >= 3)

    for line in lines where line.fillDuration > 0 {
        #expect(line.fractionSung(by: line.start) == 0)
        #expect(line.fractionSung(by: line.start + line.fillDuration) == 1)
        let middle = line.fractionSung(by: line.start + line.fillDuration / 2)
        #expect(abs(middle - 0.5) < 0.001)
    }

    // A line crowded by its successor is still given the floor, and one
    // holding a silence open is still capped.
    #expect(lines[0].fillDuration == 1.2)
    #expect(lines[2].fillDuration <= 6)
}

@Test func `long silences are marked as instrumental breaks`() {
    // A gap long enough to be a solo gets a wordless line, so the panel
    // moves through it instead of sitting on the last line sung.
    let lyrics = LyricsParser.parse(
        """
        [00:20.00]alpha
        [00:45.00]bravo
        """,
        format: "lrc"
    )

    #expect(lyrics.lines.count == 4)
    // An intro counts too: the first line is twenty seconds in.
    #expect(lyrics.lines[0].text.isEmpty)
    #expect(lyrics.lines[0].start == 0)
    #expect(lyrics.lines[1].text == "alpha")
    // The break begins a plausible singing-length after the line started,
    // because a line-timed source never records when a line ends.
    #expect(lyrics.lines[2].text.isEmpty)
    #expect(lyrics.lines[2].start == 24)
    #expect(lyrics.lines[3].text == "bravo")
}

@Test func `ordinary spacing between lines is not a break`() {
    // Short gaps are just how sung lines sit apart; marking them would put
    // a note between every couplet.
    let lyrics = LyricsParser.parse(
        """
        [00:01.00]alpha
        [00:05.00]bravo
        [00:09.00]charlie
        """,
        format: "lrc"
    )

    #expect(lyrics.lines.count == 3)
    #expect(lyrics.lines.allSatisfy { !$0.text.isEmpty })
}

@Test func `a dual-language title is tried in both of its forms`() {
    // A lyric database indexes a song under one title. YouTube Music reports
    // the original and its romanisation joined by a dash, and the combined
    // string matches neither - measured against the service, the combined
    // form returns nothing where the romanised half returns results.
    let queries = LRCLibRequest.queries(
        title: "五等分の軌跡 - Gotobun no Kiseki",
        artist: "Nakanoke no Itsutsugo"
    )

    // Widest first, so a precise match is preferred.
    #expect(queries.first == "五等分の軌跡 - Gotobun no Kiseki Nakanoke no Itsutsugo")
    // Both halves are tried with the artist.
    #expect(queries.contains("Gotobun no Kiseki Nakanoke no Itsutsugo"))
    #expect(queries.contains("五等分の軌跡 Nakanoke no Itsutsugo"))
    // And each title alone, for a database that indexes no artist match.
    #expect(queries.contains("Gotobun no Kiseki"))
}

@Test func `a qualifier the database does not carry is dropped`() {
    let queries = LRCLibRequest.queries(
        title: "A Song (TV Size)",
        artist: "A Band"
    )
    #expect(queries.first == "A Song (TV Size) A Band")
    #expect(queries.contains("A Song A Band"))

    // Nothing repeats: a plain title yields one query per form, not four.
    let plain = LRCLibRequest.queries(title: "A Song", artist: "A Band")
    #expect(plain == ["A Song A Band", "A Song"])
}

@Test func `rich lyrics use better lyrics timing lead`() {
    let rich = LyricsParser.parse(
        "[00:01.00]<00:01.00>one <00:01.50>two",
        format: "lrc"
    )
    let line = LyricsParser.parse("[00:01.00]one two", format: "lrc")
    let plain = LyricsParser.parse("one two", format: "plain")

    #expect(rich.timingLead == 0.150)
    #expect(line.timingLead == 0.115)
    #expect(plain.timingLead == 0)
}

@Test func `bini search accepts only its lyric storage and matching cut`() {
    let body = Data(
        """
        {"results":[
          {"duration":90,"timing_type":"word","lyricsUrl":"https://lyrics-storage.binimum.org/short.ttml"},
          {"duration":199,"timing_type":"word","lyricsUrl":"https://example.com/wrong.ttml"},
          {"duration":200,"timing_type":"word","lyricsUrl":"https://lyrics-storage.binimum.org/right.ttml"}
        ]}
        """.utf8
    )

    #expect(
        BiniLyricsRequest.lyricURL(from: body, duration: 200)?.lastPathComponent
            == "right.ttml"
    )
    #expect(
        BiniLyricsRequest.isTrustedStorageURL(
            URL(string: "https://lyrics-storage.binimum.org/a.ttml")!
        )
    )
    #expect(
        BiniLyricsRequest.isTrustedStorageURL(
            URL(string: "https://example.com/a.ttml")!
        ) == false
    )
}

@Test func `bini and legato try cleaned title alternates`() {
    let bini = BiniLyricsRequest.urls(
        title: "A Song (TV Size)",
        artist: "A Band",
        duration: 90
    )
    let legato = LegatoLyricsRequest.urls(
        title: "A Song (TV Size)",
        artist: "A Band",
        duration: 90
    )

    #expect(bini.count == 2)
    #expect(bini.last?.query?.contains("track=A%20Song") == true)
    #expect(legato.count == 2)
    #expect(legato.last?.query?.contains("s=A%20Song") == true)
}

@Test func `legato response becomes a line timed fallback`() {
    let direct = Data(#"{"lyrics":"[00:01.00]alpha\n[00:03.00]bravo"}"#.utf8)
    let nested = Data(
        #"{"lyrics":"{\"lyrics\":\"[00:02.00]charlie\"}"}"#.utf8
    )

    #expect(LegatoLyricsRequest.lyrics(from: direct).lines.map(\.text) == ["alpha", "bravo"])
    #expect(LegatoLyricsRequest.lyrics(from: nested).lines.first?.text == "charlie")
}
