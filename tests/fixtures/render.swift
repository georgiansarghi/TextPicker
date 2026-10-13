import Foundation
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Native CoreText shaping (including RTL and Indic scripts), no screen capture.
func color(_ hex: String) -> CGColor {
    let n = UInt32(hex.dropFirst(), radix: 16)!
    return CGColor(red: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8) & 255)/255, blue: CGFloat(n & 255)/255, alpha: 1)
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
var cases = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [[String: Any]]
for i in cases.indices {
    let item = cases[i]
    let size = item["size"] as! Double
    let fontURL = URL(fileURLWithPath: item["font"] as! String)
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as! [CTFontDescriptor]
    let font = CTFontCreateWithFontDescriptor(descriptors[0], size, nil)
    let dark = item["dark"] as? Bool ?? false
    let fg = color(item["fg"] as? String ?? (dark ? "#e8eaed" : "#171717"))
    let bg = color(item["bg"] as? String ?? (dark ? "#202124" : "#ffffff"))
    let text = item["text"] as! String
    let lines = text.components(separatedBy: "\n").map { line in
        CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg]))
    }
    let pad = 24.0
    let lineHeight = ceil(size * 1.75)
    let width = Int(ceil(lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max()! + pad*2))
    let height = Int(pad*2 + lineHeight*Double(lines.count))
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(bg)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setShouldAntialias(true)
    for (index, line) in lines.enumerated() {
        ctx.textPosition = CGPoint(x: pad, y: Double(height)-pad-size-Double(index)*lineHeight)
        CTLineDraw(line, ctx)
    }
    let url = URL(fileURLWithPath: item["path"] as! String)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }
    cases[i]["width"] = width
    cases[i]["height"] = height
    cases[i]["rendered_font"] = CTFontCopyPostScriptName(font) as String
}
try JSONSerialization.data(withJSONObject: cases, options: [.prettyPrinted, .sortedKeys]).write(to: input)
