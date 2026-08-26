import SwiftUI

/// What is playing, as a strip above the account row.
///
/// It sits inside the account panel's own glass rather than carrying its
/// own, so the sidebar's foot stays one continuous piece of material the
/// way it already does when a voice call is connected.
struct MusicNowPlayingBar: View {
    let model: AppModel
    private var music: MusicPlayerModel { model.music }
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(music.state.title)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                Text(music.state.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            transport
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .overlay(alignment: .bottom) { progress }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { model.showsLyrics.toggle() }
        .help(model.showsLyrics ? "Hide lyrics" : "Show lyrics")
    }

    private var artwork: some View {
        AsyncImage(
            url: music.state.artworkURL,
            transaction: Transaction(animation: nil)
        ) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                // Artwork arrives a moment after the title does, and a
                // placeholder that reads as a music tile keeps the row from
                // reflowing when it lands.
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(.rect(cornerRadius: 6))
    }

    private var transport: some View {
        HStack(spacing: 2) {
            // Liking a track is worth reaching for but not worth standing
            // in a narrow sidebar permanently, so it keeps to the hover
            // chrome the rest of the app already uses for secondary actions.
            if isHovered || music.state.likeStatus == .liked {
                transportButton(
                    music.state.likeStatus == .liked ? "heart.fill" : "heart",
                    help: music.state.likeStatus == .liked ? "Unlike" : "Like"
                ) {
                    music.toggleLike()
                }
            }
            transportButton("backward.fill", help: "Previous") { music.previous() }
            transportButton(
                music.state.isPlaying ? "pause.fill" : "play.fill",
                help: music.state.isPlaying ? "Pause" : "Play",
                size: 13
            ) {
                music.playPause()
            }
            transportButton("forward.fill", help: "Next") { music.next() }
        }
    }

    private func transportButton(
        _ systemImage: String,
        help: String,
        size: CGFloat = 11,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// A hairline the width of the played fraction. A track whose duration
    /// the page has not resolved draws nothing rather than a full or empty
    /// bar, either of which would be a claim about progress.
    @ViewBuilder private var progress: some View {
        if music.state.duration > 0 {
            MusicPlaybackProgressView(music: music)
            .frame(height: 2)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
        }
    }
}

/// The only sidebar view that needs the interpolated playback clock.
///
/// Keeping its periodic invalidation in this two-point strip prevents a
/// progress report from rebuilding the account controls and channel sidebar.
private struct MusicPlaybackProgressView: View {
    let music: MusicPlayerModel

    var body: some View {
        if music.state.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                bar(fraction: music.estimatedFractionComplete(at: context.date))
            }
        } else {
            bar(fraction: music.estimatedFractionComplete())
        }
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.tint)
                .frame(width: geometry.size.width * fraction)
                .animation(.linear(duration: 1), value: fraction)
        }
    }
}
