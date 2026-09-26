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

namespace Runbranch.Dialogs;

public sealed partial class ConfirmRemoveDialog : SheetDialog
{
    public ConfirmRemoveDialog(Project project)
    {
        InitializeComponent();
        Frame(Root, 420, double.NaN);
        Heading.Text = $"Remove {project.Name}?";
        Untouched.Text = $"The repository at {project.Repo.AbbreviatingHome()} is not touched.";
        // No default action. Removing is not something Return should do:
        // focus starts on Cancel, the first button, so Return cancels and
        // Remove takes a deliberate click. Escape cancels as on every sheet.
        DefaultAction = null;
    }

    public bool Confirmed { get; private set; }

    void OnCancelClick(object sender, RoutedEventArgs e) => Hide();

    void OnRemove(object sender, RoutedEventArgs e)
    {
        Confirmed = true;
        Hide();
    }
}
