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

// Blocking sheet over the window. Closes itself when the run comes up; stays
// put when it does not, because that is the moment you need the log.

using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;

namespace Runbranch.Dialogs;

public sealed partial class RunDialog : SheetDialog
{
    readonly Runner runner = new();
    readonly string title;
    bool started;
    bool stopped;
    bool closing;

    public RunDialog(string title, IReadOnlyList<string> args)
    {
        InitializeComponent();
        Frame(Root, 620, 420);
        this.title = title;
        Headline.Text = title;
        Lines.ItemsSource = runner.Lines;
        runner.Lines.CollectionChanged += (_, _) => ScrollToEnd();
        runner.Completed += (_, _) => OnFinished();
        // Started once the sheet is up, not before: a sheet that had to wait
        // for another to be dismissed would otherwise run behind it.
        Opened += (_, _) =>
        {
            if (started) return;
            started = true;
            runner.Start(args);
        };
    }

    public RunOutcome Outcome =>
        runner.Finished && !runner.Failed ? RunOutcome.Succeeded : stopped ? RunOutcome.Stopped : RunOutcome.Failed;

    /// <summary>Escape is Stop while running (the Mac's cancel action), and Close after.</summary>
    protected override void OnCancel()
    {
        if (runner.IsRunning) Stop();
        else Hide();
    }

    void OnStop(object sender, RoutedEventArgs e) => Stop();

    void Stop()
    {
        stopped = true;
        runner.Cancel();
    }

    void OnClose(object sender, RoutedEventArgs e) => Hide();

    void OnCopyLog(object sender, RoutedEventArgs e)
    {
        var data = new DataPackage();
        data.SetText(string.Join("\n", runner.Lines));
        Clipboard.SetContent(data);
    }

    void OnFinished()
    {
        Spinner.IsActive = false;
        Spinner.Visibility = Visibility.Collapsed;
        Succeeded.Visibility = runner.Failed ? Visibility.Collapsed : Visibility.Visible;
        Failed.Visibility = runner.Failed ? Visibility.Visible : Visibility.Collapsed;
        Headline.Text = runner.Failed ? $"{title} — failed" : $"{title} — done";
        CopyLog.Visibility = runner.Failed ? Visibility.Visible : Visibility.Collapsed;
        StopButton.Visibility = Visibility.Collapsed;
        CloseButton.Visibility = Visibility.Visible;
        DefaultAction = CloseButton;
        CloseButton.Focus(FocusState.Programmatic);

        // Success needs no audience. Failure does.
        if (runner.Failed || closing) return;
        closing = true;
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(800);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => Hide();
        timer.Start();
    }

    /// <summary>
    /// After layout, so the new line's height is in the extent. Unanimated:
    /// a chatty install would otherwise be a scroll that never catches up.
    /// </summary>
    void ScrollToEnd() =>
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            Scroller.UpdateLayout();
            Scroller.ChangeView(null, Scroller.ScrollableHeight, null, disableAnimation: true);
        });
}
