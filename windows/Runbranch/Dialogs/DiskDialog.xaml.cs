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

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Runbranch.Dialogs;

public sealed record DiskRowView(string Title, string Project, string Size, BadgeSpec Badge)
{
    public static DiskRowView From(DiskRow r) => new(DiskRules.Title(r), r.Project, r.Size, DiskRules.Badge(r));
}

public sealed partial class DiskDialog : SheetDialog
{
    readonly Func<List<DiskRow>> measure;
    readonly Func<string, string?> prune;

    /// <param name="measure">Every worktree and its size, off the UI thread. Seconds, not milliseconds.</param>
    /// <param name="prune">Removes one project's worktrees whose branch is gone; what went wrong, or null.</param>
    public DiskDialog(Func<List<DiskRow>> measure, Func<string, string?> prune)
    {
        InitializeComponent();
        Frame(Root, 520, 400);
        DefaultAction = Done;
        this.measure = measure;
        this.prune = prune;
        Opened += (_, _) => Measure();
    }

    /// <summary>Whether anything was pruned, so the caller knows its caches are stale.</summary>
    public bool Pruned { get; private set; }

    void Measure()
    {
        Show(null);
        _ = Task.Run(measure).ContinueWith(t => DispatcherQueue.TryEnqueue(() =>
            Show(t.IsCompletedSuccessfully ? t.Result : [])), TaskScheduler.Default);
    }

    /// <summary>null: still measuring.</summary>
    void Show(List<DiskRow>? rows)
    {
        Summary.Text = DiskRules.Summary(rows);
        Measuring.Visibility = rows is null ? Visibility.Visible : Visibility.Collapsed;
        Empty.Visibility = rows is { Count: 0 } ? Visibility.Visible : Visibility.Collapsed;
        List.Visibility = rows is { Count: > 0 } ? Visibility.Visible : Visibility.Collapsed;
        Rows.ItemsSource = rows?.Select(DiskRowView.From).ToList();
        Status.Text = DiskRules.Footer(rows) ?? "";

        var prunable = rows is null ? [] : DiskRules.Prunable(rows);
        Reclaim.Visibility = prunable.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ReclaimMenu.Items.Clear();
        foreach (var p in prunable)
        {
            var item = new MenuFlyoutItem { Text = p };
            item.Click += (_, _) => Prune(p);
            ReclaimMenu.Items.Add(item);
        }
    }

    /// <summary>Prunes, then measures again: the only picture worth showing afterwards is a new one.</summary>
    void Prune(string project)
    {
        Problem.IsOpen = false;
        Show(null);
        _ = Task.Run(() => prune(project)).ContinueWith(t => DispatcherQueue.TryEnqueue(() =>
        {
            var err = t.IsCompletedSuccessfully ? t.Result : t.Exception?.GetBaseException().Message;
            if (err is not null)
            {
                Problem.Title = "Runbranch could not do that";
                Problem.Message = err;
                Problem.IsOpen = true;
            }
            else Pruned = true;
            Measure();
        }), TaskScheduler.Default);
    }

    void OnDone(object sender, RoutedEventArgs e) => Hide();
}
