import Foundation

/// What the injected observer reports back from the page.
///
/// The page and this side agree on JSON rather than a dictionary so the
/// payload decodes as a value and can be tested without a web view.
/// One thing a search turned up.
nonisolated struct MusicSearchResult: Equatable, Sendable, Identifiable, Decodable {
    var videoId: String
    var title: String
    var subtitle: String
    var artwork: String?

    var id: String { videoId }

    var artworkURL: URL? {
        artwork.flatMap { MusicArtworkURL.upscaled(from: $0, size: 96) }
    }
}

nonisolated enum MusicBridgeEvent: Equatable, Sendable {
    case ready
    case state(MusicPlaybackState)
    case signedOut
    case searchResults(query: String, results: [MusicSearchResult])

    private struct Payload: Decodable {
        var type: String
        var videoId: String?
        var title: String?
        var artist: String?
        var artwork: String?
        var isPlaying: Bool?
        var progress: Double?
        var duration: Double?
        var likeStatus: String?
        var isAd: Bool?
        var query: String?
        var results: [MusicSearchResult]?
    }

    /// Decodes one observer message. Anything unrecognised or malformed
    /// returns nil: the page's markup is not a contract this side controls,
    /// so a shape that no longer parses has to leave the last good state
    /// alone rather than tearing the bar down.
    static func decode(from json: String) -> MusicBridgeEvent? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }

        switch payload.type {
        case "READY":
            return .ready
        case "SIGNED_OUT":
            return .signedOut
        case "STATE":
            return .state(state(from: payload))
        case "SEARCH":
            return .searchResults(
                query: payload.query ?? "",
                results: payload.results ?? []
            )
        default:
            return nil
        }
    }

    private static func state(from payload: Payload) -> MusicPlaybackState {
        MusicPlaybackState(
            videoID: payload.videoId ?? "",
            title: payload.title ?? "",
            artist: payload.artist ?? "",
            artworkURL: payload.artwork.flatMap { MusicArtworkURL.upscaled(from: $0) },
            isPlaying: payload.isPlaying ?? false,
            progress: finite(payload.progress),
            duration: finite(payload.duration),
            likeStatus: payload.likeStatus
                .flatMap(MusicLikeStatus.init(rawValue:)) ?? .indifferent,
            isAdvertisement: payload.isAd ?? false
        )
    }

    /// JavaScript reports an unresolved time as NaN or Infinity, both of
    /// which survive JSON as a number and then poison every arithmetic that
    /// touches them. They land here as zero instead.
    private static func finite(_ value: Double?) -> TimeInterval {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }
}

/// The player bar's thumbnail is served at the size the bar itself draws,
/// which is far too small for album art. Google's image host takes the size
/// in the path, so asking for a larger one is a rewrite rather than a
/// different request.
nonisolated enum MusicArtworkURL {
    static func upscaled(from source: String, size: Int = 256) -> URL? {
        guard let url = URL(string: source) else { return nil }
        guard let range = source.range(
            of: "=w[0-9]+-h[0-9]+",
            options: .regularExpression
        ) else { return url }
        return URL(string: source.replacingCharacters(
            in: range,
            with: "=w\(size)-h\(size)"
        )) ?? url
    }
}
