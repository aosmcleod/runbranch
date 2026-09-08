// Renders a monochrome template image for the menu bar from the logo mark.
//
// A menu bar item has to be a template: macOS tints it for light and dark
// menu bars and inverts it when the menu is open, so colour and gradient
// cannot survive the trip. What carries over is the silhouette, which is why
// this reduces the mark to its coverage and throws the rest away.
//
//   swift tools/menubar-glyph.swift <source.png> <out-dir>
//
// Writes MenuBarIcon.png (18pt) and MenuBarIcon@2x.png (36pt).

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: menubar-glyph <source.png> <out-dir>\n"
        .data(using: .utf8)!)
    exit(2)
}
guard let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

/// Alpha below this is treated as absent. The mark's edges are antialiased and
/// its glass panels are semi-transparent, so a naive test picks up a halo.
let cutoff: CGFloat = 0.35

func silhouette(_ image: CGImage, side: Int) -> CGImage? {
    // Read coverage at high resolution, then box-filter down. Thresholding
    // after scaling keeps the edge smooth instead of stair-stepped.
    let w = image.width, h = image.height
    var alpha = [CGFloat](repeating: 0, count: w * h)
    var hue = [CGFloat](repeating: -1, count: w * h)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for i in 0..<(w * h) {
        alpha[i] = CGFloat(px[i * 4 + 3]) / 255
        // Hue identifies which card a pixel belongs to. A filled silhouette of
        // the union is an unreadable blob — the three cards only read as three
        // shapes if the boundaries between them survive, and colour is the
        // only thing in a flat PNG that says where those boundaries are.
        if alpha[i] > 0.5 {
            let r = CGFloat(px[i * 4]) / 255, g = CGFloat(px[i * 4 + 1]) / 255
            let b = CGFloat(px[i * 4 + 2]) / 255
            hue[i] = NSColor(red: r, green: g, blue: b, alpha: 1).hueComponent
        }
    }

    guard let out = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let scale = CGFloat(w) / CGFloat(side)
    for y in 0..<side {
        for x in 0..<side {
            // Average the source block this output pixel covers.
            let x0 = Int(CGFloat(x) * scale), x1 = min(w, Int(CGFloat(x + 1) * scale))
            let y0 = Int(CGFloat(y) * scale), y1 = min(h, Int(CGFloat(y + 1) * scale))
            var sum: CGFloat = 0, n = 0
            for sy in y0..<max(y0 + 1, y1) {
                for sx in x0..<max(x0 + 1, x1) { sum += alpha[sy * w + sx]; n += 1 }
            }
            let cover = n > 0 ? sum / CGFloat(n) : 0
            // Carve a gap wherever the block straddles two cards.
            var hues: [CGFloat] = []
            for sy in y0..<max(y0 + 1, y1) {
                for sx in x0..<max(x0 + 1, x1) where hue[sy * w + sx] >= 0 {
                    hues.append(hue[sy * w + sx])
                }
            }
            // Carve only where a block genuinely sits on a boundary. Testing
            // the hue spread alone marked any block containing a sliver of a
            // second card, which at 18pt is most of them — the gaps then ate
            // the glyph. Requiring the minority side to be a real share of the
            // block keeps the gap to the boundary itself.
            var straddles = false
            if let lo = hues.min(), let hi = hues.max(), !hues.isEmpty {
                let spread = min(hi - lo, 1 - (hi - lo))   // hue wraps at 1
                if spread > 0.06 {
                    let mid = (lo + hi) / 2
                    let below = hues.filter { $0 < mid }.count
                    let minority = min(below, hues.count - below)
                    straddles = CGFloat(minority) / CGFloat(hues.count) > 0.3
                }
            }
            if straddles {
                out.setFillColor(CGColor(gray: 0, alpha: 0))
                out.fill(CGRect(x: x, y: side - 1 - y, width: 1, height: 1))
                continue
            }
            // Anything meaningfully covered becomes solid; partial coverage at
            // the boundary keeps its value so the edge stays soft.
            let a = cover < cutoff ? 0 : min(1, cover * 1.25)
            out.setFillColor(CGColor(gray: 0, alpha: a))
            out.fill(CGRect(x: x, y: side - 1 - y, width: 1, height: 1))
        }
    }
    return out.makeImage()
}

for (side, name) in [(18, "MenuBarIcon.png"), (36, "MenuBarIcon@2x.png")] {
    guard let glyph = silhouette(cg, side: side) else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: glyph)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    let path = args[2] + "/" + name
    try! png.write(to: URL(fileURLWithPath: path))
    print("    \(name) written (\(side)pt)")
}
