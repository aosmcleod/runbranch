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

namespace Runbranch;

/// <summary>
/// The app's Build lives in App.xaml.cs, beside the WinUI Application this
/// project does not compile. Updates.cs only reads these two, for
/// Updater.Shared, which no test touches: the tests build their own Updater.
/// </summary>
static class Build
{
    public static string Version => "1.5.1";
    public static bool IsDevelopment => false;
}
