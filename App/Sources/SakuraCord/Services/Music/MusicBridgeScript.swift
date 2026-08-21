import Foundation

/// The script injected into YouTube Music to report what it is playing and
/// to drive its transport.
///
/// The page is a moving target: none of these selectors are a published
/// contract, and Google reshapes the markup without notice. Every read here
/// is therefore defensive, and the observer reports nothing rather than
/// guessing when the element it wants has gone.
///
/// Adapted from Kaset (MIT, https://github.com/sozercan/kaset), whose
/// observer had already found the parts of this that are not obvious:
/// playback state comes from the media element rather than the play button,
/// because the button's label is localised; artwork has to be read from the
/// literal `src` attribute, because `img.src` resolves an empty attribute
/// against the page URL; and the structured player metadata beats the
/// player bar's text, which mixes in localised view counts.
nonisolated enum MusicBridgeScript {
    /// The handler name the page posts to, and that the web view registers.
    static let messageHandlerName = "sakuracordMusic"

    static let source = """
    (function () {
        if (window.__sakuracordMusicBridgeInstalled) { return; }
        window.__sakuracordMusicBridgeInstalled = true;

        const bridge = window.webkit.messageHandlers.\(messageHandlerName);
        const POLL_INTERVAL_MS = 1000;
        let pollId = null;
        let lastPayload = '';

        function post(payload) {
            const encoded = JSON.stringify(payload);
            // The observer fires far more often than the state changes.
            // Posting only differences keeps the bridge quiet while a track
            // plays untouched, which is most of the time.
            if (payload.type === 'STATE' && encoded === lastPayload) { return; }
            if (payload.type === 'STATE') { lastPayload = encoded; }
            bridge.postMessage(encoded);
        }

        function isAdShowing() {
            const moviePlayer = document.getElementById('movie_player');
            return !!(moviePlayer && moviePlayer.classList
                && moviePlayer.classList.contains('ad-showing'));
        }

        function playerMetadata() {
            const moviePlayer = document.getElementById('movie_player');
            if (!moviePlayer || typeof moviePlayer.getVideoData !== 'function') {
                return null;
            }
            try { return moviePlayer.getVideoData(); } catch (error) { return null; }
        }

        function currentVideoId() {
            // The player reports the id under either name depending on the
            // build, and reports neither while a track is being swapped.
            const metadata = playerMetadata();
            if (metadata) {
                const id = metadata.video_id || metadata.videoId || '';
                if (id) { return id; }
            }
            // The address bar still knows during that gap.
            try {
                return new URL(window.location.href).searchParams.get('v') || '';
            } catch (error) {
                return '';
            }
        }

        function artworkSource() {
            const thumb = document.querySelector(
                '.ytmusic-player-bar .thumbnail img, ytmusic-player-bar .image'
            );
            if (!thumb) { return ''; }
            // An absent attribute resolves against the document base URL, so
            // the literal attribute decides whether there is artwork at all.
            const raw = (thumb.getAttribute('src') || '').trim();
            return raw ? (thumb.src || raw) : '';
        }

        function likeStatus() {
            const renderer = document.querySelector('ytmusic-like-button-renderer');
            const status = renderer && renderer.getAttribute('like-status');
            return status === 'LIKE' || status === 'DISLIKE' ? status : 'INDIFFERENT';
        }

        function playbackClock(media, progressBar) {
            const ready = !!(media && media.currentSrc && media.readyState >= 1);
            const barProgress = progressBar ? Number(progressBar.getAttribute('value')) : NaN;
            const barDuration = progressBar
                ? Number(progressBar.getAttribute('aria-valuemax'))
                : NaN;
            const mediaProgress = media ? Number(media.currentTime) : NaN;
            const mediaDuration = media ? Number(media.duration) : NaN;
            return {
                // The player bar can stop updating while the media element
                // keeps playing, so ready media wins over the bar's attributes.
                progress: ready && isFinite(mediaProgress)
                    ? mediaProgress
                    : (isFinite(barProgress) ? barProgress : 0),
                duration: ready && isFinite(mediaDuration) && mediaDuration > 0
                    ? mediaDuration
                    : (isFinite(barDuration) && barDuration > 0 ? barDuration : 0)
            };
        }

        function sendState() {
            const media = document.querySelector('video');
            const titleElement = document.querySelector('.ytmusic-player-bar.title');
            const bylineElement = document.querySelector('.ytmusic-player-bar.byline');
            const metadata = playerMetadata();

            const domTitle = titleElement ? titleElement.textContent.trim() : '';
            const metadataTitle = metadata && typeof metadata.title === 'string'
                ? metadata.title.trim()
                : '';
            // The bar's text lags a track change; the structured metadata does not.
            const title = metadataTitle || domTitle;
            // The byline carries localised view counts alongside the artist,
            // so the structured author is preferred wherever it exists.
            const metadataArtist = metadata && typeof metadata.author === 'string'
                ? metadata.author.trim()
                : '';
            const artist = metadataArtist
                || (bylineElement ? bylineElement.textContent.trim() : '');

            const clock = playbackClock(media, document.querySelector('#progress-bar'));
            const videoId = currentVideoId();
            post({
                type: 'STATE',
                videoId: videoId,
                title: title,
                artist: artist,
                artwork: artworkSource(),
                // The play button's label is localised. The media element is not.
                isPlaying: media ? !media.paused : false,
                progress: clock.progress,
                duration: clock.duration,
                likeStatus: likeStatus(),
                isAd: isAdShowing()
            });
        }

        function startPolling() {
            if (pollId) { return; }
            // Mutations report a track change immediately; only the progress
            // needs a clock, and one second is finer than the bar can show.
            pollId = setInterval(sendState, POLL_INTERVAL_MS);
        }

        function click(selector) {
            const element = document.querySelector(selector);
            if (element) { element.click(); }
            sendState();
        }

        function resultsFrom(payload) {
            // InnerTube nests its rows deeply and the shape shifts between
            // builds, so the tree is walked for the renderer rather than
            // indexed into by a path that would break on the next change.
            const rows = [];
            (function walk(node) {
                if (!node || typeof node !== 'object') { return; }
                if (node.musicResponsiveListItemRenderer) {
                    rows.push(node.musicResponsiveListItemRenderer);
                }
                for (const key in node) { walk(node[key]); }
            })(payload);

            const results = [];
            for (const row of rows) {
                let videoId = '';
                (function findVideo(node) {
                    if (videoId || !node || typeof node !== 'object') { return; }
                    if (node.watchEndpoint && node.watchEndpoint.videoId) {
                        videoId = node.watchEndpoint.videoId;
                        return;
                    }
                    for (const key in node) { findVideo(node[key]); }
                })(row);
                // A row with nothing to play is a header or an album shelf.
                if (!videoId) { continue; }

                const columns = (row.flexColumns || []).map(function (column) {
                    const renderer = column.musicResponsiveListItemFlexColumnRenderer;
                    const runs = renderer && renderer.text && renderer.text.runs;
                    return runs ? runs.map(function (run) { return run.text; }).join('') : '';
                });

                let thumbnail = '';
                const thumbnails = row.thumbnail
                    && row.thumbnail.musicThumbnailRenderer
                    && row.thumbnail.musicThumbnailRenderer.thumbnail
                    && row.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails;
                if (thumbnails && thumbnails.length) {
                    thumbnail = thumbnails[thumbnails.length - 1].url || '';
                }

                results.push({
                    videoId: videoId,
                    title: columns[0] || '',
                    // The second column carries artist, album and duration
                    // run together with separators already in it.
                    subtitle: columns.slice(1).filter(Boolean).join(' '),
                    artwork: thumbnail
                });
                if (results.length >= 25) { break; }
            }
            return results;
        }

        window.__sakuracordMusic = {
            search: function (query) {
                const config = (window.ytcfg && window.ytcfg.data_) || {};
                const key = config.INNERTUBE_API_KEY;
                const context = config.INNERTUBE_CONTEXT;
                if (!key || !context) {
                    post({ type: 'SEARCH', query: query, results: [] });
                    return;
                }
                // The page's own credentials and client context are used, so
                // a signed-in listener searches their library the same way
                // the page would, and no key is reimplemented on our side.
                fetch('/youtubei/v1/search?key=' + encodeURIComponent(key), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ context: context, query: query })
                })
                    .then(function (response) { return response.json(); })
                    .then(function (payload) {
                        post({
                            type: 'SEARCH',
                            query: query,
                            results: resultsFrom(payload)
                        });
                    })
                    .catch(function () {
                        post({ type: 'SEARCH', query: query, results: [] });
                    });
            },
            play: function (videoId) {
                if (!videoId) { return; }
                // Setting location would reload the document: the player
                // would be torn down and rebuilt, the bridge reinjected,
                // and audio would stop for as long as that took. Clicking a
                // link instead lets the page's own router handle it, which
                // swaps the track without leaving the document.
                const link = document.createElement('a');
                link.href = '/watch?v=' + encodeURIComponent(videoId);
                link.style.display = 'none';
                document.body.appendChild(link);
                link.click();
                link.remove();
                // The router does not always take the click - a page that
                // has not finished booting has no router yet - so a
                // navigation that changed nothing falls back to a load.
                const requested = videoId;
                setTimeout(function () {
                    if (currentVideoId() !== requested) {
                        window.location.href = '/watch?v=' + encodeURIComponent(requested);
                    }
                }, 1200);
            },
            playPause: function () { click('.play-pause-button.ytmusic-player-bar'); },
            next: function () { click('.next-button.ytmusic-player-bar'); },
            previous: function () { click('.previous-button.ytmusic-player-bar'); },
            like: function () { click('ytmusic-like-button-renderer #button-shape-like button'); },
            pause: function () {
                const media = document.querySelector('video');
                if (media && !media.paused) { media.pause(); }
                sendState();
            },
            resume: function () {
                const media = document.querySelector('video');
                if (media && media.paused) { media.play(); }
                sendState();
            },
            seek: function (seconds) {
                const media = document.querySelector('video');
                if (media && isFinite(seconds)) { media.currentTime = seconds; }
                sendState();
            }
        };

        function attach(playerBar) {
            let pending = null;
            const observer = new MutationObserver(function () {
                if (pending) { return; }
                pending = setTimeout(function () {
                    pending = null;
                    sendState();
                }, 100);
            });
            observer.observe(playerBar, {
                attributes: true, characterData: true, childList: true, subtree: true,
                attributeFilter: ['title', 'aria-label', 'like-status', 'value', 'aria-valuemax']
            });
            post({ type: 'READY' });
            startPolling();
            sendState();
        }

        function waitForPlayerBar() {
            const playerBar = document.querySelector('ytmusic-player-bar');
            if (playerBar) { attach(playerBar); return; }
            // A signed-out page never grows a player bar, so this retries
            // rather than failing: signing in makes one appear in place.
            setTimeout(waitForPlayerBar, 500);
        }

        waitForPlayerBar();
    })();
    """
}
