// Renders Resources/AppIcon.icns: swift scripts/make-icon.swift (run from the repo root).
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt rounded square centred in 1024.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.13, green: 0.20, blue: 0.33, alpha: 1).cgColor,
    NSColor(red: 0.20, green: 0.42, blue: 0.47, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

// Three fanned photo cards; back ones faded, front one crisp.
func card(angle: CGFloat, alpha: CGFloat, front: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 470)
    ctx.rotate(by: angle * .pi / 180)
    let r = CGRect(x: -230, y: -175, width: 460, height: 350)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.35 * alpha).cgColor)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(NSColor(white: 0.97, alpha: alpha).cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)
    // "Photo": sky + hill inside a margin.
    let inner = r.insetBy(dx: 24, dy: 24)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.clip()
    ctx.setFillColor(NSColor(red: 0.62, green: 0.78, blue: 0.86, alpha: alpha).cgColor)
    ctx.fill(inner)
    ctx.setFillColor(NSColor(red: 0.30, green: 0.52, blue: 0.45, alpha: alpha).cgColor)
    ctx.move(to: CGPoint(x: inner.minX, y: inner.minY))
    ctx.addLine(to: CGPoint(x: inner.minX, y: inner.minY + 110))
    ctx.addQuadCurve(to: CGPoint(x: inner.maxX, y: inner.minY + 70), control: CGPoint(x: inner.midX - 40, y: inner.minY + 230))
    ctx.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
    ctx.fillPath()
    ctx.setFillColor(NSColor(red: 0.98, green: 0.86, blue: 0.55, alpha: alpha).cgColor)
    ctx.fillEllipse(in: CGRect(x: inner.maxX - 120, y: inner.maxY - 110, width: 70, height: 70))
    ctx.restoreGState()
    if front {
        let badge = CGRect(x: r.maxX - 95, y: r.maxY - 95, width: 130, height: 130)
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor(red: 0.22, green: 0.78, blue: 0.45, alpha: 1).cgColor)
        ctx.fillEllipse(in: badge)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(18)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: badge.minX + 34, y: badge.midY))
        ctx.addLine(to: CGPoint(x: badge.midX - 8, y: badge.minY + 38))
        ctx.addLine(to: CGPoint(x: badge.maxX - 30, y: badge.maxY - 36))
        ctx.strokePath()
    }
    ctx.restoreGState()
}
card(angle: 12, alpha: 0.35, front: false)
card(angle: -9, alpha: 0.6, front: false)
card(angle: 0, alpha: 1, front: true)
ctx.restoreGState()

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
let master = set.appendingPathComponent("master.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)
for px in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(px)x\(px)\(scale == 2 ? "@2x" : "").png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px * scale)", "\(px * scale)", master.path, "--out", set.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
    }
}
try! fm.removeItem(at: master)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("winnow-icon.png"))
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
