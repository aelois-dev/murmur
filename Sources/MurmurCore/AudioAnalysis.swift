import Foundation

/// Lightweight signal checks used to skip silent recordings and drop classic Whisper hallucinations.
public enum AudioAnalysis {
    /// Whether the audio after `start` contains speech, judged against the whole recording's noise floor.
    /// Guards reuse of an early transcription: any speech after the snapshot means it's stale.
    public static func tailHasSpeech(_ samples: [Float], from start: Int) -> Bool {
        let frame = 320
        guard start < samples.count, samples.count >= frame else { return false }
        var energies: [Float] = []
        var i = 0
        while i + frame <= samples.count { energies.append(rms(samples[i..<(i + frame)])); i += frame }
        let floor = energies.sorted()[energies.count / 10]
        let threshold = max(0.006, floor * 3.5)
        var voiced = 0
        var j = (start / frame) * frame
        while j + frame <= samples.count {
            if rms(samples[j..<(j + frame)]) > threshold { voiced += 1 }
            j += frame
        }
        return voiced >= 3
    }

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

    /// Boosts quiet recordings (whispering, distant mic) so the speech model hears them clearly.
    public static func normalized(_ samples: [Float]) -> [Float] {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0.0005, peak < 0.25 else { return samples }
        let gain = min(12, 0.5 / peak)
        return samples.map { $0 * gain }
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
