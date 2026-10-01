import Foundation

/// Keys that can drive push-to-talk. `fn` matches Flow's default; the others are for keyboards without a Globe key.
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case fn, rightOption, rightCommand, controlOption, rightControl
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fn: "fn (Globe)"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .controlOption: "⌃ Control + ⌥ Option"
        case .rightControl: "Right ⌃ Control"
        }
    }

    /// Short glyph label used inline ("hold fn to dictate").
    public var shortLabel: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "right ⌥"
        case .rightCommand: "right ⌘"
        case .controlOption: "⌃⌥"
        case .rightControl: "right ⌃"
        }
    }

    /// Modifier used together with the push-to-talk key to trigger Command Mode.
    public var commandModifierLabel: String {
        switch self {
        case .fn: "fn + ⌃"
        case .rightOption: "right ⌥ + ⌃"
        case .rightCommand: "right ⌘ + ⌃"
        case .controlOption: "⌃⌥ + ⌘"
        case .rightControl: "right ⌃ + ⌥"
        }
    }
}

/// How long the microphone stays open after a dictation so the next one starts instantly.
public enum MicReadiness: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, off, oneMinute, fiveMinutes, always
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .off: "Off"
        case .oneMinute: "1 minute after dictating"
        case .fiveMinutes: "5 minutes after dictating"
        case .always: "Always"
        }
    }

    /// Seconds to keep the mic open after a dictation; `isBluetooth` matters for `.automatic`.
    public func seconds(isBluetooth: Bool) -> TimeInterval {
        switch self {
        case .automatic: isBluetooth ? 60 : 0
        case .off: 0
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .always: .infinity
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    // Shortcuts
    public var pushToTalkKey: HotkeyChoice = .fn
    public var handsFreeWithSpace = true
    public var commandModeEnabled = true
    public var doubleTapForHandsFree = true

    // Audio
    public var microphoneUID: String? = nil
    public var soundEffects = true
    public var soundVolume: Double = 0.35
    public var pauseMediaWhileDictating = false
    public var micReadiness: MicReadiness = .automatic

    // Transcription
    public var whisperModel: String = ModelDefaults.whisperModel
    /// nil = auto-detect.
    public var language: String? = nil
    public var smartFormatting = true
    public var aiEditing = true
    public var llmModel: String = ModelDefaults.llmModel
    public var contextAwareness = true
    public var autoLearnWords = true

    // Styles
    public var styles: [String: WritingStyle] = Dictionary(uniqueKeysWithValues: AppCategory.allCases.map { ($0.rawValue, .formal) })
    public var stylesEnabled = true

    // App
    public var showFlowBarAlways = true
    public var launchAtLogin = false
    public var showInDock = true
    public var historyRetention: HistoryRetention = .forever
    public var keepTranscriptInClipboard = false
    public var hasCompletedOnboarding = false
    public var displayName: String? = nil
    /// Set once Accessibility has worked; if it later stops (app updated), we explain how to re-enable it.
    public var accessibilityGrantedOnce = false

    public init() {}

    public func style(for category: AppCategory) -> WritingStyle {
        styles[category.rawValue] ?? .formal
    }

    public mutating func setStyle(_ style: WritingStyle, for category: AppCategory) {
        styles[category.rawValue] = style
    }

    // Tolerant decoding so new settings never wipe a user's existing file.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? current }
        pushToTalkKey = v(.pushToTalkKey, pushToTalkKey)
        handsFreeWithSpace = v(.handsFreeWithSpace, handsFreeWithSpace)
        commandModeEnabled = v(.commandModeEnabled, commandModeEnabled)
        doubleTapForHandsFree = v(.doubleTapForHandsFree, doubleTapForHandsFree)
        microphoneUID = (try? c.decodeIfPresent(String.self, forKey: .microphoneUID)) ?? nil
        soundEffects = v(.soundEffects, soundEffects)
        soundVolume = v(.soundVolume, soundVolume)
        pauseMediaWhileDictating = v(.pauseMediaWhileDictating, pauseMediaWhileDictating)
        micReadiness = v(.micReadiness, micReadiness)
        whisperModel = v(.whisperModel, whisperModel)
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? nil
        smartFormatting = v(.smartFormatting, smartFormatting)
        aiEditing = v(.aiEditing, aiEditing)
        llmModel = v(.llmModel, llmModel)
        contextAwareness = v(.contextAwareness, contextAwareness)
        autoLearnWords = v(.autoLearnWords, autoLearnWords)
        styles = v(.styles, styles)
        stylesEnabled = v(.stylesEnabled, stylesEnabled)
        showFlowBarAlways = v(.showFlowBarAlways, showFlowBarAlways)
        launchAtLogin = v(.launchAtLogin, launchAtLogin)
        showInDock = v(.showInDock, showInDock)
        historyRetention = v(.historyRetention, historyRetention)
        keepTranscriptInClipboard = v(.keepTranscriptInClipboard, keepTranscriptInClipboard)
        hasCompletedOnboarding = v(.hasCompletedOnboarding, hasCompletedOnboarding)
        accessibilityGrantedOnce = v(.accessibilityGrantedOnce, accessibilityGrantedOnce)
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
    }
}

public enum ModelDefaults {
    public static let whisperModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    public static let llmModel = "Qwen3-4B-Instruct-2507-Q4_K_M"
}

/// Languages offered in Settings (Whisper supports ~100; these are the common ones plus auto-detect).
public enum SupportedLanguages {
    public static let all: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
        ("nl", "Dutch"), ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"), ("fi", "Finnish"), ("pl", "Polish"),
        ("cs", "Czech"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"), ("el", "Greek"), ("he", "Hebrew"),
        ("ar", "Arabic"), ("hi", "Hindi"), ("bn", "Bengali"), ("ta", "Tamil"), ("zh", "Chinese"), ("ja", "Japanese"),
        ("ko", "Korean"), ("vi", "Vietnamese"), ("th", "Thai"), ("id", "Indonesian"), ("ms", "Malay"), ("tl", "Tagalog"),
    ]

    public static func name(for code: String?) -> String {
        guard let code else { return "Auto-detect" }
        return all.first(where: { $0.code == code })?.name ?? code
    }
}

/// Small JSON-file persistence helper for Application Support.
public struct JSONStore<Value: Codable> {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

public enum AppPaths {
    public static var supportDirectory: URL {
        // Tests and UI snapshots point this elsewhere so they never touch real user data.
        if let override = ProcessInfo.processInfo.environment["MURMUR_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur", isDirectory: true)
    }
    /// Models always live in the real Application Support folder (they're large and shared with test runs).
    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models", isDirectory: true)
    }
    public static var whisperModelsDirectory: URL { modelsDirectory.appendingPathComponent("whisper", isDirectory: true) }
    public static var llmModelsDirectory: URL { modelsDirectory.appendingPathComponent("llm", isDirectory: true) }
    public static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var historyFile: URL { supportDirectory.appendingPathComponent("history.json") }
    public static var dictionaryFile: URL { supportDirectory.appendingPathComponent("dictionary.json") }
    public static var snippetsFile: URL { supportDirectory.appendingPathComponent("snippets.json") }
    public static var logFile: URL { supportDirectory.appendingPathComponent("murmur.log") }
}
