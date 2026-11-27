// Vygeneruje 1024×1024 PNG ikonu aplikácie: Vimeo „v“ + logo NUNEZ NFE.  Použitie: swift make_icon.swift výstup.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Podklad v štýle Big Sur – prechod tyrkysová → zelená (ako Vimeo)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor(red: 0.30, green: 0.75, blue: 0.80, alpha: 1).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(red: 0.33, green: 0.71, blue: 0.86, alpha: 1),
           ending: NSColor(red: 0.30, green: 0.80, blue: 0.68, alpha: 1))?.draw(in: tilePath, angle: -45)

// Text NUNEZ NFE – biely, priamo na tyrkysovom podklade
let band = NSRect(x: tile.minX, y: tile.minY + 40, width: tile.width, height: 190)

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    return NSFont.systemFont(ofSize: size, weight: weight)
}
let orange = NSColor.white
// „NUNEZ“ so zrkadlovo otočeným prvým N, „NFE“ tenším písmom
let firstN = NSAttributedString(string: "N", attributes: [.font: font(118, .heavy), .foregroundColor: orange])
let unez = NSAttributedString(string: "UNEZ", attributes: [.font: font(118, .heavy), .foregroundColor: orange, .kern: 2])
let nfe = NSAttributedString(string: "NFE", attributes: [.font: font(118, .light), .foregroundColor: NSColor.white, .kern: 4])
let wN = firstN.size().width, wU = unez.size().width, wF = nfe.size().width
let gap: CGFloat = 14
let total = wN + 2 + wU + gap + wF
let textH = unez.size().height
var x = tile.midX - total / 2
let y = band.midY - textH / 2 + 4
// zrkadlové N
NSGraphicsContext.saveGraphicsState()
let flip = NSAffineTransform()
flip.translateX(by: x + wN, yBy: 0)
flip.scaleX(by: -1, yBy: 1)
flip.concat()
firstN.draw(at: NSPoint(x: 0, y: y))
NSGraphicsContext.restoreGraphicsState()
x += wN + 2
unez.draw(at: NSPoint(x: x, y: y))
x += wU + gap
nfe.draw(at: NSPoint(x: x, y: y))

// Vimeo „v“ – biela obrysová čiara so zaoblenými koncami
let v = NSBezierPath()
let s: CGFloat = 1.1
func P(_ px: CGFloat, _ py: CGFloat) -> NSPoint { NSPoint(x: 512 + (px - 512) * s, y: 380 + py * s) }
// ľavá vlajočka a ľavé rameno
v.move(to: P(300, 360))
v.curve(to: P(352, 392), controlPoint1: P(318, 380), controlPoint2: P(334, 392))
v.curve(to: P(402, 340), controlPoint1: P(380, 392), controlPoint2: P(394, 372))
v.curve(to: P(470, 60), controlPoint1: P(420, 250), controlPoint2: P(440, 110))
v.curve(to: P(520, 40), controlPoint1: P(482, 38), controlPoint2: P(504, 30))
// pravé rameno so zatočením nahor
v.curve(to: P(705, 330), controlPoint1: P(600, 110), controlPoint2: P(700, 230))
v.curve(to: P(640, 440), controlPoint1: P(712, 410), controlPoint2: P(680, 452))
v.curve(to: P(578, 330), controlPoint1: P(600, 428), controlPoint2: P(570, 380))
v.curve(to: P(606, 268), controlPoint1: P(584, 300), controlPoint2: P(596, 282))
v.lineWidth = 44
v.lineCapStyle = .round
v.lineJoinStyle = .round
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlphaComponent(0.15).cgColor)
NSColor.white.setStroke()
v.stroke()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
print("Ikona uložená: \(out)")
