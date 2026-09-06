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

    var id: String { ref }

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

// MARK: - Small views

struct Badge: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol, !symbol.isEmpty {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
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
    let uptime: String

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

            Text(uptime)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            // A label, not a button: Open already opens it, and two ways to do
            // one thing is worse than one obvious way.
            ForEach(state.targets) { t in
                HStack(spacing: 5) {
                    Circle()
                        .fill((health.status[t.name] ?? .unknown).color)
                        .frame(width: 5, height: 5)
                    Text("localhost:\(String(t.port))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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

    var body: some View {
        HStack(spacing: 8) {
            if showGutter {
                ZStack {
                    if isLive {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                    }
                }
                .frame(width: 14, height: 14)
            }

            Text(branch.ref)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)

            if branch.isDefault {
                Badge(text: "default", color: .accentColor)
            } else if let l = branch.pr.label {
                // No PR badge on the default branch: every PR merges INTO
                // development, so its own state says nothing about the branch
                // you are choosing.
                Badge(text: l, symbol: branch.pr.symbol, color: branch.pr.color)
            }
            Badge(text: branch.owner)

            // No "running" badge: the spinner in the gutter already says it,
            // and the header names the branch. "ready" only means the worktree
            // exists, which stops being interesting once it is live.
            if !isLive && branch.ready {
                Badge(text: "ready", symbol: "bolt.fill", color: .green)
            }

            Spacer(minLength: 8)

            Text(branch.age)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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

// MARK: - Main

struct ProjectRow: View {
    let project: Project
    let isLive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.symbol)
                .font(.system(size: 12))
                .foregroundStyle(isLive ? Color.green : .secondary)
                .frame(width: 16)
            Text(project.name).font(.system(size: 13))
            Spacer(minLength: 0)
            if isLive {
                ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 12, height: 12)
            }
        }
    }
}

struct ContentView: View {
    @State private var projects: [Project] = []
    @State private var selectedProject: String?
    @State private var liveProjects: Set<String> = []

    @State private var branches: [Branch] = []
    @State private var presets: [String] = []
    @State private var state = RunState.idle
    @State private var selection: String?
    @State private var preset = ""
    @State private var showMerged = false
    @State private var showOlder = false
    @State private var query = ""
    @State private var searchOpen = false
    @FocusState private var searchFocused: Bool
    @State private var logDir = ""

    @State private var sheetTitle = ""
    @State private var showingRun = false
    @State private var showingLogs = false
    @State private var now = Date()
    @StateObject private var runner = Runner()
    @StateObject private var health = HealthMonitor()

    /// Ticks so uptime stays true without polling the engine.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var uptime: String {
        guard state.running, state.epoch > 0 else { return "—" }
        let s = max(0, Int(now.timeIntervalSince1970 - state.epoch))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private static let week = 7 * 24 * 60 * 60

    private var project: Project? {
        projects.first { $0.id == selectedProject }
    }

    var visible: [Branch] {
        let now = Int(Date().timeIntervalSince1970)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return branches.filter { b in
            // Search overrides the filters: if you typed a branch's name you
            // want to see it, merged and ancient or not.
            if !q.isEmpty { return b.ref.lowercased().contains(q) }
            if b.isDefault || b.ref == state.ref { return true }
            if !showMerged && b.pr == .merged { return false }
            if !showOlder && now - b.timestamp > Self.week { return false }
            return true
        }
    }

    private var filtersActive: Bool { showMerged || showOlder }

    private var selectedBranch: Branch? {
        branches.first { $0.ref == selection }
    }

    /// Start / Stop / Switch, decided by what is running and what is selected.
    private var primary: (title: String, action: () -> Void)? {
        guard let p = selectedProject, let ref = selection else { return nil }
        if state.running && state.ref == ref {
            return ("Stop", { run(["stop", p], "Stopping \(ref)") })
        }
        if state.running {
            // do_run stops whatever this project has running first, and says
            // so as it goes.
            return ("Switch", { run(["run", p, ref, preset], "Switching to \(ref)") })
        }
        return ("Start", { run(["run", p, ref, preset], "Starting \(ref)") })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProject) {
                // Running first, the way Finder puts Recents above Favorites.
                if !liveProjects.isEmpty {
                    Section("Running") {
                        ForEach(projects.filter { liveProjects.contains($0.id) }) { p in
                            ProjectRow(project: p, isLive: true).tag(p.id)
                        }
                    }
                }
                Section("Projects") {
                    ForEach(projects.filter { !liveProjects.contains($0.id) }) { p in
                        ProjectRow(project: p, isLive: false).tag(p.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            if project == nil {
                ContentUnavailableView(
                    "No project selected",
                    systemImage: "square.stack.3d.up",
                    description: Text("Projects are declared in \(Engine.projectsDir)"))
            } else {
                detail
            }
        }
        .frame(minWidth: 780, idealWidth: 820, minHeight: 440, idealHeight: 540)
        // The toolbar paints an opaque band across the whole window width,
        // including over the sidebar — which is what put a grey block above a
        // translucent sidebar and a seam beside the title. Finder's sidebar
        // material runs unbroken to the top because its toolbar has no
        // background of its own.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task {
            // Reclaim before reading state, so a crash's leftovers are gone
            // before anything is drawn rather than showing as a phantom run.
            Engine.reclaim()
            loadProjects()
        }
        .onReceive(clock) { now = $0 }
        .onChange(of: searchFocused) { _, focused in
            if !focused && query.isEmpty { searchOpen = false }
        }
        .onChange(of: selectedProject) { _, _ in reload() }
        .background {
            // Shortcuts with no visible control of their own.
            Group {
                ForEach(Array(projects.prefix(9).enumerated()), id: \.element.id) { i, p in
                    Button("") { selectedProject = p.id }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Button("") {
                    if state.running, let p = selectedProject {
                        run(["stop", p], "Stopping \(state.ref)")
                    }
                }
                .keyboardShortcut(".", modifiers: .command)

                Button("") { searchOpen = true; searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
            .opacity(0)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // macOS has no .searchToolbarBehavior(.minimize) — that is
                // iOS only — so the collapse is done by hand.
                if searchOpen {
                    TextField("Search branches", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($searchFocused)
                        .onSubmit { searchFocused = false }
                        .onExitCommand { query = ""; searchOpen = false }
                } else {
                    Button {
                        searchOpen = true
                        searchFocused = true
                    } label: { Image(systemName: "magnifyingglass") }
                    .help("Search branches")
                }

                // Filters belong in the toolbar, not as checkboxes in the body:
                // the body is content, the chrome is options.
                Menu {
                    Toggle("Show merged", isOn: $showMerged)
                    Toggle("Show older than a week", isOn: $showOlder)
                } label: {
                    // A plain glyph: the chevron a Menu draws by default is
                    // noise, and no native app shows one here.
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(filtersActive ? Color.accentColor : .primary)
                }
                .menuIndicator(.hidden)
                .help("Filter branches")

                Button {
                    if let p = selectedProject { _ = Engine.capture(["refresh", p]) }
                    reload()
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-read branches and pull request state")
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Menu {
                    if let b = selectedBranch, let p = selectedProject {
                        Button("Copy branch name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(b.ref, forType: .string)
                        }
                        if let url = state.urls.first, state.running, state.ref == b.ref {
                            Button("Copy URL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                        }
                        Divider()
                        if b.ready {
                            Button("Reveal worktree in Finder") { revealWorktree(b.ref) }
                            Button("Remove worktree") {
                                run(["remove-worktree", p, b.ref], "Removing \(b.ref)")
                            }
                            .disabled(state.running && state.ref == b.ref)
                            Divider()
                        }
                    }
                    Button("Open logs in Finder") { openLogs() }
                    if let p = project {
                        Button("Reveal repository in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.repo)
                        }
                        Button("Edit project config") { editConfig(p.id) }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .help("More actions")
            }
        }
        .sheet(isPresented: $showingRun) {
            RunSheet(runner: runner, title: sheetTitle) {
                showingRun = false
                reload()
                refreshLive()
            }
        }
        .sheet(isPresented: $showingLogs) {
            LogViewer(logDir: logDir, targets: state.targets) { showingLogs = false }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {

            if visible.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label(query.isEmpty ? "No branches to show" : "No match",
                          systemImage: query.isEmpty ? "arrow.triangle.branch" : "magnifyingglass")
                } description: {
                    Text(query.isEmpty
                         ? "Merged branches and anything older than a week are hidden. Change that in the filter menu."
                         : "No branch matches “\(query)”.")
                }
                Spacer()
            } else {
            List(visible, selection: $selection) { branch in
                BranchRow(branch: branch,
                          isLive: state.running && state.ref == branch.ref,
                          showGutter: state.running)
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
                    RunStrip(state: state, health: health, uptime: uptime)
                }
            }
            }

            Divider()

            HStack(spacing: 12) {
                // Presets come from the project's own config, so a one-server
                // project shows one button and Studio shows three.
                if presets.count > 1 {
                    Picker("", selection: $preset) {
                        ForEach(presets, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(width: CGFloat(min(presets.count, 4)) * 72)
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
                        if let primary {
                            Button(primary.title, action: primary.action)
                                .buttonStyle(.glassProminent).controlSize(.large)
                                .keyboardShortcut(.defaultAction)
                                .help("\(primary.title) \(selection ?? "")")
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(.background)
        // Finder titles the folder, Mail titles the mailbox. The app's own name
        // is already on the menu bar and does not need repeating here.
        .navigationTitle(project?.name ?? "Runbranch")
        .navigationSubtitle(state.running ? "\(state.ref) · \(state.preset)" : "")
    }

    private func run(_ args: [String], _ title: String) {
        sheetTitle = title
        showingRun = true
        runner.start(args)
    }

    private func loadProjects() {
        projects = Engine.projects()
        if selectedProject == nil { selectedProject = projects.first?.id }
        refreshLive()
        reload()
    }

    /// Which projects have something up — drives the sidebar spinners.
    private func refreshLive() {
        var live: Set<String> = []
        for p in projects where Engine.state(p.id).running { live.insert(p.id) }
        liveProjects = live
    }

    private func reload() {
        guard let p = selectedProject else { return }
        branches = Engine.branches(p)
        presets = Engine.presets(p)
        state = Engine.state(p)
        logDir = Engine.paths(p).count >= 2 ? Engine.paths(p)[1] : ""
        if state.running { health.watch(state.targets) } else { health.stop() }
        if preset.isEmpty || !presets.contains(preset) { preset = presets.first ?? "" }
        if state.running {
            selection = state.ref
            if presets.contains(state.preset) { preset = state.preset }
        } else if selection == nil || !branches.contains(where: { $0.ref == selection }) {
            selection = branches.first(where: { $0.mine && $0.pr != .merged })?.ref
                     ?? branches.first(where: { $0.isDefault })?.ref
        }
    }

    private func reveal(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func revealWorktree(_ ref: String) {
        guard let p = selectedProject else { return }
        let fields = Engine.paths(p, ref: ref)
        if fields.count >= 5 { reveal(fields[4]) }
    }

    private func openLogs() {
        guard let p = selectedProject else { return }
        let fields = Engine.paths(p)
        if fields.count >= 2 { reveal(fields[1]) }
    }

    /// Hand the .conf to whatever the user opens shell scripts with.
    private func editConfig(_ p: String) {
        let fields = Engine.paths(p)
        guard fields.count >= 3 else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: fields[2]))
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
