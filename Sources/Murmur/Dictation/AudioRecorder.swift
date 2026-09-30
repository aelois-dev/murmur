import AudioToolbox
import AVFoundation
import MurmurEngine

enum AudioRecorderError: LocalizedError {
    case noInput
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone is available."
        case .formatUnavailable: "The microphone format isn't supported."
        }
    }
}

/// Captures microphone audio and converts it to 16 kHz mono Float32 for the speech model.
final class AudioRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// Called on the audio thread with the RMS level of each buffer.
    var onLevel: ((Float) -> Void)?

    /// End-to-end tests inject audio here instead of using the microphone.
    static var injectedSamples: [Float]?

    func start(deviceUID: String?) throws {
        if isRecording { return }
        if Self.injectedSamples != nil {
            isRecording = true
            startedAt = Date()
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = deviceUID, let deviceID = AudioInputDevice.deviceID(forUID: uid), let unit = input.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.write("Couldn't select microphone \(uid): \(status)") }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInput }
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else { throw AudioRecorderError.formatUnavailable }
        self.converter = converter

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16000 * 60)
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRecording = true
        startedAt = Date()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(chunk.count)).squareRoot()
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
        onLevel?(rms)
    }

    /// Stops recording and returns the captured 16 kHz samples.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        if let injected = Self.injectedSamples {
            isRecording = false
            return injected
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        isRecording = false
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        return result
    }

    func cancel() { _ = stop() }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / 16000
    }
}
