import Foundation

// MARK: - Provider abstraction

/// What we know about the playing track; duration (seconds) helps pick the right candidate.
nonisolated struct LyricsQuery: Sendable {
    let title: String
    let artist: String
    let duration: TimeInterval
}

nonisolated enum LyricsSourceError: Error {
    /// Every source answered and none has synced lyrics for the song.
    case notFound
    /// At least one source couldn't be reached (timeout, HTTP 5xx…), so the answer isn't final.
    case unavailable
}

/// Which backend(s) to ask. `auto` walks the whole chain; the others use exactly one provider.
nonisolated enum LyricsSourcePreference: String, CaseIterable, Identifiable, Sendable {
    case auto
    case lrclib
    case netease
    case betterLyrics

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .lrclib: return "LRCLIB"
        case .netease: return "NetEase"
        case .betterLyrics: return "BetterLyrics"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Try every source in order"
        case .lrclib: return "Community line-synced lyrics"
        case .netease: return "Large catalog, line-synced"
        case .betterLyrics: return "Apple Music, word-by-word"
        }
    }

    /// Provider name this preference is restricted to; nil means no restriction.
    var providerName: String? {
        self == .auto ? nil : displayName
    }

    private static let defaultsKey = "lyricsSourcePreference"

    static func load() -> LyricsSourcePreference {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .auto
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

nonisolated struct LyricsResult: Sendable {
    let lrc: String
    let provider: String
}

/// A lyrics backend that returns time-synced lyrics as LRC text.
nonisolated protocol LyricsProvider: Sendable {
    var name: String { get }
    func fetchSyncedLRC(for query: LyricsQuery, session: URLSession) async throws -> String
}

// MARK: - Shared helpers

nonisolated enum LyricsMatching {
    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[\(\[].*$"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 4 = same, 2 = one contains the other, 0 = unrelated. Both inputs must be normalized.
    static func similarity(_ lhs: String, _ rhs: String) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 4 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 2 }
        return 0
    }

    static func looksLikeLRC(_ text: String) -> Bool {
        text.range(of: #"\[\d{1,2}:\d{2}"#, options: .regularExpression) != nil
    }

    static func data(from url: URL, session: URLSession, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - LRCLIB

nonisolated struct LRCLibProvider: LyricsProvider {
    let name = "LRCLIB"

    private struct Result: Decodable {
        let syncedLyrics: String?
        let duration: Double?
    }

    func fetchSyncedLRC(for query: LyricsQuery, session: URLSession) async throws -> String {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        var items = [URLQueryItem(name: "track_name", value: query.title)]
        if !query.artist.isEmpty { items.append(.init(name: "artist_name", value: query.artist)) }
        comps.queryItems = items

        let data = try await LyricsMatching.data(from: comps.url!, session: session)
        let results = try JSONDecoder().decode([Result].self, from: data)
            .filter { ($0.syncedLyrics ?? "").isEmpty == false }

        // Prefer the version whose length is closest to the playing track.
        let best = query.duration > 0
            ? results.min { abs(($0.duration ?? .infinity) - query.duration) < abs(($1.duration ?? .infinity) - query.duration) }
            : results.first
        if let lrc = best?.syncedLyrics { return lrc }
        throw LyricsSourceError.notFound
    }
}

// MARK: - NetEase Cloud Music

nonisolated struct NetEaseProvider: LyricsProvider {
    let name = "NetEase"

    private struct SearchResponse: Decodable {
        struct Payload: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            struct Artist: Decodable { let name: String? }
            let id: Int
            let name: String
            let duration: Double?
            let artists: [Artist]?
        }
        let result: Payload?
    }

    private struct LyricResponse: Decodable {
        struct LRC: Decodable { let lyric: String? }
        let lrc: LRC?
    }

    private let headers = ["User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com"]

    func fetchSyncedLRC(for query: LyricsQuery, session: URLSession) async throws -> String {
        var search = URLComponents(string: "https://music.163.com/api/search/get")!
        search.queryItems = [
            .init(name: "s", value: [query.title, query.artist].filter { !$0.isEmpty }.joined(separator: " ")),
            .init(name: "type", value: "1"),
            .init(name: "limit", value: "8")
        ]
        let searchData = try await LyricsMatching.data(from: search.url!, session: session, headers: headers)
        let songs = try JSONDecoder().decode(SearchResponse.self, from: searchData).result?.songs ?? []
        guard let song = bestMatch(in: songs, query: query) else { throw LyricsSourceError.notFound }

        var lyric = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lyric.queryItems = [
            .init(name: "id", value: String(song.id)),
            .init(name: "lv", value: "1")
        ]
        let lyricData = try await LyricsMatching.data(from: lyric.url!, session: session, headers: headers)
        let raw = try JSONDecoder().decode(LyricResponse.self, from: lyricData).lrc?.lyric ?? ""
        // NetEase opens with credit lines ("作词 : …", "制作人 : …") that are not lyrics.
        let lrc = raw
            .components(separatedBy: .newlines)
            .filter { $0.range(of: #"^\[[\d:.]+\]\s*(作词|作曲|编曲|制作人|混音|母带|录音|监制|和声|吉他|贝斯|鼓|弦乐|封面|出品|发行|OP|SP|词|曲)\s*[:：]"#, options: .regularExpression) == nil }
            .joined(separator: "\n")
        guard LyricsMatching.looksLikeLRC(lrc) else { throw LyricsSourceError.notFound }
        return lrc
    }

    /// Wrong lyrics are worse than none, so a candidate needs a title match, an artist match
    /// (when known) and a plausible duration.
    private func bestMatch(in songs: [SearchResponse.Song], query: LyricsQuery) -> SearchResponse.Song? {
        let title = LyricsMatching.normalize(query.title)
        let artist = LyricsMatching.normalize(query.artist)

        var best: (song: SearchResponse.Song, score: Int)?
        for song in songs {
            let titleScore = LyricsMatching.similarity(title, LyricsMatching.normalize(song.name))
            guard titleScore > 0 else { continue }

            var artistScore = 0
            if !artist.isEmpty {
                artistScore = (song.artists ?? [])
                    .map { LyricsMatching.similarity(artist, LyricsMatching.normalize($0.name ?? "")) }
                    .max() ?? 0
                guard artistScore > 0 else { continue }
            }

            var durationScore = 0
            if query.duration > 0, let ms = song.duration {
                let gap = abs(ms / 1000 - query.duration)
                guard gap <= 10 else { continue }
                durationScore = gap <= 3 ? 3 : 1
            }

            let score = titleScore + artistScore + durationScore
            if score > (best?.score ?? 0) { best = (song, score) }
        }
        return best?.song
    }
}

// MARK: - BetterLyrics (Apple Music TTML)

nonisolated struct BetterLyricsProvider: LyricsProvider {
    let name = "BetterLyrics"

    private struct Response: Decodable { let ttml: String? }

    func fetchSyncedLRC(for query: LyricsQuery, session: URLSession) async throws -> String {
        var comps = URLComponents(string: "https://lyrics-api.boidu.dev/getLyrics")!
        var items = [
            URLQueryItem(name: "s", value: query.title),
            URLQueryItem(name: "a", value: query.artist)
        ]
        if query.duration > 0 { items.append(.init(name: "d", value: String(Int(query.duration.rounded())))) }
        comps.queryItems = items

        let data = try await LyricsMatching.data(from: comps.url!, session: session)
        guard let ttml = try JSONDecoder().decode(Response.self, from: data).ttml, !ttml.isEmpty else {
            throw LyricsSourceError.notFound
        }
        let lrc = TTMLToLRC.convert(ttml)
        guard LyricsMatching.looksLikeLRC(lrc) else { throw LyricsSourceError.notFound }
        return lrc
    }
}

/// Converts word-timed TTML into enhanced LRC: `[mm:ss.xx]<mm:ss.xxx>word <mm:ss.xxx>word <mm:ss.xxx>`.
/// The final tag marks when the last word ends. Lines without word timing become plain LRC lines.
nonisolated final class TTMLToLRC: NSObject, XMLParserDelegate {
    private var output: [(time: TimeInterval, text: String)] = []

    private var lineStart: TimeInterval?
    private var lineText = ""
    private var segments: [(time: TimeInterval, text: String)] = []
    private var lastWordEnd: TimeInterval?
    private var pendingSpace = false

    private var spanStack: [Bool] = []   // true when skipped (background vocals, translation, romanization)
    private var skipDepth = 0
    private var inWordSpan = false
    private var spanBegin: TimeInterval?
    private var spanEnd: TimeInterval?
    private var spanText = ""

    static func convert(_ ttml: String) -> String {
        guard let data = ttml.data(using: .utf8) else { return "" }
        let converter = TTMLToLRC()
        let parser = XMLParser(data: data)
        parser.delegate = converter
        guard parser.parse() else { return "" }

        return converter.output
            .sorted { $0.time < $1.time }
            .map { "[\(stamp($0.time, decimals: 2))]\($0.text)" }
            .joined(separator: "\n")
    }

    private static func stamp(_ time: TimeInterval, decimals: Int) -> String {
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        return String(format: "%02d:%0\(decimals + 3).\(decimals)f", minutes, seconds)
    }

    /// Accepts "12.345", "1:02.345" and "01:02:03.5".
    private static func seconds(from value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "p":
            lineStart = Self.seconds(from: attributeDict["begin"])
            lineText = ""
            segments.removeAll()
            lastWordEnd = nil
            pendingSpace = false
            spanStack.removeAll()
            skipDepth = 0
            inWordSpan = false
        case "span":
            let role = attributeDict["ttm:role"] ?? ""
            let skip = skipDepth > 0 || ["x-bg", "x-translation", "x-roman"].contains(role)
            spanStack.append(skip)
            if skip {
                skipDepth += 1
            } else {
                if pendingSpace, !segments.isEmpty { segments[segments.count - 1].text += " " }
                pendingSpace = false
                inWordSpan = true
                spanBegin = Self.seconds(from: attributeDict["begin"])
                spanEnd = Self.seconds(from: attributeDict["end"])
                spanText = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard lineStart != nil, skipDepth == 0 else { return }
        if inWordSpan {
            spanText += string
        } else {
            lineText += string
            if !segments.isEmpty, string.contains(where: \.isWhitespace) { pendingSpace = true }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "span":
            if spanStack.popLast() == true {
                skipDepth -= 1
            } else if inWordSpan {
                inWordSpan = false
                let word = spanText.components(separatedBy: .whitespacesAndNewlines).joined()
                if !word.isEmpty, let begin = spanBegin {
                    segments.append((begin, word))
                    lastWordEnd = spanEnd ?? begin
                }
            }
        case "p":
            finishLine()
        default:
            break
        }
    }

    private func finishLine() {
        defer { lineStart = nil }
        if let first = segments.first {
            let start = lineStart ?? first.time
            var text = segments
                .map { "<\(Self.stamp($0.time, decimals: 3))>\($0.text)" }
                .joined()
            if let end = lastWordEnd { text += "<\(Self.stamp(end, decimals: 3))>" }
            output.append((start, text))
            return
        }

        let plain = lineText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if let start = lineStart, !plain.isEmpty { output.append((start, plain)) }
    }
}

// MARK: - Fallback chain

/// Tries each provider in order and returns the first usable LRC. Providers are queried one at a
/// time, so most songs cost a single request instead of one per provider.
nonisolated final class LyricsSource: Sendable {
    private let providers: [any LyricsProvider]
    private let session: URLSession

    init(providers: [any LyricsProvider] = [LRCLibProvider(), NetEaseProvider(), BetterLyricsProvider()]) {
        self.providers = providers

        // Ephemeral: lyrics are cached by LyricTicker, so URLCache would only duplicate them in memory.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }

    /// A specific preference is asked first; if it has nothing for this song the other sources are
    /// tried in their usual order, so a song isn't left without lyrics just because one source lacks it.
    func fetchSyncedLyrics(for query: LyricsQuery, preference: LyricsSourcePreference = .auto) async throws -> LyricsResult {
        let preferred = providers.filter { $0.name == preference.providerName }
        let candidates = preferred + providers.filter { $0.name != preference.providerName }
        var anyUnavailable = false
        for provider in candidates {
            // Sources like LRCLIB answer 503 now and then; one quick retry usually gets through.
            for attempt in 0..<2 {
                do {
                    let lrc = try await provider.fetchSyncedLRC(for: query, session: session)
                    if LyricsMatching.looksLikeLRC(lrc) { return LyricsResult(lrc: lrc, provider: provider.name) }
                    break
                } catch LyricsSourceError.notFound {
                    break
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    NSLog("Lyrette: \(provider.name) failed (attempt \(attempt + 1)): \(error)")
                    if attempt == 0 {
                        try await Task.sleep(nanoseconds: 600_000_000)
                    } else {
                        anyUnavailable = true
                    }
                }
            }
        }
        throw anyUnavailable ? LyricsSourceError.unavailable : LyricsSourceError.notFound
    }
}
