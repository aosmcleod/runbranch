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

    /// Blocking. Used for the short reads (branch list, status).
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

    static func isRunning() -> Bool { capture(["status"]).code == 0 }
}

/// Streams a run into the window, one line at a time.
final class Runner: ObservableObject {
    @Published var lines: [String] = []
    @Published var finished = false
    @Published var failed = false

    private var proc: Process?

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

    func cancel() {
        proc?.terminate()
    }
}

// MARK: - Views

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

    var body: some View {
        HStack(spacing: 8) {
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
            if branch.ready {
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

struct PickerView: View {
    @Binding var selection: String?
    @Binding var target: Target
    @Binding var includeMerged: Bool
    @Binding var showOlder: Bool
    let branches: [Branch]
    let onStart: () -> Void
    let onCancel: () -> Void

    private static let week = 7 * 24 * 60 * 60

    var visible: [Branch] {
        let now = Int(Date().timeIntervalSince1970)
        return branches.filter { b in
            if b.isDefault { return true }          // development is always offered
            if !includeMerged && b.pr == .merged { return false }
            if !showOlder && now - b.timestamp > Self.week { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run a Frankly demo").font(.system(size: 15, weight: .semibold))
                Text("From a throwaway worktree. Your Studio checkout is never touched.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            List(visible, selection: $selection) { branch in
                BranchRow(branch: branch).tag(branch.ref)
            }
            .listStyle(.inset)
            .frame(minHeight: 220)

            Divider()

            HStack(spacing: 16) {
                Toggle("Merged", isOn: $includeMerged)
                Toggle("Older than a week", isOn: $showOlder)
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
                .frame(width: 200)

                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

struct RunView: View {
    @ObservedObject var runner: Runner
    let branch: String
    let target: Target
    let onStop: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !runner.finished {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: runner.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(runner.failed ? .red : .green)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(runner.finished ? (runner.failed ? "Failed" : "Demo running") : "Starting…")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(branch) · \(target.title)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
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
            .frame(minHeight: 260)

            Divider()

            HStack {
                Spacer()
                if runner.finished {
                    Button("Close", action: onClose).keyboardShortcut(.defaultAction)
                } else {
                    Button("Stop", action: onStop)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

struct ContentView: View {
    @State private var branches: [Branch] = []
    @State private var selection: String?
    @State private var target: Target = .web
    @State private var includeMerged = false
    @State private var showOlder = false
    @State private var running = false
    @StateObject private var runner = Runner()

    var body: some View {
        Group {
            if running {
                RunView(runner: runner,
                        branch: selection ?? "",
                        target: target,
                        onStop: { runner.cancel(); running = false },
                        onClose: { NSApp.terminate(nil) })
            } else {
                PickerView(selection: $selection,
                           target: $target,
                           includeMerged: $includeMerged,
                           showOlder: $showOlder,
                           branches: branches,
                           onStart: start,
                           onCancel: { NSApp.terminate(nil) })
            }
        }
        .frame(width: 560, height: 460)
        .task { load() }
    }

    private func load() {
        let found = Engine.branches()
        branches = found
        if selection == nil {
            // Default to the newest branch of yours that is still live.
            selection = found.first(where: { $0.mine && $0.pr != .merged })?.ref
                     ?? found.first(where: { $0.isDefault })?.ref
        }
    }

    private func start() {
        guard let ref = selection else { return }
        running = true
        runner.start(["run", ref, target.rawValue])
    }
}

@main
struct FranklyLauncherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
