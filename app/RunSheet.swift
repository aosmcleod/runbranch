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

// A run while it is happening: the streamed output, and reading it back.

import SwiftUI
import AppKit

/// Blocking sheet over the launcher. Closes itself when the demo comes up;
/// stays put when it does not, because that is the moment you need the log.
struct RunSheet: View {
    @ObservedObject var runner: Runner
    let title: String
    let onDone: () -> Void

    @State private var closing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !runner.finished {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: runner.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(runner.failed ? .red : .green)
                }
                Text(headline).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(runner.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: runner.lines.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }

            Divider()

            HStack {
                if runner.failed {
                    Button("Copy log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(runner.lines.joined(separator: "\n"), forType: .string)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                Spacer()
                if runner.finished {
                    Button("Close", action: onDone)
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Stop") { runner.cancel() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 620, height: 420)
        .onChange(of: runner.finished) { _, done in
            // Success needs no audience. Failure does.
            guard done, !runner.failed, !closing else { return }
            closing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onDone() }
        }
    }

    private var headline: String {
        if !runner.finished { return title }
        return runner.failed ? "\(title) — failed" : "\(title) — done"
    }
}

/// A live tail of one target's log. The engine already writes each target to
/// its own file; this just follows it.
struct LogViewer: View {
    let logDir: String
    let targets: [RunTarget]
    let onClose: () -> Void

    /// A line with an identity that survives the next tick.
    ///
    /// The list used to be `[String]` rendered through `Array(_:.enumerated())`,
    /// so every line's identity was its index and appending to the tail
    /// renumbered nothing but still rebuilt the pairs on every render.
    private struct Line: Identifiable {
        let id: Int
        let text: String
        let isError: Bool
    }

    @State private var selected: String

    init(logDir: String, targets: [RunTarget], onClose: @escaping () -> Void) {
        self.logDir = logDir
        self.targets = targets
        self.onClose = onClose
        // Valid on the FIRST layout pass, not the second.
        //
        // This was set in onAppear, so the first render had no selection at
        // all — and a segmented picker whose selection matches none of its
        // tags lays out at a different width. The header then reflowed a frame
        // later, the spacer between the filter field and the controls
        // recomputed, and every control slid across. Only visible on a project
        // with more than one target, which is why a one-target demo never
        // showed it.
        _selected = State(initialValue: targets.first?.name ?? "")
    }
    @State private var lines: [Line] = []
    @State private var nextID = 0
    /// How much of the file has been consumed. The point of the whole
    /// rewrite: re-reading, de-ANSI-ing and re-splitting the entire log every
    /// 1.5 seconds cost 22ms at 1 MB, 50ms at 4 MB and 198ms at 16 MB — a
    /// visible hitch on a chatty dev server, on the main thread, forever.
    @State private var offset: UInt64 = 0
    @State private var filter = ""
    @State private var jumpTarget: Int?
    /// Both persisted: which way you like to read a log does not change
    /// between runs, and having them reset every time makes them not worth
    /// setting.
    @AppStorage("logs.follow") private var follow = true
    @AppStorage("logs.wrap") private var wrap = true

    /// Retained lines. 250,000 lines measured at 36.6 MB, which would more
    /// than double the app's whole footprint to hold output nobody scrolls
    /// back to. The file keeps everything; Reveal in Finder is right there.
    private static let keep = 5_000
    /// How far back to start when opening a log that is already large. Reading
    /// 16 MB to show the last screenful is work for its own sake.
    private static let tailCap: UInt64 = 256 * 1024

    private var shown: [Line] {
        filter.isEmpty ? lines : lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    /// Lines worth jumping to.
    ///
    /// Deliberately broad, and it will match a line that only mentions the
    /// word — "0 errors" included. A viewer that misses the error you opened
    /// it for is worse than one that occasionally offers a line you did not
    /// need, and every framework spells this differently.
    private static func looksLikeError(_ line: String) -> Bool {
        let l = line.lowercased()
        for needle in ["error", "exception", "failed", "failure", "fatal",
                       "traceback", "panic:", "econnrefused", "eaddrinuse"] {
            if l.contains(needle) { return true }
        }
        return false
    }

    private var errorLines: [Line] { shown.filter(\.isError) }

    var body: some View {
        VStack(spacing: 0) {
            // Titled, like every other sheet in the app. This was a bare
            // strip of controls with no title at all, which is most of why it
            // read as foreign — and the buttons were `.bordered` while every
            // other button here is glass.
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Logs").font(.system(size: 14, weight: .semibold))
                    // The target's name, unless the picker below is already
                    // showing it.
                    Text(targets.count > 1 || selected.isEmpty ? " " : selected)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if targets.count > 1 {
                    Picker("", selection: $selected) {
                        ForEach(targets) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
                Spacer(minLength: 8)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                HStack(spacing: 8) { controls }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                // The horizontal axis only when lines are not wrapping.
                //
                // Enabling it unconditionally seemed tidier — it keeps the
                // view's identity stable across a wrap toggle — but a
                // horizontal axis and children asking for maxWidth: .infinity
                // are contradictory instructions. The lines wrapped at a width
                // of SwiftUI's choosing, the content came out wider than the
                // sheet, and every line sat indented halfway across it.
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(wrap ? nil : 1)
                                // Without this an unwrapped line is truncated
                                // to the viewport instead of making the
                                // content wide enough to scroll.
                                .fixedSize(horizontal: !wrap, vertical: false)
                                .foregroundStyle(line.isError
                                                 ? AnyShapeStyle(Color.red)
                                                 : AnyShapeStyle(.primary))
                                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                // Flexible rather than ideal-driven, so the content's width
                // can never reach the frame at the end of this view and the
                // sheet's size is decided in one place. Belt and braces: the
                // sheet was measured opening at 680x460 and staying there, so
                // this is not fixing an observed resize.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: lines.last?.id) { _, last in
                    guard follow, let last else { return }
                    // Bottom LEFT, not `.bottom`. `.bottom` is (0.5, 1) and
                    // the x half of it matters now that this scroll view has
                    // a horizontal axis: following the tail scrolled the log
                    // to horizontally centred, so every line sat indented
                    // halfway across the sheet.
                    withAnimation { proxy.scrollTo(last, anchor: .bottomLeading) }
                }
                // Jumping while pinned to the tail scrolls straight back, so
                // unpin first. Following is what you want while waiting and
                // exactly not what you want while reading.
                .onChange(of: jumpTarget) { _, row in
                    guard let row else { return }
                    follow = false
                    // Vertically centred, horizontally at the start, for the
                    // same reason as above.
                    withAnimation { proxy.scrollTo(row, anchor: UnitPoint(x: 0, y: 0.5)) }
                    jumpTarget = nil
                }
            }

            Divider()
            HStack(spacing: 8) {
                // Both fixed and always present. The count grew from "0 lines"
                // as the first read landed and the error tally appeared from
                // nothing, so the footer reflowed a beat after the sheet
                // opened.
                Text("\(shown.count) lines")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(errorLines.isEmpty ? " "
                     : "· \(errorLines.count) matching error")
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .frame(width: 150, alignment: .leading)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 680, height: 460)
        // Nothing touches the disk until the sheet has finished presenting.
        //
        // This was an .onAppear that read the log synchronously — open, seek,
        // read, a regex over the chunk, then build a Line per row — and
        // started a run-loop Timer, all on the main thread while the sheet was
        // animating in. That is what "the log appears and then the buttons fly
        // in" was: the content won the race for the first frame and the
        // chrome lost it. Ports and Disk do no work on appear and neither of
        // them does this.
        //
        // .task rather than .onAppear so it is off the presentation entirely,
        // keyed on the target so switching restarts it, and cancelled on
        // dismissal for free — which also retires the Timer.
        .task(id: selected) {
            try? await Task.sleep(for: .milliseconds(200))
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
        .onChange(of: selected) { _, _ in reset() }
        // Opened before the run state had loaded, this had no targets to pick
        // from and nothing ever went back for them: `selected` stayed empty,
        // `load` returned at its own guard, and the viewer sat at "0 lines"
        // over a log file with plenty in it.
        .onChange(of: targets.map(\.name).joined(separator: ",")) { _, _ in
            guard selected.isEmpty || !targets.contains(where: { $0.name == selected })
            else { return }
            selected = targets.first?.name ?? ""
            reset()
            load()
        }
    }

    /// One control, so five of them match.
    ///
    /// Two were `Toggle(.button)`, which fills with the accent colour when on.
    /// Both default to on, so the row opened with two buttons lit up as though
    /// something wanted attention — and the accent belongs to a state that is
    /// NOT the default, which is how the filter glyph in the main toolbar uses
    /// it. `Toggle(.button)` also pads differently from `Button`, and SF
    /// Symbols have different intrinsic widths, so five controls that should
    /// have matched were three sizes.
    ///
    /// State is the glyph's prominence now: on is the ordinary colour, off is
    /// dimmed. The fixed box is what keeps a wide symbol and a narrow one the
    /// same size.
    private func iconButton(_ symbol: String, help: String,
                            off: Bool = false, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(width: 15, height: 15)
        }
        // Not glass, and not GlassEffectContainer either.
        //
        // Both were tried, and glass in this header did two unwanted things:
        // it did not actually render as glass — it came out as a flat dark
        // chip — and the header stopped being painted on the sheet's first
        // frames, so the log appeared and the whole control row arrived after
        // it. The header's LAYOUT was measured as stable throughout (one
        // geometry event, 680x56, never changing), so what was late was the
        // drawing, not the position.
        //
        // The other sheets' headers are plain and none of them do this.
        .buttonStyle(.bordered)
        .disabled(disabled)
        .help(help)
    }

    @ViewBuilder
    private var controls: some View {
        iconButton("exclamationmark.magnifyingglass",
                   help: errorLines.isEmpty ? "No errors in this log"
                                            : "Jump to the first error",
                   disabled: errorLines.isEmpty) {
            jumpTarget = errorLines.first?.id
        }
        iconButton("text.word.spacing",
                   help: wrap ? "Wrapping long lines" : "Long lines scroll sideways",
                   off: !wrap) { wrap.toggle() }
        iconButton("arrow.down.to.line",
                   help: follow ? "Following new output"
                                : "Not following — new output does not scroll",
                   off: !follow) { follow.toggle() }
        iconButton("doc.on.doc", help: "Copy what is on screen") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"),
                                           forType: .string)
        }
        iconButton("folder", help: "Reveal in Finder") {
            NSWorkspace.shared.selectFile("\(logDir)/\(selected).log",
                                          inFileViewerRootedAtPath: logDir)
        }
    }

    private func reset() {
        lines = []; offset = 0; nextID = 0
    }

    /// Read whatever has been appended since last time.
    private func load() {
        guard !selected.isEmpty else { return }
        let path = "\(logDir)/\(selected).log"
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }

        // A run restarts by truncating its log, so a file shorter than what we
        // have already read is a new log rather than a shrinking one.
        if size < offset { reset() }
        var from = offset
        var skipPartialFirstLine = false
        if from == 0 && size > Self.tailCap {
            from = size - Self.tailCap
            skipPartialFirstLine = true
        }
        guard size > from else { return }

        try? handle.seek(toOffset: from)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }

        // Stop at the last newline. A tick can land mid-line, and half a line
        // committed now is a wrong line forever — the rest arrives next tick
        // and would start its own.
        guard let lastBreak = chunk.lastIndex(of: 0x0A) else { return }
        let complete = chunk[chunk.startIndex...lastBreak]
        offset = from + UInt64(complete.count)

        guard var text = String(data: Data(complete), encoding: .utf8) else { return }
        text = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)

        var fresh = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Seeking into the middle of the file lands mid-line by definition.
        if skipPartialFirstLine && !fresh.isEmpty { fresh.removeFirst() }
        guard !fresh.isEmpty else { return }

        // Explicitly unanimated.
        //
        // The first read lands while the sheet is still presenting, so its
        // layout consequences were picked up by the presentation's animation —
        // the jump-to-error button going from disabled to enabled, the counts
        // in the footer. That is what "the log appears and then the buttons
        // fly in" was: not the sheet resizing, but the header being animated
        // into place a frame after the content.
        withTransaction(Transaction(animation: nil)) {
            for line in fresh {
                lines.append(Line(id: nextID, text: line,
                                  isError: Self.looksLikeError(line)))
                nextID += 1
            }
            if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
        }
    }
}
