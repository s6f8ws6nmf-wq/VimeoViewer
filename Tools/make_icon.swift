// Vygeneruje 1024×1024 PNG ikonu aplikácie.  Použitie: swift make_icon.swift výstup.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Podklad v štýle Big Sur (zaoblený štvorec s okrajom)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor(red: 0.10, green: 0.62, blue: 0.86, alpha: 1).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(red: 0.16, green: 0.76, blue: 0.96, alpha: 1),
           ending: NSColor(red: 0.05, green: 0.42, blue: 0.72, alpha: 1))?.draw(in: tilePath, angle: -90)

// Tri „panely“: prepis vľavo, video v strede, komentáre vpravo
let white = NSColor.white
let panelY: CGFloat = 300, panelH: CGFloat = 420
white.withAlphaComponent(0.30).setFill()
NSBezierPath(roundedRect: NSRect(x: 180, y: panelY, width: 130, height: panelH), xRadius: 26, yRadius: 26).fill()
NSBezierPath(roundedRect: NSRect(x: 714, y: panelY, width: 130, height: panelH), xRadius: 26, yRadius: 26).fill()
white.withAlphaComponent(0.85).setFill()
for i in 0..<5 {
    let y = panelY + panelH - 70 - CGFloat(i) * 72
    NSBezierPath(roundedRect: NSRect(x: 205, y: y, width: i % 2 == 0 ? 80 : 60, height: 18), xRadius: 9, yRadius: 9).fill()
    NSBezierPath(roundedRect: NSRect(x: 739, y: y, width: i % 2 == 0 ? 60 : 80, height: 18), xRadius: 9, yRadius: 9).fill()
}
white.setFill()
let screen = NSRect(x: 340, y: panelY, width: 344, height: panelH)
NSBezierPath(roundedRect: screen, xRadius: 34, yRadius: 34).fill()

// Tlačidlo prehrávania
let play = NSBezierPath()
let cx = screen.midX + 12, cy = screen.midY
play.move(to: NSPoint(x: cx - 60, y: cy + 80))
play.line(to: NSPoint(x: cx + 80, y: cy))
play.line(to: NSPoint(x: cx - 60, y: cy - 80))
play.close()
NSColor(red: 0.07, green: 0.50, blue: 0.80, alpha: 1).setFill()
play.fill()

// Spodná lišta (zdieľanie)
white.withAlphaComponent(0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: 180, y: 200, width: 664, height: 60), xRadius: 30, yRadius: 30).fill()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
print("Ikona uložená: \(out)")
