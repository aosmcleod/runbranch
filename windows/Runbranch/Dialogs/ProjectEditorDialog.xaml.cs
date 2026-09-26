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

// Editing a project's config without opening a text editor.
//
// The engine owns the file: this reads `get` and writes changed keys through
// `set`, which keeps comments, backs the file up and reverts anything that
// will not load. So the worst a mistake here can do is show an error.

using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Runbranch.Dialogs;

public sealed partial class ProjectEditorDialog : SheetDialog
{
    readonly string projectId;
    readonly Func<string, string, string?> set;
    readonly Func<string?> configPath;
    readonly List<string> runtimes = [.. EditorRules.Runtimes];
    Dictionary<string, string> values = new(StringComparer.Ordinal);
    Dictionary<string, string> original = new(StringComparer.Ordinal);
    bool filling = true;
    bool saving;

    /// <param name="get">Every key, from `get`, off the UI thread.</param>
    /// <param name="set">Writes one key; what went wrong, or null.</param>
    /// <param name="configPath">The .conf, for Show in File Explorer.</param>
    public ProjectEditorDialog(string projectId, Func<Dictionary<string, string>> get,
        Func<string, string, string?> set, Func<string?> configPath)
    {
        InitializeComponent();
        Frame(Root, 560, 620);
        DefaultAction = Save;
        this.projectId = projectId;
        this.set = set;
        this.configPath = configPath;
        Heading.Text = projectId;
        Opened += async (_, _) => Fill(await Task.Run(get));
    }

    /// <summary>Whether any key was written — even if a later one failed — so the caller knows its caches are stale.</summary>
    public bool Saved { get; private set; }

    IEnumerable<FrameworkElement> Fields() =>
        ((StackPanel)Form.Content).Children.OfType<SettingsCard>().Select(c => c.Content).OfType<FrameworkElement>();

    void Fill(Dictionary<string, string> loaded)
    {
        original = new(loaded, StringComparer.Ordinal);
        values = new(loaded, StringComparer.Ordinal);
        string Value(string key) => values.TryGetValue(key, out var v) ? v : "";

        filling = true;
        foreach (var field in Fields())
        {
            switch (field)
            {
                case TextBox { Tag: string key } box:
                    box.Text = Value(key);
                    break;
                case ToggleSwitch { Tag: string key } toggle:
                    toggle.IsOn = Value(key) == "1";
                    break;
            }
        }
        // A runtime this build does not list is kept and shown, rather than
        // read as None and quietly offered for overwriting.
        var runtime = Value("RUNTIME");
        if (!runtimes.Contains(runtime)) runtimes.Add(runtime);
        foreach (var r in runtimes) Runtime.Items.Add(r.Length == 0 ? "None" : r);
        Runtime.SelectedIndex = runtimes.IndexOf(runtime);
        Symbol.Symbol = Value("SYMBOL");
        Repository.Text = Value("REPO").AbbreviatingHome();
        InRepo.IsOpen = Value("IN_REPO").Length > 0;
        filling = false;

        Spinner.IsActive = false;
        Spinner.Visibility = Visibility.Collapsed;
        Form.Visibility = Visibility.Visible;
        Refresh();
        if (ScrollForDemo > 0)
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
                () => Form.ChangeView(null, Form.ScrollableHeight * ScrollForDemo, null, disableAnimation: true));
    }

    /// <summary>The dialog harness, to show the rest of the form: 0 to 1 of the way down.</summary>
    internal double ScrollForDemo { get; set; }

    /// <summary>
    /// A key the user has not touched and the engine did not send stays
    /// absent, so an empty field is not a change; anything else is recorded.
    /// </summary>
    void Change(string key, string value)
    {
        if (filling) return;
        if (!values.ContainsKey(key) && value.Length == 0) return;
        values[key] = value;
        Refresh();
    }

    // A multi-line TextBox hands back CR for every line break; the engine's
    // wire format (and the loaded value) is LF.
    void OnText(object sender, TextChangedEventArgs e)
    {
        if (sender is TextBox { Tag: string key } box) Change(key, box.Text.Replace("\r\n", "\n").Replace('\r', '\n'));
    }

    void OnToggled(object sender, RoutedEventArgs e)
    {
        if (sender is ToggleSwitch { Tag: string key } toggle) Change(key, toggle.IsOn ? "1" : "0");
    }

    void OnRuntime(object sender, SelectionChangedEventArgs e)
    {
        if (Runtime.SelectedIndex >= 0) Change("RUNTIME", runtimes[Runtime.SelectedIndex]);
    }

    void OnSymbol(object? sender, string symbol) => Change("SYMBOL", symbol);

    void Refresh()
    {
        var dirty = EditorRules.DirtyKeys(values, original);
        Heading.Text = values.TryGetValue("NAME", out var name) && name.Length > 0 ? name : projectId;
        Unsaved.Text = dirty.Count > 0 ? $"{dirty.Count} unsaved" : "";
        Save.Content = saving ? "Saving…" : "Save";
        Save.IsEnabled = dirty.Count > 0 && !saving;
        OffsetCard.Description = EditorRules.OffsetNote(
            values.TryGetValue("TARGETS", out var t) ? t : "", values.TryGetValue("PORT_OFFSET", out var o) ? o : "");
    }

    /// <summary>
    /// Writes only what changed, and stops at the first failure rather than
    /// carrying on and leaving the file half-updated. What was written before
    /// the failure is no longer unsaved, so trying again writes only the rest.
    /// </summary>
    async void OnSave(object sender, RoutedEventArgs e)
    {
        saving = true;
        Problem.IsOpen = false;
        Refresh();
        var keys = EditorRules.DirtyKeys(values, original);
        var snapshot = new Dictionary<string, string>(values, StringComparer.Ordinal);
        var (failure, written) = await Task.Run(() =>
        {
            var done = new List<string>();
            foreach (var k in keys)
            {
                if (set(k, snapshot[k]) is { } err) return (err, done);
                done.Add(k);
            }
            return ((string?)null, done);
        });
        foreach (var k in written) original[k] = snapshot[k];
        Saved |= written.Count > 0;
        saving = false;
        if (failure is null)
        {
            Hide();
            return;
        }
        Problem.Title = "Could not save";
        Problem.Message = EditorRules.FirstLine(failure);
        Problem.IsOpen = true;
        Refresh();
    }

    async void OnReveal(object sender, RoutedEventArgs e)
    {
        if (await Task.Run(configPath) is { Length: > 0 } path) Shell.ShowInExplorer(path);
    }

    void OnCancelClick(object sender, RoutedEventArgs e) => Hide();
}
