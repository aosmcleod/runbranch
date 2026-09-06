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

    init?(tsv line: String) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 3 else { return nil }
        id = f[0]; name = f[1]; repo = f[2]
    }
}

/// What the engine says is running for one project.
struct RunState {
    var running = false
    var ref = ""
    var preset = ""
    var started = ""
    var urls: [URL] = []

    static let idle = RunState()

    init() {}

    /// `running|idle  ref  preset  started  url,url`, tab separated.
    init(tsv line: String) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 5, f[0] == "running" else { self = .idle; return }
        running = true
        ref = f[1]
        preset = f[2]
        started = f[3]
        urls = f[4].components(separatedBy: ",").compactMap {
            $0.isEmpty ? nil : URL(string: $0)
        }
    }
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

    static func state(_ project: String) -> RunState {
        let line = capture(["state", project]).out.components(separatedBy: "\n").first ?? ""
        return RunState(tsv: line)
    }
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

// MARK: - Main

struct ProjectRow: View {
    let project: Project
    let isLive: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isLive {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
            }
            Text(project.name).font(.system(size: 13))
            Spacer(minLength: 0)
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

    @State private var sheetTitle = ""
    @State private var showingRun = false
    @StateObject private var runner = Runner()

    private static let week = 7 * 24 * 60 * 60

    private var project: Project? {
        projects.first { $0.id == selectedProject }
    }

    var visible: [Branch] {
        let now = Int(Date().timeIntervalSince1970)
        return branches.filter { b in
            if b.isDefault || b.ref == state.ref { return true }
            if !showMerged && b.pr == .merged { return false }
            if !showOlder && now - b.timestamp > Self.week { return false }
            return true
        }
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
            List(projects, selection: $selectedProject) { p in
                ProjectRow(project: p, isLive: liveProjects.contains(p.id)).tag(p.id)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if project == nil {
                ContentUnavailableView("No project selected", systemImage: "square.stack.3d.up")
            } else {
                detail
            }
        }
        .frame(minWidth: 780, idealWidth: 820, minHeight: 440, idealHeight: 540)
        .task { loadProjects() }
        .onChange(of: selectedProject) { _, _ in reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let p = selectedProject { _ = Engine.capture(["refresh", p]) }
                    reload()
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-read branches and pull request state")
            }
        }
        .sheet(isPresented: $showingRun) {
            RunSheet(runner: runner, title: sheetTitle) {
                showingRun = false
                reload()
                refreshLive()
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.running
                 ? "\(state.ref) is running · \(state.preset) · since \(shortTime(state.started))"
                 : "Runs from a throwaway worktree. Your checkout is never touched.")
                .font(.system(size: 11))
                .foregroundStyle(state.running ? .primary : .secondary)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)

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

            Divider()

            HStack(spacing: 16) {
                Toggle("Show merged", isOn: $showMerged)
                Toggle("Show older than a week", isOn: $showOlder)
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .padding(.horizontal, 16).padding(.vertical, 10)

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
                        if state.running, let url = state.urls.first {
                            Button("Open") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                        if let primary {
                            Button(primary.title, action: primary.action)
                                .buttonStyle(.glassProminent).controlSize(.large)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
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
        if preset.isEmpty || !presets.contains(preset) { preset = presets.first ?? "" }
        if state.running {
            selection = state.ref
            if presets.contains(state.preset) { preset = state.preset }
        } else if selection == nil || !branches.contains(where: { $0.ref == selection }) {
            selection = branches.first(where: { $0.mine && $0.pr != .merged })?.ref
                     ?? branches.first(where: { $0.isDefault })?.ref
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
        WindowGroup("runbranch") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
