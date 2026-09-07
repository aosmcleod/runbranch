import AppKit
// crop <in.png> <out.png> <x> <y> <w> <h> [scale]
// Origin top-left, in points; `scale` maps points to captured pixels.
let a = CommandLine.arguments
guard a.count >= 7, let x = Double(a[3]), let y = Double(a[4]),
      let w = Double(a[5]), let h = Double(a[6]) else {
    FileHandle.standardError.write("usage: crop <in> <out> x y w h [scale]\n".data(using: .utf8)!); exit(2)
}
let scale = a.count >= 8 ? (Double(a[7]) ?? 1) : 1
guard let img = NSImage(contentsOfFile: a[1]), let t = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: t), let cg = rep.cgImage else { exit(1) }
let r = CGRect(x: x*scale, y: y*scale, width: w*scale, height: h*scale)
    .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
guard !r.isNull, let out = cg.cropping(to: r) else {
    FileHandle.standardError.write("rect outside image\n".data(using: .utf8)!); exit(1)
}
try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?
    .write(to: URL(fileURLWithPath: a[2]))
FileHandle.standardError.write("cropped \(Int(r.width))x\(Int(r.height))\n".data(using: .utf8)!)
