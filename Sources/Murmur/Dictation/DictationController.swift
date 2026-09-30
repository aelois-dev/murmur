import AppKit
import MurmurCore
import MurmurEngine

/// Orchestrates a dictation: shortcut → microphone → speech model → cleanup → paste → history.
@MainActor
final class DictationController {
    let model: AppModel
    private var machine = HotkeyStateMachine()
    private let recorder = AudioRecorder()
    let hotkeys = HotkeyMonitor()
    private var tickTimer: Timer?
    private var permissionTimer: Timer?
    private var target = TargetApp()
    private var cancelled: (samples: [Float], target: TargetApp, mode: RecordingMode)?
    private var processingTask: Task<Void, Never>?
    private let inputSourceGuard = InputSourceGuard()
    /// Self-test hook: receives the final text instead of pasting it (no clipboard or history side effects).
    var dryRunSink: ((DictationRecord) -> Void)?
    private var dryRunResult: DictationRecord?

    init(model: AppModel) {
        self.model = model
        model.onShortcutSettingsChanged = { [weak self] in self?.configureHotkeys() }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Setup

    func start() {
        configureHotkeys()
        hotkeys.handler = { [weak self] signal in self?.handle(signal) ?? false }
        hotkeys.isRecording = { [weak self] in self?.machine.isRecording ?? false }
        if !hotkeys.start() { waitForAccessibility() }
    }

    func configureHotkeys() {
        let s = model.settings
        hotkeys.hotkey = s.pushToTalkKey
        hotkeys.handsFreeWithSpace = s.handsFreeWithSpace
        hotkeys.commandModeEnabled = s.commandModeEnabled
        machine.doubleTapEnabled = s.doubleTapForHandsFree
        machine.commandModeEnabled = s.commandModeEnabled
    }

    /// Accessibility can be granted at any time; start listening as soon as it is.
    private func waitForAccessibility() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.model.refreshPermissions()
                if self.model.accessibilityTrusted, self.hotkeys.start() {
                    timer.invalidate()
                    self.permissionTimer = nil
                    Log.write("Accessibility granted; shortcuts active")
                }
            }
        }
    }

    // MARK: - Input

    private func handle(_ signal: HotkeyMonitor.Signal) -> Bool {
        switch signal {
        case .pttDown:
            if model.settings.pushToTalkKey == .fn && !machine.isRecording { inputSourceGuard.remember() }
            send(.pttDown)
        case .pttUp: send(.pttUp)
        case .handsFree: send(.handsFreeShortcut)
        case .commandModifier: send(.commandModifierDown)
        case .escape: send(.escape)
        case .otherKey: send(.otherKeyPressed)
        }
        return true
    }

    func barClicked() { send(.barClicked) }
    func stopClicked() { send(.stopClicked) }
    func cancelClicked() { send(.cancelClicked) }

    private func send(_ event: HotkeyStateMachine.Event) {
        let actions = machine.handle(event, at: now)
        guard !actions.isEmpty else { return }
        // Leave the event-tap callback quickly; do the work on the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            for action in actions { self?.perform(action) }
        }
    }

    private func perform(_ action: HotkeyStateMachine.Action) {
        switch action {
        case .startRecording(let mode): startRecording(mode)
        case .switchMode(let mode): switchMode(mode)
        case .stopAndProcess(let mode): stopAndProcess(mode)
        case .cancel(let reason): cancel(reason)
        case .notice(let message): model.showNotice(message)
        case .warnTimeLimit: model.showNotice("Recording stops in 1 minute", duration: 4)
        }
    }

    // MARK: - Recording

    private func startRecording(_ mode: RecordingMode) {
        switch model.whisperStatus {
        case .notDownloaded, .failed:
            abortStart("Download a speech model in Settings to start dictating", action: ("Open Settings", .openSettings))
            return
        default: break
        }
        model.refreshPermissions()
        guard model.micAuthorized || AudioRecorder.injectedSamples != nil else {
            abortStart("Murmur needs microphone access", action: ("Allow", .openMicrophone))
            model.requestMicrophone()
            return
        }
        model.dismissNotice()
        cancelled = nil
        target = TargetApp.current()
        if model.settings.soundEffects { Sounds.shared.play(.start, volume: model.settings.soundVolume) }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.model.pushLevel(level) }
        }
        do {
            try recorder.start(deviceUID: model.settings.microphoneUID)
        } catch {
            Log.write("Recording failed to start: \(error)")
            machine.reset()
            model.phase = .idle
            model.showNotice("Microphone unavailable — check your input device", kind: .error, actions: [("Settings", .openSettings)], duration: 4)
            if model.settings.soundEffects { Sounds.shared.play(.error, volume: model.settings.soundVolume) }
            return
        }
        if model.settings.pauseMediaWhileDictating {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                if self?.recorder.isRecording == true { SystemAudio.muteOutput(true) }
            }
        }
        model.phase = .recording(mode)
        model.recordingStartedAt = Date()
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(.tick) }
        }
        Log.write("Recording started (\(mode.rawValue)) in \(target.name ?? "unknown app")")
    }

    private func abortStart(_ message: String, action: (String, FlowNotice.Action)) {
        machine.reset()
        model.phase = .idle
        model.showNotice(message, kind: .error, actions: [action], duration: 4)
        if model.settings.soundEffects { Sounds.shared.play(.error, volume: model.settings.soundVolume) }
    }

    private func switchMode(_ mode: RecordingMode) {
        model.phase = .recording(mode)
        Log.write("Switched to \(mode.rawValue)")
    }

    private func endRecording() -> [Float] {
        tickTimer?.invalidate()
        tickTimer = nil
        let samples = recorder.stop()
        SystemAudio.muteOutput(false)
        model.resetLevels()
        model.recordingStartedAt = nil
        return samples
    }

    private func stopAndProcess(_ mode: RecordingMode) {
        let samples = endRecording()
        if model.settings.pushToTalkKey == .fn { inputSourceGuard.restoreSoon() }
        if model.settings.soundEffects { Sounds.shared.play(.stop, volume: model.settings.soundVolume) }
        process(samples, mode: mode, target: target)
    }

    private func cancel(_ reason: HotkeyStateMachine.CancelReason) {
        let samples = endRecording()
        model.phase = .idle
        switch reason {
        case .tooShort:
            Log.write("Dismissed (too short)")
        case .userCancelled, .tripleTap:
            if model.settings.pushToTalkKey == .fn { inputSourceGuard.restoreSoon() }
            if model.settings.soundEffects { Sounds.shared.play(.cancel, volume: model.settings.soundVolume) }
            if Double(samples.count) / 16000 > 0.6 {
                cancelled = (samples, target, machine.currentMode ?? .pushToTalk)
                model.showNotice("Transcript cancelled", actions: [("Undo", .undoCancel), ("Open History", .openHistory)], duration: 5)
            }
            Log.write("Cancelled by user")
        }
    }

    /// Undo from the cancellation notice: transcribe what was recorded after all.
    func undoCancel() {
        guard let cancelled, machine.state == .idle else { return }
        self.cancelled = nil
        model.dismissNotice()
        _ = machine.handle(.pttDown, at: now)
        _ = machine.handle(.pttUp, at: now + 10)
        process(cancelled.samples, mode: cancelled.mode == .command ? .command : .pushToTalk, target: cancelled.target)
    }

    // MARK: - Processing

    func process(_ samples: [Float], mode: RecordingMode, target: TargetApp) {
        model.phase = .processing(mode)
        let audioDuration = Double(samples.count) / 16000
        let settings = model.settings
        let dictionary = model.dictionary
        let snippets = model.snippets
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishProcessing() }
            guard audioDuration >= 0.25 else { return }

            // The model may still be loading right after launch.
            var waited = 0.0
            while !model.whisperStatus.isReady && waited < 180 {
                if case .failed = model.whisperStatus { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            guard model.whisperStatus.isReady else {
                model.showNotice("The speech model isn't ready yet", kind: .error)
                return
            }

            let started = Date()
            let transcript: TranscriptionOutput
            do {
                transcript = try await model.transcriber.transcribe(samples, language: settings.language,
                                                                   prompt: VocabularyCorrector.speechPrompt(for: dictionary))
            } catch {
                Log.write("Transcription failed: \(error)")
                model.showNotice("Transcription failed", kind: .error)
                return
            }
            Log.write("Heard (\(String(format: "%.2f", transcript.seconds))s for \(String(format: "%.1f", audioDuration))s audio): \(transcript.text)")
            guard !transcript.text.isEmpty else {
                if audioDuration > 1 {
                    model.showNotice("No speech detected", kind: .info, actions: [("Microphone", .openSettings)])
                }
                return
            }

            if mode == .command {
                await runCommand(transcript.text, target: target, audioDuration: audioDuration, started: started)
                return
            }

            let category = AppCategory.category(forBundleID: target.bundleID, appName: target.name)
            let polisher = model.llmStatus.isReady ? model.polisher : nil
            let output = await Task.detached(priority: .userInitiated) {
                TextPipeline.process(raw: transcript.text, settings: settings, dictionary: dictionary, snippets: snippets,
                                     category: category, appName: target.name, polisher: polisher)
            }.value
            guard !output.text.isEmpty else { return }
            if let reason = output.rejectedAIReason { Log.write("AI edit discarded: \(reason)") }

            if dryRunSink != nil {
                dryRunResult = DictationRecord(rawText: transcript.text, text: output.text, appName: target.name, appBundleID: target.bundleID,
                                               audioDuration: audioDuration, processingTime: Date().timeIntervalSince(started), aiEdited: output.aiEdited)
                return
            }
            let focus = TextInserter.focusInfo()
            let text = TextInserter.adjustForContext(output.text, preceding: focus.precedingCharacter)
            let inserted = TextInserter.insert(text, keepInClipboard: settings.keepTranscriptInClipboard)
            let elapsed = Date().timeIntervalSince(started)
            Log.write("Inserted in \(String(format: "%.2f", elapsed))s (ai: \(output.aiEdited), \(String(format: "%.2f", output.aiSeconds))s): \(output.text)")
            if !inserted {
                model.showNotice("Copied to clipboard — press ⌘V to paste", kind: .info, actions: [("Enable auto-paste", .openAccessibility)], duration: 5)
            }
            model.addHistory(DictationRecord(rawText: transcript.text, text: output.text, appName: target.name, appBundleID: target.bundleID,
                                             audioDuration: audioDuration, processingTime: elapsed, mode: .dictation,
                                             aiEdited: output.aiEdited, insertionFailed: !inserted))
        }
    }

    private func runCommand(_ instruction: String, target: TargetApp, audioDuration: Double, started: Date) async {
        guard let polisher = model.polisher, model.llmStatus.isReady else {
            model.showNotice("Command Mode needs the AI model — download it in Settings", kind: .error, actions: [("Open Settings", .openSettings)], duration: 4)
            return
        }
        let focus = TextInserter.focusInfo()
        var selected = focus.selectedText
        if selected == nil { selected = TextInserter.copySelection() }
        let selection = selected
        do {
            let (result, stats) = try await Task.detached(priority: .userInitiated) {
                try polisher.command(instruction: instruction, selectedText: selection)
            }.value
            guard !result.isEmpty else {
                model.showNotice("Command didn't produce any text")
                return
            }
            let inserted = TextInserter.insert(result, keepInClipboard: model.settings.keepTranscriptInClipboard)
            Log.write("Command '\(instruction)' → \(result.count) chars in \(String(format: "%.2f", stats.seconds))s")
            if !inserted { model.showNotice("Copied to clipboard — press ⌘V to paste", actions: [("Enable auto-paste", .openAccessibility)], duration: 5) }
            model.addHistory(DictationRecord(rawText: instruction, text: result, appName: target.name, appBundleID: target.bundleID,
                                             audioDuration: audioDuration, processingTime: Date().timeIntervalSince(started),
                                             mode: .command, aiEdited: true, insertionFailed: !inserted))
        } catch {
            Log.write("Command failed: \(error)")
            model.showNotice("Command failed", kind: .error)
        }
    }

    private func finishProcessing() {
        _ = machine.handle(.processingFinished, at: now)
        if case .processing = model.phase { model.phase = .idle }
        if let sink = dryRunSink {
            sink(dryRunResult ?? DictationRecord(rawText: "", text: "", audioDuration: 0, processingTime: 0))
            dryRunResult = nil
        }
    }

    // MARK: - Menu actions

    func pasteLastTranscript() {
        guard let last = model.lastTranscript else { return }
        if !TextInserter.insert(last.text, keepInClipboard: model.settings.keepTranscriptInClipboard) {
            model.showNotice("Copied to clipboard — press ⌘V to paste")
        }
    }

    func toggleHandsFree() {
        if machine.isRecording { send(.stopClicked) } else { send(.handsFreeShortcut) }
    }
}
