import AppKit
import MurmurCore
import SwiftUI

/// Live microphone check with a device picker: shows a level meter and warns about missing or virtual inputs.
@MainActor
final class MicMeter: ObservableObject {
    @Published var level: CGFloat = 0
    @Published var heardVoice = false
    @Published var running = false
    @Published var failed = false
    private let recorder = AudioRecorder()
    private var stopTask: Task<Void, Never>?

    /// Snapshots render this view without touching the microphone.
    static var previewOnly = false

    /// Which device the meter opened (UID, or the default device's name).
    private(set) var deviceKey: String?

    func start(uid: String?, duration: TimeInterval? = nil) {
        stop()
        deviceKey = uid ?? AudioInputDevice.defaultInputName ?? ""
        if Self.previewOnly { level = 0.55; heardVoice = true; running = true; return }
        heardVoice = false
        failed = false
        recorder.onLevel = { [weak self] rms in
            Task { @MainActor in
                guard let self else { return }
                let db = 20 * log10(max(rms, 0.0001))
                let normalized = CGFloat(max(0, min(1, (db + 55) / 45)))
                self.level = self.level * 0.4 + normalized * 0.6
                if rms > 0.02 { self.heardVoice = true }
            }
        }
        do {
            try recorder.start(deviceUID: uid)
            running = true
        } catch {
            failed = true
            running = false
        }
        if let duration {
            stopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                if !Task.isCancelled { self?.stop() }
            }
        }
    }

    func stop() {
        stopTask?.cancel()
        if running { recorder.cancel() }
        running = false
        level = 0
    }
}

struct MicTestView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var meter = MicMeter()
    @ObservedObject private var audio = AudioDeviceMonitor.shared
    var autoStart: Bool

    private var devices: [AudioInputDevice] { audio.devices }

    static func isVirtual(_ name: String) -> Bool { AudioInputDevice.isVirtual(name) }

    private var currentName: String {
        if let uid = model.settings.microphoneUID, let d = devices.first(where: { $0.uid == uid }) { return d.name }
        return audio.defaultInputName ?? "None"
    }

    private var warning: String? {
        if audio.realDevices.isEmpty {
            return "No microphone connected. Connect AirPods (Control Center → Sound), a headset, a webcam or a USB mic — a Mac mini has no built-in mic. AirPods can hop to your iPhone, so check they're connected to this Mac."
        }
        if let uid = model.settings.microphoneUID, !devices.contains(where: { $0.uid == uid }) {
            return "The microphone you picked isn't connected right now, so Murmur will use the system default."
        }
        if Self.isVirtual(currentName) {
            return "“\(currentName)” is a virtual device, not a real microphone. Pick your headset or mic above."
        }
        if meter.failed { return "Couldn't open this microphone. Try another one." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").foregroundStyle(Theme.accent)
                Picker("", selection: $model.settings.microphoneUID) {
                    Text("System default (\(audio.defaultInputName ?? "none"))").tag(String?.none)
                    ForEach(devices) { d in
                        Text(Self.isVirtual(d.name) ? "\(d.name) (virtual)" : d.name).tag(String?.some(d.uid))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                if !autoStart {
                    Button(meter.running ? "Stop" : "Test") {
                        if meter.running { meter.stop() } else { meter.start(uid: model.settings.microphoneUID, duration: 12) }
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    .disabled(!model.micAuthorized)
                }
            }
            if meter.running || autoStart {
                HStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.border)
                            Capsule().fill(meter.heardVoice ? Theme.success : Theme.accent)
                                .frame(width: max(6, geo.size.width * meter.level))
                                .animation(.linear(duration: 0.08), value: meter.level)
                        }
                    }
                    .frame(height: 8)
                    Text(meter.heardVoice ? "We can hear you" : "Say something…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(meter.heardVoice ? Theme.success : Theme.secondary)
                        .frame(width: 110, alignment: .leading)
                }
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            audio.refresh()
            if autoStart && model.micAuthorized { meter.start(uid: model.settings.microphoneUID) }
        }
        .onChange(of: audio.devices) { _, _ in restartIfNeeded() }
        .onChange(of: audio.defaultInputName) { _, _ in restartIfNeeded() }
        .onDisappear { meter.stop() }
        .onChange(of: model.settings.microphoneUID) { _, uid in
            if meter.running || autoStart { meter.start(uid: uid, duration: autoStart ? nil : 12) }
        }
        .onChange(of: model.micAuthorized) { _, ok in
            if ok && autoStart { meter.start(uid: model.settings.microphoneUID) }
        }
    }

    /// A device connected or the default changed: reopen the mic so the meter follows it —
    /// but only if the effective device really changed (reopening AirPods costs ~1.5 s each time).
    private func restartIfNeeded() {
        guard meter.running || (autoStart && model.micAuthorized) else { return }
        let effective = model.settings.microphoneUID ?? audio.defaultInputName ?? ""
        guard effective != meter.deviceKey else { return }
        meter.start(uid: model.settings.microphoneUID, duration: autoStart ? nil : 12)
    }
}
