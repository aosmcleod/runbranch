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

// The window the sheets belong to, for the things a XamlRoot cannot do: a
// folder picker in an unpackaged app has to be told which window owns it.

using Microsoft.UI;

namespace Runbranch.Dialogs;

public static class Host
{
    static nint handle;

    /// <summary>
    /// The main window's handle. Set it if the sheets are shown over some
    /// other window; otherwise it is App.Instance.Window's, found when first
    /// asked, so the main window has nothing to wire up.
    /// </summary>
    public static nint WindowHandle
    {
        get => handle != 0 ? handle
            : App.Instance?.Window is { } w ? WinRT.Interop.WindowNative.GetWindowHandle(w) : 0;
        set => handle = value;
    }

    public static WindowId WindowId => Win32Interop.GetWindowIdFromWindow(WindowHandle);
}
