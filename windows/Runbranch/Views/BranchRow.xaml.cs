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

namespace Runbranch.Views;

/// <summary>
/// What one list row needs: the branch, and the two facts about the run that
/// change how it is drawn. A record, so the list can tell a row that changed
/// from one that did not and leave the rest alone.
/// </summary>
public sealed record BranchItem(Branch Branch, bool IsLive, bool ShowGutter)
{
    public string Ref => Branch.Ref;

    /// <summary>What a list item is called to a screen reader: the branch, not the record.</summary>
    public override string ToString() => Branch.Display;
}

public sealed partial class BranchRow : UserControl
{
    public BranchRow()
    {
        InitializeComponent();
        // The glyphs set from code carry a brush from one theme.
        ActualThemeChanged += (_, _) => Fill();
    }

    public static readonly DependencyProperty ItemProperty = DependencyProperty.Register(
        nameof(Item), typeof(BranchItem), typeof(BranchRow), new PropertyMetadata(null, (d, _) => ((BranchRow)d).Fill()));

    public BranchItem? Item
    {
        get => (BranchItem?)GetValue(ItemProperty);
        set => SetValue(ItemProperty, value);
    }

    void Fill()
    {
        Line.Children.Clear();
        if (Item is not { } item) return;
        var b = item.Branch;

        Gutter.Visibility = item.ShowGutter ? Visibility.Visible : Visibility.Collapsed;
        Spinner.IsActive = item.IsLive;
        Spinner.Visibility = item.IsLive ? Visibility.Visible : Visibility.Collapsed;

        if (b.IsRemote)
        {
            var cloud = Icons.Make("cloud", (double)Application.Current.Resources["RbBadgeIconSize"]);
            cloud.Foreground = Tones.Lookup(this, "RbTertiaryBrush");
            cloud.VerticalAlignment = VerticalAlignment.Center;
            ToolTipService.SetToolTip(cloud, "Remote branch — selecting it builds a worktree at its tip");
            Line.Children.Add(cloud);
        }

        // Tail truncation, not the Mac's middle truncation: WinUI's TextBlock
        // has only the one. The end of a branch name is usually the part that
        // tells two apart, which is why the Mac kept it; the tooltip keeps it
        // here.
        var name = new TextBlock
        {
            Text = b.Display,
            Style = (Style)Application.Current.Resources["RbBodyTextStyle"],
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            VerticalAlignment = VerticalAlignment.Center,
            // The badges' own bounds, so the name and the capsules centre on
            // the same line rather than the name riding low by its descenders.
            TextLineBounds = TextLineBounds.Tight,
        };
        ToolTipService.SetToolTip(name, b.Ref);
        Line.Children.Add(name);

        if (b.IsDefault)
        {
            Line.Children.Add(new Badge { Text = "default", Tone = Tone.Trunk });
        }
        else if (b.PR.Label() is { } label)
        {
            Line.Children.Add(new Badge { Text = label, Symbol = Glyphs.OrNone(b.PR.Symbol()), Tone = b.PR.Tone() });
        }
        else if (b.IsSubsumed)
        {
            // Everything on this branch is already in the trunk, and no pull
            // request said so. Squashes, rebases and merges done by hand all
            // land here — the commit graph is the only thing that can see them.
            Line.Children.Add(Tip(new Badge { Text = "merged", Symbol = Glyphs.OrNone(PRState.Merged.Symbol()), Tone = PRState.Merged.Tone() },
                "Nothing here the default branch does not already have — safe to delete"));
        }

        if (b.Owner.Length > 0) Line.Children.Add(new Badge { Text = b.Owner });

        // What is actually being worked on. This is the branch your checkout
        // is sitting on, so it is the one whose edits are live on disk — and
        // the only one that can be run in place.
        if (b.IsCurrent)
            Line.Children.Add(new Badge { Text = "checked out", Symbol = "pencil", Tone = Tone.Orange });
        else if (b.CheckedOutAt.Length > 0)
            Line.Children.Add(Tip(new Badge { Text = "in another worktree", Symbol = Glyphs.OrNone("arrow.triangle.branch"), Tone = Tone.Purple },
                b.CheckedOutAt.AbbreviatingHome()));

        if (!item.IsLive && b.Ready)
            Line.Children.Add(new Badge { Text = "ready", Symbol = "bolt.fill", Tone = Tone.Green });

        // What the work actually is. A branch name is what someone called it;
        // this is what it does.
        Subject.Text = b.Subject;

        // How old, then how far from the trunk — the two questions you ask of
        // a branch you do not recognise, stacked to match the two lines on the
        // left rather than crowding the badges.
        Age.Text = b.Age;
        Divergence.Text = b.HasDivergence ? DivergenceText(b) : "";
        ToolTipService.SetToolTip(Divergence, b.HasDivergence ? DivergenceHelp(b) : null);
    }

    static Badge Tip(Badge badge, string tip)
    {
        ToolTipService.SetToolTip(badge, tip);
        return badge;
    }

    /// <summary>
    /// Arrows rather than `+3 / -8`: plus and minus in a list of commits reads
    /// as added and removed lines, which is a different number entirely.
    /// </summary>
    public static string DivergenceText(Branch b)
    {
        var parts = new List<string>();
        if (b.Ahead is > 0 and var a) parts.Add($"↑{a}");
        if (b.Behind is > 0 and var n) parts.Add($"↓{n}");
        return string.Join(' ', parts);
    }

    public static string DivergenceHelp(Branch b)
    {
        var parts = new List<string>();
        if (b.Ahead is > 0 and var a) parts.Add($"{a} ahead of the default branch");
        if (b.Behind is > 0 and var n) parts.Add($"{n} behind");
        return "Commits: " + string.Join(", ", parts);
    }
}
