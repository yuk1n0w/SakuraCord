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

    /// Whether the player intends to play. This stays true while YouTube is
    /// buffering, which is what keeps the transport showing Pause rather
    /// than flickering back to Play during an ordinary network stall.
    var isPlaying: Bool = false

    /// Whether the media clock is advancing right now.
    ///
    /// YouTube reports `isPlaying` through buffering and seeking. Carrying
    /// the last progress report through either one makes richly timed lyrics
    /// run ahead of the voice, so interpolation follows this narrower value.
    var isClockRunning: Bool = false

    /// The media element's rate when the progress snapshot was taken.
    var playbackRate: Double = 1

    var progress: TimeInterval = 0
    var duration: TimeInterval = 0
    var likeStatus: MusicLikeStatus = .indifferent

    /// The wall-clock instant at which the page sampled `progress`.
    /// Bridge delivery is normally quick, but using the source instant keeps
    /// a busy WebKit process from turning delivery latency into lyric drift.
    var sampledAt: Date?

    /// An advertisement. The page reports one as an ordinary playing track,
    /// but its title and artist belong to the ad rather than to anything
    /// worth putting in front of someone, so the bar treats it as no track.
    var isAdvertisement: Bool = false

    /// Whether the page has a Google session. Signing in happens on the
    /// page itself, so this is what decides whether to offer it.
    var isSignedIn: Bool = false

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

    /// Whether replacing one state with the other can change anything the
    /// interface presents immediately.
    ///
    /// Progress is deliberately excluded. The page reports it every second,
    /// while the visible clock is interpolated from the latest report. Making
    /// progress part of the observed value invalidated the complete sidebar,
    /// lyrics panel and menu-command graph once a second for no visual gain.
    func hasSamePresentation(as other: Self) -> Bool {
        var lhs = self
        var rhs = other
        lhs.progress = 0
        rhs.progress = 0
        lhs.sampledAt = nil
        rhs.sampledAt = nil
        return lhs == rhs
    }
}
