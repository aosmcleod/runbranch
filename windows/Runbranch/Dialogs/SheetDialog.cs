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

// What every sheet shares beyond its look (SheetStyles.xaml): the Mac's fixed
// size, and its keyboard — Return for the default action, Escape for the
// cancel action — which a ContentDialog with its own footer has to be told.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Runbranch.Dialogs;

public partial class SheetDialog : ContentDialog
{
    static readonly string[] PopupKeys =
        ["ToggleSwitchPreContentMargin", "ToggleSwitchPostContentMargin", "InfoBarTitleFontSize", "InfoBarMessageFontSize"];

    FrameworkElement? frame;
    double wanted = double.NaN;

    public SheetDialog()
    {
        // A subclass does not get the implicit ContentDialog style, which
        // matches on the exact type, and falls back to the pre-Fluent one.
        Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"];
        PreviewKeyDown += OnPreviewKeyDown;
        Opened += (_, _) =>
        {
            Fit();
            if (XamlRoot is { } r) r.Changed += OnRootChanged;
            // A dialog opens with focus on its first focusable element, which
            // in a footer is Cancel — and Return on a focused button presses
            // that button, so Return would cancel rather than do the default.
            // A text field keeps the focus: Return from one is the default anyway.
            if (XamlRoot is { } root && FocusManager.GetFocusedElement(root) is Button focused
                && DefaultAction is { IsEnabled: true, Visibility: Visibility.Visible } action && !ReferenceEquals(focused, action))
                action.Focus(FocusState.Programmatic);
        };
        Closed += (_, _) =>
        {
            if (XamlRoot is { } r) r.Changed -= OnRootChanged;
        };
    }

    /// <summary>
    /// The button Return presses: the Mac's `.keyboardShortcut(.defaultAction)`.
    /// null when nothing is the default right now (a run in progress).
    /// </summary>
    protected Button? DefaultAction { get; set; }

    /// <summary>
    /// What Escape does: the Mac's `.cancelAction`. Closing, unless a sheet
    /// says otherwise — a run in progress stops instead, an install cannot be
    /// walked away from. Sheets with no cancel button on the Mac close too:
    /// every Windows dialog does on Escape, and Done does the same thing.
    /// </summary>
    protected virtual void OnCancel() => Hide();

    /// <summary>
    /// Sizes the sheet to the Mac's frame. `height` NaN sizes it to its
    /// content (About). The stock maximums are raised to fit, per dialog, so
    /// one sheet's size cannot leak into another's.
    /// </summary>
    protected void Frame(FrameworkElement root, double width, double height)
    {
        frame = root;
        root.Width = width;
        // Lightweight-styling keys read by templates applied inside the
        // dialog's popup, where the dialog's own resources are no longer on
        // the lookup path: repeated on the sheet's root, which is. Without
        // this every ToggleSwitch in a sheet measured 36 rather than 28.
        foreach (var key in PopupKeys)
            if (Resources.TryGetValue(key, out var value)) root.Resources[key] = value;
        // One device-independent pixel for each side of the stock border.
        Resources["ContentDialogMaxWidth"] = width + 2;
        Resize(height);
    }

    /// <summary>A new height, for the Update sheet, which has two.</summary>
    protected void Resize(double height)
    {
        wanted = height;
        Resources["ContentDialogMaxHeight"] = double.IsNaN(height) ? 1000.0 : height + 2;
        Fit();
    }

    void OnRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => Fit();

    /// <summary>
    /// Never taller than the window. The main window's minimum is 440 high
    /// and the editor is 620: clipped, its footer and Save would be gone.
    /// </summary>
    void Fit()
    {
        if (frame is null) return;
        if (double.IsNaN(wanted))
        {
            frame.Height = double.NaN;
            return;
        }
        var room = XamlRoot is { } r ? r.Size.Height - 2 * (double)Application.Current.Resources["RbSpacingLarge"] : wanted;
        frame.Height = room > 0 ? Math.Min(wanted, room) : wanted;
    }

    void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            OnCancel();
            return;
        }
        if (e.Key != VirtualKey.Enter) return;
        // Return on a focused button presses that button, as Windows expects;
        // in a multi-line field it is a new line. Everywhere else it is the
        // default action — including a checkbox, which ignores Return.
        var focused = XamlRoot is null ? null : FocusManager.GetFocusedElement(XamlRoot);
        if (focused is ButtonBase and not CheckBox) return;
        if (focused is TextBox { AcceptsReturn: true } or ComboBox { IsDropDownOpen: true }) return;
        if (DefaultAction is not { IsEnabled: true, Visibility: Visibility.Visible } button) return;
        e.Handled = true;
        Press(button);
    }

    /// <summary>
    /// A resource for something built in code: the sheet's own (SheetStyles)
    /// first, then the app's (Tokens.xaml). The dialog's Resources indexer
    /// alone does not reach the app's, and a miss there is a fail-fast.
    /// </summary>
    protected T Resource<T>(string key) =>
        (T)(Resources.TryGetValue(key, out var mine) ? mine : Application.Current.Resources[key]);

    /// <summary>Clicks a button as a click would, so its Click handler is the only path.</summary>
    protected static void Press(Button button) =>
        (new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke) as IInvokeProvider)?.Invoke();
}
