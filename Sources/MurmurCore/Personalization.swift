import Foundation

/// A voice shortcut: say the cue, get the full text.
public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public var createdAt: Date

    public init(id: UUID = UUID(), trigger: String, expansion: String, createdAt: Date = Date()) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.createdAt = createdAt
    }
}

/// A personal dictionary entry. `replacing` lists common mis-hearings that should become `word`.
public struct DictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var word: String
    public var replacing: [String]
    public var createdAt: Date
    public var autoLearned: Bool

    public init(id: UUID = UUID(), word: String, replacing: [String] = [], createdAt: Date = Date(), autoLearned: Bool = false) {
        self.id = id
        self.word = word
        self.replacing = replacing
        self.createdAt = createdAt
        self.autoLearned = autoLearned
    }
}

public enum SnippetExpander {
    /// Replaces spoken snippet cues with their expansions. Matching ignores case and punctuation.
    public static func expand(_ text: String, snippets: [Snippet]) -> (text: String, used: [Snippet]) {
        var result = text
        var used: [Snippet] = []
        // Longest triggers first so "my calendar link" wins over "calendar".
        for snippet in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            // Whole utterance is the cue: paste the expansion verbatim.
            if normalize(result) == normalize(trigger) {
                return (snippet.expansion, used + [snippet])
            }
            let words = trigger.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"[\s,.\-]+"#) + #"(?![\p{L}\p{N}])[.,!?]?"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            if regex.firstMatch(in: result, range: range) != nil {
                let template = NSRegularExpression.escapedTemplate(for: snippet.expansion)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
                used.append(snippet)
            }
        }
        return (result, used)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum VocabularyCorrector {
    /// Fixes casing/spelling of dictionary words and applies explicit replacements.
    public static func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        var result = text
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            var variants = entry.replacing.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            variants.append(word)
            // A spaced-out version ("whisper kit" -> "WhisperKit") is a very common mis-hearing of compound names.
            let spaced = splitCamelCase(word)
            if spaced.lowercased() != word.lowercased() { variants.append(spaced) }
            for variant in variants {
                let parts = variant.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
                guard !parts.isEmpty else { continue }
                let pattern = #"(?<![\p{L}\p{N}])"# + parts.joined(separator: #"[\s\-]+"#) + #"(?![\p{L}\p{N}])"#
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: word))
            }
        }
        return result
    }

    /// Text handed to the speech model as context so it prefers these spellings.
    public static func speechPrompt(for entries: [DictionaryEntry], limit: Int = 40) -> String? {
        let words = entries.prefix(limit).map(\.word).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: ", ") + "."
    }

    static func splitCamelCase(_ word: String) -> String {
        var out = ""
        var previous: Character?
        for c in word {
            if let p = previous, c.isUppercase, p.isLowercase { out.append(" ") }
            out.append(c)
            previous = c
        }
        return out
    }

    /// Words that look like names or jargon the user corrected — candidates for auto-learning.
    /// Compares the text Murmur inserted with what the user changed it to.
    public static func learnCandidates(original: String, edited: String) -> [String] {
        let originalWords = Set(original.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { $0.lowercased() })
        let editedWords = edited.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        return editedWords.filter { word in
            word.count >= 3 && !originalWords.contains(word.lowercased()) && (word.first?.isUppercase ?? false || word.contains(where: \.isNumber))
        }
    }
}
