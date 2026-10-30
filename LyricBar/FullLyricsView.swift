import SwiftUI
import AppKit

// MARK: - Full lyrics screen (Apple Music style)

struct FullLyricsView: View {
    @ObservedObject var ticker: LyricTicker
    /// Set when shown inside the popover: adds a back button and uses a smaller layout.
    var onBack: (() -> Void)?
    @State private var accent = lyricBarBlue

    private var isEmbedded: Bool { onBack != nil }
    private var lineFont: Font { .system(size: isEmbedded ? 21 : 27, weight: .bold) }

    var body: some View {
        VStack(spacing: 0) {
            header
            lyricsScroll
            footer
        }
        // A background never affects layout; the scaledToFill artwork would otherwise make
        // this view wider than the popover and crop its content.
        .background {
            LyricsBackdrop(image: ticker.albumArtImage, accent: accent)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: isEmbedded ? nil : 380, minHeight: isEmbedded ? nil : 520)
        .onAppear { accent = dominantColor(from: ticker.albumArtData) }
        .onChange(of: ticker.albumArtData) { _, data in
            withAnimation(.easeInOut(duration: 0.6)) { accent = dominantColor(from: data) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back")
            }

            AlbumArtworkView(image: ticker.albumArtImage, size: 46, isLoading: ticker.albumArtIsLoading)

            VStack(alignment: .leading, spacing: 2) {
                Text(ticker.hasNowPlaying ? ticker.nowPlayingTitle : "Nothing playing")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(ticker.nowPlayingArtist)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            LyricsSourceMenu(ticker: ticker)
        }
        .padding(.horizontal, isEmbedded ? 14 : 20)
        .padding(.top, isEmbedded ? 14 : 34)   // the window variant clears the transparent title bar
        .padding(.bottom, 10)
    }

    // MARK: Lyrics

    private var lyricsScroll: some View {
        let lines = ticker.lyricLines
        let currentIndex = lines.firstIndex { $0.id == ticker.currentLineID }
        let gaps = Dictionary(uniqueKeysWithValues: ticker.lyricGaps.map { ($0.afterIndex, $0) })
        let activeGap = ticker.activeGapAfterIndex

        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if lines.isEmpty {
                        placeholder
                    } else {
                        Color.clear.frame(height: 40)
                        if let intro = gaps[-1], activeGap == -1 {
                            GapDotsRow(gap: intro, ticker: ticker).id(Self.gapID(-1))
                        }
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            LyricLineRow(
                                line: line,
                                distance: currentIndex.map { index - $0 },
                                font: lineFont,
                                ticker: ticker
                            ) {
                                // Seek so the lyric position (playback minus offset) lands on this line.
                                ticker.seek(to: line.time + ticker.lyricsOffset)
                            }
                            .id(line.id)

                            if let gap = gaps[index], activeGap == index {
                                GapDotsRow(gap: gap, ticker: ticker).id(Self.gapID(index))
                            }
                        }
                        Color.clear.frame(height: 260)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: activeGap)
                .padding(.horizontal, isEmbedded ? 20 : 28)
            }
            .mask(edgeFade)
            .onAppear { scroll(proxy, to: ticker.currentLineID, animated: false) }
            .onChange(of: ticker.currentLineID) { _, id in scroll(proxy, to: id, animated: true) }
            .onChange(of: ticker.activeGapAfterIndex) { _, index in
                if let index { scroll(proxy, to: Self.gapID(index), animated: true) }
            }
            .onChange(of: lines.count) { _, _ in scroll(proxy, to: ticker.currentLineID, animated: false) }
        }
    }

    private static func gapID(_ afterIndex: Int) -> String { "gap-\(afterIndex)" }

    private func scroll<ID: Hashable>(_ proxy: ScrollViewProxy, to id: ID?, animated: Bool) {
        guard let id else { return }
        let anchor = UnitPoint(x: 0.5, y: 0.3)
        if animated {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.88)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.07),
                .init(color: .black, location: 0.9),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            if ticker.isFetching {
                ProgressView().controlSize(.regular)
            }
            Text(placeholderText)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }

    private var placeholderText: String {
        if ticker.isFetching { return "Finding lyrics…" }
        return ticker.hasNowPlaying ? "No synced lyrics for this song" : "Play a song to see its lyrics"
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                LyricsOffsetControl(ticker: ticker, showsLabel: false)
            }

            SeekBarView(ticker: ticker, tint: .white)

            HStack(spacing: 30) {
                TransportButton(systemName: "backward.fill", size: 18) { ticker.previousTrack() }
                TransportButton(systemName: ticker.isPlaying ? "pause.fill" : "play.fill", size: 26) {
                    ticker.togglePlayPause()
                }
                TransportButton(systemName: "forward.fill", size: 18) { ticker.nextTrack() }
            }
            .disabled(!ticker.hasNowPlaying)
        }
        .padding(.horizontal, isEmbedded ? 20 : 28)
        .padding(.top, 8)
        .padding(.bottom, isEmbedded ? 14 : 18)
    }
}

// MARK: - Lines

private struct LyricLineRow: View {
    let line: LRCLine
    /// Lines away from the current one (negative = already sung); nil when nothing is current yet.
    let distance: Int?
    let font: Font
    let ticker: LyricTicker
    let onTap: () -> Void

    @State private var isHovering = false

    private var isCurrent: Bool { distance == 0 }

    private var opacity: Double {
        guard let distance else { return 0.6 }
        if distance == 0 || isHovering { return 1 }
        return max(0.22, 0.55 - 0.07 * Double(abs(distance)))
    }

    private var blurRadius: Double {
        guard let distance, distance != 0, !isHovering else { return 0 }
        return min(Double(abs(distance)), 5) * 0.8
    }

    var body: some View {
        Group {
            if isCurrent, !line.words.isEmpty {
                WordSyncedLine(words: line.words, font: font, ticker: ticker)
            } else {
                Text(line.text)
                    .font(font)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(isCurrent ? 1 : 0.88, anchor: .leading)
        .opacity(opacity)
        .blur(radius: blurRadius)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: isCurrent)
        .animation(.easeOut(duration: 0.35), value: distance)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onTap)
        .accessibilityLabel(line.text)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Word-by-word line

/// The active line, filling each word as it is sung. Only this view redraws every frame.
private struct WordSyncedLine: View {
    let words: [LyricWord]
    let font: Font
    let ticker: LyricTicker

    /// Syllables without a space between them stay together so wrapping never splits a word.
    private var groups: [[LyricWord]] {
        var result: [[LyricWord]] = []
        var current: [LyricWord] = []
        for word in words {
            current.append(word)
            if word.text.hasSuffix(" ") {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !ticker.isPlaying)) { context in
            let position = ticker.lyricPosition(at: context.date)
            WordFlowLayout(spaceWidth: 8, lineSpacing: 4) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    HStack(spacing: 0) {
                        ForEach(group) { word in
                            KaraokeWord(
                                text: word.text.trimmingCharacters(in: .whitespaces),
                                font: font,
                                progress: progress(of: word, at: position)
                            )
                        }
                    }
                }
            }
        }
    }

    private func progress(of word: LyricWord, at position: TimeInterval) -> Double {
        let length = max(word.end - word.start, 0.05)
        return min(1, max(0, (position - word.start) / length))
    }
}

private struct KaraokeWord: View {
    let text: String
    let font: Font
    let progress: Double

    /// Soft leading edge so the fill sweeps across the word instead of cutting it.
    private var sweep: LinearGradient {
        let edge = 0.2
        let head = progress * (1 + edge)
        return LinearGradient(
            stops: [
                .init(color: .white, location: max(0, head - edge)),
                .init(color: .clear, location: min(1, head))
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.white.opacity(0.35))
            .overlay {
                Text(text)
                    .font(font)
                    .foregroundStyle(.white)
                    .mask(sweep)
                    .shadow(color: .white.opacity(progress > 0 && progress < 1 ? 0.45 : 0), radius: 8)
            }
            .offset(y: -3 * progress)   // sung words lift slightly
    }
}

/// Wraps pre-grouped words, adding `spaceWidth` after each group.
private struct WordFlowLayout: Layout {
    var spaceWidth: CGFloat
    var lineSpacing: CGFloat

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spaceWidth
            usedWidth = max(usedWidth, x - spaceWidth)
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: usedWidth, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? result.size.width, height: result.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

// MARK: - Pause dots

/// Three dots that fill one by one across an intro or instrumental break, like Apple Music.
private struct GapDotsRow: View {
    let gap: LyricGap
    let ticker: LyricTicker

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !ticker.isPlaying)) { context in
            let position = ticker.lyricPosition(at: context.date)
            let span = max(gap.end - gap.start, 0.1)
            let progress = min(1, max(0, (position - gap.start) / span))
            // Shrink away over the last stretch so the next line takes over smoothly.
            let exit = progress > 0.94 ? max(0, 1 - (progress - 0.94) / 0.06) : 1

            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    let fill = min(1, max(0, progress * 3 - Double(index)))
                    Circle()
                        .fill(.white.opacity(0.3 + 0.7 * fill))
                        .frame(width: 12, height: 12)
                        .scaleEffect(0.82 + 0.18 * fill)
                }
            }
            .scaleEffect((1 + 0.07 * sin(position * 2.4)) * (0.4 + 0.6 * exit), anchor: .leading)
            .opacity(exit)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .accessibilityLabel("Instrumental break")
    }
}

// MARK: - Backdrop

private struct LyricsBackdrop: View {
    let image: NSImage?
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.95), accent.opacity(0.55), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.5)
                    .blur(radius: 70)
                    .saturation(1.4)
                    .opacity(0.7)
                    .transition(.opacity)
            }

            Color.black.opacity(0.32)
        }
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: image)
    }
}

// MARK: - Shared controls

/// Picks which backend supplies lyrics, and shows which one is supplying them now.
struct LyricsSourceMenu: View {
    @ObservedObject var ticker: LyricTicker

    private var label: String {
        let preference = ticker.lyricsSourcePreference
        if preference == .auto, !ticker.lyricsProviderName.isEmpty {
            return "Auto · \(ticker.lyricsProviderName)"
        }
        return preference.displayName
    }

    var body: some View {
        Menu {
            ForEach(LyricsSourcePreference.allCases) { preference in
                Button {
                    ticker.setLyricsSourcePreference(preference)
                } label: {
                    if preference == ticker.lyricsSourcePreference {
                        Label("\(preference.displayName) — \(preference.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(preference.displayName) — \(preference.detail)")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.badge.star")
                Text(label)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.12), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Lyrics source")
    }
}

struct TransportButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Scrubber with elapsed and total time. Drags move locally and seek once on release.
struct SeekBarView: View {
    @ObservedObject var ticker: LyricTicker
    var tint: Color
    @State private var dragFraction: Double?
    @State private var isHovering = false

    var body: some View {
        let duration = ticker.playbackDuration

        TimelineView(.animation(minimumInterval: 0.25, paused: !ticker.isPlaying || dragFraction != nil)) { context in
            let position = dragFraction.map { $0 * duration } ?? ticker.currentPosition(at: context.date)
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0

            VStack(spacing: 5) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.22))
                        Capsule().fill(tint).frame(width: geometry.size.width * fraction)
                    }
                    .frame(height: dragFraction != nil || isHovering ? 8 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(1, max(0, value.location.x / max(geometry.size.width, 1)))
                            }
                            .onEnded { value in
                                let target = min(1, max(0, value.location.x / max(geometry.size.width, 1)))
                                ticker.seek(to: target * duration)
                                dragFraction = nil
                            }
                    )
                    .onHover { isHovering = $0 }
                    .animation(.easeOut(duration: 0.15), value: dragFraction != nil || isHovering)
                }
                .frame(height: 14)

                HStack {
                    Text(formatTime(position))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(tint.opacity(0.7))
            }
        }
        .disabled(duration <= 0)
        .opacity(duration > 0 ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formatTime(ticker.currentPosition())) of \(formatTime(duration))")
    }
}

/// Nudges the lyrics later (+) or earlier (-) for the current song. Saved per song.
struct LyricsOffsetControl: View {
    @ObservedObject var ticker: LyricTicker
    var showsLabel = true
    private let step: TimeInterval = 0.25

    private var offsetText: String {
        ticker.lyricsOffset == 0 ? "0.00s" : String(format: "%+.2fs", ticker.lyricsOffset)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 10, weight: .semibold))
            if showsLabel {
                Text("Timing")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
            }

            if showsLabel { Spacer(minLength: 0) }

            stepButton("minus", help: "Show lyrics earlier") { ticker.adjustLyricsOffset(by: -step) }

            Text(offsetText)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(minWidth: 46)

            stepButton("plus", help: "Show lyrics later") { ticker.adjustLyricsOffset(by: step) }

            stepButton("arrow.counterclockwise", help: "Reset timing") { ticker.resetLyricsOffset() }
                .disabled(ticker.lyricsOffset == 0)
                .opacity(ticker.lyricsOffset == 0 ? 0.35 : 1)
        }
        .foregroundStyle(.secondary)
        .disabled(!ticker.hasNowPlaying)
        .help("Lyrics too early? Press +. Too late? Press −.")
    }

    private func stepButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

func formatTime(_ time: TimeInterval) -> String {
    let total = max(0, Int(time.rounded(.down)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}
