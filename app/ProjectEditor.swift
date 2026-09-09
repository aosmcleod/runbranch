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

// Editing a project, which is every config key in a sheet rather than a
// text editor.

import SwiftUI
import AppKit

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
