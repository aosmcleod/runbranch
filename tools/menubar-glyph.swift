// Renders a monochrome template image for the menu bar from the logo mark.
//
// A menu bar item has to be a template: macOS tints it for light and dark menu
// bars and inverts it while the menu is open, so colour and gradient cannot
// survive the trip. Only the silhouette does — which is a problem when the
// mark's shapes overlap, because their union is then one contiguous blob with
// nothing to say where one shape ends.
//
// So: cut a hairline gap where two materially different hues meet.
//
// The width of that gap is the whole trick, and an earlier attempt got it
// wrong. Marking any output pixel whose source block straddled a hue boundary
// made the gap as wide as a block — about 70 source pixels at 18pt — and it ate
// more of the glyph than it revealed. Sizing the band in OUTPUT pixels and
// converting back to source works: one output pixel wide, along the actual
// boundary, at any target size.
//
// Marks whose parts are already separated by transparency have no internal
// boundary to find, so they fall through this unchanged.
//
//   swift tools/menubar-glyph.swift <source.png> <out-dir>
//
// Writes MenuBarIcon.png (18pt) and MenuBarIcon@2x.png (36pt).

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

/// Alpha below this counts as absent. Edges are antialiased and panels may be
/// semi-transparent, so a naive test picks up a halo.
let alphaCutoff: Float = 0.35
// The mark's shapes are identified by hue band, and the bands below are tuned
// to the current mark: a warm shape, a cool shape, and the blended colour where
// they overlap. Reacting to local hue *distance* instead was tried and is worse
// — it fires on the gradient inside a single shape and, more importantly, only
// nicks the seam where the colour happens to change fastest, rather than
// following the whole boundary between the two shapes.
//
// Retune these if the mark changes. `tools/hue-probe` prints a scanline.
let warmBand: (Float, Float) = (0.85, 0.20)   // wraps through 0
let blendBand: (Float, Float) = (0.72, 0.85)  // the overlap

let W = cg.width, H = cg.height
let read = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                     space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
read.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
let px = read.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)

/// 0 absent, 1 the warm shape, 2 the overlap, 3 the cool shape.
var cls = [UInt8](repeating: 0, count: W * H)
var alpha = [Float](repeating: 0, count: W * H)
for i in 0..<(W * H) {
    let a = Float(px[i * 4 + 3]) / 255
    alpha[i] = a
    guard a > 0.5 else { continue }
    let c = NSColor(red: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255,
                    blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
    let h = Float(c.hueComponent)
    if h >= warmBand.0 || h < warmBand.1            { cls[i] = 1 }
    else if h >= blendBand.0 && h < blendBand.1     { cls[i] = 2 }
    else                                            { cls[i] = 3 }
}

/// True when nothing in the mark overlaps — no two bands are both present — in
/// which case transparency already separates the shapes and there is no seam to
/// cut. A mark like that falls through unchanged.
let hasOverlap = cls.contains(2)

func render(size S: Int) -> CGImage {
    // One output pixel spans this many source pixels, so this is what "a
    // one-pixel gap" means down here.
    let span = Float(W) / Float(S)
    let r = max(1, Int((span * 0.55).rounded()))

    // Sample a ring rather than a filled disc: the band only needs to know
    // whether a different hue is within reach, not how much of one.
    let ring: [(Int, Int)] = (0..<12).map { k in
        let t = Float(k) / 12 * 2 * .pi
        return (Int((cos(t) * Float(r)).rounded()), Int((sin(t) * Float(r)).rounded()))
    }

    var gap = [Bool](repeating: false, count: W * H)
    if hasOverlap {
        // Cut along the boundary between the warm shape and everything else,
        // counting the overlap as part of the other shape so the front one
        // reads unbroken.
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                guard cls[i] == 2 || cls[i] == 3 else { continue }
                for (dx, dy) in ring {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
                    if cls[ny * W + nx] == 1 { gap[i] = true; break }
                }
            }
        }
    }

    let out = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Average the coverage of the source block each output pixel covers, then
    // threshold. Thresholding after the average keeps the edge smooth rather
    // than stair-stepped, and renders the band as a soft one-pixel line.
    let scale = Float(W) / Float(S)
    for oy in 0..<S {
        for ox in 0..<S {
            let x0 = Int(Float(ox) * scale), x1 = min(W, Int(Float(ox + 1) * scale))
            let y0 = Int(Float(oy) * scale), y1 = min(H, Int(Float(oy + 1) * scale))
            var sum: Float = 0
            var n = 0
            for sy in y0..<max(y0 + 1, y1) {
                for sx in x0..<max(x0 + 1, x1) {
                    let i = sy * W + sx
                    sum += gap[i] ? 0 : alpha[i]
                    n += 1
                }
            }
            let cover = n > 0 ? sum / Float(n) : 0
            let a = cover < alphaCutoff ? 0 : min(1, cover * 1.25)
            out.setFillColor(CGColor(gray: 0, alpha: CGFloat(a)))
            out.fill(CGRect(x: ox, y: S - 1 - oy, width: 1, height: 1))
        }
    }
    return out.makeImage()!
}

for (side, name) in [(18, "MenuBarIcon.png"), (36, "MenuBarIcon@2x.png")] {
    let glyph = render(size: side)
    guard let png = NSBitmapImageRep(cgImage: glyph)
            .representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed at \(side)pt\n".data(using: .utf8)!)
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: args[2] + "/" + name))
    print("    \(name) written (\(side)pt)")
}
