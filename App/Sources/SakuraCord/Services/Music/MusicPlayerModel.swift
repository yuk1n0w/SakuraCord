import AppKit
import Foundation
import Observation
import WebKit

/// A collection selection needs a full navigation so the web player builds
/// the collection queue, rather than only switching to one video.
nonisolated enum MusicPlaylistPlaybackURL {
    static func url(videoID: String, playlistID: String) -> URL? {
        guard !playlistID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.youtube.com"
        components.path = "/watch"
        components.queryItems = []
        if !videoID.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "v", value: videoID))
        }
        components.queryItems?.append(URLQueryItem(name: "list", value: playlistID))
        return components.url
    }

    static func belongsToPlaylist(_ sourceURL: URL?, playlistID: String) -> Bool {
        guard let sourceURL,
              let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
              components.host == "music.youtube.com"
        else { return false }
        return components.queryItems?.contains {
            $0.name == "list" && $0.value == playlistID
        } == true
    }
}

/// Owns the YouTube Music page and projects what it is playing.
///
/// The page is the player. YouTube Music has no public playback API, and its
/// licensed audio only decodes inside Google's own player, so this holds a
/// web view for the app's lifetime and reads it rather than reimplementing
/// it. The view outlives any window showing it: dismissing the browse panel
/// must not stop the music.
///
/// Playback state is kept here rather than on `AppModel` because it ticks
/// once a second while a track plays, and the app tree must not redraw at
/// that rate.
@Observable
final class MusicPlayerModel {
    /// What the page reports it is playing.
    private(set) var state: MusicPlaybackState = .idle

    let discordPresence = MusicDiscordPresenceModel()

    /// The words for whatever is playing. Kept beside the player so a
    /// lookup follows the track without the panel having to watch for it.
    let lyrics = LyricsModel()

    init() {
        lyrics.pageFetch = { [weak self] url in
            await self?.pageResponse(for: url)
        }
        lyrics.youtubeLyricsFetch = { [weak self] videoID in
            await self?.youtubeLyricsResponse(for: videoID)
        }
        discordPresence.currentLyric = { [weak self] state in
            guard let self else { return nil }
            return self.lyrics.activeText(for: state, at: self.estimatedProgress())
        }
        discordPresence.currentProgress = { [weak self] in
            self?.estimatedProgress()
        }
    }

    /// What the last search turned up, and what was asked.
    private(set) var searchResults: [MusicSearchResult] = []
    private(set) var searchQuery = ""
    private(set) var isSearching = false

    /// The home feed, so there is something to browse without already
    /// knowing what to ask for.
    private(set) var homeSections: [MusicBrowseSection] = []
    private(set) var isLoadingHome = false

    /// A playlist or album the listener opened, and its tracks.
    ///
    /// A card in the feed is usually a collection rather than a track, and
    /// opening one to see what is in it is most of what a feed is for.
    private(set) var openedList: MusicOpenedList?

    /// Whether the panel is showing the page itself rather than the native
    /// surface.
    ///
    /// Signing in is Google's own flow and can only happen on the page, so
    /// the page has to be reachable even though nothing else here uses it.
    /// Making it invisible without leaving a way back to it took sign-in
    /// away entirely.
    var showsPage = false

    /// Whether the music surface is showing, and as what. The web view
    /// exists either way: the overlay retains its host when dismissed, so
    /// closing the panel hides the page rather than stopping it.
    var presentation: MusicOverlayPresentation?

    /// Whether the page has produced a player bar. A signed-out page never
    /// does, so this doubles as "there is a usable session".
    private(set) var isReady = false

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var engineWindow: NSWindow?
    @ObservationIgnored private var bridge: Bridge?

    /// Whether this side paused the music, and so owes it a resume. A track
    /// the listener paused themselves during a call stays paused afterwards.
    @ObservationIgnored private var didPauseForCall = false

    /// When the page last reported progress, and what it said.
    ///
    /// The bridge reports once a second, which is far too coarse to light a
    /// lyric line on: a line would land up to a second late and the whole
    /// panel would step rather than follow. Interpolating from the last
    /// report gives a clock smooth enough to read against.
    @ObservationIgnored private var progressReport: ProgressReport?
    @ObservationIgnored private var pendingPlaylistID: String?

    private struct ProgressReport {
        var seconds: TimeInterval
        var at: Date
        var rate: Double
        var advances: Bool
    }

    /// Commands issued before the page installed the bridge.
    ///
    /// The web view is created on first use and the page takes seconds to
    /// load, so the first search or home request almost always arrives
    /// before there is anything to receive it. Without this they were
    /// evaluated against an absent bridge and vanished, leaving whatever
    /// asked for them waiting on a reply that could never come.
    @ObservationIgnored private var queuedCommands: [(String, String)] = []

    /// YouTube Music refuses to serve an unrecognised client, and Google
    /// rejects sign-in from anything it can identify as an embedded view.
    /// Presenting as Safari is what makes the page work at all.
    @ObservationIgnored private static let userAgent = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 \
    (KHTML, like Gecko) Version/17.0 Safari/605.1.15
    """

    @ObservationIgnored private static let home = URL(
        string: "https://music.youtube.com"
    )!

    /// The live web view, created on first use.
    ///
    /// Creation is deferred so an app that never opens music never pays for
    /// a web content process, and the session's cookies are never touched.
    func webViewForDisplay() -> WKWebView {
        if let webView { return webView }

        let bridge = Bridge { [weak self] event, sourceURL in
            self?.apply(event, from: sourceURL)
        }
        let controller = WKUserContentController()
        controller.add(bridge, name: MusicBridgeScript.messageHandlerName)
        controller.addUserScript(
            WKUserScript(
                source: MusicBridgeScript.source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        // The default store persists to disk, which is what keeps a Google
        // session across launches. An ephemeral store would sign the
        // listener out every time the app quit.
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        // Playback is started by the transport, not by a click inside the page.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        self.bridge = bridge
        self.webView = webView
        parkWebView()
        webView.load(URLRequest(url: Self.home))
        return webView
    }

    /// Moves the live page into the visible sign-in surface.
    func webViewForPresentation() -> WKWebView {
        let webView = webViewForDisplay()
        if engineWindow?.contentView === webView {
            engineWindow?.contentView = NSView(frame: .zero)
        }
        return webView
    }

    /// Keeps Google's player attached without attaching its video layer to
    /// the SwiftUI chat window. An invisible engine window is enough for the
    /// page router and audio pipeline, but its display commits no longer make
    /// the complete DM interface participate in every video frame.
    func parkWebView() {
        guard let webView else { return }
        let window: NSWindow
        if let engineWindow {
            window = engineWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 2, height: 2),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.hasShadow = false
            window.alphaValue = 0.01
            window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
            self.engineWindow = window
        }
        webView.removeFromSuperview()
        window.contentView = webView
        window.orderFront(nil)
    }

    /// Runs a request from the music page rather than from the app.
    ///
    /// Google answers a native client 429 on the public translation endpoint
    /// however the request is dressed - every host it is offered on, with or
    /// without a browser user agent - while the identical request from a page
    /// succeeds. The page is already open to keep playback alive, so lyric
    /// decorations are asked for there rather than not at all.
    func pageResponse(for url: URL) async -> Data? {
        guard let webView, isReady else { return nil }
        do {
            let value = try await webView.callAsyncJavaScript(
                """
                // Match Better Lyrics' transport: repeated lyric lines should
                // come from WebKit's HTTP cache instead of spending Google's
                // tiny anonymous translation quota again after every refresh.
                const response = await fetch(url, { cache: 'force-cache' });
                if (!response.ok) { return null; }
                return await response.text();
                """,
                arguments: ["url": url.absoluteString],
                contentWorld: .page
            )
            guard let text = value as? String else { return nil }
            return Data(text.utf8)
        } catch {
            return nil
        }
    }

    /// Asks the signed-in page for its own Lyrics tab.
    ///
    /// Community providers remain preferable because they can carry line or
    /// word timing. This response is only consumed after those miss, but its
    /// request starts beside them so the fallback does not add another long
    /// wait to an already unsuccessful lookup.
    func youtubeLyricsResponse(for videoID: String) async -> Data? {
        guard let webView, isReady, !videoID.isEmpty else { return nil }
        do {
            let value = try await webView.callAsyncJavaScript(
                """
                const config = (window.ytcfg && window.ytcfg.data_) || {};
                const key = config.INNERTUBE_API_KEY;
                const context = config.INNERTUBE_CONTEXT;
                if (!key || !context) { return null; }

                async function request(path, body) {
                    const controller = new AbortController();
                    const timeout = setTimeout(function () {
                        controller.abort();
                    }, 8000);
                    try {
                        const response = await fetch(
                            path + '?key=' + encodeURIComponent(key),
                            {
                                method: 'POST',
                                credentials: 'include',
                                headers: { 'Content-Type': 'application/json' },
                                body: JSON.stringify(Object.assign(
                                    { context: context },
                                    body
                                )),
                                signal: controller.signal
                            }
                        );
                        if (!response.ok) { return null; }
                        return await response.json();
                    } finally {
                        clearTimeout(timeout);
                    }
                }

                const next = await request('/youtubei/v1/next', {
                    videoId: videoID
                });
                const tabs = next && next.contents
                    && next.contents.singleColumnMusicWatchNextResultsRenderer
                    && next.contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer
                    && next.contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer
                        .watchNextTabbedResultsRenderer
                    && next.contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer
                        .watchNextTabbedResultsRenderer.tabs;
                const lyricsTab = tabs && tabs[1] && tabs[1].tabRenderer;
                const browseId = lyricsTab && !lyricsTab.unselectable
                    && lyricsTab.endpoint
                    && lyricsTab.endpoint.browseEndpoint
                    && lyricsTab.endpoint.browseEndpoint.browseId;
                if (!browseId) { return null; }

                const browse = await request('/youtubei/v1/browse', {
                    browseId: browseId
                });
                return browse ? JSON.stringify(browse) : null;
                """,
                arguments: ["videoID": videoID],
                contentWorld: .page
            )
            guard let text = value as? String else { return nil }
            return Data(text.utf8)
        } catch {
            return nil
        }
    }

    /// Where playback has reached, carried forward from the last report.
    ///
    /// Only a playing track advances: a paused one sits where it was, and a
    /// track whose progress has never been reported has nowhere to carry
    /// forward from.
    func estimatedProgress(at now: Date = Date()) -> TimeInterval {
        guard let report = progressReport else { return state.progress }
        guard report.advances else { return report.seconds }
        let carried = report.seconds
            + max(now.timeIntervalSince(report.at), 0) * report.rate
        guard state.duration > 0 else { return carried }
        return min(carried, state.duration)
    }

    /// The narrow progress views ask for their own clock. Progress reports
    /// therefore stay outside Observation and do not make unrelated sidebar
    /// controls redraw once a second.
    func estimatedFractionComplete(at now: Date = Date()) -> Double {
        guard state.duration > 0, state.duration.isFinite else { return 0 }
        return min(max(estimatedProgress(at: now) / state.duration, 0), 1)
    }

    // MARK: - Transport

    func playPause() { evaluate("playPause") }
    func next() { evaluate("next") }
    func previous() { evaluate("previous") }
    func toggleLike() { evaluate("like") }

    /// Jumps to a moment in the track. A lyric line knows when it is sung,
    /// so tapping one is a seek rather than a scrub.
    func seek(toSeconds seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        evaluate("seek", argument: "\(seconds)")
        // The page reports progress once a second, so without restamping
        // here the lyric would snap back to where it was until the next
        // report caught up.
        progressReport = ProgressReport(
            seconds: seconds,
            at: Date(),
            rate: state.playbackRate,
            advances: state.isPlaying
        )
    }

    func seek(toFraction fraction: Double) {
        guard state.duration > 0 else { return }
        let seconds = min(max(fraction, 0), 1) * state.duration
        seek(toSeconds: seconds)
    }

    // MARK: - Searching

    /// Runs a search inside the page.
    ///
    /// The page holds the credentials and the client context, so the query
    /// goes through it rather than through a key reimplemented on this
    /// side. A signed-in listener therefore searches as themselves.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        // Loaded lazily so a search is possible before the panel has ever
        // been opened.
        _ = webViewForDisplay()
        evaluate("search", argument: encoded(trimmed))
        expire(after: .seconds(20)) { [weak self] in
            guard let self, isSearching, searchQuery == trimmed else { return }
            isSearching = false
        }
    }

    /// Loads the home feed once. It is the page's own home, so a
    /// signed-in listener gets theirs.
    func loadHomeIfNeeded() {
        guard homeSections.isEmpty, !isLoadingHome else { return }
        loadHome()
    }

    /// Fetches the feed again, whatever is already held.
    ///
    /// The feed is the page's, so it changes when the session does or when
    /// YouTube rebuilds it. Nothing here can know when that happened, which
    /// is why asking is a command rather than a schedule.
    func refreshHome() {
        guard !isLoadingHome else { return }
        loadHome()
    }

    private func loadHome() {
        isLoadingHome = true
        _ = webViewForDisplay()
        evaluate("home")
        expire(after: .seconds(20)) { [weak self] in
            guard let self, isLoadingHome else { return }
            isLoadingHome = false
        }
    }

    /// Gives up on a reply that never arrived. A page that failed to load,
    /// or a build whose endpoints have moved, must not leave the panel
    /// spinning at someone indefinitely.
    private func expire(
        after duration: Duration,
        _ body: @escaping () -> Void
    ) {
        Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            body()
        }
    }

    /// Plays a track, or starts a playlist or album.
    /// Whether this is the thing currently playing.
    ///
    /// An empty identifier never matches. A collection carries no video id,
    /// and the player reports none of its own while it is switching tracks,
    /// so comparing them directly marked every album in the feed as playing
    /// at once for as long as the switch took.
    func isPlaying(_ result: MusicSearchResult) -> Bool {
        !result.videoId.isEmpty && result.videoId == state.videoID
    }

    /// Opens a playlist or album to show what is in it.
    func openList(_ result: MusicSearchResult) {
        guard !result.browseId.isEmpty else { return }
        openedList = MusicOpenedList(
            browseId: result.browseId,
            title: result.title,
            subtitle: result.subtitle,
            artwork: result.artwork,
            items: [],
            isLoading: true
        )
        _ = webViewForDisplay()
        evaluate(
            "openList",
            argument: "\(encoded(result.browseId)), \(encoded(result.playlistId))"
        )
        expire(after: .seconds(20)) { [weak self] in
            guard let self, openedList?.isLoading == true else { return }
            openedList?.isLoading = false
        }
    }

    func closeList() {
        openedList = nil
    }

    func play(_ result: MusicSearchResult) {
        let webView = webViewForDisplay()
        if let url = MusicPlaylistPlaybackURL.url(
            videoID: result.videoId,
            playlistID: result.playlistId
        ) {
            pendingPlaylistID = result.playlistId
            isReady = false
            webView.load(URLRequest(url: url))
            return
        }
        pendingPlaylistID = nil
        evaluate(
            "play",
            argument: encoded(result.videoId)
        )
    }

    /// A query becomes a JavaScript string literal, and quotes, backslashes
    /// and newlines in it must not end that literal early.
    private func encoded(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(bytes: data, encoding: .utf8)
        else { return "\"\"" }
        return literal
    }

    // MARK: - Voice calls

    /// Silences music for a voice call, remembering that it did so.
    ///
    /// Talking over your own music is the whole problem, so a call takes the
    /// audio. It only pauses what is actually playing, so that ending a call
    /// cannot start music that was never running.
    func pauseForVoiceCall() {
        guard state.isPlaying else { return }
        didPauseForCall = true
        evaluate("pause")
    }

    /// Returns the music a call took, and nothing else. A listener who
    /// paused the track themselves mid-call keeps it paused.
    func resumeAfterVoiceCall() {
        guard didPauseForCall else { return }
        didPauseForCall = false
        evaluate("resume")
    }

    // MARK: - Bridge

    private func apply(_ event: MusicBridgeEvent, from sourceURL: URL?) {
        // The old page can still deliver an observation after navigation
        // begins. It must not mark the new page ready or consume its resume.
        if let pendingPlaylistID,
           !MusicPlaylistPlaybackURL.belongsToPlaylist(
               sourceURL,
               playlistID: pendingPlaylistID
           ) { return }
        switch event {
        case .ready:
            isReady = true
            let queued = queuedCommands
            queuedCommands = []
            for (command, argument) in queued {
                run(command, argument: argument)
            }
        case .signedOut:
            isReady = false
            pendingPlaylistID = nil
            state = .idle
            discordPresence.updateMusic(.idle)
            progressReport = nil
            lyrics.track(.idle)
        case let .list(browseId, results):
            // A reply for a collection the listener has already left is
            // dropped rather than filling the one they are looking at now.
            guard openedList?.browseId == browseId else { return }
            openedList?.items = results
            openedList?.isLoading = false
        case let .home(sections):
            // Keep this clean surface aligned with the page the listener
            // sees: it is a quick way back to familiar music, not a second
            // recommendation feed competing with YouTube Music itself.
            homeSections = MusicHomeFeed.visibleSections(from: sections)
            isLoadingHome = false
        case let .searchResults(query, results):
            // A reply for a query the listener has already moved on from is
            // dropped rather than replacing what they are looking at now.
            guard query == searchQuery else { return }
            searchResults = results
            isSearching = false
        case let .state(state):
            isReady = true
            if pendingPlaylistID != nil, state.hasTrack {
                pendingPlaylistID = nil
                if !state.isPlaying { evaluate("resume") }
            }
            // Signing in or out replaces whose feed this is, so the one on
            // screen belonged to the previous session and is discarded.
            // Without this, a listener signs in and keeps looking at the
            // signed-out feed with no sign anything is stale.
            if state.isSignedIn != self.state.isSignedIn {
                homeSections = []
                searchResults = []
                loadHomeIfNeeded()
            }
            // A report only restarts the clock when it actually moves the
            // playhead; the page repeats its progress while paused, and
            // restamping then would make a paused track appear to advance.
            if state.videoID != self.state.videoID
                || state.progress != progressReport?.seconds
                || state.isClockRunning != progressReport?.advances
                || state.playbackRate != progressReport?.rate
            {
                let receivedAt = Date()
                let sourceInstant = state.sampledAt ?? receivedAt
                // JavaScript and Swift share the machine's wall clock. Still,
                // reject a nonsensical source instant so a clock adjustment or
                // malformed page value cannot fling the playhead around.
                let sourceAge = receivedAt.timeIntervalSince(sourceInstant)
                let reportInstant = (0 ... 5).contains(sourceAge)
                    ? sourceInstant
                    : receivedAt
                progressReport = ProgressReport(
                    seconds: state.progress,
                    at: reportInstant,
                    rate: state.playbackRate,
                    advances: state.isClockRunning
                )
            }
            // A ticking playhead is not presentation state. Keep its latest
            // report for the two narrow progress views, but only publish a
            // new observed value when title, transport, artwork, duration or
            // session state actually changed.
            if !state.hasSamePresentation(as: self.state) {
                self.state = state
            }
            lyrics.track(state)
            discordPresence.updateMusic(state)
        }
    }

    private func evaluate(_ command: String, argument: String = "") {
        guard isReady else {
            queuedCommands.append((command, argument))
            return
        }
        run(command, argument: argument)
    }

    private func run(_ command: String, argument: String) {
        guard let webView else { return }
        webView.evaluateJavaScript(
            "window.__sakuracordMusic && window.__sakuracordMusic.\(command)(\(argument))"
        )
    }

    /// Receives the page's messages. `WKUserContentController` retains its
    /// handler, so this is a separate object rather than the model itself,
    /// which would otherwise be kept alive by its own web view.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        private let receive: (MusicBridgeEvent, URL?) -> Void

        init(receive: @escaping (MusicBridgeEvent, URL?) -> Void) {
            self.receive = receive
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let json = message.body as? String,
                  let event = MusicBridgeEvent.decode(from: json)
            else { return }
            receive(event, message.frameInfo.request.url)
        }
    }
}
