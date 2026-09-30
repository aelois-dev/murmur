import AppKit
import MurmurCore
import SwiftUI

/// Renders the UI offscreen to PNG files so the build loop can check layouts without screen access.
@MainActor
enum Snapshotter {
    static func run(outputDirectory: URL) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        MicMeter.previewOnly = true
        let model = AppModel.shared
        model.whisperStatus = .ready
        model.llmStatus = .ready
        model.micAuthorized = true
        model.accessibilityTrusted = true
        seedDemoData(model)

        for appearance in ["light", "dark"] {
            let ns = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)!
            for section in HubSection.allCases {
                model.hubSection = section
                render(HubView(controller: nil).environmentObject(model), size: NSSize(width: 1000, height: 690), appearance: ns,
                       to: outputDirectory.appendingPathComponent("hub-\(section.rawValue)-\(appearance).png"))
            }
        }
        let light = NSAppearance(named: .aqua)!
        model.hubSection = .settings
        render(SettingsView().environmentObject(model).frame(width: 784).background(Theme.background), size: NSSize(width: 784, height: 2300), appearance: light,
               to: outputDirectory.appendingPathComponent("settings-full.png"))
        model.micAuthorized = true
        model.accessibilityTrusted = false
        render(OnboardingView(onFinish: {}, initialStep: 1).environmentObject(model), size: NSSize(width: 760, height: 560),
               appearance: NSAppearance(named: .darkAqua)!, to: outputDirectory.appendingPathComponent("onboarding-1-mic.png"))
        model.micAuthorized = false
        for step in 0..<5 {
            render(OnboardingView(onFinish: {}, initialStep: step).environmentObject(model), size: NSSize(width: 760, height: 560),
                   appearance: NSAppearance(named: .darkAqua)!, to: outputDirectory.appendingPathComponent("onboarding-\(step).png"))
        }

        let actions = FlowBarActions(click: {}, stop: {}, cancel: {}, notice: { _ in })
        let states: [(String, DictationPhase, Bool, FlowNotice?)] = [
            ("idle", .idle, false, nil),
            ("hover", .idle, true, nil),
            ("ptt", .recording(.pushToTalk), false, nil),
            ("handsfree", .recording(.handsFree), false, nil),
            ("command", .recording(.command), false, nil),
            ("processing", .processing(.pushToTalk), false, nil),
            ("notice", .idle, false, FlowNotice(message: "Transcript cancelled", actions: [(title: "Undo", action: .undoCancel), (title: "Open History", action: .openHistory)])),
        ]
        model.levels = [0.1, 0.25, 0.5, 0.8, 0.6, 0.9, 0.7, 0.4, 0.65, 0.85, 0.5, 0.3, 0.45, 0.2, 0.1]
        for (name, phase, hover, notice) in states {
            model.phase = phase
            model.flowBarHovering = hover
            model.notice = notice
            let view = FlowBarView(actions: actions).environmentObject(model)
                .frame(width: FlowBarController.panelSize.width, height: FlowBarController.panelSize.height)
                .background(Color(white: 0.82))
            render(view, size: FlowBarController.panelSize, appearance: light, to: outputDirectory.appendingPathComponent("flowbar-\(name).png"))
        }
        print("Snapshots written to \(outputDirectory.path)")
    }

    static func seedDemoData(_ model: AppModel) {
        guard model.history.isEmpty else { return }
        let now = Date()
        let samples: [(Double, String, String, Bool)] = [
            (-300, "Hey Sarah, I'll send over the deck by end of day. Let me know if the numbers on slide 4 look right to you.", "Slack", true),
            (-4000, "Remind me to book flights for the offsite and check if Jon can join the Thursday call.", "Notes", true),
            (-90000, "My top goals this week are:\n1. Finish the report\n2. Send the presentation\n3. Book the flights", "Notion", true),
            (-95000, "Thanks so much for the intro! Happy to find time next week — does Tuesday at 3 work?", "Mail", false),
        ]
        for (offset, text, app, ai) in samples {
            model.addHistory(DictationRecord(date: now.addingTimeInterval(offset), rawText: text, text: text, appName: app, appBundleID: app,
                                             audioDuration: Double(text.split(separator: " ").count) / 2.6, processingTime: 0.8, aiEdited: ai))
        }
        model.dictionary = [DictionaryEntry(word: "WhisperKit"), DictionaryEntry(word: "Siobhan", replacing: ["shivon"]), DictionaryEntry(word: "Qwen", autoLearned: true)]
        model.snippets = [Snippet(trigger: "my calendar link", expansion: "https://cal.com/gabriel/30min"), Snippet(trigger: "my address", expansion: "1 Infinite Loop, Cupertino, CA 95014")]
    }

    static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
        window.orderOut(nil)
    }
}
