import AppKit
let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
let bg = CGGradient(colorsSpace: cs, colors: [c(0.20, 0.17, 0.55), c(0.42, 0.36, 0.95), c(0.66, 0.38, 0.92)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.28), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 760), startRadius: 0, endCenter: CGPoint(x: 512, y: 760), endRadius: 520, options: [])
let top = CGPoint(x: 512, y: 850)
let veil = CGMutablePath()
veil.move(to: top)
veil.addCurve(to: CGPoint(x: 205, y: 215), control1: CGPoint(x: 400, y: 840), control2: CGPoint(x: 300, y: 500))
let hemY: CGFloat = 215
let xs: [CGFloat] = [205, 328, 451, 574, 697, 819]
for i in 0..<(xs.count - 1) {
    let mid = (xs[i] + xs[i + 1]) / 2
    veil.addQuadCurve(to: CGPoint(x: xs[i + 1], y: hemY), control: CGPoint(x: mid, y: hemY + (i % 2 == 0 ? -46 : 46)))
}
veil.addCurve(to: top, control1: CGPoint(x: 724, y: 500), control2: CGPoint(x: 624, y: 840))
veil.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: c(0.1, 0.05, 0.3, 0.45))
ctx.addPath(veil); ctx.setFillColor(c(1, 1, 1, 0.9)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(veil); ctx.clip()
let shade = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0), c(0.55, 0.45, 0.95, 0.35)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: 850), end: CGPoint(x: 0, y: 200), options: [])
ctx.setLineCap(.round)
for (dx, w, a) in [(-200.0, 22.0, 0.22), (-80.0, 18.0, 0.18), (60.0, 18.0, 0.18), (190.0, 22.0, 0.22)] as [(CGFloat, CGFloat, CGFloat)] {
    let f = CGMutablePath()
    f.move(to: CGPoint(x: 512 + dx * 0.08, y: 800))
    f.addCurve(to: CGPoint(x: 512 + dx * 1.35, y: 200), control1: CGPoint(x: 512 + dx * 0.3, y: 620), control2: CGPoint(x: 512 + dx * 1.2, y: 420))
    ctx.addPath(f); ctx.setStrokeColor(c(0.35, 0.25, 0.85, a)); ctx.setLineWidth(w); ctx.strokePath()
}
ctx.restoreGState()
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
