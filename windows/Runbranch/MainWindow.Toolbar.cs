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

// The title bar: title and subtitle, the sidebar toggle, search (spec F11),
// and the filter / refresh / ••• buttons with the Mac toolbar's menus. The
// ••• menu also carries what the Mac's menu bar had (spec F3), since there is
// no menu bar here.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Runbranch.Dialogs;
using Windows.ApplicationModel.DataTransfer;

namespace Runbranch;

public sealed partial class MainWindow
{
    /// <summary>Below this the search box folds into a button (F11).</summary>
    const double SearchCollapseWidth = 900;
    /// <summary>The box at its widest, and the narrowest that is still worth typing in.</summary>
    const double SearchWidth = 320, SearchMinWidth = 160;
    /// <summary>Kept free between the title and the search box, so there is always somewhere to drag the window by.</summary>
    const double DragMinWidth = 48;
    bool searchExpandedByButton;

    IEnumerable<Button> HeaderButtons => [PaneButton, SearchButton, FilterButton, RefreshButton, MoreButton];

    /// <summary>
    /// The header's buttons, sized to the caption buttons: as wide as one of
    /// them (the system's width for this DPI and the tall height, read from
    /// the inset it reserves for all three) and as tall as the bar. Measured
    /// rather than assumed, so a Windows that draws them differently still
    /// gets one row of equal buttons.
    /// </summary>
    void LayoutHeader()
    {
        var scale = Scale;
        var inset = AppWindow.TitleBar.RightInset / scale;
        if (inset > 0)
        {
            var width = Math.Round(inset / 3);
            var height = AppTitleBar.ActualHeight > 0 ? AppTitleBar.ActualHeight : 48;
            foreach (var b in HeaderButtons)
            {
                b.Width = width;
                b.Height = height;
            }
            // The TitleBar control reserves the caption buttons' inset in
            // physical pixels as if they were DIPs: 180 at 125% for 144 of
            // buttons, which left a 36 px gap between ••• and minimise. Set
            // right, after the control has set it wrong on this resize.
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                if (RightPaddingColumn() is { } column && Math.Abs(column.Width.Value - inset) > 0.5)
                    column.Width = new GridLength(inset);
            });
        }
        LayoutSearch();
    }

    /// <summary>The title bar template's last column, which it reserves for the caption buttons.</summary>
    ColumnDefinition? RightPaddingColumn() =>
        Descendants(AppTitleBar).OfType<Grid>().FirstOrDefault(g => g.Name == "PART_LayoutRoot") is { ColumnDefinitions.Count: 12 } root
            ? root.ColumnDefinitions[11]
            : null;

    void WireToolbar()
    {
        SetGlyph(SearchGlyph, "magnifyingglass");
        SetGlyph(FilterGlyph, "line.3.horizontal.decrease");
        SetGlyph(RefreshGlyph, "arrow.clockwise");
        SetGlyph(MoreGlyph, "ellipsis");

        PaneButton.Click += (_, _) => Nav.IsPaneVisible = !Nav.IsPaneVisible;

        SearchBox.TextChanged += (_, e) =>
        {
            filter.Query = SearchBox.Text;
            if (Showing is { } snap) RenderList(snap);
            RenderActionBar();
        };
        SearchBox.LostFocus += (_, _) =>
        {
            if (searchExpandedByButton && SearchBox.Text.Length == 0)
            {
                searchExpandedByButton = false;
                LayoutSearch();
            }
        };
        SearchButton.Click += (_, _) =>
        {
            searchExpandedByButton = true;
            LayoutSearch();
            SearchBox.Focus(FocusState.Programmatic);
        };
        Root.SizeChanged += (_, _) => LayoutHeader();
        Root.Loaded += (_, _) => LayoutHeader();
        FilterMenu.Opening += (_, _) => FillFilterMenu();
        RefreshButton.Click += (_, _) => _ = RefreshSelected();
        MoreMenu.Opening += (_, _) => FillMoreMenu();
    }

    static void SetGlyph(FontIcon icon, string symbol)
    {
        var g = Icons.Glyph(symbol);
        icon.FontFamily = g.Family;
        icon.Glyph = g.Glyph;
    }

    void SetTitle(string? title, string? subtitle)
    {
        AppTitleBar.Title = title ?? "Runbranch";
        AppTitleBar.Subtitle = subtitle ?? "";
        // The box's room depends on where the title ends, which is known once
        // the new title has been laid out.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, LayoutSearch);
    }

    /// <summary>The Mac hides its whole toolbar on the welcome screen: there is nothing yet to search or filter.</summary>
    void RenderToolbar(bool welcome)
    {
        PaneButton.Visibility = welcome ? Visibility.Collapsed : Visibility.Visible;
        ToolbarButtons.Visibility = welcome ? Visibility.Collapsed : Visibility.Visible;
        LayoutSearch();
        // Tinted while any filter is on, so a short list says why it is short.
        if (filter.IsActive)
            FilterGlyph.Foreground = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"];
        else
            FilterGlyph.ClearValue(IconElement.ForegroundProperty);
    }

    /// <summary>
    /// Always there on a wide window; a button that opens it below ~900 px,
    /// the way Explorer's search folds away (F11). A query in the box keeps it
    /// open whatever the width, since hiding a live filter hides why the list
    /// is short.
    ///
    /// Sized to the room the title leaves, up to 320: a fixed width was
    /// clipped at its left end once a long project name and a running
    /// branch's subtitle took their share of the bar. When that room is too
    /// small to type in, it folds into the button as a narrow window does.
    /// </summary>
    void LayoutSearch()
    {
        var welcome = Welcome.Visibility == Visibility.Visible;
        var narrow = (Root.ActualWidth > 0 && Root.ActualWidth < SearchCollapseWidth) || SearchRoom() < SearchMinWidth;
        var show = !welcome && (!narrow || searchExpandedByButton || SearchBox.Text.Length > 0);
        SearchBox.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        SearchButton.Visibility = !welcome && !show ? Visibility.Visible : Visibility.Collapsed;
        SearchBox.Width = Math.Max(0, Math.Min(SearchWidth, SearchRoom()));
    }

    /// <summary>
    /// What the title and subtitle leave for the box: the bar, less the
    /// caption buttons, the header buttons, the gap after the box, a drag
    /// region, and wherever the title's text ends.
    /// </summary>
    double SearchRoom()
    {
        if (AppTitleBar.ActualWidth <= 0) return SearchWidth;
        var buttons = new[] { FilterButton, RefreshButton, MoreButton }.Sum(b => b.Width);
        double titleEnd = 0;
        foreach (var t in Descendants(AppTitleBar).OfType<TextBlock>())
        {
            if (t.Name is not ("PART_TitleText" or "PART_SubtitleText") || t.Visibility != Visibility.Visible || t.ActualWidth <= 0) continue;
            titleEnd = Math.Max(titleEnd, t.TransformToVisual(AppTitleBar).TransformPoint(default).X + t.ActualWidth + t.Margin.Right);
        }
        return AppTitleBar.ActualWidth - AppWindow.TitleBar.RightInset / Scale - buttons - SearchBox.Margin.Right - DragMinWidth - titleEnd;
    }
    void FocusSearch()
    {
        if (Welcome.Visibility == Visibility.Visible) return;
        searchExpandedByButton = true;
        LayoutSearch();
        SearchBox.Focus(FocusState.Keyboard);
    }

    void FillFilterMenu()
    {
        FilterMenu.Items.Clear();
        FilterMenu.Items.Add(Toggle("Only my branches", filter.MineOnly, v => filter.MineOnly = v));
        FilterMenu.Items.Add(new MenuFlyoutSeparator());
        FilterMenu.Items.Add(Toggle("Show merged", filter.ShowMerged, v => filter.ShowMerged = v));
        FilterMenu.Items.Add(Toggle("Show older than a week", filter.ShowOlder, v => filter.ShowOlder = v));
        FilterMenu.Items.Add(Toggle("Show all remote branches", filter.ShowAllRemote, v => filter.ShowAllRemote = v));
    }

    ToggleMenuFlyoutItem Toggle(string text, bool on, Action<bool> set)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = on };
        item.Click += (_, _) =>
        {
            set(item.IsChecked);
            RenderToolbar(welcome: false);
            if (Showing is { } snap) RenderList(snap);
            RenderActionBar();
        };
        return item;
    }

    /// <summary>The Mac toolbar's ••• menu, item for item, then its menu bar's (F3).</summary>
    void FillMoreMenu()
    {
        var m = MoreMenu.Items;
        m.Clear();
        var p = selectedProject;
        var project = SelectedProjectInfo;
        var snap = Showing;

        if (SelectedBranch is { } b && p is not null)
        {
            m.Add(MenuItem("Copy branch name", () => Copy(b.Ref)));
            if (snap is { State.Running: true } s && s.State.Ref == b.Ref && s.State.Urls.FirstOrDefault() is { } url)
                m.Add(MenuItem("Copy URL", () => Copy(url.AbsoluteUri)));
            if (b.PRNumber.Length > 0)
                m.Add(MenuItem($"Open pull request #{b.PRNumber}", () => _ = OpenPullRequest(b.PRNumber)));
            m.Add(new MenuFlyoutSeparator());
            if (b.Ready)
            {
                var open = new MenuFlyoutSubItem { Text = "Open worktree in" };
                foreach (var editor in Editor.Installed)
                {
                    var e = editor;
                    open.Items.Add(MenuItem(e.Title, () => _ = OpenWorktree(b.Ref, e)));
                }
                m.Add(open);
                m.Add(MenuItem("Show worktree in File Explorer", () => _ = RevealWorktree(b.Ref)));
                var running = snap is { State.Running: true } rs && rs.State.Ref == b.Ref;
                m.Add(MenuItem("Remove worktree", () => _ = Run(Engine.RemoveWorktreeArgs(p, b.Ref), $"Removing {b.Ref}"), enabled: !running));
                m.Add(new MenuFlyoutSeparator());
            }
        }
        if (SelectedBranch is { CanRunInPlace: true } here && p is not null)
        {
            // In place is the default for this branch, so the menu offers the
            // other one.
            var chosen = preset;
            m.Add(MenuItem("Run in an isolated worktree instead…",
                () => _ = StartChecking(p, here.Ref, chosen, $"Starting {here.Ref} in a worktree", inPlace: false)));
            m.Add(new MenuFlyoutSeparator());
        }

        m.Add(MenuItem("Add a project…", () => _ = AddProject()));
        m.Add(MenuItem("Scan for projects…", () => _ = ScanForProjects()));
        m.Add(new MenuFlyoutSeparator());
        m.Add(MenuItem("Ports…", () => _ = ShowPorts()));
        m.Add(MenuItem("Disk…", () => _ = ShowDisk()));
        m.Add(MenuItem("Open logs folder", () => _ = OpenLogs()));
        if (project is not null)
        {
            m.Add(MenuItem("Show repository in File Explorer", () => Reveal(project.Repo)));
            m.Add(new MenuFlyoutSeparator());
            m.Add(MenuItem("Project settings…", () => _ = EditProject(project.Id)));
            m.Add(MenuItem("Open config in a text editor", () => _ = EditConfig(project.Id)));
        }
        m.Add(MenuItem("Open projects folder", OpenProjectsFolder));

        m.Add(new MenuFlyoutSeparator());
        var check = new ToggleMenuFlyoutItem { Text = "Check for updates on launch", IsChecked = Settings.Shared.UpdatesCheck };
        check.Click += (_, _) => Settings.Shared.UpdatesCheck = check.IsChecked;
        m.Add(check);
        var where = new MenuFlyoutSubItem { Text = "Show Runbranch in" };
        foreach (var mode in Presentations.All)
        {
            var radio = new RadioMenuFlyoutItem
            {
                Text = mode.Label(),
                GroupName = "presentation",
                IsChecked = Settings.Shared.Presentation == mode,
            };
            var chosen = mode;
            radio.Click += (_, _) => App.Instance?.Apply(chosen);
            where.Items.Add(radio);
        }
        m.Add(where);
        var look = new MenuFlyoutSubItem { Text = "Appearance" };
        foreach (var appearance in Appearances.All)
        {
            var radio = new RadioMenuFlyoutItem
            {
                Text = appearance.Label(),
                GroupName = "appearance",
                IsChecked = Settings.Shared.Appearance == appearance,
            };
            var chosen = appearance;
            radio.Click += (_, _) => SetAppearance(chosen);
            look.Items.Add(radio);
        }
        m.Add(look);

        m.Add(new MenuFlyoutSeparator());
        m.Add(MenuItem("Check for updates…", () => _ = CheckForUpdates()));
        m.Add(MenuItem("About Runbranch", () => _ = ShowAbout()));
    }

    static void Copy(string text)
    {
        var data = new DataPackage();
        data.SetText(text);
        Clipboard.SetContent(data);
    }

    /// <summary>
    /// The Mac's Check for Updates…: check, then show the result unless a
    /// sheet is already up.
    /// </summary>
    async Task CheckForUpdates()
    {
        if (Root.XamlRoot is not { } root) return;
        await Updater.Shared.CheckNowAsync();
        if (!Sheets.IsOpen) await Sheets.Update(root);
    }

    async Task ShowAbout()
    {
        if (Root.XamlRoot is { } root) await Sheets.About(root);
    }

    /// <summary>Every element under root, depth first. Here rather than in the
    /// layout probe, which release builds leave out, because the title bar
    /// fix-ups above need it too.</summary>
    static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            yield return child;
            foreach (var d in Descendants(child)) yield return d;
        }
    }
}
