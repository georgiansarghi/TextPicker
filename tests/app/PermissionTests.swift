import AppKit

@main
struct PermissionTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) {
            checks += 1
            let passed = value()
            if !passed { FileHandle.standardError.write(Data("Permission check \(checks) failed\n".utf8)) }
            precondition(passed, "Permission check \(checks) failed")
        }
        var access = CaptureAccess()
        var reads = 0
        var requests: [CapturePermission] = []
        var opened: [URL] = []
        var opensSuccessfully = true
        let actions = PermissionActions(check: { reads += 1; return access }, request: {
            requests.append($0)
        }, openSettings: { opened.append($0); return opensSuccessfully })
        let model = PermissionStatus(actions: actions)
        check(reads == 1 && requests.isEmpty && opened.isEmpty)
        for flags in 0..<8 {
            access = CaptureAccess(screenRecording: flags & 1 != 0, accessibility: flags & 2 != 0,
                                   inputReady: flags & 4 != 0)
            model.refresh()
            check(model.access.ready == (access.screenRecording && access.accessibility && access.inputReady))
            check(requests.isEmpty && opened.isEmpty) // Checking is never a request.
        }
        access = CaptureAccess(screenRecording: true, accessibility: true, inputReady: true)
        model.refresh()
        check(model.access.ready)
        model.request(.screenRecording)
        model.request(.accessibility)
        check(requests.isEmpty)
        access = CaptureAccess()
        model.request(.accessibility)
        model.request(.accessibility)
        check(requests == [.accessibility]) // No repeated native prompts after denial.
        access.accessibility = true
        model.refresh()
        check(!model.access.ready) // A permission bit is not a working input tap.
        access.screenRecording = true
        model.refresh()
        check(!model.access.ready && model.access.guidance.contains("capture input is not ready"))
        access.inputReady = true
        model.refresh()
        check(model.access.ready)
        access.screenRecording = false
        model.refresh()
        check(!model.access.ready) // Revocation is reflected on the next check.
        model.request(.screenRecording)
        check(requests.last == .screenRecording)
        model.openSettings(.screenRecording)
        check(opened.last?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
        check(model.settingsError == nil)
        opensSuccessfully = false
        model.openSettings(.accessibility)
        check(model.settingsError?.contains("System Settings") == true)
        check(opened.last?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        access = CaptureAccess(screenRecording: true, accessibility: true, inputReady: true)
        model.refresh()
        check(model.settingsError == nil)

        // Build/render our own synthetic UI, without showing windows, invoking
        // permission APIs, opening Settings, reading screen pixels or clipboard.
        access = CaptureAccess()
        var refreshes = 0
        let controller = PermissionsWindowController(model: PermissionStatus(actions: actions), onRefresh: { _ in refreshes += 1 }, onQuit: {})
        let window = controller.window!
        let content = window.contentView!
        check(window.title == "TextPicker Permissions" && window.styleMask.contains(.closable))
        check(!window.isVisible && !controller.monitoring)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func labels() -> [String] { descendants(content).compactMap { ($0 as? NSTextField)?.stringValue } }
        func buttons() -> [NSButton] { descendants(content).compactMap { $0 as? NSButton } }
        check(CapturePermission.allCases.allSatisfy { labels().contains($0.title) })
        check(CapturePermission.allCases.count == 2 && !labels().contains("Input Monitoring"))
        check(buttons().filter { $0.title == "Grant Access" && !$0.isHidden }.count == 2)
        check(buttons().contains { $0.title == "Later" })
        content.layoutSubtreeIfNeeded()
        if CommandLine.arguments.count == 2 {
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        let screenGrant = buttons().first { $0.title == "Grant Access" && $0.tag == 0 }!
        let originalRequests = requests.count
        screenGrant.performClick(nil)
        check(requests.count == originalRequests + 1 && requests.last == .screenRecording)
        check(!screenGrant.isEnabled && screenGrant.title == "Requested")
        screenGrant.performClick(nil)
        check(requests.count == originalRequests + 1)
        let originalOpens = opened.count
        buttons().first { $0.title == "Open Settings…" && $0.tag == 1 }!.performClick(nil)
        check(opened.count == originalOpens + 1 && opened.last?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        check(labels().contains { $0.contains("Open System Settings") })
        let beforeRequests = requests.count
        let initialRefreshes = refreshes
        controller.beginMonitoring()
        controller.beginMonitoring()
        check(controller.monitoring)
        access = CaptureAccess(screenRecording: true, accessibility: true, inputReady: true)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        check(refreshes == initialRefreshes + 1 && labels().filter { $0 == "✓ Granted" }.count == 2)
        check(buttons().contains { $0.title == "Done" })
        check(buttons().allSatisfy { $0.title != "Grant Access" || $0.isHidden })
        check(requests.count == beforeRequests)
        RunLoop.main.run(until: Date().addingTimeInterval(1.15))
        check(refreshes >= initialRefreshes + 2)
        controller.close()
        check(!controller.monitoring)
        let stopped = refreshes
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        check(refreshes == stopped)
        check(controller.window === window) // Reopening reuses, rather than stacks, windows.
        controller.beginMonitoring()
        // Exercise the red-close delegate path without showing a real window.
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        check(!controller.monitoring)
        controller.shutdown()
        print("PASS: \(checks) permission state/UI/lifecycle checks; no real requests, input, screen or clipboard access")
    }
}
