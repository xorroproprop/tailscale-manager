// Draws AppIcon.icns: a hard black slab with an offset amber shadow, and four square nodes wired in a ring —
// one lit amber (this Mac). Run: swift make-icon.swift   (build.sh runs it when AppIcon.icns is missing)
import AppKit

func png(_ size: Int, _ path: String) {
    let s = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: s, y: s)
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32) {
        cg.setFillColor(CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                                blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
        cg.fill(CGRect(x: x, y: y, width: w, height: h))
    }
    let amber: UInt32 = 0xFF9F0A, paper: UInt32 = 0xF2F1ED, ink: UInt32 = 0x0B0C0E
    rect(156, 100, 768, 768, amber)              // hard offset shadow
    rect(100, 156, 768, 768, ink)                // slab
    let a: CGFloat = 282, b: CGFloat = 686, n: CGFloat = 132, w: CGFloat = 36   // node centers, node size, wire
    rect(a, a + 56 - w / 2, b - a, w, paper); rect(a, b + 56 - w / 2, b - a, w, paper)   // wires: bottom, top
    rect(a - w / 2, a + 56, w, b - a, paper); rect(b - w / 2, a + 56, w, b - a, paper)   // left, right
    for (x, y, c) in [(a, b, paper), (b, b, paper), (a, a, paper), (b, a, amber)] {
        rect(x - n / 2, y + 56 - n / 2, n, n, c)
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let set = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for p in [16, 32, 128, 256, 512] {
    png(p, "\(set)/icon_\(p)x\(p).png")
    png(p * 2, "\(set)/icon_\(p)x\(p)@2x.png")
}
let t = Process()
t.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
t.arguments = ["-c", "icns", set, "-o", "AppIcon.icns"]
try! t.run(); t.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
print("✅ AppIcon.icns")
