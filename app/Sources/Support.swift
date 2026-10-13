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

enum Backend: String, CaseIterable {
    case onnxSmall = "onnx-small", coreMLCPU = "coreml-cpu", nativeCPU = "native-cpu"

    static func configured(_ raw: Any?) -> [Backend]? {
        guard let raw else { return allCases } // Older full bundles / test executables.
        guard let names = raw as? [String], !names.isEmpty, Set(names).count == names.count else { return nil }
        let values = names.compactMap(Backend.init(rawValue:))
        return values.count == names.count ? values : nil
    }
    static var bundled: [Backend] {
        configured(Bundle.main.object(forInfoDictionaryKey: "TextPickerEngines")) ?? []
    }
    static func restored(_ value: String?, available: [Backend] = allCases) -> Backend {
        precondition(!available.isEmpty)
        if let saved = value.flatMap(Backend.init(rawValue:)), available.contains(saved) { return saved }
        return [.coreMLCPU, .nativeCPU, .onnxSmall].first { available.contains($0) }!
    }
    var menuTitle: String {
        switch self {
        case .onnxSmall: return "ONNX Runtime CPU"
        case .coreMLCPU: return "Core ML CPU"
        case .nativeCPU: return "Native CPU"
        }
    }
    var shortTitle: String {
        switch self {
        case .onnxSmall: return "Small · ONNX/CPU"
        case .coreMLCPU: return "Small · Core ML/CPU"
        case .nativeCPU: return "Small · Native/CPU"
        }
    }
    var toolTip: String {
        switch self {
        case .onnxSmall:
            return "PP-OCRv6 Small through ONNX Runtime and RapidOCR on the CPU. Independent of Core ML; a working alternative with its own preprocessing."
        case .coreMLCPU:
            return "Converted PP-OCRv6 Small with CPU-only Core ML inference. Recommended on this Mac; Neural Engine excluded. NumPy/OpenCV handle pre/postprocessing."
        case .nativeCPU:
            return "Both PP-OCRv6 Small networks run in our C++/Accelerate CPU executor with unchanged FP32 weights. ImageIO decoding, minimal native OpenCV preprocessing/crops and Clipper box expansion; no Python, ONNX Runtime or Core ML inference. Core ML CPU remains recommended."
        }
    }
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

final class Diagnostics {
    static let shared = Diagnostics()
    private let url: URL
    private init() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TextPicker")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        url = folder.appendingPathComponent("prototype.log")
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
