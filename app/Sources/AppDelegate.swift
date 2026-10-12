import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Phase { case starting, ready, preparing, selecting, recognizing, failed }
    private var phase: Phase = .starting
    private var backend = Backend(rawValue: UserDefaults.standard.string(forKey: "backend") ?? "") ?? .mlxSmall
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let captureItem = NSMenuItem(title: "Capture Text", action: #selector(captureText), keyEquivalent: "2")
    private let cancelItem = NSMenuItem(title: "Cancel Current Capture", action: #selector(cancelCapture), keyEquivalent: "")
    private var modelItems: [NSMenuItem] = []
    private var lineBreaksItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private let capture = CaptureController()
    private let toast = Toast()
    private let hotKey = GlobalHotKey()
    private var worker: OCRWorker!
    private var files: CaptureFiles!
    private var currentImage: URL?
    private var selectionGeneration: UUID?
    private var selectionDisplayLayout: [DisplayLayoutEntry] = []
    private var selectionFinishedAt: Double = 0
    private var lastResult = "No captures yet"
    private var lastError = "None"
    private var testWindow: NSWindow?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var displayObserver: NSObjectProtocol?
    private var keepLines: Bool { !UserDefaults.standard.bool(forKey: "joinLines") }
    private var playSound: Bool { UserDefaults.standard.bool(forKey: "playSound") }
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown" }
    private var isCapturing: Bool { [.preparing, .selecting, .recognizing].contains(phase) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { files = try CaptureFiles() }
        catch { alert("Cannot initialize TextOCR", error.localizedDescription); NSApp.terminate(nil); return }
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
        hotKey.onPress = { [weak self] in
            guard let self else { return }
            Diagnostics.shared.log("Shortcut received phase=\(self.phase)")
            if self.isCapturing { self.cancelActiveCapture(reason: "shortcut") } else { self.captureText() }
        }
        hotKey.register()
        Diagnostics.shared.log("Launch v\(appVersion) screen_permission=\(CGPreflightScreenCaptureAccess()) hotkey_status=\(hotKey.status)")
        if hotKey.status != 0 {
            DispatchQueue.main.async { [weak self] in
                self?.alert("⌘⇧2 is unavailable", "Another app may own this shortcut (for example TextSniper). Quit it, then quit and reopen TextOCR. Capture Text in this menu still works. Error: \(self?.hotKey.status ?? 0).")
            }
        }
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
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "TextOCR")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "TextOCR — local screen text capture", action: nil, keyEquivalent: ""))
        menu.items[0].isEnabled = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        captureItem.target = self
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(captureItem)
        cancelItem.target = self
        menu.addItem(cancelItem)
        menu.addItem(.separator())
        let modelMenu = NSMenu(title: "OCR Model")
        modelMenu.autoenablesItems = false
        for backend in Backend.allCases {
            let item = NSMenuItem(title: backend.title, action: #selector(selectBackend(_:)), keyEquivalent: "")
            item.representedObject = backend.rawValue
            item.target = self
            modelItems.append(item)
            modelMenu.addItem(item)
        }
        let parent = NSMenuItem(title: "OCR Model", action: nil, keyEquivalent: "")
        parent.submenu = modelMenu
        menu.addItem(parent)
        lineBreaksItem = item("Preserve Line Breaks", #selector(toggleLines))
        soundItem = item("Play Sound When Copied", #selector(toggleSound))
        menu.addItem(lineBreaksItem); menu.addItem(soundItem)
        menu.addItem(item("Restart OCR Engine", #selector(restartEngine)))
        menu.addItem(.separator())
        menu.addItem(item("Open Test Card…", #selector(openTestCard)))
        menu.addItem(item("Screen Recording Permission…", #selector(openPermissions)))
        menu.addItem(item("Diagnostics…", #selector(showDiagnostics)))
        menu.addItem(item("Testing Guide…", #selector(openGuide)))
        menu.addItem(.separator())
        let quit = item("Quit TextOCR", #selector(quitApp))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }
    private func refreshMenu() {
        guard statusItem != nil else { return }
        let status: String
        switch phase {
        case .starting: status = "Warming \(backend.shortTitle)…"
        case .ready: status = "Ready • \(backend.shortTitle)"
        case .preparing: status = "Preparing screen capture…"
        case .selecting: status = "Drag a region • Esc to cancel"
        case .recognizing: status = "Recognizing • \(backend.shortTitle)…"
        case .failed: status = "OCR unavailable — restart or change model"
        }
        statusLine.title = status
        statusItem.button?.title = [.starting, .preparing, .recognizing].contains(phase) ? " ···" : ""
        statusItem.button?.toolTip = "TextOCR — \(status)\nCapture: ⌘⇧2"
        captureItem.isEnabled = phase == .ready
        cancelItem.isEnabled = isCapturing
        for item in modelItems {
            item.state = item.representedObject as? String == backend.rawValue ? .on : .off
            item.isEnabled = !isCapturing
        }
        lineBreaksItem.state = keepLines ? .on : .off
        soundItem.state = playSound ? .on : .off
    }

    @objc private func captureText() {
        guard phase == .ready else {
            if phase == .failed { restartEngine() }
            toast.show("OCR engine is warming up", detail: "Try ⌘⇧2 when the menu says Ready")
            return
        }
        toast.dismiss()
        guard CGPreflightScreenCaptureAccess() else {
            NSApp.activate(ignoringOtherApps: true)
            _ = CGRequestScreenCaptureAccess()
            guard CGPreflightScreenCaptureAccess() else {
                let response = alert("Allow Screen Recording for TextOCR",
                    "Enable TextOCR in System Settings → Privacy & Security → Screen & System Audio Recording. Then quit and reopen TextOCR if macOS asks. Recognition stays entirely on this Mac. No Accessibility permission is needed.",
                    button: "Open Settings")
                if response == .alertFirstButtonReturn { openPermissions() }
                return
            }
            beginSelection()
            return
        }
        // Menu clicks finish closing before screen snapshots are taken.
        beginSelection()
    }

    private func beginSelection() {
        let token = UUID()
        selectionGeneration = token
        selectionDisplayLayout = DisplayLayoutEntry.current()
        phase = .preparing; refreshMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.phase == .preparing, self.selectionGeneration == token else { return }
            self.capture.begin(selected: { [weak self] image in
                guard let self else { return }
                do {
                    self.currentImage = try self.files.save(image)
                    self.phase = .recognizing; self.refreshMenu()
                    self.toast.show("Recognizing text…", detail: "\(self.backend.shortTitle) • ⌘⇧2 to cancel", duration: 10)
                    self.worker.recognize(self.currentImage!)
                } catch { self.fail(error.localizedDescription) }
            }, cancelled: { [weak self] in
                guard let self else { return }
                self.phase = self.worker.ready ? .ready : .failed
                self.refreshMenu()
            }, failed: { [weak self] message in self?.fail(message, stopWorker: false) })
        }
    }

    private func complete(text: String, ocrMS: Double) {
        guard phase == .recognizing else { return }
        files.remove(currentImage); currentImage = nil
        phase = .ready
        let output = clipboardText(text, keepLineBreaks: keepLines)
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - selectionFinishedAt) * 1000)
        if output.isEmpty {
            toast.show("No text found", detail: "Clipboard unchanged — try a tighter selection")
            lastResult = "No text found (\(elapsed) ms after selection)"
        } else {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(output, forType: .string) {
                lastResult = "Copied \(output.count) characters; OCR \(Int(ocrMS)) ms; after selection \(elapsed) ms"
                toast.show("Copied \(output.count) characters", detail: "\(backend.shortTitle) • \(elapsed) ms • paste with ⌘V")
                if playSound { NSSound(named: "Pop")?.play() }
            } else {
                lastResult = "Clipboard write failed"
                toast.show("Could not write to clipboard", detail: "Try capturing again")
            }
        }
        Diagnostics.shared.log("backend=\(backend.rawValue) \(lastResult)")
        refreshMenu()
    }

    private func fail(_ message: String, stopWorker: Bool = true) {
        selectionGeneration = nil
        capture.cancel(notify: false)
        if stopWorker { worker?.stop() }
        files?.remove(currentImage); currentImage = nil
        lastError = message
        phase = worker?.ready == true ? .ready : .failed
        Diagnostics.shared.log("Failure: \(message)")
        refreshMenu()
        toast.show("Capture could not finish", detail: String(message.prefix(85)), duration: 5)
    }

    @objc private func cancelCapture() { cancelActiveCapture(reason: "menu") }
    private func cancelActiveCapture(reason: String) {
        guard isCapturing else { return }
        let cancelledPhase = phase
        let wasRecognizing = phase == .recognizing
        selectionGeneration = nil
        capture.cancel(notify: false)
        files.remove(currentImage); currentImage = nil
        toast.dismiss()
        if wasRecognizing { restartEngine() }
        else { phase = worker.ready ? .ready : .failed; refreshMenu() }
        Diagnostics.shared.log("Capture cancelled reason=\(reason) phase=\(cancelledPhase); clipboard unchanged")
    }
    @objc private func restartEngine() {
        guard worker != nil else { return }
        selectionGeneration = nil
        capture.cancel(notify: false)
        files.remove(currentImage); currentImage = nil
        toast.dismiss()
        phase = .starting
        refreshMenu()
        worker.start(backend)
    }
    @objc private func selectBackend(_ item: NSMenuItem) {
        guard !isCapturing, let raw = item.representedObject as? String, let value = Backend(rawValue: raw) else { return }
        backend = value
        UserDefaults.standard.set(raw, forKey: "backend")
        restartEngine()
    }
    @objc private func toggleLines() {
        UserDefaults.standard.set(keepLines, forKey: "joinLines")
        refreshMenu()
    }
    @objc private func toggleSound() {
        UserDefaults.standard.set(!playSound, forKey: "playSound")
        refreshMenu()
    }
    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func showDiagnostics() {
        let permission = CGPreflightScreenCaptureAccess() ? "Granted" : "Not granted"
        let text = "Version: \(appVersion) (Apple Silicon)\nBackend: \(backend.shortTitle)\nScreen Recording: \(permission)\nShortcut: ⌘⇧2 (registration status \(hotKey.status))\n\nLast result: \(lastResult)\nLast error: \(lastError)\n\nOCR is offline. No screenshot/text history is saved. Logs contain timings/errors only."
        if alert("TextOCR Diagnostics", text, button: "Open Log") == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Diagnostics.shared.url)
        }
    }
    @objc private func openGuide() {
        if let url = Bundle.main.url(forResource: "TESTING", withExtension: "md") { NSWorkspace.shared.open(url) }
    }
    @objc private func openTestCard() {
        if let testWindow { NSApp.activate(ignoringOtherApps: true); testWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 690, height: 355),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TextOCR Test Card"
        window.isReleasedWhenClosed = false
        let text = "Capture a region with ⌘⇧2, then paste into your editor.\n\nThe quick brown fox jumps over the lazy dog.\nOrder #A1042 costs $39.95 before tax.\n\nGrüße aus München! Öffnen Sie die Einstellungen.\nDie Straße führt über die Brücke zum Café.\nRechnungsbetrag: 1.234,56 € inkl. 19 % MwSt.\n\nconst total = items.reduce((sum, x) => sum + x.price, 0);"
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        label.frame = CGRect(x: 24, y: 25, width: 642, height: 285)
        window.contentView?.addSubview(label)
        window.center()
        testWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        capture.cancel(notify: false)
        worker?.stop()
        files?.remove(currentImage)
    }
    @discardableResult private func alert(_ title: String, _ message: String, button: String = "OK") -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: button)
        if button != "OK" { alert.addButton(withTitle: "Cancel") }
        return alert.runModal()
    }
}
