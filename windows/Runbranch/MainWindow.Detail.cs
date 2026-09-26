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

// The detail pane: the snapshot it draws from, the cache behind it, which
// branch and preset are selected, and the list, strip and action bar that show
// them (ContentView.swift: detail, reload, applySelection, primary).

using System.Collections.ObjectModel;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Runbranch.Views;
using Windows.System;

namespace Runbranch;

/// <summary>
/// Everything the detail pane needs for one project, as a single value.
///
/// It used to be six separate @State vars on the Mac, assigned at different
/// moments — branches from cache synchronously, run state only when the engine
/// replied — so mid-switch the window showed one project's branches beside
/// another's status bar, title and subtitle. Snapshots are swapped whole, and
/// the pane refuses to draw one whose id is not the selected project, so a
/// mismatch cannot be represented rather than merely being unlikely.
/// </summary>
public sealed record ProjectSnapshot(string Id, IReadOnlyList<Branch> Branches, IReadOnlyList<string> Presets, RunState State, ProjectPaths Paths)
{
    public string LogDir => Paths.Logs;

    /// <summary>Blocking: four engine calls. Off the UI thread.</summary>
    public static ProjectSnapshot Load(string id) =>
        new(id, Engine.Branches(id), Engine.Presets(id), Engine.State(id), Engine.Paths(id));
}

public sealed partial class MainWindow
{
    List<Project> projects = [];
    string? selectedProject;
    HashSet<string> liveProjects = [];
    bool loadingProjects = true;

    /// <summary>The one currently displayed, and everything already fetched.</summary>
    ProjectSnapshot? snapshot;
    readonly Dictionary<string, ProjectSnapshot> cache = [];

    string? selection;
    string preset = "";
    readonly BranchFilter filter = new();
    readonly HealthMonitor health;

    readonly ObservableCollection<BranchItem> rows = [];
    bool syncingList;
    bool syncingPresets;

    Project? SelectedProjectInfo => projects.FirstOrDefault(p => p.Id == selectedProject);

    /// <summary>
    /// The snapshot, but only if it belongs to the selected project. Every
    /// read goes through here, so stale data cannot reach the screen.
    /// </summary>
    ProjectSnapshot? Showing => snapshot is { } s && s.Id == selectedProject ? s : null;

    Branch? SelectedBranch => Showing?.Branches.FirstOrDefault(b => b.Ref == selection);

    void WireDetail()
    {
        BranchList.ItemsSource = rows;
        BranchList.SelectionChanged += (_, _) =>
        {
            if (syncingList) return;
            selection = (BranchList.SelectedItem as BranchItem)?.Ref;
            RenderActionBar();
        };
        // Return starts, stops or switches, as the Mac's default action does.
        BranchList.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter || Showing is not { } snap || Primary(snap) is not { } p) return;
            e.Handled = true;
            p.Action();
        };
        BranchList.ContextRequested += OnBranchContextRequested;

        PresetPicker.SelectionChanged += (_, _) =>
        {
            if (syncingPresets) return;
            if (PresetPicker.SelectedItem is SegmentedItem { Tag: string name }) preset = name;
        };

        LogsButton.Click += (_, _) => _ = ShowLogs();
        OpenButton.Click += (_, _) =>
        {
            if (Showing?.State.Urls.FirstOrDefault() is { } url) Shell.OpenUrl(url);
        };
        UpdateButton.Click += (_, _) => _ = UpdateRun();
        PrimaryButton.Click += (_, _) =>
        {
            if (Showing is { } snap && Primary(snap) is { } p) p.Action();
        };
    }

    /// <summary>
    /// Builds the whole snapshot, then assigns it in one go. Nothing is applied
    /// piecemeal, and a reply that arrives after you have switched away is
    /// dropped rather than half-drawn.
    /// </summary>
    async Task Reload()
    {
        if (selectedProject is not { } p)
        {
            snapshot = null;
            Render();
            return;
        }

        // A cached snapshot is complete, so showing it immediately is safe.
        snapshot = cache.GetValueOrDefault(p);
        if (snapshot is not null) ApplySelection(snapshot);
        Render();

        var fresh = await Task.Run(() => ProjectSnapshot.Load(p));
        if (selectedProject != p) return;

        cache[p] = fresh;
        snapshot = fresh;
        ApplySelection(fresh);
        Render();
    }

    /// <summary>Selection and preset belong to the snapshot, so they move with it.</summary>
    void ApplySelection(ProjectSnapshot snap)
    {
        if (snap.State.Running) health.Watch(snap.State.Targets); else health.Stop();
        UpdateTray();

        if (preset.Length == 0 || !snap.Presets.Contains(preset)) preset = snap.Presets.FirstOrDefault() ?? "";
        if (snap.State.Running)
        {
            selection = snap.State.Ref;
            if (snap.Presets.Contains(snap.State.Preset)) preset = snap.State.Preset;
        }
        else if (selection is null || snap.Branches.All(b => b.Ref != selection))
        {
            selection = snap.Branches.FirstOrDefault(b => b.Mine && b.PR != PRState.Merged)?.Ref
                        ?? snap.Branches.FirstOrDefault(b => b.IsDefault)?.Ref;
        }
    }

    /// <summary>Everything, from the state fields. Cheap enough to call after any change.</summary>
    void Render()
    {
        var welcome = projects.Count == 0 && !loadingProjects;
        Welcome.Visibility = welcome ? Visibility.Visible : Visibility.Collapsed;
        Nav.Visibility = welcome ? Visibility.Collapsed : Visibility.Visible;
        ApplyWindowMode(welcome);
        RenderToolbar(welcome);
        RenderSidebar();
        RenderDetail();
    }

    void RenderDetail()
    {
        var project = SelectedProjectInfo;
        var snap = Showing;

        NoProject.Visibility = Visibility.Collapsed;
        Loading.Visibility = Visibility.Collapsed;
        Loading.IsActive = false;
        Detail.Visibility = Visibility.Collapsed;

        if (project is null)
        {
            if (!loadingProjects)
            {
                NoProject.Show("square.stack.3d.up", "No project selected",
                    $"Projects are declared in {projectsDir.AbbreviatingHome()}");
                NoProject.Visibility = Visibility.Visible;
            }
            SetTitle(null, null);
            return;
        }
        if (snap is null)
        {
            // Loading. Deliberately not the previous project's data with
            // pieces swapped in as they arrive.
            Loading.Visibility = Visibility.Visible;
            Loading.IsActive = true;
            SetTitle(project.Name, null);
            return;
        }

        Detail.Visibility = Visibility.Visible;
        var state = snap.State;
        // Explorer titles the folder, Mail the mailbox: the window names what
        // it is showing.
        SetTitle(project.Name, state.Running ? $"{state.Ref} · {state.Preset}" : null);
        RenderStrip();
        RenderList(snap);
        RenderActionBar();
    }

    void RenderStrip()
    {
        if (Showing is not { State.Running: true } snap)
        {
            Strip.Visibility = Visibility.Collapsed;
            return;
        }
        Strip.Visibility = Visibility.Visible;
        Strip.Show(snap.State, health.Worst(snap.State));
    }

    void OnHealthChanged()
    {
        if (Showing is { State.Running: true } snap) Strip.SetHealth(health.Worst(snap.State));
        UpdateTray();
    }

    void RenderList(ProjectSnapshot snap)
    {
        var state = snap.State;
        var visible = filter.Visible(snap.Branches, state);
        var next = visible.Select(b => new BranchItem(b, state.Running && state.Ref == b.Ref, state.Running)).ToList();

        syncingList = true;
        try
        {
            // In place when only rows changed, so the list keeps its scroll
            // position through a reload; wholesale when the set did.
            if (rows.Count == next.Count && rows.Select(r => r.Ref).SequenceEqual(next.Select(r => r.Ref)))
            {
                for (var i = 0; i < next.Count; i++)
                    if (rows[i] != next[i]) rows[i] = next[i];
            }
            else
            {
                rows.Clear();
                foreach (var r in next) rows.Add(r);
            }
            BranchList.SelectedItem = rows.FirstOrDefault(r => r.Ref == selection);
        }
        finally
        {
            syncingList = false;
        }

        var empty = next.Count == 0;
        BranchList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        NoBranches.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        if (empty)
        {
            if (filter.Query.Length == 0)
                NoBranches.Show("arrow.triangle.branch", "No branches to show",
                    "Merged branches and anything older than a week are hidden. Change that in the filter menu.");
            else
                NoBranches.Show("magnifyingglass", "No match", $"No branch matches “{filter.Query}”.");
        }
    }

    void RenderActionBar()
    {
        if (Showing is not { } snap || selection is null)
        {
            ActionBar.Visibility = Visibility.Collapsed;
            return;
        }
        ActionBar.Visibility = Visibility.Visible;
        var state = snap.State;

        // Presets come from the project's own config, so a one-server project
        // shows no picker and a bigger one shows three.
        syncingPresets = true;
        try
        {
            if (snap.Presets.Count > 1)
            {
                var names = PresetPicker.Items.OfType<SegmentedItem>().Select(i => i.Tag as string);
                if (!names.SequenceEqual(snap.Presets))
                {
                    PresetPicker.Items.Clear();
                    foreach (var name in snap.Presets)
                        PresetPicker.Items.Add(new SegmentedItem { Content = Capitalised(name), Tag = name });
                }
                PresetPicker.SelectedIndex = snap.Presets.ToList().IndexOf(preset);
                PresetPicker.IsEnabled = !(state.Running && state.Ref == selection);
                PresetPicker.Visibility = Visibility.Visible;
            }
            else
            {
                PresetPicker.Visibility = Visibility.Collapsed;
            }
        }
        finally
        {
            syncingPresets = false;
        }

        LogsButton.Visibility = Shown(state.Running);
        OpenButton.Visibility = Shown(state.Running && state.Targets.Count > 0);
        // Only when there is something to catch up on. An always-present
        // Update would be mistaken for Refresh, which is the confusion this
        // whole thing came out of.
        UpdateButton.Visibility = Shown(state.Running && state.Behind > 0);
        ToolTipService.SetToolTip(UpdateButton, $"Re-check-out {state.Ref} at its latest commit and restart");

        if (Primary(snap) is { } p)
        {
            PrimaryButton.Visibility = Visibility.Visible;
            PrimaryButton.Content = p.Title;
            PrimaryButton.Style = (Style)Application.Current.Resources[p.Destructive ? "DestructiveButtonStyle" : "AccentButtonStyle"];
            ToolTipService.SetToolTip(PrimaryButton, $"{p.Title} {selection}");
        }
        else
        {
            PrimaryButton.Visibility = Visibility.Collapsed;
        }
    }

    static Visibility Shown(bool yes) => yes ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Swift's `.capitalized`: the first letter of each word.</summary>
    static string Capitalised(string s) =>
        string.Join(' ', s.Split(' ').Select(w => w.Length == 0 ? w : char.ToUpperInvariant(w[0]) + w[1..].ToLowerInvariant()));

    sealed record PrimaryAction(string Title, bool Destructive, Action Action);

    /// <summary>Start / Stop / Switch, decided by what is running and what is selected.</summary>
    PrimaryAction? Primary(ProjectSnapshot snap)
    {
        var state = snap.State;
        if (selectedProject is not { } p || selection is not { } @ref) return null;
        if (state.Running && state.Ref == @ref)
        {
            if (state.Adopted)
            {
                // `stop` has no state to work from — there is no run of ours.
                // Ending it means ending the process on the port, which is the
                // one thing kill-port is careful about.
                return new("Stop", true, () => _ = StopAdopted(snap));
            }
            return new("Stop", true, () => _ = Run(Engine.StopArgs(p), $"Stopping {@ref}"));
        }
        // The branch the checkout is on runs IN PLACE by default.
        //
        // A worktree of it would be a second copy of code that is already on
        // disk, pinned to a commit, that cannot show an edit — which is the
        // opposite of what anyone wants from the branch they are working on.
        // So the default inverts here, and the isolated run moves to the menu.
        var inPlace = SelectedBranch?.CanRunInPlace ?? false;
        var chosen = preset;

        if (state.Running)
        {
            // The engine's run stops whatever this project has running first,
            // and says so as it goes.
            return new("Switch", false, () => _ = StartChecking(p, @ref, chosen, $"Switching to {@ref}", inPlace));
        }
        var label = inPlace ? "Run in place" : "Start";
        return new(label, false, () => _ = StartChecking(p, @ref, chosen, $"Starting {@ref}", inPlace));
    }

    void OnBranchContextRequested(UIElement sender, ContextRequestedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not BranchItem item) return;
        if (Showing is not { } snap || selectedProject is not { } p) return;
        var b = item.Branch;
        // Only what the Mac's row menu has: removing a worktree that is not
        // the one running.
        if (!(b.Ready && snap.State.Ref != b.Ref)) return;

        var menu = new MenuFlyout();
        menu.Items.Add(MenuItem("Remove worktree", () => _ = Run(Engine.RemoveWorktreeArgs(p, b.Ref), $"Removing {b.Ref}")));
        if (e.TryGetPosition(BranchList, out var at))
            menu.ShowAt(BranchList, at);
        else
            menu.ShowAt(e.OriginalSource as FrameworkElement ?? BranchList);
        e.Handled = true;
    }

    static MenuFlyoutItem MenuItem(string text, Action action, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        item.Click += (_, _) => action();
        return item;
    }

    void UpdateTray()
    {
        if (App.Instance?.Tray is not { } tray) return;
        var name = SelectedProjectInfo?.Name ?? selectedProject;
        var state = Showing?.State;
        var running = state?.Running ?? false;
        tray.Update(name, state?.Ref, running, running ? health.Worst(state!).Title() : null);
    }
}
