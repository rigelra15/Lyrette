import SwiftUI

// MARK: - Player page

extension LyretteMenuView {
    var playerView: some View {
        VStack(spacing: 12) {
            TurntableDeck(
                artwork: ticker.albumArtImage,
                isPlaying: ticker.isPlaying && ticker.hasNowPlaying,
                tint: accentColor
            )
            .frame(height: 262)

            trackInfo

            SeekBarView(ticker: ticker, tint: accentColor)

            playbackControls

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                PageButton(title: "Lyrics", systemImage: "quote.bubble", tint: accentColor) {
                    show(.lyrics)
                }
                PageButton(title: "Settings", systemImage: "gearshape", tint: accentColor) {
                    show(.settings)
                }
            }
        }
        .padding(16)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ticker.hasNowPlaying ? ticker.nowPlayingTitle : "Nothing playing")
                .font(.system(size: 17, weight: .bold))
                .lineLimit(1)

            Text(ticker.hasNowPlaying ? ticker.nowPlayingArtist : "Play a song in Music or Spotify")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(currentLyricText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .padding(.top, 3)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: currentLyricText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PageButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(tint)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Turntable

/// A record deck: the record spins at 33⅓ rpm while music plays, and the tonearm swings onto it.
struct TurntableDeck: View {
    let artwork: NSImage?
    let isPlaying: Bool
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let recordSize = min(size.height - 24, size.width * 0.66)
            let recordCenter = CGPoint(x: size.width * 0.43, y: size.height / 2)

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.95), tint.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    }

                SpinningRecord(artwork: artwork, isPlaying: isPlaying, tint: tint)
                    .frame(width: recordSize, height: recordSize)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    .position(recordCenter)

                Tonearm(isPlaying: isPlaying, length: recordSize * 0.78)
                    .position(x: size.width - 38, y: 34)
            }
        }
    }
}

private struct SpinningRecord: View {
    let artwork: NSImage?
    let isPlaying: Bool
    let tint: Color

    /// Angle kept across pauses so the record stops where it is and picks up from there.
    @State private var spin = SpinState()

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { context in
            let angle = spin.angle(at: context.date, playing: isPlaying)

            VinylDisc()
                .overlay { label }
                .rotationEffect(.degrees(angle))
                .overlay { Sheen() }
        }
    }

    private var label: some View {
        GeometryReader { proxy in
            let side = proxy.size.width * 0.38
            RecordLabel(artwork: artwork, tint: tint)
                .frame(width: side, height: side)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

/// Accumulates rotation from frame to frame instead of deriving it from the clock, so pausing
/// freezes the record in place rather than snapping it when playback resumes.
private final class SpinState {
    private var angle: Double = 0
    private var lastDate: Date?
    private static let degreesPerSecond = 200.0 // 33⅓ rpm

    func angle(at date: Date, playing: Bool) -> Double {
        defer { lastDate = playing ? date : nil }
        guard playing, let lastDate else { return angle }
        let delta = min(date.timeIntervalSince(lastDate), 0.1)
        angle = (angle + delta * Self.degreesPerSecond).truncatingRemainder(dividingBy: 360)
        return angle
    }
}

private struct VinylDisc: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = size.width / 2

            context.fill(Path(ellipseIn: rect), with: .color(Color(white: 0.07)))

            // Grooves: fine rings with a slightly brighter band every few, like real tracks.
            var r = radius * 0.97
            var index = 0
            while r > radius * 0.42 {
                let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                let alpha = index % 9 == 0 ? 0.12 : 0.05
                context.stroke(ring, with: .color(.white.opacity(alpha)), lineWidth: 0.6)
                r -= 2.2
                index += 1
            }

            // Lead-out ring around the label.
            let lead = radius * 0.41
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - lead, y: center.y - lead, width: lead * 2, height: lead * 2)),
                with: .color(.white.opacity(0.1)),
                lineWidth: 1.2
            )
        }
    }
}

/// Light reflected off the grooves. It stays put while the record turns underneath it.
private struct Sheen: View {
    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [
                        .white.opacity(0), .white.opacity(0.14), .white.opacity(0),
                        .white.opacity(0), .white.opacity(0.09), .white.opacity(0), .white.opacity(0)
                    ],
                    center: .center,
                    angle: .degrees(-35)
                )
            )
            .mask { Ring(innerFraction: 0.4).fill(style: FillStyle(eoFill: true)) }
            .allowsHitTesting(false)
    }
}

/// The grooved band of the record: a disc with the label area cut out.
private struct Ring: Shape {
    let innerFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect)
        path.addEllipse(in: rect.insetBy(dx: rect.width * (1 - innerFraction) / 2, dy: rect.height * (1 - innerFraction) / 2))
        return path
    }
}

private struct RecordLabel: View {
    let artwork: NSImage?
    let tint: Color

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(tint)
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1) }
        .overlay {
            // Spindle hole.
            Circle()
                .fill(Color(white: 0.85))
                .frame(width: 7, height: 7)
                .overlay { Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1) }
        }
    }
}

/// Pivot, arm and headshell, drawn pointing down from the pivot and swung toward the record.
private struct Tonearm: View {
    let isPlaying: Bool
    let length: CGFloat

    private var angle: Double { isPlaying ? 24 : 4 }

    var body: some View {
        ZStack(alignment: .top) {
            // Arm and headshell, hanging from the pivot.
            VStack(spacing: 0) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.92), Color(white: 0.62)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 5, height: length)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(white: 0.95))
                    .frame(width: 14, height: 24)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(.black.opacity(0.2), lineWidth: 1)
                    }
                    .rotationEffect(.degrees(-18), anchor: .top)
            }
            .shadow(color: .black.opacity(0.3), radius: 3, x: -2, y: 3)
            .rotationEffect(.degrees(angle), anchor: .top)

            // Pivot.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.97), Color(white: 0.7)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 28
                    )
                )
                .frame(width: 30, height: 30)
                .overlay { Circle().strokeBorder(.black.opacity(0.15), lineWidth: 1) }
                .overlay { Circle().fill(Color(white: 0.55)).frame(width: 9, height: 9) }
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .offset(y: -15)
        }
        .frame(width: 30, height: length + 24, alignment: .top)
        .offset(y: (length + 24) / 2 - 15)
        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: isPlaying)
    }
}
