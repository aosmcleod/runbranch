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

// The Update sheet draws whatever Updater.Shared says, and redraws when it
// changes — which it does off the UI thread while downloading.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Runbranch.Dialogs;

public sealed partial class UpdateDialog : SheetDialog
{
    readonly Updater updater;
    readonly Action quit;

    /// <param name="quit">Ends the app once the helper is waiting for it to.</param>
    public UpdateDialog(Updater updater, Action quit)
    {
        InitializeComponent();
        Frame(Root, 520, 260);
        this.updater = updater;
        this.quit = quit;
        Mark.Source = new BitmapImage(new Uri(Build.MarkUri));

        void Changed() => DispatcherQueue.TryEnqueue(Render);
        updater.Changed += Changed;
        Closed += (_, _) =>
        {
            updater.Changed -= Changed;
            // Closing is Later, Done or Close: the offer goes, as on the Mac,
            // until the next check finds it again.
            if (updater.Phase != UpdatePhase.Installing) updater.Dismiss();
        };
        Render();
    }

    bool Busy => updater.Phase is UpdatePhase.Downloading or UpdatePhase.Verifying or UpdatePhase.Installing;

    /// <summary>There is no walking away from an install half done; Escape closes anything else.</summary>
    protected override void OnCancel()
    {
        if (!Busy) Hide();
    }

    void Render()
    {
        var release = updater.Available;
        var phase = updater.Phase;
        var installed = updater.Installed.Description;
        Resize(release is null ? 260 : 440);

        (Heading.Text, Subtitle.Text) = (release, phase) switch
        {
            ({ } r, _) => ($"Runbranch {r.Version.Description} is available", $"You have {installed}"),
            (null, UpdatePhase.Failed) => ("Could not check for updates", updater.Reason),
            // Not "out for macOS": a release is also like this for the few
            // minutes between being published and the workflow attaching its
            // zip, when it is out for nothing yet. This is true either way.
            (null, UpdatePhase.NotForWindows) =>
                ($"Runbranch {updater.Newer?.Description ?? "a newer version"} isn't ready for Windows yet", $"You have {installed}"),
            (null, UpdatePhase.Development) => ("This is a development build", $"Built from source as {installed}"),
            (null, UpdatePhase.Checking) => ("Checking for updates", $"You have {installed}"),
            _ => ("Runbranch is up to date", $"Version {installed}, the latest release"),
        };

        NotesScroller.Visibility = release is null ? Visibility.Collapsed : Visibility.Visible;
        Notes.Text = release?.Notes ?? "";
        Status.Visibility = release is null ? Visibility.Visible : Visibility.Collapsed;
        Checking.IsActive = phase == UpdatePhase.Checking;
        Checking.Visibility = phase == UpdatePhase.Checking ? Visibility.Visible : Visibility.Collapsed;
        StatusIcon.Visibility = phase == UpdatePhase.Checking ? Visibility.Collapsed : Visibility.Visible;
        Icons.SetSymbol(StatusIcon, phase switch
        {
            UpdatePhase.Failed => "wifi.exclamationmark",
            // The Mac shows a clock, which Icons has no glyph for yet.
            UpdatePhase.NotForWindows => "bell",
            UpdatePhase.Development => "hammer",
            _ => "checkmark.circle",
        });
        StatusLine.Text = phase switch
        {
            UpdatePhase.Failed => "Releases are listed on GitHub if you would rather look yourself.",
            UpdatePhase.NotForWindows =>
                "The Windows version is not ready yet. It will be offered here once it is, and there is nothing to install until then.",
            UpdatePhase.Development =>
                "It does not update itself, because an update would replace the build you are working on with whatever was last released.",
            UpdatePhase.Checking => "Asking GitHub for the latest release.",
            _ => "Nothing to install.",
        };

        // The footer, by phase.
        Working.Visibility = Busy ? Visibility.Visible : Visibility.Collapsed;
        Progress.IsIndeterminate = phase != UpdatePhase.Downloading || updater.Progress is null;
        Progress.Value = updater.Progress ?? 0;
        WorkingText.Text = phase switch
        {
            UpdatePhase.Downloading => $"Downloading {release?.Version.Description}…",
            UpdatePhase.Verifying => "Checking the download…",
            _ => "Installing. Runbranch will restart on its own.",
        };

        var failed = phase == UpdatePhase.Failed;
        Why.Text = updater.Reason;
        Why.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
        OpenReleases.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;

        var offering = release is not null && !Busy && !failed;
        TurnOff.Visibility = offering ? Visibility.Visible : Visibility.Collapsed;
        Later.Visibility = offering ? Visibility.Visible : Visibility.Collapsed;
        Install.Visibility = offering ? Visibility.Visible : Visibility.Collapsed;

        Close.Content = failed ? "Close" : "Done";
        Close.Visibility = !Busy && !offering ? Visibility.Visible : Visibility.Collapsed;
        DefaultAction = Busy ? null : offering ? Install : Close;
    }

    async void OnInstall(object sender, RoutedEventArgs e)
    {
        if (updater.Available is { } release) await updater.InstallAsync(release, () => DispatcherQueue.TryEnqueue(() => quit()));
    }

    void OnTurnOff(object sender, RoutedEventArgs e)
    {
        updater.TurnOffChecks();
        Hide();
    }

    void OnOpenReleases(object sender, RoutedEventArgs e) => Shell.OpenUrl(ReleaseFeed.ReleasesPage);

    void OnClose(object sender, RoutedEventArgs e) => Hide();
}
