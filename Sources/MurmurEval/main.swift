import AVFoundation
import Foundation
import MurmurCore
import MurmurEngine

// Evaluation harness for the overnight build loop.
//
//   murmur-eval stt  <whisper-model> <cases.json>              speech-to-text accuracy + latency
//   murmur-eval text <llm-model|none> <text-cases.json>          cleanup quality + latency
//   murmur-eval e2e  <whisper-model> <llm-model|none> <cases.json> audio -> final text

struct AudioCase: Codable {
    var file: String
    var text: String
    var expected: String?
}

struct TextCase: Codable {
    var input: String
    var expected: String
    var app: String?
}

func loadSamples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let frames = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return [] }
    try file.read(into: buffer)
    if file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1 && file.processingFormat.commonFormat == .pcmFormatFloat32 {
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let outFrames = AVAudioFrameCount(Double(frames) * 16000 / file.processingFormat.sampleRate) + 1024
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames)!
    var consumed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if consumed { status.pointee = .endOfStream; return nil }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

func decode<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

func loadPolisher(_ id: String) throws -> Polisher? {
    guard id != "none" else { return nil }
    guard let info = ModelCatalog.llm(id) else { fatalError("unknown llm model \(id)") }
    let start = Date()
    let polisher = try Polisher(info: info)
    polisher.warmUp()
    print("llm \(id) loaded+warmed in \(fmt(Date().timeIntervalSince(start)))s")
    return polisher
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: murmur-eval stt|text|e2e ...")
    exit(2)
}

var settings = AppSettings()
settings.stylesEnabled = false

switch args[1] {
case "stt", "e2e":
    let model = args[2]
    let casesPath = args[1] == "stt" ? args[3] : args[4]
    let llmID = args[1] == "e2e" ? args[3] : "none"
    let cases = try decode([AudioCase].self, casesPath)
    let dir = URL(fileURLWithPath: casesPath).deletingLastPathComponent()
    let transcriber = Transcriber()
    let loadStart = Date()
    try await transcriber.load(model: model) { p in
        if Int(p * 100) % 10 == 0 { print("  download \(Int(p * 100))%") }
    }
    print("whisper \(model) ready in \(fmt(Date().timeIntervalSince(loadStart)))s")
    let polisher = try loadPolisher(llmID)
    settings.aiEditing = polisher != nil
    var totalWER = 0.0, totalSTT = 0.0, totalAudio = 0.0, totalText = 0.0, finalScores = 0.0
    for c in cases {
        let samples = try loadSamples(dir.appendingPathComponent(c.file).path)
        let audioSeconds = Double(samples.count) / 16000
        let out = try await transcriber.transcribe(samples, language: "en")
        let wer = WordErrorRate.compute(reference: c.text, hypothesis: out.text)
        totalWER += wer; totalSTT += out.seconds; totalAudio += audioSeconds
        print("\n[\(c.file)] audio \(fmt(audioSeconds))s  stt \(fmt(out.seconds))s  WER \(fmt(wer))")
        print("  heard: \(out.text)")
        if args[1] == "e2e" {
            let t0 = Date()
            let result = TextPipeline.process(raw: out.text, settings: settings, dictionary: [], snippets: [], category: .other, appName: nil, polisher: polisher)
            let dt = Date().timeIntervalSince(t0)
            totalText += dt
            let expected = c.expected ?? c.text
            let score = WordErrorRate.similarity(expected, result.text)
            finalScores += score
            print("  final: \(result.text.replacingOccurrences(of: "\n", with: "⏎"))  [text \(fmt(dt))s ai=\(result.aiEdited)\(result.rejectedAIReason.map { " rejected: \($0)" } ?? "")] sim \(fmt(score))")
        }
    }
    let n = Double(cases.count)
    print("\nSUMMARY model=\(model) cases=\(cases.count) meanWER=\(fmt(totalWER / n)) sttSeconds/case=\(fmt(totalSTT / n)) RTF=\(fmt(totalSTT / totalAudio))" +
          (args[1] == "e2e" ? " textSeconds/case=\(fmt(totalText / n)) meanSim=\(fmt(finalScores / n))" : ""))

case "text":
    let cases = try decode([TextCase].self, args[3])
    let polisher = try loadPolisher(args[2])
    settings.aiEditing = polisher != nil
    var exact = 0, simTotal = 0.0, timeTotal = 0.0
    for c in cases {
        let t0 = Date()
        let result = TextPipeline.process(raw: c.input, settings: settings, dictionary: [DictionaryEntry(word: "Murmur"), DictionaryEntry(word: "WhisperKit")], snippets: [], category: .other, appName: c.app, polisher: polisher)
        let dt = Date().timeIntervalSince(t0)
        timeTotal += dt
        let sim = WordErrorRate.similarity(c.expected, result.text)
        simTotal += sim
        let isExact = result.text == c.expected
        if isExact { exact += 1 }
        print("\n\(isExact ? "✅" : (sim >= 0.9 ? "🟡" : "❌")) \(fmt(dt))s sim \(fmt(sim)) ai=\(result.aiEdited)\(result.rejectedAIReason.map { " (rejected: \($0))" } ?? "")")
        print("  in:  \(c.input)")
        print("  out: \(result.text.replacingOccurrences(of: "\n", with: "⏎"))")
        if !isExact { print("  exp: \(c.expected.replacingOccurrences(of: "\n", with: "⏎"))") }
    }
    let n = Double(cases.count)
    print("\nSUMMARY llm=\(args[2]) cases=\(cases.count) exact=\(exact) meanSim=\(fmt(simTotal / n)) seconds/case=\(fmt(timeTotal / n))")

default:
    print("unknown command")
    exit(2)
}
