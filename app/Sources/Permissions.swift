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
            return "Reads only the area you select. Nothing leaves your Mac."
        case .accessibility:
            return "Runs the shortcut and keeps menus open while you select."
        }
    }
    var symbol: String {
        switch self {
        case .screenRecording: return "rectangle.dashed"
        case .accessibility: return "accessibility"
        }
    }
    var tint: NSColor {
        switch self {
        case .screenRecording: return .systemBlue
        case .accessibility: return .systemIndigo
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
        if ready { return "You're all set." }
        if screenRecording && accessibility && !inputReady { return "Almost there. Quit and reopen TextPicker." }
        return "Already on in System Settings? Quit and reopen TextPicker."
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
private final class PermissionRow: NSView {
    let status = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "Granted")
    let button: NSButton
    private(set) var state = PermissionMenuState.notGranted
    private let permission: CapturePermission

    init(_ permission: CapturePermission, target: AnyObject, action: Selector) {
        self.permission = permission
        button = NSButton(title: PermissionMenuState.notGranted.buttonTitle, target: target, action: action)
        super.init(frame: .zero)
        let tile = NSBox()
        tile.boxType = .custom
        tile.borderWidth = 0
        tile.fillColor = permission.tint
        tile.cornerRadius = 7
        tile.contentViewMargins = .zero
        let symbol = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil)!)
        symbol.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        symbol.contentTintColor = .white
        symbol.translatesAutoresizingMaskIntoConstraints = false
        tile.contentView!.addSubview(symbol)
        let title = NSTextField(labelWithString: permission.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: permission.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let copy = NSStackView(views: [title, detail])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 2
        button.bezelStyle = .rounded
        button.tag = CapturePermission.allCases.firstIndex(of: permission)!
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!)
        check.contentTintColor = .systemGreen
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .systemGreen
        status.setViews([check, statusLabel], in: .leading)
        status.spacing = 4
        // Fixed-width trailing slot sized for the widest title, so Allow →
        // Open Settings… → Granted never changes the row or window width.
        button.title = "Open Settings…"
        let slotWidth = button.intrinsicContentSize.width
        button.title = PermissionMenuState.notGranted.buttonTitle
        let slot = NSView()
        for view in [status, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(view)
        }
        let row = NSStackView(views: [tile, copy, NSView(), slot])
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: slotWidth),
            slot.heightAnchor.constraint(equalTo: button.heightAnchor),
            button.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            status.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 30), tile.heightAnchor.constraint(equalToConstant: 30),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 58),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ model: PermissionStatus) {
        state = model.access.menuState(permission, requested: model.requested)
        status.isHidden = state != .granted
        status.setAccessibilityLabel("\(permission.title): \(model.access.status(permission))")
        button.isHidden = state == .granted
        button.title = state == .notGranted ? "Allow" : "Open Settings…"
        button.setAccessibilityLabel(state == .notGranted ? "Allow \(permission.title)" : "Open \(permission.title) settings")
    }
}

@MainActor
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    private let model: PermissionStatus
    private let onRefresh: (CaptureAccess) -> Void
    private let onQuit: () -> Void
    private var rows: [PermissionRow] = []
    private var constructedWindow = false
    private let guidance = NSTextField(labelWithString: "")
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
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "TextPicker Permissions"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
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
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 52).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let title = NSTextField(labelWithString: "Set up TextPicker")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Allow two permissions to start capturing text.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2
        let header = NSStackView(views: [icon, heading])
        header.spacing = 14
        rows = CapturePermission.allCases.map { PermissionRow($0, target: self, action: #selector(rowAction(_:))) }
        let card = NSBox()
        card.boxType = .custom
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.cornerRadius = 10
        card.contentViewMargins = .zero
        let divider = NSBox()
        divider.boxType = .separator
        let list = NSStackView(views: [rows[0], divider, rows[1]])
        list.orientation = .vertical
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        card.contentView!.addSubview(list)
        guidance.font = .systemFont(ofSize: 11)
        guidance.lineBreakMode = .byTruncatingTail
        guidance.textColor = .secondaryLabelColor
        let quitButton = NSButton(title: "Quit TextPicker", target: self, action: #selector(quit))
        dismissButton.target = self
        dismissButton.action = #selector(dismissWindow)
        dismissButton.keyEquivalent = "\r"
        for button in [quitButton, dismissButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [quitButton, NSView(), dismissButton])
        buttons.spacing = 12
        let content = NSStackView(views: [header, card, guidance, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.setCustomSpacing(22, after: header)
        content.setCustomSpacing(8, after: card)
        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor),
            list.topAnchor.constraint(equalTo: card.contentView!.topAnchor),
            list.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -28),
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: body.topAnchor, constant: 40),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -20),
            card.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor),
        ] + rows.map { $0.widthAnchor.constraint(equalTo: list.widthAnchor) })
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
        guidance.toolTip = guidance.stringValue
        dismissButton.title = model.access.ready ? "Done" : "Later"
    }
    @objc private func rowAction(_ sender: NSButton) {
        // Act on the state the button showed, as the menu rows do.
        model.perform(rows[sender.tag].state.action, for: CapturePermission.allCases[sender.tag])
        refresh()
    }
    @objc private func dismissWindow() { close() }
    @objc private func quit() { onQuit() }
    override func close() { stopMonitoring(); super.close() }
    func windowWillClose(_ notification: Notification) { stopMonitoring() }
    func shutdown() { close() }
}
