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
using Microsoft.UI.Xaml.Media.Imaging;

namespace Runbranch.Views;

public sealed partial class WelcomeView : UserControl
{
    public WelcomeView()
    {
        InitializeComponent();
        Mark.Source = new BitmapImage(new Uri(Build.MarkUri));
        ScanButton.Click += (_, _) => ScanRequested?.Invoke(this, EventArgs.Empty);
        AddButton.Click += (_, _) => AddRequested?.Invoke(this, EventArgs.Empty);
    }

    public event EventHandler? ScanRequested;
    public event EventHandler? AddRequested;
}
