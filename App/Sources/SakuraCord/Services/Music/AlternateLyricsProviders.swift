import Foundation

/// Searches BiniLyrics and resolves its result to the rich TTML document.
///
/// BiniLyrics is Better Lyrics' next open rich-sync source after Unison. Its
/// search response points at a separate storage origin; accepting only that
/// exact HTTPS host keeps a compromised response from turning lyric lookup
/// into an arbitrary native fetch.
nonisolated enum BiniLyricsRequest {
    static let endpoint = URL(string: "https://lyrics-api.binimum.org/")!
    private static let storageHost = "lyrics-storage.binimum.org"

    static func urls(
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> [URL] {
        LRCLibRequest.titles(title: title).compactMap { title in
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "track", value: title),
                URLQueryItem(name: "artist", value: artist),
                URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
            ]
            return components?.url
        }
    }

    struct Envelope: Decodable, Sendable {
        var results: [Result]
    }

    struct Result: Decodable, Sendable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var timingType: String?
        var lyricsURL: URL?

        private enum CodingKeys: String, CodingKey {
            case trackName = "track_name"
            case artistName = "artist_name"
            case duration
            case timingType = "timing_type"
            case lyricsURL = "lyricsUrl"
        }
    }

    /// Picks the same recording rather than a cover, edit or extended cut.
    static func lyricURL(from body: Data, duration: TimeInterval) -> URL? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        else { return nil }

        let candidates: [Result]
        if duration > 0 {
            let tolerance = max(5, duration * 0.08)
            candidates = envelope.results
                .filter { result in
                    guard let candidateDuration = result.duration else { return false }
                    return abs(candidateDuration - duration) <= tolerance
                }
                .sorted {
                    abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration)
                }
        } else {
            candidates = envelope.results
        }

        return candidates.lazy.compactMap(\.lyricsURL).first(where: isTrustedStorageURL)
    }

    static func isTrustedStorageURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == storageHost
    }
}

/// Better Lyrics' open Legato line-timed fallback, backed by KuGou.
nonisolated enum LegatoLyricsRequest {
    static let endpoint = URL(
        string: "https://lyrics-api.boidu.dev/kugou/getLyrics"
    )!

    static func urls(
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> [URL] {
        LRCLibRequest.titles(title: title).compactMap { title in
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "s", value: title),
                URLQueryItem(name: "a", value: artist),
                URLQueryItem(name: "d", value: String(Int(duration.rounded())))
            ]
            return components?.url
        }
    }

    private struct Envelope: Decodable {
        var lyrics: String?
    }

    static func lyrics(from body: Data) -> TimedLyrics {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
              var source = envelope.lyrics,
              !source.isEmpty
        else { return .empty }

        // Older Legato responses double-encoded the LRC in a small JSON
        // object. Current ones return it directly; reading both costs almost
        // nothing and keeps the fallback useful across the service migration.
        if let nested = source.data(using: .utf8)
            .flatMap({ try? JSONDecoder().decode(Envelope.self, from: $0) }),
            let unwrapped = nested.lyrics,
            !unwrapped.isEmpty
        {
            source = unwrapped
        }
        return LyricsParser.parse(source, format: "lrc")
    }
}
