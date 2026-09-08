// Renders the monochrome template image for the menu bar.
//
// A menu bar item has to be a template: macOS tints it for light and dark menu
// bars and inverts it while the menu is open, so colour and gradient cannot
// survive the trip. Only the silhouette does — and the mark's two petals
// overlap, so their plain silhouette is one blob with nothing to say where a
// petal ends.
//
// The source is therefore a vector with the seams drawn in as real geometry:
// the two petals and the lens where they cross are separate paths with gaps
// between them. Rendering that gives an exact result at any size.
//
// This replaced deriving the seams from the colour PNG, which worked but needed
// hue bands tuned by hand to the mark, and re-tuning whenever it changed. If
// you ever have to go back to it, the two things that make it work are in the
// `app-icons` skill; the short version is that the gap must be sized in output
// pixels and cut between hue-classified regions, not wherever hue changes.
//
//   swift tools/menubar-glyph.swift <source.svg> <out-dir>
//
// Writes MenuBarIcon.png (18pt) and MenuBarIcon@2x.png (36pt).

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(
        "usage: menubar-glyph <source.svg> <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
guard let art = NSImage(contentsOfFile: args[1]), art.size.width > 0 else {
    FileHandle.standardError.write("""
        cannot read \(args[1])

        This wants the seamed vector — two petals and the lens where they cross
        as separate paths. A raster source will load but its silhouette is a
        single blob, which is the whole thing this avoids.

        """.data(using: .utf8)!)
    exit(1)
}

// The menu bar is about 22pt tall and a template usually fills 16 to 18 of it.
//
// Fitting the artwork into a SQUARE canvas is what made this too small: the
// mark is wider than it is tall, so fitting by the smaller dimension left the
// glyph occupying 12 of 18 vertical pixels. The vector also carries about 30%
// empty margin of its own, which compounded it. So: crop to the real content,
// then size by HEIGHT and let the width fall where it does. A status item is
// variable-width and does not want a square.
let contentHeight = 16
let canvasPad = 1
/// Supersampling factor. The seams are roughly a pixel wide at the target, so
/// rendering straight to 18pt leaves them to the rasteriser's antialiasing;
/// rendering large and averaging down keeps them as a definite line.
let over = 32

/// Rasterise the vector at `height` pixels tall, and report its alpha plus the
/// bounds the artwork actually occupies.
func rasterise(height: Int) -> (cover: [Float], w: Int, h: Int,
                                minX: Int, maxX: Int, minY: Int, maxY: Int) {
    let w = Int((CGFloat(height) * art.size.width / art.size.height).rounded())
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: w * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    art.draw(in: NSRect(x: 0, y: 0, width: w, height: height))
    NSGraphicsContext.restoreGraphicsState()

    // Only the alpha matters; the paths' own colour is irrelevant to a template.
    let ctx = CGContext(data: nil, width: w, height: height, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: height))
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * height * 4)
    var cover = [Float](repeating: 0, count: w * height)
    var minX = w, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<w {
            let a = Float(px[(y * w + x) * 4 + 3]) / 255
            cover[y * w + x] = a
            if a > 0.02 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    return (cover, w, height, minX, maxX, minY, maxY)
}

func write(_ cover: [Float], w: Int, h: Int, to path: String) throws {
    let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<h {
        for x in 0..<w {
            out.setFillColor(CGColor(gray: 0, alpha: CGFloat(cover[y * w + x])))
            out.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1))
        }
    }
    let png = NSBitmapImageRep(cgImage: out.makeImage()!)
        .representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: path))
}

for (factor, name) in [(1, "MenuBarIcon.png"), (2, "MenuBarIcon@2x.png")] {
    let ch = contentHeight * factor
    let pad = canvasPad * factor

    // Rasterise large, crop to the artwork's real bounds, then average down to
    // the target. Cropping first is what makes the glyph fill its height: the
    // vector's own empty margin is discarded rather than scaled along with it.
    let r = rasterise(height: ch * over)
    guard r.maxX >= r.minX, r.maxY >= r.minY else {
        FileHandle.standardError.write("source has no visible content\n".data(using: .utf8)!)
        exit(1)
    }
    let cw = r.maxX - r.minX + 1, chh = r.maxY - r.minY + 1
    let step = Float(chh) / Float(ch)                 // source px per output px
    let outW = max(1, Int((Float(cw) / step).rounded()))

    var down = [Float](repeating: 0, count: outW * ch)
    for oy in 0..<ch {
        for ox in 0..<outW {
            let sx0 = r.minX + Int(Float(ox) * step), sx1 = min(r.maxX + 1,
                                     r.minX + Int(Float(ox + 1) * step))
            let sy0 = r.minY + Int(Float(oy) * step), sy1 = min(r.maxY + 1,
                                     r.minY + Int(Float(oy + 1) * step))
            var sum: Float = 0
            var n = 0
            for sy in sy0..<max(sy0 + 1, sy1) {
                for sx in sx0..<max(sx0 + 1, sx1) { sum += r.cover[sy * r.w + sx]; n += 1 }
            }
            down[oy * outW + ox] = n > 0 ? sum / Float(n) : 0
        }
    }

    // Pad, so the glyph does not butt against its neighbours in the bar.
    let padW = outW + pad * 2, padH = ch + pad * 2
    var canvas = [Float](repeating: 0, count: padW * padH)
    for y in 0..<ch {
        for x in 0..<outW { canvas[(y + pad) * padW + (x + pad)] = down[y * outW + x] }
    }

    try write(canvas, w: padW, h: padH, to: args[2] + "/" + name)
    print("    \(name) written (\(padW)x\(padH), content \(outW)x\(ch))")
}
