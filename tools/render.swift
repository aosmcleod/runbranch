import AppKit
import WebKit

// Render an HTML file to a PNG at a given size, using WebKit — which supports
// real blend modes and backdrop-filter, unlike sips' SVG rasteriser.
let args = CommandLine.arguments
guard args.count >= 4, let px = Int(args[3]) else {
    FileHandle.standardError.write("usage: render <in.html> <out.png> <px>\n".data(using: .utf8)!)
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Done: NSObject, WKNavigationDelegate {
    let web: WKWebView; let out: URL; let px: Int
    init(web: WKWebView, out: URL, px: Int) { self.web = web; self.out = out; self.px = px }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        // Let fonts, filters and compositing settle before snapshotting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: self.px, height: self.px)
            w.takeSnapshot(with: cfg) { image, err in
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write("snapshot failed: \(err?.localizedDescription ?? "?")\n".data(using: .utf8)!)
                    exit(1)
                }
                try? png.write(to: self.out)
                exit(0)
            }
        }
    }
}

let cfg = WKWebViewConfiguration()
let web = WKWebView(frame: CGRect(x: 0, y: 0, width: px, height: px), configuration: cfg)
web.setValue(false, forKey: "drawsBackground")     // transparent where the page is
let delegate = Done(web: web, out: outURL, px: px)
web.navigationDelegate = delegate
web.loadFileURL(inURL, allowingReadAccessTo: inURL.deletingLastPathComponent())
app.run()
