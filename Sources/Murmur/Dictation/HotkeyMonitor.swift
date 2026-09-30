import AppKit
import Carbon.HIToolbox
import MurmurCore

/// Listens for the dictation shortcuts system-wide with a CGEvent tap (needs Accessibility permission).
final class HotkeyMonitor {
    enum Signal {
        case pttDown, pttUp, handsFree, commandModifier, escape, otherKey, pasteLast
    }

    /// Returns true if the key event should be swallowed.
    var handler: ((Signal) -> Bool)?
    /// Whether a dictation is active (so Esc/Space are ours to swallow).
    var isRecording: () -> Bool = { false }

    var hotkey: HotkeyChoice = .fn
    var handsFreeWithSpace = true
    var commandModeEnabled = true

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pttDown = false
    private var commandSent = false
    private var swallowNextSpaceUp = false
    private var swallowNextEscapeUp = false

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.write("Event tap unavailable (Accessibility permission missing?)")
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("Hotkey monitor started (\(hotkey.rawValue))")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        pttDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            handleFlags(event)
            return Unmanaged.passUnretained(event)
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == kVK_Space && swallowNextSpaceUp { swallowNextSpaceUp = false; return nil }
            if keyCode == kVK_Escape && swallowNextEscapeUp { swallowNextEscapeUp = false; return nil }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlags(_ event: CGEvent) {
        let flags = event.flags
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isDown: Bool
        switch hotkey {
        case .fn:
            // Only the fn/Globe key itself counts: arrow and function keys also carry the "secondary fn" flag.
            guard keyCode == kVK_Function else { return checkCommandModifier(flags) }
            isDown = flags.contains(.maskSecondaryFn)
        case .rightOption, .rightCommand, .rightControl:
            // Device-dependent bits tell the right-hand modifier apart from the left one.
            let bit: UInt64 = hotkey == .rightOption ? 0x40 : (hotkey == .rightCommand ? 0x10 : 0x2000)
            let down = flags.rawValue & bit != 0
            guard down != pttDown else { return checkCommandModifier(flags) }
            isDown = down
        case .controlOption:
            let both = flags.contains(.maskControl) && flags.contains(.maskAlternate)
            if pttDown {
                if both { return checkCommandModifier(flags) }
                isDown = false
            } else {
                isDown = both && !flags.contains(.maskShift) && !flags.contains(.maskCommand)
            }
        }

        if isDown && !pttDown {
            pttDown = true
            commandSent = false
            _ = handler?(.pttDown)
            checkCommandModifier(flags)
        } else if !isDown && pttDown {
            pttDown = false
            commandSent = false
            _ = handler?(.pttUp)
        }
    }

    private func checkCommandModifier(_ flags: CGEventFlags) {
        guard pttDown, commandModeEnabled, !commandSent else { return }
        let commandFlag: CGEventFlags
        switch hotkey {
        case .fn, .rightOption, .rightCommand: commandFlag = .maskControl
        case .controlOption: commandFlag = .maskCommand
        case .rightControl: commandFlag = .maskAlternate
        }
        if flags.contains(commandFlag) {
            commandSent = true
            _ = handler?(.commandModifier)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if keyCode == kVK_Escape && isRecording() {
            if !isRepeat { _ = handler?(.escape) }
            swallowNextEscapeUp = true
            return nil
        }
        // ⌃⌘V pastes the last transcript (like Flow).
        if keyCode == kVK_ANSI_V && !isRepeat && event.flags.contains(.maskControl) && event.flags.contains(.maskCommand)
            && !event.flags.contains(.maskAlternate) && !event.flags.contains(.maskShift) {
            if handler?(.pasteLast) == true { return nil }
        }
        if pttDown {
            if keyCode == kVK_Space && handsFreeWithSpace {
                if !isRepeat { _ = handler?(.handsFree) }
                swallowNextSpaceUp = true
                return nil
            }
            if !isRepeat { _ = handler?(.otherKey) }
        }
        return Unmanaged.passUnretained(event)
    }
}
