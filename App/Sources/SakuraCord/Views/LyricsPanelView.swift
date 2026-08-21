import SwiftUI

/// The words of whatever is playing, lit as they are sung.
///
/// The clock is a timer feeding state rather than a `TimelineView`. A
/// TimelineView rebuilds its whole body on every tick, which meant the
/// scroll reader and its change handler were recreated ten times a second
/// and never observed a stable change to scroll on. Holding the position in
/// state keeps the view identity still, so the panel can follow the song.
struct LyricsPanelView: View {
    let music: MusicPlayerModel

    @State private var time: TimeInterval = 0
    @State private var activeIndex: Int?

    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: ChatChromeMetrics.memberListWidth)
        .frame(maxHeight: .infinity)
        .onReceive(ticker) { _ in advance() }
    }

    /// Moves the clock on. A paused track still advances nothing, so the
    /// work here is a comparison and no redraw.
    private func advance() {
        let position = music.estimatedProgress()
        guard position != time else { return }
        time = position
        let index = music.lyrics.lyrics.activeIndex(at: position)
        if index != activeIndex {
            activeIndex = index
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(music.state.hasTrack ? music.state.title : "Lyrics")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if music.state.hasTrack {
                Text(music.state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if !music.state.hasTrack {
            message("Nothing playing")
        } else if music.lyrics.lyrics.isEmpty {
            switch music.lyrics.status {
            case .searching:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                message("No lyrics found for this track")
            case .idle, .found:
                message("Nothing playing")
            }
        } else {
            lines
        }
    }

    private var lines: some View {
        let lyrics = music.lyrics.lyrics
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lyrics.lines) { line in
                        LyricLineView(
                            line: line,
                            // Only the sung line needs the clock. Handing it
                            // to every line would redraw the whole song ten
                            // times a second to change one of them.
                            time: activeIndex == line.id ? time : nil,
                            isSynced: lyrics.synchronisation == .line,
                            seek: { music.seek(toSeconds: line.start) }
                        )
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 14)
                // Room to bring the first and last lines to the middle, so
                // the lit line sits in the same place all song.
                .padding(.vertical, 160)
            }
            .scrollIndicators(.never)
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onChange(of: lyrics.lines.count) { _, _ in
                // A new song starts at the top rather than wherever the
                // last one had scrolled to.
                guard let index = activeIndex else { return }
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One line, filled as it is sung.
///
/// Every line other than the active one is dimmed by the same amount. An
/// earlier version faded and blurred by distance from the active line,
/// which decayed the far end of a song into an unreadable smear and made
/// every line on screen re-animate on every transition. Only two lines
/// change now: the one being left and the one being reached.
private struct LyricLineView: View {
    let line: LyricLine

    /// Where playback has reached, but only for the line being sung.
    /// A nil means this line is not the active one.
    let time: TimeInterval?

    /// An unsynced lyric has no line to light, so nothing is dimmed against
    /// a line that does not exist.
    let isSynced: Bool

    let seek: () -> Void

    private var isActive: Bool { time != nil }
    private var isLit: Bool { isActive || !isSynced }

    var body: some View {
        content
            .font(.system(size: 16, weight: isActive ? .bold : .medium))
            .opacity(isLit ? 1 : 0.45)
            // The sung line grows from its leading edge rather than its
            // middle, so the text does not swim sideways as it lights.
            .scaleEffect(isActive ? 1.04 : 1, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            // A line knows when it is sung, so tapping one is a seek. It is
            // the fastest way back to a part of a song you wanted again.
            .onTapGesture(perform: seek)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isActive)
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(line.text.isEmpty ? "Instrumental break" : line.text)
    }

    @ViewBuilder private var content: some View {
        if let time, isSynced, !line.text.isEmpty {
            // Drawn as one attributed run rather than a row of views so the
            // line wraps the way text does; a stack of words would not.
            Text(filled(at: time))
        } else {
            Text(displayText)
                .foregroundStyle(isLit ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
    }

    /// The line with the part sung so far brought up to full strength.
    ///
    /// A richly-timed source knows where each word starts and the fill
    /// follows those. A line-timed source knows only the line's span, so
    /// the fill sweeps across it evenly - an estimate, but one that tracks
    /// the singing far better than lighting the whole line at once.
    private func filled(at time: TimeInterval) -> AttributedString {
        if line.isWordTimed {
            let sung = line.wordsSung(by: time)
            var result = AttributedString()
            for (index, word) in line.words.enumerated() {
                var piece = AttributedString(word.text)
                piece.foregroundColor = index < sung ? .primary : .secondary
                result.append(piece)
            }
            return result
        }

        // Split by character rather than by word: a language that does not
        // put spaces between words - Japanese among them - would otherwise
        // fill in one jump, which is no fill at all.
        let text = line.text
        let sungCount = Int((Double(text.count) * line.fractionSung(by: time)).rounded())
        let cut = text.index(text.startIndex, offsetBy: min(sungCount, text.count))
        var lit = AttributedString(text[..<cut])
        lit.foregroundColor = .primary
        var rest = AttributedString(text[cut...])
        rest.foregroundColor = .secondary
        return lit + rest
    }

    /// A stamp with no words is an instrumental break the writer marked.
    /// Drawn as a note, it reads as part of the song; drawn as the empty
    /// string it was, it reads as a gap where something failed to load.
    private var displayText: String {
        line.text.isEmpty ? "♪" : line.text
    }
}
