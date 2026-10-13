// Opt-in LIVE diagnostic, not part of scripts/test.sh. Shows a synthetic window and
// captures ONLY that window through a display include-list. No permission request,
// other-window pixels, clipboard access, or shipping debug-image persistence.
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

private final class PatternView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        for y in stride(from: 0, to: Int(bounds.height), by: 8) {
            for x in stride(from: 0, to: Int(bounds.width), by: 8) {
                let column: Int = x / 8, row: Int = y / 8
                let red: CGFloat = CGFloat((column + row * 3) % 9 + 1) / 10.0
                let green: CGFloat = CGFloat((column * 3 + row) % 7 + 1) / 8.0
                let blue: CGFloat = CGFloat((column * 2 + row * 5) % 9 + 1) / 10.0
                NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).setFill()
                NSRect(x: x, y: y, width: 8, height: 8).fill()
            }
        }
    }
}

@MainActor
private final class Probe: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    let output: URL
    init(output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); NSApp.terminate(nil) }
            catch { fputs("Live probe failed: \(error)\n", stderr); exit(1) }
        }
    }
    func save(_ image: CGImage, name: String) throws {
        let path = output.appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw appError("Cannot create diagnostic PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw appError("Cannot save diagnostic PNG") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func run() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw appError("Host has no screen access; no permission request made") }
        guard let screen = NSScreen.main,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            throw appError("No display")
        }
        // Refuse reuse: evidence is append-only by choosing a fresh output folder.
        guard !FileManager.default.fileExists(atPath: output.path) else { throw appError("Choose a new diagnostic directory") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let size = CGSize(width: min(900, screen.visibleFrame.width - 80), height: min(500, screen.visibleFrame.height - 80))
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "TextPicker synthetic capture diagnostic"
        panel.level = .floating; panel.isOpaque = true; panel.backgroundColor = .white
        panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.contentView = PatternView(frame: CGRect(origin: .zero, size: size))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        // Allow WindowServer to commit the newly drawn synthetic surface.
        try await Task.sleep(nanoseconds: 300_000_000)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }),
              let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else {
            throw appError("Synthetic window/display not available")
        }
        let filter = SCContentFilter(display: display, including: [window])
        if #available(macOS 14.2, *) { filter.includeMenuBar = false }
        func request(_ local: CGRect) throws -> RegionCaptureRequest {
            try RegionCaptureRequest(selection: local.offsetBy(dx: frame.minX - screen.frame.minX, dy: frame.minY - screen.frame.minY),
                                     viewSize: screen.frame.size, contentSize: filter.contentRect.size,
                                     pointPixelScale: CGFloat(filter.pointPixelScale))
        }
        let referencePlan = try request(CGRect(origin: .zero, size: size))
        let reference = try await referencePlan.capture {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: $0)
        }
        try save(reference, name: "reference")
        let cases: [(String, CGRect)] = [
            ("square", CGRect(x: 40, y: 40, width: 160, height: 160)),
            ("wide", CGRect(x: 40, y: 40, width: 640, height: 8)),
            ("tall", CGRect(x: 40, y: 40, width: 8, height: 360)),
            ("odd-wide", CGRect(x: 40.5, y: 80.5, width: 301.5, height: 13.5)),
            ("odd-tall", CGRect(x: 80.5, y: 40.5, width: 13.5, height: 301.5)),
            ("normal", CGRect(x: 40, y: 40, width: 300, height: 100)),
            ("odd-height", CGRect(x: 40, y: 40, width: 302, height: 13.5)),
            ("odd-width", CGRect(x: 40, y: 40, width: 301.5, height: 14)),
            ("odd-both-integer-origin", CGRect(x: 40, y: 40, width: 301.5, height: 13.5)),
            ("odd-square", CGRect(x: 40.5, y: 40.5, width: 161.5, height: 161.5)),
            ("fractional-origin-even-size", CGRect(x: 40.5, y: 40.5, width: 300, height: 100)),
            ("minimum-wide", CGRect(x: 40.5, y: 40.5, width: 640.5, height: 3.5)),
            ("minimum-tall", CGRect(x: 40.5, y: 40.5, width: 3.5, height: 360.5)),
        ]
        var rows = [[String: Any]]()
        for (name, local) in cases {
            guard CGRect(origin: .zero, size: size).contains(local) else { continue }
            let plan = try request(local)
            for variant in ["legacy", "fixed"] {
                let image: CGImage
                if variant == "legacy" {
                    // Exact pre-fix fractional ROI + forced output size behavior.
                    let config = plan.configuration()
                    config.sourceRect = plan.selectionSourceRect
                    config.width = plan.pixelWidth; config.height = plan.pixelHeight
                    image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } else {
                    image = try await plan.capture {
                        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: $0)
                    }
                }
                let stats = CaptureImageDiagnostics(image)
                try save(image, name: "\(name)-\(variant)")
                let scale = CGFloat(filter.pointPixelScale)
                let row: [String: Any] = ["case": name, "variant": variant,
                    "width": image.width, "height": image.height,
                    "nonopaque_pixels": stats.nonopaquePixels ?? -1, "min_alpha": stats.minimumAlpha ?? -1,
                    "capture_width": plan.captureWidth, "capture_height": plan.captureHeight,
                    "reference_rect": [Double((plan.selectionSourceRect.minX - referencePlan.selectionSourceRect.minX) * scale),
                                       Double((plan.selectionSourceRect.minY - referencePlan.selectionSourceRect.minY) * scale),
                                       Double(plan.pixelWidth), Double(plan.pixelHeight)]]
                rows.append(row)
                print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
                fflush(stdout)
            }
        }
        let result = output.appendingPathComponent("results.json")
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: result)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: result.path)
    }
}

@main
struct RegionCaptureProbe {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: RegionCaptureProbe NEW_OUTPUT_DIRECTORY (synthetic window only)\n", stderr); exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Probe(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
