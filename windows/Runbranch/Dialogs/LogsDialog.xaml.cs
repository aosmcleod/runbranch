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

// A live tail of one target's log. The engine already writes each target to
// its own file; this just follows it (ui-map §4.6, LogTail.cs).

using System.Collections.ObjectModel;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Runbranch.Dialogs;

/// <summary>
/// A line with an identity that survives the next tick. On the Mac the list
/// was once strings keyed by index, which rebuilt every row on every render.
/// </summary>
public sealed record LogLine(int Id, string Text, bool IsError);

public sealed partial class LogLineTemplates : DataTemplateSelector
{
    public DataTemplate? Plain { get; set; }
    public DataTemplate? Error { get; set; }

    protected override DataTemplate SelectTemplateCore(object item) =>
        (item is LogLine { IsError: true } ? Error : Plain) ?? throw new InvalidOperationException("LogLineTemplates needs both templates.");

    protected override DataTemplate SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}

public sealed partial class LogsDialog : SheetDialog
{
    static readonly TimeSpan FirstRead = TimeSpan.FromMilliseconds(200);
    static readonly TimeSpan Interval = TimeSpan.FromMilliseconds(1500);

    readonly string logDir;
    readonly Func<IReadOnlyList<RunTarget>> targets;
    readonly DispatcherQueueTimer timer;
    readonly List<LogLine> lines = [];
    ObservableCollection<LogLine> shown = [];
    LogTail tail = new();
    string selected;
    string names;
    string filter = "";
    int nextId;
    bool reading;
    bool building;

    public LogsDialog(string logDir, Func<IReadOnlyList<RunTarget>> targets)
    {
        InitializeComponent();
        Frame(Root, 680, 460);
        DefaultAction = Done;
        this.logDir = logDir;
        this.targets = targets;

        // Valid on the first layout pass, not the second. On the Mac this was
        // set on appear, so the first render had no selection at all — and a
        // segmented picker whose selection matches none of its items lays out
        // at a different width, so the header reflowed a frame later.
        var initial = targets();
        selected = initial.FirstOrDefault()?.Name ?? "";
        names = Names(initial);
        BuildPicker(initial);
        Lines.ItemsSource = shown;

        // Nothing touches the disk until the sheet has finished presenting.
        // The Mac read the log synchronously while its sheet animated in,
        // and the content won the race for the first frame.
        timer = DispatcherQueue.CreateTimer();
        timer.Interval = FirstRead;
        timer.Tick += (_, _) =>
        {
            timer.Interval = Interval;
            CheckTargets();
            Load();
        };
        Opened += (_, _) => timer.Start();
        Closed += (_, _) => timer.Stop();
    }

    static string Names(IReadOnlyList<RunTarget> list) => string.Join(",", list.Select(t => t.Name));

    void BuildPicker(IReadOnlyList<RunTarget> list)
    {
        building = true;
        Picker.Items.Clear();
        if (list.Count > 1)
        {
            // The button padding, so the picker is the 28 px every control here
            // is; its own padding made it 30, and clamping it clipped descenders.
            var padding = Resource<Thickness>("ButtonPadding");
            foreach (var t in list) Picker.Items.Add(new SegmentedItem { Content = t.Name, Tag = t.Name, Padding = padding });
            Picker.SelectedIndex = Math.Max(0, list.ToList().FindIndex(t => t.Name == selected));
            Picker.Visibility = Visibility.Visible;
        }
        else Picker.Visibility = Visibility.Collapsed;
        Subtitle.Text = list.Count > 1 || selected.Length == 0 ? " " : selected;
        building = false;
    }

    /// <summary>
    /// Opened before the run state had loaded, the Mac's viewer had no
    /// targets to pick from and nothing ever went back for them: it sat at
    /// "0 lines" over a log file with plenty in it. So the list is asked for
    /// again each tick, and a selection it no longer holds is replaced.
    /// </summary>
    void CheckTargets()
    {
        var now = targets();
        var joined = Names(now);
        if (joined == names) return;
        names = joined;
        if (selected.Length == 0 || now.All(t => t.Name != selected))
        {
            selected = now.FirstOrDefault()?.Name ?? "";
            Reset();
        }
        BuildPicker(now);
    }

    void OnPicked(object sender, SelectionChangedEventArgs e)
    {
        if (building || Picker.SelectedItem is not SegmentedItem { Tag: string name } || name == selected) return;
        selected = name;
        Subtitle.Text = " ";
        Reset();
        // Switching restarts the loop, first read after the same short beat.
        timer.Stop();
        timer.Interval = FirstRead;
        timer.Start();
    }

    /// <summary>A fresh tail rather than a rewound one, so a read in flight for the old target lands nowhere.</summary>
    void Reset()
    {
        tail = new LogTail();
        lines.Clear();
        nextId = 0;
        Rebuild();
    }

    void Load()
    {
        if (selected.Length == 0 || reading) return;
        reading = true;
        var mine = tail;
        var path = Path.Combine(logDir, selected + ".log");
        _ = Task.Run(() => mine.Read(path)).ContinueWith(t => DispatcherQueue.TryEnqueue(() =>
        {
            reading = false;
            if (!ReferenceEquals(mine, tail) || !t.IsCompletedSuccessfully) return;
            Apply(t.Result);
        }), TaskScheduler.Default);
    }

    void Apply(LogChunk chunk)
    {
        if (chunk.Reset)
        {
            lines.Clear();
            nextId = 0;
        }
        if (chunk.Lines.Count == 0)
        {
            if (chunk.Reset) Rebuild();
            return;
        }
        var fresh = chunk.Lines.Select(l => new LogLine(nextId++, l, LogRules.LooksLikeError(l))).ToList();
        lines.AddRange(fresh);
        if (chunk.Reset || lines.Count > LogRules.Keep)
        {
            if (lines.Count > LogRules.Keep) lines.RemoveRange(0, lines.Count - LogRules.Keep);
            Rebuild();
        }
        else
        {
            foreach (var l in fresh)
                if (LogRules.Matches(l.Text, filter)) shown.Add(l);
            Counts();
        }
        ScrollToEnd();
    }

    void Rebuild()
    {
        shown = new ObservableCollection<LogLine>(lines.Where(l => LogRules.Matches(l.Text, filter)));
        Lines.ItemsSource = shown;
        Counts();
    }

    void Counts()
    {
        LineCount.Text = LogRules.LineCount(shown.Count);
        ErrorCount.Text = LogRules.ErrorCount(shown.Count(l => l.IsError));
    }

    void OnFilterChanged(object sender, TextChangedEventArgs e)
    {
        filter = Filter.Text;
        Rebuild();
        ScrollToEnd();
    }

    void OnReveal(object sender, RoutedEventArgs e)
    {
        var file = Path.Combine(logDir, selected + ".log");
        if (selected.Length > 0 && File.Exists(file)) Shell.ShowInExplorer(file);
        else if (Directory.Exists(logDir)) Shell.OpenFolder(logDir);
    }

    void OnDone(object sender, RoutedEventArgs e) => Hide();

    void ScrollToEnd() =>
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            Scroller.UpdateLayout();
            Scroller.ChangeView(null, Scroller.ScrollableHeight, null, disableAnimation: true);
        });
}
