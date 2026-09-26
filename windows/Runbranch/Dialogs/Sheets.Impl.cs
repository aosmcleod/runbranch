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

// The bodies of Sheets (the contract is Sheets.cs): each builds its dialog
// over the real engine and puts it up through Present, which keeps the
// one-at-a-time rule. The dialogs take their data as functions, so the
// harness (Harness.cs) can put the same dialogs up over demo data.

using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Runbranch.Dialogs;

public static partial class Sheets
{
    /// <summary>
    /// The theme of the window the sheet is over, followed while it is up.
    /// A dialog lives in the window's popup layer, which does not inherit the
    /// theme its content asks for, so a window set to dark by the Appearance
    /// setting would otherwise put up light sheets.
    /// </summary>
    internal static T Themed<T>(T dialog, XamlRoot root) where T : ContentDialog
    {
        if (root.Content is not FrameworkElement content) return dialog;
        void Follow(FrameworkElement sender, object args) => dialog.RequestedTheme = content.ActualTheme;
        Follow(content, null!);
        content.ActualThemeChanged += Follow;
        dialog.Closed += (_, _) => content.ActualThemeChanged -= Follow;
        return dialog;
    }

    public static partial async Task<RunOutcome> Run(XamlRoot root, string title, IReadOnlyList<string> args)
    {
        var dialog = Themed(new RunDialog(title, args), root);
        await Present(dialog, root);
        return dialog.Outcome;
    }

    public static partial Task Logs(XamlRoot root, string logDir, Func<IReadOnlyList<RunTarget>> targets) =>
        Present(Themed(new LogsDialog(logDir, targets), root), root);

    public static partial async Task<bool> Ports(XamlRoot root)
    {
        var dialog = Themed(new PortsDialog(() => (Engine.Ports(), Engine.Overlaps()), Separate), root);
        await Present(dialog, root, isPorts: true);
        return dialog.Moved;
    }

    /// <summary>
    /// The engine picks the number: it has to clear every port the project
    /// declares at once, and account for servers Runbranch did not start.
    /// </summary>
    static string? Separate(string project)
    {
        var offset = Engine.SuggestedOffset(project);
        if (offset is not > 0) return PortRules.NotMoved(project, offset);
        return Engine.Set(project, "PORT_OFFSET", offset.Value.ToString(CultureInfo.InvariantCulture));
    }

    public static partial async Task<PortResolution> PortConflict(XamlRoot root, PendingRun pending)
    {
        var dialog = Themed(new PortConflictDialog(pending), root);
        await Present(dialog, root);
        return dialog.Resolution;
    }

    public static partial async Task<bool> Disk(XamlRoot root)
    {
        var dialog = Themed(new DiskDialog(Engine.Disk, Engine.PruneGone), root);
        await Present(dialog, root);
        return dialog.Pruned;
    }

    public static partial async Task<IReadOnlyList<string>> Scan(XamlRoot root, string startFolder)
    {
        // Overridable, as on the Mac, so documentation captures do not
        // publish a real account name.
        var folder = Environment.GetEnvironmentVariable("RB_SCAN_ROOT") is { Length: > 0 } over ? over : startFolder;
        var dialog = Themed(new ScanDialog(folder, Engine.Scan, Engine.Add), root);
        await Present(dialog, root);
        return dialog.Added;
    }

    public static partial async Task<bool> EditProject(XamlRoot root, string projectId)
    {
        var dialog = Themed(new ProjectEditorDialog(projectId,
            () => Engine.Get(projectId),
            (key, value) => Engine.Set(projectId, key, value),
            () => Engine.Paths(projectId).Config), root);
        await Present(dialog, root);
        return dialog.Saved;
    }

    public static partial async Task<bool> ConfirmRemove(XamlRoot root, Project project)
    {
        var dialog = Themed(new ConfirmRemoveDialog(project), root);
        await Present(dialog, root);
        return dialog.Confirmed;
    }

    public static partial Task Problem(XamlRoot root, string message, string title) =>
        Present(Themed(Alerts.Problem(message, title), root), root);

    public static partial Task About(XamlRoot root) => Present(Themed(new AboutDialog(), root), root);

    public static partial Task Update(XamlRoot root) => Present(Themed(new UpdateDialog(Updater.Shared, QuitForUpdate), root), root);

    /// <summary>
    /// Quits outright once the install helper is waiting. A quit that is only
    /// a request can be held up — on the Mac the update sheet did exactly
    /// that, and the helper sat out its whole patience and had to kill the
    /// app — so ask, then leave.
    /// </summary>
    static void QuitForUpdate()
    {
        App.Instance?.Quit();
        _ = Task.Delay(500).ContinueWith(_ => Environment.Exit(0), TaskScheduler.Default);
    }

    public static partial async Task<bool> WhatsNewIfAny(XamlRoot root)
    {
        var installed = AppVersion.Installed;
        var decision = WhatsNew.Decide(Settings.Shared.LastSeenVersion, installed, ReleaseNotes.All);
        if (decision.Record is { } record) Settings.Shared.LastSeenVersion = record;
        if (decision.Show.Count == 0) return false;
        await Present(Themed(new WhatsNewDialog(decision.Show, installed), root), root);
        return true;
    }
}

/// <summary>
/// The one alert that is a stock dialog, as a Windows alert is, with the Mac's
/// words. A single OK is the only button, so the stock layout cannot put it in
/// the wrong place; Remove has a sheet of its own (ConfirmRemoveDialog) because
/// with two buttons it did.
/// </summary>
static class Alerts
{
    static TextBlock Body(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        IsTextSelectionEnabled = true,
        Style = (Style)Application.Current.Resources["RbBodyTextStyle"],
    };

    /// <summary>The engine's words verbatim, Fix: block and all — it names the command that fixes it.</summary>
    public static ContentDialog Problem(string message, string title) => new()
    {
        Title = title,
        Content = Body(message),
        CloseButtonText = "OK",
        DefaultButton = ContentDialogButton.Close,
    };
}
