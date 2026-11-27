// Vygeneruje 1024×1024 PNG ikonu aplikácie.  Použitie: swift make_icon.swift výstup.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Podklad v štýle Big Sur – modrá farba Vimea
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor(red: 0.10, green: 0.72, blue: 0.92, alpha: 1).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(red: 0.20, green: 0.80, blue: 0.98, alpha: 1),
           ending: NSColor(red: 0.06, green: 0.60, blue: 0.85, alpha: 1))?.draw(in: tilePath, angle: -90)

// Výrazné biele kurzívne „v“
var font = NSFont.systemFont(ofSize: 760, weight: .heavy)
let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
if italic.fontDescriptor.symbolicTraits.contains(.italic) {
    font = italic
} else {
    for name in ["AvenirNext-HeavyItalic", "Futura-CondensedExtraBold", "HelveticaNeue-CondensedBlack"] {
        if let f = NSFont(name: name, size: 760) { font = f; break }
    }
}
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
let v = NSAttributedString(string: "v", attributes: attrs)
let line = CTLineCreateWithAttributedString(v)
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor.black.withAlphaComponent(0.18).cgColor)
ctx.textPosition = CGPoint(x: tile.midX - bounds.midX, y: tile.midY - bounds.midY)
CTLineDraw(line, ctx)

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
print("Ikona uložená: \(out)")
