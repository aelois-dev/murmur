import AppKit
import SwiftUI

/// Visual language inspired by Flow: warm cream surfaces, near-black ink, serif display type, lavender accents.
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let background = dynamic(light: 0xFAF8F3, dark: 0x161519)
    static let sidebar = dynamic(light: 0xF2EFE7, dark: 0x1C1B20)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x222127)
    static let cardHover = dynamic(light: 0xF6F3EC, dark: 0x29282F)
    static let border = dynamic(light: 0xE6E1D6, dark: 0x33313A)
    static let ink = dynamic(light: 0x1A1A1E, dark: 0xF2F0EB)
    static let secondary = dynamic(light: 0x6D6A72, dark: 0xA3A0AA)
    static let tertiary = dynamic(light: 0x9D99A1, dark: 0x75727C)
    static let accent = dynamic(light: 0x6F4FF2, dark: 0xA692FF)
    static let accentSoft = dynamic(light: 0xECE5FF, dark: 0x2C2641)
    static let accentBorder = dynamic(light: 0xC9B8FF, dark: 0x4B4170)
    static let selection = dynamic(light: 0xE8E3D8, dark: 0x2B2A31)
    static let success = dynamic(light: 0x2E9E5B, dark: 0x5ACB86)
    static let warning = dynamic(light: 0xC77A12, dark: 0xF0AE4B)
    static let danger = dynamic(light: 0xD4483B, dark: 0xFF7A6B)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func displayItalic(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif).italic() }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Rounded card container used across the hub.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Pill-shaped button in the Flow style (lavender primary, outlined secondary).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, dark, destructive }
    var kind: Kind = .primary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 6 : 8)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.ink
        case .secondary: Theme.ink
        case .dark: Theme.background
        case .destructive: Theme.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accentSoft
        case .secondary: Theme.card
        // Ink-colored: black in light mode, near-white in dark mode, so it always stands out.
        case .dark: Theme.ink
        case .destructive: Theme.card
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: Theme.accentBorder
        case .secondary: Theme.border
        case .dark: Color.clear
        case .destructive: Theme.border
        }
    }
}

/// A keycap glyph like the ones Flow uses to show shortcuts.
struct Keycap: View {
    var label: String
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .frame(minWidth: 26, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 0, x: 0, y: 1.5)
    }
}

/// Renders a shortcut like "fn + Space" as keycaps.
struct ShortcutLabel: View {
    var keys: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 { Text("+").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                Keycap(label: key)
            }
        }
    }
}
