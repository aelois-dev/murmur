import AppKit
import Combine
import MurmurCore
import SwiftUI

/// The floating pill at the bottom of the screen (Flow's "Flow Bar").
@MainActor
final class FlowBarController {
    private let panel: NSPanel
    private let model: AppModel
    private weak var controller: DictationController?
    private var cancellables: Set<AnyCancellable> = []
    private var hoverTimer: Timer?
    static let panelSize = NSSize(width: 420, height: 150)

    init(model: AppModel, controller: DictationController) {
        self.model = model
        self.controller = controller
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        let actions = FlowBarActions(
            click: { [weak controller] in controller?.barClicked() },
            stop: { [weak controller] in controller?.stopClicked() },
            cancel: { [weak controller] in controller?.cancelClicked() },
            notice: { [weak self] action in self?.handleNotice(action) }
        )
        let host = NSHostingView(rootView: FlowBarView(actions: actions).environmentObject(model))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        model.$phase.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &cancellables)
        model.$notice.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &cancellables)
        model.onFlowBarSettingsChanged = { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }

        // Poll the pointer so the panel only captures clicks over the pill itself; everything else passes through.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHover() }
        }
        refresh()
    }

    var shouldShow: Bool {
        model.settings.showFlowBarAlways || model.phase.isActive || model.notice != nil
    }

    func refresh() {
        if shouldShow {
            if !panel.isVisible || model.phase == .idle { reposition() }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private var currentScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    func reposition() {
        guard let screen = currentScreen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - Self.panelSize.width / 2, y: visible.minY + 4)
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
    }

    /// The pill's clickable rect in screen coordinates for the current state.
    private var interactiveRect: NSRect {
        let size = FlowBarView.pillSize(phase: model.phase, hovering: model.flowBarHovering, hasNotice: model.notice != nil)
        let frame = panel.frame
        let bottomInset = FlowBarView.bottomInset
        var rect = NSRect(x: frame.midX - size.width / 2, y: frame.minY + bottomInset, width: size.width, height: size.height)
        if model.notice != nil { rect = rect.union(NSRect(x: frame.midX - 170, y: frame.minY + bottomInset + size.height + 6, width: 340, height: 44)) }
        return rect.insetBy(dx: -8, dy: -8)
    }

    private func updateHover() {
        guard panel.isVisible else { return }
        let inside = NSMouseInRect(NSEvent.mouseLocation, interactiveRect, false)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        let hovering = inside && model.phase == .idle
        if model.flowBarHovering != hovering {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { model.flowBarHovering = hovering }
        }
    }

    private func handleNotice(_ action: FlowNotice.Action) {
        model.dismissNotice()
        switch action {
        case .undoCancel: controller?.undoCancel()
        case .openHistory:
            model.hubSection = .home
            NotificationCenter.default.post(name: .murmurShowHub, object: nil)
        case .openSettings:
            model.hubSection = .settings
            NotificationCenter.default.post(name: .murmurShowHub, object: nil)
        case .openAccessibility:
            Permissions.promptAccessibility()
            Permissions.openAccessibilitySettings()
        case .openMicrophone:
            Permissions.openMicrophoneSettings()
        case .paste:
            controller?.pasteLastTranscript()
        case .openDictionary:
            model.hubSection = .dictionary
            NotificationCenter.default.post(name: .murmurShowHub, object: nil)
        }
    }
}

struct FlowBarActions {
    var click: () -> Void
    var stop: () -> Void
    var cancel: () -> Void
    var notice: (FlowNotice.Action) -> Void
}

struct FlowBarView: View {
    @EnvironmentObject var model: AppModel
    var actions: FlowBarActions

    static let bottomInset: CGFloat = 10

    static func pillSize(phase: DictationPhase, hovering: Bool, hasNotice: Bool) -> CGSize {
        switch phase {
        case .idle: hovering ? CGSize(width: 64, height: 22) : CGSize(width: 40, height: 9)
        case .recording(.pushToTalk): CGSize(width: 104, height: 34)
        case .recording(.handsFree): CGSize(width: 150, height: 34)
        case .recording(.command): CGSize(width: 150, height: 34)
        case .processing: CGSize(width: 104, height: 34)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if let notice = model.notice {
                NoticeBubble(notice: notice, onAction: actions.notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.flowBarHovering && model.phase == .idle {
                Tooltip(text: tooltipText)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            pill
        }
        .padding(.bottom, Self.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: model.phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.notice?.id)
    }

    private var tooltipText: String {
        if !model.whisperStatus.isReady {
            if case .downloading(let p) = model.whisperStatus { return "Downloading speech model… \(Int(p * 100))%" }
            return "Getting ready…"
        }
        return "Click or hold \(model.settings.pushToTalkKey.shortLabel) to start dictating"
    }

    private var pill: some View {
        let size = Self.pillSize(phase: model.phase, hovering: model.flowBarHovering, hasNotice: model.notice != nil)
        return ZStack {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(model.phase == .idle && !model.flowBarHovering ? 0.55 : 0.92))
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(model.phase == .idle ? 0.35 : 0.18), lineWidth: 1)
            content
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(model.phase == .idle ? 0.12 : 0.28), radius: model.phase == .idle ? 3 : 10, y: 3)
        .contentShape(Capsule())
        .onTapGesture {
            if model.phase == .idle || model.phase == .recording(.handsFree) { actions.click() }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            if model.flowBarHovering {
                WaveformBars(levels: Array(repeating: 0.08, count: 7), color: .white.opacity(0.7), barWidth: 2.5, spacing: 3, maxHeight: 10)
                    .transition(.opacity)
            }
        case .recording(.pushToTalk):
            WaveformBars(levels: model.levels, color: .white, barWidth: 3, spacing: 3, maxHeight: 20)
                .transition(.opacity)
        case .recording(.handsFree):
            HStack(spacing: 8) {
                CircleButton(symbol: "xmark", background: Color.white.opacity(0.14), foreground: .white, action: actions.cancel)
                WaveformBars(levels: Array(model.levels.suffix(11)), color: .white, barWidth: 3, spacing: 2.5, maxHeight: 18)
                CircleButton(symbol: "stop.fill", background: Color(red: 1, green: 0.27, blue: 0.23), foreground: .white, action: actions.stop)
            }
            .padding(.horizontal, 5)
        case .recording(.command):
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.78, green: 0.7, blue: 1))
                WaveformBars(levels: Array(model.levels.suffix(11)), color: Color(red: 0.8, green: 0.73, blue: 1), barWidth: 3, spacing: 2.5, maxHeight: 18)
            }
        case .processing(let mode):
            ProcessingDots(tint: mode == .command ? Color(red: 0.8, green: 0.73, blue: 1) : .white)
        }
    }
}

struct WaveformBars: View {
    var levels: [CGFloat]
    var color: Color
    var barWidth: CGFloat
    var spacing: CGFloat
    var maxHeight: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                // Taper towards the edges so the shape reads like a voice waveform.
                let position = Double(index) / Double(max(1, levels.count - 1))
                let taper = 0.55 + 0.45 * sin(position * .pi)
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: max(barWidth, maxHeight * min(1, level * taper * 1.25 + 0.04)))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}

struct ProcessingDots: View {
    var tint: Color
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                    .opacity(animate ? 1 : 0.35)
                    .offset(y: animate ? -2.5 : 0)
                    .animation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true).delay(Double(i) * 0.14), value: animate)
            }
        }
        .onAppear { animate = true }
    }
}

struct CircleButton: View {
    var symbol: String
    var background: Color
    var foreground: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .background(Circle().fill(background.opacity(hovering ? 1 : 0.9)))
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Tooltip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.88)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

struct NoticeBubble: View {
    var notice: FlowNotice
    var onAction: (FlowNotice.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if notice.kind == .error {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
            } else if notice.kind == .success {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.55))
            }
            Text(notice.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            ForEach(Array(notice.actions.enumerated()), id: \.offset) { _, item in
                Button(item.title) { onAction(item.action) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.8, green: 0.73, blue: 1))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.black.opacity(0.9)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .fixedSize()
    }
}
