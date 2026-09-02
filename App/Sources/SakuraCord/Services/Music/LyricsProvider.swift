import Foundation
import Observation
import OSLog

/// Builds a lookup against the Better Lyrics community lyric service.
///
/// The service is keyed by YouTube's video id, with the title, artist and
/// duration alongside it so it can fall back to matching a song it knows
/// under a different id. Better Lyrics sends a per-install identity header
/// so it can attribute votes; SakuraCord only reads, so it sends nothing
/// that would identify the listener.
nonisolated enum UnisonLyricsRequest {
    static let endpoint = URL(string: "https://unison.boidu.dev/lyrics")!

    static func url(
        videoID: String,
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> URL? {
        guard !videoID.isEmpty else { return nil }
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "song", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        return components?.url
    }

    /// The service wraps its payload in `data`, and answers 404 when it
    /// knows the track but has no words for it.
    struct Envelope: Decodable, Sendable {
        struct Payload: Decodable, Sendable {
            var lyrics: String?
            var format: String?
            var syncType: String?
        }

        var data: Payload?
    }

    static func lyrics(from body: Data) -> TimedLyrics {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
              let payload = envelope.data,
              let source = payload.lyrics, !source.isEmpty
        else { return .empty }
        return LyricsParser.parse(source, format: payload.format ?? "plain")
    }
}

/// Reads the plain lyric copy returned by YouTube Music's own Lyrics tab.
///
/// This is deliberately a last resort: the page's copy carries no timing,
/// but it is still preferable to an empty panel when every richer community
/// source misses a track that YouTube itself knows.
nonisolated enum YouTubeMusicLyricsResponse {
    static func lyrics(from body: Data) -> TimedLyrics {
        guard let response = try? JSONDecoder().decode(
            YouTubeLyricsRoot.self,
            from: body
        ),
              let runs = response.contents?
                  .sectionListRenderer?
                  .contents?
                  .first?
                  .musicDescriptionShelfRenderer?
                  .description?
                  .runs
        else { return .empty }

        let text = runs.map(\.text).joined()
        return LyricsParser.parse(text, format: "plain")
    }
}

nonisolated private struct YouTubeLyricsRoot: Decodable {
    var contents: YouTubeLyricsContents?
}

nonisolated private struct YouTubeLyricsContents: Decodable {
    var sectionListRenderer: YouTubeLyricsSectionList?
}

nonisolated private struct YouTubeLyricsSectionList: Decodable {
    var contents: [YouTubeLyricsSection]?
}

nonisolated private struct YouTubeLyricsSection: Decodable {
    var musicDescriptionShelfRenderer: YouTubeLyricsDescriptionShelf?
}

nonisolated private struct YouTubeLyricsDescriptionShelf: Decodable {
    var description: YouTubeLyricsDescription?
}

nonisolated private struct YouTubeLyricsDescription: Decodable {
    var runs: [YouTubeLyricsRun]?
}

nonisolated private struct YouTubeLyricsRun: Decodable {
    var text: String
}

typealias YouTubeLyricsPageFetch = @Sendable (String) async -> Data?

/// The metadata that determines one lyric lookup.
///
/// The page publishes the new video id before every other field settles.
/// Keying only by that id made the first, half-old snapshot permanent: later
/// corrected metadata looked like the same request and never got another try.
nonisolated struct LyricsLookupRequest: Equatable, Sendable {
    var identity: String
    var title: String
    var artist: String
    var duration: Int

    init?(state: MusicPlaybackState) {
        guard state.hasTrack,
              let identity = LyricsModel.identity(for: state)
        else { return nil }

        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = state.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !artist.isEmpty,
              state.duration.isFinite,
              state.duration > 0
        else { return nil }

        self.identity = identity
        self.title = title
        self.artist = artist
        duration = Int(state.duration.rounded())
    }
}

/// Holds the words for whatever is playing.
///
/// Sources are ranked by the timing they actually return, then by Better
/// Lyrics' provider order. A rich word/syllable copy therefore beats every
/// line-timed one, and an unsynced copy can never hide a timed alternate.
@Observable
final class LyricsModel {
    /// What the panel should say. A lookup that has not run yet and a
    /// lookup that came back empty look identical on screen unless they are
    /// kept apart, and reading "no lyrics" while a search is still in
    /// flight is how a working feature looks broken.
    enum Status: Equatable, Sendable {
        case idle
        case searching
        case found
        case unavailable
    }

    private(set) var lyrics: TimedLyrics = .empty
    private(set) var status: Status = .idle
    private(set) var showsRomanization: Bool
    private(set) var showsTranslation: Bool
    private(set) var translationLanguage: String

    /// The track the current words belong to, so a late response for a
    /// track that has already been skipped past is discarded rather than
    /// shown against the wrong song.
    @ObservationIgnored private var loadedTrack: String?
    @ObservationIgnored private var loadedRequest: LyricsLookupRequest?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var decorationTask: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession = .shared
    @ObservationIgnored private let languageService = LyricsLanguageService()

    /// How a decoration request reaches the network. Google refuses the
    /// public translation endpoint to a native client, so the player hands
    /// the panel its own page to ask from.
    @ObservationIgnored var pageFetch: LyricsPageFetch?
    @ObservationIgnored var youtubeLyricsFetch: YouTubeLyricsPageFetch?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "Lyrics"
    )

    private static let romanizationDefaultsKey =
        "dev.sakuracord.music.lyrics.romanization"
    private static let translationDefaultsKey =
        "dev.sakuracord.music.lyrics.translation"
    private static let translationLanguageDefaultsKey =
        "dev.sakuracord.music.lyrics.translation-language"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsRomanization = defaults.bool(forKey: Self.romanizationDefaultsKey)
        showsTranslation = defaults.bool(forKey: Self.translationDefaultsKey)
        let storedLanguage = defaults.string(
            forKey: Self.translationLanguageDefaultsKey
        )
        if let storedLanguage,
           LyricsTranslationLanguage.supported.contains(where: {
               $0.code == storedLanguage
           }) {
            translationLanguage = storedLanguage
        } else {
            translationLanguage = "en"
        }
    }

    var translationLanguageName: String {
        LyricsTranslationLanguage.named(translationLanguage)
    }

    func setShowsRomanization(_ showsRomanization: Bool) {
        guard showsRomanization != self.showsRomanization else { return }
        self.showsRomanization = showsRomanization
        defaults.set(showsRomanization, forKey: Self.romanizationDefaultsKey)
        refreshDecorations()
    }

    func setShowsTranslation(_ showsTranslation: Bool) {
        guard showsTranslation != self.showsTranslation else { return }
        self.showsTranslation = showsTranslation
        defaults.set(showsTranslation, forKey: Self.translationDefaultsKey)
        refreshDecorations()
    }

    func setTranslationLanguage(_ language: String) {
        guard LyricsTranslationLanguage.supported.contains(where: {
            $0.code == language
        }), language != translationLanguage else { return }
        translationLanguage = language
        defaults.set(language, forKey: Self.translationLanguageDefaultsKey)
        if showsTranslation { refreshDecorations() }
    }

    /// Identifies the playing track for caching and for discarding stale
    /// responses. The video id is preferred because it survives the title
    /// corrections the page makes just after a change, but a track without
    /// one is still worth looking up, so title and artist stand in.
    nonisolated static func identity(for state: MusicPlaybackState) -> String? {
        if !state.videoID.isEmpty { return state.videoID }
        let fallback = "\(state.title)|\(state.artist)"
        return fallback == "|" ? nil : fallback
    }

    /// Follows the player. Called on every state update, so it has to be
    /// cheap and idempotent for the common case of the same track playing on.
    func track(_ state: MusicPlaybackState) {
        guard state.hasTrack, let identity = Self.identity(for: state) else {
            clear()
            return
        }

        if identity != loadedTrack {
            loadedTrack = identity
            loadedRequest = nil
            lyrics = .empty
            task?.cancel()
            decorationTask?.cancel()
            status = .searching
        }

        // A track transition reports the id first, then fixes title, artist
        // and duration over the next few page mutations. Wait for a complete
        // match instead of firing a lookup against mixed old/new metadata.
        guard let request = LyricsLookupRequest(state: state),
              request != loadedRequest
        else { return }

        loadedRequest = request
        lyrics = .empty
        task?.cancel()
        decorationTask?.cancel()
        status = .searching
        logger.info(
            "lyric lookup: \(state.title, privacy: .public) / \(state.artist, privacy: .public) [\(identity, privacy: .public)] duration \(Int(state.duration))"
        )
        task = Task { [weak self] in
            await self?.load(for: state, request: request)
        }
    }

    private func load(
        for state: MusicPlaybackState,
        request: LyricsLookupRequest
    ) async {
        let found = await lookUp(state)
        guard !Task.isCancelled, loadedRequest == request else { return }
        if found.isEmpty {
            status = .unavailable
            logger.info("lyric lookup: nothing for \(request.identity, privacy: .public)")
        } else {
            lyrics = found
            status = .found
            logger.info(
                "lyric lookup: \(found.lines.count) lines, synced \(found.synchronisation == .line)"
            )
            refreshDecorations()
        }
    }

    private func refreshDecorations() {
        decorationTask?.cancel()
        guard status == .found,
              let identity = loadedTrack,
              let request = loadedRequest,
              showsRomanization || showsTranslation
        else { return }

        guard let pageFetch else {
            logger.info("lyric decorations: no music page to request them from")
            return
        }
        let source = lyrics
        let romanizes = showsRomanization
        let targetLanguage = showsTranslation ? translationLanguage : nil
        decorationTask = Task { [weak self, languageService] in
            let decorated = await languageService.enrich(
                source,
                romanizes: romanizes,
                translationLanguage: targetLanguage,
                fetch: pageFetch
            )
            guard !Task.isCancelled,
                  let self,
                  self.loadedTrack == identity,
                  self.loadedRequest == request
            else { return }
            self.lyrics = decorated
        }
    }

    /// Starts independent sources together, then resolves them in Better
    /// Lyrics' quality order. This keeps a slow line fallback from delaying a
    /// rich answer while avoiding the old first-nonempty bug where LRCLib's
    /// plain text could discard real timing from a later source.
    private func lookUp(_ state: MusicPlaybackState) async -> TimedLyrics {
        async let unisonTask = lookUpUnison(state)
        async let biniTask = lookUpBini(state)
        async let lrcLibTask = lookUpLRCLib(state)
        async let legatoTask = lookUpLegato(state)
        async let youtubeTask = lookUpYouTubeMusic(state)

        let unison = await unisonTask
        let bini = await biniTask

        if unison.isWordTimed {
            return selected(unison, source: "Unison", quality: "word-timed")
        }
        if bini.isWordTimed {
            return selected(bini, source: "BiniLyrics", quality: "word-timed")
        }

        if unison.isLineTimed {
            return selected(unison, source: "Unison", quality: "line-timed")
        }
        if bini.isLineTimed {
            return selected(bini, source: "BiniLyrics", quality: "line-timed")
        }

        let lrcLib = await lrcLibTask
        let legato = await legatoTask
        if lrcLib.isLineTimed {
            return selected(lrcLib, source: "LRCLib", quality: "line-timed")
        }
        if legato.isLineTimed {
            return selected(legato, source: "Legato", quality: "line-timed")
        }

        let youtube = await youtubeTask

        // YouTube's own unsynced copy is Better Lyrics' final page-native
        // fallback. Bini and Legato normally return timed formats, but
        // retaining a readable copy is still better than claiming there are
        // no lyrics if one degrades.
        for (source, found) in [
            ("YouTube Music", youtube),
            ("Unison", unison),
            ("BiniLyrics", bini),
            ("LRCLib", lrcLib),
            ("Legato", legato)
        ] where !found.isEmpty {
            return selected(found, source: source, quality: "unsynced")
        }
        return .empty
    }

    private func lookUpUnison(_ state: MusicPlaybackState) async -> TimedLyrics {
        guard let url = UnisonLyricsRequest.url(
            videoID: state.videoID,
            title: state.title,
            artist: state.artist,
            duration: state.duration
        ), let body = await body(for: URLRequest(url: url)) else { return .empty }
        return UnisonLyricsRequest.lyrics(from: body)
    }

    private func lookUpBini(_ state: MusicPlaybackState) async -> TimedLyrics {
        var fallback = TimedLyrics.empty
        for url in BiniLyricsRequest.urls(
            title: state.title,
            artist: state.artist,
            duration: state.duration
        ) {
            guard !Task.isCancelled else { return .empty }
            guard let searchBody = await body(for: URLRequest(url: url)),
                  let lyricsURL = BiniLyricsRequest.lyricURL(
                    from: searchBody,
                    duration: state.duration
                  ),
                  let source = await body(for: URLRequest(url: lyricsURL)),
                  let text = String(bytes: source, encoding: .utf8)
            else { continue }

            let found = LyricsParser.parse(text, format: "ttml")
            if found.isWordTimed { return found }
            if fallback.isEmpty { fallback = found }
        }
        return fallback
    }

    private func lookUpYouTubeMusic(
        _ state: MusicPlaybackState
    ) async -> TimedLyrics {
        guard !state.videoID.isEmpty,
              let youtubeLyricsFetch,
              let body = await youtubeLyricsFetch(state.videoID)
        else { return .empty }
        return YouTubeMusicLyricsResponse.lyrics(from: body)
    }

    private func lookUpLRCLib(_ state: MusicPlaybackState) async -> TimedLyrics {
        var fallback = TimedLyrics.empty

        for query in LRCLibRequest.queries(title: state.title, artist: state.artist) {
            guard !Task.isCancelled else { return .empty }
            guard let request = LRCLibRequest.request(query: query) else { continue }
            guard let body = await body(for: request) else { continue }
            let found = LRCLibRequest.lyrics(from: body, duration: state.duration)
            if found.isLineTimed { return found }
            if fallback.isEmpty { fallback = found }
        }
        return fallback
    }

    private func lookUpLegato(_ state: MusicPlaybackState) async -> TimedLyrics {
        var fallback = TimedLyrics.empty
        for url in LegatoLyricsRequest.urls(
            title: state.title,
            artist: state.artist,
            duration: state.duration
        ) {
            guard !Task.isCancelled else { return .empty }
            guard let body = await body(for: URLRequest(url: url)) else { continue }
            let found = LegatoLyricsRequest.lyrics(from: body)
            if found.isLineTimed { return found }
            if fallback.isEmpty { fallback = found }
        }
        return fallback
    }

    private func selected(
        _ lyrics: TimedLyrics,
        source: String,
        quality: String
    ) -> TimedLyrics {
        logger.info(
            "lyric lookup: \(quality, privacy: .public) copy from \(source, privacy: .public)"
        )
        return lyrics
    }

    /// A source that answers "not found" and a source that could not be
    /// reached are both just "no words from here": the chain moves on to
    /// the next either way.
    private func body(for request: URLRequest) async -> Data? {
        do {
            var request = request
            request.timeoutInterval = 8
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200
            else { return nil }
            return body
        } catch {
            logger.debug(
                "lyric lookup failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func clear() {
        guard loadedTrack != nil else { return }
        task?.cancel()
        decorationTask?.cancel()
        loadedTrack = nil
        loadedRequest = nil
        lyrics = .empty
        status = .idle
    }
}
