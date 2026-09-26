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

using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Runbranch.Views;

/// <summary>
/// The run's status, as one card.
///
/// An earlier Mac version copied Stocks' stats grid literally — a column of
/// 9pt uppercase labels over values. At that size the labels were unreadable,
/// and four of them turned a status line into a form. What actually matters is
/// one sentence (how it is, how long) and the things you might click. So: no
/// labels.
/// </summary>
public sealed partial class RunStrip : UserControl
{
    readonly DispatcherQueueTimer tick;
    RunState state = RunState.Idle;
    Health worst = Health.Starting;

    public RunStrip()
    {
        InitializeComponent();
        // The tick lives in here and touches one TextBlock. On the Mac,
        // driving it from ContentView re-rendered the whole detail every
        // second, which rebuilt the toolbar menus and dismissed any open
        // submenu; the same care applies to the flyouts here.
        tick = DispatcherQueue.GetForCurrentThread().CreateTimer();
        tick.Interval = TimeSpan.FromSeconds(1);
        tick.IsRepeating = true;
        tick.Tick += (_, _) => Uptime.Text = Elapsed(state.Epoch, DateTimeOffset.UtcNow);
        Loaded += (_, _) => SyncTick();
        Unloaded += (_, _) => tick.Stop();
        ActualThemeChanged += (_, _) =>
        {
            SetHealth(worst);
            Fill();
        };
    }

    /// <summary>`HH:MM:SS` since the engine's start time; a dash when it did not say.</summary>
    public static string Elapsed(double epoch, DateTimeOffset now)
    {
        if (epoch <= 0) return "—";
        var s = Math.Max(0, (long)(now.ToUnixTimeMilliseconds() / 1000.0 - epoch));
        return string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}:{2:00}", s / 3600, s % 3600 / 60, s % 60);
    }

    /// <summary>The run, and the worst of its targets' health (HealthMonitor.Worst).</summary>
    public void Show(RunState run, Health health)
    {
        var changedRun = !ReferenceEquals(run, state);
        state = run;
        SetHealth(health);
        if (changedRun) Fill();
        SyncTick();
    }

    public void SetHealth(Health health)
    {
        worst = health;
        Dot.Fill = Tones.Brush(this, health.Tone());
        HealthText.Text = health.Title();
    }

    void SyncTick()
    {
        Uptime.Text = Elapsed(state.Epoch, DateTimeOffset.UtcNow);
        if (state.Running && IsLoaded) tick.Start(); else tick.Stop();
    }

    void Fill()
    {
        // The chips live in the line between the label and the uptime.
        foreach (var old in Line.Children.OfType<Badge>().ToList()) Line.Children.Remove(old);
        var chips = new List<Badge>();

        // Which kind of run this is, because the two behave differently in the
        // way that matters: a worktree run is a snapshot and will not see your
        // edits, an in-place run is your checkout and will.
        if (state.Adopted)
            chips.Add(Tip(new Badge { Text = "started elsewhere", Symbol = "arrow.up.right.square", Tone = Tone.Orange },
                "Already running when Runbranch looked — not started by it"));
        else if (state.InPlace)
            chips.Add(Tip(new Badge { Text = "in place", Symbol = "pencil", Tone = Tone.Orange },
                "Running your checkout — edits and uncommitted work are live"));

        // A worktree is pinned to the commit it was cut at, so a run cannot
        // see anything pushed since. Saying so is most of the value here;
        // catching up is an action, and lives with the actions.
        if (state.Behind > 0)
            chips.Add(Tip(new Badge
            {
                Text = state.Behind == 1 ? "1 commit behind" : $"{state.Behind} commits behind",
                Symbol = "arrow.down.circle",
                Tone = Tone.Trunk,
            }, "The branch has moved on since this worktree was made"));

        // An in-place run whose checkout has been switched is still serving —
        // from whatever is on the branch now. The run is not broken, so this
        // is a warning rather than a failure: what is wrong is the label, and
        // possibly what you believe is running.
        if (state.SwitchedTo.Length > 0)
            chips.Add(Tip(new Badge { Text = $"now on {state.SwitchedTo}", Symbol = "exclamationmark.triangle.fill", Tone = Tone.Red },
                $"Started for {state.Ref}, but the checkout was switched to {state.SwitchedTo}. The servers are serving that."));

        var at = Line.Children.IndexOf(HealthText) + 1;
        foreach (var chip in chips) Line.Children.Insert(at++, chip);

        // A label, not a button: Open already opens it, and two ways to do one
        // thing is worse than one obvious way.
        Ports.Children.Clear();
        foreach (var t in state.Targets)
        {
            var label = new TextBlock
            {
                Text = $"localhost:{t.Port.ToString(CultureInfo.InvariantCulture)}",
                Style = (Style)Application.Current.Resources["RbBodyTextStyle"],
                Foreground = Tones.Lookup(this, "RbSecondaryBrush"),
                TextLineBounds = TextLineBounds.Tight,
                TextWrapping = TextWrapping.NoWrap,
            };
            ToolTipService.SetToolTip(label, t.Name);
            Ports.Children.Add(label);
        }
    }

    static Badge Tip(Badge badge, string tip)
    {
        ToolTipService.SetToolTip(badge, tip);
        return badge;
    }
}
