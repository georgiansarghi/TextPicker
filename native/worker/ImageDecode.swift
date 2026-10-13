import Darwin
import Foundation
import ImageIO
import CoreGraphics

struct CapturePixels {
    let width: Int
    let height: Int
    let bgra: [UInt8]
}

func nativeError(_ message: String) -> NSError {
    NSError(domain: "TextPickerNative", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Open once, reject special files/symlinks, and copy a bounded stable input.
/// Metadata and decoding must refer to the same bytes, not two URL lookups.
private func captureData(_ path: String) throws -> Data {
    guard !path.utf8.contains(0) else { throw nativeError("Invalid capture path") }
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
    guard fd >= 0 else { throw nativeError("Cannot read capture image") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size > 0, info.st_size <= TEXTPICKER_MAX_FILE_BYTES else {
        throw nativeError("Capture must be a regular image file within the size limit")
    }
    var data = Data(count: Int(info.st_size))
    try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw nativeError("Cannot read complete capture image") }
            offset += count
        }
    }
    return data
}

/// Screenshot contract: opaque 8-bit RGB or grayscale. Read original samples;
/// drawing into another color space would change the validated normalization.
func decodeCapture(_ path: String) throws -> CapturePixels {
    let encoded = try captureData(path)
    guard let source = CGImageSourceCreateWithData(encoded as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
        throw nativeError("Cannot read capture image metadata")
    }
    guard width > 0, height > 0, width <= TEXTPICKER_MAX_IMAGE_SIDE, height <= TEXTPICKER_MAX_IMAGE_SIDE,
          width * height <= TEXTPICKER_MAX_IMAGE_PIXELS else {
        throw nativeError("Selection is too large; capture a smaller region")
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: false] as CFDictionary),
          image.width == width, image.height == height, image.bitsPerComponent == 8,
          image.bitsPerPixel % 8 == 0, let data = image.dataProvider?.data,
          let pixels = CFDataGetBytePtr(data) else {
        throw nativeError("Cannot decode an 8-bit capture image")
    }
    let channels = image.bitsPerPixel / 8
    let gray = image.colorSpace?.model == .monochrome
    guard (gray && (channels == 1 || channels == 2)) ||
            (image.colorSpace?.model == .rgb && (channels == 3 || channels == 4)),
          image.bytesPerRow >= width * channels,
          image.bytesPerRow <= CFDataGetLength(data) / height else {
        throw nativeError("Unsupported capture pixel format")
    }
    let alpha = image.alphaInfo
    let alphaFirst = alpha == .first || alpha == .premultipliedFirst
    let alphaLast = alpha == .last || alpha == .premultipliedLast
    let first = alphaFirst || alpha == .noneSkipFirst
    let order = image.bitmapInfo.intersection(.byteOrderMask)
    let little = (channels == 4 && order == .byteOrder32Little) ||
        (channels == 2 && order == .byteOrder16Little)
    return try withExtendedLifetime((data, image, encoded)) {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sourcePixel = pixels.advanced(by: y * image.bytesPerRow + x * channels)
                func component(_ logical: Int) -> UInt8 {
                    sourcePixel[little ? channels - 1 - logical : logical]
                }
                // Premultiplied samples cannot in general recover the exact
                // original RGB. Fail explicitly instead of silently changing OCR.
                if alphaFirst || alphaLast {
                    guard component(alphaFirst ? 0 : channels - 1) == 255 else {
                        throw nativeError("Capture image must be opaque; use a normal screenshot")
                    }
                }
                let start = first ? 1 : 0
                let dst = (y * width + x) * 4
                out[dst] = component(gray ? start : start + 2)
                out[dst + 1] = component(gray ? start : start + 1)
                out[dst + 2] = component(start)
            }
        }
        return CapturePixels(width: width, height: height, bgra: out)
    }
}
