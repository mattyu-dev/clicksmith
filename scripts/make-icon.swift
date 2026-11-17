// Regenerate: swiftc -O scripts/make-icon.swift -o /tmp/mkicon && /tmp/mkicon /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o Support/AppIcon.icns
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSShadow().then { $0.shadowBlurRadius = s*0.02; $0.shadowOffset = NSSize(width: 0, height: -s*0.01); $0.shadowColor = .black.withAlphaComponent(0.35); $0.set() }
    NSGradient(colors: [NSColor(red: 0.42, green: 0.25, blue: 0.98, alpha: 1), NSColor(red: 0.98, green: 0.36, blue: 0.55, alpha: 1)])!.draw(in: path, angle: -60)
    NSShadow().set()
    // cursor-ish click ring
    let ring = NSBezierPath(ovalIn: NSRect(x: s*0.28, y: s*0.28, width: s*0.44, height: s*0.44)); ring.lineWidth = s*0.018
    NSColor.white.withAlphaComponent(0.25).setStroke(); ring.stroke()
    let cfg = NSImage.SymbolConfiguration(pointSize: s*0.42, weight: .bold).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size; sym.draw(in: NSRect(x: (s - sz.width)/2, y: (s - sz.height)/2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
extension NSObject { @discardableResult func then(_ f: (Self) -> Void) -> Self { f(self); return self } }
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
