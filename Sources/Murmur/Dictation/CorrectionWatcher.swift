import AppKit
import ApplicationServices
import MurmurCore

/// After Murmur inserts text, peeks at the field a little later; if the user fixed a name or term, learn it.
@MainActor
final class CorrectionWatcher {
    private struct Pending {
        let element: AXUIElement
        let inserted: String
        let start: Int
    }

    private var pending: Pending?
    private var checks: [DispatchWorkItem] = []
    var onLearn: ((CorrectionLearner.Correction) -> Void)?

    func track(element: AXUIElement?, inserted: String, endLocation: Int?) {
        check()
        cancelChecks()
        let text = inserted.trimmingCharacters(in: .whitespaces)
        guard let element, let end = endLocation else { pending = nil; return }
        let start = end - (text as NSString).length
        guard start >= 0, TextStats.wordCount(text) >= 2 else { pending = nil; return }
        pending = Pending(element: element, inserted: text, start: start)
        for delay in [20.0, 60.0] {
            let item = DispatchWorkItem { [weak self] in self?.check() }
            checks.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// Compares what we inserted with what's in the field now.
    func check() {
        guard let p = pending, let value = TextInserter.value(of: p.element) else { return }
        let ns = value as NSString
        guard p.start < ns.length else { return }
        let length = min(ns.length - p.start, (p.inserted as NSString).length + 60)
        let region = ns.substring(with: NSRange(location: p.start, length: length))
        let wordCount = p.inserted.split(separator: " ").count
        let window = region.split(separator: " ", omittingEmptySubsequences: true).prefix(wordCount + 2).joined(separator: " ")
        let found = CorrectionLearner.corrections(original: p.inserted, edited: window).filter(Self.isLearnable)
        guard !found.isEmpty else { return }
        pending = nil
        cancelChecks()
        for correction in found.prefix(3) { onLearn?(correction) }
    }

    private func cancelChecks() {
        checks.forEach { $0.cancel() }
        checks.removeAll()
    }

    /// Learn names and jargon, never ordinary words (fixing "Their" → "There" is grammar, not vocabulary).
    static func isLearnable(_ c: CorrectionLearner.Correction) -> Bool {
        let word = c.to.trimmingCharacters(in: .punctuationCharacters)
        guard word.count >= 3 else { return false }
        if word.contains(where: \.isNumber) || word.dropFirst().contains(where: \.isUppercase) { return true }
        // If the lowercase form is a normal dictionary word, it isn't something the speech model needs to learn.
        return NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0).location != NSNotFound
    }
}
