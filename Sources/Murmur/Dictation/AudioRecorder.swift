import AudioToolbox
import AVFoundation
import CoreAudio

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
///
/// Bluetooth mics (AirPods) take about a second to wake up, which used to swallow the first words. So:
/// - `onLive` fires when audio is really flowing (the "start talking" chime plays then, not at key press);
/// - after a dictation the engine can stay running ("warm") so the next one starts instantly;
/// - while warm, the last ~0.6 s is kept and prepended, catching words said right as the key goes down.
final class AudioRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var engineUID: String?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()

    // Guarded by `lock`.
    private var samples: [Float] = []
    private var preroll: [Float] = []
    private var capturing = false
    private var live = false
    private var liveNotified = false
    private var noiseFloor: Float = 0.02
    private var lastVoiceUptime: TimeInterval = 0
    private var voiceSeen = false

    private let prerollCapacity = 9600 // 0.6 s at 16 kHz
    private var engineStartUptime: TimeInterval = 0
    private var startedUptime: TimeInterval = 0
    private var coolDown: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// Whether the input device is Bluetooth (slow to wake, so worth keeping warm).
    private(set) var isBluetoothInput = false
    private(set) var inputName: String?

    /// Called on the audio thread with the RMS level of each captured buffer.
    var onLevel: ((Float) -> Void)?
    /// Called (on any thread) once audio is really flowing for the current capture.
    var onLive: (() -> Void)?

    /// End-to-end tests inject audio here instead of using the microphone.
    static var injectedSamples: [Float]?

    var isWarm: Bool { engine?.isRunning == true && !isRecording }

    // MARK: - Voice activity (used to transcribe during pauses)

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

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16000
    }

    // MARK: - Start / stop

    func start(deviceUID: String?) throws {
        if isRecording { return }
        coolDown?.cancel()
        coolDown = nil
        startedUptime = ProcessInfo.processInfo.systemUptime
        startedAt = Date()
        if Self.injectedSamples != nil {
            isRecording = true
            onLive?()
            return
        }

        if let engine, engine.isRunning, engineUID == deviceUID {
            // Warm start: the mic is already live; seed with the audio from just before the key press.
            lock.lock()
            samples = preroll
            let prerollSeconds = Double(preroll.count) / 16000
            resetVoiceState()
            capturing = true
            let isLive = live
            liveNotified = isLive
            lock.unlock()
            isRecording = true
            if isLive { onLive?() }
            Log.write("Mic warm start (\(inputName ?? "input"), \(String(format: "%.2f", prerollSeconds))s pre-roll)")
            return
        }

        shutdown()
        try startEngine(deviceUID: deviceUID)
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16000 * 60)
        resetVoiceState()
        capturing = true
        liveNotified = false
        lock.unlock()
        isRecording = true
    }

    /// Opens the microphone without recording (used when the user wants it always ready).
    func prewarm(deviceUID: String?) {
        guard engine?.isRunning != true, !isRecording, Self.injectedSamples == nil else { return }
        do { try startEngine(deviceUID: deviceUID) } catch { Log.write("Prewarm failed: \(error)") }
    }

    /// Stops recording and returns the captured 16 kHz samples. The mic stays open for `keepWarmFor` seconds.
    func stop(keepWarmFor seconds: TimeInterval = 0) -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        if let injected = Self.injectedSamples { return injected }
        lock.lock()
        capturing = false
        let result = samples
        samples.removeAll()
        lock.unlock()
        if seconds > 0, engine?.isRunning == true {
            if seconds.isFinite {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.isRecording else { return }
                    self.shutdown()
                }
                coolDown = work
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
            }
        } else {
            shutdown()
        }
        return result
    }

    func cancel(keepWarmFor seconds: TimeInterval = 0) { _ = stop(keepWarmFor: seconds) }

    /// Closes the microphone completely.
    func shutdown() {
        coolDown?.cancel()
        coolDown = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine = nil
        converter = nil
        lock.lock()
        live = false
        preroll.removeAll()
        lock.unlock()
    }

    private func resetVoiceState() {
        noiseFloor = 0.02
        voiceSeen = false
        lastVoiceUptime = ProcessInfo.processInfo.systemUptime
    }

    private func startEngine(deviceUID: String?) throws {
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

        // Identify the real device for logging and warm-up decisions. (With the system default, the engine's own
        // device is a private "CADefaultDeviceAggregate", so ask Core Audio which input that actually is.)
        let realDevice = deviceUID.flatMap { AudioInputDevice.deviceID(forUID: $0) } ?? AudioInputDevice.defaultInputID
        if let realDevice {
            isBluetoothInput = AudioInputDevice.isBluetooth(realDevice)
            inputName = AudioInputDevice.name(of: realDevice)
        } else {
            isBluetoothInput = false
            inputName = nil
        }

        lock.lock()
        live = false
        preroll.removeAll()
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        engineStartUptime = ProcessInfo.processInfo.systemUptime
        try engine.start()
        self.engine = engine
        engineUID = deviceUID
        // Device switched or disconnected underneath us (AirPods taken out, default input changed).
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("Microphone configuration changed")
            if !self.isRecording { self.shutdown() }
        }
        Log.write("Mic opened: \(inputName ?? "default input")\(isBluetoothInput ? " (Bluetooth)" : "") \(Int(format.sampleRate)) Hz")
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
        var peak: Float = 0
        for s in chunk {
            sum += s * s
            peak = max(peak, abs(s))
        }
        let rms = (sum / Float(chunk.count)).squareRoot()

        var fireLive = false
        var isCapturing = false
        var liveAfterMs: Int?
        lock.lock()
        if !live && peak > 0.00001 {
            // First real audio since the mic opened (Bluetooth delivers silence while it switches modes).
            live = true
            liveAfterMs = Int((ProcessInfo.processInfo.systemUptime - engineStartUptime) * 1000)
        }
        if live {
            preroll.append(contentsOf: chunk)
            if preroll.count > prerollCapacity { preroll.removeFirst(preroll.count - prerollCapacity) }
        }
        if capturing && live {
            samples.append(contentsOf: chunk)
            noiseFloor = rms < noiseFloor ? rms : noiseFloor * 0.995 + rms * 0.005
            if rms > max(0.006, noiseFloor * 3.5) {
                voiceSeen = true
                lastVoiceUptime = ProcessInfo.processInfo.systemUptime
            }
            if !liveNotified {
                liveNotified = true
                fireLive = true
            }
            isCapturing = true
        }
        lock.unlock()
        if let liveAfterMs { Log.write("Mic live after \(liveAfterMs) ms") }
        if fireLive { onLive?() }
        if isCapturing { onLevel?(rms) }
    }

    /// Runs buffers through the same conversion path the microphone uses (for tests).
    func convertForTest(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        guard let format = buffers.first?.format, let converter = AVAudioConverter(from: format, to: targetFormat) else { return [] }
        self.converter = converter
        lock.lock(); samples.removeAll(); capturing = true; live = true; liveNotified = true; lock.unlock()
        for b in buffers { process(b) }
        self.converter = nil
        lock.lock(); defer { samples.removeAll(); capturing = false; live = false; lock.unlock() }
        return samples
    }
}
