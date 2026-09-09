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

// The main window.

import SwiftUI
import AppKit

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

struct ContentView: View {
    @State private var projects: [Project] = []
    @State private var selectedProject: String?
    @State private var liveProjects: Set<String> = []

    /// The one currently displayed, and everything already fetched.
    @State private var snapshot: ProjectSnapshot?
    @State private var cache: [String: ProjectSnapshot] = [:]

    @State private var selection: String?
    @State private var preset = ""

    /// How the branch list is narrowed. Five toggles and a query that are only
    /// ever read together, so they travel together and the predicate that
    /// reads them lives with them.
    struct BranchFilter {
        var mineOnly = false
        var showAllRemote = false
        var showMerged = false
        var showOlder = false
        var query = ""

        var active: Bool { mineOnly || showAllRemote || showMerged || showOlder }
        var search: String { query.trimmingCharacters(in: .whitespaces).lowercased() }
    }
    @State private var filter = BranchFilter()

    /// What is on top of the window.
    ///
    /// One value rather than four booleans, two optionals and a loose title
    /// string. Only one sheet can be up at a time, and the old shape could
    /// represent six at once — as well as a run title with no run sheet to put
    /// it on, which is the pairing that actually went wrong.
    enum Sheet: Identifiable {
        case run(title: String)
        case logs
        case ports
        case scan
        case editing(project: String)
        case resolvingPorts(PendingRun)
        case disk

        /// Identity is the case, not the payload. A sheet does not become a
        /// different sheet because its title changed.
        var id: String {
            switch self {
            case .run:            return "run"
            case .logs:           return "logs"
            case .ports:          return "ports"
            case .scan:           return "scan"
            case .editing(let p): return "editing:\(p)"
            case .disk:           return "disk"
            case .resolvingPorts: return "port-conflict"
            }
        }
    }
    @State private var sheet: Sheet?

    @State private var loadingProjects = true
    @StateObject private var runner = Runner()
    @StateObject private var health = HealthMonitor()
    @Environment(\.openWindow) private var openWindow
    @State private var presentation = Presentation.current
    @State private var removing: Project?
    /// What the engine last complained about, for anything that is not a
    /// streamed run. Without this the app simply swallowed those failures.
    @State private var problem: String?
    /// Every declared port and what is on it.
    @State private var portRows: [PortRow] = []
    /// Every worktree on disk, or nil when it has not been measured.
    ///
    /// Deliberately NOT read on the refresh path. Measuring it means `du -sk`
    /// per worktree, and a worktree holds node_modules — measured at 3.35s
    /// across three worktrees on this machine, against 0.33s for every other
    /// engine call in that sweep put together. Nothing outside the disk sheet
    /// shows the number, so the hot path was paying three seconds for
    /// something nobody could see.
    ///
    /// nil is "not measured yet" and distinct from measured-and-empty, which
    /// is what lets the sheet say "Measuring…" rather than "nothing here".
    @State private var diskRows: [DiskRow]?

    /// A slow tick, so a server started while the window sits idle is noticed.
    ///
    /// Both pictures were read on launch and after every operation and never
    /// otherwise, so they could sit wrong for as long as nobody touched
    /// anything — which is most of the time, since a run is meant to outlive
    /// your attention. Thirty seconds and not a tight poll: each read is one
    /// `lsof` per declared port plus a `ps` to attribute the holder.
    ///
    /// Static, or it would be rebuilt on every render and never fire.
    private static let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
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
        let q = filter.search
        return branches.filter { b in
            // Search overrides the filters: if you typed a branch's name you
            // want to see it, merged and ancient or not.
            if !q.isEmpty {
                return b.ref.lowercased().contains(q) || b.subject.lowercased().contains(q)
            }
            // The default branch and whatever is running are always shown:
            // hiding the thing on screen would be worse than a wide filter.
            if b.isDefault || b.ref == state.ref { return true }
            if filter.mineOnly && !b.mine { return false }
            // A repo can carry hundreds of remote branches and almost none of
            // them are worth looking at. The ones with an open pull request
            // are exactly the reviewable set, so those show by default and
            // the rest are opt-in.
            if b.isRemote && !filter.showAllRemote && b.pr != .open { return false }
            if !filter.showMerged && b.pr == .merged { return false }
            if !filter.showOlder && now - b.timestamp > Self.week { return false }
            return true
        }
    }

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
            WelcomeView(onScan: { present(.scan) }, onAdd: addProject)
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
            bridge.scanForProjects = { present(.scan) }
            bridge.refresh = { Task { await reload() } }
            bridge.hasSelection = { selectedProject != nil }
            bridge.editProject = {
                guard let p = selectedProject else { return }
                present(.editing(project: p))
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

                // After the state fields are settled, so what is read is
                // what the assertions above describe.
                let drawn = await SelfTest.readScreen()

                SelfTest.report([
                    ("windows", String(realWindows.count)),
                    ("projects", String(projects.count)),
                    ("selected", selectedProject ?? ""),
                    ("running", (st?.running ?? false) ? "1" : "0"),
                    ("targets", String(st?.targets.count ?? 0)),
                    ("health", worst),
                    ("problem", problem ?? ""),
                    // Whether the screen could be read at all, separately from
                    // what it said. Conflating them turns a missing permission
                    // into a passing assertion.
                    ("drawnok", drawn.lines == nil ? "0" : "1"),
                    ("drawn", (drawn.lines ?? []).joined(separator: " | ").lowercased()),
                    ("drawnwhy", drawn.why),
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
                        present(.editing(project: p))
                    } else {
                        Screenshot.note("no project selected; settings sheet not opened")
                    }
                case .scan:
                    present(.scan)
                case .about:
                    AboutPanel.shared.show()
                case .logs:
                    // Wait for the run, or the viewer opens over no targets and
                    // sits at "0 lines" whatever the log actually holds.
                    var waitedForRun = 0
                    while !(snapshot?.state.running ?? false) && waitedForRun < 60 {
                        try? await Task.sleep(for: .milliseconds(100))
                        waitedForRun += 1
                    }
                    if snapshot?.state.running ?? false {
                        present(.logs)
                    } else {
                        // Photographing an empty viewer and calling it a log
                        // scene is how this went unnoticed the first time.
                        Screenshot.note("nothing is running; log viewer not opened")
                    }
                case .disk:
                    present(.disk)
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

                Button("") { if let p = selectedProject { present(.editing(project: p)) } }
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
        .searchable(text: $filter.query, placement: .toolbar, prompt: "Search branches")
        .toolbar(projects.isEmpty ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("Only my branches", isOn: $filter.mineOnly)
                    Divider()
                    Toggle("Show merged", isOn: $filter.showMerged)
                    Toggle("Show older than a week", isOn: $filter.showOlder)
                    Toggle("Show all remote branches", isOn: $filter.showAllRemote)
                } label: {
                    // A plain glyph: the chevron a Menu draws by default is
                    // noise, and no native app shows one here.
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(filter.active ? Color.accentColor : .primary)
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
                    Button("Ports…") { present(.ports) }
                    Button("Disk…") { diskRows = nil; present(.disk) }
                    Button("Open logs in Finder") { openLogs() }
                    if let p = project {
                        Button("Reveal repository in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.repo)
                        }
                        Divider()
                        Button("Project settings…") { present(.editing(project: p.id)) }
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
        .sheet(item: $sheet) { which in
            switch which {
            case .run(let title):
                RunSheet(runner: runner, title: title) {
                    sheet = nil
                    if let p = selectedProject { cache[p] = nil }
                    Task {
                        // An engine operation can change the project set —
                        // removal does — and a selection pointing at something
                        // that no longer exists leaves the detail pane
                        // describing a project that is gone.
                        await syncProjectList()
                        await reload()
                        await refreshLive()
                    }
                }
            case .editing(let id):
                ProjectEditor(projectID: id) { changed in
                    sheet = nil
                    guard changed else { return }
                    cache[id] = nil
                    Task {
                        projects = await Task.detached { Engine.projects() }.value
                        await reload()
                    }
                }
            case .resolvingPorts(let pending):
                PortConflictSheet(
                    pending: pending,
                    onSwitch: { resolveBySwitching(pending) },
                    onTakeOver: { resolveByTakingOver(pending) },
                    onShift: { resolveByShifting(pending) },
                    onCancel: { sheet = nil })
            case .ports:
                PortsSheet(rows: portRows) { sheet = nil }
            case .disk:
                DiskSheet(rows: diskRows,
                          onPrune: { pruneGone($0) },
                          onClose: { sheet = nil })
                    .task { await measureDisk() }
            case .scan:
                ScanSheet { added in
                    sheet = nil
                    guard added > 0 else { return }
                    Task {
                        projects = await Task.detached { Engine.projects() }.value
                        if selectedProject == nil { selectedProject = projects.first?.id }
                        await reload()
                    }
                }
            case .logs:
                LogViewer(logDir: current?.logDir ?? "",
                          targets: current?.state.targets ?? []) { sheet = nil }
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
        .onReceive(Self.tick) { _ in
            // Nobody is looking at an occluded window, so nothing here is
            // worth the two processes it costs.
            guard NSApp.occlusionState.contains(.visible) else { return }
            switch sheet {
            // The ports sheet is what this is for. The disk sheet is not: it
            // costs seconds to measure and worktrees do not change size while
            // you look at them.
            case nil, .some(.ports): break
            // A run sheet is streaming and the rest are modal edits. Moving
            // the list under them is worse than being briefly out of date.
            default: return
            }
            Task { await refreshLive() }
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
    }

    private func detail(_ snap: ProjectSnapshot) -> some View {
        let state = snap.state
        let rows = visible(snap)
        return VStack(alignment: .leading, spacing: 0) {

            if rows.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label(filter.query.isEmpty ? "No branches to show" : "No match",
                          systemImage: filter.query.isEmpty ? "arrow.triangle.branch" : "magnifyingglass")
                } description: {
                    Text(filter.query.isEmpty
                         ? "Merged branches and anything older than a week are hidden. Change that in the filter menu."
                         : "No branch matches “\(filter.query)”.")
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
                            Button("Logs") { present(.logs) }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                        if state.running, let url = state.urls.first {
                            Button("Open") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                        // Only when there is something to catch up on. An
                        // always-present Update would be mistaken for Refresh,
                        // which is the confusion this whole thing came out of.
                        if state.running, state.behind > 0 {
                            Button("Update") { updateRun() }
                                .buttonStyle(.glass).controlSize(.large)
                                .help("Re-check-out \(state.ref) at its latest commit "
                                      + "and restart")
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
                present(.resolvingPorts(
                    PendingRun(project: project, ref: ref, preset: preset,
                               title: title, inPlace: inPlace, conflict: conflict)))
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

    /// Re-check-out the ref at its tip and start again.
    ///
    /// A stop and a start under the covers, which is why it is one engine call
    /// rather than two from here: getting the ref, preset or port offset wrong
    /// in between would start a different run than the one that was showing.
    private func updateRun() {
        guard let p = selectedProject, let snap = current, snap.state.running else { return }
        cache[p] = nil
        run(["update", p], "Updating \(snap.state.ref)")
    }

    /// Walk the worktrees and add up what they cost. Seconds, not milliseconds.
    private func measureDisk() async {
        diskRows = await Task.detached { Engine.disk() }.value
    }

    /// Remove one project's worktrees whose branch no longer exists.
    private func pruneGone(_ project: String) {
        Task {
            let err = await Task.detached { Engine.failure(["prune-gone", project]) }.value
            if let err { problem = err }
            diskRows = nil
            await measureDisk()
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
        sheet = nil
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
        sheet = nil
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
        // Deliberately not dismissing first: present() below handles the swap,
        // and clearing it here would collapse both into one update.
        run(runArgs(pending.project, pending.ref, pending.preset,
                    inPlace: pending.inPlace, offset: offset), pending.title)
    }

    private func run(_ args: [String], _ title: String) {
        runner.start(args)
        present(.run(title: title))
    }

    /// Put a sheet up.
    ///
    /// Replacing one sheet with another inside a single update leaves SwiftUI
    /// presenting neither, so a swap dismisses and presents on the next turn of
    /// the loop instead. Only "Run on N" reaches that path — it resolves a port
    /// clash and starts the run with nothing awaited in between — but going
    /// through here means no future caller has to know that.
    private func present(_ next: Sheet) {
        guard sheet != nil else { sheet = next; return }
        sheet = nil
        Task { @MainActor in sheet = next }
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
            // No accessory in this header. Three attempts at a plus that
            // matched the system's own control — sizing, colour, hover — and
            // none of them looked right; SwiftUI styles the label it generates
            // and not content handed to it. Adding a project is on Cmd-N, in
            // the ellipsis menu and on the welcome screen, so nothing is lost
            // by leaving the header alone.
            Section("Projects", isExpanded: $projectsExpanded) {
                ForEach(others) { projectRow($0, isLive: false) }
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
        Button("Project settings…") { present(.editing(project: p.id)) }
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
