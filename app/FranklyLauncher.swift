// FranklyLauncher — the front end. All the work happens in frankly-launcher.sh;
// this is a window over it.
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

enum Target: String, CaseIterable, Identifiable {
    case web, admin, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .web: return "Web"
        case .admin: return "Admin"
        case .both: return "Both"
        }
    }
}

/// What the engine says is running right now.
struct DemoState {
    var running = false
    var ref = ""
    var target: Target = .web
    var started = ""
    var webUp = false
    var adminUp = false

    static let idle = DemoState()

    init() {}

    /// `running|idle  ref  target  started  web  admin`, tab separated.
    init(tsv line: String) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 6, f[0] == "running" else { self = .idle; return }
        running = true
        ref = f[1]
        target = Target(rawValue: f[2]) ?? .web
        started = f[3]
        webUp = f[4] == "1"
        adminUp = f[5] == "1"
    }

    var url: URL? {
        if webUp { return URL(string: "http://localhost:3000") }
        if adminUp { return URL(string: "http://localhost:3002") }
        return nil
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
        return NSHomeDirectory() + "/Development/work/frankly-launcher/frankly-launcher.sh"
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

    static func branches() -> [Branch] {
        capture(["branches"]).out
            .components(separatedBy: "\n")
            .compactMap { $0.isEmpty ? nil : Branch(tsv: $0) }
    }

    static func state() -> DemoState {
        let line = capture(["state"]).out.components(separatedBy: "\n").first ?? ""
        return DemoState(tsv: line)
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

struct ContentView: View {
    @State private var branches: [Branch] = []
    @State private var demo = DemoState.idle
    @State private var selection: String?
    @State private var target: Target = .web
    @State private var showMerged = false
    @State private var showOlder = false
    @State private var sheetTitle = ""
    @State private var showingRun = false
    @StateObject private var runner = Runner()

    private static let week = 7 * 24 * 60 * 60

    var visible: [Branch] {
        let now = Int(Date().timeIntervalSince1970)
        return branches.filter { b in
            if b.isDefault || b.ref == demo.ref { return true }
            if !showMerged && b.pr == .merged { return false }
            if !showOlder && now - b.timestamp > Self.week { return false }
            return true
        }
    }

    /// Start / Stop / Switch, decided by what is running and what is selected.
    private var primary: (title: String, action: () -> Void)? {
        guard let ref = selection else { return nil }
        if demo.running && demo.ref == ref {
            return ("Stop", { run(["stop"], "Stopping \(ref)") })
        }
        if demo.running {
            // do_run stops the current demo first; only one fits on the shared
            // Postgres, and it says so as it goes.
            return ("Switch", { run(["run", ref, target.rawValue], "Switching to \(ref)") })
        }
        return ("Start", { run(["run", ref, target.rawValue], "Starting \(ref)") })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(demo.running
                 ? "\(demo.ref) is running · \(demo.target.title) · since \(shortTime(demo.started))"
                 : "Runs from a throwaway worktree. Your Studio checkout is never touched.")
                .font(.system(size: 11))
                .foregroundStyle(demo.running ? .primary : .secondary)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)

            List(visible, selection: $selection) { branch in
                BranchRow(branch: branch,
                          isLive: demo.running && demo.ref == branch.ref,
                          showGutter: demo.running)
                    .tag(branch.ref)
                    .contextMenu {
                        if branch.ready && demo.ref != branch.ref {
                            Button("Remove worktree") {
                                run(["remove-worktree", branch.ref], "Removing \(branch.ref)")
                            }
                        }
                    }
            }
            .listStyle(.inset)
            .onChange(of: selection) { _, _ in syncTargetToDemo() }

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
                Picker("", selection: $target) {
                    ForEach(Target.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .frame(width: 210)
                // A running demo's target is a fact, not a choice.
                .disabled(demo.running && demo.ref == selection)

                Spacer()

                // Liquid Glass, and grouped so the two buttons blend into one
                // another the way system controls do rather than reading as two
                // unrelated slabs.
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        if demo.running, let url = demo.url {
                            Button("Open") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                        }
                        if let primary {
                            Button(primary.title, action: primary.action)
                                .buttonStyle(.glassProminent)
                                .controlSize(.large)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(minWidth: 560, idealWidth: 580, minHeight: 400, idealHeight: 520)
        .task { reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    _ = Engine.capture(["refresh-branches"])
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh branches and pull request state")
            }
        }
        .sheet(isPresented: $showingRun) {
            RunSheet(runner: runner, title: sheetTitle) {
                showingRun = false
                reload()
            }
        }
    }

    private func run(_ args: [String], _ title: String) {
        sheetTitle = title
        showingRun = true
        runner.start(args)
    }

    private func reload() {
        branches = Engine.branches()
        demo = Engine.state()
        if demo.running {
            selection = demo.ref
            target = demo.target
        } else if selection == nil || !branches.contains(where: { $0.ref == selection }) {
            selection = branches.first(where: { $0.mine && $0.pr != .merged })?.ref
                     ?? branches.first(where: { $0.isDefault })?.ref
        }
    }

    private func syncTargetToDemo() {
        if demo.running && demo.ref == selection { target = demo.target }
    }

    /// "2026-09-04 23:32:59" -> "23:32".
    private func shortTime(_ s: String) -> String {
        let parts = s.components(separatedBy: " ")
        guard parts.count == 2 else { return s }
        return parts[1].components(separatedBy: ":").prefix(2).joined(separator: ":")
    }
}

@main
struct FranklyLauncherApp: App {
    var body: some Scene {
        WindowGroup("Frankly Launcher") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
