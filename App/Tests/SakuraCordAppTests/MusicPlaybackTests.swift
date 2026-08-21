import Foundation
import MediaPipeline
import Testing
@testable import SakuraCord

@Test func `the bridge reads a playing track off the page`() {
    let event = MusicBridgeEvent.decode(from: """
    {"type":"STATE","title":"Ur Not Alone","artist":"Chevy",
     "artwork":"https://lh3.googleusercontent.com/abc=w60-h60-l90-rj",
     "isPlaying":true,"progress":42.5,"duration":210,
     "likeStatus":"LIKE","isAd":false}
    """)

    guard case let .state(state) = event else {
        Issue.record("expected a state event, got \(String(describing: event))")
        return
    }
    #expect(state.title == "Ur Not Alone")
    #expect(state.artist == "Chevy")
    #expect(state.isPlaying)
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
