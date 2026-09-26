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
using Microsoft.UI.Xaml.Media.Imaging;

namespace Runbranch.Dialogs;

/// <summary>
/// A dialog rather than the Mac's free-standing panel (spec D16): there is no
/// Settings page to host it, and a second top-level window for four lines of
/// text is more window than it needs.
/// </summary>
public sealed partial class AboutDialog : SheetDialog
{
    public AboutDialog()
    {
        InitializeComponent();
        Frame(Root, 340, double.NaN);
        DefaultAction = Done;
        Mark.Source = new BitmapImage(new Uri(Build.MarkUri));
        Version.Text = $"Version {Build.Version}";
        DevBadge.Visibility = Build.LooksDevelopment ? Visibility.Visible : Visibility.Collapsed;
        Repo.NavigateUri = new Uri(Build.RepositoryUrl);
    }

    void OnDone(object sender, RoutedEventArgs e) => Hide();
}
