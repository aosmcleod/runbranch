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

    @State private var selected: String = ""
    @State private var lines: [Line] = []
    @State private var nextID = 0
    /// How much of the file has been consumed. The point of the whole
    /// rewrite: re-reading, de-ANSI-ing and re-splitting the entire log every
    /// 1.5 seconds cost 22ms at 1 MB, 50ms at 4 MB and 198ms at 16 MB — a
    /// visible hitch on a chatty dev server, on the main thread, forever.
    @State private var offset: UInt64 = 0
    @State private var filter = ""
    @State private var timer: Timer?
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
            HStack(spacing: 10) {
                if targets.count > 1 {
                    Picker("", selection: $selected) {
                        ForEach(targets) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
                Spacer()
                controls
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
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
                .onChange(of: lines.last?.id) { _, last in
                    guard follow, let last else { return }
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
                // Jumping while pinned to the tail scrolls straight back, so
                // unpin first. Following is what you want while waiting and
                // exactly not what you want while reading.
                .onChange(of: jumpTarget) { _, row in
                    guard let row else { return }
                    follow = false
                    withAnimation { proxy.scrollTo(row, anchor: .center) }
                    jumpTarget = nil
                }
            }

            Divider()
            HStack(spacing: 8) {
                Text("\(shown.count) lines")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !errorLines.isEmpty {
                    Text("· \(errorLines.count) matching error")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 680, height: 460)
        .onAppear {
            selected = targets.first?.name ?? ""
            load()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in load() }
        }
        .onDisappear { timer?.invalidate() }
        .onChange(of: selected) { _, _ in reset(); load() }
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

    @ViewBuilder
    private var controls: some View {
        Button {
            jumpTarget = errorLines.first?.id
        } label: { Image(systemName: "exclamationmark.magnifyingglass") }
            .disabled(errorLines.isEmpty)
            .help(errorLines.isEmpty ? "No errors in this log" : "Jump to the first error")
        Toggle(isOn: $wrap) { Image(systemName: "text.word.spacing") }
            .toggleStyle(.button)
            .help(wrap ? "Wrapping long lines" : "Long lines scroll sideways")
        Toggle(isOn: $follow) { Image(systemName: "arrow.down.to.line") }
            .toggleStyle(.button)
            .help(follow ? "Following new output" : "Not following — new output does not scroll")
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"),
                                           forType: .string)
        } label: { Image(systemName: "doc.on.doc") }
            .help("Copy what is on screen")
        Button {
            NSWorkspace.shared.selectFile("\(logDir)/\(selected).log",
                                          inFileViewerRootedAtPath: logDir)
        } label: { Image(systemName: "folder") }
            .help("Reveal in Finder")
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

        for line in fresh {
            lines.append(Line(id: nextID, text: line, isError: Self.looksLikeError(line)))
            nextID += 1
        }
        if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
    }
}
