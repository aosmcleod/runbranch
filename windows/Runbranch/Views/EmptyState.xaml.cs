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

using Microsoft.UI.Xaml.Controls;

namespace Runbranch.Views;

public sealed partial class EmptyState : UserControl
{
    public EmptyState() => InitializeComponent();

    /// <summary>An SF Symbol name (Icons maps it), a title, and the line under it.</summary>
    public void Show(string symbol, string title, string message)
    {
        var shown = Views.Glyphs.OrNone(symbol);
        Glyph.Visibility = shown.Length > 0 ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        var g = Icons.Glyph(shown);
        Glyph.FontFamily = g.Family;
        Glyph.Glyph = g.Glyph;
        TitleText.Text = title;
        MessageText.Text = message;
    }
}
