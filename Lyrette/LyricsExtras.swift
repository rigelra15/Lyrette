import SwiftUI
import NaturalLanguage
import Translation

// MARK: - Romanization

/// Turns Japanese, Chinese and Korean lyrics into Latin letters on the device; no network needed.
nonisolated enum LyricRomanizer {
    /// nil when the line has nothing to romanize (already Latin, punctuation, empty).
    static func romanize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, containsCJK(trimmed) else { return nil }

        let result: String
        if containsKana(trimmed) {
            result = japaneseRomaji(trimmed)
        } else if containsHangul(trimmed) {
            result = koreanRomaja(trimmed)
        } else {
            result = transliterate(trimmed)
        }
        let cleaned = fullWidthPunctuationToASCII(result)
            .replacingOccurrences(of: #"\s+([,.!?)])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == trimmed ? nil : cleaned
    }

    /// Chinese → pinyin with tone marks, Korean → Revised Romanization–style Latin.
    private static func transliterate(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        return mutable as String
    }

    /// Kanji need their Japanese reading, which only the tokenizer knows; a plain transform would
    /// read them as Mandarin.
    private static func japaneseRomaji(_ text: String) -> String {
        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        guard let tokenizer = CFStringTokenizerCreate(
            nil, cfText, range, kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale
        ) else { return transliterate(text) }

        var pieces: [String] = []
        var lastEnd = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            // Keep punctuation and spaces that sit between tokens.
            if tokenRange.location > lastEnd {
                let gap = (text as NSString).substring(with: NSRange(location: lastEnd, length: tokenRange.location - lastEnd))
                let kept = gap.trimmingCharacters(in: .whitespaces)
                if !kept.isEmpty { pieces.append(transliterate(kept)) }
            }
            let token = (text as NSString).substring(with: NSRange(location: tokenRange.location, length: tokenRange.length))
            if !containsCJK(token) {
                pieces.append(token)            // already Latin (English words in J-pop lines)
            } else if let particle = particles[token] {
                pieces.append(particle)         // は/へ/を as particles read wa/e/o
            } else if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                pieces.append(latin)
            } else {
                pieces.append(transliterate(token))
            }
            lastEnd = tokenRange.location + tokenRange.length
        }
        if lastEnd < (text as NSString).length {
            pieces.append(transliterate((text as NSString).substring(from: lastEnd)))
        }
        return pieces.joined(separator: " ")
    }

    private static let particles = ["は": "wa", "へ": "e", "を": "o"]

    private static func fullWidthPunctuationToASCII(_ text: String) -> String {
        let map: [Character: String] = ["，": ", ", "。": ". ", "！": "! ", "？": "? ", "、": ", ", "：": ": ", "；": "; ",
                                        "（": " (", "）": ") ", "「": "\"", "」": "\"", "『": "\"", "』": "\"", "　": " ", "…": "..."]
        return String(text.flatMap { map[$0].map(Array.init) ?? [$0] })
    }

    // Revised Romanization of Korean, syllable by syllable, with the common linking rule:
    // a final consonant before a vowel-initial syllable is carried over (사랑이 → sarangi).
    private static let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
    private static let medials = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"]
    /// Final consonant as pronounced at the end of a syllable.
    private static let finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"]
    /// Final consonant as it sounds when it links into a following vowel.
    private static let linkedFinals = ["", "g", "kk", "ks", "n", "nj", "nh", "d", "r", "lg", "lm", "lb", "ls", "lt", "lp", "lh", "m", "b", "bs", "s", "ss", "ng", "j", "ch", "k", "t", "p", "h"]

    private static func koreanRomaja(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = ""
        for (index, scalar) in scalars.enumerated() {
            guard (0xAC00...0xD7A3).contains(scalar.value) else {
                output.unicodeScalars.append(scalar)
                continue
            }
            let code = Int(scalar.value) - 0xAC00
            let initial = code / (21 * 28)
            let medial = (code % (21 * 28)) / 28
            let final = code % 28

            // Initial ㅇ is silent; a linked final from the previous syllable already supplied it.
            output += initials[initial] + medials[medial]

            let next = index + 1 < scalars.count ? scalars[index + 1].value : 0
            let nextStartsWithVowel = (0xAC00...0xD7A3).contains(next) && (Int(next) - 0xAC00) / (21 * 28) == 11
            if final != 0 {
                output += nextStartsWithVowel && final != 21 ? linkedFinals[final] : finals[final]
            }
        }
        return output
    }

    private static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF,   // Hiragana, Katakana
                 0x3400...0x4DBF,   // CJK Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xAC00...0xD7AF,   // Hangul syllables
                 0x1100...0x11FF,   // Hangul Jamo
                 0x3130...0x318F:   // Hangul compatibility Jamo
                return true
            default:
                return false
            }
        }
    }

    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }
}

// MARK: - Display settings

/// What the menu bar shows for the current line.
enum MenuBarLyricStyle: String, CaseIterable, Identifiable {
    case original, romanized, translated
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .romanized: return "Romanization"
        case .translated: return "Translation"
        }
    }
}

/// Languages offered as translation targets.
enum TranslationTargets {
    static let identifiers = [
        "en", "id", "ja", "ko", "zh-Hans", "zh-Hant", "es", "fr", "de", "pt", "it", "ru", "th", "vi", "ar", "hi", "tr", "nl", "pl", "uk"
    ]

    static var systemDefault: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return identifiers.contains(code) ? code : "en"
    }

    static func name(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// Where translation of the current song stands.
enum LyricsTranslationState: Equatable {
    case off
    case working
    case ready
    /// The on-device model for this pair isn't downloaded yet; the user can download it.
    case needsDownload(source: String, target: String)
    /// Lyrics are already in the target language.
    case sameLanguage
    case unsupported
    case failed
}

// MARK: - Translation

/// Translates lyric lines with Apple's on-device Translation models.
enum LyricsTranslator {
    static func detectLanguage(of lines: [String]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.joined(separator: "\n"))
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }

    enum Outcome {
        case translated([String])
        case needsDownload(source: Locale.Language)
        case sameLanguage
        case unsupported
    }

    @MainActor
    static func translate(_ lines: [String], to targetID: String) async throws -> Outcome {
        guard let source = detectLanguage(of: lines) else { return .unsupported }
        let target = Locale.Language(identifier: targetID)
        if source.languageCode == target.languageCode, source.script == target.script || targetID.count == 2 {
            return .sameLanguage
        }

        switch await LanguageAvailability().status(from: source, to: target) {
        case .unsupported:
            return .unsupported
        case .supported:
            return .needsDownload(source: source)
        case .installed:
            break
        @unknown default:
            return .unsupported
        }

        let session = TranslationSession(installedSource: source, target: target)
        let requests = lines.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let responses = try await session.translations(from: requests)
        var translated = Array(repeating: "", count: lines.count)
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id), index < translated.count {
                translated[index] = response.targetText
            }
        }
        return .translated(translated)
    }
}

// MARK: - Menu

/// Romanization, translation and menu bar text options, shown next to the lyrics source menu.
struct LyricsDisplayMenu: View {
    @ObservedObject var ticker: LyricTicker
    var onDarkBackground = true

    /// Set to ask macOS to download a translation model; `.translationTask` shows the download prompt.
    @State private var downloadConfiguration: TranslationSession.Configuration?

    var body: some View {
        Menu {
            Toggle("Show Romanization", isOn: $ticker.showRomanization)
            Toggle("Show Translation", isOn: $ticker.showTranslation)

            Divider()

            Picker("Menu Bar Shows", selection: $ticker.menuBarLyricStyle) {
                ForEach(MenuBarLyricStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            Picker("Translate To", selection: $ticker.translationTarget) {
                ForEach(TranslationTargets.identifiers, id: \.self) { id in
                    Text(TranslationTargets.name(for: id)).tag(id)
                }
            }

            if case let .needsDownload(source, target) = ticker.translationState {
                Divider()
                Button("Download \(TranslationTargets.name(for: source)) → \(TranslationTargets.name(for: target)) for Translation…") {
                    downloadConfiguration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: source),
                        target: Locale.Language(identifier: target)
                    )
                }
            }
            if let note = statusNote {
                Text(note)
            }
        } label: {
            Image(systemName: "character.bubble")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(onDarkBackground ? AnyShapeStyle(.white.opacity(0.12)) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Romanization & translation")
        .translationTask(downloadConfiguration) { session in
            try? await session.prepareTranslation()
            await MainActor.run {
                downloadConfiguration = nil
                ticker.refreshTranslation()
            }
        }
    }

    private var statusNote: String? {
        switch ticker.translationState {
        case .working: return "Translating…"
        case .sameLanguage: return "Lyrics are already in \(TranslationTargets.name(for: ticker.translationTarget))"
        case .unsupported: return "Translation isn't available for this language"
        case .failed: return "Translation failed"
        default: return nil
        }
    }
}
