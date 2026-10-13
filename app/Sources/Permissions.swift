import AppKit
import ApplicationServices

// TextPicker's own AppKit permission UI. Checks never capture the screen or request
// access; system prompts are initiated only by an explicit Grant Access click.
enum CapturePermission: CaseIterable {
    case screenRecording, accessibility

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }
    var detail: String {
        switch self {
        case .screenRecording:
            return "Reads the region you select for local text recognition. TextPicker does not record audio or upload your captures."
        case .accessibility:
            return "Enables the capture shortcut and region selection without dismissing open menus. TextPicker does not record your keystrokes."
        }
    }
    var settingsURL: URL {
        let pane: String
        switch self {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

enum PermissionMenuAction { case allow, settings }

enum PermissionMenuState: Equatable {
    case notGranted, requested, granted
    var action: PermissionMenuAction { self == .notGranted ? .allow : .settings }
    var buttonTitle: String {
        switch self {
        case .notGranted: return "Allow"
        case .requested: return "Open Settings…"
        case .granted: return "Settings…"
        }
    }
}

struct CaptureAccess: Equatable {
    var screenRecording = false
    var accessibility = false
    var inputReady = false

    // Permission bits alone are not enough: the actual capture input must work.
    var ready: Bool { screenRecording && accessibility && inputReady }

    func granted(_ permission: CapturePermission) -> Bool {
        switch permission {
        case .screenRecording: return screenRecording
        case .accessibility: return accessibility
        }
    }
    func status(_ permission: CapturePermission) -> String {
        granted(permission) ? "Granted" : "Not granted"
    }
    func menuState(_ permission: CapturePermission, requested: Set<CapturePermission>) -> PermissionMenuState {
        if granted(permission) { return .granted }
        return requested.contains(permission) ? .requested : .notGranted
    }
    func menuGuidance(settingsError: String?) -> String? {
        if settingsError != nil { return "Open System Settings → Privacy & Security." }
        if screenRecording && accessibility && !inputReady { return "Quit and reopen TextPicker to enable capture." }
        return nil
    }
    var guidance: String {
        if ready { return "Permissions are ready. Close this window, then use Capture Text or your shortcut." }
        if screenRecording && accessibility && !inputReady {
            return "Permissions have been granted, but capture input is not ready. Quit and reopen TextPicker."
        }
        return "Enable the required permissions, then return here. If the switches are already on, quit and reopen TextPicker. After an app update, macOS may need you to toggle or re-add TextPicker."
    }
}

@MainActor
struct PermissionActions {
    let check: () -> CaptureAccess
    let request: (CapturePermission) -> Void
    let openSettings: (URL) -> Bool

    static func live(check: @escaping () -> CaptureAccess) -> PermissionActions {
        PermissionActions(check: check, request: { permission in
            switch permission {
            case .screenRecording: _ = CGRequestScreenCaptureAccess()
            case .accessibility:
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        }, openSettings: { NSWorkspace.shared.open($0) })
    }
}

@MainActor
final class PermissionStatus {
    private let actions: PermissionActions
    private(set) var access: CaptureAccess
    private(set) var requested: Set<CapturePermission> = []
    private(set) var settingsError: String?

    init(actions: PermissionActions) {
        self.actions = actions
        access = actions.check()
    }
    func refresh() {
        let wasReady = access.ready
        access = actions.check()
        // Resolving missing access clears old guidance, but polling an already
        // granted permission must not erase a failed Settings-open action.
        if !wasReady && access.ready { settingsError = nil }
    }
    func request(_ permission: CapturePermission) {
        refresh()
        guard !access.granted(permission), !requested.contains(permission) else { return }
        // Do not repeatedly open a system prompt if access was denied. The
        // adjacent settings action remains available for changing that choice.
        requested.insert(permission)
        actions.request(permission)
        refresh()
    }
    func perform(_ action: PermissionMenuAction, for permission: CapturePermission) {
        // Preserve the clicked button’s intent even if access changes before delivery.
        switch action {
        case .allow: request(permission)
        case .settings: openSettings(permission)
        }
    }
    func openSettings(_ permission: CapturePermission) {
        settingsError = actions.openSettings(permission.settingsURL) ? nil
            : "Open System Settings → Privacy & Security → \(permission.title)."
    }
}

/// Shared lifecycle for passive menu/window refresh. Never requests permissions.
@MainActor
final class PermissionRefreshMonitor {
    private let refresh: () -> Void
    private let shouldRefresh: () -> Bool
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    var isRunning: Bool { timer != nil }

    init(shouldRefresh: @escaping () -> Bool = { true }, refresh: @escaping () -> Void) {
        self.shouldRefresh = shouldRefresh
        self.refresh = refresh
    }
    func start() {
        guard !isRunning else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func tick() {
        guard isRunning, shouldRefresh() else { return }
        refresh()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor
private final class PermissionRow: NSBox {
    let status = NSTextField(labelWithString: "")
    let grant: NSButton
    let settings: NSButton
    private let permission: CapturePermission

    init(_ permission: CapturePermission, target: AnyObject, grantAction: Selector, settingsAction: Selector) {
        self.permission = permission
        grant = NSButton(title: "Grant Access", target: target, action: grantAction)
        settings = NSButton(title: "Open Settings…", target: target, action: settingsAction)
        super.init(frame: .zero)
        boxType = .custom
        borderWidth = 1
        borderColor = .separatorColor
        fillColor = .controlBackgroundColor
        cornerRadius = 10
        contentViewMargins = .zero
        let title = NSTextField(labelWithString: permission.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let requirement = NSTextField(labelWithString: "Required")
        requirement.font = .systemFont(ofSize: 11)
        requirement.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, requirement])
        heading.spacing = 8
        let detail = NSTextField(wrappingLabelWithString: permission.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 370
        let copy = NSStackView(views: [heading, detail])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 6
        let buttons = NSStackView(views: [grant, settings])
        buttons.spacing = 6
        for button in [grant, settings] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = CapturePermission.allCases.firstIndex(of: permission)!
        }
        grant.setAccessibilityLabel("Grant \(permission.title) access")
        settings.setAccessibilityLabel("Open \(permission.title) settings")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.alignment = .right
        let controls = NSStackView(views: [status, buttons])
        controls.orientation = .vertical
        controls.alignment = .trailing
        controls.spacing = 10
        let content = contentView!
        for view in [copy, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            copy.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            copy.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            copy.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
            copy.widthAnchor.constraint(equalToConstant: 370),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: copy.trailingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            controls.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            heightAnchor.constraint(equalToConstant: 108),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ model: PermissionStatus) {
        let access = model.access
        status.stringValue = (access.granted(permission) ? "✓ " : "") + access.status(permission)
        status.textColor = access.granted(permission) ? .systemGreen : .systemOrange
        status.setAccessibilityLabel("\(permission.title): \(access.status(permission))")
        grant.isHidden = access.granted(permission)
        grant.isEnabled = !model.requested.contains(permission)
        grant.title = model.requested.contains(permission) ? "Requested" : "Grant Access"
        settings.isHidden = access.granted(permission)
    }
}

@MainActor
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    private let model: PermissionStatus
    private let onRefresh: (CaptureAccess) -> Void
    private let onQuit: () -> Void
    private var rows: [PermissionRow] = []
    private var constructedWindow = false
    private let guidance = NSTextField(wrappingLabelWithString: "")
    private let dismissButton = NSButton(title: "Later", target: nil, action: nil)
    private lazy var refreshMonitor = PermissionRefreshMonitor { [weak self] in self?.refresh() }
    var monitoring: Bool { refreshMonitor.isRunning }

    init(model: PermissionStatus, onRefresh: @escaping (CaptureAccess) -> Void, onQuit: @escaping () -> Void) {
        self.model = model
        self.onRefresh = onRefresh
        self.onQuit = onQuit
        super.init(window: nil)
        loadWindow()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadWindow() {
        guard !constructedWindow else { return }
        constructedWindow = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 470),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TextPicker Permissions"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.animationBehavior = .none
        let background = NSBox(frame: window.contentView!.bounds)
        background.boxType = .custom
        background.borderWidth = 0
        background.fillColor = .windowBackgroundColor
        background.contentViewMargins = .zero
        window.contentView = background
        let body = background.contentView!
        let title = NSTextField(labelWithString: "Set up TextPicker")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Grant access below to capture text. Checks update automatically when you return from System Settings.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 670
        rows = CapturePermission.allCases.map { PermissionRow($0, target: self, grantAction: #selector(grant(_:)), settingsAction: #selector(settings(_:))) }
        guidance.font = .systemFont(ofSize: 12)
        guidance.textColor = .secondaryLabelColor
        guidance.preferredMaxLayoutWidth = 670
        guidance.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let quitButton = NSButton(title: "Quit TextPicker", target: self, action: #selector(quit))
        let refresh = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        dismissButton.target = self
        dismissButton.action = #selector(dismissWindow)
        dismissButton.keyEquivalent = "\r"
        let spacer = NSView()
        let buttons = NSStackView(views: [quitButton, spacer, refresh, dismissButton])
        buttons.spacing = 10
        for button in [quitButton, refresh, dismissButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let content = NSStackView(views: [title, subtitle] + rows + [guidance, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: body.topAnchor, constant: 22),
            content.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor),
            guidance.widthAnchor.constraint(equalTo: content.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: content.widthAnchor),
        ] + rows.map { $0.widthAnchor.constraint(equalTo: content.widthAnchor) })
        self.window = window
        render()
        window.center()
    }

    func present() {
        // Repeated menu actions reuse the same window and observers.
        refresh()
        beginMonitoring()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    // Separate from presentation so passive checks/lifecycle can be tested
    // without activating a window or touching real macOS permission settings.
    func beginMonitoring() { refreshMonitor.start() }
    private func stopMonitoring() { refreshMonitor.stop() }
    func refresh() {
        model.refresh()
        render()
        onRefresh(model.access)
    }
    private func render() {
        guard isWindowLoaded else { return }
        rows.forEach { $0.update(model) }
        guidance.stringValue = model.settingsError ?? model.access.guidance
        dismissButton.title = model.access.ready ? "Done" : "Later"
    }
    @objc private func grant(_ sender: NSButton) {
        model.request(CapturePermission.allCases[sender.tag])
        refresh()
    }
    @objc private func settings(_ sender: NSButton) {
        model.openSettings(CapturePermission.allCases[sender.tag])
        render()
    }
    @objc private func checkAgain() { refresh() }
    @objc private func dismissWindow() { close() }
    @objc private func quit() { onQuit() }
    override func close() { stopMonitoring(); super.close() }
    func windowWillClose(_ notification: Notification) { stopMonitoring() }
    func shutdown() { close() }
}
