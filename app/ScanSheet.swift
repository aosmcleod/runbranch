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

// Finding projects nobody has declared yet.

import SwiftUI
import AppKit

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
