import MurmurCore
import SwiftUI

// MARK: - Dictionary

struct DictionaryView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    @State private var word = ""
    @State private var misheard = ""
    @State private var search = ""

    var body: some View {
        Page {
            PageHeader(title: "Dictionary", subtitle: "Teach Murmur names, jargon and unusual spellings. They're used as hints for the speech model and corrected automatically.") {
                Button { withAnimation { adding = true } } label: { Label("Add new", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }

            if adding {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("New word").font(.system(size: 14, weight: .semibold))
                        FieldRow(label: "Word or phrase", placeholder: "e.g. Qwen, Kubernetes, Siobhan", text: $word)
                        FieldRow(label: "Often misheard as (optional)", placeholder: "e.g. queen, cue when — separate with commas", text: $misheard)
                        HStack {
                            Spacer()
                            Button("Cancel") { reset() }.buttonStyle(PillButtonStyle(kind: .secondary))
                            Button("Add word") {
                                let variants = misheard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                model.addWord(word, replacing: variants)
                                reset()
                            }
                            .buttonStyle(PillButtonStyle(kind: .dark))
                            .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                Toggle("", isOn: $model.settings.autoLearnWords).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn from my corrections").font(.system(size: 13, weight: .medium))
                    Text("When you fix a name or term Murmur typed, it's added here automatically.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }

            if model.dictionary.isEmpty && !adding {
                EmptyState(icon: "character.book.closed", title: "No words yet", message: "Add names and terms you use often — like your coworkers, products or technical words — so Murmur spells them right.")
            } else if !model.dictionary.isEmpty {
                HStack {
                    Text("\(model.dictionary.count) word\(model.dictionary.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    SearchField(text: $search, placeholder: "Search").frame(width: 200)
                }
                let entries = search.isEmpty ? model.dictionary : model.dictionary.filter { $0.word.localizedCaseInsensitiveContains(search) }
                ListCard {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().overlay(Theme.border) }
                        DictionaryRow(entry: entry)
                    }
                }
            }
        }
    }

    private func reset() {
        withAnimation {
            adding = false
            word = ""
            misheard = ""
        }
    }
}

struct DictionaryRow: View {
    @EnvironmentObject var model: AppModel
    var entry: DictionaryEntry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.word).font(.system(size: 13, weight: .medium))
                if !entry.replacing.isEmpty {
                    Text("Replaces “\(entry.replacing.joined(separator: "”, “"))”")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
            }
            if entry.autoLearned {
                Text("Auto-added")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accentSoft))
            }
            Spacer()
            RowIconButton(symbol: "trash", help: "Remove") {
                model.dictionary.removeAll { $0.id == entry.id }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(hovering ? Theme.cardHover : .clear)
        .onHover { hovering = $0 }
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var editing: Snippet?

    var body: some View {
        Page {
            PageHeader(title: "Snippets", subtitle: "Voice shortcuts for things you type often — links, intros, addresses, FAQs. Say the cue and Murmur inserts the full text.") {
                Button { startAdding() } label: { Label("Add new", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }

            if adding {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(editing == nil ? "New snippet" : "Edit snippet").font(.system(size: 14, weight: .semibold))
                        FieldRow(label: "When I say", placeholder: "e.g. my calendar link", text: $trigger)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Insert").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                            TextEditor(text: $expansion)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 90, maxHeight: 180)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.background))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") { reset() }.buttonStyle(PillButtonStyle(kind: .secondary))
                            Button(editing == nil ? "Add snippet" : "Save") { save() }
                                .buttonStyle(PillButtonStyle(kind: .dark))
                                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if model.snippets.isEmpty && !adding {
                EmptyState(icon: "text.badge.plus", title: "No snippets yet", message: "Try one for your scheduling link: say “my calendar link” and Murmur types the URL.")
            } else if !model.snippets.isEmpty {
                ListCard {
                    ForEach(Array(model.snippets.enumerated()), id: \.element.id) { index, snippet in
                        if index > 0 { Divider().overlay(Theme.border) }
                        SnippetRow(snippet: snippet, onEdit: { edit(snippet) })
                    }
                }
            }
        }
    }

    private func startAdding() {
        withAnimation {
            editing = nil
            trigger = ""
            expansion = ""
            adding = true
        }
    }

    private func edit(_ snippet: Snippet) {
        withAnimation {
            editing = snippet
            trigger = snippet.trigger
            expansion = snippet.expansion
            adding = true
        }
    }

    private func save() {
        let cue = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing, let index = model.snippets.firstIndex(where: { $0.id == editing.id }) {
            model.snippets[index].trigger = cue
            model.snippets[index].expansion = expansion
        } else {
            model.snippets.insert(Snippet(trigger: cue, expansion: expansion), at: 0)
        }
        reset()
    }

    private func reset() {
        withAnimation {
            adding = false
            editing = nil
            trigger = ""
            expansion = ""
        }
    }
}

struct SnippetRow: View {
    @EnvironmentObject var model: AppModel
    var snippet: Snippet
    var onEdit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("“\(snippet.trigger)”")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 180, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.top, 2)
            Text(snippet.expansion)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
            Spacer()
            HStack(spacing: 4) {
                RowIconButton(symbol: "pencil", help: "Edit", action: onEdit)
                RowIconButton(symbol: "trash", help: "Delete") { model.snippets.removeAll { $0.id == snippet.id } }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(hovering ? Theme.cardHover : .clear)
        .onHover { hovering = $0 }
    }
}

// MARK: - Style

struct StyleView: View {
    @EnvironmentObject var model: AppModel
    @State private var category: AppCategory = .personal

    var body: some View {
        Page {
            PageHeader(title: "Style", subtitle: "Murmur formats your words to match where you're writing. Styles only change capitalization and punctuation — never your words.") {
                Toggle("Apply styles", isOn: $model.settings.stylesEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.accent)
            }

            HStack(spacing: 6) {
                ForEach(AppCategory.allCases) { c in
                    Button { withAnimation(.easeOut(duration: 0.15)) { category = c } } label: {
                        Text(c.title)
                            .font(.system(size: 13, weight: category == c ? .semibold : .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundStyle(category == c ? Theme.ink : Theme.secondary)
                            .background(Capsule().fill(category == c ? Theme.card : Color.clear))
                            .overlay(Capsule().strokeBorder(category == c ? Theme.border : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(Theme.selection.opacity(0.6)))

            Text("Applies in \(category.appExamples).")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)

            HStack(alignment: .top, spacing: 14) {
                ForEach(category.availableStyles) { style in
                    StyleCard(style: style, selected: model.settings.style(for: category) == style) {
                        model.settings.setStyle(style, for: category)
                    }
                }
            }
            .opacity(model.settings.stylesEnabled ? 1 : 0.45)
            .disabled(!model.settings.stylesEnabled)
        }
    }
}

struct StyleCard: View {
    var style: WritingStyle
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(style.title).font(Theme.display(24))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Theme.accent : Theme.tertiary)
                }
                Text(style.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Text(style.example)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(red: 0.2, green: 0.47, blue: 0.98)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hovering && !selected ? Theme.cardHover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Shared bits

struct FieldRow: View {
    var label: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        }
    }
}

struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
