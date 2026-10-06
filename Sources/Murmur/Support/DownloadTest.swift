import AppKit
import MurmurCore
import MurmurEngine

/// `--download-test <llm-id>`: downloads an AI model through the same code path as the Settings "Download" button,
/// waits for it to load, writes `download-test.txt` in the support folder, then quits.
@MainActor
enum DownloadTest {
    static func run(modelID: String, model: AppModel) {
        let start = Date()
        func finish(_ result: String) {
            let line = "\(result) after \(String(format: "%.1f", Date().timeIntervalSince(start)))s"
            try? line.write(to: AppPaths.supportDirectory.appendingPathComponent("download-test.txt"), atomically: true, encoding: .utf8)
            Log.write("Download test: \(line)")
            NSApp.terminate(nil)
        }
        guard let info = ModelCatalog.llm(modelID) else { return finish("FAIL unknown model \(modelID)") }
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        model.settings.llmModel = modelID
        model.downloadLLM(info)
        Task { @MainActor in
            var lastLogged = -1
            while Date().timeIntervalSince(start) < 900 {
                switch model.llmStatus {
                case .ready:
                    let size = (try? FileManager.default.attributesOfItem(atPath: info.localURL.path)[.size] as? Int64) ?? 0
                    return finish("PASS downloaded \(size / 1_048_576) MB and loaded")
                case .failed(let message):
                    return finish("FAIL \(message)")
                case .downloading(let p):
                    let pct = Int(p * 100)
                    if pct / 10 != lastLogged / 10 { lastLogged = pct; Log.write("Download test progress \(pct)%") }
                default: break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            finish("FAIL timed out")
        }
    }
}
