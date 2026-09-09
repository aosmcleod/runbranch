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

// The only place that talks to runbranch.sh. Every subcommand the app uses
// is a function here, and nothing else shells out.

import SwiftUI
import AppKit

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
    /// The engine, which ships inside the bundle.
    ///
    /// It used to be found through an absolute path written into Info.plist at
    /// build time, falling back to a guess at ~/Development/runbranch. Both
    /// only ever worked on the machine that did the building: a copy given to
    /// anyone else would launch and find nothing to run.
    ///
    /// RB_ENGINE overrides it, for pointing a built app at a working copy
    /// without rebuilding.
    static var scriptPath: String {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["RB_ENGINE"],
           fm.isExecutableFile(atPath: override) {
            return override
        }
        if let bundled = Bundle.main.url(forResource: "runbranch", withExtension: "sh"),
           fm.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        // Nothing to run. Say so rather than failing later with a confusing
        // error from every engine call.
        return Bundle.main.bundlePath + "/Contents/Resources/runbranch.sh"
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

    /// Every worktree on disk across every project, and what it costs.
    static func disk() -> [DiskRow] { DiskRow.parse(capture(["disk"]).out) }

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
