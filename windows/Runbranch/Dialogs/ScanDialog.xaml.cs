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

// First run, and the "Scan for projects" flow afterwards.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace Runbranch.Dialogs;

public sealed record FoundRepo(string Name, string Path)
{
    /// <summary>Abbreviated, so a screenshot of the list does not publish the account name.</summary>
    public string Where => Path.AbbreviatingHome();
}

public sealed partial class ScanDialog : SheetDialog
{
    enum Phase { Idle, Scanning, Results, Adding, Done }

    readonly Func<string, List<ScanResult>> scan;
    readonly Func<string, AddedProject?> add;
    readonly List<string> added = [];
    List<FoundRepo> found = [];
    Phase phase;
    bool cancelled;

    /// <param name="scan">Undeclared repositories under a folder, off the UI thread.</param>
    /// <param name="add">Declares one; null if it would not.</param>
    public ScanDialog(string folder, Func<string, List<ScanResult>> scan, Func<string, AddedProject?> add)
    {
        InitializeComponent();
        Frame(Root, 560, 480);
        this.scan = scan;
        this.add = add;
        Folder.Text = folder;
        Set(Phase.Idle);
    }

    /// <summary>The ids of the projects added, in the order they were.</summary>
    public IReadOnlyList<string> Added => added;

    void Set(Phase next)
    {
        phase = next;
        var choosing = next is Phase.Idle or Phase.Scanning;
        Choose.Visibility = choosing ? Visibility.Visible : Visibility.Collapsed;
        Looking.Visibility = next == Phase.Scanning ? Visibility.Visible : Visibility.Collapsed;
        Folder.IsEnabled = Browse.IsEnabled = next == Phase.Idle;
        Found.Visibility = next == Phase.Results && found.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        Nothing.Visibility = next == Phase.Results && found.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Adding.Visibility = next is Phase.Adding or Phase.Done ? Visibility.Visible : Visibility.Collapsed;
        SelectAll.Visibility = next == Phase.Results && found.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        DefaultAction = next is Phase.Adding or Phase.Done ? null : Primary;
        Update();
    }

    /// <summary>The primary button's words and whether it can be pressed, which change with the selection.</summary>
    void Update()
    {
        var chosen = Found.SelectedItems.Count;
        switch (phase)
        {
            case Phase.Idle:
            case Phase.Scanning:
                Primary.Content = "Scan";
                Primary.IsEnabled = phase == Phase.Idle && Folder.Text.Trim().Length > 0;
                break;
            case Phase.Results:
                Primary.Content = ScanRules.AddButton(chosen);
                Primary.IsEnabled = chosen > 0;
                break;
            default:
                Primary.Content = "Done";
                Primary.IsEnabled = phase == Phase.Done;
                break;
        }
        SelectAll.Content = found.Count > 0 && chosen == found.Count ? "Select none" : "Select all";
    }

    void OnFolderChanged(object sender, TextChangedEventArgs e) => Update();

    void OnChosen(object sender, SelectionChangedEventArgs e) => Update();

    void OnSelectAll(object sender, RoutedEventArgs e)
    {
        if (Found.SelectedItems.Count == found.Count) Found.DeselectRange(new Microsoft.UI.Xaml.Data.ItemIndexRange(0, (uint)found.Count));
        else Found.SelectAll();
    }

    async void OnBrowse(object sender, RoutedEventArgs e)
    {
        // The Windows App SDK picker, which takes the owning window by id: the
        // WinRT one needs InitializeWithWindow in an unpackaged app, and
        // throws without it.
        var picker = new FolderPicker(Host.WindowId);
        if (Directory.Exists(Folder.Text.Trim())) picker.SuggestedFolder = Folder.Text.Trim();
        var result = await picker.PickSingleFolderAsync();
        if (result is not null) Folder.Text = result.Path;
    }

    void OnPrimary(object sender, RoutedEventArgs e)
    {
        switch (phase)
        {
            case Phase.Idle: _ = Scan(); break;
            case Phase.Results: _ = Add(); break;
            case Phase.Done: Hide(); break;
        }
    }

    /// <summary>The dialog harness, to show the results phase without a click.</summary>
    internal void StartScanForDemo() => _ = Scan();

    async Task Scan()
    {
        Set(Phase.Scanning);
        var dir = Folder.Text.Trim();
        var repos = await Task.Run(() => scan(dir));
        found = repos.Select(r => new FoundRepo(r.Name, r.Path)).ToList();
        Found.ItemsSource = found;
        Set(Phase.Results);
    }

    async Task Add()
    {
        var chosen = found.Where(f => Found.SelectedItems.Contains(f)).ToList();
        Set(Phase.Adding);
        Progress.Value = 0;
        for (var i = 0; i < chosen.Count; i++)
        {
            AddingText.Text = $"Reading {chosen[i].Name}…";
            var path = chosen[i].Path;
            if (await Task.Run(() => add(path)) is { } a) added.Add(ScanRules.Id(a));
            Progress.Value = (double)(i + 1) / chosen.Count;
            // Cancel stops after the one in hand, rather than on the Mac, where
            // the sheet went and the adding carried on out of sight.
            if (cancelled) return;
        }
        AddingText.Text = ScanRules.Added(added.Count);
        Set(Phase.Done);
        // Then close itself. Sitting on a finished progress bar waiting to be
        // dismissed asks the user to acknowledge something they already know,
        // and the result is behind the sheet: the projects are in the sidebar.
        // Long enough to register that it finished, short enough not to be a wait.
        await Task.Delay(650);
        if (!cancelled) Hide();
    }

    protected override void OnCancel()
    {
        cancelled = true;
        Hide();
    }

    void OnCancelClick(object sender, RoutedEventArgs e) => OnCancel();
}
