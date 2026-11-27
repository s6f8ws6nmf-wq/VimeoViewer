// Vygeneruje 1024×1024 PNG ikonu aplikácie: elegantné Vimeo „v“ a nápis NUNEZ NFE (tyrkysová + biela).
// Použitie: swift make_icon.swift výstup.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Podklad v štýle Big Sur – jemný tyrkysový prechod
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 22
shadow.set()
rgb(72, 188, 206).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: rgb(84, 203, 220), ending: rgb(60, 172, 194))?.draw(in: tilePath, angle: -45)

// Jemné svetlo v hornej časti
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.10))?
    .draw(in: tile, angle: 90)
NSGraphicsContext.restoreGraphicsState()

// Vimeo „v“ – tenká biela línia so zaoblenými koncami, vycentrovaná, s decentným glitch efektom
let s: CGFloat = 0.78
let vBottom: CGFloat = 417
func P(_ px: CGFloat, _ py: CGFloat) -> NSPoint {
    NSPoint(x: 512 + (px - 506) * s, y: vBottom + (py - 30) * s)
}
func vPath(dx: CGFloat) -> NSBezierPath {
    let v = NSBezierPath()
    v.move(to: P(300, 360))
    v.curve(to: P(352, 392), controlPoint1: P(318, 380), controlPoint2: P(334, 392))
    v.curve(to: P(402, 340), controlPoint1: P(380, 392), controlPoint2: P(394, 372))
    v.curve(to: P(470, 60), controlPoint1: P(420, 250), controlPoint2: P(440, 110))
    v.curve(to: P(520, 40), controlPoint1: P(482, 38), controlPoint2: P(504, 30))
    v.curve(to: P(705, 330), controlPoint1: P(600, 110), controlPoint2: P(700, 230))
    v.curve(to: P(640, 440), controlPoint1: P(712, 410), controlPoint2: P(680, 452))
    v.curve(to: P(578, 330), controlPoint1: P(600, 428), controlPoint2: P(570, 380))
    v.curve(to: P(606, 268), controlPoint1: P(584, 300), controlPoint2: P(596, 282))
    let t = AffineTransform(translationByX: dx, byY: 0)
    v.transform(using: t)
    v.lineWidth = 34
    v.lineCapStyle = .round
    v.lineJoinStyle = .round
    return v
}

// „v“ sa nakreslí do samostatnej vrstvy (farebné posunuté kópie + biela línia)…
guard let layerRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layerRep)
rgb(28, 110, 140, 0.9).setStroke()
vPath(dx: -12).stroke()
rgb(175, 242, 255, 0.92).setStroke()
vPath(dx: 12).stroke()
NSColor.white.setStroke()
vPath(dx: 0).stroke()
NSGraphicsContext.restoreGraphicsState()

// …a potom sa vloží s niekoľkými vodorovne posunutými pásmi (glitch).
if let vImage = layerRep.cgImage {
    let ctx = NSGraphicsContext.current!.cgContext
    let full = CGRect(x: 0, y: 0, width: size, height: size)
    let bands: [(CGFloat, CGFloat, CGFloat)] = [(520, 532, -14), (600, 618, 18), (690, 698, 10)]
    var calm: [CGRect] = []
    var y0: CGFloat = 0
    for (b0, b1, _) in bands {
        calm.append(CGRect(x: 0, y: y0, width: CGFloat(size), height: b0 - y0))
        y0 = b1
    }
    calm.append(CGRect(x: 0, y: y0, width: CGFloat(size), height: CGFloat(size) - y0))
    ctx.saveGState()
    ctx.clip(to: calm)
    ctx.draw(vImage, in: full)
    ctx.restoreGState()
    for (b0, b1, shift) in bands {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: b0, width: CGFloat(size), height: b1 - b0))
        ctx.draw(vImage, in: full.offsetBy(dx: shift, dy: 0))
        ctx.restoreGState()
    }
}

// Nápis NUNEZ NFE – malý, s riedkym rozostupom (prvé N zrkadlovo ako v logu)
let white = NSColor.white.withAlphaComponent(0.95)
let kern: CGFloat = 10
let bold = NSFont.systemFont(ofSize: 64, weight: .semibold)
let light = NSFont.systemFont(ofSize: 64, weight: .light)
let firstN = NSAttributedString(string: "N", attributes: [.font: bold, .foregroundColor: white])
let unez = NSAttributedString(string: "UNEZ", attributes: [.font: bold, .foregroundColor: white, .kern: kern])
let nfe = NSAttributedString(string: "NFE", attributes: [.font: light, .foregroundColor: white, .kern: kern])
let wN = firstN.size().width
let wU = unez.size().width - kern
let wF = nfe.size().width - kern
let gap: CGFloat = 26
let total = wN + kern + wU + gap + wF
let textH = unez.size().height
let textY: CGFloat = 300 - textH / 2
var x = 512 - total / 2

NSGraphicsContext.saveGraphicsState()
let flip = NSAffineTransform()
flip.translateX(by: x + wN, yBy: 0)
flip.scaleX(by: -1, yBy: 1)
flip.concat()
firstN.draw(at: NSPoint(x: 0, y: textY))
NSGraphicsContext.restoreGraphicsState()
x += wN + kern
unez.draw(at: NSPoint(x: x, y: textY))
x += wU + gap
nfe.draw(at: NSPoint(x: x, y: textY))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
print("Ikona uložená: \(out)")
