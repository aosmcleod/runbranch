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
    /// Where this branch is checked out, when that is a worktree someone made
    /// themselves. Empty otherwise. Git will not check one branch out twice, so
    /// this is also why an in-place run of it is not on offer.
    let checkedOutAt: String

    /// Runnable in place — in the real checkout, with whatever is in the
    /// working tree right now, rather than from a snapshot.
    var canRunInPlace: Bool { isCurrent && !isRemote }

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
        checkedOutAt = f.count > 12 ? f[12] : ""
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
    let favourite: Bool

    init?(tsv line: String) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 3 else { return nil }
        id = f[0]; name = f[1]; repo = f[2]
        symbol = f.count >= 5 && !f[4].isEmpty ? f[4] : "shippingbox"
        favourite = f.count >= 6 && f[5] == "1"
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
    /// Running in the real checkout rather than a worktree, so what is served
    /// is whatever is on disk — uncommitted work included.
    var inPlace = false
    /// Runbranch did not start this — it found the project already up and is
    /// reporting it rather than pretending otherwise. Stopping it means ending
    /// a process someone else started, so it goes through kill-port.
    var adopted = false
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
                inPlace = f.count > 6 && f[6] == "1"
                adopted = f.count > 7 && f[7] == "1"
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

extension String {
    /// `/Users/someone/code` → `~/code`.
    ///
    /// Not cosmetic: a full path in the UI puts the account name into any
    /// screenshot of it, and this was inlined at three call sites where a
    /// fourth would have missed it.
    var abbreviatingHome: String {
        replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// What to do about a port that is already taken.
///
/// Three ways out, in the order they are usually wanted: take the port from our
/// own run, go somewhere else, or think again. "Switch" is primary because the
/// common case is wanting to look at this branch instead of the one running —
/// and because it keeps the URL where the user expects it.
struct PortConflictSheet: View {
    let pending: PendingRun
    let onSwitch: () -> Void
    let onTakeOver: () -> Void
    let onShift: () -> Void
    let onCancel: () -> Void

    private var conflict: PortConflict { pending.conflict }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ports already in use").font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(conflict.clashes) { c in
                    HStack(spacing: 8) {
                        Text(c.target)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 64, alignment: .leading)
                        Text("port \(String(c.port))")
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text(describe(c))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if conflict.shiftIsBestEffort {
                    // An honest caveat beats a button that silently might not
                    // work — and the failure, if it comes, is immediate and
                    // names the fix.
                    Text("""
                         Running alongside passes the new port as PORT. Most \
                         dev servers honour it; if this one does not, the run \
                         stops straight away and says what to change.
                         """)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Spacer(minLength: 0)
            Divider()

            HStack(spacing: 10) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.glass).controlSize(.large)
                Spacer()
                if conflict.canShift {
                    Button("Run on \(String(shiftedFirstPort))", action: onShift)
                        .buttonStyle(.glass).controlSize(.large)
                }
                if !conflict.owners.isEmpty {
                    // Stopping a run of ours is the routine resolution, and
                    // still destructive enough to be red.
                    Button("Stop and Switch", action: onSwitch)
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .tint(.red)
                        .keyboardShortcut(.defaultAction)
                } else if !conflict.outsiders.isEmpty {
                    // A server something else started. Offered, because
                    // refusing outright is unhelpful when it is plainly the
                    // same project — but never the default action, and it says
                    // what it will kill rather than hiding behind a verb.
                    Button(takeOverLabel, action: onTakeOver)
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .tint(.red)
                        .help("Ends the process listed above, then starts this run")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460, height: 300)
    }

    private var takeOverLabel: String {
        conflict.outsiders.count > 1 ? "Take Over Ports" : "Take Over Port"
    }

    private func describe(_ c: PortClash) -> String {
        switch c.kind {
        case .ours:    return "\(c.owner) — a Runbranch run"
        case .outside: return "\(c.owner) — started outside Runbranch"
        case .unknown: return "another app (pid \(c.pid))"
        }
    }

    private var subtitle: String {
        let ours = conflict.owners, outside = conflict.outsiders
        if !ours.isEmpty && outside.isEmpty {
            return "Runbranch is running \(ours.joined(separator: " and ")) on them."
        }
        if ours.isEmpty && !outside.isEmpty {
            return "\(outside.joined(separator: " and ")) is already running, "
                 + "started by something other than Runbranch."
        }
        if !ours.isEmpty && !outside.isEmpty { return "Some are ours, some are not." }
        return "Something outside Runbranch is using them."
    }

    /// The port the first target would move to, so the button names a number
    /// rather than an offset nobody asked to think about.
    private var shiftedFirstPort: Int {
        (conflict.clashes.first?.port ?? 0) + conflict.freeOffset
    }

}

/// What is on every declared port, across every project.
///
/// Answers "what is using 5173" without reaching for lsof, and says whose it is
/// — which lsof cannot, because it does not know which directory belongs to
/// which project.
struct PortsSheet: View {
    let rows: [PortRow]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "network").font(.system(size: 18)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ports").font(.system(size: 14, weight: .semibold))
                    Text("Every port your projects declare, and what is on it")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Divider()

            if rows.isEmpty {
                VStack {
                    Text("No ports declared yet.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { r in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(r.port))
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text("\(r.project) · \(r.target)")
                                            .font(.system(size: 12))
                                        badge(for: r)
                                    }
                                    if !r.isFree && !r.what.isEmpty {
                                        Text(r.what)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            Divider().padding(.leading, 18)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Done", action: onClose).buttonStyle(.glass).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 520, height: 420)
    }

    @ViewBuilder
    private func badge(for r: PortRow) -> some View {
        if r.isFree {
            Badge(text: "free")
        } else if r.isOurs {
            Badge(text: "running", symbol: "bolt.fill", color: .green)
        } else {
            // Not ours: either another project of yours, or the same project
            // started by something else. Either way it blocks this one.
            Badge(text: r.owner.isEmpty ? "in use" : "\(r.owner), outside",
                  symbol: "exclamationmark.triangle.fill", color: .orange)
        }
    }
}

/// A start that is waiting on the user to resolve a port conflict.
struct PendingRun: Identifiable {
    let project: String
    let ref: String
    let preset: String
    let title: String
    let inPlace: Bool
    let conflict: PortConflict
    var id: String { project + ref + preset }
}

/// A port a run needs that something else is already listening on.
///
/// Parsed from `runbranch.sh check-ports`, which is asked BEFORE starting so
/// the user gets a choice rather than a failure. `owner` is the project whose
/// run holds the port, empty when it is something they started themselves;
/// `overridable` says whether the command can be told a different port, which
/// it can only do if the config uses {port}.
struct PortClash: Identifiable {
    let target: String
    let port: Int
    let owner: String
    /// Whether the holder is a run of ours, the same project started by
    /// something else, or unattributable. It decides what can be offered:
    /// stopping our own run is routine, killing a server someone else started
    /// is not.
    let kind: Kind
    let pid: Int

    enum Kind: String { case ours, outside, unknown }
    /// How the target can be told a different port: `explicit` when its command
    /// names one itself, `env` when the only route is PORT in the environment,
    /// which a lot of tooling honours and some ignores.
    let move: PortClash.Move

    enum Move: String { case explicit, env }
    var id: String { target }
}

struct PortConflict {
    let clashes: [PortClash]
    /// The smallest shift that clears every port in the preset.
    let freeOffset: Int

    /// Always offer to move. Every target gets PORT in its environment, so a
    /// shift has a real chance even when the config never anticipated one —
    /// and when the server ignores it, the run fails immediately and says
    /// exactly what to add. Refusing to try was the worse default.
    var canShift: Bool { !clashes.isEmpty }

    /// True when at least one target can only be moved through PORT, so the
    /// offer is a good chance rather than a certainty.
    var shiftIsBestEffort: Bool { clashes.contains { $0.move == .env } }
    /// Projects whose own Runbranch run holds these ports — the ones we can
    /// stop as a matter of course.
    var owners: [String] { names(where: .ours) }

    /// Projects already running outside Runbranch on these ports. Stopping one
    /// means killing a server something else started, which is the user's call
    /// and not a routine one.
    var outsiders: [String] { names(where: .outside) }

    /// Processes we cannot attribute, and would not presume to kill.
    var strangers: [PortClash] { clashes.filter { $0.kind == .unknown } }

    private func names(where kind: PortClash.Kind) -> [String] {
        var seen: [String] = []
        for c in clashes where c.kind == kind && !c.owner.isEmpty && !seen.contains(c.owner) {
            seen.append(c.owner)
        }
        return seen
    }

    static func parse(_ text: String) -> PortConflict? {
        var clashes: [PortClash] = []
        var offset = 1
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "OFFSET", f.count >= 2 { offset = Int(f[1]) ?? 1; continue }
            guard f.count >= 6, let port = Int(f[1]), let pid = Int(f[4]) else { continue }
            clashes.append(PortClash(target: f[0], port: port, owner: f[2],
                                     kind: PortClash.Kind(rawValue: f[3]) ?? .unknown,
                                     pid: pid,
                                     move: PortClash.Move(rawValue: f[5]) ?? .env))
        }
        return clashes.isEmpty ? nil : PortConflict(clashes: clashes, freeOffset: offset)
    }
}

/// A declared port and what is on it, from `runbranch.sh ports`.
struct PortRow: Identifiable {
    let project: String
    let target: String
    let port: Int
    /// `free`, `ours` when this project's own run holds it, `outside` otherwise.
    let state: String
    let owner: String
    let pid: Int
    let what: String

    var id: String { project + target }
    var isFree: Bool { state == "free" }
    var isOurs: Bool { state == "ours" }

    static func parse(_ text: String) -> [PortRow] {
        text.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 8, let port = Int(f[2]) else { return nil }
            return PortRow(project: f[0], target: f[1], port: port, state: f[3],
                           owner: f[4], pid: Int(f[6]) ?? 0, what: f[7])
        }
    }
}

// MARK: - Engine

/// Runs runbranch.sh.
///
/// An app launched from the Dock inherits launchd's environment, which has
/// neither docker (/usr/local/bin) nor pnpm (/opt/homebrew/bin) nor node (fnm
/// mints its bin directory per shell session), so the script would report them
/// all missing. The fix used to be running every single call through a
/// login+interactive zsh, which was wrong twice over: each call paid full
/// shell startup — sourcing .zshrc, and whatever that runs — and any hang in
/// the user's shell config hung the app with it, with no way to tell from the
/// outside what it was waiting for.
///
/// So resolve the login environment exactly once, with a deadline, and run the
/// script directly from then on.
enum Engine {
    static var scriptPath: String {
        if let p = Bundle.main.object(forInfoDictionaryKey: "FLScriptPath") as? String,
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return NSHomeDirectory() + "/Development/runbranch/runbranch.sh"
    }

    /// The user's login shell environment, read once. Interactive, because
    /// PATH additions like fnm's live in .zshrc rather than .zprofile, but
    /// bounded: a shell that does not answer in time must not take the app
    /// down with it.
    static let loginEnvironment: [String: String] = {
        var resolved: [String: String] = [:]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // NUL-separated, so values containing newlines survive the round trip.
        p.arguments = ["-lic", "env -0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        // A shell reading from an inherited stdin would wait forever.
        p.standardInput = FileHandle.nullDevice

        guard (try? p.run()) != nil else { return resolved }

        // Read on a background queue: a full pipe blocks the writer, and a
        // blocked writer never exits, which would deadlock the deadline below.
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            FileHandle.standardError.write(
                "login shell did not answer within 5s; falling back to a default PATH. "
                    .data(using: .utf8)!)
            FileHandle.standardError.write(
                "Run `runbranch.sh doctor` to see what is missing.\n".data(using: .utf8)!)
            return resolved
        }
        p.waitUntilExit()

        for entry in data.split(separator: 0) {
            guard let text = String(data: Data(entry), encoding: .utf8),
                  let eq = text.firstIndex(of: "=") else { continue }
            resolved[String(text[text.startIndex..<eq])] = String(text[text.index(after: eq)...])
        }
        return resolved
    }()

    /// What the script actually runs with. The login shell supplies PATH and
    /// anything else only it knows about; this process's own variables win
    /// where both have a value, so a caller can still override with RB_*.
    static let environment: [String: String] = {
        let own = ProcessInfo.processInfo.environment
        var env = loginEnvironment
        for (k, v) in own where k != "PATH" { env[k] = v }
        if env["PATH"]?.isEmpty ?? true {
            // Last resort. Deliberately explicit rather than silent: doctor
            // will name whatever is still missing.
            env["PATH"] = [own["PATH"], "/opt/homebrew/bin", "/usr/local/bin",
                           "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                .compactMap { $0 }.joined(separator: ":")
        }
        return env
    }()

    static func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scriptPath)
        p.arguments = args
        p.environment = environment
        // Nothing here ever wants input, and an inherited stdin is how a child
        // ends up waiting on a terminal that is not there.
        p.standardInput = FileHandle.nullDevice
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

    /// Git repos under a directory that are not already declared, as
    /// (name, path) pairs.
    static func scan(_ directory: String) -> [(name: String, path: String)] {
        capture(["scan", directory]).out
            .components(separatedBy: "\n")
            .compactMap { line in
                let f = line.components(separatedBy: "\t")
                guard f.count >= 2, !f[0].isEmpty else { return nil }
                return (f[0], f[1])
            }
    }

    @discardableResult
    static func favourite(_ project: String, _ on: Bool) -> String? {
        failure(["favourite", project, on ? "on" : "off"])
    }

    /// Runs a subcommand and returns what it complained about, or nil if it
    /// worked.
    ///
    /// The engine names the command that fixes every failure it reports, which
    /// is worth nothing if the caller throws it away. Anything that is not a
    /// streamed run goes through here.
    static func failure(_ args: [String]) -> String? {
        let p = process(args)
        let err = Pipe()
        p.standardOutput = Pipe()
        p.standardError = err
        do { try p.run() } catch { return "Could not run \(scriptPath)." }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        let tidy = text
            .replacingOccurrences(of: "FAILED", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tidy.isEmpty
            ? "\(args.first ?? "The engine") failed, with nothing to say why."
            : tidy
    }

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

    /// Whether a command resolves on the engine's PATH — which is the login
    /// shell's, not this process's. A direct lookup, since spawning a shell to
    /// answer it cost more than every other check put together.
    static func hasCommand(_ name: String) -> Bool {
        if let cached = commandCache[name] { return cached }
        let fm = FileManager.default
        let found = (environment["PATH"] ?? "")
            .split(separator: ":")
            .contains { fm.isExecutableFile(atPath: "\($0)/\(name)") }
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
                    if let http = response as? HTTPURLResponse {
                        self.status[t.name] = http.statusCode < 500 ? .healthy : .failing
                    } else {
                        // Covers both an error and the case of no error and no
                        // HTTP response, which the previous version assigned
                        // nothing for at all — leaving the status on whatever
                        // it already held, which for a starting run meant
                        // "Starting" forever with nothing to say why.
                        // Not answering yet is not the same as broken.
                        self.status[t.name] = self.status[t.name] == .healthy ? .failing : .starting
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
    /// Observed, not just held. As a plain property this view never subscribed
    /// to the monitor's changes, so the indicator kept whatever it first drew:
    /// a run that had gone healthy still read "Starting" indefinitely.
    @ObservedObject var health: HealthMonitor
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

            // Which kind of run this is, because the two behave differently in
            // the way that matters: a worktree run is a snapshot and will not
            // see your edits, an in-place run is your checkout and will.
            if state.adopted {
                Badge(text: "started elsewhere", symbol: "arrow.up.right.square",
                      color: .orange)
                    .help("Already running when Runbranch looked — not started by it")
            } else if state.inPlace {
                Badge(text: "in place", symbol: "pencil", color: .orange)
                    .help("Running your checkout — edits and uncommitted work are live")
            }

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
                        Badge(text: "default", color: .accentColor)
                    } else if let l = branch.pr.label {
                        Badge(text: l, symbol: branch.pr.symbol, color: branch.pr.color)
                    }
                    Badge(text: branch.owner)
                    // What is actually being worked on. This is the branch your
                    // checkout is sitting on, so it is the one whose edits are
                    // live on disk — and the only one that can be run in place.
                    if branch.isCurrent {
                        Badge(text: "checked out", symbol: "pencil",
                              color: .orange)
                    } else if !branch.checkedOutAt.isEmpty {
                        Badge(text: "in another worktree", symbol: "arrow.triangle.branch",
                              color: .purple)
                    }
                    if !isLive && branch.ready {
                        Badge(text: "ready", symbol: "bolt.fill", color: .green)
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

    /// Which screen to photograph. The docs need more than one, and opening a
    /// sheet by hand before every capture is not automation.
    enum Scene: String { case main, settings, scan, logs, about }

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
                        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// Every declared port and what is on it.
    @State private var portRows: [PortRow] = []
    /// Projects whose ports are held by something Runbranch did not start.
    @State private var occupiedElsewhere: Set<String> = []
    @State private var showingPorts = false
    @State private var hoveringProjects = false
    // Persisted: collapsing a section is a preference, and having it spring
    // back open on every launch would make it pointless.
    @AppStorage("sidebar.running.expanded")    private var runningExpanded = true
    @AppStorage("sidebar.favourites.expanded") private var favouritesExpanded = true
    @AppStorage("sidebar.projects.expanded")   private var projectsExpanded = true

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
                            // Abbreviated, like Finder and the rest of the app.
                            // A full path here also puts the account name into
                            // any screenshot of this sheet.
                            Text((f["REPO"] ?? "").abbreviatingHome)
                                .font(.system(size: 11, design: .monospaced))
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

/// First run, and the "Scan for projects" flow afterwards.
///
/// The scan does not start on its own. Walking somebody's home directory
/// before they have asked is the kind of helpfulness that reads as a liberty,
/// so the folder is shown, pre-filled, and waits.
struct ScanSheet: View {
    let onClose: (_ added: Int) -> Void

    // Overridable so documentation captures do not publish a real account name.
    @State private var directory = ProcessInfo.processInfo.environment["RB_SCAN_ROOT"]
        ?? NSHomeDirectory() + "/Development"
    @State private var found: [(name: String, path: String)] = []
    @State private var chosen: Set<String> = []
    @State private var phase: Phase = .idle
    @State private var progress = 0.0
    @State private var currentName = ""

    enum Phase { case idle, scanning, results, adding, done }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Find projects").font(.system(size: 14, weight: .semibold))
                    Text("Runbranch reads each repository and proposes a config you can correct.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Divider()

            switch phase {
            case .idle, .scanning:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("Folder", text: $directory)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button("Choose…", action: chooseFolder)
                    }
                    Text("Git repositories up to three levels deep, ignoring node_modules.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if phase == .scanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(18)

            case .results:
                if found.isEmpty {
                    ContentUnavailableView("Nothing new here", systemImage: "folder",
                        description: Text("No git repositories under that folder that are not already declared."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(found, id: \.path) { repo in
                            Toggle(isOn: Binding(
                                get: { chosen.contains(repo.path) },
                                set: { on in
                                    if on { chosen.insert(repo.path) }
                                    else { chosen.remove(repo.path) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(repo.name).font(.system(size: 12))
                                    Text(repo.path.abbreviatingHome)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }

            case .adding, .done:
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(width: 260)
                    Text(phase == .done ? "Done" : "Reading \(currentName)…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                if phase == .results && !found.isEmpty {
                    Button(chosen.count == found.count ? "Select none" : "Select all") {
                        chosen = chosen.count == found.count ? [] : Set(found.map(\.path))
                    }
                    .buttonStyle(.glass).controlSize(.large)
                }
                Spacer()
                Button("Cancel") { onClose(0) }
                    .buttonStyle(.glass).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                switch phase {
                case .idle, .scanning:
                    Button("Scan") { scan() }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(phase == .scanning)
                case .results:
                    Button("Add \(chosen.count)") { add() }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen.isEmpty)
                case .adding, .done:
                    Button("Done") { onClose(chosen.count) }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .disabled(phase != .done)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 560, height: 480)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: directory)
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }

    private func scan() {
        phase = .scanning
        let dir = directory
        Task {
            let repos = await Task.detached { Engine.scan(dir) }.value
            found = repos
            // Nothing pre-selected: adding twenty projects nobody asked for is
            // worse than making them tick the two they want.
            chosen = []
            phase = .results
        }
    }

    private func add() {
        phase = .adding
        let paths = found.filter { chosen.contains($0.path) }
        Task {
            for (i, repo) in paths.enumerated() {
                currentName = repo.name
                _ = await Task.detached { Engine.add(repo.path) }.value
                progress = Double(i + 1) / Double(paths.count)
            }
            phase = .done
        }
    }
}

/// Shown when no projects are declared. The alternative was an empty sidebar
/// beside an empty pane, which tells a first-time user nothing at all.
/// The bare glyph on transparency, not the app icon. Inside the app the
/// rounded tile is redundant — the window already is the app — and the tile's
/// light background sits badly on a dark splash.
enum Mark {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Mark", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

struct WelcomeView: View {
    let onScan: () -> Void
    let onAdd: () -> Void

    /// Both buttons get the same width so neither looks like the runt. Sizing
    /// to the longer label and letting the shorter one match is the usual fix.
    private let buttonWidth: CGFloat = 124

    var body: some View {
        VStack(spacing: 0) {
            if let mark = Mark.image {
                Image(nsImage: mark)
                    .resizable().frame(width: 84, height: 84)
                    .padding(.bottom, 16)
            }
            Text("Runbranch").font(.system(size: 24, weight: .semibold))
            Text("Run any branch of any project, on a real port.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("Isolated in a throwaway worktree, or in place in your checkout.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)

            HStack(spacing: 10) {
                Button(action: onScan) {
                    Text("Scan…").frame(width: buttonWidth)
                }
                .buttonStyle(.glassProminent)
                Button(action: onAdd) {
                    Text("Add a project…").frame(width: buttonWidth)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .padding(.top, 24)

            Text("Projects are plain config files you can commit to the repository.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.top, 22)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Sets the window's content size when the app crosses between onboarding and
/// the browser. Onboarding needs a fraction of the room the branch list does,
/// and a splash floating in a half-empty 1000pt window reads as a bug.
///
/// Only acts on a transition, so a window the user has resized by hand is left
/// alone until the mode actually changes.
struct WindowSizer: NSViewRepresentable {
    let compact: Bool
    static let compactSize = NSSize(width: 520, height: 400)
    static let fullSize = NSSize(width: 1000, height: 720)

    final class Coordinator { var applied: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.applied != compact else { return }
        context.coordinator.applied = compact
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let size = compact ? Self.compactSize : Self.fullSize
            window.setContentSize(size)
            window.styleMask = compact
                ? window.styleMask.subtracting(.resizable)
                : window.styleMask.union(.resizable)
            window.center()
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
    @State private var scanning = false
    @State private var loadingProjects = true
    @StateObject private var runner = Runner()
    @StateObject private var health = HealthMonitor()
    @Environment(\.openWindow) private var openWindow
    @State private var presentation = Presentation.current
    @State private var removing: Project?
    @State private var pendingRun: PendingRun?
    /// What the engine last complained about, for anything that is not a
    /// streamed run. Without this the app simply swallowed those failures.
    @State private var problem: String?
    /// Every declared port and what is on it.
    @State private var portRows: [PortRow] = []
    /// Projects whose ports are held by something Runbranch did not start.
    @State private var occupiedElsewhere: Set<String> = []
    @State private var showingPorts = false
    @State private var hoveringProjects = false
    // Persisted: collapsing a section is a preference, and having it spring
    // back open on every launch would make it pointless.
    @AppStorage("sidebar.running.expanded")    private var runningExpanded = true
    @AppStorage("sidebar.favourites.expanded") private var favouritesExpanded = true
    @AppStorage("sidebar.projects.expanded")   private var projectsExpanded = true

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
            if state.adopted {
                // `stop` has no state to work from — there is no run of ours.
                // Ending it means ending the process on the port, which is the
                // one thing kill-port is careful about.
                return ("Stop", true, { stopAdopted(snap) })
            }
            return ("Stop", true, { run(["stop", p], "Stopping \(ref)") })
        }
        // The branch the checkout is on runs IN PLACE by default.
        //
        // A worktree of it would be a second copy of code that is already on
        // disk, pinned to a commit, that cannot show an edit — which is the
        // opposite of what anyone wants from the branch they are working on. So
        // the default inverts here, and the isolated run moves to the menu.
        let inPlace = selectedBranch?.canRunInPlace ?? false

        if state.running {
            // do_run stops whatever this project has running first, and says
            // so as it goes.
            return ("Switch", false, {
                startChecking(p, ref, preset, "Switching to \(ref)", inPlace: inPlace)
            })
        }
        let label = inPlace ? "Run in Place" : "Start"
        return (label, false, {
            startChecking(p, ref, preset, "Starting \(ref)", inPlace: inPlace)
        })
    }

    var body: some View {
        Group {
        if projects.isEmpty && !loadingProjects {
            WelcomeView(onScan: { scanning = true }, onAdd: addProject)
        } else {
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
        }
        }
        .background(WindowSizer(compact: projects.isEmpty && !loadingProjects))
        // Hiding the toolbar background removed the seam above the sidebar but
        // left content scrolling visibly under the title. `.automatic` gives
        // both: nothing at rest, a material once something scrolls beneath it.
        .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        .task {
            // Reclaim before reading state, so a crash's leftovers are gone
            // before anything is drawn rather than showing as a phantom run.
            _ = await Task.detached { Engine.reclaim() }.value
            loadProjects()

            // The status item lives outside any view, so hand it the actions
            // it needs and keep its state fed from here.
            let bar = MenuBarController.shared
            // Focuses the existing window rather than making one, because the
            // scene above is a Window and not a WindowGroup.
            bar.onOpenWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            bar.onStop = {
                guard let p = selectedProject else { return }
                run(["stop", p], "Stopping")
            }
            bar.apply(Presentation.current, initial: true)

            let bridge = MenuBridge.shared
            bridge.addProject = { addProject() }
            bridge.scanForProjects = { scanning = true }
            bridge.refresh = { Task { await reload() } }
            bridge.hasSelection = { selectedProject != nil }
            bridge.editProject = {
                guard let p = selectedProject else { return }
                editingProject = .init(id: p)
            }
            if SelfTest.requested {
                SelfTest.armWatchdog()
                // Wait for the things a launch is supposed to produce, rather
                // than sleeping a fixed amount and hoping.
                var waited = 0
                while waited < 120 {
                    let ready = !projects.isEmpty && selectedProject != nil
                        && !(snapshot?.state.running ?? false ? health.status.isEmpty : false)
                    if ready && waited > 10 { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }

                let realWindows = NSApp.windows.filter {
                    $0.isVisible && $0.parent == nil && !($0 is NSPanel)
                        && $0.frame.width > 200
                }
                let st = snapshot?.state
                let worst = st.map { s -> String in
                    let all = s.targets.compactMap { health.status[$0.name] }
                    if all.isEmpty { return "unknown" }
                    if all.contains(.failing) { return "failing" }
                    if all.contains(.starting) { return "starting" }
                    return all.allSatisfy { $0 == .healthy } ? "healthy" : "mixed"
                } ?? "no-state"

                SelfTest.report([
                    ("windows", String(realWindows.count)),
                    ("projects", String(projects.count)),
                    ("selected", selectedProject ?? ""),
                    ("running", (st?.running ?? false) ? "1" : "0"),
                    ("targets", String(st?.targets.count ?? 0)),
                    ("health", worst),
                    ("problem", problem ?? ""),
                ])
                exit(0)
            }

            if let path = Screenshot.path {
                // Open whatever the requested scene needs, then let it settle.
                switch Screenshot.scene {
                case .main:
                    break
                case .settings:
                    // Projects load asynchronously, so a selection may not
                    // exist yet. Waiting beats capturing an empty sheet.
                    var waited = 0
                    while selectedProject == nil && waited < 40 {
                        try? await Task.sleep(for: .milliseconds(100))
                        waited += 1
                    }
                    if let p = selectedProject {
                        editingProject = .init(id: p)
                    } else {
                        Screenshot.note("no project selected; settings sheet not opened")
                    }
                case .scan:
                    scanning = true
                case .about:
                    AboutPanel.shared.show()
                case .logs:
                    showingLogs = true
                }
                if Screenshot.scene != .main { try? await Task.sleep(for: .seconds(1.2)) }
                // The first health poll can take up to its 3s timeout, and the
                // watch only starts once state has loaded. Waiting for a real
                // answer beats padding a sleep and hoping.
                var settle = 0
                while settle < 60 {
                    let pending = health.status.values.contains {
                        $0 == .unknown || $0 == .starting
                    }
                    if !pending && !health.status.isEmpty { break }
                    if health.status.isEmpty && settle > 20 { break }
                    try? await Task.sleep(for: .milliseconds(200))
                    settle += 1
                }
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
                Button("", action: stopSelected)
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
        .toolbar(projects.isEmpty ? .hidden : .automatic, for: .windowToolbar)
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
                    if let b = selectedBranch, let p = selectedProject, b.canRunInPlace {
                        // In place is the default for this branch, so the menu
                        // offers the other one.
                        Button("Run in an isolated worktree instead…") {
                            startChecking(p, b.ref, preset,
                                          "Starting \(b.ref) in a worktree",
                                          inPlace: false)
                        }
                        Divider()
                    }
                    Button("Add project…") { addProject() }
                    Divider()
                    Button("Ports…") { showingPorts = true }
                    Button("Open logs in Finder") { openLogs() }
                    if let p = project {
                        Button("Reveal repository in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.repo)
                        }
                        Divider()
                        Button("Project settings…") { editingProject = .init(id: p.id) }
                        Button("Open config in a text editor") { editConfig(p.id) }
                    }
                    Divider()
                    Picker("Show Runbranch in", selection: Binding(
                        get: { presentation },
                        set: { presentation = $0; MenuBarController.shared.apply($0) })) {
                        ForEach(Presentation.allCases) { Text($0.label).tag($0) }
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
                Task {
                    // An engine operation can change the project set — removal
                    // does — and a selection pointing at something that no
                    // longer exists leaves the detail pane describing a project
                    // that is gone.
                    await syncProjectList()
                    await reload()
                    await refreshLive()
                }
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
        .confirmationDialog(
            "Remove \(removing?.name ?? "")?",
            isPresented: Binding(get: { removing != nil },
                                 set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Project", role: .destructive) {
                guard let p = removing else { return }
                removing = nil
                run(["remove", p.id], "Removing \(p.name)")
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("""
                 Deletes this project's config file and any worktrees, logs and \
                 ports Runbranch created for it.

                 The repository at \(removing?.repo.abbreviatingHome ?? "") \
                 is not touched.
                 """)
        }
        .alert("Runbranch could not do that", isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            // The engine's own words, including the command it suggests. A
            // paraphrase would lose the useful half.
            Text(problem ?? "")
        }
        .sheet(item: $pendingRun) { pending in
            PortConflictSheet(
                pending: pending,
                onSwitch: { resolveBySwitching(pending) },
                onTakeOver: { resolveByTakingOver(pending) },
                onShift: { resolveByShifting(pending) },
                onCancel: { pendingRun = nil })
        }
        .sheet(isPresented: $showingPorts) {
            PortsSheet(rows: portRows) { showingPorts = false }
        }
        .sheet(isPresented: $scanning) {
            ScanSheet { added in
                scanning = false
                guard added > 0 else { return }
                Task {
                    projects = await Task.detached { Engine.projects() }.value
                    if selectedProject == nil { selectedProject = projects.first?.id }
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

    /// Ask the engine what holds the ports before starting anything.
    ///
    /// The alternative is starting and failing, which is what used to happen —
    /// and the failure could not offer to fix itself because by then it was
    /// just text in a log.
    private func startChecking(_ project: String, _ ref: String, _ preset: String,
                               _ title: String, inPlace: Bool = false) {
        Task {
            let result = await Task.detached {
                Engine.capture(["check-ports", project, preset])
            }.value
            if result.code != 0, let conflict = PortConflict.parse(result.out) {
                pendingRun = PendingRun(project: project, ref: ref,
                                        preset: preset, title: title,
                                        inPlace: inPlace, conflict: conflict)
            } else {
                run(runArgs(project, ref, preset, inPlace: inPlace), title)
            }
        }
    }

    /// End a run Runbranch did not start, target by target.
    private func stopAdopted(_ snap: ProjectSnapshot) {
        let pids = snap.state.targets.filter(\.alive).map { String($0.pid) }
        Task {
            for pid in pids {
                let err = await Task.detached { Engine.failure(["kill-port", pid]) }.value
                if let err { problem = err; break }
            }
            await syncProjectList()
            await reload()
            await refreshLive()
        }
    }

    private func stopSelected() {
        guard let snap = current, snap.state.running, let p = selectedProject else { return }
        run(["stop", p], "Stopping \(snap.state.ref)")
    }

    private func runArgs(_ project: String, _ ref: String, _ preset: String,
                         inPlace: Bool, offset: Int? = nil) -> [String] {
        var args = ["run", project, ref, preset]
        if let offset { args.append(String(offset)) }
        if inPlace { args.append("--in-place") }
        return args
    }

    /// End a server something else started, then start ours.
    ///
    /// Only ever reached from an explicit button naming what it will kill. The
    /// engine does the killing so the rule about which processes are fair game
    /// lives in one place.
    private func resolveByTakingOver(_ pending: PendingRun) {
        let pids = pending.conflict.clashes
            .filter { $0.kind == .outside }
            .map { String($0.pid) }
        pendingRun = nil
        Task {
            for pid in pids {
                let err = await Task.detached { Engine.failure(["kill-port", pid]) }.value
                if let err { problem = err; return }
            }
            run(runArgs(pending.project, pending.ref, pending.preset,
                        inPlace: pending.inPlace), pending.title)
        }
    }

    /// Stop whatever of ours holds the ports, then start. The engine refuses to
    /// remove a running project's config for the same reason: leaving servers
    /// with nothing that knows how to stop them is worse than not starting.
    private func resolveBySwitching(_ pending: PendingRun) {
        let owners = pending.conflict.owners
        pendingRun = nil
        Task {
            for owner in owners {
                let stopErr = await Task.detached { Engine.failure(["stop", owner]) }.value
                if let stopErr {
                    // Carrying on would hit the same ports and fail again, with
                    // a less useful message than this one.
                    problem = stopErr
                    return
                }
            }
            await syncProjectList()
            run(runArgs(pending.project, pending.ref, pending.preset,
                        inPlace: pending.inPlace), pending.title)
        }
    }

    private func resolveByShifting(_ pending: PendingRun) {
        let offset = pending.conflict.freeOffset
        pendingRun = nil
        run(runArgs(pending.project, pending.ref, pending.preset,
                    inPlace: pending.inPlace, offset: offset), pending.title)
    }

    private func run(_ args: [String], _ title: String) {
        sheetTitle = title
        showingRun = true
        runner.start(args)
    }

    /// Re-read the project list and drop a selection that no longer resolves.
    private func syncProjectList() async {
        let found = await Task.detached { Engine.projects() }.value
        projects = found
        if let sel = selectedProject, !found.contains(where: { $0.id == sel }) {
            cache[sel] = nil
            snapshot = nil
            selectedProject = found.first?.id
        }
    }

    private func loadProjects() {
        Task {
            let found = await Task.detached { Engine.projects() }.value
            projects = found
            loadingProjects = false
            if selectedProject == nil {
                // For a screenshot or a self-test, prefer a project that is
                // actually running: the status strip is the most informative
                // thing on screen, and an idle project hides it — along with
                // anything a test wanted to assert about it.
                let unattended = Screenshot.path != nil || SelfTest.requested
                let live = unattended
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

        // Whatever is on the ports, including servers Runbranch did not start.
        // Read in the same sweep that finds live runs, so it is right on launch
        // and after every operation without anyone pressing anything.
        let rows = await Task.detached { PortRow.parse(Engine.capture(["ports"]).out) }.value
        portRows = rows
        occupiedElsewhere = Set(rows.filter { $0.state == "outside" }.map(\.project))
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

        let bar = MenuBarController.shared
        bar.project = projects.first { $0.id == snap.id }?.name ?? snap.id
        bar.branch = snap.state.ref
        bar.running = snap.state.running

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
    /// Favourites and Running are both promotions, so a project appears in the
    /// higher one only — listing it twice would be worse than either.
    private var favourites: [Project] {
        projects.filter { $0.favourite && !liveProjects.contains($0.id) }
    }
    private var others: [Project] {
        projects.filter { !$0.favourite && !liveProjects.contains($0.id) }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedProject) {
            // Collapsible, which is what was missing.
            //
            // Mail puts a new-folder icon beside the collapse chevron in its
            // sidebar headers, and the reason ours had no chevron to sit beside
            // is that a Section only gets one when it is given an isExpanded
            // binding. With one, SwiftUI supplies the control and lays it out
            // after the header content — so the plus lands to its left, which
            // is the arrangement Mail has.
            if !live.isEmpty {
                Section("Running", isExpanded: $runningExpanded) {
                    ForEach(live) { projectRow($0, isLive: true) }
                }
            }
            if !favourites.isEmpty {
                Section("Favourites", isExpanded: $favouritesExpanded) {
                    ForEach(favourites) { projectRow($0, isLive: false) }
                }
            }
            Section(isExpanded: $projectsExpanded) {
                ForEach(others) { projectRow($0, isLive: false) }
            } header: {
                // The system styles the automatic label but not content given
                // to it, so the plus matches by hand: same secondary colour and
                // weight as the label, revealed on hover like the chevron.
                HStack(spacing: 0) {
                    Text("Projects")
                    Spacer(minLength: 0)
                    Menu {
                        Button("Add a Project…") { addProject() }
                        Button("Scan for Projects…") { scanning = true }
                    } label: {
                        Image(systemName: "plus")
                            // Header labels are ~11pt semibold secondary; the
                            // glyph reads a shade small at that size, so 12.
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            // A hit area worth aiming at, without the glyph
                            // growing to match.
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .opacity(hoveringProjects ? 1 : 0)
                    .help("Add or scan for projects")
                }
                // The whole row is the hover target, so the button does not
                // have to be found before it appears.
                .contentShape(Rectangle())
                .onHover { hoveringProjects = $0 }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }

    @ViewBuilder
    private func projectRow(_ p: Project, isLive: Bool) -> some View {
        ProjectRow(project: p, isLive: isLive,
                   isSelected: selectedProject == p.id)
            .tag(p.id)
            .contextMenu { projectMenu(p) }
    }

    @ViewBuilder
    private func projectMenu(_ p: Project) -> some View {
        Button(p.favourite ? "Remove from Favourites" : "Add to Favourites") {
            toggleFavourite(p)
        }
        Divider()
        Button("Project settings…") { editingProject = .init(id: p.id) }
        Button("Reveal repository in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.repo)
        }
        Button("Open config in a text editor") { editConfig(p.id) }
        Divider()
        Button("Remove Project…", role: .destructive) { removing = p }
    }

    private func toggleFavourite(_ p: Project) {
        Task {
            let favErr = await Task.detached { Engine.favourite(p.id, !p.favourite) }.value
            if let favErr {
                problem = favErr
                return
            }
            projects = await Task.detached { Engine.projects() }.value
        }
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

}

/// Where the app appears: Dock, menu bar, or both.
///
/// Menu-bar-only means switching NSApplication's activation policy to
/// .accessory, which removes the Dock icon and the app's own menu bar. That is
/// reversible at runtime, but it also means the window can only be summoned
/// from the status item, so the status menu always offers a way back.
enum Presentation: String, CaseIterable, Identifiable {
    case dock, both, menuBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dock:    return "Dock Only"
        case .both:    return "Dock and Menu Bar"
        case .menuBar: return "Menu Bar Only"
        }
    }

    var showsStatusItem: Bool { self != .dock }
    var policy: NSApplication.ActivationPolicy { self == .menuBar ? .accessory : .regular }

    static let key = "presentation"

    static var current: Presentation {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(Presentation.init) ?? .dock
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Owns the status item. One instance, created at launch.
@MainActor
final class MenuBarController: NSObject, ObservableObject {
    static let shared = MenuBarController()

    @Published private(set) var mode: Presentation = .dock
    private var item: NSStatusItem?

    /// What the menu shows. Set by the window as its state changes, since the
    /// status item lives outside any view.
    var project: String?
    var branch: String?
    var running = false
    var healthLabel: String?
    var onOpenWindow: (() -> Void)?
    var onStop: (() -> Void)?

    /// `initial` is the application of the saved setting at launch, which must
    /// not summon a window: SwiftUI has already made one, and asking for
    /// another opens a duplicate.
    // Menu-bar-only still shows its window at launch, because the scene opens
    // one and closing it here does not work: tearing down ContentView takes
    // with it the openWindow environment action that `onOpenWindow` captured,
    // so the status menu could no longer bring a window back at all. Suppressing
    // the launch window needs the scene to not open one in the first place —
    // `.defaultLaunchBehavior(.suppressed)` — which is a per-scene decision and
    // cannot be made conditional on a runtime setting.
    private var closeObserver: NSObjectProtocol?

    func apply(_ next: Presentation, initial: Bool = false) {
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in MenuBarController.shared.windowClosed() }
            }
        }

        mode = next
        Presentation.current = next
        NSApp.setActivationPolicy(next.policy)

        if next.showsStatusItem {
            if item == nil { install() }
        } else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
        }

        // Leaving .accessory does not bring the window back on its own, and
        // entering it hides one that was open. Either way the user asked for a
        // change of where the app lives, not for their window to vanish.
        if next != .menuBar && !initial {
            NSApp.activate(ignoringOtherApps: true)
            onOpenWindow?()
        }
    }

    private func install() {
        let new = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = new.button {
            // A template image is tinted by the system for light and dark menu
            // bars and inverted while the menu is open. Anything else looks
            // wrong in at least one of those states.
            // NSImage(named:) resolves MenuBarIcon@2x.png alongside the 1x file
            // and builds one image with both, so the item is sharp on Retina.
            // Loading the 1x by URL got that representation only.
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true
                // Never scale the axes independently. The default for a button
                // is proportional, but saying so costs nothing and this glyph
                // is not square, which is exactly when the difference shows.
                button.imageScaling = .scaleProportionallyDown
                // Its own size, deliberately. The mark is wider than it is
                // tall and a status item is variable-width; forcing a square
                // was what made the glyph small.
                button.image = image
            } else {
                button.title = "RB"
            }
            button.toolTip = "Runbranch"
        }
        new.menu = buildMenu()
        item = new
    }

    /// Rebuilt on each open, so it reflects the current run rather than
    /// whatever was true when the item was installed.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func refresh() {
        guard let menu = item?.menu else { return }
        menu.removeAllItems()

        let heading: String
        if let project {
            heading = running
                ? "\(project) — \(branch ?? "?")"
                : "\(project) — not running"
        } else {
            heading = "No project selected"
        }
        let title = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if running, let healthLabel {
            let status = NSMenuItem(title: healthLabel, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        menu.addItem(.separator())

        if running {
            menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "")
                .target = self
        }
        menu.addItem(withTitle: "Open Runbranch", action: #selector(openWindow),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Runbranch", action: #selector(quit), keyEquivalent: "q")
            .target = self
    }

    @objc private func stop() { onStop?() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openWindow() {
        // An .accessory app cannot raise a window, so become .regular first —
        // and then STAY there while the window is up.
        //
        // Reverting on a timer instead does not work: the policy change lands
        // while the window is still being created and takes it with it, so
        // Open silently produced nothing. The Dock icon is tied to whether a
        // window is open, which is also the behaviour people expect from a
        // menu bar app that can show one.
        if mode == .menuBar { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        onOpenWindow?()
    }

    /// Back to accessory once the last window goes away, so the Dock icon does
    /// not linger against the setting.
    func windowClosed() {
        guard mode == .menuBar else { return }
        // The closing window is still in the list at notification time.
        let remaining = NSApp.windows.filter {
            $0.isVisible && $0.parent == nil && !($0 is NSPanel)
        }
        guard remaining.count <= 1 else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refresh() }
}

/// Lets the main menu drive the window's actions.
///
/// Menu commands are built at the App level, where none of ContentView's state
/// is reachable. Rather than duplicate the work behind each command, the view
/// registers what it can do and the menu items call through.
@MainActor
final class MenuBridge: ObservableObject {
    static let shared = MenuBridge()
    var addProject: (() -> Void)?
    var scanForProjects: (() -> Void)?
    var editProject: (() -> Void)?
    var refresh: (() -> Void)?
    /// Nil when nothing is selected, so the menu can disable what needs one.
    var hasSelection: () -> Bool = { false }
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
        let text = pairs.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n") + "\n"
        FileHandle.standardOutput.write(text.data(using: .utf8)!)
        if let out = ProcessInfo.processInfo.environment["RB_SELFTEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
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

/// Owns the About panel. One instance, built on first use.
@MainActor
final class AboutPanel {
    static let shared = AboutPanel()
    private var panel: NSPanel?
    /// So a capture can target this window rather than guessing at it by size.
    /// Guessing picked an invisible 500x500 window AppKit keeps around and
    /// cropped the main window instead.
    nonisolated(unsafe) static var windowNumber: Int?

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            // Not a utility panel: it should not float over everything, and it
            // should go away when the app is not in front.
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AboutView())
            p.contentView = host
            p.setContentSize(host.fittingSize)
            p.center()
            panel = p
            AboutPanel.windowNumber = p.windowNumber
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The About window.
///
/// Not `orderFrontStandardAboutPanel`, which was the first attempt: it renders
/// the icon at a fixed, small size and takes no instruction about it, and it
/// has nowhere to put a link. The layout below follows the same shape as the
/// system panel — icon, name, one line of what it is, version, then the small
/// print — because that shape is what people recognise.
struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            // The app icon rather than the bare mark: the tile is what the
            // system panels show, and it is what the app looks like in the Dock.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .padding(.top, 26)

            Text("Runbranch")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 14)

            Text("Version \(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Spacer(minLength: 14)

            VStack(spacing: 3) {
                Text("Created by Alec McLeod")
                Text("MIT licensed — free to use, change and share")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Link("Runbranch on GitHub", destination: repoURL)
                .font(.system(size: 11))
                .padding(.top, 10)
                .padding(.bottom, 24)
        }
        .multilineTextAlignment(.center)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var repoURL: URL {
        URL(string: "https://github.com/aosmcleod/runbranch")!
    }
}

/// Keeps the app alive with no window open.
///
/// A SwiftUI app terminates when its last window closes, which makes menu-bar
/// only mode impossible: switching to .accessory takes the window away and the
/// app exits with it. In Dock-only mode the old behaviour is right — closing
/// the window of a single-window utility should quit it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        Presentation.current == .dock
    }
}

@main
struct RunBranchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // No window tabbing. It fills View and Window with items — Show Tab
        // Bar, Merge All Windows, Move Tab to New Window — that do nothing
        // useful for a single-window utility whose whole state is one project.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        Window("Runbranch", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)

        .commands {
            // Toggle Sidebar, which View otherwise lacks entirely.
            SidebarCommands()
            CommandGroup(replacing: .help) {
                Button("Runbranch on GitHub") {
                    if let url = URL(string: "https://github.com/aosmcleod/runbranch") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Runbranch") { AboutPanel.shared.show() }
            }
            // Replacing .newItem drops "New Window" with it, which is the
            // right call: a second window on the same projects would show the
            // same state twice and offer no way to tell them apart.
            CommandGroup(replacing: .newItem) {
                Button("Add a Project…") { MenuBridge.shared.addProject?() }
                    .keyboardShortcut("n")
                Button("Scan for Projects…") { MenuBridge.shared.scanForProjects?() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Project Settings…") { MenuBridge.shared.editProject?() }
                    .keyboardShortcut(",")
                    .disabled(!MenuBridge.shared.hasSelection())
                Button("Reveal Projects Folder in Finder") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: Engine.projectsDir)
                }
                Divider()
                Button("Refresh") { MenuBridge.shared.refresh?() }
                    .keyboardShortcut("r")
            }
        }
    }

}

