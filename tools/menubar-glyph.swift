// Renders a monochrome template image for the menu bar from the logo mark.
//
// A menu bar item has to be a template: macOS tints it for light and dark menu
// bars and inverts it while the menu is open, so colour and gradient cannot
// survive the trip. Only the silhouette does.
//
//   swift tools/menubar-glyph.swift <source.png> <out-dir>
//
// Writes MenuBarIcon.png (18pt) and MenuBarIcon@2x.png (36pt).
//
// This works because the mark's shapes are separated by real transparency. An
// earlier mark was three contiguous overlapping cards, whose silhouette was a
// single unreadable blob; separating them meant carving gaps along colour
// boundaries, and at 18pt those gaps ate more of the glyph than they revealed.
// If the mark ever changes back to contiguous shapes, a flat silhouette will
// not be enough and line art would be the thing to try.

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(
        "usage: menubar-glyph <source.png> <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
guard let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

/// Alpha below this counts as absent. The mark's edges are antialiased and its
/// panels are semi-transparent, so a naive test picks up a halo.
let cutoff: CGFloat = 0.35

func silhouette(_ image: CGImage, side: Int) -> CGImage? {
    let w = image.width, h = image.height
    guard let read = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    read.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = read.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

    var alpha = [CGFloat](repeating: 0, count: w * h)
    for i in 0..<(w * h) { alpha[i] = CGFloat(px[i * 4 + 3]) / 255 }

    guard let out = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    // Average the coverage of the source block each output pixel covers, then
    // threshold. Thresholding after the average keeps the edge smooth rather
    // than stair-stepped.
    let scale = CGFloat(w) / CGFloat(side)
    for y in 0..<side {
        for x in 0..<side {
            let x0 = Int(CGFloat(x) * scale), x1 = min(w, Int(CGFloat(x + 1) * scale))
            let y0 = Int(CGFloat(y) * scale), y1 = min(h, Int(CGFloat(y + 1) * scale))
            var sum: CGFloat = 0
            var n = 0
            for sy in y0..<max(y0 + 1, y1) {
                for sx in x0..<max(x0 + 1, x1) {
                    sum += alpha[sy * w + sx]
                    n += 1
                }
            }
            let cover = n > 0 ? sum / CGFloat(n) : 0
            let a = cover < cutoff ? 0 : min(1, cover * 1.25)
            out.setFillColor(CGColor(gray: 0, alpha: a))
            out.fill(CGRect(x: x, y: side - 1 - y, width: 1, height: 1))
        }
    }
    return out.makeImage()
}

for (side, name) in [(18, "MenuBarIcon.png"), (36, "MenuBarIcon@2x.png")] {
    guard let glyph = silhouette(cg, side: side),
          let png = NSBitmapImageRep(cgImage: glyph)
            .representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed at \(side)pt\n".data(using: .utf8)!)
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: args[2] + "/" + name))
    print("    \(name) written (\(side)pt)")
}
