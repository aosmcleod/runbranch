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

// Answers "what is using 5173" without reaching for netstat, and says whose
// it is — which netstat cannot, because it does not know which directory
// belongs to which project.

using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Runbranch.Dialogs;

public sealed record PortRowView(string Port, string Title, BadgeSpec Badge, string What, Visibility WhatVisibility)
{
    public static PortRowView From(PortRow r) => new(
        r.Port.ToString(CultureInfo.InvariantCulture), $"{r.Project} · {r.Target}", PortRules.Badge(r), r.What,
        !r.IsFree && r.What.Length > 0 ? Visibility.Visible : Visibility.Collapsed);
}

public sealed partial class PortsDialog : SheetDialog
{
    readonly Func<(List<PortRow> Rows, List<PortOverlap> Overlaps)> load;
    readonly Func<string, string?> move;
    readonly DispatcherQueueTimer refresh;
    bool loading;

    /// <param name="load">Every declared port and the overlaps, off the UI thread.</param>
    /// <param name="move">Gives a project a free PORT_OFFSET; what went wrong, or null.</param>
    public PortsDialog(Func<(List<PortRow>, List<PortOverlap>)> load, Func<string, string?> move)
    {
        InitializeComponent();
        Frame(Root, 520, 460);
        DefaultAction = Done;
        this.load = load;
        this.move = move;

        // Kept current while it is open, at the main window's 30 s live
        // refresh interval: it is the one sheet that refresh runs behind.
        refresh = DispatcherQueue.CreateTimer();
        refresh.Interval = TimeSpan.FromSeconds(30);
        refresh.Tick += (_, _) => Reload();
        Opened += (_, _) =>
        {
            Reload();
            refresh.Start();
        };
        Closed += (_, _) => refresh.Stop();
    }

    /// <summary>Whether a project's ports were moved, so the caller knows its caches are stale.</summary>
    public bool Moved { get; private set; }

    void Reload()
    {
        if (loading) return;
        loading = true;
        _ = Task.Run(load).ContinueWith(t => DispatcherQueue.TryEnqueue(() =>
        {
            loading = false;
            if (t.IsCompletedSuccessfully) Show(t.Result.Rows, t.Result.Overlaps);
        }), TaskScheduler.Default);
    }

    void Show(List<PortRow> rows, List<PortOverlap> overlaps)
    {
        Spinner.IsActive = false;
        Spinner.Visibility = Visibility.Collapsed;
        Empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        List.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        Rows.ItemsSource = rows.Select(PortRowView.From).ToList();

        Overlaps.Visibility = overlaps.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        OverlapHeading.Text = PortRules.OverlapHeading(overlaps.Count);
        OverlapRows.Children.Clear();
        foreach (var o in overlaps) OverlapRows.Children.Add(OverlapRow(o));
    }

    /// <summary>
    /// The projects that cannot run together, and a way to fix it: giving one
    /// of them a PORT_OFFSET, which shifts every port it declares and
    /// rewrites {port} in its commands — so a project declaring 3000 and 3001
    /// keeps them adjacent. Which one moves is a real choice: one of them is
    /// probably the one you think of as owning the port.
    /// </summary>
    Grid OverlapRow(PortOverlap o)
    {
        var row = new Grid { ColumnSpacing = Resource<double>("RbSpacing") };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var port = new TextBlock
        {
            Text = o.Port.ToString(CultureInfo.InvariantCulture),
            Style = Resource<Style>("SheetPortTextStyle"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var who = new TextBlock
        {
            Text = string.Join(", ", o.Projects),
            Style = Resource<Style>("RbCaptionTextStyle"),
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
        foreach (var p in o.Projects)
        {
            var item = new MenuFlyoutItem { Text = p };
            item.Click += (_, _) => Move(p);
            menu.Items.Add(item);
        }
        var button = new DropDownButton { Content = "Move…", Flyout = menu, Style = Resource<Style>("SheetDropDownButtonStyle") };
        Grid.SetColumn(who, 1);
        Grid.SetColumn(button, 2);
        row.Children.Add(port);
        row.Children.Add(who);
        row.Children.Add(button);
        return row;
    }

    void Move(string project)
    {
        Problem.IsOpen = false;
        _ = Task.Run(() => move(project)).ContinueWith(t => DispatcherQueue.TryEnqueue(() =>
        {
            var err = t.IsCompletedSuccessfully ? t.Result : t.Exception?.GetBaseException().Message;
            if (err is not null)
            {
                Problem.Title = "Runbranch could not do that";
                Problem.Message = err;
                Problem.IsOpen = true;
                return;
            }
            Moved = true;
            Reload();
        }), TaskScheduler.Default);
    }

    void OnDone(object sender, RoutedEventArgs e) => Hide();
}
