import AppKit
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let outer = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 210, yRadius: 210)
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1).setFill(); outer.fill()
        let colors: [NSColor] = [NSColor(calibratedRed: 0.32, green: 0.48, blue: 0.60, alpha: 1), NSColor(calibratedRed: 0.73, green: 0.41, blue: 0.52, alpha: 1), NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.47, alpha: 1)]
        for (i, color) in colors.enumerated() {
            color.setFill()
            let y = CGFloat(250 + i * 165)
            NSBezierPath(roundedRect: NSRect(x: 230, y: y, width: 564, height: 120), xRadius: 60, yRadius: 60).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
