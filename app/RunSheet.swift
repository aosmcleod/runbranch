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
    /// Pinned to the tail, until you jump to an error.
    ///
    /// This was a button, and it read as a download glyph that did nothing —
    /// fairly, since it is on by default and the tail is where you already
    /// are. It only ever needed to be off for one reason, which is that
    /// jumping somewhere while pinned scrolls straight back.
    @State private var following = true

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
                filterField
                controlGroup
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                // Vertical only. Lines wrap; there is no longer a mode where
                // they run off the side, which also retires the horizontal
                // axis that kept fighting maxWidth: .infinity children.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(line.isError
                                                 ? AnyShapeStyle(Color.red)
                                                 : AnyShapeStyle(.primary))
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                    guard following, let last else { return }
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
                    // Unpin first, or the next poll scrolls straight back to
                    // the tail and the error you jumped to is gone again.
                    following = false
                    withAnimation { proxy.scrollTo(row, anchor: .center) }
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

    /// The rounded search field and the grouped button capsule from the main
    /// window, rebuilt by hand.
    ///
    /// In the main window neither is styled by anyone: macOS draws them,
    /// because they are a `.searchable(placement: .toolbar)` and a
    /// `ToolbarItemGroup`. A sheet has no window toolbar, so neither is
    /// available here — and a plain HStack of `.bordered` buttons next to a
    /// `.roundedBorder` field is exactly the flat, square result you would
    /// expect.
    ///
    /// Putting the sheet in a NavigationStack does get a real toolbar, and it
    /// did draw a proper rounded search field — but the ToolbarItemGroup
    /// buttons never appeared and the title landed loose in the content area,
    /// which was worse than this. So: the same shapes, built here.
    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 92)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    /// One capsule, two buttons, a hairline between them.
    private var controlGroup: some View {
        HStack(spacing: 0) {
            groupButton("exclamationmark.magnifyingglass",
                        help: errorLines.isEmpty ? "No errors in this log"
                                                 : "Jump to the first error",
                        disabled: errorLines.isEmpty) {
                jumpTarget = errorLines.first?.id
            }
            Divider().frame(height: 14)
            groupButton("folder", help: "Reveal in Finder") {
                NSWorkspace.shared.selectFile("\(logDir)/\(selected).log",
                                              inFileViewerRootedAtPath: logDir)
            }
        }
        .background(.quaternary, in: Capsule())
    }

    private func groupButton(_ symbol: String, help: String,
                             disabled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                // A fixed box, so a wide symbol and a narrow one take the same
                // room and the capsule stays even.
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
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
