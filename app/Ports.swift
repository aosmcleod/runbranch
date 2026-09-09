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

// Who holds a port, and what to do when it is not us. Two sheets: one that
// resolves a clash at run time, one that just shows the picture.

import SwiftUI
import AppKit

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
