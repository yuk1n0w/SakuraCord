import MediaPipeline

/// Whether a voice session should be holding the audio.
///
/// Music pauses for a call and comes back after it. The states that count
/// as "in a call" are the ones where the listener is either talking or
/// about to be: a session that is still connecting will have audio in a
/// moment, and one that is reconnecting has not left. Only a session that
/// has genuinely finished gives the audio back, so a dropped connection
/// retrying does not start the music mid-call.
nonisolated enum MusicVoiceCoordinationPolicy {
    static func callHoldsAudio(during state: VoiceSessionState) -> Bool {
        switch state {
        case .connecting, .connected, .reconnecting:
            true
        case .idle, .disconnecting, .disconnected, .failed:
            false
        }
    }
}
