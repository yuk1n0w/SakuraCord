import Foundation

/// What the injected observer reports back from the page.
///
/// The page and this side agree on JSON rather than a dictionary so the
/// payload decodes as a value and can be tested without a web view.
/// One thing a search turned up.
nonisolated struct MusicSearchResult: Equatable, Sendable, Identifiable, Decodable {
    /// A single track. Empty for a card that is a playlist or an album.
    var videoId: String = ""

    /// A playlist or album, which is most of what a home feed offers.
    var playlistId: String = ""

    /// The page's own id for opening this, which is not derivable: an
    /// album's browse id is not its playlist id behind a prefix.
    var browseId: String = ""

    var title: String
    var subtitle: String
    var artwork: String?

    var id: String { videoId.isEmpty ? playlistId : videoId }

    private enum CodingKeys: String, CodingKey {
        case videoId, playlistId, browseId, title, subtitle, artwork
    }

    /// Decoded field by field rather than by the synthesised initialiser.
    ///
    /// Swift's synthesised decoding ignores these defaults and demands every
    /// key, so one field missing from the page's payload failed the whole
    /// item, which failed the whole array, which emptied the entire feed.
    /// A bridge and a model that change independently must not be able to
    /// take each other down over a field that was not sent.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try container.decodeIfPresent(String.self, forKey: .videoId) ?? ""
        playlistId = try container.decodeIfPresent(String.self, forKey: .playlistId) ?? ""
        browseId = try container.decodeIfPresent(String.self, forKey: .browseId) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        artwork = try container.decodeIfPresent(String.self, forKey: .artwork)
    }

    /// Artwork at the size it will be drawn.
    ///
    /// The size is asked for rather than fixed: the page serves its
    /// thumbnails at the size its own rows draw, which is far below what a
    /// card needs, and asking for one size everywhere means either a blurry
    /// card or a wastefully large row.
    func artworkURL(size: Int) -> URL? {
        artwork.flatMap { MusicArtworkURL.upscaled(from: $0, size: size) }
    }
}

/// A shelf of the home feed, named the way the page names it.
nonisolated struct MusicBrowseSection: Equatable, Sendable, Identifiable, Decodable {
    var title: String
    var items: [MusicSearchResult]

    private enum CodingKeys: String, CodingKey {
        case title, items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        items = try container.decodeIfPresent([MusicSearchResult].self, forKey: .items) ?? []
    }

    /// The title is what the page calls the shelf, and two shelves are
    /// never given the same name in one feed.
    var id: String { title }
}

/// Keeps the deliberately small native home surface to the two useful music
/// shelves. Listening history comes from the rendered page and Quick picks
/// from its recommendation response; the two are kept separate and ordered
/// the same way every time either source refreshes.
nonisolated enum MusicHomeFeed {
    static func visibleSections(
        from sections: [MusicBrowseSection]
    ) -> [MusicBrowseSection] {
        [
            canonicalSection(named: "Listen again", from: sections),
            canonicalSection(named: "Quick picks", from: sections),
        ].compactMap { $0 }
    }

    private static func canonicalSection(
        named title: String,
        from sections: [MusicBrowseSection]
    ) -> MusicBrowseSection? {
        guard var section = sections.first(where: {
            normalized($0.title) == normalized(title)
        }) else { return nil }
        section.title = title
        return section
    }

    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

nonisolated enum MusicBridgeEvent: Equatable, Sendable {
    case ready
    case state(MusicPlaybackState)
    case signedOut
    case searchResults(query: String, results: [MusicSearchResult])
    case home(sections: [MusicBrowseSection])
    case list(browseId: String, results: [MusicSearchResult])

    private struct Payload: Decodable {
        var type: String
        var videoId: String?
        var title: String?
        var artist: String?
        var artwork: String?
        var isPlaying: Bool?
        var isClockRunning: Bool?
        var playbackRate: Double?
        var progress: Double?
        var duration: Double?
        var sampledAt: Double?
        var likeStatus: String?
        var isAd: Bool?
        var isSignedIn: Bool?
        var query: String?
        var results: [MusicSearchResult]?
        var sections: [MusicBrowseSection]?
        var browseId: String?
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
        case "LIST":
            return .list(
                browseId: payload.browseId ?? "",
                results: payload.results ?? []
            )
        case "HOME":
            return .home(sections: payload.sections ?? [])
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
        let isPlaying = payload.isPlaying ?? false
        return MusicPlaybackState(
            videoID: payload.videoId ?? "",
            title: payload.title ?? "",
            artist: payload.artist ?? "",
            artworkURL: payload.artwork.flatMap { MusicArtworkURL.upscaled(from: $0) },
            isPlaying: isPlaying,
            isClockRunning: payload.isClockRunning ?? isPlaying,
            playbackRate: positive(payload.playbackRate, default: 1),
            progress: finite(payload.progress),
            duration: finite(payload.duration),
            likeStatus: payload.likeStatus
                .flatMap(MusicLikeStatus.init(rawValue:)) ?? .indifferent,
            sampledAt: sampledDate(milliseconds: payload.sampledAt),
            isAdvertisement: payload.isAd ?? false,
            isSignedIn: payload.isSignedIn ?? false
        )
    }

    /// JavaScript reports an unresolved time as NaN or Infinity, both of
    /// which survive JSON as a number and then poison every arithmetic that
    /// touches them. They land here as zero instead.
    private static func finite(_ value: Double?) -> TimeInterval {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }

    private static func positive(_ value: Double?, default fallback: Double) -> Double {
        guard let value, value.isFinite, value > 0 else { return fallback }
        return value
    }

    private static func sampledDate(milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

/// The player bar's thumbnail is served at the size the bar itself draws,
/// which is far too small for album art. Google's image host takes the size
/// in the path, so asking for a larger one is a rewrite rather than a
/// different request.
nonisolated enum MusicArtworkURL {
    static func upscaled(from source: String, size: Int = 256) -> URL? {
        guard let url = URL(string: source) else { return nil }

        // Google's image host takes the size in the path, so a larger one is
        // a rewrite rather than a different request.
        if let range = source.range(
            of: "=w[0-9]+-h[0-9]+",
            options: .regularExpression
        ) {
            return URL(string: source.replacingCharacters(
                in: range,
                with: "=w\(size)-h\(size)"
            )) ?? url
        }

        // Video thumbnails carry no size at all, only a named variant. The
        // default is 120 points wide and looks it; the larger names are the
        // only way up.
        if source.contains("/vi/") {
            let name = size > 320 ? "maxresdefault" : "hqdefault"
            if let range = source.range(
                of: "/(default|mqdefault|hqdefault|sddefault|maxresdefault)\\.jpg",
                options: .regularExpression
            ) {
                return URL(string: source.replacingCharacters(
                    in: range,
                    with: "/\(name).jpg"
                )) ?? url
            }
        }

        return url
    }
}
