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

// What the worktrees cost, and getting rid of the ones nothing wants.

import SwiftUI
import AppKit

struct DiskSheet: View {
    /// nil until the walk finishes. It takes seconds, so saying so beats
    /// showing an empty list that looks like an answer.
    let rows: [DiskRow]?
    /// Prunes one project's dead worktrees and hands back the new picture.
    let onPrune: (String) -> Void
    let onClose: () -> Void

    private var known: [DiskRow] { rows ?? [] }
    private var total: Int { known.reduce(0) { $0 + $1.kb } }
    private var spare: Int { known.filter { !$0.isRunning }.reduce(0) { $0 + $1.kb } }
    /// Projects with at least one worktree whose ref no longer exists.
    private var prunable: [String] {
        var seen: [String] = []
        for r in known where r.isGone && !seen.contains(r.project) { seen.append(r.project) }
        return seen
    }

    /// Spelled out rather than interpolated, because the obvious version said
    /// "1 worktrees" and "Zero KB not in use".
    private var summary: String {
        guard let rows else { return "Measuring…" }
        guard !rows.isEmpty else { return "Nothing on disk yet" }
        let count = rows.count == 1 ? "1 worktree" : "\(rows.count) worktrees"
        let size = DiskRow.formatted(kb: total)
        guard spare > 0 else { return "\(count) · \(size), all of it in use" }
        return "\(count) · \(size), \(DiskRow.formatted(kb: spare)) not in use"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 18)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Disk").font(.system(size: 14, weight: .semibold))
                    Text(summary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Divider()

            if rows == nil {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Adding up what the worktrees cost.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if known.isEmpty {
                VStack(spacing: 4) {
                    Text("No worktrees yet.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("One is made the first time you run a branch.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(known) { r in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(r.ref == "?" ? r.slug : r.ref)
                                            .font(.system(size: 12))
                                            .lineLimit(1).truncationMode(.middle)
                                        badge(for: r)
                                    }
                                    Text(r.project)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 8)
                                Text(r.size)
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            Divider().padding(.leading, 18)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                // Offered rather than waited for. The whole point of a
                // throwaway worktree is that you stop thinking about it, so
                // something has to raise it.
                if rows == nil {
                    EmptyView()
                } else if prunable.isEmpty {
                    Text("Nothing to reclaim — every worktree's branch still exists.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(prunable.count == 1
                         ? "One project has worktrees whose branch is gone"
                         : "\(prunable.count) projects have worktrees whose branch is gone")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !prunable.isEmpty {
                    // Deliberately not "merged": a squash-merge leaves a
                    // branch looking unmerged, so that heuristic would either
                    // miss the common case or delete work.
                    Menu("Reclaim…") {
                        ForEach(prunable, id: \.self) { p in
                            Button(p) { onPrune(p) }
                        }
                    }
                    .menuStyle(.button).controlSize(.large).fixedSize()
                }
                Button("Done", action: onClose)
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        // 520 to match the Ports sheet, and because at 460 the footer line about
        // reclaimable worktrees wrapped onto two.
        .frame(width: 520, height: 400)
    }

    @ViewBuilder
    private func badge(for r: DiskRow) -> some View {
        if r.isRunning {
            Badge(text: "running", symbol: "bolt.fill", color: .green)
        } else if r.isGone {
            Badge(text: "branch gone", symbol: "trash", color: .orange)
                .help("The branch this was cut from no longer exists")
        } else {
            Badge(text: "idle")
        }
    }
}
