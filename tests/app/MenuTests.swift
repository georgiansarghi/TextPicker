import AppKit
import ApplicationServices

@main
struct MenuTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
            checks += 1
            precondition(value(), "FAIL \(message) at \(file):\(line)")
        }
        let defaultsName = "TextPicker.MenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let original = CaptureShortcut.default
        check(original.validationError == nil)
        check(CaptureShortcut.restored(from: defaults) == original)
        check(original.matches(key: 19, flags: [.maskCommand, .maskShift]))
        check(original.matches(key: 19, flags: [.maskCommand, .maskShift, .maskAlphaShift]))
        check(!original.matches(key: 19, flags: [.maskCommand]))
        check(!original.matches(key: 19, flags: [.maskCommand, .maskShift, .maskAlternate]))
        check(!original.matches(key: 20, flags: [.maskCommand, .maskShift]))
        let custom = CaptureShortcut(keyCode: 17, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue)
        check(custom.validationError == nil)
        check(custom.menuModifiers == [.control, .option])
        check(custom.menuEquivalent.count == 1)
        check(custom.display.hasPrefix("⌃⌥"))
        custom.save(to: defaults)
        check(CaptureShortcut.restored(from: defaults) == custom)
        for flags: CGEventFlags in [[], .maskShift, .maskAlternate, [.maskShift, .maskAlternate], [.maskControl, .maskAlphaShift]] {
            let invalid = CaptureShortcut(keyCode: 17, modifiers: flags.rawValue)
            check(invalid.validationError != nil)
            invalid.save(to: defaults)
            check(CaptureShortcut.restored(from: defaults) == custom)
        }
        for key: UInt16 in [36, 48, 49, 51, 53, 55, 63, 127, UInt16.max] {
            check(CaptureShortcut(keyCode: key, modifiers: CGEventFlags.maskCommand.rawValue).validationError != nil)
        }
        for key: UInt16 in [12, 13, 4, 20, 21, 23] {
            check(CaptureShortcut(keyCode: key, modifiers: CGEventFlags([.maskCommand, .maskShift]).rawValue).validationError != nil)
        }
        for (key, label) in CaptureShortcut.functionKeys {
            let value = CaptureShortcut(keyCode: key, modifiers: CGEventFlags.maskControl.rawValue)
            check(value.validationError == nil)
            check(value.keyLabel == label)
            check(value.menuEquivalent.count == 1)
        }
        for data in [Data("invalid".utf8), Data(repeating: 32, count: 1025),
                     Data("{\"keyCode\":65535,\"modifiers\":0}".utf8)] {
            defaults.set(data, forKey: CaptureShortcut.preferenceKey)
            check(CaptureShortcut.restored(from: defaults) == original)
        }
        original.save(to: defaults)
        check(CaptureShortcut.restored(from: defaults) == original)

        var routing = MenuKeyRouting()
        check(!routing.route(.keyDown, key: 19, flags: [.maskCommand, .maskShift], repeated: false).consume)
        routing.recording = true
        let recorded = routing.route(.keyDown, key: 19, flags: [.maskCommand, .maskShift], repeated: false)
        check(recorded.consume && recorded.action == .record, "old shortcut is recorded, not captured")
        routing.end()
        let repeatAfterSave = routing.route(.keyDown, key: 19, flags: [.maskCommand, .maskShift], repeated: true)
        check(repeatAfterSave.consume && repeatAfterSave.action == nil)
        check(routing.route(.keyUp, key: 19, flags: [], repeated: false).consume, "release remains paired after save/close")
        check(!routing.route(.keyUp, key: 19, flags: [], repeated: false).consume)
        routing.recording = true
        check(routing.route(.keyDown, key: 53, flags: [], repeated: false).action == .record)
        routing.end()
        check(routing.route(.keyUp, key: 53, flags: [], repeated: false).consume)
        routing.recording = true
        check(routing.route(.keyDown, key: 17, flags: [], repeated: true).consume)
        check(!routing.route(.keyUp, key: 17, flags: [], repeated: false).consume, "preexisting held keys retain original owner")
        check(!routing.route(.leftMouseDown, key: 0, flags: [], repeated: false).consume)
        check(!routing.route(.flagsChanged, key: 55, flags: .maskCommand, repeated: false).consume)
        routing.end()
        routing.controlKeys = [36, 49, 123, 124]
        check(routing.route(.keyDown, key: 49, flags: [], repeated: false).action == .control)
        routing.end()
        check(routing.route(.keyUp, key: 49, flags: [], repeated: false).consume)
        routing.controlKeys = [49]
        check(!routing.route(.keyDown, key: 49, flags: .maskCommand, repeated: false).consume)

        routing.controlKeys = [49]
        check(!routing.route(.keyDown, key: 49, flags: [], repeated: false, captureActive: true).consume,
              "selection owns Space instead of toggling a setting")
        routing.recording = true
        check(!routing.route(.keyDown, key: 17, flags: .maskCommand, repeated: false, captureActive: true).consume)
        routing.end()

        // Exercise real common-mode callback scheduling, but never install an
        // event tap or post an event. Native menu tracking uses this run-loop mode.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        let input = CaptureInput()
        check(!input.available && !input.beginShortcutRecording())
        var delivered: [UInt16] = []
        input.setMenuKeys([49]) { delivered.append($0) }
        check(input.routeMenuKey(.keyDown, key: 49, flags: [], repeated: false))
        let trackingTimer = Timer(timeInterval: 0.01, repeats: false) { _ in }
        RunLoop.main.add(trackingTimer, forMode: .eventTracking)
        _ = RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.02))
        check(delivered == [49], "delivery happens before leaving menu tracking")
        check(input.routeMenuKey(.keyUp, key: 49, flags: [], repeated: false))
        check(input.routeMenuKey(.keyDown, key: 49, flags: [], repeated: false))
        input.endMenuTracking()
        drain()
        check(delivered == [49], "queued action is discarded on close")
        check(input.routeMenuKey(.keyUp, key: 49, flags: [], repeated: false))
        input.setMenuKeys([49]) { delivered.append($0) }
        check(input.routeMenuKey(.keyDown, key: 49, flags: [], repeated: false))
        input.setMenuKeys([36]) { delivered.append($0) }
        drain()
        check(delivered == [49], "queued action is discarded after highlight changes")
        check(input.routeMenuKey(.keyUp, key: 49, flags: [], repeated: false))
        input.stop()

        // Exercise the actual tap handler with constructed (never posted) events.
        // Opening TextPicker's menu must not bypass suppressing shortcut routing.
        let captureInput = CaptureInput()
        captureInput.canStartCapture = true
        var shortcutCalls = 0, cancelCalls = 0, settingCalls = 0
        var pointerActions: [CaptureInputState.Action] = []
        captureInput.onShortcut = { shortcutCalls += 1 }
        captureInput.onCancel = { cancelCalls += 1; captureInput.endSelection() }
        captureInput.onPointer = { action, _ in pointerActions.append(action) }
        captureInput.setMenuKeys([49]) { _ in settingCalls += 1 }
        func keyboard(_ key: UInt16, down: Bool, flags: CGEventFlags = []) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
            event.flags = flags
            return event
        }
        func trackingDrain() {
            let until = Date(timeIntervalSinceNow: 0.02)
            let keepAlive = Timer(timeInterval: 0.005, repeats: true) { _ in }
            RunLoop.main.add(keepAlive, forMode: .eventTracking)
            while Date() < until { _ = RunLoop.main.run(mode: .eventTracking, before: until) }
            keepAlive.invalidate()
        }
        // Queue an edit, then start capture before it can run: stale edits must
        // not change the very menu being captured.
        check(captureInput.routeMenuKey(.keyDown, key: 49, flags: [], repeated: false))
        check(captureInput.routeMenuKey(.keyUp, key: 49, flags: [], repeated: false))
        check(captureInput.handle(.keyDown, keyboard(19, down: true, flags: [.maskCommand, .maskShift])) == nil)
        trackingDrain()
        check(shortcutCalls == 1 && settingCalls == 0, "shortcut delivered inside tracking loop; pending edit invalidated")
        check(captureInput.handle(.keyUp, keyboard(19, down: false)) == nil)
        check(captureInput.handle(.keyDown, keyboard(49, down: true)) == nil)
        check(captureInput.handle(.keyUp, keyboard(49, down: false)) == nil)
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 100, y: 100), mouseButton: .left)!
        move.setIntegerValueField(.mouseEventDeltaX, value: 10)
        check(captureInput.handle(.mouseMoved, move) == nil)
        for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 100, y: 100), mouseButton: .left)!
            check(captureInput.handle(type, event) == nil)
        }
        trackingDrain()
        check(settingCalls == 0 && pointerActions == [.move, .down, .move, .up])
        check(captureInput.handle(.keyDown, keyboard(53, down: true)) == nil)
        trackingDrain()
        check(cancelCalls == 1)
        check(captureInput.handle(.keyUp, keyboard(53, down: false)) == nil)
        check(captureInput.handle(.keyDown, keyboard(49, down: true)) == nil)
        trackingDrain()
        check(settingCalls == 1, "menu keyboard controls resume after cancellation")
        check(captureInput.handle(.keyUp, keyboard(49, down: false)) == nil)
        check(captureInput.handle(.mouseMoved, move) != nil, "ordinary pointer events resume")
        check(captureInput.handle(.keyDown, keyboard(19, down: true, flags: [.maskCommand, .maskShift])) == nil)
        captureInput.endSelection()
        trackingDrain()
        check(shortcutCalls == 1, "stale capture callbacks are rejected")
        check(captureInput.handle(.keyUp, keyboard(19, down: false)) == nil)
        captureInput.onCancel = nil
        captureInput.stop()

        var lines = true, sound = false
        var lineCalls = 0, soundCalls = 0, recordings = 0, resets = 0
        var captures = 0, retries = 0, permissions = 0, quits = 0
        var additiveSetting = false, feedbackSetting = true, loginRequests: [Bool] = [], loginSettingsCalls = 0
        let controls = CaptureMenu(actions: .init(
            capture: { captures += 1 }, retry: { retries += 1 },
            permission: { _, _ in permissions += 1 },
            lines: { lines = $0; lineCalls += 1 }, sound: { sound = $0; soundCalls += 1 },
            record: { recordings += 1 }, resetShortcut: { resets += 1 },
            quit: { quits += 1 },
            additiveClipboard: { additiveSetting = $0 }, showCaptureFeedback: { feedbackSetting = $0 },
            login: { loginRequests.append($0) }, loginSettings: { loginSettingsCalls += 1 }))
        let linesItem = controls.menu.items.first { $0.view === controls.lines }!
        func update(ready: Bool = true, capturing: Bool = false, failed: Bool = false, access: Bool = true) {
            controls.update(ready: ready, capturing: capturing, failed: failed,
                            access: CaptureAccess(screenRecording: access, accessibility: access, inputReady: access), keepLines: lines, playSound: sound, shortcut: custom)
            check(controls.menu.items.first === controls.capture && !controls.capture.isHidden)
            check(controls.capture.title == "Capture Text", "first menu label stays static in every state")
        }
        update(ready: false) // Startup: unavailable, but no transient progress row.
        check(!controls.capture.isEnabled)
        update()
        check(controls.menu.items.allSatisfy { $0.submenu == nil })
        check(!controls.menu.showsStateColumn)
        check(controls.menu.items.allSatisfy { $0.state == .off }, "no main-menu checkmark gutter")
        check(controls.menu.items.filter(\.isSectionHeader).map(\.title) == ["Settings", "Permissions"])
        check(controls.menu.items.filter(\.isSeparatorItem).count == 3)
        check(!controls.menu.autoenablesItems)
        check(controls.retry.isHidden)
        check(controls.menu.items.allSatisfy { $0.title != "Cancel Capture" })
        check(controls.capture.isEnabled && controls.permissionRows.values.allSatisfy { $0.state == .granted })
        check(controls.menu.items.allSatisfy { !["Capture Access…", "Set Up Capture Access…"].contains($0.title) })
        check(controls.menu.items.allSatisfy { $0.title != "OCR Engine" }, "native app has no engine chooser")
        check(controls.menu.items.allSatisfy { !["Open Test Card…", "Restart OCR Engine", "Testing Guide…", "OCR Model"].contains($0.title) })
        check(controls.lines.value && !controls.sound.value)
        check(controls.lines.control.cell?.accessibilityRole() == .checkBox)
        check(controls.sound.control.cell?.accessibilityRole() == .checkBox)
        check(controls.lines.frame.height == 28 && controls.sound.frame.height == 28)
        check(controls.shortcut.frame.height == 28 && controls.shortcutHint.isHidden)
        check(controls.shortcutHint.toolTip == nil && controls.shortcutHint.view == nil)
        check(!controls.shortcutHint.isEnabled && controls.shortcutHint.action == nil)
        check(controls.menu.index(of: controls.shortcutHint) == controls.menu.index(of: controls.shortcutItem) + 1)
        check(controls.menu.index(of: linesItem) == controls.menu.index(of: controls.shortcutHint) + 1)
        check(controls.menu.items.filter(\.isSectionHeader).allSatisfy { $0.view is MenuSectionRow })
        let visibleBeforeCapture = controls.menu.items.filter { !$0.isHidden }.map(\.title)
        let rowSizeBeforeCapture = controls.shortcut.frame.size
        controls.update(ready: false, capturing: true, failed: false,
                        access: CaptureAccess(screenRecording: true, accessibility: true, inputReady: true), keepLines: lines, playSound: sound,
                        shortcut: custom, preservingSelection: true)
        check(controls.menu.items.filter { !$0.isHidden }.map(\.title) == visibleBeforeCapture)
        check(controls.capture.isEnabled && controls.shortcut.recordButton.isEnabled)
        check(controls.shortcut.frame.size == rowSizeBeforeCapture, "capture must not reflow or dim its subject")
        check(controls.lines.control.accessibilityLabel() == "Preserve Line Breaks")
        check(controls.sound.control.accessibilityLabel() == "Play Sound When Copied")
        controls.lines.activate()
        check(!lines && lineCalls == 1)
        // Exercise the native checkbox target/action path, not just the row helper.
        controls.sound.control.state = .on
        check(NSApp.sendAction(controls.sound.control.action!, to: controls.sound.control.target, from: controls.sound.control))
        check(sound && soundCalls == 1)
        check(controls.highlight(linesItem) == [36, 49, 123, 124])
        check(controls.lines.highlighted && !controls.sound.highlighted)
        controls.handleKey(124, item: linesItem)
        check(lines && lineCalls == 2)
        controls.handleKey(123, item: linesItem)
        check(!lines && lineCalls == 3)
        controls.handleKey(36, item: linesItem)
        check(lines && lineCalls == 4)
        check(controls.highlight(controls.shortcutItem) == [36, 49, 51])
        controls.handleKey(36, item: controls.shortcutItem)
        check(recordings == 1)
        controls.handleKey(51, item: controls.shortcutItem)
        check(resets == 1)
        let idleMenuHeight = controls.menu.size.height
        controls.shortcut.setRecording(true)
        update()
        check(controls.shortcut.recording && controls.capture.keyEquivalent.isEmpty)
        check(controls.shortcut.frame.height == 28 && !controls.shortcutHint.isHidden)
        check(controls.menu.size.height > idleMenuHeight, "native guidance row owns its spacing")
        controls.shortcut.layoutSubtreeIfNeeded()
        check(controls.shortcut.bounds.contains(controls.shortcut.recordButton.frame))
        check(controls.shortcut.bounds.contains(controls.shortcut.label.frame))
        check(controls.shortcut.guidance == controls.shortcutHint.title)
        controls.shortcut.setRecording(true, message: "Choose another combination.")
        check(controls.shortcutHint.title == "Choose another combination.")
        check(controls.shortcutHint.attributedTitle?.string == controls.shortcutHint.title)
        controls.shortcut.setRecording(false)
        update()
        check(controls.capture.keyEquivalent == custom.menuEquivalent)
        check(controls.capture.keyEquivalentModifierMask == custom.menuModifiers)
        check(controls.shortcut.recordButton.title == custom.display)
        check(controls.shortcut.frame.height == 28 && controls.shortcutHint.isHidden)
        check(controls.menu.size.height == idleMenuHeight)
        update(ready: false, capturing: true)
        check(!controls.capture.isEnabled)
        check(controls.menu.items.filter { !$0.isHidden }.map(\.title) == visibleBeforeCapture,
              "recognition must not insert any transient menu row")
        check(controls.menu.size.height == idleMenuHeight)
        check(!controls.shortcutItem.isEnabled && !controls.shortcut.recordButton.isEnabled && !controls.shortcut.resetButton.isEnabled)
        controls.shortcut.record(); controls.shortcut.reset()
        check(recordings == 1 && resets == 1)
        update(ready: false, failed: true, access: false)
        check(!controls.retry.isHidden && controls.permissionRows.values.allSatisfy { $0.state == .notGranted })
        check(!controls.capture.isEnabled)
        check(controls.menu.items.filter { $0.view is PermissionMenuRow && !$0.isHidden }.count == 2)
        update()
        for title in ["Capture Text", "Retry OCR Engine", "Quit TextPicker"] {
            let item = controls.menu.items.first { $0.title == title }!
            check(NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        check(captures == 1 && retries == 1 && permissions == 0 && quits == 1)
        check(controls.highlight(nil).isEmpty && !controls.shortcut.highlighted && !controls.lines.highlighted)

        check(controls.menu.items.allSatisfy { $0.title != "Diagnostics…" })
        check(controls.menu.items.last?.title == "Quit TextPicker")
        check(controls.menu.items.dropLast().last?.isSeparatorItem == true,
              "the final section contains only Quit")

        check(!controls.additive.value && controls.feedback.value && !controls.login.value && controls.loginHelp.isHidden)
        controls.additive.activate()
        controls.feedback.activate()
        controls.login.activate()
        check(additiveSetting && !feedbackSetting && loginRequests == [true])
        check(sound && soundCalls == 1, "success-popup setting is independent of sound")
        let additiveItem = controls.menu.items.first { $0.view === controls.additive }!
        check(controls.highlight(additiveItem) == [36, 49, 123, 124])
        controls.handleKey(123, item: additiveItem)
        check(!additiveSetting)
        controls.update(ready: true, capturing: false, failed: false, access: CaptureAccess(screenRecording: true, accessibility: true, inputReady: true),
            keepLines: lines, playSound: sound, shortcut: custom,
            additiveClipboard: true, showCaptureFeedback: false, loginRequested: true,
            loginHelpTitle: "Approve Launch at Login…")
        check(controls.additive.value && !controls.feedback.value && controls.login.value)
        check(!controls.loginHelp.isHidden && controls.loginHelp.title == "Approve Launch at Login…")
        check(NSApp.sendAction(controls.loginHelp.action!, to: controls.loginHelp.target, from: controls.loginHelp))
        check(loginSettingsCalls == 1)
        update()
        check(controls.loginHelp.isHidden && !controls.login.value)

        // Resizing must keep controls inside a full-width row, with stable text
        // alignment; do not assume a 350-point menu after AppKit sizes its items.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 28))
        let responsive = ShortcutMenuRow()
        host.addSubview(responsive)
        host.setFrameSize(NSSize(width: 410, height: 28))
        responsive.layoutSubtreeIfNeeded()
        check(responsive.frame.width == 410)
        controls.lines.layoutSubtreeIfNeeded()
        let checkboxTitleX = controls.lines.control.frame.minX + controls.lines.control.cell!.titleRect(forBounds: controls.lines.control.bounds).minX
        let shortcutTitleX = responsive.label.frame.minX + responsive.label.cell!.titleRect(forBounds: responsive.label.bounds).minX
        check(abs(shortcutTitleX - checkboxTitleX) < 0.01, "shortcut label aligns to native checkbox title, not its box")
        let permissionRow = controls.permissionRows[.screenRecording]!
        let permissionItem = controls.menu.items.first { $0.view === permissionRow }!
        permissionRow.layoutSubtreeIfNeeded()
        let permissionTitleX = permissionRow.label.frame.minX + permissionRow.label.cell!.titleRect(forBounds: permissionRow.label.bounds).minX
        check(abs(permissionTitleX - checkboxTitleX) < 0.01, "permission labels align with checkbox titles")
        check(controls.highlight(permissionItem) == [36, 49])
        check(permissionRow.button.accessibilityLabel() == "Open Screen Recording settings")
        check(NSApp.sendAction(permissionRow.button.action!, to: permissionRow.button.target, from: permissionRow.button))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        check(permissions == 1)
        controls.handleKey(36, item: permissionItem)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        check(permissions == 2)
        check(responsive.resetButton.frame.maxX == 410 - SettingsMenuRow.trailingInset)
        check(responsive.recordButton.frame.width < 122)
        check(responsive.label.frame.maxX < responsive.recordButton.frame.minX)
        responsive.setRecording(true)
        responsive.layoutSubtreeIfNeeded()
        check(responsive.recordButton.frame.width == 122)
        check(responsive.label.frame.maxX < responsive.recordButton.frame.minX)
        responsive.setRecording(false)
        responsive.layoutSubtreeIfNeeded()
        check(responsive.guidance.isEmpty && responsive.frame.height == 28)

        for row in [controls.lines, controls.additive, controls.sound, controls.feedback, controls.login] {
            let item = controls.menu.items.first { $0.view === row }!
            row.update(false)
            check(item.title == row.label.stringValue)
            check(NSApp.sendAction(item.action!, to: item.target, from: item))
            check(row.value, "every checkbox keeps its native menu action after dispatch cleanup")
            check(NSApp.sendAction(item.action!, to: item.target, from: item))
            check(!row.value)
        }

        if CommandLine.arguments.count > 1 {
            // Fresh views: NSMenu owns layout constraints on its assigned views.
            // This is an offscreen synthetic rendering, never a screen capture.
            let preview = NSBox(frame: NSRect(x: 0, y: 0, width: 350, height: 114))
            preview.boxType = .custom
            preview.borderWidth = 0
            preview.contentViewMargins = .zero
            preview.fillColor = .windowBackgroundColor
            let heading = MenuSectionRow(title: "Settings", font: controls.menu.font)
            let shortcutPreview = ShortcutMenuRow()
            shortcutPreview.update(original)
            let linesPreview = MenuToggleRow(title: "Preserve Line Breaks")
            linesPreview.update(true)
            let soundPreview = MenuToggleRow(title: "Play Sound When Copied")
            soundPreview.update(false)
            for (row, y) in [(heading as NSView, CGFloat(84)), (shortcutPreview, CGFloat(56)),
                             (linesPreview, CGFloat(28)), (soundPreview, CGFloat(0))] {
                preview.contentView!.addSubview(row)
                row.frame.origin = NSPoint(x: 0, y: y)
            }
            preview.layoutSubtreeIfNeeded()
            if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
                }
            }
        }
        print("PASS: \(checks) menu/shortcut/routing checks; no real input, screen, clipboard or standard-preference access")
    }
}
