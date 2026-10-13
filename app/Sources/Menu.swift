import AppKit

/// Native controls in custom menu rows. They deliberately do not cancel menu
/// tracking: both mouse and keyboard changes remain visible in the open menu.
@MainActor
class SettingsMenuRow: NSView {
    let label: NSTextField
    private lazy var alignmentCheckbox = NSButton(checkboxWithTitle: "Capture Shortcut", target: nil, action: nil)
    var checkboxTitleLeading: CGFloat {
        alignmentCheckbox.font = label.font
        return Self.textInset + 7 + alignmentCheckbox.cell!.titleRect(forBounds: NSRect(x: 0, y: 0, width: 300, height: 22)).minX
    }
    var highlighted = false { didSet { needsDisplay = true; label.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor } }
    static let textInset: CGFloat = 14
    static let trailingInset: CGFloat = 18
    static let rowHeight: CGFloat = 28
    init(title: String, height: CGFloat = 28) {
        label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 350, height: height))
        autoresizingMask = [.width]
        label.font = NSMenu().font
        label.frame = NSRect(x: Self.textInset, y: (height - 18) / 2, width: 202, height: 18)
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        label.frame.origin = NSPoint(x: Self.textInset, y: (bounds.height - 18) / 2)
    }
    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }
}

@MainActor
final class MenuToggleRow: SettingsMenuRow {
    let control: NSButton
    var onChange: ((Bool) -> Void)?
    var value: Bool { control.state == .on }
    init(title: String) {
        control = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        super.init(title: title)
        label.isHidden = true // The real checkbox owns both its box and title.
        control.font = label.font
        control.target = self
        control.action = #selector(changed)
        control.setAccessibilityLabel(title)
        control.setAccessibilityHelp("Toggle this setting. Left turns it off; Right turns it on.")
        addSubview(control)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var highlighted: Bool {
        didSet {
            control.attributedTitle = NSAttributedString(string: control.title, attributes: [
                .font: control.font ?? .systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
            ])
        }
    }
    override func layout() {
        super.layout()
        // Indent the checkbox under the section heading, as in a compact form.
        control.frame = NSRect(x: Self.textInset + 7, y: (bounds.height - 22) / 2,
                               width: bounds.width - Self.textInset - 7 - Self.trailingInset, height: 22)
    }
    func update(_ value: Bool) { control.state = value ? .on : .off }
    func activate(_ value: Bool? = nil) {
        guard control.isEnabled else { return }
        update(value ?? !self.value)
        changed()
    }
    @objc private func changed() { onChange?(value) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === control || hit.isDescendant(of: control) ? hit : self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49: activate()
        case 123: activate(false)
        case 124: activate(true)
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class PermissionMenuRow: SettingsMenuRow {
    let permission: CapturePermission
    let button = NSButton(title: "Allow", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    private(set) var state: PermissionMenuState = .notGranted
    var onActivate: ((PermissionMenuAction) -> Void)?

    init(_ permission: CapturePermission) {
        self.permission = permission
        super.init(title: permission.title)
        label.setAccessibilityElement(true)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = label.font
        button.target = self
        button.action = #selector(activate)
        status.font = .systemFont(ofSize: 13, weight: .semibold)
        status.alignment = .center
        status.setAccessibilityElement(false) // The label/button describe the state.
        addSubview(status)
        addSubview(button)
        update(.notGranted, enabled: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var highlighted: Bool {
        didSet { status.textColor = highlighted ? .selectedMenuItemTextColor : .systemGreen }
    }
    override func layout() {
        super.layout()
        button.frame = NSRect(x: bounds.width - Self.trailingInset - 112, y: 1, width: 112, height: 26)
        status.frame = NSRect(x: button.frame.minX - 24, y: 5, width: 18, height: 18)
        let leading = checkboxTitleLeading - label.cell!.titleRect(forBounds: label.bounds).minX
        label.frame = NSRect(x: leading, y: 5, width: max(0, status.frame.minX - 8 - leading), height: 18)
    }
    func update(_ state: PermissionMenuState, enabled: Bool) {
        self.state = state
        let description = state == .granted ? "Granted" : "Not granted"
        button.title = state.buttonTitle
        button.isEnabled = enabled
        button.setAccessibilityLabel(state.action == .allow ? "Allow \(permission.title)" : "Open \(permission.title) settings")
        button.setAccessibilityHelp("\(permission.title): \(description)")
        label.setAccessibilityLabel("\(permission.title): \(description)")
        status.stringValue = state == .granted ? "✓" : ""
        status.textColor = highlighted ? .selectedMenuItemTextColor : .systemGreen
    }
    @objc func activate() { if button.isEnabled { onActivate?(state.action) } }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        // Native fallback before Accessibility allows the capture event tap.
        if event.keyCode == 36 || event.keyCode == 49 { activate() }
        else { super.keyDown(with: event) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === button || hit.isDescendant(of: button) ? hit : self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }
}

@MainActor
final class MenuSectionRow: SettingsMenuRow {
    init(title: String, font: NSFont) {
        super.init(title: title, height: 30)
        label.font = .systemFont(ofSize: font.pointSize, weight: .semibold)
        label.textColor = .labelColor
        label.setAccessibilityElement(true)
        label.setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class ShortcutMenuRow: SettingsMenuRow {
    let recordButton = NSButton(title: "", target: nil, action: nil)
    let resetButton = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset shortcut")!, target: nil, action: nil)
    private(set) var guidance = ""
    var onGuidanceChange: ((String) -> Void)?
    var onRecord: (() -> Void)?
    var onReset: (() -> Void)?
    private(set) var recording = false
    private var shortcut = CaptureShortcut.default
    init() {
        super.init(title: "Capture Shortcut")
        recordButton.font = label.font
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .small
        recordButton.target = self
        recordButton.action = #selector(record)
        recordButton.setAccessibilityLabel("Record capture shortcut")
        resetButton.isBordered = false
        resetButton.target = self
        resetButton.action = #selector(reset)
        resetButton.toolTip = "Reset to ⌘⇧2"
        resetButton.setAccessibilityLabel("Reset capture shortcut to Command Shift 2")
        for view in [recordButton, resetButton] { addSubview(view) }
        update(.default)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let topRowY = bounds.height - Self.rowHeight
        let right = bounds.width - Self.trailingInset
        resetButton.frame = NSRect(x: right - 24, y: topRowY + 1, width: 24, height: 26)
        let width: CGFloat = recording ? 122 : max(84, min(122, recordButton.attributedTitle.size().width + 24))
        recordButton.frame = NSRect(x: resetButton.frame.minX - 6 - width, y: topRowY + 1, width: width, height: 26)
        let labelTitleX = label.cell!.titleRect(forBounds: label.bounds).minX
        let leading = checkboxTitleLeading - labelTitleX
        label.frame = NSRect(x: leading, y: topRowY + 5,
                             width: max(0, recordButton.frame.minX - 8 - leading), height: 18)
    }
    func update(_ shortcut: CaptureShortcut) {
        self.shortcut = shortcut
        if !recording { setRecording(false) }
    }
    func setRecording(_ active: Bool, message: String? = nil) {
        recording = active
        recordButton.title = active ? "Press shortcut…" : shortcut.display
        recordButton.setAccessibilityValue(recordButton.title)
        recordButton.setAccessibilityLabel(active ? "Recording capture shortcut" : "Capture shortcut: \(shortcut.accessibilityDescription)")
        let message = message ?? (active ? "Include ⌘ or ⌃ · Esc cancels" : "")
        recordButton.setAccessibilityHelp(message.isEmpty ? "Press to change the capture shortcut." : message)
        // Never resize the custom view during tracking: AppKit can retain the
        // old row's clipping rectangle. A separate native item owns guidance.
        if guidance != message {
            guidance = message
            onGuidanceChange?(message)
        }
        needsLayout = true
    }
    func setEnabled(_ enabled: Bool) { recordButton.isEnabled = enabled; resetButton.isEnabled = enabled }
    @objc func record() { if recordButton.isEnabled { onRecord?() } }
    @objc func reset() { if resetButton.isEnabled { onReset?() } }
}

@MainActor
final class CaptureMenu: NSObject {
    struct Actions {
        var capture: () -> Void
        var retry: () -> Void
        var permission: (CapturePermission, PermissionMenuAction) -> Void
        var backend: (Backend) -> Void
        var lines: (Bool) -> Void
        var sound: (Bool) -> Void
        var record: () -> Void
        var resetShortcut: () -> Void
        var quit: () -> Void
        var additiveClipboard: (Bool) -> Void = { _ in }
        var showCaptureFeedback: (Bool) -> Void = { _ in }
        var login: (Bool) -> Void = { _ in }
        var loginSettings: () -> Void = {}
    }
    let menu = NSMenu()
    let capture = NSMenuItem(title: "Capture Text", action: nil, keyEquivalent: "")
    let retry = NSMenuItem(title: "Retry OCR Engine", action: nil, keyEquivalent: "")
    let permissionRows = Dictionary(uniqueKeysWithValues: CapturePermission.allCases.map { ($0, PermissionMenuRow($0)) })
    let permissionHint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let shortcut = ShortcutMenuRow()
    let shortcutHint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let engineItem = NSMenuItem(title: "OCR Engine", action: nil, keyEquivalent: "")
    let engineMenu = NSMenu(title: "OCR Engine")
    let lines = MenuToggleRow(title: "Preserve Line Breaks")
    let sound = MenuToggleRow(title: "Play Sound When Copied")
    let additive = MenuToggleRow(title: "Additive Clipboard")
    let feedback = MenuToggleRow(title: "Show Capture Feedback")
    let login = MenuToggleRow(title: "Launch at Login")
    let loginHelp = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private(set) var engines: [NSMenuItem] = []
    private(set) var shortcutItem: NSMenuItem!
    private let actions: Actions
    private var permissionActionsEnabled = true

    init(actions: Actions, backends: [Backend] = Backend.allCases) {
        precondition(!backends.isEmpty && Set(backends).count == backends.count)
        self.actions = actions
        super.init()
        menu.autoenablesItems = false
        menu.showsStateColumn = false // Only the engine submenu needs a checkmark gutter.
        add(capture, #selector(captureAction))
        add(retry, #selector(retryAction))
        menu.addItem(.separator())
        addSection("Settings")
        shortcutItem = addView(shortcut, action: #selector(recordAction))
        shortcutHint.isEnabled = false
        shortcutHint.isHidden = true
        menu.addItem(shortcutHint)
        for row in [lines, additive, sound, feedback, login] {
            _ = addView(row, action: #selector(toggleAction(_:)))
        }
        loginHelp.isHidden = true
        add(loginHelp, #selector(loginSettingsAction))
        engineMenu.autoenablesItems = false
        engineMenu.showsStateColumn = true
        engineItem.submenu = engineMenu
        if backends.count > 1 { menu.addItem(engineItem) }
        for backend in [Backend.nativeCPU, .coreMLCPU, .onnxSmall] where backends.contains(backend) {
            let item = NSMenuItem(title: backend.menuTitle, action: nil, keyEquivalent: "")
            item.representedObject = backend.rawValue
            item.toolTip = backend.toolTip
            item.target = self
            item.action = #selector(engineAction(_:))
            engineMenu.addItem(item)
            engines.append(item)
        }
        menu.addItem(.separator())
        addSection("Permissions")
        for permission in CapturePermission.allCases {
            let row = permissionRows[permission]!
            _ = addView(row, action: #selector(permissionAction(_:)))
            row.onActivate = { [weak self] action in
                guard let self, self.permissionActionsEnabled else { return }
                self.menu.cancelTracking()
                onCaptureRunLoop { self.actions.permission(permission, action) }
            }
        }
        permissionHint.isEnabled = false
        permissionHint.isHidden = true
        menu.addItem(permissionHint)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TextPicker", action: nil, keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        add(quit, #selector(quitAction))
        lines.onChange = actions.lines
        sound.onChange = actions.sound
        additive.onChange = actions.additiveClipboard
        feedback.onChange = actions.showCaptureFeedback
        login.onChange = actions.login
        shortcut.onRecord = actions.record
        shortcut.onReset = actions.resetShortcut
        shortcut.onGuidanceChange = { [weak self] message in
            guard let self else { return }
            self.shortcutHint.title = message
            self.shortcutHint.attributedTitle = NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
            ])
            self.shortcutHint.isHidden = message.isEmpty
        }
    }
    private func addSection(_ title: String) {
        let header = NSMenuItem.sectionHeader(title: title)
        header.view = MenuSectionRow(title: title, font: menu.font)
        menu.addItem(header)
    }
    private func add(_ item: NSMenuItem, _ selector: Selector) {
        item.target = self; item.action = selector; menu.addItem(item)
    }
    private func addView(_ view: SettingsMenuRow, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: view.label.stringValue, action: nil, keyEquivalent: "")
        view.label.font = menu.font
        if let row = view as? MenuToggleRow { row.control.font = menu.font }
        item.view = view; add(item, action)
        return item
    }
    func update(ready: Bool, capturing: Bool, failed: Bool,
                access: CaptureAccess, backend: Backend, keepLines: Bool, playSound: Bool, shortcut value: CaptureShortcut,
                preservingSelection: Bool = false, additiveClipboard: Bool = false,
                showCaptureFeedback: Bool = true, loginRequested: Bool = false,
                loginHelpTitle: String? = nil, loginError: String? = nil,
                requestedPermissions: Set<CapturePermission> = [], permissionError: String? = nil) {
        // The open menu is the capture subject. Do not reflow its geometry
        // or gray its controls until the image exists.
        permissionActionsEnabled = !capturing
        guard !preservingSelection else { return }
        // Capture Text is always the first row; fast progress must not flash a
        // temporary label above it. Only availability and actionable rows change.
        capture.isEnabled = ready && access.ready
        retry.isHidden = !failed
        for permission in CapturePermission.allCases {
            permissionRows[permission]!.update(access.menuState(permission, requested: requestedPermissions), enabled: !capturing)
        }
        for item in menu.items where item.view is PermissionMenuRow { item.isEnabled = !capturing }
        let guidance = access.menuGuidance(settingsError: permissionError)
        permissionHint.title = guidance ?? ""
        permissionHint.attributedTitle = NSAttributedString(string: guidance ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
        ])
        permissionHint.toolTip = permissionError
        permissionHint.isHidden = guidance == nil
        shortcut.setEnabled(!capturing)
        shortcutItem.isEnabled = !capturing
        shortcut.update(value)
        capture.keyEquivalent = shortcut.recording ? "" : value.menuEquivalent
        capture.keyEquivalentModifierMask = value.menuModifiers
        lines.update(keepLines)
        sound.update(playSound)
        additive.update(additiveClipboard)
        feedback.update(showCaptureFeedback)
        login.update(loginRequested)
        loginHelp.title = loginHelpTitle ?? ""
        loginHelp.toolTip = loginError
        loginHelp.isHidden = loginHelpTitle == nil
        engineItem.isEnabled = !capturing
        engineItem.toolTip = "Current engine: \(backend.shortTitle)"
        for item in engines {
            item.state = item.representedObject as? String == backend.rawValue ? .on : .off
            item.isEnabled = !capturing
        }
    }
    func highlight(_ item: NSMenuItem?) -> Set<UInt16> {
        for row in [shortcut as SettingsMenuRow, lines, additive, sound, feedback, login] + CapturePermission.allCases.map({ permissionRows[$0]! }) {
            row.highlighted = item != nil && item?.view === row
        }
        guard item?.isEnabled == true else { return [] }
        if item?.view is MenuToggleRow { return [36, 49, 123, 124] }
        if item === shortcutItem { return [36, 49, 51] }
        if item?.view is PermissionMenuRow { return [36, 49] }
        return []
    }
    func handleKey(_ key: UInt16, item: NSMenuItem) {
        guard item.isEnabled else { return }
        if let row = item.view as? MenuToggleRow {
            if key == 123 { row.activate(false) }
            else if key == 124 { row.activate(true) }
            else if key == 36 || key == 49 { row.activate() }
        } else if let row = item.view as? PermissionMenuRow {
            if key == 36 || key == 49 { row.activate() }
        } else if item === shortcutItem {
            if key == 51 { shortcut.reset() }
            else if key == 36 || key == 49 { shortcut.record() }
        }
    }
    @objc private func captureAction() { actions.capture() }
    @objc private func retryAction() { actions.retry() }
    @objc private func permissionAction(_ item: NSMenuItem) { (item.view as? PermissionMenuRow)?.activate() }
    @objc private func recordAction() { shortcut.record() }
    @objc private func toggleAction(_ item: NSMenuItem) { (item.view as? MenuToggleRow)?.activate() }
    @objc private func loginSettingsAction() { actions.loginSettings() }
    @objc private func engineAction(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let backend = Backend(rawValue: raw) { actions.backend(backend) }
    }
    @objc private func quitAction() { actions.quit() }
}
