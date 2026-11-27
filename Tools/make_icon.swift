// Vygeneruje 1024×1024 PNG ikonu aplikácie.  Použitie: swift make_icon.swift výstup.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Podklad v štýle Big Sur – tmavá nočná modrá
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor(red: 0.05, green: 0.12, blue: 0.22, alpha: 1).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(red: 0.10, green: 0.22, blue: 0.36, alpha: 1),
           ending: NSColor(red: 0.03, green: 0.08, blue: 0.16, alpha: 1))?.draw(in: tilePath, angle: -90)

// Výrazné kurzívne „v“ s farebným prechodom (tyrkysová Vimeo → svetlá azúrová)
var font = NSFont.systemFont(ofSize: 760, weight: .heavy)
let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
if italic.fontDescriptor.symbolicTraits.contains(.italic) {
    font = italic
} else {
    for name in ["AvenirNext-HeavyItalic", "Futura-CondensedExtraBold", "HelveticaNeue-CondensedBlack"] {
        if let f = NSFont(name: name, size: 760) { font = f; break }
    }
}
let ctFont = font as CTFont
var ch: [UniChar] = Array("v".utf16)
var glyphs = [CGGlyph](repeating: 0, count: ch.count)
CTFontGetGlyphsForCharacters(ctFont, &ch, &glyphs, ch.count)
// Kurzívu doplníme skosením, ak ju písmo samo nemá.
var transform = font.fontDescriptor.symbolicTraits.contains(.italic) ? CGAffineTransform.identity : CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
guard let glyphPath = CTFontCreatePathForGlyph(ctFont, glyphs[0], &transform) else { exit(1) }
let gb = glyphPath.boundingBoxOfPath
var move = CGAffineTransform(translationX: tile.midX - gb.midX, y: tile.midY - gb.midY + 10)
guard let vPath = glyphPath.copy(using: &move) else { exit(1) }

let ctx = NSGraphicsContext.current!.cgContext
// jemná žiara
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: NSColor(red: 0.10, green: 0.72, blue: 0.92, alpha: 0.55).cgColor)
ctx.addPath(vPath)
ctx.setFillColor(NSColor(red: 0.10, green: 0.72, blue: 0.92, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()
// prechod
ctx.saveGState()
ctx.addPath(vPath)
ctx.clip()
let colors = [NSColor(red: 0.55, green: 0.93, blue: 1.00, alpha: 1).cgColor,
              NSColor(red: 0.10, green: 0.72, blue: 0.92, alpha: 1).cgColor,
              NSColor(red: 0.00, green: 0.50, blue: 0.86, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
let r = vPath.boundingBoxOfPath
ctx.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
print("Ikona uložená: \(out)")
