import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Menu tracking must not postpone selection/cancellation callbacks until the
/// menu closes. Also used to return asynchronous screen acquisition to AppKit.
func onCaptureRunLoop(_ action: @escaping @MainActor () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated { action() }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

struct DisplayLayoutEntry: Equatable {
    let id: UInt32
    let frame: CGRect
    let scale: CGFloat

    @MainActor static func current() -> [DisplayLayoutEntry] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayLayoutEntry(id: id.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
        }.sorted { $0.id < $1.id }
    }
}

let releasesURL = URL(string: "https://github.com/georgiansarghi/TextPicker/releases/latest")!

/// Releases up to 0.11 used the placeholder identifier `local.textpicker`.
/// Copy those settings once so the identifier change keeps user choices.
func migrateLegacySettings(to identifier: String, from legacy: String = "local.textpicker",
                           defaults: UserDefaults = .standard) {
    guard identifier != legacy, defaults.persistentDomain(forName: identifier)?.isEmpty ?? true,
          let settings = defaults.persistentDomain(forName: legacy), !settings.isEmpty else { return }
    defaults.setPersistentDomain(settings, forName: identifier)
}

func appError(_ message: String) -> NSError {
    NSError(domain: "TextPicker", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Local AppKit points (bottom-left) -> CGImage pixels (top-left).
func pixelCrop(selection: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
    guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
    let clipped = selection.standardized.intersection(CGRect(origin: .zero, size: viewSize))
    guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return .zero }
    let sx = imageSize.width / viewSize.width, sy = imageSize.height / viewSize.height
    return CGRect(x: clipped.minX * sx, y: (viewSize.height - clipped.maxY) * sy,
                  width: clipped.width * sx, height: clipped.height * sy)
        .integral.intersection(CGRect(origin: .zero, size: imageSize))
}

/// An explicitly enabled, in-memory collection of successful OCR captures.
/// Never reads existing clipboard contents. Proposals commit only after a
/// successful clipboard write, so blank/cancel/failure cannot start a session.
struct AdditiveClipboardSession {
    private var enabled = false
    private var captured: String?
    var isAppending: Bool { enabled && captured != nil }

    mutating func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        captured = nil
    }
    func proposedText(_ raw: String, keepLineBreaks: Bool) -> String {
        let text = clipboardText(raw, keepLineBreaks: keepLineBreaks)
        guard !text.isEmpty, enabled, let captured else { return text }
        return captured + "\n" + text
    }
    mutating func didCopy(_ text: String) {
        if enabled && !text.isEmpty { captured = text }
    }
}

func clipboardText(_ raw: String, keepLineBreaks: Bool) -> String {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return keepLineBreaks ? text : text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
}

final class CaptureFiles {
    let directory: URL
    init(directory customDirectory: URL? = nil) throws {
        directory = customDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("TextPicker-Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Single-instance app: clear only our own stale capture files after a crash.
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if file.lastPathComponent.hasPrefix("capture-") && file.pathExtension == "png" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    func save(_ image: CGImage) throws -> URL {
        let url = directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        // Create with owner-only permissions before writing any image bytes.
        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw appError("Cannot create temporary capture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            remove(url)
            throw appError("Cannot save temporary capture")
        }
        // ImageIO may replace the pre-created file while finalizing its PNG.
        // The enclosing 0700 directory keeps it private during that replacement.
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        catch { remove(url); throw error }
        return url
    }
    func remove(_ url: URL?) {
        if let url, url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

func diagnosticTracingEnabled(_ environment: [String: String]) -> Bool {
    environment["TEXTPICKER_DEBUG"] == "1"
}

final class Diagnostics {
    static let traceEnabled = diagnosticTracingEnabled(ProcessInfo.processInfo.environment)
    static let shared = Diagnostics()
    private let url: URL
    private init() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TextPicker")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        url = folder.appendingPathComponent("TextPicker.log")
    }
    /// Verbose metadata is opt-in. The autoclosure avoids formatting when disabled.
    func trace(_ message: @autoclosure () -> String) {
        guard Self.traceEnabled else { return }
        log(message())
    }
    /// Call on main thread. No recognized text or screenshot content in this log.
    func log(_ message: String) {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 256_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
    }
}
