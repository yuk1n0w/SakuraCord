import AppKit
import QuartzCore
import SwiftUI

/// The words of whatever is playing, lit as they are sung.
///
/// The panel owns only the active line. Its high-frequency playback value lives
/// in the active text child, so local seeks and track transitions repaint the
/// words immediately without laying out the complete panel ten times a second.
struct LyricsPanelView: View {
    let music: MusicPlayerModel

    @State private var activeIndex: Int?

    /// Line changes do not need display-rate polling. The active line still
    /// changes within a single animation frame at 15 Hz, while the word fill
    /// owns the smoother clock in the active text child.
    private static let tick = Duration.milliseconds(66)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: ChatChromeMetrics.memberListWidth)
        .frame(maxHeight: .infinity)
        // Only a running clock can move the lit line on. Polling a paused
        // track woke the main run loop fifteen times a second to decide that
        // nothing had changed; a seek moves the line along directly instead.
        .task(id: music.state.isClockRunning) {
            advance()
            guard music.state.isClockRunning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard !Task.isCancelled else { return }
                advance()
            }
        }
        .onChange(of: music.state.videoID) { _, _ in
            activeIndex = nil
            advance()
        }
    }

    /// Moves the clock on. A paused track still advances nothing, so the
    /// work here is a comparison and no redraw.
    private func advance() {
        let lyrics = music.lyrics.lyrics
        let position = music.estimatedProgress() + lyrics.timingLead
        let index = lyrics.activeIndex(at: position)
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
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lyrics.lines) { line in
                        LyricLineView(
                            line: line,
                            music: music,
                            isActive: activeIndex == line.id,
                            isSynced: lyrics.synchronisation == .line,
                            timingLead: lyrics.timingLead,
                            seek: {
                                music.seek(toSeconds: line.start)
                                advance()
                            }
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
            .id(music.state.videoID)
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                // cubic-bezier(0.86, 0, 0.2, 1) over 0.5s: a slow start,
                // a fast middle and a long settle, which is what stops the
                // panel from feeling like it jumps between lines.
                withAnimation(.timingCurve(0.86, 0, 0.2, 1, duration: 0.34)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onChange(of: lyrics.lines.count) { _, _ in
                // A new song starts at the top rather than wherever the
                // last one had scrolled to.
                guard let index = activeIndex else { return }
                proxy.scrollTo(index, anchor: .center)
            }
            .onChange(of: visibleDecorationLayout) { _, _ in
                guard let index = activeIndex else { return }
                // Romanization and translation arrive after the primary
                // lyrics. Their new rows change every preceding line's
                // height, so re-anchor after SwiftUI has laid them out rather
                // than leaving the sung line to jump away from the centre.
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.timingCurve(0.86, 0, 0.2, 1, duration: 0.24)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    private var visibleDecorationLayout: [String?] {
        music.lyrics.lyrics.lines.flatMap { line in
            [
                music.lyrics.showsRomanization ? line.romanization : nil,
                music.lyrics.showsTranslation
                    ? line.translation(for: music.lyrics.translationLanguage)
                    : nil,
            ]
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
/// The weights, sizes and timings follow Better Lyrics' own defaults, scaled
/// for a sidebar panel rather than the half-window it draws into: every line
/// is bold, an inactive line sits at a third of full strength and slightly
/// shrunk, and becoming active is a fast scale rather than a slow fade.
private struct LyricLineView: View {
    let line: LyricLine
    let music: MusicPlayerModel

    let isActive: Bool

    /// An unsynced lyric has no line to light, so nothing is dimmed against
    /// a line that does not exist.
    let isSynced: Bool

    let timingLead: TimeInterval

    let seek: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Better Lyrics' inactive opacity. Dimmer than it sounds, which is what
    /// makes the sung line carry without the rest disappearing.
    private static let inactiveOpacity: Double = 0.3

    /// The original native treatment lifts the active line just enough to
    /// read as buoyant without making the surrounding lyrics jump.
    private static let activeScale: Double = 1.04

    /// Width of the gradient's soft edge in points. Better Lyrics' percentage
    /// edge is drawn at much larger type; keeping a point floor stops a short
    /// sidebar word from collapsing that edge into a two-pixel guillotine.
    private static let sweepSoftness: Double = 10

    private var isLit: Bool { isActive || !isSynced }
    private var romanization: String? {
        guard music.lyrics.showsRomanization else { return nil }
        return line.romanization
    }

    private var translation: String? {
        guard music.lyrics.showsTranslation else { return nil }
        return line.translation(for: music.lyrics.translationLanguage)
    }

    private var secondaryOpacity: Double {
        isLit ? 0.62 : 0.24
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            primaryContent

            if let romanization {
                romanizationContent(romanization)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(isActive ? 0.055 : 0.025))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(.white.opacity(isActive ? 0.11 : 0.055))
                            }
                    }
                    .opacity(secondaryOpacity)
            }

            if let translation {
                Text(translation)
                    .font(.system(size: 15, weight: .semibold))
                    .lineSpacing(2)
                    .foregroundStyle(.primary)
                    .opacity(secondaryOpacity)
            }
        }
            .font(.system(size: 23, weight: .bold))
            .lineSpacing(23 * 0.333)
            .scaleEffect(
                reduceMotion || !isActive ? 1 : Self.activeScale,
                anchor: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            // A line knows when it is sung, so tapping one is a seek. It is
            // the fastest way back to a part of a song you wanted again.
            .onTapGesture(perform: seek)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.32, dampingFraction: 0.82),
                value: isActive
            )
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var primaryContent: some View {
        if line.text.isEmpty {
            // An instrumental break, drawn as the note the extension draws.
            Text("♪")
                .foregroundStyle(.primary)
                .opacity(isLit ? 1 : Self.inactiveOpacity)
        } else if isActive, isSynced {
            // The line fills across as it is sung. It remains one shaped text
            // layout so wrapping and bidirectional text stay native even
            // though its marked glyph runs animate independently.
            ActiveLyricText(
                line: line,
                music: music,
                inactiveOpacity: Self.inactiveOpacity,
                sweepSoftness: Self.sweepSoftness,
                timingLead: timingLead,
                reduceMotion: reduceMotion
            )
        } else {
            Text(line.text)
                .foregroundStyle(.primary)
                .opacity(isLit ? 1 : Self.inactiveOpacity)
        }
    }

    @ViewBuilder private func romanizationContent(_ text: String) -> some View {
        // Romanization is supporting copy, not a second karaoke surface.
        // Repainting it with its own display clock doubled the hottest lyric
        // rendering path whenever language helpers were enabled.
        Text(text)
            .foregroundStyle(.primary)
        .font(.system(size: 13, weight: .semibold))
        .lineSpacing(2)
    }

    private var accessibilityLabel: String {
        if line.text.isEmpty { return "Instrumental break" }
        return [line.text, romanization, translation]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

/// The only lyric view that follows the display clock.
///
/// Its clock lives in an AppKit leaf view. Invalidating that leaf repaints the
/// glyphs without asking SwiftUI to lay out the entire window for every lyric
/// frame, which is crucial while the message timeline and glass chrome are on
/// screen beside it.
private struct ActiveLyricText: NSViewRepresentable {
    let line: LyricLine
    let music: MusicPlayerModel
    let inactiveOpacity: Double
    let sweepSoftness: Double
    let timingLead: TimeInterval
    let reduceMotion: Bool

    func makeNSView(context _: Context) -> StylizedLyricsTextView {
        let view = StylizedLyricsTextView()
        configure(view)
        return view
    }

    func updateNSView(_ view: StylizedLyricsTextView, context _: Context) {
        configure(view)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: StylizedLyricsTextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.requiredHeight(for: width))
    }

    private func configure(_ view: StylizedLyricsTextView) {
        view.configure(
            line: line,
            music: music,
            inactiveOpacity: inactiveOpacity,
            sweepSoftness: sweepSoftness,
            timingLead: timingLead,
            reduceMotion: reduceMotion
        )
    }
}

/// One independently animated run. Rich lyrics use the provider's exact
/// spans. Line-timed lyrics retain their existing whole-line sweep, but their
/// visible words receive the same short stagger Better Lyrics gives its
/// line-synced tokens so the line still settles with some life.
private nonisolated struct AnimatedLyricSegment: Equatable, Sendable {
    let index: Int
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let moves: Bool
    let characterCount: Int

    static func makeSegments(for line: LyricLine) -> [Self] {
        if line.isWordTimed {
            return line.words.enumerated().map { index, word in
                Self(
                    index: index,
                    text: word.text,
                    start: word.start,
                    end: word.end,
                    moves: !word.text.allSatisfy(\.isWhitespace),
                    characterCount: word.text.count
                )
            }
        }

        let tokens = tokens(in: line.text)
        var wordIndex = 0
        return tokens.enumerated().map { index, token in
            let isWhitespace = token.allSatisfy(\.isWhitespace)
            let start = line.start + Double(wordIndex) * 0.05
            if !isWhitespace {
                wordIndex += 1
            }
            return Self(
                index: index,
                text: token,
                start: start,
                end: start,
                moves: !isWhitespace,
                characterCount: token.count
            )
        }
    }

    private static func tokens(in text: String) -> [String] {
        guard let first = text.first else { return [] }
        var result: [String] = []
        var token = String(first)
        var tokenIsWhitespace = first.isWhitespace

        for character in text.dropFirst() {
            if character.isWhitespace == tokenIsWhitespace {
                token.append(character)
            } else if character.isWhitespace {
                // Keep a word and its following spacing in one marked run.
                // It halves the amount of text work during line-timed lyrics
                // without changing wrapping or the visible stagger.
                token.append(character)
                tokenIsWhitespace = true
            } else {
                result.append(token)
                token = String(character)
                tokenIsWhitespace = false
            }
        }
        result.append(token)
        return result
    }
}

/// Better Lyrics' stylized word treatment, drawn in an isolated native view.
///
/// The dim and lit glyph images are shaped once. Core Animation gradients then
/// sweep across the timed words at display cadence, preserving native text
/// layout without slicing individual glyphs into hard rectangular pieces.
private final class StylizedLyricsTextView: NSView {
    private struct SweepFragment {
        let characterOffset: Int
        let characterCount: Int
        let contentFrame: CGRect
        let highlightMask: CAGradientLayer
        let glowMask: CAGradientLayer
    }

    private struct VisualFragment {
        let characterOffset: Int
        var characterCount: Int
        var frame: CGRect
    }

    private struct SegmentLayout {
        let segment: AnimatedLyricSegment
        let characters: [NSRange]
        var characterRects: [CGRect] = []
        var sweepFragments: [SweepFragment] = []

        /// The word's own halo. Each one pulses on its own clock, so the
        /// flare belongs to a layer per word rather than to the line.
        var glowLayer: CALayer?
    }

    /// How far the halo spreads. Better Lyrics blooms 0.8rem from three-rem
    /// type; at the size a sidebar draws that is this many points.
    private static let glowRadius: CGFloat = 6

    /// Better Lyrics holds the flare for a little longer than the word it
    /// belongs to, with a floor so a short syllable still registers.
    private static let glowDurationRatio: Double = 1.2
    private static let shortestGlow: TimeInterval = 1.2

    /// The halo is a supporting light, not a second copy of the words.
    private static let glowStrength: Double = 0.9

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()
    private let baseLayer = CALayer()
    private let glowContainer = CALayer()
    private let highlightLayer = CALayer()
    private let highlightMask = CALayer()

    private weak var music: MusicPlayerModel?
    private var line: LyricLine?
    private var segmentLayouts: [SegmentLayout] = []
    private var inactiveOpacity = 0.3
    private var sweepSoftness = 0.1
    private var timingLead: TimeInterval = 0
    private var timer: Timer?
    private var reduceMotion = false
    private var glowImage: CGImage?
    private var laidOutWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.maximumNumberOfLines = 0
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)

        wantsLayer = true
        layer?.masksToBounds = false
        baseLayer.contentsGravity = .topLeft
        highlightLayer.contentsGravity = .topLeft
        highlightLayer.mask = highlightMask
        glowContainer.masksToBounds = false
        layer?.addSublayer(baseLayer)
        layer?.addSublayer(glowContainer)
        layer?.addSublayer(highlightLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setTimerRunning(music?.state.isClockRunning ?? false)
    }

    /// Follows the display clock only while the words are actually moving.
    ///
    /// A paused track, an advertisement or a window the panel is not in
    /// cannot change what is lit, and a repeating timer that wakes the main
    /// run loop thirty times a second to decide that is the kind of idle
    /// cost this panel exists to avoid.
    private func setTimerRunning(_ isRunning: Bool) {
        let interval = reduceMotion ? 1.0 / 10 : 1.0 / 30
        guard isRunning, window != nil else {
            timer?.invalidate()
            timer = nil
            return
        }
        if let timer, timer.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func configure(
        line: LyricLine,
        music: MusicPlayerModel,
        inactiveOpacity: Double,
        sweepSoftness: Double,
        timingLead: TimeInterval,
        reduceMotion: Bool
    ) {
        self.music = music
        self.inactiveOpacity = inactiveOpacity
        self.sweepSoftness = sweepSoftness
        self.timingLead = timingLead
        self.reduceMotion = reduceMotion

        let rebuildsPrimaryLayers = self.line.map {
            !$0.hasSamePrimaryAnimation(as: line)
        } ?? true
        self.line = line
        if rebuildsPrimaryLayers {
            rebuildText(for: line)
            laidOutWidth = 0
            invalidateIntrinsicContentSize()
        }
        setTimerRunning(music.state.isClockRunning)
        updateMask()
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        updateContainerWidth(width)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height + 4)
    }

    override func layout() {
        super.layout()
        updateContainerWidth(bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        baseLayer.frame = frame
        glowContainer.frame = frame
        highlightLayer.frame = frame
        highlightMask.frame = frame
        CATransaction.commit()
    }

    @objc private func tick() {
        guard let music, music.state.isClockRunning, window != nil else { return }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        updateMask()
        AppPerformanceDiagnostics.recordOperation(
            "LyricsWordHighlightUpdate",
            durationNanoseconds:
                DispatchTime.now().uptimeNanoseconds - startedAt
        )
    }

    private func rebuildText(for line: LyricLine) {
        removeGlowLayers()
        let segments = AnimatedLyricSegment.makeSegments(for: line)
        let completeText = segments.map(\.text).joined()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 23 * 0.333
        storage.setAttributedString(
            NSAttributedString(
                string: completeText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 23, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )

        var utf16Offset = 0
        segmentLayouts = segments.map { segment in
            let string = segment.text as NSString
            var characterRanges: [NSRange] = []
            var localOffset = 0
            for character in segment.text {
                let length = String(character).utf16.count
                characterRanges.append(NSRange(location: utf16Offset + localOffset, length: length))
                localOffset += length
            }
            utf16Offset += string.length
            return SegmentLayout(segment: segment, characters: characterRanges)
        }
    }

    private func updateMask() {
        guard let line, let music, laidOutWidth > 0 else { return }
        let time = music.estimatedProgress() + timingLead
        let lineProgress = line.fractionSung(by: time)
        let totalCharacters = max(segmentLayouts.reduce(0) { $0 + $1.characters.count }, 1)
        let fillDuration = line.fillDuration
        var lineCharacterOffset = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in segmentLayouts.indices {
            let layout = segmentLayouts[index]
            var progress = highlightProgress(
                at: time,
                segment: layout.segment,
                lineProgress: lineProgress,
                usesRichTiming: line.isWordTimed
            )

            // A line-timed source has one clock for the entire sentence. Map
            // that clock into each token before applying the same gradient,
            // so its words sweep in sequence instead of all filling together.
            if !line.isWordTimed, !layout.characters.isEmpty {
                let head = lineProgress * Double(totalCharacters)
                progress = clamp(
                    (head - Double(lineCharacterOffset))
                        / Double(layout.characters.count)
                )
            }

            for fragment in layout.sweepFragments {
                let fragmentProgress: Double
                if layout.characters.count > fragment.characterCount {
                    let head = progress * Double(layout.characters.count)
                    fragmentProgress = clamp(
                        (head - Double(fragment.characterOffset))
                            / Double(fragment.characterCount)
                    )
                } else {
                    fragmentProgress = progress
                }
                updateSweep(
                    fragment.highlightMask,
                    contentFrame: fragment.contentFrame,
                    progress: fragmentProgress
                )
                updateSweep(
                    fragment.glowMask,
                    contentFrame: fragment.contentFrame,
                    progress: fragmentProgress
                )
            }
            if let glowLayer = layout.glowLayer {
                // A line-timed source never says when a word starts, so its
                // flare is placed where the line's own fill reaches it. The
                // glow and the fill then share one clock instead of drifting.
                let share = Double(layout.characters.count) / Double(totalCharacters)
                let reached = Double(lineCharacterOffset) / Double(totalCharacters)
                let start = line.isWordTimed
                    ? layout.segment.start
                    : line.start + fillDuration * reached
                let duration = line.isWordTimed
                    ? layout.segment.end - layout.segment.start
                    : fillDuration * share
                glowLayer.opacity = Float(
                    glowAmount(at: time, start: start, duration: duration)
                )
            }
            lineCharacterOffset += layout.characters.count
        }
        CATransaction.commit()
    }

    /// Better Lyrics flares the word being sung and lets the flare fall away
    /// over the word's own length. The decay is what makes a line read as a
    /// voice moving through it rather than as a row of lamps switching on.
    private func glowAmount(
        at time: TimeInterval,
        start: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard !reduceMotion else { return 0 }
        let elapsed = time - start
        guard elapsed >= 0 else { return 0 }
        let span = max(duration * Self.glowDurationRatio, Self.shortestGlow)
        let progress = clamp(elapsed / span)
        return pow(1 - progress, 1.6) * Self.glowStrength
    }

    /// Moves a soft opaque-to-transparent band across one visual word run.
    ///
    /// Better Lyrics starts the band outside the word and lets it finish past
    /// the far edge. Reproducing that gradient is the important detail here:
    /// a rectangular per-character mask visibly cuts vertical slices through
    /// curved glyphs, while this edge remains continuous through the text.
    private func updateSweep(
        _ mask: CAGradientLayer,
        contentFrame: CGRect,
        progress: Double
    ) {
        let contentWidth = Double(max(contentFrame.width, 1))
        let maskWidth = Double(max(mask.bounds.width, 1))
        let contentSoftness = min(
            max(sweepSoftness / contentWidth, 0.1),
            0.5
        )
        let contentOffset = Double(contentFrame.minX - mask.frame.minX)
        let position = (
            contentOffset + (-0.2 + 1.6 * clamp(progress)) * contentWidth
        ) / maskWidth
        let softness = contentSoftness * contentWidth / maskWidth
        let end = position + softness
        let opaque = NSColor.white.cgColor
        let transparent = NSColor.clear.cgColor

        if end <= 0 {
            mask.colors = [transparent, transparent]
            mask.locations = [0, 1]
        } else if position >= 1 {
            mask.colors = [opaque, opaque]
            mask.locations = [0, 1]
        } else if position <= 0 {
            let alpha = clamp(end / softness)
            let leading = NSColor.white.withAlphaComponent(alpha).cgColor
            mask.colors = [leading, transparent, transparent]
            mask.locations = [0, NSNumber(value: min(end, 1)), 1]
        } else if end >= 1 {
            let alpha = clamp((end - 1) / softness)
            let trailing = NSColor.white.withAlphaComponent(alpha).cgColor
            mask.colors = [opaque, opaque, trailing]
            mask.locations = [0, NSNumber(value: position), 1]
        } else {
            mask.colors = [opaque, opaque, transparent, transparent]
            mask.locations = [
                0,
                NSNumber(value: position),
                NSNumber(value: end),
                1,
            ]
        }
    }

    private func highlightProgress(
        at time: TimeInterval,
        segment: AnimatedLyricSegment,
        lineProgress: Double,
        usesRichTiming: Bool
    ) -> Double {
        // Reduce Motion keeps the information and drops the movement: a word
        // arrives when it is sung, and a line that knows only its own start
        // is simply lit rather than swept.
        guard !reduceMotion else {
            guard usesRichTiming else { return 1 }
            return time >= segment.start ? 1 : 0
        }
        guard usesRichTiming else { return lineProgress }
        let duration = segment.end - segment.start
        guard duration > 0 else { return time >= segment.start ? 1 : 0 }
        let swipeStart = segment.start - duration * 0.1
        return clamp((time - swipeStart) / (duration * 1.6))
    }

    private func updateContainerWidth(_ width: CGFloat) {
        guard width > 0, width != laidOutWidth else { return }
        laidOutWidth = width
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        contentHeight = ceil(layoutManager.usedRect(for: textContainer).height + 4)

        for index in segmentLayouts.indices {
            segmentLayouts[index].characterRects = segmentLayouts[index].characters.map { range in
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                var rect = layoutManager.boundingRect(
                    forGlyphRange: glyphRange,
                    in: textContainer
                )
                rect.origin.y += 2
                return rect
            }
        }
        rebuildLayers(width: width, height: contentHeight)
        updateMask()
    }

    private func rebuildLayers(width: CGFloat, height: CGFloat) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let fullRange = NSRange(location: 0, length: storage.length)

        // The dim line is the lit one at a lower layer opacity. Shaping and
        // rasterizing the same glyphs a second time only to draw them paler
        // doubled the work every line change costs.
        storage.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: fullRange
        )
        let highlightImage = renderedImage(width: width, height: height, scale: scale)
        glowImage = highlightImage.flatMap { glyphs in
            haloImage(width: width, height: height, scale: scale, without: glyphs)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.contentsScale = scale
        highlightLayer.contentsScale = scale
        highlightMask.contentsScale = scale
        baseLayer.contents = highlightImage
        baseLayer.opacity = Float(inactiveOpacity)
        highlightLayer.contents = highlightImage
        rebuildSweepLayers(width: width, height: height, scale: scale)
        CATransaction.commit()
    }

    /// The halo without the glyphs that cast it.
    ///
    /// Keeping the letterforms out of the flare is what lets a word glow
    /// before the fill has crossed it: only the aura brightens, so the words
    /// still arrive on the sweep rather than ahead of it.
    private func haloImage(
        width: CGFloat,
        height: CGFloat,
        scale: CGFloat,
        without glyphs: CGImage
    ) -> CGImage? {
        guard let lit = renderedImage(
            width: width,
            height: height,
            scale: scale,
            glow: Self.glowRadius
        ) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: lit.width,
            height: lit.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let rect = CGRect(x: 0, y: 0, width: lit.width, height: lit.height)
        context.draw(lit, in: rect)
        context.setBlendMode(.destinationOut)
        context.draw(glyphs, in: rect)
        return context.makeImage()
    }

    /// Gives every word its own gradient and halo layer.
    ///
    /// One layer per word is what allows each flare to fade on its own
    /// clock. They share a single rendered image and are masked to their
    /// word, so a line of them costs one bitmap rather than one each.
    private func rebuildSweepLayers(width: CGFloat, height: CGFloat, scale: CGFloat) {
        removeGlowLayers()
        highlightMask.sublayers?.forEach { $0.removeFromSuperlayer() }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)

        for index in segmentLayouts.indices {
            let layout = segmentLayouts[index]
            guard layout.segment.moves, !layout.characterRects.isEmpty else { continue }

            let glowMaskContainer = CALayer()
            glowMaskContainer.frame = frame
            glowMaskContainer.contentsScale = scale

            let glow = CALayer()
            glow.frame = frame
            glow.contentsGravity = .topLeft
            glow.contentsScale = scale
            glow.contents = glowImage
            glow.mask = glowMaskContainer
            glow.opacity = 0
            glowContainer.addSublayer(glow)

            let fragments = visualFragments(for: layout.characterRects).map { fragment in
                let highlightGradient = makeSweepMask(
                    frame: fragment.frame,
                    scale: scale
                )
                highlightMask.addSublayer(highlightGradient)

                // The halo needs room on every side of the glyphs. Its sweep
                // is still calculated against the unexpanded content frame,
                // so this bloom does not light the next letters early.
                let glowGradient = makeSweepMask(
                    frame: fragment.frame.insetBy(
                        dx: -Self.glowRadius,
                        dy: -Self.glowRadius
                    ),
                    scale: scale
                )
                glowMaskContainer.addSublayer(glowGradient)
                return SweepFragment(
                    characterOffset: fragment.characterOffset,
                    characterCount: fragment.characterCount,
                    contentFrame: fragment.frame,
                    highlightMask: highlightGradient,
                    glowMask: glowGradient
                )
            }

            segmentLayouts[index].glowLayer = glow
            segmentLayouts[index].sweepFragments = fragments
        }
    }

    private func makeSweepMask(frame: CGRect, scale: CGFloat) -> CAGradientLayer {
        let gradient = CAGradientLayer()
        gradient.frame = frame
        gradient.contentsScale = scale
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        gradient.locations = [0, 1]
        return gradient
    }

    private func visualFragments(
        for characterRects: [CGRect]
    ) -> [VisualFragment] {
        var fragments: [VisualFragment] = []

        for (index, rect) in characterRects.enumerated() where !rect.isEmpty {
            if let last = fragments.indices.last,
               abs(fragments[last].frame.midY - rect.midY) < 1
            {
                fragments[last].characterCount += 1
                fragments[last].frame = fragments[last].frame.union(rect)
            } else {
                fragments.append(
                    VisualFragment(
                        characterOffset: index,
                        characterCount: 1,
                        frame: rect
                    )
                )
            }
        }
        return fragments
    }

    private func removeGlowLayers() {
        glowContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for index in segmentLayouts.indices {
            segmentLayouts[index].glowLayer = nil
            segmentLayouts[index].sweepFragments = []
        }
    }

    private func renderedImage(
        width: CGFloat,
        height: CGFloat,
        scale: CGFloat,
        glow: CGFloat = 0
    ) -> CGImage? {
        let pixelsWide = max(Int(ceil(width * scale)), 1)
        let pixelsHigh = max(Int(ceil(height * scale)), 1)
        guard let context = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(pixelsHigh))
        context.scaleBy(x: scale, y: -scale)
        if glow > 0 {
            context.setShadow(
                offset: .zero,
                blur: glow,
                color: NSColor.labelColor.cgColor
            )
        }
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: NSPoint(x: 0, y: 2))
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

}
