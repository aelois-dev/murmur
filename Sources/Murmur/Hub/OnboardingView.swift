import AppKit
import MurmurCore
import MurmurEngine
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    var onFinish: () -> Void
    var initialStep = 0
    @State private var step = 0
    @State private var practice = ""
    @State private var globeUsage = Permissions.globeKeyUsage

    private let steps = ["Welcome", "Permissions", "Shortcut", "Models", "Try it"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Theme.ink : Theme.border)
                        .frame(width: i == step ? 26 : 8, height: 6)
                }
            }
            .padding(.top, 34)
            .animation(.spring(response: 0.3), value: step)

            ZStack {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: shortcut
                case 3: models
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 60)
            .transition(.opacity)

            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Spacer()
                if step < steps.count - 1 {
                    Button(step == 0 ? "Get started" : "Continue") { withAnimation { step += 1 } }
                        .buttonStyle(PillButtonStyle(kind: .dark))
                } else {
                    Button("Finish") { onFinish() }.buttonStyle(PillButtonStyle(kind: .dark))
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .frame(width: 760, height: 560)
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.refreshPermissions()
            let usage = Permissions.globeKeyUsage
            if usage != globeUsage { globeUsage = usage }
        }
        .onAppear { step = initialStep }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            LogoMark(size: 64)
            (Text("Don't type, ").font(Theme.display(44)) + Text("just speak").font(Theme.displayItalic(44)))
                .multilineTextAlignment(.center)
            Text("Murmur turns your voice into clean, polished text in any app. Hold a key, talk naturally, and release — your words appear where your cursor is.\nEverything runs privately on this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            FlowBarIllustration().padding(.top, 12)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Give Murmur two permissions").font(Theme.display(32))
            Text("These let Murmur hear you and type for you. You can change them anytime in System Settings.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            PermissionRow(icon: "mic.fill", title: "Microphone", detail: "So Murmur can hear you while you dictate.", granted: model.micAuthorized) {
                model.requestMicrophone()
            }
            PermissionRow(icon: "accessibility", title: "Accessibility", detail: "So your shortcut works in every app and text can be pasted where your cursor is. Turn on Murmur in the list that opens.", granted: model.accessibilityTrusted) {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
        }
        .frame(maxWidth: 560)
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your dictation key").font(Theme.display(32))
            Text("Hold it to talk, release to insert. Double-tap it (or add Space) for hands-free.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            Card {
                HStack {
                    Text("Push to talk").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Picker("", selection: $model.settings.pushToTalkKey) {
                        ForEach(HotkeyChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
            if model.settings.pushToTalkKey == .fn {
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: globeUsage == 0 ? "checkmark.circle.fill" : "globe")
                            .font(.system(size: 20))
                            .foregroundStyle(globeUsage == 0 ? Theme.success : Theme.warning)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(globeUsage == 0 ? "The 🌐 key is ready" : "Set the 🌐 key to “Do Nothing”")
                                .font(.system(size: 13, weight: .semibold))
                            Text(globeUsage == 0 ? "Pressing fn won't open anything else." : globeUsage == 1
                                 ? "Right now fn also switches input source. Murmur switches it back after each dictation, and a quick tap still switches as usual — but for the smoothest experience set “Press 🌐 key to” → “Do Nothing” (switch sources with ⌃Space), or pick another key above."
                                 : "Right now fn also triggers “\(Permissions.globeKeyDescription)”, which will get in the way. In Keyboard settings, set “Press 🌐 key to” → “Do Nothing”, or pick another key above.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if globeUsage != 0 {
                            Button("Open Keyboard Settings") { Permissions.openKeyboardSettings() }
                                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 580)
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("On-device models").font(Theme.display(32))
            Text("Murmur transcribes and edits on your Mac, so your voice never leaves it. The first download takes a minute.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Speech recognition").font(.system(size: 13, weight: .semibold))
                        Text(ModelCatalog.whisper(model.settings.whisperModel).map { "\($0.title) · \($0.sizeLabel)" } ?? "").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    ModelStatusLine(status: model.whisperStatus, detail: nil)
                    if case .failed = model.whisperStatus {
                        Button("Retry") { model.loadWhisper() }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    }
                }
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI editing (optional)").font(.system(size: 13, weight: .semibold))
                        Text(ModelCatalog.llm(model.settings.llmModel).map { "\($0.title) · \(ByteCountFormatter.string(fromByteCount: $0.sizeBytes, countStyle: .file))" } ?? "")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    ModelStatusLine(status: model.llmStatus, detail: nil)
                    if let info = ModelCatalog.llm(model.settings.llmModel), !info.isDownloaded, model.llmStatus == .notDownloaded {
                        Button("Download") { model.downloadLLM(info) }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    }
                }
            }
        }
        .frame(maxWidth: 580)
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it").font(Theme.display(32))
            HStack(spacing: 6) {
                Text("Click the box, hold").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Keycap(label: model.settings.pushToTalkKey.shortLabel)
                Text("and say something like “Hey, this is my first message with Murmur.”").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            TextEditor(text: $practice)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(practice.isEmpty ? Theme.border : Theme.accent, lineWidth: practice.isEmpty ? 1 : 2))
            if !practice.isEmpty {
                Label("Nice — that's all there is to it.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.success)
            } else if !model.accessibilityTrusted {
                Label("Turn on Accessibility for Murmur to use the shortcut.", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }
        }
        .frame(maxWidth: 580)
    }
}

struct PermissionRow: View {
    var icon: String
    var title: String
    var detail: String
    var granted: Bool
    var action: () -> Void

    var body: some View {
        Card(padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.accentSoft))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if granted {
                    StatusBadge(ok: true, text: "Allowed")
                } else {
                    Button("Allow", action: action).buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                }
            }
        }
    }
}
