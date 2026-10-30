import SwiftUI
import AppKit
import ServiceManagement

let lyretteBlue = Color(red: 0, green: 129.0 / 255.0, blue: 251.0 / 255.0)

func dominantColor(from data: Data?) -> Color {
    let accent = ArtworkAccent.dominantRGB(from: data)
    return Color(red: accent.red, green: accent.green, blue: accent.blue)
}

/// The popover never resizes: the status item anchors to it, so any size change would make it jump.
enum LyrettePopoverMetrics {
    static let size = CGSize(width: 360, height: 520)
}

struct LyretteMenuBarLabel: View {
    @ObservedObject var ticker: LyricTicker

    var body: some View {
        Text(ticker.menuBarTitle)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: 150, alignment: .leading)
            .clipped()
    }
}

struct LyretteMenuView: View {
    @ObservedObject var ticker: LyricTicker
    @State var accentColor = lyretteBlue
    @State private var page: PopoverPage = .player

    /// The popover opens on the turntable; lyrics and settings slide in from the right.
    enum PopoverPage {
        case player, lyrics, settings
    }

    func show(_ newPage: PopoverPage) {
        withAnimation(.easeInOut(duration: 0.25)) { page = newPage }
    }

    var body: some View {
        Group {
            switch page {
            case .player:
                playerView
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .lyrics:
                FullLyricsView(ticker: ticker) { show(.player) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .settings:
                settingsView
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: LyrettePopoverMetrics.size.width, height: LyrettePopoverMetrics.size.height)
        .clipped()
        .background(.regularMaterial)
        .onAppear {
            accentColor = dominantColor(from: ticker.albumArtData)
        }
        .onChange(of: ticker.albumArtData) { _, newData in
            accentColor = dominantColor(from: newData)
        }
    }

    private var settingsView: some View {
        VStack(spacing: 10) {
            settingsHeader
            nowPlayingHeader
            lyricCard
            SeekBarView(ticker: ticker, tint: accentColor)
            playbackControls
            connectionsRow
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
    }

    // MARK: Header

    private var settingsHeader: some View {
        HStack {
            Button { show(.player) } label: {
                Label("Player", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(accentColor)
            .help("Back to the player")

            Spacer()

            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(height: 18)
    }

    private var nowPlayingHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            AlbumArtworkView(
                image: ticker.albumArtImage,
                size: 72,
                isLoading: ticker.albumArtIsLoading
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(ticker.hasNowPlaying ? ticker.nowPlayingTitle : "Nothing playing")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ticker.hasNowPlaying ? ticker.nowPlayingArtist : "Play a song in Music or Spotify")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if ticker.hasNowPlaying, !ticker.playingAppName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: ticker.playingAppName == "Spotify" ? "waveform" : "music.note")
                        Text(ticker.playingAppName)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentColor)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: 72)
    }

    // MARK: Lyric card

    private var lyricCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("LYRICS", systemImage: "quote.opening")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                if ticker.isFetching {
                    ProgressView()
                        .controlSize(.mini)
                }

                Spacer(minLength: 0)

                LyricsDisplayMenu(ticker: ticker, onDarkBackground: false)
                LyricsSourceMenu(ticker: ticker)
            }

            // Fixed two-line slot so a long lyric never changes the layout.
            Text(currentLyricText)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .topLeading)

            LyricsOffsetControl(ticker: ticker)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accentColor.opacity(0.4), lineWidth: 1)
        }
    }

    var currentLyricText: String {
        if ticker.isFetching {
            return "Finding synchronized lyrics…"
        }
        if !ticker.current.isEmpty, ticker.current != "Lyrette" {
            return ticker.displayedCurrentLine
        }
        return ticker.hasNowPlaying ? "Lyrics will appear here" : "Play a song to see synced lyrics"
    }

    // MARK: Controls

    var playbackControls: some View {
        HStack(spacing: 28) {
            playbackButton("backward.fill", help: "Previous track") {
                ticker.previousTrack()
            }

            Button {
                ticker.togglePlayPause()
            } label: {
                Image(systemName: ticker.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(.white)
                    .background(Circle().fill(accentColor))
            }
            .buttonStyle(.plain)
            .help(ticker.isPlaying ? "Pause" : "Play")

            playbackButton("forward.fill", help: "Next track") {
                ticker.nextTrack()
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(!ticker.hasNowPlaying)
        .opacity(ticker.hasNowPlaying ? 1 : 0.45)
    }

    private func playbackButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Connections

    private var connectionsRow: some View {
        VStack(spacing: 0) {
            PlayerAccessRow(
                name: "Music",
                bundleID: "com.apple.Music",
                isAllowed: ticker.musicAccessOK
            ) {
                ticker.requestAutomationAccess(app: .music)
            }
            Divider().padding(.leading, 40)
            PlayerAccessRow(
                name: "Spotify",
                bundleID: "com.spotify.client",
                isAllowed: ticker.spotifyAccessOK
            ) {
                ticker.requestAutomationAccess(app: .spotify)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()

            HStack(spacing: 4) {
                LaunchAtLoginRow()

                Spacer(minLength: 0)

                FooterIconButton(systemName: "arrow.clockwise", help: "Clear lyrics cache") {
                    ticker.clearCache()
                }
                FooterIconButton(systemName: "arrow.down.circle", help: "Check for updates") {
                    DispatchQueue.main.async {
                        UpdateChecker.shared.checkNow()
                    }
                }
                FooterIconButton(systemName: "info.circle", help: "About Lyrette") {
                    DispatchQueue.main.async {
                        LyretteWindows.shared.showAbout()
                    }
                }
                FooterIconButton(systemName: "power", help: "Quit Lyrette") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

// MARK: - Components

struct AlbumArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    var isLoading = false
    var showsShadow = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [lyretteBlue.opacity(0.9), lyretteBlue.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }

            if isLoading {
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .fill(.black.opacity(0.18))
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(showsShadow ? 0.2 : 0), radius: 6, y: 3)
        .accessibilityLabel("Album artwork")
    }
}

/// One player in the access list: its real app icon, name, and whether Lyrette may read it.
private struct PlayerAccessRow: View {
    let name: String
    let bundleID: String
    let isAllowed: Bool
    let requestAccess: () -> Void

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, height: 22)

            Text(name)
                .font(.system(size: 12, weight: .medium))

            Spacer(minLength: 8)

            status
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        if appURL == nil {
            Text("Not installed")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else if isAllowed {
            Label("Connected", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            Button("Allow Access", action: requestAccess)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Let Lyrette read what \(name) is playing")
        }
    }
}

private struct FooterIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct LaunchAtLoginRow: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle(isOn: $isEnabled) {
            Text("Launch at Login")
                .font(.system(size: 11, weight: .medium))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .onChange(of: isEnabled) { _, enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                isEnabled = !enabled
                NSLog("Lyrette: launch at login failed: \(error)")
            }
        }
    }
}

#Preview {
    let ticker = LyricTicker()
    LyretteMenuView(ticker: ticker)
}
