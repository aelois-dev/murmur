import Foundation

public enum RecordingMode: String, Sendable, Equatable {
    case pushToTalk, handsFree, command
}

/// Pure state machine behind the dictation shortcuts, matching Flow's behaviour:
/// - hold the key to talk, release to insert;
/// - double-tap the key (or press key + Space, or click the Flow bar) for hands-free, tap again to finish;
/// - key + Control for Command Mode;
/// - Esc or the ✕ button cancels; a very short tap is dismissed.
public struct HotkeyStateMachine: Sendable {
    public enum Event: Sendable, Equatable {
        case pttDown, pttUp
        case handsFreeShortcut
        case commandModifierDown
        case escape
        case barClicked, stopClicked, cancelClicked
        case tick
        case processingFinished
        /// Another key was pressed while the push-to-talk key was held (e.g. fn+arrow): not a dictation.
        case otherKeyPressed
    }

    public enum CancelReason: Sendable, Equatable {
        case tooShort, userCancelled, tripleTap
    }

    public enum Action: Sendable, Equatable {
        case startRecording(RecordingMode)
        case switchMode(RecordingMode)
        case stopAndProcess(RecordingMode)
        case cancel(CancelReason)
        case notice(String)
        case warnTimeLimit
    }

    public enum State: Sendable, Equatable {
        case idle
        case recording(mode: RecordingMode, startedAt: TimeInterval, lockedAt: TimeInterval?)
        /// Key released very quickly; still recording while we wait to see if it's a double-tap.
        case awaitingSecondTap(startedAt: TimeInterval, releasedAt: TimeInterval)
        case processing
    }

    public struct Timing: Sendable {
        public var shortTap: TimeInterval = 0.35
        public var doubleTapWindow: TimeInterval = 0.5
        public var cancelAfterLockWindow: TimeInterval = 0.5
        public var commandSwitchWindow: TimeInterval = 1.0
        public var minimumCommand: TimeInterval = 0.3
        public var warnAfter: TimeInterval = 19 * 60
        public var maxDuration: TimeInterval = 20 * 60
        public init() {}
    }

    public private(set) var state: State = .idle
    public var timing = Timing()
    public var doubleTapEnabled = true
    public var commandModeEnabled = true
    private var warned = false

    public init() {}

    public var isRecording: Bool {
        switch state {
        case .recording, .awaitingSecondTap: true
        default: false
        }
    }

    public var currentMode: RecordingMode? {
        switch state {
        case .recording(let mode, _, _): mode
        case .awaitingSecondTap: .pushToTalk
        default: nil
        }
    }

    public mutating func handle(_ event: Event, at now: TimeInterval) -> [Action] {
        switch (state, event) {
        // MARK: idle
        case (.idle, .pttDown):
            return start(.pushToTalk, at: now)
        case (.idle, .handsFreeShortcut), (.idle, .barClicked):
            return start(.handsFree, at: now, locked: true)
        case (.idle, _):
            return []

        // MARK: push-to-talk
        case (.recording(.pushToTalk, let started, _), .pttUp):
            let held = now - started
            if held < timing.shortTap {
                if doubleTapEnabled {
                    state = .awaitingSecondTap(startedAt: started, releasedAt: now)
                    return []
                }
                state = .idle
                return [.cancel(.tooShort)]
            }
            state = .processing
            return [.stopAndProcess(.pushToTalk)]
        case (.recording(.pushToTalk, let started, _), .handsFreeShortcut):
            state = .recording(mode: .handsFree, startedAt: started, lockedAt: now)
            return [.switchMode(.handsFree)]
        case (.recording(.pushToTalk, let started, _), .otherKeyPressed):
            guard now - started < 1.0 else { return [] }
            state = .idle
            return [.cancel(.tooShort)]
        case (.recording(.pushToTalk, let started, _), .commandModifierDown):
            guard commandModeEnabled, now - started < timing.commandSwitchWindow else { return [] }
            state = .recording(mode: .command, startedAt: started, lockedAt: nil)
            return [.switchMode(.command)]

        // MARK: waiting for a possible double-tap
        case (.awaitingSecondTap(let started, let released), .pttDown):
            if now - released <= timing.doubleTapWindow {
                state = .recording(mode: .handsFree, startedAt: started, lockedAt: now)
                return [.switchMode(.handsFree)]
            }
            // Too late to count as a double-tap: the first tap was a dismissal; start fresh.
            state = .idle
            return [.cancel(.tooShort)] + start(.pushToTalk, at: now)
        case (.awaitingSecondTap(let started, _), .handsFreeShortcut):
            state = .recording(mode: .handsFree, startedAt: started, lockedAt: now)
            return [.switchMode(.handsFree)]
        case (.awaitingSecondTap(_, let released), .tick):
            if now - released > timing.doubleTapWindow {
                state = .idle
                return [.cancel(.tooShort)]
            }
            return []
        case (.awaitingSecondTap, .otherKeyPressed):
            state = .idle
            return [.cancel(.tooShort)]
        case (.awaitingSecondTap, .escape), (.awaitingSecondTap, .cancelClicked):
            state = .idle
            return [.cancel(.userCancelled)]
        case (.awaitingSecondTap, _):
            return []

        // MARK: hands-free
        case (.recording(.handsFree, _, let locked), .pttDown),
             (.recording(.handsFree, _, let locked), .handsFreeShortcut):
            if let locked, now - locked < timing.cancelAfterLockWindow {
                state = .idle
                return [.cancel(.tripleTap)]
            }
            state = .processing
            return [.stopAndProcess(.handsFree)]
        case (.recording(.handsFree, _, _), .stopClicked), (.recording(.handsFree, _, _), .barClicked):
            state = .processing
            return [.stopAndProcess(.handsFree)]
        case (.recording(.handsFree, _, _), .pttUp):
            return []

        // MARK: command mode
        case (.recording(.command, let started, _), .pttUp):
            if now - started < timing.minimumCommand {
                state = .idle
                return [.cancel(.tooShort)]
            }
            state = .processing
            return [.stopAndProcess(.command)]

        // MARK: shared recording behaviour
        case (.recording, .escape), (.recording, .cancelClicked):
            state = .idle
            return [.cancel(.userCancelled)]
        case (.recording(let mode, let started, _), .tick):
            let elapsed = now - started
            if elapsed >= timing.maxDuration {
                state = .processing
                return [.stopAndProcess(mode)]
            }
            if elapsed >= timing.warnAfter && !warned {
                warned = true
                return [.warnTimeLimit]
            }
            return []
        case (.recording(let mode, _, _), .stopClicked):
            state = .processing
            return [.stopAndProcess(mode)]
        case (.recording, _):
            return []

        // MARK: processing
        case (.processing, .processingFinished):
            state = .idle
            return []
        case (.processing, .pttDown), (.processing, .handsFreeShortcut):
            return [.notice("Transcript currently processing")]
        case (.processing, _):
            return []
        }
    }

    /// Force the machine back to idle (e.g. after an error while recording).
    public mutating func reset() {
        state = .idle
        warned = false
    }

    private mutating func start(_ mode: RecordingMode, at now: TimeInterval, locked: Bool = false) -> [Action] {
        warned = false
        state = .recording(mode: mode, startedAt: now, lockedAt: locked ? now : nil)
        return [.startRecording(mode)]
    }
}
