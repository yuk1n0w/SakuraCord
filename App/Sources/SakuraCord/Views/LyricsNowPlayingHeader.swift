import SwiftUI

/// The song above its lyrics: artwork, a title and artist that roll when they
/// do not fit, the transport, and a scrubber. It sits on the window's own
/// surface like the rest of the workspace, lit only by a soft glow taken from
/// the artwork.
struct LyricsNowPlayingHeader: View {
    let music: MusicPlayerModel

    private static let artworkSize: CGFloat = 68

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(
                        text: music.state.hasTrack ? music.state.title : "Nothing playing",
                        font: .system(size: 15, weight: .semibold),
                        isRolling: music.state.isPlaying
                    )
                    if music.state.hasTrack {
                        MarqueeText(
                            text: music.state.artist,
                            font: .system(size: 13),
                            isRolling: music.state.isPlaying
                        )
                        .foregroundStyle(.secondary)
                    }
                    if music.state.hasTrack {
                        transport
                            .padding(.top, 3)
                    }
                }
            }
            if music.state.hasTrack, music.state.duration > 0 {
                LyricsPlaybackScrubber(music: music)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(alignment: .top) { artworkGlow }
    }

    private var artwork: some View {
        ArtworkImage(url: music.state.artworkURL)
            .frame(width: Self.artworkSize, height: Self.artworkSize)
            .clipShape(.rect(cornerRadius: 10))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            .accessibilityHidden(true)
    }

    /// The artwork, blurred far past recognition, tinting the top of the pane
    /// and fading out before the lyrics begin.
    @ViewBuilder private var artworkGlow: some View {
        if music.state.hasTrack, music.state.artworkURL != nil {
            ArtworkImage(url: music.state.artworkURL)
                .frame(height: 170)
                .frame(maxWidth: .infinity)
                .blur(radius: 42)
                .opacity(0.4)
                .mask {
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var transport: some View {
        HStack(spacing: 4) {
            transportButton(
                music.state.likeStatus == .liked ? "heart.fill" : "heart",
                help: music.state.likeStatus == .liked ? "Unlike" : "Like"
            ) { music.toggleLike() }
            transportButton("backward.fill", help: "Previous") { music.previous() }
            transportButton(
                music.state.isPlaying ? "pause.fill" : "play.fill",
                help: music.state.isPlaying ? "Pause" : "Play",
                size: 15
            ) { music.playPause() }
            transportButton("forward.fill", help: "Next") { music.next() }
        }
        .foregroundStyle(.primary)
    }

    private func transportButton(
        _ systemImage: String,
        help: String,
        size: CGFloat = 12,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ArtworkImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                // Artwork lands a moment after the title; a music tile keeps
                // the header from reflowing when it does.
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}

/// Played time over a draggable track. It owns the interpolated clock, so a
/// once-a-second tick redraws this strip rather than the whole header.
private struct LyricsPlaybackScrubber: View {
    let music: MusicPlayerModel
    @State private var scrubFraction: Double?

    var body: some View {
        if music.state.isPlaying, scrubFraction == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(fraction: music.estimatedFractionComplete(at: context.date))
            }
        } else {
            content(fraction: scrubFraction ?? music.estimatedFractionComplete())
        }
    }

    private func content(fraction: Double) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.tint)
                        .frame(width: geometry.size.width * fraction)
                        .animation(scrubFraction == nil ? .linear(duration: 1) : nil, value: fraction)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrubFraction = Self.fraction(value.location.x, width: geometry.size.width)
                        }
                        .onEnded { value in
                            music.seek(toFraction: Self.fraction(
                                value.location.x,
                                width: geometry.size.width
                            ))
                            scrubFraction = nil
                        }
                )
            }
            .frame(height: 12)

            HStack {
                Text(Self.time(fraction * music.state.duration))
                Spacer(minLength: 0)
                Text("-" + Self.time(max(0, (1 - fraction) * music.state.duration)))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            "\(Self.time(fraction * music.state.duration)) of \(Self.time(music.state.duration))"
        )
    }

    private static func fraction(_ position: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(position / width, 0), 1))
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A single line that rolls sideways when it is wider than its space, then
/// loops seamlessly. It rests when `isRolling` is false or Reduce Motion is on,
/// so a paused track costs nothing.
struct MarqueeText: View {
    let text: String
    let font: Font
    var isRolling = true

    private static let gap: CGFloat = 36
    private static let pointsPerSecond: CGFloat = 30
    private static let restBeforeRolling: Duration = .seconds(2)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        // The hidden line sets the height and the width the text may use.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .overlay(alignment: .leading) {
                HStack(spacing: Self.gap) {
                    label
                    if overflows { label }
                }
                .fixedSize()
                .offset(x: offset)
            }
            .clipped()
            .mask { edgeFade }
            .task(id: RollKey(text: text, width: textWidth, rolls: rolls)) {
                await roll()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
    }

    private var overflows: Bool {
        textWidth > availableWidth + 0.5
    }

    private var rolls: Bool {
        overflows && isRolling && !reduceMotion
    }

    /// Softens only the edge the text is scrolling through.
    private var edgeFade: some View {
        LinearGradient(
            stops: overflows
                ? [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.9),
                    .init(color: .clear, location: 1),
                ]
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func roll() async {
        withTransaction(Transaction(animation: nil)) { offset = 0 }
        guard rolls else { return }
        let distance = textWidth + Self.gap
        let duration = Double(distance / Self.pointsPerSecond)
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.restBeforeRolling)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // The second copy now sits exactly where the first began, so the
            // jump back is invisible.
            withTransaction(Transaction(animation: nil)) { offset = 0 }
        }
    }

    private struct RollKey: Equatable {
        let text: String
        let width: CGFloat
        let rolls: Bool
    }
}
