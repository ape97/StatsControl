// Generates the app icon (1024 px) in the style of the macOS 26 icons:
// squircle with a deep gradient, soft highlight and shadow; in front a white activity curve with area fill and end point.
// Usage: swift scripts/icon.swift <output.png>
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// Superellipse like the Apple icon shape (continuous corners).
func squircle(_ rect: CGRect, n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func linear(_ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, locations: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)

// Shadow below the shape
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0, 0, 0, 0.35))
cg.addPath(shape)
cg.setFillColor(color(0.0, 0.25, 0.28))
cg.fillPath()
cg.restoreGState()

// Base gradient: fresh green at the top, turquoise in the middle, deep teal at the bottom
cg.saveGState()
cg.addPath(shape)
cg.clip()
linear([color(0.36, 0.86, 0.52), color(0.10, 0.68, 0.70), color(0.03, 0.27, 0.35)],
       CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100), locations: [0, 0.5, 1])
// Soft highlight at the top left
let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.32), color(1, 1, 1, 0)] as CFArray, locations: nil)!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 860), startRadius: 0, endCenter: CGPoint(x: 330, y: 860), endRadius: 560, options: [])
// Subtle depth at the bottom right
let shade = CGGradient(colorsSpace: space, colors: [color(0.0, 0.1, 0.18, 0.35), color(0.0, 0.1, 0.18, 0)] as CFArray, locations: nil)!
cg.drawRadialGradient(shade, startCenter: CGPoint(x: 820, y: 140), startRadius: 0, endCenter: CGPoint(x: 820, y: 140), endRadius: 520, options: [])

// Grid: three fine horizontal lines
let left: CGFloat = 232, right: CGFloat = 792
cg.setStrokeColor(color(1, 1, 1, 0.10))
cg.setLineWidth(4)
cg.setLineCap(.round)
for y in [400.0, 512.0, 624.0] as [CGFloat] {
    cg.move(to: CGPoint(x: left, y: y)); cg.addLine(to: CGPoint(x: right, y: y)); cg.strokePath()
}

// Activity curve: control points, Catmull-Rom smoothing as Bézier
let pts: [CGPoint] = [CGPoint(x: 232, y: 420), CGPoint(x: 316, y: 470), CGPoint(x: 396, y: 410),
                      CGPoint(x: 476, y: 590), CGPoint(x: 556, y: 490), CGPoint(x: 636, y: 550),
                      CGPoint(x: 712, y: 490), CGPoint(x: 792, y: 650)]
func curve(_ p: [CGPoint]) -> CGMutablePath {
    let path = CGMutablePath()
    path.move(to: p[0])
    for i in 0..<(p.count - 1) {
        let p0 = i > 0 ? p[i - 1] : p[i], p1 = p[i], p2 = p[i + 1], p3 = i + 2 < p.count ? p[i + 2] : p[i + 1]
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    return path
}
let line = curve(pts)

// Area fill below the curve: 35 % → 0 % white
let area = CGMutablePath()
area.addPath(line)
area.addLine(to: CGPoint(x: right, y: 340))
area.addLine(to: CGPoint(x: left, y: 340))
area.closeSubpath()
// faded out at the sides to avoid hard edges
cg.saveGState()
cg.addPath(area)
cg.clip()
cg.beginTransparencyLayer(auxiliaryInfo: nil)
linear([color(1, 1, 1, 0.35), color(1, 1, 1, 0)], CGPoint(x: 512, y: 660), CGPoint(x: 512, y: 360))
cg.setBlendMode(.destinationIn)
linear([color(1, 1, 1, 0), color(1, 1, 1, 1), color(1, 1, 1, 1), color(1, 1, 1, 0)],
       CGPoint(x: left, y: 0), CGPoint(x: right, y: 0), locations: [0, 0.2, 0.8, 1])
cg.endTransparencyLayer()
cg.restoreGState()

// Line with soft shadow
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0, 0.12, 0.2, 0.35))
cg.addPath(line)
cg.setStrokeColor(color(1, 1, 1))
cg.setLineWidth(34)
cg.setLineCap(.round)
cg.setLineJoin(.round)
cg.strokePath()
cg.restoreGState()

// End point with a slight glow
let end = pts[pts.count - 1]
let halo = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.55), color(1, 1, 1, 0)] as CFArray, locations: nil)!
cg.drawRadialGradient(halo, startCenter: end, startRadius: 0, endCenter: end, endRadius: 70, options: [])
cg.setFillColor(color(1, 1, 1))
cg.fillEllipse(in: CGRect(x: end.x - 30, y: end.y - 30, width: 60, height: 60))

// Glass edge: light border at the top, dark at the bottom
cg.restoreGState()
cg.saveGState()
cg.addPath(shape)
cg.setLineWidth(6)
cg.replacePathWithStrokedPath()
cg.clip()
linear([color(1, 1, 1, 0.55), color(1, 1, 1, 0.08), color(0, 0, 0, 0.15)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100),
       locations: [0, 0.5, 1])
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
