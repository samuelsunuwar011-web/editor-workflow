// Draws Resources/AppIcon.icns: the menu bar mark (film frame + play) in tally amber on a dark tile.
import AppKit
let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1), ending: NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1))!.draw(in: tile, angle: -90)
    let amber = NSColor(red: 0.91, green: 0.64, blue: 0.23, alpha: 1)
    amber.set()
    let fw = s * 0.52, fh = s * 0.40
    let frame = NSBezierPath(roundedRect: NSRect(x: (s - fw) / 2, y: (s - fh) / 2, width: fw, height: fh), xRadius: s * 0.07, yRadius: s * 0.07)
    frame.lineWidth = s * 0.045; frame.stroke()
    let p = NSBezierPath(); let cx = s / 2, cy = s / 2, t = s * 0.1
    p.move(to: NSPoint(x: cx - t * 0.7, y: cy - t)); p.line(to: NSPoint(x: cx - t * 0.7, y: cy + t)); p.line(to: NSPoint(x: cx + t * 1.0, y: cy)); p.close(); p.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
