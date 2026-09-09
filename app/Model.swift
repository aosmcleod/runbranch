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

// The things the engine reports, as values. No behaviour beyond decoding
// what `runbranch.sh` prints and describing it.

import SwiftUI
import AppKit

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
    /// Commits the ref has gained since this run's worktree was cut. A
    /// worktree is pinned to one commit, so a run cannot see anything pushed
    /// after it started. Always 0 in place, where the working tree is live.
    var behind = 0
    /// The branch the checkout sits on now, when an in-place run is no longer
    /// on the one it was started for. Empty when it is where it should be.
    var switchedTo = ""
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
            case "behind" where f.count >= 2:
                behind = Int(f[1]) ?? 0
            case "switched" where f.count >= 2:
                switchedTo = f[1]
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
/// One worktree on disk: what it cost, and whether anything still wants it.
struct DiskRow: Identifiable {
    let project: String
    let slug: String
    let ref: String
    let kb: Int
    /// `running`, `gone` when the ref no longer exists, `idle` otherwise.
    let state: String

    var id: String { project + "/" + slug }
    var isGone: Bool { state == "gone" }
    var isRunning: Bool { state == "running" }

    var size: String { Self.formatted(kb: kb) }

    /// One formatter, and not the `ByteCountFormatter.string` class method:
    /// that one spells zero as "Zero KB", which read as a bug in the sheet
    /// footer and would read as one on any empty worktree too.
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func formatted(kb: Int) -> String {
        bytes.string(fromByteCount: Int64(kb) * 1024)
    }

    static func parse(_ text: String) -> [DiskRow] {
        text.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5 else { return nil }
            return DiskRow(project: f[0], slug: f[1], ref: f[2],
                           kb: Int(f[3]) ?? 0, state: f[4])
        }
    }
}

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
