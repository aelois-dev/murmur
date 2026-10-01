import AppKit
import AVFoundation
import CoreAudio
import MurmurCore

enum Log {
    private static let queue = DispatchQueue(label: "murmur.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let url = AppPaths.logFile
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
        #if DEBUG
        print(line, terminator: "")
        #endif
    }
}

enum Permissions {
    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// Shows the system prompt that adds Murmur to the Accessibility list.
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// What the Globe/fn key does on its own: 0 = nothing, 1 = change input source, 2 = emoji, 3 = dictation.
    static var globeKeyUsage: Int {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType") ?? 0
    }

    static var globeKeyDescription: String {
        switch globeKeyUsage {
        case 0: "Do Nothing"
        case 1: "Change Input Source"
        case 2: "Show Emoji & Symbols"
        case 3: "Start Dictation"
        default: "Unknown"
        }
    }
}

/// Short UI sounds, synthesized once at launch so they ship without audio assets.
final class Sounds {
    static let shared = Sounds()
    enum Kind { case start, stop, cancel, error }
    private var players: [Kind: AVAudioPlayer] = [:]

    private init() {
        players[.start] = Self.makePlayer(notes: [(660, 0.055), (990, 0.09)], gain: 0.55)
        players[.stop] = Self.makePlayer(notes: [(880, 0.05), (587, 0.09)], gain: 0.45)
        players[.cancel] = Self.makePlayer(notes: [(440, 0.07), (330, 0.1)], gain: 0.4)
        players[.error] = Self.makePlayer(notes: [(311, 0.09), (233, 0.14)], gain: 0.45)
    }

    var isLoaded: Bool { players.count == 4 && players.values.allSatisfy { $0.duration > 0.05 } }

    func play(_ kind: Kind, volume: Double) {
        guard let player = players[kind] else { return }
        player.volume = Float(volume)
        player.currentTime = 0
        player.play()
    }

    private static func makePlayer(notes: [(Double, Double)], gain: Double) -> AVAudioPlayer? {
        let rate = 44100.0
        var samples: [Int16] = []
        for (freq, duration) in notes {
            let count = Int(rate * duration)
            for i in 0..<count {
                let t = Double(i) / rate
                // Soft attack, exponential decay, a touch of the octave for a glassy "ding".
                let env = min(1, t / 0.004) * exp(-t / (duration * 0.45))
                let v = (sin(2 * .pi * freq * t) + 0.25 * sin(4 * .pi * freq * t)) * env * gain
                samples.append(Int16(max(-1, min(1, v)) * 32767 * 0.6))
            }
        }
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + samples.count * 2).littleEndian)
        data.append("WAVEfmt ".data(using: .ascii)!)
        append(UInt32(16).littleEndian); append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(rate).littleEndian); append(UInt32(rate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append("data".data(using: .ascii)!)
        append(UInt32(samples.count * 2).littleEndian)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        let player = try? AVAudioPlayer(data: data)
        player?.prepareToPlay()
        return player
    }
}

/// Input devices for the microphone picker.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? { all().first { $0.uid == uid }?.id }

    static func name(of id: AudioDeviceID) -> String? { stringProperty(id, kAudioObjectPropertyName) }

    /// AirPods and other Bluetooth headsets need ~1 s to switch into microphone mode.
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static var defaultInputID: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static var defaultInputName: String? { defaultInputID.flatMap { stringProperty($0, kAudioObjectPropertyName) } }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// Mutes the default output device while dictating (Flow's "mute audio while dictating").
enum SystemAudio {
    private static var mutedByUs = false

    static func muteOutput(_ mute: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return }
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &muteAddress) else { return }
        var current: UInt32 = 0
        var currentSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &currentSize, &current)
        if mute {
            guard current == 0 else { return }
            var one: UInt32 = 1
            if AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &one) == noErr { mutedByUs = true }
        } else if mutedByUs {
            var zero: UInt32 = 0
            AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &zero)
            mutedByUs = false
        }
    }
}

/// Keeps the microphone list current as devices come and go (AirPods connecting, USB mics unplugged…).
@MainActor
final class AudioDeviceMonitor: ObservableObject {
    static let shared = AudioDeviceMonitor()
    @Published private(set) var devices: [AudioInputDevice] = AudioInputDevice.all()
    @Published private(set) var defaultInputName: String? = AudioInputDevice.defaultInputName

    private init() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main) { _, _ in
                MainActor.assumeIsolated {
                    AudioDeviceMonitor.shared.refresh()
                    // Bluetooth devices finish publishing their input stream a moment after they appear.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { AudioDeviceMonitor.shared.refresh() } }
                }
            }
        }
    }

    func refresh() {
        let list = AudioInputDevice.all()
        let name = AudioInputDevice.defaultInputName
        if list != devices { devices = list }
        if name != defaultInputName { defaultInputName = name }
    }

    /// Real microphones (not virtual loopback devices like Teams or BlackHole).
    var realDevices: [AudioInputDevice] { devices.filter { !AudioInputDevice.isVirtual($0.name) } }
}

extension AudioInputDevice {
    static let virtualMarkers = ["teams audio", "blackhole", "loopback", "soundflower", "zoomaudio", "zoom audio", "aggregate", "multi-output", "virtual"]

    static func isVirtual(_ name: String) -> Bool {
        let lower = name.lowercased()
        return virtualMarkers.contains { lower.contains($0) }
    }
}
