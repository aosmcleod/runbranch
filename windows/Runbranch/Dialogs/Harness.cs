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

// A development aid: RB_SHOW_SHEET=<name> opens one sheet over demo data as
// soon as the window is up, so each can be looked at and photographed
// without driving the app into the state that raises it — the part of the
// Mac's `--screenshot --scene` that concerns sheets. RB_SHEET_THEME=dark or
// light forces the theme on the window's content, as the Appearance setting
// does. Nothing here runs unless the variable is set.

using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace Runbranch.Dialogs;

public static partial class Harness
{
    public static void Attach(Window window)
    {
        var scene = Environment.GetEnvironmentVariable("RB_SHOW_SHEET");
        if (string.IsNullOrEmpty(scene)) return;
        if (Environment.GetEnvironmentVariable("RB_SHEET_PROBE") is { Length: > 0 } trace)
            AppDomain.CurrentDomain.FirstChanceException += (_, e) =>
            {
                try { File.AppendAllText(trace + ".exceptions", $"{e.Exception.GetType().Name}: {e.Exception.Message}\n{Environment.StackTrace}\n\n"); }
                catch (IOException) { }
            };
        void Go(FrameworkElement content)
        {
            if (Environment.GetEnvironmentVariable("RB_SHEET_THEME") is { Length: > 0 } theme)
                content.RequestedTheme = theme == "dark" ? ElementTheme.Dark : ElementTheme.Light;
            // After the launch has settled: the window's own start-up (the
            // onboarding size, What's new) would otherwise resize it under
            // the sheet, or dismiss the sheet to show its own.
            var timer = content.DispatcherQueue.CreateTimer();
            timer.Interval = TimeSpan.FromSeconds(3);
            timer.IsRepeating = false;
            timer.Tick += (_, _) =>
            {
                Sheets.DismissCurrent();
                // The Mac's default window, so every sheet has the room it has there.
                var scale = content.XamlRoot.RasterizationScale;
                window.AppWindow.Resize(new SizeInt32((int)(1000 * scale), (int)(720 * scale)));
                var shown = Environment.GetEnvironmentVariable("RB_SHEET_LIVE") == "1" && window is MainWindow main
                    ? ShowLive(scene, content.XamlRoot, main)
                    : Show(scene, content.XamlRoot);
                _ = shown.ContinueWith(t => Crash.Record(t.Exception!), TaskContinuationOptions.OnlyOnFaulted);
                if (Environment.GetEnvironmentVariable("RB_SHEET_PROBE") is { Length: > 0 } probe) Probe(content, probe);
            };
            timer.Start();
        }
        if (window.Content is FrameworkElement fe)
        {
            if (fe.IsLoaded) Go(fe);
            else fe.Loaded += (_, _) => Go(fe);
        }
    }

    /// <summary>
    /// RB_SHEET_PROBE=&lt;file&gt;: the measured size of every control in the
    /// open sheet, so the F6 grid (28 px controls, badges hugging their text)
    /// can be checked by number rather than by eye.
    /// </summary>
    static void Probe(FrameworkElement content, string file)
    {
        var timer = content.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            string[] wanted =
            [
                "Button", "DropDownButton", "HyperlinkButton", "TextBox", "ComboBox", "ToggleSwitch", "AutoSuggestBox",
                "Segmented", "SegmentedItem", "Badge", "SettingsCard", "CheckBox", "ListViewItem", "ProgressBar", "InfoBar",
                "SymbolPicker", "Image",
            ];
            var lines = new List<string>();
            // One control's whole template, when its size needs explaining.
            void Dump(DependencyObject o, int depth)
            {
                for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(o); i++)
                {
                    var c = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(o, i);
                    if (c is FrameworkElement f)
                        lines.Add($"{new string(' ', depth * 2)}{c.GetType().Name} {f.Name} {f.ActualWidth:0.#}x{f.ActualHeight:0.#} m={f.Margin} v={f.Visibility}");
                    Dump(c, depth + 1);
                }
            }
            void Walk(DependencyObject o, int depth)
            {
                if (o is FrameworkElement { Visibility: Visibility.Visible } fe && fe.ActualHeight > 0 && wanted.Contains(o.GetType().Name))
                    lines.Add($"{o.GetType().Name} {fe.Name} {fe.ActualWidth:0.#}x{fe.ActualHeight:0.#}");
                if (o is Views.Badge or Views.SymbolPicker) return;
                if (o is Microsoft.UI.Xaml.Controls.ToggleSwitch && !lines.Any(l => l.StartsWith("  ", StringComparison.Ordinal))) Dump(o, 1);
                for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(o); i++)
                    Walk(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(o, i), depth + 1);
            }
            foreach (var popup in Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(content.XamlRoot))
                if (popup.Child is { } child) Walk(child, 0);
            File.WriteAllLines(file, lines);
        };
        timer.Start();
    }

    /// <summary>RB_SHEET_RESULT=&lt;file&gt;: what a sheet returned, so a keyboard test can check the choice.</summary>
    static void Result(object value)
    {
        if (Environment.GetEnvironmentVariable("RB_SHEET_RESULT") is { Length: > 0 } file) File.WriteAllText(file, value.ToString());
    }

    /// <summary>
    /// RB_SHEET_LIVE=1: the real sheet, over whatever RB_PROJECTS_DIR and
    /// RB_HOME hold, as the app itself would open it — for the docs captures
    /// (tools/screenshot.ps1), which run against the same demo as the Mac's
    /// so the two sets show the same projects. Scenes with no live
    /// equivalent fall back to the demo data.
    /// </summary>
    static async Task ShowLive(string scene, XamlRoot root, MainWindow window)
    {
        var project = Environment.GetEnvironmentVariable("RB_SHEET_PROJECT") ?? "northwind-web";
        switch (scene)
        {
            case "logs":
                // The sheet reads the selected project's snapshot, which the
                // window is still loading when the harness fires.
                for (var i = 0; i < 60 && !window.HasSnapshot; i++) await Task.Delay(250);
                await window.ShowLogs();
                break;
            case "ports": await Sheets.Ports(root); break;
            case "disk": await Sheets.Disk(root); break;
            case "scan": await Sheets.Scan(root, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)); break;
            case "editor": await Sheets.EditProject(root, project); break;
            default: await Show(scene, root); break;
        }
    }

    static async Task Show(string scene, XamlRoot root)
    {
        switch (scene)
        {
            case "run":
                // A stream that takes its time, so the running state can be
                // seen: Windows PowerShell stands in for the engine.
                Environment.SetEnvironmentVariable("RB_ENGINE",
                    Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"));
                await Sheets.Run(root, "Starting feat/checkout-summary", ["-NoProfile", "-Command", Demo.RunScript]);
                break;
            case "run-failed":
                await Sheets.Run(root, "Starting feat/checkout-summary", ["run", "no-such-project", "main", "web"]);
                break;
            case "logs":
                await Sheets.Logs(root, Demo.LogDir(), () => Demo.Targets);
                break;
            case "logs-one":
                await Sheets.Logs(root, Demo.LogDir(), () => Demo.Targets.Take(1).ToList());
                break;
            case "ports":
                await Sheets.Present(Sheets.Themed(new PortsDialog(() => (Demo.Ports, Demo.Overlaps),
                    p => PortRules.NotMoved(p, 0)), root), root, isPorts: true);
                break;
            case "conflict":
            case "conflict-outside":
                Result(await Sheets.PortConflict(root, Demo.Pending(outside: scene == "conflict-outside")));
                break;
            case "disk":
                await Sheets.Present(Sheets.Themed(new DiskDialog(() => Demo.Disk, _ => null), root), root);
                break;
            case "disk-measuring":
                await Sheets.Present(Sheets.Themed(new DiskDialog(() => { Thread.Sleep(60_000); return []; }, _ => null), root), root);
                break;
            case "scan":
            case "scan-results":
            {
                var dialog = new ScanDialog(@"C:\Code", _ => Demo.Found, _ => null);
                if (scene == "scan-results") dialog.Opened += (_, _) => dialog.StartScanForDemo();
                await Sheets.Present(Sheets.Themed(dialog, root), root);
                break;
            }
            case "editor":
            case "editor-mid":
            case "editor-end":
                await Sheets.Present(Sheets.Themed(new ProjectEditorDialog("northwind", () => Demo.Config,
                    (_, _) => "TARGETS: line 2 needs name:port:health:command", () => null) { ScrollForDemo = scene == "editor-end" ? 1 : scene == "editor-mid" ? 0.5 : 0 }, root), root);
                break;
            case "remove":
                Result(await Sheets.ConfirmRemove(root, new Project { Id = "northwind", Name = "Northwind Web", Repo = @"C:\Code\northwind-web" }));
                break;
            case "problem":
                await Sheets.Problem(root, "Northwind Web: C:\\Code\\northwind-web is not a git repository.\nFix:\n    edit the REPO line in northwind.conf");
                break;
            case "about":
                await Sheets.About(root);
                break;
            case "update":
                Updater.Shared.Offer(Release.Sample(ReleaseNotes.All.FirstOrDefault()?.Notes ?? Demo.Notes));
                await Sheets.Update(root);
                break;
            case "update-downloading":
                Updater.Shared.Offer(Release.Sample(Demo.Notes));
                Updater.Shared.Preview(UpdatePhase.Downloading, 0.42);
                await Sheets.Update(root);
                break;
            case "update-failed":
                Updater.Shared.Preview(UpdatePhase.Failed, reason: "No network connection.");
                await Sheets.Update(root);
                break;
            case "update-current":
                Updater.Shared.Preview(UpdatePhase.UpToDate);
                await Sheets.Update(root);
                break;
            case "update-dev":
                Updater.Shared.Preview(UpdatePhase.Development);
                await Sheets.Update(root);
                break;
            case "whatsnew":
            {
                var notes = ReleaseNotes.All.Count > 0 ? ReleaseNotes.All.Take(2).ToList() : [new ReleaseNote("1.5.1", Demo.Notes)];
                await Sheets.Present(Sheets.Themed(new WhatsNewDialog(notes, AppVersion.Parse(notes[0].Version)!), root), root);
                break;
            }
            default:
                await Sheets.Problem(root, $"RB_SHOW_SHEET={scene} is not a sheet the harness knows.");
                break;
        }
    }
}
