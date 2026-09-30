import CoreML
import Foundation
import MurmurCore
import WhisperKit

public struct TranscriptionOutput: Sendable {
    public var text: String
    public var language: String?
    public var seconds: Double

    public init(text: String, language: String?, seconds: Double) {
        self.text = text
        self.language = language
        self.seconds = seconds
    }
}

public enum TranscriberError: LocalizedError {
    case notLoaded
    public var errorDescription: String? { "The speech model isn't loaded yet." }
}

/// Local speech-to-text on top of WhisperKit (Core ML on the Neural Engine).
public actor Transcriber {
    private var whisper: WhisperKit?
    public private(set) var loadedModel: String?

    public init() {}

    public var isReady: Bool { whisper != nil }

    // MARK: - Model files

    public static var downloadBase: URL { AppPaths.whisperModelsDirectory }

    public static func localFolder(for model: String) -> URL? {
        let folder = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        let ok = required.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        return ok ? folder : nil
    }

    public static func isDownloaded(_ model: String) -> Bool { localFolder(for: model) != nil }

    public static func download(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let existing = localFolder(for: model) { return existing }
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        return try await WhisperKit.download(variant: model, downloadBase: downloadBase, progressCallback: { p in
            progress(p.fractionCompleted)
        })
    }

    public static func delete(_ model: String) throws {
        if let folder = localFolder(for: model) { try FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Loading

    public func load(model: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if loadedModel == model, whisper != nil { return }
        let folder = try await Self.download(model, progress: progress)
        await whisper?.unloadModels()
        whisper = nil
        let config = WhisperKitConfig(
            model: model,
            downloadBase: Self.downloadBase,
            modelFolder: folder.path,
            tokenizerFolder: Self.downloadBase,
            computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        whisper = try await WhisperKit(config)
        loadedModel = model
        // A tiny warm-up decode so the first real dictation doesn't pay one-time setup costs.
        _ = try? await whisper?.transcribe(audioArray: [Float](repeating: 0, count: 16000), decodeOptions: DecodingOptions(language: "en", withoutTimestamps: true))
    }

    public func unload() async {
        await whisper?.unloadModels()
        whisper = nil
        loadedModel = nil
    }

    // MARK: - Transcription

    public func transcribe(_ samples: [Float], language: String?, prompt: String? = nil) async throws -> TranscriptionOutput {
        guard let whisper else { throw TranscriberError.notLoaded }
        let start = Date()
        guard AudioAnalysis.hasSpeech(samples) else {
            return TranscriptionOutput(text: "", language: language, seconds: Date().timeIntervalSince(start))
        }
        var promptTokens: [Int]?
        if let prompt, !prompt.isEmpty, let tokenizer = whisper.tokenizer {
            let limit = tokenizer.specialTokens.specialTokenBegin
            promptTokens = tokenizer.encode(text: " " + prompt).filter { $0 < limit }.suffix(200).map { $0 }
        }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            suppressBlank: true,
            chunkingStrategy: samples.count > 16000 * 29 ? .vad : ChunkingStrategy.none
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = Self.cleanWhisperOutput(results.map(\.text).joined(separator: " "))
        let detected = results.first?.language
        let filtered = AudioAnalysis.isLikelyHallucination(text, samples: samples) ? "" : text
        return TranscriptionOutput(text: filtered, language: detected, seconds: Date().timeIntervalSince(start))
    }

    static func cleanWhisperOutput(_ text: String) -> String {
        var t = text
        // Non-speech annotations Whisper sometimes emits.
        t = t.replacingOccurrences(of: #"\[(?:BLANK_AUDIO|MUSIC|Music|NOISE|Noise|SILENCE|Silence|inaudible|INAUDIBLE)[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\((?:silence|music|noise|inaudible|laughs|laughter|sighs|coughs|applause)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lightweight signal checks used to skip silent recordings and drop classic Whisper hallucinations.
public enum AudioAnalysis {
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Seconds of audio whose short-term energy is clearly above the noise floor.
    public static func voicedSeconds(_ samples: [Float], sampleRate: Int = 16000) -> Double {
        let frame = sampleRate / 50 // 20 ms
        guard samples.count >= frame else { return 0 }
        var energies: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            energies.append(rms(samples[i..<(i + frame)]))
            i += frame
        }
        let sorted = energies.sorted()
        let noiseFloor = sorted[sorted.count / 10]
        let threshold = max(0.004, noiseFloor * 3)
        let voiced = energies.filter { $0 > threshold }.count
        return Double(voiced) * 0.02
    }

    public static func hasSpeech(_ samples: [Float]) -> Bool {
        guard samples.count > 16000 / 4 else { return false }
        let peak = samples.reduce(0) { max($0, abs($1)) }
        if peak < 0.003 { return false }
        return voicedSeconds(samples) >= 0.15
    }

    static let hallucinations: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!", "thank you for watching", "you", "bye", "bye.",
        "subtitles by the amara.org community", "please subscribe", "so", "okay", "i'm sorry", "thank you very much",
    ]

    public static func isLikelyHallucination(_ text: String, samples: [Float]) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard hallucinations.contains(normalized) || hallucinations.contains(normalized + ".") else { return false }
        // Only discard when there was very little actual voice activity.
        return voicedSeconds(samples) < 0.6
    }
}
