import Foundation

public enum DictationMode: String, Codable, Sendable {
    case dictation, command
}

public struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    /// What the speech model heard.
    public var rawText: String
    /// What was inserted.
    public var text: String
    public var appName: String?
    public var appBundleID: String?
    /// Seconds of recorded speech.
    public var audioDuration: Double
    /// Seconds from key release to insertion.
    public var processingTime: Double
    public var mode: DictationMode
    public var aiEdited: Bool
    /// Set when insertion failed and the text was left on the clipboard.
    public var insertionFailed: Bool

    public init(id: UUID = UUID(), date: Date = Date(), rawText: String, text: String, appName: String? = nil, appBundleID: String? = nil,
                audioDuration: Double, processingTime: Double, mode: DictationMode = .dictation, aiEdited: Bool = false, insertionFailed: Bool = false) {
        self.id = id
        self.date = date
        self.rawText = rawText
        self.text = text
        self.appName = appName
        self.appBundleID = appBundleID
        self.audioDuration = audioDuration
        self.processingTime = processingTime
        self.mode = mode
        self.aiEdited = aiEdited
        self.insertionFailed = insertionFailed
    }

    public var wordCount: Int { TextStats.wordCount(text) }
}

public enum TextStats {
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}

public struct UsageStats: Equatable, Sendable {
    public var totalWords: Int
    public var averageWPM: Int
    public var dayStreak: Int
    public var weekStreak: Int
    public var dictationCount: Int
    public var appsUsed: Int
    public var wordsToday: Int

    public static func compute(from records: [DictationRecord], now: Date = Date(), calendar: Calendar = .current) -> UsageStats {
        let dictations = records.filter { $0.mode == .dictation }
        let totalWords = dictations.reduce(0) { $0 + $1.wordCount }
        // WPM only counts recordings long enough to be meaningful.
        let timed = dictations.filter { $0.audioDuration >= 1.5 && $0.wordCount > 0 }
        let minutes = timed.reduce(0.0) { $0 + $1.audioDuration } / 60
        let timedWords = timed.reduce(0) { $0 + $1.wordCount }
        let wpm = minutes > 0 ? Int((Double(timedWords) / minutes).rounded()) : 0

        let days = Set(records.map { calendar.startOfDay(for: $0.date) })
        var dayStreak = 0
        var cursor = calendar.startOfDay(for: now)
        // A streak survives until the end of today even if you haven't dictated yet today.
        if !days.contains(cursor) { cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        while days.contains(cursor) {
            dayStreak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        let weeks = Set(records.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0.date)?.start })
        var weekStreak = 0
        var weekCursor = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        if !weeks.contains(weekCursor) { weekCursor = calendar.date(byAdding: .weekOfYear, value: -1, to: weekCursor)! }
        while weeks.contains(weekCursor) {
            weekStreak += 1
            weekCursor = calendar.date(byAdding: .weekOfYear, value: -1, to: weekCursor)!
        }

        let today = calendar.startOfDay(for: now)
        let wordsToday = dictations.filter { calendar.startOfDay(for: $0.date) == today }.reduce(0) { $0 + $1.wordCount }
        let apps = Set(records.compactMap { $0.appBundleID ?? $0.appName })
        return UsageStats(totalWords: totalWords, averageWPM: wpm, dayStreak: dayStreak, weekStreak: weekStreak,
                          dictationCount: records.count, appsUsed: apps.count, wordsToday: wordsToday)
    }
}

public enum HistoryRetention: String, Codable, CaseIterable, Sendable, Identifiable {
    case forever, month, week, day, never
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .forever: "Forever"
        case .month: "30 days"
        case .week: "7 days"
        case .day: "24 hours"
        case .never: "Don't save history"
        }
    }

    public var maxAge: TimeInterval? {
        switch self {
        case .forever: nil
        case .month: 30 * 86400
        case .week: 7 * 86400
        case .day: 86400
        case .never: 0
        }
    }
}

public enum HistoryGrouping {
    /// Groups records into sections like "TODAY", "YESTERDAY", "MONDAY, SEP 28".
    public static func sections(_ records: [DictationRecord], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, records: [DictationRecord])] {
        let sorted = records.sorted { $0.date > $1.date }
        var order: [Date] = []
        var buckets: [Date: [DictationRecord]] = [:]
        for r in sorted {
            let day = calendar.startOfDay(for: r.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(r)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEE, MMM d")
        let yearFormatter = DateFormatter()
        yearFormatter.calendar = calendar
        yearFormatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return order.map { day in
            let title: String
            if calendar.isDate(day, inSameDayAs: now) { title = "TODAY" }
            else if let y = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)), calendar.isDate(day, inSameDayAs: y) { title = "YESTERDAY" }
            else if calendar.component(.year, from: day) == calendar.component(.year, from: now) { title = formatter.string(from: day).uppercased() }
            else { title = yearFormatter.string(from: day).uppercased() }
            return (title, buckets[day] ?? [])
        }
    }
}
