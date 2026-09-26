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

package run

import (
	"os"
	"path/filepath"
)

// Where macOS tools live when launchd's PATH does not include them.
func extraPathDirs() []string {
	home, _ := os.UserHomeDir()
	return []string{
		"/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
		filepath.Join(home, ".local", "bin"), filepath.Join(home, "Library", "pnpm"),
		"/Applications/Docker.app/Contents/Resources/bin",
	}
}

// LongPathsEnabled has no meaning off Windows.
func LongPathsEnabled() (enabled, known bool) { return true, false }
