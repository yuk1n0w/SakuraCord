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

/// Holds the words for whatever is playing.
///
/// Sources are tried in order and the first that answers wins. LRCLib leads
/// because it is open, needs no credential, and indexes by title and artist
/// rather than by video id - so it answers even when the page has not told
/// us which video is playing. The community service follows for the tracks
/// LRCLib has never seen.
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

    /// The track the current words belong to, so a late response for a
    /// track that has already been skipped past is discarded rather than
    /// shown against the wrong song.
    @ObservationIgnored private var loadedTrack: String?
    @ObservationIgnored private var missingTracks: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession = .shared
    @ObservationIgnored private let logger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "Lyrics"
    )

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
        guard identity != loadedTrack else { return }

        loadedTrack = identity
        lyrics = .empty
        task?.cancel()

        guard !missingTracks.contains(identity) else {
            status = .unavailable
            return
        }

        status = .searching
        task = Task { [weak self] in
            await self?.load(for: state, identity: identity)
        }
    }

    private func load(for state: MusicPlaybackState, identity: String) async {
        let found = await lookUp(state)
        guard !Task.isCancelled, loadedTrack == identity else { return }
        if found.isEmpty {
            missingTracks.insert(identity)
            status = .unavailable
        } else {
            lyrics = found
            status = .found
        }
    }

    /// Tries each source until one answers.
    private func lookUp(_ state: MusicPlaybackState) async -> TimedLyrics {
        if let request = LRCLibRequest.request(title: state.title, artist: state.artist) {
            if let body = await body(for: request) {
                let found = LRCLibRequest.lyrics(from: body, duration: state.duration)
                if !found.isEmpty { return found }
            }
        }
        if let url = UnisonLyricsRequest.url(
            videoID: state.videoID,
            title: state.title,
            artist: state.artist,
            duration: state.duration
        ), let body = await body(for: URLRequest(url: url)) {
            return UnisonLyricsRequest.lyrics(from: body)
        }
        return .empty
    }

    /// A source that answers "not found" and a source that could not be
    /// reached are both just "no words from here": the chain moves on to
    /// the next either way.
    private func body(for request: URLRequest) async -> Data? {
        do {
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
        loadedTrack = nil
        lyrics = .empty
        status = .idle
    }
}
