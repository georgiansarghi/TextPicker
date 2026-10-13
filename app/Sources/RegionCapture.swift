import AppKit
import ScreenCaptureKit

/// Size/alpha statistics only. No pixel colors, coordinates, text or image files
/// are retained. Work stays off the main thread during normal acquisition.
struct CaptureImageDiagnostics {
    let width: Int
    let height: Int
    let nonopaquePixels: Int?
    let minimumAlpha: Int?

    init(_ image: CGImage) {
        width = image.width; height = image.height
        let first = image.alphaInfo == .first || image.alphaInfo == .premultipliedFirst
        let last = image.alphaInfo == .last || image.alphaInfo == .premultipliedLast
        guard first || last else { nonopaquePixels = 0; minimumAlpha = 255; return }
        let channels = image.bitsPerPixel / 8
        guard image.bitsPerComponent == 8, [2, 4].contains(channels), image.bytesPerRow > 0,
              image.width <= image.bytesPerRow / channels,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= image.width * channels,
              image.height - 1 <= (CFDataGetLength(data) - image.width * channels) / image.bytesPerRow else {
            nonopaquePixels = nil; minimumAlpha = nil; return
        }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let little = (channels == 4 && order == .byteOrder32Little) || (channels == 2 && order == .byteOrder16Little)
        let logical = first ? 0 : channels - 1
        let index = little ? channels - 1 - logical : logical
        var count = 0, minimum = 255
        for y in 0..<height {
            for x in 0..<width {
                let alpha = Int(bytes[y * image.bytesPerRow + x * channels + index])
                if alpha != 255 { count += 1 }
                minimum = min(minimum, alpha)
            }
        }
        nonopaquePixels = count; minimumAlpha = minimum
    }
    var description: String {
        "pixels=\(width)x\(height) nonopaque=\(nonopaquePixels.map(String.init) ?? "unknown") alpha_min=\(minimumAlpha.map(String.init) ?? "unknown")"
    }
}

/// ScreenCaptureKit quantizes its source rectangle to logical screen points.
/// Request the tight whole-point envelope at native resolution, then trim only
/// its boundary pixels to the exact selection. Never falls back to a display shot.
struct RegionCaptureRequest {
    let selectionSourceRect: CGRect
    let sourceRect: CGRect
    let cropRect: CGRect
    let captureWidth: Int
    let captureHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int

    init(selection: CGRect, viewSize: CGSize, contentSize: CGSize, pointPixelScale: CGFloat) throws {
        let values = [selection.origin.x, selection.origin.y, selection.width, selection.height,
                      viewSize.width, viewSize.height, contentSize.width, contentSize.height,
                      pointPixelScale]
        guard values.allSatisfy({ $0.isFinite }), !selection.isNull, !selection.isInfinite,
              viewSize.width > 0, viewSize.height > 0, pointPixelScale > 0 else {
            throw appError("The selected region has invalid dimensions. Try capturing again.")
        }
        // Both sizes are logical points. Do not guess a transform across a display
        // reconfiguration, even if its notification has not reached the main loop.
        guard contentSize == viewSize else {
            throw appError("The selected display changed size. Try capturing again.")
        }
        let fullWidth = (contentSize.width * pointPixelScale).rounded()
        let fullHeight = (contentSize.height * pointPixelScale).rounded()
        guard fullWidth.isFinite, fullHeight.isFinite, fullWidth >= 1, fullHeight >= 1,
              fullWidth < CGFloat(Int.max), fullHeight < CGFloat(Int.max) else {
            throw appError("The selected display has invalid dimensions. Try capturing again.")
        }
        let standardized = selection.standardized
        guard [standardized.minX, standardized.maxX, standardized.minY, standardized.maxY]
            .allSatisfy({ $0.isFinite }) else {
            throw appError("The selected region has invalid dimensions. Try capturing again.")
        }
        let pixels = pixelCrop(selection: selection, viewSize: viewSize,
                               imageSize: CGSize(width: fullWidth, height: fullHeight))
        guard !pixels.isEmpty, !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
              pixels.width < CGFloat(Int.max), pixels.height < CGFloat(Int.max) else {
            throw appError("The selected region is outside the display. Try capturing again.")
        }
        // First retain the original, exact backing-pixel selection envelope.
        let sx = fullWidth / contentSize.width, sy = fullHeight / contentSize.height
        let region = CGRect(x: pixels.minX / sx, y: pixels.minY / sy,
                            width: pixels.width / sx, height: pixels.height / sy)
        guard [region.minX, region.minY, region.maxX, region.maxY, region.width, region.height]
            .allSatisfy({ $0.isFinite }), region.width > 0, region.height > 0 else {
            throw appError("The selected region has invalid dimensions. Try capturing again.")
        }
        selectionSourceRect = region
        // Fractional source points plus forced odd output dimensions can produce
        // scaling and transparent strips in ScreenCaptureKit (live-probe regression).
        // Rounding ONLY the output dimensions also shifts the selected pixels.
        let aligned = region.integral.intersection(CGRect(origin: .zero, size: contentSize))
        let left = (aligned.minX * sx).rounded(), top = (aligned.minY * sy).rounded()
        let right = (aligned.maxX * sx).rounded(), bottom = (aligned.maxY * sy).rounded()
        let width = right - left, height = bottom - top
        let trim = pixels.offsetBy(dx: -left, dy: -top)
        guard width >= 1, height >= 1, width < CGFloat(Int.max), height < CGFloat(Int.max),
              CGRect(x: 0, y: 0, width: width, height: height).contains(trim) else {
            throw appError("The selected region could not be aligned. Try capturing again.")
        }
        sourceRect = aligned
        cropRect = trim
        captureWidth = Int(width)
        captureHeight = Int(height)
        pixelWidth = Int(pixels.width)
        pixelHeight = Int(pixels.height)
    }

    func configuration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = captureWidth
        config.height = captureHeight
        config.showsCursor = false
        config.capturesAudio = false
        if #available(macOS 15.0, *) { config.captureMicrophone = false }
        config.captureResolution = .best
        return config
    }

    /// Injecting just the image provider lets tests inspect the exact production
    /// request without taking screenshots, prompting for access or using clipboard.
    /// No retry, full-display fallback, alpha flattening or resampling. The only
    /// trim removes the tiny logical-point alignment border, not a screen image.
    func capture(using acquire: (SCStreamConfiguration) async throws -> CGImage) async throws -> CGImage {
        try Task.checkCancellation()
        let image = try await acquire(configuration())
        try Task.checkCancellation()
        guard image.width == captureWidth, image.height == captureHeight else {
            throw appError("Region dimensions mismatch: requested \(captureWidth)x\(captureHeight), received \(image.width)x\(image.height). Try capturing again.")
        }
        if cropRect == CGRect(x: 0, y: 0, width: captureWidth, height: captureHeight) { return image }
        guard let selected = image.cropping(to: cropRect), selected.width == pixelWidth, selected.height == pixelHeight else {
            throw appError("The selected region could not be trimmed. Try capturing again.")
        }
        return selected
    }
}
