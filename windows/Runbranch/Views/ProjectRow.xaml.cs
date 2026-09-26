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

public sealed partial class ProjectRow : UserControl
{
    public ProjectRow() => InitializeComponent();

    public ProjectRow(Project project, bool isLive) : this() => Show(project, isLive);

    public void Show(Project project, bool isLive)
    {
        NameText.Text = project.Name;
        Spinner.IsActive = isLive;
        Spinner.Visibility = isLive ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(this, project.Repo.AbbreviatingHome());
    }

    /// <summary>
    /// The project's own glyph (its config's SYMBOL, mapped by Icons), at the
    /// sidebar's icon size. Green while something runs, as on the Mac; the
    /// stock foreground otherwise, because a NavigationView's icons are
    /// primary text and a grey one would read as disabled here. The Mac's
    /// white-when-selected is not needed: a Windows selection is a subtle fill
    /// with an accent pill, not a solid accent the glyph has to stand off.
    /// </summary>
    public static FontIcon Icon(Project project, bool isLive, FrameworkElement themeSource)
    {
        var icon = Icons.Make(project.Symbol, (double)Application.Current.Resources["RbIconSize"]);
        if (isLive && Tones.Brush(themeSource, Tone.Green) is { } green) icon.Foreground = green;
        return icon;
    }
}
