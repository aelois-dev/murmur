import AppKit
import AVFoundation
import Carbon.HIToolbox
import MurmurCore
import MurmurEngine

/// `--e2e <audio dir>`: drives the real app like a user would — synthetic fn key presses through the
/// system event stream, injected audio, and a real text view that receives the ⌘V paste.
/// Verifies push-to-talk, smart spacing, hands-free (double-tap), Command Mode and clipboard restore.
@MainActor
enum EndToEndTest {
    static func run(audioDirectory: URL, model: AppModel, controller: DictationController) {
        Task { @MainActor in
            var log: [String] = []
            var passed = 0, total = 0
            func check(_ name: String, _ ok: Bool, _ detail: String) {
                total += 1
                if ok { passed += 1 }
                log.append("\(ok ? "PASS" : "FAIL") \(name): \(detail)")
            }

            while !model.whisperStatus.isReady || model.llmStatus == .loading {
                if case .failed = model.whisperStatus { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard controller.hotkeys.isRunning else {
                finish(["FAIL hotkey monitor not running (no Accessibility)"], passed: 0, total: 1, dir: audioDirectory)
                return
            }

            // 0. Microphone conversion path with typical device formats, and UI sounds.
            for (rate, channels) in [(48000.0, 1), (44100.0, 2), (16000.0, 1), (24000.0, 1)] {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
                var buffers: [AVAudioPCMBuffer] = []
                var phase = 0.0
                for _ in 0..<Int(rate / 1024) { // ~1 second in 1024-frame chunks, like the tap
                    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                    b.frameLength = 1024
                    for i in 0..<1024 {
                        let v = Float(sin(phase) * 0.3)
                        phase += 2 * .pi * 440 / rate
                        for c in 0..<channels { b.floatChannelData![c][i] = v }
                    }
                    buffers.append(b)
                }
                let out = AudioRecorder().convertForTest(buffers)
                let expected = Double(buffers.count * 1024) / rate * 16000
                let rms = AudioAnalysis.rms(out[...])
                check("mic conversion \(Int(rate))Hz x\(channels)", abs(Double(out.count) - expected) < 1600 && rms > 0.15 && rms < 0.25,
                      "samples=\(out.count) expected≈\(Int(expected)) rms=\(String(format: "%.3f", rms))")
            }
            check("sounds loaded", Sounds.shared.isLoaded, "players ready: \(Sounds.shared.isLoaded)")

            // A real window with a text view to type into.
            let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 640, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Murmur end-to-end test"
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = window.contentView!.bounds
            scroll.autoresizingMask = [.width, .height]
            let textView = scroll.documentView as! NSTextView
            textView.font = .systemFont(ofSize: 15)
            window.contentView!.addSubview(scroll)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            try? await Task.sleep(nanoseconds: 800_000_000)

            // Protect the user's clipboard: remember it, use a sentinel, restore it at the end.
            let pasteboard = NSPasteboard.general
            let savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) } }
            let sentinel = "murmur-clipboard-sentinel-\(UUID().uuidString.prefix(6))"
            pasteboard.clearContents()
            pasteboard.setString(sentinel, forType: .string)
            let savedInput = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()

            @MainActor func samples(_ name: String) -> [Float] { (try? SelfTest.load(audioDirectory.appendingPathComponent(name))) ?? [] }
            @MainActor func waitIdle() async {
                try? await Task.sleep(nanoseconds: 300_000_000)
                for _ in 0..<200 where model.phase != .idle { try? await Task.sleep(nanoseconds: 100_000_000) }
                try? await Task.sleep(nanoseconds: 900_000_000)
            }

            @MainActor func ensureFocus() async -> Bool {
                for _ in 0..<10 {
                    if safeToType { return true }
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(textView)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                return safeToType
            }
            guard await ensureFocus() else {
                finish(["FAIL could not focus the test window; aborted without sending keys"], passed: 0, total: 1, dir: audioDirectory)
                return
            }

            // 1. Push to talk.
            AudioRecorder.injectedSamples = samples("02_fillers.wav")
            postFn(down: true)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let recordingSeen = model.phase == .recording(.pushToTalk)
            postFn(down: false)
            await waitIdle()
            check("push-to-talk recording state", recordingSeen, "phase while held: \(recordingSeen)")
            check("push-to-talk paste", textView.string == "So I think we should meet tomorrow at noon.", "text=\(textView.string.debugDescription)")
            check("clipboard restored", pasteboard.string(forType: .string) == sentinel, "clipboard=\(pasteboard.string(forType: .string)?.prefix(40).debugDescription ?? "nil")")

            guard await ensureFocus() else { log.append("ABORT lost focus"); finish(log, passed: passed, total: total + 1, dir: audioDirectory); return }
            // 2. Second dictation continues the text with smart spacing.
            AudioRecorder.injectedSamples = samples("03_backtrack.wav")
            postFn(down: true)
            try? await Task.sleep(nanoseconds: 900_000_000)
            postFn(down: false)
            await waitIdle()
            check("smart spacing + backtrack", textView.string == "So I think we should meet tomorrow at noon. Let's do coffee at 3.", "text=\(textView.string.debugDescription)")

            guard await ensureFocus() else { log.append("ABORT lost focus"); finish(log, passed: passed, total: total + 1, dir: audioDirectory); return }
            // 2b. Speaking, pausing, then releasing: text should appear almost immediately (pause-time transcription).
            textView.string = ""
            AudioRecorder.injectedSamples = samples("01_simple.wav")
            postFn(down: true)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            postFn(down: false)
            let released = Date()
            for _ in 0..<60 where textView.string.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000) }
            let latency = Date().timeIntervalSince(released)
            await waitIdle()
            check("instant text after a pause", textView.string == "Hey, can you send me the quarterly report by Friday? Thanks." && latency < 0.6,
                  "latency=\(String(format: "%.2f", latency))s text=\(textView.string.debugDescription)")

            // 3. Hands-free by double-tapping fn, then tap to finish.
            textView.string = ""
            AudioRecorder.injectedSamples = samples("06_question.wav")
            postFn(down: true); try? await Task.sleep(nanoseconds: 90_000_000)
            postFn(down: false); try? await Task.sleep(nanoseconds: 150_000_000)
            postFn(down: true); try? await Task.sleep(nanoseconds: 90_000_000)
            postFn(down: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let handsFreeSeen = model.phase == .recording(.handsFree)
            postFn(down: true); try? await Task.sleep(nanoseconds: 80_000_000)
            postFn(down: false)
            await waitIdle()
            check("hands-free locked after double-tap", handsFreeSeen, "phase: \(handsFreeSeen)")
            check("hands-free paste", textView.string == "What's the capital of France?", "text=\(textView.string.debugDescription)")

            guard await ensureFocus() else { log.append("ABORT lost focus"); finish(log, passed: passed, total: total + 1, dir: audioDirectory); return }
            // 3b. ⌃⌘V pastes the last transcript again.
            textView.string = ""
            if safeToType, let v = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
               let vUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
                v.flags = [.maskControl, .maskCommand]
                vUp.flags = [.maskControl, .maskCommand]
                v.post(tap: .cghidEventTap)
                vUp.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            check("paste last transcript (⌃⌘V)", textView.string == "What's the capital of France?", "text=\(textView.string.debugDescription)")

            // 4. Quick tap is ignored.
            textView.string = ""
            AudioRecorder.injectedSamples = samples("06_question.wav")
            postFn(down: true); try? await Task.sleep(nanoseconds: 80_000_000)
            postFn(down: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            check("quick tap dismissed", textView.string.isEmpty && model.phase == .idle, "text=\(textView.string.debugDescription)")

            guard await ensureFocus() else { log.append("ABORT lost focus"); finish(log, passed: passed, total: total + 1, dir: audioDirectory); return }
            // 5. Esc cancels a recording.
            AudioRecorder.injectedSamples = samples("02_fillers.wav")
            postFn(down: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            postKey(kVK_Escape)
            try? await Task.sleep(nanoseconds: 200_000_000)
            postFn(down: false)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            check("escape cancels", textView.string.isEmpty && model.phase == .idle, "text=\(textView.string.debugDescription) notice=\(model.notice?.message ?? "none")")

            guard await ensureFocus() else { log.append("ABORT lost focus"); finish(log, passed: passed, total: total + 1, dir: audioDirectory); return }
            // 6. On-screen context: names already in the field are spelled the same way; mid-sentence continues lowercase.
            textView.string = "Hi Siobhan, thanks for the notes. I was thinking that "
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            AudioRecorder.injectedSamples = samples("ctx_siobhan.wav")
            postFn(down: true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            postFn(down: false)
            await waitIdle()
            let ctxText = textView.string
            check("context spelling (Siobhan)", ctxText.contains("that Siobhan") || ctxText.contains("that siobhan") ? ctxText.contains("Siobhan is right") : false, "text=\(ctxText.debugDescription)")

            // 7. Auto-learning: the user fixes a name after insertion → it's added to the dictionary.
            textView.string = "Please ask Kestrell about the launch."
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            try? await Task.sleep(nanoseconds: 200_000_000)
            let focus = TextInserter.focusInfo()
            controller.corrections.track(element: focus.element, inserted: "Please ask Kestrell about the launch.", endLocation: focus.insertionLocation)
            textView.string = "Please ask Kjestrel about the launch."
            controller.corrections.check()
            try? await Task.sleep(nanoseconds: 300_000_000)
            check("auto-learn corrected name", model.dictionary.contains { $0.word == "Kjestrel" && $0.autoLearned }, "dictionary=\(model.dictionary.map(\.word))")
            model.dictionary.removeAll { $0.autoLearned }

            // 8. Command Mode on a selection.
            if model.llmStatus.isReady {
                textView.string = "hey whats up can u send me the report by tmrw"
                textView.selectAll(nil)
                AudioRecorder.injectedSamples = samples("cmd_formal.wav")
                postFn(down: true)
                try? await Task.sleep(nanoseconds: 60_000_000)
                postFlags([.maskSecondaryFn, .maskControl], keyCode: kVK_Control)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let commandSeen = model.phase == .recording(.command)
                postFlags([.maskSecondaryFn], keyCode: kVK_Control)
                postFn(down: false)
                await waitIdle()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let result = textView.string
                check("command mode state", commandSeen, "phase: \(commandSeen)")
                check("command mode rewrite", result != "hey whats up can u send me the report by tmrw" && result.lowercased().contains("report") && !result.contains("\n\n\n"),
                      "text=\(result.debugDescription)")
            } else {
                log.append("SKIP command mode (AI model not ready: \(model.llmStatus.label))")
            }

            AudioRecorder.injectedSamples = nil
            if let savedInput { TISSelectInputSource(savedInput) }
            pasteboard.clearContents()
            if !savedClipboard.isEmpty {
                pasteboard.writeObjects(savedClipboard.map { entry in
                    let item = NSPasteboardItem()
                    for (type, data) in entry { item.setData(data, forType: type) }
                    return item
                })
            }
            window.orderOut(nil)
            finish(log, passed: passed, total: total, dir: audioDirectory)
        }
    }

    static func postFn(down: Bool) {
        postFlags(down ? [.maskSecondaryFn] : [], keyCode: kVK_Function)
    }

    /// Synthetic keys must only ever reach our own test window.
    static var safeToType: Bool { NSApp.isActive && NSApp.keyWindow?.title == "Murmur end-to-end test" }

    static func postFlags(_ flags: CGEventFlags, keyCode: Int) {
        guard safeToType else { return }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func postKey(_ keyCode: Int) {
        guard safeToType else { return }
        CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)?.post(tap: .cghidEventTap)
    }

    static func finish(_ log: [String], passed: Int, total: Int, dir: URL) {
        let text = (log + ["RESULT \(passed)/\(total) passed"]).joined(separator: "\n")
        try? text.write(to: dir.appendingPathComponent("e2e-report.txt"), atomically: true, encoding: .utf8)
        Log.write("E2E finished: \(passed)/\(total)")
        NSApp.terminate(nil)
    }
}
