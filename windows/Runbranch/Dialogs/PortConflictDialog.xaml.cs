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

// What to do about a port that is already taken.
//
// Three ways out, in the order they are usually wanted: take the port from our
// own run, go somewhere else, or think again. "Switch" is primary because the
// common case is wanting to look at this branch instead of the one running —
// and because it keeps the URL where the user expects it. The sheet only
// decides; the main window does what was chosen (Sheets.cs).

using System.Globalization;
using Microsoft.UI.Xaml;

namespace Runbranch.Dialogs;

public sealed record ClashRow(string Target, string Port, string Description);

public sealed partial class PortConflictDialog : SheetDialog
{
    public PortConflictDialog(PendingRun pending)
    {
        InitializeComponent();
        Frame(Root, 460, 300);
        var conflict = pending.Conflict;

        Subtitle.Text = PortRules.Subtitle(conflict);
        Clashes.ItemsSource = conflict.Clashes
            .Select(c => new ClashRow(c.Target, "port " + c.Port.ToString(CultureInfo.InvariantCulture), PortRules.Describe(c)))
            .ToList();
        if (conflict.ShiftIsBestEffort)
        {
            Caveat.Text = PortRules.ShiftCaveat;
            Caveat.Visibility = Visibility.Visible;
        }

        if (conflict.CanShift)
        {
            Shift.Content = "Run on " + PortRules.ShiftedFirstPort(conflict).ToString(CultureInfo.InvariantCulture);
            Shift.Visibility = Visibility.Visible;
        }
        if (conflict.Owners.Count > 0)
        {
            Switch.Visibility = Visibility.Visible;
            DefaultAction = Switch;
        }
        else if (conflict.Outsiders.Count > 0)
        {
            TakeOver.Content = PortRules.TakeOverLabel(conflict);
            TakeOver.Visibility = Visibility.Visible;
        }
    }

    public PortResolution Resolution { get; private set; } = PortResolution.Cancel;

    void Choose(PortResolution r)
    {
        Resolution = r;
        Hide();
    }

    void OnCancelClick(object sender, RoutedEventArgs e) => Choose(PortResolution.Cancel);
    void OnShift(object sender, RoutedEventArgs e) => Choose(PortResolution.Shift);
    void OnSwitch(object sender, RoutedEventArgs e) => Choose(PortResolution.StopAndSwitch);
    void OnTakeOver(object sender, RoutedEventArgs e) => Choose(PortResolution.TakeOver);
}
