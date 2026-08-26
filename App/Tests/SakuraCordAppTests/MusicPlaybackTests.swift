import Foundation
import MediaPipeline
import Testing
@testable import SakuraCord

@Test func `the bridge reads a playing track off the page`() {
    let event = MusicBridgeEvent.decode(from: """
    {"type":"STATE","title":"Ur Not Alone","artist":"Chevy",
     "artwork":"https://lh3.googleusercontent.com/abc=w60-h60-l90-rj",
     "isPlaying":true,"isClockRunning":false,"playbackRate":1.25,
     "progress":42.5,"duration":210,"sampledAt":1787356800000,
     "likeStatus":"LIKE","isAd":false}
    """)

    guard case let .state(state) = event else {
        Issue.record("expected a state event, got \(String(describing: event))")
        return
    }
    #expect(state.title == "Ur Not Alone")
    #expect(state.artist == "Chevy")
    #expect(state.isPlaying)
    #expect(state.isClockRunning == false)
    #expect(state.playbackRate == 1.25)
    #expect(state.sampledAt == Date(timeIntervalSince1970: 1_787_356_800))
    #expect(state.likeStatus == .liked)
    #expect(state.hasTrack)
    // The bar draws artwork far larger than the page's own thumbnail, and
    // the size lives in the path rather than in a query.
    #expect(
        state.artworkURL?.absoluteString
            == "https://lh3.googleusercontent.com/abc=w256-h256-l90-rj"
    )
}

@Test func `an advertisement is playing but is not a track`() {
    let event = MusicBridgeEvent.decode(from: """
    {"type":"STATE","title":"Some Ad","artist":"A Brand",
     "isPlaying":true,"progress":3,"duration":30,"isAd":true}
    """)

    guard case let .state(state) = event else {
        Issue.record("expected a state event")
        return
    }
    // The ad's own title is not something to put in front of someone, so the
    // bar treats it as nothing playing even though audio is running.
    #expect(state.isAdvertisement)
    #expect(state.hasTrack == false)
}

@Test func `the bridge refuses a payload it cannot read`() {
    // The page's markup is not a contract, so a shape that stops parsing has
    // to leave the last good state alone rather than clearing the bar.
    #expect(MusicBridgeEvent.decode(from: "not json") == nil)
    #expect(MusicBridgeEvent.decode(from: #"{"type":"WHAT"}"#) == nil)
    #expect(MusicBridgeEvent.decode(from: #"{"type":"READY"}"#) == .ready)
}

@Test func `an unresolved duration never reaches arithmetic`() {
    // JavaScript reports an unresolved time as null here rather than a
    // number; either way it must not become a progress fraction.
    let event = MusicBridgeEvent.decode(from: """
    {"type":"STATE","title":"Loading","artist":"","isPlaying":false,
     "progress":null,"duration":null}
    """)

    guard case let .state(state) = event else {
        Issue.record("expected a state event")
        return
    }
    #expect(state.duration == 0)
    #expect(state.fractionComplete == 0)
}

@Test func `playhead ticks do not invalidate music presentation state`() {
    let earlier = MusicPlaybackState(
        videoID: "abc",
        title: "A Song",
        artist: "A Band",
        isPlaying: true,
        progress: 10,
        duration: 200
    )
    var later = earlier
    later.progress = 11

    #expect(earlier.hasSamePresentation(as: later))

    later.isPlaying = false
    #expect(earlier.hasSamePresentation(as: later) == false)
}

@Test func `a call takes the audio and gives it back`() {
    // Connecting counts as being in a call: audio is a moment away, and
    // waiting for `connected` would let a track play over the join.
    #expect(MusicVoiceCoordinationPolicy.callHoldsAudio(during: .connecting))
    #expect(MusicVoiceCoordinationPolicy.callHoldsAudio(during: .connected))
    // Reconnecting has not left the call, so the music stays down rather
    // than starting up mid-conversation while the session retries.
    #expect(MusicVoiceCoordinationPolicy.callHoldsAudio(during: .reconnecting))

    for state in [
        VoiceSessionState.idle, .disconnecting, .disconnected, .failed
    ] {
        #expect(MusicVoiceCoordinationPolicy.callHoldsAudio(during: state) == false)
    }
}

@Test func `artwork is asked for at the size it is drawn`() {
    // Google's image host takes the size in the path, so a bigger one is a
    // rewrite. The page serves the size its own small rows draw.
    #expect(
        MusicArtworkURL.upscaled(
            from: "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj",
            size: 360
        )?.absoluteString == "https://lh3.googleusercontent.com/abc=w360-h360-l90-rj"
    )

    // A video thumbnail carries no size at all, only a named variant, so
    // the name is the only way up.
    #expect(
        MusicArtworkURL.upscaled(
            from: "https://i.ytimg.com/vi/abc123/default.jpg",
            size: 360
        )?.absoluteString == "https://i.ytimg.com/vi/abc123/maxresdefault.jpg"
    )
    #expect(
        MusicArtworkURL.upscaled(
            from: "https://i.ytimg.com/vi/abc123/default.jpg",
            size: 120
        )?.absoluteString == "https://i.ytimg.com/vi/abc123/hqdefault.jpg"
    )

    // A URL in neither shape is left exactly as it came rather than being
    // mangled into one that resolves to nothing.
    #expect(
        MusicArtworkURL.upscaled(from: "https://example.com/art.png", size: 360)?
            .absoluteString == "https://example.com/art.png"
    )
    #expect(MusicArtworkURL.upscaled(from: "", size: 360) == nil)
}

@Test func `a field the page did not send does not empty the feed`() {
    // The page's payload and this model are changed independently, and a
    // field added to one but not the other must not be able to take the
    // whole surface down. Swift's synthesised decoding demands every key,
    // which is how one missing field emptied an entire home feed.
    let event = MusicBridgeEvent.decode(from: """
    {"type":"HOME","sections":[
      {"title":"Listen again","items":[
        {"videoId":"abc","title":"A Song","subtitle":"A Band"},
        {"playlistId":"PL123","title":"A Playlist","subtitle":"Various"}
      ]}
    ]}
    """)

    guard case let .home(sections) = event else {
        Issue.record("expected a home event, got \(String(describing: event))")
        return
    }
    #expect(sections.count == 1)
    #expect(sections[0].title == "Listen again")
    #expect(sections[0].items.count == 2)

    // A track identifies by its video, a playlist by its own id.
    #expect(sections[0].items[0].id == "abc")
    #expect(sections[0].items[1].id == "PL123")
    // The one that is a playlist carries no video, and vice versa.
    #expect(sections[0].items[0].playlistId.isEmpty)
    #expect(sections[0].items[1].videoId.isEmpty)
}

@Test func `native music home keeps listen again before quick picks`() {
    let event = MusicBridgeEvent.decode(from: """
    {"type":"HOME","sections":[
      {"title":"Quick picks","items":[
        {"videoId":"legacy","title":"Legacy","subtitle":"Artist"}
      ]},
      {"title":"Albums for you","items":[
        {"playlistId":"album","title":"Album","subtitle":"Artist"}
      ]},
      {"title":"Listen again","items":[
        {"videoId":"recent","title":"Recent","subtitle":"Artist"}
      ]}
    ]}
    """)
    guard case let .home(sections) = event else {
        Issue.record("expected a home event")
        return
    }

    let visible = MusicHomeFeed.visibleSections(from: sections)
    #expect(visible.map(\.title) == ["Listen again", "Quick picks"])
    #expect(visible[0].items.map(\.videoId) == ["recent"])
    #expect(visible[1].items.map(\.videoId) == ["legacy"])

    // Recommendations never masquerade as missing listening history.
    let recommendationsOnly = MusicHomeFeed.visibleSections(
        from: Array(sections.prefix(2))
    )
    #expect(recommendationsOnly.map(\.title) == ["Quick picks"])
}

@Test func `a search result without a playlist still decodes`() {
    let event = MusicBridgeEvent.decode(from: """
    {"type":"SEARCH","query":"q","results":[{"videoId":"abc","title":"T","subtitle":"S"}]}
    """)

    guard case let .searchResults(query, results) = event else {
        Issue.record("expected search results")
        return
    }
    #expect(query == "q")
    #expect(results.count == 1)
    #expect(results[0].videoId == "abc")
}
