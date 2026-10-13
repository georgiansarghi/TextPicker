import AppKit

@main
struct InputTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
    static func main() {
        var state = CaptureInputState()
        check(!state.route(.mouseMoved).consume, "Idle mouse events pass through")
        check(!state.route(.keyDown, key: 0).consume, "Idle typing passes through")
        check(!state.route(.scrollWheel).consume, "Idle scroll passes through")
        let start = state.route(.keyDown, key: 19, shortcut: true, canBegin: true)
        check(start.consume && start.action == .shortcut && state.active, "Shortcut is intercepted and arms selection immediately")
        check(state.route(.keyDown, key: 19, shortcut: true, repeatKey: true).action == nil, "Holding shortcut cannot toggle repeatedly")
        check(state.route(.keyUp, key: 19).consume, "Shortcut release cannot reach the menu")
        check(state.route(.mouseMoved).action == .move, "Selection movement is routed")
        check(state.route(.scrollWheel).consume, "Menu must not scroll during selection")
        check(!state.route(.keyUp, key: 8).consume, "Preexisting key press must receive its release")
        check(!state.route(.otherMouseUp, button: 4).consume, "Preexisting button press must receive its release")
        check(state.route(.leftMouseDown).action == .down, "Selection press is routed")
        check(state.route(.leftMouseDragged).action == .move, "Selection drag is routed")
        check(state.route(.leftMouseUp).action == .up && state.mode == .capturing, "Mouse-up keeps input blocked until the screenshot exists")
        check(state.route(.mouseMoved).consume && state.route(.mouseMoved).action == nil, "No menu movement or new selection during screenshot")
        check(state.route(.keyDown, key: 1).consume, "Typing cannot alter the menu during screenshot")
        state.end()
        check(state.route(.keyUp, key: 1).consume, "Swallowed presses do not leak their releases after completion")
        check(!state.route(.mouseMoved).consume, "Capture completion restores normal movement")
        check(!state.route(.keyDown, key: 1).consume, "Capture completion restores typing")

        state.begin()
        _ = state.route(.leftMouseDown)
        check(state.route(.keyDown, key: 53).action == .cancel, "Escape cancels only our selection")
        state.end()
        check(state.route(.keyUp, key: 53).consume, "Escape release is not forwarded")
        check(state.route(.leftMouseDragged).consume, "Cancelling mid-drag must also swallow its remaining drag events")
        check(state.route(.leftMouseUp).consume, "Cancelling mid-drag swallows its trailing mouse-up")
        check(!state.route(.leftMouseUp).consume, "Only the matched release is swallowed")
        check(!state.route(.leftMouseDragged).consume, "Drag suppression ends after its paired release")
        state.begin()
        check(state.route(.rightMouseDown, button: 1).action == .cancel, "Right-click cancels")
        state.end()
        check(state.route(.rightMouseDragged, button: 1).consume, "Right-button cancellation drains the remainder of the drag")
        check(state.route(.rightMouseUp, button: 1).consume, "Right-click release cannot click the underlying menu")
        state.begin()
        check(state.route(.keyDown, key: 19, shortcut: true).action == .shortcut, "A new shortcut press requests cancellation")
        state.end()
        check(state.route(.keyDown, key: 19, shortcut: true, repeatKey: true).action == nil, "Repeats after cancellation cannot restart capture")
        _ = state.route(.keyUp, key: 19)
        check(state.route(.keyDown, key: 19, shortcut: true, canBegin: false).action == .shortcut && !state.active,
              "Unavailable engine/permissions do not lock input")
        state.reset()
        check(!state.active && !state.route(.mouseMoved).consume && !state.route(.keyUp, key: 19).consume, "Teardown restores all input")
        // A press that reached the menu before selection still owns its release,
        // even if its autorepeat happens while selection is active.
        state.begin()
        check(state.route(.keyDown, key: 8, repeatKey: true).consume, "Suppress preexisting-key repeats during capture")
        check(!state.route(.keyUp, key: 8).consume, "Do not steal the original app's key release after suppressing a repeat")
        state.reset()
        let heldShortcut = state.route(.keyDown, key: 19, shortcut: true, repeatKey: true, canBegin: true)
        check(heldShortcut.consume && heldShortcut.action == nil && !state.active, "A repeat cannot start a fresh capture")
        check(!state.route(.keyUp, key: 19).consume, "A shortcut-looking repeat must not steal a preexisting release")

        // Reproduce the reported failure: absolute event position stays fixed
        // while movement deltas continue arriving from the mouse/trackpad.
        let anchor = CGPoint(x: 100, y: 100)
        let main = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let motion = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: anchor, mouseButton: .left)!
        motion.setIntegerValueField(.mouseEventDeltaX, value: 7)
        motion.setIntegerValueField(.mouseEventDeltaY, value: -3)
        var pointer = anchor
        for _ in 0..<3 {
            pointer = movedCapturePointer(pointer,
                dx: CGFloat(motion.getIntegerValueField(.mouseEventDeltaX)),
                dy: CGFloat(motion.getIntegerValueField(.mouseEventDeltaY)), displays: [main])
        }
        check(pointer == CGPoint(x: 121, y: 91), "Software pointer must accumulate deltas even when absolute coordinates are frozen")
        check(motion.location == anchor, "Synthetic event was never moved or posted")
        check(movedCapturePointer(CGPoint(x: 999, y: 699), dx: 100, dy: 100, displays: [main]) == CGPoint(x: 999, y: 699), "Clamp at desktop edges")
        let left = CGRect(x: -1000, y: 0, width: 1000, height: 700)
        check(movedCapturePointer(CGPoint(x: 10, y: 100), dx: -20, dy: 0, displays: [main, left]) == CGPoint(x: -10, y: 100), "Cross into a display left of the primary")
        let above = CGRect(x: 0, y: -800, width: 1000, height: 800)
        check(movedCapturePointer(CGPoint(x: 100, y: 10), dx: 0, dy: -20, displays: [main, above]) == CGPoint(x: 100, y: -10), "Cross into a display above the primary")
        check(movedCapturePointer(anchor, dx: 1, dy: 2, displays: []) == CGPoint(x: 101, y: 102), "Missing display metadata must not freeze motion")
        print("PASS: \(checks) input routing/pointer checks; no global input injection or permission prompts")
    }
}
