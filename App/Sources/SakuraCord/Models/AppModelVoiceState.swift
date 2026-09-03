import MediaPipeline
import SakuraCordModels

extension AppModel {
    func consumeVoiceStateChanged(_ state: VoiceParticipantState) {
        let effects = VoiceStateSoundPolicy.effects(
            previous: voiceStates[state.userID],
            current: state,
            activeChannelID: activeVoiceChannel?.id,
            currentUserID: snapshot?.currentUser.id
        )
        voiceStates[state.userID] = state.channelID == nil ? nil : state
        reconcileApplicationStreamWatchSuppression(for: state)
        watchAvailableDirectMessageStreamsAutomatically()
        if !state.isVideoEnabled {
            voiceVideoFrames[String(state.userID.rawValue)] = nil
        }
        if state.guildID == nil {
            reconcilePrivateCallVoiceState(state)
        }
        if voiceVideoPreferences.playsFeedbackSounds {
            for effect in effects {
                soundPlayer.play(effect)
            }
        }
    }
}
