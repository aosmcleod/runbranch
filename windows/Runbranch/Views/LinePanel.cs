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
using Windows.Foundation;

namespace Runbranch.Views;

/// <summary>
/// One line of a row: children side by side, centred on the line, where the
/// first TextBlock gives up width before anything else does.
///
/// A branch row is a name followed by its badges. A horizontal StackPanel
/// never shrinks the name, so a long one pushed the badges out of the row and
/// clipped them; a Grid with the name in a star column keeps the name but
/// strands the badges at the far edge. The Mac's HStack does what is wanted —
/// the name truncates and the badges sit right after it — and this is that.
/// </summary>
public sealed partial class LinePanel : Panel
{
    public static readonly DependencyProperty SpacingProperty = DependencyProperty.Register(
        nameof(Spacing), typeof(double), typeof(LinePanel), new PropertyMetadata(8.0, (d, _) => ((LinePanel)d).InvalidateMeasure()));

    public double Spacing
    {
        get => (double)GetValue(SpacingProperty);
        set => SetValue(SpacingProperty, value);
    }

    UIElement? Shrinker => Children.FirstOrDefault(c => c is TextBlock && c.Visibility == Visibility.Visible);

    IEnumerable<UIElement> Shown => Children.Where(c => c.Visibility == Visibility.Visible);

    protected override Size MeasureOverride(Size available)
    {
        var shrinker = Shrinker;
        double used = 0, height = 0;
        var count = 0;
        foreach (var c in Shown)
        {
            count++;
            if (c == shrinker) continue;
            c.Measure(new Size(double.PositiveInfinity, available.Height));
            used += c.DesiredSize.Width;
            height = Math.Max(height, c.DesiredSize.Height);
        }
        used += Math.Max(0, count - 1) * Spacing;
        if (shrinker is not null)
        {
            var room = double.IsInfinity(available.Width) ? double.PositiveInfinity : Math.Max(0, available.Width - used);
            shrinker.Measure(new Size(room, available.Height));
            used += shrinker.DesiredSize.Width;
            height = Math.Max(height, shrinker.DesiredSize.Height);
        }
        return new Size(double.IsInfinity(available.Width) ? used : Math.Min(used, available.Width), height);
    }

    /// <summary>
    /// Text sits on one baseline, the way a line of type does: the name and
    /// every chip's label, whatever their sizes. Centring each child instead
    /// put 13 px and 11 px text on different baselines, a pixel or two apart,
    /// which reads as the chips floating. The tallest child with a baseline
    /// (a chip, when there is one) is centred on the line, and the rest are
    /// hung from its baseline. Anything without text — an icon — is centred.
    /// </summary>
    protected override Size ArrangeOverride(Size final)
    {
        var shown = Shown.ToList();
        double? line = null;
        double tallest = -1;
        foreach (var c in shown)
        {
            if (BaselineOf(c) is not { } b || c.DesiredSize.Height <= tallest) continue;
            tallest = c.DesiredSize.Height;
            line = (final.Height - c.DesiredSize.Height) / 2 + b;
        }

        double x = 0;
        foreach (var c in shown)
        {
            var w = c.DesiredSize.Width;
            var h = c.DesiredSize.Height;
            var top = line is { } l && BaselineOf(c) is { } b ? l - b : (final.Height - h) / 2;
            c.Arrange(new Rect(x, top, w, h));
            x += w + Spacing;
        }
        return final;
    }

    /// <summary>
    /// From a child's top to its text's baseline: a TextBlock's own
    /// BaselineOffset, a Badge's Baseline, and nothing for anything else. Not
    /// the height of a tight TextBlock, though that is where its baseline
    /// nominally is: the desired height is rounded to the pixel grid and the
    /// text is not, which put the name 0.7 px above the chips at 125%.
    /// </summary>
    static double? BaselineOf(UIElement c) => c switch
    {
        Badge badge => badge.Baseline,
        TextBlock { TextLineBounds: TextLineBounds.Tight } t => t.BaselineOffset > 0 ? t.BaselineOffset : t.DesiredSize.Height,
        _ => null,
    };
}
