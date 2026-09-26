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

// Every sheet the main window can put up, and the one rule they share: one at
// a time. The Mac expresses that as a single `Sheet` enum in ContentView; here
// it is this class, because ContentDialog enforces it harder than SwiftUI does
// — ShowAsync throws when another dialog is already open on the same root.
//
// The main window only ever calls these methods. It never constructs a dialog
// itself, and nothing in Dialogs/ reaches back into the window: whatever a
// sheet decides comes back as its return value, and the window acts on it.
// That keeps the start flow (check ports, resolve, run) in one place, as it is
// in ContentView.startChecking.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Runbranch.Dialogs;

/// <summary>How a streamed engine command ended.</summary>
public enum RunOutcome { Succeeded, Failed, Stopped }

/// <summary>What the user chose on the port conflict sheet.</summary>
public enum PortResolution
{
    Cancel,
    /// <summary>Stop the Runbranch runs holding the ports, then run.</summary>
    StopAndSwitch,
    /// <summary>End the outside processes holding the ports, then run.</summary>
    TakeOver,
    /// <summary>Run with the conflict's FreeOffset.</summary>
    Shift,
}

public static partial class Sheets
{
    static ContentDialog? current;

    /// <summary>Whether a sheet is up. The 30 s live refresh and the update offer both check it.</summary>
    public static bool IsOpen => current is not null;

    /// <summary>
    /// Whether the sheet that is up is the Ports sheet, which is the one sheet
    /// the 30 s live refresh still runs behind (ContentView.swift:664).
    /// </summary>
    public static bool PortsOpen { get; private set; }

    /// <summary>Hides whatever sheet is up. Its Show call then returns as if cancelled.</summary>
    public static void DismissCurrent() => current?.Hide();

    /// <summary>
    /// Shows a dialog as the only sheet. If one is already up it is dismissed
    /// first, and this waits a dispatcher turn before showing the next —
    /// the same dismiss-then-present the Mac's present() does, for the same
    /// reason: presenting in the same turn as a dismissal is refused.
    /// </summary>
    public static async Task<ContentDialogResult> Present(ContentDialog dialog, XamlRoot root, bool isPorts = false)
    {
        if (current is not null)
        {
            var closing = current;
            var closed = new TaskCompletionSource();
            closing.Closed += (_, _) => closed.TrySetResult();
            closing.Hide();
            await closed.Task;
            await Task.Yield();
        }
        dialog.XamlRoot = root;
        current = dialog;
        PortsOpen = isPorts;
        try
        {
            return await dialog.ShowAsync();
        }
        finally
        {
            if (ReferenceEquals(current, dialog))
            {
                current = null;
                PortsOpen = false;
            }
        }
    }

    // ------------------------------------------------------------------
    // The sheets. Bodies belong to Dialogs/*: the stubs below keep the main
    // window compiling until each dialog lands, and are replaced one by one.
    // ------------------------------------------------------------------

    /// <summary>Streams an engine command (run, stop, update, remove, remove-worktree) — RunSheet.swift.
    /// Auto-closes 0.8 s after success; stays open on failure. Stop terminates the command.</summary>
    public static partial Task<RunOutcome> Run(XamlRoot root, string title, IReadOnlyList<string> args);

    /// <summary>Tails logs/&lt;target&gt;.log for the running targets — RunSheet.swift LogsSheet.
    /// <paramref name="targets"/> is re-read each tick, since targets can change while it is open.</summary>
    public static partial Task Logs(XamlRoot root, string logDir, Func<IReadOnlyList<RunTarget>> targets);

    /// <summary>Every declared port and what holds it, plus overlaps and Move… — Ports.swift PortsSheet.
    /// Moving a project writes PORT_OFFSET itself; returns whether anything was moved.</summary>
    public static partial Task<bool> Ports(XamlRoot root);

    /// <summary>The ports a run needs are taken — Ports.swift PortConflictSheet.</summary>
    public static partial Task<PortResolution> PortConflict(XamlRoot root, PendingRun pending);

    /// <summary>Worktree sizes and Reclaim… — Disk.swift. Returns whether anything was pruned.</summary>
    public static partial Task<bool> Disk(XamlRoot root);

    /// <summary>Find and add projects — ScanSheet.swift. Returns the ids of the projects added, in order.</summary>
    public static partial Task<IReadOnlyList<string>> Scan(XamlRoot root, string startFolder);

    /// <summary>Every config key in a form — ProjectEditor.swift. Returns whether anything was saved.</summary>
    public static partial Task<bool> EditProject(XamlRoot root, string projectId);

    /// <summary>"Remove &lt;name&gt;?" with the repository-is-not-touched wording — ContentView.swift:643.</summary>
    public static partial Task<bool> ConfirmRemove(XamlRoot root, Project project);

    /// <summary>"Runbranch could not do that" plus the engine's verbatim message — ContentView.swift:679.</summary>
    public static partial Task Problem(XamlRoot root, string message, string title = "Runbranch could not do that");

    /// <summary>About Runbranch — App.swift AboutView.</summary>
    public static partial Task About(XamlRoot root);

    /// <summary>The update sheet for whatever Updater.Shared has found or is doing — Updates.swift UpdateSheet.</summary>
    public static partial Task Update(XamlRoot root);

    /// <summary>What's new since the last version this user opened; shows nothing when there is nothing new.
    /// Returns whether it showed anything — Updates.swift WhatsNewSheet.</summary>
    public static partial Task<bool> WhatsNewIfAny(XamlRoot root);
}
