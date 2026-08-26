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

    /// The queries to try, in order, for one track.
    ///
    /// A lyric database indexes a song under one title; YouTube Music
    /// routinely reports two at once - the original and its romanisation,
    /// joined by a dash - and the combined string matches neither. Measured
    /// against the service: the romanised title alone finds a track that the
    /// combined form returns nothing for at all.
    ///
    /// Ordered widest-first so a precise match is preferred, and narrowed
    /// only when that finds nothing.
    static func titles(title: String) -> [String] {
        var titles = [title]

        // Both halves of a dual title, each of which may be the indexed one.
        let separators = [" - ", " – ", " ~ ", "～"]
        for separator in separators where title.contains(separator) {
            titles.append(
                contentsOf: title.components(separatedBy: separator)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            )
        }

        // A qualifier the database does not carry in its title.
        let stripped = title.replacingOccurrences(
            of: #"[\(（\[].*?[\)）\]]"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        titles.append(stripped)

        var unique: [String] = []
        for title in titles {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !unique.contains(trimmed) {
                unique.append(trimmed)
            }
        }
        return unique
    }

    static func queries(title: String, artist: String) -> [String] {
        var queries: [String] = []
        for trimmed in titles(title: title) {
            for query in ["\(trimmed) \(artist)", trimmed] {
                let value = query.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, !queries.contains(value) {
                    queries.append(value)
                }
            }
        }
        return queries
    }

    static func url(query: String) -> URL? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    static func request(query: String) -> URLRequest? {
        guard let url = url(query: query) else { return nil }
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

    /// A duration difference small enough to be metadata disagreement about
    /// the same recording rather than a different one.
    private static let confidentTolerance: TimeInterval = 5

    /// Beyond the confident window, how far a result may still be from the
    /// playing track before it is a different cut altogether. Proportional,
    /// because a few seconds means something different on a ninety-second
    /// edit than on a ten-minute one.
    private static let proportionalTolerance = 0.08

    /// Picks the recording that is actually playing.
    ///
    /// Duration is the discriminator: the same song is indexed many times -
    /// TV edits, movie sizes, extended versions, covers - and a lyric timed
    /// against a different cut drifts further out of step the longer it
    /// plays.
    ///
    /// It is matched in two tiers, because an exact window is too strict to
    /// be useful. YouTube's duration and a lyric database's routinely
    /// disagree by a few seconds on the same recording, and demanding
    /// agreement within a few seconds threw away every usable result for a
    /// track the database plainly had. So: prefer anything that agrees
    /// closely, then fall back to the nearest within a proportional bound,
    /// and only past that decide it is a different recording and show
    /// nothing.
    static func select(
        from results: [Result],
        duration: TimeInterval
    ) -> TimedLyrics {
        let usable = results.filter { $0.instrumental != true }
        guard duration > 0 else { return best(of: usable) }

        let byCloseness = usable.sorted {
            abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration)
        }
        let confident = byCloseness.filter {
            abs(($0.duration ?? 0) - duration) <= confidentTolerance
        }
        if let picked = best(of: confident).nonEmpty { return picked }

        let plausible = byCloseness.filter {
            abs(($0.duration ?? 0) - duration) <= duration * proportionalTolerance
        }
        return best(of: plausible)
    }

    /// A timed lyric is worth more than a closer duration, so a synced
    /// result wins even when an unsynced one matches marginally better.
    private static func best(of candidates: [Result]) -> TimedLyrics {
        if let synced = candidates.first(where: { !($0.syncedLyrics ?? "").isEmpty }),
           let source = synced.syncedLyrics {
            return LyricsParser.parse(source, format: "lrc")
        }
        if let plain = candidates.first(where: { !($0.plainLyrics ?? "").isEmpty }),
           let source = plain.plainLyrics {
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

// The target isolates to the main actor by default; this is read from
// nonisolated matching code, so it opts out explicitly.
private nonisolated extension TimedLyrics {
    /// The lyric itself when there is one, so an empty tier falls through
    /// to the next rather than being mistaken for an answer.
    var nonEmpty: TimedLyrics? { isEmpty ? nil : self }
}
