import Foundation
import Combine
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - LRC Models & Parser

/// One word or syllable of a line. `text` keeps a trailing space when a space follows it.
struct LyricWord: Identifiable {
    let id = UUID()
    let start: TimeInterval
    var end: TimeInterval
    let text: String
}

struct LRCLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
    /// Empty for line-synced lyrics; filled from enhanced-LRC `<mm:ss.xxx>` tags.
    var words: [LyricWord] = []
    /// When the line stops being sung: last word end, an empty LRC marker, or an estimate from its length.
    var end: TimeInterval = 0
}

/// A long pause (intro, instrumental) shown as three dots. `afterIndex` is -1 for the intro.
struct LyricGap: Identifiable {
    let afterIndex: Int
    let start: TimeInterval
    let end: TimeInterval
    var id: Int { afterIndex }
}

enum LRCParser {
    private static let regex = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]"#, options: [])
    private static let wordTag = try! NSRegularExpression(pattern: #"<(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?>"#, options: [])

    private static func seconds(_ ns: NSString, _ m: NSTextCheckingResult) -> TimeInterval {
        let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
        var frac: Double = 0
        if m.numberOfRanges >= 4, m.range(at: 3).location != NSNotFound {
            let fractionStr = ns.substring(with: m.range(at: 3))
            if let fraction = Double(fractionStr) {
                frac = fractionStr.count == 3 ? fraction / 1000.0 : fraction / 100.0
            }
        }
        return mm * 60 + ss + frac
    }

    /// Splits "<t>word <t>word <t>" into words; the last tag only marks the end of the final word.
    private static func parseWords(_ raw: String) -> (text: String, words: [LyricWord]) {
        let ns = raw as NSString
        let tags = wordTag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !tags.isEmpty else { return (raw.trimmingCharacters(in: .whitespaces), []) }

        var words: [LyricWord] = []
        for (i, tag) in tags.enumerated() {
            let start = seconds(ns, tag)
            let textStart = tag.range.location + tag.range.length
            let textEnd = i + 1 < tags.count ? tags[i + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            let end = i + 1 < tags.count ? seconds(ns, tags[i + 1]) : start
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(LyricWord(start: start, end: end, text: text))
            }
        }
        let plain = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return (plain, words)
    }

    static func parse(_ string: String) -> [LRCLine] {
        let lines = string.components(separatedBy: .newlines)

        var results: [LRCLine] = []
        var breakTimes: [TimeInterval] = []   // "[00:14.81]" with no text: where the previous line ends

        for raw in lines {
            let nsLine = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { continue }

            // Remove timestamps to get the lyric text (and word tags, if any)
            let stripped = regex.stringByReplacingMatches(in: raw, options: [], range: NSRange(location: 0, length: nsLine.length), withTemplate: "")
            let (text, words) = parseWords(stripped)
            guard !text.isEmpty else {
                breakTimes.append(contentsOf: matches.filter { $0.numberOfRanges >= 3 }.map { seconds(nsLine, $0) })
                continue
            }

            for m in matches where m.numberOfRanges >= 3 {
                results.append(LRCLine(time: seconds(nsLine, m), text: text, words: words))
            }
        }

        results.sort { $0.time < $1.time }

        // A word that ends exactly where it starts (no end tag) lasts until the next word or line.
        for i in results.indices where !results[i].words.isEmpty {
            let nextLine = i + 1 < results.count ? results[i + 1].time : results[i].time + 4
            for w in results[i].words.indices {
                let nextStart = w + 1 < results[i].words.count ? results[i].words[w + 1].start : nextLine
                if results[i].words[w].end <= results[i].words[w].start {
                    results[i].words[w].end = max(nextStart, results[i].words[w].start + 0.1)
                }
            }
        }

        breakTimes.sort()
        for i in results.indices {
            let next: TimeInterval? = i + 1 < results.count ? results[i + 1].time : nil
            let start = results[i].time
            var end: TimeInterval
            if let lastWord = results[i].words.last {
                end = lastWord.end
            } else if let marker = breakTimes.first(where: { $0 > start + 0.5 && $0 < (next ?? .infinity) }) {
                end = marker
            } else {
                end = start + max(3, Double(results[i].text.count) * 0.12)
            }
            if let next { end = min(end, next) }
            results[i].end = max(end, start)
        }
        return results
    }

    /// Pauses long enough to be worth showing as dots (Apple Music style).
    static func gaps(in lines: [LRCLine], minDuration: TimeInterval = 5) -> [LyricGap] {
        guard let first = lines.first else { return [] }
        var result: [LyricGap] = []
        if first.time >= minDuration {
            result.append(LyricGap(afterIndex: -1, start: 0, end: first.time))
        }
        for i in 0..<(lines.count - 1) {
            let start = lines[i].end
            let end = lines[i + 1].time
            if end - start >= minDuration {
                result.append(LyricGap(afterIndex: i, start: start, end: end))
            }
        }
        return result
    }
}

// Lyrics providers (LRCLIB, NetEase, BetterLyrics) live in LyricsProviders.swift.

// MARK: - Album Artwork
struct ArtworkSearchResponse: Decodable {
    let results: [ArtworkSearchResult]
}

struct ArtworkSearchResult: Decodable {
    let trackName: String?
    let artistName: String?
    let artworkUrl100: String?
}

struct ArtworkSource {
    private let cacheDir: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("LyretteCache", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        cacheDir = dir
    }

    func fetchArtwork(track: String, artist: String) async -> Data? {
        let key = cacheKey(track: track, artist: artist)
        if let cached = readCache(for: key) {
            return cached
        }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: [artist, track].filter { !$0.isEmpty }.joined(separator: " ")),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "8")
        ]

        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }

            let search = try JSONDecoder().decode(ArtworkSearchResponse.self, from: data)
            guard let match = bestMatch(in: search.results, track: track, artist: artist),
                  let artworkString = match.artworkUrl100,
                  let artworkURL = enlargedArtworkURL(from: artworkString) else {
                return nil
            }

            let (imageData, imageResponse) = try await URLSession.shared.data(from: artworkURL)
            guard let imageHTTP = imageResponse as? HTTPURLResponse,
                  (200..<300).contains(imageHTTP.statusCode),
                  !imageData.isEmpty else {
                return nil
            }

            writeCache(imageData, for: key)
            return imageData
        } catch {
            NSLog("Lyrette: artwork fetch error: \(error)")
            return nil
        }
    }

    private func bestMatch(in results: [ArtworkSearchResult], track: String, artist: String) -> ArtworkSearchResult? {
        guard !results.isEmpty else { return nil }

        let normalizedTrack = normalize(track)
        let normalizedArtist = normalize(artist)

        return results.max { lhs, rhs in
            score(lhs, track: normalizedTrack, artist: normalizedArtist) <
                score(rhs, track: normalizedTrack, artist: normalizedArtist)
        }
    }

    private func score(_ result: ArtworkSearchResult, track: String, artist: String) -> Int {
        let candidateTrack = normalize(result.trackName ?? "")
        let candidateArtist = normalize(result.artistName ?? "")
        var score = 0

        if candidateTrack == track {
            score += 4
        } else if !track.isEmpty && (candidateTrack.contains(track) || track.contains(candidateTrack)) {
            score += 2
        }

        if !artist.isEmpty, candidateArtist == artist {
            score += 4
        } else if !artist.isEmpty && (candidateArtist.contains(artist) || artist.contains(candidateArtist)) {
            score += 2
        }

        if result.artworkUrl100 != nil {
            score += 1
        }
        return score
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\(\[].*$"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func enlargedArtworkURL(from string: String) -> URL? {
        let enlarged = string
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            .replacingOccurrences(of: "100x100-75", with: "600x600-75")
        return URL(string: enlarged)
    }

    private func cacheKey(track: String, artist: String) -> String {
        let raw = (artist + "||" + track).lowercased()
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func readCache(for key: String) -> Data? {
        let url = cacheDir.appendingPathComponent(key + ".image")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    private func writeCache(_ data: Data, for key: String) {
        let url = cacheDir.appendingPathComponent(key + ".image")
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Now Playing via AppleScript
enum PlaybackState: String {
    case idle
    case playing
    case paused
}

struct NowPlayingInfo {
    let title: String
    let artist: String
    var position: TimeInterval
    var duration: TimeInterval
    let state: PlaybackState
    var isPlaying: Bool { state == .playing }
}

nonisolated func parseNowPlayingInfo(
    _ result: String?,
    durationScale: Double
) -> NowPlayingInfo? {
    guard let result, durationScale > 0 else { return nil }
    let parts = result.components(separatedBy: "||")
    guard parts.count == 5 else { return nil }

    let positionText = parts[2].replacingOccurrences(of: ",", with: ".")
    let durationText = parts[3].replacingOccurrences(of: ",", with: ".")
    let stateText = parts[4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let position = Double(positionText),
          let rawDuration = Double(durationText),
          let state = PlaybackState(rawValue: stateText),
          state != .idle else {
        return nil
    }

    return NowPlayingInfo(
        title: parts[0],
        artist: parts[1],
        position: position,
        duration: rawDuration * durationScale,
        state: state
    )
}

nonisolated private func runAppleScript(_ source: String) -> String? {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return nil }
    let out = script.executeAndReturnError(&error)
    if let error {
        if let code = error[NSAppleScript.errorNumber] as? Int, code == -1743 {
            // Not authorized — silent, handled by caller cooldown
        } else {
            NSLog("Lyrette: AppleScript error: \(error)")
        }
        return nil
    }
    return out.stringValue
}

nonisolated func nowPlayingFromAppleMusic() -> NowPlayingInfo? {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil else {
        return nil
    }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil else {
        return nil
    }
    let script = """
    with timeout of 2 seconds
        if application "Music" is running then
            tell application "Music"
                if exists current track then
                    set s to player state as string
                    if s is "playing" or s is "paused" then
                        set t to name of current track
                        set a to artist of current track
                        set p to player position
                        set d to duration of current track
                        return t & "||" & a & "||" & (p as string) & "||" & (d as string) & "||" & s
                    end if
                end if
            end tell
        end if
    end timeout
    """
    return parseNowPlayingInfo(runAppleScript(script), durationScale: 1)
}

nonisolated func nowPlayingFromSpotify() -> NowPlayingInfo? {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else {
        return nil
    }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first != nil else {
        return nil
    }
    let script = """
    with timeout of 2 seconds
        tell application id "com.spotify.client"
            set s to player state as string
            if s is not "stopped" then
                set t to name of current track
                set a to artist of current track
                set p to player position
                set d to duration of current track
                return t & "||" & a & "||" & (p as string) & "||" & (d as string) & "||" & s
            end if
        end tell
    end timeout
    """
    return parseNowPlayingInfo(runAppleScript(script), durationScale: 0.001)
}

// DISABLED: browser YouTube Music support (AppleScript connection unreliable)
nonisolated func nowPlayingFromBrowser() -> NowPlayingInfo? {
    return nil
}

// MARK: - Playback Controls
nonisolated func controlPlayback(app: AutomationTarget, action: String) {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first != nil else { return }
    let script = """
    with timeout of 2 seconds
        tell application "\(app.appName)"
            \(action)
        end tell
    end timeout
    """
    var error: NSDictionary?
    guard let appleScript = NSAppleScript(source: script) else { return }
    appleScript.executeAndReturnError(&error)
    if let error {
        NSLog("Lyrette: playback control error: \(error)")
    }
}

/// Locale-safe: the position is sent as an integer ms count divided inside AppleScript.
nonisolated func seekPlayback(app: AutomationTarget, milliseconds: Int) {
    controlPlayback(app: app, action: "set player position to (\(milliseconds) / 1000)")
}

nonisolated func playPauseMusic() {
    controlPlayback(app: .music, action: "playpause")
}

nonisolated func nextTrackMusic() {
    controlPlayback(app: .music, action: "next track")
}

nonisolated func previousTrackMusic() {
    controlPlayback(app: .music, action: "previous track")
}

nonisolated func playPauseSpotify() {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first != nil else { return }
    let script = """
    with timeout of 2 seconds
        tell application "Spotify"
            if player state is playing then
                pause
            else
                play
            end if
        end tell
    end timeout
    """
    var error: NSDictionary?
    guard let appleScript = NSAppleScript(source: script) else { return }
    appleScript.executeAndReturnError(&error)
    if let error {
        NSLog("Lyrette: playback control error: \(error)")
    }
}

nonisolated func nextTrackSpotify() {
    controlPlayback(app: .spotify, action: "next track")
}

nonisolated func previousTrackSpotify() {
    controlPlayback(app: .spotify, action: "previous track")
}

enum AutomationTarget {
    case music
    case spotify

    nonisolated var bundleIdentifier: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    nonisolated var appName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }
}

@discardableResult
nonisolated func performAutomationAccessRequest(app: AutomationTarget) -> Bool {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) != nil else {
        NSLog("Automation request: \(app.appName) not found on this system")
        return false
    }

    let script = """
    with timeout of 2 seconds
        tell application "\(app.appName)"
            return name
        end tell
    end timeout
    """

    var error: NSDictionary?
    guard let appleScript = NSAppleScript(source: script) else { return false }
    appleScript.executeAndReturnError(&error)
    if let error {
        NSLog("Automation request error: \(error)")
        return false
    }
    return true
}

// MARK: - LyricTicker
final class LyricTicker: ObservableObject {

    // Simple caches
    private var memoryCache: [String: String] = [:] // key: cacheKey(artist,title), value: LRC
    private var missingLyricsKeys: Set<String> = [] // songs no provider had lyrics for (session only)
    private lazy var cacheDir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("LyretteCache", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    // Published UI state
    @Published var current: String = "Lyrette"       // current lyric line
    @Published private(set) var currentLineID: UUID?
    @Published var isFetching: Bool = false          // whether we are fetching lyrics
    @Published var nowPlayingArtist: String = ""     // artist from source
    @Published var nowPlayingTitle: String = ""      // title from source
    @Published var albumArtData: Data? {
        didSet { albumArtImage = albumArtData.flatMap(NSImage.init(data:)) }
    }
    /// Decoded once per artwork change so views never decode image data in `body`.
    private(set) var albumArtImage: NSImage?
    @Published var albumArtIsLoading: Bool = false
    @Published var playingAppName: String = ""
    @Published var musicAccessOK: Bool = false
    @Published var spotifyAccessOK: Bool = false
    @Published private(set) var playbackState: PlaybackState = .idle
    @Published private(set) var playbackDurationMs: Int64 = 0
    @Published private(set) var lyricsStatus = "idle"
    @Published private(set) var artworkStatus = "idle"
    @Published private(set) var lyricsProviderName: String = ""   // who supplied the lyrics on screen
    /// Seconds the lyrics are delayed (+) or advanced (-) for the current song.
    @Published private(set) var lyricsOffset: TimeInterval = 0
    /// Which pause is showing dots right now (-1 = intro); nil while a line is being sung.
    @Published private(set) var activeGapAfterIndex: Int?
    private(set) var lyricGaps: [LyricGap] = []
    private var gapsByIndex: [Int: LyricGap] = [:]

    /// A positive offset moves the lyrics ahead (each line shows sooner); negative holds them back.
    /// Offsets saved by older versions used the opposite sign under "lyricsOffsets" and are migrated.
    private static let offsetsKey = "lyricsOffsetsV2"
    private static let legacyOffsetsKey = "lyricsOffsets"

    /// Position the lyrics should be drawn at: playback position plus the user's timing offset.
    func lyricPosition(at date: Date = Date()) -> TimeInterval {
        currentPosition(at: date) + lyricsOffset
    }

    func adjustLyricsOffset(by delta: TimeInterval) {
        setLyricsOffset(lyricsOffset + delta)
    }

    func resetLyricsOffset() {
        setLyricsOffset(0)
    }

    private func setLyricsOffset(_ value: TimeInterval) {
        let clamped = min(15, max(-15, (value * 20).rounded() / 20))
        guard clamped != lyricsOffset, !currentSongKey.isEmpty else { return }
        lyricsOffset = clamped

        var all = UserDefaults.standard.dictionary(forKey: Self.offsetsKey) as? [String: Double] ?? [:]
        if clamped == 0 { all.removeValue(forKey: currentSongKey) } else { all[currentSongKey] = clamped }
        UserDefaults.standard.set(all, forKey: Self.offsetsKey)

        updateCurrentLine(elapsed: currentPosition())
    }

    private static func storedOffset(for songKey: String) -> TimeInterval {
        migrateLegacyOffsets()
        return (UserDefaults.standard.dictionary(forKey: offsetsKey) as? [String: Double])?[songKey] ?? 0
    }

    private static func migrateLegacyOffsets() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.dictionary(forKey: legacyOffsetsKey) as? [String: Double] else { return }
        var current = defaults.dictionary(forKey: offsetsKey) as? [String: Double] ?? [:]
        for (key, value) in legacy where current[key] == nil { current[key] = -value }
        defaults.set(current, forKey: offsetsKey)
        defaults.removeObject(forKey: legacyOffsetsKey)
    }
    @Published private(set) var lyricsSourcePreference: LyricsSourcePreference = .load()

    var playbackDuration: TimeInterval { Double(playbackDurationMs) / 1_000 }

    /// Position now, extrapolated from the last poll while playing. Cheap enough to call per frame.
    func currentPosition(at date: Date = Date()) -> TimeInterval {
        var position = anchorPosition
        if playbackState == .playing { position += date.timeIntervalSince(anchorDate) }
        return playbackDuration > 0 ? min(max(0, position), playbackDuration) : max(0, position)
    }

    func setLyricsSourcePreference(_ preference: LyricsSourcePreference) {
        guard preference != lyricsSourcePreference else { return }
        lyricsSourcePreference = preference
        preference.save()
        // Forget the current song so the next poll fetches it again from the chosen source.
        fetchTask?.cancel()
        currentSongKey = ""
        pollNowPlaying()
    }

    var hasNowPlaying: Bool {
        !nowPlayingTitle.isEmpty
    }

    // Computed title for MenuBarExtra
    var menuBarTitle: String {
        if isFetching {
            let t = [nowPlayingArtist, nowPlayingTitle].filter { !$0.isEmpty }.joined(separator: " - ")
            return t.isEmpty ? "Fetching…" : t
        }
        return current.isEmpty ? "—" : current
    }

    private var syncLines: [LRCLine] = [] {
        didSet {
            lyricGaps = LRCParser.gaps(in: syncLines)
            gapsByIndex = Dictionary(uniqueKeysWithValues: lyricGaps.map { ($0.afterIndex, $0) })
        }
    }
    private var currentLyricIndex: Int?
    private var syncStartDate: Date?
    private var rawLRC: String = ""

    var lyricLines: [LRCLine] { syncLines }

    private let source = LyricsSource()
    private let artworkSource = ArtworkSource()
    private var monitorTimer: Timer?
    private var scheduledPollInterval: TimeInterval?
    private var currentSongKey: String = ""
    private var fetchTask: Task<Void, Never>?
    @Published var isPlaying: Bool = false
    private var lastActiveSource: AutomationTarget?
    private var idleTimer: Timer?

    // MARK: Access check
    func checkSpotifyAutomationAccess() {
        requestAutomationAccess(app: .spotify)
    }

    // MARK: Now Playing Monitoring
    // AppleScript is the expensive part, so it is polled slowly and the position is interpolated
    // locally in between (lineTimer) to keep lyric timing aligned.
    // One in-flight read is allowed so slow AppleScript calls cannot starve every result.
    private let activePollInterval: TimeInterval = 1.0
    private let idlePollInterval: TimeInterval = 5.0
    private let lineTickInterval: TimeInterval = 0.25
    private var pollGate = NowPlayingPollGate()
    private var lineTimer: Timer?
    private var anchorPosition: TimeInterval = 0
    private var anchorDate = Date()

    private func startLineTimer() {
        guard lineTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: lineTickInterval, repeats: true) { [weak self] _ in
            self?.tickPlayback()
        }
        timer.tolerance = lineTickInterval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        lineTimer = timer
    }

    private func stopLineTimer() {
        lineTimer?.invalidate()
        lineTimer = nil
    }

    /// Advances position and lyric line from the last poll without touching AppleScript.
    private func tickPlayback() {
        guard playbackState == .playing else { return }
        var position = anchorPosition + Date().timeIntervalSince(anchorDate)
        if playbackDurationMs > 0 { position = min(position, Double(playbackDurationMs) / 1_000) }
        if !syncLines.isEmpty { updateCurrentLine(elapsed: position) }
    }

    private func setPollingTimer(_ interval: TimeInterval) {
        guard scheduledPollInterval != interval else { return }
        scheduledPollInterval = interval
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollNowPlaying()
        }
        if let monitorTimer { RunLoop.main.add(monitorTimer, forMode: .common) }
    }

    func startMonitoringNowPlaying() {
        stopMonitoring()
        setPollingTimer(idlePollInterval)
        pollNowPlaying()
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        stopLineTimer()
        scheduledPollInterval = nil
        pollGate.invalidate()
    }

    private func pollNowPlaying() {
        guard let pollToken = pollGate.begin() else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let spotifyInfo = nowPlayingFromSpotify()
            let amInfo = nowPlayingFromAppleMusic()

            DispatchQueue.main.async {
                guard self.pollGate.finish(pollToken) else { return }
                if amInfo != nil { self.musicAccessOK = true }
                if spotifyInfo != nil { self.spotifyAccessOK = true }

                let previouslySelected: PreferredNowPlayingSource?
                switch self.lastActiveSource {
                case .music: previouslySelected = .appleMusic
                case .spotify: previouslySelected = .spotify
                case nil: previouslySelected = nil
                }
                let source = preferredNowPlayingSource(
                    spotifyState: spotifyInfo?.state,
                    appleMusicState: amInfo?.state,
                    previouslySelected: previouslySelected,
                    hasPreviousSnapshot: self.hasNowPlaying
                )
                let info = source == .spotify ? spotifyInfo : amInfo

                guard let source, let info else {
                    if shouldRetainNowPlayingSnapshot(
                        hasTrack: self.hasNowPlaying,
                        state: self.playbackState
                    ) {
                        self.stopLineTimer()
                        self.isPlaying = false
                        self.playbackState = .paused
                        self.scheduleIdleResetIfNeeded()
                        return
                    }

                    self.stopLineTimer()
                    self.isPlaying = false
                    self.playbackState = .idle
                    self.playbackDurationMs = 0
                    self.scheduleIdleResetIfNeeded()
                    return
                }

                self.setPollingTimer(self.activePollInterval)
                self.idleTimer?.invalidate()
                self.idleTimer = nil
                let activeSource: AutomationTarget = source == .spotify ? .spotify : .music
                self.lastActiveSource = activeSource
                self.playingAppName = activeSource.displayName
                self.playbackState = info.state
                self.isPlaying = info.isPlaying
                let duration = max(0, info.duration)
                let position = duration > 0
                    ? min(max(0, info.position), duration)
                    : max(0, info.position)
                self.playbackDurationMs = Int64((duration * 1_000).rounded())
                self.anchorPosition = position
                self.anchorDate = Date()
                if info.isPlaying { self.startLineTimer() } else { self.stopLineTimer() }

                let songKey = "\(info.title)||\(info.artist)"
                if songKey != self.currentSongKey {
                    self.currentSongKey = songKey
                    self.lyricsOffset = Self.storedOffset(for: songKey)
                    self.fetchTask?.cancel()
                    self.beginFetching(artist: info.artist, title: info.title)
                    let ticker = self
                    self.fetchTask = Task { [weak ticker] in
                        await ticker?.prepareAndFetch(for: info, songKey: songKey)
                    }
                }
                if !self.syncLines.isEmpty { self.updateCurrentLine(elapsed: position) }
            }
        }
    }

    private func scheduleIdleResetIfNeeded() {
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.current = "Lyrette"
                self.currentLineID = nil
                self.currentLyricIndex = nil
                self.nowPlayingArtist = ""
                self.nowPlayingTitle = ""
                self.playingAppName = ""
                self.lastActiveSource = nil
                self.playbackState = .idle
                self.isPlaying = false
                self.playbackDurationMs = 0
                self.albumArtData = nil
                self.albumArtIsLoading = false
                self.artworkStatus = "idle"
                self.lyricsStatus = "idle"
                self.currentSongKey = ""
                self.lyricsOffset = 0
                self.activeGapAfterIndex = nil
                self.fetchTask?.cancel()
                self.fetchTask = nil
                self.syncLines.removeAll()
                self.idleTimer = nil
                self.rawLRC = ""
                self.setPollingTimer(self.idlePollInterval)
            }
        }
        if let idleTimer { RunLoop.main.add(idleTimer, forMode: .common) }
    }

    private func prepareAndFetch(for info: NowPlayingInfo, songKey: String) async {
        async let artworkTask = artworkSource.fetchArtwork(track: info.title, artist: info.artist)

        do {
            let key = cacheKey(artist: info.artist, title: info.title)
            let lrc: String
            let provider: String
            if let cached = readCache(for: key) {
                (provider, lrc) = Self.splitSourceTag(cached)
            } else if missingLyricsKeys.contains(key) {
                // Already tried every provider this session; don't hit the network again.
                throw LyricsSourceError.notFound
            } else {
                let query = LyricsQuery(title: info.title, artist: info.artist, duration: info.duration)
                do {
                    let result = try await source.fetchSyncedLyrics(for: query, preference: lyricsSourcePreference)
                    lrc = result.lrc
                    provider = result.provider
                } catch LyricsSourceError.notFound {
                    missingLyricsKeys.insert(key)
                    throw LyricsSourceError.notFound
                }
                writeCache("[x-source:\(provider)]\n" + lrc, for: key)
            }

            let lines = LRCParser.parse(lrc)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.currentSongKey == songKey else { return }
                self.rawLRC = lrc
                self.lyricsProviderName = lines.isEmpty ? "" : provider
                self.syncLines = lines
                self.currentLyricIndex = nil
                self.lyricsStatus = lines.isEmpty ? "notFound" : "ready"
                self.isFetching = false
                self.syncStartDate = Date().addingTimeInterval(-info.position)
                if lines.isEmpty {
                    self.current = "Lyrics not found"
                } else {
                    self.updateCurrentLine(elapsed: info.position)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            NSLog("Lyrette: fetch error: \(error)")
            let unavailable = (error as? LyricsSourceError) == .unavailable
            await MainActor.run {
                guard self.currentSongKey == songKey else { return }
                if unavailable { self.scheduleLyricsRetry(for: songKey) }
                self.rawLRC = ""
                self.lyricsProviderName = ""
                self.syncLines = []
                self.currentLyricIndex = nil
                self.lyricsStatus = "notFound"
                self.isFetching = false
                self.current = [info.artist, info.title].filter { !$0.isEmpty }.joined(separator: " - ")
                self.currentLineID = nil
                self.syncStartDate = nil
            }
        }

        let artwork = await artworkTask
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard self.currentSongKey == songKey else { return }
            self.albumArtData = artwork
            self.artworkStatus = artwork == nil ? "notFound" : "ready"
            self.albumArtIsLoading = false
        }
    }

    // MARK: Fetching state helpers
    func beginFetching(artist: String, title: String) {
        syncLines.removeAll()
        currentLineID = nil
        currentLyricIndex = nil
        syncStartDate = nil
        nowPlayingArtist = artist
        nowPlayingTitle = title
        lyricsProviderName = ""
        activeGapAfterIndex = nil
        albumArtData = nil
        albumArtIsLoading = true
        lyricsStatus = "loading"
        artworkStatus = "loading"
        isFetching = true
        current = ""
    }

    func requestAutomationAccess(app: AutomationTarget) {
        Task.detached { [weak self] in
            let ok = performAutomationAccessRequest(app: app)
            await self?.applyAutomationAccessResult(ok, for: app)
        }
    }

    private func applyAutomationAccessResult(_ allowed: Bool, for app: AutomationTarget) {
        switch app {
        case .music: musicAccessOK = allowed
        case .spotify: spotifyAccessOK = allowed
        }
    }

    // MARK: Sync update
    /// `rawElapsed` is the playback position; the user's offset is added here.
    private func updateCurrentLine(elapsed rawElapsed: TimeInterval) {
        guard !syncLines.isEmpty else { return }
        let elapsed = rawElapsed + lyricsOffset

        if let intro = gapsByIndex[-1], elapsed < intro.end {
            enterGap(intro, elapsed: elapsed)
            return
        }
        // Playback moves forward, so resume from the current line unless the user seeked back.
        var idx = 0
        if let hint = currentLyricIndex, hint < syncLines.count, elapsed >= syncLines[hint].time {
            idx = hint
        }
        while idx + 1 < syncLines.count && elapsed >= syncLines[idx + 1].time {
            idx += 1
        }
        if let gap = gapsByIndex[idx], elapsed >= gap.start {
            enterGap(gap, elapsed: elapsed)
            return
        }

        let newLine = syncLines[idx]
        currentLyricIndex = idx
        if activeGapAfterIndex != nil { activeGapAfterIndex = nil }
        if current != newLine.text { current = newLine.text }
        if currentLineID != newLine.id { currentLineID = newLine.id }
    }

    /// During a long pause the menu bar shows "○ ○ ○" filling up, like Apple Music's dots.
    private func enterGap(_ gap: LyricGap, elapsed: TimeInterval) {
        let span = max(gap.end - gap.start, 0.1)
        let progress = min(1, max(0, (elapsed - gap.start) / span))
        let filled = min(3, Int(progress * 4))
        let dots = (0..<3).map { $0 < filled ? "●" : "○" }.joined(separator: " ")

        currentLyricIndex = gap.afterIndex >= 0 ? gap.afterIndex : nil
        if current != dots { current = dots }
        if currentLineID != nil { currentLineID = nil }
        if activeGapAfterIndex != gap.afterIndex { activeGapAfterIndex = gap.afterIndex }
    }

    // MARK: - Playback Controls
    func togglePlayPause() {
        guard let source = lastActiveSource, playbackState != .idle else { return }

        // Flip the UI right away instead of waiting for the next poll (up to 5 s while paused).
        // A poll already in flight would report the old state, so its result is dropped.
        pollGate.invalidate()
        anchorPosition = currentPosition()
        anchorDate = Date()
        let willPlay = playbackState != .playing
        playbackState = willPlay ? .playing : .paused
        isPlaying = willPlay
        if willPlay { startLineTimer() } else { stopLineTimer() }
        setPollingTimer(activePollInterval)

        sendCommand {
            switch source {
            case .music: playPauseMusic()
            case .spotify: playPauseSpotify()
            }
        }
    }

    func nextTrack() {
        guard let source = lastActiveSource else { return }
        sendCommand {
            switch source {
            case .music: nextTrackMusic()
            case .spotify: nextTrackSpotify()
            }
        }
    }

    func previousTrack() {
        guard let source = lastActiveSource else { return }
        sendCommand {
            switch source {
            case .music: previousTrackMusic()
            case .spotify: previousTrackSpotify()
            }
        }
    }

    /// Runs a player command off the main thread, then polls at once so the result shows
    /// without waiting for the regular timer.
    private func sendCommand(_ command: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            command()
            DispatchQueue.main.async { self?.pollNowPlaying() }
        }
    }

    // MARK: - Lyrics retry

    private var lyricsRetryCounts: [String: Int] = [:]

    /// A source was unreachable rather than empty, so try again shortly (a few times per song).
    private func scheduleLyricsRetry(for songKey: String) {
        let attempts = lyricsRetryCounts[songKey, default: 0]
        guard attempts < 3 else { return }
        lyricsRetryCounts[songKey] = attempts + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(10 * (attempts + 1))) { [weak self] in
            guard let self, self.currentSongKey == songKey, self.syncLines.isEmpty, !self.isFetching else { return }
            self.retryLyrics()
        }
    }

    /// Forgets that the current song had no lyrics and fetches it again from the network.
    func retryLyrics() {
        guard hasNowPlaying else { return }
        missingLyricsKeys.remove(cacheKey(artist: nowPlayingArtist, title: nowPlayingTitle))
        fetchTask?.cancel()
        currentSongKey = ""
        pollNowPlaying()
    }

    // MARK: - Seek
    func seek(to seconds: TimeInterval) {
        guard let source = lastActiveSource, playbackState != .idle else { return }
        let target = playbackDuration > 0 ? min(max(0, seconds), playbackDuration) : max(0, seconds)

        // Move the local clock first so the UI follows the drag immediately.
        anchorPosition = target
        anchorDate = Date()
        currentLyricIndex = nil
        if !syncLines.isEmpty { updateCurrentLine(elapsed: target) }

        let milliseconds = Int(target * 1_000)
        DispatchQueue.global(qos: .userInitiated).async {
            seekPlayback(app: source, milliseconds: milliseconds)
        }
    }

    // MARK: - Export LRC
    func exportLRC() {
        guard !rawLRC.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(nowPlayingArtist) - \(nowPlayingTitle).lrc"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? self.rawLRC.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Copy Lyrics
    func copyLyricsToClipboard() {
        let lines = syncLines
        guard !lines.isEmpty else { return }
        let text = lines.map { $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Cache helpers
    func clearCache() {
        memoryCache.removeAll()
        missingLyricsKeys.removeAll()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
    }

    private func cacheKey(artist: String, title: String) -> String {
        // Auto keeps the original key; a pinned source gets its own entry so switching never serves stale results.
        let suffix = lyricsSourcePreference == .auto ? "" : "||" + lyricsSourcePreference.rawValue
        let raw = (artist + "||" + title + suffix).lowercased()
        if let data = raw.data(using: .utf8) {
            let digest = SHA256.hash(data: data)
            return digest.compactMap { String(format: "%02x", $0) }.joined()
        }
        return raw.replacingOccurrences(of: "/", with: "_")
    }

    /// Cached files start with "[x-source:Name]"; older files have no tag.
    private static func splitSourceTag(_ cached: String) -> (provider: String, lrc: String) {
        let prefix = "[x-source:"
        guard cached.hasPrefix(prefix), let close = cached.firstIndex(of: "]") else { return ("Cached", cached) }
        let name = String(cached[cached.index(cached.startIndex, offsetBy: prefix.count)..<close])
        let rest = cached[cached.index(after: close)...].drop(while: \.isNewline)
        return (name.isEmpty ? "Cached" : name, String(rest))
    }

    private func readCache(for key: String) -> String? {
        if let m = memoryCache[key] { return m }
        let url = cacheDir.appendingPathComponent(key + ".lrc")
        if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) {
            memoryCache[key] = s
            return s
        }
        return nil
    }

    private func writeCache(_ value: String, for key: String) {
        memoryCache[key] = value
        let url = cacheDir.appendingPathComponent(key + ".lrc")
        try? value.data(using: .utf8)?.write(to: url)
    }
}
