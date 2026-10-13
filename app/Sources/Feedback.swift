import AppKit

/// Keep the existing inverse preference so upgrades and rollback builds agree.
enum CaptureFeedbackPreference {
    private static let key = "disableSuccessNotification"
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: key)
    }
    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(!enabled, forKey: key)
    }
}

/// Fixed, user-facing copy: no OCR contents, model names, timings or raw errors.
enum CaptureFeedback: Equatable {
    enum Failure: CaseIterable {
        case screenAccess, inputAccess, captureTimeout, recognitionTimeout, smallerArea, retryEngine, retryCapture
    }
    case copied, added, reading, noText, copyFailed, gettingReady
    case failure(Failure)

    var title: String {
        switch self {
        case .copied: return "Copied to clipboard"
        case .added: return "Added to clipboard"
        case .reading: return "Reading text…"
        case .noText: return "No text found"
        case .copyFailed: return "Couldn’t copy text"
        case .gettingReady: return "Getting ready…"
        case .failure: return "Couldn’t capture text"
        }
    }
    var detail: String {
        switch self {
        case .copied, .added, .reading: return ""
        case .noText, .failure(.smallerArea): return "Try selecting a smaller area."
        case .copyFailed, .failure(.retryCapture): return "Try capturing again."
        case .gettingReady: return "Try again in a moment."
        case .failure(.screenAccess): return "Allow Screen Recording under Permissions."
        case .failure(.inputAccess): return "Check Accessibility under Permissions."
        case .failure(.captureTimeout): return "The capture took too long. Try again."
        case .failure(.recognitionTimeout): return "Text recognition timed out. Use Retry OCR Engine."
        case .failure(.retryEngine): return "Use Retry OCR Engine in the menu."
        }
    }
    var kind: Toast.Kind {
        switch self {
        case .copied, .added: return .success
        case .reading: return .progress
        default: return .attention
        }
    }
    var duration: TimeInterval {
        switch self {
        case .copied, .added: return 1.5
        case .reading: return 10
        case .failure, .copyFailed: return 5
        default: return 2.5
        }
    }
    static func forFailure(_ message: String, engineReady: Bool) -> CaptureFeedback {
        let text = message.lowercased()
        // Known causes get actionable copy; unknown/library errors never leak
        // arbitrary text into the popup. The original error stays in the log.
        if text.contains("screen") && ["permission", "denied", "not authorized"].contains(where: text.contains) {
            return .failure(.screenAccess)
        }
        if ["accessibility", "input tap"].contains(where: text.contains) {
            return .failure(.inputAccess)
        }
        if text.contains("screen capture took too long") { return .failure(.captureTimeout) }
        if text.contains("recognition exceeded") { return .failure(.recognitionTimeout) }
        if ["too large", "too wide", "width bound", "not enough memory"].contains(where: text.contains) {
            return .failure(.smallerArea)
        }
        return .failure(engineReady ? .retryCapture : .retryEngine)
    }
}

/// Main-run-loop presentation. Injected presenters let tests exercise timing and
/// cancellation without displaying windows or inspecting screen contents.
final class Toast {
    enum Kind: CaseIterable {
        case progress, success, attention
        func shouldShow(suppressRoutine: Bool) -> Bool { self == .attention || !suppressRoutine }
    }
    private let presentOverride: ((CaptureFeedback) -> Void)?
    private let hideOverride: (() -> Void)?
    private var panel: NSPanel?
    private var pending: Timer?
    private var dismissal: Timer?
    private var generation: UInt64 = 0
    private var pendingKind: Kind?
    private(set) var visibleKind: Kind?
    var suppressRoutineNotifications = false {
        didSet {
            if [visibleKind, pendingKind].compactMap({ $0 }).contains(where: { !$0.shouldShow(suppressRoutine: suppressRoutineNotifications) }) {
                dismiss()
            }
        }
    }
    init(present: ((CaptureFeedback) -> Void)? = nil, hide: (() -> Void)? = nil) {
        presentOverride = present
        hideOverride = hide
    }
    func show(_ feedback: CaptureFeedback, after delay: TimeInterval? = nil, duration: TimeInterval? = nil) {
        guard feedback.kind.shouldShow(suppressRoutine: suppressRoutineNotifications) else { return }
        dismiss()
        let token = generation
        let delay = delay ?? (feedback.kind == .progress ? 0.5 : 0)
        let duration = duration ?? feedback.duration
        if delay > 0 {
            pendingKind = feedback.kind
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self, self.generation == token else { return }
                self.pending = nil; self.pendingKind = nil
                self.present(feedback, duration: duration, token: token)
            }
            pending = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            present(feedback, duration: duration, token: token)
        }
    }
    private func present(_ feedback: CaptureFeedback, duration: TimeInterval, token: UInt64) {
        guard generation == token, feedback.kind.shouldShow(suppressRoutine: suppressRoutineNotifications) else { return }
        visibleKind = feedback.kind
        if let presentOverride { presentOverride(feedback) }
        else if !presentPanel(feedback) {
            if generation == token { visibleKind = nil }
            return
        }
        guard generation == token else { return }
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.dismiss()
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func presentPanel(_ feedback: CaptureFeedback) -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return false }
        let compact = feedback.detail.isEmpty
        let size = CGSize(width: compact ? 240 : 360, height: compact ? 52 : 92)
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 65,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        panel.setAccessibilitySubrole(.floatingWindow)
        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: feedback.title)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.alignment = .center
        label.frame = CGRect(x: 12, y: compact ? 15 : 56, width: size.width - 24, height: 22)
        effect.addSubview(label)
        if !compact {
            let sublabel = NSTextField(wrappingLabelWithString: feedback.detail)
            sublabel.font = .systemFont(ofSize: 12)
            sublabel.textColor = .secondaryLabelColor
            sublabel.alignment = .center
            sublabel.maximumNumberOfLines = 2
            sublabel.frame = CGRect(x: 12, y: 14, width: size.width - 24, height: 32)
            effect.addSubview(sublabel)
        }
        panel.contentView = effect
        self.panel = panel
        panel.orderFrontRegardless()
        return true
    }
    func dismiss() {
        generation &+= 1
        pending?.invalidate(); pending = nil; pendingKind = nil
        dismissal?.invalidate(); dismissal = nil
        panel?.close(); panel = nil
        if visibleKind != nil { hideOverride?() }
        visibleKind = nil
    }
    deinit {
        pending?.invalidate()
        dismissal?.invalidate()
    }
}
