// Places a window capture on a 2880x1800 App Store canvas with a caption.
// usage: swift scripts/compose-screenshot.swift <capture.png> <out.png> "<caption>"
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let shot = NSImage(contentsOfFile: args[1]),
      let shotRep = shot.representations.first else {
    print("usage: compose-screenshot.swift <capture.png> <out.png> \"caption\""); exit(2)
}
let W = 2880, H = 1800
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: W, height: H)

// Glacier gradient with two soft lights: the app's palette.
NSGradient(colors: [NSColor(srgbRed: 0.06, green: 0.17, blue: 0.28, alpha: 1),
                    NSColor(srgbRed: 0.03, green: 0.09, blue: 0.16, alpha: 1)])!.draw(in: canvas, angle: -90)
for (x, y, r, c) in [(0.18, 0.85, 1100.0, NSColor(srgbRed: 0.55, green: 0.95, blue: 0.90, alpha: 0.22)),
                     (0.85, 0.65, 1300.0, NSColor(srgbRed: 0.49, green: 0.83, blue: 0.99, alpha: 0.25))] {
    let center = NSPoint(x: Double(W) * x, y: Double(H) * y)
    NSGradient(colors: [c, c.withAlphaComponent(0)])!.draw(fromCenter: center, radius: 0, toCenter: center, radius: r, options: [])
}

// Caption.
let style = NSMutableParagraphStyle(); style.alignment = .center
let font = NSFont(name: "Avenir Next Bold", size: 104) ?? .boldSystemFont(ofSize: 104)
let caption = NSAttributedString(string: args[3], attributes: [
    .font: font, .foregroundColor: NSColor(srgbRed: 0.93, green: 0.97, blue: 1, alpha: 1), .paragraphStyle: style])
caption.draw(in: NSRect(x: 160, y: H - 300, width: W - 320, height: 180))

// Window, scaled to fit under the caption, with a deep shadow.
let srcW = Double(shotRep.pixelsWide), srcH = Double(shotRep.pixelsHigh)
let maxW = Double(W) - 320, maxH = Double(H) - 420
let scale = min(maxW / srcW, maxH / srcH)
let dw = srcW * scale, dh = srcH * scale
let frame = NSRect(x: (Double(W) - dw) / 2, y: 90, width: dw, height: dh)
let shadow = NSShadow(); shadow.shadowBlurRadius = 90; shadow.shadowOffset = NSSize(width: 0, height: -30)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.55); shadow.set()
shot.draw(in: frame)
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) \(W)x\(H)")
