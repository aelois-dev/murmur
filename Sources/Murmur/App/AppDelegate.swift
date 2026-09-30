import AppKit
import Combine
import MurmurCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = AppModel.shared
    private(set) var controller: DictationController!
    private var flowBar: FlowBarController?
    private var statusItem: NSStatusItem?
    private var hubWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").first(where: { $0 != .current }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        Log.write("Murmur \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") launched")
        buildMainMenu()
        controller = DictationController(model: model)
        controller.start()
        flowBar = FlowBarController(model: model, controller: controller)
        setupStatusItem()
        model.loadModels()

        NotificationCenter.default.addObserver(forName: .murmurShowHub, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showHub() }
        }
        NotificationCenter.default.addObserver(forName: .murmurDockPolicyChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateActivationPolicy() }
        }
        model.$phase.combineLatest(model.$whisperStatus).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusIcon() }
        }.store(in: &cancellables)

        if let i = CommandLine.arguments.firstIndex(of: "--e2e"), i + 1 < CommandLine.arguments.count {
            EndToEndTest.run(audioDirectory: URL(fileURLWithPath: CommandLine.arguments[i + 1]), model: model, controller: controller)
        } else if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            SelfTest.run(casesPath: CommandLine.arguments[i + 1], model: model, controller: controller)
        } else if ProcessInfo.processInfo.environment["MURMUR_NO_WINDOW"] != nil {
            updateActivationPolicy()
        } else if model.settings.hasCompletedOnboarding {
            showHub()
        } else {
            showOnboarding()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHub()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        SystemAudio.muteOutput(false)
    }

    // MARK: - Windows

    func showHub() {
        if hubWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 690),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Murmur"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 560)
            window.backgroundColor = NSColor(Theme.background)
            window.contentView = NSHostingView(rootView: HubView(controller: controller).environmentObject(model))
            window.center()
            window.setFrameAutosaveName("MurmurHub")
            window.delegate = self
            hubWindow = window
        }
        updateActivationPolicy(forceRegular: true)
        hubWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(Theme.background)
            window.contentView = NSHostingView(rootView: OnboardingView(onFinish: { [weak self] in self?.finishOnboarding() }).environmentObject(model))
            window.center()
            window.delegate = self
            onboardingWindow = window
        }
        updateActivationPolicy(forceRegular: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishOnboarding() {
        model.settings.hasCompletedOnboarding = true
        onboardingWindow?.close()
        onboardingWindow = nil
        showHub()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { self.updateActivationPolicy() }
    }

    private func updateActivationPolicy(forceRegular: Bool = false) {
        let anyWindow = (hubWindow?.isVisible ?? false) || (onboardingWindow?.isVisible ?? false)
        // "Show in Dock" keeps the icon; otherwise it only appears while a Murmur window is open.
        let regular = model.settings.showInDock || forceRegular || anyWindow
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.image(active: false)
        item.button?.toolTip = "Murmur"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = StatusIcon.image(active: model.phase.isActive)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let key = model.settings.pushToTalkKey.shortLabel
        let status: String
        switch model.whisperStatus {
        case .ready: status = model.accessibilityTrusted ? "Ready — hold \(key) to dictate" : "Needs Accessibility access to use shortcuts"
        case .downloading(let p): status = "Downloading speech model… \(Int(p * 100))%"
        case .loading: status = "Preparing speech model…"
        case .notDownloaded: status = "Speech model not downloaded"
        case .failed(let m): status = m
        }
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        if !model.accessibilityTrusted {
            menu.addItem(item("Grant Accessibility Access…", #selector(grantAccessibility)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Murmur", #selector(openHub), key: "o"))
        menu.addItem(item(model.phase.isActive ? "Stop Dictation" : "Start Hands-Free Dictation", #selector(toggleHandsFree)))
        let paste = item("Paste Last Transcript (⌃⌘V)", #selector(pasteLast))
        paste.isEnabled = model.lastTranscript != nil
        menu.addItem(paste)
        let copy = item("Copy Last Transcript", #selector(copyLast))
        copy.isEnabled = model.lastTranscript != nil
        menu.addItem(copy)
        menu.addItem(.separator())

        let micMenu = NSMenu()
        let auto = NSMenuItem(title: "System Default\(AudioInputDevice.defaultInputName.map { " (\($0))" } ?? "")", action: #selector(selectMic(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = nil
        auto.state = model.settings.microphoneUID == nil ? .on : .off
        micMenu.addItem(auto)
        for device in AudioInputDevice.all() {
            let m = NSMenuItem(title: device.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = device.uid
            m.state = model.settings.microphoneUID == device.uid ? .on : .off
            micMenu.addItem(m)
        }
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu
        menu.addItem(micItem)

        let langMenu = NSMenu()
        let autoLang = NSMenuItem(title: "Auto-detect", action: #selector(selectLanguage(_:)), keyEquivalent: "")
        autoLang.target = self
        autoLang.state = model.settings.language == nil ? .on : .off
        langMenu.addItem(autoLang)
        for lang in SupportedLanguages.all {
            let l = NSMenuItem(title: lang.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            l.target = self
            l.representedObject = lang.code
            l.state = model.settings.language == lang.code ? .on : .off
            langMenu.addItem(l)
        }
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Murmur", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openHub() { model.hubSection = .home; showHub() }
    @objc private func openSettings() { model.hubSection = .settings; showHub() }
    @objc private func toggleHandsFree() { controller.toggleHandsFree() }
    @objc private func pasteLast() { controller.pasteLastTranscript() }
    @objc private func copyLast() {
        guard let text = model.lastTranscript?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func grantAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
    }
    @objc private func selectMic(_ sender: NSMenuItem) { model.settings.microphoneUID = sender.representedObject as? String }
    @objc private func selectLanguage(_ sender: NSMenuItem) { model.settings.language = sender.representedObject as? String }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Main menu (for ⌘Q, ⌘W, copy/paste in text fields)

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Murmur", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Murmur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}

/// Menu bar glyph: a small waveform, filled when dictating.
enum StatusIcon {
    static func image(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let heights: [CGFloat] = active ? [6, 12, 16, 10, 6] : [5, 9, 13, 9, 5]
            let barWidth: CGFloat = 2.2
            let spacing: CGFloat = 1.4
            let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
            var x = (rect.width - total) / 2
            NSColor.black.setFill()
            for h in heights {
                let bar = NSRect(x: x, y: (rect.height - h) / 2, width: barWidth, height: h)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
