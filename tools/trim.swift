import AppKit

// Trim a PNG to its visible content, optionally dropping matte fringing first,
// then centre it on a square canvas at a chosen size.
//
//   trim <in.png> <out.png> <size> [fraction] [alphaCutoff]
//
// The cutoff matters for more than tidiness: fringing speckles sit outside the
// real artwork, so they drag the bounding box outward and the centring with it.
let a = CommandLine.arguments
guard a.count >= 4, let size = Int(a[3]) else {
    FileHandle.standardError.write("usage: trim <in> <out> <size> [fraction] [cutoff]\n".data(using: .utf8)!); exit(2)
}
let fraction = a.count >= 5 ? (Double(a[4]) ?? 1.0) : 1.0
let cutoff   = a.count >= 6 ? (Double(a[5]) ?? 0.0) : 0.0
// "optical" nudges the artwork so its centre of MASS lands centre, rather than
// the middle of its bounding box. For an asymmetric mark the two differ.
let optical  = a.count >= 7 && a[6] == "optical"

guard let img = NSImage(contentsOfFile: a[1]), let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage else { exit(1) }
let w = cg.width, h = cg.height

// Read once into a buffer; colorAt() per pixel is far too slow at this size.
var buf = [UInt8](repeating: 0, count: w * h * 4)
guard let rctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                           bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
rctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

var dropped = 0
if cutoff > 0 {
    let limit = UInt8(cutoff * 255)
    for i in stride(from: 0, to: buf.count, by: 4) where buf[i+3] > 0 && buf[i+3] < limit {
        buf[i] = 0; buf[i+1] = 0; buf[i+2] = 0; buf[i+3] = 0
        dropped += 1
    }
}

var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h { for x in 0..<w {
    if buf[(y * w + x) * 4 + 3] > 6 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}}
guard maxX >= minX else { exit(1) }
let cw = maxX - minX + 1, ch = maxY - minY + 1

guard let cleaned = rctx.makeImage(),
      let cropped = cleaned.cropping(to: CGRect(x: minX, y: minY, width: cw, height: ch)),
      let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
out.interpolationQuality = .high

let side = Double(max(cw, ch))
let scale = Double(size) * fraction / side
let dw = Double(cw) * scale, dh = Double(ch) * scale

var ox = 0.0, oy = 0.0
if optical {
    var sx = 0.0, sy = 0.0, sa = 0.0
    for y in minY...maxY { for x in minX...maxX {
        let al = Double(buf[(y * w + x) * 4 + 3]) / 255.0
        if al > 0.02 { sx += Double(x) * al; sy += Double(y) * al; sa += al }
    }}
    // Shift by the opposite of the mass offset, in output pixels.
    ox = -(sx / sa - Double(minX + maxX) / 2) * scale
    oy =  (sy / sa - Double(minY + maxY) / 2) * scale   // CG y is flipped
    FileHandle.standardError.write(String(format: "optical nudge %+.1f, %+.1f px\n", ox, oy).data(using: .utf8)!)
}
out.draw(cropped, in: CGRect(x: (Double(size) - dw) / 2 + ox, y: (Double(size) - dh) / 2 + oy,
                             width: dw, height: dh))
guard let final = out.makeImage() else { exit(1) }
try? NSBitmapImageRep(cgImage: final).representation(using: .png, properties: [:])?
    .write(to: URL(fileURLWithPath: a[2]))
FileHandle.standardError.write(
  "content \(cw)x\(ch)  dropped \(dropped) fringe px  -> \(size) at \(Int(fraction*100))%\n".data(using: .utf8)!)
