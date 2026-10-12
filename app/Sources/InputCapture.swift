import AppKit
import ApplicationServices

/// Small, testable routing policy. No event text is read or retained.
struct CaptureInputState {
    enum Mode { case idle, selecting, capturing }
    enum Action: Equatable { case shortcut, move, down, up, cancel }
    struct Decision {
        let consume: Bool
        let action: Action?
    }
    private(set) var mode: Mode = .idle
    private var swallowedKeys: Set<Int64> = []
    private var swallowedButtons: Set<Int64> = []
    var active: Bool { mode != .idle }

    mutating func begin() { mode = .selecting }
    mutating func capture() { mode = .capturing }
    mutating func end() { mode = .idle } // Still swallow matching releases after cancellation.
    mutating func reset() { self = CaptureInputState() }

    mutating func route(_ type: CGEventType, key: Int64 = 0, button: Int64 = 0,
                        shortcut: Bool = false, repeatKey: Bool = false,
                        canBegin: Bool = false) -> Decision {
        func eat(_ action: Action? = nil) -> Decision { Decision(consume: true, action: action) }
        let pass = Decision(consume: false, action: nil)
        // A release whose press predates capture must still reach its original app.
        if type == .keyUp { return swallowedKeys.remove(key) != nil ? eat() : pass }
        if type == .keyDown {
            if shortcut {
                let first = swallowedKeys.insert(key).inserted
                guard first && !repeatKey else { return eat() }
                if !active && canBegin { begin() }
                return eat(.shortcut)
            }
            if swallowedKeys.contains(key) { return eat() }
            guard active else { return pass }
            swallowedKeys.insert(key)
            if key == 53 && !repeatKey { capture(); return eat(.cancel) }
            return eat()
        }
        let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
        let up = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
        if up {
            guard swallowedButtons.remove(button) != nil else { return pass }
            if mode == .selecting && type == .leftMouseUp { capture(); return eat(.up) }
            return eat()
        }
        guard active else { return pass }
        if down {
            swallowedButtons.insert(button)
            if mode == .selecting && type == .leftMouseDown { return eat(.down) }
            if type == .rightMouseDown { capture(); return eat(.cancel) }
        }
        if mode == .selecting && [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
            return eat(.move)
        }
        return eat() // Scroll, extra buttons and movement while the image is being captured.
    }
}

/// One suppressing session event tap, including the shortcut itself. No Carbon
/// hotkey or key window: the menu's app never sees the capture keystroke/drag.
/// All access is on the main run loop; the tap callback only routes and queues work.
final class CaptureInput {
    var onShortcut: (() -> Void)?
    var onPointer: ((CaptureInputState.Action, CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var canStartCapture = false
    private(set) var failureReason = "Enable Accessibility for TextOCR, then reopen it."
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var state = CaptureInputState()
    private var session: UInt64 = 0
    private var beganAt: Double = 0
    private var hiddenCursorDisplay: CGDirectDisplayID?
    private(set) var pointer = CGPoint.zero // Quartz desktop coordinates, top-left origin.
    var available: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var intercepting: Bool { state.active }

    @discardableResult func install() -> Bool {
        if available { return true }
        stop()
        guard AXIsProcessTrusted() else {
            failureReason = "Enable Accessibility for TextOCR, then reopen it."
            return false
        }
        failureReason = "macOS could not create the input tap. Check Accessibility and any Input Monitoring request, then reopen TextOCR."
        let types: [CGEventType] = [.keyDown, .keyUp, .mouseMoved, .leftMouseDown, .leftMouseUp,
                                   .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                   .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<CaptureInput>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.state.active else { return }
            if !self.available || ProcessInfo.processInfo.systemUptime - self.beganAt > 120 {
                self.interrupted("Input capture ended for safety. Try the shortcut again.")
            }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
        return available
    }

    @discardableResult func beginSelection() -> Bool {
        guard available else { return false }
        if !state.active {
            // Do not swallow the release of a click that the menu already received.
            guard !mouseButtonHeld else {
                failureReason = "Release the mouse buttons before starting capture."
                return false
            }
            arm(at: CGEvent(source: nil)?.location ?? .zero)
        }
        if hiddenCursorDisplay == nil {
            let display = CGMainDisplayID()
            guard CGDisplayHideCursor(display) == .success else {
                failureReason = "macOS could not hide the system pointer. Capture cancelled; input restored."
                endSelection()
                return false
            }
            hiddenCursorDisplay = display
        }
        return true
    }

    func imageCaptureStarted() { state.capture() }
    func endSelection() {
        state.end()
        session &+= 1 // Discard queued pointer/shortcut actions from the old session.
        if let display = hiddenCursorDisplay {
            CGDisplayShowCursor(display)
            hiddenCursorDisplay = nil
        }
    }
    func stop() {
        endSelection()
        watchdog?.invalidate(); watchdog = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        state.reset()
    }
    private var mouseButtonHeld: Bool {
        [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.combinedSessionState, button: $0) }
    }
    private func arm(at point: CGPoint) {
        session &+= 1
        state.begin()
        pointer = point
        beganAt = ProcessInfo.processInfo.systemUptime
    }
    private func interrupted(_ message: String) {
        endSelection()
        let token = session
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session == token else { return }
            self.onFailure?(message)
        }
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if state.active { interrupted("macOS interrupted input capture. Selection cancelled; input restored.") }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let shortcut = type == .keyDown && key == 19 && flags == [.maskCommand, .maskShift]
        let wasActive = state.active
        let decision = state.route(type, key: key, button: event.getIntegerValueField(.mouseEventButtonNumber),
                                   shortcut: shortcut, repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                   canBegin: shortcut && canStartCapture && !mouseButtonHeld)
        if !wasActive && state.active { arm(at: event.location) }
        guard decision.consume else { return Unmanaged.passUnretained(event) }
        let point = event.location
        if decision.action == .move || decision.action == .down || decision.action == .up {
            pointer = point
            // Suppress the event but keep pointer coordinates advancing. This API
            // moves the pointer without generating a mouse-move event for the menu.
            if CGWarpMouseCursorPosition(point) != .success {
                interrupted("Could not track the selection pointer. Input restored.")
                return nil
            }
        }
        if let action = decision.action {
            let token = session
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session == token else { return }
                switch action {
                case .shortcut: self.onShortcut?()
                case .cancel: self.onCancel?()
                default: self.onPointer?(action, point)
                }
            }
        }
        return nil
    }
    deinit {
        // Normal lifecycle calls stop(); this also balances cursor visibility on teardown.
        if let display = hiddenCursorDisplay { CGDisplayShowCursor(display) }
        watchdog?.invalidate()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
