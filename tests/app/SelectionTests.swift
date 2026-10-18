import AppKit

@main
struct SelectionTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 400, height: 240)
        let panel = SelectionPanel(frame: frame)
        precondition(panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeMain && !panel.canBecomeKey)
        precondition(!panel.hidesOnDeactivate && !panel.isOpaque && panel.ignoresMouseEvents)
        precondition(panel.animationBehavior == .none && panel.backgroundColor.alphaComponent == 0)
        panel.close()
        let view = SelectionView(frame: frame)
        func render() -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 240,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 1600, bitsPerPixel: 32)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            view.draw(frame)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        let empty = render()
        precondition((empty.colorAt(x: 10, y: 10)?.alphaComponent ?? 1) == 0)
        view.selection = CGRect(x: 50, y: 40, width: 140, height: 120)
        view.pointer = CGPoint(x: 250, y: 100)
        let drawn = render()
        precondition(Data(bytes: empty.bitmapData!, count: 1600 * 240) != Data(bytes: drawn.bitmapData!, count: 1600 * 240))
        for point in [(5, 5), (395, 235), (100, 120)] {
            precondition((drawn.colorAt(x: point.0, y: point.1)?.alphaComponent ?? 1) == 0)
        }
        precondition(selectionRect(from: CGPoint(x: 190, y: 160), to: CGPoint(x: 50, y: 40), bounds: frame) == view.selection)
        precondition(selectionRect(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 500, y: 500), bounds: frame) == CGRect(x: 50, y: 40, width: 350, height: 200))
        precondition(appKitPoint(CGPoint(x: -100, y: 50), mainDisplayHeight: 900) == CGPoint(x: -100, y: 850))
        precondition(appKitPoint(CGPoint(x: 200, y: -100), mainDisplayHeight: 900) == CGPoint(x: 200, y: 1000))
        // Quartz y=0 (top row of the main display) must hit the main screen, not
        // fall outside it or onto a display stacked above it.
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900), above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        let top = screenHitPoint(appKitPoint(CGPoint(x: 10, y: 0), mainDisplayHeight: 900))
        precondition(main.contains(top) && !above.contains(top))
        let bottom = screenHitPoint(appKitPoint(CGPoint(x: 10, y: 899), mainDisplayHeight: 900))
        precondition(main.contains(bottom))
        precondition(above.contains(screenHitPoint(appKitPoint(CGPoint(x: 10, y: -1), mainDisplayHeight: 900))))
        let layout = DisplayLayoutEntry(id: 1, frame: frame, scale: 2)
        precondition(layout == DisplayLayoutEntry(id: 1, frame: frame, scale: 2))
        precondition(layout != DisplayLayoutEntry(id: 1, frame: frame, scale: 1))
        print("PASS: non-key click-through panel, transparent drawing, outline/crosshair, clipping, display coordinates")
    }
}
