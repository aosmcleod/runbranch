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

package disk

import (
	"io/fs"
	"path/filepath"
	"syscall"
)

// sizeKB is `du -sk`: allocated blocks, symlinks not followed, and each
// inode counted once — pnpm hardlinks its store into every node_modules, and
// a naive sum counts the same file in every worktree that links it.
func sizeKB(dir string) int64 {
	type ino struct{ dev, ino uint64 }
	seen := map[ino]bool{}
	var blocks int64
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		fi, err := d.Info()
		if err != nil {
			return nil
		}
		st, ok := fi.Sys().(*syscall.Stat_t)
		if !ok {
			blocks += (fi.Size() + 511) / 512
			return nil
		}
		if st.Nlink > 1 {
			k := ino{uint64(st.Dev), uint64(st.Ino)}
			if seen[k] {
				return nil
			}
			seen[k] = true
		}
		blocks += int64(st.Blocks)
		return nil
	})
	return (blocks*512 + 1023) / 1024
}
