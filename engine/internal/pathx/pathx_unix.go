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

import (
	"os"
	"path/filepath"
)

// APFS is case-insensitive by default, but not always, and the bash engine
// compared case-sensitively. Keep that.
const foldCase = false

// No short names here, and Long leaves symlinks alone: a path the engine
// prints is the path it was given.
func longName(p string) string { return p }

// resolved is what a comparison sees: the path with its symlinks followed,
// as far as it exists. Only comparisons use it (key), and a comparison
// resolves both sides, so /var and /private/var agree. They did not before:
// lsof reports a process's working directory resolved, a config names it as
// written, and on macOS every temp directory is under /var, a symlink to
// /private/var. A repo reached through a symlink failed the same way.
func resolved(p string) string {
	rest := ""
	cur := p
	for {
		if r, err := filepath.EvalSymlinks(cur); err == nil {
			if rest == "" {
				return r
			}
			return filepath.Join(r, rest)
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p
		}
		rest = filepath.Join(filepath.Base(cur), rest)
		cur = parent
	}
}

func removeAll(p string) error {
	if p == "" {
		return nil
	}
	return os.RemoveAll(p)
}

// No MAX_PATH to reach past.
func extended(p string) string { return p }
