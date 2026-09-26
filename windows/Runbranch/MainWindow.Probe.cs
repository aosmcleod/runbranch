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

// RB_LAYOUT_PROBE=<file>: every two seconds, write the measured size of each
// thing the F6 grid pins — controls 28, chips 18, rows by their lines — so the
// grid can be checked by numbers rather than by squinting at a screenshot. A
// development aid; nothing reads the file but the person who asked for it.

using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Runbranch.Views;

namespace Runbranch;

public sealed partial class MainWindow
{
    Microsoft.UI.Dispatching.DispatcherQueueTimer? probeTimer;

    void WireProbe()
    {
        if (Environment.GetEnvironmentVariable("RB_LAYOUT_PROBE") is not { Length: > 0 } path) return;
        probeTimer = DispatcherQueue.CreateTimer();
        probeTimer.Interval = TimeSpan.FromSeconds(2);
        probeTimer.Tick += (_, _) =>
        {
            try { File.WriteAllLines(path, Probe()); } catch (IOException) { }
        };
        probeTimer.Start();
    }

    IEnumerable<string> Probe()
    {
        static string N(double d) => d.ToString("0.##", CultureInfo.InvariantCulture);
        string Size(string name, FrameworkElement? e) =>
            e is null || e.Visibility != Visibility.Visible ? $"{name} -" : $"{name} {N(e.ActualWidth)}x{N(e.ActualHeight)}";

        yield return $"scale {N(Scale)} theme {Root.ActualTheme}";
        var bar = AppWindow.TitleBar;
        yield return $"caption fg={bar.ButtonForegroundColor} inactive={bar.ButtonInactiveForegroundColor} " +
                     $"hover={bar.ButtonHoverBackgroundColor} pressed={bar.ButtonPressedBackgroundColor} height={bar.PreferredHeightOption} " +
                     $"lookup={Caption("RbCaptionForeground")}";
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter op)
            yield return $"presenter resizable={op.IsResizable} maximizable={op.IsMaximizable} compact={compactApplied}";
        yield return Size("titlebar", AppTitleBar);
        yield return $"caption-inset {N(AppWindow.TitleBar.RightInset / Scale)} (per button {N(AppWindow.TitleBar.RightInset / Scale / 3)})";
        yield return Size("pane", PaneButton);
        if (RightPaddingColumn() is { } rp) yield return $"titlebar-right-padding-column {N(rp.ActualWidth)} (set {rp.Width})";
        foreach (var b in new[] { FilterButton, RefreshButton, MoreButton })
            yield return $"{Size(b.Name, b)} x={N(b.TransformToVisual(AppTitleBar).TransformPoint(default).X)}";
        yield return Size("search", SearchBox);
        yield return Size("filter", FilterButton);
        yield return Size("refresh", RefreshButton);
        yield return Size("more", MoreButton);
        yield return Size("presets", PresetPicker);
        yield return Size("logs", LogsButton);
        yield return Size("open", OpenButton);
        yield return Size("update", UpdateButton);
        yield return Size("primary", PrimaryButton);
        {
            static string C(Brush? b) => b is SolidColorBrush s ? $"{s.Color}@{N(s.Opacity)}" : b?.GetType().Name ?? "null";
            var presenter = Descendants(PrimaryButton).OfType<ContentPresenter>().FirstOrDefault();
            var text = Descendants(PrimaryButton).OfType<TextBlock>().FirstOrDefault();
            yield return $"primary-colours button fg={C(PrimaryButton.Foreground)} bg={C(PrimaryButton.Background)} " +
                         $"presenter fg={C(presenter?.Foreground)} bg={C(presenter?.Background)} text fg={C(text?.Foreground)} " +
                         $"theme={PrimaryButton.ActualTheme}";
        }
        yield return Size("actionbar", ActionBar);
        yield return Size("strip", Strip);
        foreach (var item in projectItems.Values.Take(1)) yield return Size("sidebar-item", item);

        for (var i = 0; i < Math.Min(rows.Count, 4); i++)
        {
            if (BranchList.ContainerFromIndex(i) is not ListViewItem container) continue;
            yield return Size($"row{i}-container", container);
            if (Descendants(container).OfType<BranchRow>().FirstOrDefault() is not { } row) continue;
            yield return Size($"row{i}", row);
            if (Descendants(row).OfType<LinePanel>().FirstOrDefault() is not { } line) continue;
            foreach (var child in line.Children.OfType<FrameworkElement>())
            {
                var at = child.TransformToVisual(line).TransformPoint(default);
                // Where the text's baseline actually landed, from the arranged
                // label rather than from the layout's own arithmetic.
                var baseline = child switch
                {
                    Badge b => b.LabelElement.TransformToVisual(line).TransformPoint(default).Y + b.LabelElement.BaselineOffset,
                    TextBlock t => at.Y + t.BaselineOffset,
                    _ => double.NaN,
                };
                var label = child switch
                {
                    Badge b => $"chip '{b.Text}'",
                    TextBlock t => $"name '{t.Text}'",
                    _ => child.GetType().Name,
                };
                yield return $"  {label} h={N(child.ActualHeight)} top={N(at.Y)} baseline={N(baseline)}";
            }
        }
    }
}
