import AppKit
import MurmurCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page {
            HStack(alignment: .center, spacing: 16) {
                Text("Welcome back, \(model.firstName)")
                    .font(Theme.display(32))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 12)
                StatsRow(stats: model.stats)
            }

            HeroCard()

            HistorySection()
        }
    }
}

struct StatsRow: View {
    var stats: UsageStats

    var body: some View {
        HStack(spacing: 8) {
            StatPill(icon: "flame.fill", tint: Color(red: 0.95, green: 0.45, blue: 0.2), value: "\(stats.dayStreak)", unit: stats.dayStreak == 1 ? "day" : "days")
            StatPill(icon: "text.word.spacing", tint: Theme.accent, value: Self.compact(stats.totalWords), unit: "words")
            StatPill(icon: "bolt.fill", tint: Color(red: 0.95, green: 0.7, blue: 0.1), value: "\(stats.averageWPM)", unit: "WPM")
        }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: n < 10_000 ? "%.1fK" : "%.0fK", Double(n) / 1000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}

struct StatPill: View {
    var icon: String
    var tint: Color
    var value: String
    var unit: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Text(unit).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

/// The big card at the top of Home: how to dictate, or what's left to set up.
struct HeroCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let key = model.settings.pushToTalkKey
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    Text("Hold ").font(Theme.display(26))
                    Text(key.shortLabel).font(Theme.displayItalic(26))
                    Text(" to dictate in any app").font(Theme.display(26))
                }
                Text("Speak naturally, then release. Murmur removes filler words, fixes punctuation and types it wherever your cursor is — privately, on this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    ShortcutHint(keys: [key.shortLabel], label: "Hold to talk")
                    ShortcutHint(keys: model.settings.handsFreeWithSpace ? [key.shortLabel, "Space"] : [key.shortLabel, key.shortLabel], label: "Hands-free")
                    if model.settings.commandModeEnabled {
                        ShortcutHint(keys: key.commandModifierLabel.components(separatedBy: " + "), label: "Command")
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            FlowBarIllustration()
        }
        .padding(26)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accentSoft, Theme.card], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.accentBorder.opacity(0.6)))
    }
}

struct ShortcutHint: View {
    var keys: [String]
    var label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ShortcutLabel(keys: keys)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }
}

/// A live-looking Flow bar mock that animates gently.
struct FlowBarIllustration: View {
    static func level(index: Int, time t: Double) -> CGFloat {
        let x = Double(index)
        let wave: Double = abs(sin(t * 2.2 + x * 0.7))
        let swell: Double = 0.6 + 0.4 * sin(t * 0.9 + x)
        return CGFloat(0.25 + 0.55 * wave * swell)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let levels: [CGFloat] = (0..<13).map { Self.level(index: $0, time: t) }
            ZStack {
                Capsule().fill(Color.black.opacity(0.92))
                Capsule().strokeBorder(Color.white.opacity(0.18))
                WaveformBars(levels: levels, color: .white, barWidth: 3, spacing: 3, maxHeight: 22)
            }
            .frame(width: 118, height: 38)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .frame(width: 150)
    }
}

struct HistorySection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let filtered = model.historySearch.isEmpty ? model.history : model.history.filter {
            $0.text.localizedCaseInsensitiveContains(model.historySearch) || ($0.appName ?? "").localizedCaseInsensitiveContains(model.historySearch)
        }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("History").font(.system(size: 15, weight: .semibold))
                Spacer()
                SearchField(text: $model.historySearch, placeholder: "Search transcripts")
                    .frame(width: 220)
            }
            if model.history.isEmpty {
                EmptyHistory()
            } else if filtered.isEmpty {
                Text("No transcripts match “\(model.historySearch)”.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .padding(.vertical, 20)
            } else {
                ForEach(HistoryGrouping.sections(Array(filtered.sorted { $0.date > $1.date }.prefix(300))), id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.tertiary)
                        VStack(spacing: 0) {
                            ForEach(Array(section.records.enumerated()), id: \.element.id) { index, record in
                                if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                                HistoryRow(record: record)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }
}

struct EmptyHistory: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("Your dictations will appear here")
                .font(.system(size: 14, weight: .semibold))
            Text("Click into any text box, hold \(model.settings.pushToTalkKey.shortLabel) and start talking.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    var record: DictationRecord
    @State private var hovering = false
    @State private var copied = false
    @State private var expanded = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(Self.timeFormatter.string(from: record.date))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                if record.mode == .command {
                    Label("Command · “\(record.rawText)”", systemImage: "wand.and.stars")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                Text(record.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let app = record.appName { Text(app) }
                    if record.aiEdited { Text("·"); Text("AI edited") }
                    if record.insertionFailed { Text("·"); Text("Copied to clipboard") }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                RowIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                RowIconButton(symbol: "trash", help: "Delete") { model.deleteHistory(record.id) }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(hovering ? Theme.cardHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { expanded.toggle() }
    }
}

struct RowIconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Theme.ink : Theme.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.selection : Color.clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}
