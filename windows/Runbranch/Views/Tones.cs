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
using Microsoft.UI.Xaml.Media;

namespace Runbranch.Views;

/// <summary>
/// The Tokens.xaml brush for a Tone, for views that set colours from code (the
/// health dot, a live project's glyph). Badge does the same lookup for itself.
///
/// By the element's own theme, read from the theme dictionary directly:
/// indexing Application.Resources answers for the app's theme, which is not
/// the element's when anything above it sets RequestedTheme. Callers look the
/// brush up again on ActualThemeChanged, since a brush from one theme keeps
/// its colour in the other.
/// </summary>
public static class Tones
{
    public static Brush? Brush(FrameworkElement element, Tone tone) => Lookup(element, $"Rb{tone}Brush");

    public static Brush? Lookup(FrameworkElement element, string key)
    {
        var theme = element.ActualTheme == ElementTheme.Dark ? "Dark" : "Light";
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
