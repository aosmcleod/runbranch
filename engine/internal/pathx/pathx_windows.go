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

package pathx

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

// NTFS preserves case and ignores it.
const foldCase = true

// longName expands 8.3 components with GetLongPathName. That call fails on a
// path that does not exist, so it is applied to the deepest ancestor that
// does and the remainder is re-attached as written.
// resolved is the path a comparison sees. Long already did the work that
// matters on Windows (8.3 names); junctions are left as they are.
func resolved(p string) string { return p }

func longName(p string) string {
	rest := ""
	cur := p
	for {
		if _, err := os.Lstat(cur); err == nil {
			break
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p
		}
		rest = filepath.Join(filepath.Base(cur), rest)
		cur = parent
	}
	u, err := windows.UTF16PtrFromString(cur)
	if err != nil {
		return p
	}
	buf := make([]uint16, windows.MAX_LONG_PATH)
	n, err := windows.GetLongPathName(u, &buf[0], uint32(len(buf)))
	if err != nil || n == 0 || int(n) > len(buf) {
		return p
	}
	long := windows.UTF16ToString(buf[:n])
	if rest == "" {
		return long
	}
	return filepath.Join(long, rest)
}

// extended gives a path the \\?\ prefix, which lifts the 260-character limit
// for every API that accepts it. A worktree's node_modules routinely passes
// 260, and LongPathsEnabled is off by default.
func extended(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	if strings.HasPrefix(abs, `\\?\`) {
		return abs
	}
	if strings.HasPrefix(abs, `\\`) {
		return `\\?\UNC\` + abs[2:]
	}
	return `\\?\` + abs
}

func removeAll(p string) error {
	if p == "" {
		return nil
	}
	x := extended(p)
	if err := os.RemoveAll(x); err == nil {
		return nil
	}
	// Git marks its object files read-only, and Windows will not delete a
	// read-only file. Clear the attribute on everything and try once more.
	_ = filepath.WalkDir(x, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if u, e := windows.UTF16PtrFromString(path); e == nil {
			if attrs, e := windows.GetFileAttributes(u); e == nil && attrs&windows.FILE_ATTRIBUTE_READONLY != 0 {
				_ = windows.SetFileAttributes(u, attrs&^windows.FILE_ATTRIBUTE_READONLY)
			}
		}
		return nil
	})
	return os.RemoveAll(x)
}
