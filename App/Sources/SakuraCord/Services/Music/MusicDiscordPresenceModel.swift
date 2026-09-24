import DiscordSocialSDKBridge
import Foundation
import Observation
import Security

/// Sharing must never reveal music from an invisible account, another signed-in
/// Discord identity, an advertisement, or a paused player.
nonisolated enum MusicDiscordPresencePolicy {
    static func matchesAccount(_ accountID: String, userID: UInt64) -> Bool {
        String(userID) == accountID
    }

    static func canPublish(_ state: MusicPlaybackState, isVisible: Bool) -> Bool {
        isVisible && state.isSignedIn && state.isPlaying && state.hasTrack
    }

    static func activityText(_ text: String, fallback: String) -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = source.isEmpty ? fallback : source
        var result = ""
        for scalar in value.unicodeScalars {
            let addition = String(scalar)
            guard result.utf8.count + addition.utf8.count <= 128 else { break }
            result.unicodeScalars.append(scalar)
        }
        return result.utf8.count >= 2 ? result : fallback
    }

    static func songURL(for videoID: String) -> URL? {
        guard !videoID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        guard let url = components.url, url.absoluteString.utf8.count <= 256 else {
            return nil
        }
        return url
    }
}

/// Publishes only the current account's actively playing music through
/// Discord's OAuth-based Social SDK. No normal-account Gateway credential is
/// passed to the SDK.
@Observable
final class MusicDiscordPresenceModel {
    private static let applicationID: UInt64 = 1_552_325_906_847_109_260
    private static let preferencePrefix = "musicDiscordPresenceEnabled."

    private(set) var isAvailable = sakura_social_available() != 0
    private(set) var isEnabled = false
    private(set) var isConnected = false
    private(set) var statusText: String?

    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var bridge: OpaquePointer?
    @ObservationIgnored private var callbackTimer: Timer?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var musicState: MusicPlaybackState = .idle
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var lastPublished: PublishedTrack?
    @ObservationIgnored var currentLyric: ((MusicPlaybackState) -> String?)?
    @ObservationIgnored var currentProgress: (() -> TimeInterval?)?

    private struct PublishedTrack: Equatable {
        let videoID: String
        let title: String
        let artist: String
        let artworkURL: URL?
        let isPlaying: Bool
        let lyric: String?
    }

    func useAccount(_ nextAccountID: String?) {
        guard nextAccountID != accountID else { return }
        if let bridge {
            sakura_social_clear(bridge)
            sakura_social_disconnect(bridge)
        }
        accountID = nextAccountID
        isConnected = false
        lastPublished = nil
        isRefreshing = false
        statusText = nil
        isEnabled = nextAccountID.map {
            UserDefaults.standard.bool(forKey: Self.preferencePrefix + $0)
        } ?? false
        if isEnabled, isVisible {
            start()
        } else {
            stopCallbacks()
            if isEnabled { statusText = "Waiting until your status is visible" }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable, let accountID else { return }
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferencePrefix + accountID)
        if enabled {
            if isVisible {
                start()
            } else {
                statusText = "Waiting until your status is visible"
            }
        } else {
            if let bridge {
                sakura_social_clear(bridge)
                sakura_social_disconnect(bridge)
            }
            isConnected = false
            lastPublished = nil
            statusText = nil
            stopCallbacks()
        }
    }

    func updateMusic(_ state: MusicPlaybackState) {
        musicState = state
        publishIfChanged()
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if !visible {
            if let bridge, isEnabled {
                sakura_social_clear(bridge)
                sakura_social_disconnect(bridge)
            }
            isConnected = false
            lastPublished = nil
            stopCallbacks()
            if isEnabled { statusText = "Waiting until your status is visible" }
        } else if isEnabled {
            start()
        }
    }

    func forgetAccount(_ accountID: String) {
        MusicPresenceCredentialStore.remove(accountID: accountID)
        UserDefaults.standard.removeObject(forKey: Self.preferencePrefix + accountID)
        if self.accountID == accountID { useAccount(nil) }
    }

    private func start() {
        guard isAvailable, let accountID else { return }
        if bridge == nil {
            bridge = sakura_social_create(
                Self.applicationID,
                Unmanaged.passUnretained(self).toOpaque(),
                { context, ready, userID in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<MusicDiscordPresenceModel>
                            .fromOpaque(context).takeUnretainedValue()
                            .receivedStatus(ready: ready != 0, userID: userID)
                    }
                },
                { context, access, refresh, expires in
                    guard let context, let access, let refresh else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<MusicDiscordPresenceModel>
                            .fromOpaque(context).takeUnretainedValue()
                            .receivedTokens(
                                access: String(cString: access),
                                refresh: String(cString: refresh),
                                expiresIn: expires
                            )
                    }
                },
                { context, message in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<MusicDiscordPresenceModel>
                            .fromOpaque(context).takeUnretainedValue()
                            .receivedError(message.map(String.init(cString:)) ?? "Discord connection failed")
                    }
                }
            )
        }
        guard let bridge else {
            statusText = "Discord Social SDK is unavailable"
            return
        }
        if callbackTimer == nil {
            callbackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                sakura_social_run_callbacks()
                MainActor.assumeIsolated { self?.publishIfChanged() }
            }
        }
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshIfNeeded() }
            }
        }
        isConnected = false
        statusText = "Connecting to Discord…"
        if let credentials = MusicPresenceCredentialStore.load(accountID: accountID) {
            if credentials.expiresAt > Date().addingTimeInterval(3600) {
                credentials.accessToken.withCString { sakura_social_connect(bridge, $0) }
            } else {
                isRefreshing = true
                credentials.refreshToken.withCString { sakura_social_refresh(bridge, $0) }
            }
        } else {
            sakura_social_authorize(bridge)
        }
    }

    private func stopCallbacks() {
        callbackTimer?.invalidate()
        callbackTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        isRefreshing = false
    }

    private func refreshIfNeeded() {
        guard isEnabled, !isRefreshing, let accountID, let bridge,
              let credentials = MusicPresenceCredentialStore.load(accountID: accountID),
              credentials.expiresAt < Date().addingTimeInterval(24 * 3_600)
        else { return }
        isRefreshing = true
        credentials.refreshToken.withCString { sakura_social_refresh(bridge, $0) }
    }

    private func receivedStatus(ready: Bool, userID: UInt64) {
        guard isEnabled, let accountID else { return }
        guard ready else {
            isConnected = false
            lastPublished = nil
            if isVisible { statusText = "Reconnecting to Discord…" }
            return
        }
        guard MusicDiscordPresencePolicy.matchesAccount(accountID, userID: userID) else {
            isConnected = false
            statusText = "Discord authorization belongs to another account"
            MusicPresenceCredentialStore.remove(accountID: accountID)
            if let bridge { sakura_social_disconnect(bridge) }
            return
        }
        isConnected = true
        statusText = nil
        publishIfChanged()
    }

    private func receivedTokens(access: String, refresh: String, expiresIn: Int32) {
        guard isEnabled, let accountID else { return }
        isRefreshing = false
        let credentials = MusicPresenceCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        guard MusicPresenceCredentialStore.save(credentials, accountID: accountID) else {
            statusText = "Could not save Discord authorization in Keychain"
            return
        }
        statusText = "Connecting to Discord…"
    }

    private func receivedError(_ message: String) {
        guard isEnabled else { return }
        isRefreshing = false
        isConnected = false
        lastPublished = nil
        statusText = message
    }

    private func publishIfChanged() {
        guard isEnabled, isConnected, let bridge else { return }
        guard isVisible else {
            if lastPublished != nil {
                sakura_social_clear(bridge)
                lastPublished = nil
            }
            return
        }
        let state = musicState
        let isPlaying = MusicDiscordPresencePolicy.canPublish(
            state, isVisible: isVisible
        )
        let track = PublishedTrack(
            videoID: state.videoID,
            title: state.title,
            artist: state.artist,
            artworkURL: state.artworkURL,
            isPlaying: isPlaying,
            lyric: isPlaying ? currentLyric?(state) : nil
        )
        guard track != lastPublished else { return }
        lastPublished = track
        guard track.isPlaying else {
            sakura_social_clear(bridge)
            return
        }
        let startedAt: UInt64
        let endsAt: UInt64
        let progress = currentProgress?() ?? state.progress
        if state.duration.isFinite, state.duration > 0,
           progress.isFinite, progress >= 0
        {
            let start = Date().timeIntervalSince1970 - progress
            startedAt = UInt64(max(start, 0) * 1_000)
            endsAt = UInt64(max(start + state.duration, 0) * 1_000)
        } else {
            startedAt = 0
            endsAt = 0
        }
        let titleText = MusicDiscordPresencePolicy.activityText(
            track.title, fallback: "Music"
        )
        let artistText = MusicDiscordPresencePolicy.activityText(
            track.lyric ?? track.artist, fallback: "YouTube Music"
        )
        let artworkText = track.artworkURL.flatMap { url in
            let value = url.absoluteString
            return url.scheme == "https" && value.utf8.count <= 300 ? value : nil
        } ?? ""
        let songURLText = MusicDiscordPresencePolicy.songURL(
            for: track.videoID
        )?.absoluteString ?? ""
        titleText.withCString { title in
            artistText.withCString { artist in
                artworkText.withCString { artwork in
                    songURLText.withCString { songURL in
                        sakura_social_update(
                            bridge, title, artist, artwork, songURL,
                            startedAt, endsAt
                        )
                    }
                }
            }
        }
    }
}

private struct MusicPresenceCredentials: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

private enum MusicPresenceCredentialStore {
    static let service = "dev.sakuracord.music-discord-presence"

    static func load(accountID: String) -> MusicPresenceCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(MusicPresenceCredentials.self, from: data)
    }

    static func save(_ credentials: MusicPresenceCredentials, accountID: String) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
            return true
        }
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func remove(accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        SecItemDelete(query as CFDictionary)
    }
}
