import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Phase { case starting, ready, preparing, selecting, recognizing, failed }
    private var phase: Phase = .starting
    private let availableBackends = Backend.bundled
    private var backend = Backend.coreMLCPU
    private var statusItem: NSStatusItem!
    private var controls: CaptureMenu!
    private var shortcut = CaptureShortcut.restored()
    private var menuOpen = false
    private var recordingTimer: Timer?
    private let input = CaptureInput()
    private lazy var capture = CaptureController(input: input)
    private let toast = Toast()
    private var worker: OCRWorker!
    private var files: CaptureFiles!
    private var currentImage: URL?
    private var selectionDisplayLayout: [DisplayLayoutEntry] = []
    private var selectionFinishedAt: Double = 0
    private lazy var permissionStatus = PermissionStatus(actions: .live(check: { [weak self] in
        guard let self else { return CaptureAccess() }
        return self.readAccess(repairInput: !self.isCapturing)
    }))
    private var access: CaptureAccess { permissionStatus.access }
    private lazy var permissionMenuMonitor = PermissionRefreshMonitor(shouldRefresh: { [weak self] in
        guard let self else { return false }
        return self.menuOpen && !self.isCapturing
    }, refresh: { [weak self] in
        self?.permissionStatus.refresh()
        self?.refreshMenu()
    })
    private var permissionsWindow: PermissionsWindowController?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var displayObserver: NSObjectProtocol?
    private var keepLines: Bool { !UserDefaults.standard.bool(forKey: "joinLines") }
    private var playSound: Bool { UserDefaults.standard.bool(forKey: "playSound") }
    private var additiveClipboard: Bool { UserDefaults.standard.bool(forKey: "additiveClipboard") }
    private var clipboardSession = AdditiveClipboardSession()
    private var showCaptureFeedback: Bool { CaptureFeedbackPreference.isEnabled() }
    private let loginItem = LoginItemController(actions: .live)
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown" }
    private var isCapturing: Bool { [.preparing, .selecting, .recognizing].contains(phase) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { files = try CaptureFiles() }
        catch { showStartupError("Cannot initialize TextPicker", error.localizedDescription); NSApp.terminate(nil); return }
        guard !availableBackends.isEmpty else {
            showStartupError("Invalid TextPicker build", "No valid OCR engine is configured. Reinstall TextPicker.")
            NSApp.terminate(nil); return
        }
        let saved = UserDefaults.standard.string(forKey: "backend")
        backend = Backend.restored(saved, available: availableBackends)
        // A smaller edition must not overwrite a valid preference for an engine
        // it omits. Returning to the full edition restores that saved choice.
        if saved.flatMap(Backend.init(rawValue:)) == nil {
            UserDefaults.standard.set(backend.rawValue, forKey: "backend")
        }
        toast.suppressRoutineNotifications = !showCaptureFeedback
        setupMenu()
        guard let resources = Bundle.main.resourceURL else { NSApp.terminate(nil); return }
        worker = OCRWorker(resources: resources)
        worker.onReady = { [weak self] milliseconds in
            guard let self else { return }
            self.phase = .ready
            Diagnostics.shared.log("Ready backend=\(self.backend.rawValue) warmup_ms=\(Int(milliseconds))")
            self.refreshMenu()
        }
        worker.onResult = { [weak self] text, milliseconds in self?.complete(text: text, ocrMS: milliseconds) }
        worker.onFailure = { [weak self] message in self?.fail(message) }
        capture.onSelecting = { [weak self] in self?.phase = .selecting; self?.refreshMenu() }
        capture.onCapturing = { [weak self] in
            self?.selectionFinishedAt = ProcessInfo.processInfo.systemUptime
            self?.phase = .preparing
            self?.refreshMenu()
        }
        input.onShortcut = { [weak self] in
            guard let self else { return }
            Diagnostics.shared.log("Shortcut received phase=\(self.phase)")
            if self.isCapturing { self.cancelActiveCapture(reason: "shortcut") } else { self.captureText() }
        }
        input.onFailure = { [weak self] message in
            guard let self else { return }
            self.fail(message, stopWorker: false)
            self.permissionStatus.refresh()
            if !self.access.ready { self.showPermissions() }
        }
        permissionStatus.refresh()
        Diagnostics.shared.log("Launch v\(appVersion) screen_permission=\(access.screenRecording) input_access=\(access.inputReady)")
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.cancelActiveCapture(reason: "sleep"); self?.worker.stop(); self?.phase = .starting; self?.refreshMenu()
            }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartEngine() }
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .preparing || self.phase == .selecting else { return }
                guard self.selectionDisplayLayout != DisplayLayoutEntry.current() else {
                    Diagnostics.shared.log("Display notification ignored: geometry unchanged")
                    return
                }
                self.cancelActiveCapture(reason: "display layout changed")
            }
        }
        restartEngine()
        // Missing access gets one persistent, actionable setup window—not a
        // disappearing toast or a chain of modal alerts. Healthy launches stay quiet.
        if !access.ready { showPermissions() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isCapturing else { return false }
        permissionStatus.refresh()
        if !access.ready { showPermissions() }
        return false
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "TextPicker")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeading
        controls = CaptureMenu(actions: .init(
            capture: { [weak self] in self?.captureText() },
            retry: { [weak self] in self?.restartEngine() },
            permission: { [weak self] permission, action in self?.performPermissionAction(action, for: permission) },
            backend: { [weak self] in self?.selectBackend($0) },
            lines: { [weak self] value in
                guard let self else { return }
                if self.controls.shortcut.recording { self.stopRecordingShortcut() }
                UserDefaults.standard.set(!value, forKey: "joinLines")
                self.refreshMenu()
            },
            sound: { [weak self] value in
                guard let self else { return }
                if self.controls.shortcut.recording { self.stopRecordingShortcut() }
                UserDefaults.standard.set(value, forKey: "playSound")
                self.refreshMenu()
            },
            record: { [weak self] in self?.beginRecordingShortcut() },
            resetShortcut: { [weak self] in self?.saveShortcut(.default) },
            quit: { NSApp.terminate(nil) },
            additiveClipboard: { [weak self] value in
                guard let self else { return }
                if self.controls.shortcut.recording { self.stopRecordingShortcut() }
                self.clipboardSession.setEnabled(value)
                UserDefaults.standard.set(value, forKey: "additiveClipboard")
                self.refreshMenu()
            },
            showCaptureFeedback: { [weak self] value in
                guard let self else { return }
                if self.controls.shortcut.recording { self.stopRecordingShortcut() }
                CaptureFeedbackPreference.setEnabled(value)
                self.toast.suppressRoutineNotifications = !value
                self.refreshMenu()
            },
            login: { [weak self] value in
                guard let self else { return }
                if self.controls.shortcut.recording { self.stopRecordingShortcut() }
                self.loginItem.setRequested(value)
                self.refreshMenu()
            },
            loginSettings: { [weak self] in self?.loginItem.openSettings() }), backends: availableBackends)
        controls.menu.delegate = self
        statusItem.menu = controls.menu
        input.captureShortcut = shortcut
        input.onRecordedShortcut = { [weak self] key, flags in
            guard let self, self.menuOpen, self.controls.shortcut.recording else { return }
            if key == 53 { self.stopRecordingShortcut(); return }
            let value = CaptureShortcut(keyCode: key, modifiers: flags.rawValue)
            if let error = value.validationError {
                self.controls.shortcut.setRecording(true, message: error)
            } else { self.saveShortcut(value) }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        loginItem.refresh()
        if !isCapturing { permissionStatus.refresh() }
        refreshMenu()
        permissionMenuMonitor.start()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        permissionMenuMonitor.stop()
        stopRecordingShortcut()
        input.endMenuTracking()
        _ = controls.highlight(nil)
    }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let keys = controls.highlight(item)
        guard !controls.shortcut.recording else { return }
        input.setMenuKeys(keys) { [weak self, weak item] key in
            guard let self, let item, self.menuOpen, self.controls.menu.highlightedItem === item else { return }
            self.controls.handleKey(key, item: item)
        }
    }
    private func beginRecordingShortcut() {
        guard menuOpen, !isCapturing else { return }
        if controls.shortcut.recording { stopRecordingShortcut(); return }
        guard input.beginShortcutRecording() else {
            controls.shortcut.setRecording(false, message: "Enable Accessibility under Permissions first.")
            return
        }
        controls.shortcut.setRecording(true)
        refreshMenu()
        // Bound interception even if a menu-close notification is ever missed.
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecordingShortcut() }
        }
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        NSAccessibility.post(element: controls.shortcut.recordButton, notification: .valueChanged)
    }
    private func stopRecordingShortcut() {
        recordingTimer?.invalidate(); recordingTimer = nil
        input.endShortcutRecording()
        controls?.shortcut.setRecording(false)
        if menuOpen { menu(controls.menu, willHighlight: controls.menu.highlightedItem) }
        refreshMenu()
    }
    private func saveShortcut(_ value: CaptureShortcut) {
        guard value.validationError == nil, !isCapturing else { return }
        shortcut = value
        shortcut.save()
        input.captureShortcut = value
        stopRecordingShortcut()
        NSAccessibility.post(element: controls.shortcut.recordButton, notification: .valueChanged)
    }
    private func refreshMenu() {
        guard statusItem != nil else { return }
        let status: String
        switch phase {
        case .starting: status = "Warming \(backend.shortTitle)…"
        case .ready: status = access.ready ? "Ready • \(backend.shortTitle)" : "Permissions required"
        case .preparing: status = "Preparing screen capture…"
        case .selecting: status = "Drag a region • Esc to cancel"
        case .recognizing: status = "Recognizing • \(backend.shortTitle)…"
        case .failed: status = "OCR unavailable — use Retry OCR Engine"
        }
        let preservingSelection = menuOpen && [.preparing, .selecting].contains(phase)
        if !preservingSelection {
            statusItem.button?.title = [.starting, .preparing, .recognizing].contains(phase) ? " ···" : ""
            statusItem.button?.toolTip = "TextPicker — \(status)\nCapture: \(shortcut.display)"
        }
        // The tap still dispatches the shortcut when canStartCapture is false,
        // so missing access opens setup without arming/blocking selection input.
        input.canStartCapture = phase == .ready && access.ready && input.available
        controls.update(ready: phase == .ready, capturing: isCapturing, failed: phase == .failed,
                        access: access, backend: backend, keepLines: keepLines,
                        playSound: playSound, shortcut: shortcut, preservingSelection: preservingSelection,
                        additiveClipboard: additiveClipboard, showCaptureFeedback: showCaptureFeedback,
                        loginRequested: loginItem.status.requested, loginHelpTitle: loginItem.helpTitle, loginError: loginItem.error,
                        requestedPermissions: permissionStatus.requested, permissionError: permissionStatus.settingsError)
    }

    private func captureText() {
        guard phase == .ready else {
            if phase == .failed { restartEngine() }
            toast.show(.gettingReady)
            return
        }
        toast.dismiss()
        permissionStatus.refresh()
        guard access.ready else {
            input.endSelection()
            showPermissions()
            return
        }
        permissionsWindow?.close()
        beginSelection()
    }

    private func beginSelection() {
        selectionDisplayLayout = DisplayLayoutEntry.current()
        phase = .preparing; refreshMenu()
        // Interception is already armed by the tap. Install pointer callbacks now,
        // not after a timer that could lose the start of a fast drag.
        capture.begin(selected: { [weak self] image in
            guard let self else { return }
            do {
                self.currentImage = try self.files.save(image)
                self.phase = .recognizing; self.refreshMenu()
                self.toast.show(.reading)
                self.worker.recognize(self.currentImage!)
            } catch { self.fail(error.localizedDescription) }
        }, cancelled: { [weak self] in
            guard let self else { return }
            self.phase = self.worker.ready ? .ready : .failed
            self.refreshMenu()
        }, failed: { [weak self] message in self?.fail(message, stopWorker: false) })
    }

    private func complete(text: String, ocrMS: Double) {
        guard phase == .recognizing else { return }
        files.remove(currentImage); currentImage = nil
        phase = .ready
        toast.dismiss() // Cancel pending progress before presenting the result.
        clipboardSession.setEnabled(additiveClipboard)
        let appended = clipboardSession.isAppending
        let output = clipboardSession.proposedText(text, keepLineBreaks: keepLines)
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - selectionFinishedAt) * 1000)
        let lastResult: String
        if output.isEmpty {
            toast.show(.noText)
            lastResult = "No text found (\(elapsed) ms after selection)"
        } else {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(output, forType: .string) {
                clipboardSession.didCopy(output)
                lastResult = "Copied \(output.count) characters; OCR \(Int(ocrMS)) ms; after selection \(elapsed) ms"
                toast.show(appended ? .added : .copied)
                if playSound { NSSound(named: "Pop")?.play() }
            } else {
                lastResult = "Clipboard write failed"
                toast.show(.copyFailed)
            }
        }
        Diagnostics.shared.log("backend=\(backend.rawValue) \(lastResult)")
        refreshMenu()
    }

    private func fail(_ message: String, stopWorker: Bool = true) {
        capture.cancel(notify: false)
        if stopWorker { worker?.stop() }
        files?.remove(currentImage); currentImage = nil
        phase = worker?.ready == true ? .ready : .failed
        Diagnostics.shared.log("Failure: \(message)")
        refreshMenu()
        toast.show(.forFailure(message, engineReady: worker?.ready == true))
    }

    private func cancelActiveCapture(reason: String) {
        guard isCapturing else { return }
        let cancelledPhase = phase
        let wasRecognizing = phase == .recognizing
        capture.cancel(notify: false)
        files.remove(currentImage); currentImage = nil
        toast.dismiss()
        if wasRecognizing { restartEngine() }
        else { phase = worker.ready ? .ready : .failed; refreshMenu() }
        Diagnostics.shared.log("Capture cancelled reason=\(reason) phase=\(cancelledPhase); clipboard unchanged")
    }
    private func restartEngine() {
        guard worker != nil else { return }
        capture.cancel(notify: false)
        files.remove(currentImage); currentImage = nil
        toast.dismiss()
        phase = .starting
        refreshMenu()
        worker.start(backend)
    }
    private func selectBackend(_ value: Backend) {
        guard !isCapturing, availableBackends.contains(value), value != backend else { return }
        backend = value
        UserDefaults.standard.set(value.rawValue, forKey: "backend")
        restartEngine()
    }
    private func readAccess(repairInput: Bool) -> CaptureAccess {
        let trusted = AXIsProcessTrusted()
        if repairInput && !isCapturing && trusted && !input.available { input.install() }
        return CaptureAccess(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: trusted,
                             inputReady: input.available)
    }
    private func performPermissionAction(_ action: PermissionMenuAction, for permission: CapturePermission) {
        guard !isCapturing else { return }
        stopRecordingShortcut()
        input.endSelection()
        permissionStatus.perform(action, for: permission)
        permissionsWindow?.refresh()
        refreshMenu()
    }
    private func showPermissions() {
        cancelActiveCapture(reason: "permissions")
        input.endSelection()
        toast.dismiss()
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController(model: permissionStatus, onRefresh: { [weak self] _ in
                self?.refreshMenu()
            }, onQuit: { NSApp.terminate(nil) })
        }
        permissionsWindow?.present()
    }
    func applicationWillTerminate(_ notification: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        if let sleepObserver { workspace.removeObserver(sleepObserver) }
        if let wakeObserver { workspace.removeObserver(wakeObserver) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        sleepObserver = nil; wakeObserver = nil; displayObserver = nil
        recordingTimer?.invalidate(); recordingTimer = nil
        permissionMenuMonitor.stop()
        toast.dismiss()
        permissionsWindow?.shutdown()
        capture.cancel(notify: false)
        input.stop()
        worker?.stop()
        files?.remove(currentImage)
    }
    private func showStartupError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}
