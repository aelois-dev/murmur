import Foundation

/// Spots the words a user fixed after Murmur inserted text ("Jon" → "John"), so they can be learned.
public enum CorrectionLearner {
    public struct Correction: Equatable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || ($0.isPunctuation && $0 != "'" && $0 != "-" && $0 != "’") }).map(String.init)
    }

    /// Word-level alignment of what was inserted vs. what the text says now; returns small, word-for-word fixes.
    public static func corrections(original: String, edited: String) -> [Correction] {
        let a = words(original), b = words(edited)
        guard !a.isEmpty, !b.isEmpty, a.count <= 400, b.count <= 480 else { return [] }
        // Levenshtein table over words (case-sensitive so capitalization fixes count).
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...max(1, a.count) where a.count > 0 {
            for j in 1...max(1, b.count) where b.count > 0 {
                d[i][j] = a[i - 1] == b[j - 1] ? d[i - 1][j - 1] : 1 + min(d[i - 1][j - 1], d[i - 1][j], d[i][j - 1])
            }
        }
        // Too many changes means a rewrite, not a spelling fix.
        guard d[a.count][b.count] <= max(2, a.count / 4) else { return [] }
        var i = a.count, j = b.count
        var result: [Correction] = []
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] { i -= 1; j -= 1; continue }
            if d[i][j] == d[i - 1][j - 1] + 1 {
                let from = a[i - 1], to = b[j - 1]
                if isSpellingFix(from: from, to: to) { result.append(Correction(from: from, to: to)) }
                i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }

    static func isSpellingFix(from: String, to: String) -> Bool {
        let f = from.lowercased(), t = to.lowercased()
        guard to.filter(\.isLetter).count >= 3, f != t || from != to else { return false }
        if f == t { return to.first?.isUppercase == true } // capitalization of a name: "murmur" → "Murmur"
        let distance = WordErrorRate.editDistance(Array(f), Array(t))
        return distance <= max(2, t.count / 3)
    }
}

/// Decides whether dictated text continues a sentence already in the field, and adapts its first word.
public enum ContinuationFormatter {
    static let commonStarters: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "then", "because", "if", "when", "while", "that", "this", "these", "those",
        "it", "its", "it's", "we", "we're", "we'll", "you", "you're", "they", "they're", "he", "she", "my", "our", "your", "their",
        "to", "for", "with", "without", "in", "on", "at", "of", "from", "by", "as", "about", "also", "just", "maybe", "which",
        "what", "who", "how", "why", "where", "there", "here", "is", "are", "was", "were", "be", "been", "can", "could", "would",
        "should", "will", "do", "does", "did", "not", "no", "yes", "all", "some", "any", "more", "most", "very", "really", "too",
    ]

    /// True when `before` ends mid-sentence (so the next text shouldn't start with a capital).
    public static func isMidSentence(_ before: String) -> Bool {
        let trimmed = before.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        guard let last = trimmed.last else { return false }
        if last.isNewline || ".!?:;…".contains(last) { return false }
        return last.isLetter || last.isNumber || last == ","
    }

    public static func adapt(_ text: String, before: String?) -> String {
        guard let before, isMidSentence(before), let firstWord = text.split(separator: " ").first else { return text }
        let bare = firstWord.trimmingCharacters(in: .punctuationCharacters)
        guard commonStarters.contains(bare.lowercased()), bare.first?.isUppercase == true, bare.dropFirst().allSatisfy({ !$0.isUppercase }) else { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }
}
