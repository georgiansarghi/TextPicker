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
    private var deadline: Timer?
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
        let timeout = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.fail("Screen capture took too long. Input restored; try again.")
            }
        }
        deadline = timeout
        RunLoop.main.add(timeout, forMode: .common)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let screenSize = screen.frame.size
        // A MainActor Task may wait behind TextPicker's own NSMenu tracking loop.
        // Acquire off-main, then deliver through the same common-mode path as
        // selection events. No AppKit objects are accessed by the detached task.
        captureTask = Task.detached { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard let displayID, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw appError("The selected display is no longer available")
                }
                let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { overlayIDs.contains($0.windowID) })
                let request = try RegionCaptureRequest(selection: rect, viewSize: screenSize,
                                                       contentSize: filter.contentRect.size,
                                                       pointPixelScale: CGFloat(filter.pointPixelScale))
                // Request only the selection's tight logical-point envelope.
                // A boundary-only trim removes ScreenCaptureKit's alignment halo;
                // no full-display image, resampling or alpha flattening is used.
                let image = try await request.capture { config in
                    try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                }
                let metadata = CaptureImageDiagnostics(image)
                onCaptureRunLoop { [weak self] in
                    guard let self, self.generation == token else { return }
                    Diagnostics.shared.log("Region capture requested=\(request.captureWidth)x\(request.captureHeight) selected=\(request.pixelWidth)x\(request.pixelHeight) \(metadata.description)")
                    let callback = self.selectedCallback
                    self.cancel(notify: false) // Only now return input to the menu.
                    callback?(image)
                }
            } catch {
                let message = "Screen capture failed: \(error.localizedDescription)"
                onCaptureRunLoop { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fail(message)
                }
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
        deadline?.invalidate(); deadline = nil
        cancelCallback = nil; selectedCallback = nil; failedCallback = nil
        origin = nil; dragIndex = nil
        for overlay in overlays { overlay.panel.orderOut(nil); overlay.panel.close() }
        overlays.removeAll()
        input.onPointer = nil; input.onCancel = nil
        input.endSelection()
        if notify { callback?() }
    }
}
