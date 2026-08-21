import Foundation

/// Looks a song up on LRCLib.
///
/// LRCLib is open, unauthenticated, and meant to be called by third-party
/// players, which is why it leads the chain: Better Lyrics' own aggregator
/// sits behind a Turnstile challenge that only a browser can answer, and
/// the community service alone turns out to know very few tracks.
///
/// The search endpoint is used rather than the exact-match one because the
/// metadata a player reports is not the metadata a lyric database was
/// indexed under - punctuation, romanisation and featured artists all
/// differ - so the match is made here, against duration.
nonisolated enum LRCLibRequest {
    static let endpoint = URL(string: "https://lrclib.net/api/search")!

    /// LRCLib asks callers to identify themselves rather than pretend to be
    /// a browser, and honouring that is the price of an open service.
    static let userAgent = "SakuraCord (https://github.com/yuk1n0w/SakuraCord)"

    static func url(title: String, artist: String) -> URL? {
        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    static func request(title: String, artist: String) -> URLRequest? {
        guard let url = url(title: title, artist: artist) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    struct Result: Decodable, Sendable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    /// Picks the recording that is actually playing.
    ///
    /// Duration is the discriminator: the same song is indexed many times -
    /// TV edits, extended versions, covers - and a lyric timed against a
    /// different cut drifts further out of step the longer it plays. A
    /// result more than a few seconds from the playing track is a different
    /// recording, and no lyric beats a confidently wrong one.
    static func select(
        from results: [Result],
        duration: TimeInterval
    ) -> TimedLyrics {
        let tolerance: TimeInterval = 4
        let usable = results.filter { $0.instrumental != true }
        let matching = duration > 0
            ? usable.filter { abs(($0.duration ?? 0) - duration) <= tolerance }
            : usable

        // With no duration to match on, the database's own ranking is the
        // only signal available, so the first result stands.
        let candidates = duration > 0
            ? matching.sorted {
                abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration)
            }
            : matching

        // A timed lyric is worth more than a closer duration, so a synced
        // result wins even when an unsynced one matches marginally better.
        if let synced = candidates.first(where: {
            !($0.syncedLyrics ?? "").isEmpty
        }), let source = synced.syncedLyrics {
            return LyricsParser.parse(source, format: "lrc")
        }
        if let plain = candidates.first(where: {
            !($0.plainLyrics ?? "").isEmpty
        }), let source = plain.plainLyrics {
            return LyricsParser.parse(source, format: "plain")
        }
        return .empty
    }

    static func lyrics(from body: Data, duration: TimeInterval) -> TimedLyrics {
        guard let results = try? JSONDecoder().decode([Result].self, from: body)
        else { return .empty }
        return select(from: results, duration: duration)
    }
}
