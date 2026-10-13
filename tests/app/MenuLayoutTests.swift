import AppKit

/// Explicit, opt-in live AppKit layout check. Shows only this synthetic menu;
/// never installs an input tap, posts input, captures pixels or reads clipboard.
@main
struct MenuLayoutTests {
    @MainActor static func main() {
        guard CommandLine.arguments.contains("--live-menu-layout") else {
            print("Requires --live-menu-layout: briefly displays a synthetic menu.")
            return
        }
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { fatalError("No display for live menu layout check") }
        let controls = CaptureMenu(actions: .init(capture: {}, retry: {}, permission: { _, _ in },
            lines: { _ in }, sound: { _ in }, record: {}, resetShortcut: {}, quit: {}))
        controls.update(ready: true, capturing: false, failed: false, access: CaptureAccess(screenRecording: true, accessibility: true, inputReady: true),
                        keepLines: true, playSound: false, shortcut: .default)
        var stage = 0
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func visible(_ view: NSView, name: String) {
            view.layoutSubtreeIfNeeded()
            check(view.window != nil, "\(name) attached to a live menu window")
            check(view.visibleRect.contains(view.bounds.insetBy(dx: 0.5, dy: 0.5)), "\(name) not clipped: \(view.visibleRect) / \(view.bounds)")
        }
        let timer = Timer(timeInterval: 0.12, repeats: true) { _ in
            MainActor.assumeIsolated {
                switch stage {
                case 0:
                    visible(controls.shortcut, name: "idle row")
                    controls.shortcut.setRecording(true)
                case 1:
                    visible(controls.shortcut, name: "recording row")
                    visible(controls.shortcut.label, name: "recording label")
                    visible(controls.shortcut.recordButton, name: "recording button")
                    check(controls.shortcut.frame.height == 28, "recording does not resize custom row")
                    check(!controls.shortcutHint.isHidden && controls.shortcutHint.view == nil, "guidance uses native item")
                    let row = controls.shortcut.convert(controls.shortcut.bounds, to: nil)
                    let next = controls.lines.convert(controls.lines.bounds, to: nil)
                    check(!row.intersects(next), "recording and checkbox frames do not overlap")
                    controls.shortcut.setRecording(true, message: "Include Command (⌘) or Control (⌃).")
                case 2:
                    visible(controls.shortcut, name: "error row")
                    visible(controls.shortcut.recordButton, name: "error button")
                    controls.shortcut.setRecording(false)
                case 3:
                    visible(controls.shortcut, name: "restored row")
                    check(controls.shortcutHint.isHidden, "guidance disappears after recording")
                    check(!controls.menu.showsStateColumn, "no extra checkmark gutter")
                    controls.menu.cancelTrackingWithoutAnimation()
                default: controls.menu.cancelTrackingWithoutAnimation()
                }
                stage += 1
            }
        }
        let safety = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated { controls.menu.cancelTrackingWithoutAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(safety, forMode: .common)
        let frame = screen.visibleFrame
        _ = controls.menu.popUp(positioning: nil, at: NSPoint(x: frame.midX - 175, y: frame.maxY - 70), in: nil)
        timer.invalidate(); safety.invalidate()
        check(stage == 4, "all live stages completed (menu may have been dismissed manually)")
        if !failures.isEmpty { fatalError(failures.joined(separator: "\n")) }
        print("PASS: \(checks) live native-menu layout checks; no screenshots, input posting or permission requests")
    }
}
