import AppKit

@main
struct SettingsTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, line: UInt = #line) {
            checks += 1; precondition(value(), "Failed settings check at line \(line)")
        }
        var session = AdditiveClipboardSession()
        check(!session.isAppending)
        check(session.proposedText(" first ", keepLineBreaks: true) == "first")
        session.setEnabled(true)
        check(session.proposedText(" \n ", keepLineBreaks: true) == "")
        // Blank, cancellation, OCR failure or failed clipboard writes do not commit.
        _ = session.proposedText("failed write", keepLineBreaks: true)
        check(session.proposedText("first", keepLineBreaks: true) == "first")
        check(!session.isAppending) // A failed write did not start the collection.
        session.didCopy("first")
        check(session.isAppending)
        check(session.proposedText("second", keepLineBreaks: true) == "first\nsecond")
        check(session.proposedText(" \n ", keepLineBreaks: true) == "")
        session.didCopy("") // Defensive: empty results never erase the session.
        _ = session.proposedText("failed write", keepLineBreaks: true)
        check(session.proposedText("second", keepLineBreaks: true) == "first\nsecond")
        session.setEnabled(true) // Merely refreshing the same preference is not a reset.
        let second = session.proposedText("second", keepLineBreaks: true)
        session.didCopy(second)
        check(session.proposedText("third", keepLineBreaks: true) == "first\nsecond\nthird")
        session.setEnabled(false)
        check(!session.isAppending)
        check(session.proposedText("replacement", keepLineBreaks: true) == "replacement")
        session.didCopy("replacement")
        session.setEnabled(true)
        check(!session.isAppending)
        check(session.proposedText("fresh", keepLineBreaks: true) == "fresh")
        session.didCopy("fresh")
        check(session.proposedText(" a\n b ", keepLineBreaks: false) == "fresh\na b")
        check(session.proposedText(" Grüße!\nCafé ", keepLineBreaks: true) == "fresh\nGrüße!\nCafé")
        var relaunched = AdditiveClipboardSession()
        relaunched.setEnabled(true)
        check(!relaunched.isAppending)
        check(relaunched.proposedText("new launch", keepLineBreaks: true) == "new launch")

        var status = LoginItemStatus.off, registrations: [Bool] = [], opened = 0, fail = false
        let controller = LoginItemController(actions: .init(status: { status }, setRequested: { desired in
            registrations.append(desired)
            if fail { throw NSError(domain: "SyntheticLoginTest", code: 1) }
            status = desired ? .enabled : .off
        }, openSettings: { opened += 1 }))
        check(controller.status == .off && controller.helpTitle == nil && registrations.isEmpty)
        controller.refresh(); controller.refresh()
        check(registrations.isEmpty && opened == 0)
        controller.setRequested(true)
        check(registrations == [true] && controller.status == .enabled && controller.helpTitle == nil)
        controller.setRequested(true)
        check(registrations == [true])
        controller.setRequested(false)
        check(registrations == [true, false] && controller.status == .off)
        status = .requiresApproval
        controller.refresh()
        check(controller.status.requested && controller.helpTitle == "Approve Launch at Login…")
        controller.openSettings()
        check(opened == 1 && registrations == [true, false])
        controller.setRequested(false)
        check(registrations == [true, false, false] && controller.status == .off)
        fail = true
        controller.setRequested(true)
        check(controller.error != nil && !controller.status.requested && controller.helpTitle != nil)
        controller.refresh()
        check(controller.error != nil)
        status = .enabled // User changes System Settings externally.
        controller.refresh()
        check(controller.error == nil && controller.status == .enabled)
        status = .off
        controller.refresh()
        check(!controller.status.requested)
        status = .unavailable
        controller.refresh()
        check(controller.helpTitle == "Login Item Unavailable — Open Settings…")
        print("PASS: \(checks) clipboard/session/login checks; no real clipboard, login changes or popup presentation")
    }
}
