import Foundation

/// Keeps AI edits honest: the AI may add punctuation, drop filler words and apply genuine self-corrections,
/// but it may not reword what the speaker said. Any word it swapped or dropped without a reason is put back.
public enum FaithfulMerge {
    struct Token {
        var lead: String
        var text: String
        var key: String
    }

    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "er", "erm", "ah", "hmm", "mm", "mhm", "like"]
    static let fillerPairs: [[String]] = [["you", "know"], ["i", "mean"]]
    static let correctionCues: Set<String> = ["no", "nope", "sorry", "actually", "wait", "rather", "mean", "scratch", "correction", "oops"]
    static let stopwords: Set<String> = ["a", "an", "the", "to", "of", "and", "or", "in", "on", "at", "for", "is", "it", "i", "we", "you", "that", "this"]
    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "fifteen": "15", "twenty": "20", "thirty": "30", "fifty": "50", "hundred": "100",
    ]

    static func key(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "%")))
    }

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var lead = ""
        var current = ""
        for ch in s {
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(Token(lead: lead, text: current, key: key(current)))
                    current = ""
                    lead = ""
                }
                lead.append(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(Token(lead: lead, text: current, key: key(current))) }
        return tokens
    }

    enum Op { case match(Int, Int), sub(Int, Int), del(Int), ins(Int) }

    static func align(_ a: [Token], _ b: [Token]) -> [Op] {
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let same = a[i - 1].key == b[j - 1].key
                    d[i][j] = min(d[i - 1][j - 1] + (same ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
                }
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i - 1].key == b[j - 1].key && d[i][j] == d[i - 1][j - 1] {
                ops.append(.match(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0 && d[i][j] == d[i - 1][j] + 1 {
                ops.append(.del(i - 1)); i -= 1
            } else if j > 0 && d[i][j] == d[i][j - 1] + 1 {
                ops.append(.ins(j - 1)); j -= 1
            } else {
                ops.append(.sub(i - 1, j - 1)); i -= 1; j -= 1
            }
        }
        return ops.reversed()
    }

    /// - Parameters:
    ///   - original: the text before AI editing (already rule-cleaned).
    ///   - edited: the AI's version.
    ///   - allowed: words the AI may introduce (dictionary entries, names on screen).
    public static func merge(original: String, edited: String, allowed: Set<String> = []) -> String {
        // Scripts without spaces, or edits that restructure into lines, aren't word-alignable; leave them be.
        if CJK.contains(original) || CJK.contains(edited) { return edited }
        if edited.contains("\n") && !original.contains("\n") { return edited }
        let a = tokenize(original), b = tokenize(edited)
        guard !a.isEmpty, !b.isEmpty else { return edited }
        let allowedKeys = Set(allowed.flatMap { tokenize($0).map(\.key) })
        let ops = align(a, b)

        // Which deleted original tokens are legitimately removed.
        var deletedIndices: [Int] = []
        for op in ops { if case .del(let i) = op { deletedIndices.append(i) } }
        var explained = Set<Int>()
        var spanStart = 0
        while spanStart < deletedIndices.count {
            var spanEnd = spanStart
            while spanEnd + 1 < deletedIndices.count && deletedIndices[spanEnd + 1] == deletedIndices[spanEnd] + 1 { spanEnd += 1 }
            let span = Array(deletedIndices[spanStart...spanEnd])
            if isExplainedDeletion(span, in: a) { explained.formUnion(span) }
            spanStart = spanEnd + 1
        }

        var out: [Token] = []
        func endsSentence(_ t: Token?) -> Bool {
            guard let t else { return true }
            return t.text.hasSuffix(".") || t.text.hasSuffix("!") || t.text.hasSuffix("?") || t.text.hasSuffix(":")
        }
        for op in ops {
            switch op {
            case .match(let i, let j):
                var token = b[j]
                // The AI capitalized a word because it started *its* sentence; mid-sentence, keep the original casing.
                if let f = token.text.first, f.isUppercase, a[i].text.first?.isLowercase == true, !out.isEmpty, !endsSentence(out.last),
                   !token.lead.contains("\n") {
                    token.text = token.text.prefix(1).lowercased() + token.text.dropFirst()
                }
                out.append(token)
            case .sub(let i, let j):
                if isAllowedSubstitution(from: a[i].key, to: b[j].key, allowed: allowedKeys) {
                    out.append(b[j])
                } else {
                    out.append(Token(lead: b[j].lead, text: a[i].text, key: a[i].key))
                }
            case .del(let i):
                if !explained.contains(i) {
                    out.append(Token(lead: out.isEmpty ? "" : (a[i].lead.contains("\n") ? a[i].lead : " "), text: a[i].text, key: a[i].key))
                }
            case .ins(let j):
                let k = b[j].key
                if k.isEmpty || Int(k) != nil || allowedKeys.contains(k) || isListMarker(b[j].text) { out.append(b[j]) }
            }
        }
        var text = ""
        for (index, token) in out.enumerated() {
            text += (index == 0 ? "" : (token.lead.isEmpty ? " " : token.lead)) + token.text
        }
        // A re-inserted first word may need its capital back.
        if let first = text.first, first.isLowercase, let origFirst = original.first, origFirst.isUppercase, text.prefix(1).lowercased() == original.prefix(1).lowercased() {
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        return text
    }

    static func isListMarker(_ s: String) -> Bool {
        s.range(of: #"^\d+[.)]$"#, options: .regularExpression) != nil
    }

    static func isAllowedSubstitution(from: String, to: String, allowed: Set<String>) -> Bool {
        if from == to { return true }
        if from.replacingOccurrences(of: "'", with: "") == to.replacingOccurrences(of: "'", with: "") { return true }
        if numberWords[from] == to || numberWords[to] == from { return true }
        if (from == "percent" && to == "%") || (to.hasSuffix("%") && numberWords[from] == String(to.dropLast())) { return true }
        if allowed.contains(to) { return true }
        return false
    }

    static func isExplainedDeletion(_ span: [Int], in a: [Token]) -> Bool {
        guard let first = span.first, let last = span.last else { return true }
        let keys = span.map { a[$0].key }.filter { !$0.isEmpty }
        if keys.isEmpty { return true }
        // Filler words.
        var k = 0
        var allFiller = true
        while k < keys.count {
            if fillers.contains(keys[k]) { k += 1; continue }
            if k + 1 < keys.count, fillerPairs.contains([keys[k], keys[k + 1]]) { k += 2; continue }
            allFiller = false
            break
        }
        if allFiller { return true }
        guard span.count <= 8 else { return false }
        // Restatement: the speaker repeated part of the phrase they replaced ("as a gift, as a present").
        let spanSet = Set(keys)
        let after = Set((last + 1..<min(a.count, last + 4)).map { a[$0].key })
        let before = Set((max(0, first - 3)..<first).map { a[$0].key })
        let overlapAfter = spanSet.intersection(after), overlapBefore = spanSet.intersection(before)
        if overlapAfter.count >= 2 || overlapBefore.count >= 2 { return true }
        if overlapAfter.contains(where: { !stopwords.contains($0) }) { return true }
        // Self-correction cue set off by punctuation (", no,", ". Sorry,", "— actually —").
        for idx in span where correctionCues.contains(a[idx].key) {
            let marked = a[idx].text.hasSuffix(",") || a[idx].text.hasSuffix(".") || a[idx].text.hasSuffix("—")
                || (idx > 0 && (a[idx - 1].text.hasSuffix(",") || a[idx - 1].text.hasSuffix(".") || a[idx - 1].text.hasSuffix("—")))
            if marked { return true }
        }
        return false
    }
}
