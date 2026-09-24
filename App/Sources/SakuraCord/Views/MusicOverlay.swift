import AppKit
import SwiftUI
import WebKit

/// The music surface's presentation. One case today, but the overlay
/// machinery keys off an identifiable value the way the workspace
/// navigation overlay does.
enum MusicOverlayPresentation: String, Identifiable {
    case browse

    var id: Self { self }
}

/// Hosts the live YouTube Music page.
///
/// This is the audio engine, not the interface. YouTube Music's licensed
/// audio only decodes inside Google's own player, so the page runs - but
/// nothing of it is shown, and it does no layout or painting worth the
/// name at this size. Everything the listener looks at is drawn natively.
///
/// It stays mounted because it is playing: the overlay retains its host
/// when dismissed, so closing the panel hides the interface without
/// stopping the music.
struct MusicWebViewHost: NSViewRepresentable {
    let music: MusicPlayerModel

    final class Coordinator {
        let music: MusicPlayerModel

        init(music: MusicPlayerModel) {
            self.music = music
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(music: music)
    }

    func makeNSView(context _: Context) -> WKWebView {
        music.webViewForPresentation()
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    static func dismantleNSView(_: WKWebView, coordinator: Coordinator) {
        coordinator.music.parkWebView()
    }
}

/// Searching and playing, drawn natively over the workspace.
struct MusicOverlayView: View {
    let model: AppModel
    let animationState: WindowModalAnimationState

    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var music: MusicPlayerModel { model.music }

    var body: some View {
        ZStack {
            // The retained modal exists after it closes only to keep the
            // player attached. Removing its native chrome here releases the
            // feed's image views and AttributeGraph instead of preserving a
            // hidden copy of the whole browser surface for the rest of the
            // app session.
            if music.presentation != nil {
                Color.black.opacity(
                    WindowModalVisualStyle.menuBackgroundDimmingOpacity
                )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { music.presentation = nil }

                GlassEffectContainer(spacing: 0) {
                    VStack(spacing: 0) {
                        if music.showsPage {
                            pageHeader
                            Divider()
                            // The page fills the panel while it is showing, so
                            // Google's own sign-in flow has somewhere to run.
                            MusicWebViewHost(music: music)
                                .clipShape(.rect(cornerRadius: 8))
                                .padding(10)
                        } else {
                            searchField
                            Divider()
                            discordPresenceControls
                            Divider()
                            results
                        }
                    }
                    .glassEffect(
                        .regular,
                        in: ConcentricRectangle(
                            corners: .concentric(minimum: .fixed(20)),
                            isUniform: true
                        )
                    )
                }
                .frame(maxWidth: 720, maxHeight: 620)
                .padding(28)
                .scaleEffect(animationState.isVisible ? 1 : 0.97)
                .opacity(animationState.isVisible ? 1 : 0)
            }

            // The model retains the player in a nonvisible engine window when
            // Google's page is not being shown. That keeps playback alive
            // without attaching WebKit's video layer to the chat window.
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityHidden(!animationState.isVisible)
        .onAppear {
            isSearchFocused = true
            music.loadHomeIfNeeded()
        }
    }

    /// Shown while the page itself is on screen.
    private var pageHeader: some View {
        HStack(spacing: 9) {
            Text(music.state.isSignedIn ? "YouTube Music" : "Sign in to YouTube Music")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 8)
            Button("Done") { music.showsPage = false }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search songs, albums, artists", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isSearchFocused)
                .onSubmit {
                    searchTask?.cancel()
                    music.search(query)
                }
                // Searching as the query is typed, because waiting for
                // Return reads as a field that does nothing. Held briefly
                // so a word being typed is one search rather than one per
                // keystroke.
                .onChange(of: query) { _, typed in
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        music.search(typed)
                    }
                }
            if music.isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }

            // The way back to the page. Signed out it is the only way to
            // sign in; signed in it is the way to anything this surface
            // does not draw natively yet.
            Button {
                music.showsPage = true
            } label: {
                if music.state.isSignedIn {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sign in").font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .help(music.state.isSignedIn ? "Open YouTube Music" : "Sign in")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var discordPresenceControls: some View {
        HStack(spacing: 12) {
            Toggle(
                "Show what I'm listening to on Discord",
                isOn: Binding(
                    get: { music.discordPresence.isEnabled },
                    set: { music.discordPresence.setEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .disabled(model.activeAccountID == nil || !music.discordPresence.isAvailable)

            Spacer(minLength: 8)

            Text(discordPresenceStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(discordPresenceStatus)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var discordPresenceStatus: String {
        if !music.discordPresence.isAvailable { return "SDK not included in this build" }
        if model.activeAccountID == nil { return "Sign in to SakuraCord first" }
        return music.discordPresence.statusText
            ?? (music.discordPresence.isEnabled ? "Only while playing and visible" : "Off")
    }

    @ViewBuilder private var results: some View {
        if let list = music.openedList {
            openedList(list)
        } else if !music.searchResults.isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(music.searchResults) { result in
                        MusicSearchRow(
                            result: result,
                            isPlaying: music.isPlaying(result),
                            play: { music.play(result) }
                        )
                    }
                }
                .padding(.vertical, 6)
            }
        } else if music.searchQuery.isEmpty, !music.homeSections.isEmpty {
            home
        } else {
            Text(emptyTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A playlist or album, with its tracks.
    private func openedList(_ list: MusicOpenedList) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button {
                    music.closeList()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Back")

                AsyncImage(
                    url: list.artworkURL,
                    transaction: Transaction(animation: nil)
                ) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(list.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if !list.subtitle.isEmpty {
                        Text(list.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if list.isLoading, list.items.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if list.items.isEmpty {
                Text("Nothing in here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list.items) { item in
                            MusicSearchRow(
                                result: item,
                                isPlaying: music.isPlaying(item),
                                play: { music.play(item) }
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    /// The home feed, so the panel opens onto something to play rather than
    /// onto an empty field that has to be guessed at.
    private var home: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(music.homeSections) { section in
                    VStack(alignment: .leading, spacing: 9) {
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 16)
                        }
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(section.items) { item in
                                    MusicCard(
                                        item: item,
                                        isPlaying: music.isPlaying(item),
                                        play: { music.play(item) },
                                        open: item.browseId.isEmpty
                                            ? nil
                                            : { music.openList(item) }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
            .padding(.vertical, 14)
        }
    }

    private var emptyTitle: String {
        if music.isSearching { return "Searching…" }
        if music.searchQuery.isEmpty {
            return music.isLoadingHome ? "Loading…" : "Search for something to play"
        }
        return "Nothing found for “\(music.searchQuery)”"
    }
}

/// One search result.
private struct MusicSearchRow: View {
    let result: MusicSearchResult
    let isPlaying: Bool
    let play: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 11) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 14, weight: isPlaying ? .semibold : .regular))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.primary.opacity(0.08))
                    .padding(.horizontal, 8)
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: play)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(result.title), \(result.subtitle)")
    }

    private var artwork: some View {
        AsyncImage(
            url: result.artworkURL(size: 120),
            transaction: Transaction(animation: nil)
        ) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(.rect(cornerRadius: 5))
    }
}

/// One card in a home shelf.
private struct MusicCard: View {
    let item: MusicSearchResult
    let isPlaying: Bool
    let play: () -> Void

    /// Present when the card is a collection rather than a track. Opening
    /// one to see what is in it is what a feed of albums is for; playing it
    /// outright is the deliberate act, so that takes the explicit button.
    let open: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(
                // 256 pixels covers a 116-point card at Retina scale without
                // retaining a needlessly larger decoded bitmap per tile.
                url: item.artworkURL(size: 256),
                transaction: Transaction(animation: nil)
            ) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 116, height: 116)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                if isHovered || isPlaying {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.35))
                        .overlay {
                            Button(action: play) {
                                Image(
                                    systemName: isPlaying
                                        ? "speaker.wave.2.fill"
                                        : "play.fill"
                                )
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .help("Play")
                        }
                }
            }

            Text(item.title)
                .font(.system(size: 12, weight: isPlaying ? .semibold : .medium))
                .lineLimit(2)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 116)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { (open ?? play)() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
    }
}
