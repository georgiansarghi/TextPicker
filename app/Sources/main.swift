import AppKit
import Darwin

// Broken worker pipes are errors, not signals that should terminate the UI.
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let identifier = Bundle.main.bundleIdentifier ?? "io.github.georgiansarghi.TextPicker"
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    existing.activate(options: [])
    exit(0)
}
migrateLegacySettings(to: identifier)
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
