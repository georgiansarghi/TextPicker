import AppKit

@main
struct FeedbackTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
            checks += 1; precondition(value(), "Failed feedback check at line \(line): \(message)")
        }
        let domain = "TextPicker-feedback-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        check(CaptureFeedbackPreference.isEnabled(in: defaults))
        defaults.set(true, forKey: "disableSuccessNotification")
        check(!CaptureFeedbackPreference.isEnabled(in: defaults))
        defaults.set(false, forKey: "disableSuccessNotification")
        check(CaptureFeedbackPreference.isEnabled(in: defaults))
        for enabled in [false, true, false] {
            CaptureFeedbackPreference.setEnabled(enabled, in: defaults)
            check(CaptureFeedbackPreference.isEnabled(in: defaults) == enabled)
            check(defaults.bool(forKey: "disableSuccessNotification") == !enabled)
        }
        let routine: [CaptureFeedback] = [.copied, .added, .reading]
        let attention: [CaptureFeedback] = [.noText, .copyFailed, .gettingReady] + CaptureFeedback.Failure.allCases.map { .failure($0) }
        check(CaptureFeedback.copied.title == "Copied to clipboard")
        check(CaptureFeedback.added.title == "Added to clipboard")
        check(CaptureFeedback.reading.title == "Reading text…")
        for notice in routine {
            check(notice.detail.isEmpty)
            check(!notice.kind.shouldShow(suppressRoutine: true))
            check(notice.kind.shouldShow(suppressRoutine: false))
        }
        for notice in attention {
            check(!notice.detail.isEmpty)
            check(notice.kind == .attention && notice.kind.shouldShow(suppressRoutine: true))
        }
        check(CaptureFeedback.forFailure("Screen capture denied", engineReady: true) == .failure(.screenAccess))
        check(CaptureFeedback.forFailure("Enable Accessibility", engineReady: true) == .failure(.inputAccess))
        check(CaptureFeedback.forFailure("Screen capture took too long", engineReady: true) == .failure(.captureTimeout))
        check(CaptureFeedback.forFailure("Recognition exceeded 10 seconds", engineReady: false) == .failure(.recognitionTimeout))
        for raw in ["Selection is too large", "Text line is too wide", "Text line exceeds native width bound", "Not enough memory"] {
            check(CaptureFeedback.forFailure(raw, engineReady: false) == .failure(.smallerArea))
        }
        let privateError = "Synthetic raw implementation error: /private/example"
        check(CaptureFeedback.forFailure(privateError, engineReady: true) == .failure(.retryCapture))
        check(CaptureFeedback.forFailure(privateError, engineReady: false) == .failure(.retryEngine))
        check(!CaptureFeedback.forFailure(privateError, engineReady: false).detail.contains(privateError))

        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        func pump(_ mode: RunLoop.Mode = .default, seconds: Double = 0.08) {
            let deadline = Date().addingTimeInterval(seconds)
            let keepAlive = Timer(timeInterval: 0.01, repeats: true) { _ in }
            RunLoop.main.add(keepAlive, forMode: mode)
            defer { keepAlive.invalidate() }
            while Date() < deadline { _ = RunLoop.main.run(mode: mode, before: deadline) }
        }
        for mode in [RunLoop.Mode.default, .eventTracking] {
            var rendered: [CaptureFeedback] = []
            var hidden = 0
            let toast = Toast(present: { rendered.append($0) }, hide: { hidden += 1 })
            toast.show(.reading) // Actual 500 ms default; no immediate presentation.
            pump(mode)
            check(rendered.isEmpty)
            toast.show(.copied)
            pump(mode, seconds: 0.55)
            check(rendered == [.copied], "Late progress must not replace a fast result")
            toast.dismiss()
            check(hidden == 1)
            rendered.removeAll()

            toast.show(.reading, after: 0.02)
            check(rendered.isEmpty)
            pump(mode)
            check(rendered == [.reading] && toast.visibleKind == .progress)
            toast.show(.added)
            check(rendered == [.reading, .added] && toast.visibleKind == .success)
            toast.suppressRoutineNotifications = true
            check(toast.visibleKind == nil)
            toast.suppressRoutineNotifications = false
            rendered.removeAll()

            toast.show(.reading, after: 0.02)
            toast.dismiss() // Cancel/quit/engine restart.
            pump(mode)
            check(rendered.isEmpty)
            toast.show(.reading, after: 0.02)
            toast.show(.failure(.retryEngine))
            pump(mode)
            check(rendered == [.failure(.retryEngine)])
            toast.suppressRoutineNotifications = true
            check(toast.visibleKind == .attention, "Errors remain visible when routine feedback is hidden")
            toast.dismiss()
            rendered.removeAll()

            toast.suppressRoutineNotifications = false
            toast.show(.reading, after: 0.02)
            toast.suppressRoutineNotifications = true // Cancel a pending popup too.
            toast.suppressRoutineNotifications = false
            pump(mode)
            check(rendered.isEmpty)
            toast.suppressRoutineNotifications = true
            for notice in routine { toast.show(notice, after: 0.02) }
            pump(mode)
            check(rendered.isEmpty)
            for notice in attention { toast.show(notice); check(rendered.last == notice) }
            toast.dismiss()
            rendered.removeAll()
            toast.suppressRoutineNotifications = false
            toast.show(.copied, duration: 0.02)
            pump(mode)
            check(rendered == [.copied] && toast.visibleKind == nil, "Automatic dismissal works during menu tracking too")
        }
        var reentrant: Toast!
        reentrant = Toast(present: { _ in reentrant.suppressRoutineNotifications = true })
        reentrant.show(.copied)
        check(reentrant.visibleKind == nil, "suppression during presentation cannot leave a stale popup")
        reentrant = nil
        print("PASS: \(checks) feedback copy/preference/timing checks; injected presentation only, no screen or clipboard access")
    }
}
