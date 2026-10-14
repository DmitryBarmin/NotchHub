import AppKit
let dir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let rect = NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88)
        let shape = NSBezierPath(roundedRect: rect, xRadius: p * 0.2, yRadius: p * 0.2)
        NSGradient(starting: NSColor(red: 0.14, green: 0.17, blue: 0.23, alpha: 1), ending: NSColor(red: 0.03, green: 0.035, blue: 0.05, alpha: 1))!.draw(in: shape, angle: -90)
        let pill = NSBezierPath(roundedRect: NSRect(x: p * 0.2, y: p * 0.34, width: p * 0.6, height: p * 0.32), xRadius: p * 0.16, yRadius: p * 0.16)
        NSColor.black.setFill(); pill.fill()
        NSColor(red: 0.64, green: 0.78, blue: 1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: p * 0.27, y: p * 0.435, width: p * 0.13, height: p * 0.13)).fill()
        let line = NSBezierPath(roundedRect: NSRect(x: p * 0.47, y: p * 0.475, width: p * 0.23, height: p * 0.045), xRadius: p * 0.02, yRadius: p * 0.02)
        NSColor.white.withAlphaComponent(0.85).setFill(); line.fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
