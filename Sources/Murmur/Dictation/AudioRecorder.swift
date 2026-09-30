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

    // Voice activity, used to start transcribing during pauses (before the key is released).
    private var noiseFloor: Float = 0.02
    private var lastVoiceUptime: TimeInterval = 0
    private var voiceSeen = false

    /// Uptime of the last buffer that contained speech.
    var lastVoiceAt: TimeInterval {
        if Self.injectedSamples != nil { return startedUptime }
        lock.lock(); defer { lock.unlock() }
        return lastVoiceUptime
    }

    /// How long the speaker has been quiet (0 until they've said something).
    var silenceDuration: TimeInterval {
        if Self.injectedSamples != nil { return 10 }
        lock.lock(); defer { lock.unlock() }
        return voiceSeen ? ProcessInfo.processInfo.systemUptime - lastVoiceUptime : 0
    }

    /// A copy of everything recorded so far.
    func snapshot() -> [Float] {
        if let injected = Self.injectedSamples { return injected }
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private var startedUptime: TimeInterval = 0

    func start(deviceUID: String?) throws {
        if isRecording { return }
        startedUptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        noiseFloor = 0.02
        voiceSeen = false
        lastVoiceUptime = startedUptime
        lock.unlock()
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
        // Adaptive noise floor: follows quiet levels quickly, rises slowly.
        noiseFloor = rms < noiseFloor ? rms : noiseFloor * 0.995 + rms * 0.005
        if rms > max(0.006, noiseFloor * 3.5) {
            voiceSeen = true
            lastVoiceUptime = ProcessInfo.processInfo.systemUptime
        }
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

    /// Runs buffers through the same conversion path the microphone uses (for tests).
    func convertForTest(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        guard let format = buffers.first?.format, let converter = AVAudioConverter(from: format, to: targetFormat) else { return [] }
        self.converter = converter
        lock.lock(); samples.removeAll(); lock.unlock()
        for b in buffers { process(b) }
        self.converter = nil
        lock.lock(); defer { samples.removeAll(); lock.unlock() }
        return samples
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / 16000
    }
}
