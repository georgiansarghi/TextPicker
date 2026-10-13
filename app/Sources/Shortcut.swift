import AppKit
import Carbon

/// Physical key + explicit modifiers. No typed text or input history is retained.
struct CaptureShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt64
    static let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    static let `default` = CaptureShortcut(keyCode: 19, modifiers: CGEventFlags([.maskCommand, .maskShift]).rawValue)
    static let preferenceKey = "captureShortcut"

    // Regular keyboard keys and F1–F20. Escape is always cancellation; modifier,
    // media, return/tab/delete keys cannot become capture shortcuts.
    static let regularKeys: Set<UInt16> = Set(0...35).union([37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50])
    static let functionKeys: [UInt16: String] = [122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]

    var validationError: String? {
        let flags = CGEventFlags(rawValue: modifiers)
        guard modifiers == flags.intersection(Self.modifierMask).rawValue,
              flags.contains(.maskCommand) || flags.contains(.maskControl) else {
            return "Include Command (⌘) or Control (⌃)."
        }
        guard Self.regularKeys.contains(keyCode) || Self.functionKeys[keyCode] != nil else {
            return "Use a letter, number, punctuation or F-key."
        }
        // Protect Quit/close/hide and macOS screenshot/logout/force-quit chords.
        // Other applications' shortcuts cannot be comprehensively enumerated.
        if flags.contains(.maskCommand) && ([12, 13, 4].contains(keyCode) ||
            (flags.contains(.maskShift) && [20, 21, 23].contains(keyCode))) {
            return "That combination is reserved. Choose another."
        }
        return nil
    }
    func matches(key: Int64, flags: CGEventFlags) -> Bool {
        key == Int64(keyCode) && flags.intersection(Self.modifierMask).rawValue == modifiers
    }
    static func restored(from defaults: UserDefaults = .standard) -> CaptureShortcut {
        guard let data = defaults.data(forKey: preferenceKey), data.count <= 1024,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.validationError == nil else { return .default }
        return value
    }
    func save(to defaults: UserDefaults = .standard) {
        guard validationError == nil, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
    var keyLabel: String {
        if let function = Self.functionKeys[keyCode] { return function }
        // Resolve the physical key against the current keyboard layout, without
        // Shift/Option/dead-key composition. In particular, German Y/Z stay honest.
        guard let copied = TISCopyCurrentASCIICapableKeyboardLayoutInputSource() else { return "Key \(keyCode)" }
        let source = copied.takeRetainedValue()
        return withExtendedLifetime(source) {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(keyCode)" }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKey: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKey, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return "Key \(keyCode)" }
            let label = String(utf16CodeUnits: characters, count: length)
            return label.uppercased().count == 1 ? label.uppercased() : label
        }
    }
    var display: String {
        let flags = CGEventFlags(rawValue: modifiers)
        return (flags.contains(.maskControl) ? "⌃" : "") + (flags.contains(.maskAlternate) ? "⌥" : "") +
            (flags.contains(.maskShift) ? "⇧" : "") + (flags.contains(.maskCommand) ? "⌘" : "") + keyLabel
    }
    var accessibilityDescription: String {
        let flags = CGEventFlags(rawValue: modifiers)
        var words: [String] = []
        if flags.contains(.maskControl) { words.append("Control") }
        if flags.contains(.maskAlternate) { words.append("Option") }
        if flags.contains(.maskShift) { words.append("Shift") }
        if flags.contains(.maskCommand) { words.append("Command") }
        words.append(keyLabel)
        return words.joined(separator: " ")
    }
    var menuModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        return result
    }
    var menuEquivalent: String {
        // Function-key equivalents use AppKit's private-use Unicode characters.
        if let name = Self.functionKeys[keyCode], let number = Int(name.dropFirst()) {
            return String(UnicodeScalar(0xF703 + number)!)
        }
        let label = keyLabel.lowercased()
        return label.count == 1 ? label : ""
    }
}

/// Paired ownership for menu editing. Finishing recording/menu tracking does not
/// leak key-up events or held-key repeats into the underlying app or capture path.
struct MenuKeyRouting {
    enum Action: Equatable { case record, control }
    var recording = false
    var controlKeys: Set<UInt16> = []
    private var owned: Set<UInt16> = []
    mutating func route(_ type: CGEventType, key: UInt16, flags: CGEventFlags, repeated: Bool, captureActive: Bool = false) -> (consume: Bool, action: Action?) {
        if type == .keyUp { return (owned.remove(key) != nil, nil) }
        guard type == .keyDown else { return (false, nil) }
        if owned.contains(key) { return (true, nil) }
        guard !captureActive else { return (false, nil) }
        let control = controlKeys.contains(key) && flags.intersection(CaptureShortcut.modifierMask).isEmpty
        guard recording || control else { return (false, nil) }
        // A preexisting held key retains its original release owner.
        guard !repeated else { return (true, nil) }
        owned.insert(key)
        return (true, recording ? .record : .control)
    }
    mutating func end() { recording = false; controlKeys = [] }
}
