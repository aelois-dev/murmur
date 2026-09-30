import AppKit
import AVFoundation
import MurmurCore

/// `--selftest cases.json`: runs recorded audio through the real in-app pipeline (model loading, transcription,
/// AI editing) without touching the clipboard or history, writes a JSON report next to the cases, then quits.
@MainActor
enum SelfTest {
    struct Case: Decodable { var file: String; var text: String; var expected: String? }

    static func run(casesPath: String, model: AppModel, controller: DictationController) {
        Task { @MainActor in
            let launch = Date()
            while !model.whisperStatus.isReady {
                if case .failed = model.whisperStatus { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let whisperReady = Date().timeIntervalSince(launch)
            while model.llmStatus == .loading { try? await Task.sleep(nanoseconds: 250_000_000) }
            let llmReady = Date().timeIntervalSince(launch)
            var report: [[String: Any]] = []
            let url = URL(fileURLWithPath: casesPath)
            let cases = (try? JSONDecoder().decode([Case].self, from: Data(contentsOf: url))) ?? []
            for c in cases {
                let samples = (try? load(url.deletingLastPathComponent().appendingPathComponent(c.file))) ?? []
                let record: DictationRecord = await withCheckedContinuation { continuation in
                    controller.dryRunSink = { continuation.resume(returning: $0) }
                    controller.process(samples, mode: .pushToTalk, target: TargetApp(name: "Notes", bundleID: "com.apple.Notes"))
                }
                controller.dryRunSink = nil
                let expected = c.expected ?? c.text
                report.append(["file": c.file, "heard": record.rawText, "output": record.text, "expected": expected,
                               "exact": record.text == expected, "similarity": WordErrorRate.similarity(expected, record.text),
                               "seconds": record.processingTime, "aiEdited": record.aiEdited])
            }
            let summary: [String: Any] = [
                "whisperStatus": model.whisperStatus.label, "llmStatus": model.llmStatus.label,
                "whisperReadySeconds": whisperReady, "llmReadySeconds": llmReady,
                "exact": report.filter { $0["exact"] as? Bool == true }.count, "cases": report.count,
                "meanSeconds": report.map { $0["seconds"] as? Double ?? 0 }.reduce(0, +) / Double(max(1, report.count)),
                "results": report,
            ]
            let out = url.deletingLastPathComponent().appendingPathComponent("selftest-report.json")
            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out) }
            Log.write("Self-test finished: \(summary["exact"] ?? 0)/\(report.count) exact")
            NSApp.terminate(nil)
        }
    }

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 1024)!
        var done = false
        converter.convert(to: out, error: nil) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true
            status.pointee = .haveData
            return buffer
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
