import AppKit
import MurmurCore
import SwiftUI

struct HubView: View {
    @EnvironmentObject var model: AppModel
    var controller: DictationController?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 216)
            Rectangle().fill(Theme.border).frame(width: 1)
            ZStack {
                Theme.background
                content
                    .id(model.hubSection)
                    .transition(.opacity)
            }
        }
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        .frame(minWidth: 820, minHeight: 560)
        .ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        switch model.hubSection {
        case .home: HomeView()
        case .dictionary: DictionaryView()
        case .snippets: SnippetsView()
        case .style: StyleView()
        case .settings: SettingsView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                LogoMark(size: 22)
                Text("Murmur").font(Theme.display(22))
            }
            .padding(.horizontal, 14)
            .padding(.top, 46)
            .padding(.bottom, 22)

            ForEach([HubSection.home, .dictionary, .snippets, .style]) { section in
                SidebarItem(section: section, selected: model.hubSection == section) { model.hubSection = section }
            }

            Spacer()

            ReadinessCard()
                .padding(.bottom, 8)

            SidebarItem(section: .settings, selected: model.hubSection == .settings) { model.hubSection = .settings }
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }
}

struct SidebarItem: View {
    var section: HubSection
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(selected ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small status card at the bottom of the sidebar: what's left to set up, or the shortcut reminder.
struct ReadinessCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.accessibilityTrusted || !model.micAuthorized {
                Label("Finish setup", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                Text(!model.micAuthorized ? "Allow microphone access to start dictating." : "Allow Accessibility so Murmur can hear your shortcut and paste text.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open settings") { model.hubSection = .settings }
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            } else {
                switch model.whisperStatus {
                case .ready:
                    HStack(spacing: 6) {
                        Circle().fill(Theme.success).frame(width: 7, height: 7)
                        Text("Ready").font(.system(size: 12, weight: .semibold))
                    }
                    HStack(spacing: 4) {
                        Text("Hold").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Keycap(label: model.settings.pushToTalkKey.shortLabel).scaleEffect(0.85)
                        Text("to dictate").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                case .downloading(let p):
                    Text("Downloading speech model").font(.system(size: 12, weight: .semibold))
                    ProgressView(value: p).tint(Theme.accent)
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Preparing speech model…").font(.system(size: 11, weight: .medium))
                    }
                    Text("First launch can take a minute.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                case .notDownloaded, .failed:
                    Text(model.whisperStatus.label).font(.system(size: 12, weight: .semibold))
                    Button("Download") { model.loadWhisper() }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Murmur's mark: five rounded bars inside a soft lavender tile.
struct LogoMark: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x1A1A1E)), Color(nsColor: NSColor(hex: 0x3A2F6B))], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: size * 0.07) {
                ForEach([0.3, 0.55, 0.8, 0.5, 0.3], id: \.self) { h in
                    Capsule().fill(Color.white).frame(width: size * 0.09, height: size * h)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Section header used at the top of every hub page.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.display(32))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = EmptyView()
    }
}

/// Scrollable page scaffold with consistent padding and max width.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 40)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}
