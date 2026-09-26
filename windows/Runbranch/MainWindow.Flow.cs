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

// What the window does: the start flow with its port check, the three ways
// out of a port conflict, streamed runs, stopping, and every sheet the window
// opens (ContentView.swift: startChecking, resolveBy*, run, stopAdopted,
// updateRun, addProject, and the sheet handlers). Every sheet goes through
// Sheets.*; what a sheet decides comes back as its result and is acted on here,
// so the start flow stays in one place, as it does on the Mac.

using Microsoft.UI.Xaml;
using Runbranch.Dialogs;

namespace Runbranch;

public sealed partial class MainWindow
{
    /// <summary>
    /// Ask the engine what holds the ports before starting anything.
    ///
    /// The alternative is starting and failing, which is what used to happen —
    /// and the failure could not offer to fix itself because by then it was
    /// just text in a log.
    /// </summary>
    async Task StartChecking(string project, string @ref, string chosenPreset, string title, bool inPlace)
    {
        if (Root.XamlRoot is not { } root) return;
        var conflict = await Task.Run(() => Engine.CheckPorts(project, chosenPreset));
        if (conflict is null)
        {
            await Run(Engine.RunArgs(project, @ref, chosenPreset, inPlace: inPlace), title);
            return;
        }

        var pending = new PendingRun(project, @ref, chosenPreset, title, inPlace, conflict);
        switch (await Sheets.PortConflict(root, pending))
        {
            case PortResolution.StopAndSwitch: await ResolveBySwitching(pending); break;
            case PortResolution.TakeOver: await ResolveByTakingOver(pending); break;
            case PortResolution.Shift: await ResolveByShifting(pending); break;
        }
    }

    /// <summary>
    /// Stop whatever of ours holds the ports, then start. The engine refuses to
    /// remove a running project's config for the same reason: leaving servers
    /// with nothing that knows how to stop them is worse than not starting.
    /// </summary>
    async Task ResolveBySwitching(PendingRun pending)
    {
        foreach (var owner in pending.Conflict.Owners)
        {
            var err = await Task.Run(() => Engine.Stop(owner));
            if (err is not null)
            {
                // Carrying on would hit the same ports and fail again, with a
                // less useful message than this one.
                await ShowProblem(err);
                return;
            }
        }
        await SyncProjectList();
        await Run(Engine.RunArgs(pending.Project, pending.Ref, pending.Preset, inPlace: pending.InPlace), pending.Title);
    }

    /// <summary>
    /// End a server something else started, then start ours.
    ///
    /// Only ever reached from an explicit button naming what it will kill. The
    /// engine does the killing so the rule about which processes are fair game
    /// lives in one place.
    /// </summary>
    async Task ResolveByTakingOver(PendingRun pending)
    {
        var pids = pending.Conflict.Clashes.Where(c => c.Kind == PortClash.Kinds.Outside).Select(c => c.Pid).ToList();
        foreach (var pid in pids)
        {
            var err = await Task.Run(() => Engine.KillPort(pid));
            if (err is not null)
            {
                await ShowProblem(err);
                return;
            }
        }
        await Run(Engine.RunArgs(pending.Project, pending.Ref, pending.Preset, inPlace: pending.InPlace), pending.Title);
    }

    Task ResolveByShifting(PendingRun pending) =>
        Run(Engine.RunArgs(pending.Project, pending.Ref, pending.Preset, pending.Conflict.FreeOffset, pending.InPlace), pending.Title);

    /// <summary>
    /// A streamed engine command in the Run sheet, and what closing it means:
    /// the cache is stale, and an operation can change the project set —
    /// removal does — so the list is re-read before anything is redrawn. A
    /// selection pointing at something that no longer exists would leave the
    /// detail pane describing a project that is gone.
    /// </summary>
    async Task Run(IReadOnlyList<string> args, string title)
    {
        if (Root.XamlRoot is not { } root) return;
        await Sheets.Run(root, title, args);
        if (selectedProject is { } p) cache.Remove(p);
        await SyncProjectList();
        await Reload();
        await RefreshLive();
    }

    /// <summary>End a run Runbranch did not start, target by target.</summary>
    async Task StopAdopted(ProjectSnapshot snap)
    {
        foreach (var pid in snap.State.Targets.Where(t => t.Alive).Select(t => t.Pid).ToList())
        {
            var err = await Task.Run(() => Engine.KillPort(pid));
            if (err is not null)
            {
                await ShowProblem(err);
                break;
            }
        }
        cache.Remove(snap.Id);
        await SyncProjectList();
        await Reload();
        await RefreshLive();
    }

    /// <summary>
    /// Shift+F5 and Ctrl+. — the selected project's run, whichever branch is
    /// selected. An adopted run goes through kill-port, as the Stop button's
    /// does; the Mac's shortcut sent `stop`, which has nothing to stop there.
    /// </summary>
    void StopSelected()
    {
        if (Showing is not { State.Running: true } snap || selectedProject is not { } p) return;
        if (snap.State.Adopted) _ = StopAdopted(snap);
        else _ = Run(Engine.StopArgs(p), $"Stopping {snap.State.Ref}");
    }

    /// <summary>
    /// Stop from the notification-area menu. With the window on screen it is
    /// the same streamed stop as anywhere else; hidden, a sheet would stream
    /// into a window nobody can see, so it stops quietly and only surfaces the
    /// window if the engine had something to say.
    /// </summary>
    public void StopFromTray()
    {
        if (IsOnScreen)
        {
            StopSelected();
            return;
        }
        _ = StopQuietly();
    }

    async Task StopQuietly()
    {
        if (selectedProject is not { } p) return;
        var snap = Showing ?? await Task.Run(() => ProjectSnapshot.Load(p));
        if (!snap.State.Running) return;
        string? err = null;
        if (snap.State.Adopted)
        {
            foreach (var t in snap.State.Targets.Where(t => t.Alive).ToList())
                err ??= await Task.Run(() => Engine.KillPort(t.Pid));
        }
        else
        {
            err = await Task.Run(() => Engine.Stop(p));
        }
        cache.Remove(p);
        await SyncProjectList();
        await Reload();
        await RefreshLive();
        if (err is not null)
        {
            Present();
            await ShowProblem(err);
        }
    }

    /// <summary>
    /// Re-check-out the ref at its tip and start again.
    ///
    /// A stop and a start under the covers, which is why it is one engine call
    /// rather than two from here: getting the ref, preset or port offset wrong
    /// in between would start a different run than the one that was showing.
    /// </summary>
    async Task UpdateRun()
    {
        if (selectedProject is not { } p || Showing is not { State.Running: true } snap) return;
        cache.Remove(p);
        await Run(Engine.UpdateArgs(p), $"Updating {snap.State.Ref}");
    }

    /// <summary>The toolbar's refresh: the engine re-reads branches and pull requests, then the pane reloads.</summary>
    async Task RefreshSelected()
    {
        if (selectedProject is { } p)
        {
            await Task.Run(() => Engine.Refresh(p));
            cache.Remove(p);
        }
        await Reload();
    }

    // --- sheets --------------------------------------------------------------

    async Task ShowProblem(string message)
    {
        if (Root.XamlRoot is { } root) await Sheets.Problem(root, message);
    }

    /// <summary>Whether the selected project has loaded, for the sheet harness.</summary>
    internal bool HasSnapshot => Showing is not null;

    internal async Task ShowLogs()
    {
        if (Root.XamlRoot is not { } root || Showing is not { } snap) return;
        var id = snap.Id;
        // Re-read each tick by the sheet: targets can change while it is open.
        await Sheets.Logs(root, snap.LogDir, () =>
            (cache.GetValueOrDefault(id) ?? snap).State.Targets);
    }

    async Task ShowPorts()
    {
        if (Root.XamlRoot is not { } root) return;
        // Moving a project rewrites its PORT_OFFSET, so every cached snapshot
        // may now name the wrong ports.
        if (await Sheets.Ports(root)) cache.Clear();
        await Reload();
        await RefreshLive();
    }

    async Task ShowDisk()
    {
        if (Root.XamlRoot is not { } root) return;
        if (await Sheets.Disk(root))
        {
            cache.Clear();
            await Reload();
        }
        await RefreshLive();
    }

    Task EditSelectedProject() => selectedProject is { } p ? EditProject(p) : Task.CompletedTask;

    async Task EditProject(string id)
    {
        if (Root.XamlRoot is not { } root) return;
        if (!await Sheets.EditProject(root, id)) return;
        cache.Remove(id);
        projects = await Task.Run(Engine.Projects);
        Render();
        await Reload();
    }

    /// <summary>
    /// Scan for projects. Afterwards the selection lands on the first one
    /// added: closing onto whatever was selected before makes a successful scan
    /// look like nothing happened.
    /// </summary>
    async Task ScanForProjects()
    {
        if (Root.XamlRoot is not { } root) return;
        var start = Environment.GetEnvironmentVariable("RB_SCAN_ROOT") is { Length: > 0 } scanRoot
            ? scanRoot
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Development");
        var added = await Sheets.Scan(root, start);
        if (added.Count == 0) return;
        projects = await Task.Run(Engine.Projects);
        loadingProjects = false;
        var fresh = added.FirstOrDefault(id => projects.Any(p => p.Id == id));
        if (fresh is not null) SelectProject(fresh, reload: false);
        else if (selectedProject is null) SelectProject(projects.FirstOrDefault()?.Id, reload: false);
        Render();
        await Reload();
        await RefreshLive();
    }

    /// <summary>
    /// Point it at a repo and it writes a config by reading what is already
    /// there — lockfile, scripts, ports, compose services, toolchain pin. The
    /// file opens straight away, because these are guesses and the point is
    /// that you can see and correct them.
    /// </summary>
    async Task AddProject()
    {
        if (Root.XamlRoot is not { } root) return;
        var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(AppWindow.Id)
        {
            CommitButtonText = "Add",
        };
        var development = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Development");
        if (Directory.Exists(development)) picker.SuggestedStartFolder = development;
        var picked = await picker.PickSingleFolderAsync();
        if (picked?.Path is not { Length: > 0 } path) return;

        var added = await Task.Run(() => Engine.Add(path));
        if (added is null)
        {
            await Sheets.Problem(root, "It needs to be a git repository, and not already declared.", "Could not add that folder");
            return;
        }
        projects = await Task.Run(Engine.Projects);
        loadingProjects = false;
        SelectProject(added.Name, reload: false);
        Render();
        Shell.OpenInTextEditor(added.File);
        await Reload();
    }

    // --- File Explorer, editors, browser -------------------------------------

    ProjectPaths CachedPaths(string p) => cache.GetValueOrDefault(p)?.Paths ?? Engine.Paths(p);

    static void Reveal(string path)
    {
        if (path.Length == 0 || !(Directory.Exists(path) || File.Exists(path))) return;
        Shell.ShowInExplorer(path);
    }

    async Task OpenWorktree(string @ref, Editor editor)
    {
        if (selectedProject is not { } p) return;
        if (await Task.Run(() => Engine.Paths(p, @ref).Worktree) is { Length: > 0 } dir) editor.Open(dir);
    }

    async Task RevealWorktree(string @ref)
    {
        if (selectedProject is not { } p) return;
        if (await Task.Run(() => Engine.Paths(p, @ref).Worktree) is { Length: > 0 } dir) Reveal(dir);
    }

    async Task OpenLogs()
    {
        if (selectedProject is not { } p) return;
        var paths = await Task.Run(() => CachedPaths(p));
        Reveal(paths.Logs);
    }

    /// <summary>The engine reports the GitHub slug, so the app does not have to parse a remote URL of its own.</summary>
    async Task OpenPullRequest(string number)
    {
        if (selectedProject is not { } p) return;
        var paths = await Task.Run(() => CachedPaths(p));
        if (paths.PullRequestUrl(number) is { } url) Shell.OpenUrl(url);
    }

    /// <summary>Hand the .conf to whatever opens text files; it has no association of its own.</summary>
    async Task EditConfig(string p)
    {
        var paths = await Task.Run(() => CachedPaths(p));
        if (paths.Config.Length > 0) Shell.OpenInTextEditor(paths.Config);
    }

    void OpenProjectsFolder()
    {
        if (projectsDir.Length > 0) Reveal(projectsDir);
    }
}
