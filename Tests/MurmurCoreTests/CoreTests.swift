import Foundation
import Testing
@testable import MurmurCore

@Suite struct TextCleanerTests {
    let cleaner = TextCleaner()

    @Test(arguments: [
        ("Um, so I think we should, uh, meet tomorrow.", "So I think we should meet tomorrow."),
        ("Let's do coffee at 2 actually 3.", "Let's do coffee at 3."),
        ("Let's do coffee at 2, actually, 3.", "Let's do coffee at 3."),
        ("Let's meet on Tuesday, no, Wednesday.", "Let's meet on Wednesday."),
        ("I can't wait to see you exclamation point Let's meet at seven period", "I can't wait to see you! Let's meet at seven."),
        ("I I think the the plan works.", "I think the plan works."),
        ("The trial period ends soon.", "The trial period ends soon."),
        ("Add an Oxford comma here.", "Add an Oxford comma here."),
        ("Send the email. Scratch that. Call him instead.", "Call him instead."),
        ("i think i'm ready", "I think I'm ready"),
        ("one of them said two things", "One of them said two things"),
        ("hello comma how are you question mark", "Hello, how are you?"),
        ("Uh.", ""),
        ("We shipped it. Uh, it works.", "We shipped it. It works."),
    ])
    func cleans(input: String, expected: String) {
        #expect(cleaner.clean(input) == expected)
    }

    @Test func newLine() {
        #expect(cleaner.clean("When is reading club new line should be tomorrow") == "When is reading club\nShould be tomorrow")
        #expect(cleaner.clean("Hi team. New paragraph. Here's the update.") == "Hi team.\n\nHere's the update.")
    }

    @Test func numberedListFromWords() {
        let out = cleaner.clean("My top goals this week are one finish the report two send the presentation.")
        #expect(out == "My top goals this week are:\n1. Finish the report\n2. Send the presentation")
    }

    @Test func numberedListFromDigits() {
        let out = cleaner.clean("My top goals this week are 1. Finish the report. 2. Send the presentation. 3. Book flights.")
        #expect(out == "My top goals this week are:\n1. Finish the report\n2. Send the presentation\n3. Book flights")
    }

    @Test func listNeedsIntro() {
        #expect(!cleaner.clean("I have one dog and two cats.").contains("\n"))
    }
}

@Suite struct StyleTests {
    @Test func casualDropsFinalPeriod() {
        #expect(StyleFormatter.apply(.casual, to: "Sounds good.") == "Sounds good")
        #expect(StyleFormatter.apply(.casual, to: "Are you coming?") == "Are you coming?")
    }

    @Test func veryCasualLowercases() {
        #expect(StyleFormatter.apply(.veryCasual, to: "Sounds good. See you at 5.") == "sounds good. see you at 5")
        #expect(StyleFormatter.apply(.veryCasual, to: "I think NASA is cool.") == "I think NASA is cool")
        #expect(StyleFormatter.apply(.veryCasual, to: "Gabriel is here.", protectedWords: ["Gabriel"]) == "Gabriel is here")
    }

    @Test func excited() {
        #expect(StyleFormatter.apply(.excited, to: "See you there.") == "See you there!")
    }

    @Test func formalUnchanged() {
        #expect(StyleFormatter.apply(.formal, to: "Hello there.") == "Hello there.")
    }

    @Test func categories() {
        #expect(AppCategory.category(forBundleID: "com.tinyspeck.slackmacgap") == .work)
        #expect(AppCategory.category(forBundleID: "com.apple.MobileSMS") == .personal)
        #expect(AppCategory.category(forBundleID: "com.apple.mail") == .email)
        #expect(AppCategory.category(forBundleID: "com.apple.Notes") == .other)
        #expect(AppCategory.personal.availableStyles.contains(.veryCasual))
        #expect(!AppCategory.email.availableStyles.contains(.veryCasual))
    }
}

@Suite struct PersonalizationTests {
    @Test func snippetInline() {
        let s = Snippet(trigger: "my calendar link", expansion: "https://cal.com/me")
        #expect(SnippetExpander.expand("Here is my calendar link.", snippets: [s]).text == "Here is https://cal.com/me")
    }

    @Test func snippetWholeUtterance() {
        let s = Snippet(trigger: "intro email", expansion: "Hi there,\n\nNice to meet you.")
        let r = SnippetExpander.expand("Intro email.", snippets: [s])
        #expect(r.text == "Hi there,\n\nNice to meet you.")
        #expect(r.used.count == 1)
    }

    @Test func snippetNoFalseMatch() {
        let s = Snippet(trigger: "sig", expansion: "— G")
        #expect(SnippetExpander.expand("The signal is weak.", snippets: [s]).text == "The signal is weak.")
    }

    @Test func dictionaryFixesCasingAndSplits() {
        let entries = [DictionaryEntry(word: "WhisperKit"), DictionaryEntry(word: "Claude Code", replacing: ["cloud code"])]
        #expect(VocabularyCorrector.apply("I love whisper kit and whisperkit.", entries: entries) == "I love WhisperKit and WhisperKit.")
        #expect(VocabularyCorrector.apply("Open cloud code now.", entries: entries) == "Open Claude Code now.")
    }

    @Test func speechPrompt() {
        #expect(VocabularyCorrector.speechPrompt(for: [DictionaryEntry(word: "Murmur"), DictionaryEntry(word: "Qwen")]) == "Murmur, Qwen.")
        #expect(VocabularyCorrector.speechPrompt(for: []) == nil)
    }

    @Test func learnCandidates() {
        let words = VocabularyCorrector.learnCandidates(original: "Ask Jon about the deck", edited: "Ask Jonh about the deck")
        #expect(words == ["Jonh"])
    }
}

@Suite struct HotkeyTests {
    @Test func holdToTalk() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.pttDown, at: 0) == [.startRecording(.pushToTalk)])
        #expect(m.handle(.pttUp, at: 1.2) == [.stopAndProcess(.pushToTalk)])
        #expect(m.state == .processing)
        #expect(m.handle(.processingFinished, at: 2) == [])
        #expect(m.state == .idle)
    }

    @Test func quickTapIsDismissed() {
        var m = HotkeyStateMachine()
        _ = m.handle(.pttDown, at: 0)
        #expect(m.handle(.pttUp, at: 0.1) == [])
        #expect(m.handle(.tick, at: 0.3) == [])
        #expect(m.handle(.tick, at: 0.7) == [.cancel(.tooShort)])
        #expect(m.state == .idle)
    }

    @Test func doubleTapLocksHandsFree() {
        var m = HotkeyStateMachine()
        _ = m.handle(.pttDown, at: 0)
        _ = m.handle(.pttUp, at: 0.1)
        #expect(m.handle(.pttDown, at: 0.3) == [.switchMode(.handsFree)])
        #expect(m.handle(.pttUp, at: 0.4) == [])
        #expect(m.handle(.tick, at: 5) == [])
        #expect(m.handle(.pttDown, at: 8) == [.stopAndProcess(.handsFree)])
    }

    @Test func tripleTapCancels() {
        var m = HotkeyStateMachine()
        _ = m.handle(.pttDown, at: 0)
        _ = m.handle(.pttUp, at: 0.1)
        _ = m.handle(.pttDown, at: 0.3)
        _ = m.handle(.pttUp, at: 0.35)
        #expect(m.handle(.pttDown, at: 0.5) == [.cancel(.tripleTap)])
    }

    @Test func fnSpaceHandsFree() {
        var m = HotkeyStateMachine()
        _ = m.handle(.pttDown, at: 0)
        #expect(m.handle(.handsFreeShortcut, at: 0.2) == [.switchMode(.handsFree)])
        #expect(m.handle(.pttUp, at: 0.5) == [])
        #expect(m.handle(.handsFreeShortcut, at: 6) == [.stopAndProcess(.handsFree)])
    }

    @Test func handsFreeFromIdleAndBar() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.barClicked, at: 0) == [.startRecording(.handsFree)])
        #expect(m.handle(.stopClicked, at: 4) == [.stopAndProcess(.handsFree)])
    }

    @Test func commandMode() {
        var m = HotkeyStateMachine()
        _ = m.handle(.pttDown, at: 0)
        #expect(m.handle(.commandModifierDown, at: 0.05) == [.switchMode(.command)])
        #expect(m.handle(.pttUp, at: 2) == [.stopAndProcess(.command)])
    }

    @Test func commandQuickReleaseDismisses() {
        var m = HotkeyStateMachine()
        _ = m.handle(.pttDown, at: 0)
        _ = m.handle(.commandModifierDown, at: 0.05)
        #expect(m.handle(.pttUp, at: 0.2) == [.cancel(.tooShort)])
    }

    @Test func escapeCancels() {
        var m = HotkeyStateMachine()
        _ = m.handle(.pttDown, at: 0)
        #expect(m.handle(.escape, at: 2) == [.cancel(.userCancelled)])
        #expect(m.state == .idle)
    }

    @Test func busyNotice() {
        var m = HotkeyStateMachine()
        _ = m.handle(.pttDown, at: 0)
        _ = m.handle(.pttUp, at: 2)
        #expect(m.handle(.pttDown, at: 2.5) == [.notice("Transcript currently processing")])
    }

    @Test func timeLimit() {
        var m = HotkeyStateMachine()
        _ = m.handle(.handsFreeShortcut, at: 0)
        #expect(m.handle(.tick, at: 19 * 60 + 1) == [.warnTimeLimit])
        #expect(m.handle(.tick, at: 19 * 60 + 2) == [])
        #expect(m.handle(.tick, at: 20 * 60) == [.stopAndProcess(.handsFree)])
    }
}

@Suite struct StatsTests {
    let cal = Calendar(identifier: .gregorian)

    func record(daysAgo: Int, words: Int, seconds: Double, now: Date) -> DictationRecord {
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        return DictationRecord(date: cal.date(byAdding: .day, value: -daysAgo, to: now)!, rawText: text, text: text, appBundleID: "a\(daysAgo)", audioDuration: seconds, processingTime: 0.5)
    }

    @Test func streakAndWPM() {
        let now = Date()
        let records = [record(daysAgo: 0, words: 150, seconds: 60, now: now), record(daysAgo: 1, words: 75, seconds: 30, now: now), record(daysAgo: 2, words: 10, seconds: 4, now: now), record(daysAgo: 5, words: 10, seconds: 4, now: now)]
        let stats = UsageStats.compute(from: records, now: now, calendar: cal)
        #expect(stats.dayStreak == 3)
        #expect(stats.totalWords == 245)
        #expect(stats.averageWPM == 150)
        #expect(stats.appsUsed == 4)
        #expect(stats.wordsToday == 150)
    }

    @Test func streakSurvivesUntilEndOfToday() {
        let now = Date()
        let stats = UsageStats.compute(from: [record(daysAgo: 1, words: 5, seconds: 3, now: now)], now: now, calendar: cal)
        #expect(stats.dayStreak == 1)
    }

    @Test func grouping() {
        let now = Date()
        let sections = HistoryGrouping.sections([record(daysAgo: 0, words: 1, seconds: 1, now: now), record(daysAgo: 1, words: 1, seconds: 1, now: now)], now: now, calendar: cal)
        #expect(sections.map(\.title) == ["TODAY", "YESTERDAY"])
    }

    @Test func settingsDecodeTolerant() throws {
        let json = #"{"soundEffects": false, "unknownKey": 3}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(s.soundEffects == false)
        #expect(s.pushToTalkKey == .fn)
    }
}

@Suite struct WERTests {
    @Test func basics() {
        #expect(WordErrorRate.compute(reference: "hello world", hypothesis: "Hello, world!") == 0)
        #expect(WordErrorRate.compute(reference: "hello world", hypothesis: "hello word") == 0.5)
        #expect(WordErrorRate.compute(reference: "meet at seven", hypothesis: "meet at 7") == 0)
    }
}
