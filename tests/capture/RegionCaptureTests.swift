import AppKit
import ScreenCaptureKit

@main
struct RegionCaptureTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            preconditionFailure(message)
        }
    }
    static func near(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) < 0.000001 }
    static func same(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        near(lhs.minX, rhs.minX) && near(lhs.minY, rhs.minY)
            && near(lhs.width, rhs.width) && near(lhs.height, rhs.height)
    }
    static func syntheticImage(width: Int, height: Int, transparentPixel: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x % 256)
                bytes[i + 1] = UInt8(y % 256)
                bytes[i + 2] = UInt8((x + y) % 256)
            }
        }
        if transparentPixel { bytes[0] = 0; bytes[1] = 0; bytes[2] = 0; bytes[3] = 0 }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func main() async throws {
        let view = CGSize(width: 100, height: 80)
        let known: [(CGRect, CGFloat, CGRect, Int, Int)] = [
            (CGRect(x: 10, y: 12, width: 30, height: 25), 2, CGRect(x: 10, y: 43, width: 30, height: 25), 60, 50),
            (CGRect(x: 0, y: 70, width: 10, height: 10), 2, CGRect(x: 0, y: 0, width: 10, height: 10), 20, 20),
            (CGRect(x: 90, y: 0, width: 10, height: 10), 1, CGRect(x: 90, y: 70, width: 10, height: 10), 10, 10),
            (CGRect(x: 10.2, y: 12.7, width: 30.1, height: 25.2), 1, CGRect(x: 10, y: 42, width: 31, height: 26), 31, 26),
            (CGRect(x: 10.2, y: 12.7, width: 30.1, height: 25.2), 2, CGRect(x: 10, y: 42, width: 30.5, height: 25.5), 61, 51),
        ]
        for (selection, scale, source, width, height) in known {
            let plan = try RegionCaptureRequest(selection: selection, viewSize: view, contentSize: view, pointPixelScale: scale)
            check(same(plan.selectionSourceRect, source), "Known exact top-left selection rectangle")
            check(plan.pixelWidth == width && plan.pixelHeight == height, "Known backing pixel dimensions")
        }
        // Retina, non-Retina, scaled and portrait displays, both drag directions,
        // explicit whole-display selection, fractional edges and boundary clipping.
        for size in [view, CGSize(width: 1512, height: 982), CGSize(width: 801, height: 601), CGSize(width: 1080, height: 1920)] {
            for scale: CGFloat in [1, 2, 1.25, 1.5] {
                let full = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
                for selection in [CGRect(x: 10.2, y: 12.7, width: 30.1, height: 25.2),
                                  CGRect(x: 40.3, y: 37.9, width: -30.1, height: -25.2),
                                  CGRect(x: -8, y: -4, width: 21, height: 30),
                                  CGRect(x: size.width - 10.1, y: size.height - 12.3, width: 25, height: 30),
                                  CGRect(origin: .zero, size: size)] {
                    let plan = try RegionCaptureRequest(selection: selection, viewSize: size, contentSize: size, pointPixelScale: scale)
                    let expected = pixelCrop(selection: selection, viewSize: size, imageSize: full)
                    let sx = full.width / size.width, sy = full.height / size.height
                    let requestedPixels = CGRect(x: (plan.sourceRect.minX * sx).rounded() + plan.cropRect.minX,
                                                 y: (plan.sourceRect.minY * sy).rounded() + plan.cropRect.minY,
                                                 width: plan.cropRect.width, height: plan.cropRect.height)
                    check(plan.sourceRect.insetBy(dx: -0.000001, dy: -0.000001).contains(plan.selectionSourceRect), "Envelope contains only selection plus alignment boundary")
                    check(plan.selectionSourceRect.minX - plan.sourceRect.minX < 1.000001 &&
                          plan.selectionSourceRect.minY - plan.sourceRect.minY < 1.000001 &&
                          plan.sourceRect.maxX - plan.selectionSourceRect.maxX < 1.000001 &&
                          plan.sourceRect.maxY - plan.selectionSourceRect.maxY < 1.000001,
                          "Alignment expands less than one logical point per edge")
                    check(same(requestedPixels, expected), "Same pixel envelope as prior crop")
                    check(plan.pixelWidth == Int(expected.width) && plan.pixelHeight == Int(expected.height), "No downsampling")
                    let config = plan.configuration()
                    check(config.sourceRect == plan.sourceRect && !config.sourceRect.isEmpty, "Explicit bounded source; no default full display")
                    check(config.width == plan.captureWidth && config.height == plan.captureHeight, "Output matches native aligned region, not forced odd dimensions")
                    check(!config.showsCursor && !config.capturesAudio, "Cursor and system audio explicitly off")
                    if #available(macOS 15.0, *) { check(!config.captureMicrophone, "Microphone explicitly off") }
                    check(config.captureResolution == .best, "Original resolution policy retained")
                }
            }
        }
        // Desktop origins never leak into the display-local source rectangle.
        for frame in [CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                      CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                      CGRect(x: 0, y: 1080, width: 1280, height: 720),
                      CGRect(x: 1920, y: 0, width: 1080, height: 1920)] {
            let global = CGRect(x: frame.minX + 13.5, y: frame.minY + 29.5, width: 40, height: 25)
            let local = global.offsetBy(dx: -frame.minX, dy: -frame.minY)
            let plan = try RegionCaptureRequest(selection: local, viewSize: frame.size,
                                                contentSize: frame.size, pointPixelScale: 2)
            check(same(plan.selectionSourceRect, CGRect(x: 13.5, y: frame.height - 54.5, width: 40, height: 25)),
                  "Secondary display uses local top-left points, not desktop origin")
            check(plan.pixelWidth == 80 && plan.pixelHeight == 50, "Secondary-display pixel scale retained")
        }
        let invalid: [(CGRect, CGSize, CGSize, CGFloat)] = [
            (.zero, view, view, 2), (.null, view, view, 2), (.infinite, view, view, 2),
            (CGRect(x: 200, y: 200, width: 10, height: 10), view, view, 2),
            (CGRect(x: CGFloat.nan, y: 2, width: 3, height: 4), view, view, 2),
            (CGRect(x: 1, y: 2, width: 3, height: 4), .zero, .zero, 2),
            (CGRect(x: 1, y: 2, width: 3, height: 4), view, CGSize(width: 101, height: 80), 2),
            (CGRect(x: 1, y: 2, width: 3, height: 4), view, view, 0),
            (CGRect(x: 1, y: 2, width: 3, height: 4), view, view, -1),
            (CGRect(x: 1, y: 2, width: 3, height: 4), view, view, .infinity),
            (CGRect(x: 1, y: 2, width: 3, height: 4), view, view, .nan),
            (CGRect(x: 1, y: 2, width: 3, height: 4), view, view, .greatestFiniteMagnitude),
            (CGRect(x: 1, y: 2, width: 3, height: 4), view, view, .leastNonzeroMagnitude),
        ]
        for (index, entry) in invalid.enumerated() {
            let (selection, size, content, scale) = entry
            do {
                _ = try RegionCaptureRequest(selection: selection, viewSize: size, contentSize: content, pointPixelScale: scale)
                preconditionFailure("Invalid/stale geometry accepted at case \(index)")
            } catch { check(true, "Invalid geometry rejected before image acquisition") }
        }
        let plan = try RegionCaptureRequest(selection: CGRect(x: 10, y: 12, width: 30, height: 25),
                                            viewSize: view, contentSize: view, pointPixelScale: 2)
        // Only synthetic test-owned pixels exist here; no ScreenCaptureKit call.
        let scene = syntheticImage(width: 200, height: 160)
        let expected = scene.cropping(to: CGRect(x: 20, y: 86, width: 60, height: 50))!
        var calls = 0
        let result = try await plan.capture { config in
            calls += 1
            check(config.sourceRect == CGRect(x: 10, y: 43, width: 30, height: 25), "Production provider receives only the region")
            check(config.width == 60 && config.height == 50, "Provider never asked for full-display output")
            return expected
        }
        check(calls == 1 && result === expected, "Region image forwarded unchanged, without second crop")
        for wrong in [scene, syntheticImage(width: 59, height: 50), syntheticImage(width: 60, height: 51)] {
            var attempts = 0
            do {
                _ = try await plan.capture { _ in attempts += 1; return wrong }
                preconditionFailure("Unexpected output dimensions accepted")
            } catch { check(attempts == 1, "Unexpected image rejected; no full-display retry") }
        }
        // The macOS live probe reproduced transparent strips and scaling when
        // fractional logical-point sources were forced into odd pixel canvases.
        for selection in [CGRect(x: 10.5, y: 12.5, width: 30, height: 25),
                          CGRect(x: 10.5, y: 12.5, width: 30.5, height: 3.5),
                          CGRect(x: 10.5, y: 12.5, width: 3.5, height: 30.5)] {
            let aligned = try RegionCaptureRequest(selection: selection, viewSize: view, contentSize: view, pointPixelScale: 2)
            check(aligned.sourceRect == aligned.sourceRect.integral, "Whole-point API request")
            check(aligned.captureWidth % 2 == 0 && aligned.captureHeight % 2 == 0, "Native Retina canvas dimensions")
            let frame = syntheticImage(width: aligned.captureWidth, height: aligned.captureHeight)
            let expectedCrop = frame.cropping(to: aligned.cropRect)!
            let trimmed = try await aligned.capture { _ in frame }
            check(trimmed.width == aligned.pixelWidth && trimmed.height == aligned.pixelHeight, "Exact selected output size after boundary trim")
            check(CFEqual(trimmed.dataProvider!.data!, expectedCrop.dataProvider!.data!), "Boundary trim preserves RGB/alpha bytes without resampling")
        }
        let opaqueStats = CaptureImageDiagnostics(expected)
        check(opaqueStats.nonopaquePixels == 0 && opaqueStats.minimumAlpha == 255, "Opaque image statistics")
        let transparentStats = CaptureImageDiagnostics(syntheticImage(width: 7, height: 5, transparentPixel: true))
        check(transparentStats.nonopaquePixels == 1 && transparentStats.minimumAlpha == 0, "Transparency count and minimum alpha")
        check(transparentStats.description == "pixels=7x5 nonopaque=1 alpha_min=0", "Diagnostic contains size and alpha only")
        var failures = 0
        do {
            _ = try await plan.capture { _ in failures += 1; throw appError("synthetic provider failure") }
            preconditionFailure("Provider error ignored")
        } catch { check(failures == 1, "Provider error propagated without fallback") }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await plan.capture { _ in preconditionFailure("Cancelled request acquired pixels") }
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError { check(true, "Pre-cancelled request does not acquire pixels") }
        let cancelledDuring = Task {
            try await plan.capture { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return expected
            }
        }
        do { _ = try await cancelledDuring.value; preconditionFailure("Stale image delivered") }
        catch is CancellationError { check(true, "Cancelled acquisition discards its image") }
        print("PASS: \(checks) region-only capture checks; synthetic/injected pixels, no real capture or permission requests")
    }
}
