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
using Microsoft.UI.Xaml.Media;

namespace Runbranch.Views;

/// <summary>
/// &lt;views:Badge Text="ready" Symbol="bolt.fill" Tone="Green" /&gt;
///
/// Symbol is an SF Symbol name (Icons.cs maps it), empty for text alone.
/// Tone picks the colour from Tokens.xaml. The Mac's `onFill` variant, for a
/// badge over a solid accent selection, is not needed: a Windows list
/// selection is a subtle fill with an accent pill, not a solid accent.
/// </summary>
public sealed partial class Badge : UserControl
{
    public Badge()
    {
        InitializeComponent();
        // Theme brushes are looked up by key, so a switch between light and
        // dark has to look them up again.
        ActualThemeChanged += (_, _) => ApplyTone();
        Loaded += (_, _) => ApplyTone();
    }

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(Badge), new PropertyMetadata("", (d, e) => ((Badge)d).Label.Text = (string)e.NewValue ?? ""));

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public static readonly DependencyProperty SymbolProperty = DependencyProperty.Register(
        nameof(Symbol), typeof(string), typeof(Badge), new PropertyMetadata("", (d, _) => ((Badge)d).ApplySymbol()));

    public string Symbol
    {
        get => (string)GetValue(SymbolProperty);
        set => SetValue(SymbolProperty, value);
    }

    public static readonly DependencyProperty ToneProperty = DependencyProperty.Register(
        nameof(Tone), typeof(Tone), typeof(Badge), new PropertyMetadata(Tone.Secondary, (d, _) => ((Badge)d).ApplyTone()));

    public Tone Tone
    {
        get => (Tone)GetValue(ToneProperty);
        set => SetValue(ToneProperty, value);
    }

    /// <summary>
    /// From the chip's top to its text's baseline, once measured: the label
    /// sits centred in the chip, and its own BaselineOffset says where the
    /// baseline is inside it. LinePanel uses this to put chips on the branch
    /// name's baseline.
    /// </summary>
    public double Baseline => (Capsule.Height - Label.DesiredSize.Height) / 2 + Label.BaselineOffset;

    /// <summary>The label, for the layout probe's measurements.</summary>
    internal TextBlock LabelElement => Label;

    void ApplySymbol()
    {
        if (string.IsNullOrEmpty(Symbol))
        {
            Glyph.Visibility = Visibility.Collapsed;
            // Spacing only between an icon and its text; with no icon it
            // would be an extra 4 px at the chip's left end.
            Parts.ColumnSpacing = 0;
            return;
        }
        var g = Icons.Glyph(Symbol);
        Glyph.FontFamily = g.Family;
        Glyph.Glyph = g.Glyph;
        Glyph.Visibility = Visibility.Visible;
        Parts.ColumnSpacing = (double)Application.Current.Resources["RbSpacingSmall"];
    }

    void ApplyTone()
    {
        var fg = Lookup($"Rb{Tone}Brush");
        var bg = Lookup($"Rb{Tone}FillBrush");
        Label.Foreground = fg;
        Glyph.Foreground = fg;
        Capsule.Background = bg;
    }

    /// <summary>
    /// The brush for this control's current theme. Application.Resources
    /// indexing answers for the app's theme, which is not this element's when
    /// a page sets RequestedTheme, so the theme dictionary is read directly.
    /// </summary>
    Brush? Lookup(string key)
    {
        var theme = ActualTheme == ElementTheme.Dark ? "Dark" : "Light";
        foreach (var dict in Application.Current.Resources.MergedDictionaries.Prepend(Application.Current.Resources))
        {
            if (dict.ThemeDictionaries.TryGetValue(theme, out var t) && t is ResourceDictionary td &&
                td.TryGetValue(key, out var v) && v is Brush b)
                return b;
            if (dict.TryGetValue(key, out var plain) && plain is Brush pb) return pb;
        }
        return null;
    }
}
