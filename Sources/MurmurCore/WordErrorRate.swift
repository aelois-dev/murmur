import Foundation

/// Word error rate, used by the evaluation harness to score transcription and cleanup quality.
public enum WordErrorRate {
    public static func normalize(_ text: String) -> [String] {
        let numberWords = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                           "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12"]
        // CJK scripts don't use spaces, so each character counts as a token.
        let spaced = CJK.spaced(text)
        return spaced.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
            .map { numberWords[$0] ?? $0 }
    }

    public static func compute(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(editDistance(ref, hyp)) / Double(ref.count)
    }

    public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 0...1 similarity between two texts at the word level (1 = identical).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a), y = normalize(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(x, y)) / Double(longest)
    }
}

/// Helpers for Chinese/Japanese/Korean text.
public enum CJK {
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF, // Han
             0x3040...0x309F, 0x30A0...0x30FF, // Hiragana, Katakana
             0xAC00...0xD7AF: // Hangul
            return true
        default:
            return false
        }
    }

    public static func contains(_ text: String) -> Bool { text.unicodeScalars.contains(where: isCJK) }

    /// Puts spaces around CJK characters so they can be counted/compared like words.
    public static func spaced(_ text: String) -> String {
        guard contains(text) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                out.append(" ")
                out.append(scalar)
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Uses full-width punctuation next to CJK text ("开会,讨论" → "开会，讨论").
    public static func normalizePunctuation(_ text: String) -> String {
        guard contains(text) else { return text }
        let map: [Character: Character] = [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；"]
        var chars = Array(text)
        for i in chars.indices {
            guard let full = map[chars[i]], i > 0 else { continue }
            // Previous non-space character must be CJK; don't touch decimals like "3.5".
            var j = i - 1
            while j > 0 && chars[j] == " " { j -= 1 }
            guard let prev = chars[j].unicodeScalars.first, isCJK(prev) else { continue }
            if chars[i] == ".", i + 1 < chars.count, chars[i + 1].isNumber { continue }
            chars[i] = full
        }
        var result = String(chars)
        // No spaces around full-width punctuation or between CJK characters.
        result = result.replacingOccurrences(of: #"\s*([，。？！：；])\s*"#, with: "$1", options: .regularExpression)
        return result
    }
}
