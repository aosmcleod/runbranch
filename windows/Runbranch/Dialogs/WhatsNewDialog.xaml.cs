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
using Microsoft.UI.Xaml.Media.Imaging;
using Runbranch.Views;

namespace Runbranch.Dialogs;

public sealed partial class WhatsNewDialog : SheetDialog
{
    public WhatsNewDialog(IReadOnlyList<ReleaseNote> entries, AppVersion installed)
    {
        InitializeComponent();
        Frame(Root, 520, 440);
        DefaultAction = Continue;
        Mark.Source = new BitmapImage(new Uri(Build.MarkUri));
        Heading.Text = $"What's new in Runbranch {installed.Description}";
        Subtitle.Text = entries.Count > 1 ? $"{entries.Count} releases since you last opened it" : "Updated from within Runbranch";
        Changelog.NavigateUri = ReleaseFeed.ReleasesPage;

        foreach (var entry in entries)
        {
            var section = new StackPanel();
            // The version only earns a line of its own when there is more
            // than one, which is the skipped-a-release case.
            if (entries.Count > 1)
                section.Children.Add(new TextBlock { Text = entry.Version, Style = Resource<Style>("VersionStyle") });
            section.Children.Add(new NotesText { Text = entry.Notes });
            Entries.Children.Add(section);
        }
    }

    void OnContinue(object sender, RoutedEventArgs e) => Hide();
}
