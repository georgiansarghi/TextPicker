import AppKit

@main
struct PermissionMenuTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, line: UInt = #line) {
            checks += 1; precondition(value(), "Permission menu check failed at line \(line)")
        }
        func pump(_ seconds: Double = 0.03, mode: RunLoop.Mode = .default) {
            let deadline = Date().addingTimeInterval(seconds)
            let keepAlive = Timer(timeInterval: 0.01, repeats: true) { _ in }
            RunLoop.main.add(keepAlive, forMode: mode)
            defer { keepAlive.invalidate() }
            while Date() < deadline { _ = RunLoop.main.run(mode: mode, before: deadline) }
        }
        var access = CaptureAccess(), reads = 0, requests: [CapturePermission] = [], opened: [URL] = []
        var settingsWorks = true
        let model = PermissionStatus(actions: .init(check: { reads += 1; return access },
            request: { requests.append($0) }, openSettings: { opened.append($0); return settingsWorks }))
        let controls = CaptureMenu(actions: .init(capture: {}, retry: {}, permission: { permission, action in
            model.perform(action, for: permission)
        }, lines: { _ in }, sound: { _ in }, record: {}, resetShortcut: {}, quit: {}))
        func redraw(capturing: Bool = false, frozen: Bool = false) {
            controls.update(ready: true, capturing: capturing, failed: false, access: model.access,
                keepLines: true, playSound: false, shortcut: .default,
                preservingSelection: frozen, requestedPermissions: model.requested, permissionError: model.settingsError)
        }
        redraw()
        check(controls.menu.items.filter(\.isSectionHeader).map(\.title) == ["Settings", "Permissions"])
        check(controls.permissionRows.count == 2)
        check(controls.menu.items.allSatisfy { !["Capture Access…", "Set Up Capture Access…", "Input Monitoring"].contains($0.title) })
        check(requests.isEmpty && opened.isEmpty)
        for bits in 0..<8 {
            access = CaptureAccess(screenRecording: bits & 1 != 0, accessibility: bits & 2 != 0, inputReady: bits & 4 != 0)
            model.refresh(); redraw()
            check(controls.capture.isEnabled == access.ready)
            for permission in CapturePermission.allCases {
                let row = controls.permissionRows[permission]!
                let granted = access.granted(permission)
                check(row.state == (granted ? .granted : .notGranted))
                check(row.button.title == (granted ? "Settings…" : "Allow"))
                check(row.status.stringValue == (granted ? "✓" : ""))
                check(row.label.accessibilityLabel() == "\(permission.title): \(granted ? "Granted" : "Not granted")")
                for width: CGFloat in [350, 410] {
                    row.setFrameSize(NSSize(width: width, height: 28))
                    row.layoutSubtreeIfNeeded()
                    check(row.bounds.contains(row.button.frame) && row.bounds.contains(row.label.frame))
                    check(row.label.frame.maxX <= row.status.frame.minX && row.status.frame.maxX <= row.button.frame.minX)
                    let textX = row.label.frame.minX + row.label.cell!.titleRect(forBounds: row.label.bounds).minX
                    check(abs(textX - row.checkboxTitleLeading) < 0.01)
                    check(row.button.accessibilityLabel()?.contains(permission.title) == true)
                }
            }
            check(requests.isEmpty && opened.isEmpty)
        }
        let sample = PermissionMenuRow(.screenRecording)
        for state in [PermissionMenuState.notGranted, .requested, .granted] {
            sample.update(state, enabled: true)
            sample.layoutSubtreeIfNeeded()
            check(sample.button.intrinsicContentSize.width <= sample.button.frame.width)
            check(sample.label.intrinsicContentSize.width <= sample.label.frame.width)
        }
        let screen = controls.permissionRows[.screenRecording]!
        let accessibility = controls.permissionRows[.accessibility]!
        // A queued Settings click must remain Settings, even if access is revoked
        // and the visible row becomes Allow before the callback is delivered.
        screen.activate()
        access = CaptureAccess()
        model.refresh(); redraw()
        pump()
        check(requests.isEmpty && opened.last == CapturePermission.screenRecording.settingsURL)
        screen.button.performClick(nil); pump(); redraw()
        check(requests == [.screenRecording])
        check(screen.state == .requested && screen.button.title == "Open Settings…")

        // The initial setup window uses this exact model, including request history.
        let window = PermissionsWindowController(model: model, onRefresh: { _ in redraw() }, onQuit: {})
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(window.window!.contentView!).compactMap { $0 as? NSButton }
        let screenGrant = buttons.first { $0.title == "Open Settings…" && $0.tag == 0 }!
        check(screenGrant.isEnabled && !window.window!.isVisible)
        screenGrant.performClick(nil)
        check(requests == [.screenRecording] && opened.last == CapturePermission.screenRecording.settingsURL)
        buttons.first { $0.title == "Allow" && $0.tag == 1 }!.performClick(nil)
        check(requests == [.screenRecording, .accessibility])
        check(accessibility.state == .requested && accessibility.button.title == "Open Settings…")
        let openCount = opened.count
        accessibility.activate(); pump()
        check(opened.count == openCount + 1 && opened.last == CapturePermission.accessibility.settingsURL)
        check(requests.count == 2)
        // Native keyboard fallback requires no tap/Accessibility grant.
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        screen.keyDown(with: key); pump()
        check(opened.count == openCount + 2 && requests.count == 2)
        settingsWorks = false
        accessibility.activate(); pump(); redraw()
        check(!controls.permissionHint.isHidden && controls.permissionHint.toolTip?.contains("Accessibility") == true)
        settingsWorks = true
        accessibility.activate(); pump(); redraw()
        check(controls.permissionHint.isHidden)

        access = CaptureAccess(screenRecording: true, accessibility: true, inputReady: false)
        window.refresh()
        check(screen.status.stringValue == "✓" && accessibility.status.stringValue == "✓")
        check(!controls.capture.isEnabled && controls.permissionHint.title.contains("Quit and reopen"))
        access.inputReady = true
        window.refresh()
        check(controls.capture.isEnabled && controls.permissionHint.isHidden)
        check(screen.button.title == "Settings…" && accessibility.button.title == "Settings…")
        settingsWorks = false
        screen.activate(); pump(); window.refresh()
        check(!controls.permissionHint.isHidden && model.settingsError != nil)
        model.refresh(); redraw()
        check(!controls.permissionHint.isHidden) // Polling granted access must retain action errors.
        settingsWorks = true
        screen.activate(); pump(); window.refresh()
        check(controls.permissionHint.isHidden)
        let beforeRequests = requests.count, beforeOpens = opened.count
        let visible = controls.menu.items.filter { !$0.isHidden }.map(\.title)
        access = CaptureAccess()
        model.refresh(); redraw(capturing: true, frozen: true)
        check(controls.menu.items.filter { !$0.isHidden }.map(\.title) == visible)
        check(screen.state == .granted && screen.button.isEnabled)
        screen.button.performClick(nil); pump()
        check(requests.count == beforeRequests && opened.count == beforeOpens)
        redraw(capturing: true)
        check(!screen.button.isEnabled && !accessibility.button.isEnabled)
        redraw()
        check(screen.state == .requested && accessibility.state == .requested)
        window.shutdown()

        // Poll only while the menu owns monitoring, pause through selection, and
        // refresh in the actual tracking mode without requesting/capturing anything.
        var capturing = true
        let monitor = PermissionRefreshMonitor(shouldRefresh: { !capturing }, refresh: { model.refresh(); redraw() })
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        let beforeReads = reads
        monitor.start(); monitor.start()
        check(monitor.isRunning)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        pump(1.1, mode: .eventTracking)
        check(reads == beforeReads)
        capturing = false
        access = CaptureAccess(screenRecording: true, accessibility: true, inputReady: true)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        check(reads == beforeReads + 1 && controls.capture.isEnabled)
        pump(1.1, mode: .eventTracking)
        check(reads >= beforeReads + 2)
        monitor.stop(); monitor.stop()
        check(!monitor.isRunning)
        let stopped = reads
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        pump(1.1, mode: .eventTracking)
        check(reads == stopped && requests.count == beforeRequests)
        var temporary: PermissionRefreshMonitor? = PermissionRefreshMonitor { model.refresh() }
        let weakMonitor = { [weak temporary] in temporary }
        temporary?.start()
        temporary = nil
        check(weakMonitor() == nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        check(reads == stopped)
        print("PASS: \(checks) permission-menu/shared-window/polling checks; injected actions, no real requests or screen/clipboard access")
    }
}
