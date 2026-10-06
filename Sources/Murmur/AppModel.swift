import AppKit
import AVFoundation
import Combine
import MurmurCore
import MurmurEngine
import ServiceManagement

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    var label: String {
        switch self {
        case .notDownloaded: "Not downloaded"
        case .downloading(let p): "Downloading \(Int(p * 100))%"
        case .loading: "Preparing…"
        case .ready: "Ready"
        case .failed(let message): message
        }
    }
}

enum DictationPhase: Equatable {
    case idle
    case recording(RecordingMode)
    case processing(RecordingMode)

    var isActive: Bool { self != .idle }
}

struct FlowNotice: Equatable, Identifiable {
    enum Kind: Equatable { case info, error, success }
    enum Action: Equatable { case undoCancel, openHistory, openSettings, openAccessibility, openMicrophone, paste, openDictionary }

    let id = UUID()
    var message: String
    var kind: Kind = .info
    var actions: [(title: String, action: Action)] = []
    var duration: TimeInterval = 2.5

    static func == (lhs: FlowNotice, rhs: FlowNotice) -> Bool { lhs.id == rhs.id }
}

enum HubSection: String, CaseIterable, Identifiable {
    case home, dictionary, snippets, style, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .style: "Style"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .style: "textformat"
        case .settings: "gearshape"
        }
    }
}

/// Central app state shared by the hub, the Flow bar and the dictation controller.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var history: [DictationRecord]
    @Published var dictionary: [DictionaryEntry] { didSet { dictionaryStore.save(dictionary) } }
    @Published var snippets: [Snippet] { didSet { snippetStore.save(snippets) } }

    @Published var phase: DictationPhase = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 15)
    @Published var notice: FlowNotice?
    @Published var whisperStatus: ModelStatus = .notDownloaded
    @Published var llmStatus: ModelStatus = .notDownloaded
    /// "2.1 GB of 18.6 GB" while an AI model downloads.
    @Published var llmDownloadDetail: String?
    @Published var micAuthorized = false
    @Published var accessibilityTrusted = false
    @Published var hubSection: HubSection = .home
    @Published var flowBarHovering = false
    @Published var recordingStartedAt: Date?
    /// The microphone is actually delivering audio for the current recording.
    @Published var micLive = false
    @Published var historySearch = ""

    let transcriber = Transcriber()
    private(set) var polisher: Polisher?
    private var noticeTask: Task<Void, Never>?
    private let settingsStore = JSONStore<AppSettings>(url: AppPaths.settingsFile)
    private let historyStore = JSONStore<[DictationRecord]>(url: AppPaths.historyFile)
    private let dictionaryStore = JSONStore<[DictionaryEntry]>(url: AppPaths.dictionaryFile)
    private let snippetStore = JSONStore<[Snippet]>(url: AppPaths.snippetsFile)
    private var llmDownloader: FileDownloader?
    private var whisperLoadTask: Task<Void, Never>?

    /// Called when shortcut-related settings change so the hotkey monitor can reconfigure.
    var onShortcutSettingsChanged: (() -> Void)?
    var onFlowBarSettingsChanged: (() -> Void)?
    var onMicSettingsChanged: (() -> Void)?

    init() {
        if let stored = settingsStore.load() {
            settings = stored
        } else {
            // Fresh install: pick the best models this Mac's memory can run.
            var fresh = AppSettings()
            fresh.llmModel = ModelCatalog.recommendedLLM(forRAMGB: ModelCatalog.installedRAMGB)
            fresh.whisperModel = ModelCatalog.recommendedWhisper(forRAMGB: ModelCatalog.installedRAMGB)
            settings = fresh
        }
        history = historyStore.load() ?? []
        dictionary = dictionaryStore.load() ?? []
        snippets = snippetStore.load() ?? []
        applyRetention()
        refreshPermissions()
    }

    // MARK: - Derived

    var stats: UsageStats { UsageStats.compute(from: history) }
    var lastTranscript: DictationRecord? { history.max(by: { $0.date < $1.date }) }

    var firstName: String {
        if let name = settings.displayName, !name.isEmpty { return name }
        let full = NSFullUserName()
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    var isReadyToDictate: Bool { whisperStatus.isReady }

    // MARK: - Settings

    private func settingsChanged(from old: AppSettings) {
        settingsStore.save(settings)
        if old.pushToTalkKey != settings.pushToTalkKey || old.handsFreeWithSpace != settings.handsFreeWithSpace
            || old.commandModeEnabled != settings.commandModeEnabled || old.doubleTapForHandsFree != settings.doubleTapForHandsFree {
            onShortcutSettingsChanged?()
        }
        if old.showFlowBarAlways != settings.showFlowBarAlways { onFlowBarSettingsChanged?() }
        if old.micReadiness != settings.micReadiness || old.microphoneUID != settings.microphoneUID { onMicSettingsChanged?() }
        if old.whisperModel != settings.whisperModel { loadWhisper() }
        if old.llmModel != settings.llmModel || old.aiEditing != settings.aiEditing { loadLLM() }
        if old.launchAtLogin != settings.launchAtLogin { applyLaunchAtLogin() }
        if old.historyRetention != settings.historyRetention { applyRetention() }
        if old.showInDock != settings.showInDock { NotificationCenter.default.post(name: .murmurDockPolicyChanged, object: nil) }
    }

    private func applyLaunchAtLogin() {
        do {
            if settings.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("Launch at login change failed: \(error)")
        }
    }

    // MARK: - History

    func addHistory(_ record: DictationRecord) {
        guard settings.historyRetention != .never else { return }
        history.append(record)
        historyStore.save(history)
    }

    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        historyStore.save(history)
    }

    func clearHistory() {
        history.removeAll()
        historyStore.save(history)
    }

    func applyRetention() {
        guard let maxAge = settings.historyRetention.maxAge else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let before = history.count
        history.removeAll { $0.date < cutoff }
        if history.count != before || maxAge == 0 { historyStore.save(history) }
    }

    // MARK: - Dictionary & snippets

    func addWord(_ word: String, replacing: [String] = [], autoLearned: Bool = false) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !dictionary.contains(where: { $0.word.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        dictionary.insert(DictionaryEntry(word: trimmed, replacing: replacing, autoLearned: autoLearned), at: 0)
    }

    // MARK: - Flow bar feedback

    func pushLevel(_ level: Float) {
        // Map RMS (~0.001...0.3) to 0...1 on a perceptual (log) scale.
        let db = 20 * log10(max(level, 0.0001))
        let normalized = CGFloat(max(0, min(1, (db + 55) / 40)))
        var next = levels
        next.removeFirst()
        next.append(normalized)
        levels = next
    }

    func resetLevels() { levels = Array(repeating: 0, count: levels.count) }

    func showNotice(_ message: String, kind: FlowNotice.Kind = .info, actions: [(String, FlowNotice.Action)] = [], duration: TimeInterval = 2.5) {
        noticeTask?.cancel()
        let notice = FlowNotice(message: message, kind: kind, actions: actions.map { (title: $0.0, action: $0.1) }, duration: duration)
        self.notice = notice
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self?.notice?.id == notice.id { self?.notice = nil }
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    // MARK: - Permissions

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        // Only publish real changes; this runs on timers and every publish re-renders the UI.
        if mic != micAuthorized { micAuthorized = mic }
        if ax != accessibilityTrusted { accessibilityTrusted = ax }
        if ax && !settings.accessibilityGrantedOnce { settings.accessibilityGrantedOnce = true }
    }

    /// Accessibility worked before but doesn't now: macOS revoked it because the app binary changed.
    var accessibilityNeedsRegrant: Bool { !accessibilityTrusted && settings.accessibilityGrantedOnce }

    static let regrantHelp = "Murmur was updated, so macOS needs Accessibility turned on again: in System Settings → Privacy & Security → Accessibility, select Murmur and click − to remove it, then click Allow here."

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.micAuthorized = granted
                if !granted { Permissions.openMicrophoneSettings() }
            }
        }
    }

    // MARK: - Models

    func loadModels() {
        loadWhisper()
        loadLLM()
    }

    func loadWhisper() {
        let model = settings.whisperModel
        whisperLoadTask?.cancel()
        whisperStatus = Transcriber.isDownloaded(model) ? .loading : .downloading(0)
        whisperLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let start = Date()
                try await transcriber.load(model: model) { progress in
                    Task { @MainActor in
                        if case .downloading = self.whisperStatus { self.whisperStatus = progress >= 1 ? .loading : .downloading(progress) }
                    }
                }
                guard model == settings.whisperModel else { return }
                whisperStatus = .ready
                Log.write("Speech model \(model) ready in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            } catch {
                whisperStatus = .failed("Couldn't load the speech model")
                Log.write("Speech model load failed: \(error)")
            }
        }
    }

    func loadLLM() {
        guard settings.aiEditing || settings.commandModeEnabled, let info = ModelCatalog.llm(settings.llmModel) else {
            polisher = nil
            llmStatus = .notDownloaded
            return
        }
        guard info.isDownloaded else {
            polisher = nil
            llmStatus = .notDownloaded
            return
        }
        if polisher?.info.id == info.id { llmStatus = .ready; return }
        llmStatus = .loading
        polisher = nil
        Task.detached(priority: .utility) {
            do {
                let start = Date()
                let polisher = try Polisher(info: info)
                polisher.warmUp()
                await MainActor.run {
                    guard self.settings.llmModel == info.id else { return }
                    self.polisher = polisher
                    self.llmStatus = .ready
                    Log.write("AI model \(info.id) ready in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                }
            } catch {
                await MainActor.run {
                    self.llmStatus = .failed("Couldn't load the AI model")
                    Log.write("AI model load failed: \(error)")
                }
            }
        }
    }

    /// Free space on the startup disk, in bytes.
    static var freeDiskBytes: Int64 {
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    func downloadLLM(_ info: LLMModelInfo) {
        guard llmDownloader == nil else { return }
        // Leave a few GB spare so the Mac doesn't run out of room.
        let needed = info.sizeBytes + 3_000_000_000
        guard Self.freeDiskBytes >= needed else {
            llmStatus = .failed("Needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free disk space")
            return
        }
        llmStatus = .downloading(0)
        llmDownloadDetail = "Starting…"
        try? FileManager.default.createDirectory(at: AppPaths.llmModelsDirectory, withIntermediateDirectories: true)
        let downloader = FileDownloader(url: info.url, destination: info.localURL)
        llmDownloader = downloader
        downloader.start(progress: { [weak self] written, total in
            Task { @MainActor in
                self?.llmStatus = .downloading(Double(written) / Double(total))
                self?.llmDownloadDetail = "\(ByteCountFormatter.string(fromByteCount: written, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            }
        }, completion: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.llmDownloader = nil
                self.llmDownloadDetail = nil
                if let error {
                    self.llmStatus = .failed("Download failed")
                    Log.write("LLM download failed: \(error)")
                } else {
                    self.loadLLM()
                }
            }
        })
    }

    func downloadWhisper(_ model: String) {
        if settings.whisperModel != model { settings.whisperModel = model } else { loadWhisper() }
    }
}

extension Notification.Name {
    static let murmurDockPolicyChanged = Notification.Name("murmurDockPolicyChanged")
    static let murmurShowHub = Notification.Name("murmurShowHub")
}

/// URLSession download with byte-level progress and automatic resume (large models can be 18+ GB).
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let url: URL
    let destination: URL
    private var progress: ((Int64, Int64) -> Void)?
    private var completion: ((Error?) -> Void)?
    private var session: URLSession?
    private var lastReported: Int64 = 0
    private var retriesLeft = 5
    private var finished = false

    init(url: URL, destination: URL) {
        self.url = url
        self.destination = destination
    }

    func start(progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Error?) -> Void) {
        self.progress = progress
        self.completion = completion
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session?.downloadTask(with: url).resume()
    }

    func cancel() {
        finished = true
        session?.invalidateAndCancel()
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        completion?(error)
        completion = nil
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        // Report roughly every 0.5% (and at the end).
        if totalBytesWritten - lastReported >= totalBytesExpectedToWrite / 200 || totalBytesWritten == totalBytesExpectedToWrite {
            lastReported = totalBytesWritten
            progress?(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !finished else { return }
        // Network hiccup or sleep: pick up where we left off instead of starting over.
        if retriesLeft > 0, (error as NSError).code != NSURLErrorCancelled {
            retriesLeft -= 1
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            Log.write("Download interrupted (\(error.localizedDescription)); \(resumeData != nil ? "resuming" : "restarting") — \(retriesLeft) retries left")
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.finished, let session = self.session else { return }
                let next = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: self.url)
                next.resume()
            }
            return
        }
        finish(error)
    }
}
