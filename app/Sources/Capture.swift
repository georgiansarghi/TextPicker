import AppKit
import ScreenCaptureKit

private enum SelectionAppearance {
    // Keep panel and view in sync. 0.001 can quantize to zero in an 8-bit
    // backing store, making the overlay click-through. 0.01 is user-validated.
    static let hitTestOpacity: CGFloat = 0.01
    static var hitTestColor: NSColor { .black.withAlphaComponent(hitTestOpacity) }
    static let minimumSelectionSize: CGFloat = 3
}

/// A transient overlay, never a main window or a foreground application switch.
final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        setAccessibilitySubrole(.floatingWindow)
        animationBehavior = .none
        isReleasedWhenClosed = false
        hasShadow = false
        isOpaque = false
        backgroundColor = SelectionAppearance.hitTestColor
        ignoresMouseEvents = false
        level = .screenSaver
    }
}

final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var cursorTracking: NSTrackingArea?
    private var origin: NSPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTracking = area
        super.updateTrackingAreas()
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { claimCursor() }
    private func claimCursor() {
        // Nonactivating key focus lets AppKit own the cursor on this display,
        // without NSApp.activate or switching the foreground application.
        window?.makeKey()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
    }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }
    override func draw(_ dirtyRect: NSRect) {
        // Clear old outlines. No screenshot is ever painted over the desktop.
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        // Nearly transparent, but not click-through after pixel quantization.
        SelectionAppearance.hitTestColor.setFill()
        bounds.fill()
        if !selection.isEmpty {
            let border = NSBezierPath(rect: selection)
            NSColor.black.setStroke()
            border.lineWidth = 3
            border.stroke()
            NSColor.white.setStroke()
            border.lineWidth = 1.5
            border.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        onDiagnostic?("Selection mouse-down")
        claimCursor()
        origin = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        NSCursor.crosshair.set()
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                           width: abs(point.x - origin.x), height: abs(point.y - origin.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard origin != nil else { return }
        defer { origin = nil }
        mouseDragged(with: event)
        guard selection.width >= SelectionAppearance.minimumSelectionSize,
              selection.height >= SelectionAppearance.minimumSelectionSize else {
            cancelSelection(reason: "empty drag")
            return
        }
        onDiagnostic?("Selection mouse-up accepted; capturing")
        onSelect?(selection)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelSelection(reason: "Escape") }
    }
    override func rightMouseDown(with event: NSEvent) { cancelSelection(reason: "right-click") }
    private func cancelSelection(reason: String) {
        onDiagnostic?("Selection cancelled: \(reason)")
        onCancel?()
    }
}

@MainActor
final class CaptureController {
    private var panels: [NSPanel] = []
    private var generation: UUID?
    private var deadline: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    private var cancelCallback: (() -> Void)?
    private var escapeHotKey: GlobalHotKey?
    private var cursorPushed = false
    var onSelecting: (() -> Void)?
    var onCapturing: (() -> Void)?

    func begin(selected: @escaping (CGImage) -> Void, cancelled: @escaping () -> Void,
               failed: @escaping (String) -> Void) {
        cancel(notify: false)
        let token = UUID()
        generation = token
        cancelCallback = cancelled
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            cancel(notify: false)
            failed("No displays are available for capture")
            return
        }
        let escape = GlobalHotKey(keyCode: 53, modifiers: 0, eventID: 2)
        escape.onPress = { [weak self] in
            Diagnostics.shared.log("Selection cancelled: Escape hotkey")
            self?.cancel()
        }
        escape.register()
        escapeHotKey = escape
        if escape.status != 0 {
            Diagnostics.shared.log("Selection Escape registration failed status=\(escape.status); panel Esc/right-click remain available")
        }
        let mouse = NSEvent.mouseLocation
        var keyPanel: NSPanel?
        for screen in screens {
            let panel = SelectionPanel(frame: screen.frame)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onSelect = { [weak self] rect in
                guard let self, self.generation == token else { return }
                self.captureRegion(rect, screen: screen, token: token, selected: selected, failed: failed)
            }
            view.onCancel = { [weak self] in self?.cancel() }
            view.onDiagnostic = { Diagnostics.shared.log($0) }
            panel.contentView = view
            panel.makeFirstResponder(view)
            panels.append(panel)
            panel.orderFrontRegardless()
            view.updateTrackingAreas()
            panel.invalidateCursorRects(for: view)
            if screen.frame.contains(mouse) { keyPanel = panel }
        }
        (keyPanel ?? panels.first)?.makeKey()
        NSCursor.crosshair.push()
        cursorPushed = true
        Diagnostics.shared.log("Selection overlay ready panels=\(panels.count)")
        onSelecting?()
        // AppKit processes key-window/cursor notifications after ordering.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, !self.panels.isEmpty else { return }
            NSCursor.crosshair.set()
        }
    }

    private func captureRegion(_ rect: CGRect, screen: NSScreen, token: UUID,
                               selected: @escaping (CGImage) -> Void, failed: @escaping (String) -> Void) {
        let overlayIDs = Set(panels.map { CGWindowID($0.windowNumber) })
        dismissOverlay()
        onCapturing?()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.cancel(notify: false)
            failed("Screen capture took too long. Check Screen Recording permission and try again.")
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        captureTask = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == id.uint32Value }) else {
                    throw appError("The selected display is no longer available")
                }
                // Panels are already hidden without animation. Explicit exclusion
                // also prevents a queued compositor frame from capturing our outline.
                let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { overlayIDs.contains($0.windowID) })
                let config = SCStreamConfiguration()
                config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
                config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
                config.showsCursor = false
                config.captureResolution = .best
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard self.generation == token, !Task.isCancelled else { return }
                let pixels = pixelCrop(selection: rect, viewSize: screen.frame.size,
                                       imageSize: CGSize(width: image.width, height: image.height))
                guard let cropped = image.cropping(to: pixels) else { throw appError("The selected region could not be captured") }
                self.cancel(notify: false)
                selected(cropped)
            } catch {
                guard let self, self.generation == token else { return }
                self.cancel(notify: false)
                failed("Screen capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func dismissOverlay() {
        escapeHotKey = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    func cancel(notify: Bool = true) {
        let callback = generation == nil ? nil : cancelCallback
        generation = nil
        captureTask?.cancel(); captureTask = nil
        deadline?.cancel(); deadline = nil
        cancelCallback = nil
        dismissOverlay()
        if notify { callback?() }
    }
}
