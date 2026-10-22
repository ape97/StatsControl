// Composes README images: the raw menu snapshot under a clean menu bar on a soft gradient, light and dark.
// Usage: swift scripts/compose.swift <rawDir> <outDir> <colorA hex> <colorB hex> <page>...
//   rawDir holds <page>-light.png / <page>-dark.png and <firstPage>-symbol.png (see the app's --snapshot mode);
//   writes <outDir>/<page>-light.png and <outDir>/<page>-dark.png. The colours are the app icon's two gradient colours.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 6 else { FileHandle.standardError.write(Data("usage: compose.swift rawDir outDir colorA colorB page...\n".utf8)); exit(2) }
let rawDir = args[1], outDir = args[2], pages = Array(args[5...])
let scale: CGFloat = 2, panelWidth: CGFloat = 380, margin: CGFloat = 48, barHeight: CGFloat = 24, gap: CGFloat = 8

func rgb(_ hex: String) -> [CGFloat] {
    let v = UInt32(hex, radix: 16) ?? 0
    return [CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255]
}
let colorA = rgb(args[3]), colorB = rgb(args[4])
func mix(_ c: [CGFloat], _ with: CGFloat, _ t: CGFloat) -> CGColor {
    CGColor(srgbRed: c[0] + (with - c[0]) * t, green: c[1] + (with - c[1]) * t, blue: c[2] + (with - c[2]) * t, alpha: 1)
}

func load(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write(Data("missing \(path)\n".utf8)); exit(1)
    }
    return image
}

/// The snapshot's symbol strip has a light (top) and a dark (bottom) background; recover the ink as an alpha mask.
func symbol(dark: Bool) -> CGImage {
    let sheet = load("\(rawDir)/\(pages[0])-symbol.png")
    let h = sheet.height / 2, w = sheet.width
    let strip = sheet.cropping(to: CGRect(x: 0, y: dark ? h : 0, width: w, height: h))!
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(strip, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in 0..<(w * h) {
        let l = Double(px[i * 4]) / 255
        let a = dark ? max(0, (l - 0.16) / 0.84) : 1 - l
        let ink: UInt8 = dark ? 255 : 0
        px[i * 4] = UInt8(Double(ink) * a); px[i * 4 + 1] = px[i * 4]; px[i * 4 + 2] = px[i * 4]; px[i * 4 + 3] = UInt8(a * 255)
    }
    return ctx.makeImage()!
}

func glyph(_ name: String, ink: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
    return NSImage(size: base.size, flipped: false) { r in base.draw(in: r); ink.set(); r.fill(using: .sourceIn); return true }
}

/// ImageIO adds an eXIf chunk (pixel size) even without properties; keep only the chunks needed to display the image.
func stripMetadata(_ png: Data) -> Data {
    let keep: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "sRGB"]
    var out = png.prefix(8), i = 8
    while i + 12 <= png.count {
        let length = png[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
        if keep.contains(String(decoding: png[i + 4..<i + 8], as: UTF8.self)) { out += png[i..<i + 12 + length] }
        i += 12 + length
    }
    return out
}

func compose(page: String, dark: Bool) {
    let panel = load("\(rawDir)/\(page)-\(dark ? "dark" : "light").png")
    let panelHeight = CGFloat(panel.height) / scale
    let width = panelWidth + 2 * margin, height = barHeight + gap + panelHeight + margin
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Work top-down like a layout: y = 0 is the top edge.
    ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: 1, y: -1)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.current = ns

    let colors = dark ? [mix(colorA, 0, 0.72), mix(colorB, 0, 0.55)] : [mix(colorA, 1, 0.62), mix(colorB, 1, 0.55)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

    // Menu bar: translucent so the gradient shows through; only this app's icon plus generic system glyphs.
    ctx.setFillColor(dark ? CGColor(gray: 0, alpha: 0.45) : CGColor(gray: 1, alpha: 0.55))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: barHeight))
    let ink = dark ? NSColor.white : NSColor.black
    var x = width - 12
    let text = NSAttributedString(string: "Mon 9:41", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink])
    x -= text.size().width
    text.draw(at: NSPoint(x: x, y: (barHeight - text.size().height) / 2))
    for name in ["battery.100", "wifi", "magnifyingglass"] {
        guard let g = glyph(name, ink: ink) else { continue }
        x -= 14 + g.size.width
        g.draw(in: NSRect(x: x, y: (barHeight - g.size.height) / 2, width: g.size.width, height: g.size.height), from: .zero, operation: .sourceOver,
               fraction: 1, respectFlipped: true, hints: nil)
    }
    let icon = symbol(dark: dark)
    let iconW = CGFloat(icon.width) / scale, iconH = CGFloat(icon.height) / scale
    let iconX = x - 8 - iconW
    ctx.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.22 : 0.16))   // selected-item highlight while the menu is open
    ctx.addPath(CGPath(roundedRect: CGRect(x: iconX, y: 1, width: iconW, height: barHeight - 2), cornerWidth: 5, cornerHeight: 5, transform: nil))
    ctx.fillPath()
    ctx.saveGState(); ctx.translateBy(x: 0, y: barHeight); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(icon, in: CGRect(x: iconX, y: (barHeight - iconH) / 2, width: iconW, height: iconH)); ctx.restoreGState()

    // Panel: rounded, soft shadow, hairline border.
    let rect = CGRect(x: margin, y: barHeight + gap, width: panelWidth, height: panelHeight)
    let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.28))
    ctx.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 1, alpha: 1))
    ctx.addPath(path); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.translateBy(x: 0, y: rect.minY + rect.height); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(panel, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.22 : 0.14)); ctx.setLineWidth(0.5)
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 11.75, cornerHeight: 11.75, transform: nil)); ctx.strokePath()

    let url = URL(fileURLWithPath: "\(outDir)/\(page)-\(dark ? "dark" : "light").png")
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
    do { try stripMetadata(data as Data).write(to: url) } catch { exit(1) }
    print(url.path)
}

for page in pages { for dark in [false, true] { compose(page: page, dark: dark) } }
