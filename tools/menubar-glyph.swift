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

/// A little air, so the glyph does not touch the edge of its slot.
let inset: CGFloat = 0.03
/// Supersampling factor. The seams are roughly a pixel wide at the target, so
/// rendering straight to 18pt leaves them to the rasteriser's antialiasing;
/// rendering large and averaging down keeps them as a definite line.
let over = 32

/// Fit the vector into a square of `side`, centred, and return its coverage.
func coverage(side: Int) -> [Float] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: side * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let avail = CGFloat(side) * (1 - inset * 2)
    let scale = min(avail / art.size.width, avail / art.size.height)
    let w = art.size.width * scale, h = art.size.height * scale
    art.draw(in: NSRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2,
                        width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()

    // Only the alpha matters; the paths' own colour is irrelevant to a template.
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: side, height: side))
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: side * side * 4)
    return (0..<(side * side)).map { Float(px[$0 * 4 + 3]) / 255 }
}

func write(_ cover: [Float], side: Int, to path: String) throws {
    let out = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<side {
        for x in 0..<side {
            out.setFillColor(CGColor(gray: 0, alpha: CGFloat(cover[y * side + x])))
            out.fill(CGRect(x: x, y: side - 1 - y, width: 1, height: 1))
        }
    }
    let png = NSBitmapImageRep(cgImage: out.makeImage()!)
        .representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: path))
}

for (side, name) in [(18, "MenuBarIcon.png"), (36, "MenuBarIcon@2x.png")] {
    let big = side * over
    let hi = coverage(side: big)
    var down = [Float](repeating: 0, count: side * side)
    let cells = Float(over * over)
    for oy in 0..<side {
        for ox in 0..<side {
            var sum: Float = 0
            for sy in (oy * over)..<((oy + 1) * over) {
                for sx in (ox * over)..<((ox + 1) * over) { sum += hi[sy * big + sx] }
            }
            down[oy * side + ox] = sum / cells
        }
    }
    try write(down, side: side, to: args[2] + "/" + name)
    print("    \(name) written (\(side)pt)")
}
