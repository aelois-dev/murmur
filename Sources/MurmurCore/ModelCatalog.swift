import Foundation

/// A local language model for AI editing and Command Mode (GGUF, run by llama.cpp).
public struct LLMModelInfo: Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    public var fileName: String
    public var url: URL
    public var sizeBytes: Int64
    /// Qwen3 hybrid models need the "thinking" block suppressed.
    public var needsNoThink: Bool
    /// Smallest Mac memory (GB) this model runs comfortably on, next to the speech model.
    public var minRAMGB: Int

    public var localURL: URL { AppPaths.llmModelsDirectory.appendingPathComponent(fileName) }
    public var isDownloaded: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path), let size = attrs[.size] as? Int64 else { return false }
        return size > sizeBytes / 2
    }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

/// A Whisper speech model (Core ML, run by WhisperKit).
public struct WhisperModelInfo: Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    public var sizeLabel: String
    public var englishOnly: Bool
    public var minRAMGB: Int = 8
}

public enum ModelCatalog {
    public static let whisperModels: [WhisperModelInfo] = [
        WhisperModelInfo(id: "openai_whisper-large-v3-v20240930_turbo_632MB", title: "Large v3 Turbo", detail: "Fast and accurate · 100+ languages", sizeLabel: "632 MB", englishOnly: false),
        WhisperModelInfo(id: "openai_whisper-large-v3-v20240930_turbo", title: "Large v3 Turbo (full precision)", detail: "A little more accurate · same speed", sizeLabel: "1.6 GB", englishOnly: false, minRAMGB: 16),
        WhisperModelInfo(id: "openai_whisper-large-v3", title: "Large v3", detail: "Most accurate · slower", sizeLabel: "3.1 GB", englishOnly: false, minRAMGB: 24),
        WhisperModelInfo(id: "openai_whisper-small.en_217MB", title: "Small (English)", detail: "Faster · English only", sizeLabel: "217 MB", englishOnly: true),
        WhisperModelInfo(id: "openai_whisper-small_216MB", title: "Small", detail: "Faster · 100+ languages", sizeLabel: "216 MB", englishOnly: false),
        WhisperModelInfo(id: "openai_whisper-base.en", title: "Base (English)", detail: "Fastest · English only", sizeLabel: "140 MB", englishOnly: true),
    ]

    public static let llmModels: [LLMModelInfo] = [
        LLMModelInfo(id: "Qwen3-1.7B-Q4_K_M", title: "Qwen3 1.7B", detail: "Fastest, lighter edits",
                     fileName: "Qwen3-1.7B-Q4_K_M.gguf",
                     url: URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!,
                     sizeBytes: 1_107_409_472, needsNoThink: true, minRAMGB: 8),
        LLMModelInfo(id: "Qwen3-4B-Instruct-2507-Q4_K_M", title: "Qwen3 4B", detail: "Fast, great edits",
                     fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                     url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
                     sizeBytes: 2_497_281_120, needsNoThink: false, minRAMGB: 8),
        LLMModelInfo(id: "Qwen3-30B-A3B-Instruct-2507-Q4_K_M", title: "Qwen3 30B-A3B", detail: "Best quality, still fast (32 GB+ Macs)",
                     fileName: "Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf",
                     url: URL(string: "https://huggingface.co/unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF/resolve/main/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf")!,
                     sizeBytes: 18_556_686_752, needsNoThink: false, minRAMGB: 32),
    ]

    public static func whisper(_ id: String) -> WhisperModelInfo? { whisperModels.first { $0.id == id } }
    public static func llm(_ id: String) -> LLMModelInfo? { llmModels.first { $0.id == id } }

    /// This Mac's memory in GB (rounded to the marketed size: 16, 24, 32, …).
    public static var installedRAMGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// Models that fit a Mac with `ramGB` of memory; the current selection is always kept so it stays visible.
    public static func llmModels(fittingRAMGB ramGB: Int, keeping selected: String? = nil) -> [LLMModelInfo] {
        llmModels.filter { $0.minRAMGB <= ramGB || $0.id == selected }
    }

    public static func whisperModels(fittingRAMGB ramGB: Int, keeping selected: String? = nil) -> [WhisperModelInfo] {
        whisperModels.filter { $0.minRAMGB <= ramGB || $0.id == selected }
    }

    /// Best AI editor for a Mac's memory: the 30B mixture-of-experts model is both smarter and fast on 32 GB+.
    public static func recommendedLLM(forRAMGB ramGB: Int) -> String {
        ramGB >= 32 ? "Qwen3-30B-A3B-Instruct-2507-Q4_K_M" : ModelDefaults.llmModel
    }

    /// Best speech model for a Mac's memory (full precision when there's room; same speed, slightly more accurate).
    public static func recommendedWhisper(forRAMGB ramGB: Int) -> String {
        ramGB >= 32 ? "openai_whisper-large-v3-v20240930_turbo" : ModelDefaults.whisperModel
    }
}
