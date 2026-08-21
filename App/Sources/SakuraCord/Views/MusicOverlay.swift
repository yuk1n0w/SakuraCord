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

    func makeNSView(context _: Context) -> WKWebView {
        music.webViewForDisplay()
    }

    func updateNSView(_: WKWebView, context _: Context) {}
}

/// Searching and playing, drawn natively over the workspace.
struct MusicOverlayView: View {
    let model: AppModel
    let animationState: WindowModalAnimationState

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var music: MusicPlayerModel { model.music }

    var body: some View {
        ZStack {
            Color.black.opacity(
                WindowModalVisualStyle.menuBackgroundDimmingOpacity
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { music.presentation = nil }

            GlassEffectContainer(spacing: 0) {
                VStack(spacing: 0) {
                    searchField
                    Divider()
                    results
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

            // The engine. Present so it keeps playing, and never looked at.
            MusicWebViewHost(music: music)
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityHidden(!animationState.isVisible)
        .onAppear { isSearchFocused = true }
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
                .onSubmit { music.search(query) }
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
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    @ViewBuilder private var results: some View {
        if music.searchResults.isEmpty {
            VStack(spacing: 6) {
                Text(emptyTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(music.searchResults) { result in
                        MusicSearchRow(
                            result: result,
                            isPlaying: result.videoId == music.state.videoID,
                            play: { music.play(result) }
                        )
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var emptyTitle: String {
        if music.isSearching { return "Searching…" }
        return music.searchQuery.isEmpty
            ? "Search for something to play"
            : "Nothing found for “\(music.searchQuery)”"
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
            url: result.artworkURL,
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
