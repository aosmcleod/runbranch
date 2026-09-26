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

// The sidebar: Running, Favourites and Projects as collapsible parents in the
// NavigationView (spec F2), each project's row, and its context menu
// (ContentView.swift: sidebar, projectRow, projectMenu).

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Runbranch.Dialogs;
using Runbranch.Views;

namespace Runbranch;

public sealed partial class MainWindow
{
    const string RunningSection = "section:running";
    const string FavouritesSection = "section:favourites";
    const string ProjectsSection = "section:projects";

    /// <summary>What the sidebar was last built from, so an unchanged picture is not rebuilt.</summary>
    string sidebarShape = "";
    bool syncingSidebar;
    readonly Dictionary<string, NavigationViewItem> projectItems = [];

    List<Project> Live => projects.Where(p => liveProjects.Contains(p.Id)).ToList();

    /// <summary>
    /// Favourites and Running are both promotions, so a project appears in the
    /// higher one only — listing it twice would be worse than either.
    /// </summary>
    List<Project> Favourites => projects.Where(p => p.Favourite && !liveProjects.Contains(p.Id)).ToList();

    List<Project> Others => projects.Where(p => !p.Favourite && !liveProjects.Contains(p.Id)).ToList();

    /// <summary>Top to bottom, as drawn: Ctrl+1…9 counts down this.</summary>
    List<Project> SidebarOrder() => [.. Live, .. Favourites, .. Others];

    void WireSidebar()
    {
        Nav.SelectionChanged += (_, e) =>
        {
            if (syncingSidebar) return;
            if (e.SelectedItem is NavigationViewItem { Tag: string id } && !id.StartsWith("section:", StringComparison.Ordinal))
                SelectProject(id);
        };
        // Persisted: collapsing a section is a preference, and having it spring
        // back open on every launch would make it pointless.
        Nav.Expanding += (_, e) => RememberExpansion(e.ExpandingItemContainer?.Tag as string, true);
        Nav.Collapsed += (_, e) => RememberExpansion(e.CollapsedItemContainer?.Tag as string, false);
        // A live project's glyph is green in the theme it was drawn in.
        Root.ActualThemeChanged += (_, _) =>
        {
            sidebarShape = "";
            RenderSidebar();
        };
    }

    static void RememberExpansion(string? tag, bool expanded)
    {
        switch (tag)
        {
            case RunningSection: Settings.Shared.SidebarRunningExpanded = expanded; break;
            case FavouritesSection: Settings.Shared.SidebarFavouritesExpanded = expanded; break;
            case ProjectsSection: Settings.Shared.SidebarProjectsExpanded = expanded; break;
        }
    }

    /// <summary>
    /// Selects a project and loads it. Everything that changes the selection
    /// comes through here, as everything on the Mac changes selectedProject
    /// and lets onChange reload.
    /// </summary>
    void SelectProject(string? id, bool reload = true)
    {
        if (id == selectedProject) return;
        selectedProject = id;
        SyncSidebarSelection();
        if (reload) _ = Reload();
    }

    void RenderSidebar()
    {
        var live = Live;
        var favourites = Favourites;
        var others = Others;

        var shape = string.Join('\n',
            new[] { ("L", live), ("F", favourites), ("P", others) }.SelectMany(section =>
                section.Item2.Select(p => $"{section.Item1}\t{p.Id}\t{p.Name}\t{p.Symbol}\t{p.Repo}")));
        if (shape == sidebarShape)
        {
            SyncSidebarSelection();
            return;
        }
        sidebarShape = shape;

        syncingSidebar = true;
        try
        {
            Nav.MenuItems.Clear();
            projectItems.Clear();
            if (live.Count > 0)
                Nav.MenuItems.Add(Section("Running", RunningSection, Settings.Shared.SidebarRunningExpanded, live, isLive: true));
            if (favourites.Count > 0)
                Nav.MenuItems.Add(Section("Favourites", FavouritesSection, Settings.Shared.SidebarFavouritesExpanded, favourites, isLive: false));
            // No accessory in this header, as on the Mac: adding a project is
            // on Ctrl+N, in the ••• menu and on the welcome screen, so nothing
            // is lost by leaving the header alone.
            Nav.MenuItems.Add(Section("Projects", ProjectsSection, Settings.Shared.SidebarProjectsExpanded, others, isLive: false));
        }
        finally
        {
            syncingSidebar = false;
        }
        SyncSidebarSelection();
    }

    NavigationViewItem Section(string title, string tag, bool expanded, List<Project> members, bool isLive)
    {
        var section = new NavigationViewItem
        {
            Content = title,
            Tag = tag,
            SelectsOnInvoked = false,
            IsExpanded = expanded,
        };
        foreach (var p in members)
        {
            var item = new NavigationViewItem
            {
                Content = new ProjectRow(p, isLive),
                Icon = ProjectRow.Icon(p, isLive, Root),
                Tag = p.Id,
            };
            // The row is a control, so there is no text for a screen reader to
            // find without being told.
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, p.Name);
            var menu = new MenuFlyout();
            var project = p;
            menu.Opening += (_, _) => FillProjectMenu(menu, project);
            item.ContextFlyout = menu;
            projectItems[p.Id] = item;
            section.MenuItems.Add(item);
        }
        return section;
    }

    void SyncSidebarSelection()
    {
        syncingSidebar = true;
        try
        {
            Nav.SelectedItem = selectedProject is { } id && projectItems.TryGetValue(id, out var item) ? item : null;
        }
        finally
        {
            syncingSidebar = false;
        }
    }

    /// <summary>
    /// Built as it opens, from the project as it is now: the favourite toggle
    /// has to name the state the project is in, not the one it was in when
    /// the sidebar was drawn.
    /// </summary>
    void FillProjectMenu(MenuFlyout menu, Project stale)
    {
        var p = projects.FirstOrDefault(x => x.Id == stale.Id) ?? stale;
        menu.Items.Clear();
        menu.Items.Add(MenuItem(p.Favourite ? "Remove from Favourites" : "Add to Favourites", () => _ = ToggleFavourite(p)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Project settings…", () => _ = EditProject(p.Id)));
        menu.Items.Add(MenuItem("Show repository in File Explorer", () => Reveal(p.Repo)));
        menu.Items.Add(MenuItem("Open config in a text editor", () => _ = EditConfig(p.Id)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Remove project…", () => _ = RemoveProject(p)));
    }

    async Task ToggleFavourite(Project p)
    {
        var err = await Task.Run(() => Engine.Favourite(p.Id, !p.Favourite));
        if (err is not null)
        {
            await ShowProblem(err);
            return;
        }
        projects = await Task.Run(Engine.Projects);
        Render();
    }

    async Task RemoveProject(Project p)
    {
        if (Root.XamlRoot is not { } root) return;
        if (!await Sheets.ConfirmRemove(root, p)) return;
        await Run(Engine.RemoveArgs(p.Id), $"Removing {p.Name}");
    }

    /// <summary>Re-read the project list and drop a selection that no longer resolves.</summary>
    async Task SyncProjectList()
    {
        var found = await Task.Run(Engine.Projects);
        projects = found;
        if (selectedProject is { } sel && found.All(p => p.Id != sel))
        {
            cache.Remove(sel);
            snapshot = null;
            SelectProject(found.FirstOrDefault()?.Id, reload: false);
        }
        Render();
    }

    /// <summary>Which projects have something up — drives the sidebar's Running section and spinners.</summary>
    ///
    /// Every project at once rather than one after another. On Windows an
    /// engine call costs about 300 ms, nearly all of it process start, so a
    /// sidebar of twenty projects asked in turn was six seconds behind every
    /// Stop. And only the newest refresh is applied: they overlap (the 30 s
    /// tick and the one after every run), and an older one finishing last used
    /// to put a stopped project back under Running until the next tick.
    async Task RefreshLive()
    {
        var mine = ++liveGeneration;
        var ids = projects.Select(p => p.Id).ToList();
        var states = await Task.WhenAll(ids.Select(id => Task.Run(() => (id, Engine.State(id).Running))));
        if (mine != liveGeneration) return;
        liveProjects = states.Where(s => s.Running).Select(s => s.id).ToHashSet();
        RenderSidebar();
    }

    int liveGeneration;
}
