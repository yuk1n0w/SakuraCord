import Foundation

/// The script injected into YouTube Music to report what it is playing, to
/// drive its transport, and to ask its own API for music to play.
///
/// The page is a moving target: none of these selectors or response shapes
/// are a published contract, and Google reshapes both without notice. Every
/// read here is therefore defensive, and the observer reports nothing rather
/// than guessing when what it wants has gone.
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
        const VIDEO_STATE_EVENTS = [
            'loadedmetadata', 'durationchange', 'play', 'playing', 'pause',
            'waiting', 'seeking', 'seeked', 'ratechange', 'ended', 'emptied'
        ];
        let pollId = null;
        let lastPayload = '';
        let observedPlayer = null;
        let observedMedia = null;
        let homeRequestGeneration = 0;

        function post(payload) {
            const encoded = JSON.stringify(payload);
            // The observer fires far more often than the state changes.
            // Posting only differences keeps the bridge quiet while a track
            // plays untouched, which is most of the time.
            if (payload.type === 'STATE' && encoded === lastPayload) { return; }
            if (payload.type === 'STATE') { lastPayload = encoded; }
            bridge.postMessage(encoded);
        }

        // ---- Reading the player -------------------------------------------

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

        function playbackClock(player, media, progressBar) {
            const ready = !!(media && media.currentSrc && media.readyState >= 1);
            const barProgress = progressBar ? Number(progressBar.getAttribute('value')) : NaN;
            const barDuration = progressBar
                ? Number(progressBar.getAttribute('aria-valuemax'))
                : NaN;
            const mediaProgress = media ? Number(media.currentTime) : NaN;
            const mediaDuration = media ? Number(media.duration) : NaN;
            let playerProgress = NaN;
            let playerDuration = NaN;
            try {
                if (player && typeof player.getCurrentTime === 'function') {
                    playerProgress = Number(player.getCurrentTime());
                }
                if (player && typeof player.getDuration === 'function') {
                    playerDuration = Number(player.getDuration());
                }
            } catch (error) {}
            return {
                // The movie player is YouTube's authoritative clock. The media
                // element and bar remain defensive fallbacks for page builds
                // that stop exposing those methods.
                progress: isFinite(playerProgress)
                    ? playerProgress
                    : (ready && isFinite(mediaProgress)
                    ? mediaProgress
                    : (isFinite(barProgress) ? barProgress : 0)),
                duration: isFinite(playerDuration) && playerDuration > 0
                    ? playerDuration
                    : (ready && isFinite(mediaDuration) && mediaDuration > 0
                    ? mediaDuration
                    : (isFinite(barDuration) && barDuration > 0 ? barDuration : 0))
            };
        }

        function playbackState(player, media) {
            let isPlaying = !!(media && !media.paused && !media.ended);
            let isClockRunning = isPlaying
                && !media.seeking
                && media.error === null;
            try {
                if (player && typeof player.getPlayerStateObject === 'function') {
                    const state = player.getPlayerStateObject();
                    if (state && typeof state === 'object') {
                        isPlaying = !!state.isPlaying;
                        isClockRunning = isPlaying
                            && !state.isBuffering
                            && !state.isSeeking
                            && !state.isUiSeeking;
                    }
                }
            } catch (error) {}
            return { isPlaying: isPlaying, isClockRunning: isClockRunning };
        }

        function mediaStateChanged() { sendState(); }
        function playerStateChanged() { sendState(); }

        function detachMedia() {
            if (!observedMedia) { return; }
            for (const event of VIDEO_STATE_EVENTS) {
                observedMedia.removeEventListener(event, mediaStateChanged);
            }
            observedMedia = null;
        }

        function attachMedia(media) {
            if (media === observedMedia) { return; }
            detachMedia();
            observedMedia = media;
            if (!media) { return; }
            for (const event of VIDEO_STATE_EVENTS) {
                media.addEventListener(event, mediaStateChanged);
            }
        }

        function detachPlayer() {
            if (observedPlayer && typeof observedPlayer.removeEventListener === 'function') {
                observedPlayer.removeEventListener('onStateChange', playerStateChanged);
            }
            detachMedia();
            observedPlayer = null;
        }

        function playerAndMedia() {
            const player = document.getElementById('movie_player');
            if (player !== observedPlayer) {
                detachPlayer();
                observedPlayer = player;
                if (player && typeof player.addEventListener === 'function') {
                    player.addEventListener('onStateChange', playerStateChanged);
                }
            }
            const media = player && typeof player.querySelector === 'function'
                ? player.querySelector('video')
                : document.querySelector('video');
            attachMedia(media);
            return { player: player, media: media };
        }

        function sendState() {
            const bound = playerAndMedia();
            const player = bound.player;
            const media = bound.media;
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

            const clock = playbackClock(player, media, document.querySelector('#progress-bar'));
            const playback = playbackState(player, media);
            const config = (window.ytcfg && window.ytcfg.data_) || {};
            post({
                type: 'STATE',
                // The page knows whether there is a session; without this
                // the panel cannot tell "no library" from "not signed in".
                isSignedIn: !!config.LOGGED_IN,
                videoId: currentVideoId(),
                title: title,
                artist: artist,
                artwork: artworkSource(),
                isPlaying: playback.isPlaying,
                isClockRunning: playback.isClockRunning,
                playbackRate: media && isFinite(media.playbackRate) && media.playbackRate > 0
                    ? media.playbackRate
                    : 1,
                progress: clock.progress,
                duration: clock.duration,
                sampledAt: Date.now(),
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

        // ---- Asking the page's own API ------------------------------------

        function innertube(path, body) {
            const config = (window.ytcfg && window.ytcfg.data_) || {};
            const key = config.INNERTUBE_API_KEY;
            const context = config.INNERTUBE_CONTEXT;
            if (!key || !context) { return Promise.reject(new Error('no client')); }
            // The page's own credentials and client context are used, so a
            // signed-in listener sees their own home and library, and no key
            // is reimplemented on our side.
            return fetch(path + '?key=' + encodeURIComponent(key), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(Object.assign({ context: context }, body))
            }).then(function (response) { return response.json(); });
        }

        function findVideoId(node) {
            let found = '';
            (function walk(value) {
                if (found || !value || typeof value !== 'object') { return; }
                if (value.watchEndpoint && value.watchEndpoint.videoId) {
                    found = value.watchEndpoint.videoId;
                    return;
                }
                for (const key in value) { walk(value[key]); }
            })(node);
            return found;
        }

        function findPlaylistId(node) {
            let found = '';
            (function walk(value) {
                if (found || !value || typeof value !== 'object') { return; }
                if (typeof value.playlistId === 'string' && value.playlistId) {
                    found = value.playlistId;
                    return;
                }
                // A playlist's browse id is its playlist id behind a VL
                // prefix, which is the only identifier some cards carry.
                if (typeof value.browseId === 'string'
                    && value.browseId.indexOf('VL') === 0) {
                    found = value.browseId.slice(2);
                    return;
                }
                for (const key in value) { walk(value[key]); }
            })(node);
            return found;
        }

        function findBrowseId(node) {
            let found = '';
            (function walk(value) {
                if (found || !value || typeof value !== 'object') { return; }
                if (value.browseEndpoint && typeof value.browseEndpoint.browseId === 'string') {
                    found = value.browseEndpoint.browseId;
                    return;
                }
                for (const key in value) { walk(value[key]); }
            })(node);
            return found;
        }

        function largestThumbnail(node) {
            let url = '';
            (function walk(value) {
                if (url || !value || typeof value !== 'object') { return; }
                if (Array.isArray(value.thumbnails) && value.thumbnails.length) {
                    url = value.thumbnails[value.thumbnails.length - 1].url || '';
                    return;
                }
                for (const key in value) { walk(value[key]); }
            })(node);
            return url;
        }

        function runsText(node) {
            if (!node) { return ''; }
            const runs = node.runs;
            if (!runs) { return node.simpleText || ''; }
            return runs.map(function (run) { return run.text; }).join('');
        }

        /// A row in a shelf: title in the first column, everything else after.
        function listItem(renderer) {
            const videoId = findVideoId(renderer);
            // A row with nothing to play is a header, an artist or an album.
            if (!videoId) { return null; }
            const columns = (renderer.flexColumns || []).map(function (column) {
                const inner = column.musicResponsiveListItemFlexColumnRenderer;
                return inner ? runsText(inner.text) : '';
            });
            return {
                videoId: videoId,
                playlistId: '',
                browseId: '',
                title: columns[0] || '',
                subtitle: columns.slice(1).filter(Boolean).join(' • '),
                artwork: largestThumbnail(renderer.thumbnail)
            };
        }

        /// A card in a home shelf.
        ///
        /// Most of home is albums and playlists rather than single tracks -
        /// "listen again" and a library shelf carry nothing else - so a card
        /// with no video is still playable by its playlist. Requiring a
        /// video id here emptied every such shelf, and an empty shelf was
        /// then dropped as a promo row.
        function cardItem(renderer) {
            const videoId = findVideoId(renderer);
            const playlistId = videoId ? '' : findPlaylistId(renderer);
            if (!videoId && !playlistId) { return null; }
            return {
                videoId: videoId,
                playlistId: playlistId,
                // The canonical id for opening the thing, taken from the
                // page rather than derived: an album's browse id is not its
                // playlist id behind a prefix.
                browseId: videoId ? '' : findBrowseId(renderer),
                title: runsText(renderer.title),
                subtitle: runsText(renderer.subtitle),
                artwork: largestThumbnail(renderer.thumbnailRenderer || renderer.thumbnail)
            };
        }

        /// The top result, which is a card rather than a row.
        function cardShelfItem(renderer) {
            const videoId = findVideoId(renderer);
            if (!videoId) { return null; }
            return {
                videoId: videoId,
                playlistId: '',
                browseId: '',
                title: runsText(renderer.title),
                subtitle: runsText(renderer.subtitle),
                artwork: largestThumbnail(renderer.thumbnail)
            };
        }

        function resultsFrom(payload) {
            const results = [];
            const seen = {};

            function take(item) {
                if (!item || seen[item.videoId]) { return; }
                seen[item.videoId] = true;
                results.push(item);
            }

            // Walked shelf by shelf in document order, so YouTube's own
            // ranking survives. Collecting every row wherever it appeared in
            // the tree flattened the shelves into whatever order the JSON
            // happened to nest, which put videos above the song asked for.
            (function walk(node) {
                if (!node || typeof node !== 'object' || results.length >= 30) { return; }

                if (node.musicCardShelfRenderer) {
                    const card = node.musicCardShelfRenderer;
                    take(cardShelfItem(card));
                    // The card shelf carries its own related rows underneath.
                    for (const entry of card.contents || []) {
                        if (entry.musicResponsiveListItemRenderer) {
                            take(listItem(entry.musicResponsiveListItemRenderer));
                        }
                    }
                    return;
                }

                // Rows are wrapped in whatever section the build uses -
                // this response has no shelf renderer at all, only rows
                // inside item sections - so they are taken wherever they
                // are found. Walking in document order is what preserves
                // the ranking; the wrapper does not matter.
                if (node.musicResponsiveListItemRenderer) {
                    take(listItem(node.musicResponsiveListItemRenderer));
                    return;
                }

                // Arrays are walked in order so ordered content keeps its order.
                if (Array.isArray(node)) {
                    for (const value of node) { walk(value); }
                    return;
                }
                for (const key in node) { walk(node[key]); }
            })(payload);

            return results;
        }

        function sectionsFrom(payload) {
            const sections = [];
            (function walk(node) {
                if (!node || typeof node !== 'object' || sections.length >= 24) { return; }

                if (node.musicCarouselShelfRenderer) {
                    const shelf = node.musicCarouselShelfRenderer;
                    const header = shelf.header
                        && shelf.header.musicCarouselShelfBasicHeaderRenderer;
                    const items = [];
                    for (const entry of shelf.contents || []) {
                        // Home mixes card shelves and list shelves; both carry
                        // a watch endpoint when there is something to play.
                        const item = entry.musicTwoRowItemRenderer
                            ? cardItem(entry.musicTwoRowItemRenderer)
                            : (entry.musicResponsiveListItemRenderer
                                ? listItem(entry.musicResponsiveListItemRenderer)
                                : null);
                        if (item) { items.push(item); }
                        if (items.length >= 12) { break; }
                    }
                    // A shelf with nothing playable is a promo or a link row.
                    if (items.length) {
                        sections.push({
                            title: header ? runsText(header.title) : '',
                            items: items
                        });
                    }
                    return;
                }

                if (Array.isArray(node)) {
                    for (const value of node) { walk(value); }
                    return;
                }
                for (const key in node) { walk(node[key]); }
            })(payload);
            return sections;
        }

        function rendererData(element) {
            if (!element) { return null; }
            return element.data
                || (element.__data && element.__data.data)
                || null;
        }

        /// Reads one card from the live renderer. Polymer normally leaves the
        /// exact response object on `data`, which is preferable because it
        /// retains canonical endpoints. The DOM fallback keeps this working
        /// when a page build stops exposing that property.
        function renderedCardItem(element) {
            const data = rendererData(element);
            const fromData = data ? cardItem(data) : null;
            if (fromData) { return fromData; }

            let videoId = '';
            let playlistId = '';
            let browseId = '';
            for (const link of element.querySelectorAll('a[href]')) {
                let url;
                try { url = new URL(link.href, window.location.href); }
                catch (error) { continue; }
                if (!videoId) { videoId = url.searchParams.get('v') || ''; }
                if (!playlistId) { playlistId = url.searchParams.get('list') || ''; }
                if (!browseId && url.pathname.indexOf('/browse/') === 0) {
                    browseId = url.pathname.slice('/browse/'.length);
                }
                if (videoId) { break; }
            }
            if (!videoId && !playlistId) { return null; }

            const title = element.querySelector('.title, #title');
            const subtitle = element.querySelector('.subtitle, #subtitle');
            const image = element.querySelector('img');
            const artwork = image
                ? (image.currentSrc || image.getAttribute('src') || '')
                : '';
            return {
                videoId: videoId,
                playlistId: videoId ? '' : playlistId,
                browseId: videoId ? '' : browseId,
                title: title ? title.textContent.trim() : '',
                subtitle: subtitle ? subtitle.textContent.trim() : '',
                artwork: artwork
            };
        }

        /// The home API can be assigned a different experiment than the
        /// rendered page. Read the visible shelf so native and web surfaces
        /// represent the same signed-in account instead of relabelling an
        /// unrelated recommendation response.
        function renderedListenAgainSection() {
            const shelves = document.querySelectorAll(
                'ytmusic-carousel-shelf-renderer'
            );
            for (const element of shelves) {
                const shelf = rendererData(element);
                const header = shelf && shelf.header
                    && shelf.header.musicCarouselShelfBasicHeaderRenderer;
                const headerElement = element.querySelector(
                    'ytmusic-carousel-shelf-basic-header-renderer #title, '
                    + 'ytmusic-carousel-shelf-basic-header-renderer .title'
                );
                const title = (header ? runsText(header.title) : '')
                    || (headerElement ? headerElement.textContent.trim() : '');
                if (title.trim().toLowerCase() !== 'listen again') { continue; }

                const items = [];
                const seen = {};
                function take(item) {
                    if (!item) { return; }
                    const id = item.videoId || item.playlistId;
                    if (!id || seen[id]) { return; }
                    seen[id] = true;
                    items.push(item);
                }

                if (shelf && Array.isArray(shelf.contents)) {
                    for (const entry of shelf.contents) {
                        if (entry.musicTwoRowItemRenderer) {
                            take(cardItem(entry.musicTwoRowItemRenderer));
                        } else if (entry.musicResponsiveListItemRenderer) {
                            take(listItem(entry.musicResponsiveListItemRenderer));
                        }
                    }
                }
                for (const card of element.querySelectorAll(
                    'ytmusic-two-row-item-renderer, '
                    + 'ytmusic-responsive-list-item-renderer'
                )) {
                    take(renderedCardItem(card));
                }
                if (items.length) {
                    return { title: 'Listen again', items: items.slice(0, 12) };
                }
            }
            return null;
        }

        function quickPicksSection(from) {
            return from.find(function (section) {
                return section.title.trim().toLowerCase() === 'quick picks';
            }) || null;
        }

        // ---- Commands ------------------------------------------------------

        function click(selector) {
            const element = document.querySelector(selector);
            if (element) { element.click(); }
            sendState();
        }

        window.__sakuracordMusic = {
            search: function (query) {
                innertube('/youtubei/v1/search', { query: query })
                    .then(function (payload) {
                        post({ type: 'SEARCH', query: query, results: resultsFrom(payload) });
                    })
                    .catch(function () {
                        post({ type: 'SEARCH', query: query, results: [] });
                    });
            },
            openList: function (browseId, playlistId) {
                if (!browseId) { return; }
                // A playlist or album's own page, whose rows are ordinary
                // track rows - the same shape a search shelf uses. Its rows
                // do not name their parent, so restore that context here;
                // otherwise a chosen track can start but has no collection
                // queue to continue through.
                innertube('/youtubei/v1/browse', { browseId: browseId })
                    .then(function (payload) {
                        const results = resultsFrom(payload).map(function (result) {
                            if (!result.playlistId && playlistId) {
                                result.playlistId = playlistId;
                            }
                            return result;
                        });
                        post({
                            type: 'LIST',
                            browseId: browseId,
                            results: results
                        });
                    })
                    .catch(function () {
                        post({ type: 'LIST', browseId: browseId, results: [] });
                    });
            },
            home: function () {
                const generation = ++homeRequestGeneration;
                let attempts = 0;
                function loadQuickPicks(listenAgain) {
                    innertube('/youtubei/v1/browse', { browseId: 'FEmusic_home' })
                        .then(function (payload) {
                            if (generation !== homeRequestGeneration) { return; }
                            const quickPicks = quickPicksSection(sectionsFrom(payload));
                            post({
                                type: 'HOME',
                                sections: [listenAgain, quickPicks].filter(Boolean)
                            });
                        })
                        .catch(function () {
                            if (generation !== homeRequestGeneration) { return; }
                            post({
                                type: 'HOME',
                                sections: listenAgain ? [listenAgain] : []
                            });
                        });
                }
                function capture() {
                    if (generation !== homeRequestGeneration) { return; }
                    const rendered = renderedListenAgainSection();
                    if (rendered) {
                        // Listening history appears as soon as the page has
                        // rendered it; recommendations join it when their
                        // independent request completes.
                        post({ type: 'HOME', sections: [rendered] });
                        loadQuickPicks(rendered);
                        return;
                    }
                    attempts += 1;
                    if (attempts < 32) {
                        window.setTimeout(capture, 250);
                        return;
                    }

                    // A hidden page may not retain its rendered history, but
                    // Quick picks remains independently useful and truthful.
                    loadQuickPicks(null);
                }
                capture();
            },
            play: function (videoId, playlistId) {
                // A collection track needs both pieces: the video chooses
                // the starting song and the playlist keeps the page's queue
                // pointed at its following tracks.
                const route = videoId
                    ? '/watch?v=' + encodeURIComponent(videoId)
                        + (playlistId ? '&list=' + encodeURIComponent(playlistId) : '')
                    : (playlistId ? '/watch?list=' + encodeURIComponent(playlistId) : '');
                if (!route) { return; }
                // Setting location would reload the document: the player
                // would be torn down and rebuilt, the bridge reinjected, and
                // audio would stop for as long as that took. Clicking a link
                // instead lets the page's own router handle it, which swaps
                // the track without leaving the document.
                const previous = currentVideoId();
                const link = document.createElement('a');
                link.href = route;
                link.style.display = 'none';
                document.body.appendChild(link);
                link.click();
                link.remove();
                // The router loads the track but leaves it standing: the
                // click is ours rather than the listener's, so the page does
                // not treat it as the gesture that starts playback. Waiting
                // for the requested track to arrive and then telling the
                // player to run is what makes choosing a song play it.
                //
                // The router also does not always take the click - a page
                // that has not finished booting has no router yet - so a
                // navigation that changed nothing still falls back to a load.
                const requested = videoId;
                let attempts = 0;
                const waiting = window.setInterval(function () {
                    attempts += 1;
                    const current = currentVideoId();
                    // A playlist starts on whichever track it chooses, so it
                    // is satisfied by any track other than the one playing.
                    const arrived = requested
                        ? current === requested
                        : (current && current !== previous);
                    if (arrived) {
                        window.clearInterval(waiting);
                        const player = document.getElementById('movie_player');
                        const media = document.querySelector('video');
                        if (player && typeof player.playVideo === 'function') {
                            player.playVideo();
                        } else if (media && media.paused) {
                            media.play();
                        }
                        sendState();
                        return;
                    }
                    if (attempts === 5 && requested && current !== requested) {
                        window.location.href = route;
                    }
                    if (attempts >= 40) { window.clearInterval(waiting); }
                }, 250);
            },
            playPause: function () { click('.play-pause-button.ytmusic-player-bar'); },
            next: function () { click('.next-button.ytmusic-player-bar'); },
            previous: function () { click('.previous-button.ytmusic-player-bar'); },
            like: function () { click('ytmusic-like-button-renderer #button-shape-like button'); },
            pause: function () {
                const player = document.getElementById('movie_player');
                const media = document.querySelector('video');
                if (player && typeof player.pauseVideo === 'function') { player.pauseVideo(); }
                else if (media && !media.paused) { media.pause(); }
                sendState();
            },
            resume: function () {
                const player = document.getElementById('movie_player');
                const media = document.querySelector('video');
                if (player && typeof player.playVideo === 'function') { player.playVideo(); }
                else if (media && media.paused) { media.play(); }
                sendState();
            },
            seek: function (seconds) {
                const player = document.getElementById('movie_player');
                const media = document.querySelector('video');
                if (!isFinite(seconds) || seconds < 0) { return; }
                if (player && typeof player.seekTo === 'function') {
                    player.seekTo(seconds, true);
                    if (typeof player.playVideo === 'function') { player.playVideo(); }
                } else if (media) {
                    media.currentTime = seconds;
                    if (media.paused) { media.play(); }
                }
                sendState();
            }
        };

        // Announced as soon as the commands exist, which is what a caller is
        // waiting for. Observation of the player bar starts separately below,
        // because a page with nothing playing has no bar yet - waiting for one
        // to report readiness stranded every command issued before playback.
        post({ type: 'READY' });

        // ---- Observing ------------------------------------------------------

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
            startPolling();
            sendState();
        }

        function waitForPlayerBar() {
            const playerBar = document.querySelector('ytmusic-player-bar');
            if (playerBar) { attach(playerBar); return; }
            // A page with nothing playing has no player bar, so this retries
            // rather than failing: starting a track makes one appear.
            setTimeout(waitForPlayerBar, 500);
        }

        window.addEventListener('unload', detachPlayer);
        waitForPlayerBar();
    })();
    """
}
