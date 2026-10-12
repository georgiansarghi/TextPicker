import AppKit
import ScreenCaptureKit

/// Drawing only. Neither input nor keyboard focus ever goes to this window.
final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        setAccessibilitySubrole(.floatingWindow)
        animationBehavior = .none
        isReleasedWhenClosed = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        level = .screenSaver
    }
}

final class SelectionView: NSView {
    var selection = CGRect.zero { didSet { needsDisplay = true } }
    var pointer: CGPoint? { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        if !selection.isEmpty {
            let border = NSBezierPath(rect: selection)
            NSColor.black.setStroke(); border.lineWidth = 3; border.stroke()
            NSColor.white.setStroke(); border.lineWidth = 1.5; border.stroke()
        }
        if let pointer {
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: pointer.x - 9, y: pointer.y))
            cross.line(to: CGPoint(x: pointer.x + 9, y: pointer.y))
            cross.move(to: CGPoint(x: pointer.x, y: pointer.y - 9))
            cross.line(to: CGPoint(x: pointer.x, y: pointer.y + 9))
            NSColor.black.setStroke(); cross.lineWidth = 3; cross.stroke()
            NSColor.white.setStroke(); cross.lineWidth = 1; cross.stroke()
        }
    }
}

/// Quartz global coordinates use a top-left origin; AppKit's desktop is bottom-left.
func appKitPoint(_ point: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: mainDisplayHeight - point.y)
}
func selectionRect(from origin: CGPoint, to point: CGPoint, bounds: CGRect) -> CGRect {
    CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
           width: abs(point.x - origin.x), height: abs(point.y - origin.y)).intersection(bounds)
}

@MainActor
final class CaptureController {
    private struct Overlay {
        let screen: NSScreen
        let panel: SelectionPanel
        let view: SelectionView
    }
    private let input: CaptureInput
    private var overlays: [Overlay] = []
    private var dragIndex: Int?
    private var origin: CGPoint?
    private var mainDisplayHeight: CGFloat = 0
    private var generation: UUID?
    private var deadline: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    private var cancelCallback: (() -> Void)?
    private var selectedCallback: ((CGImage) -> Void)?
    private var failedCallback: ((String) -> Void)?
    var onSelecting: (() -> Void)?
    var onCapturing: (() -> Void)?

    init(input: CaptureInput) { self.input = input }

    func begin(selected: @escaping (CGImage) -> Void, cancelled: @escaping () -> Void,
               failed: @escaping (String) -> Void) {
        if generation != nil { cancel(notify: false) }
        guard input.beginSelection() else {
            input.endSelection()
            failed(input.failureReason)
            return
        }
        generation = UUID()
        cancelCallback = cancelled
        selectedCallback = selected
        failedCallback = failed
        mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        for screen in NSScreen.screens {
            let panel = SelectionPanel(frame: screen.frame)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            panel.contentView = view
            overlays.append(Overlay(screen: screen, panel: panel, view: view))
        }
        guard !overlays.isEmpty else { fail("No displays are available for capture"); return }
        input.onPointer = { [weak self] action, point in self?.handle(action, quartzPoint: point) }
        input.onCancel = { [weak self] in
            Diagnostics.shared.log("Selection cancelled: intercepted Escape/right-click")
            self?.cancel()
        }
        updatePointer(appKitPoint(input.pointer, mainDisplayHeight: mainDisplayHeight))
        for overlay in overlays { overlay.panel.orderFrontRegardless() }
        Diagnostics.shared.log("Selection ready: input intercepted; no key window")
        onSelecting?()
    }

    private func updatePointer(_ point: CGPoint) {
        for overlay in overlays {
            let frame = overlay.screen.frame
            overlay.view.pointer = frame.contains(point) ? CGPoint(x: point.x - frame.minX, y: point.y - frame.minY) : nil
        }
    }
    private func handle(_ action: CaptureInputState.Action, quartzPoint: CGPoint) {
        guard generation != nil, captureTask == nil else { return }
        let point = appKitPoint(quartzPoint, mainDisplayHeight: mainDisplayHeight)
        updatePointer(point)
        if action == .down {
            dragIndex = overlays.firstIndex { $0.screen.frame.contains(point) }
            origin = point
            for overlay in overlays { overlay.view.selection = .zero }
            Diagnostics.shared.log("Selection mouse-down intercepted")
        }
        guard let index = dragIndex, let origin else {
            if action == .up { cancel() }
            return
        }
        let overlay = overlays[index]
        let global = selectionRect(from: origin, to: point, bounds: overlay.screen.frame)
        let local = global.offsetBy(dx: -overlay.screen.frame.minX, dy: -overlay.screen.frame.minY)
        overlay.view.selection = local
        if action == .up {
            guard local.width >= 3, local.height >= 3 else { cancel(); return }
            captureRegion(local, screen: overlay.screen)
        }
    }

    private func captureRegion(_ rect: CGRect, screen: NSScreen) {
        guard let token = generation else { return }
        input.imageCaptureStarted()
        // Keep input blocked and all panels alive until the image exists. Excluding
        // their IDs avoids outline/crosshair pixels without dismissing the menu.
        let overlayIDs = Set(overlays.map { CGWindowID($0.panel.windowNumber) })
        onCapturing?()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.fail("Screen capture took too long. Input restored; try again.")
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
                let callback = self.selectedCallback
                self.cancel(notify: false) // Only now return the mouse/keyboard to the menu.
                callback?(cropped)
            } catch {
                guard let self, self.generation == token else { return }
                self.fail("Screen capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ message: String) {
        let callback = failedCallback
        cancel(notify: false)
        callback?(message)
    }
    func cancel(notify: Bool = true) {
        let callback = generation == nil ? nil : cancelCallback
        generation = nil
        captureTask?.cancel(); captureTask = nil
        deadline?.cancel(); deadline = nil
        cancelCallback = nil; selectedCallback = nil; failedCallback = nil
        origin = nil; dragIndex = nil
        for overlay in overlays { overlay.panel.orderOut(nil); overlay.panel.close() }
        overlays.removeAll()
        input.onPointer = nil; input.onCancel = nil
        input.endSelection()
        if notify { callback?() }
    }
}
