// Runbranch — run any branch of any project on a real port.
// Copyright (C) 2026 Alec McLeod
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; without even the
// implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details:
// <https://www.gnu.org/licenses/>.

// The app photographing itself — for the documentation, and for the test
// that reads back what it drew.

import SwiftUI
import AppKit
import ScreenCaptureKit
import Vision

/// Screenshots of this window kept catching whatever was on the active Space
/// instead. Two dead ends before this worked: `cacheDisplay` draws the view
/// tree but cannot composite vibrancy or SwiftUI's layers, so the sidebar came
/// back blank; and ScreenCaptureKit needs Screen Recording permission, which
/// an ad-hoc-signed binary launched from a terminal is never prompted for.
///
/// So the app does not photograph itself. `--hold <seconds>` opens the window,
/// prints its window number, and waits — and the caller uses `screencapture
/// -l`, which already has the permission. The window number is the piece only
/// the app knows.
enum Screenshot {
    static var path: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--screenshot"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// Which screen to photograph. The docs need more than one, and opening a
    /// sheet by hand before every capture is not automation.
    enum Scene: String { case main, settings, scan, logs, about, disk }

    /// Capture diagnostics. Launched via LaunchServices the app has no useful
    /// stderr, so mirror everything into RB_SHOT_LOG for the script to show.
    static func note(_ text: String) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        guard let path = ProcessInfo.processInfo.environment["RB_SHOT_LOG"] else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static var scene: Scene {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--scene"), i + 1 < a.count,
              let s = Scene(rawValue: a[i + 1]) else { return .main }
        return s
    }

    /// Photographs its own window through ScreenCaptureKit, which captures what
    /// the window server actually composited — glass, vibrancy and all.
    ///
    /// Two earlier approaches failed and are worth not repeating. `cacheDisplay`
    /// draws the view tree but cannot composite vibrancy or SwiftUI's layers,
    /// so the sidebar came back blank. `CGWindowListCreateImage` is gone in
    /// macOS 26. This route needs Screen Recording permission, which macOS does
    /// not prompt for on an ad-hoc-signed binary launched from a terminal — it
    /// has to be added by hand in System Settings.
    @MainActor
    static func captureAndQuit(to path: String) async {
        // Hard deadline. NSApp.terminate can be refused and a stuck await never
        // reaches the defer, so this exits the process outright.
        Task.detached {
            try? await Task.sleep(for: .seconds(30))
            Screenshot.note("capture timed out after 30s")
            exit(2)
        }
        defer { NSApp.terminate(nil) }
        // The main window, never a sheet: a sheet is a child window, and
        // changing its level detaches it from the modal session it belongs to.
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.parent == nil
        }) ?? NSApp.windows.first(where: { $0.isVisible })
            ?? NSApp.windows.first else { return }

        // A window belongs to one Space, and a fullscreen app's Space excludes
        // it — which is why every earlier capture caught whatever was
        // fullscreen instead. This was the real cause, not the capture API.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        // A window whose sharingType is .none is visible on screen but absent
        // from the capture API's list entirely — the exact symptom we had, and
        // indistinguishable from a missing permission from the outside.
        window.sharingType = .readOnly
        // Capture on the sharpest available display. A window on a 1x monitor
        // can only ever yield 1x pixels, so if a Retina screen is attached the
        // shot should happen there.
        let best = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        if let screen = best ?? NSScreen.main {
            // Whatever size the mode asked for — onboarding is deliberately
            // small — just centred so every capture is framed the same way.
            let size = window.frame.size
            let vf = screen.visibleFrame
            window.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        // Focus is taken only when the capture is for documentation.
        //
        // A window that is not frontmost photographs with grey traffic
        // lights and dimmed controls, so a docs shot needs this. But the
        // pipeline also gets used to check a layout while working, and
        // there it steals focus five times a run, which makes the machine
        // unusable alongside. RB_SHOT_QUIET is for that.
        if ProcessInfo.processInfo.environment["RB_SHOT_QUIET"] == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        try? await Task.sleep(for: .seconds(3.5))     // layout, health poll, glass

        // Re-assert focus. Anything that grabbed it during the settle above
        // leaves the window looking inactive — grey traffic lights, dimmed
        // controls — which reads as a broken app rather than a screenshot.
        window.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["RB_SHOT_QUIET"] == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Raising the main window buries any panel the scene opened, which is
        // how the About shot came back showing the window behind it.
        // The panel opens over the main window, so it needs raising after the
        // window above has taken focus.
        if Screenshot.scene == .about { AboutPanel.shared.show() }
        try? await Task.sleep(for: .milliseconds(600))

        do {
            let id = CGWindowID(window.windowNumber)
            let mypid = ProcessInfo.processInfo.processIdentifier
            // Poll for any on-screen window belonging to this app, rather than
            // one specific window number. With a sheet open there are several,
            // and which one NSApp lists first is not ours to predict — waiting
            // on the wrong number simply timed out while the app sat visible
            // on screen. The largest is the real window; the rest are its
            // sheets, and they are all captured together below.
            var ours: [SCWindow] = []
            for _ in 0..<12 {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                ours = content.windows.filter {
                    $0.owningApplication?.processID == mypid && $0.isOnScreen
                        && $0.frame.width > 1 && $0.frame.height > 1
                }
                if !ours.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(400))
            }

            guard let target = ours.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else {
                // A granted call lists every on-screen window on the machine.
                // A short list owned only by system processes means the grant
                // is missing; owner names alone do not prove it is present.
                let content = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                let seen = content?.windows.count ?? -1
                let owners = Set((content?.windows ?? []).compactMap {
                    $0.owningApplication?.applicationName
                }).sorted().joined(separator: ", ")
                let ours = NSApp.windows.map {
                    "#\($0.windowNumber) visible=\($0.isVisible) "
                        + "sharing=\($0.sharingType.rawValue) frame=\($0.frame)"
                }.joined(separator: " | ")
                // Full dump. Every inference so far has been wrong; this
                // says exactly what the capture API can see and who owns it.
                let mypid = ProcessInfo.processInfo.processIdentifier
                let dump = (content?.windows ?? []).map { w in
                    let app = w.owningApplication
                    return "  id=\(w.windowID) pid=\(app?.processID ?? -1)"
                        + " bundle=\(app?.bundleIdentifier ?? "?")"
                        + " onScreen=\(w.isOnScreen) frame=\(w.frame)"
                }.joined(separator: "\n")
                Screenshot.note("our pid=\(mypid) windowNumber=\(id)\nvisible windows:\n\(dump)")

                let msg = "window \(id) never became visible to the capture API. "
                    + "Capture API sees \(seen) windows owned by [\(owners)]; "
                    + "a short, system-only list means this build lacks the Screen "
                    + "Recording grant — see the header of tools/screenshot.sh.\n"
                    + "Our windows: \(ours)\n"
                Screenshot.note(msg)
                return
            }
            // A sheet is its own window, so a single-window filter composited
            // it in flat: no shadow, no rounded edge, wrong against the parent.
            // Filtering the display down to this app instead captures every
            // window we own, each with its real chrome, and leaves everything
            // else out.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            let ourWindows = ours
            let display = content.displays.first {
                $0.frame.intersects(target.frame)
            } ?? content.displays.first

            let filter: SCContentFilter
            var region: CGRect?
            if let display, let me = content.applications.first(where: {
                $0.processID == mypid
            }) {
                filter = SCContentFilter(display: display,
                                         including: [me],
                                         exceptingWindows: [])
                // Union of the target and whatever is presented OVER it —
                // sheets overlap their parent, a status item in the menu bar
                // does not. Unioning everything the process owns stretched the
                // crop from 1140x860 to 2174x1720 to take in a 38x34 window up
                // by the clock.
                let overlapping = ourWindows.filter {
                    $0.frame.intersects(target.frame) || $0.windowID == target.windowID
                }
                let union = overlapping.dropFirst().reduce(
                    overlapping.first?.frame ?? target.frame) { $0.union($1.frame) }
                region = union.insetBy(dx: -70, dy: -70)
                    .intersection(CGRect(origin: .zero, size: display.frame.size))
            } else {
                filter = SCContentFilter(desktopIndependentWindow: target)
            }

            let cfg = SCStreamConfiguration()
            // Ask for exactly the native pixel size. A hardcoded 2x here
            // upscaled the render on any display that is not 2x, which is what
            // made every screenshot look soft. pointPixelScale is the display's
            // real ratio, so this is sharp on Retina and on a 1x monitor alike.
            let scale = CGFloat(filter.pointPixelScale)
            let rect = region ?? filter.contentRect
            if region != nil { cfg.sourceRect = rect }
            cfg.width = Int((rect.width * scale).rounded())
            cfg.height = Int((rect.height * scale).rounded())
            cfg.showsCursor = false
            cfg.scalesToFit = false
            cfg.backgroundColor = .clear
            let shot = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
            guard let png = NSBitmapImageRep(cgImage: shot)
                    .representation(using: .png, properties: [:]) else { return }
            try png.write(to: URL(fileURLWithPath: path))
            Screenshot.note("wrote \(path) (\(shot.width)x\(shot.height))")
            // A sheet's modal session refuses NSApp.terminate, which left the
            // watchdog to kill a run that had already succeeded. The file is
            // written and flushed, so leave now.
            exit(0)
        } catch {
            // Not necessarily a permission problem, so do not assert one.
            let msg = """
            capture failed: \(error.localizedDescription)
            If that reads as a permission problem, add Runbranch.app under
            System Settings > Privacy & Security > Screen Recording.

            """
            Screenshot.note(msg)
        }
    }
}

/// Reports what the app actually managed to do, then exits.
///
/// The two bugs that nearly shipped were both in this layer and neither was
/// found by looking for it: a health indicator that never updated because the
/// view did not observe its monitor, and a duplicate window at every launch.
/// Both are one assertion each — if you can ask the running app how many
/// windows it has and whether health resolved.
///
/// Deliberately does not activate. A test that steals focus is a test nobody
/// runs while working.
enum SelfTest {
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("--selftest")
    }

    /// `key <TAB> value` per line, for a shell test to assert on.
    ///
    /// Written to RB_SELFTEST_OUT when set, because the app has to be launched
    /// through `open` to reliably get a window and `open` does not give the
    /// caller its stdout.
    static func report(_ pairs: [(String, String)]) {
        // One line per field, tab-separated, so a value carrying either would
        // silently invent a field. Screen-read text is arbitrary by nature.
        let text = pairs.map { pair -> String in
            let v = pair.1.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            return "\(pair.0)\t\(v)"
        }.joined(separator: "\n") + "\n"
        FileHandle.standardOutput.write(text.data(using: .utf8)!)
        if let out = ProcessInfo.processInfo.environment["RB_SELFTEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// What the window actually has on it, read back off the screen.
    ///
    /// Every other field in this report asks the app what it thinks. The bug
    /// this suite exists for was one where the app thought correctly and drew
    /// something else: a healthy run read "starting" indefinitely because the
    /// strip held its monitor as a plain property and never subscribed. The
    /// monitor was right the whole time. Only the pixels disagreed, so only
    /// the pixels can catch it.
    ///
    /// Returns nil when it could not read the screen — most often a missing
    /// Screen Recording grant, which is per-signature and so absent on a fresh
    /// build. That is reported as its own field rather than failing, because a
    /// suite that treats "could not look" as "looks right" is worse than one
    /// that admits it did not look.
    /// Why it could not look, when it could not. Five different causes used to
    /// arrive as one nil, which made a skipping suite impossible to diagnose —
    /// the first time it skipped, nothing said whether the permission was gone
    /// or the window was simply not where it was expected.
    @MainActor
    static func readScreen() async -> (lines: [String]?, why: String) {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.parent == nil && $0.frame.width > 200
        }) else {
            let seen = NSApp.windows.map {
                "visible=\($0.isVisible) child=\($0.parent != nil) w=\(Int($0.frame.width))"
            }.joined(separator: "; ")
            return (nil, "no window of ours to read [\(seen)]")
        }
        // Absent this the window is on screen but missing from the capture
        // API's list entirely, which is indistinguishable from no permission.
        window.sharingType = .readOnly
        // Deliberately no ordering front, no activation, and no change of
        // collection behaviour. The read happens where the window already is.
        do {
            let mypid = ProcessInfo.processInfo.processIdentifier
            // onScreenWindowsOnly: false, and no isOnScreen filter below.
            //
            // A window belongs to one Space and the capture API calls a window
            // on any other Space off-screen. The test launches the app in the
            // background on purpose, so the active Space is not ours to
            // predict — a fullscreen app's Space excludes our window outright.
            // The documentation path solves that by fronting the window and
            // activating the app, which is exactly what this must not do.
            //
            // A desktop-independent filter renders the window's own content
            // rather than a region of the display, so it does not need the
            // window to be on the active Space at all. Asking for off-screen
            // windows too is what lets us find it in the first place.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let target = content.windows.filter({
                $0.owningApplication?.processID == mypid && $0.frame.width > 200
            }).max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else {
                // A granted call lists every on-screen window on the machine.
                // A short list owned only by system processes means the grant
                // is missing rather than the window being absent.
                // Name the owners rather than counting them. A guess from the
                // count read "not on screen" for what was a missing grant just
                // as readily as the other way round, and the names settle it:
                // a list of only system processes means no grant.
                let owners = Set(content.windows.compactMap {
                    $0.owningApplication?.applicationName
                }).sorted().joined(separator: ", ")
                return (nil, "capture API sees \(content.windows.count) windows, "
                    + "none of them ours, owned by [\(owners)] — if that is only "
                    + "system processes it is a missing Screen Recording grant")
            }

            // The window on its own, not the documentation path's union with
            // whatever is presented over it. This wants legible text, not
            // correct chrome.
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int((target.frame.width * scale).rounded())
            cfg.height = Int((target.frame.height * scale).rounded())
            cfg.showsCursor = false
            cfg.scalesToFit = false
            let shot = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // These are labels, not prose. Correction rewrites "feat/checkout"
            // into words that were never on the screen.
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: shot, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap {
                $0.topCandidates(1).first?.string
            }
            if lines.isEmpty {
                return (nil, "read a \(shot.width)x\(shot.height) image with no text in it")
            }
            return (lines, "")
        } catch {
            return (nil, "capture failed: \(error.localizedDescription)")
        }
    }

    /// Nothing here should take 20 seconds. If it does, that is the finding.
    static func armWatchdog() {
        Task.detached {
            try? await Task.sleep(for: .seconds(20))
            FileHandle.standardError.write("selftest timed out\n".data(using: .utf8)!)
            exit(3)
        }
    }
}

