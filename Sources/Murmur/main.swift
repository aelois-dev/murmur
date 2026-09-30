import AppKit

// `--snapshot <dir>` renders the UI to PNGs (used by the automated build loop), then exits.
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-snapshot-\(UUID().uuidString)")
    setenv("MURMUR_SUPPORT_DIR", sandbox.path, 1)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        Snapshotter.run(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
