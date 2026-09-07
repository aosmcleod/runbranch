// RunBranch — the front end. All the work happens in runbranch.sh;
// this is a window over it. Projects are declared in projects/*.conf and the
// app knows nothing about any of them beyond what the engine reports.
//
// Why a compiled app rather than osascript dialogs: NSAlert cannot be made to
// look like anything but NSAlert. It picks up desktop translucency, it shows
// the interpreter's icon rather than ours, and it stacks buttons vertically
// past two. It also cannot show progress, which meant handing off to
// Terminal.app over Apple Events — a permission the bundle does not have, so a
// launch could fail silently. Running the script as a subprocess and streaming
// it into this window removes that whole class of failure.

import SwiftUI
import AppKit
import ScreenCaptureKit

// MARK: - Model

struct Branch: Identifiable, Hashable {
    let ref: String
    let age: String
    let timestamp: Int
    let owner: String
    let mine: Bool
    let pr: PRState
    let ready: Bool
    let isDefault: Bool
    let isCurrent: Bool
    let prNumber: String
    /// The pull request title, or the tip commit's subject when there is none.
    let subject: String
    let isRemote: Bool

    var id: String { ref }
    var display: String { isRemote ? String(ref.dropFirst("origin/".count)) : ref }

    /// `ref age ts owner mine pr ready isDefault isCurrent`, tab separated.
    init?(tsv line: String) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 9 else { return nil }
        ref = f[0]
        age = f[1]
        timestamp = Int(f[2]) ?? 0
        owner = f[3]
        mine = f[4] == "1"
        pr = PRState(raw: f[5])
        ready = f[6] == "1"
        isDefault = f[7] == "1"
        isCurrent = f[8] == "1"
        prNumber = f.count > 9 ? f[9] : ""
        subject = f.count > 10 ? f[10] : ""
        isRemote = f.count > 11 && f[11] == "1"
    }
}

enum PRState {
    case open, merged, closed, none

    init(raw: String) {
        switch raw {
        case "OPEN": self = .open
        case "MERGED": self = .merged
        case "CLOSED": self = .closed
        default: self = .none
        }
    }

    var label: String? {
        switch self {
        case .open: return "open"
        case .merged: return "merged"
        case .closed: return "closed"
        case .none: return nil
        }
    }

    // GitHub's own status colours, so the badges read the way the PR list does.
    var color: Color {
        switch self {
        case .open: return Color(red: 0.13, green: 0.65, blue: 0.31)
        case .merged: return Color(red: 0.64, green: 0.44, blue: 0.97)
        case .closed: return Color(red: 0.97, green: 0.32, blue: 0.29)
        case .none: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .open: return "arrow.triangle.pull"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark"
        case .none: return ""
        }
    }
}

/// A project the engine knows about. Presets are whatever its config declares,
/// so nothing here is specific to any one repo.
struct Project: Identifiable, Hashable {
    let id: String        // the .conf basename
    let name: String      // display name
    let repo: String

    /// Sidebar glyph, named by the project's own config. SF Symbols are fine
    /// here — the licence only bars them from the app icon.
    let symbol: String

    init?(tsv line: String) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 3 else { return nil }
        id = f[0]; name = f[1]; repo = f[2]
        symbol = f.count >= 5 && !f[4].isEmpty ? f[4] : "shippingbox"
    }
}

/// One server inside a run.
struct RunTarget: Identifiable, Hashable {
    let name: String
    let port: Int
    let health: String
    let pid: Int
    let alive: Bool

    var id: String { name }
    var url: URL? { URL(string: "http://localhost:\(port)") }
    var healthURL: URL? { URL(string: "http://localhost:\(port)\(health.isEmpty ? "/" : health)") }
}

/// What the engine says is running for one project.
struct RunState {
    var running = false
    var ref = ""
    var preset = ""
    var started = ""
    var epoch: TimeInterval = 0
    var worktree = ""
    var targets: [RunTarget] = []

    static let idle = RunState()

    init() {}

    /// One `run` line then one `target` line each; `idle` on its own when not.
    init(output: String) {
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let f = line.components(separatedBy: "\t")
            switch f.first {
            case "run" where f.count >= 6:
                running = true
                ref = f[1]; preset = f[2]; started = f[3]
                epoch = TimeInterval(f[4]) ?? 0
                worktree = f[5]
            case "target" where f.count >= 6:
                targets.append(RunTarget(name: f[1],
                                         port: Int(f[2]) ?? 0,
                                         health: f[3],
                                         pid: Int(f[4]) ?? 0,
                                         alive: f[5] == "1"))
            default: break
            }
        }
    }

    var urls: [URL] { targets.compactMap(\.url) }
}

// MARK: - Engine

/// Runs frankly-launcher.sh. Always through a login+interactive zsh: an app
/// launched from the Dock inherits launchd's PATH, which has neither docker
/// (/usr/local/bin) nor pnpm (/opt/homebrew/bin) nor node (fnm mints its bin
/// directory per shell session), and the script would report them all missing.
enum Engine {
    static var scriptPath: String {
        if let p = Bundle.main.object(forInfoDictionaryKey: "FLScriptPath") as? String,
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return NSHomeDirectory() + "/Development/runbranch/runbranch.sh"
    }

    static func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "exec \"$0\" \"$@\"", scriptPath] + args
        return p
    }

    /// Blocking. Used for the short reads (branch list, state).
    static func capture(_ args: [String]) -> (out: String, code: Int32) {
        let p = process(args)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    static func projects() -> [Project] {
        capture(["projects"]).out
            .components(separatedBy: "\n")
            .compactMap { $0.isEmpty ? nil : Project(tsv: $0) }
    }

    static func branches(_ project: String) -> [Branch] {
        capture(["branches", project]).out
            .components(separatedBy: "\n")
            .compactMap { $0.isEmpty ? nil : Branch(tsv: $0) }
    }

    static func presets(_ project: String) -> [String] {
        capture(["presets", project]).out
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    /// Where the engine keeps things for a project:
    /// worktrees, logs, config, repo, and optionally one branch's worktree.
    static func paths(_ project: String, ref: String? = nil) -> [String] {
        var args = ["paths", project]
        if let ref { args.append(ref) }
        return capture(args).out
            .components(separatedBy: "\n").first?
            .components(separatedBy: "\t") ?? []
    }

    static var projectsDir: String {
        (scriptPath as NSString).deletingLastPathComponent + "/projects"
    }

    static func state(_ project: String) -> RunState {
        RunState(output: capture(["state", project]).out)
    }

    @discardableResult
    static func reclaim() -> String { capture(["reclaim"]).out }

    /// Reads a repo, writes a proposed config, returns (name, file).
    static func add(_ repoPath: String) -> (name: String, file: String)? {
        let r = capture(["add", repoPath])
        guard r.code == 0 else { return nil }
        let f = r.out.components(separatedBy: "\n").first?.components(separatedBy: "\t") ?? []
        guard f.count >= 2 else { return nil }
        return (f[0], f[1])
    }

    /// Every editable field of a project. TARGETS arrives with \u{1}
    /// separating its lines, since it is the one multi-line value.
    static func get(_ project: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in capture(["get", project]).out.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            out[parts[0]] = parts.dropFirst().joined(separator: "\t")
                .replacingOccurrences(of: "\u{1}", with: "\n")
        }
        return out
    }

    /// Writes one key. Returns nil on success, or what went wrong.
    static func set(_ project: String, _ key: String, _ value: String) -> String? {
        let wire = value.replacingOccurrences(of: "\n", with: "\u{1}")
        let p = process(["set", project, key, wire])
        let err = Pipe()
        p.standardOutput = Pipe()
        p.standardError = err
        do { try p.run() } catch { return "could not run the engine" }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let msg = String(data: data, encoding: .utf8) ?? ""
        return msg.isEmpty ? "writing \(key) failed" : msg
    }

    /// Whether a command resolves in the user's login shell — which is not the
    /// same as this process's PATH.
    static func hasCommand(_ name: String) -> Bool {
        if let cached = commandCache[name] { return cached }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v \(name) >/dev/null 2>&1"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let found = p.terminationStatus == 0
        commandCache[name] = found
        return found
    }
    private nonisolated(unsafe) static var commandCache: [String: Bool] = [:]
}

/// Streams a run into the sheet, one line at a time.
final class Runner: ObservableObject {
    @Published var lines: [String] = []
    @Published var finished = false
    @Published var failed = false

    private var proc: Process?

    var isRunning: Bool { proc?.isRunning ?? false }

    func start(_ args: [String]) {
        lines = []
        finished = false
        failed = false

        let p = Engine.process(args)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        proc = p

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            // Strip the ANSI colour the script emits for terminals.
            let clean = chunk.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            DispatchQueue.main.async {
                for line in clean.components(separatedBy: "\n") where !line.isEmpty {
                    self?.lines.append(line)
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.finished = true
                self?.failed = proc.terminationStatus != 0
            }
        }

        do { try p.run() } catch {
            lines.append("Could not start \(Engine.scriptPath)")
            finished = true
            failed = true
        }
    }

    func cancel() { proc?.terminate() }
}

/// Polls each target's health URL. Health is a fact to be checked, not
/// something to assume because a process is still alive — a server can be up
/// and answering 500s.
@MainActor
final class HealthMonitor: ObservableObject {
    enum Health { case unknown, starting, healthy, failing }

    @Published var status: [String: Health] = [:]
    private var timer: Timer?
    private var targets: [RunTarget] = []

    func watch(_ targets: [RunTarget]) {
        self.targets = targets
        timer?.invalidate()
        guard !targets.isEmpty else { status = [:]; return }
        for t in targets where status[t.name] == nil { status[t.name] = .unknown }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; status = [:]; targets = [] }

    private func poll() {
        for t in targets {
            guard t.alive, let url = t.healthURL else {
                status[t.name] = .failing
                continue
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            req.httpMethod = "GET"
            URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
                Task { @MainActor in
                    guard let self else { return }
                    if error != nil {
                        // Not answering yet is not the same as broken.
                        self.status[t.name] = self.status[t.name] == .healthy ? .failing : .starting
                    } else if let http = response as? HTTPURLResponse {
                        self.status[t.name] = http.statusCode < 500 ? .healthy : .failing
                    }
                }
            }.resume()
        }
    }
}

extension HealthMonitor.Health {
    var color: Color {
        switch self {
        case .healthy: return .green
        case .starting: return .orange
        case .failing: return .red
        case .unknown: return .secondary
        }
    }
    var label: String {
        switch self {
        case .healthy: return "healthy"
        case .starting: return "starting"
        case .failing: return "not responding"
        case .unknown: return "unknown"
        }
    }
}

/// Editors we can offer, in the order most people would want them. Only the
/// ones actually installed are shown — a menu full of things you do not have
/// is worse than a short menu.
enum Editor: CaseIterable {
    case vscode, cursor, zed, xcode, claudeCode, terminal, finder

    var title: String {
        switch self {
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .xcode: return "Xcode"
        case .claudeCode: return "Claude Code"
        case .terminal: return "Terminal"
        case .finder: return "Finder"
        }
    }

    var bundleID: String? {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .zed: return "dev.zed.Zed"
        case .xcode: return "com.apple.dt.Xcode"
        // Claude Code is a CLI, so it opens a Terminal sitting in the worktree.
        // Claude.app declares a claude:// scheme but the format for opening a
        // directory is not documented, and guessing at one is how you ship a
        // menu item that silently does nothing.
        case .claudeCode: return "com.apple.Terminal"
        case .terminal: return "com.apple.Terminal"
        case .finder: return nil          // always there
        }
    }

    var isInstalled: Bool {
        if case .claudeCode = self { return Engine.hasCommand("claude") }
        guard let id = bundleID else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    func open(_ path: String) {
        if case .claudeCode = self {
            let script = """
            tell application "Terminal"
              do script "cd \(path.replacingOccurrences(of: "\"", with: "\\\"")) && claude"
              activate
            end tell
            """
            if let s = NSAppleScript(source: script) { s.executeAndReturnError(nil) }
            return
        }
        let dir = URL(fileURLWithPath: path)
        guard let id = bundleID else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Small views

struct Badge: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .secondary
    /// A selected row is painted in the accent colour, so a badge that paints
    /// itself the accent colour disappears into it — which is exactly what
    /// happened to `default`. On selection every badge drops its own colour
    /// and becomes translucent white, which reads against any accent the user
    /// has chosen, including the ones we cannot predict.
    var onSelection: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol, !symbol.isEmpty {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(onSelection ? AnyShapeStyle(.white) : AnyShapeStyle(color))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(onSelection ? Color.white.opacity(0.22) : color.opacity(0.14),
                    in: Capsule())
    }
}

/// The run's status, as one glass bar.
///
/// An earlier version copied Stocks' stats grid literally — a column of
/// 9pt uppercase labels over values. At that size, in tertiary, the labels
/// were unreadable, and four of them turned a status line into a form. What
/// actually matters is one sentence (how it is, how long) and the things you
/// might click. So: no labels, and the clickable parts look clickable.
struct RunStrip: View {
    let state: RunState
    let health: HealthMonitor
    let epoch: TimeInterval

    static func elapsed(since epoch: TimeInterval, now: Date) -> String {
        guard epoch > 0 else { return "—" }
        let s = max(0, Int(now.timeIntervalSince1970 - epoch))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private var worst: HealthMonitor.Health {
        let all = state.targets.compactMap { health.status[$0.name] }
        if all.contains(.failing) { return .failing }
        if all.contains(.starting) || all.isEmpty { return .starting }
        return all.allSatisfy { $0 == .healthy } ? .healthy : .starting
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(worst.color)
                .frame(width: 8, height: 8)
                .shadow(color: worst.color.opacity(0.7), radius: 3)

            Text(worst.label.capitalized)
                .font(.system(size: 13, weight: .medium))

            // TimelineView keeps the tick inside this label. Driving it from
            // ContentView re-rendered the whole detail every second, which
            // rebuilt the toolbar menus and dismissed any open submenu.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.elapsed(since: epoch, now: ctx.date))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            // A label, not a button: Open already opens it, and two ways to do
            // one thing is worse than one obvious way.
            ForEach(state.targets) { t in
                Text("localhost:\(String(t.port))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(t.name)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct BranchRow: View {
    let branch: Branch
    let isLive: Bool
    /// Reserve the leading slot whenever ANY demo is up, so branch names stay
    /// on one vertical line instead of the live row shunting itself sideways.
    let showGutter: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showGutter {
                ZStack {
                    if isLive { ProgressView().controlSize(.small) }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if branch.isRemote {
                        Image(systemName: "cloud")
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8))
                                                        : AnyShapeStyle(.tertiary))
                            .help("Remote branch — selecting it builds a worktree at its tip")
                    }
                    Text(branch.display)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if branch.isDefault {
                        Badge(text: "default", color: .accentColor, onSelection: isSelected)
                    } else if let l = branch.pr.label {
                        Badge(text: l, symbol: branch.pr.symbol, color: branch.pr.color, onSelection: isSelected)
                    }
                    Badge(text: branch.owner, onSelection: isSelected)
                    if !isLive && branch.ready {
                        Badge(text: "ready", symbol: "bolt.fill", color: .green, onSelection: isSelected)
                    }
                }

                // What the work actually is. A branch name is what someone
                // called it; this is what it does.
                if !branch.subject.isEmpty {
                    Text(branch.subject)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            Text(branch.age)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 1)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Run sheet

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

    @State private var selected: String = ""
    @State private var lines: [String] = []
    @State private var filter = ""
    @State private var timer: Timer?

    private var shown: [String] {
        filter.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if targets.count > 1 {
                    Picker("", selection: $selected) {
                        ForEach(targets) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy log")
                Button {
                    NSWorkspace.shared.selectFile("\(logDir)/\(selected).log",
                                                  inFileViewerRootedAtPath: logDir)
                } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: shown.count) { _, n in
                    withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }

            Divider()
            HStack {
                Text("\(shown.count) lines").font(.system(size: 11)).foregroundStyle(.secondary)
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
        .onChange(of: selected) { _, _ in lines = []; load() }
    }

    private func load() {
        guard !selected.isEmpty else { return }
        let path = "\(logDir)/\(selected).log"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let clean = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        lines = clean.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}

/// Everything the detail pane needs for one project, as a single value.
///
/// It used to be six separate @State vars assigned at different moments —
/// branches from cache synchronously, run state only when the engine replied —
/// so mid-switch the window showed one project's branches beside another's
/// status bar, title and subtitle. Snapshots are swapped whole, and the pane
/// refuses to draw one whose id is not the selected project, so a mismatch
/// cannot be represented rather than merely being unlikely.
struct ProjectSnapshot {
    let id: String
    var branches: [Branch] = []
    var presets: [String] = []
    var state: RunState = .idle
    var paths: [String] = []

    var logDir: String { paths.count >= 2 ? paths[1] : "" }

    static func load(_ id: String) -> ProjectSnapshot {
        ProjectSnapshot(id: id,
                        branches: Engine.branches(id),
                        presets: Engine.presets(id),
                        state: Engine.state(id),
                        paths: Engine.paths(id))
    }
}

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
        defer { NSApp.terminate(nil) }
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first
        else { return }

        // A window belongs to one Space, and a fullscreen app's Space excludes
        // it — which is why every earlier capture caught whatever was
        // fullscreen instead. This was the real cause, not the capture API.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        if let screen = NSScreen.main {
            let size = NSSize(width: 1000, height: 620)
            let vf = screen.visibleFrame
            window.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(2.5))     // layout, health poll, glass

        do {
            let id = CGWindowID(window.windowNumber)
            // The window does not appear in the shareable list immediately, so
            // poll rather than assume. Without this the capture succeeded only
            // sometimes, which is worse than failing.
            var target: SCWindow?
            for _ in 0..<12 {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                if let w = content.windows.first(where: { $0.windowID == id }) { target = w; break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard let target else {
                FileHandle.standardError.write("window never became visible to the capture API\n"
                    .data(using: .utf8)!)
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(target.frame.width * 2)
            cfg.height = Int(target.frame.height * 2)
            cfg.showsCursor = false
            cfg.scalesToFit = true
            let shot = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
            guard let png = NSBitmapImageRep(cgImage: shot)
                    .representation(using: .png, properties: [:]) else { return }
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(
              "wrote \(path) (\(shot.width)x\(shot.height))\n".data(using: .utf8)!)
        } catch {
            let msg = """
            capture failed: \(error.localizedDescription)
            add Runbranch.app under System Settings > Privacy & Security > Screen Recording

            """
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        }
    }
}

/// A searchable grid of symbols, the way the SF Symbols picker works: icons
/// only, no names. A `Picker` listing names was unreadable — you scan icons by
/// shape, and the label just gets in the way.
///
/// The list is curated rather than exhaustive. There is no public API to
/// enumerate SF Symbols, and a few hundred relevant ones beat ten thousand
/// unsearchable ones.
struct SymbolPicker: View {
    @Binding var selection: String
    @State private var query = ""
    @State private var open = false

    private static let all: [String] = [
        // projects and things
        "shippingbox", "cube", "cube.transparent", "square.stack.3d.up", "square.stack",
        "folder", "folder.badge.gearshape", "tray.full", "archivebox", "briefcase",
        // web and network
        "globe", "globe.americas", "network", "antenna.radiowaves.left.and.right",
        "wifi", "link", "cloud", "icloud", "point.3.connected.trianglepath.dotted",
        // servers and data
        "server.rack", "externaldrive", "internaldrive", "cylinder.split.1x2",
        "chart.bar.doc.horizontal", "tablecells", "list.bullet.rectangle",
        // building and business
        "building.2", "building.columns", "storefront", "cart", "creditcard",
        "banknote", "chart.line.uptrend.xyaxis", "chart.pie", "percent",
        // design
        "paintpalette", "paintbrush", "swatchpalette", "eyedropper", "ruler",
        "square.on.circle", "circle.hexagongrid", "wand.and.stars", "sparkles",
        // code and tools
        "terminal", "curlybraces", "chevron.left.forwardslash.chevron.right",
        "hammer", "wrench.and.screwdriver", "gearshape.2", "cpu", "memorychip",
        "ladybug", "testtube.2", "flask",
        // documents and writing
        "doc.text", "doc.richtext", "book", "books.vertical", "text.book.closed",
        "newspaper", "pencil.and.outline", "signature",
        // communication
        "envelope", "bubble.left.and.bubble.right", "megaphone", "bell",
        "phone", "video", "person.2", "person.3",
        // media
        "photo", "photo.stack", "film", "music.note", "waveform", "mic",
        "play.rectangle", "camera",
        // navigation and places
        "map", "location", "signpost.right", "airplane", "car", "tram",
        // nature and misc
        "leaf", "tree", "flame", "drop", "bolt", "sun.max", "moon.stars",
        "star", "heart", "flag", "tag", "bookmark", "pin", "key", "lock",
        "shield", "checkmark.seal", "target", "scope", "puzzlepiece",
        "gamecontroller", "dice", "crown", "gift", "cup.and.saucer", "fork.knife",
    ]

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.all }
        return Self.all.filter { $0.contains(q) }
    }

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.isEmpty ? "shippingbox" : selection)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .padding(10)

                Divider()

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4),
                                             count: 8), spacing: 4) {
                        ForEach(matches, id: \.self) { name in
                            Button {
                                selection = name
                                open = false
                                query = ""
                            } label: {
                                Image(systemName: name)
                                    .font(.system(size: 15))
                                    .frame(width: 34, height: 30)
                                    .background(name == selection
                                                ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                                : AnyShapeStyle(.clear),
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(name)      // the name is there if you want it
                        }
                    }
                    .padding(10)
                }
                .frame(height: 240)

                if matches.isEmpty {
                    Text("Nothing matches “\(query)”")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                }
            }
            .frame(width: 330)
        }
    }
}

/// Editing a project's config without opening a text editor.
///
/// The engine owns the file: this reads `get` and writes changed keys through
/// `set`, which keeps comments, backs the file up and reverts anything that
/// will not load. So the worst a mistake here can do is show an error.
struct ProjectEditor: View {
    let projectID: String
    let onClose: (_ changed: Bool) -> Void

    @State private var f: [String: String] = [:]
    @State private var original: [String: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var problem: String?

    private static let runtimes = ["", "mise", "fnm", "asdf", "nvm"]

    private func bind(_ key: String) -> Binding<String> {
        Binding(get: { f[key] ?? "" }, set: { f[key] = $0 })
    }
    private func boolBind(_ key: String) -> Binding<Bool> {
        Binding(get: { f[key] == "1" }, set: { f[key] = $0 ? "1" : "0" })
    }
    private var dirtyKeys: [String] {
        f.keys.filter { f[$0] != original[$0] }.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: f["SYMBOL"]?.isEmpty == false ? f["SYMBOL"]! : "shippingbox")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(f["NAME"] ?? projectID).font(.system(size: 14, weight: .semibold))
                Spacer()
                if !dirtyKeys.isEmpty {
                    Text("\(dirtyKeys.count) unsaved")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 13)

            Divider()

            if loading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section("Project") {
                        TextField("Name", text: bind("NAME"))
                        LabeledContent("Sidebar icon") {
                            SymbolPicker(selection: bind("SYMBOL"))
                        }
                        TextField("Default branch", text: bind("DEFAULT_BRANCH"))
                        LabeledContent("Repository") {
                            Text(f["REPO"] ?? "").font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    Section("Run") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Targets — one per line: name:port:health:command")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            TextEditor(text: bind("TARGETS"))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minHeight: 64)
                        }
                        TextField("Always started", text: bind("ALWAYS"),
                                  prompt: Text("e.g. api"))
                        TextField("Presets", text: bind("PRESETS"),
                                  prompt: Text("web=web  both=web,admin"))
                        Toggle("Targets come from a Procfile", isOn: boolBind("PROCFILE"))
                        Toggle("The server opens a browser itself", isOn: boolBind("OPENS_ITSELF"))
                    }

                    Section("Setup") {
                        TextField("Install", text: bind("INSTALL"),
                                  prompt: Text("pnpm install --frozen-lockfile"))
                        Picker("Runtime", selection: bind("RUNTIME")) {
                            ForEach(Self.runtimes, id: \.self) { r in
                                Text(r.isEmpty ? "None" : r).tag(r)
                            }
                        }
                        TextField("Copy into the worktree", text: bind("COPY_FILES"),
                                  prompt: Text(".env.local"))
                    }

                    Section("Infrastructure") {
                        TextField("Compose services", text: bind("COMPOSE_SERVICES"),
                                  prompt: Text("postgres valkey"))
                        TextField("Compose project", text: bind("COMPOSE_PROJECT"))
                        TextField("Migrate", text: bind("MIGRATE"))
                        TextField("Seed", text: bind("SEED"))
                        TextField("Database URL variables", text: bind("DB_URL_VARS"),
                                  prompt: Text("DATABASE_URL"))
                    }

                    if let repo = f["IN_REPO"], !repo.isEmpty {
                        Section {
                            Label("This project also has a .runbranch in its repository. Values here override it.",
                                  systemImage: "doc.badge.gearshape")
                                .font(.system(size: 11))
                        }
                    }
                }
                .formStyle(.grouped)
            }

            if let problem {
                Divider()
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }

            Divider()
            HStack {
                Button("Reveal config") { revealConfig() }
                    .buttonStyle(.glass).controlSize(.large)
                Spacer()
                Button("Cancel") { onClose(false) }
                    .buttonStyle(.glass).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(dirtyKeys.isEmpty || saving)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 560, height: 620)
        .task {
            let loaded = await Task.detached { Engine.get(projectID) }.value
            f = loaded; original = loaded; loading = false
        }
    }

    private func revealConfig() {
        let paths = Engine.paths(projectID)
        guard paths.count >= 3 else { return }
        NSWorkspace.shared.selectFile(paths[2], inFileViewerRootedAtPath:
            (paths[2] as NSString).deletingLastPathComponent)
    }

    /// Writes only what changed, and stops at the first failure rather than
    /// carrying on and leaving the file half-updated.
    private func save() {
        saving = true
        problem = nil
        let keys = dirtyKeys
        let values = f
        Task {
            let failure = await Task.detached { () -> String? in
                for k in keys {
                    if let err = Engine.set(projectID, k, values[k] ?? "") { return err }
                }
                return nil
            }.value
            saving = false
            if let failure {
                problem = failure.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n").first ?? failure
            } else {
                onClose(true)
            }
        }
    }
}

// MARK: - Main

struct ProjectRow: View {
    let project: Project
    let isLive: Bool
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : (isLive ? .green : .secondary))
                .frame(width: 16)
            Text(project.name).font(.system(size: 13))
            Spacer(minLength: 0)
            if isLive {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            }
        }
    }
}

struct ContentView: View {
    @State private var projects: [Project] = []
    @State private var selectedProject: String?
    @State private var liveProjects: Set<String> = []

    /// The one currently displayed, and everything already fetched.
    @State private var snapshot: ProjectSnapshot?
    @State private var cache: [String: ProjectSnapshot] = [:]

    @State private var selection: String?
    @State private var preset = ""
    @State private var showMerged = false
    @State private var showOlder = false
    @State private var showAllRemote = false
    @State private var mineOnly = false
    @State private var query = ""

    @State private var sheetTitle = ""
    @State private var showingRun = false
    @State private var showingLogs = false
    /// A String is not Identifiable, so `.sheet(item:)` needs a wrapper.
    private struct EditTarget: Identifiable { let id: String }
    @State private var editingProject: EditTarget?
    @StateObject private var runner = Runner()
    @StateObject private var health = HealthMonitor()

    private static let week = 7 * 24 * 60 * 60

    private var project: Project? {
        projects.first { $0.id == selectedProject }
    }

    /// The snapshot, but only if it belongs to the selected project. Every
    /// read goes through here, so stale data cannot reach the screen.
    private var current: ProjectSnapshot? {
        guard let s = snapshot, s.id == selectedProject else { return nil }
        return s
    }

    func visible(_ snap: ProjectSnapshot) -> [Branch] {
        let branches = snap.branches
        let state = snap.state
        let now = Int(Date().timeIntervalSince1970)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return branches.filter { b in
            // Search overrides the filters: if you typed a branch's name you
            // want to see it, merged and ancient or not.
            if !q.isEmpty {
                return b.ref.lowercased().contains(q) || b.subject.lowercased().contains(q)
            }
            // The default branch and whatever is running are always shown:
            // hiding the thing on screen would be worse than a wide filter.
            if b.isDefault || b.ref == state.ref { return true }
            if mineOnly && !b.mine { return false }
            // A repo can carry hundreds of remote branches and almost none of
            // them are worth looking at. The ones with an open pull request
            // are exactly the reviewable set, so those show by default and
            // the rest are opt-in.
            if b.isRemote && !showAllRemote && b.pr != .open { return false }
            if !showMerged && b.pr == .merged { return false }
            if !showOlder && now - b.timestamp > Self.week { return false }
            return true
        }
    }

    private var filtersActive: Bool { showMerged || showOlder || showAllRemote || mineOnly }

    /// ⌘1…9. Precomputed because building the key equivalents inline defeated
    /// the type checker.
    private var shortcutProjects: [(key: KeyEquivalent, id: String)] {
        projects.prefix(9).enumerated().map { i, p in
            (KeyEquivalent(Character(String(i + 1))), p.id)
        }
    }

    private var selectedBranch: Branch? {
        current?.branches.first { $0.ref == selection }
    }

    /// Start / Stop / Switch, decided by what is running and what is selected.
    private func primary(_ snap: ProjectSnapshot) -> (title: String, destructive: Bool, action: () -> Void)? {
        let state = snap.state
        guard let p = selectedProject, let ref = selection else { return nil }
        if state.running && state.ref == ref {
            return ("Stop", true, { run(["stop", p], "Stopping \(ref)") })
        }
        if state.running {
            // do_run stops whatever this project has running first, and says
            // so as it goes.
            return ("Switch", false, { run(["run", p, ref, preset], "Switching to \(ref)") })
        }
        return ("Start", false, { run(["run", p, ref, preset], "Starting \(ref)") })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if project == nil {
                ContentUnavailableView(
                    "No project selected",
                    systemImage: "square.stack.3d.up",
                    description: Text("Projects are declared in \(Engine.projectsDir)"))
            } else if let snap = current {
                detail(snap)
            } else {
                // Loading. Deliberately not the previous project's data with
                // pieces swapped in as they arrive.
                VStack { ProgressView().controlSize(.small) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .navigationTitle(project?.name ?? "")
                    .navigationSubtitle("")
            }
        }
        .frame(minWidth: 780, idealWidth: 820, minHeight: 440, idealHeight: 540)
        // Hiding the toolbar background removed the seam above the sidebar but
        // left content scrolling visibly under the title. `.automatic` gives
        // both: nothing at rest, a material once something scrolls beneath it.
        .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        .task {
            // Reclaim before reading state, so a crash's leftovers are gone
            // before anything is drawn rather than showing as a phantom run.
            _ = await Task.detached { Engine.reclaim() }.value
            loadProjects()
            if let path = Screenshot.path {
                await Screenshot.captureAndQuit(to: path)
            }
        }
        .onChange(of: selectedProject) { _, _ in Task { await reload() } }
        .background {
            // Shortcuts with no visible control of their own.
            Group {
                ForEach(shortcutProjects, id: \.key) { pair in
                    Button("") { selectedProject = pair.id }
                        .keyboardShortcut(pair.key, modifiers: .command)
                }
                Button("") {
                    if let snap = current, snap.state.running, let p = selectedProject {
                        run(["stop", p], "Stopping \(snap.state.ref)")
                    }
                }
                .keyboardShortcut(".", modifiers: .command)

                Button("") { if let p = selectedProject { editingProject = .init(id: p) } }
                    .keyboardShortcut(",", modifiers: .command)

            }
            .opacity(0)
        }
        // Native search. On macOS this becomes an NSSearchToolbarItem, which
        // collapses to a magnifying glass in its own glass pill and expands
        // when clicked — Finder's behaviour, and the system's job. I hand-rolled
        // a replica for three rounds on the wrong belief that it would not
        // collapse; the replica needed its own close button and could never sit
        // in the right place.
        .searchable(text: $query, placement: .toolbar, prompt: "Search branches")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("Only my branches", isOn: $mineOnly)
                    Divider()
                    Toggle("Show merged", isOn: $showMerged)
                    Toggle("Show older than a week", isOn: $showOlder)
                    Toggle("Show all remote branches", isOn: $showAllRemote)
                } label: {
                    // A plain glyph: the chevron a Menu draws by default is
                    // noise, and no native app shows one here.
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(filtersActive ? Color.accentColor : .primary)
                }
                .menuIndicator(.hidden)
                .help("Filter branches")

                Button {
                    Task {
                        if let p = selectedProject {
                            _ = await Task.detached { Engine.capture(["refresh", p]) }.value
                            cache[p] = nil
                        }
                        await reload()
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-read branches and pull request state")
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Menu {
                    if let b = selectedBranch, let p = selectedProject {
                        Button("Copy branch name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(b.ref, forType: .string)
                        }
                        if let snap = current, snap.state.running, snap.state.ref == b.ref,
                           let url = snap.state.urls.first {
                            Button("Copy URL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                        }
                        if !b.prNumber.isEmpty {
                            Button("Open pull request #\(b.prNumber)") { openPR(b.prNumber) }
                        }
                        Divider()
                        if b.ready {
                            Menu("Open worktree in") {
                                ForEach(Editor.allCases.filter(\.isInstalled), id: \.self) { e in
                                    Button(e.title) { openWorktree(b.ref, in: e) }
                                }
                            }
                            Button("Reveal worktree in Finder") { revealWorktree(b.ref) }
                            Button("Remove worktree") {
                                run(["remove-worktree", p, b.ref], "Removing \(b.ref)")
                            }
                            .disabled(current?.state.running == true && current?.state.ref == b.ref)
                            Divider()
                        }
                    }
                    Button("Add project…") { addProject() }
                    Divider()
                    Button("Open logs in Finder") { openLogs() }
                    if let p = project {
                        Button("Reveal repository in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.repo)
                        }
                        Divider()
                        Button("Project settings…") { editingProject = .init(id: p.id) }
                        Button("Open config in a text editor") { editConfig(p.id) }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .help("More actions")
            }

        }
        .sheet(isPresented: $showingRun) {
            RunSheet(runner: runner, title: sheetTitle) {
                showingRun = false
                if let p = selectedProject { cache[p] = nil }
                Task { await reload(); await refreshLive() }
            }
        }
        .sheet(item: $editingProject) { target in
            ProjectEditor(projectID: target.id) { changed in
                editingProject = nil
                guard changed else { return }
                cache[target.id] = nil
                Task {
                    projects = await Task.detached { Engine.projects() }.value
                    await reload()
                }
            }
        }
        .sheet(isPresented: $showingLogs) {
            LogViewer(logDir: current?.logDir ?? "",
                      targets: current?.state.targets ?? []) { showingLogs = false }
        }
    }

    private func detail(_ snap: ProjectSnapshot) -> some View {
        let state = snap.state
        let rows = visible(snap)
        return VStack(alignment: .leading, spacing: 0) {

            if rows.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label(query.isEmpty ? "No branches to show" : "No match",
                          systemImage: query.isEmpty ? "arrow.triangle.branch" : "magnifyingglass")
                } description: {
                    Text(query.isEmpty
                         ? "Merged branches and anything older than a week are hidden. Change that in the filter menu."
                         : "No branch matches “\(query)”.")
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
            List(rows, selection: $selection) { branch in
                BranchRow(branch: branch,
                          isLive: state.running && state.ref == branch.ref,
                          showGutter: state.running,
                          isSelected: selection == branch.ref)
                    .tag(branch.ref)
                    .contextMenu {
                        if branch.ready && state.ref != branch.ref, let p = selectedProject {
                            Button("Remove worktree") {
                                run(["remove-worktree", p, branch.ref], "Removing \(branch.ref)")
                            }
                        }
                    }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .top, spacing: 0) {
                if state.running {
                    RunStrip(state: state, health: health, epoch: state.epoch)
                }
            }
            }

            // Nothing selected means nothing to press, and an empty bar with a
            // separator above it reads as a broken control rather than an
            // absent one.
            if selection != nil {
            Divider()

            HStack(spacing: 12) {
                // Presets come from the project's own config, so a one-server
                // project shows one button and Studio shows three.
                if snap.presets.count > 1 {
                    Picker("", selection: $preset) {
                        ForEach(snap.presets, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(width: CGFloat(min(snap.presets.count, 4)) * 72)
                    .disabled(state.running && state.ref == selection)
                }

                Spacer()

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        if state.running {
                            Button("Logs") { showingLogs = true }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                        if state.running, let url = state.urls.first {
                            Button("Open") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                        if let p = primary(snap) {
                            Button(p.title, action: p.action)
                                .buttonStyle(.glassProminent).controlSize(.large)
                                .tint(p.destructive ? .red : .accentColor)
                                .keyboardShortcut(.defaultAction)
                                .help("\(p.title) \(selection ?? "")")
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .background(.background)
        // Finder titles the folder, Mail titles the mailbox. The app's own name
        // is already on the menu bar and does not need repeating here.
        .navigationTitle(projects.first { $0.id == snap.id }?.name ?? "")
        .navigationSubtitle(state.running ? "\(state.ref) · \(state.preset)" : "")
    }

    private func run(_ args: [String], _ title: String) {
        sheetTitle = title
        showingRun = true
        runner.start(args)
    }

    private func loadProjects() {
        Task {
            let found = await Task.detached { Engine.projects() }.value
            projects = found
            if selectedProject == nil {
                // For a screenshot, show a project that is actually running —
                // the status strip is the most informative thing on screen and
                // an idle project hides it.
                let live = Screenshot.path != nil
                    ? found.first(where: { Engine.state($0.id).running })
                    : nil
                selectedProject = live?.id ?? found.first?.id
            }
            await refreshLive()
            await reload()
            // Warm every other project in the background so the second switch,
            // and every one after, costs nothing.
            for p in found where p.id != selectedProject {
                let id = p.id
                cache[id] = await Task.detached { ProjectSnapshot.load(id) }.value
            }
        }
    }

    /// Which projects have something up — drives the sidebar spinners.
    private func refreshLive() async {
        let ids = projects.map(\.id)
        let live = await Task.detached { () -> Set<String> in
            Set(ids.filter { Engine.state($0).running })
        }.value
        liveProjects = live
    }

    /// Builds the whole snapshot, then assigns it in one go. Nothing is
    /// applied piecemeal, and a reply that arrives after you have switched away
    /// is dropped rather than half-drawn.
    private func reload() async {
        guard let p = selectedProject else { snapshot = nil; return }

        // A cached snapshot is complete, so showing it immediately is safe.
        snapshot = cache[p]

        let fresh = await Task.detached { ProjectSnapshot.load(p) }.value
        guard selectedProject == p else { return }

        cache[p] = fresh
        snapshot = fresh
        applySelection(fresh)
    }

    /// Selection and preset belong to the snapshot, so they move with it.
    private func applySelection(_ snap: ProjectSnapshot) {
        if snap.state.running { health.watch(snap.state.targets) } else { health.stop() }

        if preset.isEmpty || !snap.presets.contains(preset) { preset = snap.presets.first ?? "" }
        if snap.state.running {
            selection = snap.state.ref
            if snap.presets.contains(snap.state.preset) { preset = snap.state.preset }
        } else if selection == nil || !snap.branches.contains(where: { $0.ref == selection }) {
            selection = snap.branches.first(where: { $0.mine && $0.pr != .merged })?.ref
                     ?? snap.branches.first(where: { $0.isDefault })?.ref
        }
    }

    private var live: [Project] { projects.filter { liveProjects.contains($0.id) } }
    private var idle: [Project] { projects.filter { !liveProjects.contains($0.id) } }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedProject) {
            // Running first, the way Finder puts Recents above Favorites.
            if !live.isEmpty {
                Section("Running") {
                    ForEach(live) { projectRow($0, isLive: true) }
                }
            }
            Section("Projects") {
                ForEach(idle) { projectRow($0, isLive: false) }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }

    @ViewBuilder
    private func projectRow(_ p: Project, isLive: Bool) -> some View {
        ProjectRow(project: p, isLive: isLive, isSelected: selectedProject == p.id)
            .tag(p.id)
            .contextMenu { projectMenu(p) }
    }

    @ViewBuilder
    private func projectMenu(_ p: Project) -> some View {
        Button("Project settings…") { editingProject = .init(id: p.id) }
        Button("Reveal repository in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.repo)
        }
        Button("Open config in a text editor") { editConfig(p.id) }
    }

    private func cachedPaths(_ p: String) -> [String] { cache[p]?.paths ?? Engine.paths(p) }

    private func reveal(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func openWorktree(_ ref: String, in editor: Editor) {
        guard let p = selectedProject else { return }
        let fields = Engine.paths(p, ref: ref)
        if fields.count >= 6 { editor.open(fields[5]) }
    }

    private func revealWorktree(_ ref: String) {
        guard let p = selectedProject else { return }
        let fields = Engine.paths(p, ref: ref)
        if fields.count >= 6 { reveal(fields[5]) }
    }

    private func openLogs() {
        guard let p = selectedProject else { return }
        let fields = cachedPaths(p)
        if fields.count >= 2 { reveal(fields[1]) }
    }

    /// The engine reports the GitHub slug, so the app does not have to parse a
    /// remote URL of its own.
    private func openPR(_ number: String) {
        guard let p = selectedProject else { return }
        let fields = cachedPaths(p)
        guard fields.count >= 5, !fields[4].isEmpty,
              let url = URL(string: "https://github.com/\(fields[4])/pull/\(number)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Hand the .conf to whatever the user opens shell scripts with.
    private func editConfig(_ p: String) {
        let fields = cachedPaths(p)
        guard fields.count >= 3 else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: fields[2]))
    }

    /// Point it at a repo and it writes a config by reading what is already
    /// there — lockfile, scripts, ports, compose services, toolchain pin. The
    /// file opens straight away, because these are guesses and the point is
    /// that you can see and correct them.
    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a git repository"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Development")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let added = await Task.detached { Engine.add(url.path) }.value
            guard let added else {
                let a = NSAlert()
                a.messageText = "Could not add that folder"
                a.informativeText = "It needs to be a git repository, and not already declared."
                a.runModal()
                return
            }
            projects = await Task.detached { Engine.projects() }.value
            selectedProject = added.name
            NSWorkspace.shared.open(URL(fileURLWithPath: added.file))
            await reload()
        }
    }

    /// "2026-09-04 23:32:59" -> "23:32".
    private func shortTime(_ s: String) -> String {
        let parts = s.components(separatedBy: " ")
        guard parts.count == 2 else { return s }
        return parts[1].components(separatedBy: ":").prefix(2).joined(separator: ":")
    }
}

@main
struct RunBranchApp: App {
    var body: some Scene {
        WindowGroup("Runbranch") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
