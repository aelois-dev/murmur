import Carbon

/// When the 🌐 key is set to "Change Input Source", holding fn to dictate would also flip the keyboard layout.
/// This remembers the layout when fn goes down and puts it back after a dictation (a quick tap still switches).
final class InputSourceGuard {
    private var saved: TISInputSource?

    func remember() {
        saved = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    func restoreSoon() {
        guard let saved else { return }
        self.saved = nil
        for delay in [0.15, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
                if Self.id(current) != Self.id(saved) { TISSelectInputSource(saved) }
            }
        }
    }

    private static func id(_ source: TISInputSource) -> String {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
