import Foundation

/// A track's like state, as YouTube Music reports it on its player bar.
nonisolated enum MusicLikeStatus: String, Equatable, Sendable {
    case liked = "LIKE"
    case disliked = "DISLIKE"
    case indifferent = "INDIFFERENT"
}

/// What the web player is playing, as the page itself reports it.
///
/// YouTube Music has no public playback API, so the page is the only source
/// of truth: every field here is read back out of the running player rather
/// than commanded from this side. That makes staleness the failure to guard
/// against - a field the page stops reporting empties rather than holding
/// its last value on screen, so the bar goes quiet instead of lying.
nonisolated struct MusicPlaybackState: Equatable, Sendable {
    /// YouTube's identifier for the track. Titles churn - the page corrects
    /// them a beat after a change, and the same song appears under many -
    /// so anything looking a track up keys off this instead.
    var videoID: String = ""

    var title: String = ""
    var artist: String = ""
    var artworkURL: URL?
    var isPlaying: Bool = false
    var progress: TimeInterval = 0
    var duration: TimeInterval = 0
    var likeStatus: MusicLikeStatus = .indifferent

    /// An advertisement. The page reports one as an ordinary playing track,
    /// but its title and artist belong to the ad rather than to anything
    /// worth putting in front of someone, so the bar treats it as no track.
    var isAdvertisement: Bool = false

    /// Nothing is playing and nothing is loaded.
    static let idle = MusicPlaybackState()

    /// Whether there is a track worth showing. An advertisement is playing
    /// audio but is not a track, and a player that has loaded nothing yet
    /// reports an empty title.
    var hasTrack: Bool {
        !isAdvertisement && !title.isEmpty
    }

    /// How far through the track playback is, as a fraction. A duration the
    /// page has not resolved yet reads as zero rather than dividing by it.
    var fractionComplete: Double {
        guard duration > 0, progress.isFinite, duration.isFinite else { return 0 }
        return min(max(progress / duration, 0), 1)
    }
}
