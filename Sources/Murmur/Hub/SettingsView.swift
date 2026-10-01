import AppKit
import MurmurCore
import MurmurEngine
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false
    @State private var globeUsage = Permissions.globeKeyUsage

    var body: some View {
        Page {
            PageHeader(title: "Settings")

            SettingsSection(title: "Shortcuts") {
                SettingsRow(title: "Push to talk", detail: "Hold to dictate, release to insert.") {
                    Picker("", selection: $model.settings.pushToTalkKey) {
                        ForEach(HotkeyChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                SettingsRow(title: "Hands-free", detail: "Keep recording without holding a key. Tap \(model.settings.pushToTalkKey.shortLabel) again, or click ■, to finish.") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Toggle("Double-tap \(model.settings.pushToTalkKey.shortLabel)", isOn: $model.settings.doubleTapForHandsFree)
                        Toggle("\(model.settings.pushToTalkKey.shortLabel) + Space", isOn: $model.settings.handsFreeWithSpace)
                    }
                    .toggleStyle(.checkbox)
                }
                SettingsRow(title: "Command Mode", detail: "Select text, hold \(model.settings.pushToTalkKey.commandModifierLabel) and say what to change — “make this more concise”, “translate to Spanish”.") {
                    Toggle("", isOn: $model.settings.commandModeEnabled).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                SettingsRow(title: "Paste last transcript", detail: "Inserts your most recent dictation again.") {
                    ShortcutLabel(keys: ["⌃", "⌘", "V"])
                }
                if model.settings.pushToTalkKey == .fn {
                    SettingsRow(title: "Globe key", detail: globeUsage == 0 ? "Set to “Do Nothing” — perfect." : "Currently set to “\(Permissions.globeKeyDescription)”. Set “Press 🌐 key to” to “Do Nothing” in Keyboard settings so fn doesn't also open that.") {
                        if globeUsage == 0 {
                            StatusBadge(ok: true, text: "Good")
                        } else {
                            Button("Keyboard Settings") { Permissions.openKeyboardSettings() }.buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                        }
                    }
                }
            }

            SettingsSection(title: "Microphone & sounds") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Microphone").font(.system(size: 13, weight: .medium))
                    MicTestView(autoStart: false)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                SettingsRow(title: "Keep microphone ready", detail: "Bluetooth headphones like AirPods take about a second to switch their mic on, which can cut off your first words. Keeping it ready makes dictation start instantly — but while it's ready, AirPods play audio in lower \"call\" quality and the orange mic indicator stays on. Automatic keeps Bluetooth mics ready for a minute after you dictate.") {
                    Picker("", selection: $model.settings.micReadiness) {
                        ForEach(MicReadiness.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                SettingsRow(title: "Sound effects", detail: "A chime when the mic is listening, and another when dictation stops. With AirPods, wait for the chime before you speak.") {
                    HStack(spacing: 10) {
                        if model.settings.soundEffects {
                            Slider(value: $model.settings.soundVolume, in: 0.05...1) { editing in
                                if !editing { Sounds.shared.play(.start, volume: model.settings.soundVolume) }
                            }
                            .frame(width: 110)
                        }
                        Toggle("", isOn: $model.settings.soundEffects).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                    }
                }
                SettingsRow(title: "Mute audio while dictating", detail: "Silences music and videos while you talk, then restores them.") {
                    Toggle("", isOn: $model.settings.pauseMediaWhileDictating).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
            }

            SettingsSection(title: "Transcription") {
                SettingsRow(title: "Language", detail: "Auto-detect works for 100+ languages; picking yours is a little faster and more accurate.") {
                    Picker("", selection: $model.settings.language) {
                        Text("Auto-detect").tag(String?.none)
                        ForEach(SupportedLanguages.all, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsRow(title: "Speech model", detail: "Runs on this Mac's Neural Engine. Nothing is sent anywhere.") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Picker("", selection: $model.settings.whisperModel) {
                            ForEach(ModelCatalog.whisperModels) { m in
                                Text("\(m.title) · \(m.sizeLabel)").tag(m.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        ModelStatusLine(status: model.whisperStatus, detail: ModelCatalog.whisper(model.settings.whisperModel)?.detail)
                    }
                }
                SettingsRow(title: "Smart formatting", detail: "Punctuation by name, numbered lists and backtrack (“at 2… actually 3”).") {
                    Toggle("", isOn: $model.settings.smartFormatting).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
            }

            SettingsSection(title: "AI editing") {
                SettingsRow(title: "AI auto-edits", detail: "An on-device language model removes filler words and false starts and applies your corrections, like an editor that never changes what you meant.") {
                    Toggle("", isOn: $model.settings.aiEditing).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                SettingsRow(title: "AI model", detail: "Also powers Command Mode.") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Picker("", selection: $model.settings.llmModel) {
                            ForEach(ModelCatalog.llmModels) { m in
                                Text("\(m.title) · \(ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file))").tag(m.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        HStack(spacing: 8) {
                            ModelStatusLine(status: model.llmStatus, detail: ModelCatalog.llm(model.settings.llmModel)?.detail)
                            if let info = ModelCatalog.llm(model.settings.llmModel), !info.isDownloaded, !isDownloading(model.llmStatus) {
                                Button("Download") { model.downloadLLM(info) }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                            }
                        }
                    }
                }
                SettingsRow(title: "Context awareness", detail: "Uses the app you're in and the text just before your cursor to spell names right and continue sentences naturally. Stays on this Mac.") {
                    Toggle("", isOn: $model.settings.contextAwareness).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
            }

            SettingsSection(title: "System") {
                SettingsRow(title: "Launch at login", detail: nil) {
                    Toggle("", isOn: $model.settings.launchAtLogin).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                SettingsRow(title: "Show Flow bar at all times", detail: "A small pill at the bottom of your screen. Click it to start hands-free dictation.") {
                    Toggle("", isOn: $model.settings.showFlowBarAlways).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                SettingsRow(title: "Show in Dock", detail: "Murmur always lives in the menu bar.") {
                    Toggle("", isOn: $model.settings.showInDock).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                SettingsRow(title: "Keep transcript in clipboard", detail: "Leave the text on the clipboard after pasting instead of restoring what was there.") {
                    Toggle("", isOn: $model.settings.keepTranscriptInClipboard).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
            }

            SettingsSection(title: "Permissions") {
                SettingsRow(title: "Microphone", detail: "To hear you while you dictate.") {
                    if model.micAuthorized { StatusBadge(ok: true, text: "Allowed") } else {
                        Button("Allow") { model.requestMicrophone() }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    }
                }
                SettingsRow(title: "Accessibility", detail: model.accessibilityNeedsRegrant ? AppModel.regrantHelp : "To detect your shortcut in every app and paste text where your cursor is.") {
                    if model.accessibilityTrusted { StatusBadge(ok: true, text: "Allowed") } else {
                        Button("Open System Settings") {
                            Permissions.promptAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    }
                }
            }

            SettingsSection(title: "Data & privacy") {
                SettingsRow(title: "Keep history", detail: "Transcripts are stored only on this Mac.") {
                    Picker("", selection: $model.settings.historyRetention) {
                        ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsRow(title: "Delete all history", detail: "\(model.history.count) transcript\(model.history.count == 1 ? "" : "s") saved.") {
                    Button("Delete…") { confirmClear = true }
                        .buttonStyle(PillButtonStyle(kind: .destructive, compact: true))
                        .disabled(model.history.isEmpty)
                        .confirmationDialog("Delete all transcripts?", isPresented: $confirmClear) {
                            Button("Delete all history", role: .destructive) { model.clearHistory() }
                        } message: {
                            Text("This can't be undone.")
                        }
                }
                SettingsRow(title: "Data folder", detail: "Settings, history, dictionary and models.") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory]) }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }
            }

            HStack {
                LogoMark(size: 18)
                Text("Murmur \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · Speech by WhisperKit · Editing by llama.cpp")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .onAppear {
            model.refreshPermissions()
            globeUsage = Permissions.globeKeyUsage
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshPermissions()
            globeUsage = Permissions.globeKeyUsage
        }
    }

    private func isDownloading(_ status: ModelStatus) -> Bool {
        if case .downloading = status { return true }
        return false
    }
}

struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
            VStack(spacing: 0) {
                _VariadicView.Tree(DividedLayout()) { content }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        }
    }
}

/// Inserts hairline dividers between rows of a settings section.
struct DividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 16)
            }
        }
    }
}

struct SettingsRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

struct StatusBadge: View {
    var ok: Bool
    var text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ok ? Theme.success : Theme.warning)
    }
}

struct ModelStatusLine: View {
    var status: ModelStatus
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .ready:
                Circle().fill(Theme.success).frame(width: 6, height: 6)
                Text(["Ready", detail].compactMap { $0 }.joined(separator: " · "))
            case .downloading(let p):
                ProgressView(value: p).frame(width: 80).tint(Theme.accent)
                Text("\(Int(p * 100))%").monospacedDigit()
            case .loading:
                ProgressView().controlSize(.mini)
                Text("Preparing…")
            case .notDownloaded:
                Circle().fill(Theme.tertiary).frame(width: 6, height: 6)
                Text("Not downloaded")
            case .failed(let message):
                Circle().fill(Theme.danger).frame(width: 6, height: 6)
                Text(message)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
    }
}
