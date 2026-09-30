import Foundation

/// Deterministic "smart formatting" and "backtrack" pass applied to raw speech-to-text output.
///
/// This always runs (it is fast and safe). The optional local-AI polish runs after it and
/// handles the fuzzier cases (restatements, tone), with this pass as its fallback.
public struct TextCleaner: Sendable {
    public var removeFillers = true
    public var applyBacktrack = true
    public var spokenPunctuation = true
    public var formatLists = true

    public init() {}

    public func clean(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "\r\n", with: "\n")
        text = Self.collapseSpaces(text)
        if spokenPunctuation { text = Self.applySpokenPunctuation(text) }
        if removeFillers { text = Self.removeFillerWords(text) }
        text = Self.removeStutters(text)
        if applyBacktrack { text = Self.applyBacktrack(text) }
        if formatLists { text = Self.formatNumberedLists(text) }
        text = Self.fixPunctuationSpacing(text)
        text = Self.capitalizeSentences(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Spoken punctuation ("comma", "period", "new line", ...)

    static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her", "its",
        "trial", "grace", "time", "waiting", "cooling", "free", "study", "notice", "billing", "honeymoon", "oxford", "serial", "each", "every", "one", "same",
    ]

    static func applySpokenPunctuation(_ input: String) -> String {
        var text = input
        // Line breaks first; they can be followed by any punctuation Whisper invents.
        text = replace(text, #"[,;:]?\s*\b(?:new paragraph|next paragraph)\b[,.;:!?]*\s*"#, "\n\n", options: [.caseInsensitive])
        text = replace(text, #"[,;:]?\s*\b(?:new line|newline|next line|line break)\b[,.;:!?]*\s*"#, "\n", options: [.caseInsensitive])

        let marks: [(String, String)] = [
            (#"exclamation (?:point|mark)"#, "!"),
            (#"question mark"#, "?"),
            (#"semicolon|semi-colon"#, ";"),
            (#"full stop"#, "."),
            (#"ellipsis|dot dot dot"#, "…"),
        ]
        for (spoken, mark) in marks {
            text = replace(text, #"[,.;:]?\s*\b(?:"# + spoken + #")\b[,.;:!?]*"#, mark, options: [.caseInsensitive])
        }
        // "colon", "comma" and "period" are real words too, so only convert them when they
        // are not preceded by a determiner ("a period of time", "the Oxford comma").
        text = replaceUnlessDeterminer(text, word: "period", mark: ".", requireBoundaryAfter: true)
        text = replaceUnlessDeterminer(text, word: "comma", mark: ",", requireBoundaryAfter: false)
        text = replaceUnlessDeterminer(text, word: "colon", mark: ":", requireBoundaryAfter: false)
        return text
    }

    private static func replaceUnlessDeterminer(_ text: String, word: String, mark: String, requireBoundaryAfter: Bool) -> String {
        let pattern = #"(\S+)?(\s*)\b"# + word + #"\b([,.;:!?]*)(?=(\s+\S|\s*$))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let prevRange = match.range(at: 1)
            let prevWord = prevRange.location != NSNotFound ? ns.substring(with: prevRange) : ""
            let bare = prevWord.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if determiners.contains(bare) { continue }
            if requireBoundaryAfter {
                // "period" must end the text or be followed by a capitalized word / newline.
                let after = ns.substring(from: match.range.location + match.range.length)
                let trimmed = after.drop(while: { $0 == " " })
                if let first = trimmed.first, !(first.isUppercase || first == "\n" || first.isNumber) { continue }
            }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            if prevRange.location != NSNotFound { result += prevWord }
            result += mark
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: - Fillers

    static let fillerPattern = #"\b(?:u+m+|u+h+m*|e+r+m+|e+r+|a+h+|h+m+|m+h*m+|uh-huh-uh)\b"#

    static func removeFillerWords(_ input: String) -> String {
        var text = input
        // ", uh," between two clauses collapses to a single space; ", um." keeps the final mark.
        text = replace(text, #",\s*"# + fillerPattern + #"\s*,\s*"#, " ", options: [.caseInsensitive])
        text = replace(text, #",\s*"# + fillerPattern + #"\s*(?=[.!?]|$)"#, "", options: [.caseInsensitive])
        // "um," / "uh" / "Uh." with their attached punctuation.
        text = replace(text, #"(^|[\s,.;:!?])"# + fillerPattern + #"[,.;:…]*(?=\s|$|[,.!?])"#, "$1", options: [.caseInsensitive])
        // ", you know," and ", like," used as fillers between commas.
        text = replace(text, #",\s*(?:you know|like|I mean|kind of|sort of)\s*,"#, ",", options: [.caseInsensitive])
        text = replace(text, #"^(?:so|well|okay|ok),\s*(?:you know|like),\s*"#, "", options: [.caseInsensitive])
        text = collapseSpaces(text)
        // Clean up the punctuation debris left behind.
        text = replace(text, #"\s+([,.;:!?])"#, "$1")
        text = replace(text, #"([,;:])\s*([,.;:!?])"#, "$2")
        text = replace(text, #"^\s*[,.;:]\s*"#, "")
        text = replace(text, #"([.!?\n])\s*,\s*"#, "$1 ")
        return text
    }

    // MARK: - Stutters ("I I think" -> "I think")

    static let allowedRepeats: Set<String> = ["that", "had", "is", "do", "very", "really", "so", "no", "bye", "ha", "knock", "tut", "yeah", "well"]

    static func removeStutters(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Za-z']+)(?:[,]?\s+\1\b)+"#, options: [.caseInsensitive]) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range(at: 1))
            if allowedRepeats.contains(word.lowercased()) { continue }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += word
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: - Backtrack ("at 2 actually 3", "scratch that")

    static let numberWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                              "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "hundred"]
    static let dayWords = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "tonight", "yesterday"]
    static let monthWords = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    static func applyBacktrack(_ input: String) -> String {
        var text = input
        // 1. Explicit erase commands remove the sentence (or clause) they follow.
        let erase = #"(?:scratch that|delete that|strike that|forget that|never mind that|cancel that)"#
        while let range = text.range(of: #"[,.!?;:]?\s*\b"# + erase + #"\b[,.!?;:]*"#, options: [.regularExpression, .caseInsensitive]) {
            let before = text[..<range.lowerBound]
            // Find the start of the clause/sentence being retracted.
            var cut = before.startIndex
            if let boundary = before.dropLast().lastIndex(where: { ".!?\n".contains($0) }) {
                cut = before.index(after: boundary)
            }
            let head = String(text[..<cut])
            let tail = String(text[range.upperBound...])
            text = (head.trimmingCharacters(in: .whitespaces) + " " + tail.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
        }

        // 2. "X actually/no/sorry/I mean Y" where X and Y are the same kind of thing (time, day, number).
        let unit = #"(?:\d{1,2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?|\d+(?:\.\d+)?%?|"# + (numberWords + dayWords + monthWords).joined(separator: "|") + #")(?:\s*(?:[ap]\.?m\.?|o'clock|percent|pm|am))?"#
        let trigger = #"(?:actually|no|sorry|I mean|wait|no wait|make that|or rather|rather)"#
        let pattern = #"\b("# + unit + #")\s*[,.…-]*\s*(?:"# + trigger + #")\s*[,.…-]*\s*(?:"# + trigger + #")?\s*[,.…-]*\s*("# + unit + #")\b"#
        text = replace(text, pattern, "$2", options: [.caseInsensitive])

        // 3. "X, no, Y" / "X, I mean Y" for single words of the same shape is ambiguous; leave it to AI polish.
        return collapseSpaces(text)
    }

    // MARK: - Numbered lists ("one finish the report two send the deck")

    static let ordinalSets: [[String]] = [
        ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"],
        ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"],
        ["number one", "number two", "number three", "number four", "number five", "number six", "number seven", "number eight", "number nine", "number ten"],
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"],
    ]

    static func formatNumberedLists(_ input: String) -> String {
        for markers in ordinalSets {
            if let formatted = formatList(input, markers: markers) { return formatted }
        }
        return input
    }

    private static func formatList(_ input: String, markers: [String]) -> String? {
        // Locate "one" followed later by "two" (and so on), each as a standalone marker.
        func markerRegex(_ marker: String) -> String {
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            // A marker is preceded by start, whitespace or punctuation and followed by optional punctuation.
            return #"(?:^|(?<=[\s,.;:!?]))"# + escaped + #"(?:[.):,]|\s*-)?(?=\s)"#
        }
        let lower = input
        var positions: [Range<String.Index>] = []
        var searchStart = lower.startIndex
        for marker in markers {
            guard let r = lower.range(of: markerRegex(marker), options: [.regularExpression, .caseInsensitive], range: searchStart..<lower.endIndex) else { break }
            positions.append(r)
            searchStart = r.upperBound
        }
        guard positions.count >= 2 else { return nil }
        // Require the list to be introduced: the first marker follows a colon, "are", "is", "list", "steps", etc.,
        // or starts the text. This avoids rewriting sentences like "one of them said two things".
        let intro = String(input[..<positions[0].lowerBound])
        let introTrimmed = intro.trimmingCharacters(in: .whitespaces)
        let introOK = introTrimmed.isEmpty
            || introTrimmed.hasSuffix(":")
            || introTrimmed.range(of: #"\b(?:are|is|were|include|includes|following|list|steps|goals|items|things|priorities|reasons|points|agenda|todos?|to-dos?)[,:]?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard introOK else { return nil }
        if introTrimmed.isEmpty {
            // "One, buy milk. Two, call mom." is a list; "one of them said two things" is not.
            let punctuated = positions.allSatisfy { r in
                guard let last = input[r].last else { return false }
                return ".,):-".contains(last)
            }
            guard punctuated else { return nil }
        }
        // Each item must contain at least one word.
        var items: [String] = []
        for (i, r) in positions.enumerated() {
            let end = i + 1 < positions.count ? positions[i + 1].lowerBound : input.endIndex
            var item = String(input[r.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
            item = item.trimmingCharacters(in: .whitespaces)
            // Strip a trailing "and" that joins the last two items.
            item = replace(item, #"[,]?\s+and$"#, "", options: [.caseInsensitive])
            if item.hasSuffix(".") && i + 1 < positions.count { item.removeLast() }
            guard item.rangeOfCharacter(from: .letters) != nil else { return nil }
            if i == 0, item.lowercased().hasPrefix("of ") { return nil }
            items.append(capitalizeFirst(item))
        }
        // The last item keeps everything after it; split off trailing sentences that clearly aren't part of the list.
        var trailing = ""
        if var lastItem = items.last, let dot = lastItem.range(of: #"[.!?]\s+[A-Z]"#, options: .regularExpression) {
            trailing = String(lastItem[lastItem.index(after: dot.lowerBound)...]).trimmingCharacters(in: .whitespaces)
            lastItem = String(lastItem[..<lastItem.index(after: dot.lowerBound)])
            items[items.count - 1] = lastItem
        }
        items = items.map { item in
            var t = item.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }
        var head = introTrimmed
        if !head.isEmpty {
            head = replace(head, #"[,;.]$"#, "")
            if !head.hasSuffix(":") { head += ":" }
        }
        var lines = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !head.isEmpty { lines = head + "\n" + lines }
        if !trailing.isEmpty { lines += "\n" + trailing }
        return lines
    }

    // MARK: - Punctuation & capitalization

    static func fixPunctuationSpacing(_ input: String) -> String {
        var text = input
        text = replace(text, #"[ \t]+([,.;:!?…])"#, "$1")
        text = replace(text, #"([,;:])(?=[A-Za-z])"#, "$1 ")
        text = replace(text, #"([.!?])(?=[A-Z][a-z])"#, "$1 ")
        text = replace(text, #",{2,}"#, ",")
        text = replace(text, #"\.{2,}(?!\.)"#, ".")
        text = replace(text, #",\s*([.!?])"#, "$1")
        text = replace(text, #"([.!?])[.,]+"#, "$1")
        text = replace(text, #"[ \t]*\n[ \t]*"#, "\n")
        text = replace(text, #"\n{3,}"#, "\n\n")
        text = replace(text, #"[ \t]{2,}"#, " ")
        return text
    }

    static func capitalizeSentences(_ input: String) -> String {
        var chars = Array(input)
        var capitalizeNext = true
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                // Don't capitalize things like "iPhone" or "eBay" (lowercase letter followed by uppercase).
                let nextIsUpper = i + 1 < chars.count && chars[i + 1].isUppercase
                if !nextIsUpper { chars[i] = Character(c.uppercased()) }
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                // Treat "e.g." / "3.5" / "..." as non-terminal.
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if c == "\n" || next == " " || next == "\n" { capitalizeNext = true }
            } else if c.isLetter || c.isNumber {
                capitalizeNext = false
            }
            i += 1
        }
        var result = String(chars)
        result = replace(result, #"(?<=^|\s)i(?=['’]?(?:m|ll|d|ve)?\b)(?=\s|['’]|[,.!?]|$)"#, "I")
        return result
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        if s.count > 1, s[s.index(after: s.startIndex)].isUppercase { return s }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: - Helpers

    static func collapseSpaces(_ s: String) -> String {
        replace(s, #"[ \t]{2,}"#, " ").trimmingCharacters(in: .whitespaces)
    }

    static func replace(_ s: String, _ pattern: String, _ template: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
