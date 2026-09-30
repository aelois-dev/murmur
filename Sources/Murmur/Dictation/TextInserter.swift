import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text into whichever app is focused, the way Flow does: briefly via the clipboard, then restores it.
enum TextInserter {
    struct FocusInfo {
        var precedingCharacter: Character?
        var selectedText: String?
        var isTextInput: Bool
    }

    /// Inspects the focused UI element through Accessibility (best-effort; many apps expose nothing).
    static func focusInfo() -> FocusInfo {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else {
            return FocusInfo(precedingCharacter: nil, selectedText: nil, isTextInput: false)
        }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleString = role as? String ?? ""
        let isText = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"].contains(roleString)

        var selected: CFTypeRef?
        var selectedText: String?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success, let s = selected as? String, !s.isEmpty {
            selectedText = s
        }

        var preceding: Character?
        var rangeValue: CFTypeRef?
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let text = value as? String, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location > 0 {
                let ns = text as NSString
                if range.location <= ns.length {
                    let prev = ns.substring(with: NSRange(location: range.location - 1, length: 1))
                    preceding = prev.first
                }
            }
        }
        return FocusInfo(precedingCharacter: preceding, selectedText: selectedText, isTextInput: isText)
    }

    /// Adds a leading space when continuing after a word, like Flow's smart spacing.
    static func adjustForContext(_ text: String, preceding: Character?) -> String {
        guard let preceding, let first = text.first else { return text }
        if preceding.isWhitespace || preceding.isNewline { return text }
        if "([{\"'“‘/-@#".contains(preceding) { return text }
        if first.isLetter || first.isNumber || "“\"(".contains(first) { return " " + text }
        return text
    }

    /// Pastes text into the focused app. Returns false if we couldn't (text is then left on the clipboard).
    @discardableResult
    static func insert(_ text: String, keepInClipboard: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = keepInClipboard ? [] : snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Hint to clipboard managers that this is transient.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCount = pasteboard.changeCount

        guard AXIsProcessTrusted() else { return false }
        postKey(kVK_ANSI_V, flags: .maskCommand)

        if !keepInClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Only restore if nothing else touched the clipboard in the meantime.
                guard pasteboard.changeCount == changeCount else { return }
                restore(saved, to: pasteboard)
            }
        }
        return true
    }

    /// Copies the current selection with ⌘C (for apps that don't expose it via Accessibility).
    static func copySelection(timeout: TimeInterval = 0.25) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        postKey(kVK_ANSI_C, flags: .maskCommand)
        let deadline = Date().addingTimeInterval(timeout)
        while pasteboard.changeCount == before && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let copied = pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
        restore(saved, to: pasteboard)
        return copied
    }

    static func postKey(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { entry[type] = data } }
            return entry
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

/// The app the user is dictating into, captured when recording starts.
struct TargetApp {
    var name: String?
    var bundleID: String?
    var pid: pid_t?

    static func current() -> TargetApp {
        let app = NSWorkspace.shared.frontmostApplication
        return TargetApp(name: app?.localizedName, bundleID: app?.bundleIdentifier, pid: app?.processIdentifier)
    }
}
