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

//go:build !windows

package pathx

import "os"

// APFS is case-insensitive by default, but not always, and the bash engine
// compared case-sensitively. Keep that.
const foldCase = false

// No short names here. Symlinks are deliberately not resolved: the bash
// engine compared the paths it was given, and resolving /var to /private/var
// on one side only would break more comparisons than it fixed.
func longName(p string) string { return p }

func removeAll(p string) error {
	if p == "" {
		return nil
	}
	return os.RemoveAll(p)
}

// No MAX_PATH to reach past.
func extended(p string) string { return p }
