// Render an SVG to PNG through WebKit.
//
//   swift tools/svg-render.swift <in.svg> <out.png> <width>
//
// WebKit and not NSImage, deliberately. NSImage loads SVG and renders
// gradients, but silently ignores mix-blend-mode — and the mark's top petal
// depends on one. The same file through both renderers differs by 26/1020,
// with the overlap coming out blue-violet instead of magenta, and nothing says
// anything went wrong. So the build renders with the engine that honours the
// artwork, and the app never sees the SVG at all.

import WebKit
import AppKit

final class Renderer: NSObject, WKNavigationDelegate {
    let out: String, w: Int, h: Int
    var finished = false
    var failure: String?

    init(out: String, w: Int, h: Int) { self.out = out; self.w = w; self.h = h }

    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: w, height: h)
        // The compositor needs a moment before a snapshot is worth taking; a
        // gradient-heavy document photographs blank without it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            web.takeSnapshot(with: cfg) { image, error in
                defer { self.finished = true }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    self.failure = error?.localizedDescription ?? "no image"
                    return
                }
                do { try png.write(to: URL(fileURLWithPath: self.out)) }
                catch { self.failure = error.localizedDescription }
            }
        }
    }

    func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
        finished = true
    }
}

let args = CommandLine.arguments
guard args.count == 4, let width = Int(args[3]) else {
    FileHandle.standardError.write(
        "usage: svg-render <in.svg> <out.png> <width>\n".data(using: .utf8)!)
    exit(2)
}
guard let svg = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

// Height from the document's own aspect, so the caller gives one number and
// cannot squash the artwork by giving two that disagree.
var height = width
if let m = svg.range(of: #"viewBox="[-0-9.]+ [-0-9.]+ ([0-9.]+) ([0-9.]+)""#,
                     options: .regularExpression) {
    let nums = svg[m].split(separator: "\"")[1].split(separator: " ").compactMap { Double($0) }
    if nums.count == 4, nums[2] > 0 {
        height = Int((Double(width) * nums[3] / nums[2]).rounded())
    }
}

let html = """
<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;padding:0;background:transparent}
svg{display:block;width:\(width)px;height:\(height)px}</style>
\(svg)
"""

let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height),
                    configuration: WKWebViewConfiguration())
web.setValue(false, forKey: "drawsBackground")
let renderer = Renderer(out: args[2], w: width, h: height)
web.navigationDelegate = renderer
web.loadHTMLString(html, baseURL: nil)

let deadline = Date().addingTimeInterval(30)
while !renderer.finished && Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
if let failure = renderer.failure {
    FileHandle.standardError.write("render failed: \(failure)\n".data(using: .utf8)!)
    exit(1)
}
guard renderer.finished else {
    FileHandle.standardError.write("render timed out\n".data(using: .utf8)!)
    exit(1)
}
print("    \(args[2]) (\(width)x\(height))")
