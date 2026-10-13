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
                // A repeat is not a new press. If its original press reached the
                // menu before capture, its release must still reach that menu.
                guard !repeatKey else { return eat() }
                let first = swallowedKeys.insert(key).inserted
                guard first else { return eat() }
                if !active && canBegin { begin() }
                return eat(.shortcut)
            }
            if swallowedKeys.contains(key) { return eat() }
            guard active else { return pass }
            guard !repeatKey else { return eat() }
            swallowedKeys.insert(key)
            if key == 53 { capture(); return eat(.cancel) }
            return eat()
        }
        let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
        let up = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
        if up {
            guard swallowedButtons.remove(button) != nil else { return pass }
            if mode == .selecting && type == .leftMouseUp { capture(); return eat(.up) }
            return eat()
        }
        let drag = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type)
        if !active && drag && swallowedButtons.contains(button) {
            return eat() // Drain the rest of a cancelled drag, not only its mouse-up.
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

/// Advance a software pointer independently of event.location, which can remain
/// fixed when the mouse event is suppressed. Clamp to the closest actual display.
func movedCapturePointer(_ point: CGPoint, dx: CGFloat, dy: CGFloat, displays: [CGRect]) -> CGPoint {
    let next = CGPoint(x: point.x + dx, y: point.y + dy)
    guard !displays.isEmpty else { return next }
    if displays.contains(where: { $0.contains(next) }) { return next }
    return displays.map { rect in
        CGPoint(x: min(max(next.x, rect.minX), rect.maxX - 1),
                y: min(max(next.y, rect.minY), rect.maxY - 1))
    }.min { a, b in
        hypot(a.x - next.x, a.y - next.y) < hypot(b.x - next.x, b.y - next.y)
    } ?? point
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
    var captureShortcut = CaptureShortcut.default
    var onRecordedShortcut: ((UInt16, CGEventFlags) -> Void)?
    private var menuRouting = MenuKeyRouting()
    private var menuGeneration: UInt64 = 0
    private var menuKeyAction: ((UInt16) -> Void)?

    func setMenuKeys(_ keys: Set<UInt16>, action: ((UInt16) -> Void)?) {
        menuGeneration &+= 1
        menuRouting.controlKeys = keys
        menuKeyAction = action
    }
    @discardableResult func beginShortcutRecording() -> Bool {
        guard available, !state.active else { return false }
        menuGeneration &+= 1
        menuRouting.recording = true
        return true
    }
    func endShortcutRecording() {
        menuGeneration &+= 1
        menuRouting.recording = false
    }
    func endMenuTracking() {
        menuGeneration &+= 1
        menuRouting.end()
        menuKeyAction = nil
    }
    // Factored so tracking-mode delivery and stale callback rejection can be
    // tested with synthetic key codes, without installing a tap or posting input.
    @discardableResult func routeMenuKey(_ type: CGEventType, key: UInt16, flags: CGEventFlags, repeated: Bool) -> Bool {
        let decision = menuRouting.route(type, key: key, flags: flags, repeated: repeated, captureActive: state.active)
        if let action = decision.action {
            let generation = menuGeneration
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self, self.menuGeneration == generation else { return }
                switch action {
                case .record: self.onRecordedShortcut?(key, flags)
                case .control: self.menuKeyAction?(key)
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return decision.consume
    }
    private(set) var failureReason = "Enable Accessibility for TextPicker, then reopen it."
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var state = CaptureInputState()
    private var session: UInt64 = 0
    private var beganAt: Double = 0
    private var hiddenCursorDisplay: CGDirectDisplayID?
    private var displayBounds: [CGRect] = []
    private(set) var pointer = CGPoint.zero // Quartz desktop coordinates, top-left origin.
    var available: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult func install() -> Bool {
        if available { return true }
        stop()
        guard AXIsProcessTrusted() else {
            failureReason = "Enable Accessibility for TextPicker, then reopen it."
            return false
        }
        failureReason = "macOS could not create the input tap. Check Accessibility, then reopen TextPicker."
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
        guard available else {
            failureReason = "Input capture is unavailable. Check Accessibility and reopen TextPicker."
            return false
        }
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
        restoreCursor()
    }
    private func restoreCursor() {
        guard let display = hiddenCursorDisplay else { return }
        hiddenCursorDisplay = nil // Own exactly one matching show for a successful hide.
        // Only restore after screenshot/cancellation. Warping sends no mouse event.
        CGWarpMouseCursorPosition(pointer)
        CGDisplayShowCursor(display)
    }
    func stop() {
        endMenuTracking()
        endSelection()
        watchdog?.invalidate(); watchdog = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        state.reset()
        menuRouting = MenuKeyRouting()
    }
    private var mouseButtonHeld: Bool {
        [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.combinedSessionState, button: $0) }
    }
    private func arm(at point: CGPoint) {
        menuGeneration &+= 1 // Discard queued setting edits before freezing the menu for capture.
        session &+= 1
        state.begin()
        pointer = point
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0, CGGetActiveDisplayList(count, &ids, &count) == .success {
            displayBounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        } else {
            displayBounds = [CGDisplayBounds(CGMainDisplayID())]
        }
        beganAt = ProcessInfo.processInfo.systemUptime
    }
    private func interrupted(_ message: String) {
        endSelection()
        let token = session
        onCaptureRunLoop { [weak self] in
            guard let self, self.session == token else { return }
            self.onFailure?(message)
        }
    }
    // Internal for synthetic event routing tests; tests never post these events.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if state.active { interrupted("macOS interrupted input capture. Selection cancelled; input restored.") }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection(CaptureShortcut.modifierMask)
        if routeMenuKey(type, key: UInt16(truncatingIfNeeded: key), flags: flags,
                        repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) { return nil }
        let shortcut = type == .keyDown && captureShortcut.matches(key: key, flags: flags)
        let wasActive = state.active
        let decision = state.route(type, key: key, button: event.getIntegerValueField(.mouseEventButtonNumber),
                                   shortcut: shortcut, repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                   canBegin: shortcut && canStartCapture && !mouseButtonHeld)
        if !wasActive && state.active { arm(at: event.location) }
        guard decision.consume else { return Unmanaged.passUnretained(event) }
        if decision.action == .move {
            pointer = movedCapturePointer(pointer,
                dx: CGFloat(event.getIntegerValueField(.mouseEventDeltaX)),
                dy: CGFloat(event.getIntegerValueField(.mouseEventDeltaY)), displays: displayBounds)
        }
        // Down/up use the accumulated software position too, not the anchored
        // physical pointer. Otherwise the rectangle would jump on click/release.
        let point = pointer
        if let action = decision.action {
            let token = session
            onCaptureRunLoop { [weak self] in
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
        restoreCursor()
        watchdog?.invalidate()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
