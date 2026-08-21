import Foundation
import Observation
import WebKit

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

    /// The words for whatever is playing. Kept beside the player so a
    /// lookup follows the track without the panel having to watch for it.
    let lyrics = LyricsModel()

    /// What the last search turned up, and what was asked.
    private(set) var searchResults: [MusicSearchResult] = []
    private(set) var searchQuery = ""
    private(set) var isSearching = false

    /// Whether the music surface is showing, and as what. The web view
    /// exists either way: the overlay retains its host when dismissed, so
    /// closing the panel hides the page rather than stopping it.
    var presentation: MusicOverlayPresentation?

    /// Whether the page has produced a player bar. A signed-out page never
    /// does, so this doubles as "there is a usable session".
    private(set) var isReady = false

    @ObservationIgnored private var webView: WKWebView?
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
    @ObservationIgnored private var progressReport: (seconds: TimeInterval, at: Date)?

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

        let bridge = Bridge { [weak self] event in
            self?.apply(event)
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
        webView.load(URLRequest(url: Self.home))

        self.bridge = bridge
        self.webView = webView
        return webView
    }

    /// Where playback has reached, carried forward from the last report.
    ///
    /// Only a playing track advances: a paused one sits where it was, and a
    /// track whose progress has never been reported has nowhere to carry
    /// forward from.
    func estimatedProgress(at now: Date = Date()) -> TimeInterval {
        guard state.isPlaying, let report = progressReport else {
            return state.progress
        }
        let carried = report.seconds + now.timeIntervalSince(report.at)
        guard state.duration > 0 else { return carried }
        return min(carried, state.duration)
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
        progressReport = (seconds: seconds, at: Date())
    }

    func seek(toFraction fraction: Double) {
        guard state.duration > 0 else { return }
        let seconds = min(max(fraction, 0), 1) * state.duration
        evaluate("seek", argument: "\(seconds)")
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
    }

    func play(_ result: MusicSearchResult) {
        _ = webViewForDisplay()
        evaluate("play", argument: encoded(result.videoId))
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

    private func apply(_ event: MusicBridgeEvent) {
        switch event {
        case .ready:
            isReady = true
        case .signedOut:
            isReady = false
            state = .idle
        case let .searchResults(query, results):
            // A reply for a query the listener has already moved on from is
            // dropped rather than replacing what they are looking at now.
            guard query == searchQuery else { return }
            searchResults = results
            isSearching = false
        case let .state(state):
            isReady = true
            // A report only restarts the clock when it actually moves the
            // playhead; the page repeats its progress while paused, and
            // restamping then would make a paused track appear to advance.
            if state.progress != self.state.progress || state.isPlaying != self.state.isPlaying {
                progressReport = (seconds: state.progress, at: Date())
            }
            self.state = state
            lyrics.track(state)
        }
    }

    private func evaluate(_ command: String, argument: String = "") {
        guard let webView else { return }
        webView.evaluateJavaScript(
            "window.__sakuracordMusic && window.__sakuracordMusic.\(command)(\(argument))"
        )
    }

    /// Receives the page's messages. `WKUserContentController` retains its
    /// handler, so this is a separate object rather than the model itself,
    /// which would otherwise be kept alive by its own web view.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        private let receive: (MusicBridgeEvent) -> Void

        init(receive: @escaping (MusicBridgeEvent) -> Void) {
            self.receive = receive
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let json = message.body as? String,
                  let event = MusicBridgeEvent.decode(from: json)
            else { return }
            receive(event)
        }
    }
}
